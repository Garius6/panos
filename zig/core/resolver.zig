const std = @import("std");
const ast = @import("ast.zig");
const diagnostic = @import("diagnostic.zig");
const source = @import("source.zig");
const symbols = @import("symbols.zig");

const EnumVariants = struct {
    owner: symbols.SymbolId,
    values: std.StringHashMap(symbols.SymbolId),
};

pub const ImportedExport = struct {
    name: []const u8,
    kind: symbols.SymbolKind,
    span: source.Span,
};

pub const ImportedModule = struct {
    alias: []const u8,
    span: source.Span,
    exports: []const ImportedExport,
};

const ModuleMembers = struct {
    module: symbols.SymbolId,
    values: std.StringHashMap(symbols.SymbolId),
};

pub const Resolution = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    symbols: symbols.SymbolStore,
    diagnostics: diagnostic.DiagnosticList = .{},
    decl_symbols: std.AutoHashMap(ast.DeclId, symbols.SymbolId),
    stmt_symbols: std.AutoHashMap(ast.StmtId, symbols.SymbolId),
    stmt_bindings: std.AutoHashMap(ast.StmtId, []const symbols.SymbolId),
    expr_symbols: std.AutoHashMap(ast.ExprId, symbols.SymbolId),
    pattern_symbols: std.AutoHashMap(ast.PatternId, symbols.SymbolId),
    function_parameters: std.AutoHashMap(ast.DeclId, []const symbols.SymbolId),
    lambda_parameters: std.AutoHashMap(ast.ExprId, []const symbols.SymbolId),
    lambda_captures: std.AutoHashMap(ast.ExprId, []const symbols.SymbolId),
    enum_variants: std.ArrayList(EnumVariants) = .empty,

    pub fn init(allocator: std.mem.Allocator) !Resolution {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .symbols = try symbols.SymbolStore.init(allocator),
            .decl_symbols = .init(allocator),
            .stmt_symbols = .init(allocator),
            .stmt_bindings = .init(allocator),
            .expr_symbols = .init(allocator),
            .pattern_symbols = .init(allocator),
            .function_parameters = .init(allocator),
            .lambda_parameters = .init(allocator),
            .lambda_captures = .init(allocator),
        };
    }

    pub fn deinit(self: *Resolution) void {
        for (self.enum_variants.items) |*variants| variants.values.deinit();
        self.enum_variants.deinit(self.allocator);
        self.lambda_captures.deinit();
        self.lambda_parameters.deinit();
        self.function_parameters.deinit();
        self.pattern_symbols.deinit();
        self.expr_symbols.deinit();
        self.stmt_bindings.deinit();
        self.stmt_symbols.deinit();
        self.decl_symbols.deinit();
        self.diagnostics.deinit(self.allocator);
        self.symbols.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn findEnumVariant(self: *const Resolution, owner: symbols.SymbolId, name: []const u8) ?symbols.SymbolId {
        for (self.enum_variants.items) |variants| {
            if (variants.owner == owner) return variants.values.get(name);
        }
        return null;
    }
};

const Resolver = struct {
    result: *Resolution,
    scopes: symbols.ScopeStack,
    tree: *const ast.Ast = undefined,
    module_members: std.ArrayList(ModuleMembers) = .empty,

    fn init(result: *Resolution) !Resolver {
        return .{
            .result = result,
            .scopes = try symbols.ScopeStack.init(result.allocator),
        };
    }

    fn deinit(self: *Resolver) void {
        for (self.module_members.items) |*members| members.values.deinit();
        self.module_members.deinit(self.result.allocator);
        self.scopes.deinit();
        self.* = undefined;
    }

    fn report(self: *Resolver, span: source.Span, comptime format: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.result.arena.allocator(), format, args);
        _ = try self.result.diagnostics.appendUnique(self.result.allocator, .{
            .phase = .resolver,
            .severity = .err,
            .span = span,
            .message = message,
        });
    }

    fn installBuiltins(self: *Resolver) !void {
        const builtin_names = [_][]const u8{
            "Ошибка",
            "длина",
            "паника",
            "получить",
            "отправить",
            "себя",
            "наблюдать",
            "получить_сигнал",
            "убить",
            "связать",
            "встроку",
            "Целое",
            "Число",
        };
        for (builtin_names) |name| {
            const symbol = try self.result.symbols.add(.{
                .name = name,
                .kind = .builtin,
                .span = .{ .file_id = 0, .start = 0, .end = 0 },
            });
            try self.scopes.declare(&self.result.symbols, symbol);
        }
        try self.installPreludeEnum("Опция", &.{ "Нет", "Есть" });
        try self.installPreludeEnum("Результат", &.{ "Успех", "Неудача" });
        try self.installPreludeInterface("Сравниваемое");
        try self.installPreludeInterface("Итерируемое");
    }

    fn predeclareImports(self: *Resolver, imports: []const ImportedModule) !void {
        for (imports) |import| {
            const module = try self.result.symbols.add(.{
                .name = import.alias,
                .kind = .module,
                .span = import.span,
            });
            self.scopes.declare(&self.result.symbols, module) catch |err| switch (err) {
                error.DuplicateSymbol => try self.report(import.span, "Resolve Error: символ '{s}' уже объявлен", .{import.alias}),
                else => return err,
            };
            var members = ModuleMembers{
                .module = module,
                .values = .init(self.result.allocator),
            };
            errdefer members.values.deinit();
            for (import.exports) |exported| {
                const member = try self.result.symbols.add(.{
                    .name = exported.name,
                    .kind = exported.kind,
                    .module_path = import.alias,
                    .is_exported = true,
                    .span = exported.span,
                });
                if (members.values.contains(exported.name)) {
                    try self.report(exported.span, "Resolve Error: экспорт '{s}' повторён в модуле '{s}'", .{ exported.name, import.alias });
                } else {
                    try members.values.put(exported.name, member);
                }
            }
            try self.module_members.append(self.result.allocator, members);
        }
    }

    fn moduleMember(self: *const Resolver, module: symbols.SymbolId, name: []const u8) ?symbols.SymbolId {
        for (self.module_members.items) |members| {
            if (members.module == module) return members.values.get(name);
        }
        return null;
    }

    fn installPreludeInterface(self: *Resolver, name: []const u8) !void {
        const symbol = try self.result.symbols.add(.{
            .name = name,
            .kind = .type,
            .is_exported = true,
            .span = .{ .file_id = 0, .start = 0, .end = 0 },
        });
        try self.scopes.declare(&self.result.symbols, symbol);
    }

    fn installPreludeEnum(self: *Resolver, name: []const u8, variant_names: []const []const u8) !void {
        const owner = try self.result.symbols.add(.{
            .name = name,
            .kind = .type,
            .is_exported = true,
            .span = .{ .file_id = 0, .start = 0, .end = 0 },
        });
        try self.scopes.declare(&self.result.symbols, owner);
        var variants = EnumVariants{
            .owner = owner,
            .values = .init(self.result.allocator),
        };
        errdefer variants.values.deinit();
        for (variant_names) |variant_name| {
            const variant = try self.result.symbols.add(.{
                .name = variant_name,
                .kind = .enum_variant,
                .is_exported = true,
                .owner_type = owner,
                .span = .{ .file_id = 0, .start = 0, .end = 0 },
            });
            try variants.values.put(variant_name, variant);
        }
        try self.result.enum_variants.append(self.result.allocator, variants);
    }

    fn predeclare(self: *Resolver, tree: *const ast.Ast) !void {
        for (tree.program.?.declarations) |declaration| {
            switch (tree.decl(declaration).*) {
                .function => |value| {
                    _ = try self.registerDeclaration(declaration, value.name, .function, value.span, value.is_exported, false);
                },
                .constant => |value| {
                    _ = try self.registerDeclaration(declaration, value.name, .constant, value.span, value.is_exported, true);
                },
                .struct_decl => |value| {
                    _ = try self.registerDeclaration(declaration, value.name, .type, value.span, value.is_exported, false);
                },
                .interface_decl => |value| {
                    _ = try self.registerDeclaration(declaration, value.name, .type, value.span, value.is_exported, false);
                },
                .type_alias => |value| {
                    _ = try self.registerDeclaration(declaration, value.name, .type, value.span, value.is_exported, false);
                },
                .enum_decl => |value| try self.registerEnumDeclaration(declaration, value),
                .foreign => |value| {
                    _ = try self.registerDeclaration(declaration, value.name, .function, value.span, false, false);
                },
                .impl => |value| for (value.methods) |method| {
                    const function = tree.decl(method).function;
                    _ = try self.registerMethod(method, function.name, function.span);
                },
                .import, .error_node => {},
            }
        }
    }

    fn registerEnumDeclaration(self: *Resolver, declaration: ast.DeclId, value: anytype) !void {
        const owner = try self.registerDeclaration(declaration, value.name, .type, value.span, value.is_exported, false);
        var variants = EnumVariants{
            .owner = owner,
            .values = .init(self.result.allocator),
        };
        errdefer variants.values.deinit();
        for (value.variants) |variant| {
            const symbol = try self.result.symbols.add(.{
                .name = variant.name,
                .kind = .enum_variant,
                .is_exported = value.is_exported,
                .owner_type = owner,
                .span = variant.span,
            });
            if (variants.values.contains(variant.name)) {
                try self.report(variant.span, "Resolve Error: вариант '{s}' уже объявлен", .{variant.name});
            } else {
                try variants.values.put(variant.name, symbol);
            }
        }
        try self.result.enum_variants.append(self.result.allocator, variants);
    }

    fn registerDeclaration(
        self: *Resolver,
        declaration: ast.DeclId,
        name: []const u8,
        kind: symbols.SymbolKind,
        span: source.Span,
        is_exported: bool,
        is_const: bool,
    ) !symbols.SymbolId {
        const symbol = try self.result.symbols.add(.{
            .name = name,
            .kind = kind,
            .is_exported = is_exported,
            .is_const = is_const,
            .span = span,
        });
        self.scopes.declare(&self.result.symbols, symbol) catch |err| switch (err) {
            error.DuplicateSymbol => try self.report(span, "Resolve Error: символ '{s}' уже объявлен", .{name}),
            else => return err,
        };
        try self.result.decl_symbols.put(declaration, symbol);
        return symbol;
    }

    fn registerMethod(self: *Resolver, declaration: ast.DeclId, name: []const u8, span: source.Span) !symbols.SymbolId {
        const symbol = try self.result.symbols.add(.{
            .name = name,
            .kind = .function,
            .span = span,
        });
        try self.result.decl_symbols.put(declaration, symbol);
        return symbol;
    }

    fn resolveDeclarations(self: *Resolver, tree: *const ast.Ast) !void {
        for (tree.program.?.declarations) |declaration| {
            switch (tree.decl(declaration).*) {
                .function => |value| try self.resolveFunction(declaration, value.parameters, value.body),
                .constant => |value| try self.resolveExpression(tree, value.value),
                .impl => |value| for (value.methods) |method| {
                    const function = tree.decl(method).function;
                    try self.resolveFunction(method, function.parameters, function.body);
                },
                .import, .struct_decl, .interface_decl, .enum_decl, .foreign, .type_alias, .error_node => {},
            }
        }
    }

    fn resolveFunction(self: *Resolver, declaration: ast.DeclId, parameters: []const ast.ParamDecl, body: []const ast.StmtId) !void {
        _ = try self.scopes.push();
        defer _ = self.scopes.pop() catch unreachable;
        const parameter_symbols = try self.declareParameters(parameters);
        try self.result.function_parameters.put(declaration, parameter_symbols);
        try self.resolveStatements(body);
    }

    fn declareParameters(self: *Resolver, parameters: []const ast.ParamDecl) ![]const symbols.SymbolId {
        var parameter_symbols: std.ArrayList(symbols.SymbolId) = .empty;
        defer parameter_symbols.deinit(self.result.allocator);
        for (parameters) |parameter| {
            try parameter_symbols.append(self.result.allocator, try self.declareLocal(parameter.name, parameter.span, true, false));
        }
        return self.result.arena.allocator().dupe(symbols.SymbolId, parameter_symbols.items);
    }

    fn declareLocal(self: *Resolver, name: []const u8, span: source.Span, is_const: bool, is_pattern_binder: bool) !symbols.SymbolId {
        if (isReservedBuiltin(name)) {
            try self.report(span, "Resolve Error: '{s}' — зарезервированное имя, нельзя использовать", .{name});
        }
        const symbol = try self.result.symbols.add(.{
            .name = name,
            .kind = .variable,
            .is_const = is_const,
            .is_pattern_binder = is_pattern_binder,
            .span = span,
        });
        self.scopes.declare(&self.result.symbols, symbol) catch |err| switch (err) {
            error.DuplicateSymbol => try self.report(span, "Resolve Error: символ '{s}' уже объявлен", .{name}),
            else => return err,
        };
        return symbol;
    }

    fn resolveStatements(self: *Resolver, statements: []const ast.StmtId) anyerror!void {
        for (statements) |statement| try self.resolveStatement(statement);
    }

    fn resolveStatement(self: *Resolver, statement: ast.StmtId) anyerror!void {
        const value = self.tree.stmt(statement).*;
        switch (value) {
            .let => |let| {
                try self.resolveExpression(self.tree, let.value);
                var bindings: std.ArrayList(symbols.SymbolId) = .empty;
                defer bindings.deinit(self.result.allocator);
                if (let.name) |name| {
                    const symbol = try self.declareLocal(name, let.span, let.is_const, false);
                    try self.result.stmt_symbols.put(statement, symbol);
                    try bindings.append(self.result.allocator, symbol);
                } else {
                    for (let.destructure_names) |name| {
                        try bindings.append(self.result.allocator, try self.declareLocal(name, let.span, let.is_const, false));
                    }
                }
                if (bindings.items.len != 0) try self.result.stmt_bindings.put(statement, try self.result.arena.allocator().dupe(symbols.SymbolId, bindings.items));
            },
            .return_stmt => |return_stmt| try self.resolveExpression(self.tree, return_stmt.value),
            .expr => |expression| try self.resolveExpression(self.tree, expression.value),
            .for_in => |loop| {
                try self.resolveExpression(self.tree, loop.iterable);
                _ = try self.scopes.push();
                defer _ = self.scopes.pop() catch unreachable;
                var bindings: std.ArrayList(symbols.SymbolId) = .empty;
                defer bindings.deinit(self.result.allocator);
                for (loop.names) |name| try bindings.append(self.result.allocator, try self.declareLocal(name, loop.span, false, false));
                try self.result.stmt_bindings.put(statement, try self.result.arena.allocator().dupe(symbols.SymbolId, bindings.items));
                try self.resolveStatements(loop.body);
            },
            .for_range => |range| {
                try self.resolveExpression(self.tree, range.start);
                try self.resolveExpression(self.tree, range.end);
                _ = try self.scopes.push();
                defer _ = self.scopes.pop() catch unreachable;
                const symbol = try self.declareLocal(range.name, range.span, false, false);
                try self.result.stmt_bindings.put(statement, try self.result.arena.allocator().dupe(symbols.SymbolId, &.{symbol}));
                try self.resolveStatements(range.body);
            },
            .continue_stmt, .break_stmt, .error_node => {},
        }
    }

    fn resolveExpression(self: *Resolver, tree: *const ast.Ast, expression: ast.ExprId) anyerror!void {
        self.tree = tree;
        switch (tree.expr(expression).*) {
            .ident => |ident| {
                const symbol = try self.scopes.lookupTrackingCaptures(&self.result.symbols, ident.name) orelse blk: {
                    try self.report(ident.span, "Resolve Error: неопределённое имя '{s}'", .{ident.name});
                    break :blk symbols.invalid_symbol;
                };
                try self.result.expr_symbols.put(expression, symbol);
            },
            .unary => |unary| try self.resolveExpression(tree, unary.operand),
            .binary => |binary| {
                try self.resolveExpression(tree, binary.left);
                try self.resolveExpression(tree, binary.right);
            },
            .call => |call| {
                try self.resolveExpression(tree, call.callee);
                for (call.arguments) |argument| try self.resolveExpression(tree, argument);
            },
            .spawn => |spawn| try self.resolveExpression(tree, spawn.call),
            .property => |property| {
                try self.resolveExpression(tree, property.object);
                if (self.result.expr_symbols.get(property.object)) |object_symbol| {
                    const entry = self.result.symbols.get(object_symbol) orelse return;
                    if (entry.kind == .module) {
                        if (self.moduleMember(object_symbol, property.property)) |member| {
                            try self.result.expr_symbols.put(expression, member);
                        } else {
                            try self.report(property.span, "Resolve Error: у модуля '{s}' нет экспорта '{s}'", .{ entry.name, property.property });
                        }
                    } else if (entry.kind == .type) {
                        if (self.result.findEnumVariant(object_symbol, property.property)) |variant| {
                            try self.result.expr_symbols.put(expression, variant);
                        }
                    }
                }
            },
            .if_expr => |conditional| {
                try self.resolveExpression(tree, conditional.condition);
                try self.resolveScopedStatements(conditional.then_branch);
                try self.resolveScopedStatements(conditional.else_branch);
            },
            .while_expr => |loop| {
                try self.resolveExpression(tree, loop.condition);
                try self.resolveScopedStatements(loop.body);
            },
            .tuple => |tuple| for (tuple.elements) |element| try self.resolveExpression(tree, element),
            .lambda => |lambda| try self.resolveLambda(tree, expression, lambda),
            .array => |array| for (array.elements) |element| try self.resolveExpression(tree, element),
            .map => |map| for (map.entries) |entry| {
                try self.resolveExpression(tree, entry.key);
                try self.resolveExpression(tree, entry.value);
            },
            .index => |index| {
                try self.resolveExpression(tree, index.object);
                try self.resolveExpression(tree, index.index);
            },
            .try_expr => |try_expression| try self.resolveExpression(tree, try_expression.value),
            .match_expr => |match| {
                try self.resolveExpression(tree, match.subject);
                for (match.arms) |arm| {
                    _ = try self.scopes.push();
                    defer _ = self.scopes.pop() catch unreachable;
                    try self.resolvePattern(tree, arm.pattern);
                    try self.resolveStatements(arm.body);
                }
            },
            .number, .boolean, .string, .error_node => {},
        }
    }

    fn resolveScopedStatements(self: *Resolver, statements: []const ast.StmtId) anyerror!void {
        _ = try self.scopes.push();
        defer _ = self.scopes.pop() catch unreachable;
        try self.resolveStatements(statements);
    }

    fn resolveLambda(self: *Resolver, tree: *const ast.Ast, expression: ast.ExprId, lambda: anytype) anyerror!void {
        _ = try self.scopes.enterLambda();
        const parameter_symbols = try self.declareParameters(lambda.parameters);
        try self.result.lambda_parameters.put(expression, parameter_symbols);
        try self.resolveStatements(lambda.body);
        var captures = try self.scopes.leaveLambda();
        defer captures.deinit();
        try self.result.lambda_captures.put(expression, try self.result.arena.allocator().dupe(symbols.SymbolId, captures.values.items));
        _ = tree;
    }

    fn resolvePattern(self: *Resolver, tree: *const ast.Ast, pattern: ast.PatternId) anyerror!void {
        switch (tree.pattern(pattern).*) {
            .literal => |literal| try self.resolveExpression(tree, literal.value),
            .ident => |ident| {
                const symbol = try self.declareLocal(ident.name, ident.span, false, true);
                try self.result.pattern_symbols.put(pattern, symbol);
            },
            .constructor => |constructor| {
                if (constructor.module_name) |owner_name| {
                    const owner_symbol = try self.scopes.lookupTrackingCaptures(&self.result.symbols, owner_name) orelse symbols.invalid_symbol;
                    const owner = self.result.symbols.get(owner_symbol);
                    if (owner) |entry| {
                        if (entry.kind == .type) {
                            if (self.result.findEnumVariant(owner_symbol, constructor.name)) |variant| {
                                try self.result.pattern_symbols.put(pattern, variant);
                            } else {
                                try self.report(constructor.span, "Resolve Error: у перечисления '{s}' нет варианта '{s}'", .{ owner_name, constructor.name });
                            }
                        } else {
                            try self.report(constructor.span, "Resolve Error: '{s}' не является перечислением", .{owner_name});
                        }
                    } else {
                        try self.report(constructor.span, "Resolve Error: неопределённый тип перечисления '{s}'", .{owner_name});
                    }
                }
                for (constructor.arguments) |argument| try self.resolvePattern(tree, argument);
            },
            .wildcard, .error_node => {},
        }
    }
};

pub fn resolve(allocator: std.mem.Allocator, tree: *const ast.Ast) !Resolution {
    return resolveWithImports(allocator, tree, &.{});
}

pub fn resolveWithImports(allocator: std.mem.Allocator, tree: *const ast.Ast, imports: []const ImportedModule) !Resolution {
    var result = try Resolution.init(allocator);
    errdefer result.deinit();
    var resolver = try Resolver.init(&result);
    defer resolver.deinit();
    resolver.tree = tree;

    try resolver.installBuiltins();
    try resolver.predeclareImports(imports);
    try resolver.predeclare(tree);
    try resolver.resolveDeclarations(tree);
    return result;
}

fn isReservedBuiltin(name: []const u8) bool {
    const names = [_][]const u8{
        "Ошибка",
        "длина",
        "паника",
        "получить",
        "отправить",
        "себя",
        "наблюдать",
        "получить_сигнал",
        "убить",
        "связать",
        "встроку",
        "Целое",
        "Число",
        "Итерируемое",
    };
    for (names) |reserved| {
        if (std.mem.eql(u8, name, reserved)) return true;
    }
    return false;
}

test "resolver links closures to outer locals and functions" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(
        std.testing.allocator,
        "функ внешняя(значение: Число) -> Число\nзначение\nконец\nфунк вычислить(параметр: Число) -> Число\nпер локальная = параметр\nпер замыкание = функ(добавка)\nлокальная + добавка + внешняя(1)\nконец\nзамыкание(2)\nконец",
        0,
    );
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();

    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
    const function = parsed.ast.decl(parsed.ast.program.?.declarations[1]).function;
    const lambda = parsed.ast.stmt(function.body[1]).let.value;
    const captures = resolved.lambda_captures.get(lambda).?;
    try std.testing.expectEqual(@as(usize, 2), captures.len);
    try std.testing.expectEqualStrings("локальная", resolved.symbols.get(captures[0]).?.name);
    try std.testing.expectEqualStrings("внешняя", resolved.symbols.get(captures[1]).?.name);
}

test "resolver accumulates undefined and duplicate name diagnostics" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ f() -> Число\nпер x = нет\nпер x = 1\nx\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();

    try std.testing.expectEqual(@as(usize, 2), resolved.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Resolve Error: неопределённое имя 'нет'", resolved.diagnostics.items.items[0].message);
    try std.testing.expectEqualStrings("Resolve Error: символ 'x' уже объявлен", resolved.diagnostics.items.items[1].message);
}

test "resolver links qualified enum constructors to variant symbols" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип Ответ = перечисление\nДа\nНет\nконец\nфунк f() -> Ответ\nОтвет.Да()\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();

    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
    const function = parsed.ast.decl(parsed.ast.program.?.declarations[1]).function;
    const call = parsed.ast.stmt(function.body[0]).expr.value;
    const property = parsed.ast.expr(call).call.callee;
    const variant = resolved.expr_symbols.get(property).?;
    try std.testing.expectEqual(symbols.SymbolKind.enum_variant, resolved.symbols.get(variant).?.kind);
    try std.testing.expectEqualStrings("Да", resolved.symbols.get(variant).?.name);
}

test "resolver links qualified module exports without global leakage" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "импорт \"./математика\" как мат\nфунк старт() -> Число\nмат.сложить(1, 2)\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    const imports = [_]ImportedModule{.{
        .alias = "мат",
        .span = .{ .file_id = 0, .start = 0, .end = 1 },
        .exports = &.{.{
            .name = "сложить",
            .kind = .function,
            .span = .{ .file_id = 1, .start = 0, .end = 7 },
        }},
    }};
    var resolved = try resolveWithImports(std.testing.allocator, &parsed.ast, &imports);
    defer resolved.deinit();

    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
    const start = parsed.ast.decl(parsed.ast.program.?.declarations[1]).function;
    const callee = parsed.ast.stmt(start.body[0]).expr.value;
    const call = parsed.ast.expr(callee).call;
    const symbol = resolved.expr_symbols.get(call.callee).?;
    const entry = resolved.symbols.get(symbol).?;
    try std.testing.expectEqual(symbols.SymbolKind.function, entry.kind);
    try std.testing.expectEqualStrings("мат::сложить", entry.full_name);
}

test "resolver reports unknown qualified module exports" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "импорт \"./математика\" как мат\nфунк старт() -> Число\nмат.нет(1)\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    const imports = [_]ImportedModule{.{
        .alias = "мат",
        .span = .{ .file_id = 0, .start = 0, .end = 1 },
        .exports = &.{},
    }};
    var resolved = try resolveWithImports(std.testing.allocator, &parsed.ast, &imports);
    defer resolved.deinit();

    try std.testing.expectEqual(@as(usize, 1), resolved.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Resolve Error: у модуля 'мат' нет экспорта 'нет'", resolved.diagnostics.items.items[0].message);
}

test "resolver records all statement binders for destructuring and loops" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ f() -> Пусто\nпер (ключ, значение) = (\"a\", 1)\nдля элемент в массив(1) цикл\nэлемент\nконец\nдля индекс = 1 по 2 цикл\nиндекс\nконец\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();

    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
    const function = parsed.ast.decl(parsed.ast.program.?.declarations[0]).function;
    const destructure = resolved.stmt_bindings.get(function.body[0]).?;
    const for_in = resolved.stmt_bindings.get(function.body[1]).?;
    const for_range = resolved.stmt_bindings.get(function.body[2]).?;
    try std.testing.expectEqual(@as(usize, 2), destructure.len);
    try std.testing.expectEqualStrings("ключ", resolved.symbols.get(destructure[0]).?.name);
    try std.testing.expectEqual(@as(usize, 1), for_in.len);
    try std.testing.expectEqualStrings("элемент", resolved.symbols.get(for_in[0]).?.name);
    try std.testing.expectEqual(@as(usize, 1), for_range.len);
    try std.testing.expectEqualStrings("индекс", resolved.symbols.get(for_range[0]).?.name);
}
