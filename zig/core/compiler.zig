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
    lambda_ids: std.AutoHashMap(ast.ExprId, bytecode.FunctionId),

    pub fn init(allocator: std.mem.Allocator) CompileResult {
        return .{
            .allocator = allocator,
            .program = bytecode.Program.init(allocator),
            .function_ids = .init(allocator),
            .lambda_ids = .init(allocator),
        };
    }

    pub fn deinit(self: *CompileResult) void {
        self.lambda_ids.deinit();
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

    fn predeclareLambdas(self: *Compiler) !void {
        for (self.tree.expressions.items, 0..) |expression, index| {
            const lambda = switch (expression) {
                .lambda => |value| value,
                else => continue,
            };
            if (lambda.parameters.len > std.math.maxInt(u16)) {
                try self.report(lambda.span, "Compiler Error: слишком много параметров лямбды", .{});
                continue;
            }
            const expression_id: ast.ExprId = @enumFromInt(index);
            const function_id = try self.result.program.addFunction("лямбда", @intCast(lambda.parameters.len));
            try self.result.lambda_ids.put(expression_id, function_id);
        }
    }

    fn compileLambdas(self: *Compiler) !void {
        for (self.tree.expressions.items, 0..) |expression, index| {
            const lambda = switch (expression) {
                .lambda => |value| value,
                else => continue,
            };
            const expression_id: ast.ExprId = @enumFromInt(index);
            const captures = self.resolution.lambda_captures.get(expression_id) orelse &.{};
            if (captures.len > std.math.maxInt(u16)) {
                try self.report(lambda.span, "Compiler Error: лямбда захватывает слишком много значений", .{});
                continue;
            }
            const function_id = self.result.lambda_ids.get(expression_id) orelse continue;
            const compiled = self.result.program.function(function_id) orelse continue;
            const lambda_type = self.checked.expression_types.get(expression_id) orelse continue;
            const type_entry = self.checked.types.get(lambda_type) orelse continue;
            const signature = switch (type_entry.*) {
                .function => |value| value,
                else => continue,
            };
            compiled.returns_value = !self.checked.types.eql(signature.return_type, self.checked.types.builtins.void);
            compiled.capture_count = @intCast(captures.len);
            const parameters = self.resolution.lambda_parameters.get(expression_id) orelse &.{};
            try self.compileFunctionBody(compiled, captures, parameters, lambda.body);
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
        const parameter_symbols = self.resolution.function_parameters.get(declaration) orelse &.{};
        try self.compileFunctionBody(compiled, &.{}, parameter_symbols, function.body);
    }

    fn compileFunctionBody(
        self: *Compiler,
        compiled: *bytecode.Function,
        capture_symbols: []const symbols.SymbolId,
        parameter_symbols: []const symbols.SymbolId,
        body: []const ast.StmtId,
    ) !void {
        var context = FunctionCompiler.init(self, compiled);
        defer context.deinit();
        for (capture_symbols) |capture_symbol| _ = try context.ensureLocal(capture_symbol);
        for (parameter_symbols) |parameter_symbol| _ = try context.ensureLocal(parameter_symbol);

        if (body.len == 0) {
            try compiled.emit(self.result.allocator, .{ .return_void = {} });
            compiled.local_count = context.next_local;
            return;
        }
        for (body[0 .. body.len - 1]) |statement| _ = try context.compileStatement(statement, false);
        const leaves_value = try context.compileStatement(body[body.len - 1], compiled.returns_value);
        if (compiled.returns_value and leaves_value) {
            try compiled.emit(self.result.allocator, .{ .return_value = {} });
        } else {
            try compiled.emit(self.result.allocator, .{ .return_void = {} });
        }
        compiled.local_count = context.next_local;
    }
};

const LoopContext = struct {
    break_fixups: std.ArrayList(usize) = .empty,
    continue_fixups: std.ArrayList(usize) = .empty,

    fn deinit(self: *LoopContext, allocator: std.mem.Allocator) void {
        self.continue_fixups.deinit(allocator);
        self.break_fixups.deinit(allocator);
        self.* = undefined;
    }
};

const FunctionCompiler = struct {
    compiler: *Compiler,
    function: *bytecode.Function,
    locals: std.AutoHashMap(symbols.SymbolId, u16),
    loops: std.ArrayList(LoopContext) = .empty,
    next_local: u16 = 0,

    fn init(compiler: *Compiler, function: *bytecode.Function) FunctionCompiler {
        return .{
            .compiler = compiler,
            .function = function,
            .locals = .init(compiler.result.allocator),
        };
    }

    fn deinit(self: *FunctionCompiler) void {
        for (self.loops.items) |*loop| loop.deinit(self.compiler.result.allocator);
        self.loops.deinit(self.compiler.result.allocator);
        self.locals.deinit();
        self.* = undefined;
    }

    fn ensureLocal(self: *FunctionCompiler, symbol: symbols.SymbolId) !u16 {
        if (self.locals.get(symbol)) |slot| return slot;
        const slot = try self.allocateLocal();
        try self.locals.put(symbol, slot);
        return slot;
    }

    fn allocateLocal(self: *FunctionCompiler) !u16 {
        if (self.next_local == std.math.maxInt(u16)) return error.LocalLimitReached;
        const slot = self.next_local;
        self.next_local += 1;
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
                if (bindings.len == 0) {
                    try self.compiler.report(let.span, "Compiler Error: деструктуризация пока не поддержана", .{});
                    try self.function.emit(self.compiler.result.allocator, .{ .pop = {} });
                } else if (bindings.len == 1) {
                    const slot = try self.ensureLocal(bindings[0]);
                    try self.function.emit(self.compiler.result.allocator, .{ .set_local = slot });
                } else {
                    const aggregate_slot = try self.allocateLocal();
                    try self.function.emit(self.compiler.result.allocator, .{ .set_local = aggregate_slot });
                    for (bindings, 0..) |binding, index| {
                        const field_index = try self.destructureFieldIndex(let, index) orelse {
                            try self.compiler.report(let.span, "Compiler Error: поле деструктуризации не найдено", .{});
                            continue;
                        };
                        const slot = try self.ensureLocal(binding);
                        try self.function.emit(self.compiler.result.allocator, .{ .get_local = aggregate_slot });
                        try self.function.emit(self.compiler.result.allocator, .{ .get_property = field_index });
                        try self.function.emit(self.compiler.result.allocator, .{ .set_local = slot });
                    }
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
            .for_in => |loop| blk: {
                try self.compileForIn(statement, loop);
                if (keep_value) {
                    try self.emitVoid();
                    break :blk true;
                }
                break :blk false;
            },
            .for_range => |range| blk: {
                try self.compileForRange(statement, range);
                if (keep_value) {
                    try self.emitVoid();
                    break :blk true;
                }
                break :blk false;
            },
            .continue_stmt => |span| blk: {
                try self.compileLoopControl(span, true);
                break :blk false;
            },
            .break_stmt => |span| blk: {
                try self.compileLoopControl(span, false);
                break :blk false;
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
            .call => |call| try self.compileCall(call),
            .tuple => |tuple| try self.compileSequence(tuple.elements, .build_tuple),
            .array => |array| try self.compileSequence(array.elements, .build_array),
            .map => |map| try self.compileMap(map),
            .lambda => |lambda| try self.compileLambda(expression, lambda),
            .index => |index| {
                try self.compileExpression(index.object);
                try self.compileExpression(index.index);
                try self.function.emit(self.compiler.result.allocator, .{ .get_index = {} });
            },
            .property => |property| try self.compileProperty(property),
            .if_expr => |conditional| try self.compileIf(conditional),
            .while_expr => |loop| try self.compileWhile(loop),
            else => try self.unsupportedExpression(expressionSpan(self.compiler.tree, expression)),
        }
    }

    fn compileLambda(self: *FunctionCompiler, expression: ast.ExprId, lambda: anytype) !void {
        const captures = self.compiler.resolution.lambda_captures.get(expression) orelse &.{};
        if (captures.len > std.math.maxInt(u16)) {
            try self.compiler.report(lambda.span, "Compiler Error: лямбда захватывает слишком много значений", .{});
            try self.emitVoid();
            return;
        }
        const function_id = self.compiler.result.lambda_ids.get(expression) orelse {
            try self.compiler.report(lambda.span, "Compiler Error: не удалось скомпилировать лямбду", .{});
            try self.emitVoid();
            return;
        };
        if (captures.len == 0) {
            try self.emitConstant(.{ .function_ref = function_id });
            return;
        }
        for (captures) |capture| try self.emitSymbolValue(capture, lambda.span);
        try self.function.emit(self.compiler.result.allocator, .{ .build_closure = .{
            .function_id = function_id,
            .capture_count = @intCast(captures.len),
        } });
    }

    fn compileCall(self: *FunctionCompiler, call: anytype) !void {
        if (call.argument_names != null) try self.compiler.report(call.span, "Compiler Error: именованные аргументы пока не поддержаны", .{});
        if (try self.compileCollectionMethod(call)) return;
        if (try self.structConstructor(call.callee)) |structure| {
            for (call.arguments) |argument| try self.compileExpression(argument);
            if (call.arguments.len > std.math.maxInt(u16)) return error.ArgumentLimitReached;
            const name_constant = try self.function.addConstant(self.compiler.result.allocator, .{ .string = try self.compiler.result.program.copyString(structure) });
            try self.function.emit(self.compiler.result.allocator, .{ .build_struct = .{
                .name_constant = name_constant,
                .field_count = @intCast(call.arguments.len),
            } });
            return;
        }
        try self.compileExpression(call.callee);
        for (call.arguments) |argument| try self.compileExpression(argument);
        if (call.arguments.len > std.math.maxInt(u16)) return error.ArgumentLimitReached;
        try self.function.emit(self.compiler.result.allocator, .{ .call = @intCast(call.arguments.len) });
    }

    fn compileCollectionMethod(self: *FunctionCompiler, call: anytype) !bool {
        const property = switch (self.compiler.tree.expr(call.callee).*) {
            .property => |value| value,
            else => return false,
        };
        const object_type = self.compiler.checked.expression_types.get(property.object) orelse return false;
        const type_entry = self.compiler.checked.types.get(object_type) orelse return false;
        const instruction: bytecode.Instruction = switch (type_entry.*) {
            .array => if (std.mem.eql(u8, property.property, "длина") and call.arguments.len == 0)
                .{ .array_length = {} }
            else if (std.mem.eql(u8, property.property, "получить") and call.arguments.len == 2)
                .{ .array_get_or = {} }
            else if (std.mem.eql(u8, property.property, "есть") and call.arguments.len == 1)
                .{ .array_has_index = {} }
            else if (std.mem.eql(u8, property.property, "добавить") and call.arguments.len == 1)
                .{ .array_append = {} }
            else if (std.mem.eql(u8, property.property, "содержит") and call.arguments.len == 1)
                .{ .array_contains = {} }
            else
                return false,
            .map => if (std.mem.eql(u8, property.property, "длина") and call.arguments.len == 0)
                .{ .map_length = {} }
            else if (std.mem.eql(u8, property.property, "получить") and call.arguments.len == 2)
                .{ .map_get_or = {} }
            else if (std.mem.eql(u8, property.property, "записи") and call.arguments.len == 0)
                .{ .map_entries = {} }
            else if (std.mem.eql(u8, property.property, "есть") and call.arguments.len == 1)
                .{ .map_has_key = {} }
            else if (std.mem.eql(u8, property.property, "удалить") and call.arguments.len == 1)
                .{ .map_remove_key = {} }
            else
                return false,
            else => return false,
        };
        try self.compileExpression(property.object);
        for (call.arguments) |argument| try self.compileExpression(argument);
        try self.function.emit(self.compiler.result.allocator, instruction);
        return true;
    }

    fn compileSequence(self: *FunctionCompiler, expressions: []const ast.ExprId, comptime tag: bytecode.Opcode) !void {
        if (expressions.len > std.math.maxInt(u16)) return error.CollectionLimitReached;
        for (expressions) |expression| try self.compileExpression(expression);
        const count: u16 = @intCast(expressions.len);
        try self.function.emit(self.compiler.result.allocator, switch (tag) {
            .build_tuple => .{ .build_tuple = count },
            .build_array => .{ .build_array = count },
            else => unreachable,
        });
    }

    fn compileMap(self: *FunctionCompiler, map: anytype) !void {
        if (map.entries.len > std.math.maxInt(u16)) return error.CollectionLimitReached;
        for (map.entries) |entry| {
            try self.compileExpression(entry.key);
            try self.compileExpression(entry.value);
        }
        try self.function.emit(self.compiler.result.allocator, .{ .build_map = @intCast(map.entries.len) });
    }

    fn compileProperty(self: *FunctionCompiler, property: anytype) !void {
        try self.compileExpression(property.object);
        const field_index = try self.propertyIndex(property.object, property.property);
        if (field_index) |index| {
            try self.function.emit(self.compiler.result.allocator, .{ .get_property = index });
        } else {
            try self.function.emit(self.compiler.result.allocator, .{ .pop = {} });
            try self.unsupportedExpression(property.span);
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
        try self.enterLoop();
        try self.compileBlockStatements(loop.body);
        try self.function.emit(self.compiler.result.allocator, .{ .jump = loop_start });
        const exit_target = self.function.instructions.items.len;
        self.patchJump(exit_jump, exit_target);
        self.leaveLoop(loop_start, exit_target);
        try self.emitVoid();
    }

    fn compileForRange(self: *FunctionCompiler, statement: ast.StmtId, range: anytype) !void {
        const bindings = self.compiler.resolution.stmt_bindings.get(statement) orelse &.{};
        if (bindings.len != 1) {
            try self.compiler.report(range.span, "Compiler Error: диапазон 'для' ожидает одну переменную", .{});
            return;
        }
        const index_slot = try self.ensureLocal(bindings[0]);
        const end_slot = try self.allocateLocal();
        try self.compileExpression(range.start);
        try self.function.emit(self.compiler.result.allocator, .{ .set_local = index_slot });
        try self.compileExpression(range.end);
        try self.function.emit(self.compiler.result.allocator, .{ .set_local = end_slot });

        const loop_start = self.function.instructions.items.len;
        try self.function.emit(self.compiler.result.allocator, .{ .get_local = index_slot });
        try self.function.emit(self.compiler.result.allocator, .{ .get_local = end_slot });
        try self.function.emit(self.compiler.result.allocator, .{ .less_equal = {} });
        const exit_jump = self.function.instructions.items.len;
        try self.function.emit(self.compiler.result.allocator, .{ .jump_if_false = 0 });
        try self.enterLoop();
        try self.compileBlockStatements(range.body);
        const continue_target = self.function.instructions.items.len;
        try self.function.emit(self.compiler.result.allocator, .{ .get_local = index_slot });
        try self.emitConstant(.{ .number = 1 });
        try self.function.emit(self.compiler.result.allocator, .{ .add = {} });
        try self.function.emit(self.compiler.result.allocator, .{ .set_local = index_slot });
        try self.function.emit(self.compiler.result.allocator, .{ .jump = loop_start });
        const exit_target = self.function.instructions.items.len;
        self.patchJump(exit_jump, exit_target);
        self.leaveLoop(continue_target, exit_target);
    }

    fn compileForIn(self: *FunctionCompiler, statement: ast.StmtId, loop: anytype) !void {
        const bindings = self.compiler.resolution.stmt_bindings.get(statement) orelse &.{};
        if (bindings.len == 0) {
            try self.compiler.report(loop.span, "Compiler Error: цикл 'для ... в' ожидает переменную массива", .{});
            return;
        }
        const array_slot = try self.allocateLocal();
        const index_slot = try self.allocateLocal();
        const element_slot = if (bindings.len == 1) try self.ensureLocal(bindings[0]) else try self.allocateLocal();
        try self.compileExpression(loop.iterable);
        try self.function.emit(self.compiler.result.allocator, .{ .set_local = array_slot });
        try self.emitConstant(.{ .number = 0 });
        try self.function.emit(self.compiler.result.allocator, .{ .set_local = index_slot });

        const loop_start = self.function.instructions.items.len;
        try self.function.emit(self.compiler.result.allocator, .{ .get_local = index_slot });
        try self.function.emit(self.compiler.result.allocator, .{ .get_local = array_slot });
        try self.function.emit(self.compiler.result.allocator, .{ .array_length = {} });
        try self.function.emit(self.compiler.result.allocator, .{ .less = {} });
        const exit_jump = self.function.instructions.items.len;
        try self.function.emit(self.compiler.result.allocator, .{ .jump_if_false = 0 });
        try self.function.emit(self.compiler.result.allocator, .{ .get_local = array_slot });
        try self.function.emit(self.compiler.result.allocator, .{ .get_local = index_slot });
        try self.function.emit(self.compiler.result.allocator, .{ .get_index = {} });
        try self.function.emit(self.compiler.result.allocator, .{ .set_local = element_slot });
        if (bindings.len > 1) {
            for (bindings, 0..) |binding, field_index| {
                if (field_index > std.math.maxInt(u16)) {
                    try self.compiler.report(loop.span, "Compiler Error: слишком много элементов деструктуризации", .{});
                    return;
                }
                const slot = try self.ensureLocal(binding);
                try self.function.emit(self.compiler.result.allocator, .{ .get_local = element_slot });
                try self.function.emit(self.compiler.result.allocator, .{ .get_property = @intCast(field_index) });
                try self.function.emit(self.compiler.result.allocator, .{ .set_local = slot });
            }
        }
        try self.enterLoop();
        try self.compileBlockStatements(loop.body);
        const continue_target = self.function.instructions.items.len;
        try self.function.emit(self.compiler.result.allocator, .{ .get_local = index_slot });
        try self.emitConstant(.{ .number = 1 });
        try self.function.emit(self.compiler.result.allocator, .{ .add = {} });
        try self.function.emit(self.compiler.result.allocator, .{ .set_local = index_slot });
        try self.function.emit(self.compiler.result.allocator, .{ .jump = loop_start });
        const exit_target = self.function.instructions.items.len;
        self.patchJump(exit_jump, exit_target);
        self.leaveLoop(continue_target, exit_target);
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

    fn enterLoop(self: *FunctionCompiler) !void {
        try self.loops.append(self.compiler.result.allocator, .{});
    }

    fn leaveLoop(self: *FunctionCompiler, continue_target: usize, break_target: usize) void {
        var loop = self.loops.pop().?;
        defer loop.deinit(self.compiler.result.allocator);
        for (loop.continue_fixups.items) |fixup| self.patchJump(fixup, continue_target);
        for (loop.break_fixups.items) |fixup| self.patchJump(fixup, break_target);
    }

    fn compileLoopControl(self: *FunctionCompiler, span: source.Span, is_continue: bool) !void {
        if (self.loops.items.len == 0) {
            try self.compiler.report(span, "Compiler Error: управление циклом использовано вне цикла", .{});
            return;
        }
        const jump = self.function.instructions.items.len;
        try self.function.emit(self.compiler.result.allocator, .{ .jump = 0 });
        const loop = &self.loops.items[self.loops.items.len - 1];
        if (is_continue) {
            try loop.continue_fixups.append(self.compiler.result.allocator, jump);
        } else {
            try loop.break_fixups.append(self.compiler.result.allocator, jump);
        }
    }

    fn compileIdentifier(self: *FunctionCompiler, expression: ast.ExprId) !void {
        const symbol = self.compiler.resolution.expr_symbols.get(expression) orelse return self.unsupportedExpression(expressionSpan(self.compiler.tree, expression));
        try self.emitSymbolValue(symbol, expressionSpan(self.compiler.tree, expression));
    }

    fn emitSymbolValue(self: *FunctionCompiler, symbol: symbols.SymbolId, span: source.Span) !void {
        if (self.locals.get(symbol)) |slot| {
            try self.function.emit(self.compiler.result.allocator, .{ .get_local = slot });
            return;
        }
        if (self.compiler.result.function_ids.get(symbol)) |function_id| {
            try self.emitConstant(.{ .function_ref = function_id });
            return;
        }
        try self.unsupportedExpression(span);
    }

    fn compileBinary(self: *FunctionCompiler, binary: anytype) anyerror!void {
        if (binary.operator == .assign) {
            try self.compileAssignment(binary);
            return;
        }
        if (binary.operator == .and_expr) {
            try self.compileLogicalAnd(binary);
            return;
        }
        if (binary.operator == .or_expr) {
            try self.compileLogicalOr(binary);
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

    fn compileLogicalAnd(self: *FunctionCompiler, binary: anytype) !void {
        try self.compileExpression(binary.left);
        const false_jump = self.function.instructions.items.len;
        try self.function.emit(self.compiler.result.allocator, .{ .jump_if_false = 0 });
        try self.compileExpression(binary.right);
        const end_jump = self.function.instructions.items.len;
        try self.function.emit(self.compiler.result.allocator, .{ .jump = 0 });
        self.patchJump(false_jump, self.function.instructions.items.len);
        try self.emitConstant(.{ .boolean = false });
        self.patchJump(end_jump, self.function.instructions.items.len);
    }

    fn compileLogicalOr(self: *FunctionCompiler, binary: anytype) !void {
        try self.compileExpression(binary.left);
        const false_jump = self.function.instructions.items.len;
        try self.function.emit(self.compiler.result.allocator, .{ .jump_if_false = 0 });
        try self.emitConstant(.{ .boolean = true });
        const end_jump = self.function.instructions.items.len;
        try self.function.emit(self.compiler.result.allocator, .{ .jump = 0 });
        self.patchJump(false_jump, self.function.instructions.items.len);
        try self.compileExpression(binary.right);
        self.patchJump(end_jump, self.function.instructions.items.len);
    }

    fn compileAssignment(self: *FunctionCompiler, binary: anytype) anyerror!void {
        switch (self.compiler.tree.expr(binary.left).*) {
            .ident => {
                const symbol = self.compiler.resolution.expr_symbols.get(binary.left) orelse return self.unsupportedExpression(binary.span);
                const slot = self.locals.get(symbol) orelse return self.unsupportedExpression(binary.span);
                try self.compileExpression(binary.right);
                try self.function.emit(self.compiler.result.allocator, .{ .set_local = slot });
                try self.emitVoid();
            },
            .index => |index| {
                try self.compileExpression(index.object);
                try self.compileExpression(index.index);
                try self.compileExpression(binary.right);
                try self.function.emit(self.compiler.result.allocator, .{ .set_index = {} });
                try self.emitVoid();
            },
            .property => |property| {
                const field_index = try self.propertyIndex(property.object, property.property) orelse return self.unsupportedExpression(binary.span);
                try self.compileExpression(property.object);
                try self.compileExpression(binary.right);
                try self.function.emit(self.compiler.result.allocator, .{ .set_property = field_index });
                try self.emitVoid();
            },
            else => try self.unsupportedExpression(binary.span),
        }
    }

    fn structConstructor(self: *const FunctionCompiler, callee: ast.ExprId) !?[]const u8 {
        const callee_type = self.compiler.checked.expression_types.get(callee) orelse return null;
        const type_entry = self.compiler.checked.types.get(callee_type) orelse return null;
        const nominal = switch (type_entry.*) {
            .nominal => |value| value,
            else => return null,
        };
        if (!self.compiler.checked.nominal_fields.contains(nominal.symbol)) return null;
        const symbol = self.compiler.resolution.symbols.get(nominal.symbol) orelse return null;
        return symbol.name;
    }

    fn propertyIndex(self: *FunctionCompiler, object: ast.ExprId, property: []const u8) !?u16 {
        const object_type = self.compiler.checked.expression_types.get(object) orelse return null;
        const type_entry = self.compiler.checked.types.get(object_type) orelse return null;
        switch (type_entry.*) {
            .tuple => |elements| {
                const index = std.fmt.parseInt(usize, property, 10) catch return null;
                if (index >= elements.len or index > std.math.maxInt(u16)) return null;
                return @intCast(index);
            },
            else => {},
        }
        const nominal = switch (type_entry.*) {
            .nominal => |value| value,
            else => return null,
        };
        const fields = self.compiler.checked.nominal_fields.get(nominal.symbol) orelse return null;
        for (fields, 0..) |field, index| {
            if (!std.mem.eql(u8, field.name, property)) continue;
            if (index > std.math.maxInt(u16)) return error.FieldLimitReached;
            return @intCast(index);
        }
        return null;
    }

    fn destructureFieldIndex(self: *FunctionCompiler, let: anytype, index: usize) !?u16 {
        if (let.destructure_field_names) |names| {
            if (index >= names.len) return null;
            return self.propertyIndex(let.value, names[index]);
        }
        if (index > std.math.maxInt(u16)) return null;
        return @intCast(index);
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
    try compiler.predeclareLambdas();
    try compiler.compileFunctions();
    try compiler.compileLambdas();
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

test "compiler emits structures and collections" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип Точка = структура\nx: Число\ny: Число\nконец\nфунк получить() -> Число\nпер точка = Точка(3, 4)\nпер числа = массив(точка.x, 2)\nпер цены = соответствие(\"x\" = числа[0])\nцены[\"x\"]\nконец", 0);
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
    const function = compiled.program.functions.items[0];
    var has_struct = false;
    var has_array = false;
    var has_map = false;
    var index_reads: usize = 0;
    for (function.instructions.items) |instruction| {
        switch (instruction) {
            .build_struct => has_struct = true,
            .build_array => has_array = true,
            .build_map => has_map = true,
            .get_index => index_reads += 1,
            else => {},
        }
    }
    try std.testing.expect(has_struct);
    try std.testing.expect(has_array);
    try std.testing.expect(has_map);
    try std.testing.expectEqual(@as(usize, 2), index_reads);
}

test "compiler emits property and index assignments" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип Точка = структура\nx: Число\nконец\nфунк обновить() -> Число\nпер точка = Точка(1)\nточка.x = 2\nпер числа = массив(3)\nчисла[0] = 4\nточка.x + числа[0]\nконец", 0);
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
    const function = compiled.program.functions.items[0];
    var has_set_property = false;
    var has_set_index = false;
    for (function.instructions.items) |instruction| {
        switch (instruction) {
            .set_property => has_set_property = true,
            .set_index => has_set_index = true,
            else => {},
        }
    }
    try std.testing.expect(has_set_property);
    try std.testing.expect(has_set_index);
}

test "compiler emits closures for captured lambdas" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ старт() -> Число\nпер сдвиг = 2\nпер добавить: функ(Число) -> Число = функ(значение)\nзначение + сдвиг\nконец\nдобавить(3)\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    var compiled = try compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(u16, 1), compiled.program.functions.items[1].capture_count);
    try std.testing.expectEqual(bytecode.Instruction{ .build_closure = .{ .function_id = @enumFromInt(1), .capture_count = 1 } }, compiled.program.functions.items[0].instructions.items[3]);
}
