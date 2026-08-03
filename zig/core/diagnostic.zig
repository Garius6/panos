const std = @import("std");
const source = @import("source.zig");

pub const Severity = enum {
    err,
    warning,
};

pub const Phase = enum {
    lexer,
    parser,
    resolver,
    type_checker,
    compiler,
    runtime,
    lsp,
};

pub const Diagnostic = struct {
    phase: Phase,
    severity: Severity,
    span: source.Span,
    message: []const u8,
};

pub const DiagnosticList = struct {
    items: std.ArrayList(Diagnostic) = .empty,

    pub fn deinit(self: *DiagnosticList, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
        self.* = undefined;
    }

    pub fn appendUnique(
        self: *DiagnosticList,
        allocator: std.mem.Allocator,
        diagnostic: Diagnostic,
    ) !bool {
        for (self.items.items) |existing| {
            if (existing.phase == diagnostic.phase and
                existing.severity == diagnostic.severity and
                std.meta.eql(existing.span, diagnostic.span) and
                std.mem.eql(u8, existing.message, diagnostic.message))
            {
                return false;
            }
        }
        try self.items.append(allocator, diagnostic);
        return true;
    }
};

test "diagnostics deduplicate within the same phase" {
    var diagnostics: DiagnosticList = .{};
    defer diagnostics.deinit(std.testing.allocator);

    const diagnostic = Diagnostic{
        .phase = .lexer,
        .severity = .err,
        .span = .{ .file_id = 0, .start = 4, .end = 5 },
        .message = "Лексическая ошибка: неожиданный символ '$'",
    };

    try std.testing.expect(try diagnostics.appendUnique(std.testing.allocator, diagnostic));
    try std.testing.expect(!(try diagnostics.appendUnique(std.testing.allocator, diagnostic)));
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.items.len);
}

test "same location remains available to different phases" {
    var diagnostics: DiagnosticList = .{};
    defer diagnostics.deinit(std.testing.allocator);

    const span = source.Span{ .file_id = 0, .start = 0, .end = 1 };
    try std.testing.expect(try diagnostics.appendUnique(std.testing.allocator, .{
        .phase = .lexer,
        .severity = .err,
        .span = span,
        .message = "Лексическая ошибка",
    }));
    try std.testing.expect(try diagnostics.appendUnique(std.testing.allocator, .{
        .phase = .parser,
        .severity = .err,
        .span = span,
        .message = "Синтаксическая ошибка",
    }));
    try std.testing.expectEqual(@as(usize, 2), diagnostics.items.items.len);
}
