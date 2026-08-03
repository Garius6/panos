const std = @import("std");
const ast = @import("ast.zig");
const diagnostic = @import("diagnostic.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const source = @import("source.zig");

pub const Module = struct {
    file: source.SourceFile,
    tree: ast.Ast,

    pub fn deinit(self: *Module, allocator: std.mem.Allocator) void {
        self.tree.deinit();
        allocator.free(@constCast(self.file.bytes));
        self.* = undefined;
    }
};

pub const Import = struct {
    importer: usize,
    declaration: ast.DeclId,
    target: ?usize,
    alias: []const u8,
    span: source.Span,
};

pub const ExportKind = enum {
    function,
    constant,
    type,
};

pub const Export = struct {
    module: usize,
    declaration: ast.DeclId,
    name: []const u8,
    kind: ExportKind,
    span: source.Span,
};

pub const Graph = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    modules: std.ArrayList(Module) = .empty,
    module_indices: std.StringHashMap(usize),
    loading: std.StringHashMap(void),
    order: std.ArrayList(usize) = .empty,
    imports: std.ArrayList(Import) = .empty,
    exports: std.ArrayList(Export) = .empty,
    diagnostics: diagnostic.DiagnosticList = .{},

    pub fn init(allocator: std.mem.Allocator) Graph {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .module_indices = .init(allocator),
            .loading = .init(allocator),
        };
    }

    pub fn deinit(self: *Graph) void {
        for (self.modules.items) |*module| module.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
        self.exports.deinit(self.allocator);
        self.imports.deinit(self.allocator);
        self.order.deinit(self.allocator);
        self.loading.deinit();
        self.module_indices.deinit();
        self.modules.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn moduleForPath(self: *const Graph, path: []const u8) ?*const Module {
        const index = self.module_indices.get(path) orelse return null;
        return &self.modules.items[index];
    }

    pub fn moduleForFile(self: *const Graph, file_id: source.FileId) ?*const Module {
        const index: usize = file_id;
        if (index >= self.modules.items.len) return null;
        return &self.modules.items[index];
    }

    pub fn importForDeclaration(self: *const Graph, importer: usize, declaration: ast.DeclId) ?Import {
        for (self.imports.items) |entry| {
            if (entry.importer == importer and entry.declaration == declaration) return entry;
        }
        return null;
    }

    pub fn exportForName(self: *const Graph, module: usize, name: []const u8) ?Export {
        for (self.exports.items) |entry| {
            if (entry.module == module and std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    pub fn load(self: *Graph, reader: anytype, entry_path: []const u8) !void {
        const canonical_path = try resolveImportPath(self.allocator, entry_path, "");
        defer self.allocator.free(canonical_path);
        _ = try self.loadRecursive(reader, canonical_path, null);
    }

    fn loadRecursive(self: *Graph, reader: anytype, path: []const u8, importer_span: ?source.Span) !?usize {
        if (self.loading.contains(path)) {
            try self.report(importer_span orelse .{ .file_id = 0, .start = 0, .end = 0 }, "Module Loader Error: обнаружен циклический импорт '{s}'", .{path});
            return null;
        }
        if (self.module_indices.get(path)) |existing| return existing;

        try self.loading.put(path, {});
        defer _ = self.loading.remove(path);

        const bytes = reader.read(self.allocator, path) catch |err| {
            try self.report(importer_span orelse .{ .file_id = 0, .start = 0, .end = 0 }, "Module Loader Error: не удалось загрузить модуль '{s}': {s}", .{ path, @errorName(err) });
            return null;
        };
        var owns_bytes = true;
        errdefer if (owns_bytes) self.allocator.free(bytes);

        if (self.modules.items.len > std.math.maxInt(source.FileId)) return error.ModuleLimitReached;
        const file_id: source.FileId = @intCast(self.modules.items.len);
        const stored_path = try self.arena.allocator().dupe(u8, path);
        const file = source.SourceFile.init(file_id, stored_path, bytes);

        var lexed = try lexer.tokenize(self.allocator, bytes, file_id);
        defer lexed.deinit();
        try self.appendDiagnostics(&lexed.diagnostics);

        var parsed = try parser.parse(self.allocator, lexed.tokens.items);
        errdefer parsed.deinit();
        try self.appendDiagnostics(&parsed.diagnostics);
        var tree = parsed.ast;
        parsed.ast = ast.Ast.init(self.allocator);
        parsed.deinit();
        var owns_tree = true;
        errdefer if (owns_tree) tree.deinit();

        const index = self.modules.items.len;
        try self.modules.append(self.allocator, .{ .file = file, .tree = tree });
        owns_bytes = false;
        owns_tree = false;
        errdefer {
            var module = self.modules.pop().?;
            module.deinit(self.allocator);
        }
        try self.module_indices.put(stored_path, index);
        try self.collectExports(index);

        const declarations = self.modules.items[index].tree.program.?.declarations;
        for (declarations) |declaration| {
            const import = switch (self.modules.items[index].tree.decl(declaration).*) {
                .import => |value| value,
                else => continue,
            };
            const import_path = try resolveImportPath(self.allocator, import.path, stored_path);
            defer self.allocator.free(import_path);
            const target = try self.loadRecursive(reader, import_path, import.span);
            try self.imports.append(self.allocator, .{
                .importer = index,
                .declaration = declaration,
                .target = target,
                .alias = import.alias orelse moduleBaseName(import.path),
                .span = import.span,
            });
        }
        try self.order.append(self.allocator, index);
        return index;
    }

    fn collectExports(self: *Graph, module: usize) !void {
        const tree = &self.modules.items[module].tree;
        for (tree.program.?.declarations) |declaration| {
            const entry: ?Export = switch (tree.decl(declaration).*) {
                .function => |value| if (value.is_exported) .{
                    .module = module,
                    .declaration = declaration,
                    .name = value.name,
                    .kind = .function,
                    .span = value.name_span,
                } else null,
                .constant => |value| if (value.is_exported) .{
                    .module = module,
                    .declaration = declaration,
                    .name = value.name,
                    .kind = .constant,
                    .span = value.name_span,
                } else null,
                .struct_decl => |value| if (value.is_exported) .{
                    .module = module,
                    .declaration = declaration,
                    .name = value.name,
                    .kind = .type,
                    .span = value.span,
                } else null,
                .interface_decl => |value| if (value.is_exported) .{
                    .module = module,
                    .declaration = declaration,
                    .name = value.name,
                    .kind = .type,
                    .span = value.span,
                } else null,
                .enum_decl => |value| if (value.is_exported) .{
                    .module = module,
                    .declaration = declaration,
                    .name = value.name,
                    .kind = .type,
                    .span = value.span,
                } else null,
                .type_alias => |value| if (value.is_exported) .{
                    .module = module,
                    .declaration = declaration,
                    .name = value.name,
                    .kind = .type,
                    .span = value.span,
                } else null,
                else => null,
            };
            if (entry) |value| try self.exports.append(self.allocator, value);
        }
    }

    fn appendDiagnostics(self: *Graph, values: *const diagnostic.DiagnosticList) !void {
        for (values.items.items) |value| {
            const message = try self.arena.allocator().dupe(u8, value.message);
            _ = try self.diagnostics.appendUnique(self.allocator, .{
                .phase = value.phase,
                .severity = value.severity,
                .span = value.span,
                .message = message,
            });
        }
    }

    fn report(self: *Graph, span: source.Span, comptime format: []const u8, arguments: anytype) !void {
        const message = try std.fmt.allocPrint(self.arena.allocator(), format, arguments);
        _ = try self.diagnostics.appendUnique(self.allocator, .{
            .phase = .parser,
            .severity = .err,
            .span = span,
            .message = message,
        });
    }
};

pub fn resolveImportPath(allocator: std.mem.Allocator, import_path: []const u8, importer_path: []const u8) ![]u8 {
    const suffixed = if (std.mem.endsWith(u8, import_path, ".ps"))
        import_path
    else
        try std.fmt.allocPrint(allocator, "{s}.ps", .{import_path});
    defer if (suffixed.ptr != import_path.ptr) allocator.free(suffixed);

    const combined = if (isAbsolute(suffixed) or importer_path.len == 0) suffixed else blk: {
        const directory = moduleDirectory(importer_path);
        if (directory.len == 0) break :blk suffixed;
        break :blk try std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, suffixed });
    };
    defer if (combined.ptr != suffixed.ptr) allocator.free(combined);
    return normalizePath(allocator, combined);
}

fn isAbsolute(path: []const u8) bool {
    return path.len > 0 and path[0] == '/';
}

fn moduleDirectory(path: []const u8) []const u8 {
    const separator = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return path[0..separator];
}

fn moduleBaseName(path: []const u8) []const u8 {
    const file_name = if (std.mem.lastIndexOfScalar(u8, path, '/')) |separator| path[separator + 1 ..] else path;
    return if (std.mem.endsWith(u8, file_name, ".ps")) file_name[0 .. file_name.len - 3] else file_name;
}

fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const absolute = isAbsolute(path);
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    var start: usize = 0;
    var index: usize = 0;
    while (index <= path.len) : (index += 1) {
        if (index != path.len and path[index] != '/') continue;
        const part = path[start..index];
        start = index + 1;
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len != 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
                _ = parts.pop();
            } else if (!absolute) {
                try parts.append(allocator, part);
            }
            continue;
        }
        try parts.append(allocator, part);
    }

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    if (absolute) try result.append(allocator, '/');
    for (parts.items, 0..) |part, part_index| {
        if (part_index != 0) try result.append(allocator, '/');
        try result.appendSlice(allocator, part);
    }
    if (result.items.len == 0) try result.append(allocator, '.');
    return result.toOwnedSlice(allocator);
}

const MemoryReader = struct {
    files: []const File,

    const File = struct {
        path: []const u8,
        bytes: []const u8,
    };

    fn read(self: *const MemoryReader, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        for (self.files) |file| {
            if (std.mem.eql(u8, file.path, path)) return allocator.dupe(u8, file.bytes);
        }
        return error.FileNotFound;
    }
};

test "module loader orders local imports before their importers" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./арифметика\"\nэкспорт функ старт() -> Число\nарифметика.ответ()\nконец" },
        .{ .path = "проект/арифметика.ps", .bytes = "импорт \"./детали/числа\"\nэкспорт функ ответ() -> Число\nчисла.значение()\nконец" },
        .{ .path = "проект/детали/числа.ps", .bytes = "экспорт функ значение() -> Число\n42\nконец" },
    } };
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    try graph.load(&reader, "проект/./main");

    try std.testing.expectEqual(@as(usize, 3), graph.modules.items.len);
    try std.testing.expectEqual(@as(usize, 3), graph.order.items.len);
    try std.testing.expectEqualStrings("проект/детали/числа.ps", graph.modules.items[graph.order.items[0]].file.path);
    try std.testing.expectEqualStrings("проект/арифметика.ps", graph.modules.items[graph.order.items[1]].file.path);
    try std.testing.expectEqualStrings("проект/main.ps", graph.modules.items[graph.order.items[2]].file.path);
    try std.testing.expectEqual(@as(usize, 2), graph.imports.items.len);
    try std.testing.expectEqualStrings("арифметика", graph.imports.items[1].alias);
    try std.testing.expectEqual(@as(?usize, 1), graph.imports.items[1].target);
    const answer = graph.exportForName(1, "ответ").?;
    try std.testing.expectEqual(ExportKind.function, answer.kind);
    try std.testing.expectEqual(@as(usize, 1), answer.module);
    try std.testing.expectEqual(@as(usize, 3), graph.exports.items.len);
    try std.testing.expectEqual(@as(usize, 0), graph.diagnostics.items.items.len);
}

test "module loader reports import cycles at the importing declaration" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "a.ps", .bytes = "импорт \"b\"" },
        .{ .path = "b.ps", .bytes = "импорт \"a\"" },
    } };
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    try graph.load(&reader, "a");

    try std.testing.expectEqual(@as(usize, 1), graph.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Module Loader Error: обнаружен циклический импорт 'a.ps'", graph.diagnostics.items.items[0].message);
    try std.testing.expectEqual(@as(source.FileId, 1), graph.diagnostics.items.items[0].span.file_id);
}

test "module loader reports missing local modules" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./нет\"" },
    } };
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    try graph.load(&reader, "проект/main.ps");

    try std.testing.expectEqual(@as(usize, 1), graph.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Module Loader Error: не удалось загрузить модуль 'проект/нет.ps': FileNotFound", graph.diagnostics.items.items[0].message);
    try std.testing.expectEqual(@as(source.FileId, 0), graph.diagnostics.items.items[0].span.file_id);
}

test "module loader normalizes relative import paths" {
    const path = try resolveImportPath(std.testing.allocator, "./детали/../математика", "проект/main.ps");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("проект/математика.ps", path);
}
