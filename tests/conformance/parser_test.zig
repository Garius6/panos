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

test "parser conformance fixture preserves module declarations and type syntax" {
    var lexed = try panos.lexer.tokenize(std.testing.allocator, @embedFile("parser/declarations.ps"), 0);
    defer lexed.deinit();
    var parsed = try panos.parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), lexed.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 4), parsed.ast.program.?.declarations.len);

    switch (parsed.ast.decl(parsed.ast.program.?.declarations[0]).*) {
        .import => |decl| {
            try std.testing.expectEqualStrings("./math", decl.path);
            try std.testing.expectEqualStrings("мат", decl.alias.?);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (parsed.ast.decl(parsed.ast.program.?.declarations[1]).*) {
        .constant => |decl| try std.testing.expect(decl.is_exported),
        else => return error.TestUnexpectedResult,
    }
    switch (parsed.ast.decl(parsed.ast.program.?.declarations[3]).*) {
        .function => |decl| {
            try std.testing.expectEqual(@as(usize, 1), decl.type_parameters.len);
            try std.testing.expectEqualStrings("T", decl.type_parameters[0].name);
            try std.testing.expectEqualStrings("Печатаемый", decl.type_parameters[0].bounds[0]);
        },
        else => return error.TestUnexpectedResult,
    }
}
