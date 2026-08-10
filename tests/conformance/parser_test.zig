const std = @import("std");
const panos = @import("panos_core");

test "parser conformance fixture produces one typed function" {
    var lexed = try panos.lexer.tokenize(std.testing.allocator, @embedFile("parser/basic.pns"), 0);
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
    var lexed = try panos.lexer.tokenize(std.testing.allocator, @embedFile("parser/declarations.pns"), 0);
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
    var lexed = try panos.lexer.tokenize(std.testing.allocator, @embedFile("parser/types.pns"), 0);
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
    var lexed = try panos.lexer.tokenize(std.testing.allocator, @embedFile("parser/control_flow.pns"), 0);
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
    var lexed = try panos.lexer.tokenize(std.testing.allocator, @embedFile("parser/for_in.pns"), 0);
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

test "parser conformance fixture preserves inclusive numeric ranges" {
    var lexed = try panos.lexer.tokenize(std.testing.allocator, @embedFile("parser/for_range.pns"), 0);
    defer lexed.deinit();
    var parsed = try panos.parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), lexed.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    const declaration = parsed.ast.decl(parsed.ast.program.?.declarations[0]);
    switch (declaration.*) {
        .function => |function| switch (parsed.ast.stmt(function.body[1]).*) {
            .for_range => |range| {
                try std.testing.expectEqualStrings("счётчик", range.name);
                try std.testing.expectEqual(@as(usize, 1), range.body.len);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser conformance fixture accepts binary operators after a line break" {
    var lexed = try panos.lexer.tokenize(std.testing.allocator, @embedFile("parser/wrapped_binary.pns"), 0);
    defer lexed.deinit();
    var parsed = try panos.parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), lexed.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    const declaration = parsed.ast.decl(parsed.ast.program.?.declarations[0]);
    switch (declaration.*) {
        .function => |function| switch (parsed.ast.stmt(function.body[0]).*) {
            .expr => |statement| switch (parsed.ast.expr(statement.value).*) {
                .if_expr => |conditional| switch (parsed.ast.expr(conditional.condition).*) {
                    .binary => |binary| try std.testing.expectEqual(panos.token.TokenKind.and_expr, binary.operator),
                    else => return error.TestUnexpectedResult,
                },
                else => return error.TestUnexpectedResult,
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser conformance fixture preserves bitwise negation and tuple index chains" {
    var lexed = try panos.lexer.tokenize(std.testing.allocator, @embedFile("parser/bitwise_tuple_index.pns"), 0);
    defer lexed.deinit();
    var parsed = try panos.parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), lexed.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    const declaration = parsed.ast.decl(parsed.ast.program.?.declarations[0]);
    switch (declaration.*) {
        .function => |function| {
            switch (parsed.ast.stmt(function.body[1]).*) {
                .let => |statement| switch (parsed.ast.expr(statement.value).*) {
                    .property => |outer| {
                        try std.testing.expectEqualStrings("0", outer.property);
                        switch (parsed.ast.expr(outer.object).*) {
                            .property => |inner| try std.testing.expectEqualStrings("1", inner.property),
                            else => return error.TestUnexpectedResult,
                        }
                    },
                    else => return error.TestUnexpectedResult,
                },
                else => return error.TestUnexpectedResult,
            }
            switch (parsed.ast.stmt(function.body[2]).*) {
                .expr => |statement| switch (parsed.ast.expr(statement.value).*) {
                    .unary => |unary| try std.testing.expectEqual(panos.token.TokenKind.tilde, unary.operator),
                    else => return error.TestUnexpectedResult,
                },
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser conformance fixture recovers at the next top-level declaration" {
    const input = @embedFile("parser/recovery.pns");
    var lexed = try panos.lexer.tokenize(std.testing.allocator, input, 0);
    defer lexed.deinit();
    var parsed = try panos.parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), lexed.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.diagnostics.items.items.len);
    try std.testing.expectEqual(panos.diagnostic.Phase.parser, parsed.diagnostics.items.items[0].phase);
    try std.testing.expectEqualDeep(panos.source.Span{
        .file_id = 0,
        .start = 0,
        .end = "неожиданная".len,
    }, parsed.diagnostics.items.items[0].span);
    try std.testing.expectEqual(@as(usize, 2), parsed.ast.program.?.declarations.len);
    switch (parsed.ast.decl(parsed.ast.program.?.declarations[0]).*) {
        .error_node => {},
        else => return error.TestUnexpectedResult,
    }
    switch (parsed.ast.decl(parsed.ast.program.?.declarations[1]).*) {
        .function => |function| {
            try std.testing.expectEqualStrings("рабочая", function.name);
            try std.testing.expectEqual(@as(usize, std.mem.indexOf(u8, input, "функ").?), function.span.start);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser conformance fixture preserves lambdas and spawn expressions" {
    var lexed = try panos.lexer.tokenize(std.testing.allocator, @embedFile("parser/lambda_spawn.pns"), 0);
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

test "parser conformance fixture preserves match patterns and both arm forms" {
    var lexed = try panos.lexer.tokenize(std.testing.allocator, @embedFile("parser/match.pns"), 0);
    defer lexed.deinit();
    var parsed = try panos.parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), lexed.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    const declaration = parsed.ast.decl(parsed.ast.program.?.declarations[0]);
    switch (declaration.*) {
        .function => |function| switch (parsed.ast.stmt(function.body[0]).*) {
            .expr => |statement| switch (parsed.ast.expr(statement.value).*) {
                .match_expr => |match| {
                    try std.testing.expectEqual(@as(usize, 3), match.arms.len);
                    try std.testing.expectEqual(@as(usize, 1), match.arms[1].body.len);
                    switch (parsed.ast.pattern(match.arms[0].pattern).*) {
                        .constructor => |pattern| {
                            try std.testing.expectEqualStrings("Фигура", pattern.module_name.?);
                            try std.testing.expectEqualStrings("Круг", pattern.name);
                        },
                        else => return error.TestUnexpectedResult,
                    }
                    switch (parsed.ast.pattern(match.arms[2].pattern).*) {
                        .wildcard => {},
                        else => return error.TestUnexpectedResult,
                    }
                },
                else => return error.TestUnexpectedResult,
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser conformance fixture preserves foreign ABI declarations" {
    var lexed = try panos.lexer.tokenize(std.testing.allocator, @embedFile("parser/foreign.pns"), 0);
    defer lexed.deinit();
    var parsed = try panos.parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), lexed.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.ast.program.?.declarations.len);
    switch (parsed.ast.decl(parsed.ast.program.?.declarations[0]).*) {
        .foreign => |decl| {
            try std.testing.expectEqualStrings("libc", decl.library);
            try std.testing.expectEqualStrings("копировать", decl.name);
            try std.testing.expectEqual(@as(usize, 3), decl.parameters.len);
            try std.testing.expectEqual(panos.ast.ForeignMarshalKind.pointer, decl.parameters[0].marshal);
            try std.testing.expectEqual(panos.ast.ForeignMarshalKind.c_string, decl.parameters[1].marshal);
            try std.testing.expectEqual(panos.ast.ForeignMarshalKind.int64, decl.parameters[2].marshal);
            try std.testing.expectEqual(panos.ast.ForeignMarshalKind.pointer, decl.return_marshal);
            try std.testing.expect(decl.return_owned);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (parsed.ast.decl(parsed.ast.program.?.declarations[1]).*) {
        .foreign => |decl| try std.testing.expectEqual(panos.ast.ForeignMarshalKind.float64, decl.return_marshal),
        else => return error.TestUnexpectedResult,
    }
}

test "parser conformance fixture preserves FFI structs and values by ABI" {
    var lexed = try panos.lexer.tokenize(std.testing.allocator, @embedFile("parser/ffi_struct.pns"), 0);
    defer lexed.deinit();
    var parsed = try panos.parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), lexed.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    switch (parsed.ast.decl(parsed.ast.program.?.declarations[0]).*) {
        .struct_decl => |decl| {
            try std.testing.expect(decl.is_ffi);
            try std.testing.expectEqual(@as(usize, 2), decl.fields.len);
            try std.testing.expectEqual(panos.ast.ForeignMarshalKind.float32, decl.fields[0].marshal.?);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (parsed.ast.decl(parsed.ast.program.?.declarations[1]).*) {
        .foreign => |decl| {
            try std.testing.expectEqual(panos.ast.ForeignMarshalKind.struct_value, decl.parameters[0].marshal);
            try std.testing.expectEqualStrings("Вектор2", decl.return_struct_type_name.?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser conformance fixture preserves declaration and field annotations" {
    var lexed = try panos.lexer.tokenize(std.testing.allocator, @embedFile("parser/annotations.pns"), 0);
    defer lexed.deinit();
    var parsed = try panos.parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), lexed.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    switch (parsed.ast.decl(parsed.ast.program.?.declarations[0]).*) {
        .function => |decl| {
            try std.testing.expect(decl.is_exported);
            try std.testing.expectEqual(@as(usize, 1), decl.annotations.len);
            try std.testing.expectEqualStrings("Маршрут", decl.annotations[0].name);
            try std.testing.expectEqual(@as(usize, 4), decl.annotations[0].arguments.len);
            try std.testing.expectEqualStrings("путь", decl.annotations[0].arguments[1].name.?);
            switch (decl.annotations[0].arguments[0].value) {
                .string => |value| try std.testing.expectEqualStrings("GET", value),
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
    switch (parsed.ast.decl(parsed.ast.program.?.declarations[1]).*) {
        .struct_decl => |decl| {
            try std.testing.expectEqualStrings("Модель", decl.annotations[0].name);
            try std.testing.expectEqual(@as(usize, 1), decl.fields[0].annotations.len);
            try std.testing.expectEqualStrings("Поле", decl.fields[0].annotations[0].name);
            try std.testing.expectEqualStrings("индекс", decl.fields[0].annotations[0].arguments[1].name.?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser conformance fixture lowers collection constructor literals" {
    var lexed = try panos.lexer.tokenize(std.testing.allocator, @embedFile("parser/collections.pns"), 0);
    defer lexed.deinit();
    var parsed = try panos.parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), lexed.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    const declaration = parsed.ast.decl(parsed.ast.program.?.declarations[0]);
    switch (declaration.*) {
        .function => |function| {
            switch (parsed.ast.stmt(function.body[0]).*) {
                .let => |statement| switch (parsed.ast.expr(statement.value).*) {
                    .array => |array| try std.testing.expectEqual(@as(usize, 2), array.elements.len),
                    else => return error.TestUnexpectedResult,
                },
                else => return error.TestUnexpectedResult,
            }
            switch (parsed.ast.stmt(function.body[1]).*) {
                .let => |statement| switch (parsed.ast.expr(statement.value).*) {
                    .map => |map| try std.testing.expectEqual(@as(usize, 2), map.entries.len),
                    else => return error.TestUnexpectedResult,
                },
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser conformance fixture preserves tuple and struct destructuring" {
    var lexed = try panos.lexer.tokenize(std.testing.allocator, @embedFile("parser/destructure.pns"), 0);
    defer lexed.deinit();
    var parsed = try panos.parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), lexed.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    const declaration = parsed.ast.decl(parsed.ast.program.?.declarations[1]);
    switch (declaration.*) {
        .function => |function| {
            switch (parsed.ast.stmt(function.body[0]).*) {
                .let => |statement| {
                    try std.testing.expect(statement.name == null);
                    try std.testing.expectEqual(@as(usize, 2), statement.destructure_names.len);
                    try std.testing.expect(statement.destructure_type == null);
                },
                else => return error.TestUnexpectedResult,
            }
            switch (parsed.ast.stmt(function.body[1]).*) {
                .let => |statement| {
                    try std.testing.expectEqualStrings("Точка", statement.destructure_type.?);
                    try std.testing.expectEqualStrings("x", statement.destructure_field_names.?[0]);
                    try std.testing.expectEqualStrings("абсцисса", statement.destructure_names[0]);
                },
                else => return error.TestUnexpectedResult,
            }
            switch (parsed.ast.stmt(function.body[2]).*) {
                .let => |statement| {
                    try std.testing.expect(statement.is_const);
                    try std.testing.expect(statement.destructure_field_names == null);
                },
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser conformance fixture desugars interpolated strings" {
    var lexed = try panos.lexer.tokenize(std.testing.allocator, @embedFile("parser/interpolation.pns"), 0);
    defer lexed.deinit();
    var parsed = try panos.parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), lexed.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    var conversions: usize = 0;
    for (parsed.ast.expressions.items) |expression| switch (expression) {
        .call => |call| switch (parsed.ast.expr(call.callee).*) {
            .ident => |ident| {
                if (std.mem.eql(u8, ident.name, "встроку")) conversions += 1;
            },
            else => {},
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), conversions);
}

test "parser conformance fixture preserves three-part match qualifications" {
    var lexed = try panos.lexer.tokenize(std.testing.allocator, @embedFile("parser/qualified_match.pns"), 0);
    defer lexed.deinit();
    var parsed = try panos.parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), lexed.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    const declaration = parsed.ast.decl(parsed.ast.program.?.declarations[0]);
    switch (declaration.*) {
        .function => |function| switch (parsed.ast.stmt(function.body[0]).*) {
            .expr => |statement| switch (parsed.ast.expr(statement.value).*) {
                .match_expr => |match| switch (parsed.ast.pattern(match.arms[0].pattern).*) {
                    .constructor => |pattern| {
                        try std.testing.expectEqualStrings("геометрия.Фигура", pattern.module_name.?);
                        try std.testing.expectEqualStrings("Круг", pattern.name);
                    },
                    else => return error.TestUnexpectedResult,
                },
                else => return error.TestUnexpectedResult,
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}
