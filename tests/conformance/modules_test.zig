const std = @import("std");
const panos = @import("panos_core");

// Real multi-file `.ps` fixtures under `tests/conformance/modules/`, loaded
// off DISK via `module_loader.Graph.load` + a real `Io`-backed reader — the
// exact same reader shape `panos run`/`panos build` use in
// `zig/cli/main.zig` (`FileReader`, `std.Io.Dir.cwd().readFileAlloc`), NOT
// the `MemoryReader` every existing `module_compiler.zig`/`module_loader.
// zig` test uses. Those inline tests already cover this same SEMANTIC
// ground (import edges, generics, ADTs, interfaces) — this file exists to
// cover the other half: does loading a REAL multi-file project off the
// real filesystem, exactly the way the CLI does it, actually work? Before
// this file, nothing exercised that path at all (confirmed by grepping the
// whole `zig/` tree for a non-`MemoryReader` `Graph.load` call outside
// `zig/cli/main.zig` itself).
//
// Paths are relative to the repo root, matching where `zig build test`
// always runs from (see `tests/wasm/aot_runtime_test.zig` for the same
// convention with `zig-out/bin/...`).

const FileReader = struct {
    io: std.Io,

    pub fn read(self: *const FileReader, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(1024 * 1024));
    }
};

fn loadAndCompile(allocator: std.mem.Allocator, io: std.Io, entry_path: []const u8) !struct {
    graph: panos.module_loader.Graph,
    compiled: panos.module_compiler.GraphCompileResult,
} {
    var graph = panos.module_loader.Graph.init(allocator);
    errdefer graph.deinit();
    const reader = FileReader{ .io = io };
    try graph.load(&reader, entry_path);

    var compiled = try panos.module_compiler.compileGraph(allocator, &graph);
    errdefer compiled.deinit();
    return .{ .graph = graph, .compiled = compiled };
}

fn runStartExpectingNumber(allocator: std.mem.Allocator, entry_path: []const u8, expected: f64) !void {
    var io = std.Io.Threaded.init(allocator, .{});
    defer io.deinit();

    var loaded = try loadAndCompile(allocator, io.io(), entry_path);
    defer loaded.graph.deinit();
    defer loaded.compiled.deinit();

    try std.testing.expectEqual(@as(usize, 0), loaded.graph.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), loaded.compiled.diagnostics.items.items.len);

    const start = loaded.compiled.start orelse return error.TestUnexpectedResult;
    var machine = panos.vm.Vm.init(allocator, &loaded.compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(expected, number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "modules/basic_import: cross-file exported function and constant, loaded from real files" {
    try runStartExpectingNumber(std.testing.allocator, "tests/conformance/modules/basic_import/main.pns", 42);
}

test "modules/three_file_chain: transitive import (main -> mid -> leaf), loaded from real files" {
    try runStartExpectingNumber(std.testing.allocator, "tests/conformance/modules/three_file_chain/main.pns", 31);
}

test "modules/generic_struct: imported generic struct instantiation + method dispatch, loaded from real files" {
    try runStartExpectingNumber(std.testing.allocator, "tests/conformance/modules/generic_struct/main.pns", 42);
}

test "modules/adt_match: imported generic enum construction + exhaustive match, loaded from real files" {
    try runStartExpectingNumber(std.testing.allocator, "tests/conformance/modules/adt_match/main.pns", 42);
}

test "modules/interface_dispatch: cross-module interface impl dispatched as an ordinary call, loaded from real files" {
    try runStartExpectingNumber(std.testing.allocator, "tests/conformance/modules/interface_dispatch/main.pns", 38);
}

// No `импорт` at all in this fixture — `Опция` must resolve via the
// resolver's own hardcoded prelude fallback (`installPreludeEnum` in
// `resolver.zig`, gated on `skip_prelude_hardcode`), NOT a real merged
// `@prelude` module — this test deliberately does NOT call
// `appendPreludeModule` (unlike `runner.zig`'s single-file analysis path),
// matching EXACTLY what `zig/cli/main.zig`'s real `panos run`/`panos build`
// does today: `graph.load` + `compileGraph`, nothing else. Confirmed by
// reading `main.zig` — it never calls `appendPreludeModule` either, yet a
// real built binary correctly runs a program using `Опция` (verified
// manually before writing this test). If that ever silently regressed
// (e.g. someone assumes the module-graph prelude is the only mechanism and
// removes the resolver's hardcoded fallback), this is the test that would
// catch it — `runSource`-based tests in `zig/cli/main.zig` couldn't, since
// they always go through `analyzeSourceForTarget`'s explicit
// `appendPreludeModule` call instead.
test "modules/prelude_merge: Опция resolves without any импорт, loaded from a real file" {
    try runStartExpectingNumber(std.testing.allocator, "tests/conformance/modules/prelude_merge/main.pns", 42);
}

test "modules/missing_export: importing an unexported (or nonexistent) name reports the documented diagnostic" {
    var io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io.deinit();

    var graph = panos.module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const reader = FileReader{ .io = io.io() };
    try graph.load(&reader, "tests/conformance/modules/missing_export/main.pns");

    var compiled = try panos.module_compiler.compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();

    try std.testing.expectEqual(@as(usize, 1), compiled.diagnostics.items.items.len);
    try std.testing.expectEqualStrings(
        "Resolve Error: у модуля 'библ' нет экспорта 'нет'",
        compiled.diagnostics.items.items[0].message,
    );
}

test "modules/cycle: a mutually-importing pair reports a cycle diagnostic, loaded from real files" {
    var io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io.deinit();

    var graph = panos.module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const reader = FileReader{ .io = io.io() };
    try graph.load(&reader, "tests/conformance/modules/cycle/a.pns");

    try std.testing.expectEqual(@as(usize, 1), graph.diagnostics.items.items.len);
    try std.testing.expectEqualStrings(
        "Module Loader Error: обнаружен циклический импорт 'tests/conformance/modules/cycle/a.pns'",
        graph.diagnostics.items.items[0].message,
    );
}

test "modules/adt_non_exhaustive: a match missing a variant reports an exhaustiveness diagnostic, loaded from real files" {
    var io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io.deinit();

    var graph = panos.module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const reader = FileReader{ .io = io.io() };
    try graph.load(&reader, "tests/conformance/modules/adt_non_exhaustive/main.pns");
    try std.testing.expectEqual(@as(usize, 0), graph.diagnostics.items.items.len);

    var compiled = try panos.module_compiler.compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expect(compiled.hasErrors());
}
