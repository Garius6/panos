const std = @import("std");
const matrix_runner = @import("matrix_runner.zig");

// Includes the `tests/conformance/benchmarks/*.ps` fixtures (`фиб(30)`, a
// 5-million-iteration loop, 20k string concatenations) — genuinely slow to
// run under a Debug-mode bytecode VM. Deliberately its OWN build step (`zig
// build conformance`), never `zig build test` — see `matrix_runner.zig`'s
// module doc comment.
test "every runtime-tier manifest case's recorded expected outcome matches Zig's actual outcome" {
    try matrix_runner.runTier(std.testing.allocator, "runtime");
}
