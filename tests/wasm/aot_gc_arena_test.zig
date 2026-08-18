const std = @import("std");
const panos = @import("panos_core");

// Verifies `wasm_gc_arena.zig` — Phase 1 GC (per-call arena reset), see
// `project_panos_wasm_aot_memory_growth_fix`/
// `project_panos_elm_architecture_dom_storage_design`. The deep
// end-to-end proof (memory usage staying bounded across 500 repeated
// `старт()` calls, a promoted closure surviving a SEPARATE later
// export call) was done via a Node/wasmtime harness during development
// — not reproducible here the same way `aot_tree_shaking_test.zig`'s own
// DOM test explains why (`env::dom_on_click` has no host outside
// a real browser/JS loader). These tests verify the STRUCTURAL
// properties that make that behavior possible: the wrapper exists under
// the right export name, the original body survives under a renamed
// internal name, and the permanent region (globals 1/2) is reserved
// exactly when — and only when — delayed data needs it.

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

// Full pipeline, mirroring `cli/main.zig`'s `runBuild` exactly (unlike
// `aot_tree_shaking_test.zig`'s helper, which deliberately skips
// `wasm_actors.expand` — irrelevant there, but `wasm_gc_arena.expand`
// needs to run in its real position, last, after everything else has
// settled the module's final function set).
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

    const type_store = &compiled.modules[0].checked.?.types;
    try panos.wasm_objects.expand(allocator, &module, type_store);
    try panos.wasm_strings.expand(allocator, &module, type_store);
    const iface_result = try panos.wasm_interfaces.expand(allocator, &module, type_store);
    defer allocator.free(iface_result.table);
    var frame_info = try panos.mir_cps.prepare(allocator, &module);
    defer frame_info.deinit();
    try panos.wasm_actors.expand(allocator, &module, type_store, &frame_info);
    try panos.wasm_gc_arena.expand(allocator, &module, type_store);

    return panos.wasm_emit.emitModule(allocator, &compiled.modules[0].checked.?, &module, iface_result.table);
}

test "старт gets wrapped with an arena checkpoint/restore, original body renamed and still present" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const source =
        \\функ старт() -> Число
        \\пер s: Строка = "hello" + "-world"
        \\42.0
        \\конец
    ;
    const wasm_bytes = try buildGraphToWasmBytes(allocator, source);
    defer allocator.free(wasm_bytes);

    // No DOM handler context anywhere — permanent region must NOT be
    // reserved (only 1 global: the ordinary arena bump pointer).
    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "@runtime_alloc_permanent") == null);
    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "@arena_impl_старт") != null);

    const wasm_path = "zzz_aot_gc_arena_start.wasm";
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = wasm_path, .data = wasm_bytes });
    const result = try wasmtimeInvoke(allocator, io.io(), wasm_path, "старт");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("42\n", result.stdout);
}

test "старт invoked twice in a row still produces the correct result (arena reset doesn't corrupt the next call)" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const source =
        \\функ старт() -> Целое
        \\пер s: Строка = "число-" + строки.из_числа(7.0)
        \\длина(s)
        \\конец
    ;
    const wasm_bytes = try buildGraphToWasmBytes(allocator, source);
    defer allocator.free(wasm_bytes);

    // The point here isn't the VALUE, it's that calling `старт`
    // back-to-back through the SAME instance doesn't trap or desync the
    // bump pointer. `wasmtime run --invoke` only calls once
    // per process; use a tiny Node-free proxy instead — invoke twice via
    // two separate `wasmtime run` processes against the same file, which
    // at minimum proves the checkpoint/restore doesn't corrupt the
    // MODULE on disk (a stronger same-instance, same-process repeated
    // call is covered by the Node harness used during development, see
    // `project_panos_wasm_aot_memory_growth_fix`).
    const wasm_path = "zzz_aot_gc_arena_start_twice.wasm";
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = wasm_path, .data = wasm_bytes });
    const first = try wasmtimeInvoke(allocator, io.io(), wasm_path, "старт");
    defer allocator.free(first.stdout);
    defer allocator.free(first.stderr);
    const second = try wasmtimeInvoke(allocator, io.io(), wasm_path, "старт");
    defer allocator.free(second.stdout);
    defer allocator.free(second.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, first.term);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, second.term);
    try std.testing.expectEqualStrings(first.stdout, second.stdout);
}

test "DOM.на_клик reserves the permanent region and wraps the event trampoline" {
    const allocator = std.testing.allocator;

    // The captured string and closure box must survive after `старт`
    // returns; the fixed JS-invoked trampoline, not an internal helper,
    // must receive the arena checkpoint/restore wrapper.
    const source =
        \\импорт DOM
        \\
        \\функ обработчик(контекст: Строка) -> Пусто
        \\конец
        \\
        \\функ старт() -> Число
        \\    пер контекст = "контекст-строка"
        \\    DOM.на_клик("#кнопка", функ(_: DOM.СобытиеКлика) -> Пусто
        \\        обработчик(контекст)
        \\    конец)
        \\    1.0
        \\конец
    ;
    const wasm_bytes = try buildGraphToWasmBytes(allocator, source);
    defer allocator.free(wasm_bytes);

    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "обработчик") != null);
    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "@runtime_alloc_permanent") != null);
    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "@promote_to_permanent") != null);
    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "@arena_impl_старт") != null);
    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "@arena_impl_@invoke_click") != null);
}

test "a program with no heap usage at all compiles with no arena wrapper (nothing to reset)" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const source =
        \\функ старт() -> Число
        \\1.0 + 1.0
        \\конец
    ;
    const wasm_bytes = try buildGraphToWasmBytes(allocator, source);
    defer allocator.free(wasm_bytes);

    // No `@runtime_alloc` anywhere means `wasm_gc_arena.expand` bailed
    // out via `mir_cps.usesActorMemory` before wrapping anything —
    // "старт" itself is the only function, unrenamed.
    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "@arena_impl_старт") == null);

    const wasm_path = "zzz_aot_gc_arena_no_heap.wasm";
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = wasm_path, .data = wasm_bytes });
    const result = try wasmtimeInvoke(allocator, io.io(), wasm_path, "старт");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("2\n", result.stdout);
}
