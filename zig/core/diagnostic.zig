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

/// Отображает один диагностический объект как `путь:строка:колонка: сообщение`,
/// используя тот `SourceFile`, которому принадлежит span диагностики. `file.id`
/// должен совпадать с `value.span.file_id` — вызывающим, у которых есть только
/// `Graph`, следует использовать `writeGraph`, который сам находит нужный файл
/// для каждой диагностики.
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

/// Выводит каждую диагностику из `diagnostics`, по одной на строку, находя
/// исходный файл каждой через `graph`. Если файл диагностики не найден в
/// `graph` (например, диагностика уровня графа без привязки к конкретному
/// файлу), выводится только голое сообщение.
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
