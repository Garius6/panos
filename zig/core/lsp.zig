const std = @import("std");
const ast = @import("ast.zig");
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

pub const DocumentSymbolKind = enum {
    structure,
    enumeration,
    interface,
    function,
    method,
    field,
    enum_member,
    implementation,
    constant,
    type_alias,
};

pub const DocumentSymbol = struct {
    name: []const u8,
    kind: DocumentSymbolKind,
    range: source.Span,
    selection_range: source.Span,
    children: []const DocumentSymbol = &.{},
};

pub const DocumentSymbols = struct {
    arena: std.heap.ArenaAllocator,
    items: []const DocumentSymbol = &.{},

    pub fn init(allocator: std.mem.Allocator) DocumentSymbols {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *DocumentSymbols) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const DocumentSymbolBuilder = struct {
    result: *DocumentSymbols,

    fn collect(self: *DocumentSymbolBuilder, tree: *const ast.Ast) !void {
        const program = tree.program orelse return;
        var symbols: std.ArrayList(DocumentSymbol) = .empty;
        defer symbols.deinit(self.result.arena.child_allocator);
        for (program.declarations) |declaration| {
            if (try self.fromDeclaration(tree, declaration)) |symbol| {
                try symbols.append(self.result.arena.child_allocator, symbol);
            }
        }
        self.result.items = try self.result.arena.allocator().dupe(DocumentSymbol, symbols.items);
    }

    fn fromDeclaration(self: *DocumentSymbolBuilder, tree: *const ast.Ast, declaration: ast.DeclId) !?DocumentSymbol {
        return switch (tree.decl(declaration).*) {
            .function => |value| .{
                .name = value.name,
                .kind = .function,
                .range = value.span,
                .selection_range = value.name_span,
            },
            .struct_decl => |value| .{
                .name = value.name,
                .kind = .structure,
                .range = value.span,
                .selection_range = value.span,
                .children = try self.fieldSymbols(value.fields),
            },
            .interface_decl => |value| .{
                .name = value.name,
                .kind = .interface,
                .range = value.span,
                .selection_range = value.span,
                .children = try self.interfaceMethods(value.methods),
            },
            .enum_decl => |value| .{
                .name = value.name,
                .kind = .enumeration,
                .range = value.span,
                .selection_range = value.span,
                .children = try self.variantSymbols(value.variants),
            },
            .impl => |value| .{
                .name = value.target_type,
                .kind = .implementation,
                .range = value.span,
                .selection_range = value.span,
                .children = try self.implementationMethods(tree, value.methods),
            },
            .foreign => |value| .{
                .name = value.name,
                .kind = .function,
                .range = value.span,
                .selection_range = value.span,
            },
            .constant => |value| .{
                .name = value.name,
                .kind = .constant,
                .range = value.span,
                .selection_range = value.name_span,
            },
            .type_alias => |value| .{
                .name = value.name,
                .kind = .type_alias,
                .range = value.span,
                .selection_range = value.span,
            },
            else => null,
        };
    }

    fn fieldSymbols(self: *DocumentSymbolBuilder, fields: []const ast.FieldDecl) ![]const DocumentSymbol {
        var symbols: std.ArrayList(DocumentSymbol) = .empty;
        defer symbols.deinit(self.result.arena.child_allocator);
        for (fields) |field| try symbols.append(self.result.arena.child_allocator, .{
            .name = field.name,
            .kind = .field,
            .range = field.span,
            .selection_range = field.span,
        });
        return self.result.arena.allocator().dupe(DocumentSymbol, symbols.items);
    }

    fn interfaceMethods(self: *DocumentSymbolBuilder, methods: []const ast.MethodSignature) ![]const DocumentSymbol {
        var symbols: std.ArrayList(DocumentSymbol) = .empty;
        defer symbols.deinit(self.result.arena.child_allocator);
        for (methods) |method| try symbols.append(self.result.arena.child_allocator, .{
            .name = method.name,
            .kind = .method,
            .range = method.span,
            .selection_range = method.span,
        });
        return self.result.arena.allocator().dupe(DocumentSymbol, symbols.items);
    }

    fn variantSymbols(self: *DocumentSymbolBuilder, variants: []const ast.VariantDecl) ![]const DocumentSymbol {
        var symbols: std.ArrayList(DocumentSymbol) = .empty;
        defer symbols.deinit(self.result.arena.child_allocator);
        for (variants) |variant| try symbols.append(self.result.arena.child_allocator, .{
            .name = variant.name,
            .kind = .enum_member,
            .range = variant.span,
            .selection_range = variant.span,
        });
        return self.result.arena.allocator().dupe(DocumentSymbol, symbols.items);
    }

    fn implementationMethods(self: *DocumentSymbolBuilder, tree: *const ast.Ast, methods: []const ast.DeclId) ![]const DocumentSymbol {
        var symbols: std.ArrayList(DocumentSymbol) = .empty;
        defer symbols.deinit(self.result.arena.child_allocator);
        for (methods) |method| {
            const function = tree.decl(method).function;
            try symbols.append(self.result.arena.child_allocator, .{
                .name = function.name,
                .kind = .method,
                .range = function.span,
                .selection_range = function.name_span,
            });
        }
        return self.result.arena.allocator().dupe(DocumentSymbol, symbols.items);
    }
};

pub fn documentSymbols(allocator: std.mem.Allocator, tree: *const ast.Ast) !DocumentSymbols {
    var result = DocumentSymbols.init(allocator);
    errdefer result.deinit();
    var builder = DocumentSymbolBuilder{ .result = &result };
    try builder.collect(tree);
    return result;
}

pub const FoldingRange = struct {
    span: source.Span,
};

const FoldingError = std.mem.Allocator.Error;

pub const FoldingRanges = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(FoldingRange) = .empty,

    pub fn init(allocator: std.mem.Allocator) FoldingRanges {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FoldingRanges) void {
        self.items.deinit(self.allocator);
        self.* = undefined;
    }
};

pub fn foldingRanges(allocator: std.mem.Allocator, tree: *const ast.Ast) FoldingError!FoldingRanges {
    var result = FoldingRanges.init(allocator);
    errdefer result.deinit();
    const program = tree.program orelse return result;
    for (program.declarations) |declaration| try collectDeclarationFolds(tree, declaration, &result);
    return result;
}

fn appendFold(result: *FoldingRanges, span: source.Span) FoldingError!void {
    try result.items.append(result.allocator, .{ .span = span });
}

fn collectDeclarationFolds(tree: *const ast.Ast, declaration: ast.DeclId, result: *FoldingRanges) FoldingError!void {
    switch (tree.decl(declaration).*) {
        .function => |value| {
            try appendFold(result, value.span);
            try collectStatementFolds(tree, value.body, result);
        },
        .struct_decl => |value| try appendFold(result, value.span),
        .interface_decl => |value| try appendFold(result, value.span),
        .enum_decl => |value| try appendFold(result, value.span),
        .foreign => |value| try appendFold(result, value.span),
        .impl => |value| {
            try appendFold(result, value.span);
            for (value.methods) |method| try collectDeclarationFolds(tree, method, result);
        },
        else => {},
    }
}

fn collectStatementFolds(tree: *const ast.Ast, statements: []const ast.StmtId, result: *FoldingRanges) FoldingError!void {
    for (statements) |statement| switch (tree.stmt(statement).*) {
        .return_stmt => |value| try collectExpressionFolds(tree, value.value, result),
        .let => |value| try collectExpressionFolds(tree, value.value, result),
        .expr => |value| try collectExpressionFolds(tree, value.value, result),
        .for_in => |value| {
            try appendFold(result, value.span);
            try collectExpressionFolds(tree, value.iterable, result);
            try collectStatementFolds(tree, value.body, result);
        },
        .for_range => |value| {
            try appendFold(result, value.span);
            try collectExpressionFolds(tree, value.start, result);
            try collectExpressionFolds(tree, value.end, result);
            try collectStatementFolds(tree, value.body, result);
        },
        else => {},
    };
}

fn collectExpressionFolds(tree: *const ast.Ast, expression: ast.ExprId, result: *FoldingRanges) FoldingError!void {
    switch (tree.expr(expression).*) {
        .unary => |value| try collectExpressionFolds(tree, value.operand, result),
        .binary => |value| {
            try collectExpressionFolds(tree, value.left, result);
            try collectExpressionFolds(tree, value.right, result);
        },
        .call => |value| {
            try collectExpressionFolds(tree, value.callee, result);
            for (value.arguments) |argument| try collectExpressionFolds(tree, argument, result);
        },
        .spawn => |value| try collectExpressionFolds(tree, value.call, result),
        .property => |value| try collectExpressionFolds(tree, value.object, result),
        .if_expr => |value| {
            try appendFold(result, value.span);
            try collectExpressionFolds(tree, value.condition, result);
            try collectStatementFolds(tree, value.then_branch, result);
            try collectStatementFolds(tree, value.else_branch, result);
        },
        .while_expr => |value| {
            try appendFold(result, value.span);
            try collectExpressionFolds(tree, value.condition, result);
            try collectStatementFolds(tree, value.body, result);
        },
        .tuple => |value| for (value.elements) |element| try collectExpressionFolds(tree, element, result),
        .lambda => |value| {
            try appendFold(result, value.span);
            try collectStatementFolds(tree, value.body, result);
        },
        .array => |value| for (value.elements) |element| try collectExpressionFolds(tree, element, result),
        .map => |value| for (value.entries) |entry| {
            try collectExpressionFolds(tree, entry.key, result);
            try collectExpressionFolds(tree, entry.value, result);
        },
        .index => |value| {
            try collectExpressionFolds(tree, value.object, result);
            try collectExpressionFolds(tree, value.index, result);
        },
        .try_expr => |value| try collectExpressionFolds(tree, value.value, result),
        .match_expr => |value| {
            try appendFold(result, value.span);
            try collectExpressionFolds(tree, value.subject, result);
            for (value.arms) |arm| try collectStatementFolds(tree, arm.body, result);
        },
        else => {},
    }
}

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

test "LSP structural helpers expose outlines and foldable blocks" {
    var analysis = try runner.analyzeSource(
        std.testing.allocator,
        "пример.ps",
        "тип Точка = структура\nx: Число\nконец\nтип Ответ = перечисление\nДа\nконец\nфунк старт() -> Число\nесли истина тогда\n1\nиначе\n2\nконец\nконец",
    );
    defer analysis.deinit();
    const tree = analysis.tree().?;

    var symbols = try documentSymbols(std.testing.allocator, tree);
    defer symbols.deinit();
    try std.testing.expectEqual(@as(usize, 3), symbols.items.len);
    try std.testing.expectEqual(DocumentSymbolKind.structure, symbols.items[0].kind);
    try std.testing.expectEqualStrings("x", symbols.items[0].children[0].name);
    try std.testing.expectEqual(DocumentSymbolKind.enumeration, symbols.items[1].kind);
    try std.testing.expectEqual(DocumentSymbolKind.function, symbols.items[2].kind);

    var folds = try foldingRanges(std.testing.allocator, tree);
    defer folds.deinit();
    try std.testing.expect(folds.items.items.len >= 4);
}
