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
    // First-class function values (any `.call_value`, including a plain
    // recursive/self call) now ALWAYS depend on `wasm_interfaces.expand`
    // having rewritten `.function_ref` into a real WASM table index
    // first — see `wasm_interfaces.zig`'s own doc comment.
    const iface_result = try panos.wasm_interfaces.expand(allocator, &module, &checked.types);
    defer allocator.free(iface_result.table);
    var frame_info = try panos.mir_cps.prepare(allocator, &module);
    defer frame_info.deinit();

    const wasm_bytes = try panos.wasm_emit.emitModule(allocator, &checked, &module, iface_result.table);
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

test "длина is rune count, начинается_с" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    // `строки.в_байты` (byte-level work moved here off `Строка`, see
    // specs/014-string-byte-index-safety/) isn't lowered in WASM AOT at
    // all yet (`mir_lowering.zig`'s `lowerStringBuiltinCall` — pre-existing
    // gap, unrelated to that migration) — this test keeps only the
    // rune-count/`начинается_с` assertions AOT already supports; byte-count
    // coverage lives in the native-only `type_checker.zig`/`vm.zig` tests.
    const source =
        \\функ старт() -> Булево
        \\    (длина("привет") == 6.0)
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

test "разбить splits into Массив(Строка), empty separator returns a single element" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const source =
        \\функ старт() -> Булево
        \\    пер parts = строки.разбить("a,b,c", ",")
        \\    пер unsplit = строки.разбить("привет", "")
        \\    (parts.длина() == 3)
        \\        и (parts.получить(0.0, "?") == "a")
        \\        и (parts.получить(1.0, "?") == "b")
        \\        и (parts.получить(2.0, "?") == "c")
        \\        и (unsplit.длина() == 1)
        \\        и (unsplit.получить(0.0, "?") == "привет")
        \\конец
    ;
    const wasm_path = "zzz_aot_str7.wasm";
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};
    const result = try buildAndRun(allocator, io.io(), source, wasm_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("1\n", result.stdout);
}

test "из_числа formats integers, decimals, negatives — practical digit extraction, not bit-exact Zig {d}" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const source =
        \\функ старт() -> Булево
        \\    (строки.из_числа(0.0) == "0")
        \\        и (строки.из_числа(42.0) == "42")
        \\        и (строки.из_числа(0.0 - 42.0) == "-42")
        \\        и (строки.из_числа(100.0) == "100")
        \\        и (строки.из_числа(0.5) == "0.5")
        \\        и (строки.из_числа(123.25) == "123.25")
        \\        и (строки.из_числа(0.0 - 2.5) == "-2.5")
        \\        и (строки.из_числа(0.1) == "0.1")
        \\        и (строки.из_числа(1.25 + 1.25) == "2.5")
        \\конец
    ;
    const wasm_path = "zzz_aot_str8.wasm";
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};
    const result = try buildAndRun(allocator, io.io(), source, wasm_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("1\n", result.stdout);
}

test "в_число parses integers/decimals/negatives via Успех, rejects garbage via Неудача" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const source =
        \\функ разобрать(s: Строка, ожидаемое: Число) -> Булево
        \\    выбор строки.в_число(s)
        \\    Успех(x) -> x == ожидаемое
        \\    Неудача(_) -> ложь
        \\    конец
        \\конец
        \\функ отклонить(s: Строка) -> Булево
        \\    выбор строки.в_число(s)
        \\    Успех(_) -> ложь
        \\    Неудача(_) -> истина
        \\    конец
        \\конец
        \\функ старт() -> Булево
        \\    разобрать("42", 42.0)
        \\        и разобрать("-5", 0.0 - 5.0)
        \\        и разобрать("3.14", 3.14)
        \\        и отклонить("")
        \\        и отклонить("abc")
        \\        и отклонить("12x")
        \\конец
    ;
    const wasm_path = "zzz_aot_str9.wasm";
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};
    const result = try buildAndRun(allocator, io.io(), source, wasm_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("1\n", result.stdout);
}
