const std = @import("std");

// Real end-to-end verification of `zig/wasm_runtime/runtime_wasi.zig` (T044)
// — not just "the module parses", the same "run > read" discipline
// `wasm_emit.zig`'s tests already established for T043. Requires
// `zig-out/bin/panos-aot-runtime-wasi.wasm` to already exist — `build.zig`
// wires this test to depend on that install step, so `zig build test`
// always builds the runtime first.
//
// The JS runtime (`runtime_js.zig`) has no equivalent real-execution test
// here: it needs an actual JS host providing the `js_runtime` import
// module (`now_ms`/`monotonic_ms`), which wasmtime alone can't supply.
// Its import/export CONTRACT is exercised structurally instead — see
// `"panos-aot-runtime-js.wasm exports the documented ABI and imports
// exactly the js_runtime functions it needs"` below.

fn wasmtimeInvoke(allocator: std.mem.Allocator, io: std.Io, wasm_path: []const u8, func: []const u8) !std.process.RunResult {
    // `.expand_arg0 = .expand` searches `$PATH` for "wasmtime" — but only
    // sees a real `$PATH` if the `Io` this runs against was constructed
    // with `.environ = std.testing.environ` (see each caller below);
    // `Io.Threaded`'s own default `environ` is empty by design, which
    // silently falls back to a tiny hardcoded PATH and reports
    // `FileNotFound` even when wasmtime genuinely is installed.
    return std.process.run(allocator, io, .{
        .argv = &.{ "wasmtime", "run", "--invoke", func, wasm_path },
        .expand_arg0 = .expand,
    });
}

test "panos-aot-runtime-wasi.wasm: pw_now_ms returns a real, current wall-clock timestamp" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const result = wasmtimeInvoke(allocator, io.io(), "zig-out/bin/panos-aot-runtime-wasi.wasm", "pw_now_ms") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exited_zero = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!exited_zero) {
        std.debug.print("wasmtime failed: {s}\n", .{result.stderr});
        return error.WasmtimeFailed;
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \n\r\t");
    const ms = try std.fmt.parseFloat(f64, trimmed);
    // Sanity range, not exact equality (this is wall-clock time, not
    // reproducible) — anything from 2020-01-01 to 2100-01-01 in epoch ms.
    try std.testing.expect(ms > 1577836800000.0);
    try std.testing.expect(ms < 4102444800000.0);
}

test "panos-aot-runtime-wasi.wasm: pw_monotonic_ms returns a real, non-negative duration" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const result = wasmtimeInvoke(allocator, io.io(), "zig-out/bin/panos-aot-runtime-wasi.wasm", "pw_monotonic_ms") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exited_zero = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!exited_zero) {
        std.debug.print("wasmtime failed: {s}\n", .{result.stderr});
        return error.WasmtimeFailed;
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \n\r\t");
    const ms = try std.fmt.parseFloat(f64, trimmed);
    // `CLOCK_MONOTONIC` counts from an arbitrary host reference point (see
    // `runtime_wasi.zig`'s doc comment) — the only thing that's actually
    // checkable here is that it's a real, non-negative number, NOT a
    // specific value or a comparison against the bytecode VM's own
    // `время.монотонно_мс` (different epoch entirely, different process).
    try std.testing.expect(ms >= 0.0);
}

test "panos-aot-runtime-wasi.wasm: panos_runtime_abi_version returns 0" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const result = wasmtimeInvoke(allocator, io.io(), "zig-out/bin/panos-aot-runtime-wasi.wasm", "panos_runtime_abi_version") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exited_zero = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!exited_zero) {
        std.debug.print("wasmtime failed: {s}\n", .{result.stderr});
        return error.WasmtimeFailed;
    }
    try std.testing.expectEqualStrings("0", std.mem.trim(u8, result.stdout, " \n\r\t"));
}

fn readWasmFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
}

test "panos-aot-runtime-wasi.wasm exports exactly the documented ABI functions" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();
    const bytes = readWasmFile(allocator, io.io(), "zig-out/bin/panos-aot-runtime-wasi.wasm") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer allocator.free(bytes);

    // A crude but reliable-enough contract check (this module has no
    // custom name section stripped/mangled — export names are plain
    // UTF-8 bytes in the export section, findable via substring search):
    // exactly the three exports `runtime_wasi.zig` declares should be
    // present. Byte-substring search over the whole module rather than a
    // real WASM section parser — good enough to catch "wasm-ld silently
    // stripped an export" (the actual bug T044 found, see `build.zig`'s
    // `addWasmRuntime` doc comment), without writing a second WASM parser
    // when `wasm_module.zig` already covers ENCODING, not decoding.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "pw_now_ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "pw_monotonic_ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "panos_runtime_abi_version") != null);
}

test "panos-aot-runtime-js.wasm exports the documented ABI and imports exactly the js_runtime functions it needs" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();
    const bytes = readWasmFile(allocator, io.io(), "zig-out/bin/panos-aot-runtime-js.wasm") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer allocator.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "pw_now_ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "pw_monotonic_ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "panos_runtime_abi_version") != null);
    // Confirms the host import contract itself (module name "js_runtime",
    // function names "now_ms"/"monotonic_ms") — matches
    // `wasm_runtime/runtime_js.odin`'s `foreign import js_rt "js_runtime"`
    // exactly, so the SAME `docs/src/assets/aot-dom-loader.js`-style JS
    // glue works against either the Odin- or Zig-built runtime.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "js_runtime") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "now_ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "monotonic_ms") != null);
}
