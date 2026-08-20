const std = @import("std");
const ast = @import("ast.zig");
const bytecode = @import("bytecode.zig");
const diagnostic = @import("diagnostic.zig");
const resolver = @import("resolver.zig");
const source = @import("source.zig");
const symbols = @import("symbols.zig");
const type_checker = @import("type_checker.zig");
const types = @import("types.zig");

pub const CompileResult = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    program: bytecode.Program,
    shared_program: ?*bytecode.Program = null,
    diagnostics: diagnostic.DiagnosticList = .{},
    function_ids: std.AutoHashMap(symbols.SymbolId, bytecode.FunctionId),
    lambda_ids: std.AutoHashMap(ast.ExprId, bytecode.FunctionId),
    top_level_constants: std.AutoHashMap(symbols.SymbolId, bytecode.Constant),

    pub fn init(allocator: std.mem.Allocator) CompileResult {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .program = bytecode.Program.init(allocator),
            .function_ids = .init(allocator),
            .lambda_ids = .init(allocator),
            .top_level_constants = .init(allocator),
        };
    }

    fn activeProgram(self: *CompileResult) *bytecode.Program {
        return self.shared_program orelse &self.program;
    }

    pub fn deinit(self: *CompileResult) void {
        self.top_level_constants.deinit();
        self.lambda_ids.deinit();
        self.function_ids.deinit();
        self.diagnostics.deinit(self.allocator);
        self.program.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const ImportedFunction = struct {
    symbol: symbols.SymbolId,
    function_id: bytecode.FunctionId,
};

pub const ImportedConstant = struct {
    symbol: symbols.SymbolId,
    value: bytecode.Constant,
};

pub const CompileOptions = struct {
    program: ?*bytecode.Program = null,
    functions: []const ImportedFunction = &.{},
    constants: []const ImportedConstant = &.{},
};

const Compiler = struct {
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    checked: *const type_checker.CheckResult,
    result: *CompileResult,

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
        };
    }

    fn deinit(self: *Compiler) void {
        self.* = undefined;
    }

    fn program(self: *Compiler) *bytecode.Program {
        return self.result.activeProgram();
    }

    fn report(self: *Compiler, span: source.Span, comptime format: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.result.arena.allocator(), format, args);
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
                .interface_decl => |interface| for (interface.default_methods) |method| {
                    const function = self.tree.decl(method).function;
                    try self.predeclareFunction(method, function.name, function.parameters.len);
                    const symbol = self.resolution.decl_symbols.get(method) orelse continue;
                    const function_id = self.result.function_ids.get(symbol) orelse continue;
                    if (self.program().function(function_id)) |compiled| compiled.is_default_interface_method = true;
                },
                else => {},
            }
        }
    }

    fn predeclareConstants(self: *Compiler) !void {
        for (self.tree.program.?.declarations) |declaration| {
            const constant = switch (self.tree.decl(declaration).*) {
                .constant => |value| value,
                else => continue,
            };
            const symbol = self.resolution.decl_symbols.get(declaration) orelse continue;
            const value = try self.topLevelConstant(constant.value) orelse {
                try self.report(constant.span, "Compiler Error: константа верхнего уровня должна быть литералом", .{});
                continue;
            };
            try self.result.top_level_constants.put(symbol, value);
        }
    }

    fn topLevelConstant(self: *Compiler, expression: ast.ExprId) !?bytecode.Constant {
        return switch (self.tree.expr(expression).*) {
            .number => |number| .{ .number = number.value },
            .boolean => |boolean| .{ .boolean = boolean.value },
            .string => |string| .{ .string = try self.program().copyString(string.value) },
            .unary => |unary| if (unary.operator == .minus) switch (self.tree.expr(unary.operand).*) {
                .number => |number| .{ .number = -number.value },
                else => null,
            } else null,
            else => null,
        };
    }

    fn predeclareFunction(self: *Compiler, declaration: ast.DeclId, name: []const u8, parameter_count: usize) !void {
        const symbol = self.resolution.decl_symbols.get(declaration) orelse return;
        if (parameter_count > std.math.maxInt(u16)) {
            try self.report(self.tree.decl(declaration).function.span, "Compiler Error: слишком много параметров функции", .{});
            return;
        }
        const function_id = try self.program().addFunction(name, @intCast(parameter_count));
        try self.result.function_ids.put(symbol, function_id);
    }

    fn compileFunctions(self: *Compiler) !void {
        for (self.tree.program.?.declarations) |declaration| {
            switch (self.tree.decl(declaration).*) {
                .function => try self.compileFunction(declaration),
                .impl => |implementation| for (implementation.methods) |method| try self.compileFunction(method),
                .interface_decl => |interface| for (interface.default_methods) |method| try self.compileFunction(method),
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
            const function_id = try self.program().addFunction("лямбда", @intCast(lambda.parameters.len));
            try self.result.lambda_ids.put(expression_id, function_id);
        }
    }

    // Общий код для `registerComparableMethods`/`registerCopyableMethods` —
    // оба сканируют реализации интерфейса с одним методом по имени и
    // регистрируют скомпилированный метод под именем целевой структуры,
    // различаясь только тем, какой интерфейс ищут и в какую таблицу
    // `Program.add*` пишут результат. `отправить` использует copyable-таблицу,
    // чтобы найти пользовательский `клонировать()` по имени структуры
    // сообщения в рантайме (см. `send` в `vm.zig`) — так реализуется
    // copy-on-send.
    fn registerSingleMethodInterface(self: *Compiler, interface_name: []const u8, register: *const fn (*bytecode.Program, []const u8, bytecode.FunctionId) std.mem.Allocator.Error!void) !void {
        for (self.checked.interface_implementations.items) |implementation| {
            const interface = self.resolution.symbols.get(implementation.interface) orelse continue;
            if (!std.mem.eql(u8, interface.name, interface_name)) continue;
            const target = self.resolution.symbols.get(implementation.target) orelse continue;
            const method_symbol = implementation.methods[0];
            const method = self.result.function_ids.get(method_symbol) orelse continue;
            try register(self.program(), target.name, method);
        }
    }

    // Заполняет `Program.interface_methods` — резервный (interface_name,
    // method_name, type_name) -> FunctionId путь диспетчеризации
    // `call_interface` для значений, вошедших в generic-область БЕЗ
    // Cast_Interface-обёртки (например, поле generic-типизированной
    // структуры/перечисления, построенное СНАРУЖИ generic-контекста и
    // никогда не прошедшее ни через один из известных compile-time
    // cast-injection путей — `registerInterfaceCast`/
    // `registerGenericInterfaceCasts`/`registerNestedFunctionReturnInterfaceCasts`
    // в type_checker.zig). В отличие от `registerSingleMethodInterface`
    // выше (один-единственный жёстко заданный интерфейс, `methods[0]`),
    // здесь регистрируются ВСЕ методы ВСЕХ `реализация Интерфейс для Т` —
    // общий, не завязанный на конкретный интерфейс, аналог того же
    // приёма, что уже проверен в бою на Сравниваемое/Копируемое.
    fn registerInterfaceMethods(self: *Compiler) !void {
        for (self.checked.interface_implementations.items) |implementation| {
            const interface = self.resolution.symbols.get(implementation.interface) orelse continue;
            const target = self.resolution.symbols.get(implementation.target) orelse continue;
            for (implementation.methods) |method_symbol| {
                const method_entry = self.resolution.symbols.get(method_symbol) orelse continue;
                const function_id = self.result.function_ids.get(method_symbol) orelse continue;
                try self.program().addInterfaceMethod(interface.name, method_entry.name, target.name, function_id);
            }
        }
    }

    fn registerComparableMethods(self: *Compiler) !void {
        try self.registerSingleMethodInterface("Сравниваемое", bytecode.Program.addComparableMethod);
    }

    fn registerCopyableMethods(self: *Compiler) !void {
        try self.registerSingleMethodInterface("Копируемое", bytecode.Program.addCopyableMethod);
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
            const compiled = self.program().function(function_id) orelse continue;
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
        const compiled = self.program().function(function_id) orelse return;
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
                } else if (bindings.len == 1 and let.destructure_type == null) {
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
                const return_value = return_statement.value orelse {
                    try self.function.emit(self.compiler.result.allocator, .{ .return_void = {} });
                    break :blk false;
                };
                try self.compileExpression(return_value);
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
            .string => |string| try self.emitConstant(.{ .string = try self.compiler.program().copyString(string.value) }),
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
            .cast => |cast| {
                try self.compileExpression(cast.operand);
                const cast_type = self.compiler.checked.expression_types.get(expression) orelse return;
                if (self.compiler.checked.types.eql(cast_type, self.compiler.checked.types.builtins.integer)) {
                    try self.function.emit(self.compiler.result.allocator, .{ .int_cast = {} });
                }
            },
            .binary => |binary| try self.compileBinary(binary),
            .call => |call| try self.compileCall(expression, call),
            .tuple => |tuple| try self.compileSequence(tuple.elements, .build_tuple),
            .array => |array| try self.compileSequence(array.elements, .build_array),
            .map => |map| try self.compileMap(map),
            .lambda => |lambda| try self.compileLambda(expression, lambda),
            .index => |index| {
                try self.compileExpression(index.object);
                try self.compileExpression(index.index);
                try self.function.emit(self.compiler.result.allocator, .{ .get_index = {} });
            },
            .property => |property| try self.compileProperty(expression, property),
            .if_expr => |conditional| try self.compileIf(conditional),
            .while_expr => |loop| try self.compileWhile(loop),
            .spawn => |spawn| try self.compileSpawn(spawn),
            .try_expr => |try_expression| try self.compileTry(try_expression),
            .match_expr => |match| try self.compileMatch(match),
            .select_wait => |select| {
                try self.compileExpression(select.source);
                try self.function.emit(self.compiler.result.allocator, .{ .select_wait = {} });
            },
            else => try self.unsupportedExpression(expressionSpan(self.compiler.tree, expression)),
        }
        try self.emitInterfaceCast(expression);
    }

    fn emitInterfaceCast(self: *FunctionCompiler, expression: ast.ExprId) !void {
        const cast = self.compiler.checked.interface_casts.get(expression) orelse return;
        var vtables: std.ArrayList([]const bytecode.FunctionId) = .empty;
        defer vtables.deinit(self.compiler.result.allocator);
        for (cast.entries) |entry| {
            // Переиспользует `type_checker.findInterfaceImplementation`
            // (сначала точное совпадение `.arguments` — корректно выбирает
            // между ДВУМЯ блоками `реализация` для ОДНОЙ пары
            // (интерфейс, цель) с разными аргументами, например
            // `реализация Получатель(Число) для Пара` и
            // `реализация Получатель(Строка) для Пара`; откатывается к
            // сопоставлению по generic-паттерну через `entry.target_arguments`
            // только если цель сама generic и точное совпадение не найдено),
            // а не независимую копию той же логики сопоставления.
            // Используется выходной параметр `ambiguous` — в отличие от
            // спекулятивных булевых вызовов той же функции в `assignable`,
            // здесь выбор неверного кандидата означает компиляцию неверной
            // vtable в рантайме, а не просто неверный статический тип,
            // поэтому наличие второго подходящего кандидата — это жёсткая
            // ошибка, а не выбор первого попавшегося.
            var ambiguous = false;
            const implementation = type_checker.findInterfaceImplementation(
                self.compiler.checked,
                entry.interface,
                entry.arguments,
                entry.target,
                entry.target_arguments,
                &ambiguous,
            ) orelse {
                try self.compiler.report(expressionSpan(self.compiler.tree, expression), "Compiler Error: не удалось найти реализацию интерфейса", .{});
                return;
            };
            if (ambiguous) {
                try self.compiler.report(expressionSpan(self.compiler.tree, expression), "Compiler Error: неоднозначная реализация интерфейса — несколько подходящих 'реализация' блоков", .{});
                return;
            }
            const methods = try self.compiler.program().arena.allocator().alloc(bytecode.FunctionId, implementation.methods.len);
            for (implementation.methods, methods) |method, *function_id| {
                function_id.* = self.compiler.result.function_ids.get(method) orelse {
                    try self.compiler.report(expressionSpan(self.compiler.tree, expression), "Compiler Error: не удалось найти метод интерфейса", .{});
                    return;
                };
            }
            try vtables.append(self.compiler.result.allocator, methods);
        }
        const constant = try self.function.addConstant(self.compiler.result.allocator, .{ .interface_vtables = try self.compiler.program().arena.allocator().dupe([]const bytecode.FunctionId, vtables.items) });
        try self.function.emit(self.compiler.result.allocator, .{ .cast_interface = constant });
    }

    fn compileTry(self: *FunctionCompiler, try_expression: anytype) !void {
        const value_type = self.compiler.checked.expression_types.get(try_expression.value) orelse return self.unsupportedExpression(try_expression.span);
        const value_entry = self.compiler.checked.types.get(value_type) orelse return self.unsupportedExpression(try_expression.span);
        const nominal = switch (value_entry.*) {
            .nominal => |value| value,
            else => return self.unsupportedExpression(try_expression.span),
        };
        const owner = self.compiler.resolution.symbols.get(nominal.symbol) orelse return self.unsupportedExpression(try_expression.span);
        const success_variant = if (std.mem.eql(u8, owner.name, "Опция"))
            "Опция.Есть"
        else if (std.mem.eql(u8, owner.name, "Результат"))
            "Результат.Успех"
        else
            return self.unsupportedExpression(try_expression.span);
        const object_slot = try self.allocateLocal();
        try self.compileExpression(try_expression.value);
        try self.function.emit(self.compiler.result.allocator, .{ .set_local = object_slot });
        try self.function.emit(self.compiler.result.allocator, .{ .get_local = object_slot });
        try self.emitEnumMatch(success_variant);
        const return_jump = self.function.instructions.items.len;
        try self.function.emit(self.compiler.result.allocator, .{ .jump_if_false = 0 });
        try self.function.emit(self.compiler.result.allocator, .{ .get_local = object_slot });
        try self.function.emit(self.compiler.result.allocator, .{ .get_property = 0 });
        const end_jump = self.function.instructions.items.len;
        try self.function.emit(self.compiler.result.allocator, .{ .jump = 0 });
        self.patchJump(return_jump, self.function.instructions.items.len);
        try self.function.emit(self.compiler.result.allocator, .{ .get_local = object_slot });
        try self.function.emit(self.compiler.result.allocator, .{ .return_value = {} });
        self.patchJump(end_jump, self.function.instructions.items.len);
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

    fn compileCall(self: *FunctionCompiler, expression: ast.ExprId, call: anytype) !void {
        const ordered_arguments = self.compiler.checked.call_arguments.get(expression);
        if (call.argument_names != null and ordered_arguments == null) {
            try self.compiler.report(call.span, "Compiler Error: именованные аргументы не поддержаны для этого вызова", .{});
            try self.emitVoid();
            return;
        }
        const arguments = ordered_arguments orelse call.arguments;
        if (try self.compileErrorConstructor(call)) return;
        if (try self.compilePanicBuiltin(call)) return;
        if (try self.compileToDisplayStringBuiltin(call)) return;
        if (try self.compileFilesystemBuiltin(call)) return;
        if (try self.compileOsBuiltin(call)) return;
        if (try self.compileTimeBuiltin(call)) return;
        if (try self.compileDomBuiltin(call)) return;
        if (try self.compileStateBuiltin(call)) return;
        if (try self.compileIoBuiltin(call)) return;
        if (try self.compileStringBuiltin(call)) return;
        if (try self.compileCompressBuiltin(call)) return;
        if (try self.compileSyntaxBuiltin(call)) return;
        if (try self.compileNetBuiltin(call)) return;
        if (try self.compileSqlBuiltin(call)) return;
        if (try self.compileCryptoBuiltin(call)) return;
        if (try self.compileForeignCall(call)) return;
        if (try self.compileProcessBuiltin(call)) return;
        if (try self.compileLengthBuiltin(call)) return;
        if (try self.compileCollectionMethod(call)) return;
        if (try self.compilePreludeEnumMethod(call)) return;
        if (try self.compileProcessMethod(call)) return;
        if (self.compiler.checked.interface_calls.get(expression)) |interface_call| {
            const property = switch (self.compiler.tree.expr(call.callee).*) {
                .property => |value| value,
                else => return self.unsupportedExpression(call.span),
            };
            try self.compileExpression(property.object);
            for (call.arguments) |argument| try self.compileExpression(argument);
            const interface_name = if (self.compiler.resolution.symbols.get(interface_call.interface)) |symbol| symbol.name else "";
            const method_name = blk: {
                const definition = self.compiler.checked.interface_definitions.get(interface_call.interface) orelse break :blk "";
                if (interface_call.method_index >= definition.methods.len) break :blk "";
                break :blk definition.methods[interface_call.method_index].name;
            };
            try self.function.emit(self.compiler.result.allocator, .{ .call_interface = .{
                .method_index = interface_call.method_index,
                .vtable_index = interface_call.vtable_index,
                .argument_count = @intCast(call.arguments.len),
                .interface_name = interface_name,
                .method_name = method_name,
            } });
            return;
        }
        if (self.compiler.checked.method_calls.get(expression)) |method| {
            // `о.метод[Тип](...)` — callee `Index{object: Property{...}}`,
            // не голый `Property` (явные generic-аргументы метода, см.
            // одноимённую ветку в type_checker.zig's `inferCall`) —
            // настоящий property-узел лежит на один уровень глубже.
            const property = switch (self.compiler.tree.expr(call.callee).*) {
                .property => |value| value,
                .index => |index| switch (self.compiler.tree.expr(index.object).*) {
                    .property => |value| value,
                    else => return self.unsupportedExpression(call.span),
                },
                else => return self.unsupportedExpression(call.span),
            };
            const function_id = self.compiler.result.function_ids.get(method) orelse {
                try self.compiler.report(call.span, "Compiler Error: не удалось найти метод", .{});
                return self.emitVoid();
            };
            try self.emitConstant(.{ .function_ref = function_id });
            try self.compileExpression(property.object);
            for (arguments) |argument| try self.compileExpression(argument);
            if (arguments.len == std.math.maxInt(u16)) return error.ArgumentLimitReached;
            try self.function.emit(self.compiler.result.allocator, .{ .call = @intCast(arguments.len + 1) });
            return;
        }
        if (try self.enumConstructor(call.callee)) |enumeration| {
            // Используется `arguments` (возможно, переупорядоченный по
            // именам, см. `ordered_arguments` выше), а НЕ сырой
            // `call.arguments` — иначе для конструктора enum-варианта,
            // вызванного с именованными аргументами не в порядке
            // объявления полей, значения попадут не в те поля структуры
            // в рантайме, несмотря на то что тайпчекер уже проверил
            // переупорядоченный список.
            for (arguments) |argument| try self.compileExpression(argument);
            if (arguments.len > std.math.maxInt(u16)) return error.ArgumentLimitReached;
            const name_constant = try self.function.addConstant(self.compiler.result.allocator, .{ .string = try self.compiler.program().copyString(enumeration) });
            try self.function.emit(self.compiler.result.allocator, .{ .build_struct = .{
                .name_constant = name_constant,
                .field_count = @intCast(arguments.len),
            } });
            return;
        }
        if (try self.structConstructor(call.callee)) |structure| {
            // То же самое, что и для enum-варианта выше: тайпчекер уже
            // переупорядочивает аргументы через
            // `reorderNamedArguments`/`call_arguments`, поэтому здесь
            // тоже нужен переупорядоченный `arguments`, а не сырой
            // `call.arguments` в порядке вызова — иначе значения
            // раскладываются по ОБЪЯВЛЕННОМУ порядку полей структуры и
            // попадают не в те слоты в рантайме.
            for (arguments) |argument| try self.compileExpression(argument);
            if (arguments.len > std.math.maxInt(u16)) return error.ArgumentLimitReached;
            const name_constant = try self.function.addConstant(self.compiler.result.allocator, .{ .string = try self.compiler.program().copyString(structure) });
            try self.function.emit(self.compiler.result.allocator, .{ .build_struct = .{
                .name_constant = name_constant,
                .field_count = @intCast(arguments.len),
            } });
            return;
        }
        try self.compileExpression(self.explicitGenericCallCallee(call.callee));
        for (arguments) |argument| try self.compileExpression(argument);
        if (arguments.len > std.math.maxInt(u16)) return error.ArgumentLimitReached;
        try self.function.emit(self.compiler.result.allocator, .{ .call = @intCast(arguments.len) });
    }

    // `ф[Тип](...)` — явный generic-аргумент вызова — парсится как
    // `Call_Expr{ callee: Index_Expr{ object, index } }`, точно так же,
    // как "индексация массива функций с последующим вызовом результата".
    // Тайпчекер переинтерпретирует это в `inferCallExpected`, когда
    // `index.object` резолвится в generic-функцию, но кодогенерация
    // обходит то же самое сырое AST независимо и иначе попыталась бы
    // скомпилировать `index.index` (имя типа, существующее только на
    // этапе компиляции, например `Число`) как обычный операнд индексации
    // в рантайме. Дженерики паноса никогда не мономорфизируются
    // (специализации под конкретный call site не существует), поэтому
    // явный аргумент типа не несёт никакой информации в рантайме —
    // кодогенерации достаточно перейти сразу к `index.object`, зеркально
    // повторяя определение `effective_callee` в тайпчекере. Для любой
    // другой формы (обычные вызовы и настоящая индексация-с-вызовом
    // не-generic значения) `callee` возвращается без изменений.
    fn explicitGenericCallCallee(self: *FunctionCompiler, callee: ast.ExprId) ast.ExprId {
        const index = switch (self.compiler.tree.expr(callee).*) {
            .index => |value| value,
            else => return callee,
        };
        const object_symbol = self.compiler.resolution.expr_symbols.get(index.object) orelse return callee;
        const generic_parameters = self.compiler.checked.generic_function_parameters.get(object_symbol) orelse &.{};
        if (generic_parameters.len == 0) return callee;
        return index.object;
    }

    fn compileErrorConstructor(self: *FunctionCompiler, call: anytype) !bool {
        if (call.arguments.len != 2) return false;
        const symbol = self.compiler.resolution.expr_symbols.get(call.callee) orelse return false;
        const entry = self.compiler.resolution.symbols.get(symbol) orelse return false;
        if (entry.kind != .builtin or !std.mem.eql(u8, entry.name, "Ошибка")) return false;
        for (call.arguments) |argument| try self.compileExpression(argument);
        const name_constant = try self.function.addConstant(self.compiler.result.allocator, .{ .string = try self.compiler.program().copyString("Ошибка") });
        try self.function.emit(self.compiler.result.allocator, .{ .build_struct = .{
            .name_constant = name_constant,
            .field_count = 2,
        } });
        return true;
    }

    // `встроку(x)` — интерполяция строк (`"\(expr)"`) разворачивается
    // в этот вызов ещё на этапе парсинга (`parser.zig`). Переиспользует
    // `renderRuntimeValue` из `vm.zig` (уже используется для
    // `ввод_вывод.печать`/`.строка`) — то же самое преобразование
    // "значение любого типа → строка для отображения", которое
    // документация обещает для `\( )`-интерполяции.
    fn compileToDisplayStringBuiltin(self: *FunctionCompiler, call: anytype) !bool {
        const symbol = self.compiler.resolution.expr_symbols.get(call.callee) orelse return false;
        const entry = self.compiler.resolution.symbols.get(symbol) orelse return false;
        if (entry.kind != .builtin or entry.module_path != null or !std.mem.eql(u8, entry.name, "встроку")) return false;
        if (call.arguments.len != 1) {
            try self.compiler.report(call.span, "Compiler Error: встроку(x) ожидает 1 аргумент", .{});
            try self.emitVoid();
            return true;
        }
        try self.compileExpression(call.arguments[0]);
        try self.function.emit(self.compiler.result.allocator, .{ .to_display_string = {} });
        return true;
    }

    fn compilePanicBuiltin(self: *FunctionCompiler, call: anytype) !bool {
        const symbol = self.compiler.resolution.expr_symbols.get(call.callee) orelse return false;
        const entry = self.compiler.resolution.symbols.get(symbol) orelse return false;
        if (entry.kind != .builtin or !std.mem.eql(u8, entry.name, "паника")) return false;
        if (call.arguments.len != 1) {
            try self.compiler.report(call.span, "Compiler Error: паника ожидает 1 аргумент", .{});
            try self.emitVoid();
            return true;
        }
        try self.compileExpression(call.arguments[0]);
        try self.function.emit(self.compiler.result.allocator, .{ .panic = {} });
        return true;
    }

    fn compileFilesystemBuiltin(self: *FunctionCompiler, call: anytype) !bool {
        const property = switch (self.compiler.tree.expr(call.callee).*) {
            .property => |value| value,
            else => return false,
        };
        const symbol = self.compiler.resolution.expr_symbols.get(call.callee) orelse return false;
        const entry = self.compiler.resolution.symbols.get(symbol) orelse return false;
        if (entry.kind != .builtin or entry.module_path == null or !std.mem.eql(u8, entry.module_path.?, "фс")) return false;
        if (call.arguments.len == 1 and std.mem.eql(u8, property.property, "есть")) {
            try self.compileExpression(call.arguments[0]);
            try self.function.emit(self.compiler.result.allocator, .{ .file_exists = {} });
            return true;
        }
        if (call.arguments.len == 1 and std.mem.eql(u8, property.property, "удалить")) {
            try self.compileExpression(call.arguments[0]);
            try self.function.emit(self.compiler.result.allocator, .{ .file_delete = {} });
            return true;
        }
        if (call.arguments.len == 1 and std.mem.eql(u8, property.property, "прочитать")) {
            try self.compileExpression(call.arguments[0]);
            // Неблокирующий I/O: submit кладёт задачу в воркер-пул и
            // возвращает управление немедленно, await_async — единственная
            // точка настоящей приостановки процесса (см. bytecode.zig).
            try self.function.emit(self.compiler.result.allocator, .{ .file_read_submit = {} });
            try self.function.emit(self.compiler.result.allocator, .{ .await_async = {} });
            return true;
        }
        if (call.arguments.len == 2 and std.mem.eql(u8, property.property, "записать")) {
            try self.compileExpression(call.arguments[0]);
            try self.compileExpression(call.arguments[1]);
            try self.function.emit(self.compiler.result.allocator, .{ .file_write_submit = {} });
            try self.function.emit(self.compiler.result.allocator, .{ .await_async = {} });
            return true;
        }
        if (call.arguments.len == 1 and std.mem.eql(u8, property.property, "открыть")) {
            try self.compileExpression(call.arguments[0]);
            try self.function.emit(self.compiler.result.allocator, .{ .file_open = {} });
            return true;
        }
        if (call.arguments.len == 1 and std.mem.eql(u8, property.property, "это_директория")) {
            try self.compileExpression(call.arguments[0]);
            try self.function.emit(self.compiler.result.allocator, .{ .dir_is_dir = {} });
            return true;
        }
        if (call.arguments.len == 1 and std.mem.eql(u8, property.property, "создать_директорию")) {
            try self.compileExpression(call.arguments[0]);
            try self.function.emit(self.compiler.result.allocator, .{ .dir_create = {} });
            return true;
        }
        if (call.arguments.len == 1 and std.mem.eql(u8, property.property, "список_директории")) {
            try self.compileExpression(call.arguments[0]);
            try self.function.emit(self.compiler.result.allocator, .{ .dir_list = {} });
            return true;
        }
        if (call.arguments.len == 1 and std.mem.eql(u8, property.property, "удалить_директорию")) {
            try self.compileExpression(call.arguments[0]);
            try self.function.emit(self.compiler.result.allocator, .{ .dir_delete = {} });
            return true;
        }
        return false;
    }

    fn compileOsBuiltin(self: *FunctionCompiler, call: anytype) !bool {
        const property = switch (self.compiler.tree.expr(call.callee).*) {
            .property => |value| value,
            else => return false,
        };
        const symbol = self.compiler.resolution.expr_symbols.get(call.callee) orelse return false;
        const entry = self.compiler.resolution.symbols.get(symbol) orelse return false;
        if (entry.kind != .builtin or entry.module_path == null or !std.mem.eql(u8, entry.module_path.?, "ос")) return false;
        if (call.arguments.len == 0 and std.mem.eql(u8, property.property, "аргументы")) {
            try self.function.emit(self.compiler.result.allocator, .{ .os_args = {} });
            return true;
        }
        if (call.arguments.len == 0 and std.mem.eql(u8, property.property, "версия_паноса")) {
            try self.function.emit(self.compiler.result.allocator, .{ .os_version = {} });
            return true;
        }
        if (call.arguments.len == 1 and std.mem.eql(u8, property.property, "окружение")) {
            try self.compileExpression(call.arguments[0]);
            try self.function.emit(self.compiler.result.allocator, .{ .os_env_get = {} });
            return true;
        }
        if (call.arguments.len == 2 and std.mem.eql(u8, property.property, "установить_окружение")) {
            try self.compileExpression(call.arguments[0]);
            try self.compileExpression(call.arguments[1]);
            try self.function.emit(self.compiler.result.allocator, .{ .os_env_set = {} });
            return true;
        }
        if (call.arguments.len == 1 and std.mem.eql(u8, property.property, "удалить_окружение")) {
            try self.compileExpression(call.arguments[0]);
            try self.function.emit(self.compiler.result.allocator, .{ .os_env_unset = {} });
            return true;
        }
        if (call.arguments.len == 3 and std.mem.eql(u8, property.property, "выполнить")) {
            try self.compileExpression(call.arguments[0]);
            try self.compileExpression(call.arguments[1]);
            try self.compileExpression(call.arguments[2]);
            try self.function.emit(self.compiler.result.allocator, .{ .os_exec = {} });
            return true;
        }
        if (call.arguments.len == 1 and std.mem.eql(u8, property.property, "завершить")) {
            try self.compileExpression(call.arguments[0]);
            try self.function.emit(self.compiler.result.allocator, .{ .os_exit = {} });
            return true;
        }
        return false;
    }

    fn compileTimeBuiltin(self: *FunctionCompiler, call: anytype) !bool {
        const property = switch (self.compiler.tree.expr(call.callee).*) {
            .property => |value| value,
            else => return false,
        };
        const symbol = self.compiler.resolution.expr_symbols.get(call.callee) orelse return false;
        const entry = self.compiler.resolution.symbols.get(symbol) orelse return false;
        if (entry.kind != .builtin or entry.module_path == null or !std.mem.eql(u8, entry.module_path.?, "время")) return false;
        if (call.arguments.len == 0 and std.mem.eql(u8, property.property, "сейчас_мс")) {
            try self.function.emit(self.compiler.result.allocator, .{ .time_now = {} });
            return true;
        }
        if (call.arguments.len == 0 and std.mem.eql(u8, property.property, "монотонно_мс")) {
            try self.function.emit(self.compiler.result.allocator, .{ .time_monotonic = {} });
            return true;
        }
        if (call.arguments.len == 1 and std.mem.eql(u8, property.property, "спать_мс")) {
            try self.compileExpression(call.arguments[0]);
            // Неблокирующий I/O (см. compileFilesystemBuiltin выше) — синхронный
            // std.Io.sleep() блокировал бы ЕДИНСТВЕННЫЙ OS-поток интерпретатора
            // целиком, останавливая планировщик кооперативных процессов вместе
            // с ним: `запусти другой_процесс()` перед время.спать_мс(N) никогда
            // не получал ни одного такта, пока текущий процесс спал (найдено
            // вживую — HTTP-сервер, запущенный через `запусти`, не успевал
            // забиндить порт за время сна вызывающего процесса).
            try self.function.emit(self.compiler.result.allocator, .{ .time_sleep_submit = {} });
            try self.function.emit(self.compiler.result.allocator, .{ .await_async = {} });
            return true;
        }
        return false;
    }

    // `DOM.*` доступен только в `aot_wasm_only` (`builtinAvailability` в
    // `target.zig`) — байткод-VM (нативный CLI, браузерный интерпретатор)
    // вообще не имеет опкода для DOM, его умеет опускать только AOT-путь
    // (`mir_lowering.zig`/`wasm_emit.zig`). Диагностика на этапе
    // компиляции здесь была бы ошибочной: `panos build --target=wasm`
    // ТОЖЕ прогоняет этот байткод-компилятор как часть полного анализа
    // (`module_compiler.compileGraphForTarget`, используется каждой точкой
    // входа, не только `panos run`), даже не выполняя итоговый байткод —
    // жёсткая ошибка компиляции здесь ошибочно заблокировала бы
    // легитимную AOT-сборку под wasm. Поэтому вместо неё компилируется
    // настоящая RUNTIME-паника (тот же опкод `.panic`, что и у
    // `паника(...)`), по тому же паттерну, что и у ЛЮБОГО другого
    // builtin с ограничением по таргету (`target_policy.
    // ensureRuntimeBuiltinAvailable`, срабатывающий внутри `vm.zig`, а не
    // `compiler.zig`) — паника реально срабатывает только если программу
    // с использованием DOM запустить ЧЕРЕЗ байткод-VM, что законно
    // невозможно ни на одном таргете.
    fn compileDomBuiltin(self: *FunctionCompiler, call: anytype) !bool {
        const symbol = self.compiler.resolution.expr_symbols.get(call.callee) orelse return false;
        const entry = self.compiler.resolution.symbols.get(symbol) orelse return false;
        if (entry.kind != .builtin or entry.module_path == null or !std.mem.eql(u8, entry.module_path.?, "DOM")) return false;
        const message = try self.compiler.program().copyString("DOM доступен только через panos build --target=wasm, не в этом runtime-таргете");
        try self.emitConstant(.{ .string = message });
        try self.function.emit(self.compiler.result.allocator, .{ .panic = {} });
        return true;
    }

    // `состояние.*` тоже `aot_wasm_only`, та же причина, что и у
    // `compileDomBuiltin` выше — настоящая RUNTIME-паника, а не ошибка
    // компиляции, так как этот же байткод-компилятор безусловно
    // запускается как часть полного анализа `panos build --target=wasm`
    // (`module_compiler.compileGraphForTarget`), даже не выполняя
    // результат для этой команды.
    fn compileStateBuiltin(self: *FunctionCompiler, call: anytype) !bool {
        const symbol = self.compiler.resolution.expr_symbols.get(call.callee) orelse return false;
        const entry = self.compiler.resolution.symbols.get(symbol) orelse return false;
        if (entry.kind != .builtin or entry.module_path == null or !std.mem.eql(u8, entry.module_path.?, "состояние")) return false;
        const message = try self.compiler.program().copyString("состояние доступен только через panos build --target=wasm, не в этом runtime-таргете");
        try self.emitConstant(.{ .string = message });
        try self.function.emit(self.compiler.result.allocator, .{ .panic = {} });
        return true;
    }

    fn compileIoBuiltin(self: *FunctionCompiler, call: anytype) !bool {
        const property = switch (self.compiler.tree.expr(call.callee).*) {
            .property => |value| value,
            else => return false,
        };
        const symbol = self.compiler.resolution.expr_symbols.get(call.callee) orelse return false;
        const entry = self.compiler.resolution.symbols.get(symbol) orelse return false;
        if (entry.kind != .builtin or entry.module_path == null or !std.mem.eql(u8, entry.module_path.?, "ввод_вывод")) return false;
        if (call.arguments.len == 1 and std.mem.eql(u8, property.property, "печать")) {
            try self.compileExpression(call.arguments[0]);
            try self.function.emit(self.compiler.result.allocator, .{ .io_print = {} });
            return true;
        }
        if (call.arguments.len == 1 and std.mem.eql(u8, property.property, "строка")) {
            try self.compileExpression(call.arguments[0]);
            try self.function.emit(self.compiler.result.allocator, .{ .io_println = {} });
            return true;
        }
        if (call.arguments.len == 0 and std.mem.eql(u8, property.property, "прочитать_строку")) {
            try self.function.emit(self.compiler.result.allocator, .{ .io_read_line = {} });
            return true;
        }
        return false;
    }

    fn compileStringBuiltin(self: *FunctionCompiler, call: anytype) !bool {
        const property = switch (self.compiler.tree.expr(call.callee).*) {
            .property => |value| value,
            else => return false,
        };
        const symbol = self.compiler.resolution.expr_symbols.get(call.callee) orelse return false;
        const entry = self.compiler.resolution.symbols.get(symbol) orelse return false;
        if (entry.kind != .builtin or entry.module_path == null or !std.mem.eql(u8, entry.module_path.?, "строки")) return false;
        const Op = struct { name: []const u8, argc: usize, instr: bytecode.Instruction };
        const ops = [_]Op{
            .{ .name = "из_байтов", .argc = 1, .instr = .{ .str_from_bytes = {} } },
            .{ .name = "в_число", .argc = 1, .instr = .{ .str_to_number = {} } },
            .{ .name = "из_числа", .argc = 1, .instr = .{ .str_number_to_str = {} } },
            .{ .name = "из_целого", .argc = 1, .instr = .{ .str_int_to_str = {} } },
            .{ .name = "верхний_регистр", .argc = 1, .instr = .{ .str_upper = {} } },
            .{ .name = "нижний_регистр", .argc = 1, .instr = .{ .str_lower = {} } },
            .{ .name = "заканчивается_на", .argc = 2, .instr = .{ .str_ends_with = {} } },
            .{ .name = "начинается_с", .argc = 2, .instr = .{ .str_starts_with = {} } },
            .{ .name = "содержит", .argc = 2, .instr = .{ .str_contains = {} } },
            .{ .name = "найти", .argc = 3, .instr = .{ .str_find = {} } },
            .{ .name = "заменить", .argc = 3, .instr = .{ .str_replace = {} } },
            .{ .name = "обрезать", .argc = 1, .instr = .{ .str_trim = {} } },
            .{ .name = "разбить", .argc = 2, .instr = .{ .str_split = {} } },
            .{ .name = "соединить", .argc = 2, .instr = .{ .str_join = {} } },
            .{ .name = "срез", .argc = 3, .instr = .{ .str_slice = {} } },
            .{ .name = "цифра_или_буква", .argc = 1, .instr = .{ .str_is_digit_or_letter = {} } },
            .{ .name = "это_буква", .argc = 1, .instr = .{ .str_is_letter = {} } },
            .{ .name = "это_цифра", .argc = 1, .instr = .{ .str_is_digit = {} } },
            .{ .name = "в_байты", .argc = 1, .instr = .{ .str_to_bytes = {} } },
            .{ .name = "в_руны", .argc = 1, .instr = .{ .str_to_runes = {} } },
            .{ .name = "из_рун", .argc = 1, .instr = .{ .str_from_runes = {} } },
            .{ .name = "кодовая_точка", .argc = 1, .instr = .{ .str_code_point = {} } },
        };
        for (ops) |op| {
            if (call.arguments.len == op.argc and std.mem.eql(u8, property.property, op.name)) {
                for (call.arguments) |argument| try self.compileExpression(argument);
                try self.function.emit(self.compiler.result.allocator, op.instr);
                return true;
            }
        }
        return false;
    }

    fn compileCompressBuiltin(self: *FunctionCompiler, call: anytype) !bool {
        const property = switch (self.compiler.tree.expr(call.callee).*) {
            .property => |value| value,
            else => return false,
        };
        const symbol = self.compiler.resolution.expr_symbols.get(call.callee) orelse return false;
        const entry = self.compiler.resolution.symbols.get(symbol) orelse return false;
        if (entry.kind != .builtin or entry.module_path == null or !std.mem.eql(u8, entry.module_path.?, "сжатие")) return false;
        if (call.arguments.len == 1 and std.mem.eql(u8, property.property, "разжать_gzip")) {
            try self.compileExpression(call.arguments[0]);
            try self.function.emit(self.compiler.result.allocator, .{ .gzip_decompress_submit = {} });
            try self.function.emit(self.compiler.result.allocator, .{ .await_async = {} });
            return true;
        }
        return false;
    }

    fn compileSyntaxBuiltin(self: *FunctionCompiler, call: anytype) !bool {
        const property = switch (self.compiler.tree.expr(call.callee).*) {
            .property => |value| value,
            else => return false,
        };
        const symbol = self.compiler.resolution.expr_symbols.get(call.callee) orelse return false;
        const entry = self.compiler.resolution.symbols.get(symbol) orelse return false;
        if (entry.kind != .builtin or entry.module_path == null or !std.mem.eql(u8, entry.module_path.?, "синтаксис")) return false;
        const instruction: bytecode.Instruction = if (call.arguments.len == 1 and std.mem.eql(u8, property.property, "структуры"))
            .{ .syntax_structs = {} }
        else if (call.arguments.len == 2 and std.mem.eql(u8, property.property, "поля"))
            .{ .syntax_fields = {} }
        else if (call.arguments.len == 1 and std.mem.eql(u8, property.property, "импорты"))
            .{ .syntax_imports = {} }
        else if (call.arguments.len == 2 and std.mem.eql(u8, property.property, "аннотации"))
            .{ .syntax_annotations = {} }
        else if (call.arguments.len == 3 and std.mem.eql(u8, property.property, "аргумент_аннотации"))
            .{ .syntax_annotation_arg = {} }
        else if (call.arguments.len == 3 and std.mem.eql(u8, property.property, "аннотации_поля"))
            .{ .syntax_field_annotations = {} }
        else if (call.arguments.len == 4 and std.mem.eql(u8, property.property, "аргумент_аннотации_поля"))
            .{ .syntax_field_annotation_arg = {} }
        else
            return false;
        for (call.arguments) |argument| try self.compileExpression(argument);
        try self.function.emit(self.compiler.result.allocator, instruction);
        return true;
    }

    fn compileNetBuiltin(self: *FunctionCompiler, call: anytype) !bool {
        const property = switch (self.compiler.tree.expr(call.callee).*) {
            .property => |value| value,
            else => return false,
        };
        const symbol = self.compiler.resolution.expr_symbols.get(call.callee) orelse return false;
        const entry = self.compiler.resolution.symbols.get(symbol) orelse return false;
        if (entry.kind != .builtin or entry.module_path == null or !std.mem.eql(u8, entry.module_path.?, "сеть")) return false;
        if (call.arguments.len == 2 and std.mem.eql(u8, property.property, "подключиться")) {
            for (call.arguments) |argument| try self.compileExpression(argument);
            try self.function.emit(self.compiler.result.allocator, .{ .net_connect_submit = {} });
            try self.function.emit(self.compiler.result.allocator, .{ .await_async = {} });
            return true;
        }
        if (call.arguments.len == 1 and std.mem.eql(u8, property.property, "кодировать_url")) {
            try self.compileExpression(call.arguments[0]);
            try self.function.emit(self.compiler.result.allocator, .{ .url_encode = {} });
            return true;
        }
        if (call.arguments.len == 1 and std.mem.eql(u8, property.property, "декодировать_url")) {
            try self.compileExpression(call.arguments[0]);
            try self.function.emit(self.compiler.result.allocator, .{ .url_decode = {} });
            return true;
        }
        if (call.arguments.len == 4 and std.mem.eql(u8, property.property, "http_запрос")) {
            for (call.arguments) |argument| try self.compileExpression(argument);
            try self.function.emit(self.compiler.result.allocator, .{ .http_request_submit = {} });
            try self.function.emit(self.compiler.result.allocator, .{ .await_async = {} });
            return true;
        }
        // Синхронный HTTP только для браузера опускается напрямую AOT MIR
        // бэкендом. `compileGraphForTarget` всё равно вызывает этот общий
        // байткод-компилятор для диагностики, но VM-таргет отклоняет этот
        // builtin до выполнения (target.zig: aot_wasm_only) — поэтому
        // здесь не должно быть притворной нативной байткод-реализации.
        if (call.arguments.len == 3 and std.mem.eql(u8, property.property, "http_запрос_sync")) {
            for (call.arguments) |argument| try self.compileExpression(argument);
            try self.emitVoid();
            return true;
        }
        if (call.arguments.len == 1 and std.mem.eql(u8, property.property, "http_сервер_слушать")) {
            try self.compileExpression(call.arguments[0]);
            try self.function.emit(self.compiler.result.allocator, .{ .http_listen = {} });
            return true;
        }
        return false;
    }

    fn compileCryptoBuiltin(self: *FunctionCompiler, call: anytype) !bool {
        const property = switch (self.compiler.tree.expr(call.callee).*) {
            .property => |value| value,
            else => return false,
        };
        const symbol = self.compiler.resolution.expr_symbols.get(call.callee) orelse return false;
        const entry = self.compiler.resolution.symbols.get(symbol) orelse return false;
        if (entry.kind != .builtin or entry.module_path == null or !std.mem.eql(u8, entry.module_path.?, "крипто")) return false;
        if (call.arguments.len == 2 and std.mem.eql(u8, property.property, "hmac_sha256_base64url")) {
            for (call.arguments) |argument| try self.compileExpression(argument);
            try self.function.emit(self.compiler.result.allocator, .{ .crypto_hmac_sha256_b64url = {} });
            return true;
        }
        if (call.arguments.len == 1 and std.mem.eql(u8, property.property, "base64url_кодировать")) {
            try self.compileExpression(call.arguments[0]);
            try self.function.emit(self.compiler.result.allocator, .{ .crypto_base64url_encode = {} });
            return true;
        }
        if (call.arguments.len == 1 and std.mem.eql(u8, property.property, "base64url_декодировать")) {
            try self.compileExpression(call.arguments[0]);
            try self.function.emit(self.compiler.result.allocator, .{ .crypto_base64url_decode = {} });
            return true;
        }
        if (call.arguments.len == 2 and std.mem.eql(u8, property.property, "сравнить_константное_время")) {
            for (call.arguments) |argument| try self.compileExpression(argument);
            try self.function.emit(self.compiler.result.allocator, .{ .crypto_timing_safe_eq = {} });
            return true;
        }
        return false;
    }

    fn compileSqlBuiltin(self: *FunctionCompiler, call: anytype) !bool {
        const property = switch (self.compiler.tree.expr(call.callee).*) {
            .property => |value| value,
            else => return false,
        };
        const symbol = self.compiler.resolution.expr_symbols.get(call.callee) orelse return false;
        const entry = self.compiler.resolution.symbols.get(symbol) orelse return false;
        if (entry.kind != .builtin or entry.module_path == null or !std.mem.eql(u8, entry.module_path.?, "бд")) return false;
        if (call.arguments.len == 1 and std.mem.eql(u8, property.property, "открыть")) {
            try self.compileExpression(call.arguments[0]);
            try self.function.emit(self.compiler.result.allocator, .{ .sql_open_submit = {} });
            try self.function.emit(self.compiler.result.allocator, .{ .await_async = {} });
            return true;
        }
        return false;
    }

    fn compileForeignCall(self: *FunctionCompiler, call: anytype) !bool {
        const symbol = self.compiler.resolution.expr_symbols.get(call.callee) orelse return false;
        const foreign = self.findForeignDecl(symbol) orelse return false;
        if (call.arguments.len != foreign.parameters.len) {
            try self.compiler.report(call.span, "Compiler Error: неверное количество аргументов 'внешний'-вызова", .{});
            try self.emitVoid();
            return true;
        }
        for (call.arguments) |argument| try self.compileExpression(argument);
        const param_kinds = try self.compiler.program().arena.allocator().alloc(ast.ForeignMarshalKind, foreign.parameters.len);
        for (foreign.parameters, param_kinds) |parameter, *kind| kind.* = parameter.marshal;
        // Раскладка полей struct-by-value берётся из УЖЕ
        // ПРОТИПИЗИРОВАННОЙ сигнатуры функции (`checked.symbol_types`), а
        // не через повторный резолв `parameter.struct_type_name` здесь:
        // тайпчекер уже превратил каждый `.struct_value`-параметр в
        // настоящий именованный TypeId вроде `Вектор2`/`Цвет`
        // (`foreignMarshalType` в `type_checker.zig`), так что его символ
        // достаётся одним поиском по сигнатуре.
        const signature = self.compiler.checked.symbol_types.get(symbol);
        const function_type = if (signature) |value| self.compiler.checked.types.get(value) else null;
        const param_struct_layouts = try self.compiler.program().arena.allocator().alloc([]const ast.ForeignMarshalKind, foreign.parameters.len);
        for (param_kinds, param_struct_layouts, 0..) |kind, *layout, index| {
            const parameter_type = if (function_type) |entry| switch (entry.*) {
                .function => |f| if (index < f.parameters.len) f.parameters[index] else null,
                else => null,
            } else null;
            layout.* = if (kind != .struct_value) &.{} else self.ffiStructLayoutFor(parameter_type);
        }
        const return_type = if (function_type) |entry| switch (entry.*) {
            .function => |f| f.return_type,
            else => null,
        } else null;
        const return_struct_layout: []const ast.ForeignMarshalKind = if (foreign.return_marshal != .struct_value) &.{} else self.ffiStructLayoutFor(return_type);
        // `0` (никогда не валидный указатель на функцию), если резолвер
        // уже не смог загрузить библиотеку/символ — диагностика об этом
        // уже выдана на этом этапе, этот код недостижим для программы,
        // которая реально прошла резолвинг без ошибок.
        const fn_ptr = self.compiler.resolution.foreign_functions.get(symbol) orelse 0;
        const constant_index = try self.function.addConstant(self.compiler.result.allocator, .{ .foreign_function = .{
            .fn_ptr = fn_ptr,
            .name = try self.compiler.program().copyString(foreign.name),
            .param_kinds = param_kinds,
            .param_struct_layouts = param_struct_layouts,
            .return_kind = foreign.return_marshal,
            .return_struct_layout = return_struct_layout,
        } });
        if (call.arguments.len > std.math.maxInt(u16)) return error.ArgumentLimitReached;
        try self.function.emit(self.compiler.result.allocator, .{ .call_foreign = .{
            .constant_index = constant_index,
            .argument_count = @intCast(call.arguments.len),
        } });
        return true;
    }

    // `type_id` (уже разрешённый тип паноса для `.struct_value`-параметра
    // или возврата) -> виды маршалинга полей его `ff_структура`, либо
    // `&.{}`, если это не она (не должно случаться для программы, прошедшей
    // тайпчекинг без ошибок, но это компиляционная метаданные-обвязка, не
    // место для новых паник на некорректном/poison-типе).
    fn ffiStructLayoutFor(self: *FunctionCompiler, type_id: ?types.TypeId) []const ast.ForeignMarshalKind {
        const id = type_id orelse return &.{};
        const entry = self.compiler.checked.types.get(id) orelse return &.{};
        const nominal_symbol = switch (entry.*) {
            .nominal => |n| n.symbol,
            else => return &.{},
        };
        return self.compiler.checked.ffi_struct_layouts.get(nominal_symbol) orelse &.{};
    }

    // Обратный поиск по `decl_symbols` (тот же паттерн линейного
    // сканирования, что уже используют `definitionSpan`/
    // `preciseDeclarationSpan` LSP — цена только на этапе компиляции) —
    // декларации `внешний` регистрируются как обычные символы вида
    // `.function` (см. `predeclare` в `resolver.zig`), поэтому нет
    // способа отличить внешний вызов от обычного по виду символа без
    // проверки самой декларации.
    fn findForeignDecl(self: *FunctionCompiler, symbol: symbols.SymbolId) ?@FieldType(ast.Decl, "foreign") {
        var iterator = self.compiler.resolution.decl_symbols.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.* != symbol) continue;
            return switch (self.compiler.tree.decl(entry.key_ptr.*).*) {
                .foreign => |foreign| foreign,
                else => null,
            };
        }
        return null;
    }

    fn compileProcessBuiltin(self: *FunctionCompiler, call: anytype) !bool {
        const name = switch (self.compiler.tree.expr(call.callee).*) {
            .ident => |ident| ident.name,
            else => return false,
        };
        if (std.mem.eql(u8, name, "отправить") and call.arguments.len == 2) {
            for (call.arguments) |argument| try self.compileExpression(argument);
            try self.function.emit(self.compiler.result.allocator, .{ .send = {} });
            return true;
        }
        if (std.mem.eql(u8, name, "получить") and call.arguments.len == 0) {
            try self.function.emit(self.compiler.result.allocator, .{ .receive = {} });
            return true;
        }
        if (std.mem.eql(u8, name, "себя") and call.arguments.len == 0) {
            try self.function.emit(self.compiler.result.allocator, .{ .current_process = {} });
            return true;
        }
        if (std.mem.eql(u8, name, "убить") and call.arguments.len == 1) {
            try self.compileExpression(call.arguments[0]);
            try self.function.emit(self.compiler.result.allocator, .{ .kill_process = {} });
            return true;
        }
        if (std.mem.eql(u8, name, "связать") and call.arguments.len == 1) {
            try self.compileExpression(call.arguments[0]);
            try self.function.emit(self.compiler.result.allocator, .{ .link_process = {} });
            return true;
        }
        if (std.mem.eql(u8, name, "наблюдать") and call.arguments.len == 1) {
            try self.compileExpression(call.arguments[0]);
            try self.function.emit(self.compiler.result.allocator, .{ .observe = {} });
            return true;
        }
        if (std.mem.eql(u8, name, "получить_сигнал") and call.arguments.len == 0) {
            try self.function.emit(self.compiler.result.allocator, .{ .get_signal = {} });
            return true;
        }
        if (std.mem.eql(u8, name, "ждать") and call.arguments.len == 1) {
            try self.compileExpression(call.arguments[0]);
            try self.function.emit(self.compiler.result.allocator, .{ .await_task = {} });
            return true;
        }
        if (std.mem.eql(u8, name, "ограничить_почту") and call.arguments.len == 1) {
            try self.compileExpression(call.arguments[0]);
            try self.function.emit(self.compiler.result.allocator, .{ .set_mailbox_capacity = {} });
            return true;
        }
        if (std.mem.eql(u8, name, "отправить_или") and call.arguments.len == 2) {
            for (call.arguments) |argument| try self.compileExpression(argument);
            try self.function.emit(self.compiler.result.allocator, .{ .send_or = {} });
            return true;
        }
        if (std.mem.eql(u8, name, "отмена") and call.arguments.len == 1) {
            try self.compileExpression(call.arguments[0]);
            try self.function.emit(self.compiler.result.allocator, .{ .request_cancel = {} });
            return true;
        }
        if (std.mem.eql(u8, name, "отменено") and call.arguments.len == 0) {
            try self.function.emit(self.compiler.result.allocator, .{ .is_cancelled = {} });
            return true;
        }
        return false;
    }

    fn compileProcessMethod(self: *FunctionCompiler, call: anytype) !bool {
        const property = switch (self.compiler.tree.expr(call.callee).*) {
            .property => |value| value,
            else => return false,
        };
        if (!std.mem.eql(u8, property.property, "номер") or call.arguments.len != 0) return false;
        try self.compileExpression(property.object);
        try self.function.emit(self.compiler.result.allocator, .{ .process_id = {} });
        return true;
    }

    fn compileSpawn(self: *FunctionCompiler, spawn: anytype) !void {
        const call = switch (self.compiler.tree.expr(spawn.call).*) {
            .call => |value| value,
            else => return self.unsupportedExpression(spawn.span),
        };
        const ordered_arguments = self.compiler.checked.call_arguments.get(spawn.call);
        if (call.argument_names != null and ordered_arguments == null) {
            try self.compiler.report(call.span, "Compiler Error: именованные аргументы не поддержаны для этого вызова", .{});
            return self.emitVoid();
        }
        const arguments = ordered_arguments orelse call.arguments;
        if (arguments.len > std.math.maxInt(u16)) return error.ArgumentLimitReached;
        try self.compileExpression(call.callee);
        for (arguments) |argument| try self.compileExpression(argument);
        try self.function.emit(self.compiler.result.allocator, .{ .spawn = @intCast(arguments.len) });
    }

    fn compileLengthBuiltin(self: *FunctionCompiler, call: anytype) !bool {
        if (call.arguments.len != 1) return false;
        const symbol = self.compiler.resolution.expr_symbols.get(call.callee) orelse return false;
        const entry = self.compiler.resolution.symbols.get(symbol) orelse return false;
        if (entry.kind != .builtin or !std.mem.eql(u8, entry.name, "длина")) return false;
        const argument_type = self.compiler.checked.expression_types.get(call.arguments[0]) orelse return false;
        const type_entry = self.compiler.checked.types.get(argument_type) orelse return false;
        const instruction: bytecode.Instruction = switch (type_entry.*) {
            .primitive => |primitive| if (primitive == .string) .{ .string_length = {} } else return false,
            .array => .{ .array_length = {} },
            .map => .{ .map_length = {} },
            else => return false,
        };
        try self.compileExpression(call.arguments[0]);
        try self.function.emit(self.compiler.result.allocator, instruction);
        return true;
    }

    fn compileCollectionMethod(self: *FunctionCompiler, call: anytype) !bool {
        const property = switch (self.compiler.tree.expr(call.callee).*) {
            .property => |value| value,
            else => return false,
        };
        const object_type = self.compiler.checked.expression_types.get(property.object) orelse return false;
        const type_entry = self.compiler.checked.types.get(object_type) orelse return false;
        const instruction: bytecode.Instruction = switch (type_entry.*) {
            .primitive => |primitive| if (primitive == .string and std.mem.eql(u8, property.property, "длина") and call.arguments.len == 0)
                .{ .string_length = {} }
            else
                return false,
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
            else if (std.mem.eql(u8, property.property, "срез") and call.arguments.len == 2)
                .{ .array_slice = {} }
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

    fn compilePreludeEnumMethod(self: *FunctionCompiler, call: anytype) !bool {
        const property = switch (self.compiler.tree.expr(call.callee).*) {
            .property => |value| value,
            else => return false,
        };
        const object_type = self.compiler.checked.expression_types.get(property.object) orelse return false;
        const type_entry = self.compiler.checked.types.get(object_type) orelse return false;
        const nominal = switch (type_entry.*) {
            .nominal => |value| value,
            else => return false,
        };
        const owner = self.compiler.resolution.symbols.get(nominal.symbol) orelse return false;
        if (std.mem.eql(u8, owner.name, "Опция")) {
            if (std.mem.eql(u8, property.property, "есть") and call.arguments.len == 0) {
                try self.compileExpression(property.object);
                try self.emitEnumMatch("Опция.Есть");
                return true;
            }
            if (std.mem.eql(u8, property.property, "пусто") and call.arguments.len == 0) {
                try self.compileExpression(property.object);
                try self.emitEnumMatch("Опция.Нет");
                return true;
            }
            if (std.mem.eql(u8, property.property, "получить") and call.arguments.len == 1) {
                try self.compileEnumFallback(property.object, call.arguments[0], "Опция.Есть", .field);
                return true;
            }
            if (std.mem.eql(u8, property.property, "значение") and call.arguments.len == 0) {
                try self.compileEnumStrict(property.object, null, "Опция.Есть", "нет значения");
                return true;
            }
            if (std.mem.eql(u8, property.property, "ожидать") and call.arguments.len == 1) {
                try self.compileEnumStrict(property.object, call.arguments[0], "Опция.Есть", "нет значения");
                return true;
            }
            if (std.mem.eql(u8, property.property, "запас") and call.arguments.len == 1) {
                try self.compileEnumFallback(property.object, call.arguments[0], "Опция.Есть", .receiver);
                return true;
            }
            if (std.mem.eql(u8, property.property, "заменить_значение") and call.arguments.len == 1) {
                try self.compileEnumTransform(property.object, call.arguments[0], "Опция.Есть", .{ .variant_name = "Опция.Есть", .value = .argument }, .{ .variant_name = "Опция.Нет", .value = .none });
                return true;
            }
            if (std.mem.eql(u8, property.property, "результат_или") and call.arguments.len == 1) {
                try self.compileEnumTransform(property.object, call.arguments[0], "Опция.Есть", .{ .variant_name = "Результат.Успех", .value = .field }, .{ .variant_name = "Результат.Неудача", .value = .argument });
                return true;
            }
        }
        if (std.mem.eql(u8, owner.name, "Результат")) {
            if (std.mem.eql(u8, property.property, "успех") and call.arguments.len == 0) {
                try self.compileExpression(property.object);
                try self.emitEnumMatch("Результат.Успех");
                return true;
            }
            if (std.mem.eql(u8, property.property, "ошибка") and call.arguments.len == 0) {
                try self.compileExpression(property.object);
                try self.emitEnumMatch("Результат.Неудача");
                return true;
            }
            if (std.mem.eql(u8, property.property, "получить") and call.arguments.len == 1) {
                try self.compileEnumFallback(property.object, call.arguments[0], "Результат.Успех", .field);
                return true;
            }
            if (std.mem.eql(u8, property.property, "значение") and call.arguments.len == 0) {
                try self.compileEnumStrict(property.object, null, "Результат.Успех", "нет значения");
                return true;
            }
            if (std.mem.eql(u8, property.property, "причина") and call.arguments.len == 0) {
                try self.compileEnumStrict(property.object, null, "Результат.Неудача", "нет ошибки");
                return true;
            }
            if (std.mem.eql(u8, property.property, "ожидать") and call.arguments.len == 1) {
                try self.compileEnumStrict(property.object, call.arguments[0], "Результат.Успех", "нет значения");
                return true;
            }
            if (std.mem.eql(u8, property.property, "ожидать_ошибку") and call.arguments.len == 1) {
                try self.compileEnumStrict(property.object, call.arguments[0], "Результат.Неудача", "нет ошибки");
                return true;
            }
            if (std.mem.eql(u8, property.property, "получить_ошибку") and call.arguments.len == 1) {
                try self.compileEnumFallback(property.object, call.arguments[0], "Результат.Неудача", .field);
                return true;
            }
            if (std.mem.eql(u8, property.property, "запас") and call.arguments.len == 1) {
                try self.compileEnumFallback(property.object, call.arguments[0], "Результат.Успех", .receiver);
                return true;
            }
            if (std.mem.eql(u8, property.property, "заменить_значение") and call.arguments.len == 1) {
                try self.compileEnumTransform(property.object, call.arguments[0], "Результат.Успех", .{ .variant_name = "Результат.Успех", .value = .argument }, .{ .variant_name = "Результат.Неудача", .value = .field });
                return true;
            }
            if (std.mem.eql(u8, property.property, "заменить_ошибку") and call.arguments.len == 1) {
                try self.compileEnumTransform(property.object, call.arguments[0], "Результат.Неудача", .{ .variant_name = "Результат.Неудача", .value = .argument }, .{ .variant_name = "Результат.Успех", .value = .field });
                return true;
            }
            if (std.mem.eql(u8, property.property, "опция") and call.arguments.len == 0) {
                try self.compileEnumTransform(property.object, null, "Результат.Успех", .{ .variant_name = "Опция.Есть", .value = .field }, .{ .variant_name = "Опция.Нет", .value = .none });
                return true;
            }
            if (std.mem.eql(u8, property.property, "ошибка_опция") and call.arguments.len == 0) {
                try self.compileEnumTransform(property.object, null, "Результат.Неудача", .{ .variant_name = "Опция.Есть", .value = .field }, .{ .variant_name = "Опция.Нет", .value = .none });
                return true;
            }
        }
        if (std.mem.eql(u8, owner.name, "Файл")) {
            if (std.mem.eql(u8, property.property, "прочитать") and call.arguments.len == 0) {
                try self.compileExpression(property.object);
                try self.function.emit(self.compiler.result.allocator, .{ .file_handle_read_submit = {} });
                try self.function.emit(self.compiler.result.allocator, .{ .await_async = {} });
                return true;
            }
            if (std.mem.eql(u8, property.property, "прочитать_строку") and call.arguments.len == 0) {
                try self.compileExpression(property.object);
                try self.function.emit(self.compiler.result.allocator, .{ .file_handle_read_line_submit = {} });
                try self.function.emit(self.compiler.result.allocator, .{ .await_async = {} });
                return true;
            }
            if (std.mem.eql(u8, property.property, "записать") and call.arguments.len == 1) {
                try self.compileExpression(property.object);
                try self.compileExpression(call.arguments[0]);
                try self.function.emit(self.compiler.result.allocator, .{ .file_handle_write_submit = {} });
                try self.function.emit(self.compiler.result.allocator, .{ .await_async = {} });
                return true;
            }
            if (std.mem.eql(u8, property.property, "закрыть") and call.arguments.len == 0) {
                try self.compileExpression(property.object);
                try self.function.emit(self.compiler.result.allocator, .{ .file_handle_close = {} });
                return true;
            }
        }
        if (std.mem.eql(u8, owner.name, "Соединение")) {
            if (std.mem.eql(u8, property.property, "получить") and call.arguments.len == 0) {
                try self.compileExpression(property.object);
                try self.function.emit(self.compiler.result.allocator, .{ .connection_read_submit = {} });
                try self.function.emit(self.compiler.result.allocator, .{ .await_async = {} });
                return true;
            }
            if (std.mem.eql(u8, property.property, "получить_строку") and call.arguments.len == 0) {
                try self.compileExpression(property.object);
                try self.function.emit(self.compiler.result.allocator, .{ .connection_read_line_submit = {} });
                try self.function.emit(self.compiler.result.allocator, .{ .await_async = {} });
                return true;
            }
            if (std.mem.eql(u8, property.property, "отправить") and call.arguments.len == 1) {
                try self.compileExpression(property.object);
                try self.compileExpression(call.arguments[0]);
                try self.function.emit(self.compiler.result.allocator, .{ .connection_write_submit = {} });
                try self.function.emit(self.compiler.result.allocator, .{ .await_async = {} });
                return true;
            }
            if (std.mem.eql(u8, property.property, "закрыть") and call.arguments.len == 0) {
                try self.compileExpression(property.object);
                try self.function.emit(self.compiler.result.allocator, .{ .connection_close = {} });
                return true;
            }
        }
        if (std.mem.eql(u8, owner.name, "Соединение_БД")) {
            if (std.mem.eql(u8, property.property, "выполнить") and call.arguments.len == 2) {
                try self.compileExpression(property.object);
                try self.compileExpression(call.arguments[0]);
                try self.compileExpression(call.arguments[1]);
                try self.function.emit(self.compiler.result.allocator, .{ .sql_exec_submit = {} });
                try self.function.emit(self.compiler.result.allocator, .{ .await_async = {} });
                return true;
            }
            if (std.mem.eql(u8, property.property, "запрос") and call.arguments.len == 2) {
                try self.compileExpression(property.object);
                try self.compileExpression(call.arguments[0]);
                try self.compileExpression(call.arguments[1]);
                try self.function.emit(self.compiler.result.allocator, .{ .sql_query_submit = {} });
                try self.function.emit(self.compiler.result.allocator, .{ .await_async = {} });
                return true;
            }
            if (std.mem.eql(u8, property.property, "закрыть") and call.arguments.len == 0) {
                try self.compileExpression(property.object);
                try self.function.emit(self.compiler.result.allocator, .{ .sql_close = {} });
                return true;
            }
        }
        if (std.mem.eql(u8, owner.name, "Слушатель")) {
            if (std.mem.eql(u8, property.property, "принять_запрос") and call.arguments.len == 0) {
                try self.compileExpression(property.object);
                try self.function.emit(self.compiler.result.allocator, .{ .http_accept_submit = {} });
                try self.function.emit(self.compiler.result.allocator, .{ .await_async = {} });
                return true;
            }
        }
        if (std.mem.eql(u8, owner.name, "Запрос")) {
            if (std.mem.eql(u8, property.property, "метод") and call.arguments.len == 0) {
                try self.compileExpression(property.object);
                try self.function.emit(self.compiler.result.allocator, .{ .http_request_method = {} });
                return true;
            }
            if (std.mem.eql(u8, property.property, "путь") and call.arguments.len == 0) {
                try self.compileExpression(property.object);
                try self.function.emit(self.compiler.result.allocator, .{ .http_request_path = {} });
                return true;
            }
            if (std.mem.eql(u8, property.property, "тело") and call.arguments.len == 0) {
                try self.compileExpression(property.object);
                try self.function.emit(self.compiler.result.allocator, .{ .http_request_body = {} });
                return true;
            }
            if (std.mem.eql(u8, property.property, "заголовок") and call.arguments.len == 1) {
                try self.compileExpression(property.object);
                try self.compileExpression(call.arguments[0]);
                try self.function.emit(self.compiler.result.allocator, .{ .http_request_header = {} });
                return true;
            }
            if (std.mem.eql(u8, property.property, "ответить") and call.arguments.len == 3) {
                try self.compileExpression(property.object);
                try self.compileExpression(call.arguments[0]);
                try self.compileExpression(call.arguments[1]);
                try self.compileExpression(call.arguments[2]);
                try self.function.emit(self.compiler.result.allocator, .{ .http_request_respond = {} });
                return true;
            }
        }
        return false;
    }

    const EnumFallback = enum { field, receiver };
    const EnumTransformValue = enum { field, argument, none };
    const EnumTransformBranch = struct {
        variant_name: []const u8,
        value: EnumTransformValue,
    };

    fn compileEnumFallback(self: *FunctionCompiler, object: ast.ExprId, fallback: ast.ExprId, variant_name: []const u8, result: EnumFallback) !void {
        const object_slot = try self.allocateLocal();
        const fallback_slot = try self.allocateLocal();
        try self.compileExpression(object);
        try self.function.emit(self.compiler.result.allocator, .{ .set_local = object_slot });
        try self.compileExpression(fallback);
        try self.function.emit(self.compiler.result.allocator, .{ .set_local = fallback_slot });
        try self.function.emit(self.compiler.result.allocator, .{ .get_local = object_slot });
        try self.emitEnumMatch(variant_name);
        const fallback_jump = self.function.instructions.items.len;
        try self.function.emit(self.compiler.result.allocator, .{ .jump_if_false = 0 });
        try self.function.emit(self.compiler.result.allocator, .{ .get_local = object_slot });
        switch (result) {
            .field => try self.function.emit(self.compiler.result.allocator, .{ .get_property = 0 }),
            .receiver => {},
        }
        const end_jump = self.function.instructions.items.len;
        try self.function.emit(self.compiler.result.allocator, .{ .jump = 0 });
        self.patchJump(fallback_jump, self.function.instructions.items.len);
        try self.function.emit(self.compiler.result.allocator, .{ .get_local = fallback_slot });
        self.patchJump(end_jump, self.function.instructions.items.len);
    }

    fn compileEnumStrict(self: *FunctionCompiler, object: ast.ExprId, message: ?ast.ExprId, variant_name: []const u8, default_message: []const u8) !void {
        const object_slot = try self.allocateLocal();
        var message_slot: ?u16 = null;
        try self.compileExpression(object);
        try self.function.emit(self.compiler.result.allocator, .{ .set_local = object_slot });
        if (message) |value| {
            message_slot = try self.allocateLocal();
            try self.compileExpression(value);
            try self.function.emit(self.compiler.result.allocator, .{ .set_local = message_slot.? });
        }
        try self.function.emit(self.compiler.result.allocator, .{ .get_local = object_slot });
        try self.emitEnumMatch(variant_name);
        const panic_jump = self.function.instructions.items.len;
        try self.function.emit(self.compiler.result.allocator, .{ .jump_if_false = 0 });
        try self.function.emit(self.compiler.result.allocator, .{ .get_local = object_slot });
        try self.function.emit(self.compiler.result.allocator, .{ .get_property = 0 });
        const end_jump = self.function.instructions.items.len;
        try self.function.emit(self.compiler.result.allocator, .{ .jump = 0 });
        self.patchJump(panic_jump, self.function.instructions.items.len);
        if (message_slot) |slot| {
            try self.function.emit(self.compiler.result.allocator, .{ .get_local = slot });
        } else {
            try self.emitConstant(.{ .string = try self.compiler.program().copyString(default_message) });
        }
        try self.function.emit(self.compiler.result.allocator, .{ .panic = {} });
        self.patchJump(end_jump, self.function.instructions.items.len);
    }

    fn compileEnumTransform(self: *FunctionCompiler, object: ast.ExprId, argument: ?ast.ExprId, match_variant: []const u8, matching_branch: EnumTransformBranch, fallback_branch: EnumTransformBranch) !void {
        const object_slot = try self.allocateLocal();
        var argument_slot: ?u16 = null;
        try self.compileExpression(object);
        try self.function.emit(self.compiler.result.allocator, .{ .set_local = object_slot });
        if (argument) |value| {
            argument_slot = try self.allocateLocal();
            try self.compileExpression(value);
            try self.function.emit(self.compiler.result.allocator, .{ .set_local = argument_slot.? });
        }
        try self.function.emit(self.compiler.result.allocator, .{ .get_local = object_slot });
        try self.emitEnumMatch(match_variant);
        const fallback_jump = self.function.instructions.items.len;
        try self.function.emit(self.compiler.result.allocator, .{ .jump_if_false = 0 });
        try self.compileEnumTransformBranch(object_slot, argument_slot, matching_branch);
        const end_jump = self.function.instructions.items.len;
        try self.function.emit(self.compiler.result.allocator, .{ .jump = 0 });
        self.patchJump(fallback_jump, self.function.instructions.items.len);
        try self.compileEnumTransformBranch(object_slot, argument_slot, fallback_branch);
        self.patchJump(end_jump, self.function.instructions.items.len);
    }

    fn compileEnumTransformBranch(self: *FunctionCompiler, object_slot: u16, argument_slot: ?u16, branch: EnumTransformBranch) !void {
        const field_count: u16 = switch (branch.value) {
            .field => blk: {
                try self.function.emit(self.compiler.result.allocator, .{ .get_local = object_slot });
                try self.function.emit(self.compiler.result.allocator, .{ .get_property = 0 });
                break :blk 1;
            },
            .argument => blk: {
                try self.function.emit(self.compiler.result.allocator, .{ .get_local = argument_slot orelse unreachable });
                break :blk 1;
            },
            .none => 0,
        };
        const name_constant = try self.function.addConstant(self.compiler.result.allocator, .{ .string = try self.compiler.program().copyString(branch.variant_name) });
        try self.function.emit(self.compiler.result.allocator, .{ .build_struct = .{
            .name_constant = name_constant,
            .field_count = field_count,
        } });
    }

    fn emitEnumMatch(self: *FunctionCompiler, variant_name: []const u8) !void {
        const name_constant = try self.function.addConstant(self.compiler.result.allocator, .{ .string = try self.compiler.program().copyString(variant_name) });
        try self.function.emit(self.compiler.result.allocator, .{ .match_enum = name_constant });
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

    fn compileProperty(self: *FunctionCompiler, expression: ast.ExprId, property: anytype) !void {
        if (self.compiler.resolution.expr_symbols.get(expression)) |symbol| {
            if (try self.enumVariantName(symbol)) |name| {
                const name_constant = try self.function.addConstant(self.compiler.result.allocator, .{ .string = try self.compiler.program().copyString(name) });
                try self.function.emit(self.compiler.result.allocator, .{ .build_struct = .{
                    .name_constant = name_constant,
                    .field_count = 0,
                } });
                return;
            }
            const entry = self.compiler.resolution.symbols.get(symbol) orelse return self.unsupportedExpression(property.span);
            if (entry.module_path != null) {
                try self.emitSymbolValue(symbol, property.span);
                return;
            }
        }
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

    fn compileMatch(self: *FunctionCompiler, match: anytype) !void {
        const subject_slot = try self.allocateLocal();
        try self.compileExpression(match.subject);
        try self.function.emit(self.compiler.result.allocator, .{ .set_local = subject_slot });
        var end_jumps: std.ArrayList(usize) = .empty;
        defer end_jumps.deinit(self.compiler.result.allocator);
        var fallback_seen = false;
        for (match.arms) |arm| {
            if (fallback_seen) break;
            if (self.isCatchAllPattern(arm.pattern)) {
                fallback_seen = true;
                try self.compilePatternBindings(arm.pattern, subject_slot);
                try self.compileBlockValue(arm.body);
                const end_jump = self.function.instructions.items.len;
                try self.function.emit(self.compiler.result.allocator, .{ .jump = 0 });
                try end_jumps.append(self.compiler.result.allocator, end_jump);
                continue;
            }
            var next_arm_jumps: std.ArrayList(usize) = .empty;
            defer next_arm_jumps.deinit(self.compiler.result.allocator);
            try self.compilePatternGuards(arm.pattern, subject_slot, &next_arm_jumps);
            try self.compilePatternBindings(arm.pattern, subject_slot);
            try self.compileBlockValue(arm.body);
            const end_jump = self.function.instructions.items.len;
            try self.function.emit(self.compiler.result.allocator, .{ .jump = 0 });
            try end_jumps.append(self.compiler.result.allocator, end_jump);
            const next_arm = self.function.instructions.items.len;
            for (next_arm_jumps.items) |jump| self.patchJump(jump, next_arm);
        }
        try self.emitVoid();
        const end_target = self.function.instructions.items.len;
        for (end_jumps.items) |jump| self.patchJump(jump, end_target);
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
        const info = self.compiler.checked.for_in_infos.get(statement) orelse {
            try self.compiler.report(loop.span, "Compiler Error: не удалось определить форму цикла 'для ... в'", .{});
            return;
        };
        switch (info.kind) {
            .array => try self.compileArrayForIn(statement, loop),
            .iterator => try self.compileIteratorForIn(statement, loop, info),
        }
    }

    fn compileArrayForIn(self: *FunctionCompiler, statement: ast.StmtId, loop: anytype) !void {
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
        try self.compileForInBindings(bindings, element_slot, loop.span);
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

    fn compileIteratorForIn(self: *FunctionCompiler, statement: ast.StmtId, loop: anytype, info: type_checker.ForInInfo) !void {
        const bindings = self.compiler.resolution.stmt_bindings.get(statement) orelse &.{};
        if (bindings.len == 0) {
            try self.compiler.report(loop.span, "Compiler Error: цикл 'для ... в' ожидает переменную", .{});
            return;
        }
        const function_id = if (info.iterator_dispatch == .direct) self.compiler.result.function_ids.get(info.next_method) orelse {
            try self.compiler.report(loop.span, "Compiler Error: не удалось найти метод следующий()", .{});
            return;
        } else bytecode.invalid_function;
        const iterable_slot = try self.allocateLocal();
        const option_slot = try self.allocateLocal();
        const element_slot = if (bindings.len == 1) try self.ensureLocal(bindings[0]) else try self.allocateLocal();
        try self.compileExpression(loop.iterable);
        try self.function.emit(self.compiler.result.allocator, .{ .set_local = iterable_slot });

        const loop_start = self.function.instructions.items.len;
        switch (info.iterator_dispatch) {
            .direct => {
                try self.emitConstant(.{ .function_ref = function_id });
                try self.function.emit(self.compiler.result.allocator, .{ .get_local = iterable_slot });
                try self.function.emit(self.compiler.result.allocator, .{ .call = 1 });
            },
            .interface => {
                try self.function.emit(self.compiler.result.allocator, .{ .get_local = iterable_slot });
                try self.function.emit(self.compiler.result.allocator, .{ .call_interface = .{
                    .method_index = info.next_method_index,
                    .argument_count = 0,
                } });
            },
        }
        try self.function.emit(self.compiler.result.allocator, .{ .set_local = option_slot });
        try self.function.emit(self.compiler.result.allocator, .{ .get_local = option_slot });
        const option_name = try self.function.addConstant(self.compiler.result.allocator, .{ .string = try self.compiler.program().copyString("Опция.Есть") });
        try self.function.emit(self.compiler.result.allocator, .{ .match_enum = option_name });
        const exit_jump = self.function.instructions.items.len;
        try self.function.emit(self.compiler.result.allocator, .{ .jump_if_false = 0 });
        try self.function.emit(self.compiler.result.allocator, .{ .get_local = option_slot });
        try self.function.emit(self.compiler.result.allocator, .{ .get_property = 0 });
        try self.function.emit(self.compiler.result.allocator, .{ .set_local = element_slot });
        try self.compileForInBindings(bindings, element_slot, loop.span);
        try self.enterLoop();
        try self.compileBlockStatements(loop.body);
        const continue_target = self.function.instructions.items.len;
        try self.function.emit(self.compiler.result.allocator, .{ .jump = loop_start });
        const exit_target = self.function.instructions.items.len;
        self.patchJump(exit_jump, exit_target);
        self.leaveLoop(continue_target, exit_target);
    }

    fn compileForInBindings(self: *FunctionCompiler, bindings: []const symbols.SymbolId, element_slot: u16, span: source.Span) !void {
        if (bindings.len <= 1) return;
        for (bindings, 0..) |binding, field_index| {
            if (field_index > std.math.maxInt(u16)) {
                try self.compiler.report(span, "Compiler Error: слишком много элементов деструктуризации", .{});
                return;
            }
            const slot = try self.ensureLocal(binding);
            try self.function.emit(self.compiler.result.allocator, .{ .get_local = element_slot });
            try self.function.emit(self.compiler.result.allocator, .{ .get_property = @intCast(field_index) });
            try self.function.emit(self.compiler.result.allocator, .{ .set_local = slot });
        }
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

    fn compilePatternBindings(self: *FunctionCompiler, pattern: ast.PatternId, value_slot: u16) !void {
        switch (self.compiler.tree.pattern(pattern).*) {
            .ident => {
                const binding = self.compiler.resolution.pattern_symbols.get(pattern) orelse return;
                const binding_slot = try self.ensureLocal(binding);
                try self.function.emit(self.compiler.result.allocator, .{ .get_local = value_slot });
                try self.function.emit(self.compiler.result.allocator, .{ .set_local = binding_slot });
            },
            .constructor => |constructor| for (constructor.arguments, 0..) |argument, index| {
                const field = try self.patternFieldIndex(pattern, constructor, index) orelse return self.unsupportedExpression(patternSpan(self.compiler.tree, pattern));
                const field_slot = try self.allocateLocal();
                try self.function.emit(self.compiler.result.allocator, .{ .get_local = value_slot });
                try self.function.emit(self.compiler.result.allocator, .{ .get_property = field });
                try self.function.emit(self.compiler.result.allocator, .{ .set_local = field_slot });
                try self.compilePatternBindings(argument, field_slot);
            },
            .wildcard, .literal, .error_node => {},
        }
    }

    fn compilePatternGuards(self: *FunctionCompiler, pattern: ast.PatternId, value_slot: u16, next_arm_jumps: *std.ArrayList(usize)) !void {
        if (try self.patternEnumVariantName(pattern)) |variant_name| {
            try self.function.emit(self.compiler.result.allocator, .{ .get_local = value_slot });
            const name_constant = try self.function.addConstant(self.compiler.result.allocator, .{ .string = try self.compiler.program().copyString(variant_name) });
            try self.function.emit(self.compiler.result.allocator, .{ .match_enum = name_constant });
            const next_arm = self.function.instructions.items.len;
            try self.function.emit(self.compiler.result.allocator, .{ .jump_if_false = 0 });
            try next_arm_jumps.append(self.compiler.result.allocator, next_arm);
        }
        switch (self.compiler.tree.pattern(pattern).*) {
            .literal => |literal| {
                try self.function.emit(self.compiler.result.allocator, .{ .get_local = value_slot });
                try self.compileExpression(literal.value);
                try self.function.emit(self.compiler.result.allocator, .{ .equal = {} });
                const next_arm = self.function.instructions.items.len;
                try self.function.emit(self.compiler.result.allocator, .{ .jump_if_false = 0 });
                try next_arm_jumps.append(self.compiler.result.allocator, next_arm);
            },
            .constructor => |constructor| for (constructor.arguments, 0..) |argument, index| {
                const field = try self.patternFieldIndex(pattern, constructor, index) orelse return self.unsupportedExpression(patternSpan(self.compiler.tree, pattern));
                const field_slot = try self.allocateLocal();
                try self.function.emit(self.compiler.result.allocator, .{ .get_local = value_slot });
                try self.function.emit(self.compiler.result.allocator, .{ .get_property = field });
                try self.function.emit(self.compiler.result.allocator, .{ .set_local = field_slot });
                try self.compilePatternGuards(argument, field_slot, next_arm_jumps);
            },
            .wildcard, .ident, .error_node => {},
        }
    }

    fn isCatchAllPattern(self: *FunctionCompiler, pattern: ast.PatternId) bool {
        if (self.compiler.checked.pattern_variants.contains(pattern)) return false;
        return switch (self.compiler.tree.pattern(pattern).*) {
            .wildcard, .ident => true,
            .constructor => |constructor| blk: {
                for (constructor.arguments) |argument| {
                    if (!self.isCatchAllPattern(argument)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        };
    }

    fn patternFieldIndex(self: *FunctionCompiler, pattern: ast.PatternId, constructor: anytype, argument_index: usize) !?u16 {
        const pattern_type = self.compiler.checked.pattern_types.get(pattern) orelse return null;
        const entry = self.compiler.checked.types.get(pattern_type) orelse return null;
        if (entry.* == .poison or entry.* == .unconstrained) {
            // `получить()`/`Сообщение(T)`-style untyped payloads: there's
            // no real nominal type here to look up field order from, but
            // the type checker's own poison fallback (`inferMatchPattern`)
            // still resolved a real variant symbol via `pattern_variants`
            // — enum-variant fields are purely positional (see the real
            // `.nominal` enum branch below, which never consults field
            // NAMES either), so the same positional index is correct here
            // too. Constructor patterns with payload args matched against
            // `получить()` (e.g. `выбор получить() \n Тип.Вариант(x) ->
            // ...`) failed to compile at all before this — every existing
            // fixture happened to only exercise EITHER a payload-less
            // qualified variant against `получить()` OR a real nominal
            // subject, never both at once.
            if (self.compiler.checked.pattern_variants.contains(pattern)) {
                if (argument_index > std.math.maxInt(u16)) return error.FieldLimitReached;
                return @intCast(argument_index);
            }
            return null;
        }
        const nominal = switch (entry.*) {
            .nominal => |value| value,
            else => return null,
        };
        if (self.compiler.checked.enum_definitions.contains(nominal.symbol)) {
            if (argument_index > std.math.maxInt(u16)) return error.FieldLimitReached;
            return @intCast(argument_index);
        }
        const fields = if (self.compiler.checked.nominal_fields.get(nominal.symbol)) |normal|
            normal
        else if (self.compiler.checked.generic_nominal_fields.get(nominal.symbol)) |generic|
            generic.fields
        else
            return null;
        const name = if (constructor.field_names) |field_names| blk: {
            if (argument_index >= field_names.len) return null;
            break :blk field_names[argument_index];
        } else return if (argument_index <= std.math.maxInt(u16)) @intCast(argument_index) else error.FieldLimitReached;
        for (fields, 0..) |field, index| {
            if (!std.mem.eql(u8, field.name, name)) continue;
            if (index > std.math.maxInt(u16)) return error.FieldLimitReached;
            return @intCast(index);
        }
        return null;
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
        if (self.compiler.result.top_level_constants.get(symbol)) |constant| {
            try self.emitConstant(constant);
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
        if (!self.compiler.checked.nominal_fields.contains(nominal.symbol) and !self.compiler.checked.generic_nominal_fields.contains(nominal.symbol)) return null;
        const symbol = self.compiler.resolution.symbols.get(nominal.symbol) orelse return null;
        return symbol.name;
    }

    fn enumConstructor(self: *FunctionCompiler, callee: ast.ExprId) !?[]const u8 {
        const variant_symbol = self.compiler.resolution.expr_symbols.get(callee) orelse return null;
        return self.enumVariantName(variant_symbol);
    }

    fn patternEnumVariantName(self: *FunctionCompiler, pattern: ast.PatternId) !?[]const u8 {
        const variant_symbol = self.compiler.checked.pattern_variants.get(pattern) orelse self.compiler.resolution.pattern_symbols.get(pattern) orelse return null;
        return self.enumVariantName(variant_symbol);
    }

    fn enumVariantName(self: *FunctionCompiler, variant_symbol: symbols.SymbolId) !?[]const u8 {
        const variant = self.compiler.resolution.symbols.get(variant_symbol) orelse return null;
        if (variant.kind != .enum_variant) return null;
        const owner = self.compiler.resolution.symbols.get(variant.owner_type) orelse return null;
        const name = try std.fmt.allocPrint(self.compiler.result.arena.allocator(), "{s}.{s}", .{ owner.name, variant.name });
        return name;
    }

    fn propertyIndex(self: *FunctionCompiler, object: ast.ExprId, property: []const u8) !?u16 {
        const object_type = self.compiler.checked.expression_types.get(object) orelse return null;
        if (self.compiler.checked.types.eql(object_type, self.compiler.checked.types.builtins.error_value)) {
            if (std.mem.eql(u8, property, "код")) return 0;
            if (std.mem.eql(u8, property, "сообщение")) return 1;
            return null;
        }
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
        const fields = if (self.compiler.checked.nominal_fields.get(nominal.symbol)) |normal|
            normal
        else if (self.compiler.checked.generic_nominal_fields.get(nominal.symbol)) |generic|
            generic.fields
        else
            return null;
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
    return compileWithOptions(allocator, tree, resolution, checked, .{});
}

pub fn compileWithOptions(
    allocator: std.mem.Allocator,
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    checked: *const type_checker.CheckResult,
    options: CompileOptions,
) !CompileResult {
    var result = CompileResult.init(allocator);
    errdefer result.deinit();
    result.shared_program = options.program;
    for (options.functions) |function| try result.function_ids.put(function.symbol, function.function_id);
    for (options.constants) |constant| try result.top_level_constants.put(constant.symbol, constant.value);
    var compiler = Compiler.init(tree, resolution, checked, &result);
    defer compiler.deinit();
    try compiler.predeclareConstants();
    try compiler.predeclareFunctions();
    try compiler.predeclareLambdas();
    try compiler.registerComparableMethods();
    try compiler.registerCopyableMethods();
    try compiler.registerInterfaceMethods();
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

fn patternSpan(tree: *const ast.Ast, pattern: ast.PatternId) source.Span {
    return switch (tree.pattern(pattern).*) {
        .wildcard, .error_node => |span| span,
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
    var lexed = try lexer.tokenize(std.testing.allocator, "функ старт() -> Число\nпер сдвиг = 2.0\nпер добавить: функ(Число) -> Число = функ(значение)\nзначение + сдвиг\nконец\nдобавить(3.0)\nконец", 0);
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

test "compiler rejects vtable-ambiguous interface cast when a generic target implements the same interface twice" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(
        std.testing.allocator,
        "тип Ит[T] = интерфейс\n" ++
            "функ х(это: Ит(T)) -> T\n" ++
            "это.х()\n" ++
            "конец\n" ++
            "конец\n" ++
            "тип Обёртка[T] = структура\n" ++
            "знач: T\n" ++
            "конец\n" ++
            "реализация Ит для Обёртка\n" ++
            "функ х(это: Обёртка) -> T\n" ++
            "это.знач\n" ++
            "конец\n" ++
            "конец\n" ++
            "реализация Ит для Обёртка\n" ++
            "функ х(это: Обёртка) -> T\n" ++
            "это.знач\n" ++
            "конец\n" ++
            "конец\n" ++
            "функ показать(значение: Ит(Число)) -> Число\n" ++
            "значение.х()\n" ++
            "конец\n" ++
            "функ старт() -> Число\n" ++
            "показать(Обёртка(1.0))\n" ++
            "конец",
        0,
    );
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    var compiled = try compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();

    try std.testing.expectEqual(@as(usize, 1), compiled.diagnostics.items.items.len);
    try std.testing.expect(std.mem.indexOf(u8, compiled.diagnostics.items.items[0].message, "неоднозначная реализация интерфейса") != null);
}

test "compiler diagnostics outlive the compilation pass" {
    var result = CompileResult.init(std.testing.allocator);
    defer result.deinit();
    var compiler = Compiler{
        .tree = undefined,
        .resolution = undefined,
        .checked = undefined,
        .result = &result,
    };
    try compiler.report(.{ .file_id = 0, .start = 0, .end = 0 }, "Compiler Error: тестовое сообщение", .{});
    compiler.deinit();

    try std.testing.expectEqualStrings("Compiler Error: тестовое сообщение", result.diagnostics.items.items[0].message);
}
