const std = @import("std");
const ast = @import("ast.zig");
const diagnostic = @import("diagnostic.zig");
const source = @import("source.zig");
const token = @import("token.zig");

pub const ParseResult = struct {
    allocator: std.mem.Allocator,
    ast: ast.Ast,
    diagnostics: diagnostic.DiagnosticList = .{},

    pub fn init(allocator: std.mem.Allocator) ParseResult {
        return .{
            .allocator = allocator,
            .ast = ast.Ast.init(allocator),
        };
    }

    pub fn deinit(self: *ParseResult) void {
        self.ast.deinit();
        self.diagnostics.deinit(self.allocator);
        self.* = undefined;
    }
};

const Parser = struct {
    tokens: []const token.Token,
    current: usize = 0,
    result: *ParseResult,

    fn peek(self: *const Parser) token.Token {
        if (self.tokens.len == 0) return eofToken();
        return self.tokens[@min(self.current, self.tokens.len - 1)];
    }

    fn peekSecond(self: *const Parser) token.Token {
        if (self.tokens.len == 0) return eofToken();
        return self.tokens[@min(self.current + 1, self.tokens.len - 1)];
    }

    fn next(self: *Parser) token.Token {
        const value = self.peek();
        if (self.current < self.tokens.len) self.current += 1;
        return value;
    }

    fn at(self: *const Parser, kind: token.TokenKind) bool {
        return self.peek().kind == kind;
    }

    fn report(self: *Parser, span: source.Span, message: []const u8) !void {
        _ = try self.result.diagnostics.appendUnique(self.result.allocator, .{
            .phase = .parser,
            .severity = .err,
            .span = span,
            .message = message,
        });
    }

    fn expect(self: *Parser, kind: token.TokenKind, message: []const u8) !token.Token {
        const value = self.next();
        if (value.kind != kind) try self.report(value.span, message);
        return value;
    }

    fn spanFrom(start: source.Span, end: source.Span) source.Span {
        return .{
            .file_id = start.file_id,
            .start = start.start,
            .end = end.end,
        };
    }

    fn parseProgram(self: *Parser) !void {
        var declarations: std.ArrayList(ast.DeclId) = .empty;
        defer declarations.deinit(self.result.allocator);

        while (!self.at(.eof)) {
            const doc = self.peek().doc;
            var exported = false;
            if (self.at(.export_decl)) {
                exported = true;
                _ = self.next();
            }

            if (self.at(.function)) {
                try declarations.append(self.result.allocator, try self.parseFunction(exported, doc));
                continue;
            }

            if (exported) {
                try self.report(self.peek().span, "Синтаксическая ошибка: после 'экспорт' ожидается 'функ'");
            } else {
                try self.report(self.peek().span, "Синтаксическая ошибка: ожидается top-level декларация");
            }
            _ = self.next();
        }

        try self.result.ast.setProgram(declarations.items);
    }

    fn parseFunction(self: *Parser, is_exported: bool, doc: []const u8) !ast.DeclId {
        const start = try self.expect(.function, "Синтаксическая ошибка: ожидается 'функ'");
        const name_token = try self.expect(.ident, "Синтаксическая ошибка: после 'функ' ожидается имя");
        const name = try self.result.ast.copyText(name_token.lexeme);

        var parameters: std.ArrayList(ast.ParamDecl) = .empty;
        defer parameters.deinit(self.result.allocator);
        _ = try self.expect(.l_paren, "Синтаксическая ошибка: после имени функции ожидается '('");
        while (!self.at(.r_paren) and !self.at(.eof)) {
            const parameter_start = self.peek().span;
            const parameter_name = try self.expect(.ident, "Синтаксическая ошибка: ожидается имя параметра");
            _ = try self.expect(.colon, "Синтаксическая ошибка: после имени параметра ожидается ':'");
            const parameter_type = try self.parseType();
            try parameters.append(self.result.allocator, .{
                .span = spanFrom(parameter_start, self.astTypeSpan(parameter_type)),
                .name = try self.result.ast.copyText(parameter_name.lexeme),
                .type_annotation = parameter_type,
            });
            if (!self.at(.comma)) break;
            _ = self.next();
        }
        _ = try self.expect(.r_paren, "Синтаксическая ошибка: ожидается ')'");
        _ = try self.expect(.arrow, "Синтаксическая ошибка: после параметров ожидается '-> Тип'");
        const return_type = try self.parseType();

        var body: std.ArrayList(ast.StmtId) = .empty;
        defer body.deinit(self.result.allocator);
        while (!self.at(.end) and !self.at(.eof)) {
            try body.append(self.result.allocator, try self.parseStatement());
            self.consumeSemicolons();
        }
        const end = try self.expect(.end, "Синтаксическая ошибка: функция не закрыта 'конец'");

        return self.result.ast.addDecl(.{ .function = .{
            .span = spanFrom(start.span, end.span),
            .name = name,
            .name_span = name_token.span,
            .doc = try self.result.ast.copyText(doc),
            .type_parameters = &.{},
            .parameters = try self.result.ast.copySlice(ast.ParamDecl, parameters.items),
            .return_type = return_type,
            .body = try self.result.ast.copySlice(ast.StmtId, body.items),
            .is_exported = is_exported,
        } });
    }

    fn parseType(self: *Parser) !ast.TypeId {
        const value = self.next();
        if (value.kind != .ident) {
            try self.report(value.span, "Синтаксическая ошибка: ожидается тип");
            return self.result.ast.addType(.{ .error_node = value.span });
        }

        const name = try self.result.ast.copyText(value.lexeme);
        if (!self.at(.l_paren) or self.peek().nl_before) {
            return self.result.ast.addType(.{ .ident = .{ .span = value.span, .name = name } });
        }

        _ = self.next();
        var parameters: std.ArrayList(ast.TypeId) = .empty;
        defer parameters.deinit(self.result.allocator);
        while (!self.at(.r_paren) and !self.at(.eof)) {
            try parameters.append(self.result.allocator, try self.parseType());
            if (!self.at(.comma)) break;
            _ = self.next();
        }
        const end = try self.expect(.r_paren, "Синтаксическая ошибка: ожидается ')' после параметров типа");
        return self.result.ast.addType(.{ .generic = .{
            .span = spanFrom(value.span, end.span),
            .name = name,
            .parameters = try self.result.ast.copySlice(ast.TypeId, parameters.items),
        } });
    }

    fn parseStatement(self: *Parser) !ast.StmtId {
        return switch (self.peek().kind) {
            .let, .constant => self.parseLet(),
            .return_expr => self.parseReturn(),
            .continue_expr => self.parseMarker(.continue_stmt),
            .break_expr => self.parseMarker(.break_stmt),
            else => self.parseExprStatement(),
        };
    }

    fn parseLet(self: *Parser) !ast.StmtId {
        const start = self.next();
        const name_token = try self.expect(.ident, "Синтаксическая ошибка: после 'пер' ожидается имя");
        var type_annotation: ?ast.TypeId = null;
        if (self.at(.colon)) {
            _ = self.next();
            type_annotation = try self.parseType();
        }
        if (self.at(.assign)) {
            _ = self.next();
        } else {
            try self.report(self.peek().span, "Синтаксическая ошибка: после имени переменной ожидается '='");
        }
        const value = try self.parseExpression(0);
        return self.result.ast.addStmt(.{ .let = .{
            .span = spanFrom(start.span, self.astExprSpan(value)),
            .name = try self.result.ast.copyText(name_token.lexeme),
            .value = value,
            .type_annotation = type_annotation,
            .is_const = start.kind == .constant,
        } });
    }

    fn parseReturn(self: *Parser) !ast.StmtId {
        const start = self.next();
        const value = try self.parseExpression(0);
        return self.result.ast.addStmt(.{ .return_stmt = .{
            .span = spanFrom(start.span, self.astExprSpan(value)),
            .value = value,
        } });
    }

    fn parseMarker(self: *Parser, comptime kind: enum { continue_stmt, break_stmt }) !ast.StmtId {
        const value = self.next();
        return switch (kind) {
            .continue_stmt => self.result.ast.addStmt(.{ .continue_stmt = value.span }),
            .break_stmt => self.result.ast.addStmt(.{ .break_stmt = value.span }),
        };
    }

    fn parseExprStatement(self: *Parser) !ast.StmtId {
        const value = try self.parseExpression(0);
        return self.result.ast.addStmt(.{ .expr = .{
            .span = self.astExprSpan(value),
            .value = value,
        } });
    }

    fn parseExpression(self: *Parser, minimum_precedence: u8) anyerror!ast.ExprId {
        var left = try self.parsePrefix();

        while (!self.peek().nl_before) {
            if (self.at(.l_paren)) {
                left = try self.parseCall(left);
                continue;
            }
            if (self.at(.dot)) {
                left = try self.parseProperty(left);
                continue;
            }
            if (self.at(.l_bracket)) {
                left = try self.parseIndex(left);
                continue;
            }
            if (self.at(.question)) {
                const question = self.next();
                left = try self.result.ast.addExpr(.{ .try_expr = .{
                    .span = spanFrom(self.astExprSpan(left), question.span),
                    .value = left,
                } });
                continue;
            }

            const precedence = binaryPrecedence(self.peek().kind);
            if (precedence == 0 or precedence < minimum_precedence) break;
            const operator = self.next();
            const right_precedence = if (operator.kind == .assign) precedence else precedence + 1;
            const right = try self.parseExpression(right_precedence);
            left = try self.result.ast.addExpr(.{ .binary = .{
                .span = spanFrom(self.astExprSpan(left), self.astExprSpan(right)),
                .left = left,
                .operator = operator.kind,
                .right = right,
            } });
        }

        return left;
    }

    fn parsePrefix(self: *Parser) anyerror!ast.ExprId {
        const value = self.next();
        return switch (value.kind) {
            .number => self.parseNumber(value),
            .boolean => self.result.ast.addExpr(.{ .boolean = .{
                .span = value.span,
                .value = std.mem.eql(u8, value.lexeme, "истина"),
            } }),
            .string => self.result.ast.addExpr(.{ .string = .{
                .span = value.span,
                .value = try self.result.ast.copyText(value.lexeme),
            } }),
            .ident => self.result.ast.addExpr(.{ .ident = .{
                .span = value.span,
                .name = try self.result.ast.copyText(value.lexeme),
            } }),
            .minus, .negate => blk: {
                const operand = try self.parseExpression(11);
                break :blk self.result.ast.addExpr(.{ .unary = .{
                    .span = spanFrom(value.span, self.astExprSpan(operand)),
                    .operator = value.kind,
                    .operand = operand,
                } });
            },
            .l_paren => self.parseGrouped(value),
            else => blk: {
                try self.report(value.span, "Синтаксическая ошибка: ожидается выражение");
                break :blk self.result.ast.addExpr(.{ .error_node = value.span });
            },
        };
    }

    fn parseNumber(self: *Parser, value: token.Token) !ast.ExprId {
        const number = std.fmt.parseFloat(f64, value.lexeme) catch {
            try self.report(value.span, "Синтаксическая ошибка: некорректное число");
            return self.result.ast.addExpr(.{ .error_node = value.span });
        };
        return self.result.ast.addExpr(.{ .number = .{ .span = value.span, .value = number } });
    }

    fn parseGrouped(self: *Parser, start: token.Token) !ast.ExprId {
        if (self.at(.r_paren)) {
            const end = self.next();
            return self.result.ast.addExpr(.{ .tuple = .{
                .span = spanFrom(start.span, end.span),
                .elements = &.{},
            } });
        }

        const first = try self.parseExpression(0);
        if (!self.at(.comma)) {
            _ = try self.expect(.r_paren, "Синтаксическая ошибка: ожидается ')'");
            return first;
        }

        var elements: std.ArrayList(ast.ExprId) = .empty;
        defer elements.deinit(self.result.allocator);
        try elements.append(self.result.allocator, first);
        while (self.at(.comma)) {
            _ = self.next();
            if (self.at(.r_paren)) break;
            try elements.append(self.result.allocator, try self.parseExpression(0));
        }
        const end = try self.expect(.r_paren, "Синтаксическая ошибка: ожидается ')' после тупла");
        return self.result.ast.addExpr(.{ .tuple = .{
            .span = spanFrom(start.span, end.span),
            .elements = try self.result.ast.copySlice(ast.ExprId, elements.items),
        } });
    }

    fn parseCall(self: *Parser, callee: ast.ExprId) !ast.ExprId {
        const start = self.astExprSpan(callee);
        _ = self.next();
        var arguments: std.ArrayList(ast.ExprId) = .empty;
        defer arguments.deinit(self.result.allocator);
        var argument_names: std.ArrayList([]const u8) = .empty;
        defer argument_names.deinit(self.result.allocator);
        var named: ?bool = null;

        while (!self.at(.r_paren) and !self.at(.eof)) {
            const is_named = self.at(.ident) and self.peekSecond().kind == .assign;
            if (named) |previous| {
                if (previous != is_named) try self.report(self.peek().span, "Синтаксическая ошибка: нельзя смешивать позиционные и именованные аргументы");
            } else {
                named = is_named;
            }

            if (is_named) {
                const name = self.next();
                _ = self.next();
                try argument_names.append(self.result.allocator, try self.result.ast.copyText(name.lexeme));
            }
            try arguments.append(self.result.allocator, try self.parseExpression(0));
            if (!self.at(.comma)) break;
            _ = self.next();
        }
        const end = try self.expect(.r_paren, "Синтаксическая ошибка: ожидается ')' после аргументов");
        return self.result.ast.addExpr(.{ .call = .{
            .span = spanFrom(start, end.span),
            .callee = callee,
            .arguments = try self.result.ast.copySlice(ast.ExprId, arguments.items),
            .argument_names = if (named orelse false)
                try self.result.ast.copySlice([]const u8, argument_names.items)
            else
                null,
        } });
    }

    fn parseProperty(self: *Parser, object: ast.ExprId) !ast.ExprId {
        _ = self.next();
        const property = self.next();
        if (property.kind != .ident and property.kind != .number) {
            try self.report(property.span, "Синтаксическая ошибка: после '.' ожидается имя свойства");
        }
        return self.result.ast.addExpr(.{ .property = .{
            .span = spanFrom(self.astExprSpan(object), property.span),
            .object = object,
            .property = try self.result.ast.copyText(property.lexeme),
        } });
    }

    fn parseIndex(self: *Parser, object: ast.ExprId) !ast.ExprId {
        _ = self.next();
        const index = try self.parseExpression(0);
        const end = try self.expect(.r_bracket, "Синтаксическая ошибка: ожидается ']' после индекса");
        return self.result.ast.addExpr(.{ .index = .{
            .span = spanFrom(self.astExprSpan(object), end.span),
            .object = object,
            .index = index,
        } });
    }

    fn consumeSemicolons(self: *Parser) void {
        while (self.at(.semicolon)) _ = self.next();
    }

    fn astExprSpan(self: *const Parser, id: ast.ExprId) source.Span {
        return switch (self.result.ast.expr(id).*) {
            inline else => |value| switch (@TypeOf(value)) {
                source.Span => value,
                else => value.span,
            },
        };
    }

    fn astTypeSpan(self: *const Parser, id: ast.TypeId) source.Span {
        return switch (self.result.ast.typeNode(id).*) {
            inline else => |value| switch (@TypeOf(value)) {
                source.Span => value,
                else => value.span,
            },
        };
    }
};

pub fn parse(allocator: std.mem.Allocator, tokens: []const token.Token) !ParseResult {
    var result = ParseResult.init(allocator);
    errdefer result.deinit();

    var parser = Parser{
        .tokens = tokens,
        .result = &result,
    };
    try parser.parseProgram();
    return result;
}

fn eofToken() token.Token {
    return .{
        .kind = .eof,
        .lexeme = "EOF",
        .span = .{ .file_id = 0, .start = 0, .end = 0 },
    };
}

fn binaryPrecedence(kind: token.TokenKind) u8 {
    return switch (kind) {
        .assign => 1,
        .or_expr => 2,
        .and_expr => 3,
        .equal, .not_equal => 4,
        .less, .less_equal, .greater, .greater_equal => 5,
        .pipe => 6,
        .caret => 7,
        .ampersand => 8,
        .less_less, .greater_greater => 9,
        .plus, .minus => 10,
        .star, .slash, .percent => 11,
        else => 0,
    };
}

test "parser builds an arena-backed function body from lexer tokens" {
    const lexer = @import("lexer.zig");
    var lexed = try lexer.tokenize(
        std.testing.allocator,
        "/// Складывает два числа.\nфунк сложить(a: Число, b: Число) -> Число\n    пер сумма = a + b\n    возврат сумма\nконец\n",
        6,
    );
    defer lexed.deinit();
    var parsed = try parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), lexed.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.ast.program.?.declarations.len);

    const declaration = parsed.ast.decl(parsed.ast.program.?.declarations[0]);
    switch (declaration.*) {
        .function => |function| {
            try std.testing.expectEqualStrings("сложить", function.name);
            try std.testing.expectEqual(@as(usize, 2), function.parameters.len);
            try std.testing.expectEqual(@as(usize, 2), function.body.len);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser reports a missing assignment and resumes at the next statement" {
    const lexer = @import("lexer.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ f() -> Число\nпер x 1\nx\nконец", 0);
    defer lexed.deinit();
    var parsed = try parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.diagnostics.items.items.len);
    try std.testing.expectEqualStrings(
        "Синтаксическая ошибка: после имени переменной ожидается '='",
        parsed.diagnostics.items.items[0].message,
    );
    const declaration = parsed.ast.decl(parsed.ast.program.?.declarations[0]);
    switch (declaration.*) {
        .function => |function| try std.testing.expectEqual(@as(usize, 2), function.body.len),
        else => return error.TestUnexpectedResult,
    }
}
