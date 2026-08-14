const std = @import("std");
const panos = @import("panos_core");

// Verifies WASM AOT closure support, Stage A (see
// `project_panos_wasm_aot_closures` design notes) — `mir_lowering.zig`'s
// `.lambda` lowering + `lowerSymbolValueRef`'s `.build_closure` fallback,
// `wasm_interfaces.zig`'s `expandBuildClosure`/`expandCallValue`. Real
// bug found only by running these under wasmtime, not by reading the
// code: `expandCallValue`'s first draft checked a callee ValueId against
// `direct_call_callees` (populated by scanning EVERY `.call_value`'s OWN
// callee field) — tautologically true for any call_value's own callee,
// so every closure call silently took the static-direct-call fast path
// and passed its raw (unboxed) box pointer straight to `call_indirect`
// as a table index ("undefined element: out of bounds table access").
// Fixed with a separate `static_callees` map, populated only when a
// `.function_ref` actually hits the SAME exclusion `.function_ref`'s own
// rewrite already uses.

fn wasmtimeInvoke(allocator: std.mem.Allocator, io: std.Io, wasm_path: []const u8, func: []const u8) !std.process.RunResult {
    return std.process.run(allocator, io, .{
        .argv = &.{ "wasmtime", "run", "--invoke", func, wasm_path },
        .expand_arg0 = .expand,
    });
}

// Full pipeline, mirroring `cli/main.zig`'s `runBuild` — same shape as
// `aot_gc_arena_test.zig`'s own helper (closures need `wasm_interfaces.
// expand` in its real position, same as GC needs `wasm_gc_arena.expand`).
fn buildAndRun(allocator: std.mem.Allocator, io: std.Io, source: []const u8, wasm_path: []const u8) !std.process.RunResult {
    var lexed = try panos.lexer.tokenize(allocator, source, 0);
    defer lexed.deinit();
    var parsed = try panos.parser.parse(allocator, lexed.tokens.items);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    var resolved = try panos.resolver.resolve(allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try panos.type_checker.check(allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);

    var module = try panos.mir_lowering.lowerModule(allocator, &parsed.ast, &resolved, &checked);
    defer module.deinit(allocator);

    try panos.wasm_objects.expand(allocator, &module, &checked.types);
    try panos.wasm_strings.expand(allocator, &module, &checked.types);
    const iface_result = try panos.wasm_interfaces.expand(allocator, &module, &checked.types);
    defer allocator.free(iface_result.table);
    var frame_info = try panos.mir_cps.prepare(allocator, &module);
    defer frame_info.deinit();
    try panos.wasm_actors.expand(allocator, &module, &checked.types, &frame_info);

    const wasm_bytes = try panos.wasm_emit.emitModule(allocator, &checked, &module, iface_result.table);
    defer allocator.free(wasm_bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = wasm_path, .data = wasm_bytes });
    return wasmtimeInvoke(allocator, io, wasm_path, "старт");
}

test "a lambda capturing a local number by value returns the correct sum" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const source =
        \\функ старт() -> Число
        \\пер x: Число = 42.0
        \\пер добавить_к_x = функ(y: Число) -> Число x + y конец
        \\добавить_к_x(8.0)
        \\конец
    ;
    const wasm_path = "zzz_aot_closures_capture.wasm";
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};
    const result = try buildAndRun(allocator, io.io(), source, wasm_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("50\n", result.stdout);
}

test "a plain named function used as a first-class value is called correctly through a wrapper" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const source =
        \\функ удвоить(x: Число) -> Число
        \\x * 2.0
        \\конец
        \\
        \\функ старт() -> Число
        \\пер f = удвоить
        \\f(21.0)
        \\конец
    ;
    const wasm_path = "zzz_aot_closures_plainfn.wasm";
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};
    const result = try buildAndRun(allocator, io.io(), source, wasm_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("42\n", result.stdout);
}

test "a closure returned from a function and passed to a higher-order function works" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const source =
        \\функ применить(ф: функ(Число) -> Число, x: Число) -> Число
        \\ф(x)
        \\конец
        \\
        \\функ сделать_умножитель(множитель: Число) -> функ(Число) -> Число
        \\функ(x: Число) -> Число x * множитель конец
        \\конец
        \\
        \\функ старт() -> Число
        \\пер утроить = сделать_умножитель(3.0)
        \\применить(утроить, 7.0)
        \\конец
    ;
    const wasm_path = "zzz_aot_closures_higher_order.wasm";
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};
    const result = try buildAndRun(allocator, io.io(), source, wasm_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("21\n", result.stdout);
}
