const std = @import("std");
const panos = @import("panos_core");

test "parser conformance fixture produces one typed function" {
    var lexed = try panos.lexer.tokenize(std.testing.allocator, @embedFile("parser/basic.ps"), 0);
    defer lexed.deinit();
    var parsed = try panos.parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), lexed.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
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
