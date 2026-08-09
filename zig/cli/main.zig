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

    while (arguments.next()) |arg| {
        if (std.mem.eql(u8, arg, "--target")) {
            target = arguments.next() orelse "";
        } else if (std.mem.startsWith(u8, arg, "--target=")) {
            target = arg["--target=".len..];
        } else if (std.mem.eql(u8, arg, "-o")) {
            output = arguments.next() orelse "";
        } else {
            input = arg;
        }
    }

    if (!std.mem.eql(u8, target, "wasm")) {
        try stderr.print("panos build: поддерживается только --target=wasm (получено: \"{s}\")\n", .{target});
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
        const base = if (std.mem.endsWith(u8, input, ".ps")) input[0 .. input.len - 3] else input;
        output_owned = try std.fmt.allocPrint(init.gpa, "{s}.wasm", .{base});
        output = output_owned.?;
    }

    const reader = FileReader{ .io = init.io };
    const bytes = reader.read(init.gpa, input) catch |err| {
        try stderr.print("panos build: не удалось прочитать {s}: {t}\n", .{ input, err });
        try stderr.flush();
        std.process.exit(1);
    };
    defer init.gpa.free(bytes);

    var analysis = try panos_core.runner.analyzeSource(init.gpa, input, bytes);
    defer analysis.deinit();
    if (analysis.diagnostics.items.items.len != 0) {
        try writeAnalysisDiagnostics(stderr, &analysis);
        if (analysis.hasErrors()) {
            try stderr.flush();
            std.process.exit(1);
        }
    }

    const tree = analysis.tree() orelse {
        try stderr.print("panos build: не удалось разобрать {s}\n", .{input});
        try stderr.flush();
        std.process.exit(1);
    };
    const resolution = analysis.resolution() orelse {
        try stderr.print("panos build: резолвер не выполнился для {s}\n", .{input});
        try stderr.flush();
        std.process.exit(1);
    };
    const checked = analysis.checkedResult() orelse {
        try stderr.print("panos build: тайпчекер не выполнился для {s}\n", .{input});
        try stderr.flush();
        std.process.exit(1);
    };

    // `mir_lowering.zig`'s `unsupported()` is an uncatchable `@panic` for
    // anything outside the Phase-1a subset (see that file's own scope
    // note) — a source file using ADTs/closures/interfaces/`для`/methods/
    // etc. will crash the build with that message rather than fail
    // gracefully. Documented current limitation, not something this
    // command works around.
    var module = try panos_core.mir_lowering.lowerModule(init.gpa, tree, resolution, checked);
    defer module.deinit(init.gpa);

    const wasm_bytes = panos_core.wasm_emit.emitModule(init.gpa, checked, &module) catch |err| {
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
    var stdout_buffer: [256]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    var stderr_buffer: [256]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    var arguments = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer arguments.deinit();
    _ = arguments.next();
    var verbose = false;
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
    if (std.mem.eql(u8, file_path, "-v") or std.mem.eql(u8, file_path, "--verbose")) {
        verbose = true;
        file_path = arguments.next() orelse {
            try stderr.print("panos [-v|--verbose] [file.ps] [program arguments...]\n", .{});
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

    var graph = panos_core.module_loader.Graph.init(init.gpa);
    defer graph.deinit();
    try graph.load(&FileReader{ .io = init.io }, file_path);
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
    machine.program_args = program_args.items;
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |runtime_value| {
            const output = try panos_core.runner.renderValue(init.gpa, runtime_value);
            defer init.gpa.free(output);
            if (verbose) try stdout.print("EXECUTION\n--------------------------\n", .{});
            try stdout.print("{s}\n", .{output});
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
            try stderr.print("{s}\n", .{message});
            try stderr.flush();
            std.process.exit(1);
        },
    }
}

test "CLI imports the migration core" {
    try std.testing.expectEqualStrings("phase-0", panos_core.migration_stage);
}

test "CLI runs exported start through the Zig pipeline" {
    var result = try runSource(std.testing.allocator, "пример.ps", "функ сложить(a: Число, b: Число) -> Число\na + b\nконец\nэкспорт функ старт() -> Число\nсложить(2, 3)\nконец");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("5", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "CLI records stable verbose pipeline summaries" {
    var result = try runSourceWithVerbose(std.testing.allocator, "пример.ps", "функ старт() -> Число\n42\nконец", true);
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
