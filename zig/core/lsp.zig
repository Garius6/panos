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
