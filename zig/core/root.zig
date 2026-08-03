const std = @import("std");

pub const ast = @import("ast.zig");
pub const diagnostic = @import("diagnostic.zig");
pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const source = @import("source.zig");
pub const symbols = @import("symbols.zig");
pub const target = @import("target.zig");
pub const token = @import("token.zig");
pub const types = @import("types.zig");

pub const migration_stage = "phase-0";

pub fn version() []const u8 {
    return "0.0.0-dev";
}

test "migration core reports its initial stage" {
    try std.testing.expectEqualStrings("phase-0", migration_stage);
}
