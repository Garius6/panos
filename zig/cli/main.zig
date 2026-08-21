const std = @import("std");
const panos_core = @import("panos_core");
const panos_embed = @import("panos_embed");

pub const DiagnosticFormatError = panos_core.diagnostic.FormatError;

pub const Execution = panos_core.runner.Execution;
pub const VerboseInfo = panos_core.runner.VerboseInfo;
pub const SourceRun = panos_core.runner.SourceRun;

pub const formatDiagnostic = panos_core.diagnostic.format;

pub fn runSource(allocator: std.mem.Allocator, path: []const u8, input: []const u8) !SourceRun {
    return panos_core.runner.runSource(allocator, path, input);
}

pub fn runSourceWithVerbose(allocator: std.mem.Allocator, path: []const u8, input: []const u8, verbose: bool) !SourceRun {
    return panos_core.runner.runSourceWithVerbose(allocator, path, input, verbose);
}

pub fn writeDiagnostics(writer: *std.Io.Writer, file: panos_core.source.SourceFile, diagnostics: *const panos_core.diagnostic.DiagnosticList) !void {
    for (diagnostics.items.items) |value| {
        const rendered = try formatDiagnostic(std.heap.page_allocator, file, value);
        defer std.heap.page_allocator.free(rendered);
        try writer.print("{s}\n", .{rendered});
    }
}

pub fn writeVerboseInfo(writer: *std.Io.Writer, info: VerboseInfo) !void {
    try writer.print("AST\n--------------------------\nдеклараций: {d}\n\n", .{info.declarations});
    if (info.symbols) |symbols| {
        try writer.print("TYPE CHECK\n--------------------------\nсимволов: {d}\n", .{symbols});
        if (info.types) |types| try writer.print("типов: {d}\n", .{types});
        try writer.print("\n", .{});
    }
    if (info.functions) |functions| {
        try writer.print("BYTECODE\n--------------------------\nфункций: {d}\n\n", .{functions});
    }
}

const FileReader = struct {
    io: std.Io,

    pub fn read(self: *const FileReader, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(16 * 1024 * 1024));
    }
};

const writeGraphDiagnostics = panos_core.diagnostic.writeGraph;

fn writeModuleDiagnostics(writer: *std.Io.Writer, graph: *const panos_core.module_loader.Graph) !void {
    return writeGraphDiagnostics(writer, graph, &graph.diagnostics);
}

fn hasErrors(diagnostics: *const panos_core.diagnostic.DiagnosticList) bool {
    for (diagnostics.items.items) |value| {
        if (value.severity == .err) return true;
    }
    return false;
}

fn writeAnalysisDiagnostics(writer: *std.Io.Writer, analysis: *const panos_core.runner.SourceAnalysis) !void {
    // `analysis.graph` равен null, только если `reportUnsupportedImports`
    // отклоняет исходник ещё до построения графа (`runner.zig`) — в этом
    // случае нет модуля/файла, относительно которого разрешать диапазон,
    // поэтому используется голое сообщение (тот же fallback, что и у
    // `writeGraphDiagnostics`, когда поиск конкретного файла не удаётся).
    if (analysis.graph) |*graph| {
        try writeGraphDiagnostics(writer, graph, &analysis.diagnostics);
    } else {
        for (analysis.diagnostics.items.items) |item| try writer.print("{s}\n", .{item.message});
    }
}

// `panos build --compile <файл.pns> [-o выход]` — автономный исполняемый
// файл в стиле Bun. Полный дизайн см. в doc-комментарии модуля
// `zig/core/bundle.zig` (внутрь встраивается ИСХОДНИК, а не байткод —
// получившийся бинарник перекомпилирует его при каждом запуске). Эта
// команда прогоняет обычный `module_loader.Graph.load` точно так же, как
// нормальный запуск `panos <file>` (реальный поиск через `$PANOS_STDLIB`/
// `std/` рядом с исполняемым файлом — на этапе СБОРКИ нужна именно
// настоящая stdlib, чтобы `bundle.collect` мог захватить те модули,
// которые программа реально использовала), затем передаёт полученный
// граф в `bundle.collect`, чтобы свернуть его во встраиваемый bundle.
fn runCompile(init: std.process.Init, stdout: *std.Io.Writer, stderr: *std.Io.Writer, input: []const u8, output_arg: []const u8) !void {
    if (input.len == 0) {
        try stderr.print("panos build --compile <файл.pns> [-o выход]\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    var output_owned: ?[]u8 = null;
    defer if (output_owned) |owned| init.gpa.free(owned);
    var output = output_arg;
    if (output.len == 0) {
        const base = if (std.mem.endsWith(u8, input, ".pns"))
            input[0 .. input.len - 4]
        else if (std.mem.endsWith(u8, input, ".ps"))
            input[0 .. input.len - 3]
        else
            input;
        output_owned = try init.gpa.dupe(u8, base);
        output = output_owned.?;
    }

    var graph = panos_core.module_loader.Graph.init(init.gpa);
    defer graph.deinit();
    var global_search_roots: std.ArrayList([]const u8) = .empty;
    defer {
        for (global_search_roots.items) |root| init.gpa.free(root);
        global_search_roots.deinit(init.gpa);
    }
    if (init.environ_map.get("PANOS_STDLIB")) |stdlib_dir| {
        try global_search_roots.append(init.gpa, try init.gpa.dupe(u8, stdlib_dir));
    }
    var exe_dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (std.process.executableDirPath(init.io, &exe_dir_buffer)) |len| {
        try global_search_roots.append(init.gpa, try std.fmt.allocPrint(init.gpa, "{s}/std", .{exe_dir_buffer[0..len]}));
    } else |_| {}
    graph.global_search_roots = global_search_roots.items;
    try graph.load(&FileReader{ .io = init.io }, input);
    if (graph.diagnostics.items.items.len != 0) {
        try writeModuleDiagnostics(stderr, &graph);
        if (hasErrors(&graph.diagnostics)) {
            try stderr.flush();
            std.process.exit(1);
        }
    }

    var bundle = try panos_core.bundle.collect(init.gpa, init.io, &graph, global_search_roots.items);
    defer bundle.deinit();
    const bundle_bytes = try panos_core.bundle.serialize(init.gpa, &bundle);
    defer init.gpa.free(bundle_bytes);

    var exe_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const exe_path_len = std.process.executablePath(init.io, &exe_path_buffer) catch {
        try stderr.print("panos build --compile: не удалось определить путь к собственному исполняемому файлу\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };
    const base_binary = try std.Io.Dir.cwd().readFileAlloc(init.io, exe_path_buffer[0..exe_path_len], init.gpa, .limited(256 * 1024 * 1024));
    defer init.gpa.free(base_binary);

    const combined = try panos_core.bundle.appendTrailer(init.gpa, base_binary, bundle_bytes);
    defer init.gpa.free(combined);

    std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output, .data = combined }) catch |err| {
        try stderr.print("panos build --compile: не удалось записать {s}: {t}\n", .{ output, err });
        try stderr.flush();
        std.process.exit(1);
    };
    // Бит "исполняемый" — у исходного бинарника, откуда всё скопировано, он
    // уже стоит, но `writeFile`/`createFile` выше создают НОВЫЙ файл с
    // правами по умолчанию (не исполняемый), не наследуя их ниоткуда.
    var output_file = std.Io.Dir.cwd().openFile(init.io, output, .{}) catch |err| {
        try stderr.print("panos build --compile: записан {s}, но не удалось выставить право на выполнение: {t}\n", .{ output, err });
        try stderr.flush();
        std.process.exit(1);
    };
    defer output_file.close(init.io);
    output_file.setPermissions(init.io, .executable_file) catch |err| {
        try stderr.print("panos build --compile: записан {s}, но не удалось выставить право на выполнение: {t}\n", .{ output, err });
        try stderr.flush();
        std.process.exit(1);
    };

    try stdout.print("panos build --compile: записан {s} ({d} модул(ей/ь) в bundle)\n", .{ output, bundle.entries.len });
    try stdout.flush();
}

// `panos build --target=wasm <файл.ps> [-o выход.wasm]`. Поддержка
// многофайлового `импорт` по-настоящему: `graph.load` ниже разрешает весь
// граф модулей входного файла на диске (`FileReader`, корень поиска
// `PANOS_STDLIB`) так же, как это делает нативное исполнение, а
// `mir_lowering.zig` опускает уровнем ниже получившийся граф целиком, а не
// изолированный `ast.Ast`. Обычные (негенерик) файловые импорты `std/`
// работают целиком — проверено на `импорт "математика"`, скомпилированном
// и запущенном под wasmtime. Остаётся более узкий пробел именно для
// ГЕНЕРИК файловых импортов (например `импорт "коллекции"`, все
// экспортируемые функции которого — `[T]`) — понижение MIR отклоняет их с
// `AotUnsupported`, первопричина ещё не найдена.
fn runBuild(init: std.process.Init, stdout: *std.Io.Writer, stderr: *std.Io.Writer, arguments: *std.process.Args.Iterator) !void {
    var target: []const u8 = "";
    var input: []const u8 = "";
    var output: []const u8 = "";
    var compile = false;

    while (arguments.next()) |arg| {
        if (std.mem.eql(u8, arg, "--target")) {
            target = arguments.next() orelse "";
        } else if (std.mem.startsWith(u8, arg, "--target=")) {
            target = arg["--target=".len..];
        } else if (std.mem.eql(u8, arg, "--compile")) {
            compile = true;
        } else if (std.mem.eql(u8, arg, "-o")) {
            output = arguments.next() orelse "";
        } else {
            input = arg;
        }
    }

    if (compile) {
        try runCompile(init, stdout, stderr, input, output);
        return;
    }

    if (!std.mem.eql(u8, target, "wasm")) {
        try stderr.print("panos build: поддерживается --target=wasm или --compile (получено таргет: \"{s}\")\n", .{target});
        try stderr.flush();
        std.process.exit(1);
    }
    if (input.len == 0) {
        try stderr.print("panos build --target=wasm <файл.ps> [-o выход.wasm]\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    var output_owned: ?[]u8 = null;
    defer if (output_owned) |owned| init.gpa.free(owned);
    if (output.len == 0) {
        const base = if (std.mem.endsWith(u8, input, ".pns"))
            input[0 .. input.len - 4]
        else if (std.mem.endsWith(u8, input, ".ps"))
            input[0 .. input.len - 3]
        else
            input;
        output_owned = try std.fmt.allocPrint(init.gpa, "{s}.wasm", .{base});
        output = output_owned.?;
    }

    // AOT идёт по тому же графу module-loader/resolver/type-checker, что и
    // нативное исполнение. Понижение MIR всё ещё поддерживает только свой
    // подмножество языка Phase-1, но обычный локальный `импорт` больше не
    // заставляет склеивать импортируемый исходник в один файл перед сборкой
    // WASM.
    var graph = panos_core.module_loader.Graph.init(init.gpa);
    defer graph.deinit();
    var global_search_roots: std.ArrayList([]const u8) = .empty;
    defer {
        for (global_search_roots.items) |root| init.gpa.free(root);
        global_search_roots.deinit(init.gpa);
    }
    if (init.environ_map.get("PANOS_STDLIB")) |stdlib_dir| {
        try global_search_roots.append(init.gpa, try init.gpa.dupe(u8, stdlib_dir));
    }
    var exe_dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (std.process.executableDirPath(init.io, &exe_dir_buffer)) |len| {
        try global_search_roots.append(init.gpa, try std.fmt.allocPrint(init.gpa, "{s}/std", .{exe_dir_buffer[0..len]}));
    } else |_| {}
    graph.global_search_roots = global_search_roots.items;
    try graph.load(&FileReader{ .io = init.io }, input);
    _ = try graph.appendPreludeModule(panos_core.prelude.SOURCE);
    if (graph.diagnostics.items.items.len != 0) {
        try writeModuleDiagnostics(stderr, &graph);
        if (hasErrors(&graph.diagnostics)) {
            try stderr.flush();
            std.process.exit(1);
        }
    }

    var compiled = try panos_core.module_compiler.compileGraphForTarget(init.gpa, &graph, .aot_js_wasm);
    defer compiled.deinit();
    try writeGraphDiagnostics(stderr, &graph, &compiled.diagnostics);
    if (compiled.hasErrors()) {
        try stderr.flush();
        std.process.exit(1);
    }
    const entry_checked = if (compiled.modules[0].checked) |*value| value else {
        try stderr.print("panos build: тайпчекер не выполнился для {s}\n", .{input});
        try stderr.flush();
        std.process.exit(1);
    };

    // `mir_lowering.zig` возвращает специфичную для AOT причину как данные,
    // а не пишет напрямую в `std.Io.Writer` вызывающей стороны. Это
    // оставляет вывод под контролем CLI и позволяет внутрипроцессным тестам
    // наблюдать сбои, не повреждая протокол Zig-тест-раннера.
    var aot_diagnostic: panos_core.mir_lowering.AotDiagnostic = .{};
    var module = panos_core.mir_lowering.lowerGraphWithDiagnostic(init.gpa, &graph, &compiled, &aot_diagnostic) catch |err| {
        if (err != error.AotUnsupported) return err;
        if (aot_diagnostic.reason) |reason| {
            if (aot_diagnostic.subject) |subject| {
                try stderr.print("panos build: AOT (wasm) не поддерживает — {s} (символ: {s})\n", .{ reason, subject });
            } else {
                try stderr.print("panos build: AOT (wasm) не поддерживает — {s}\n", .{reason});
            }
        } else {
            try stderr.print("panos build: AOT (wasm) не поддерживает используемую конструкцию\n", .{});
        }
        try stderr.flush();
        std.process.exit(1);
    };
    defer module.deinit(init.gpa);
    panos_core.wasm_objects.expand(init.gpa, &module, &entry_checked.types) catch |err| {
        try stderr.print("panos build: объекты: {t}\n", .{err});
        try stderr.flush();
        std.process.exit(1);
    };
    panos_core.wasm_strings.expand(init.gpa, &module, &entry_checked.types) catch |err| {
        try stderr.print("panos build: строки: {t}\n", .{err});
        try stderr.flush();
        std.process.exit(1);
    };
    const iface_result = panos_core.wasm_interfaces.expand(init.gpa, &module, &entry_checked.types) catch |err| {
        try stderr.print("panos build: интерфейсы: {t}\n", .{err});
        try stderr.flush();
        std.process.exit(1);
    };
    defer init.gpa.free(iface_result.table);
    var frame_info = try panos_core.mir_cps.prepare(init.gpa, &module);
    defer frame_info.deinit();
    panos_core.wasm_actors.expand(init.gpa, &module, &entry_checked.types, &frame_info) catch |err| {
        try stderr.print("panos build: акторы: {t}\n", .{err});
        try stderr.flush();
        std.process.exit(1);
    };
    // GC Phase 1 (сброс арены на каждый вызов) — последним, после того как
    // все остальные проходы уже определили финальный набор/имена функций
    // модуля.
    panos_core.wasm_gc_arena.expand(init.gpa, &module, &entry_checked.types) catch |err| {
        try stderr.print("panos build: GC-обёртка: {t}\n", .{err});
        try stderr.flush();
        std.process.exit(1);
    };

    const wasm_bytes = panos_core.wasm_emit.emitModule(init.gpa, entry_checked, &module, iface_result.table) catch |err| {
        try stderr.print("panos build: не удалось эмитировать WASM для {s}: {t}\n", .{ input, err });
        try stderr.flush();
        std.process.exit(1);
    };
    defer init.gpa.free(wasm_bytes);

    std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output, .data = wasm_bytes }) catch |err| {
        try stderr.print("panos build: не удалось записать {s}: {t}\n", .{ output, err });
        try stderr.flush();
        std.process.exit(1);
    };
    try stdout.print("panos build: записан {s}\n", .{output});
    try stdout.flush();
}

pub fn main(init: std.process.Init) !void {
    // `.initStreaming`, а НЕ `.init` по умолчанию (режим `.positional`) —
    // `.positional` пишет через `pwrite` по локальной для `Writer` позиции
    // `pos`, которая стартует с 0 и невидима для любого ДРУГОГО `Writer`
    // на том же файле. Под `panos run x.ps > log.txt 2>&1` (или любым
    // shell-редиректом, дублирующим stdout/stderr в ОДИН и тот же
    // seekable-файл) независимо отслеживаемые позиции stdout и stderr
    // обе начинаются с 0 — тот, кто флашится вторым, перезаписывает байты
    // первого по общему смещению вместо дописывания после них, незаметно
    // теряя реальный вывод программы всякий раз, когда параллельно
    // печаталось предупреждение. Потоковый режим использует обычный
    // последовательный `write()` — единственно верный выбор для
    // stdout/stderr (в отличие от файла вывода `--target=wasm` ниже,
    // которому `.positional` действительно нужен, это никогда не файлы
    // произвольного доступа в нашем эксклюзивном владении).
    var stdout_buffer: [256]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    var stderr_buffer: [256]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .initStreaming(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    // Проверка на автономный исполняемый файл (`panos build --compile`,
    // см. `zig/core/bundle.zig`) — ПЕРВЫМ делом, до любого обычного
    // разбора argv: обычный вызов `panos <file>` (без трейлера) платит
    // ровно одним маленьким positional-чтением своих последних 16 байт
    // (см. doc-комментарий `bundle.readTrailer`), всё остальное ниже без
    // изменений. У fat-бинарника НЕТ отдельного аргумента "какой файл" —
    // сам бинарник И ЕСТЬ программа, поэтому каждая реальная запись argv
    // напрямую становится `program_args`.
    var exe_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (std.process.executablePath(init.io, &exe_path_buffer)) |exe_path_len| {
        if (panos_core.bundle.readTrailer(init.io, init.gpa, exe_path_buffer[0..exe_path_len]) catch null) |bundle_bytes| {
            defer init.gpa.free(bundle_bytes);
            var fat_arguments = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
            defer fat_arguments.deinit();
            _ = fat_arguments.next(); // argv[0] — собственный путь fat-бинарника
            var fat_program_args: std.ArrayList([]const u8) = .empty;
            defer {
                for (fat_program_args.items) |argument| init.gpa.free(argument);
                fat_program_args.deinit(init.gpa);
            }
            while (fat_arguments.next()) |argument| try fat_program_args.append(init.gpa, try init.gpa.dupe(u8, argument));
            try runFatBinary(init, stdout, stderr, bundle_bytes, fat_program_args.items);
            return;
        }
    } else |_| {}

    var arguments = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer arguments.deinit();
    _ = arguments.next();
    var verbose = false;
    var profile_ffi = false;
    // REPL нет ни в одном из тулчейнов — без файла-аргумента выводится
    // понятное информационное сообщение, а не молчаливый no-op.
    var file_path = arguments.next() orelse {
        try stdout.print("Panos REPL пока не реализован\n", .{});
        try stdout.flush();
        return;
    };
    while (std.mem.eql(u8, file_path, "-v") or std.mem.eql(u8, file_path, "--verbose") or std.mem.eql(u8, file_path, "--profile-ffi")) {
        if (std.mem.eql(u8, file_path, "--profile-ffi")) {
            profile_ffi = true;
        } else {
            verbose = true;
        }
        file_path = arguments.next() orelse {
            try stderr.print("panos [-v|--verbose] [--profile-ffi] <файл.pns> [аргументы программы...]\n", .{});
            try stderr.flush();
            std.process.exit(1);
        };
    }
    if (std.mem.eql(u8, file_path, "build")) {
        try runBuild(init, stdout, stderr, &arguments);
        return;
    }

    // Всё, что осталось в командной строке после пути к скрипту — это `ос.
    // аргументы()` (`Vm.program_args` в `vm.zig`). Копируется через
    // `init.gpa`, потому что `arguments.next()` указывает во внутренний
    // буфер итератора, который инвалидируется `arguments.deinit()` ниже —
    // а эти строки должны пережить это, на весь запуск VM.
    var program_args: std.ArrayList([]const u8) = .empty;
    defer {
        for (program_args.items) |argument| init.gpa.free(argument);
        program_args.deinit(init.gpa);
    }
    while (arguments.next()) |argument| try program_args.append(init.gpa, try init.gpa.dupe(u8, argument));

    var global_search_roots: std.ArrayList([]const u8) = .empty;
    defer {
        for (global_search_roots.items) |root| init.gpa.free(root);
        global_search_roots.deinit(init.gpa);
    }
    // `$PANOS_STDLIB`, затем `std/` рядом с этим бинарником — уровни 3/4
    // документированного поиска модулей (`docs/src/getting-started/
    // installation.md` §"Поиск модулей"), уровень 2 (`модули/` рядом с
    // импортирующим файлом) относится к каждому импортёру отдельно и
    // целиком живёт в `module_loader.zig`.
    if (init.environ_map.get("PANOS_STDLIB")) |stdlib_dir| {
        try global_search_roots.append(init.gpa, try init.gpa.dupe(u8, stdlib_dir));
    }
    var exe_dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (std.process.executableDirPath(init.io, &exe_dir_buffer)) |len| {
        try global_search_roots.append(init.gpa, try std.fmt.allocPrint(init.gpa, "{s}/std", .{exe_dir_buffer[0..len]}));
    } else |_| {
        // Нет реального пути к исполняемому файлу (например, песочница
        // или встроенный контекст запуска) — тогда уровень 4 просто
        // недоступен, это не фатальная ошибка; уровни 1-3 по-прежнему
        // работают точно как задокументировано.
    }

    try runGraph(init, stdout, stderr, FileReader{ .io = init.io }, file_path, global_search_roots.items, program_args.items, verbose, profile_ffi);
}

// Общая функция для обычного файлового пути `panos <file>` выше (`reader`
// = `FileReader`, реальный диск) и пути автономного fat-бинарника ниже
// (`reader` = `bundle.BundleReader`, содержимое `.pns` в памяти) —
// `anytype`, чтобы оба варианта удовлетворяли duck-typed интерфейсу
// `reader` из `module_loader.Graph.load` без общего базового типа.
fn runGraph(
    init: std.process.Init,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    reader: anytype,
    entry_path: []const u8,
    global_search_roots: []const []const u8,
    program_args: []const []const u8,
    verbose: bool,
    profile_ffi: bool,
) !void {
    var runtime = panos_embed.Runtime.init(init.gpa, .{
        .global_search_roots = global_search_roots,
        .program_args = program_args,
        .foreign_profile_enabled = profile_ffi,
        // Одноразовый CLI-процесс — завершается сразу после этого запуска,
        // не переиспользует `runtime`/`machine` для дальнейших вызовов —
        // см. doc-комментарий `Vm.abandon_background_async_on_root_exit`.
        .abandon_background_async_on_root_exit = true,
        // Настоящий терминал/лог — печать должна быть видна ПОКА
        // программа выполняется (особенно для `http.обслуживать` и
        // другого кода, который никогда не возвращается на успехе), не
        // только одним блоком после возврата `runStart()`.
        .live_stdout = true,
    });
    defer runtime.deinit();
    try runtime.load(&reader, entry_path);
    // Настоящий модуль prelude (как и в однофайловом пайплайне
    // `runner.zig`, и в LSP) вместо захардкоженных заглушек типов
    // Опция/Результат/интерфейс в тайпчекере — `ImportContext.collect` из
    // `module_compiler.zig` прокидывает его настоящие определения во все
    // остальные модули, `preludePass` (`type_checker.zig`) пропускает свой
    // хардкод, как только это обнаруживает.
    if (runtime.graphDiagnostics().items.items.len != 0) {
        try writeModuleDiagnostics(stderr, runtime.graph());
        if (runtime.hasGraphErrors()) {
            try stderr.flush();
            std.process.exit(1);
        }
    }

    try runtime.compile();
    const compiled = runtime.compiledGraph() orelse unreachable;
    const compilation_diagnostics = runtime.compilationDiagnostics() orelse unreachable;
    try writeGraphDiagnostics(stderr, runtime.graph(), compilation_diagnostics);
    if (runtime.hasCompilationErrors()) {
        try stderr.flush();
        std.process.exit(1);
    }

    if (compiled.start == null) {
        try stderr.print("Compiler Error: не определена функция 'старт'\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }
    if (verbose) {
        const entry = &compiled.modules[0];
        const resolution = if (entry.resolution) |*value| value else unreachable;
        const checked = if (entry.checked) |*value| value else unreachable;
        try writeVerboseInfo(stdout, .{
            .declarations = runtime.graph().modules.items[0].tree.program.?.declarations.len,
            .symbols = resolution.symbols.symbols.items.len - 1,
            .types = checked.types.types.items.len - 1,
            .functions = compiled.program.functions.items.len,
        });
    }

    const execution = try runtime.runStart();
    if (profile_ffi) {
        try runtime.writeForeignProfile(stderr);
        try stderr.flush();
    }
    switch (execution) {
        .success => |runtime_value| {
            const output = try panos_core.runner.renderValue(init.gpa, runtime_value);
            defer init.gpa.free(output);
            if (verbose) try stdout.print("EXECUTION\n--------------------------\n", .{});
            // `ввод_вывод.печать`/`.строка` УЖЕ ушли в реальный stdout по
            // ходу выполнения (`live_stdout = true` выше, `Vm.ioPrint`) —
            // здесь печатается ТОЛЬКО итоговое значение, не
            // `runtime.output()` повторно (иначе — дубликат всего вывода).
            try stdout.print("{s}\n", .{output});
            try stdout.flush();
            // `stderr` буферизован (`stderr_buffer` выше) и иначе флашится
            // только на путях выхода с ошибкой — диагностика, состоящая
            // ТОЛЬКО из предупреждения (например "неиспользованная
            // переменная"), написанная `writeGraphDiagnostics` выше, без
            // этого никогда не доходит до настоящего терминала на пути
            // успеха: процесс просто нормально завершается, а у
            // буферизованного `Io.Writer` в Zig нет авто-флаша при выходе
            // по типу деструктора.
            try stderr.flush();
        },
        .runtime_error => |message| {
            // `runtime.output()` уже ушёл в реальный stdout по ходу
            // выполнения (`live_stdout = true`) — здесь повторно НЕ
            // печатается, та же причина, что у пути `.success` выше.
            try stderr.print("{s}\n", .{message});
            try stderr.flush();
            std.process.exit(1);
        },
    }
}

// Запускает автономный bundle, встроенный через `panos build --compile`
// (`zig/core/bundle.zig`). Содержимое `.pns` отдаётся прямо из памяти
// (`bundle.BundleReader`, для него вообще нет временной директории) —
// настоящая временная директория на диске создаётся, только если bundle
// несёт хотя бы одну запись `внешний`-библиотеки, поскольку `dlopen`/
// `LoadLibraryW` нужен реальный файл. Оба случая используют один и тот же
// `runGraph`, параметризованный только `reader`.
fn runFatBinary(init: std.process.Init, stdout: *std.Io.Writer, stderr: *std.Io.Writer, bundle_bytes: []const u8, program_args: []const []const u8) !void {
    var decoded = panos_core.bundle.deserialize(init.gpa, bundle_bytes) catch |err| {
        try stderr.print("panos: повреждённый встроенный bundle: {t}\n", .{err});
        try stderr.flush();
        std.process.exit(1);
    };
    defer decoded.deinit();

    // Префикс пространства имён для виртуального пути каждой записи —
    // используется для построения `entry_path` для `graph.load` ниже вне
    // зависимости от того, пишется ли под ним что-то реально на диск.
    // Только записи `внешний`-библиотек (если есть) получают здесь РЕАЛЬНЫЕ
    // байты на диске; содержимое `.pns` отдаётся `BundleReader` прямо из
    // `decoded`, вообще не касаясь этой директории.
    const now_ns = std.Io.Timestamp.now(init.io, .real).nanoseconds;
    const temp_root = try std.fmt.allocPrint(init.gpa, ".panos-fat-{d}", .{now_ns});
    defer init.gpa.free(temp_root);
    defer std.Io.Dir.cwd().deleteTree(init.io, temp_root) catch {};

    for (decoded.entries) |entry| {
        if (!entry.is_library) continue;
        const full_path = try std.fmt.allocPrint(init.gpa, "{s}/{s}", .{ temp_root, entry.path });
        defer init.gpa.free(full_path);
        if (std.fs.path.dirname(full_path)) |dir| try std.Io.Dir.cwd().createDirPath(init.io, dir);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = full_path, .data = entry.content });
    }

    const entry_path = try std.fmt.allocPrint(init.gpa, "{s}/{s}", .{ temp_root, decoded.entry_path });
    defer init.gpa.free(entry_path);

    // ОДИН синтетический корень, а не настоящий `$PANOS_STDLIB`/`std/`
    // рядом с исполняемым файлом — автономный исполняемый файл несёт ВСЮ
    // свою транзитивную зависимость (включая любые использованные модули
    // `std/`) внутри самого bundle, вообще не трогая для этого реальную
    // файловую систему (почему форма именно такая — см. doc-комментарии
    // `bundle.collect`/`bundle.bundleKey`: собственный поиск кандидатов по
    // голому имени в `module_loader.zig` пробует `{root}/{name}(.pns|.ps)`
    // для каждой записи `global_search_roots`, а `bundleKey` на этапе
    // сборки хранит ключи bundle вида ровно `"std/{name}.pns"` для всего,
    // до чего дотянулись таким путём). Подключение сюда РЕАЛЬНОГО
    // `$PANOS_STDLIB` сделало бы поведение "автономного" бинарника
    // зависящим от того, что случайно установлено на машине, где он
    // запускается — именно то, чего эта функциональность избегает.
    const synthetic_root = try std.fmt.allocPrint(init.gpa, "{s}/std", .{temp_root});
    defer init.gpa.free(synthetic_root);
    const global_search_roots = [_][]const u8{synthetic_root};

    try runGraph(init, stdout, stderr, panos_core.bundle.BundleReader{ .bundle = &decoded, .temp_root = temp_root }, entry_path, &global_search_roots, program_args, false, false);
}

test "CLI imports the migration core" {
    try std.testing.expectEqualStrings("phase-0", panos_core.migration_stage);
}

test "CLI runs exported start through the Zig pipeline" {
    var result = try runSource(std.testing.allocator, "пример.ps", "функ сложить(a: Число, b: Число) -> Число\na + b\nконец\nэкспорт функ старт() -> Число\nсложить(2.0, 3.0)\nконец");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("5", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "CLI records stable verbose pipeline summaries" {
    var result = try runSourceWithVerbose(std.testing.allocator, "пример.ps", "функ старт() -> Число\n42.0\nконец", true);
    defer result.deinit();

    const info = result.verbose orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), info.declarations);
    try std.testing.expect(info.symbols != null);
    try std.testing.expect(info.types != null);
    // The embedded prelude module now shares the same bytecode.Program (see
    // module_compiler.compileGraph), so this count includes its real
    // compiled functions (Опция/Результат methods etc) alongside the user's
    // own — no longer just the one function this program itself declares.
    try std.testing.expect((info.functions orelse 0) > 1);
}

test "CLI returns frontend diagnostics without executing" {
    var result = try runSource(std.testing.allocator, "ошибка.ps", "функ старт() -> Число\nнеизвестно\nконец");
    defer result.deinit();
    try std.testing.expect(result.hasErrors());
    try std.testing.expect(result.execution == null);
}

test "CLI formats errors with the documented source location" {
    const file = panos_core.source.SourceFile.init(4, "пример.ps", "пер x\n$");
    const rendered = try formatDiagnostic(std.testing.allocator, file, .{
        .phase = .parser,
        .severity = .err,
        .span = .{ .file_id = 4, .start = 9, .end = 10 },
        .message = "Синтаксическая ошибка: неожиданный токен",
    });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "пример.ps:2:1: Синтаксическая ошибка: неожиданный токен",
        rendered,
    );
}

test "CLI marks warnings without changing their Russian message" {
    const file = panos_core.source.SourceFile.init(0, "main.ps", "x");
    const rendered = try formatDiagnostic(std.testing.allocator, file, .{
        .phase = .type_checker,
        .severity = .warning,
        .span = .{ .file_id = 0, .start = 0, .end = 1 },
        .message = "неиспользуемая переменная 'x'",
    });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("main.ps:1:1: warning: неиспользуемая переменная 'x'", rendered);
}

test "CLI formats module-loader diagnostics at their source file" {
    var graph = panos_core.module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const bytes = try std.testing.allocator.dupe(u8, "x");
    try graph.modules.append(std.testing.allocator, .{
        .file = panos_core.source.SourceFile.init(0, "модуль.ps", bytes),
        .tree = panos_core.ast.Ast.init(std.testing.allocator),
    });
    const message = try graph.arena.allocator().dupe(u8, "Module Loader Error: пример");
    _ = try graph.diagnostics.appendUnique(std.testing.allocator, .{
        .phase = .parser,
        .severity = .err,
        .span = .{ .file_id = 0, .start = 0, .end = 0 },
        .message = message,
    });
    try std.testing.expect(hasErrors(&graph.diagnostics));
    const module = graph.moduleForFile(0).?;
    const rendered = try formatDiagnostic(std.testing.allocator, module.file, graph.diagnostics.items.items[0]);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("модуль.ps:1:1: Module Loader Error: пример", rendered);
}

test "CLI rejects diagnostics outside their source file" {
    const file = panos_core.source.SourceFile.init(0, "main.ps", "x");
    try std.testing.expectError(error.FileMismatch, formatDiagnostic(std.testing.allocator, file, .{
        .phase = .lexer,
        .severity = .err,
        .span = .{ .file_id = 1, .start = 0, .end = 1 },
        .message = "Лексическая ошибка",
    }));
    try std.testing.expectError(error.InvalidSpan, formatDiagnostic(std.testing.allocator, file, .{
        .phase = .lexer,
        .severity = .err,
        .span = .{ .file_id = 0, .start = 0, .end = 2 },
        .message = "Лексическая ошибка",
    }));
}
