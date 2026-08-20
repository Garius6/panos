const std = @import("std");
const ast = @import("ast.zig");
const resolver = @import("resolver.zig");
const source = @import("source.zig");
const symbols = @import("symbols.zig");

// Классифицирует идентификаторы по УЖЕ вычисленному резолвером
// `Symbol.kind` — не по регулярным выражениям/соглашениям об именовании
// (регекс-подсветка не может по одному лишь имени отличить переменную от
// функции от типа, особенно с кириллицей, где нет универсального
// соглашения "тип начинается с заглавной буквы"). Порядок вариантов здесь
// ДОЛЖЕН совпадать с `token_type_names` ниже — индекс И ЕСТЬ тип токена
// протокола LSP (легенда в `zig/lsp/main.zig`).
pub const TokenType = enum(u32) {
    namespace,
    type,
    enum_member,
    function,
    variable,
    parameter,
};

pub const token_type_names = [_][]const u8{ "namespace", "type", "enumMember", "function", "variable", "parameter" };

pub const Token = struct {
    span: source.Span,
    token_type: TokenType,
};

// Только "голые" идентификаторы (выражения `.ident` через
// `resolution.expr_symbols` — выражение, разрешившееся в конкретный
// символ). Доступ через `.property` (`x.поле`/`x.метод()`) НЕ включается:
// резолвер также записывает разрешённый символ под СОБСТВЕННЫМ id
// выражения Property (для перехода к определению по
// модуль-квалифицированному вызову вроде `математика.пи()`) — без
// фильтрации только по `.ident` это дало бы второй, перекрывающий токен
// на весь "математика.пи", а не только на имя модуля. Поля/методы
// структур пока не классифицируются в любом случае — только
// идентификаторы уровня модуля (переменные, параметры, функции, типы,
// варианты перечислений, имена модулей).
pub fn computeSemanticTokens(allocator: std.mem.Allocator, tree: *const ast.Ast, resolution: *const resolver.Resolution) ![]Token {
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(allocator);

    var iterator = resolution.expr_symbols.iterator();
    while (iterator.next()) |entry| {
        const expression = entry.key_ptr.*;
        if (tree.expr(expression).* != .ident) continue;
        const symbol_id = entry.value_ptr.*;
        const symbol = resolution.symbols.get(symbol_id) orelse continue;
        const token_type: TokenType = switch (symbol.kind) {
            .type => .type,
            .enum_variant => .enum_member,
            .function => .function,
            .module => .namespace,
            .variable => if (isParameterSymbol(resolution, symbol_id)) .parameter else .variable,
            .constant => .variable,
            .builtin => continue,
        };
        try tokens.append(allocator, .{ .span = ast.exprSpan(tree.expr(expression).*), .token_type = token_type });
    }
    return tokens.toOwnedSlice(allocator);
}

// Параметром считается любой Symbol_Id, встречающийся в чьих-либо
// `function_parameters` — единственный способ отличить параметр от
// обычной локальной переменной `пер` (у обоих `SymbolKind.variable`,
// разница только в происхождении символа, и именно `function_parameters`
// об этом знает — см. `resolveFunctionBody` в `resolver.zig`).
fn isParameterSymbol(resolution: *const resolver.Resolution, symbol_id: symbols.SymbolId) bool {
    var iterator = resolution.function_parameters.valueIterator();
    while (iterator.next()) |parameter_symbols| {
        for (parameter_symbols.*) |candidate| {
            if (candidate == symbol_id) return true;
        }
    }
    return false;
}

test "computeSemanticTokens classifies by symbol kind" {
    const allocator = std.testing.allocator;
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const source_text =
        \\тип Точка = структура
        \\    x: Число
        \\конец
        \\
        \\функ квадрат(n: Целое) -> Целое
        \\    пер р: Целое = n * n
        \\    р
        \\конец
        \\
        \\функ старт() -> Пусто
        \\    пер п: Точка = Точка(1.0)
        \\    квадрат(3)
        \\конец
    ;
    var lexed = try lexer.tokenize(allocator, source_text, 0);
    defer lexed.deinit();
    var parsed = try parser.parse(allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(allocator, &parsed.ast);
    defer resolved.deinit();

    const tokens = try computeSemanticTokens(allocator, &parsed.ast, &resolved);
    defer allocator.free(tokens);

    var counts = [_]usize{0} ** 6;
    for (tokens) |token| counts[@intFromEnum(token.token_type)] += 1;

    try std.testing.expect(counts[@intFromEnum(TokenType.parameter)] >= 1);
    try std.testing.expect(counts[@intFromEnum(TokenType.variable)] >= 1);
    try std.testing.expect(counts[@intFromEnum(TokenType.type)] >= 1);
    try std.testing.expect(counts[@intFromEnum(TokenType.function)] >= 1);
}

test "computeSemanticTokens does not duplicate a token for a module-qualified call" {
    const allocator = std.testing.allocator;
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    // `фс` (не `строки`) — настоящий НАТИВНЫЙ встроенный модуль
    // (`installBuiltinModule` в `resolver.zig`), разрешимый без полного
    // графа импортов/загрузки файлов; `строки` в этом Zig-порте —
    // пользовательский файл `std/строки.ps`, который этот однофайловый
    // тест резолвера загрузить не может.
    const source_text =
        \\импорт фс
        \\
        \\функ старт() -> Булево
        \\    фс.есть("путь")
        \\конец
    ;
    var lexed = try lexer.tokenize(allocator, source_text, 0);
    defer lexed.deinit();
    var parsed = try parser.parse(allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(allocator, &parsed.ast);
    defer resolved.deinit();

    const tokens = try computeSemanticTokens(allocator, &parsed.ast, &resolved);
    defer allocator.free(tokens);

    var namespace_count: usize = 0;
    var max_len: usize = 0;
    for (tokens) |token| {
        if (token.token_type != .namespace) continue;
        namespace_count += 1;
        const length = token.span.end - token.span.start;
        if (length > max_len) max_len = length;
    }
    try std.testing.expectEqual(@as(usize, 1), namespace_count);
    // "фс" — 2 кириллических символа (4 байта UTF-8); утечка span'а
    // `.property` покрыла бы "фс.есть", что заметно длиннее.
    try std.testing.expect(max_len <= 10);
}
