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

fn writeModuleDiagnostics(writer: *std.Io.Writer, graph: *const panos_core.module_loader.Graph) !void {
    for (graph.diagnostics.items.items) |value| {
        const module = graph.moduleForFile(value.span.file_id) orelse {
            try writer.print("{s}\n", .{value.message});
            continue;
        };
        const rendered = try formatDiagnostic(std.heap.page_allocator, module.file, value);
        defer std.heap.page_allocator.free(rendered);
        try writer.print("{s}\n", .{rendered});
    }
}

fn hasErrors(diagnostics: *const panos_core.diagnostic.DiagnosticList) bool {
    for (diagnostics.items.items) |value| {
        if (value.severity == .err) return true;
    }
    return false;
}

fn reportUnsupportedModuleExecution(graph: *panos_core.module_loader.Graph) !void {
    if (graph.imports.items.len == 0) return;
    const import = graph.imports.items[0];
    _ = try graph.diagnostics.appendUnique(graph.allocator, .{
        .phase = .compiler,
        .severity = .err,
        .span = import.span,
        .message = try graph.arena.allocator().dupe(u8, "Compiler Error: выполнение импортов ещё не поддержано Zig-версией"),
    });
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
    var file_path = arguments.next() orelse {
        try stdout.print("Panos REPL ещё не поддержан Zig-версией\n", .{});
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
        try stderr.print("panos build: Zig AOT-сборка ещё не поддержана\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    var graph = panos_core.module_loader.Graph.init(init.gpa);
    defer graph.deinit();
    try graph.load(&FileReader{ .io = init.io }, file_path);
    if (!hasErrors(&graph.diagnostics) and graph.modules.items.len > 1) try reportUnsupportedModuleExecution(&graph);
    if (graph.diagnostics.items.items.len != 0) {
        try writeModuleDiagnostics(stderr, &graph);
        if (hasErrors(&graph.diagnostics)) {
            try stderr.flush();
            std.process.exit(1);
        }
    }

    const input = std.Io.Dir.cwd().readFileAlloc(init.io, file_path, init.gpa, .limited(16 * 1024 * 1024)) catch |err| {
        try stderr.print("Не удалось загрузить входной файл {s}: {s}\n", .{ file_path, @errorName(err) });
        try stderr.flush();
        std.process.exit(1);
    };
    defer init.gpa.free(input);
    var result = try runSourceWithVerbose(init.gpa, file_path, input, verbose);
    defer result.deinit();
    const file = panos_core.source.SourceFile.init(0, file_path, input);
    if (result.verbose) |info| try writeVerboseInfo(stdout, info);
    try writeDiagnostics(stderr, file, &result.diagnostics);
    if (result.hasErrors()) {
        try stderr.flush();
        std.process.exit(1);
    }
    switch (result.execution orelse unreachable) {
        .success => |output| {
            if (result.verbose != null) try stdout.print("EXECUTION\n--------------------------\n", .{});
            try stdout.print("{s}\n", .{output});
            try stdout.flush();
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
    try std.testing.expectEqual(@as(?usize, 1), info.functions);
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

test "CLI blocks execution before the module linker is available" {
    var graph = panos_core.module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.imports.append(std.testing.allocator, .{
        .importer = 0,
        .declaration = @enumFromInt(0),
        .target = 1,
        .alias = "математика",
        .span = .{ .file_id = 0, .start = 0, .end = 1 },
    });
    try reportUnsupportedModuleExecution(&graph);

    try std.testing.expectEqual(@as(usize, 1), graph.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Compiler Error: выполнение импортов ещё не поддержано Zig-версией", graph.diagnostics.items.items[0].message);
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
