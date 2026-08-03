const std = @import("std");
const ast = @import("ast.zig");
const bytecode = @import("bytecode.zig");
const diagnostic = @import("diagnostic.zig");
const resolver = @import("resolver.zig");
const source = @import("source.zig");
const symbols = @import("symbols.zig");
const type_checker = @import("type_checker.zig");

pub const CompileResult = struct {
    allocator: std.mem.Allocator,
    program: bytecode.Program,
    diagnostics: diagnostic.DiagnosticList = .{},
    function_ids: std.AutoHashMap(symbols.SymbolId, bytecode.FunctionId),

    pub fn init(allocator: std.mem.Allocator) CompileResult {
        return .{
            .allocator = allocator,
            .program = bytecode.Program.init(allocator),
            .function_ids = .init(allocator),
        };
    }

    pub fn deinit(self: *CompileResult) void {
        self.function_ids.deinit();
        self.diagnostics.deinit(self.allocator);
        self.program.deinit();
        self.* = undefined;
    }
};

const Compiler = struct {
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    checked: *const type_checker.CheckResult,
    result: *CompileResult,
    arena: std.heap.ArenaAllocator,

    fn init(
        tree: *const ast.Ast,
        resolution: *const resolver.Resolution,
        checked: *const type_checker.CheckResult,
        result: *CompileResult,
    ) Compiler {
        return .{
            .tree = tree,
            .resolution = resolution,
            .checked = checked,
            .result = result,
            .arena = std.heap.ArenaAllocator.init(result.allocator),
        };
    }

    fn deinit(self: *Compiler) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn report(self: *Compiler, span: source.Span, comptime format: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.arena.allocator(), format, args);
        _ = try self.result.diagnostics.appendUnique(self.result.allocator, .{
            .phase = .compiler,
            .severity = .err,
            .span = span,
            .message = message,
        });
    }

    fn predeclareFunctions(self: *Compiler) !void {
        for (self.tree.program.?.declarations) |declaration| {
            switch (self.tree.decl(declaration).*) {
                .function => |function| try self.predeclareFunction(declaration, function.name, function.parameters.len),
                .impl => |implementation| for (implementation.methods) |method| {
                    const function = self.tree.decl(method).function;
                    try self.predeclareFunction(method, function.name, function.parameters.len);
                },
                else => {},
            }
        }
    }

    fn predeclareFunction(self: *Compiler, declaration: ast.DeclId, name: []const u8, parameter_count: usize) !void {
        const symbol = self.resolution.decl_symbols.get(declaration) orelse return;
        if (parameter_count > std.math.maxInt(u16)) {
            try self.report(self.tree.decl(declaration).function.span, "Compiler Error: слишком много параметров функции", .{});
            return;
        }
        const function_id = try self.result.program.addFunction(name, @intCast(parameter_count));
        try self.result.function_ids.put(symbol, function_id);
    }

    fn compileFunctions(self: *Compiler) !void {
        for (self.tree.program.?.declarations) |declaration| {
            switch (self.tree.decl(declaration).*) {
                .function => try self.compileFunction(declaration),
                .impl => |implementation| for (implementation.methods) |method| try self.compileFunction(method),
                else => {},
            }
        }
    }

    fn compileFunction(self: *Compiler, declaration: ast.DeclId) !void {
        const function = self.tree.decl(declaration).function;
        const symbol = self.resolution.decl_symbols.get(declaration) orelse return;
        const function_id = self.result.function_ids.get(symbol) orelse return;
        const compiled = self.result.program.function(function_id) orelse return;
        const signature_id = self.checked.symbol_types.get(symbol) orelse return;
        const signature = self.checked.types.get(signature_id) orelse return;
        const function_type = switch (signature.*) {
            .function => |value| value,
            else => return,
        };
        compiled.returns_value = !self.checked.types.eql(function_type.return_type, self.checked.types.builtins.void);

        var context = FunctionCompiler.init(self, compiled);
        defer context.deinit();
        const parameter_symbols = self.resolution.function_parameters.get(declaration) orelse &.{};
        for (parameter_symbols) |parameter_symbol| _ = try context.ensureLocal(parameter_symbol);

        if (function.body.len == 0) {
            try compiled.emit(self.result.allocator, .{ .return_void = {} });
            return;
        }
        for (function.body[0 .. function.body.len - 1]) |statement| _ = try context.compileStatement(statement, false);
        const leaves_value = try context.compileStatement(function.body[function.body.len - 1], compiled.returns_value);
        if (compiled.returns_value and leaves_value) {
            try compiled.emit(self.result.allocator, .{ .return_value = {} });
        } else {
            try compiled.emit(self.result.allocator, .{ .return_void = {} });
        }
        compiled.local_count = context.next_local;
    }
};

const FunctionCompiler = struct {
    compiler: *Compiler,
    function: *bytecode.Function,
    locals: std.AutoHashMap(symbols.SymbolId, u16),
    next_local: u16 = 0,

    fn init(compiler: *Compiler, function: *bytecode.Function) FunctionCompiler {
        return .{
            .compiler = compiler,
            .function = function,
            .locals = .init(compiler.result.allocator),
        };
    }

    fn deinit(self: *FunctionCompiler) void {
        self.locals.deinit();
        self.* = undefined;
    }

    fn ensureLocal(self: *FunctionCompiler, symbol: symbols.SymbolId) !u16 {
        if (self.locals.get(symbol)) |slot| return slot;
        if (self.next_local == std.math.maxInt(u16)) return error.LocalLimitReached;
        const slot = self.next_local;
        self.next_local += 1;
        try self.locals.put(symbol, slot);
        return slot;
    }

    fn emitConstant(self: *FunctionCompiler, constant: bytecode.Constant) !void {
        const index = try self.function.addConstant(self.compiler.result.allocator, constant);
        try self.function.emit(self.compiler.result.allocator, .{ .constant = index });
    }

    fn emitVoid(self: *FunctionCompiler) !void {
        try self.emitConstant(.{ .void = {} });
    }

    fn compileStatement(self: *FunctionCompiler, statement: ast.StmtId, keep_value: bool) anyerror!bool {
        return switch (self.compiler.tree.stmt(statement).*) {
            .let => |let| blk: {
                try self.compileExpression(let.value);
                const bindings = self.compiler.resolution.stmt_bindings.get(statement) orelse &.{};
                if (bindings.len != 1) {
                    try self.compiler.report(let.span, "Compiler Error: деструктуризация пока не поддержана", .{});
                    try self.function.emit(self.compiler.result.allocator, .{ .pop = {} });
                } else {
                    const slot = try self.ensureLocal(bindings[0]);
                    try self.function.emit(self.compiler.result.allocator, .{ .set_local = slot });
                }
                if (keep_value) {
                    try self.emitVoid();
                    break :blk true;
                }
                break :blk false;
            },
            .return_stmt => |return_statement| blk: {
                try self.compileExpression(return_statement.value);
                if (self.function.returns_value) {
                    try self.function.emit(self.compiler.result.allocator, .{ .return_value = {} });
                } else {
                    try self.function.emit(self.compiler.result.allocator, .{ .pop = {} });
                    try self.function.emit(self.compiler.result.allocator, .{ .return_void = {} });
                }
                break :blk false;
            },
            .expr => |expression| blk: {
                try self.compileExpression(expression.value);
                if (!keep_value) try self.function.emit(self.compiler.result.allocator, .{ .pop = {} });
                break :blk keep_value;
            },
            else => blk: {
                try self.compiler.report(statementSpan(self.compiler.tree, statement), "Compiler Error: инструкция пока не поддержана", .{});
                if (keep_value) {
                    try self.emitVoid();
                    break :blk true;
                }
                break :blk false;
            },
        };
    }

    fn compileExpression(self: *FunctionCompiler, expression: ast.ExprId) anyerror!void {
        switch (self.compiler.tree.expr(expression).*) {
            .number => |number| try self.emitConstant(.{ .number = number.value }),
            .boolean => |boolean| try self.emitConstant(.{ .boolean = boolean.value }),
            .string => |string| try self.emitConstant(.{ .string = try self.compiler.result.program.copyString(string.value) }),
            .ident => try self.compileIdentifier(expression),
            .unary => |unary| {
                try self.compileExpression(unary.operand);
                const instruction: bytecode.Instruction = switch (unary.operator) {
                    .minus => .{ .negate_number = {} },
                    .negate => .{ .logical_not = {} },
                    .tilde => .{ .bit_not = {} },
                    else => return self.unsupportedExpression(unary.span),
                };
                try self.function.emit(self.compiler.result.allocator, instruction);
            },
            .binary => |binary| try self.compileBinary(binary),
            .call => |call| {
                if (call.argument_names != null) try self.compiler.report(call.span, "Compiler Error: именованные аргументы пока не поддержаны", .{});
                try self.compileExpression(call.callee);
                for (call.arguments) |argument| try self.compileExpression(argument);
                if (call.arguments.len > std.math.maxInt(u16)) return error.ArgumentLimitReached;
                try self.function.emit(self.compiler.result.allocator, .{ .call = @intCast(call.arguments.len) });
            },
            .if_expr => |conditional| try self.compileIf(conditional),
            .while_expr => |loop| try self.compileWhile(loop),
            else => try self.unsupportedExpression(expressionSpan(self.compiler.tree, expression)),
        }
    }

    fn compileIf(self: *FunctionCompiler, conditional: anytype) !void {
        try self.compileExpression(conditional.condition);
        const false_jump = self.function.instructions.items.len;
        try self.function.emit(self.compiler.result.allocator, .{ .jump_if_false = 0 });
        try self.compileBlockValue(conditional.then_branch);
        const end_jump = self.function.instructions.items.len;
        try self.function.emit(self.compiler.result.allocator, .{ .jump = 0 });
        self.patchJump(false_jump, self.function.instructions.items.len);
        try self.compileBlockValue(conditional.else_branch);
        self.patchJump(end_jump, self.function.instructions.items.len);
    }

    fn compileWhile(self: *FunctionCompiler, loop: anytype) !void {
        const loop_start = self.function.instructions.items.len;
        try self.compileExpression(loop.condition);
        const exit_jump = self.function.instructions.items.len;
        try self.function.emit(self.compiler.result.allocator, .{ .jump_if_false = 0 });
        try self.compileBlockStatements(loop.body);
        try self.function.emit(self.compiler.result.allocator, .{ .jump = loop_start });
        self.patchJump(exit_jump, self.function.instructions.items.len);
        try self.emitVoid();
    }

    fn compileBlockValue(self: *FunctionCompiler, statements: []const ast.StmtId) !void {
        if (statements.len == 0) {
            try self.emitVoid();
            return;
        }
        for (statements[0 .. statements.len - 1]) |statement| _ = try self.compileStatement(statement, false);
        if (!try self.compileStatement(statements[statements.len - 1], true)) try self.emitVoid();
    }

    fn compileBlockStatements(self: *FunctionCompiler, statements: []const ast.StmtId) !void {
        for (statements) |statement| _ = try self.compileStatement(statement, false);
    }

    fn patchJump(self: *FunctionCompiler, instruction_index: usize, target: usize) void {
        switch (self.function.instructions.items[instruction_index]) {
            .jump => self.function.instructions.items[instruction_index].jump = target,
            .jump_if_false => self.function.instructions.items[instruction_index].jump_if_false = target,
            else => unreachable,
        }
    }

    fn compileIdentifier(self: *FunctionCompiler, expression: ast.ExprId) !void {
        const symbol = self.compiler.resolution.expr_symbols.get(expression) orelse return self.unsupportedExpression(expressionSpan(self.compiler.tree, expression));
        if (self.locals.get(symbol)) |slot| {
            try self.function.emit(self.compiler.result.allocator, .{ .get_local = slot });
            return;
        }
        if (self.compiler.result.function_ids.get(symbol)) |function_id| {
            try self.emitConstant(.{ .function_ref = function_id });
            return;
        }
        try self.unsupportedExpression(expressionSpan(self.compiler.tree, expression));
    }

    fn compileBinary(self: *FunctionCompiler, binary: anytype) anyerror!void {
        if (binary.operator == .assign) {
            try self.compileAssignment(binary);
            return;
        }
        try self.compileExpression(binary.left);
        try self.compileExpression(binary.right);
        const instruction: bytecode.Instruction = switch (binary.operator) {
            .plus => .{ .add = {} },
            .minus => .{ .subtract = {} },
            .star => .{ .multiply = {} },
            .slash => if (self.expressionIsInteger(binary.left)) .{ .int_divide = {} } else .{ .divide = {} },
            .percent => .{ .modulo = {} },
            .ampersand => .{ .bit_and = {} },
            .pipe => .{ .bit_or = {} },
            .caret => .{ .bit_xor = {} },
            .less_less => .{ .shift_left = {} },
            .greater_greater => .{ .shift_right = {} },
            .less => .{ .less = {} },
            .less_equal => .{ .less_equal = {} },
            .greater => .{ .greater = {} },
            .greater_equal => .{ .greater_equal = {} },
            .equal => .{ .equal = {} },
            .not_equal => .{ .not_equal = {} },
            else => return self.unsupportedExpression(binary.span),
        };
        try self.function.emit(self.compiler.result.allocator, instruction);
    }

    fn compileAssignment(self: *FunctionCompiler, binary: anytype) anyerror!void {
        const symbol = switch (self.compiler.tree.expr(binary.left).*) {
            .ident => self.compiler.resolution.expr_symbols.get(binary.left) orelse return self.unsupportedExpression(binary.span),
            else => return self.unsupportedExpression(binary.span),
        };
        const slot = self.locals.get(symbol) orelse return self.unsupportedExpression(binary.span);
        try self.compileExpression(binary.right);
        try self.function.emit(self.compiler.result.allocator, .{ .set_local = slot });
        try self.emitVoid();
    }

    fn expressionIsInteger(self: *const FunctionCompiler, expression: ast.ExprId) bool {
        const inferred = self.compiler.checked.expression_types.get(expression) orelse return false;
        return self.compiler.checked.types.eql(inferred, self.compiler.checked.types.builtins.integer);
    }

    fn unsupportedExpression(self: *FunctionCompiler, span: source.Span) !void {
        try self.compiler.report(span, "Compiler Error: выражение пока не поддержано", .{});
        try self.emitVoid();
    }
};

pub fn compile(
    allocator: std.mem.Allocator,
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    checked: *const type_checker.CheckResult,
) !CompileResult {
    var result = CompileResult.init(allocator);
    errdefer result.deinit();
    var compiler = Compiler.init(tree, resolution, checked, &result);
    defer compiler.deinit();
    try compiler.predeclareFunctions();
    try compiler.compileFunctions();
    return result;
}

fn expressionSpan(tree: *const ast.Ast, expression: ast.ExprId) source.Span {
    return switch (tree.expr(expression).*) {
        .error_node => |span| span,
        inline else => |value| value.span,
    };
}

fn statementSpan(tree: *const ast.Ast, statement: ast.StmtId) source.Span {
    return switch (tree.stmt(statement).*) {
        .continue_stmt, .break_stmt, .error_node => |span| span,
        inline else => |value| value.span,
    };
}

test "compiler emits locals, arithmetic and direct calls" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ сложить(a: Число, b: Число) -> Число\na + b\nконец\nфунк старт() -> Число\nпер сумма = сложить(1, 2)\nсумма * 3\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    var compiled = try compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();

    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 2), compiled.program.functions.items.len);
    const entry = compiled.program.functions.items[1];
    try std.testing.expectEqual(@as(u16, 1), entry.local_count);
    try std.testing.expectEqual(bytecode.Instruction{ .call = 2 }, entry.instructions.items[3]);
    try std.testing.expectEqual(bytecode.Instruction{ .set_local = 0 }, entry.instructions.items[4]);
    try std.testing.expectEqual(bytecode.Instruction{ .multiply = {} }, entry.instructions.items[7]);
    try std.testing.expectEqual(bytecode.Instruction{ .return_value = {} }, entry.instructions.items[8]);
}

test "compiler emits absolute jumps for if and while expressions" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ выбрать(условие: Булево) -> Число\nесли условие тогда\n1\nиначе\n2\nконец\nконец\nфунк посчитать(предел: Число) -> Число\nпер счётчик = 0\nпока счётчик < предел цикл\nсчётчик = счётчик + 1\nконец\nсчётчик\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    var compiled = try compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();

    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const choose = compiled.program.functions.items[0];
    try std.testing.expectEqual(bytecode.Instruction{ .jump_if_false = 4 }, choose.instructions.items[1]);
    try std.testing.expectEqual(bytecode.Instruction{ .jump = 5 }, choose.instructions.items[3]);
    const count = compiled.program.functions.items[1];
    var has_forward_exit = false;
    var has_backward_loop = false;
    for (count.instructions.items, 0..) |instruction, index| {
        switch (instruction) {
            .jump_if_false => |target| has_forward_exit = has_forward_exit or target > index,
            .jump => |target| has_backward_loop = has_backward_loop or target < index,
            else => {},
        }
    }
    try std.testing.expect(has_forward_exit);
    try std.testing.expect(has_backward_loop);
}
