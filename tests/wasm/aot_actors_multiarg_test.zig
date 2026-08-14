const std = @import("std");
const panos = @import("panos_core");

fn wasmtimeInvoke(allocator: std.mem.Allocator, io: std.Io, wasm_path: []const u8, func: []const u8) !std.process.RunResult {
    return std.process.run(allocator, io, .{
        .argv = &.{ "wasmtime", "run", "--invoke", func, wasm_path },
        .expand_arg0 = .expand,
    });
}

test "spawned actor with 2 constructor args: exercises expandSpawn's reverse-order arg-copy fix" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const source =
        \\тип Ответ = перечисление
        \\    Значение(Число)
        \\конец
        \\
        \\тип Сообщение = перечисление
        \\    Спроси(Процесс(Ответ))
        \\конец
        \\
        \\функ вычти(а: Число, б: Число) -> Пусто
        \\    выбор получить()
        \\        Сообщение.Спроси(отвечающему) тогда
        \\            отправить(отвечающему, Ответ.Значение(а - б))
        \\        конец
        \\    конец
        \\конец
        \\
        \\функ старт() -> Число
        \\    пер proc: Процесс(Сообщение) = запусти вычти(100.0, 37.0)
        \\    отправить(proc, Сообщение.Спроси(себя()))
        \\    выбор получить()
        \\        Ответ.Значение(x) -> x
        \\    конец
        \\конец
    ;

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
    // See `aot_actors_test.zig`'s own comment: `.call_value` now always
    // needs `wasm_interfaces.expand` to have run first.
    const iface_result = try panos.wasm_interfaces.expand(allocator, &module, &checked.types);
    defer allocator.free(iface_result.table);
    var frame_info = try panos.mir_cps.prepare(allocator, &module);
    defer frame_info.deinit();
    try panos.wasm_actors.expand(allocator, &module, &checked.types, &frame_info);

    const wasm_bytes = try panos.wasm_emit.emitModule(allocator, &checked, &module, iface_result.table);
    defer allocator.free(wasm_bytes);

    const wasm_path = "zzz_actors_multiarg_test.wasm";
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = wasm_path, .data = wasm_bytes });
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};

    const result = try wasmtimeInvoke(allocator, io.io(), wasm_path, "старт");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("63\n", result.stdout);
}
