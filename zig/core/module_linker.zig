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

    // `prelude_module`, если задан и не совпадает с самим импортёром,
    // сливается как НЕКВАЛИФИЦИРОВАННЫЙ неявный импорт (без `импорт`/
    // алиаса) перед собственными явными импортами импортёра — см.
    // `predeclareUnqualifiedImports` в `resolver.zig`.
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
                // Импорт нативного модуля с алиасом (`импорт "ввод_вывод"
                // как ио`) — `target == null` здесь не значит "не удалось
                // загрузить" (этот случай уже обрабатывает диагностика в
                // module_loader.zig), это значит "разрешился амбиентно,
                // без файла вообще".
                const native_name = import.native_module orelse continue;
                // Голый импорт нативного модуля без алиаса (`импорт
                // время`) — реальное имя УЖЕ глобально амбиентно
                // (`installBuiltins` в resolver.zig), предобъявление
                // ВТОРОГО символа модуля `время` здесь просто
                // столкнётся с ним (`Resolve Error: символ 'время' уже
                // объявлен`). Что-то строить здесь нужно только при
                // настоящем переименовании (`как ...`).
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
        var visited: std.AutoHashMap(usize, void) = .init(allocator);
        defer visited.deinit();
        return buildExportsForTargetTransitive(allocator, arena, graph, target, importer, &visited);
    }

    // `экспорт "путь"` (Dart-style реэкспорт, `graph.reexports`) — рёбра
    // модуля `target`, помеченные как реэкспорт, ТОЖЕ вносят свой вклад
    // в набор экспортов, видимых под алиасом `target` для `importer`,
    // ПОД РОДНЫМИ ИМЕНАМИ реэкспортированного модуля, плоско (не через
    // вложенный псевдоним) — рекурсивно, реэкспорт реэкспорта тоже
    // работает. `visited` — защита от цикла (А реэкспортирует Б
    // реэкспортирует А); первое посещение модуля молча выигрывает при
    // конфликте имён между несколькими реэкспортами (не проверяется
    // отдельно — тот же уровень строгости, что резолвер уже применяет к
    // обычным столкновениям имён символов).
    fn buildExportsForTargetTransitive(allocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator, graph: *const module_loader.Graph, target: usize, importer: usize, visited: *std.AutoHashMap(usize, void)) anyerror![]const resolver.ImportedExport {
        if (visited.contains(target)) return &.{};
        try visited.put(target, {});
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
                    // Impl с квалифицированным таргетом, объявленный в
                    // ЭТОМ ЖЕ модуле (`importer`), который к тому же
                    // импортирует файл самой структуры — метод там уже
                    // обычная ЛОКАЛЬНАЯ декларация, мостить его как
                    // "импортированный" не нужно (иначе собственный
                    // `collect()` импортёра попытается прочитать свои же
                    // ещё не заполненные результаты `checked`/`compiled`,
                    // `error.ImportNotChecked`).
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
                    // Символ импортированной `внешний`-функции регистрируется
                    // как обычная функция (`resolver.zig`'s `predeclare`
                    // тоже регистрирует ЛОКАЛЬНУЮ `внешний`-декларацию как
                    // `.function` symbols.SymbolKind) — вызывающий код на
                    // стороне выражения не должен отличать импортированный
                    // `внешний` от обычной функции.
                    .foreign_function => .function,
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
        for (graph.reexports.items) |reexport| {
            if (reexport.module != target) continue;
            const reexported_target = reexport.target orelse continue;
            const transitive = try buildExportsForTargetTransitive(allocator, arena, graph, reexported_target, importer, visited);
            try exports.appendSlice(allocator, transitive);
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
