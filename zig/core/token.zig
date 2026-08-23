const std = @import("std");
const source = @import("source.zig");

pub const TokenKind = enum {
    number,
    boolean,
    plus,
    minus,
    star,
    string,
    slash,
    assign,
    l_paren,
    r_paren,
    l_bracket,
    r_bracket,
    less,
    greater,
    less_equal,
    greater_equal,
    equal,
    negate,
    not_equal,
    ident,
    function,
    colon,
    if_expr,
    then,
    else_expr,
    and_expr,
    or_expr,
    while_expr,
    loop,
    continue_expr,
    break_expr,
    arrow,
    end,
    type_decl,
    struct_decl,
    dot,
    impl,
    interface,
    for_expr,
    return_expr,
    defer_expr,
    let,
    constant,
    import,
    export_decl,
    enum_decl,
    match,
    as,
    semicolon,
    comma,
    question,
    spawn,
    wait_select,
    percent,
    in,
    foreign,
    ff_struct,
    interp_string_start,
    interp_string_mid,
    interp_string_end,
    ampersand,
    pipe,
    caret,
    tilde,
    less_less,
    greater_greater,
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    lexeme: []const u8,
    span: source.Span,
    nl_before: bool = false,
    doc: []const u8 = "",
};

pub fn lookupKeyword(identifier: []const u8) TokenKind {
    const keywords = [_]struct {
        spelling: []const u8,
        kind: TokenKind,
    }{
        .{ .spelling = "пер", .kind = .let },
        .{ .spelling = "конст", .kind = .constant },
        .{ .spelling = "истина", .kind = .boolean },
        .{ .spelling = "ложь", .kind = .boolean },
        .{ .spelling = "функ", .kind = .function },
        .{ .spelling = "возврат", .kind = .return_expr },
        .{ .spelling = "отложить", .kind = .defer_expr },
        .{ .spelling = "конец", .kind = .end },
        .{ .spelling = "пока", .kind = .while_expr },
        .{ .spelling = "цикл", .kind = .loop },
        .{ .spelling = "продолжить", .kind = .continue_expr },
        .{ .spelling = "прервать", .kind = .break_expr },
        .{ .spelling = "если", .kind = .if_expr },
        .{ .spelling = "тогда", .kind = .then },
        .{ .spelling = "иначе", .kind = .else_expr },
        .{ .spelling = "не", .kind = .negate },
        .{ .spelling = "и", .kind = .and_expr },
        .{ .spelling = "или", .kind = .or_expr },
        .{ .spelling = "тип", .kind = .type_decl },
        .{ .spelling = "структура", .kind = .struct_decl },
        .{ .spelling = "реализация", .kind = .impl },
        .{ .spelling = "интерфейс", .kind = .interface },
        .{ .spelling = "для", .kind = .for_expr },
        .{ .spelling = "импорт", .kind = .import },
        .{ .spelling = "экспорт", .kind = .export_decl },
        .{ .spelling = "перечисление", .kind = .enum_decl },
        .{ .spelling = "выбор", .kind = .match },
        .{ .spelling = "как", .kind = .as },
        .{ .spelling = "запусти", .kind = .spawn },
        // `выбор ожидание(...)` — блокирующее ожидание из нескольких
        // источников в стиле select; имеет смысл только сразу после
        // `выбор` (см. `parseMatchExpression` в `parser.zig`) — одиночное
        // `ожидание` где-либо ещё — ошибка разбора, как и лишний
        // `тогда`/`конец`.
        .{ .spelling = "ожидание", .kind = .wait_select },
        .{ .spelling = "в", .kind = .in },
        .{ .spelling = "внешний", .kind = .foreign },
        .{ .spelling = "ff_структура", .kind = .ff_struct },
    };

    for (keywords) |keyword| {
        if (std.mem.eql(u8, identifier, keyword.spelling)) return keyword.kind;
    }
    return .ident;
}

test "Russian keywords retain their Odin token kinds" {
    const cases = [_]struct {
        spelling: []const u8,
        kind: TokenKind,
    }{
        .{ .spelling = "пер", .kind = .let },
        .{ .spelling = "конст", .kind = .constant },
        .{ .spelling = "истина", .kind = .boolean },
        .{ .spelling = "ложь", .kind = .boolean },
        .{ .spelling = "функ", .kind = .function },
        .{ .spelling = "возврат", .kind = .return_expr },
        .{ .spelling = "отложить", .kind = .defer_expr },
        .{ .spelling = "конец", .kind = .end },
        .{ .spelling = "пока", .kind = .while_expr },
        .{ .spelling = "цикл", .kind = .loop },
        .{ .spelling = "продолжить", .kind = .continue_expr },
        .{ .spelling = "прервать", .kind = .break_expr },
        .{ .spelling = "если", .kind = .if_expr },
        .{ .spelling = "тогда", .kind = .then },
        .{ .spelling = "иначе", .kind = .else_expr },
        .{ .spelling = "не", .kind = .negate },
        .{ .spelling = "и", .kind = .and_expr },
        .{ .spelling = "или", .kind = .or_expr },
        .{ .spelling = "тип", .kind = .type_decl },
        .{ .spelling = "структура", .kind = .struct_decl },
        .{ .spelling = "реализация", .kind = .impl },
        .{ .spelling = "интерфейс", .kind = .interface },
        .{ .spelling = "для", .kind = .for_expr },
        .{ .spelling = "импорт", .kind = .import },
        .{ .spelling = "экспорт", .kind = .export_decl },
        .{ .spelling = "перечисление", .kind = .enum_decl },
        .{ .spelling = "выбор", .kind = .match },
        .{ .spelling = "как", .kind = .as },
        .{ .spelling = "запусти", .kind = .spawn },
        // `выбор ожидание(...)` — блокирующее ожидание из нескольких
        // источников в стиле select; имеет смысл только сразу после
        // `выбор` (см. `parseMatchExpression` в `parser.zig`) — одиночное
        // `ожидание` где-либо ещё — ошибка разбора, как и лишний
        // `тогда`/`конец`.
        .{ .spelling = "ожидание", .kind = .wait_select },
        .{ .spelling = "в", .kind = .in },
        .{ .spelling = "внешний", .kind = .foreign },
        .{ .spelling = "ff_структура", .kind = .ff_struct },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.kind, lookupKeyword(case.spelling));
    }
    try std.testing.expectEqual(TokenKind.ident, lookupKeyword("пользовательское_имя"));
}
