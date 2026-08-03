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

    fn parseAnnotations(self: *Parser) ![]const ast.Annotation {
        var annotations: std.ArrayList(ast.Annotation) = .empty;
        defer annotations.deinit(self.result.allocator);

        while (self.at(.ampersand)) {
            const start = self.next();
            const name = try self.expect(.ident, "Синтаксическая ошибка: после '&' ожидается имя аннотации");
            var arguments: std.ArrayList(ast.AnnotationArgument) = .empty;
            defer arguments.deinit(self.result.allocator);
            var end = name.span;

            if (self.at(.l_paren)) {
                _ = self.next();
                while (!self.at(.r_paren) and !self.at(.eof)) {
                    try arguments.append(self.result.allocator, try self.parseAnnotationArgument());
                    if (!self.at(.comma)) break;
                    _ = self.next();
                }
                end = (try self.expect(.r_paren, "Синтаксическая ошибка: после аргументов аннотации ожидается ')'")).span;
            }

            try annotations.append(self.result.allocator, .{
                .span = spanFrom(start.span, end),
                .name = try self.result.ast.copyText(name.lexeme),
                .arguments = try self.result.ast.copySlice(ast.AnnotationArgument, arguments.items),
            });
        }
        return self.result.ast.copySlice(ast.Annotation, annotations.items);
    }

    fn parseAnnotationArgument(self: *Parser) !ast.AnnotationArgument {
        var name: ?[]const u8 = null;
        if (self.at(.ident) and self.peekSecond().kind == .assign) {
            name = try self.result.ast.copyText(self.next().lexeme);
            _ = self.next();
        }

        const value = self.next();
        const annotation_value: ast.AnnotationValue = switch (value.kind) {
            .string => .{ .string = try self.result.ast.copyText(value.lexeme) },
            .number => .{ .number = try self.result.ast.copyText(value.lexeme) },
            .boolean => .{ .boolean = try self.result.ast.copyText(value.lexeme) },
            .ident => .{ .ident = try self.result.ast.copyText(value.lexeme) },
            else => blk: {
                try self.report(value.span, "Синтаксическая ошибка: недопустимое значение аргумента аннотации");
                break :blk .{ .ident = "" };
            },
        };
        return .{ .name = name, .value = annotation_value };
    }

    fn parseProgram(self: *Parser) !void {
        var declarations: std.ArrayList(ast.DeclId) = .empty;
        defer declarations.deinit(self.result.allocator);

        while (!self.at(.eof)) {
            const doc = self.peek().doc;
            const annotations = try self.parseAnnotations();
            var exported = false;
            if (self.at(.export_decl)) {
                exported = true;
                _ = self.next();
            }

            if (self.at(.function)) {
                try declarations.append(self.result.allocator, try self.parseFunction(exported, doc, annotations));
                continue;
            }

            if (self.at(.import)) {
                if (exported) try self.report(self.peek().span, "Синтаксическая ошибка: 'экспорт' недопустим для импорта");
                if (annotations.len != 0) try self.report(self.peek().span, "Синтаксическая ошибка: аннотации недопустимы для импорта");
                try declarations.append(self.result.allocator, try self.parseImport());
                continue;
            }

            if (self.at(.constant)) {
                if (annotations.len != 0) try self.report(self.peek().span, "Синтаксическая ошибка: аннотации недопустимы для константы");
                try declarations.append(self.result.allocator, try self.parseTopLevelConst(exported, doc));
                continue;
            }

            if (self.at(.type_decl)) {
                try declarations.append(self.result.allocator, try self.parseTypeDeclaration(exported, doc, annotations));
                continue;
            }

            if (self.at(.impl)) {
                if (exported) try self.report(self.peek().span, "Синтаксическая ошибка: 'экспорт' недопустим для реализации");
                if (annotations.len != 0) try self.report(self.peek().span, "Синтаксическая ошибка: аннотации недопустимы для реализации");
                try declarations.append(self.result.allocator, try self.parseImplDeclaration());
                continue;
            }

            if (self.at(.foreign)) {
                if (exported) try self.report(self.peek().span, "Синтаксическая ошибка: 'внешний' не может быть экспортирован");
                if (annotations.len != 0) try self.report(self.peek().span, "Синтаксическая ошибка: аннотации недопустимы для 'внешний'");
                try declarations.append(self.result.allocator, try self.parseForeignDeclaration());
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

    fn parseFunction(self: *Parser, is_exported: bool, doc: []const u8, annotations: []const ast.Annotation) !ast.DeclId {
        const start = try self.expect(.function, "Синтаксическая ошибка: ожидается 'функ'");
        const name_token = try self.expect(.ident, "Синтаксическая ошибка: после 'функ' ожидается имя");
        const name = try self.result.ast.copyText(name_token.lexeme);
        const type_parameters = try self.parseTypeParameters();

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
            .type_parameters = type_parameters,
            .parameters = try self.result.ast.copySlice(ast.ParamDecl, parameters.items),
            .return_type = return_type,
            .body = try self.result.ast.copySlice(ast.StmtId, body.items),
            .is_exported = is_exported,
            .annotations = annotations,
        } });
    }

    fn parseType(self: *Parser) anyerror!ast.TypeId {
        const value = self.next();
        if (value.kind == .function) return self.parseFunctionType(value);
        if (value.kind == .l_paren) return self.parseTupleType(value);
        if (value.kind != .ident) {
            try self.report(value.span, "Синтаксическая ошибка: ожидается тип");
            return self.result.ast.addType(.{ .error_node = value.span });
        }

        const name = try self.result.ast.copyText(value.lexeme);
        if (self.at(.dot)) {
            _ = self.next();
            const member = try self.expect(.ident, "Синтаксическая ошибка: после '.' ожидается имя типа");
            const parameters = try self.parseTypeArguments();
            const end = if (parameters.end) |span| span else member.span;
            return self.result.ast.addType(.{ .qualified = .{
                .span = spanFrom(value.span, end),
                .module_name = name,
                .name = try self.result.ast.copyText(member.lexeme),
                .parameters = parameters.values,
            } });
        }

        const parameters = try self.parseTypeArguments();
        if (parameters.values.len == 0) {
            return self.result.ast.addType(.{ .ident = .{ .span = value.span, .name = name } });
        }
        return self.result.ast.addType(.{ .generic = .{
            .span = spanFrom(value.span, parameters.end.?),
            .name = name,
            .parameters = parameters.values,
        } });
    }

    fn parseImport(self: *Parser) !ast.DeclId {
        const start = try self.expect(.import, "Синтаксическая ошибка: ожидается 'импорт'");
        const path = self.next();
        if (path.kind != .ident and path.kind != .string) {
            try self.report(path.span, "Синтаксическая ошибка: после 'импорт' ожидается имя модуля или строка пути");
        }

        var alias: ?[]const u8 = null;
        var end = path.span;
        if (self.at(.as)) {
            _ = self.next();
            const alias_token = try self.expect(.ident, "Синтаксическая ошибка: после 'как' ожидается псевдоним");
            alias = try self.result.ast.copyText(alias_token.lexeme);
            end = alias_token.span;
        }
        self.consumeSemicolons();
        return self.result.ast.addDecl(.{ .import = .{
            .span = spanFrom(start.span, end),
            .path = try self.result.ast.copyText(path.lexeme),
            .alias = alias,
        } });
    }

    fn parseTopLevelConst(self: *Parser, is_exported: bool, doc: []const u8) !ast.DeclId {
        const start = try self.expect(.constant, "Синтаксическая ошибка: ожидается 'конст'");
        const name = try self.expect(.ident, "Синтаксическая ошибка: после 'конст' ожидается имя");
        _ = try self.expect(.assign, "Синтаксическая ошибка: после имени константы ожидается '='");
        const value = try self.parseExpression(0);
        self.consumeSemicolons();
        return self.result.ast.addDecl(.{ .constant = .{
            .span = spanFrom(start.span, self.astExprSpan(value)),
            .name = try self.result.ast.copyText(name.lexeme),
            .name_span = name.span,
            .doc = try self.result.ast.copyText(doc),
            .value = value,
            .is_exported = is_exported,
        } });
    }

    fn parseTypeDeclaration(self: *Parser, is_exported: bool, doc: []const u8, annotations: []const ast.Annotation) !ast.DeclId {
        const start = try self.expect(.type_decl, "Синтаксическая ошибка: ожидается 'тип'");
        const name = try self.expect(.ident, "Синтаксическая ошибка: после 'тип' ожидается имя");
        const type_parameters = try self.parseDeclaredTypeParameters();
        _ = try self.expect(.assign, "Синтаксическая ошибка: после имени типа ожидается '='");

        return switch (self.peek().kind) {
            .struct_decl => self.parseStructDeclaration(start, name, type_parameters, is_exported, doc, annotations),
            .interface => self.parseInterfaceDeclaration(start, name, type_parameters, is_exported, doc, annotations),
            .enum_decl => self.parseEnumDeclaration(start, name, type_parameters, is_exported, doc, annotations),
            .ff_struct => blk: {
                if (annotations.len != 0) try self.report(name.span, "Синтаксическая ошибка: аннотации недопустимы для ff_структура");
                break :blk self.parseFfiStructDeclaration(start, name, type_parameters, is_exported, doc);
            },
            else => self.parseTypeAliasAfterHeader(start, name, type_parameters, is_exported, doc, annotations),
        };
    }

    fn parseTypeAliasAfterHeader(
        self: *Parser,
        start: token.Token,
        name: token.Token,
        type_parameters: []const []const u8,
        is_exported: bool,
        doc: []const u8,
        annotations: []const ast.Annotation,
    ) !ast.DeclId {
        if (type_parameters.len != 0) {
            try self.report(name.span, "Синтаксическая ошибка: generic type alias пока не поддержан");
        }
        const aliased_type = try self.parseType();
        self.consumeSemicolons();
        return self.result.ast.addDecl(.{ .type_alias = .{
            .span = spanFrom(start.span, self.astTypeSpan(aliased_type)),
            .name = try self.result.ast.copyText(name.lexeme),
            .doc = try self.result.ast.copyText(doc),
            .is_exported = is_exported,
            .annotations = annotations,
            .aliased_type = aliased_type,
        } });
    }

    fn parseStructDeclaration(
        self: *Parser,
        start: token.Token,
        name: token.Token,
        type_parameters: []const []const u8,
        is_exported: bool,
        doc: []const u8,
        annotations: []const ast.Annotation,
    ) !ast.DeclId {
        _ = try self.expect(.struct_decl, "Синтаксическая ошибка: ожидается 'структура'");
        var fields: std.ArrayList(ast.FieldDecl) = .empty;
        defer fields.deinit(self.result.allocator);

        while (!self.at(.end) and !self.at(.eof)) {
            const field_annotations = try self.parseAnnotations();
            const field_start = self.peek().span;
            const field_name = try self.expect(.ident, "Синтаксическая ошибка: ожидается имя поля структуры");
            _ = try self.expect(.colon, "Синтаксическая ошибка: после имени поля ожидается ':'");
            const field_type = try self.parseType();
            try fields.append(self.result.allocator, .{
                .span = spanFrom(field_start, self.astTypeSpan(field_type)),
                .name = try self.result.ast.copyText(field_name.lexeme),
                .type_annotation = field_type,
                .annotations = field_annotations,
            });
            self.consumeSemicolons();
        }
        const end = try self.expect(.end, "Синтаксическая ошибка: структура не закрыта 'конец'");
        return self.result.ast.addDecl(.{ .struct_decl = .{
            .span = spanFrom(start.span, end.span),
            .name = try self.result.ast.copyText(name.lexeme),
            .doc = try self.result.ast.copyText(doc),
            .type_parameters = type_parameters,
            .fields = try self.result.ast.copySlice(ast.FieldDecl, fields.items),
            .is_exported = is_exported,
            .annotations = annotations,
        } });
    }

    fn parseFfiStructDeclaration(
        self: *Parser,
        start: token.Token,
        name: token.Token,
        type_parameters: []const []const u8,
        is_exported: bool,
        doc: []const u8,
    ) !ast.DeclId {
        _ = try self.expect(.ff_struct, "Синтаксическая ошибка: ожидается 'ff_структура'");
        if (type_parameters.len != 0) {
            try self.report(name.span, "Синтаксическая ошибка: ff_структура не поддерживает type-параметры");
        }

        var fields: std.ArrayList(ast.FieldDecl) = .empty;
        defer fields.deinit(self.result.allocator);
        while (!self.at(.end) and !self.at(.eof)) {
            const field_start = self.peek().span;
            const field_name = try self.expect(.ident, "Синтаксическая ошибка: ожидается имя поля ff_структура");
            _ = try self.expect(.colon, "Синтаксическая ошибка: после имени поля ff_структура ожидается ':'");
            const field_type = try self.parseForeignMarshalType();
            const supported = switch (field_type.marshal) {
                .int8, .int32, .int64, .float32, .float64 => true,
                else => false,
            };
            if (!supported) {
                try self.report(field_name.span, "Синтаксическая ошибка: поле ff_структура поддерживает только Целое(8|32|64)/Число(32|64)");
            }
            try fields.append(self.result.allocator, .{
                .span = spanFrom(field_start, field_type.span),
                .name = try self.result.ast.copyText(field_name.lexeme),
                .marshal = if (supported) field_type.marshal else .int32,
            });
            self.consumeSemicolons();
        }
        const end = try self.expect(.end, "Синтаксическая ошибка: ff_структура не закрыта 'конец'");
        return self.result.ast.addDecl(.{ .struct_decl = .{
            .span = spanFrom(start.span, end.span),
            .name = try self.result.ast.copyText(name.lexeme),
            .doc = try self.result.ast.copyText(doc),
            .type_parameters = &.{},
            .fields = try self.result.ast.copySlice(ast.FieldDecl, fields.items),
            .is_exported = is_exported,
            .is_ffi = true,
        } });
    }

    fn parseImplDeclaration(self: *Parser) !ast.DeclId {
        const start = try self.expect(.impl, "Синтаксическая ошибка: ожидается 'реализация'");
        const first = try self.parseQualifiedName("Синтаксическая ошибка: после 'реализация' ожидается тип или интерфейс");

        var interface_module: ?[]const u8 = null;
        var interface_name: ?[]const u8 = null;
        var target_module: ?[]const u8 = null;
        var target_type: []const u8 = undefined;
        if (self.at(.for_expr)) {
            _ = self.next();
            const target = try self.parseQualifiedName("Синтаксическая ошибка: после 'для' ожидается целевой тип");
            interface_module = first.module_name;
            interface_name = first.name;
            target_module = target.module_name;
            target_type = target.name;
        } else {
            target_module = first.module_name;
            target_type = first.name;
        }

        var methods: std.ArrayList(ast.DeclId) = .empty;
        defer methods.deinit(self.result.allocator);
        while (!self.at(.end) and !self.at(.eof)) {
            const doc = self.peek().doc;
            if (!self.at(.function)) {
                try self.report(self.peek().span, "Синтаксическая ошибка: в реализации ожидается 'функ'");
                _ = self.next();
                continue;
            }
            try methods.append(self.result.allocator, try self.parseFunction(false, doc, &.{}));
        }
        const end = try self.expect(.end, "Синтаксическая ошибка: реализация не закрыта 'конец'");
        return self.result.ast.addDecl(.{ .impl = .{
            .span = spanFrom(start.span, end.span),
            .interface_module = interface_module,
            .interface_name = interface_name,
            .target_module = target_module,
            .target_type = target_type,
            .methods = try self.result.ast.copySlice(ast.DeclId, methods.items),
        } });
    }

    const ParsedForeignMarshal = struct {
        span: source.Span,
        marshal: ast.ForeignMarshalKind,
        pointee: ?ast.TypeId = null,
        struct_type_name: ?[]const u8 = null,
    };

    fn parseForeignDeclaration(self: *Parser) !ast.DeclId {
        const start = try self.expect(.foreign, "Синтаксическая ошибка: ожидается 'внешний'");
        const library = try self.expect(.string, "Синтаксическая ошибка: после 'внешний' ожидается имя библиотеки строкой");
        _ = try self.expect(.function, "Синтаксическая ошибка: после имени библиотеки ожидается 'функ'");
        const name = try self.expect(.ident, "Синтаксическая ошибка: после 'функ' ожидается имя");

        var parameters: std.ArrayList(ast.ForeignParam) = .empty;
        defer parameters.deinit(self.result.allocator);
        _ = try self.expect(.l_paren, "Синтаксическая ошибка: после имени внешней функции ожидается '('");
        while (!self.at(.r_paren) and !self.at(.eof)) {
            const parameter_start = self.peek().span;
            const parameter_name = try self.expect(.ident, "Синтаксическая ошибка: ожидается имя параметра внешней функции");
            _ = try self.expect(.colon, "Синтаксическая ошибка: после имени параметра ожидается ':'");
            const parameter_type = try self.parseForeignMarshalType();
            if (parameter_type.marshal == .void) {
                try self.report(parameter_start, "Синтаксическая ошибка: 'Пусто' допустим только как возвращаемый тип 'внешний', не как тип параметра");
            }
            try parameters.append(self.result.allocator, .{
                .span = spanFrom(parameter_start, parameter_type.span),
                .name = try self.result.ast.copyText(parameter_name.lexeme),
                .marshal = parameter_type.marshal,
                .pointee = parameter_type.pointee,
                .struct_type_name = parameter_type.struct_type_name,
            });
            if (!self.at(.comma)) break;
            _ = self.next();
        }
        _ = try self.expect(.r_paren, "Синтаксическая ошибка: ожидается ')' после параметров внешней функции");
        _ = try self.expect(.arrow, "Синтаксическая ошибка: после параметров внешней функции ожидается '-> Тип'");
        const return_type = try self.parseForeignMarshalType();
        const return_owned = if (return_type.marshal == .pointer) self.parseForeignOwnershipSuffix() else false;
        self.consumeSemicolons();

        return self.result.ast.addDecl(.{ .foreign = .{
            .span = spanFrom(start.span, return_type.span),
            .library = try self.result.ast.copyText(library.lexeme),
            .name = try self.result.ast.copyText(name.lexeme),
            .parameters = try self.result.ast.copySlice(ast.ForeignParam, parameters.items),
            .return_marshal = return_type.marshal,
            .return_pointee = return_type.pointee,
            .return_struct_type_name = return_type.struct_type_name,
            .return_owned = return_owned,
        } });
    }

    fn parseForeignMarshalType(self: *Parser) anyerror!ParsedForeignMarshal {
        const type_token = self.peek();
        if (type_token.kind != .ident) {
            try self.report(type_token.span, "Синтаксическая ошибка: во 'внешний' ожидается тип (Целое/Число/КСтрока/Указатель/Пусто)");
            _ = self.next();
            return .{ .span = type_token.span, .marshal = .int32 };
        }
        _ = self.next();

        if (std.mem.eql(u8, type_token.lexeme, "Пусто")) {
            return .{ .span = type_token.span, .marshal = .void };
        }
        if (std.mem.eql(u8, type_token.lexeme, "КСтрока")) {
            return .{ .span = type_token.span, .marshal = .c_string };
        }
        if (std.mem.eql(u8, type_token.lexeme, "Указатель")) {
            _ = try self.expect(.l_paren, "Синтаксическая ошибка: после 'Указатель' ожидается '('");
            const pointee = try self.parseType();
            const end = try self.expect(.r_paren, "Синтаксическая ошибка: после типа указателя ожидается ')'");
            return .{ .span = spanFrom(type_token.span, end.span), .marshal = .pointer, .pointee = pointee };
        }
        if (std.mem.eql(u8, type_token.lexeme, "Целое") or std.mem.eql(u8, type_token.lexeme, "Число")) {
            _ = try self.expect(.l_paren, "Синтаксическая ошибка: после ABI-типа ожидается ширина в скобках");
            const width = self.next();
            const end = try self.expect(.r_paren, "Синтаксическая ошибка: после ширины ABI-типа ожидается ')'");
            const is_integer = std.mem.eql(u8, type_token.lexeme, "Целое");
            const valid_width = if (is_integer)
                std.mem.eql(u8, width.lexeme, "8") or std.mem.eql(u8, width.lexeme, "32") or std.mem.eql(u8, width.lexeme, "64")
            else
                std.mem.eql(u8, width.lexeme, "32") or std.mem.eql(u8, width.lexeme, "64");
            if (width.kind != .number or !valid_width) {
                try self.report(width.span, if (is_integer)
                    "Синтаксическая ошибка: 'Целое(...)' в 'внешний' ожидает ширину 8, 32 или 64"
                else
                    "Синтаксическая ошибка: 'Число(...)' в 'внешний' ожидает ширину 32 или 64");
            }
            return .{
                .span = spanFrom(type_token.span, end.span),
                .marshal = if (is_integer)
                    if (std.mem.eql(u8, width.lexeme, "8")) .int8 else if (std.mem.eql(u8, width.lexeme, "64")) .int64 else .int32
                else if (std.mem.eql(u8, width.lexeme, "64")) .float64 else .float32,
            };
        }

        return .{
            .span = type_token.span,
            .marshal = .struct_value,
            .struct_type_name = try self.result.ast.copyText(type_token.lexeme),
        };
    }

    fn parseForeignOwnershipSuffix(self: *Parser) bool {
        if (!self.at(.ident)) return false;
        if (std.mem.eql(u8, self.peek().lexeme, "свой")) {
            _ = self.next();
            return true;
        }
        if (std.mem.eql(u8, self.peek().lexeme, "чужой")) _ = self.next();
        return false;
    }

    const QualifiedName = struct {
        span: source.Span,
        module_name: ?[]const u8,
        name: []const u8,
    };

    fn parseQualifiedName(self: *Parser, message: []const u8) !QualifiedName {
        const first = try self.expect(.ident, message);
        const first_name = try self.result.ast.copyText(first.lexeme);
        if (!self.at(.dot)) {
            return .{
                .span = first.span,
                .module_name = null,
                .name = first_name,
            };
        }
        _ = self.next();
        const member = try self.expect(.ident, "Синтаксическая ошибка: после '.' ожидается имя");
        return .{
            .span = spanFrom(first.span, member.span),
            .module_name = first_name,
            .name = try self.result.ast.copyText(member.lexeme),
        };
    }

    fn parseInterfaceDeclaration(
        self: *Parser,
        start: token.Token,
        name: token.Token,
        type_parameters: []const []const u8,
        is_exported: bool,
        doc: []const u8,
        annotations: []const ast.Annotation,
    ) !ast.DeclId {
        _ = try self.expect(.interface, "Синтаксическая ошибка: ожидается 'интерфейс'");
        var methods: std.ArrayList(ast.MethodSignature) = .empty;
        defer methods.deinit(self.result.allocator);

        while (!self.at(.end) and !self.at(.eof)) {
            try methods.append(self.result.allocator, try self.parseMethodSignature());
            self.consumeSemicolons();
        }
        const end = try self.expect(.end, "Синтаксическая ошибка: интерфейс не закрыт 'конец'");
        return self.result.ast.addDecl(.{ .interface_decl = .{
            .span = spanFrom(start.span, end.span),
            .name = try self.result.ast.copyText(name.lexeme),
            .doc = try self.result.ast.copyText(doc),
            .type_parameters = type_parameters,
            .methods = try self.result.ast.copySlice(ast.MethodSignature, methods.items),
            .is_exported = is_exported,
            .annotations = annotations,
        } });
    }

    fn parseMethodSignature(self: *Parser) !ast.MethodSignature {
        const start = try self.expect(.function, "Синтаксическая ошибка: в интерфейсе ожидается 'функ'");
        const name = try self.expect(.ident, "Синтаксическая ошибка: после 'функ' ожидается имя метода");
        const parameters = try self.parseParameterList();
        _ = try self.expect(.arrow, "Синтаксическая ошибка: после параметров ожидается '-> Тип'");
        const return_type = try self.parseType();
        return .{
            .span = spanFrom(start.span, self.astTypeSpan(return_type)),
            .name = try self.result.ast.copyText(name.lexeme),
            .parameters = parameters,
            .return_type = return_type,
        };
    }

    fn parseEnumDeclaration(
        self: *Parser,
        start: token.Token,
        name: token.Token,
        type_parameters: []const []const u8,
        is_exported: bool,
        doc: []const u8,
        annotations: []const ast.Annotation,
    ) !ast.DeclId {
        _ = try self.expect(.enum_decl, "Синтаксическая ошибка: ожидается 'перечисление'");
        var variants: std.ArrayList(ast.VariantDecl) = .empty;
        defer variants.deinit(self.result.allocator);

        while (!self.at(.end) and !self.at(.eof)) {
            const variant_name = try self.expect(.ident, "Синтаксическая ошибка: ожидается имя варианта перечисления");
            var types: std.ArrayList(ast.TypeId) = .empty;
            defer types.deinit(self.result.allocator);
            var end = variant_name.span;
            if (self.at(.l_paren)) {
                _ = self.next();
                while (!self.at(.r_paren) and !self.at(.eof)) {
                    try types.append(self.result.allocator, try self.parseType());
                    if (!self.at(.comma)) break;
                    _ = self.next();
                }
                end = (try self.expect(.r_paren, "Синтаксическая ошибка: ожидается ')' после полей варианта")).span;
            }
            try variants.append(self.result.allocator, .{
                .span = spanFrom(variant_name.span, end),
                .name = try self.result.ast.copyText(variant_name.lexeme),
                .types = try self.result.ast.copySlice(ast.TypeId, types.items),
            });
            self.consumeSemicolons();
        }
        const end = try self.expect(.end, "Синтаксическая ошибка: перечисление не закрыто 'конец'");
        return self.result.ast.addDecl(.{ .enum_decl = .{
            .span = spanFrom(start.span, end.span),
            .name = try self.result.ast.copyText(name.lexeme),
            .doc = try self.result.ast.copyText(doc),
            .type_parameters = type_parameters,
            .variants = try self.result.ast.copySlice(ast.VariantDecl, variants.items),
            .is_exported = is_exported,
            .annotations = annotations,
        } });
    }

    fn parseParameterList(self: *Parser) ![]const ast.ParamDecl {
        var parameters: std.ArrayList(ast.ParamDecl) = .empty;
        defer parameters.deinit(self.result.allocator);
        _ = try self.expect(.l_paren, "Синтаксическая ошибка: после имени ожидается '('");
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
        return self.result.ast.copySlice(ast.ParamDecl, parameters.items);
    }

    fn parseDeclaredTypeParameters(self: *Parser) ![]const []const u8 {
        if (!self.at(.l_bracket)) return &.{};
        _ = self.next();
        var parameters: std.ArrayList([]const u8) = .empty;
        defer parameters.deinit(self.result.allocator);
        while (!self.at(.r_bracket) and !self.at(.eof)) {
            const name = try self.expect(.ident, "Синтаксическая ошибка: ожидается имя type-параметра");
            try parameters.append(self.result.allocator, try self.result.ast.copyText(name.lexeme));
            if (self.at(.colon)) {
                try self.report(self.peek().span, "Синтаксическая ошибка: ограничения type-параметров допустимы только у функций");
                _ = self.next();
                while (self.at(.ident) or self.at(.plus)) _ = self.next();
            }
            if (!self.at(.comma)) break;
            _ = self.next();
        }
        _ = try self.expect(.r_bracket, "Синтаксическая ошибка: ожидается ']' после type-параметров");
        return self.result.ast.copySlice([]const u8, parameters.items);
    }

    fn parseTypeParameters(self: *Parser) ![]const ast.TypeParameter {
        if (!self.at(.l_bracket)) return &.{};
        _ = self.next();
        var parameters: std.ArrayList(ast.TypeParameter) = .empty;
        defer parameters.deinit(self.result.allocator);

        while (!self.at(.r_bracket) and !self.at(.eof)) {
            const name = try self.expect(.ident, "Синтаксическая ошибка: ожидается имя type-параметра");
            var bounds: std.ArrayList([]const u8) = .empty;
            defer bounds.deinit(self.result.allocator);
            if (self.at(.colon)) {
                _ = self.next();
                while (true) {
                    const bound = try self.expect(.ident, "Синтаксическая ошибка: ожидается интерфейс-ограничение");
                    try bounds.append(self.result.allocator, try self.result.ast.copyText(bound.lexeme));
                    if (!self.at(.plus)) break;
                    _ = self.next();
                }
            }
            try parameters.append(self.result.allocator, .{
                .name = try self.result.ast.copyText(name.lexeme),
                .bounds = try self.result.ast.copySlice([]const u8, bounds.items),
            });
            if (!self.at(.comma)) break;
            _ = self.next();
        }
        _ = try self.expect(.r_bracket, "Синтаксическая ошибка: ожидается ']' после type-параметров");
        return self.result.ast.copySlice(ast.TypeParameter, parameters.items);
    }

    fn skipBracketedTypeParameters(self: *Parser) void {
        var depth: usize = 0;
        while (!self.at(.eof)) {
            const value = self.next();
            if (value.kind == .l_bracket) depth += 1;
            if (value.kind == .r_bracket) {
                depth -= 1;
                if (depth == 0) return;
            }
        }
    }

    fn parseFunctionType(self: *Parser, start: token.Token) !ast.TypeId {
        _ = try self.expect(.l_paren, "Синтаксическая ошибка: после 'функ' ожидается '('");
        var parameters: std.ArrayList(ast.TypeId) = .empty;
        defer parameters.deinit(self.result.allocator);
        while (!self.at(.r_paren) and !self.at(.eof)) {
            try parameters.append(self.result.allocator, try self.parseType());
            if (!self.at(.comma)) break;
            _ = self.next();
        }
        _ = try self.expect(.r_paren, "Синтаксическая ошибка: ожидается ')' после параметров типа функции");
        _ = try self.expect(.arrow, "Синтаксическая ошибка: после параметров типа функции ожидается '->'");
        const return_type = try self.parseType();
        return self.result.ast.addType(.{ .function = .{
            .span = spanFrom(start.span, self.astTypeSpan(return_type)),
            .parameters = try self.result.ast.copySlice(ast.TypeId, parameters.items),
            .return_type = return_type,
        } });
    }

    fn parseTupleType(self: *Parser, start: token.Token) !ast.TypeId {
        var elements: std.ArrayList(ast.TypeId) = .empty;
        defer elements.deinit(self.result.allocator);
        while (!self.at(.r_paren) and !self.at(.eof)) {
            try elements.append(self.result.allocator, try self.parseType());
            if (!self.at(.comma)) break;
            _ = self.next();
        }
        const end = try self.expect(.r_paren, "Синтаксическая ошибка: ожидается ')' после type-тупла");
        return self.result.ast.addType(.{ .tuple = .{
            .span = spanFrom(start.span, end.span),
            .elements = try self.result.ast.copySlice(ast.TypeId, elements.items),
        } });
    }

    const ParsedTypeArguments = struct {
        values: []const ast.TypeId,
        end: ?source.Span,
    };

    fn parseTypeArguments(self: *Parser) !ParsedTypeArguments {
        if (!self.at(.l_paren) or self.peek().nl_before) return .{ .values = &.{}, .end = null };
        _ = self.next();
        var parameters: std.ArrayList(ast.TypeId) = .empty;
        defer parameters.deinit(self.result.allocator);
        while (!self.at(.r_paren) and !self.at(.eof)) {
            try parameters.append(self.result.allocator, try self.parseType());
            if (!self.at(.comma)) break;
            _ = self.next();
        }
        const end = try self.expect(.r_paren, "Синтаксическая ошибка: ожидается ')' после параметров типа");
        return .{
            .values = try self.result.ast.copySlice(ast.TypeId, parameters.items),
            .end = end.span,
        };
    }

    fn parseStatement(self: *Parser) !ast.StmtId {
        return switch (self.peek().kind) {
            .let, .constant => self.parseLet(),
            .return_expr => self.parseReturn(),
            .continue_expr => self.parseMarker(.continue_stmt),
            .break_expr => self.parseMarker(.break_stmt),
            .for_expr => self.parseForIn(),
            else => self.parseExprStatement(),
        };
    }

    fn parseForIn(self: *Parser) !ast.StmtId {
        const start = try self.expect(.for_expr, "Синтаксическая ошибка: ожидается 'для'");
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.result.allocator);

        if (self.at(.l_paren)) {
            _ = self.next();
            while (!self.at(.r_paren) and !self.at(.eof)) {
                const name = try self.expect(.ident, "Синтаксическая ошибка: в 'для' ожидается имя переменной");
                try names.append(self.result.allocator, try self.result.ast.copyText(name.lexeme));
                if (!self.at(.comma)) break;
                _ = self.next();
            }
            _ = try self.expect(.r_paren, "Синтаксическая ошибка: ожидается ')' в 'для'");
        } else {
            const name = try self.expect(.ident, "Синтаксическая ошибка: после 'для' ожидается имя переменной");
            try names.append(self.result.allocator, try self.result.ast.copyText(name.lexeme));
            if (self.at(.assign)) return self.parseForRange(start, name);
        }

        _ = try self.expect(.in, "Синтаксическая ошибка: после переменной 'для' ожидается 'в'");
        const iterable = try self.parseExpression(0);
        _ = try self.expect(.loop, "Синтаксическая ошибка: после итерируемого значения ожидается 'цикл'");
        const body = try self.parseStatementBlock(null);
        const end = try self.expect(.end, "Синтаксическая ошибка: 'для' не закрыт 'конец'");
        return self.result.ast.addStmt(.{ .for_in = .{
            .span = spanFrom(start.span, end.span),
            .names = try self.result.ast.copySlice([]const u8, names.items),
            .iterable = iterable,
            .body = body,
        } });
    }

    fn parseForRange(self: *Parser, start: token.Token, name: token.Token) !ast.StmtId {
        _ = try self.expect(.assign, "Синтаксическая ошибка: после переменной диапазона ожидается '='");
        const range_start = try self.parseExpression(0);
        const through = self.next();
        if (through.kind != .ident or !std.mem.eql(u8, through.lexeme, "по")) {
            try self.report(through.span, "Синтаксическая ошибка: после начала диапазона 'для X = ...' ожидается 'по'");
        }
        const range_end = try self.parseExpression(0);
        _ = try self.expect(.loop, "Синтаксическая ошибка: после конца диапазона ожидается 'цикл'");
        const body = try self.parseStatementBlock(null);
        const end = try self.expect(.end, "Синтаксическая ошибка: диапазон 'для' не закрыт 'конец'");
        return self.result.ast.addStmt(.{ .for_range = .{
            .span = spanFrom(start.span, end.span),
            .name = try self.result.ast.copyText(name.lexeme),
            .start = range_start,
            .end = range_end,
            .body = body,
        } });
    }

    fn parseLet(self: *Parser) !ast.StmtId {
        const start = self.next();
        var name: ?[]const u8 = null;
        var type_annotation: ?ast.TypeId = null;
        var destructure_names: []const []const u8 = &.{};
        var destructure_type: ?[]const u8 = null;
        var destructure_field_names: ?[]const []const u8 = null;

        if (self.at(.l_paren)) {
            const destructure = try self.parseDestructureNames(false);
            destructure_names = destructure.names;
        } else {
            const name_token = try self.expect(.ident, "Синтаксическая ошибка: после 'пер' ожидается имя");
            if (self.at(.l_paren)) {
                destructure_type = try self.result.ast.copyText(name_token.lexeme);
                const destructure = try self.parseDestructureNames(true);
                destructure_names = destructure.names;
                destructure_field_names = destructure.field_names;
            } else {
                name = try self.result.ast.copyText(name_token.lexeme);
                if (self.at(.colon)) {
                    _ = self.next();
                    type_annotation = try self.parseType();
                }
            }
        }
        if (self.at(.assign)) {
            _ = self.next();
        } else {
            try self.report(self.peek().span, "Синтаксическая ошибка: после имени переменной ожидается '='");
        }
        const value = try self.parseExpression(0);
        return self.result.ast.addStmt(.{ .let = .{
            .span = spanFrom(start.span, self.astExprSpan(value)),
            .name = name,
            .value = value,
            .type_annotation = type_annotation,
            .is_const = start.kind == .constant,
            .destructure_names = destructure_names,
            .destructure_type = destructure_type,
            .destructure_field_names = destructure_field_names,
        } });
    }

    const DestructureNames = struct {
        names: []const []const u8,
        field_names: ?[]const []const u8 = null,
    };

    fn parseDestructureNames(self: *Parser, allow_named: bool) !DestructureNames {
        _ = try self.expect(.l_paren, "Синтаксическая ошибка: ожидается '('");
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.result.allocator);
        var field_names: std.ArrayList([]const u8) = .empty;
        defer field_names.deinit(self.result.allocator);
        const named = allow_named and self.at(.ident) and self.peekSecond().kind == .colon;

        while (!self.at(.r_paren) and !self.at(.eof)) {
            if (named) {
                const field = try self.expect(.ident, "Синтаксическая ошибка: ожидается имя поля в именованной деструктуризации");
                _ = try self.expect(.colon, "Синтаксическая ошибка: после имени поля деструктуризации ожидается ':'");
                try field_names.append(self.result.allocator, try self.result.ast.copyText(field.lexeme));
            } else if (allow_named and self.at(.ident) and self.peekSecond().kind == .colon) {
                try self.report(self.peek().span, "Синтаксическая ошибка: нельзя смешивать позиционную и именованную деструктуризацию");
            }

            const name = try self.expect(.ident, "Синтаксическая ошибка: в шаблоне деструктуризации ожидается идентификатор");
            try names.append(self.result.allocator, try self.result.ast.copyText(name.lexeme));
            if (!self.at(.comma)) break;
            _ = self.next();
        }
        _ = try self.expect(.r_paren, "Синтаксическая ошибка: ожидается ')' после шаблона деструктуризации");
        return .{
            .names = try self.result.ast.copySlice([]const u8, names.items),
            .field_names = if (named) try self.result.ast.copySlice([]const u8, field_names.items) else null,
        };
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

        while (true) {
            if (!self.peek().nl_before) {
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
            .interp_string_start => self.parseInterpolatedString(value),
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
            .if_expr => self.parseIfExpression(value),
            .while_expr => self.parseWhileExpression(value),
            .function => self.parseLambdaExpression(value),
            .spawn => self.parseSpawnExpression(value),
            .match => self.parseMatchExpression(value),
            else => blk: {
                try self.report(value.span, "Синтаксическая ошибка: ожидается выражение");
                break :blk self.result.ast.addExpr(.{ .error_node = value.span });
            },
        };
    }

    fn parseLambdaExpression(self: *Parser, start: token.Token) anyerror!ast.ExprId {
        const parameters = try self.parseLambdaParameters();
        var return_type: ?ast.TypeId = null;
        if (self.at(.arrow)) {
            _ = self.next();
            return_type = try self.parseType();
        }
        const body = try self.parseStatementBlock(null);
        const end = try self.expect(.end, "Синтаксическая ошибка: лямбда не закрыта 'конец'");
        return self.result.ast.addExpr(.{ .lambda = .{
            .span = spanFrom(start.span, end.span),
            .parameters = parameters,
            .return_type = return_type,
            .body = body,
        } });
    }

    fn parseLambdaParameters(self: *Parser) ![]const ast.ParamDecl {
        var parameters: std.ArrayList(ast.ParamDecl) = .empty;
        defer parameters.deinit(self.result.allocator);
        _ = try self.expect(.l_paren, "Синтаксическая ошибка: после 'функ' ожидается '('");
        while (!self.at(.r_paren) and !self.at(.eof)) {
            const name = try self.expect(.ident, "Синтаксическая ошибка: ожидается имя параметра лямбды");
            var type_annotation: ?ast.TypeId = null;
            var end = name.span;
            if (self.at(.colon)) {
                _ = self.next();
                type_annotation = try self.parseType();
                end = self.astTypeSpan(type_annotation.?);
            }
            try parameters.append(self.result.allocator, .{
                .span = spanFrom(name.span, end),
                .name = try self.result.ast.copyText(name.lexeme),
                .type_annotation = type_annotation,
            });
            if (!self.at(.comma)) break;
            _ = self.next();
        }
        _ = try self.expect(.r_paren, "Синтаксическая ошибка: ожидается ')' после параметров лямбды");
        return self.result.ast.copySlice(ast.ParamDecl, parameters.items);
    }

    fn parseSpawnExpression(self: *Parser, start: token.Token) anyerror!ast.ExprId {
        const call = try self.parseExpression(12);
        return self.result.ast.addExpr(.{ .spawn = .{
            .span = spanFrom(start.span, self.astExprSpan(call)),
            .call = call,
        } });
    }

    fn parseMatchExpression(self: *Parser, start: token.Token) anyerror!ast.ExprId {
        const subject = try self.parseExpression(0);
        var arms: std.ArrayList(ast.MatchArm) = .empty;
        defer arms.deinit(self.result.allocator);

        while (!self.at(.end) and !self.at(.eof)) {
            const arm_start = self.peek().span;
            const pattern = try self.parsePattern();
            var body: []const ast.StmtId = undefined;
            var end = self.astPatternSpan(pattern);
            if (self.at(.then)) {
                _ = self.next();
                body = try self.parseStatementBlock(null);
                end = (try self.expect(.end, "Синтаксическая ошибка: блок ветки 'выбор' не закрыт 'конец'")).span;
            } else {
                _ = try self.expect(.arrow, "Синтаксическая ошибка: после шаблона 'выбор' ожидается '->'");
                const value = try self.parseExpression(0);
                const statement = try self.result.ast.addStmt(.{ .expr = .{
                    .span = self.astExprSpan(value),
                    .value = value,
                } });
                body = try self.result.ast.copySlice(ast.StmtId, &.{statement});
                end = self.astExprSpan(value);
                self.consumeSemicolons();
            }
            try arms.append(self.result.allocator, .{
                .span = spanFrom(arm_start, end),
                .pattern = pattern,
                .body = body,
            });
        }

        const end = try self.expect(.end, "Синтаксическая ошибка: 'выбор' не закрыт 'конец'");
        if (arms.items.len == 0) {
            try self.report(start.span, "Синтаксическая ошибка: выбор должен содержать хотя бы одну ветку");
        }
        return self.result.ast.addExpr(.{ .match_expr = .{
            .span = spanFrom(start.span, end.span),
            .subject = subject,
            .arms = try self.result.ast.copySlice(ast.MatchArm, arms.items),
        } });
    }

    fn parsePattern(self: *Parser) anyerror!ast.PatternId {
        const value = self.next();
        switch (value.kind) {
            .number => {
                const literal = try self.parseNumber(value);
                return self.result.ast.addPattern(.{ .literal = .{
                    .span = value.span,
                    .value = literal,
                } });
            },
            .string => {
                const literal = try self.result.ast.addExpr(.{ .string = .{
                    .span = value.span,
                    .value = try self.result.ast.copyText(value.lexeme),
                } });
                return self.result.ast.addPattern(.{ .literal = .{
                    .span = value.span,
                    .value = literal,
                } });
            },
            .boolean => {
                const literal = try self.result.ast.addExpr(.{ .boolean = .{
                    .span = value.span,
                    .value = std.mem.eql(u8, value.lexeme, "истина"),
                } });
                return self.result.ast.addPattern(.{ .literal = .{
                    .span = value.span,
                    .value = literal,
                } });
            },
            .ident => {},
            else => {
                try self.report(value.span, "Синтаксическая ошибка: такой шаблон в выборе не поддержан");
                return self.result.ast.addPattern(.{ .error_node = value.span });
            },
        }

        if (std.mem.eql(u8, value.lexeme, "_")) {
            return self.result.ast.addPattern(.{ .wildcard = value.span });
        }

        var module_name: ?[]const u8 = null;
        var name = try self.result.ast.copyText(value.lexeme);
        var end = value.span;
        if (self.at(.dot)) {
            _ = self.next();
            const member = try self.expect(.ident, "Синтаксическая ошибка: после '.' в шаблоне ожидается идентификатор");
            module_name = name;
            name = try self.result.ast.copyText(member.lexeme);
            end = member.span;
            if (self.at(.dot)) {
                _ = self.next();
                const variant = try self.expect(.ident, "Синтаксическая ошибка: после '.' в квалифицированном шаблоне ожидается идентификатор");
                module_name = try std.fmt.allocPrint(self.result.ast.arena.allocator(), "{s}.{s}", .{ module_name.?, name });
                name = try self.result.ast.copyText(variant.lexeme);
                end = variant.span;
            }
        }

        if (!self.at(.l_paren)) {
            if (module_name) |module| {
                return self.result.ast.addPattern(.{ .constructor = .{
                    .span = spanFrom(value.span, end),
                    .module_name = module,
                    .name = name,
                } });
            }
            return self.result.ast.addPattern(.{ .ident = .{
                .span = value.span,
                .name = name,
            } });
        }

        _ = self.next();
        var arguments: std.ArrayList(ast.PatternId) = .empty;
        defer arguments.deinit(self.result.allocator);
        var field_names: std.ArrayList([]const u8) = .empty;
        defer field_names.deinit(self.result.allocator);
        const named = self.at(.ident) and self.peekSecond().kind == .colon;
        while (!self.at(.r_paren) and !self.at(.eof)) {
            if (named) {
                const field = try self.expect(.ident, "Синтаксическая ошибка: ожидается имя поля шаблона");
                _ = try self.expect(.colon, "Синтаксическая ошибка: после имени поля шаблона ожидается ':'");
                try field_names.append(self.result.allocator, try self.result.ast.copyText(field.lexeme));
            } else if (self.at(.ident) and self.peekSecond().kind == .colon) {
                try self.report(self.peek().span, "Синтаксическая ошибка: нельзя смешивать позиционные и именованные поля в шаблоне");
            }
            try arguments.append(self.result.allocator, try self.parsePattern());
            if (!self.at(.comma)) break;
            _ = self.next();
        }
        end = (try self.expect(.r_paren, "Синтаксическая ошибка: ожидается ')' после шаблона-конструктора")).span;
        return self.result.ast.addPattern(.{ .constructor = .{
            .span = spanFrom(value.span, end),
            .module_name = module_name,
            .name = name,
            .arguments = try self.result.ast.copySlice(ast.PatternId, arguments.items),
            .field_names = if (named) try self.result.ast.copySlice([]const u8, field_names.items) else null,
        } });
    }

    fn parseIfExpression(self: *Parser, start: token.Token) anyerror!ast.ExprId {
        const condition = try self.parseExpression(0);
        _ = try self.expect(.then, "Синтаксическая ошибка: после условия 'если' ожидается 'тогда'");
        const then_branch = try self.parseStatementBlock(.else_expr);
        var else_branch: []const ast.StmtId = &.{};
        if (self.at(.else_expr)) {
            _ = self.next();
            else_branch = try self.parseStatementBlock(null);
        }
        const end = try self.expect(.end, "Синтаксическая ошибка: 'если' не закрыт 'конец'");
        return self.result.ast.addExpr(.{ .if_expr = .{
            .span = spanFrom(start.span, end.span),
            .condition = condition,
            .then_branch = then_branch,
            .else_branch = else_branch,
        } });
    }

    fn parseWhileExpression(self: *Parser, start: token.Token) anyerror!ast.ExprId {
        const condition = try self.parseExpression(0);
        _ = try self.expect(.loop, "Синтаксическая ошибка: после условия 'пока' ожидается 'цикл'");
        const body = try self.parseStatementBlock(null);
        const end = try self.expect(.end, "Синтаксическая ошибка: 'пока' не закрыт 'конец'");
        return self.result.ast.addExpr(.{ .while_expr = .{
            .span = spanFrom(start.span, end.span),
            .condition = condition,
            .body = body,
        } });
    }

    fn parseStatementBlock(self: *Parser, alternate_terminator: ?token.TokenKind) ![]const ast.StmtId {
        var statements: std.ArrayList(ast.StmtId) = .empty;
        defer statements.deinit(self.result.allocator);
        while (!self.at(.end) and (alternate_terminator == null or !self.at(alternate_terminator.?)) and !self.at(.eof)) {
            try statements.append(self.result.allocator, try self.parseStatement());
            self.consumeSemicolons();
        }
        return self.result.ast.copySlice(ast.StmtId, statements.items);
    }

    fn parseNumber(self: *Parser, value: token.Token) !ast.ExprId {
        const number = std.fmt.parseFloat(f64, value.lexeme) catch {
            try self.report(value.span, "Синтаксическая ошибка: некорректное число");
            return self.result.ast.addExpr(.{ .error_node = value.span });
        };
        return self.result.ast.addExpr(.{ .number = .{ .span = value.span, .value = number } });
    }

    fn parseInterpolatedString(self: *Parser, start: token.Token) anyerror!ast.ExprId {
        var result: ?ast.ExprId = null;
        try self.appendInterpolationString(&result, start);

        while (true) {
            const embedded = try self.parseExpression(0);
            const embedded_span = self.astExprSpan(embedded);
            const callee = try self.result.ast.addExpr(.{ .ident = .{
                .span = embedded_span,
                .name = try self.result.ast.copyText("встроку"),
            } });
            const conversion = try self.result.ast.addExpr(.{ .call = .{
                .span = embedded_span,
                .callee = callee,
                .arguments = try self.result.ast.copySlice(ast.ExprId, &.{embedded}),
            } });
            if (result) |previous| {
                result = try self.result.ast.addExpr(.{ .binary = .{
                    .span = spanFrom(self.astExprSpan(previous), embedded_span),
                    .left = previous,
                    .operator = .plus,
                    .right = conversion,
                } });
            } else {
                result = conversion;
            }

            const fragment = self.next();
            switch (fragment.kind) {
                .interp_string_mid => {
                    try self.appendInterpolationString(&result, fragment);
                },
                .interp_string_end => {
                    try self.appendInterpolationString(&result, fragment);
                    return result.?;
                },
                else => {
                    try self.report(fragment.span, "Синтаксическая ошибка: ожидалось продолжение строковой интерполяции");
                    return result.?;
                },
            }
        }
    }

    fn appendInterpolationString(self: *Parser, result: *?ast.ExprId, fragment: token.Token) !void {
        if (fragment.lexeme.len == 0) return;
        const literal = try self.result.ast.addExpr(.{ .string = .{
            .span = fragment.span,
            .value = try self.result.ast.copyText(fragment.lexeme),
        } });
        if (result.*) |previous| {
            result.* = try self.result.ast.addExpr(.{ .binary = .{
                .span = spanFrom(self.astExprSpan(previous), fragment.span),
                .left = previous,
                .operator = .plus,
                .right = literal,
            } });
        } else {
            result.* = literal;
        }
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
        switch (self.result.ast.expr(callee).*) {
            .ident => |ident| {
                if (std.mem.eql(u8, ident.name, "массив")) return self.parseArrayLiteral(start);
                if (std.mem.eql(u8, ident.name, "соответствие")) return self.parseMapLiteral(start);
            },
            else => {},
        }

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

    fn parseArrayLiteral(self: *Parser, start: source.Span) !ast.ExprId {
        var elements: std.ArrayList(ast.ExprId) = .empty;
        defer elements.deinit(self.result.allocator);
        while (!self.at(.r_paren) and !self.at(.eof)) {
            try elements.append(self.result.allocator, try self.parseExpression(0));
            if (!self.at(.comma)) break;
            _ = self.next();
        }
        const end = try self.expect(.r_paren, "Синтаксическая ошибка: ожидается ')' после элементов массива");
        return self.result.ast.addExpr(.{ .array = .{
            .span = spanFrom(start, end.span),
            .elements = try self.result.ast.copySlice(ast.ExprId, elements.items),
        } });
    }

    fn parseMapLiteral(self: *Parser, start: source.Span) !ast.ExprId {
        var entries: std.ArrayList(ast.MapEntry) = .empty;
        defer entries.deinit(self.result.allocator);
        while (!self.at(.r_paren) and !self.at(.eof)) {
            const entry_start = self.peek().span;
            const key = try self.parseExpression(12);
            _ = try self.expect(.assign, "Синтаксическая ошибка: после ключа соответствия ожидается '='");
            const value = try self.parseExpression(0);
            try entries.append(self.result.allocator, .{
                .span = spanFrom(entry_start, self.astExprSpan(value)),
                .key = key,
                .value = value,
            });
            if (!self.at(.comma)) break;
            _ = self.next();
        }
        const end = try self.expect(.r_paren, "Синтаксическая ошибка: ожидается ')' после пар соответствия");
        return self.result.ast.addExpr(.{ .map = .{
            .span = spanFrom(start, end.span),
            .entries = try self.result.ast.copySlice(ast.MapEntry, entries.items),
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

    fn astPatternSpan(self: *const Parser, id: ast.PatternId) source.Span {
        return switch (self.result.ast.pattern(id).*) {
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
