const std = @import("std");
const matrix_runner = @import("matrix_runner.zig");

test "every graph-tier manifest case's recorded expected outcome matches Zig's actual outcome" {
    try matrix_runner.runTierGraph(std.testing.allocator, "graph");
}
