const std = @import("std");

pub const outcome = @import("outcome.zig");

pub const manifest_version: u32 = 1;

pub const Manifest = struct {
    version: u32,
    cases: []const Case,
};

// `input` — всегда реальный ПУТЬ к .ps-файлу относительно корня репозитория
// (читается через `Io.Dir.cwd()` во время прогона матрицы, а не
// `@embedFile` — список случаев управляется манифестом, то есть это данные
// времени выполнения, а `@embedFile` требует путь, известный на этапе
// компиляции).
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
