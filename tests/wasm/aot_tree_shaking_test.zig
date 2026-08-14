const std = @import("std");
const panos = @import("panos_core");

// Verifies `mir_lowering.zig`'s `computeReachableSymbols`/tree-shaking:
// `cli/main.zig`'s AOT build path used to compile the ENTIRE prelude +
// entry module unconditionally — every "AOT (wasm) не поддерживает X"
// build failure hit across the whole WASM-AOT initiative this session was
// in prelude code no test program was even using, just reachable-in-
// principle. This test proves the actual selling point: a declaration
// that would fail to LOWER if reached (a real, explicit
// `mir_lowering.zig` limitation — casting one value to two interfaces at
// once, "Phase 2") compiles successfully as long as it's never actually
// CALLED from `старт` — because it's never lowered at all now, not
// because the limitation itself was fixed.

const MemoryReader = struct {
    files: []const struct { path: []const u8, bytes: []const u8 },

    pub fn read(self: *const MemoryReader, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        for (self.files) |file| {
            if (std.mem.eql(u8, file.path, path)) return allocator.dupe(u8, file.bytes);
        }
        return error.FileNotFound;
    }
};

fn wasmtimeInvoke(allocator: std.mem.Allocator, io: std.Io, wasm_path: []const u8, func: []const u8) !std.process.RunResult {
    return std.process.run(allocator, io, .{
        .argv = &.{ "wasmtime", "run", "--invoke", func, wasm_path },
        .expand_arg0 = .expand,
    });
}

fn buildGraphToWasmBytes(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const reader = MemoryReader{ .files = &.{.{ .path = "программа.ps", .bytes = source }} };
    var graph = panos.module_loader.Graph.init(allocator);
    defer graph.deinit();
    try graph.load(&reader, "программа");
    _ = try graph.appendPreludeModule(panos.prelude.SOURCE);
    try std.testing.expectEqual(@as(usize, 0), graph.diagnostics.items.items.len);

    var compiled = try panos.module_compiler.compileGraphForTarget(allocator, &graph, .aot_js_wasm);
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var module = try panos.mir_lowering.lowerGraph(allocator, &graph, &compiled);
    defer module.deinit(allocator);

    try panos.wasm_objects.expand(allocator, &module, &compiled.modules[0].checked.?.types);
    try panos.wasm_strings.expand(allocator, &module, &compiled.modules[0].checked.?.types);
    const iface_result = try panos.wasm_interfaces.expand(allocator, &module, &compiled.modules[0].checked.?.types);
    defer allocator.free(iface_result.table);
    var frame_info = try panos.mir_cps.prepare(allocator, &module);
    defer frame_info.deinit();

    return panos.wasm_emit.emitModule(allocator, &compiled.modules[0].checked.?, &module, iface_result.table);
}

fn buildAndRunGraph(allocator: std.mem.Allocator, io: std.Io, source: []const u8, wasm_path: []const u8) !std.process.RunResult {
    const wasm_bytes = try buildGraphToWasmBytes(allocator, source);
    defer allocator.free(wasm_bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = wasm_path, .data = wasm_bytes });
    return wasmtimeInvoke(allocator, io, wasm_path, "старт");
}

test "an unreachable declaration that would fail to lower is skipped, not compiled" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    // `никогда_не_вызывается` casts one value to TWO interfaces at once —
    // `mir_lowering.zig`'s `applyInterfaceCast` explicitly reports this
    // "Phase 2" case as unsupported (`cast.entries.len > 1`) whenever it's
    // actually LOWERED. Never called from `старт` — tree-shaking must
    // skip lowering it entirely, so the build succeeds anyway.
    const source =
        \\тип А = интерфейс
        \\функ а() -> Число
        \\конец
        \\
        \\тип Б = интерфейс
        \\функ б() -> Число
        \\конец
        \\
        \\тип Обе = структура
        \\значение: Число
        \\конец
        \\
        \\реализация А для Обе
        \\функ а(это: Обе) -> Число
        \\это.значение
        \\конец
        \\конец
        \\
        \\реализация Б для Обе
        \\функ б(это: Обе) -> Число
        \\это.значение
        \\конец
        \\конец
        \\
        \\функ принять_как_а_и_б(x: А, y: Б) -> Число
        \\x.а() + y.б()
        \\конец
        \\
        \\функ никогда_не_вызывается() -> Число
        \\пер значение = Обе(1.0)
        \\принять_как_а_и_б(значение, значение)
        \\конец
        \\
        \\функ старт() -> Число
        \\42.0
        \\конец
    ;
    const wasm_path = "zzz_aot_tree_shaking.wasm";
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};
    const result = try buildAndRunGraph(allocator, io.io(), source, wasm_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("42\n", result.stdout);
}

test "a function reachable only via DOM.на_клик's string-literal handler name is kept" {
    const allocator = std.testing.allocator;

    // `обработчик` is never called by name anywhere in ordinary MIR
    // (only referenced as a STRING LITERAL argument to `DOM.на_клик`'s
    // 3-argument form, resolved by `instance.exports[name]` at runtime
    // in the browser loader) — the DOM-handler-root heuristic must find
    // it via that string literal and keep it reachable, or this build
    // would succeed but the compiled `обработчик` export would be
    // silently missing (a real regression the browser loader can't
    // detect until a user actually clicks the button). Can't invoke
    // this one through `wasmtime run` directly (no host providing
    // `env::dom_on_click_context` outside a real browser/JS loader) —
    // just verify the build succeeds and the export survives.
    const source =
        \\импорт DOM
        \\
        \\экспорт функ обработчик(контекст: Строка) -> Пусто
        \\конец
        \\
        \\функ старт() -> Число
        \\    DOM.на_клик("#кнопка", "обработчик", "контекст")
        \\    1.0
        \\конец
    ;
    const wasm_bytes = try buildGraphToWasmBytes(allocator, source);
    defer allocator.free(wasm_bytes);
    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "обработчик") != null);
}

test "a generic function returning bare T, called with both a Число and a struct argument, is flagged as a conflicting instantiation" {
    const allocator = std.testing.allocator;

    // `первый[T](x: T) -> T` — the ONE residual risk the "no
    // monomorphization" design (see `5cced87`'s own commit message and
    // `project_panos_wasm_no_monomorphization_needed` memory) explicitly
    // left open: a bare, unwrapped `T` as a function's OWN return type,
    // compiled exactly once, called here with BOTH a Число (f64) and a
    // Коробка (i32 nominal handle) — the SAME compiled body can't
    // represent both.
    //
    // Checks `computeReachableSymbols`'s own `.conflicts` list directly
    // rather than running the full `buildGraphToWasmBytes`/`lowerGraph`
    // pipeline and expecting `error.AotUnsupported` — `lowerGraph`'s
    // `unsupported(...)` reports via `std.debug.print`, a raw syscall
    // write that bypasses Zig's `Io` abstraction; triggering it from
    // CODE UNDER TEST while `zig build`'s own test runner is using the
    // `--listen=-` stdin/stdout protocol corrupts that protocol (a real
    // Zig 0.16 std-library interaction, not a bug in this diagnostic —
    // confirmed by running the exact same test binary directly with
    // plain `zig test`, outside the protocol, where it passes cleanly).
    // No other `unsupported(...)` call site in this file was ever
    // exercised by an in-process test before this one — every other AOT
    // test invokes `wasmtime`/`panos` as a separate subprocess instead.
    const source =
        \\функ первый[T](x: T) -> T
        \\x
        \\конец
        \\
        \\тип Коробка = структура
        \\значение: Число
        \\конец
        \\
        \\функ старт() -> Число
        \\пер a = первый(1.0)
        \\пер b = первый(Коробка(2.0))
        \\a
        \\конец
    ;
    const reader = MemoryReader{ .files = &.{.{ .path = "программа.ps", .bytes = source }} };
    var graph = panos.module_loader.Graph.init(allocator);
    defer graph.deinit();
    try graph.load(&reader, "программа");
    _ = try graph.appendPreludeModule(panos.prelude.SOURCE);
    try std.testing.expectEqual(@as(usize, 0), graph.diagnostics.items.items.len);

    var compiled = try panos.module_compiler.compileGraphForTarget(allocator, &graph, .aot_js_wasm);
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var reachability = try panos.mir_lowering.computeReachableSymbols(allocator, &graph, &compiled);
    defer reachability.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), reachability.conflicts.items.len);
}
