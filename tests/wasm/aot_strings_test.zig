const std = @import("std");
const panos = @import("panos_core");

fn wasmtimeInvoke(allocator: std.mem.Allocator, io: std.Io, wasm_path: []const u8, func: []const u8) !std.process.RunResult {
    return std.process.run(allocator, io, .{
        .argv = &.{ "wasmtime", "run", "--invoke", func, wasm_path },
        .expand_arg0 = .expand,
    });
}

fn buildAndRun(allocator: std.mem.Allocator, io: std.Io, source: []const u8, wasm_path: []const u8) !std.process.RunResult {
    var lexed = try panos.lexer.tokenize(allocator, source, 0);
    defer lexed.deinit();
    var parsed = try panos.parser.parse(allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try panos.resolver.resolve(allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try panos.type_checker.check(allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    var module = try panos.mir_lowering.lowerModule(allocator, &parsed.ast, &resolved, &checked);
    defer module.deinit(allocator);

    try panos.wasm_objects.expand(allocator, &module, &checked.types);
    try panos.wasm_strings.expand(allocator, &module, &checked.types);
    var frame_info = try panos.mir_cps.prepare(allocator, &module);
    defer frame_info.deinit();

    const wasm_bytes = try panos.wasm_emit.emitModule(allocator, &checked, &module);
    defer allocator.free(wasm_bytes);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = wasm_path, .data = wasm_bytes });
    return wasmtimeInvoke(allocator, io, wasm_path, "старт");
}

test "string literal equality, no host imports" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const source =
        \\функ старт() -> Булево
        \\    "привет" == "привет"
        \\конец
    ;
    const wasm_path = "zzz_aot_str1.wasm";
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};
    const result = try buildAndRun(allocator, io.io(), source, wasm_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("1\n", result.stdout);
}

test "string concat produces real byte-equal value (not handle equality)" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const source =
        \\функ старт() -> Булево
        \\    пер a = "при" + "вет"
        \\    a == "привет"
        \\конец
    ;
    const wasm_path = "zzz_aot_str2.wasm";
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};
    const result = try buildAndRun(allocator, io.io(), source, wasm_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("1\n", result.stdout);
}

test "string inequality after concat" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const source =
        \\функ старт() -> Булево
        \\    пер a = "при" + "вет"
        \\    a <> "пока"
        \\конец
    ;
    const wasm_path = "zzz_aot_str3.wasm";
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};
    const result = try buildAndRun(allocator, io.io(), source, wasm_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("1\n", result.stdout);
}

test "длина is rune count, длина_байт is byte count, начинается_с" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const source =
        \\функ старт() -> Булево
        \\    (длина("привет") == 6.0) и (строки.длина_байт("привет") == 12.0)
        \\        и строки.начинается_с("привет мир", "привет")
        \\        и (не строки.начинается_с("привет мир", "мир"))
        \\конец
    ;
    const wasm_path = "zzz_aot_str4.wasm";
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};
    const result = try buildAndRun(allocator, io.io(), source, wasm_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("1\n", result.stdout);
}

test "срез is rune-indexed, найти returns rune index or -1" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const source =
        \\функ старт() -> Булево
        \\    (строки.срез("привет мир", 1.0, 5.0) == "риве")
        \\        и (строки.найти("привет мир", "мир", 0.0) == 7.0)
        \\        и (строки.найти("привет мир", "xyz", 0.0) == -1.0)
        \\конец
    ;
    const wasm_path = "zzz_aot_str5.wasm";
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};
    const result = try buildAndRun(allocator, io.io(), source, wasm_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("1\n", result.stdout);
}

test "заменить replaces all occurrences, byte-level, empty target is a no-op" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const source =
        \\функ старт() -> Булево
        \\    (строки.заменить("аабб", "аа", "x") == "xбб")
        \\        и (строки.заменить("aabbaabb", "aa", "x") == "xbbxbb")
        \\        и (строки.заменить("hello", "z", "y") == "hello")
        \\        и (строки.заменить("привет", "", "X") == "привет")
        \\конец
    ;
    const wasm_path = "zzz_aot_str6.wasm";
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};
    const result = try buildAndRun(allocator, io.io(), source, wasm_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("1\n", result.stdout);
}
