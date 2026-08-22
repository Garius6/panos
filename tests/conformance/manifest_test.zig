const std = @import("std");
const manifest = @import("panos_conformance");

test "populated manifest validates through the public parser" {
    var parsed = try manifest.parse(std.testing.allocator, @embedFile("manifest.json"));
    defer parsed.deinit();

    try std.testing.expectEqual(manifest.manifest_version, parsed.value.version);
    // T053 populated this with real, verified cases — see
    // `zig/conformance/matrix_runner.zig` (and its four per-tier
    // `matrix_{semantic,runtime,native,aot}_test.zig` callers) for the
    // tests that actually RUN them against Zig and check the recorded
    // outcome.
    try std.testing.expectEqual(@as(usize, 54), parsed.value.cases.len);
    try std.testing.expectEqualStrings("semantic-undefined-name", parsed.value.cases[0].id);
}
