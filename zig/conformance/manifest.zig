const std = @import("std");

pub const outcome = @import("outcome.zig");

pub const manifest_version: u32 = 1;

pub const Manifest = struct {
    version: u32,
    cases: []const Case,
};

// `input`/`expected` complete the shape `specs/010-zig-migration/contracts/
// conformance.md` documents (`Case record`/`Outcome record`) — the original
// skeleton (`id`/`tier`/`profile` only) predates any populated case (T053
// is the first task to actually fill `manifest.json`). `input` is always a
// real `.ps` FILE PATH relative to the repo root (read via `Io.Dir.cwd()`
// at matrix-run time, not `@embedFile` — a manifest-driven case list is
// runtime data, `@embedFile` needs a comptime-known path).
pub const Case = struct {
    id: []const u8,
    tier: []const u8,
    profile: []const u8,
    input: []const u8,
    expected: outcome.Outcome,
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !std.json.Parsed(Manifest) {
    return std.json.parseFromSlice(Manifest, allocator, source, .{ .ignore_unknown_fields = false });
}

test "manifest parser accepts the current empty schema" {
    var parsed = try parse(std.testing.allocator, "{\"version\":1,\"cases\":[]}");
    defer parsed.deinit();

    try std.testing.expectEqual(manifest_version, parsed.value.version);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.cases.len);
}
