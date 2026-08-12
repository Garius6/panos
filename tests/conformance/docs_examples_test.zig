const std = @import("std");
const panos = @import("panos_core");

// Every ```panos code block in docs/src/**/*.md, compiled+run through the
// SAME `runner.runSource` path `panos run file.ps` uses — real gap found
// 2026-08-11: 9 real, pre-existing bugs (7 originally reported + 2 found
// while fixing those) surfaced ONLY via a one-off, manual sweep of these
// exact blocks, because nothing in `zig build test`/`conformance` ever
// exercised documented examples at all. This makes that sweep permanent
// and automatic instead of an occasional manual chore — every regression
// that breaks a documented example (or every accepted PR that makes a
// documented claim false) now fails CI immediately.
//
// Convention for doc authors (`docs/src/language/*.md` etc): a fenced
// ```panos block is treated as a RUNNABLE full program (must compile with
// zero diagnostics AND execute to `.success`) only if its source contains
// `старт(` (an entry-point function declaration) — matches how every
// existing runnable example in this doc set is already written
// (self-contained, own `функ старт()`/`экспорт функ старт()`). Blocks
// without an entry point (bare type declarations, syntax fragments) are
// PARSE-checked only (must at least lex+parse without a parser-phase
// diagnostic) — asserting full compile/run on a fragment would be a false
// positive, not a real check.
//
// A block whose FIRST LINE is exactly `// panos-doctest: skip` opts out
// entirely (e.g. a deliberately-invalid example demonstrating a rejected
// construct) — grep this file's own failure output before reaching for
// this: skipping should be rare and each use should carry a comment
// explaining why the example can't be verified this way.

const skip_marker = "// panos-doctest: skip";

// `panos run file.ps` (`zig/cli/main.zig`) resolves imports through a real
// `module_loader.Graph` + `module_compiler.compileGraph` — `runner.
// runSource` (a single in-memory buffer, no project context) is a
// DIFFERENT, simpler path meant for LSP/hover-style single-snippet
// analysis and doesn't support `импорт` at all. Doc examples using
// `импорт строки`/`импорт сеть`/etc are real, ordinary programs — so this
// harness mirrors the CLI's actual path (a one-"file" in-memory reader,
// same shape `module_compiler.zig`'s own tests already use), not
// `runSource`.
// Serves the synthetic doc-block content for its own entry path; falls
// through to REAL files on disk for everything else — a doc example
// importing a real stdlib module (`импорт математика`, resolved via
// `Graph.global_search_roots` pointing at the real `std/` directory)
// needs its transitive imports to actually read off disk, the same way
// `tests/conformance/modules_test.zig`'s own `FileReader` does.
const DocBlockReader = struct {
    entry_path: []const u8,
    entry_bytes: []const u8,
    io: std.Io,

    pub fn read(self: *const DocBlockReader, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        if (std.mem.eql(u8, path, self.entry_path)) return allocator.dupe(u8, self.entry_bytes);
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(1024 * 1024));
    }
};

fn trimCr(line: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, line, "\r")) line[0 .. line.len - 1] else line;
}

// Doc examples routinely trigger benign warnings (e.g. `неиспользованная
// переменная` on a binder that exists purely to illustrate destructuring)
// — only an actual `.err`-severity diagnostic means the example is
// genuinely broken.
fn firstError(diagnostics: *const panos.diagnostic.DiagnosticList) ?[]const u8 {
    for (diagnostics.items.items) |item| {
        if (item.severity == .err) return item.message;
    }
    return null;
}

fn fragmentParses(allocator: std.mem.Allocator, source_text: []const u8) !bool {
    var lexed = panos.lexer.tokenize(allocator, source_text, 0) catch return false;
    defer lexed.deinit();
    var parsed = try panos.parser.parse(allocator, lexed.tokens.items);
    defer parsed.deinit();
    return firstError(&parsed.diagnostics) == null;
}

fn appendFailure(allocator: std.mem.Allocator, list: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const message = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(message);
    try list.appendSlice(allocator, message);
}

fn extractPanosBlocks(allocator: std.mem.Allocator, markdown: []const u8) ![]const []const u8 {
    var blocks: std.ArrayList([]const u8) = .empty;
    errdefer blocks.deinit(allocator);
    var lines = std.mem.splitScalar(u8, markdown, '\n');
    while (lines.next()) |line| {
        if (!std.mem.eql(u8, trimCr(line), "```panos")) continue;
        var body: std.ArrayList(u8) = .empty;
        errdefer body.deinit(allocator);
        while (lines.next()) |body_line| {
            if (std.mem.eql(u8, trimCr(body_line), "```")) break;
            try body.appendSlice(allocator, body_line);
            try body.append(allocator, '\n');
        }
        try blocks.append(allocator, try body.toOwnedSlice(allocator));
    }
    return blocks.toOwnedSlice(allocator);
}

fn collectMarkdownFiles(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, out: *std.ArrayList([]const u8)) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        const child_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        switch (entry.kind) {
            .directory => {
                try collectMarkdownFiles(allocator, io, child_path, out);
                allocator.free(child_path);
            },
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".md")) {
                    try out.append(allocator, child_path);
                } else {
                    allocator.free(child_path);
                }
            },
            else => allocator.free(child_path),
        }
    }
}

test "every runnable panos code block in docs/src compiles and runs cleanly" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{});
    defer io.deinit();

    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |path| allocator.free(path);
        files.deinit(allocator);
    }
    try collectMarkdownFiles(allocator, io.io(), "docs/src", &files);
    // A near-zero count means the doc tree wasn't found (wrong cwd) or was
    // gutted — either way this test silently passing with 0 blocks
    // checked would be worse than a loud failure.
    try std.testing.expect(files.items.len > 5);

    var failures: std.ArrayList(u8) = .empty;
    defer failures.deinit(allocator);
    var checked: usize = 0;
    var runnable: usize = 0;
    var failure_count: usize = 0;

    std.mem.sort([]const u8, files.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    for (files.items) |file_path| {
        const content = try std.Io.Dir.cwd().readFileAlloc(io.io(), file_path, allocator, .limited(4 * 1024 * 1024));
        defer allocator.free(content);
        const blocks = try extractPanosBlocks(allocator, content);
        defer {
            for (blocks) |block| allocator.free(block);
            allocator.free(@constCast(blocks));
        }
        for (blocks, 0..) |block, index| {
            if (std.mem.startsWith(u8, block, skip_marker)) continue;
            checked += 1;
            const has_entry_point = std.mem.indexOf(u8, block, "старт(") != null;
            if (!has_entry_point) {
                // Fragment (no entry point) — parse-only check, tried
                // twice: as-is (covers top-level-shaped fragments — bare
                // type/interface/function declarations), and wrapped in a
                // synthetic function body (covers STATEMENT-shaped
                // fragments — `пер x = ...` and friends are only valid
                // syntax inside a function, not at top level, but are a
                // completely ordinary way to illustrate a single
                // expression/statement in prose). A parser diagnostic in
                // BOTH attempts means the snippet itself is malformed,
                // not just "incomplete on purpose".
                if (try fragmentParses(allocator, block)) continue;
                const wrapped = try std.fmt.allocPrint(allocator, "функ __doctest_fragment() -> Пусто\n{s}конец\n", .{block});
                defer allocator.free(wrapped);
                if (try fragmentParses(allocator, wrapped)) continue;
                failure_count += 1;
                try appendFailure(allocator, &failures, "{s} block #{d} (fragment, parse-only): does not parse standalone or wrapped in a function body\n", .{ file_path, index + 1 });
                continue;
            }
            runnable += 1;
            const reader = DocBlockReader{ .entry_path = "doctest/main.ps", .entry_bytes = block, .io = io.io() };
            var graph = panos.module_loader.Graph.init(allocator);
            defer graph.deinit();
            // Matches `zig/cli/main.zig`'s own resolution order for a
            // bare `импорт математика` — the real `std/` next to the repo
            // root, since `zig build test` always runs from there (see
            // `modules_test.zig`'s own comment for this same convention).
            graph.global_search_roots = &.{"std"};
            graph.load(&reader, "doctest/main") catch |err| {
                failure_count += 1;
                try appendFailure(allocator, &failures, "{s} block #{d}: load error {s}\n", .{ file_path, index + 1, @errorName(err) });
                continue;
            };
            if (firstError(&graph.diagnostics)) |message| {
                failure_count += 1;
                try appendFailure(allocator, &failures, "{s} block #{d}: {s}\n", .{ file_path, index + 1, message });
                continue;
            }
            var compiled = panos.module_compiler.compileGraph(allocator, &graph) catch |err| {
                failure_count += 1;
                try appendFailure(allocator, &failures, "{s} block #{d}: compile error {s}\n", .{ file_path, index + 1, @errorName(err) });
                continue;
            };
            defer compiled.deinit();
            if (firstError(&compiled.diagnostics)) |message| {
                failure_count += 1;
                try appendFailure(allocator, &failures, "{s} block #{d}: {s}\n", .{ file_path, index + 1, message });
                continue;
            }
            const start = compiled.start orelse {
                failure_count += 1;
                try appendFailure(allocator, &failures, "{s} block #{d}: compiled but no entry point found (`экспорт функ старт()`?)\n", .{ file_path, index + 1 });
                continue;
            };
            var machine = panos.vm.Vm.init(allocator, &compiled.program);
            defer machine.deinit();
            switch (machine.run(start, &.{}) catch |err| {
                failure_count += 1;
                try appendFailure(allocator, &failures, "{s} block #{d}: VM error {s}\n", .{ file_path, index + 1, @errorName(err) });
                continue;
            }) {
                .runtime_error => |message| {
                    failure_count += 1;
                    try appendFailure(allocator, &failures, "{s} block #{d}: runtime error: {s}\n", .{ file_path, index + 1, message });
                },
                .success => {},
            }
        }
    }

    if (failure_count != 0) {
        std.debug.print("\n{d} of {d} runnable doc examples ({d} total blocks checked) failed:\n{s}\n", .{ failure_count, runnable, checked, failures.items });
        return error.DocExampleFailed;
    }
}
