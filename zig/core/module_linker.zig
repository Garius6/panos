const std = @import("std");
const module_loader = @import("module_loader.zig");
const resolver = @import("resolver.zig");
const symbols = @import("symbols.zig");

pub const ImportScope = struct {
    arena: std.heap.ArenaAllocator,
    modules: []const resolver.ImportedModule = &.{},

    pub fn init(allocator: std.mem.Allocator, graph: *const module_loader.Graph, importer: usize) !ImportScope {
        var result = ImportScope{
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer result.deinit();
        var modules: std.ArrayList(resolver.ImportedModule) = .empty;
        defer modules.deinit(allocator);
        for (graph.imports.items) |import| {
            if (import.importer != importer) continue;
            const target = import.target orelse continue;
            var exports: std.ArrayList(resolver.ImportedExport) = .empty;
            defer exports.deinit(allocator);
            for (graph.exports.items) |exported| {
                if (exported.module != target) continue;
                try exports.append(allocator, .{
                    .name = exported.name,
                    .kind = switch (exported.kind) {
                        .function => .function,
                        .constant => .constant,
                        .type => .type,
                    },
                    .span = exported.span,
                    .origin = .{
                        .module = target,
                        .declaration = exported.declaration,
                    },
                });
            }
            try modules.append(allocator, .{
                .alias = import.alias,
                .span = import.span,
                .exports = try result.arena.allocator().dupe(resolver.ImportedExport, exports.items),
            });
        }
        result.modules = try result.arena.allocator().dupe(resolver.ImportedModule, modules.items);
        return result;
    }

    pub fn deinit(self: *ImportScope) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const MemoryReader = struct {
    files: []const File,

    const File = struct {
        path: []const u8,
        bytes: []const u8,
    };

    pub fn read(self: *const MemoryReader, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        for (self.files) |file| {
            if (std.mem.eql(u8, file.path, path)) return allocator.dupe(u8, file.bytes);
        }
        return error.FileNotFound;
    }
};

test "module linker provides graph exports to resolver import scopes" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./математика\" как мат\nфунк старт() -> Число\nмат.сложить(20, 22)\nконец" },
        .{ .path = "проект/математика.ps", .bytes = "экспорт функ сложить(a: Число, b: Число) -> Число\na + b\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var scope = try ImportScope.init(std.testing.allocator, &graph, 0);
    defer scope.deinit();
    try std.testing.expectEqual(@as(usize, 1), scope.modules.len);
    try std.testing.expectEqualStrings("мат", scope.modules[0].alias);
    try std.testing.expectEqual(@as(usize, 1), scope.modules[0].exports.len);
    try std.testing.expectEqual(symbols.SymbolKind.function, scope.modules[0].exports[0].kind);

    var resolved = try resolver.resolveWithImports(std.testing.allocator, &graph.modules.items[0].tree, scope.modules);
    defer resolved.deinit();
    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
}
