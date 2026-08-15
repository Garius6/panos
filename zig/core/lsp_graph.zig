const std = @import("std");
const ast = @import("ast.zig");
const diagnostic = @import("diagnostic.zig");
const lsp = @import("lsp.zig");
const module_compiler = @import("module_compiler.zig");
const module_loader = @import("module_loader.zig");
const prelude = @import("prelude.zig");
const resolver = @import("resolver.zig");
const source = @import("source.zig");
const type_checker = @import("type_checker.zig");

// Real multi-file `module_loader.Graph`-backed analysis for the LSP —
// unlike `runner.analyzeSource` (single-file only, explicitly REJECTS any
// `импорт`), this is what makes `textDocument/definition`/`references`
// actually cross document boundaries. Before this file, any document
// containing `импорт` got ZERO LSP support at all (every handler used
// `analyzeSource`, which returns no tree/resolution for such a document) —
// cross-document navigation was a strict SUBSET of a bigger, pre-existing
// gap, not a separate one.
//
// Deliberately scoped to `definition`/`references` only for now (see
// `zig/lsp/main.zig`'s doc comments at their call sites) — swapping EVERY
// handler (hover/completion/foldingRange/documentSymbol/codeLens/
// signatureHelp/selectionRange/semanticTokensFull/prepareRename/rename/
// documentHighlight/workspace symbol) to this backend is a much bigger,
// separately-verifiable change, not bundled in here.

// `Reader` implements `module_loader.Graph.load`'s duck-typed `reader`
// interface — checks OPEN, possibly-unsaved documents FIRST (the LSP
// contract's own words: "a graph built with all currently open unsaved-
// source overrides"), falls back to real disk I/O for files that aren't
// open. `path` here is always the STRIPPED absolute filesystem path (see
// `uriToPath`) — `module_loader.resolveImportPath` join/normalize logic
// only ever produces one from the entry path's own shape, so this stays
// consistent for every import in the graph, not just the entry file.
const Reader = struct {
    io: std.Io,
    documents: *const lsp.DocumentStore,

    pub fn read(self: *const Reader, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const uri = try pathToUri(allocator, path);
        defer allocator.free(uri);
        if (self.documents.sourceText(uri)) |text| return allocator.dupe(u8, text);
        // Accept the raw-Unicode form used by older clients/tests too; the
        // canonical URI returned to the client remains percent-encoded.
        const raw_uri = try std.fmt.allocPrint(allocator, "file://{s}", .{path});
        defer allocator.free(raw_uri);
        if (self.documents.sourceText(raw_uri)) |text| return allocator.dupe(u8, text);
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(4 * 1024 * 1024));
    }
};

pub fn uriToPath(uri: []const u8) ?[]const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    return uri[prefix.len..];
}

// LSP clients normally percent-encode file URIs (`%20`, UTF-8 bytes, ...).
// Keep `uriToPath` as the zero-allocation fast path for existing callers, and
// use this owned variant whenever the path is passed to the filesystem or
// compared with graph module paths.
pub fn uriToPathAlloc(allocator: std.mem.Allocator, uri: []const u8) !?[]u8 {
    const raw = uriToPath(uri) orelse return null;
    const buffer = try allocator.dupe(u8, raw);
    const decoded = std.Uri.percentDecodeInPlace(buffer);
    const result = try allocator.alloc(u8, decoded.len);
    @memcpy(result, decoded);
    allocator.free(buffer);
    return result;
}

pub fn pathToUri(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(allocator);
    try encoded.appendSlice(allocator, "file://");
    for (path) |byte| {
        const safe = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~' or byte == '/';
        if (safe) {
            try encoded.append(allocator, byte);
        } else {
            const hex = "0123456789ABCDEF";
            try encoded.appendSlice(allocator, &.{ '%', hex[byte >> 4], hex[byte & 0x0f] });
        }
    }
    return encoded.toOwnedSlice(allocator);
}

pub const GraphAnalysis = struct {
    graph: module_loader.Graph,
    compiled: module_compiler.GraphCompileResult,

    pub fn deinit(self: *GraphAnalysis) void {
        self.compiled.deinit();
        self.graph.deinit();
        self.* = undefined;
    }

    pub fn hasErrors(self: *const GraphAnalysis) bool {
        for (self.graph.diagnostics.items.items) |item| {
            if (item.severity == .err) return true;
        }
        return self.compiled.hasErrors();
    }

    pub fn moduleCount(self: *const GraphAnalysis) usize {
        return self.graph.modules.items.len;
    }

    pub fn moduleTree(self: *const GraphAnalysis, index: usize) *const ast.Ast {
        return &self.graph.modules.items[index].tree;
    }

    pub fn moduleResolution(self: *const GraphAnalysis, index: usize) ?*const resolver.Resolution {
        return if (self.compiled.modules[index].resolution) |*value| value else null;
    }

    pub fn moduleChecked(self: *const GraphAnalysis, index: usize) ?*const type_checker.CheckResult {
        return if (self.compiled.modules[index].checked) |*value| value else null;
    }

    pub fn modulePath(self: *const GraphAnalysis, index: usize) []const u8 {
        return self.graph.modules.items[index].file.path;
    }

    pub fn moduleSourceFile(self: *const GraphAnalysis, index: usize) source.SourceFile {
        const module = &self.graph.modules.items[index];
        return source.SourceFile.init(module.file.id, module.file.path, module.file.bytes);
    }

    // Entry module (the document the request was made against) is always
    // index 0 — `Graph.load` appends it first, before any import; the
    // prelude module (appended separately, see `analyze` below) always
    // comes after every real module.
    pub fn entryTree(self: *const GraphAnalysis) *const ast.Ast {
        return self.moduleTree(0);
    }

    pub fn entryResolution(self: *const GraphAnalysis) ?*const resolver.Resolution {
        return self.moduleResolution(0);
    }
};

pub fn analyze(allocator: std.mem.Allocator, io: std.Io, documents: *const lsp.DocumentStore, entry_uri: []const u8, global_search_roots: []const []const u8) !GraphAnalysis {
    const entry_path = (try uriToPathAlloc(allocator, entry_uri)) orelse return error.NotAFileUri;
    defer allocator.free(entry_path);
    var graph = module_loader.Graph.init(allocator);
    errdefer graph.deinit();
    // Without this, any import resolved via `$PANOS_STDLIB`/exe-relative
    // `std/` (not a same-directory relative `./...` import) never loads at
    // all — `Module Loader Error: не удалось загрузить модуль`, silently
    // caught by every caller (`definition`/`references` in `lsp/main.zig`
    // return `null` on ANY `analyze` error), surfacing to the user as a
    // bare "не найдено определение" for the target symbol, with no
    // diagnostic ever shown. Real gap found: `cli/main.zig`'s real `panos`
    // binary sets this (`$PANOS_STDLIB` then exe-relative `std/`, see its
    // own comment) before every `graph.load`; this LSP-side graph builder
    // never did, for ANY caller, since the day this file was added.
    graph.global_search_roots = global_search_roots;
    const reader = Reader{ .io = io, .documents = documents };
    try graph.load(&reader, entry_path);
    _ = try graph.appendPreludeModule(prelude.SOURCE);
    var compiled = try module_compiler.compileGraph(allocator, &graph);
    errdefer compiled.deinit();
    return .{ .graph = graph, .compiled = compiled };
}

test "uriToPath/pathToUri round-trip a file:// URI" {
    const allocator = std.testing.allocator;
    const path = uriToPath("file:///пример.ps").?;
    try std.testing.expectEqualStrings("/пример.ps", path);
    const uri = try pathToUri(allocator, path);
    defer allocator.free(uri);
    try std.testing.expectEqualStrings("file:///%D0%BF%D1%80%D0%B8%D0%BC%D0%B5%D1%80.ps", uri);
    const decoded = (try uriToPathAlloc(allocator, uri)).?;
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("/пример.ps", decoded);
}

test "uriToPathAlloc decodes spaces and percent-encoded UTF-8" {
    const allocator = std.testing.allocator;
    const path = (try uriToPathAlloc(allocator, "file:///tmp/Panos%20%D1%82%D0%B5%D1%81%D1%82.ps")).?;
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/Panos тест.ps", path);
}

test "uriToPath rejects a non-file URI" {
    try std.testing.expectEqual(@as(?[]const u8, null), uriToPath("untitled:пример.ps"));
}

test "analyze loads a real multi-file graph from open, unsaved documents" {
    const allocator = std.testing.allocator;
    var documents = lsp.DocumentStore.init(allocator);
    defer documents.deinit();
    try documents.replace("file:///проект/main.ps", "импорт \"./математика\" как мат\nэкспорт функ старт() -> Число\nмат.сложить(мат.ОТВЕТ, 2.0)\nконец");
    try documents.replace("file:///проект/математика.ps", "экспорт конст ОТВЕТ = 40.0\nэкспорт функ сложить(a: Число, b: Число) -> Число\na + b\nконец");

    var io = std.Io.Threaded.init(allocator, .{});
    defer io.deinit();

    var analysis = try analyze(allocator, io.io(), &documents, "file:///проект/main.ps", &.{});
    defer analysis.deinit();

    try std.testing.expect(!analysis.hasErrors());
    try std.testing.expectEqual(@as(usize, 3), analysis.moduleCount()); // main + математика + prelude
    try std.testing.expectEqualStrings("/проект/main.ps", analysis.modulePath(0));
    try std.testing.expectEqualStrings("/проект/математика.ps", analysis.modulePath(1));
}
