const std = @import("std");
const panos_core = @import("panos_core");

pub const DiagnosticFormatError = error{
    FileMismatch,
    InvalidSpan,
};

pub const Execution = union(enum) {
    success: []const u8,
    runtime_error: []const u8,
};

pub const SourceRun = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    diagnostics: panos_core.diagnostic.DiagnosticList = .{},
    execution: ?Execution = null,

    fn init(allocator: std.mem.Allocator) SourceRun {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *SourceRun) void {
        self.diagnostics.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn hasErrors(self: *const SourceRun) bool {
        for (self.diagnostics.items.items) |diagnostic| {
            if (diagnostic.severity == .err) return true;
        }
        return false;
    }

    fn appendDiagnostics(self: *SourceRun, diagnostics: *const panos_core.diagnostic.DiagnosticList) !void {
        for (diagnostics.items.items) |value| {
            const message = try self.arena.allocator().dupe(u8, value.message);
            _ = try self.diagnostics.appendUnique(self.allocator, .{
                .phase = value.phase,
                .severity = value.severity,
                .span = value.span,
                .message = message,
            });
        }
    }

    fn report(self: *SourceRun, phase: panos_core.diagnostic.Phase, span: panos_core.source.Span, message: []const u8) !void {
        _ = try self.diagnostics.appendUnique(self.allocator, .{
            .phase = phase,
            .severity = .err,
            .span = span,
            .message = try self.arena.allocator().dupe(u8, message),
        });
    }
};

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
    var result = SourceRun.init(allocator);
    errdefer result.deinit();
    const file = panos_core.source.SourceFile.init(0, path, input);

    var lexed = try panos_core.lexer.tokenize(allocator, input, file.id);
    defer lexed.deinit();
    try result.appendDiagnostics(&lexed.diagnostics);

    var parsed = try panos_core.parser.parse(allocator, lexed.tokens.items);
    defer parsed.deinit();
    try result.appendDiagnostics(&parsed.diagnostics);

    var resolved = try panos_core.resolver.resolve(allocator, &parsed.ast);
    defer resolved.deinit();
    try result.appendDiagnostics(&resolved.diagnostics);

    var checked = try panos_core.type_checker.check(allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try result.appendDiagnostics(&checked.diagnostics);
    if (result.hasErrors()) return result;

    var compiled = try panos_core.compiler.compile(allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try result.appendDiagnostics(&compiled.diagnostics);
    if (result.hasErrors()) return result;

    const start = findStartFunction(&resolved, &compiled) orelse {
        try result.report(.compiler, .{ .file_id = file.id, .start = 0, .end = 0 }, "Compiler Error: не определена функция 'старт'");
        return result;
    };
    var vm = panos_core.vm.Vm.init(allocator, &compiled.program);
    defer vm.deinit();
    switch (try vm.run(start, &.{})) {
        .success => |runtime_value| result.execution = .{ .success = try renderValue(result.arena.allocator(), runtime_value) },
        .runtime_error => |message| result.execution = .{ .runtime_error = try result.arena.allocator().dupe(u8, message) },
    }
    return result;
}

pub fn writeDiagnostics(writer: *std.Io.Writer, file: panos_core.source.SourceFile, diagnostics: *const panos_core.diagnostic.DiagnosticList) !void {
    for (diagnostics.items.items) |value| {
        const rendered = try formatDiagnostic(std.heap.page_allocator, file, value);
        defer std.heap.page_allocator.free(rendered);
        try writer.print("{s}\n", .{rendered});
    }
}

fn findStartFunction(resolution: *const panos_core.resolver.Resolution, compiled: *const panos_core.compiler.CompileResult) ?panos_core.bytecode.FunctionId {
    for (resolution.symbols.symbols.items, 0..) |symbol, index| {
        if (symbol.kind != .function or !std.mem.eql(u8, symbol.name, "старт")) continue;
        const id: panos_core.symbols.SymbolId = @enumFromInt(index);
        return compiled.function_ids.get(id);
    }
    return null;
}

fn renderValue(allocator: std.mem.Allocator, runtime_value: panos_core.value.Value) ![]const u8 {
    return switch (runtime_value) {
        .void => allocator.dupe(u8, ""),
        .number => |number| std.fmt.allocPrint(allocator, "{d}", .{number}),
        .boolean => |boolean| std.fmt.allocPrint(allocator, "{}", .{boolean}),
        .string => |string| allocator.dupe(u8, string),
        .heap_string => |string| allocator.dupe(u8, string.bytes),
        else => allocator.dupe(u8, "<составное значение>"),
    };
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
    var file_path = arguments.next() orelse {
        try stdout.print("Panos REPL ещё не поддержан Zig-версией\n", .{});
        try stdout.flush();
        return;
    };
    if (std.mem.eql(u8, file_path, "-v") or std.mem.eql(u8, file_path, "--verbose")) {
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

    const input = std.Io.Dir.cwd().readFileAlloc(init.io, file_path, init.gpa, .limited(16 * 1024 * 1024)) catch |err| {
        try stderr.print("Не удалось загрузить входной файл {s}: {s}\n", .{ file_path, @errorName(err) });
        try stderr.flush();
        std.process.exit(1);
    };
    defer init.gpa.free(input);
    var result = try runSource(init.gpa, file_path, input);
    defer result.deinit();
    const file = panos_core.source.SourceFile.init(0, file_path, input);
    try writeDiagnostics(stderr, file, &result.diagnostics);
    if (result.hasErrors()) {
        try stderr.flush();
        std.process.exit(1);
    }
    switch (result.execution orelse unreachable) {
        .success => |output| {
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
