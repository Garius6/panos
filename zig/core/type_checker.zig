const std = @import("std");
const ast = @import("ast.zig");
const diagnostic = @import("diagnostic.zig");
const resolver = @import("resolver.zig");
const source = @import("source.zig");
const symbols = @import("symbols.zig");
const types = @import("types.zig");

pub const CheckResult = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    types: types.TypeStore,
    diagnostics: diagnostic.DiagnosticList = .{},
    expression_types: std.AutoHashMap(ast.ExprId, types.TypeId),
    symbol_types: std.AutoHashMap(symbols.SymbolId, types.TypeId),

    pub fn init(allocator: std.mem.Allocator) !CheckResult {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .types = try types.TypeStore.init(allocator),
            .expression_types = .init(allocator),
            .symbol_types = .init(allocator),
        };
    }

    pub fn deinit(self: *CheckResult) void {
        self.symbol_types.deinit();
        self.expression_types.deinit();
        self.diagnostics.deinit(self.allocator);
        self.types.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

const Checker = struct {
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    result: *CheckResult,
    current_return: ?types.TypeId = null,

    fn report(self: *Checker, span: source.Span, comptime format: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.result.arena.allocator(), format, args);
        _ = try self.result.diagnostics.appendUnique(self.result.allocator, .{
            .phase = .type_checker,
            .severity = .err,
            .span = span,
            .message = message,
        });
    }

    fn signaturePass(self: *Checker) !void {
        for (self.tree.program.?.declarations) |declaration| {
            switch (self.tree.decl(declaration).*) {
                .function => |function| try self.defineFunctionSignature(declaration, function.parameters, function.return_type),
                .foreign => {},
                .impl => |implementation| for (implementation.methods) |method| {
                    const function = self.tree.decl(method).function;
                    try self.defineFunctionSignature(method, function.parameters, function.return_type);
                },
                else => {},
            }
        }
    }

    fn defineFunctionSignature(self: *Checker, declaration: ast.DeclId, parameters: []const ast.ParamDecl, return_type: ast.TypeId) !void {
        var parameter_types: std.ArrayList(types.TypeId) = .empty;
        defer parameter_types.deinit(self.result.allocator);
        for (parameters) |parameter| {
            try parameter_types.append(self.result.allocator, try self.resolveType(parameter.type_annotation.?));
        }
        const signature = try self.result.types.function(parameter_types.items, try self.resolveType(return_type));
        const symbol = self.resolution.decl_symbols.get(declaration) orelse return;
        try self.result.symbol_types.put(symbol, signature);
    }

    fn bodyPass(self: *Checker) !void {
        for (self.tree.program.?.declarations) |declaration| {
            switch (self.tree.decl(declaration).*) {
                .function => |function| try self.checkFunction(declaration, function.body),
                .constant => |constant| {
                    const value_type = try self.infer(constant.value);
                    if (self.resolution.decl_symbols.get(declaration)) |symbol| try self.result.symbol_types.put(symbol, value_type);
                },
                .impl => |implementation| for (implementation.methods) |method| {
                    const function = self.tree.decl(method).function;
                    _ = function;
                    try self.checkFunction(method, self.tree.decl(method).function.body);
                },
                else => {},
            }
        }
    }

    fn checkFunction(self: *Checker, declaration: ast.DeclId, body: []const ast.StmtId) !void {
        const function_symbol = self.resolution.decl_symbols.get(declaration) orelse return;
        const signature = self.result.symbol_types.get(function_symbol) orelse return;
        const function_type = self.result.types.get(signature).?.function;
        const previous_return = self.current_return;
        self.current_return = function_type.return_type;
        defer self.current_return = previous_return;
        const parameter_symbols = self.resolution.function_parameters.get(declaration) orelse &.{};
        for (parameter_symbols, function_type.parameters) |parameter_symbol, parameter_type| {
            try self.result.symbol_types.put(parameter_symbol, parameter_type);
        }
        const actual = try self.inferBlock(body);
        if (!self.assignable(actual, function_type.return_type)) {
            const span = self.tree.decl(declaration).function.span;
            try self.report(span, "Type Error: функция должна возвращать объявленный тип", .{});
        }
    }

    fn inferStatement(self: *Checker, statement: ast.StmtId, expected_return: types.TypeId) anyerror!types.TypeId {
        return switch (self.tree.stmt(statement).*) {
            .let => |let| blk: {
                const expected = if (let.type_annotation) |annotation| try self.resolveType(annotation) else null;
                const value_type = if (expected) |type_id| try self.inferExpected(let.value, type_id) else try self.infer(let.value);
                if (expected) |type_id| {
                    if (!self.assignable(value_type, type_id)) try self.report(let.span, "Type Error: значение переменной не совпадает с аннотацией", .{});
                }
                if (self.resolution.stmt_symbols.get(statement)) |symbol| try self.result.symbol_types.put(symbol, value_type);
                break :blk self.result.types.builtins.void;
            },
            .return_stmt => |return_statement| blk: {
                const value_type = try self.infer(return_statement.value);
                if (!self.assignable(value_type, expected_return)) try self.report(return_statement.span, "Type Error: возвращаемое значение не совпадает с типом функции", .{});
                break :blk expected_return;
            },
            .expr => |expression| self.infer(expression.value),
            else => self.result.types.builtins.void,
        };
    }

    fn infer(self: *Checker, expression: ast.ExprId) anyerror!types.TypeId {
        const inferred = switch (self.tree.expr(expression).*) {
            .number => self.result.types.builtins.number,
            .boolean => self.result.types.builtins.boolean,
            .string => self.result.types.builtins.string,
            .ident => blk: {
                const symbol = self.resolution.expr_symbols.get(expression) orelse break :blk try self.result.types.poison();
                break :blk self.result.symbol_types.get(symbol) orelse try self.result.types.poison();
            },
            .unary => |unary| try self.inferUnary(unary),
            .binary => |binary| try self.inferBinary(binary),
            .call => |call| try self.inferCall(call),
            .tuple => |tuple| blk: {
                var element_types: std.ArrayList(types.TypeId) = .empty;
                defer element_types.deinit(self.result.allocator);
                for (tuple.elements) |element| try element_types.append(self.result.allocator, try self.infer(element));
                break :blk try self.result.types.tuple(element_types.items);
            },
            .array => |array| blk: {
                if (array.elements.len == 0) break :blk try self.result.types.array(try self.result.types.poison());
                const element_type = try self.infer(array.elements[0]);
                for (array.elements[1..]) |element| {
                    if (!self.assignable(try self.infer(element), element_type)) try self.report(array.span, "Type Error: элементы массива имеют разные типы", .{});
                }
                break :blk try self.result.types.array(element_type);
            },
            .map => |map| blk: {
                if (map.entries.len == 0) break :blk try self.result.types.map(try self.result.types.poison(), try self.result.types.poison());
                const key = try self.infer(map.entries[0].key);
                const value = try self.infer(map.entries[0].value);
                for (map.entries[1..]) |entry| {
                    if (!self.assignable(try self.infer(entry.key), key)) try self.report(entry.span, "Type Error: ключи соответствия имеют разные типы", .{});
                    if (!self.assignable(try self.infer(entry.value), value)) try self.report(entry.span, "Type Error: значения соответствия имеют разные типы", .{});
                }
                break :blk try self.result.types.map(key, value);
            },
            .index => |index| try self.inferIndex(index),
            .lambda => |lambda| try self.inferLambda(expression, lambda, null),
            .if_expr => |conditional| try self.inferIf(conditional),
            .while_expr => |loop| try self.inferWhile(loop),
            else => try self.result.types.poison(),
        };
        try self.result.expression_types.put(expression, inferred);
        return inferred;
    }

    fn inferExpected(self: *Checker, expression: ast.ExprId, expected: types.TypeId) anyerror!types.TypeId {
        if (self.tree.expr(expression).* == .lambda) {
            return self.inferLambda(expression, self.tree.expr(expression).lambda, expected);
        }
        return self.infer(expression);
    }

    fn inferBlock(self: *Checker, statements: []const ast.StmtId) anyerror!types.TypeId {
        var result_type = self.result.types.builtins.void;
        for (statements) |statement| result_type = try self.inferStatement(statement, self.current_return orelse self.result.types.builtins.void);
        return result_type;
    }

    fn inferIf(self: *Checker, conditional: anytype) anyerror!types.TypeId {
        const condition = try self.infer(conditional.condition);
        if (!self.assignable(condition, self.result.types.builtins.boolean)) {
            try self.report(conditional.span, "Type Error: условие 'если' должно иметь тип Булево", .{});
        }
        const then_type = try self.inferBlock(conditional.then_branch);
        const else_type = try self.inferBlock(conditional.else_branch);
        if (!self.assignable(then_type, else_type) or !self.assignable(else_type, then_type)) {
            try self.report(conditional.span, "Type Error: ветви 'если' возвращают разные типы", .{});
            return self.result.types.poison();
        }
        return then_type;
    }

    fn inferWhile(self: *Checker, loop: anytype) anyerror!types.TypeId {
        const condition = try self.infer(loop.condition);
        if (!self.assignable(condition, self.result.types.builtins.boolean)) {
            try self.report(loop.span, "Type Error: условие 'пока' должно иметь тип Булево", .{});
        }
        _ = try self.inferBlock(loop.body);
        return self.result.types.builtins.void;
    }

    fn inferIndex(self: *Checker, index: anytype) anyerror!types.TypeId {
        const object_type = try self.infer(index.object);
        const index_type = try self.infer(index.index);
        const object = self.result.types.get(object_type) orelse return self.result.types.poison();
        return switch (object.*) {
            .array => |element| blk: {
                if (!self.assignable(index_type, self.result.types.builtins.integer) and !self.assignable(index_type, self.result.types.builtins.number)) {
                    try self.report(index.span, "Type Error: индекс массива должен быть числом", .{});
                }
                break :blk element;
            },
            .map => |map| blk: {
                if (!self.assignable(index_type, map.key)) try self.report(index.span, "Type Error: ключ соответствия имеет неверный тип", .{});
                break :blk map.value;
            },
            else => blk: {
                try self.report(index.span, "Type Error: индексирование поддержано только для массива и соответствия", .{});
                break :blk try self.result.types.poison();
            },
        };
    }

    fn inferLambda(self: *Checker, expression: ast.ExprId, lambda: anytype, expected: ?types.TypeId) anyerror!types.TypeId {
        var parameter_types: std.ArrayList(types.TypeId) = .empty;
        defer parameter_types.deinit(self.result.allocator);
        var return_type = self.result.types.builtins.void;
        if (expected) |expected_type| {
            const signature = self.result.types.get(expected_type) orelse return self.result.types.poison();
            switch (signature.*) {
                .function => |function| {
                    if (lambda.parameters.len != function.parameters.len) {
                        try self.report(lambda.span, "Type Error: лямбда имеет неверное количество параметров", .{});
                    }
                    for (lambda.parameters, 0..) |parameter, index| {
                        if (index < function.parameters.len) {
                            try parameter_types.append(self.result.allocator, function.parameters[index]);
                        } else {
                            try parameter_types.append(self.result.allocator, try self.result.types.poison());
                        }
                        if (parameter.type_annotation) |annotation| {
                            const declared = try self.resolveType(annotation);
                            if (!self.assignable(declared, parameter_types.items[index])) try self.report(parameter.span, "Type Error: параметр лямбды не совпадает с ожидаемым типом", .{});
                        }
                    }
                    return_type = function.return_type;
                },
                else => {
                    try self.report(lambda.span, "Type Error: лямбда ожидает тип функции", .{});
                    return self.result.types.poison();
                },
            }
        } else {
            for (lambda.parameters) |parameter| {
                try parameter_types.append(self.result.allocator, if (parameter.type_annotation) |annotation| try self.resolveType(annotation) else try self.result.types.poison());
            }
            return_type = if (lambda.return_type) |annotation| try self.resolveType(annotation) else try self.result.types.poison();
        }

        const parameter_symbols = self.resolution.lambda_parameters.get(expression) orelse &.{};
        for (parameter_symbols, parameter_types.items) |symbol, parameter_type| try self.result.symbol_types.put(symbol, parameter_type);
        const previous_return = self.current_return;
        self.current_return = return_type;
        defer self.current_return = previous_return;
        const body_type = try self.inferBlock(lambda.body);
        if (!self.assignable(body_type, return_type)) try self.report(lambda.span, "Type Error: тело лямбды не совпадает с типом возврата", .{});
        return self.result.types.function(parameter_types.items, return_type);
    }

    fn inferUnary(self: *Checker, unary: anytype) anyerror!types.TypeId {
        const operand = try self.infer(unary.operand);
        return switch (unary.operator) {
            .negate => self.result.types.builtins.boolean,
            .tilde => self.result.types.builtins.integer,
            else => operand,
        };
    }

    fn inferBinary(self: *Checker, binary: anytype) anyerror!types.TypeId {
        const left = try self.infer(binary.left);
        const right = try self.infer(binary.right);
        return switch (binary.operator) {
            .assign => blk: {
                if (!self.assignable(right, left)) try self.report(binary.span, "Type Error: присваивание несовместимых типов", .{});
                break :blk self.result.types.builtins.void;
            },
            .equal, .not_equal, .less, .less_equal, .greater, .greater_equal, .and_expr, .or_expr => self.result.types.builtins.boolean,
            .plus => if (self.assignable(left, self.result.types.builtins.string) and self.assignable(right, self.result.types.builtins.string)) self.result.types.builtins.string else left,
            else => left,
        };
    }

    fn inferCall(self: *Checker, call: anytype) anyerror!types.TypeId {
        const callee_type = try self.infer(call.callee);
        const entry = self.result.types.get(callee_type) orelse return self.result.types.poison();
        switch (entry.*) {
            .function => |function| {
                if (call.arguments.len != function.parameters.len) try self.report(call.span, "Type Error: неверное количество аргументов функции", .{});
                const shared = @min(call.arguments.len, function.parameters.len);
                for (call.arguments[0..shared], function.parameters[0..shared]) |argument, parameter| {
                    if (!self.assignable(try self.infer(argument), parameter)) try self.report(call.span, "Type Error: аргумент не совпадает с типом параметра", .{});
                }
                return function.return_type;
            },
            else => {
                try self.report(call.span, "Type Error: вызвано значение, не являющееся функцией", .{});
                return self.result.types.poison();
            },
        }
    }

    fn resolveType(self: *Checker, type_node: ast.TypeId) !types.TypeId {
        return switch (self.tree.typeNode(type_node).*) {
            .ident => |ident| builtinType(&self.result.types, ident.name) orelse blk: {
                try self.report(ident.span, "Type Error: неизвестный тип '{s}'", .{ident.name});
                break :blk try self.result.types.poison();
            },
            .generic => |generic| blk: {
                if (std.mem.eql(u8, generic.name, "Массив") and generic.parameters.len == 1) break :blk try self.result.types.array(try self.resolveType(generic.parameters[0]));
                if (std.mem.eql(u8, generic.name, "Соответствие") and generic.parameters.len == 2) break :blk try self.result.types.map(try self.resolveType(generic.parameters[0]), try self.resolveType(generic.parameters[1]));
                try self.report(generic.span, "Type Error: неизвестный generic-тип '{s}'", .{generic.name});
                break :blk try self.result.types.poison();
            },
            .tuple => |tuple| blk: {
                var elements: std.ArrayList(types.TypeId) = .empty;
                defer elements.deinit(self.result.allocator);
                for (tuple.elements) |element| try elements.append(self.result.allocator, try self.resolveType(element));
                break :blk try self.result.types.tuple(elements.items);
            },
            .function => |function| blk: {
                var parameters: std.ArrayList(types.TypeId) = .empty;
                defer parameters.deinit(self.result.allocator);
                for (function.parameters) |parameter| try parameters.append(self.result.allocator, try self.resolveType(parameter));
                break :blk try self.result.types.function(parameters.items, try self.resolveType(function.return_type));
            },
            else => try self.result.types.poison(),
        };
    }

    fn assignable(self: *const Checker, actual: types.TypeId, expected: types.TypeId) bool {
        const actual_type = self.result.types.get(actual) orelse return true;
        const expected_type = self.result.types.get(expected) orelse return true;
        if (actual_type.* == .poison or expected_type.* == .poison) return true;
        return self.result.types.eql(actual, expected);
    }
};

pub fn check(allocator: std.mem.Allocator, tree: *const ast.Ast, resolution: *const resolver.Resolution) !CheckResult {
    var result = try CheckResult.init(allocator);
    errdefer result.deinit();
    var checker = Checker{ .tree = tree, .resolution = resolution, .result = &result };
    try checker.signaturePass();
    try checker.bodyPass();
    return result;
}

fn builtinType(store: *types.TypeStore, name: []const u8) ?types.TypeId {
    if (std.mem.eql(u8, name, "Число")) return store.builtins.number;
    if (std.mem.eql(u8, name, "Целое")) return store.builtins.integer;
    if (std.mem.eql(u8, name, "Булево")) return store.builtins.boolean;
    if (std.mem.eql(u8, name, "Строка")) return store.builtins.string;
    if (std.mem.eql(u8, name, "Пусто")) return store.builtins.void;
    if (std.mem.eql(u8, name, "Никогда")) return store.builtins.never;
    if (std.mem.eql(u8, name, "Ошибка")) return store.builtins.error_value;
    return null;
}

test "type checker verifies local arithmetic and direct calls" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ сложить(a: Число, b: Число) -> Число\na + b\nконец\nфунк старт() -> Число\nпер сумма: Число = сложить(1, 2)\nсумма\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}

test "type checker accumulates argument type diagnostics" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ число(x: Число) -> Число\nx\nконец\nфунк старт() -> Число\nчисло(\"нет\")\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 1), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Type Error: аргумент не совпадает с типом параметра", checked.diagnostics.items.items[0].message);
}

test "type checker checks control-flow conditions and branch results" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ выбрать(условие: Булево) -> Число\nесли условие тогда\n1\nиначе\n2\nконец\nконец\nфунк ошибка() -> Число\nесли 1 тогда\n\"нет\"\nиначе\n2\nконец\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 2), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Type Error: условие 'если' должно иметь тип Булево", checked.diagnostics.items.items[0].message);
    try std.testing.expectEqualStrings("Type Error: ветви 'если' возвращают разные типы", checked.diagnostics.items.items[1].message);
}

test "type checker infers collection elements through indexing" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ элемент() -> Число\nпер числа = массив(1, 2)\nпер цены = соответствие(\"яблоко\" = числа[0])\nцены[\"яблоко\"]\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    const function = parsed.ast.decl(parsed.ast.program.?.declarations[0]).function;
    const index = parsed.ast.stmt(function.body[2]).expr.value;
    try std.testing.expectEqual(checked.types.builtins.number, checked.expression_types.get(index).?);
}

test "type checker infers lambda parameters from a function annotation" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ применить(f: функ(Число) -> Число, x: Число) -> Число\nf(x)\nконец\nфунк старт() -> Число\nпер удвоить: функ(Число) -> Число = функ(значение)\nзначение * 2\nконец\nприменить(удвоить, 3)\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}
