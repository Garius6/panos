const std = @import("std");
const ast = @import("ast.zig");
const bytecode = @import("bytecode.zig");
const compiler = @import("compiler.zig");
const diagnostic = @import("diagnostic.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const source = @import("source.zig");
const symbols = @import("symbols.zig");
const type_checker = @import("type_checker.zig");
const types = @import("types.zig");
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

pub const SourceAnalysis = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    diagnostics: diagnostic.DiagnosticList = .{},
    parsed: ?parser.ParseResult = null,
    resolved: ?resolver.Resolution = null,
    checked: ?type_checker.CheckResult = null,

    pub fn init(allocator: std.mem.Allocator) SourceAnalysis {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *SourceAnalysis) void {
        if (self.checked) |*checked| checked.deinit();
        if (self.resolved) |*resolved| resolved.deinit();
        if (self.parsed) |*parsed| parsed.deinit();
        self.diagnostics.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn hasErrors(self: *const SourceAnalysis) bool {
        for (self.diagnostics.items.items) |item| {
            if (item.severity == .err) return true;
        }
        return false;
    }

    pub fn tree(self: *const SourceAnalysis) ?*const ast.Ast {
        if (self.parsed) |*parsed| return &parsed.ast;
        return null;
    }

    pub fn resolution(self: *const SourceAnalysis) ?*const resolver.Resolution {
        if (self.resolved) |*resolved| return resolved;
        return null;
    }

    pub fn checkedResult(self: *const SourceAnalysis) ?*const type_checker.CheckResult {
        if (self.checked) |*checked| return checked;
        return null;
    }

    pub fn expressionTypeName(self: *SourceAnalysis, expression: ast.ExprId) anyerror!?[]const u8 {
        const checked = self.checkedResult() orelse return null;
        const type_id = checked.expression_types.get(expression) orelse return null;
        const resolved = self.resolution() orelse return null;
        return @as(?[]const u8, try formatTypeName(self.arena.allocator(), &checked.types, &resolved.symbols, type_id));
    }

    fn appendDiagnostics(self: *SourceAnalysis, items: *const diagnostic.DiagnosticList) !void {
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

    fn report(self: *SourceAnalysis, phase: diagnostic.Phase, span: source.Span, message: []const u8) !void {
        _ = try self.diagnostics.appendUnique(self.allocator, .{
            .phase = phase,
            .severity = .err,
            .span = span,
            .message = try self.arena.allocator().dupe(u8, message),
        });
    }
};

fn formatTypeName(
    allocator: std.mem.Allocator,
    store: *const types.TypeStore,
    symbol_store: *const symbols.SymbolStore,
    type_id: types.TypeId,
) anyerror![]const u8 {
    const entry = store.get(type_id) orelse return allocator.dupe(u8, "<неизвестный тип>");
    return switch (entry.*) {
        .primitive => |primitive| allocator.dupe(u8, primitiveTypeName(primitive)),
        .tuple => |elements| formatTypeSequence(allocator, store, symbol_store, elements, "(", ")"),
        .function => |signature| blk: {
            const parameters = try formatTypeSequence(allocator, store, symbol_store, signature.parameters, "функ(", ")");
            const return_type = try formatTypeName(allocator, store, symbol_store, signature.return_type);
            break :blk std.fmt.allocPrint(allocator, "{s} -> {s}", .{ parameters, return_type });
        },
        .nominal => |nominal| blk: {
            const name = (symbol_store.get(nominal.symbol) orelse break :blk allocator.dupe(u8, "<неизвестный тип>")).name;
            if (nominal.arguments.len == 0) break :blk allocator.dupe(u8, name);
            const arguments = try formatTypeSequence(allocator, store, symbol_store, nominal.arguments, "", "");
            break :blk std.fmt.allocPrint(allocator, "{s}({s})", .{ name, arguments });
        },
        .array => |element| formatWrappedType(allocator, store, symbol_store, "Массив", element),
        .map => |map| blk: {
            const key = try formatTypeName(allocator, store, symbol_store, map.key);
            const mapped_value = try formatTypeName(allocator, store, symbol_store, map.value);
            break :blk std.fmt.allocPrint(allocator, "Соответствие({s}, {s})", .{ key, mapped_value });
        },
        .process => |message| formatWrappedType(allocator, store, symbol_store, "Процесс", message),
        .pointer => |pointee| formatWrappedType(allocator, store, symbol_store, "Указатель", pointee),
        .generic_parameter => |identifier| std.fmt.allocPrint(allocator, "T{d}", .{identifier}),
        .poison => allocator.dupe(u8, "<ошибка типа>"),
    };
}

fn formatWrappedType(
    allocator: std.mem.Allocator,
    store: *const types.TypeStore,
    symbol_store: *const symbols.SymbolStore,
    name: []const u8,
    element: types.TypeId,
) anyerror![]const u8 {
    const rendered = try formatTypeName(allocator, store, symbol_store, element);
    return std.fmt.allocPrint(allocator, "{s}({s})", .{ name, rendered });
}

fn formatTypeSequence(
    allocator: std.mem.Allocator,
    store: *const types.TypeStore,
    symbol_store: *const symbols.SymbolStore,
    values: []const types.TypeId,
    prefix: []const u8,
    suffix: []const u8,
) anyerror![]const u8 {
    var result = try allocator.dupe(u8, prefix);
    for (values, 0..) |type_value, index| {
        const rendered = try formatTypeName(allocator, store, symbol_store, type_value);
        const separator: []const u8 = if (index == 0) "" else ", ";
        result = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ result, separator, rendered });
    }
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ result, suffix });
}

fn primitiveTypeName(primitive: types.Primitive) []const u8 {
    return switch (primitive) {
        .number => "Число",
        .integer => "Целое",
        .boolean => "Булево",
        .void => "Пусто",
        .never => "Никогда",
        .string => "Строка",
        .error_value => "Ошибка",
    };
}

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
    var analysis = try analyzeSource(allocator, path, input);
    defer analysis.deinit();

    var result = SourceRun.init(allocator);
    errdefer result.deinit();
    try result.appendDiagnostics(&analysis.diagnostics);
    return result;
}

pub fn analyzeSource(allocator: std.mem.Allocator, path: []const u8, input: []const u8) !SourceAnalysis {
    var analysis = SourceAnalysis.init(allocator);
    errdefer analysis.deinit();
    const file = source.SourceFile.init(0, path, input);

    var lexed = try lexer.tokenize(allocator, input, file.id);
    defer lexed.deinit();
    try analysis.appendDiagnostics(&lexed.diagnostics);

    analysis.parsed = try parser.parse(allocator, lexed.tokens.items);
    const parsed = &analysis.parsed.?;
    try analysis.appendDiagnostics(&parsed.diagnostics);
    const tree = &parsed.ast;
    if (try reportUnsupportedImports(&analysis, tree)) return analysis;

    analysis.resolved = try resolver.resolve(allocator, tree);
    const resolved = &analysis.resolved.?;
    try analysis.appendDiagnostics(&resolved.diagnostics);

    analysis.checked = try type_checker.check(allocator, tree, resolved);
    const checked = &analysis.checked.?;
    try analysis.appendDiagnostics(&checked.diagnostics);
    return analysis;
}

pub fn runSourceWithVerbose(allocator: std.mem.Allocator, path: []const u8, input: []const u8, verbose: bool) !SourceRun {
    var result = SourceRun.init(allocator);
    errdefer result.deinit();
    var analysis = try analyzeSource(allocator, path, input);
    defer analysis.deinit();
    try result.appendDiagnostics(&analysis.diagnostics);

    const tree = analysis.tree() orelse return result;
    if (verbose) result.verbose = .{ .declarations = tree.program.?.declarations.len };
    const resolved = analysis.resolution() orelse return result;
    if (result.verbose) |*info| info.symbols = resolved.symbols.symbols.items.len - 1;
    const checked = analysis.checkedResult() orelse return result;
    if (result.verbose) |*info| info.types = checked.types.types.items.len - 1;
    if (result.hasErrors()) return result;

    var compiled = try compiler.compile(allocator, tree, resolved, checked);
    defer compiled.deinit();
    try result.appendDiagnostics(&compiled.diagnostics);
    if (result.verbose) |*info| info.functions = compiled.program.functions.items.len;
    if (result.hasErrors()) return result;

    const start = findStartFunction(resolved, &compiled) orelse {
        try result.report(.compiler, .{ .file_id = 0, .start = 0, .end = 0 }, "Compiler Error: не определена функция 'старт'");
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

fn reportUnsupportedImports(analysis: *SourceAnalysis, tree: *const ast.Ast) !bool {
    for (tree.program.?.declarations) |declaration| {
        const import = switch (tree.decl(declaration).*) {
            .import => |entry| entry,
            else => continue,
        };
        try analysis.report(.compiler, import.span, "Compiler Error: выполнение импортов ещё не поддержано Zig-версией");
    }
    return analysis.hasErrors();
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

test "runner rejects imports before a single-file execution" {
    var result = try runSource(std.testing.allocator, "main.ps", "импорт \"математика\"\nэкспорт функ старт() -> Число\n1\nконец");
    defer result.deinit();

    try std.testing.expect(result.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Compiler Error: выполнение импортов ещё не поддержано Zig-версией", result.diagnostics.items.items[0].message);
    try std.testing.expect(result.execution == null);
}

test "analysis retains expressions and their inferred types" {
    const input = "экспорт функ старт() -> Число\n42\nконец";
    var analysis = try analyzeSource(std.testing.allocator, "пример.ps", input);
    defer analysis.deinit();

    const offset = std.mem.indexOf(u8, input, "42").?;
    const expression = analysis.tree().?.findExpressionAt(0, @intCast(offset)).?;
    const checked = analysis.checkedResult().?;
    const inferred = checked.expression_types.get(expression).?;
    try std.testing.expectEqual(checked.types.builtins.number, inferred);
    try std.testing.expectEqualStrings("Число", (try analysis.expressionTypeName(expression)).?);
}
