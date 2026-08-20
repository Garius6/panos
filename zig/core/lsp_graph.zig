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

// Настоящий многофайловый анализ для LSP на основе `module_loader.Graph` —
// в отличие от `runner.analyzeSource` (только один файл, явно ОТВЕРГАЕТ
// любой `импорт`), именно это позволяет `textDocument/definition`/
// `references` реально пересекать границы документов.
//
// Намеренно ограничено пока только `definition`/`references` (см.
// doc-комментарии `zig/lsp/main.zig` у мест их вызова) — перевод КАЖДОГО
// обработчика (hover/completion/foldingRange/documentSymbol/codeLens/
// signatureHelp/selectionRange/semanticTokensFull/prepareRename/rename/
// documentHighlight/workspace symbol) на этот бэкенд — гораздо более
// крупное, отдельно проверяемое изменение, сюда не входит.

// `Reader` реализует duck-typed интерфейс `reader`, ожидаемый
// `module_loader.Graph.load` — сначала проверяет ОТКРЫТЫЕ, возможно
// несохранённые документы (по контракту LSP: "граф строится с учётом всех
// открытых несохранённых переопределений исходника"), для файлов не
// открытых в редакторе падает обратно на настоящий дисковый I/O. `path`
// здесь всегда ОЧИЩЕННЫЙ абсолютный путь файловой системы (см.
// `uriToPath`) — логика join/normalize в `module_loader.resolveImportPath`
// производит именно такой путь из формы входного пути, поэтому это
// остаётся согласованным для каждого импорта в графе, а не только для
// входного файла.
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

// LSP-клиенты обычно percent-кодируют file URI (`%20`, байты UTF-8, ...).
// `uriToPath` остаётся быстрым путём без аллокаций для существующих
// вызывающих сторон, а этот вариант с владением используется всюду, где
// путь передаётся файловой системе или сравнивается с путями модулей
// графа.
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

    // Входной модуль (документ, для которого сделан запрос) всегда имеет
    // индекс 0 — `Graph.load` добавляет его первым, до любого импорта;
    // модуль prelude (добавляется отдельно, см. `analyze` ниже) всегда
    // идёт после всех настоящих модулей.
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
    // Без этого любой импорт, резолвящийся через `$PANOS_STDLIB`/
    // относительный к exe `std/` (не относительный `./...` импорт из той
    // же директории), вообще не загружается — `Module Loader Error: не
    // удалось загрузить модуль`, молча проглатывается каждым вызывающим
    // кодом (`definition`/`references` в `lsp/main.zig` возвращают `null`
    // при ЛЮБОЙ ошибке `analyze`), для пользователя это выглядит как
    // просто "не найдено определение" для целевого символа, без единой
    // показанной диагностики.
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
