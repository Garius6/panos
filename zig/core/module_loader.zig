const std = @import("std");
const ast = @import("ast.zig");
const diagnostic = @import("diagnostic.zig");
const host_registry = @import("host_registry.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
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
    // Заполняется, когда `target == null`, потому что импорт разрешился
    // в нативный встроенный модуль (см. `resolveAndLoadImport`), а не
    // из-за ошибки — хранит РЕАЛЬНОЕ имя модуля (например,
    // "ввод_вывод"), которое может отличаться от `alias` (`импорт
    // "ввод_вывод" как ио`). `module_linker.zig` использует это поле,
    // чтобы связать алиас с экспортами нативного модуля, так же как для
    // обычного файлового таргета.
    native_module: ?[]const u8 = null,
};

// `экспорт "путь"` (стиль Dart `export`) — граф-ребро, ОТДЕЛЬНОЕ от
// обычного `Import`: не даёт `module` локального доступа к символам
// `target` (resolver.zig не должен предобъявлять их в области видимости
// `module`), но `module_linker.zig`'s `buildExportsForTarget` обходит
// эти рёбра ТРАНЗИТИВНО, чтобы вынести экспорты `target` наружу под
// собственными именами (плоско, без алиаса) для ЛЮБОГО модуля,
// импортирующего `module`.
pub const Reexport = struct {
    module: usize,
    declaration: ast.DeclId,
    target: ?usize,
    span: source.Span,
};

pub const ExportKind = enum {
    function,
    constant,
    type,
    // `экспорт внешний "хост" функ ...` — отдельный вид, не `.function`:
    // `внешний`-декларация никогда не компилируется в обычный байткод
    // (`function_id`), кросс-модульный импорт для неё мостит другие
    // данные (`resolver.Resolution.native_foreign_functions`/
    // `.foreign_functions`, сырые marshal-kind'ы параметров/возврата из
    // AST), см. `module_compiler.zig`'s `ImportContext.collect`.
    foreign_function,
};

pub const Export = struct {
    module: usize,
    declaration: ast.DeclId,
    name: []const u8,
    kind: ExportKind,
    span: source.Span,
};

// Методы, объявленные блоком `реализация Тип ... конец` в том же файле
// (обычным или интерфейсным) на экспортируемом типе-владельце — отдельно
// от `Export`, потому что метод никогда не достижим по квалифицированному
// имени (`модуль.метод`), только через диспетчеризацию на значении
// номинального типа владельца.
pub const MethodExport = struct {
    // Модуль, где ФИЗИЧЕСКИ написано тело этого метода (`функ`, файл
    // самого impl-блока) — используется, чтобы разыменовать
    // `.declaration` в реальный AST-узел/скомпилированный артефакт.
    module: usize,
    // Модуль, где объявлена ЦЕЛЕВАЯ структура/перечисление — обычно
    // совпадает с `module` (impl в том же файле или в файле
    // потребителя), но отличается для квалифицированного таргета,
    // объявленного в ТРЕТЬЕМ файле (`реализация X для Модуль.Тип`,
    // например сгенерированный кодогенератором `_gen.ps`). Используется
    // для сопоставления метода с ПРАВИЛЬНОЙ записью `Export` при
    // построении представления импорта у потребителя
    // (`buildExportsForTarget` в `module_linker.zig`) — сопоставление
    // по `module` там нашло бы только impl'ы в том же файле.
    owner_module: usize,
    owner_declaration: ast.DeclId,
    declaration: ast.DeclId,
    name: []const u8,
    span: source.Span,
};

// Варианты экспортируемого перечисления — конструирование/сопоставление
// целиком строится по имени во время компиляции (`enumVariantName` в
// `compiler.zig` строит "Owner.Variant" из собственного `.name` символа
// владельца), поэтому перенос declaration/FunctionId не нужен, только
// голое имя варианта.
pub const VariantExport = struct {
    module: usize,
    owner_declaration: ast.DeclId,
    name: []const u8,
    span: source.Span,
};

// Блок `реализация Интерфейс для Тип ... конец` в том же файле на
// экспортируемом типе-владельце — нужен отдельно от `MethodExport`, потому
// что диспетчеризация generic-параметров, связанных интерфейсом
// (`T: Сравниваемое`), требует самой записи `InterfaceImplementation`
// владельца, а не только её методов (их `MethodExport` уже покрывает как
// обычные методы).
pub const ImplExport = struct {
    // См. `MethodExport.module` — модуль, где написан сам блок
    // `реализация`.
    module: usize,
    // См. `MethodExport.owner_module` — модуль, объявляющий целевую
    // структуру/перечисление (может отличаться от `module` для
    // квалифицированного таргета в третьем файле).
    owner_module: usize,
    owner_declaration: ast.DeclId,
    interface_name: []const u8,
    // Не `null`, когда СТОРОНА ИНТЕРФЕЙСА тоже квалифицирована
    // (`реализация Модуль.Интерфейс для ...`, например `json.ВJSON` из
    // кодогенератора) — модуль/декларация, где сам интерфейс объявлен,
    // нужны `module_compiler.zig` для разрешения интерфейса в реальный
    // локальный символ в модуле-потребителе (поиск по голому имени его
    // не найдёт — у потребителя он в области видимости только как
    // `модуль.Интерфейс`, никогда неквалифицированно). `null` для
    // локального (неквалифицированного) имени интерфейса, разрешаемого
    // существующим способом (`findTypeSymbol` по голому имени).
    interface_module: ?usize = null,
    interface_declaration: ?ast.DeclId = null,
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
    reexports: std.ArrayList(Reexport) = .empty,
    exports: std.ArrayList(Export) = .empty,
    methods: std.ArrayList(MethodExport) = .empty,
    variants: std.ArrayList(VariantExport) = .empty,
    impls: std.ArrayList(ImplExport) = .empty,
    diagnostics: diagnostic.DiagnosticList = .{},
    // Директория из переменной окружения `PANOS_STDLIB` + `std/` рядом с
    // запущенным бинарником `panos`, в этом порядке приоритета,
    // проверяются ПОСЛЕ той же директории и `модули/` — задаётся
    // вызывающей стороной (`zig/cli/main.zig`) перед `.load()`, пустой по
    // умолчанию, чтобы все существующие тесты/вызовы с
    // synthetic-reader'ом сохраняли текущее поведение. Полный
    // 4-уровневый контракт поиска модулей документирован в
    // `docs/src/getting-started/installation.md` §"Поиск модулей".
    global_search_roots: []const []const u8 = &.{},
    // Зарегистрированные встраивающим Zig-приложением host-функции
    // (`panos.hostFunctions(...)`, specs/017-native-host-function-
    // registry) — задаётся `Runtime.init` (`zig/embed.zig`) перед
    // компиляцией, тем же паттерном, что `global_search_roots` выше.
    // Пусто по умолчанию — CLI/LSP/browser/тесты, ничего не встраивающие,
    // не затронуты. Прокидывается в `resolver.resolveModuleForTarget`
    // через `module_compiler.compileGraphForTarget`, без изменения их
    // публичных сигнатур (см. `host_registry.zig`).
    host_registry: []const host_registry.HostFunctionEntry = &.{},

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
        self.impls.deinit(self.allocator);
        self.variants.deinit(self.allocator);
        self.methods.deinit(self.allocator);
        self.exports.deinit(self.allocator);
        self.reexports.deinit(self.allocator);
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

    // Голые (без расширения) пути входной точки получают ту же
    // попытку `.pns`-затем-`.ps`, что и голые имена в `импорт`
    // (`appendCandidateBothSuffixes`) — иначе немигрированный
    // `.ps`-only проект, переданный как `panos run проект/main` (без
    // явного расширения), сразу упёрся бы в несуществующий `main.pns`.
    // Путь с явным расширением разрешается один раз, как есть.
    pub fn load(self: *Graph, reader: anytype, entry_path: []const u8) !void {
        if (hasKnownSourceExtension(entry_path)) {
            const canonical_path = try resolveImportPath(self.allocator, entry_path, "", ".pns");
            defer self.allocator.free(canonical_path);
            _ = try self.loadRecursive(reader, canonical_path, null);
            return;
        }

        const pns_path = try resolveImportPath(self.allocator, entry_path, "", ".pns");
        defer self.allocator.free(pns_path);
        if (self.tryLoadSilently(reader, pns_path, null)) |_| {
            return;
        } else |err| {
            if (err != error.FileNotFound) return err;
        }

        const ps_path = try resolveImportPath(self.allocator, entry_path, "", ".ps");
        defer self.allocator.free(ps_path);
        _ = try self.loadRecursive(reader, ps_path, null);
    }

    // Добавляет встроенный исходник прелюдии как модуль БЕЗ явного
    // `импорт` — берёт следующий свободный file_id, добавляется ПОСЛЕ
    // всех модулей, уже загруженных через `load()`, так что ожидания
    // `file_id` в диагностиках для реальных модулей никогда не
    // сдвигаются. Вставляется в начало `order` (не в конец), чтобы
    // компилироваться раньше любого реального модуля, который неявно от
    // него зависит. Переиспользует `collectExports`/`collectMethods`
    // так же, как для обычного файла, поэтому её типы/методы/интерфейсы
    // проходят через тот же межмодульный механизм — особый случай
    // только само слияние (неквалифицированное, без алиаса `импорт`) в
    // `module_linker.zig`.
    pub fn appendPreludeModule(self: *Graph, source_text: []const u8) !usize {
        const bytes = try self.allocator.dupe(u8, source_text);
        var owns_bytes = true;
        errdefer if (owns_bytes) self.allocator.free(bytes);

        if (self.modules.items.len > std.math.maxInt(source.FileId)) return error.ModuleLimitReached;
        const file_id: source.FileId = @intCast(self.modules.items.len);
        const stored_path = try self.arena.allocator().dupe(u8, "@prelude");
        const file = source.SourceFile.init(file_id, stored_path, bytes);

        var lexed = try lexer.tokenize(self.allocator, bytes, file_id);
        defer lexed.deinit();
        try self.appendDiagnostics(&lexed.diagnostics);

        var parsed = try parser.parse(self.allocator, lexed.tokens.items);
        errdefer parsed.deinit();
        try self.appendDiagnostics(&parsed.diagnostics);
        const tree = parsed.ast;
        parsed.ast = ast.Ast.init(self.allocator);
        parsed.deinit();
        owns_bytes = false;

        const index = self.modules.items.len;
        try self.modules.append(self.allocator, .{ .file = file, .tree = tree });
        try self.module_indices.put(stored_path, index);
        try self.collectExports(index);
        try self.collectMethods(index);
        try self.order.insert(self.allocator, 0, index);
        return index;
    }

    fn loadRecursive(self: *Graph, reader: anytype, path: []const u8, importer_span: ?source.Span) anyerror!?usize {
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
        return try self.registerModule(reader, path, bytes);
    }

    // То же, что `loadRecursive`, но ошибка чтения ПРОБРАСЫВАЕТСЯ, а не
    // репортится — используется только цепочкой фолбэков в
    // `resolveAndLoadImport`, которой нужно молча пробовать следующий
    // кандидат из корней поиска и репортить только когда провалились
    // ВСЕ кандидаты (или откатиться на нативный встроенный модуль, для
    // которого диагностика вообще не нужна). Циклический импорт всё
    // равно репортится прямо здесь — другой корень поиска не может
    // разрешить настоящий цикл, поэтому "следующего кандидата", который
    // бы помог, не существует.
    fn tryLoadSilently(self: *Graph, reader: anytype, path: []const u8, importer_span: ?source.Span) anyerror!?usize {
        if (self.loading.contains(path)) {
            try self.report(importer_span orelse .{ .file_id = 0, .start = 0, .end = 0 }, "Module Loader Error: обнаружен циклический импорт '{s}'", .{path});
            return null;
        }
        if (self.module_indices.get(path)) |existing| return existing;

        try self.loading.put(path, {});
        defer _ = self.loading.remove(path);

        const bytes = try reader.read(self.allocator, path);
        return try self.registerModule(reader, path, bytes);
    }

    // Лексинг/парсинг/регистрация модуля, чьи ИСХОДНЫЕ БАЙТЫ уже
    // прочитаны — общая для `loadRecursive` (входной файл, сам
    // репортит ошибку чтения) и `tryLoadSilently` (кандидаты фолбэка
    // импорта, ошибку чтения уже пробросил вызывающий код).
    // Рекурсивно обрабатывает СОБСТВЕННЫЕ импорты `path` через
    // `resolveAndLoadImport`, а не напрямую через
    // `loadRecursive`/`tryLoadSilently` — каждый вложенный импорт тоже
    // получает полный фолбэк по путям поиска, а не только прямые
    // импорты входного файла.
    fn registerModule(self: *Graph, reader: anytype, path: []const u8, bytes: []u8) anyerror!usize {
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
            switch (self.modules.items[index].tree.decl(declaration).*) {
                .import => |import| {
                    const resolved = try self.resolveAndLoadImport(reader, import.path, stored_path, import.span);
                    try self.imports.append(self.allocator, .{
                        .importer = index,
                        .declaration = declaration,
                        .target = resolved.target,
                        .alias = import.alias orelse moduleBaseName(import.path),
                        .span = import.span,
                        .native_module = resolved.native_module,
                    });
                },
                .reexport => |reexport| {
                    const resolved = try self.resolveAndLoadImport(reader, reexport.path, stored_path, reexport.span);
                    if (resolved.native_module != null) {
                        try self.report(reexport.span, "Module Loader Error: реэкспорт нативного встроенного модуля не поддержан", .{});
                    }
                    try self.reexports.append(self.allocator, .{
                        .module = index,
                        .declaration = declaration,
                        .target = resolved.target,
                        .span = reexport.span,
                    });
                },
                else => continue,
            }
        }
        // Должно выполняться ПОСЛЕ цикла импортов выше — квалифицированный
        // таргет impl'а (`реализация X для Модуль.Тип`) разрешает
        // `Модуль` через `self.imports`, где записи для СОБСТВЕННЫХ
        // импортов этого модуля появляются только после завершения того
        // цикла.
        try self.collectMethods(index);
        try self.order.append(self.allocator, index);
        return index;
    }

    // Документированный 4-уровневый поиск (`docs/src/getting-started/
    // installation.md` §"Поиск модулей"): та же директория, что у
    // импортёра, затем `модули/` рядом с импортёром, затем каждый из
    // `global_search_roots` по порядку (`$PANOS_STDLIB`, `std/` рядом с
    // бинарником `panos` — заполняется `zig/cli/main.zig`, пуст для
    // всех остальных вызывающих, что сохраняет их прежнее
    // одноуровневое поведение). Если файла нет НИ В ОДНОМ из этих мест
    // И голое имя импорта совпадает с зарегистрированным нативным
    // встроенным модулем (`resolver.native_builtin_modules` — тот же
    // список, что использует `installBuiltins`, поэтому они не могут
    // разойтись), это разрешается в `null` БЕЗ диагностики — модуль уже
    // амбиентно доступен без какого-либо файла, точно как если бы
    // `импорт` вообще не был написан. По-настоящему отсутствующий
    // модуль (не нативный, нигде не найден) репортит ТО ЖЕ сообщение
    // "FileNotFound", что и одноуровневая версия, для кандидата из той
    // же директории (чтобы существующие проверки текста диагностики
    // продолжали совпадать).
    const ImportResolution = struct { target: ?usize, native_module: ?[]const u8 = null };

    // Голые (без расширения) имена импорта пробуются сначала как
    // `.pns`, затем как `.ps` — толерантный к FileNotFound цикл
    // кандидатов в `resolveAndLoadImport` уже трактует "не найдено" как
    // "попробовать следующего кандидата", поэтому здесь переиспользуется
    // тот же механизм вместо отдельного второго прохода. Путь импорта с
    // уже явно указанным расширением разрешается один раз, как есть (за
    // явным `.pns`-импортом никогда не пробуется файл `.ps`, и
    // наоборот).
    fn appendCandidateBothSuffixes(self: *Graph, candidates: *std.ArrayList([]u8), raw_path: []const u8, importer_path: []const u8) !void {
        try candidates.append(self.allocator, try resolveImportPath(self.allocator, raw_path, importer_path, ".pns"));
        if (!hasKnownSourceExtension(raw_path)) {
            try candidates.append(self.allocator, try resolveImportPath(self.allocator, raw_path, importer_path, ".ps"));
        }
    }

    fn resolveAndLoadImport(self: *Graph, reader: anytype, raw_import_path: []const u8, importer_path: []const u8, importer_span: ?source.Span) anyerror!ImportResolution {
        var candidates: std.ArrayList([]u8) = .empty;
        defer {
            for (candidates.items) |candidate| self.allocator.free(candidate);
            candidates.deinit(self.allocator);
        }

        try self.appendCandidateBothSuffixes(&candidates, raw_import_path, importer_path);

        const importer_dir = moduleDirectory(importer_path);
        const modules_relative = if (importer_dir.len != 0)
            try std.fmt.allocPrint(self.allocator, "{s}/модули/{s}", .{ importer_dir, raw_import_path })
        else
            try std.fmt.allocPrint(self.allocator, "модули/{s}", .{raw_import_path});
        defer self.allocator.free(modules_relative);
        try self.appendCandidateBothSuffixes(&candidates, modules_relative, "");

        for (self.global_search_roots) |root| {
            const combined = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ root, raw_import_path });
            defer self.allocator.free(combined);
            try self.appendCandidateBothSuffixes(&candidates, combined, "");
        }

        for (candidates.items) |candidate| {
            if (self.tryLoadSilently(reader, candidate, importer_span)) |result| {
                return .{ .target = result };
            } else |err| {
                if (err != error.FileNotFound) return err;
            }
        }

        if (isBareModuleName(raw_import_path) and isNativeBuiltinModule(raw_import_path)) {
            return .{ .target = null, .native_module = try self.arena.allocator().dupe(u8, raw_import_path) };
        }

        try self.report(importer_span orelse .{ .file_id = 0, .start = 0, .end = 0 }, "Module Loader Error: не удалось загрузить модуль '{s}': FileNotFound", .{candidates.items[0]});
        return .{ .target = null };
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
                .enum_decl => |value| if (value.is_exported) blk: {
                    for (value.variants) |variant| {
                        try self.variants.append(self.allocator, .{
                            .module = module,
                            .owner_declaration = declaration,
                            .name = variant.name,
                            .span = variant.span,
                        });
                    }
                    break :blk .{
                        .module = module,
                        .declaration = declaration,
                        .name = value.name,
                        .kind = .type,
                        .span = value.span,
                    };
                } else null,
                .type_alias => |value| if (value.is_exported) .{
                    .module = module,
                    .declaration = declaration,
                    .name = value.name,
                    .kind = .type,
                    .span = value.span,
                } else null,
                .foreign => |value| if (value.is_exported) .{
                    .module = module,
                    .declaration = declaration,
                    .name = value.name,
                    .kind = .foreign_function,
                    .span = value.span,
                } else null,
                else => null,
            };
            if (entry) |value| try self.exports.append(self.allocator, value);
        }
    }

    // Impl-блоки в том же файле (обычные ИЛИ интерфейсные) на
    // экспортируемом типе-владельце: методы достижимы между модулями
    // через диспетчеризацию на значении владельца, никогда по
    // квалифицированному имени, поэтому они никогда не попадают в
    // `exports` — только в `methods`. Методы интерфейсных impl'ов —
    // тоже обычные собственные методы (`defineMethodSignature`/
    // `self.result.methods` в type_checker.zig их не различает),
    // поэтому собираются здесь так же. Также записывает `ImplExport`
    // для impl'ов на основе интерфейса — нужно отдельно для
    // межмодульной диспетчеризации generic-параметров, связанных
    // интерфейсом (`T: Сравниваемое`).
    fn collectMethods(self: *Graph, module: usize) !void {
        const tree = &self.modules.items[module].tree;
        for (tree.program.?.declarations) |declaration| {
            const implementation = switch (tree.decl(declaration).*) {
                .impl => |value| value,
                else => continue,
            };
            // Квалифицированный таргет (`реализация X для Модуль.Тип`)
            // означает, что структура живёт в ДРУГОМ модуле — разрешаем
            // этот алиас через собственную таблицу импортов текущего
            // модуля (заполняется вызывающей стороной до запуска
            // `collectMethods`, см. `registerModule`/
            // `appendPreludeModule`), чтобы найти, в каком модуле искать
            // экспортируемую декларацию. Неразрешимый алиас (опечатка,
            // нативный встроенный таргет и т.п.) молча пропускает этот
            // impl — так же, как неквалифицированный случай ниже
            // (`orelse continue`).
            const owner_lookup_module = if (implementation.target_module) |alias|
                self.resolveImportedModule(module, alias) orelse continue
            else
                module;
            const owner_location = self.findExportedTypeDeclaration(owner_lookup_module, implementation.target_type) orelse continue;
            const owner_module = owner_location.module;
            const owner_declaration = owner_location.declaration;
            for (implementation.methods) |method_declaration| {
                const function = tree.decl(method_declaration).function;
                try self.methods.append(self.allocator, .{
                    .module = module,
                    .owner_module = owner_module,
                    .owner_declaration = owner_declaration,
                    .declaration = method_declaration,
                    .name = function.name,
                    .span = function.span,
                });
            }
            if (implementation.interface_name) |interface_name| {
                // То же разрешение алиаса, что и для таргета выше, для
                // квалифицированного интерфейса (`реализация
                // Модуль.Интерфейс для ...`, например `json.ВJSON` из
                // кодогенератора) — `null` в module/declaration
                // интерфейса означает существующий путь по локальному
                // имени.
                var interface_module: ?usize = null;
                var interface_declaration: ?ast.DeclId = null;
                if (implementation.interface_module) |alias| {
                    const resolved = self.resolveImportedModule(module, alias) orelse continue;
                    const interface_location = self.findExportedTypeDeclaration(resolved, interface_name) orelse continue;
                    interface_module = interface_location.module;
                    interface_declaration = interface_location.declaration;
                }
                try self.impls.append(self.allocator, .{
                    .module = module,
                    .owner_module = owner_module,
                    .owner_declaration = owner_declaration,
                    .interface_name = interface_name,
                    .interface_module = interface_module,
                    .interface_declaration = interface_declaration,
                    .span = implementation.span,
                });
            }
        }
    }

    // Разрешает АЛИАС импорта (как он написан в исходнике `module`,
    // например `"точки"` из `импорт "./точки" как точки`) в индекс
    // целевого модуля, сканируя `self.imports` — заполняется
    // СОБСТВЕННЫМИ прямыми импортами модуля до запуска на нём
    // `collectMethods` (см. места вызова). Возвращает `null` для
    // неразрешимого алиаса (опечатка) или нативного импорта
    // (`.target == null`) — квалифицированный таргет impl'а может быть
    // только реальным файловым модулем.
    fn resolveImportedModule(self: *const Graph, module: usize, alias: []const u8) ?usize {
        for (self.imports.items) |import| {
            if (import.importer == module and std.mem.eql(u8, import.alias, alias)) return import.target;
        }
        return null;
    }

    pub const ExportedTypeLocation = struct { module: usize, declaration: ast.DeclId };

    // `module` — квалифицирующий алиас, разрешённый вызывающей стороной
    // (`реализация X для Модуль.Тип`/`реализация Модуль.Интерфейс для
    // ...`) — может оказаться barrel-файлом (`экспорт "путь"`, только
    // реэкспорты, ни одной собственной декларации), а не модулем, где
    // ТИП/ИНТЕРФЕЙС физически объявлен. Возвращаемый `.module` —
    // ФИЗИЧЕСКИЙ модуль declaration (для реэкспортированного случая —
    // НЕ совпадает с переданным `module`), нужен вызывающей стороне
    // (`owner_module`/`interface_module` в graph.impls/graph.methods)
    // именно физический, а не barrel — иначе последующий поиск методов/
    // полей в `modules[barrel].checked` находит пустоту (barrel не
    // содержит проверенных деклараций, только реэкспорт-рёбра).
    // `visited` — защита от цикла, тот же приём, что
    // `buildExportsForTargetTransitive` в module_linker.zig.
    fn findExportedTypeDeclaration(self: *const Graph, module: usize, name: []const u8) ?ExportedTypeLocation {
        var visited: std.AutoHashMap(usize, void) = .init(self.allocator);
        defer visited.deinit();
        return self.findExportedTypeDeclarationTransitive(module, name, &visited);
    }

    fn findExportedTypeDeclarationTransitive(self: *const Graph, module: usize, name: []const u8, visited: *std.AutoHashMap(usize, void)) ?ExportedTypeLocation {
        if (visited.contains(module)) return null;
        visited.put(module, {}) catch return null;
        for (self.exports.items) |exported| {
            if (exported.module != module or exported.kind != .type) continue;
            if (std.mem.eql(u8, exported.name, name)) return .{ .module = module, .declaration = exported.declaration };
        }
        for (self.reexports.items) |reexport| {
            if (reexport.module != module) continue;
            const target = reexport.target orelse continue;
            if (self.findExportedTypeDeclarationTransitive(target, name, visited)) |found| return found;
        }
        return null;
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

// `.pns` — основное расширение исходников; `.ps` принимается постоянно
// ради обратной совместимости (немигрированные файлы, непортированные
// пакеты panosiki) — GitHub Linguist ошибочно классифицирует `.ps` как
// PostScript, `.pns` ни с одним зарегистрированным языком не
// конфликтует. Путь импорта, уже явно называющий любое из расширений,
// никогда не получает второй суффикс; `preferred_suffix` применяется
// только к голым именам (`импорт "модуль"`).
fn hasKnownSourceExtension(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".ps") or std.mem.endsWith(u8, path, ".pns");
}

pub fn resolveImportPath(allocator: std.mem.Allocator, import_path: []const u8, importer_path: []const u8, preferred_suffix: []const u8) ![]u8 {
    const suffixed = if (hasKnownSourceExtension(import_path))
        import_path
    else
        try std.fmt.allocPrint(allocator, "{s}{s}", .{ import_path, preferred_suffix });
    defer if (suffixed.ptr != import_path.ptr) allocator.free(suffixed);

    const combined = if (isAbsolute(suffixed) or importer_path.len == 0) suffixed else blk: {
        const directory = moduleDirectory(importer_path);
        if (directory.len == 0) break :blk suffixed;
        break :blk try std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, suffixed });
    };
    defer if (combined.ptr != suffixed.ptr) allocator.free(combined);
    return normalizePath(allocator, combined);
}

fn isBareModuleName(path: []const u8) bool {
    return std.mem.indexOfScalar(u8, path, '/') == null;
}

fn isNativeBuiltinModule(name: []const u8) bool {
    for (resolver.native_builtin_modules) |native| {
        if (std.mem.eql(u8, name, native)) return true;
    }
    return false;
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
    if (std.mem.endsWith(u8, file_name, ".pns")) return file_name[0 .. file_name.len - 4];
    if (std.mem.endsWith(u8, file_name, ".ps")) return file_name[0 .. file_name.len - 3];
    return file_name;
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

test "module loader collects methods only for an exported same-file impl owner" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "экспорт функ старт() -> Число\n1\nконец" },
        .{ .path = "проект/точки.ps", .bytes = "экспорт тип Точка = структура\nx: Число\nконец\nтип Скрытая = структура\ny: Число\nконец\nреализация Точка\nфунк увеличить(это: Точка) -> Число\nэто.x + 1\nконец\nконец\nреализация Скрытая\nфунк читать(это: Скрытая) -> Число\nэто.y\nконец\nконец" },
    } };
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");
    try graph.load(&reader, "проект/точки");

    try std.testing.expectEqual(@as(usize, 1), graph.methods.items.len);
    try std.testing.expectEqualStrings("увеличить", graph.methods.items[0].name);
}

test "module loader collects variants only for an exported enum type" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "экспорт функ старт() -> Число\n1\nконец" },
        .{ .path = "проект/цвета.ps", .bytes = "экспорт тип Цвет = перечисление\nКрасный\nЗелёный\nконец\nтип Скрытый = перечисление\nОдин\nконец" },
    } };
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");
    try graph.load(&reader, "проект/цвета");

    try std.testing.expectEqual(@as(usize, 2), graph.variants.items.len);
    try std.testing.expectEqualStrings("Красный", graph.variants.items[0].name);
    try std.testing.expectEqualStrings("Зелёный", graph.variants.items[1].name);
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
    try std.testing.expectEqualStrings("Module Loader Error: не удалось загрузить модуль 'проект/нет.pns': FileNotFound", graph.diagnostics.items.items[0].message);
    try std.testing.expectEqual(@as(source.FileId, 0), graph.diagnostics.items.items[0].span.file_id);
}

test "module loader normalizes relative import paths" {
    const path = try resolveImportPath(std.testing.allocator, "./детали/../математика", "проект/main.ps", ".ps");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("проект/математика.ps", path);
}

test "module loader normalizes relative import paths with .pns suffix" {
    const path = try resolveImportPath(std.testing.allocator, "./детали/../математика", "проект/main.pns", ".pns");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("проект/математика.pns", path);
}

test "module loader appends a prelude module after real modules without shifting their file_ids" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "экспорт функ старт() -> Число\n1\nконец" },
    } };
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");
    try std.testing.expectEqual(@as(usize, 1), graph.modules.items.len);

    const prelude_index = try graph.appendPreludeModule("экспорт тип Штука = структура\nx: Число\nконец");
    try std.testing.expectEqual(@as(usize, 1), prelude_index);
    try std.testing.expectEqual(@as(usize, 2), graph.modules.items.len);
    try std.testing.expectEqual(@as(source.FileId, 0), graph.modules.items[0].file.id);
    try std.testing.expectEqual(@as(source.FileId, 1), graph.modules.items[1].file.id);
    try std.testing.expectEqual(@as(usize, 2), graph.order.items.len);
    try std.testing.expectEqual(prelude_index, graph.order.items[0]);
    try std.testing.expectEqual(@as(usize, 0), graph.order.items[1]);
}
