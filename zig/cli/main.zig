const std = @import("std");
const panos_core = @import("panos_core");

pub const DiagnosticFormatError = error{
    FileMismatch,
    InvalidSpan,
};

pub const Execution = panos_core.runner.Execution;
pub const VerboseInfo = panos_core.runner.VerboseInfo;
pub const SourceRun = panos_core.runner.SourceRun;

pub fn formatDiagnostic(
    allocator: std.mem.Allocator,
    file: panos_core.source.SourceFile,
    value: panos_core.diagnostic.Diagnostic,
) (DiagnosticFormatError || std.mem.Allocator.Error)![]u8 {
    if (value.span.file_id != file.id) return error.FileMismatch;
    if (!value.span.isValidFor(file)) return error.InvalidSpan;

    const position = file.lineColumn(value.span.start);
    const warning_prefix: []const u8 = switch (value.severity) {
        .err => "",
        .warning => "warning: ",
    };
    return std.fmt.allocPrint(
        allocator,
        "{s}:{d}:{d}: {s}{s}",
        .{ file.path, position.line, position.column, warning_prefix, value.message },
    );
}

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

fn writeGraphDiagnostics(
    writer: *std.Io.Writer,
    graph: *const panos_core.module_loader.Graph,
    diagnostics: *const panos_core.diagnostic.DiagnosticList,
) !void {
    for (diagnostics.items.items) |value| {
        const module = graph.moduleForFile(value.span.file_id) orelse {
            try writer.print("{s}\n", .{value.message});
            continue;
        };
        const rendered = try formatDiagnostic(std.heap.page_allocator, module.file, value);
        defer std.heap.page_allocator.free(rendered);
        try writer.print("{s}\n", .{rendered});
    }
}

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
    // `analysis.graph` is null only when `reportUnsupportedImports` rejects
    // the source before a graph is ever built (`runner.zig`) — there's no
    // module/file to resolve a span against in that case, so fall back to
    // the bare message (same fallback `writeGraphDiagnostics` itself
    // already uses when a specific file lookup fails).
    if (analysis.graph) |*graph| {
        try writeGraphDiagnostics(writer, graph, &analysis.diagnostics);
    } else {
        for (analysis.diagnostics.items.items) |item| try writer.print("{s}\n", .{item.message});
    }
}

// `panos build --compile <файл.pns> [-o выход]` — Bun-style standalone
// executable. See `zig/core/bundle.zig`'s module doc comment for the full
// design (embeds SOURCE, not compiled bytecode — recompiles at every
// startup of the produced binary). This command runs the ordinary
// `module_loader.Graph.load` exactly like a normal `panos <file>` run
// (real `$PANOS_STDLIB`/exe-relative `std/` search — at BUILD time we
// genuinely want the real stdlib, so `bundle.collect` can capture
// whichever modules the program actually used), then hands the resulting
// graph to `bundle.collect` to walk it into an embeddable bundle.
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
    // Executable bit — the source binary this was copied from already has
    // it, but `writeFile`/`createFile` above start a NEW file at the
    // default (non-executable) mode, not inherited from anywhere.
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

// `panos build --target=wasm <файл.ps> [-o выход.wasm]` — T048. Deliberately
// single-file only: `mir_lowering.zig` lowers exactly ONE `ast.Ast` (see its
// own scope note), and `runner.analyzeSource`'s single-file entry point
// already rejects `импорт` up front — the two constraints line up, this
// isn't an artificial narrowing added just for this command. Unlike Odin's
// `run_build` (`main.odin`, full multi-file module graph via
// `lower_program_graph`), there is no cross-module wasm build support yet;
// that would need `mir_lowering.zig` to grow module-graph awareness first.
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

    // AOT now follows the same module-loader/resolver/type-checker graph as
    // native execution. MIR lowering still supports only its Phase-1
    // language subset, but a plain local `импорт` no longer forces callers
    // to paste the imported source into one file before building WASM.
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

    // `mir_lowering.zig` deliberately rejects language features outside
    // the current AOT runtime (ADTs, closures, actors, async I/O, ...) —
    // it already printed the SPECIFIC reason to stderr before returning
    // `error.AotUnsupported`; this catch only needs to turn that into a
    // clean exit instead of an unhandled-error trace.
    var module = panos_core.mir_lowering.lowerGraph(init.gpa, &graph, &compiled) catch |err| {
        if (err != error.AotUnsupported) return err;
        try stderr.flush();
        std.process.exit(1);
    };
    defer module.deinit(init.gpa);
    try panos_core.mir_cps.prepare(&module);

    const wasm_bytes = panos_core.wasm_emit.emitModule(init.gpa, entry_checked, &module) catch |err| {
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
    // `.initStreaming`, NOT the default `.init` (`.positional` mode) —
    // `.positional` writes via `pwrite` at a `Writer`-local `pos` that
    // starts at 0 and is invisible to any OTHER `Writer` on the same
    // underlying file. Under `panos run x.ps > log.txt 2>&1` (or any
    // shell redirect that dups stdout/stderr to the SAME seekable file),
    // stdout's and stderr's independently-tracked positions both start at
    // 0 — whichever one flushes second overwrites the other's bytes at
    // that shared offset instead of appending after them, silently
    // dropping real program output whenever a warning diagnostic was also
    // printed. Found by running a program with an unused-variable warning
    // through `2>&1`: the warning survived, the actual return value never
    // appeared. Streaming mode uses a plain sequential `write()`, the
    // only correct choice for stdout/stderr (never actually random-access
    // files we own exclusively, unlike `--target=wasm`'s output file
    // below, which legitimately wants `.positional`).
    var stdout_buffer: [256]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    var stderr_buffer: [256]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .initStreaming(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    // Standalone-executable check (`panos build --compile`, see `zig/core/
    // bundle.zig`) — FIRST thing, before any normal argv parsing: an
    // ordinary `panos <file>` invocation (no trailer) pays for exactly one
    // small positional read of its own last 16 bytes (`bundle.readTrailer`'s
    // own doc comment), everything else below is unchanged. A fat binary
    // has NO separate "which file" argument — the binary itself IS the
    // program, so every real argv entry becomes `program_args` directly.
    var exe_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (std.process.executablePath(init.io, &exe_path_buffer)) |exe_path_len| {
        if (panos_core.bundle.readTrailer(init.io, init.gpa, exe_path_buffer[0..exe_path_len]) catch null) |bundle_bytes| {
            defer init.gpa.free(bundle_bytes);
            var fat_arguments = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
            defer fat_arguments.deinit();
            _ = fat_arguments.next(); // argv[0] — the fat binary's own path
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
    // `contracts/cli.md` says "with no file.ps, panos starts the existing
    // REPL mode" — but Odin's own `repl()` (`main.odin:205-207`) is an
    // empty stub, no output, exit 0. No REPL exists on either toolchain —
    // Odin is being deleted, not a compatibility target, so this stays a
    // clear, informative message rather than silently matching Odin's
    // no-op.
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

    // Everything left on the command line after the script path — `ос.
    // аргументы()` (`vm.zig`'s `Vm.program_args`), symmetric to Odin's
    // `run_file(filename, program_args, ...)` (`main.odin`). Duped with
    // `init.gpa` because `arguments.next()` points into the iterator's own
    // buffer, which `arguments.deinit()` below invalidates — but these
    // strings need to outlive that, through the whole VM run.
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
    // `$PANOS_STDLIB`, then `std/` next to this binary — tiers 3/4 of the
    // documented module search (`docs/src/getting-started/installation.md`
    // §"Поиск модулей"), tier 2 (`модули/` next to the importer) is
    // per-importer and lives entirely in `module_loader.zig` itself.
    if (init.environ_map.get("PANOS_STDLIB")) |stdlib_dir| {
        try global_search_roots.append(init.gpa, try init.gpa.dupe(u8, stdlib_dir));
    }
    var exe_dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (std.process.executableDirPath(init.io, &exe_dir_buffer)) |len| {
        try global_search_roots.append(init.gpa, try std.fmt.allocPrint(init.gpa, "{s}/std", .{exe_dir_buffer[0..len]}));
    } else |_| {
        // No real executable path (e.g. some sandboxed/embedded launch
        // context) — tier 4 is simply unavailable then, not a fatal error;
        // tiers 1-3 still work exactly as documented.
    }

    try runGraph(init, stdout, stderr, FileReader{ .io = init.io }, file_path, global_search_roots.items, program_args.items, verbose, profile_ffi);
}

// Shared by the normal file-based `panos <file>` path above (`reader` =
// `FileReader`, real disk) and the standalone-executable fat-binary path
// below (`reader` = `bundle.BundleReader`, in-memory `.pns` content) —
// `anytype` so both satisfy `module_loader.Graph.load`'s duck-typed
// `reader` interface without a shared base type. Identical to the
// previous inline body of `main()` from `graph.load` through the final
// `switch (execution)` — no behavioral change for the existing file-based
// path, purely an extraction so the fat-binary path can reuse it exactly.
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
    var graph = panos_core.module_loader.Graph.init(init.gpa);
    defer graph.deinit();
    graph.global_search_roots = global_search_roots;
    try graph.load(&reader, entry_path);
    // Real prelude module (same as runner.zig's single-file pipeline and
    // the LSP already do) instead of the type-checker's hardcoded
    // Опция/Результат/interface stand-ins — `module_compiler.zig`'s
    // `ImportContext.collect` bridges its real definitions into every
    // other module, `preludePass` (`type_checker.zig`) skips its own
    // hardcode once it detects this.
    _ = try graph.appendPreludeModule(panos_core.prelude.SOURCE);
    if (graph.diagnostics.items.items.len != 0) {
        try writeModuleDiagnostics(stderr, &graph);
        if (hasErrors(&graph.diagnostics)) {
            try stderr.flush();
            std.process.exit(1);
        }
    }

    var compiled = try panos_core.module_compiler.compileGraph(init.gpa, &graph);
    defer compiled.deinit();
    try writeGraphDiagnostics(stderr, &graph, &compiled.diagnostics);
    if (compiled.hasErrors()) {
        try stderr.flush();
        std.process.exit(1);
    }

    const start = compiled.start orelse {
        try stderr.print("Compiler Error: не определена функция 'старт'\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };
    if (verbose) {
        const entry = &compiled.modules[0];
        const resolution = if (entry.resolution) |*value| value else unreachable;
        const checked = if (entry.checked) |*value| value else unreachable;
        try writeVerboseInfo(stdout, .{
            .declarations = graph.modules.items[0].tree.program.?.declarations.len,
            .symbols = resolution.symbols.symbols.items.len - 1,
            .types = checked.types.types.items.len - 1,
            .functions = compiled.program.functions.items.len,
        });
    }

    var machine = panos_core.vm.Vm.init(init.gpa, &compiled.program);
    machine.program_args = program_args;
    machine.foreign_profile_enabled = profile_ffi;
    defer machine.deinit();
    const execution = try machine.run(start, &.{});
    if (profile_ffi) {
        try machine.writeForeignProfile(stderr);
        try stderr.flush();
    }
    switch (execution) {
        .success => |runtime_value| {
            const output = try panos_core.runner.renderValue(init.gpa, runtime_value);
            defer init.gpa.free(output);
            if (verbose) try stdout.print("EXECUTION\n--------------------------\n", .{});
            // `machine.output` — accumulated `ввод_вывод.печать`/`.строка`
            // calls made DURING execution — printed first, same order a
            // real stdout write during the program's own run would have
            // appeared in.
            try stdout.print("{s}{s}\n", .{ machine.output.items, output });
            try stdout.flush();
            // `stderr` is buffered (`stderr_buffer` above) and otherwise
            // only ever flushed on the error-exit paths — a WARNING-only
            // diagnostic (e.g. "неиспользованная переменная") written by
            // `writeGraphDiagnostics` above never reaches the real
            // terminal on the success path without this: the process
            // just returns normally, and Zig's buffered `Io.Writer` has
            // no destructor-style auto-flush on exit. Found by actually
            // running the built binary, not by reading the code — a unit
            // test calling `compileGraph` directly (bypassing `main`
            // entirely) saw the diagnostic just fine, which is why this
            // stayed hidden.
            try stderr.flush();
        },
        .runtime_error => |message| {
            if (machine.output.items.len != 0) {
                try stdout.print("{s}", .{machine.output.items});
                try stdout.flush();
            }
            try stderr.print("{s}\n", .{message});
            try stderr.flush();
            std.process.exit(1);
        },
    }
}

// Runs a standalone-executable bundle embedded via `panos build --compile`
// (`zig/core/bundle.zig`). `.pns` content is served straight from memory
// (`bundle.BundleReader`, no temp directory at all for it) — a real temp
// directory is only created on disk if the bundle carries at least one
// `внешний`-library entry, since `dlopen`/`LoadLibraryW` need a real file.
// Both cases share `runGraph` unchanged, parameterized only by `reader`.
fn runFatBinary(init: std.process.Init, stdout: *std.Io.Writer, stderr: *std.Io.Writer, bundle_bytes: []const u8, program_args: []const []const u8) !void {
    var decoded = panos_core.bundle.deserialize(init.gpa, bundle_bytes) catch |err| {
        try stderr.print("panos: повреждённый встроенный bundle: {t}\n", .{err});
        try stderr.flush();
        std.process.exit(1);
    };
    defer decoded.deinit();

    // A namespace prefix for every entry's virtual path — used to build
    // `entry_path` for `graph.load` below regardless of whether anything
    // is ever actually written to disk under it. Only `внешний`-library
    // entries (if any) get REAL bytes written here; `.pns` content is
    // served by `BundleReader` straight from `decoded`, never touching
    // this directory at all.
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

    // A SINGLE synthetic root, not the real `$PANOS_STDLIB`/exe-relative
    // `std/` — a standalone executable carries its ENTIRE dependency
    // closure (including any `std/` modules it used) inside the bundle
    // itself, never touching the real filesystem for it (see `bundle.
    // collect`'s/`bundle.bundleKey`'s doc comments for why this exact
    // shape — `module_loader.zig`'s own bare-name candidate search tries
    // `{root}/{name}(.pns|.ps)` for each `global_search_roots` entry, and
    // `bundleKey` stores exactly matching `"std/{name}.pns"` bundle keys
    // for anything reached this way at build time). Pulling in the REAL
    // `$PANOS_STDLIB` here would make a "standalone" binary's behavior
    // depend on what happens to be installed on the machine running it —
    // exactly what this feature exists to avoid.
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
