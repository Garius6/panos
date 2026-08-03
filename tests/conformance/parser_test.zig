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

test "parser conformance fixture preserves structs interfaces and generic ADTs" {
    var lexed = try panos.lexer.tokenize(std.testing.allocator, @embedFile("parser/types.ps"), 0);
    defer lexed.deinit();
    var parsed = try panos.parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), lexed.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 4), parsed.ast.program.?.declarations.len);

    switch (parsed.ast.decl(parsed.ast.program.?.declarations[0]).*) {
        .struct_decl => |decl| {
            try std.testing.expect(decl.is_exported);
            try std.testing.expectEqual(@as(usize, 2), decl.fields.len);
            try std.testing.expectEqualStrings("Точка на плоскости.", decl.doc);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (parsed.ast.decl(parsed.ast.program.?.declarations[1]).*) {
        .interface_decl => |decl| try std.testing.expectEqual(@as(usize, 1), decl.methods.len),
        else => return error.TestUnexpectedResult,
    }
    switch (parsed.ast.decl(parsed.ast.program.?.declarations[2]).*) {
        .impl => |decl| {
            try std.testing.expectEqualStrings("Печатаемый", decl.interface_name.?);
            try std.testing.expectEqualStrings("Точка", decl.target_type);
            try std.testing.expectEqual(@as(usize, 1), decl.methods.len);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (parsed.ast.decl(parsed.ast.program.?.declarations[3]).*) {
        .enum_decl => |decl| {
            try std.testing.expectEqualStrings("T", decl.type_parameters[0]);
            try std.testing.expectEqual(@as(usize, 2), decl.variants.len);
            try std.testing.expectEqual(@as(usize, 1), decl.variants[1].types.len);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser conformance fixture preserves nested control-flow blocks" {
    var lexed = try panos.lexer.tokenize(std.testing.allocator, @embedFile("parser/control_flow.ps"), 0);
    defer lexed.deinit();
    var parsed = try panos.parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), lexed.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    const declaration = parsed.ast.decl(parsed.ast.program.?.declarations[0]);
    switch (declaration.*) {
        .function => |function| {
            try std.testing.expectEqual(@as(usize, 4), function.body.len);
            switch (parsed.ast.stmt(function.body[2]).*) {
                .expr => |statement| switch (parsed.ast.expr(statement.value).*) {
                    .while_expr => |loop| try std.testing.expectEqual(@as(usize, 2), loop.body.len),
                    else => return error.TestUnexpectedResult,
                },
                else => return error.TestUnexpectedResult,
            }
            switch (parsed.ast.stmt(function.body[3]).*) {
                .expr => |statement| switch (parsed.ast.expr(statement.value).*) {
                    .if_expr => |conditional| {
                        try std.testing.expectEqual(@as(usize, 1), conditional.then_branch.len);
                        try std.testing.expectEqual(@as(usize, 1), conditional.else_branch.len);
                    },
                    else => return error.TestUnexpectedResult,
                },
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser conformance fixture preserves for-in bindings" {
    var lexed = try panos.lexer.tokenize(std.testing.allocator, @embedFile("parser/for_in.ps"), 0);
    defer lexed.deinit();
    var parsed = try panos.parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), lexed.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    const declaration = parsed.ast.decl(parsed.ast.program.?.declarations[0]);
    switch (declaration.*) {
        .function => |function| switch (parsed.ast.stmt(function.body[1]).*) {
            .for_in => |loop| {
                try std.testing.expectEqual(@as(usize, 2), loop.names.len);
                try std.testing.expectEqualStrings("ключ", loop.names[0]);
                try std.testing.expectEqualStrings("значение", loop.names[1]);
                try std.testing.expectEqual(@as(usize, 1), loop.body.len);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser conformance fixture preserves lambdas and spawn expressions" {
    var lexed = try panos.lexer.tokenize(std.testing.allocator, @embedFile("parser/lambda_spawn.ps"), 0);
    defer lexed.deinit();
    var parsed = try panos.parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), lexed.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    switch (parsed.ast.decl(parsed.ast.program.?.declarations[0]).*) {
        .function => |function| switch (parsed.ast.stmt(function.body[0]).*) {
            .expr => |statement| switch (parsed.ast.expr(statement.value).*) {
                .lambda => |lambda| {
                    try std.testing.expectEqual(@as(usize, 1), lambda.parameters.len);
                    try std.testing.expect(lambda.parameters[0].type_annotation == null);
                },
                else => return error.TestUnexpectedResult,
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
    switch (parsed.ast.decl(parsed.ast.program.?.declarations[1]).*) {
        .function => |function| switch (parsed.ast.stmt(function.body[0]).*) {
            .expr => |statement| switch (parsed.ast.expr(statement.value).*) {
                .spawn => {},
                else => return error.TestUnexpectedResult,
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}
