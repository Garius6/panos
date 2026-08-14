const std = @import("std");
const panos = @import("panos_core");

// Verifies bound-generic method dispatch under WASM AOT — panos generics
// are deliberately never monomorphized (see `type_checker.zig`'s own doc
// comments): a generic function bounded by an interface
// (`функ ф[T: Интерфейс](x: T) ...`) casts its argument to that interface
// AT THE CALL SITE (`type_checker.zig`'s `registerGenericInterfaceCasts`/
// `inferGenericBoundInterfaceCall`), populating the SAME `checked.
// interface_calls`/`interface_casts` maps ordinary (non-generic) interface
// dispatch uses — so a bound-generic function body's method call on `T` is
// just ordinary interface-vtable dispatch, ALREADY built for WASM AOT this
// session (`wasm_interfaces.zig`'s call_indirect + vtables). This test is
// the first thing to actually exercise that path end-to-end for WASM AOT.

fn wasmtimeInvoke(allocator: std.mem.Allocator, io: std.Io, wasm_path: []const u8, func: []const u8) !std.process.RunResult {
    return std.process.run(allocator, io, .{
        .argv = &.{ "wasmtime", "run", "--invoke", func, wasm_path },
        .expand_arg0 = .expand,
    });
}

fn buildAndRunSource(allocator: std.mem.Allocator, io: std.Io, source: []const u8, wasm_path: []const u8) !std.process.RunResult {
    var lexed = try panos.lexer.tokenize(allocator, source, 0);
    defer lexed.deinit();
    var parsed = try panos.parser.parse(allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try panos.resolver.resolve(allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try panos.type_checker.check(allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    if (checked.diagnostics.items.items.len > 0) {
        for (checked.diagnostics.items.items) |d| std.debug.print("DIAG: {s}\n", .{d.message});
        return error.TypeCheckFailed;
    }

    var module = try panos.mir_lowering.lowerModule(allocator, &parsed.ast, &resolved, &checked);
    defer module.deinit(allocator);

    try panos.wasm_objects.expand(allocator, &module, &checked.types);
    try panos.wasm_strings.expand(allocator, &module, &checked.types);
    const iface_result = try panos.wasm_interfaces.expand(allocator, &module, &checked.types);
    defer allocator.free(iface_result.table);
    var frame_info = try panos.mir_cps.prepare(allocator, &module);
    defer frame_info.deinit();

    const wasm_bytes = try panos.wasm_emit.emitModule(allocator, &checked, &module, iface_result.table);
    defer allocator.free(wasm_bytes);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = wasm_path, .data = wasm_bytes });
    return wasmtimeInvoke(allocator, io, wasm_path, "старт");
}

test "bound-generic function dispatches through the interface vtable, one compiled body, two struct instantiations" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const source =
        \\тип Форма = интерфейс
        \\функ площадь() -> Число
        \\конец
        \\
        \\тип Круг = структура
        \\радиус: Число
        \\конец
        \\
        \\реализация Форма для Круг
        \\функ площадь(это: Круг) -> Число
        \\это.радиус * это.радиус * 3.0
        \\конец
        \\конец
        \\
        \\тип Квадрат = структура
        \\сторона: Число
        \\конец
        \\
        \\реализация Форма для Квадрат
        \\функ площадь(это: Квадрат) -> Число
        \\это.сторона * это.сторона
        \\конец
        \\конец
        \\
        \\функ вычислить[T: Форма](x: T) -> Число
        \\x.площадь()
        \\конец
        \\
        \\функ старт() -> Число
        \\вычислить(Круг(2.0)) + вычислить(Квадрат(3.0))
        \\конец
    ;
    const wasm_path = "zzz_aot_generic_bound.wasm";
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};
    const result = try buildAndRunSource(allocator, io.io(), source, wasm_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("21\n", result.stdout);
}
