const std = @import("std");
const panos = @import("panos_core");
const manifest = @import("manifest.zig");
const outcome = @import("outcome.zig");

// Прогоняет каждый случай из `tests/conformance/manifest.json` и сверяет
// результат ТОЧНО с тем, что там записано в качестве ожидаемого. Значения
// `expected` в манифесте — это утверждённый эталон, а не то, что можно
// пересчитать заново: это единственный автоматический контроль регрессий.
//
// Разбито на отдельные точки входа по TIER (`runTier`/`runAot` ниже, каждая
// вызывается из СВОЕГО маленького `test`-файла/build-артефакта — см.
// `build.zig`), а не один `test`-блок, перебирающий весь манифест
// последовательно: граф сборки Zig распараллеливает только отдельные шаги
// `addTest`/`Run`, но не `test`-декларации внутри одного бинарника, а
// уровень "runtime" отдельно включает фикстуры `tests/conformance/
// benchmarks/*.ps` (рекурсия `фиб(30)`, цикл на 5 млн итераций, 20 тыс.
// конкатенаций строк) — по-настоящему медленные в байткод-VM в Debug-сборке,
// поэтому вынесены из повседневного цикла `zig build test` (см. `test_step`
// в `build.zig` — он не зависит ни от одного из уровней здесь).

pub fn computeOutcome(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !outcome.Outcome {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(source);

    var result = try panos.runner.runSource(allocator, path, source);
    defer result.deinit();

    if (result.hasErrors()) {
        var diagnostics: std.ArrayList(outcome.NormalizedDiagnostic) = .empty;
        for (result.diagnostics.items.items) |value| {
            try diagnostics.append(allocator, .{
                .phase = value.phase,
                .severity = value.severity,
                .path = try allocator.dupe(u8, path),
                .start_byte = value.span.start,
                .end_byte = value.span.end,
                .message = try allocator.dupe(u8, value.message),
            });
        }
        return .{
            .status = .diagnostic,
            .exit_code = 1,
            .stdout = "",
            .diagnostics = try diagnostics.toOwnedSlice(allocator),
        };
    }

    return switch (result.execution orelse return error.NoExecution) {
        .success => |value| .{
            .status = .success,
            .exit_code = 0,
            .stdout = try allocator.dupe(u8, value),
            .result = try allocator.dupe(u8, value),
        },
        .runtime_error => |message| .{
            .status = .runtime_error,
            .exit_code = 1,
            .stdout = "",
            .result = try allocator.dupe(u8, message),
        },
    };
}

fn freeOutcome(allocator: std.mem.Allocator, value: outcome.Outcome) void {
    if (value.stdout.len != 0) allocator.free(value.stdout);
    if (value.result) |result| allocator.free(result);
    for (value.diagnostics) |diagnostic_value| {
        allocator.free(diagnostic_value.path);
        allocator.free(diagnostic_value.message);
    }
    if (value.diagnostics.len != 0) allocator.free(value.diagnostics);
}

// Прогоняет каждый случай манифеста с `tier`, равным `tier_name` (один из
// "semantic"/"runtime"/"native" — у `aot` совсем другой путь выполнения, см.
// `runAot` ниже) через `runner.runSource` (обычный конвейер байткод-VM) и
// сверяет результат с записанным в манифесте ожиданием.
pub fn runTier(allocator: std.mem.Allocator, tier_name: []const u8) !void {
    var io = std.Io.Threaded.init(allocator, .{});
    defer io.deinit();

    const manifest_text = try std.Io.Dir.cwd().readFileAlloc(io.io(), "tests/conformance/manifest.json", allocator, .limited(1024 * 1024));
    defer allocator.free(manifest_text);

    var parsed = try manifest.parse(allocator, manifest_text);
    defer parsed.deinit();

    for (parsed.value.cases) |case| {
        if (!std.mem.eql(u8, case.tier, tier_name)) continue;

        const actual = try computeOutcome(allocator, io.io(), case.input);
        defer freeOutcome(allocator, actual);

        const mismatch = outcome.firstMismatch(case.expected, actual);
        if (mismatch != null) {
            std.debug.print("conformance case '{s}' mismatch: {t}\n", .{ case.id, mismatch.? });
            if (actual.diagnostics.len != 0) {
                std.debug.print("  actual diagnostic: {s}\n", .{actual.diagnostics[0].message});
            }
            if (actual.result) |result_value| std.debug.print("  actual result: {s}\n", .{result_value});
        }
        try std.testing.expectEqual(@as(?outcome.Mismatch, null), mismatch);
    }
}

// `computeOutcome`/`runSource` выше отвергают `импорт` целиком (см.
// `reportUnsupportedImports` в `runner.zig`) — любой фикстуре, которая
// реально многофайловая (интерфейсы/дженерики/квалифицированные имена/spawn
// между файлами и просто многофайловые программы), нужен НАСТОЯЩИЙ
// многофайловый конвейер: `module_loader.Graph` + `module_compiler.
// compileGraph`, тот же, что использует `cli/main.zig` при реальном запуске
// `panos`. `FileReader` — дословная копия приватной структуры из
// `cli/main.zig` (она не экспортируется из `panos_core`).
const FileReader = struct {
    io: std.Io,

    pub fn read(self: *const FileReader, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(16 * 1024 * 1024));
    }
};

pub fn computeOutcomeGraph(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !outcome.Outcome {
    var graph = panos.module_loader.Graph.init(allocator);
    defer graph.deinit();
    // Корень поиска stdlib, относительно корня репозитория (cwd `zig build
    // test`) — фикстуре с `импорт` модулей вида `математика`/`слог`/
    // `супервизор` нужно настоящее дерево `std/`, а не только резолюция
    // `модули/`-рядом-с-импортёром.
    graph.global_search_roots = &.{"std"};
    // `path` в манифесте — реальный путь к `.pns`/`.ps`-файлу (С
    // расширением) — `Graph.load` принимает его как есть (входной путь
    // сначала пробуется буквально, до поиска с подбором расширения,
    // применяемого для целей `импорт`).
    try graph.load(&FileReader{ .io = io }, path);
    _ = try graph.appendPreludeModule(panos.prelude.SOURCE);

    var has_load_error = false;
    for (graph.diagnostics.items.items) |value| {
        if (value.severity == .err) has_load_error = true;
    }
    if (has_load_error) {
        var diagnostics: std.ArrayList(outcome.NormalizedDiagnostic) = .empty;
        for (graph.diagnostics.items.items) |value| {
            const module = graph.moduleForFile(value.span.file_id) orelse continue;
            try diagnostics.append(allocator, .{
                .phase = value.phase,
                .severity = value.severity,
                .path = try allocator.dupe(u8, module.file.path),
                .start_byte = value.span.start,
                .end_byte = value.span.end,
                .message = try allocator.dupe(u8, value.message),
            });
        }
        return .{ .status = .diagnostic, .exit_code = 1, .stdout = "", .diagnostics = try diagnostics.toOwnedSlice(allocator) };
    }

    var compiled = try panos.module_compiler.compileGraph(allocator, &graph);
    defer compiled.deinit();

    if (compiled.hasErrors()) {
        var diagnostics: std.ArrayList(outcome.NormalizedDiagnostic) = .empty;
        for (compiled.diagnostics.items.items) |value| {
            const module = graph.moduleForFile(value.span.file_id) orelse continue;
            try diagnostics.append(allocator, .{
                .phase = value.phase,
                .severity = value.severity,
                .path = try allocator.dupe(u8, module.file.path),
                .start_byte = value.span.start,
                .end_byte = value.span.end,
                .message = try allocator.dupe(u8, value.message),
            });
        }
        return .{ .status = .diagnostic, .exit_code = 1, .stdout = "", .diagnostics = try diagnostics.toOwnedSlice(allocator) };
    }

    const start = compiled.start orelse return error.NoExecution;
    var machine = panos.vm.Vm.init(allocator, &compiled.program);
    defer machine.deinit();
    return switch (try machine.run(start, &.{})) {
        .success => |runtime_value| blk: {
            const rendered = try panos.runner.renderValue(allocator, runtime_value);
            defer allocator.free(rendered);
            const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ machine.output.items, rendered });
            break :blk .{ .status = .success, .exit_code = 0, .stdout = try allocator.dupe(u8, combined), .result = combined };
        },
        .runtime_error => |message| blk: {
            const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ machine.output.items, message });
            break :blk .{ .status = .runtime_error, .exit_code = 1, .stdout = "", .result = combined };
        },
    };
}

// Та же форма сопоставления случаев/проверок, что и `runTier`, но с вызовом
// `computeOutcomeGraph` — под ОТДЕЛЬНЫМ именем уровня (`"graph"`, никогда
// `"native"`), чтобы не затрагивать однофайловые случаи других уровней.
pub fn runTierGraph(allocator: std.mem.Allocator, tier_name: []const u8) !void {
    var io = std.Io.Threaded.init(allocator, .{});
    defer io.deinit();

    const manifest_text = try std.Io.Dir.cwd().readFileAlloc(io.io(), "tests/conformance/manifest.json", allocator, .limited(1024 * 1024));
    defer allocator.free(manifest_text);

    var parsed = try manifest.parse(allocator, manifest_text);
    defer parsed.deinit();

    for (parsed.value.cases) |case| {
        if (!std.mem.eql(u8, case.tier, tier_name)) continue;

        const actual = try computeOutcomeGraph(allocator, io.io(), case.input);
        defer freeOutcome(allocator, actual);

        const mismatch = outcome.firstMismatch(case.expected, actual);
        if (mismatch != null) {
            std.debug.print("conformance case '{s}' mismatch: {t}\n", .{ case.id, mismatch.? });
            if (actual.diagnostics.len != 0) {
                std.debug.print("  actual diagnostic: {s}\n", .{actual.diagnostics[0].message});
            }
            if (actual.result) |result_value| std.debug.print("  actual result: {s}\n", .{result_value});
        }
        try std.testing.expectEqual(@as(?outcome.Mismatch, null), mismatch);
    }
}

fn computeAotOutcome(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !outcome.Outcome {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(source);

    var lexed = try panos.lexer.tokenize(allocator, source, 0);
    defer lexed.deinit();
    var parsed = try panos.parser.parse(allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try panos.resolver.resolve(allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try panos.type_checker.check(allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    var module = try panos.mir_lowering.lowerModule(allocator, &parsed.ast, &resolved, &checked);
    defer module.deinit(allocator);
    // Тот же конвейер расширений и в том же порядке, что и реальный `panos
    // build --target=wasm` в `cli/main.zig` — `.call_value` всегда зависит
    // от того, что `wasm_interfaces.expand` уже переписал `.function_ref` в
    // настоящий индекс таблицы WASM (см. doc-комментарий `wasm_interfaces.
    // zig`), так что даже обычный рекурсивный вызов функции требует этого
    // шага.
    try panos.wasm_objects.expand(allocator, &module, &checked.types);
    try panos.wasm_strings.expand(allocator, &module, &checked.types);
    try panos.wasm_maps.expand(allocator, &module, &checked.types);
    const iface_result = try panos.wasm_interfaces.expand(allocator, &module, &checked.types);
    defer allocator.free(iface_result.table);
    var frame_info = try panos.mir_cps.prepare(allocator, &module);
    defer frame_info.deinit();
    try panos.wasm_actors.expand(allocator, &module, &checked.types, &frame_info);
    const wasm_bytes = try panos.wasm_emit.emitModule(allocator, &checked, &module, iface_result.table);
    defer allocator.free(wasm_bytes);

    const wasm_path = "zzz_matrix_aot_test.wasm";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = wasm_path, .data = wasm_bytes });
    defer std.Io.Dir.cwd().deleteFile(io, wasm_path) catch {};

    // `.environ = std.testing.environ` обязателен — собственное значение по
    // умолчанию у `Io.Threaded` ПУСТОЕ, из-за чего поиск `$PATH` в
    // `expand_arg0` молча не находит ничего.
    var wasmtime_io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer wasmtime_io.deinit();
    const result = try std.process.run(allocator, wasmtime_io.io(), .{
        .argv = &.{ "wasmtime", "run", "--invoke", "старт", wasm_path },
        .expand_arg0 = .expand,
    });
    defer allocator.free(result.stderr);

    const exit_code: i32 = switch (result.term) {
        .exited => |code| code,
        else => 1,
    };
    return .{
        .status = if (exit_code == 0) .success else .runtime_error,
        .exit_code = exit_code,
        .stdout = result.stdout,
        .result = std.mem.trim(u8, result.stdout, " \n\r\t"),
    };
}

pub fn runAot(allocator: std.mem.Allocator) !void {
    var io = std.Io.Threaded.init(allocator, .{});
    defer io.deinit();

    const manifest_text = try std.Io.Dir.cwd().readFileAlloc(io.io(), "tests/conformance/manifest.json", allocator, .limited(1024 * 1024));
    defer allocator.free(manifest_text);

    var parsed = try manifest.parse(allocator, manifest_text);
    defer parsed.deinit();

    for (parsed.value.cases) |case| {
        if (!std.mem.eql(u8, case.tier, "aot")) continue;

        const actual = computeAotOutcome(allocator, io.io(), case.input) catch |err| {
            if (err == error.FileNotFound) return error.SkipZigTest;
            return err;
        };
        defer allocator.free(actual.stdout);

        const mismatch = outcome.firstMismatch(case.expected, actual);
        if (mismatch != null) {
            std.debug.print("conformance case '{s}' mismatch: {t}\n", .{ case.id, mismatch.? });
            std.debug.print("  actual stdout: {s}\n", .{actual.stdout});
        }
        try std.testing.expectEqual(@as(?outcome.Mismatch, null), mismatch);
    }
}
