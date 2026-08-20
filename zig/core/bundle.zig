const std = @import("std");
const ast = @import("ast.zig");
const module_loader = @import("module_loader.zig");
const resolver = @import("resolver.zig");

// Поддержка `panos build --compile` (автономный исполняемый файл в духе Bun).
//
// Дизайн: встраивается ИСХОДНЫЙ КОД (замыкание зависимостей
// `module_loader.Graph` — каждый реально достигнутый `.pns`-файл, включая
// используемые модули `std/`), а не скомпилированная `bytecode.Program` —
// эта структура целиком построена на указателях (`ArrayList`/арена/срезы,
// см. её собственные doc-комментарии), формата сериализации для неё в
// кодовой базе нет, а сырой указатель на функцию `внешний`
// (`bytecode.Constant.foreign_function.fn_ptr`) в принципе не переживёт
// сериализацию между запусками процесса (адреса не стабильны между
// запусками) — так что встраивание байткода всё равно не решило бы FFI,
// а это как раз то, что требуется. Вместо этого автономный исполняемый файл
// несёт с собой собственный исходный код и байты библиотек `внешний` и
// перекомпилируется при каждом запуске, повторно используя без изменений
// обычный конвейер `module_loader.Graph`/`module_compiler.compileGraph`/
// `vm.Vm` — несколько миллисекунд дополнительного времени запуска для
// типичной программы взамен на отсутствие новой поверхности сериализации.
//
// Записи бандла адресуются путём ОТНОСИТЕЛЬНО СОБСТВЕННОЙ ДИРЕКТОРИИ
// ВХОДНОГО МОДУЛЯ (`std.fs.path.relative`, включая сегменты `..` там, где
// файл — например, модуль `$PANOS_STDLIB` — лежит вне этой директории). Во
// время выполнения весь бандл читается прямо из памяти через
// `BundleReader` (тот же самый duck-typed интерфейс `reader`, который уже
// принимает `module_loader.Graph.load` — реальная временная директория для
// содержимого `.pns` не нужна, см. doc-комментарий самого `BundleReader`) —
// реальная временная директория создаётся только если в бандле есть хотя
// бы одна запись библиотеки `внешний`, поскольку `dlopen`/`LoadLibraryW`
// принципиально нуждаются в реальном файле на диске.

pub const bundle_magic: [8]u8 = "PANOSBDL".*;
pub const trailer_magic: [8]u8 = "PANOSFAT".*;
pub const format_version: u32 = 1;

pub const Entry = struct {
    // Относительно корня бандла (собственной директории входного модуля
    // на момент сборки) — может начинаться с "../" для файла вне неё.
    path: []const u8,
    content: []const u8,
    // Байты библиотеки `внешний` (должны оказаться на РЕАЛЬНОМ диске во
    // время выполнения — `dlopen` нужен путь) в противовес исходнику
    // `.pns` (отдаётся прямо из памяти через `BundleReader`, диска не
    // касается).
    is_library: bool,
};

pub const Bundle = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    entry_path: []const u8,
    entries: []const Entry,

    pub fn deinit(self: *Bundle) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn find(self: *const Bundle, relative_path: []const u8) ?[]const u8 {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.path, relative_path)) return entry.content;
        }
        return null;
    }

    pub fn hasLibraries(self: *const Bundle) bool {
        for (self.entries) |entry| if (entry.is_library) return true;
        return false;
    }
};

// Обходит каждый модуль, уже разрешённый `graph.load` (собственное
// замыкание зависимостей входного файла — локальные `импорт`ы и модули
// `std/` вместе, именно то, что нужно реальной сборке), плюс каждое
// достижимое из них путевое объявление `внешний "./lib.so"` (объявление
// `внешний "libname"` с голым именем, разрешаемое через собственный путь
// поиска загрузчика ОС, НЕ встраивается — ограничение v1: остаётся
// системной зависимостью времени выполнения точно так же, как и при
// обычном запуске `panos <file>`).
pub fn collect(allocator: std.mem.Allocator, io: std.Io, graph: *const module_loader.Graph, search_roots: []const []const u8) !Bundle {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    // Модуль 0 — всегда входной модуль (собственный инвариант
    // `module_loader.zig` — `Graph.load` добавляет его первым, до любого
    // импорта).
    const entry_module_path = graph.modules.items[0].file.path;
    const root_dir = std.fs.path.dirname(entry_module_path) orelse ".";
    const entry_relative = try bundleKey(arena_allocator, root_dir, search_roots, entry_module_path);

    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(allocator);

    for (graph.modules.items) |module| {
        const relative = try bundleKey(arena_allocator, root_dir, search_roots, module.file.path);
        try entries.append(allocator, .{
            .path = relative,
            .content = try arena_allocator.dupe(u8, module.file.bytes),
            .is_library = false,
        });

        const tree = &module.tree;
        const declarations = (tree.program orelse continue).declarations;
        for (declarations) |decl_id| {
            const foreign = switch (tree.decl(decl_id).*) {
                .foreign => |value| value,
                else => continue,
            };
            // Голое логическое имя (без '/') — разрешается через
            // собственный путь поиска загрузчика ОС, а не как файл
            // относительно проекта; встраивать нечего (см. doc-комментарий
            // модуля).
            if (std.mem.indexOfScalar(u8, foreign.library, '/') == null) continue;

            const library_path = try resolver.resolveForeignLibraryPath(allocator, module.file.path, foreign.library);
            defer allocator.free(library_path);
            const library_bytes = std.Io.Dir.cwd().readFileAlloc(io, library_path, allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
                // Пусть об этом как следует, с правильным span/диагностикой,
                // сообщит ОБЫЧНЫЙ путь компиляции (который реально
                // разрешает `внешний`, `resolver.zig:resolveForeignFunction`)
                // — этот проход сборки бандла выполняется ДО тайпчека, так
                // что сам не может отличить "реально отсутствует" от
                // "вот-вот будет сообщено", и не должен дублировать эту
                // диагностику.
                else => continue,
            };
            defer allocator.free(library_bytes);
            const library_relative = try bundleKey(arena_allocator, root_dir, search_roots, library_path);
            // Библиотека, на которую ссылаются из более чем одного модуля
            // (или из одного модуля дважды) — дедуплицируется по
            // относительному пути, чтобы бандл не нёс дублирующиеся
            // многомегабайтные копии.
            var already_present = false;
            for (entries.items) |entry| {
                if (entry.is_library and std.mem.eql(u8, entry.path, library_relative)) {
                    already_present = true;
                    break;
                }
            }
            if (already_present) continue;
            try entries.append(allocator, .{
                .path = library_relative,
                .content = try arena_allocator.dupe(u8, library_bytes),
                .is_library = true,
            });
        }
    }

    return .{
        .allocator = allocator,
        .arena = arena,
        .entry_path = entry_relative,
        .entries = try arena_allocator.dupe(Entry, entries.items),
    };
}

// Модуль, разрешённый через `global_search_root` времени сборки
// (`$PANOS_STDLIB` или `std/` относительно исполняемого файла — импорты с
// голым именем вроде `импорт математика`), НЕ МОЖЕТ переиспользовать
// `relativize`-относительно-собственной-директории-входного-модуля так,
// как это делает обычный локальный файл `импорт "./x"`: во ВРЕМЯ
// ВЫПОЛНЕНИЯ у автономного бинарника НЕТ реального `$PANOS_STDLIB` (в этом
// и весь смысл — не нуждаться в нём), так что поиск кандидатов с голым
// именем в `module_loader.zig` (который перебирает по очереди каждую
// запись `global_search_roots`) не с чем сопоставлять, если только
// `runFatBinary` (`zig/cli/main.zig`) не подставит СИНТЕТИЧЕСКИЙ корень,
// указывающий на `<temp_root>/std`. Поэтому любой модуль, чей реальный
// (времени сборки) путь попадает ПОД один из `search_roots`, получает
// ключ, пространство имён которого — `"std/"` (часть пути ПОСЛЕ
// совпавшего корня), вместо пути относительно входного модуля —
// `runFatBinary` выставляет свой собственный (единственный,
// синтетический) `global_search_roots = &.{temp_root ++ "/std"}` именно
// под это: собственное построение кандидатов в `module_loader` естественно
// порождает `<temp_root>/std/<name>.pns`, `BundleReader` отрезает префикс
// `<temp_root>/`, и остаток (`"std/<name>.pns"`) — РОВНО этот ключ.
fn bundleKey(allocator: std.mem.Allocator, root_dir: []const u8, search_roots: []const []const u8, path: []const u8) ![]const u8 {
    for (search_roots) |root| {
        if (root.len == 0) continue;
        if (std.mem.startsWith(u8, path, root) and path.len > root.len and path[root.len] == '/') {
            return std.fmt.allocPrint(allocator, "std/{s}", .{path[root.len + 1 ..]});
        }
    }
    return relativize(allocator, root_dir, path);
}

fn pathComponents(allocator: std.mem.Allocator, path: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |part| try list.append(allocator, part);
    return list.toOwnedSlice(allocator);
}

// Намеренно НЕ `std.fs.path.relative` — этой функции для начала нужен
// РЕАЛЬНЫЙ CWD процесса, чтобы сделать относительные `from`/`to`
// абсолютными (в этой версии Zig нет дешёвого способа его получить через
// `Io`-based API `process`/`Dir`). `from`/`to` здесь всегда приходят из
// ОДНОГО И ТОГО ЖЕ `module_loader.Graph` (оба либо согласованно
// относительны реальному CWD, либо оба абсолютны) — чисто покомпонентное
// сравнение строк не нуждается в CWD вообще и полностью детерминировано
// при этом инварианте.
fn relativize(allocator: std.mem.Allocator, from_dir: []const u8, to: []const u8) ![]const u8 {
    if (from_dir.len == 0 or std.mem.eql(u8, from_dir, ".")) return allocator.dupe(u8, to);

    const from_parts = try pathComponents(allocator, from_dir);
    defer allocator.free(from_parts);
    const to_parts = try pathComponents(allocator, to);
    defer allocator.free(to_parts);

    var common: usize = 0;
    while (common < from_parts.len and common < to_parts.len and std.mem.eql(u8, from_parts[common], to_parts[common])) common += 1;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var i: usize = common;
    while (i < from_parts.len) : (i += 1) try out.appendSlice(allocator, "../");
    i = common;
    while (i < to_parts.len) : (i += 1) {
        try out.appendSlice(allocator, to_parts[i]);
        if (i + 1 < to_parts.len) try out.append(allocator, '/');
    }
    return out.toOwnedSlice(allocator);
}

fn appendU32(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try out.appendSlice(allocator, &bytes);
}

fn appendU64(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    try out.appendSlice(allocator, &bytes);
}

fn appendBlob(allocator: std.mem.Allocator, out: *std.ArrayList(u8), blob: []const u8) !void {
    try appendU64(allocator, out, blob.len);
    try out.appendSlice(allocator, blob);
}

fn appendString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try appendU32(allocator, out, @intCast(text.len));
    try out.appendSlice(allocator, text);
}

// Сериализует ТОЛЬКО полезную нагрузку бандла (без трейлера/длины/магии —
// framing уровня исполняемого файла, оборачивающий это, см. `appendTrailer`).
pub fn serialize(allocator: std.mem.Allocator, bundle: *const Bundle) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &bundle_magic);
    try appendU32(allocator, &out, format_version);
    try appendString(allocator, &out, bundle.entry_path);
    try appendU32(allocator, &out, @intCast(bundle.entries.len));
    for (bundle.entries) |entry| {
        try appendString(allocator, &out, entry.path);
        try out.append(allocator, if (entry.is_library) 1 else 0);
        try appendBlob(allocator, &out, entry.content);
    }
    return out.toOwnedSlice(allocator);
}

const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Cursor, n: usize) ![]const u8 {
        if (self.pos + n > self.bytes.len) return error.InvalidBundle;
        const slice = self.bytes[self.pos..][0..n];
        self.pos += n;
        return slice;
    }

    fn readU32(self: *Cursor) !u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .little);
    }

    fn readU64(self: *Cursor) !u64 {
        return std.mem.readInt(u64, (try self.take(8))[0..8], .little);
    }

    fn readByte(self: *Cursor) !u8 {
        return (try self.take(1))[0];
    }

    fn readString(self: *Cursor, allocator: std.mem.Allocator) ![]const u8 {
        const len = try self.readU32();
        return allocator.dupe(u8, try self.take(len));
    }

    fn readBlob(self: *Cursor, allocator: std.mem.Allocator) ![]const u8 {
        const len = try self.readU64();
        if (len > std.math.maxInt(usize)) return error.InvalidBundle;
        return allocator.dupe(u8, try self.take(@intCast(len)));
    }
};

pub fn deserialize(allocator: std.mem.Allocator, bytes: []const u8) !Bundle {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    var cursor = Cursor{ .bytes = bytes };
    const magic = try cursor.take(8);
    if (!std.mem.eql(u8, magic, &bundle_magic)) return error.InvalidBundle;
    const version = try cursor.readU32();
    if (version != format_version) return error.UnsupportedBundleVersion;
    const entry_path = try cursor.readString(arena_allocator);
    const count = try cursor.readU32();
    const entries = try arena_allocator.alloc(Entry, count);
    for (entries) |*entry| {
        entry.path = try cursor.readString(arena_allocator);
        entry.is_library = (try cursor.readByte()) != 0;
        entry.content = try cursor.readBlob(arena_allocator);
    }

    return .{
        .allocator = allocator,
        .arena = arena,
        .entry_path = entry_path,
        .entries = entries,
    };
}

// Оборачивает сериализованный бандл в framing трейлера, дописываемый к
// копии исполняемого файла `panos`: `[базовый бинарник][бандл][u64 длина
// бандла]["PANOSFAT"]`. `readTrailer` ниже — точная обратная операция.
pub fn appendTrailer(allocator: std.mem.Allocator, base_binary: []const u8, bundle_bytes: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, base_binary.len + bundle_bytes.len + 16);
    errdefer allocator.free(out);
    @memcpy(out[0..base_binary.len], base_binary);
    @memcpy(out[base_binary.len..][0..bundle_bytes.len], bundle_bytes);
    var length_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &length_bytes, bundle_bytes.len, .little);
    @memcpy(out[base_binary.len + bundle_bytes.len ..][0..8], &length_bytes);
    @memcpy(out[out.len - 8 ..], &trailer_magic);
    return out;
}

// Сначала читает ТОЛЬКО последние 16 байт (магия + длина) — обычный,
// подавляюще частый случай (ОБЫЧНЫЙ запуск `panos <file>`, реальный
// бинарник `panos` вовсе без трейлера) должен оставаться дешёвым: одно
// маленькое позиционное чтение, а не загрузка мегабайт кода самого
// бинарника в память на каждый запуск. Только когда магия действительно
// совпадает, читается (гораздо меньшая) полезная нагрузка бандла.
pub fn readTrailer(io: std.Io, allocator: std.mem.Allocator, exe_path: []const u8) !?[]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, exe_path, .{});
    defer file.close(io);
    const size = try file.length(io);
    if (size < 16) return null;
    var tail: [16]u8 = undefined;
    _ = try file.readPositionalAll(io, &tail, size - 16);
    if (!std.mem.eql(u8, tail[8..16], &trailer_magic)) return null;
    const bundle_len = std.mem.readInt(u64, tail[0..8], .little);
    if (bundle_len == 0 or bundle_len > size - 16) return null;
    const bundle_bytes = try allocator.alloc(u8, bundle_len);
    errdefer allocator.free(bundle_bytes);
    _ = try file.readPositionalAll(io, bundle_bytes, size - 16 - bundle_len);
    return bundle_bytes;
}

// Реализация duck-typed интерфейса `reader` из `module_loader.Graph.load`
// для графа, опирающегося на бандл — содержимое `.pns` отдаётся прямо из
// `Bundle` в памяти, диска не касаясь. `temp_root` — ТОТ ЖЕ префикс, что
// использован для построения `entry_path` для `graph.load` (см. путь
// запуска fat-binary в `zig/cli/main.zig`) — каждый путь импорта, который
// выводит `module_loader.zig`, строится присоединением к `entry_path`, так
// что все они автоматически остаются с префиксом `temp_root`; этот reader
// просто отрезает этот префикс обратно, чтобы найти соответствующую
// запись бандла. Записи библиотек `внешний` через этот reader вообще НЕ
// отдаются — они записываются в реальные файлы под `temp_root` ДО запуска
// `graph.load`, так что немодифицированное разрешение через `dlopen` в
// `resolver.zig` находит их прямо на диске (см. doc-комментарий модуля).
pub const BundleReader = struct {
    bundle: *const Bundle,
    temp_root: []const u8,

    pub fn read(self: *const BundleReader, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const prefix_len = self.temp_root.len + 1; // + '/'
        if (path.len <= prefix_len or !std.mem.startsWith(u8, path, self.temp_root) or path[self.temp_root.len] != '/') {
            return error.FileNotFound;
        }
        const relative = path[prefix_len..];
        const content = self.bundle.find(relative) orelse return error.FileNotFound;
        return allocator.dupe(u8, content);
    }
};

test "bundle round-trips through serialize/deserialize" {
    const allocator = std.testing.allocator;
    // `serialize` читает только `.entry_path`/`.entries` — `.arena` не
    // используется для Bundle, построенного напрямую из литералов (через
    // неё ничего не аллоцируется), так что освобождать здесь нечего.
    const bundle = Bundle{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .entry_path = "main.pns",
        .entries = &.{
            .{ .path = "main.pns", .content = "экспорт функ старт() -> Число\n42.0\nконец", .is_library = false },
            .{ .path = "libs/foo.so", .content = "\x7fELFbinary", .is_library = true },
        },
    };
    const bytes = try serialize(allocator, &bundle);
    defer allocator.free(bytes);

    var decoded = try deserialize(allocator, bytes);
    defer decoded.deinit();
    try std.testing.expectEqualStrings("main.pns", decoded.entry_path);
    try std.testing.expectEqual(@as(usize, 2), decoded.entries.len);
    try std.testing.expectEqualStrings("экспорт функ старт() -> Число\n42.0\nконец", decoded.find("main.pns").?);
    try std.testing.expectEqualStrings("\x7fELFbinary", decoded.find("libs/foo.so").?);
    try std.testing.expect(decoded.hasLibraries());
}

test "appendTrailer/readTrailer round-trip" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{});
    defer io.deinit();

    const base = "fake-binary-bytes";
    const bundle_bytes = "fake-bundle-payload";
    const combined = try appendTrailer(allocator, base, bundle_bytes);
    defer allocator.free(combined);

    const path = "zzz_bundle_trailer_probe.tmp";
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = path, .data = combined });
    defer std.Io.Dir.cwd().deleteFile(io.io(), path) catch {};

    const read_back = try readTrailer(io.io(), allocator, path);
    defer if (read_back) |bytes| allocator.free(bytes);
    try std.testing.expect(read_back != null);
    try std.testing.expectEqualStrings(bundle_bytes, read_back.?);
}

test "readTrailer returns null for a file with no trailer" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{});
    defer io.deinit();

    const path = "zzz_bundle_no_trailer_probe.tmp";
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = path, .data = "just an ordinary binary, no trailer here" });
    defer std.Io.Dir.cwd().deleteFile(io.io(), path) catch {};

    const read_back = try readTrailer(io.io(), allocator, path);
    try std.testing.expectEqual(@as(?[]u8, null), read_back);
}
