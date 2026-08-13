const std = @import("std");
const ast = @import("ast.zig");
const module_loader = @import("module_loader.zig");
const resolver = @import("resolver.zig");

// `panos build --compile` (Bun-style standalone executable) support.
//
// Design: embed SOURCE (the resolved `module_loader.Graph` closure — every
// `.pns` file actually reached, including `std/` modules used), not
// compiled `bytecode.Program` — that struct is fully pointer-based
// (`ArrayList`/arena/slices, see its own doc comments), no serialization
// format exists anywhere in this codebase, and a raw `внешний` function
// pointer (`bytecode.Constant.foreign_function.fn_ptr`) genuinely CANNOT
// survive serialization across process invocations (addresses aren't
// stable between runs) — so bytecode-embedding wouldn't even solve FFI,
// the one thing explicitly required. A standalone executable instead
// carries its own source + `внешний`-library bytes and recompiles at
// every startup, reusing the ordinary `module_loader.Graph`/
// `module_compiler.compileGraph`/`vm.Vm` pipeline unchanged — a few
// milliseconds of extra startup cost for a typical program, in exchange
// for zero new serialization surface.
//
// Bundle entries are keyed by path RELATIVE TO THE ENTRY MODULE's own
// directory (`std.fs.path.relative`, `..`-segments included where a file
// — e.g. a `$PANOS_STDLIB` module — lives outside that directory). At
// runtime the whole bundle is read straight from memory via `BundleReader`
// (the SAME duck-typed `reader` interface `module_loader.Graph.load`
// already accepts — no real temp directory needed for `.pns` content, see
// `BundleReader`'s own doc comment) — a real temp directory is only
// created if the bundle contains at least one `внешний`-library entry,
// since `dlopen`/`LoadLibraryW` fundamentally need a real file on disk.

pub const bundle_magic: [8]u8 = "PANOSBDL".*;
pub const trailer_magic: [8]u8 = "PANOSFAT".*;
pub const format_version: u32 = 1;

pub const Entry = struct {
    // Relative to the bundle root (the entry module's own directory at
    // build time) — may start with "../" for a file outside it.
    path: []const u8,
    content: []const u8,
    // `внешний`-library bytes (must land on REAL disk at run time,
    // `dlopen` needs a path) vs `.pns` source (served straight from
    // memory by `BundleReader`, never touches disk).
    is_library: bool,
};

pub const Bundle = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    entry_path: []const u8,
    entries: []const Entry,

    pub fn deinit(self: *Bundle) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn find(self: *const Bundle, relative_path: []const u8) ?[]const u8 {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.path, relative_path)) return entry.content;
        }
        return null;
    }

    pub fn hasLibraries(self: *const Bundle) bool {
        for (self.entries) |entry| if (entry.is_library) return true;
        return false;
    }
};

// Walks every module `graph.load` already resolved (the entry file's own
// dependency closure — local `импорт`s AND `std/` modules alike, exactly
// what a real compile would need) plus every path-style `внешний
// "./lib.so"` declaration reachable from them (bare-name `внешний
// "libname"`, resolved via the OS loader's own search path, is NOT
// embedded — v1 limitation, documented in the plan — it stays a runtime
// system dependency exactly as it already is for an ordinary `panos
// <file>` invocation).
pub fn collect(allocator: std.mem.Allocator, io: std.Io, graph: *const module_loader.Graph, search_roots: []const []const u8) !Bundle {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    // Module 0 is always the entry module (`module_loader.zig`'s own
    // invariant — `Graph.load` appends it first, before any import).
    const entry_module_path = graph.modules.items[0].file.path;
    const root_dir = std.fs.path.dirname(entry_module_path) orelse ".";
    const entry_relative = try bundleKey(arena_allocator, root_dir, search_roots, entry_module_path);

    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(allocator);

    for (graph.modules.items) |module| {
        const relative = try bundleKey(arena_allocator, root_dir, search_roots, module.file.path);
        try entries.append(allocator, .{
            .path = relative,
            .content = try arena_allocator.dupe(u8, module.file.bytes),
            .is_library = false,
        });

        const tree = &module.tree;
        const declarations = (tree.program orelse continue).declarations;
        for (declarations) |decl_id| {
            const foreign = switch (tree.decl(decl_id).*) {
                .foreign => |value| value,
                else => continue,
            };
            // Bare logical name (no '/') — resolved via the OS loader's
            // own search path, not a project-relative file; nothing to
            // embed (see module doc comment).
            if (std.mem.indexOfScalar(u8, foreign.library, '/') == null) continue;

            const library_path = try resolver.resolveForeignLibraryPath(allocator, module.file.path, foreign.library);
            defer allocator.free(library_path);
            const library_bytes = std.Io.Dir.cwd().readFileAlloc(io, library_path, allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
                // Let the ORDINARY compile path (which resolves `внешний`
                // for real, `resolver.zig:resolveForeignFunction`) report
                // this properly, with the right span/diagnostic — this
                // collection pass runs BEFORE typecheck, so it can't
                // itself distinguish "genuinely missing" from "will be
                // reported shortly" and shouldn't try to duplicate that
                // diagnostic.
                else => continue,
            };
            defer allocator.free(library_bytes);
            const library_relative = try bundleKey(arena_allocator, root_dir, search_roots, library_path);
            // A library referenced from more than one module (or the
            // same module twice) — dedupe by relative path so the
            // bundle doesn't carry duplicate multi-megabyte copies.
            var already_present = false;
            for (entries.items) |entry| {
                if (entry.is_library and std.mem.eql(u8, entry.path, library_relative)) {
                    already_present = true;
                    break;
                }
            }
            if (already_present) continue;
            try entries.append(allocator, .{
                .path = library_relative,
                .content = try arena_allocator.dupe(u8, library_bytes),
                .is_library = true,
            });
        }
    }

    return .{
        .allocator = allocator,
        .arena = arena,
        .entry_path = entry_relative,
        .entries = try arena_allocator.dupe(Entry, entries.items),
    };
}

// A module resolved via a build-time `global_search_root` (`$PANOS_STDLIB`
// or exe-relative `std/` — bare-name imports like `импорт математика`)
// canNOT reuse `relativize`-against-the-entry's-own-directory the way a
// plain `импорт "./x"` local file does: at RUN time the standalone binary
// has NO real `$PANOS_STDLIB` (the whole point is to need none), so
// `module_loader.zig`'s bare-name candidate search — which tries each
// `global_search_roots` entry in turn — has nothing to match against
// unless `runFatBinary` (`zig/cli/main.zig`) supplies a SYNTHETIC root
// pointing at `<temp_root>/std`. So any module whose real (build-time)
// path falls under ONE of `search_roots` gets a key namespaced under
// `"std/"` (the part of its path AFTER whichever root matched) instead
// of a path relative to the entry module — `runFatBinary` sets its own
// (single, synthetic) `global_search_roots = &.{temp_root ++ "/std"}` to
// match this exactly: `module_loader`'s own candidate-building naturally
// produces `<temp_root>/std/<name>.pns`, `BundleReader` strips the
// `<temp_root>/` prefix, and the remainder (`"std/<name>.pns"`) is
// EXACTLY this key. Real bug found by actually running a `--compile`d
// binary with a `импорт математика` in it (not by reasoning alone): the
// naive "always relative to entry dir" scheme produced a bundle key like
// `"../Users/x/dev/panos/std/математика.pns"` that no runtime candidate
// path could ever reconstruct without the real `$PANOS_STDLIB` being
// present on the machine running the binary — defeating the entire
// point of "standalone".
fn bundleKey(allocator: std.mem.Allocator, root_dir: []const u8, search_roots: []const []const u8, path: []const u8) ![]const u8 {
    for (search_roots) |root| {
        if (root.len == 0) continue;
        if (std.mem.startsWith(u8, path, root) and path.len > root.len and path[root.len] == '/') {
            return std.fmt.allocPrint(allocator, "std/{s}", .{path[root.len + 1 ..]});
        }
    }
    return relativize(allocator, root_dir, path);
}

fn pathComponents(allocator: std.mem.Allocator, path: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |part| try list.append(allocator, part);
    return list.toOwnedSlice(allocator);
}

// Deliberately NOT `std.fs.path.relative` — that function needs the REAL
// process CWD to make a relative `from`/`to` absolute first (no cheap way
// to get it under this Zig version's `Io`-based `process`/`Dir` API), and
// passing an empty placeholder produced WRONG results for this exact
// shape (`from="."`, `to="main.pns"` — verified by running the actual
// `--compile` output: it silently produced `"../main.pns"` instead of
// `"main.pns"`, and the produced standalone binary failed to find its own
// entry module at startup). `from`/`to` here always come from the SAME
// `module_loader.Graph` (both either bare-relative-to-the-real-CWD or
// both absolute, consistently) — a pure component-wise string diff needs
// no CWD at all and is fully deterministic given that invariant.
fn relativize(allocator: std.mem.Allocator, from_dir: []const u8, to: []const u8) ![]const u8 {
    if (from_dir.len == 0 or std.mem.eql(u8, from_dir, ".")) return allocator.dupe(u8, to);

    const from_parts = try pathComponents(allocator, from_dir);
    defer allocator.free(from_parts);
    const to_parts = try pathComponents(allocator, to);
    defer allocator.free(to_parts);

    var common: usize = 0;
    while (common < from_parts.len and common < to_parts.len and std.mem.eql(u8, from_parts[common], to_parts[common])) common += 1;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var i: usize = common;
    while (i < from_parts.len) : (i += 1) try out.appendSlice(allocator, "../");
    i = common;
    while (i < to_parts.len) : (i += 1) {
        try out.appendSlice(allocator, to_parts[i]);
        if (i + 1 < to_parts.len) try out.append(allocator, '/');
    }
    return out.toOwnedSlice(allocator);
}

fn appendU32(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try out.appendSlice(allocator, &bytes);
}

fn appendU64(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    try out.appendSlice(allocator, &bytes);
}

fn appendBlob(allocator: std.mem.Allocator, out: *std.ArrayList(u8), blob: []const u8) !void {
    try appendU64(allocator, out, blob.len);
    try out.appendSlice(allocator, blob);
}

fn appendString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try appendU32(allocator, out, @intCast(text.len));
    try out.appendSlice(allocator, text);
}

// Serializes ONLY the bundle payload (no trailer/length/magic — see
// `appendTrailer` for the executable-level framing that wraps this).
pub fn serialize(allocator: std.mem.Allocator, bundle: *const Bundle) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &bundle_magic);
    try appendU32(allocator, &out, format_version);
    try appendString(allocator, &out, bundle.entry_path);
    try appendU32(allocator, &out, @intCast(bundle.entries.len));
    for (bundle.entries) |entry| {
        try appendString(allocator, &out, entry.path);
        try out.append(allocator, if (entry.is_library) 1 else 0);
        try appendBlob(allocator, &out, entry.content);
    }
    return out.toOwnedSlice(allocator);
}

const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Cursor, n: usize) ![]const u8 {
        if (self.pos + n > self.bytes.len) return error.InvalidBundle;
        const slice = self.bytes[self.pos..][0..n];
        self.pos += n;
        return slice;
    }

    fn readU32(self: *Cursor) !u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .little);
    }

    fn readU64(self: *Cursor) !u64 {
        return std.mem.readInt(u64, (try self.take(8))[0..8], .little);
    }

    fn readByte(self: *Cursor) !u8 {
        return (try self.take(1))[0];
    }

    fn readString(self: *Cursor, allocator: std.mem.Allocator) ![]const u8 {
        const len = try self.readU32();
        return allocator.dupe(u8, try self.take(len));
    }

    fn readBlob(self: *Cursor, allocator: std.mem.Allocator) ![]const u8 {
        const len = try self.readU64();
        if (len > std.math.maxInt(usize)) return error.InvalidBundle;
        return allocator.dupe(u8, try self.take(@intCast(len)));
    }
};

pub fn deserialize(allocator: std.mem.Allocator, bytes: []const u8) !Bundle {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    var cursor = Cursor{ .bytes = bytes };
    const magic = try cursor.take(8);
    if (!std.mem.eql(u8, magic, &bundle_magic)) return error.InvalidBundle;
    const version = try cursor.readU32();
    if (version != format_version) return error.UnsupportedBundleVersion;
    const entry_path = try cursor.readString(arena_allocator);
    const count = try cursor.readU32();
    const entries = try arena_allocator.alloc(Entry, count);
    for (entries) |*entry| {
        entry.path = try cursor.readString(arena_allocator);
        entry.is_library = (try cursor.readByte()) != 0;
        entry.content = try cursor.readBlob(arena_allocator);
    }

    return .{
        .allocator = allocator,
        .arena = arena,
        .entry_path = entry_path,
        .entries = entries,
    };
}

// Wraps a serialized bundle in the trailer framing appended to a copy of
// the `panos` executable: `[base binary][bundle][u64 bundle length]
// ["PANOSFAT"]`. `readTrailer` below is the exact inverse.
pub fn appendTrailer(allocator: std.mem.Allocator, base_binary: []const u8, bundle_bytes: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, base_binary.len + bundle_bytes.len + 16);
    errdefer allocator.free(out);
    @memcpy(out[0..base_binary.len], base_binary);
    @memcpy(out[base_binary.len..][0..bundle_bytes.len], bundle_bytes);
    var length_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &length_bytes, bundle_bytes.len, .little);
    @memcpy(out[base_binary.len + bundle_bytes.len ..][0..8], &length_bytes);
    @memcpy(out[out.len - 8 ..], &trailer_magic);
    return out;
}

// Reads ONLY the trailing 16 bytes first (magic + length) — the common,
// overwhelmingly frequent case (an ORDINARY `panos <file>` invocation,
// running the real `panos` binary with no trailer at all) must stay
// cheap: one small positional read, not loading megabytes of the
// binary's own code into memory on every single invocation. Only when
// the magic actually matches does this read the (much smaller) bundle
// payload itself.
pub fn readTrailer(io: std.Io, allocator: std.mem.Allocator, exe_path: []const u8) !?[]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, exe_path, .{});
    defer file.close(io);
    const size = try file.length(io);
    if (size < 16) return null;
    var tail: [16]u8 = undefined;
    _ = try file.readPositionalAll(io, &tail, size - 16);
    if (!std.mem.eql(u8, tail[8..16], &trailer_magic)) return null;
    const bundle_len = std.mem.readInt(u64, tail[0..8], .little);
    if (bundle_len == 0 or bundle_len > size - 16) return null;
    const bundle_bytes = try allocator.alloc(u8, bundle_len);
    errdefer allocator.free(bundle_bytes);
    _ = try file.readPositionalAll(io, bundle_bytes, size - 16 - bundle_len);
    return bundle_bytes;
}

// `module_loader.Graph.load`'s duck-typed `reader` interface for a
// bundle-backed graph — `.pns` content is served straight out of the
// in-memory `Bundle`, never touching disk. `temp_root` is the SAME
// prefix used to build `entry_path` for `graph.load` (see `zig/cli/
// main.zig`'s fat-binary startup path) — every import path
// `module_loader.zig` derives is a join starting from `entry_path`, so
// they all stay `temp_root`-prefixed automatically; this reader just
// strips that prefix back off to find the matching bundle entry.
// `внешний`-library entries are NOT served through this reader at all —
// they're written to real files under `temp_root` BEFORE `graph.load`
// runs, so `resolver.zig`'s unmodified `dlopen`-based resolution finds
// them directly on disk (see module doc comment).
pub const BundleReader = struct {
    bundle: *const Bundle,
    temp_root: []const u8,

    pub fn read(self: *const BundleReader, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const prefix_len = self.temp_root.len + 1; // + '/'
        if (path.len <= prefix_len or !std.mem.startsWith(u8, path, self.temp_root) or path[self.temp_root.len] != '/') {
            return error.FileNotFound;
        }
        const relative = path[prefix_len..];
        const content = self.bundle.find(relative) orelse return error.FileNotFound;
        return allocator.dupe(u8, content);
    }
};

test "bundle round-trips through serialize/deserialize" {
    const allocator = std.testing.allocator;
    // `serialize` only ever reads `.entry_path`/`.entries` — `.arena` is
    // unused for a Bundle built directly from literals (nothing ever
    // allocates through it), so there is nothing to free here.
    const bundle = Bundle{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .entry_path = "main.pns",
        .entries = &.{
            .{ .path = "main.pns", .content = "экспорт функ старт() -> Число\n42.0\nконец", .is_library = false },
            .{ .path = "libs/foo.so", .content = "\x7fELFbinary", .is_library = true },
        },
    };
    const bytes = try serialize(allocator, &bundle);
    defer allocator.free(bytes);

    var decoded = try deserialize(allocator, bytes);
    defer decoded.deinit();
    try std.testing.expectEqualStrings("main.pns", decoded.entry_path);
    try std.testing.expectEqual(@as(usize, 2), decoded.entries.len);
    try std.testing.expectEqualStrings("экспорт функ старт() -> Число\n42.0\nконец", decoded.find("main.pns").?);
    try std.testing.expectEqualStrings("\x7fELFbinary", decoded.find("libs/foo.so").?);
    try std.testing.expect(decoded.hasLibraries());
}

test "appendTrailer/readTrailer round-trip" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{});
    defer io.deinit();

    const base = "fake-binary-bytes";
    const bundle_bytes = "fake-bundle-payload";
    const combined = try appendTrailer(allocator, base, bundle_bytes);
    defer allocator.free(combined);

    const path = "zzz_bundle_trailer_probe.tmp";
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = path, .data = combined });
    defer std.Io.Dir.cwd().deleteFile(io.io(), path) catch {};

    const read_back = try readTrailer(io.io(), allocator, path);
    defer if (read_back) |bytes| allocator.free(bytes);
    try std.testing.expect(read_back != null);
    try std.testing.expectEqualStrings(bundle_bytes, read_back.?);
}

test "readTrailer returns null for a file with no trailer" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{});
    defer io.deinit();

    const path = "zzz_bundle_no_trailer_probe.tmp";
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = path, .data = "just an ordinary binary, no trailer here" });
    defer std.Io.Dir.cwd().deleteFile(io.io(), path) catch {};

    const read_back = try readTrailer(io.io(), allocator, path);
    try std.testing.expectEqual(@as(?[]u8, null), read_back);
}
