const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const runner = @import("runner.zig");
const source = @import("source.zig");

pub const Range = struct {
    start: source.Utf16Position,
    end: source.Utf16Position,
};

pub const Diagnostic = struct {
    range: Range,
    severity: diagnostic.Severity,
    message: []const u8,
};

pub const DocumentDiagnostics = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Diagnostic) = .empty,

    pub fn init(allocator: std.mem.Allocator) DocumentDiagnostics {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *DocumentDiagnostics) void {
        self.items.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }
};

const Document = struct {
    text: []u8,
};

pub const DocumentStore = struct {
    allocator: std.mem.Allocator,
    documents: std.StringHashMap(Document),

    pub fn init(allocator: std.mem.Allocator) DocumentStore {
        return .{
            .allocator = allocator,
            .documents = .init(allocator),
        };
    }

    pub fn deinit(self: *DocumentStore) void {
        var iterator = self.documents.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.text);
        }
        self.documents.deinit();
        self.* = undefined;
    }

    pub fn replace(self: *DocumentStore, uri: []const u8, text: []const u8) !void {
        const copied_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(copied_text);
        if (self.documents.getPtr(uri)) |document| {
            self.allocator.free(document.text);
            document.text = copied_text;
            return;
        }
        const copied_uri = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(copied_uri);
        try self.documents.put(copied_uri, .{ .text = copied_text });
    }

    pub fn remove(self: *DocumentStore, uri: []const u8) bool {
        const removed = self.documents.fetchRemove(uri) orelse return false;
        self.allocator.free(removed.key);
        self.allocator.free(removed.value.text);
        return true;
    }

    pub fn sourceText(self: *const DocumentStore, uri: []const u8) ?[]const u8 {
        const document = self.documents.get(uri) orelse return null;
        return document.text;
    }

    pub fn diagnose(self: *const DocumentStore, uri: []const u8) !?DocumentDiagnostics {
        const document = self.documents.get(uri) orelse return null;
        return @as(?DocumentDiagnostics, try diagnoseDocument(self.allocator, uri, document.text));
    }
};

pub fn diagnoseDocument(allocator: std.mem.Allocator, path: []const u8, text: []const u8) !DocumentDiagnostics {
    var analysis = try runner.analyzeSource(allocator, path, text);
    defer analysis.deinit();

    var result = DocumentDiagnostics.init(allocator);
    errdefer result.deinit();
    const file = source.SourceFile.init(0, path, text);
    for (analysis.diagnostics.items.items) |item| {
        if (!item.span.isValidFor(file)) continue;
        try result.items.append(allocator, .{
            .range = .{
                .start = file.byteOffsetToUtf16Position(item.span.start),
                .end = file.byteOffsetToUtf16Position(item.span.end),
            },
            .severity = item.severity,
            .message = try result.arena.allocator().dupe(u8, item.message),
        });
    }
    return result;
}

test "LSP diagnostics preserve Russian UTF-16 ranges" {
    var diagnostics = try diagnoseDocument(
        std.testing.allocator,
        "пример.ps",
        "экспорт функ старт() -> Число\nнеизвестно\nконец",
    );
    defer diagnostics.deinit();

    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.items.len);
    const item = diagnostics.items.items[0];
    try std.testing.expectEqualDeep(source.Utf16Position{ .line = 1, .character = 0 }, item.range.start);
    try std.testing.expectEqualDeep(source.Utf16Position{ .line = 1, .character = 10 }, item.range.end);
    try std.testing.expectEqualStrings("Resolve Error: неопределённое имя 'неизвестно'", item.message);
}

test "LSP document store revalidates unsaved document changes" {
    var documents = DocumentStore.init(std.testing.allocator);
    defer documents.deinit();

    try documents.replace("file:///пример.ps", "экспорт функ старт() -> Число\n42\nконец");
    var valid = (try documents.diagnose("file:///пример.ps")).?;
    defer valid.deinit();
    try std.testing.expectEqual(@as(usize, 0), valid.items.items.len);

    try documents.replace("file:///пример.ps", "экспорт функ старт() -> Число\nнеизвестно\nконец");
    var invalid = (try documents.diagnose("file:///пример.ps")).?;
    defer invalid.deinit();
    try std.testing.expectEqual(@as(usize, 1), invalid.items.items.len);

    try std.testing.expect(documents.remove("file:///пример.ps"));
    try std.testing.expect((try documents.diagnose("file:///пример.ps")) == null);
}
