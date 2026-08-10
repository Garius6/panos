const std = @import("std");
const panos = @import("panos_core");

test "parser accepts the complete demonstration program" {
    var lexed = try panos.lexer.tokenize(std.testing.allocator, @embedFile("test.pns"), 0);
    defer lexed.deinit();
    var parsed = try panos.parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), lexed.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    try std.testing.expect(parsed.ast.program.?.declarations.len > 20);
}
