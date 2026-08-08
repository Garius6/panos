const std = @import("std");
const panos = @import("panos_core");
const manifest = @import("manifest.zig");
const outcome = @import("outcome.zig");

// T053 — runs every case in `tests/conformance/manifest.json` against the
// ZIG side and asserts the outcome matches EXACTLY what was recorded there.
// The manifest's `expected` values were determined by actually running BOTH
// toolchains (Odin reference + this Zig port) side by side and comparing —
// see each case's `deviation` field (or absence of one) for what that
// comparison found. This test is the automated, ongoing HALF of that gate:
// it catches a future Zig regression against the already-approved values.
// It does NOT re-run Odin itself — `zig/conformance/reference.zig` (the
// old odin-shell-out helper) was retired in T058, since it only ever
// existed to support the manual, one-time comparison used to populate
// this manifest, not an ongoing per-CI-run check.

fn computeOutcome(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !outcome.Outcome {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(source);

    var result = try panos.runner.runSource(allocator, path, source);
    defer result.deinit();

    if (result.hasErrors()) {
        var diagnostics: std.ArrayList(outcome.NormalizedDiagnostic) = .empty;
        for (result.diagnostics.items.items) |value| {
            try diagnostics.append(allocator, .{
                .phase = value.phase,
                .severity = value.severity,
                .path = try allocator.dupe(u8, path),
                .start_byte = value.span.start,
                .end_byte = value.span.end,
                .message = try allocator.dupe(u8, value.message),
            });
        }
        return .{
            .status = .diagnostic,
            .exit_code = 1,
            .stdout = "",
            .diagnostics = try diagnostics.toOwnedSlice(allocator),
        };
    }

    return switch (result.execution orelse return error.NoExecution) {
        .success => |value| .{
            .status = .success,
            .exit_code = 0,
            .stdout = try allocator.dupe(u8, value),
            .result = try allocator.dupe(u8, value),
        },
        .runtime_error => |message| .{
            .status = .runtime_error,
            .exit_code = 1,
            .stdout = "",
            .result = try allocator.dupe(u8, message),
        },
    };
}

fn freeOutcome(allocator: std.mem.Allocator, value: outcome.Outcome) void {
    if (value.stdout.len != 0) allocator.free(value.stdout);
    if (value.result) |result| allocator.free(result);
    for (value.diagnostics) |diagnostic_value| {
        allocator.free(diagnostic_value.path);
        allocator.free(diagnostic_value.message);
    }
    if (value.diagnostics.len != 0) allocator.free(value.diagnostics);
}

test "every manifest case's recorded expected outcome matches Zig's actual outcome" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{});
    defer io.deinit();

    const manifest_text = try std.Io.Dir.cwd().readFileAlloc(io.io(), "tests/conformance/manifest.json", allocator, .limited(1024 * 1024));
    defer allocator.free(manifest_text);

    var parsed = try manifest.parse(allocator, manifest_text);
    defer parsed.deinit();

    for (parsed.value.cases) |case| {
        // Only tiers `computeOutcome` (single-file `runSource`) can produce
        // an outcome for — `native`-profile module-loading cases with real
        // `импорт` (a genuinely separate code path, see `modules_test.zig`)
        // aren't in this manifest yet, same for lexer/parser/browser/aot/
        // lsp tiers (each needs its own harness, not built here).
        if (!std.mem.eql(u8, case.tier, "semantic") and !std.mem.eql(u8, case.tier, "runtime")) continue;

        const actual = try computeOutcome(allocator, io.io(), case.input);
        defer freeOutcome(allocator, actual);

        const mismatch = outcome.firstMismatch(case.expected, actual);
        if (mismatch != null) {
            std.debug.print("conformance case '{s}' mismatch: {t}\n", .{ case.id, mismatch.? });
            if (actual.diagnostics.len != 0) {
                std.debug.print("  actual diagnostic: {s}\n", .{actual.diagnostics[0].message});
            }
            if (actual.result) |result_value| std.debug.print("  actual result: {s}\n", .{result_value});
        }
        try std.testing.expectEqual(@as(?outcome.Mismatch, null), mismatch);
    }
}
