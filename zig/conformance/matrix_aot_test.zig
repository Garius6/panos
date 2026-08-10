const std = @import("std");
const matrix_runner = @import("matrix_runner.zig");

// Compiles to WASM and shells out to `wasmtime` per case — a completely
// different, much heavier execution path than the bytecode-VM tiers above.
// Its own build step (`zig build aot`), never bundled into `zig build
// test`/`conformance`.
test "every aot-tier manifest case's recorded expected outcome matches a real panos build --target=wasm + wasmtime run" {
    try matrix_runner.runAot(std.testing.allocator);
}
