const std = @import("std");
const panos = @import("panos_core");
const manifest = @import("manifest.zig");
const outcome = @import("outcome.zig");

// T053 — runs every case in `tests/conformance/manifest.json` against the
// ZIG side and asserts the outcome matches EXACTLY what was recorded there.
// The manifest's `expected` values were determined by actually running BOTH
// toolchains (Odin reference + this Zig port) side by side and comparing —
// see each case's `deviation` field (or absence of one) for what that
// comparison found. This is the automated, ongoing HALF of that gate: it
// catches a future Zig regression against the already-approved values. It
// does NOT re-run Odin itself — `zig/conformance/reference.zig` (the old
// odin-shell-out helper) was retired in T058, since it only ever existed to
// support the manual, one-time comparison used to populate this manifest,
// not an ongoing per-CI-run check.
//
// Split into per-TIER entry points (`runTier`/`runAot` below, each called
// from its OWN tiny `test` file/build artifact — see `build.zig`) instead of
// one `test` block looping over the whole manifest sequentially: Zig's build
// graph only parallelizes across separate `addTest`/`Run` steps, never
// across `test` declarations inside one binary, and the "runtime" tier in
// particular embeds the `tests/conformance/benchmarks/*.ps` fixtures
// (`фиб(30)` recursion, a 5-million-iteration loop, 20k string
// concatenations) — genuinely slow in a Debug-mode bytecode VM, and were
// dragging down `zig build test`'s everyday dev loop by being bundled into
// it at all (see `build.zig`'s `test_step`, which no longer depends on any
// tier of this).

pub fn computeOutcome(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !outcome.Outcome {
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

// Runs every manifest case whose `tier` matches `tier_name` (one of
// "semantic"/"runtime"/"native" — `aot` has its own, completely different
// execution path, see `runAot` below) through `runner.runSource` (the
// ordinary bytecode-VM pipeline) and asserts the outcome matches the
// manifest's recorded expectation exactly.
pub fn runTier(allocator: std.mem.Allocator, tier_name: []const u8) !void {
    var io = std.Io.Threaded.init(allocator, .{});
    defer io.deinit();

    const manifest_text = try std.Io.Dir.cwd().readFileAlloc(io.io(), "tests/conformance/manifest.json", allocator, .limited(1024 * 1024));
    defer allocator.free(manifest_text);

    var parsed = try manifest.parse(allocator, manifest_text);
    defer parsed.deinit();

    for (parsed.value.cases) |case| {
        if (!std.mem.eql(u8, case.tier, tier_name)) continue;

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

fn computeAotOutcome(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !outcome.Outcome {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(source);

    var lexed = try panos.lexer.tokenize(allocator, source, 0);
    defer lexed.deinit();
    var parsed = try panos.parser.parse(allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try panos.resolver.resolve(allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try panos.type_checker.check(allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    var module = try panos.mir_lowering.lowerModule(allocator, &parsed.ast, &resolved, &checked);
    defer module.deinit(allocator);
    const wasm_bytes = try panos.wasm_emit.emitModule(allocator, &checked, &module);
    defer allocator.free(wasm_bytes);

    const wasm_path = "zzz_matrix_aot_test.wasm";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = wasm_path, .data = wasm_bytes });
    defer std.Io.Dir.cwd().deleteFile(io, wasm_path) catch {};

    // `.environ = std.testing.environ` — `Io.Threaded`'s own default is
    // EMPTY, which makes `expand_arg0`'s `$PATH` search silently useless
    // (see `wasm_emit.zig`'s own tests and `specs/010-zig-migration`
    // T051's progress-report.md entry for the real bug this caused there).
    var wasmtime_io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer wasmtime_io.deinit();
    const result = try std.process.run(allocator, wasmtime_io.io(), .{
        .argv = &.{ "wasmtime", "run", "--invoke", "старт", wasm_path },
        .expand_arg0 = .expand,
    });
    defer allocator.free(result.stderr);

    const exit_code: i32 = switch (result.term) {
        .exited => |code| code,
        else => 1,
    };
    return .{
        .status = if (exit_code == 0) .success else .runtime_error,
        .exit_code = exit_code,
        .stdout = result.stdout,
        .result = std.mem.trim(u8, result.stdout, " \n\r\t"),
    };
}

pub fn runAot(allocator: std.mem.Allocator) !void {
    var io = std.Io.Threaded.init(allocator, .{});
    defer io.deinit();

    const manifest_text = try std.Io.Dir.cwd().readFileAlloc(io.io(), "tests/conformance/manifest.json", allocator, .limited(1024 * 1024));
    defer allocator.free(manifest_text);

    var parsed = try manifest.parse(allocator, manifest_text);
    defer parsed.deinit();

    for (parsed.value.cases) |case| {
        if (!std.mem.eql(u8, case.tier, "aot")) continue;

        const actual = computeAotOutcome(allocator, io.io(), case.input) catch |err| {
            if (err == error.FileNotFound) return error.SkipZigTest;
            return err;
        };
        defer allocator.free(actual.stdout);

        const mismatch = outcome.firstMismatch(case.expected, actual);
        if (mismatch != null) {
            std.debug.print("conformance case '{s}' mismatch: {t}\n", .{ case.id, mismatch.? });
            std.debug.print("  actual stdout: {s}\n", .{actual.stdout});
        }
        try std.testing.expectEqual(@as(?outcome.Mismatch, null), mismatch);
    }
}
