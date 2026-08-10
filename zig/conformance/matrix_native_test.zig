const std = @import("std");
const matrix_runner = @import("matrix_runner.zig");

test "every native-tier manifest case's recorded expected outcome matches Zig's actual outcome" {
    try matrix_runner.runTier(std.testing.allocator, "native");
}
