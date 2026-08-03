const std = @import("std");
const panos = @import("panos_core");

test "lexer conformance fixture preserves doc comments" {
    var result = try panos.lexer.tokenize(std.testing.allocator, @embedFile("lexer/basic.ps"), 0);
    defer result.deinit();

    try std.testing.expectEqual(panos.token.TokenKind.function, result.tokens.items[0].kind);
    try std.testing.expectEqualStrings("Складывает два числа.", result.tokens.items[0].doc);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
}

test "lexer conformance fixture preserves interpolation fragments" {
    var result = try panos.lexer.tokenize(std.testing.allocator, @embedFile("lexer/interpolation.ps"), 0);
    defer result.deinit();

    const expected = [_]panos.token.TokenKind{
        .let,
        .ident,
        .assign,
        .interp_string_start,
        .ident,
        .interp_string_end,
        .eof,
    };
    try std.testing.expectEqual(expected.len, result.tokens.items.len);
    for (expected, result.tokens.items) |kind, actual| {
        try std.testing.expectEqual(kind, actual.kind);
    }
}
