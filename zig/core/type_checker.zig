const std = @import("std");
const ast = @import("ast.zig");
const diagnostic = @import("diagnostic.zig");
const resolver = @import("resolver.zig");
const source = @import("source.zig");
const symbols = @import("symbols.zig");
const types = @import("types.zig");

pub const NominalField = struct {
    name: []const u8,
    typ: types.TypeId,
};

pub const CheckResult = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    types: types.TypeStore,
    diagnostics: diagnostic.DiagnosticList = .{},
    expression_types: std.AutoHashMap(ast.ExprId, types.TypeId),
    symbol_types: std.AutoHashMap(symbols.SymbolId, types.TypeId),
    nominal_fields: std.AutoHashMap(symbols.SymbolId, []const NominalField),
    type_aliases: std.AutoHashMap(symbols.SymbolId, types.TypeId),
    alias_type_nodes: std.AutoHashMap(symbols.SymbolId, ast.TypeId),

    pub fn init(allocator: std.mem.Allocator) !CheckResult {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .types = try types.TypeStore.init(allocator),
            .expression_types = .init(allocator),
            .symbol_types = .init(allocator),
            .nominal_fields = .init(allocator),
            .type_aliases = .init(allocator),
            .alias_type_nodes = .init(allocator),
        };
    }

    pub fn deinit(self: *CheckResult) void {
        self.alias_type_nodes.deinit();
        self.type_aliases.deinit();
        self.nominal_fields.deinit();
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
    loop_depth: usize = 0,
    resolving_aliases: std.AutoHashMap(symbols.SymbolId, void),

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

    fn typeAliasPass(self: *Checker) !void {
        for (self.tree.program.?.declarations) |declaration| {
            const alias = switch (self.tree.decl(declaration).*) {
                .type_alias => |value| value,
                else => continue,
            };
            const symbol = self.resolution.decl_symbols.get(declaration) orelse continue;
            try self.result.alias_type_nodes.put(symbol, alias.aliased_type);
        }
    }

    fn nominalPass(self: *Checker) !void {
        for (self.tree.program.?.declarations) |declaration| {
            const structure = switch (self.tree.decl(declaration).*) {
                .struct_decl => |value| value,
                else => continue,
            };
            if (structure.is_ffi or structure.type_parameters.len != 0) continue;
            const symbol = self.resolution.decl_symbols.get(declaration) orelse continue;
            var fields: std.ArrayList(NominalField) = .empty;
            defer fields.deinit(self.result.allocator);
            for (structure.fields) |field| {
                const annotation = field.type_annotation orelse continue;
                try fields.append(self.result.allocator, .{
                    .name = field.name,
                    .typ = try self.resolveType(annotation),
                });
            }
            try self.result.nominal_fields.put(symbol, try self.result.arena.allocator().dupe(NominalField, fields.items));
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
        const actual = try self.inferBlockExpected(body, function_type.return_type);
        if (!self.assignable(actual, function_type.return_type)) {
            const span = self.tree.decl(declaration).function.span;
            try self.report(span, "Type Error: функция должна возвращать объявленный тип", .{});
        }
    }

    fn inferStatement(self: *Checker, statement: ast.StmtId, expected_return: types.TypeId, expected_value: ?types.TypeId) anyerror!types.TypeId {
        return switch (self.tree.stmt(statement).*) {
            .let => |let| blk: {
                const expected = if (let.type_annotation) |annotation| try self.resolveType(annotation) else null;
                const value_type = if (expected) |type_id| try self.inferExpected(let.value, type_id) else try self.infer(let.value);
                if (expected) |type_id| {
                    if (!self.assignable(value_type, type_id)) try self.report(let.span, "Type Error: значение переменной не совпадает с аннотацией", .{});
                }
                if (self.isType(value_type, self.result.types.builtins.void)) try self.report(let.span, "Type Error: переменная не может иметь тип 'Пусто'", .{});
                if (let.destructure_type != null) {
                    try self.bindNominalDestructure(statement, let, value_type);
                } else {
                    try self.bindStatementValue(statement, value_type, let.span, "Type Error: деструктуризация ожидает тупл с соответствующим числом значений");
                }
                break :blk self.result.types.builtins.void;
            },
            .return_stmt => |return_statement| blk: {
                const value_type = try self.inferExpected(return_statement.value, expected_return);
                if (!self.assignable(value_type, expected_return)) try self.report(return_statement.span, "Type Error: возвращаемое значение не совпадает с типом функции", .{});
                break :blk expected_return;
            },
            .expr => |expression| if (expected_value) |expected| self.inferExpected(expression.value, expected) else self.infer(expression.value),
            .for_in => |loop| try self.inferForIn(statement, loop),
            .for_range => |range| try self.inferForRange(statement, range),
            .continue_stmt => |span| blk: {
                if (self.loop_depth == 0) try self.report(span, "Type Error: 'продолжить' можно использовать только внутри цикла", .{});
                break :blk self.result.types.builtins.void;
            },
            .break_stmt => |span| blk: {
                if (self.loop_depth == 0) try self.report(span, "Type Error: 'прервать' можно использовать только внутри цикла", .{});
                break :blk self.result.types.builtins.void;
            },
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
                if (self.resolution.symbols.get(symbol)) |entry| {
                    if (entry.kind == .type) break :blk try self.result.types.nominal(symbol, &.{});
                }
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
            .property => |property| try self.inferProperty(expression, property),
            .lambda => |lambda| try self.inferLambda(expression, lambda, null),
            .if_expr => |conditional| try self.inferIf(conditional),
            .while_expr => |loop| try self.inferWhile(loop),
            else => try self.result.types.poison(),
        };
        return self.recordExpressionType(expression, inferred);
    }

    fn inferExpected(self: *Checker, expression: ast.ExprId, expected: types.TypeId) anyerror!types.TypeId {
        return switch (self.tree.expr(expression).*) {
            .lambda => |lambda| self.recordExpressionType(expression, try self.inferLambda(expression, lambda, expected)),
            .number => |number| if (expected == self.result.types.builtins.integer) blk: {
                if (number.value != std.math.trunc(number.value)) {
                    try self.report(number.span, "Type Error: дробный литерал несовместим с Целое", .{});
                }
                break :blk self.recordExpressionType(expression, expected);
            } else self.infer(expression),
            .unary => |unary| if (expected == self.result.types.builtins.integer and unary.operator == .minus) blk: {
                _ = try self.inferExpected(unary.operand, expected);
                break :blk self.recordExpressionType(expression, expected);
            } else self.infer(expression),
            .binary => |binary| if (expected == self.result.types.builtins.integer and (binary.operator == .plus or binary.operator == .minus or binary.operator == .star)) blk: {
                const left = try self.inferExpected(binary.left, expected);
                const right = try self.inferExpected(binary.right, expected);
                if (!self.assignable(left, expected) or !self.assignable(right, expected)) {
                    try self.report(binary.span, "Type Error: целочисленное выражение содержит несовместимый операнд", .{});
                    break :blk self.recordExpressionType(expression, try self.result.types.poison());
                }
                break :blk self.recordExpressionType(expression, expected);
            } else self.infer(expression),
            .tuple => |tuple| blk: {
                const expected_type = self.result.types.get(expected) orelse break :blk self.infer(expression);
                if (expected_type.* != .tuple or expected_type.tuple.len != tuple.elements.len) break :blk self.infer(expression);
                for (tuple.elements, expected_type.tuple) |element, element_type| {
                    const actual = try self.inferExpected(element, element_type);
                    if (!self.assignable(actual, element_type)) try self.report(tuple.span, "Type Error: элемент тупла не совпадает с ожидаемым типом", .{});
                }
                break :blk self.recordExpressionType(expression, expected);
            },
            .array => |array| blk: {
                const expected_type = self.result.types.get(expected) orelse break :blk self.infer(expression);
                const element_type = switch (expected_type.*) {
                    .array => |element| element,
                    else => break :blk self.infer(expression),
                };
                for (array.elements) |element| {
                    const actual = try self.inferExpected(element, element_type);
                    if (!self.assignable(actual, element_type)) try self.report(array.span, "Type Error: элемент массива не совпадает с ожидаемым типом", .{});
                }
                break :blk self.recordExpressionType(expression, expected);
            },
            .map => |map| blk: {
                const expected_type = self.result.types.get(expected) orelse break :blk self.infer(expression);
                const expected_map = switch (expected_type.*) {
                    .map => |value| value,
                    else => break :blk self.infer(expression),
                };
                for (map.entries) |entry| {
                    const key = try self.inferExpected(entry.key, expected_map.key);
                    const value = try self.inferExpected(entry.value, expected_map.value);
                    if (!self.assignable(key, expected_map.key)) try self.report(entry.span, "Type Error: ключ соответствия не совпадает с ожидаемым типом", .{});
                    if (!self.assignable(value, expected_map.value)) try self.report(entry.span, "Type Error: значение соответствия не совпадает с ожидаемым типом", .{});
                }
                break :blk self.recordExpressionType(expression, expected);
            },
            .if_expr => |conditional| self.recordExpressionType(expression, try self.inferIfExpected(conditional, expected)),
            else => self.infer(expression),
        };
    }

    fn inferBlock(self: *Checker, statements: []const ast.StmtId) anyerror!types.TypeId {
        return self.inferBlockExpected(statements, null);
    }

    fn inferBlockExpected(self: *Checker, statements: []const ast.StmtId, expected_last: ?types.TypeId) anyerror!types.TypeId {
        var result_type = self.result.types.builtins.void;
        for (statements, 0..) |statement, index| {
            const expected_value = if (index + 1 == statements.len) expected_last else null;
            result_type = try self.inferStatement(statement, self.current_return orelse self.result.types.builtins.void, expected_value);
        }
        return result_type;
    }

    fn inferIf(self: *Checker, conditional: anytype) anyerror!types.TypeId {
        return self.inferIfExpected(conditional, null);
    }

    fn inferIfExpected(self: *Checker, conditional: anytype, expected: ?types.TypeId) anyerror!types.TypeId {
        const condition = try self.infer(conditional.condition);
        if (!self.assignable(condition, self.result.types.builtins.boolean)) {
            try self.report(conditional.span, "Type Error: условие 'если' должно иметь тип Булево", .{});
        }
        const then_type = try self.inferBlockExpected(conditional.then_branch, expected);
        const else_type = try self.inferBlockExpected(conditional.else_branch, expected);
        if (!self.assignable(then_type, else_type) or !self.assignable(else_type, then_type)) {
            try self.report(conditional.span, "Type Error: ветви 'если' возвращают разные типы", .{});
            return self.result.types.poison();
        }
        if (expected) |expected_type| {
            if (!self.assignable(then_type, expected_type) or !self.assignable(else_type, expected_type)) {
                try self.report(conditional.span, "Type Error: ветви 'если' не совпадают с ожидаемым типом", .{});
                return self.result.types.poison();
            }
            return expected_type;
        }
        return then_type;
    }

    fn recordExpressionType(self: *Checker, expression: ast.ExprId, inferred: types.TypeId) !types.TypeId {
        try self.result.expression_types.put(expression, inferred);
        return inferred;
    }

    fn inferWhile(self: *Checker, loop: anytype) anyerror!types.TypeId {
        const condition = try self.infer(loop.condition);
        if (!self.assignable(condition, self.result.types.builtins.boolean)) {
            try self.report(loop.span, "Type Error: условие 'пока' должно иметь тип Булево", .{});
        }
        self.loop_depth += 1;
        defer self.loop_depth -= 1;
        _ = try self.inferBlock(loop.body);
        return self.result.types.builtins.void;
    }

    fn inferForIn(self: *Checker, statement: ast.StmtId, loop: anytype) anyerror!types.TypeId {
        const iterable_type = try self.infer(loop.iterable);
        const iterable = self.result.types.get(iterable_type) orelse return self.result.types.builtins.void;
        switch (iterable.*) {
            .array => |element| try self.bindStatementValue(statement, element, loop.span, "Type Error: шаблон 'для (...)' не совпадает с элементом массива"),
            .map => {
                try self.report(loop.span, "Type Error: Соответствие не поддерживает позиционный доступ; для перебора элементов используйте .записи() и 'для (ключ, значение) в ...'", .{});
                try self.bindStatementPoison(statement);
            },
            .poison => try self.bindStatementPoison(statement),
            else => {
                try self.report(loop.span, "Type Error: тип не поддерживает 'для x в' (нужен Массив или Итерируемое)", .{});
                try self.bindStatementPoison(statement);
            },
        }
        self.loop_depth += 1;
        defer self.loop_depth -= 1;
        _ = try self.inferBlock(loop.body);
        return self.result.types.builtins.void;
    }

    fn inferForRange(self: *Checker, statement: ast.StmtId, range: anytype) anyerror!types.TypeId {
        const integer = self.result.types.builtins.integer;
        const start = try self.infer(range.start);
        const end = try self.infer(range.end);
        if (!self.assignable(start, integer) and !self.assignable(start, self.result.types.builtins.number)) {
            try self.report(range.span, "Type Error: начало диапазона 'для' должно быть числом", .{});
        }
        if (!self.assignable(end, integer) and !self.assignable(end, self.result.types.builtins.number)) {
            try self.report(range.span, "Type Error: конец диапазона 'для' должен быть числом", .{});
        }
        try self.bindStatementValue(statement, integer, range.span, "Type Error: диапазон 'для' объявляет одну переменную");
        self.loop_depth += 1;
        defer self.loop_depth -= 1;
        _ = try self.inferBlock(range.body);
        return self.result.types.builtins.void;
    }

    fn bindStatementValue(self: *Checker, statement: ast.StmtId, value_type: types.TypeId, span: source.Span, mismatch_message: []const u8) !void {
        const bindings = self.resolution.stmt_bindings.get(statement) orelse return;
        if (bindings.len == 1) {
            try self.result.symbol_types.put(bindings[0], value_type);
            return;
        }
        const value = self.result.types.get(value_type) orelse return;
        if (value.* == .tuple and value.tuple.len == bindings.len) {
            for (bindings, value.tuple) |symbol, element_type| try self.result.symbol_types.put(symbol, element_type);
            return;
        }
        try self.report(span, "{s}", .{mismatch_message});
        try self.bindStatementPoison(statement);
    }

    fn bindStatementPoison(self: *Checker, statement: ast.StmtId) !void {
        const bindings = self.resolution.stmt_bindings.get(statement) orelse return;
        const poison = try self.result.types.poison();
        for (bindings) |symbol| try self.result.symbol_types.put(symbol, poison);
    }

    fn bindNominalDestructure(self: *Checker, statement: ast.StmtId, let: anytype, value_type: types.TypeId) !void {
        const bindings = self.resolution.stmt_bindings.get(statement) orelse return;
        const expected_name = let.destructure_type orelse return;
        const value = self.result.types.get(value_type) orelse return;
        const nominal = switch (value.*) {
            .nominal => |entry| entry,
            else => {
                try self.report(let.span, "Type Error: деструктуризация '{s}' ожидает структуру", .{expected_name});
                try self.bindStatementPoison(statement);
                return;
            },
        };
        const symbol = self.resolution.symbols.get(nominal.symbol) orelse {
            try self.bindStatementPoison(statement);
            return;
        };
        if (!std.mem.eql(u8, symbol.name, expected_name)) {
            try self.report(let.span, "Type Error: деструктуризация ожидает структуру '{s}'", .{expected_name});
            try self.bindStatementPoison(statement);
            return;
        }
        const fields = self.result.nominal_fields.get(nominal.symbol) orelse {
            try self.report(let.span, "Type Error: тип '{s}' нельзя деструктурировать", .{expected_name});
            try self.bindStatementPoison(statement);
            return;
        };
        if (let.destructure_field_names) |names| {
            if (names.len != bindings.len) {
                try self.report(let.span, "Type Error: именованная деструктуризация имеет неверное число полей", .{});
                try self.bindStatementPoison(statement);
                return;
            }
            for (bindings, names) |binding, name| {
                for (fields) |field| {
                    if (!std.mem.eql(u8, field.name, name)) continue;
                    try self.result.symbol_types.put(binding, field.typ);
                    break;
                } else {
                    try self.report(let.span, "Type Error: у структуры '{s}' нет поля '{s}'", .{ expected_name, name });
                    try self.result.symbol_types.put(binding, try self.result.types.poison());
                }
            }
            return;
        }
        if (fields.len != bindings.len) {
            try self.report(let.span, "Type Error: деструктуризация структуры ожидает все поля по порядку", .{});
            try self.bindStatementPoison(statement);
            return;
        }
        for (bindings, fields) |binding, field| try self.result.symbol_types.put(binding, field.typ);
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

    fn inferProperty(self: *Checker, expression: ast.ExprId, property: anytype) anyerror!types.TypeId {
        if (self.resolution.expr_symbols.get(expression)) |symbol| {
            if (self.resolution.symbols.get(symbol)) |entry| {
                if (entry.kind == .enum_variant) return self.result.types.poison();
            }
        }
        const object_type = try self.infer(property.object);
        const object = self.result.types.get(object_type) orelse return self.result.types.poison();
        switch (object.*) {
            .tuple => |elements| if (tuplePropertyIndex(property.property)) |index| {
                if (index < elements.len) return elements[index];
            },
            .nominal => |nominal| if (self.result.nominal_fields.get(nominal.symbol)) |fields| {
                for (fields) |field| {
                    if (std.mem.eql(u8, field.name, property.property)) return field.typ;
                }
            },
            else => {},
        }
        try self.report(property.span, "Type Error: у типа нет поля '{s}'", .{property.property});
        return self.result.types.poison();
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
        const body_type = try self.inferBlockExpected(lambda.body, return_type);
        if (!self.assignable(body_type, return_type)) try self.report(lambda.span, "Type Error: тело лямбды не совпадает с типом возврата", .{});
        return self.result.types.function(parameter_types.items, return_type);
    }

    fn inferUnary(self: *Checker, unary: anytype) anyerror!types.TypeId {
        const operand = try self.infer(unary.operand);
        return switch (unary.operator) {
            .negate => blk: {
                if (!self.isType(operand, self.result.types.builtins.boolean)) try self.report(unary.span, "Type Error: оператор 'не' ожидает Булево", .{});
                break :blk self.result.types.builtins.boolean;
            },
            .tilde => blk: {
                if (!self.isType(operand, self.result.types.builtins.integer)) try self.report(unary.span, "Type Error: оператор '~' ожидает Целое", .{});
                break :blk self.result.types.builtins.integer;
            },
            .minus => blk: {
                if (!self.isNumeric(operand)) {
                    try self.report(unary.span, "Type Error: унарный '-' ожидает число", .{});
                    break :blk try self.result.types.poison();
                }
                break :blk operand;
            },
            else => operand,
        };
    }

    fn inferBinary(self: *Checker, binary: anytype) anyerror!types.TypeId {
        var left = try self.infer(binary.left);
        var right = try self.infer(binary.right);
        left = try self.narrowIntegerLiteral(binary.left, left, right);
        right = try self.narrowIntegerLiteral(binary.right, right, left);
        return switch (binary.operator) {
            .assign => blk: {
                try self.checkAssignmentTarget(binary.left, binary.span);
                if (!self.assignable(right, left)) try self.report(binary.span, "Type Error: присваивание несовместимых типов", .{});
                break :blk self.result.types.builtins.void;
            },
            .equal, .not_equal => blk: {
                if (!self.isPoison(left) and !self.isPoison(right) and !self.result.types.eql(left, right)) {
                    try self.report(binary.span, "Type Error: оператор сравнения ожидает значения одного типа", .{});
                }
                break :blk self.result.types.builtins.boolean;
            },
            .less, .less_equal, .greater, .greater_equal => blk: {
                if (!self.isPoison(left) and !self.isPoison(right) and (!self.isNumeric(left) or !self.isNumeric(right) or !self.result.types.eql(left, right))) {
                    try self.report(binary.span, "Type Error: оператор сравнения ожидает два числа одного типа", .{});
                }
                break :blk self.result.types.builtins.boolean;
            },
            .and_expr, .or_expr => blk: {
                if (!self.isPoison(left) and !self.isPoison(right) and (!self.isType(left, self.result.types.builtins.boolean) or !self.isType(right, self.result.types.builtins.boolean))) {
                    try self.report(binary.span, "Type Error: логический оператор ожидает два значения Булево", .{});
                }
                break :blk self.result.types.builtins.boolean;
            },
            .plus => blk: {
                if (self.isType(left, self.result.types.builtins.string) and self.isType(right, self.result.types.builtins.string)) break :blk self.result.types.builtins.string;
                if (self.isPoison(left) or self.isPoison(right)) break :blk try self.result.types.poison();
                if (!self.isNumeric(left) or !self.isNumeric(right) or !self.result.types.eql(left, right)) {
                    try self.report(binary.span, "Type Error: оператор '+' ожидает два числа одного типа или две строки", .{});
                    break :blk try self.result.types.poison();
                }
                break :blk left;
            },
            .minus, .star, .slash => blk: {
                if (self.isPoison(left) or self.isPoison(right)) break :blk try self.result.types.poison();
                if (!self.isNumeric(left) or !self.isNumeric(right) or !self.result.types.eql(left, right)) {
                    try self.report(binary.span, "Type Error: арифметический оператор ожидает два числа одного типа", .{});
                    break :blk try self.result.types.poison();
                }
                break :blk left;
            },
            .percent, .ampersand, .pipe, .caret, .less_less, .greater_greater => blk: {
                if (self.isPoison(left) or self.isPoison(right)) break :blk try self.result.types.poison();
                if (!self.isType(left, self.result.types.builtins.integer) or !self.isType(right, self.result.types.builtins.integer)) {
                    try self.report(binary.span, "Type Error: целочисленный оператор ожидает два значения Целое", .{});
                    break :blk try self.result.types.poison();
                }
                break :blk self.result.types.builtins.integer;
            },
            else => try self.result.types.poison(),
        };
    }

    fn narrowIntegerLiteral(self: *Checker, expression: ast.ExprId, inferred: types.TypeId, other: types.TypeId) !types.TypeId {
        if (self.isType(inferred, self.result.types.builtins.number) and self.isType(other, self.result.types.builtins.integer)) {
            return self.inferExpected(expression, self.result.types.builtins.integer);
        }
        return inferred;
    }

    fn checkAssignmentTarget(self: *Checker, expression: ast.ExprId, span: source.Span) !void {
        switch (self.tree.expr(expression).*) {
            .ident => {
                const symbol = self.resolution.expr_symbols.get(expression) orelse return;
                const entry = self.resolution.symbols.get(symbol) orelse return;
                if (entry.kind == .constant or entry.is_const) {
                    try self.report(span, "Type Error: нельзя присваивать константе", .{});
                } else if (entry.kind != .variable) {
                    try self.report(span, "Type Error: присваивание возможно только переменной, полю или индексу", .{});
                }
            },
            .property, .index => {},
            else => try self.report(span, "Type Error: присваивание возможно только переменной, полю или индексу", .{}),
        }
    }

    fn isType(self: *const Checker, actual: types.TypeId, expected: types.TypeId) bool {
        return self.result.types.eql(actual, expected);
    }

    fn isNumeric(self: *const Checker, type_id: types.TypeId) bool {
        return self.isType(type_id, self.result.types.builtins.number) or self.isType(type_id, self.result.types.builtins.integer);
    }

    fn isPoison(self: *const Checker, type_id: types.TypeId) bool {
        const entry = self.result.types.get(type_id) orelse return true;
        return entry.* == .poison;
    }

    fn inferCall(self: *Checker, call: anytype) anyerror!types.TypeId {
        switch (self.tree.expr(call.callee).*) {
            .property => |property| {
                const object_type = try self.infer(property.object);
                const object = self.result.types.get(object_type) orelse return self.result.types.poison();
                switch (object.*) {
                    .array => |element| {
                        if (std.mem.eql(u8, property.property, "длина")) {
                            try self.checkMethodArity(call, "длина", 0);
                            return self.result.types.builtins.integer;
                        }
                        if (std.mem.eql(u8, property.property, "есть")) {
                            try self.checkMethodArity(call, "есть", 1);
                            if (call.arguments.len != 0) {
                                const index = try self.infer(call.arguments[0]);
                                if (!self.isNumeric(index)) try self.report(call.span, "Type Error: индекс массива должен быть числом", .{});
                            }
                            return self.result.types.builtins.boolean;
                        }
                        if (std.mem.eql(u8, property.property, "получить")) {
                            try self.checkMethodArity(call, "получить", 2);
                            if (call.arguments.len != 0) {
                                const index = try self.infer(call.arguments[0]);
                                if (!self.isNumeric(index)) try self.report(call.span, "Type Error: индекс массива должен быть числом", .{});
                            }
                            if (call.arguments.len > 1 and !self.assignable(try self.inferExpected(call.arguments[1], element), element)) {
                                try self.report(call.span, "Type Error: значение по умолчанию имеет неверный тип", .{});
                            }
                            return element;
                        }
                        if (std.mem.eql(u8, property.property, "добавить")) {
                            try self.checkMethodArity(call, "добавить", 1);
                            if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], element), element)) {
                                try self.report(call.span, "Type Error: элемент массива имеет неверный тип", .{});
                            }
                            return self.result.types.builtins.void;
                        }
                        if (std.mem.eql(u8, property.property, "содержит")) {
                            try self.checkMethodArity(call, "содержит", 1);
                            if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], element), element)) {
                                try self.report(call.span, "Type Error: элемент массива имеет неверный тип", .{});
                            }
                            return self.result.types.builtins.boolean;
                        }
                    },
                    .map => |map| {
                        if (std.mem.eql(u8, property.property, "длина")) {
                            try self.checkMethodArity(call, "длина", 0);
                            return self.result.types.builtins.integer;
                        }
                        if (std.mem.eql(u8, property.property, "есть")) {
                            try self.checkMethodArity(call, "есть", 1);
                            if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], map.key), map.key)) {
                                try self.report(call.span, "Type Error: ключ соответствия имеет неверный тип", .{});
                            }
                            return self.result.types.builtins.boolean;
                        }
                        if (std.mem.eql(u8, property.property, "получить")) {
                            try self.checkMethodArity(call, "получить", 2);
                            if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], map.key), map.key)) {
                                try self.report(call.span, "Type Error: ключ соответствия имеет неверный тип", .{});
                            }
                            if (call.arguments.len > 1 and !self.assignable(try self.inferExpected(call.arguments[1], map.value), map.value)) {
                                try self.report(call.span, "Type Error: значение по умолчанию имеет неверный тип", .{});
                            }
                            return map.value;
                        }
                        if (std.mem.eql(u8, property.property, "удалить")) {
                            try self.checkMethodArity(call, "удалить", 1);
                            if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], map.key), map.key)) {
                                try self.report(call.span, "Type Error: ключ соответствия имеет неверный тип", .{});
                            }
                            return self.result.types.builtins.boolean;
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
        const callee_type = try self.infer(call.callee);
        const entry = self.result.types.get(callee_type) orelse return self.result.types.poison();
        switch (entry.*) {
            .function => |function| {
                if (call.arguments.len != function.parameters.len) try self.report(call.span, "Type Error: неверное количество аргументов функции", .{});
                const shared = @min(call.arguments.len, function.parameters.len);
                for (call.arguments[0..shared], function.parameters[0..shared]) |argument, parameter| {
                    if (!self.assignable(try self.inferExpected(argument, parameter), parameter)) try self.report(call.span, "Type Error: аргумент не совпадает с типом параметра", .{});
                }
                return function.return_type;
            },
            .nominal => |nominal| {
                if (self.result.nominal_fields.get(nominal.symbol)) |fields| {
                    if (call.arguments.len != fields.len) try self.report(call.span, "Type Error: неверное количество аргументов конструктора структуры", .{});
                    const shared = @min(call.arguments.len, fields.len);
                    for (call.arguments[0..shared], fields[0..shared]) |argument, field| {
                        if (!self.assignable(try self.inferExpected(argument, field.typ), field.typ)) try self.report(call.span, "Type Error: аргумент конструктора не совпадает с типом поля", .{});
                    }
                    return callee_type;
                }
                try self.report(call.span, "Type Error: вызвано значение, не являющееся функцией", .{});
                return self.result.types.poison();
            },
            else => {
                try self.report(call.span, "Type Error: вызвано значение, не являющееся функцией", .{});
                return self.result.types.poison();
            },
        }
    }

    fn checkMethodArity(self: *Checker, call: anytype, name: []const u8, expected: usize) !void {
        if (call.arguments.len == expected) return;
        try self.report(call.span, "Type Error: метод '{s}' ожидает {d} аргумент(а)", .{ name, expected });
        for (call.arguments) |argument| _ = try self.infer(argument);
    }

    fn resolveType(self: *Checker, type_node: ast.TypeId) !types.TypeId {
        return switch (self.tree.typeNode(type_node).*) {
            .ident => |ident| builtinType(&self.result.types, ident.name) orelse blk: {
                if (self.findTypeSymbol(ident.name)) |symbol| {
                    if (self.result.alias_type_nodes.contains(symbol)) break :blk try self.resolveAlias(symbol, ident.span);
                    break :blk try self.result.types.nominal(symbol, &.{});
                }
                try self.report(ident.span, "Type Error: неизвестный тип '{s}'", .{ident.name});
                break :blk try self.result.types.poison();
            },
            .generic => |generic| blk: {
                if (std.mem.eql(u8, generic.name, "Массив") and generic.parameters.len == 1) break :blk try self.result.types.array(try self.resolveType(generic.parameters[0]));
                if (std.mem.eql(u8, generic.name, "Соответствие") and generic.parameters.len == 2) break :blk try self.result.types.map(try self.resolveType(generic.parameters[0]), try self.resolveType(generic.parameters[1]));
                if (self.findTypeSymbol(generic.name)) |symbol| {
                    var arguments: std.ArrayList(types.TypeId) = .empty;
                    defer arguments.deinit(self.result.allocator);
                    for (generic.parameters) |parameter| try arguments.append(self.result.allocator, try self.resolveType(parameter));
                    break :blk try self.result.types.nominal(symbol, arguments.items);
                }
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

    fn findTypeSymbol(self: *const Checker, name: []const u8) ?symbols.SymbolId {
        for (self.resolution.symbols.symbols.items[1..], 1..) |entry, index| {
            if (entry.kind == .type and std.mem.eql(u8, entry.name, name)) return @enumFromInt(index);
        }
        return null;
    }

    fn resolveAlias(self: *Checker, symbol: symbols.SymbolId, span: source.Span) anyerror!types.TypeId {
        if (self.result.type_aliases.get(symbol)) |resolved| return resolved;
        const target = self.result.alias_type_nodes.get(symbol) orelse return self.result.types.poison();
        if (self.resolving_aliases.contains(symbol)) {
            try self.report(span, "Type Error: циклический псевдоним типа", .{});
            return self.result.types.poison();
        }
        try self.resolving_aliases.put(symbol, {});
        defer _ = self.resolving_aliases.remove(symbol);
        const resolved = try self.resolveType(target);
        try self.result.type_aliases.put(symbol, resolved);
        return resolved;
    }
};

pub fn check(allocator: std.mem.Allocator, tree: *const ast.Ast, resolution: *const resolver.Resolution) !CheckResult {
    var result = try CheckResult.init(allocator);
    errdefer result.deinit();
    var checker = Checker{
        .tree = tree,
        .resolution = resolution,
        .result = &result,
        .resolving_aliases = .init(allocator),
    };
    defer checker.resolving_aliases.deinit();
    try checker.typeAliasPass();
    try checker.nominalPass();
    try checker.signaturePass();
    try checker.bodyPass();
    return result;
}

fn tuplePropertyIndex(property: []const u8) ?usize {
    if (property.len == 0) return null;
    return std.fmt.parseInt(usize, property, 10) catch null;
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

test "type checker preserves nominal user types in function signatures" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип Точка = структура\nx: Число\nконец\nфунк та_же(точка: Точка) -> Точка\nточка\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}

test "type checker checks struct constructors and field access" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип Точка = структура\nx: Число\ny: Число\nконец\nфунк взять_x() -> Число\nпер точка = Точка(3, 4)\nточка.x\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    const function = parsed.ast.decl(parsed.ast.program.?.declarations[1]).function;
    const property = parsed.ast.stmt(function.body[1]).expr.value;
    try std.testing.expectEqual(checked.types.builtins.number, checked.expression_types.get(property).?);
}

test "type checker types destructuring and loop binders" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ сумма() -> Число\nпер (x, y) = (1, 2)\nпер результат = 0\nдля значение в массив(x, y) цикл\nрезультат = результат + значение\nконец\nпер целый_результат: Целое = 0\nдля индекс = 1 по 2 цикл\nцелый_результат = целый_результат + индекс\nконец\nрезультат\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    const function = parsed.ast.decl(parsed.ast.program.?.declarations[0]).function;
    const for_in_binder = resolved.stmt_bindings.get(function.body[2]).?[0];
    const for_range_binder = resolved.stmt_bindings.get(function.body[4]).?[0];
    try std.testing.expectEqual(checked.types.builtins.number, checked.symbol_types.get(for_in_binder).?);
    try std.testing.expectEqual(checked.types.builtins.integer, checked.symbol_types.get(for_range_binder).?);
}

test "type checker rejects loop control outside a loop" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ f() -> Пусто\nпродолжить\nпрервать\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 2), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Type Error: 'продолжить' можно использовать только внутри цикла", checked.diagnostics.items.items[0].message);
    try std.testing.expectEqualStrings("Type Error: 'прервать' можно использовать только внутри цикла", checked.diagnostics.items.items[1].message);
}

test "type checker narrows integer literals in an expected context" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ взять(значение: Целое) -> Целое\nзначение\nконец\nфунк сумма() -> Целое\nпер значения: Массив(Целое) = массив(1, 2)\nвзять(значения[0]) + 3\nконец\nфунк ошибка() -> Целое\nпер дробь: Целое = 1.5\nдробь\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 1), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Type Error: дробный литерал несовместим с Целое", checked.diagnostics.items.items[0].message);
    const sum = parsed.ast.decl(parsed.ast.program.?.declarations[1]).function;
    const expression = parsed.ast.stmt(sum.body[1]).expr.value;
    try std.testing.expectEqual(checked.types.builtins.integer, checked.expression_types.get(expression).?);
}

test "type checker validates operators and assignment targets" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ проверить(целое: Целое) -> Пусто\nконст неизменно = 1\nнеизменно = 2\nпер отрицание = не 1\nпер сумма = 1 + истина\nпер биты = целое & 2\nесли 1 и ложь тогда\n0\nиначе\n0\nконец\nпер финал = 0\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 4), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Type Error: нельзя присваивать константе", checked.diagnostics.items.items[0].message);
    try std.testing.expectEqualStrings("Type Error: оператор 'не' ожидает Булево", checked.diagnostics.items.items[1].message);
    try std.testing.expectEqualStrings("Type Error: оператор '+' ожидает два числа одного типа или две строки", checked.diagnostics.items.items[2].message);
    try std.testing.expectEqualStrings("Type Error: логический оператор ожидает два значения Булево", checked.diagnostics.items.items[3].message);
    const function = parsed.ast.decl(parsed.ast.program.?.declarations[0]).function;
    const bitwise_value = parsed.ast.stmt(function.body[4]).let.value;
    try std.testing.expectEqual(checked.types.builtins.integer, checked.expression_types.get(bitwise_value).?);
}

test "type checker resolves aliases before and after their declaration" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип Первый = Второй\nтип Второй = Число\nфунк взять(значение: Первый) -> Второй\nпер копия: Первый = значение\nкопия\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}

test "type checker rejects local values of type void" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ f() -> Пусто\nпер пусто: Пусто = пока ложь цикл\nконец\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 1), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Type Error: переменная не может иметь тип 'Пусто'", checked.diagnostics.items.items[0].message);
}
