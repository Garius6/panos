// Ported from `wasm_runtime/runtime_js.odin` — the browser-side half of the
// AOT runtime (mirrors `runtime_wasi.zig`'s exported names/signatures,
// different host binding: a JS import module named "js_runtime" instead of
// WASI syscalls). Same Phase-1a scoping note as `runtime_wasi.zig`:
// `pw_print_string`/`pw_println_string` need the object-table runtime
// (arena/obj_offsets/obj_sizes) that doesn't exist on the Zig side yet,
// since Phase-1a's `wasm_emit.zig` never lowers a string constant in the
// first place — nothing to print. Only the two clock functions are ported.
extern "js_runtime" fn now_ms() f64;
extern "js_runtime" fn monotonic_ms() f64;

pub export fn panos_runtime_abi_version() u32 {
    return 0;
}

pub export fn pw_monotonic_ms() f64 {
    return monotonic_ms();
}

pub export fn pw_now_ms() f64 {
    return now_ms();
}
