const std = @import("std");
const module_loader = @import("module_loader.zig");
const resolver = @import("resolver.zig");
const symbols = @import("symbols.zig");

pub const ImportScope = struct {
    arena: std.heap.ArenaAllocator,
    modules: []const resolver.ImportedModule = &.{},

    pub fn init(allocator: std.mem.Allocator, graph: *const module_loader.Graph, importer: usize) !ImportScope {
        return initWithPrelude(allocator, graph, importer, null);
    }

    // `prelude_module`, if set and not the importer itself, gets merged as
    // an UNQUALIFIED implicit import (no `импорт`/alias) ahead of the
    // importer's own explicit imports — see `resolver.zig`'s
    // `predeclareUnqualifiedImports`.
    pub fn initWithPrelude(allocator: std.mem.Allocator, graph: *const module_loader.Graph, importer: usize, prelude_module: ?usize) !ImportScope {
        var result = ImportScope{
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer result.deinit();
        var modules: std.ArrayList(resolver.ImportedModule) = .empty;
        defer modules.deinit(allocator);

        if (prelude_module) |target| {
            if (target != importer) {
                const exports = try buildExportsForTarget(allocator, &result.arena, graph, target, importer);
                try modules.append(allocator, .{
                    .alias = "",
                    .span = .{ .file_id = 0, .start = 0, .end = 0 },
                    .exports = exports,
                    .unqualified = true,
                });
            }
        }
        for (graph.imports.items) |import| {
            if (import.importer != importer) continue;
            const target = import.target orelse {
                // Aliased native import (`импорт "ввод_вывод" как ио`) —
                // `target == null` here doesn't mean "failed to load"
                // (the module_loader.zig diagnostic already handles that
                // case), it means "resolved ambiently, no file at all".
                // Real gap found auditing panosiki's `std/слог.ps`: the
                // BARE unaliased form (`импорт время`) already worked
                // (resolver.zig's `installBuiltins` makes it globally
                // ambient regardless of any `импорт`), but the alias
                // itself was never bound to anything.
                const native_name = import.native_module orelse continue;
                // Bare, unaliased native import (`импорт время`) — the
                // real name is ALREADY globally ambient
                // (`resolver.zig`'s `installBuiltins`), predeclaring a
                // SECOND `время` module symbol here would just collide
                // with it (`Resolve Error: символ 'время' уже объявлен`).
                // Only a GENUINE rename (`как ...`) needs anything built
                // here at all.
                if (std.mem.eql(u8, import.alias, native_name)) continue;
                const export_names = resolver.nativeModuleExports(native_name) orelse continue;
                var exports: std.ArrayList(resolver.ImportedExport) = .empty;
                defer exports.deinit(allocator);
                for (export_names) |export_name| {
                    try exports.append(allocator, .{
                        .name = export_name,
                        .kind = resolver.nativeModuleExportKind(native_name, export_name),
                        .span = import.span,
                        .builtin_module_path = native_name,
                    });
                }
                try modules.append(allocator, .{
                    .alias = import.alias,
                    .span = import.span,
                    .exports = try result.arena.allocator().dupe(resolver.ImportedExport, exports.items),
                });
                continue;
            };
            const exports = try buildExportsForTarget(allocator, &result.arena, graph, target, importer);
            try modules.append(allocator, .{
                .alias = import.alias,
                .span = import.span,
                .exports = exports,
            });
        }
        result.modules = try result.arena.allocator().dupe(resolver.ImportedModule, modules.items);
        return result;
    }

    fn buildExportsForTarget(allocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator, graph: *const module_loader.Graph, target: usize, importer: usize) ![]const resolver.ImportedExport {
        var exports: std.ArrayList(resolver.ImportedExport) = .empty;
        defer exports.deinit(allocator);
        for (graph.exports.items) |exported| {
            if (exported.module != target) continue;
            var methods: std.ArrayList(resolver.ImportedMethodExport) = .empty;
            defer methods.deinit(allocator);
            var variants: std.ArrayList(resolver.ImportedVariantExport) = .empty;
            defer variants.deinit(allocator);
            if (exported.kind == .type) {
                for (graph.methods.items) |method| {
                    if (method.owner_module != target or method.owner_declaration != exported.declaration) continue;
                    // A qualified-target impl declared in THIS SAME
                    // module (`importer`) that also happens to import
                    // the struct's own file — the method is already a
                    // plain LOCAL declaration there, not something to
                    // bridge as "imported" (bridging it would make
                    // `importer`'s own `collect()` try to read its OWN
                    // not-yet-populated `checked`/`compiled` results,
                    // `error.ImportNotChecked` — real crash found via
                    // the exact codegen-shaped 3-file test: связка.ps
                    // implements a qualified interface for точки.Точка,
                    // and ALSO gets imported directly by consumers of
                    // связка's own OTHER exports).
                    if (method.module == importer) continue;
                    try methods.append(allocator, .{
                        .name = method.name,
                        .module = method.module,
                        .declaration = method.declaration,
                        .span = method.span,
                    });
                }
                for (graph.variants.items) |variant| {
                    if (variant.module != target or variant.owner_declaration != exported.declaration) continue;
                    try variants.append(allocator, .{
                        .name = variant.name,
                        .span = variant.span,
                    });
                }
            }
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
                .methods = try arena.allocator().dupe(resolver.ImportedMethodExport, methods.items),
                .variants = try arena.allocator().dupe(resolver.ImportedVariantExport, variants.items),
            });
        }
        return arena.allocator().dupe(resolver.ImportedExport, exports.items);
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
