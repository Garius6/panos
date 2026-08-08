const std = @import("std");
const wasi = std.os.wasi;

// Ported from `wasm_runtime/runtime_wasi.odin` — the WASI-side half of the
// AOT runtime an emitted `.wasm` module links against (mirrored by
// `runtime_js.zig` for the browser side, same exported names/signatures,
// different host binding underneath). Scoped to exactly what
// `wasm_emit.zig`'s Phase-1a subset can ever need: `время.монотонно_мс`/
// `время.сейчас_мс` — neither one touches the AOT object-table runtime
// (`pw_string_ptr`/`arena`/`obj_offsets`/`obj_sizes` in the Odin original),
// because Phase-1a never lowers a string at all (`mir_emit.zig`'s
// `const_value` case explicitly `unsupported()`s a string constant — see
// `wasm_emit.zig`). `pw_print_string`/`pw_println_string` are NOT ported
// here yet for that reason: porting them now would mean inventing the
// object-table layout ahead of the Phase 2 work that actually needs it,
// with no way to verify it against a real caller until then.
//
// `panos_runtime_abi_version` intentionally still just returns 0 — the ABI
// hasn't grown a real caller yet (`panos build --target=wasm`'s emitted
// modules never import from this runtime; T048's output is a
// self-contained module with no imports, matching Phase-1a's scope: no
// print, no clock reads reachable from any lowered program yet either).

pub export fn panos_runtime_abi_version() u32 {
    return 0;
}

// WASI's `CLOCK_MONOTONIC` is nanoseconds since an arbitrary, host-defined
// reference point (commonly system boot) — NOT the same epoch as the
// bytecode VM's own `время.монотонно_мс` (`vm.monotonic_epoch`, this
// process's own start time). Comparing the two numerically across the
// bytecode VM and a compiled `.wasm` module was never meaningful (same
// caveat the Odin original documents) — a caller only ever checks
// monotonic DELTAS within one process, never absolute equality against
// another.
pub export fn pw_monotonic_ms() f64 {
    var ts: wasi.timestamp_t = 0;
    _ = wasi.clock_time_get(.MONOTONIC, 0, &ts);
    return @as(f64, @floatFromInt(ts)) / 1e6;
}

pub export fn pw_now_ms() f64 {
    var ts: wasi.timestamp_t = 0;
    _ = wasi.clock_time_get(.REALTIME, 0, &ts);
    return @as(f64, @floatFromInt(ts)) / 1e6;
}
