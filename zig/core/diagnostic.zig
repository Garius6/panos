const std = @import("std");
const source = @import("source.zig");
const module_loader = @import("module_loader.zig");

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

pub const FormatError = error{
    FileMismatch,
    InvalidSpan,
};

/// Renders one diagnostic as `путь:строка:колонка: сообщение`, using the
/// exact `SourceFile` the diagnostic's span belongs to. `file.id` must match
/// `value.span.file_id` — callers with only a `Graph` should use `writeGraph`
/// instead, which resolves the right file per diagnostic itself.
pub fn format(
    allocator: std.mem.Allocator,
    file: source.SourceFile,
    value: Diagnostic,
) (FormatError || std.mem.Allocator.Error)![]u8 {
    if (value.span.file_id != file.id) return error.FileMismatch;
    if (!value.span.isValidFor(file)) return error.InvalidSpan;

    const position = file.lineColumn(value.span.start);
    const warning_prefix: []const u8 = switch (value.severity) {
        .err => "",
        .warning => "warning: ",
    };
    return std.fmt.allocPrint(
        allocator,
        "{s}:{d}:{d}: {s}{s}",
        .{ file.path, position.line, position.column, warning_prefix, value.message },
    );
}

/// Writes every diagnostic in `diagnostics`, one per line, resolving each
/// one's source file through `graph`. A diagnostic whose file cannot be
/// found in `graph` (e.g. a graph-level diagnostic with no specific file)
/// falls back to printing its bare message.
pub fn writeGraph(
    writer: *std.Io.Writer,
    graph: *const module_loader.Graph,
    diagnostics: *const DiagnosticList,
) !void {
    for (diagnostics.items.items) |value| {
        const module = graph.moduleForFile(value.span.file_id) orelse {
            try writer.print("{s}\n", .{value.message});
            continue;
        };
        const rendered = try format(std.heap.page_allocator, module.file, value);
        defer std.heap.page_allocator.free(rendered);
        try writer.print("{s}\n", .{rendered});
    }
}

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
