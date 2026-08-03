const std = @import("std");
const manifest = @import("panos_conformance");

test "baseline manifest validates through the public parser" {
    var parsed = try manifest.parse(std.testing.allocator, @embedFile("manifest.json"));
    defer parsed.deinit();

    try std.testing.expectEqual(manifest.manifest_version, parsed.value.version);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.cases.len);
}
