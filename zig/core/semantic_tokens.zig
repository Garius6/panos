const std = @import("std");
const ast = @import("ast.zig");
const resolver = @import("resolver.zig");
const source = @import("source.zig");
const symbols = @import("symbols.zig");

// Ported from `core/semantic_tokens.odin`. Classifies identifiers by the
// resolver's ALREADY-computed `Symbol.kind` — not by regex/naming
// convention (a regex-based highlighter can't tell a variable from a
// function from a type by name alone, especially with Cyrillic, which has
// no universal "Type starts with a capital letter" convention). Variant
// order here MUST match `token_type_names` below — the index IS the
// LSP-protocol token type (`zig/lsp/main.zig`'s legend).
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

// Only bare identifiers (`.ident` expressions, via `resolution.expr_symbols`
// — an expression that resolved to a concrete symbol). `.property` access
// (`x.поле`/`x.метод()`) is NOT included: the resolver also records the
// resolved symbol under the Property expression's OWN id (for
// go-to-definition on a module-qualified call like `математика.пи()`) —
// without filtering to `.ident` only, that would produce a second,
// overlapping token spanning the whole "математика.пи", not just the
// module name. Struct fields/methods aren't classified yet either way,
// only module-level identifiers (variables, parameters, functions, types,
// enum variants, module names).
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

// A parameter is any Symbol_Id that shows up in SOMEONE's
// `function_parameters` — the only way to tell a parameter apart from an
// ordinary `пер`-local (both are `SymbolKind.variable`, the difference is
// only where the symbol came from, and `function_parameters` is the thing
// that knows that — see `resolver.zig`'s `resolveFunctionBody`).
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
    // `фс` (not `строки`) — a real NATIVE builtin module
    // (`resolver.zig`'s `installBuiltinModule`), resolvable without a full
    // import graph/file loading; `строки` is a user-level `std/строки.ps`
    // file in this Zig port (unlike Odin's, where it was a core builtin —
    // see the project's own migration notes), which this single-file
    // resolver test has no way to load.
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
    // "фс" is 2 Cyrillic characters (4 UTF-8 bytes); a `.property`-span
    // leak would cover "фс.есть", much longer.
    try std.testing.expect(max_len <= 10);
}
