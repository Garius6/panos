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

test "a function reachable only from a DOM.на_клик closure is kept" {
    const allocator = std.testing.allocator;

    // The click handler is a real closure, so the ordinary reachability
    // walk must traverse its body and keep the directly-called helper.
    const source =
        \\импорт DOM
        \\
        \\функ обработчик(_: DOM.СобытиеКлика) -> Пусто
        \\конец
        \\
        \\функ старт() -> Число
        \\    DOM.на_клик("#кнопка", функ(событие: DOM.СобытиеКлика) -> Пусто
        \\        обработчик(событие)
        \\    конец)
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
    // Exercise the real lowering failure rather than only inspecting the
    // reachability helper. The reason must be returned as data: a direct
    // stderr write from code under test corrupts Zig's `--listen=-` test
    // protocol before the assertion can observe the failure.
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

    var diagnostic: panos.mir_lowering.AotDiagnostic = .{};
    try std.testing.expectError(
        error.AotUnsupported,
        panos.mir_lowering.lowerGraphWithDiagnostic(allocator, &graph, &compiled, &diagnostic),
    );
    try std.testing.expect(diagnostic.reason != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.reason.?, "несовместимыми инстанциациями T") != null);
    try std.testing.expectEqualStrings("первый", diagnostic.subject.?);
}
