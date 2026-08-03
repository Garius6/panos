const std = @import("std");
const bytecode = @import("bytecode.zig");
const compiler = @import("compiler.zig");
const diagnostic = @import("diagnostic.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const source = @import("source.zig");
const symbols = @import("symbols.zig");
const type_checker = @import("type_checker.zig");
const value = @import("value.zig");
const vm = @import("vm.zig");

pub const Execution = union(enum) {
    success: []const u8,
    runtime_error: []const u8,
};

pub const VerboseInfo = struct {
    declarations: usize = 0,
    symbols: ?usize = null,
    types: ?usize = null,
    functions: ?usize = null,
};

pub const SourceRun = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    diagnostics: diagnostic.DiagnosticList = .{},
    execution: ?Execution = null,
    verbose: ?VerboseInfo = null,

    pub fn init(allocator: std.mem.Allocator) SourceRun {
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
        for (self.diagnostics.items.items) |item| {
            if (item.severity == .err) return true;
        }
        return false;
    }

    fn appendDiagnostics(self: *SourceRun, items: *const diagnostic.DiagnosticList) !void {
        for (items.items.items) |item| {
            const message = try self.arena.allocator().dupe(u8, item.message);
            _ = try self.diagnostics.appendUnique(self.allocator, .{
                .phase = item.phase,
                .severity = item.severity,
                .span = item.span,
                .message = message,
            });
        }
    }

    fn report(self: *SourceRun, phase: diagnostic.Phase, span: source.Span, message: []const u8) !void {
        _ = try self.diagnostics.appendUnique(self.allocator, .{
            .phase = phase,
            .severity = .err,
            .span = span,
            .message = try self.arena.allocator().dupe(u8, message),
        });
    }
};

pub fn runSource(allocator: std.mem.Allocator, path: []const u8, input: []const u8) !SourceRun {
    return runSourceWithVerbose(allocator, path, input, false);
}

pub fn checkSource(allocator: std.mem.Allocator, path: []const u8, input: []const u8) !SourceRun {
    var result = SourceRun.init(allocator);
    errdefer result.deinit();
    const file = source.SourceFile.init(0, path, input);

    var lexed = try lexer.tokenize(allocator, input, file.id);
    defer lexed.deinit();
    try result.appendDiagnostics(&lexed.diagnostics);

    var parsed = try parser.parse(allocator, lexed.tokens.items);
    defer parsed.deinit();
    try result.appendDiagnostics(&parsed.diagnostics);

    var resolved = try resolver.resolve(allocator, &parsed.ast);
    defer resolved.deinit();
    try result.appendDiagnostics(&resolved.diagnostics);

    var checked = try type_checker.check(allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try result.appendDiagnostics(&checked.diagnostics);
    return result;
}

pub fn runSourceWithVerbose(allocator: std.mem.Allocator, path: []const u8, input: []const u8, verbose: bool) !SourceRun {
    var result = SourceRun.init(allocator);
    errdefer result.deinit();
    const file = source.SourceFile.init(0, path, input);

    var lexed = try lexer.tokenize(allocator, input, file.id);
    defer lexed.deinit();
    try result.appendDiagnostics(&lexed.diagnostics);

    var parsed = try parser.parse(allocator, lexed.tokens.items);
    defer parsed.deinit();
    try result.appendDiagnostics(&parsed.diagnostics);
    if (verbose) result.verbose = .{ .declarations = parsed.ast.program.?.declarations.len };

    var resolved = try resolver.resolve(allocator, &parsed.ast);
    defer resolved.deinit();
    try result.appendDiagnostics(&resolved.diagnostics);
    if (result.verbose) |*info| info.symbols = resolved.symbols.symbols.items.len - 1;

    var checked = try type_checker.check(allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try result.appendDiagnostics(&checked.diagnostics);
    if (result.verbose) |*info| info.types = checked.types.types.items.len - 1;
    if (result.hasErrors()) return result;

    var compiled = try compiler.compile(allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try result.appendDiagnostics(&compiled.diagnostics);
    if (result.verbose) |*info| info.functions = compiled.program.functions.items.len;
    if (result.hasErrors()) return result;

    const start = findStartFunction(&resolved, &compiled) orelse {
        try result.report(.compiler, .{ .file_id = file.id, .start = 0, .end = 0 }, "Compiler Error: не определена функция 'старт'");
        return result;
    };
    var machine = vm.Vm.init(allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |runtime_value| result.execution = .{ .success = try renderValue(result.arena.allocator(), runtime_value) },
        .runtime_error => |message| result.execution = .{ .runtime_error = try result.arena.allocator().dupe(u8, message) },
    }
    return result;
}

fn findStartFunction(resolution: *const resolver.Resolution, compiled: *const compiler.CompileResult) ?bytecode.FunctionId {
    for (resolution.symbols.symbols.items, 0..) |symbol, index| {
        if (symbol.kind != .function or !std.mem.eql(u8, symbol.name, "старт")) continue;
        const id: symbols.SymbolId = @enumFromInt(index);
        return compiled.function_ids.get(id);
    }
    return null;
}

pub fn renderValue(allocator: std.mem.Allocator, runtime_value: value.Value) ![]const u8 {
    return switch (runtime_value) {
        .void => allocator.dupe(u8, ""),
        .number => |number| std.fmt.allocPrint(allocator, "{d}", .{number}),
        .boolean => |boolean| std.fmt.allocPrint(allocator, "{}", .{boolean}),
        .string => |string| allocator.dupe(u8, string),
        .heap_string => |string| allocator.dupe(u8, string.bytes),
        else => allocator.dupe(u8, "<составное значение>"),
    };
}

test "runner executes an exported start function" {
    var result = try runSource(std.testing.allocator, "пример.ps", "экспорт функ старт() -> Число\n2 + 3\nконец");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("5", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "runner accumulates frontend diagnostics without executing" {
    var result = try runSource(std.testing.allocator, "ошибка.ps", "функ старт() -> Число\nнеизвестно\nконец");
    defer result.deinit();

    try std.testing.expect(result.hasErrors());
    try std.testing.expect(result.execution == null);
}

test "checker accepts a valid program without an entry function" {
    var result = try checkSource(std.testing.allocator, "библиотека.ps", "экспорт функ значение() -> Число\n42\nконец");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    try std.testing.expect(result.execution == null);
}
