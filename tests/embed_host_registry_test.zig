const std = @import("std");
const panos = @import("panos_embed");

// Отдельный от `embed_host_test.zig` файл/build-таргет НАМЕРЕННО: его
// build.zig-таргет НЕ включает `rdynamic` — доказывает, что native
// host-function registry (specs/017-native-host-function-registry) не
// требует ни `pub export fn`, ни `rdynamic`, независимо от старого
// dlsym-пути, который тестирует соседний файл.

fn scale(x: f64) f64 {
    return x * 2.0;
}

const MemoryReader = struct {
    source: []const u8,

    pub fn read(self: *const MemoryReader, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        if (!std.mem.eql(u8, path, "сценарий.pns")) return error.FileNotFound;
        return allocator.dupe(u8, self.source);
    }
};

test "registry-resolved host function works without pub export fn/rdynamic" {
    const reader = MemoryReader{
        .source = "внешний \"хост\" функ scale(значение: Число(64)) -> Число(64)\n" ++
            "экспорт функ обновить(дельта: Число) -> Число\n" ++
            "scale(дельта)\n" ++
            "конец",
    };

    var runtime = panos.Runtime.init(std.testing.allocator, .{
        .host_functions = panos.hostFunctions(.{
            .scale = scale,
        }),
    });
    defer runtime.deinit();
    try runtime.load(&reader, "сценарий.pns");
    try std.testing.expect(!runtime.hasGraphErrors());
    try runtime.compile();
    try std.testing.expect(!runtime.hasCompilationErrors());

    switch (try runtime.call("обновить", &.{.{ .number = 21.0 }})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42.0), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

// User Story 2 (spec.md) — несовпадение сигнатуры между `.pns`-декларацией
// и зарегистрированной Zig-функцией ловится на резолве, не в рантайме.
test "signature mismatch (parameter count) is a Resolve Error, not a crash" {
    const reader = MemoryReader{
        .source = "внешний \"хост\" функ scale(a: Число(64), b: Число(64)) -> Число(64)\n" ++
            "экспорт функ старт() -> Число\n" ++
            "0\n" ++
            "конец",
    };

    var runtime = panos.Runtime.init(std.testing.allocator, .{
        .host_functions = panos.hostFunctions(.{
            .scale = scale,
        }),
    });
    defer runtime.deinit();
    try runtime.load(&reader, "сценарий.pns");
    try std.testing.expect(!runtime.hasGraphErrors());
    try runtime.compile();
    try std.testing.expect(runtime.hasCompilationErrors());
}

fn addInts(a: i32, b: i32) i32 {
    return a + b;
}

test "signature mismatch (marshal kind) is a Resolve Error, not a crash" {
    const reader = MemoryReader{
        .source = "внешний \"хост\" функ addInts(a: Число(64), b: Число(64)) -> Число(64)\n" ++
            "экспорт функ старт() -> Число\n" ++
            "0\n" ++
            "конец",
    };

    var runtime = panos.Runtime.init(std.testing.allocator, .{
        .host_functions = panos.hostFunctions(.{
            .addInts = addInts,
        }),
    });
    defer runtime.deinit();
    try runtime.load(&reader, "сценарий.pns");
    try std.testing.expect(!runtime.hasGraphErrors());
    try runtime.compile();
    try std.testing.expect(runtime.hasCompilationErrors());
}

// User Story 4 (spec.md) — при коллизии имени между registry-записью и
// реальным экспортированным `pub export fn` с тем же именем побеждает
// registry, не dlsym-путь.
pub export fn panos_embed_host_priority_probe(x: f64) f64 {
    return x + 1000.0; // dlsym-путь — легко отличить от registry-пути ниже
}

fn priorityProbe(x: f64) f64 {
    return x + 1.0; // registry-путь — должен победить
}

test "registry entry wins over a same-named pub export fn symbol" {
    const reader = MemoryReader{
        .source = "внешний \"хост\" функ panos_embed_host_priority_probe(значение: Число(64)) -> Число(64)\n" ++
            "экспорт функ обновить(дельта: Число) -> Число\n" ++
            "panos_embed_host_priority_probe(дельта)\n" ++
            "конец",
    };

    var runtime = panos.Runtime.init(std.testing.allocator, .{
        .host_functions = panos.hostFunctions(.{
            .panos_embed_host_priority_probe = priorityProbe,
        }),
    });
    defer runtime.deinit();
    try runtime.load(&reader, "сценарий.pns");
    try std.testing.expect(!runtime.hasGraphErrors());
    try runtime.compile();
    try std.testing.expect(!runtime.hasCompilationErrors());

    switch (try runtime.call("обновить", &.{.{ .number = 1.0 }})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 2.0), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

// User Story 3 (spec.md) — registry-вызов не проходит через
// `ffi_prep_cif`/`ffi_call`. Прямого доступа к внутренним счётчикам VM
// снаружи нет — используется существующий `--profile-ffi`-механизм
// (`Runtime.Config.foreign_profile_enabled` + `writeForeignProfile`) как
// чёрный ящик: `cachedForeignCall` (единственное место, инкрементирующее
// `cache_misses`, и единственный путь к `ffi_call`) физически недостижим
// для `.native_registry` — `invokeForeign` возвращает ДО него (`vm.zig`).
// Поэтому после N вызовов `cache hit/miss` обязано остаться `.../0`
// (НИ ОДНОГО промаха, включая самый первый вызов — недостижимо для
// dynlib-пути, где кэш пуст на первом вызове) И `ffi_call=0 us` (то самое
// поле, которое заполняет только `recordForeignNativeTime`, вызываемый
// исключительно из libffi-ветки).
test "registry path never touches the libffi cif cache" {
    const reader = MemoryReader{
        .source = "внешний \"хост\" функ scale(значение: Число(64)) -> Число(64)\n" ++
            "экспорт функ обновить(дельта: Число) -> Число\n" ++
            "scale(дельта)\n" ++
            "конец",
    };

    var runtime = panos.Runtime.init(std.testing.allocator, .{
        .host_functions = panos.hostFunctions(.{
            .scale = scale,
        }),
        .foreign_profile_enabled = true,
    });
    defer runtime.deinit();
    try runtime.load(&reader, "сценарий.pns");
    try runtime.compile();
    try std.testing.expect(!runtime.hasCompilationErrors());

    var call_index: usize = 0;
    while (call_index < 5) : (call_index += 1) {
        _ = try runtime.call("обновить", &.{.{ .number = @floatFromInt(call_index) }});
    }

    var allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer allocating.deinit();
    try runtime.writeForeignProfile(&allocating.writer);
    const profile_text = allocating.written();

    try std.testing.expect(std.mem.indexOf(u8, profile_text, "calls=5") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile_text, "ffi_call=0 us") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile_text, "cache hit/miss=5/0") != null);
}

// Многофайловый reader (тот же паттерн, что `module_loader.zig`'s
// собственные тесты) — доказывает "экспорт внешний "хост" функ ..."
// (жалоба живым тестом из jijka: "нельзя было переиспользовать
// внешний-декларации между .pns-файлами уровня") реально работающим
// сквозь `импорт`, не просто резолвится синтаксически.
const MultiFileReader = struct {
    files: []const File,

    const File = struct {
        path: []const u8,
        bytes: []const u8,
    };

    pub fn read(self: *const MultiFileReader, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        for (self.files) |file| {
            if (std.mem.eql(u8, file.path, path)) return allocator.dupe(u8, file.bytes);
        }
        return error.FileNotFound;
    }
};

test "экспорт внешний \"хост\" функ ... is callable through импорт with a real registered host function" {
    const reader = MultiFileReader{ .files = &.{
        .{
            .path = "проект/main.pns",
            .bytes = "импорт \"./host\" как хост\n" ++
                "экспорт функ обновить(дельта: Число) -> Число\n" ++
                "хост.scale(дельта)\n" ++
                "конец",
        },
        .{
            .path = "проект/host.pns",
            .bytes = "экспорт внешний \"хост\" функ scale(значение: Число(64)) -> Число(64)\n",
        },
    } };

    var runtime = panos.Runtime.init(std.testing.allocator, .{
        .host_functions = panos.hostFunctions(.{
            .scale = scale,
        }),
    });
    defer runtime.deinit();
    try runtime.load(&reader, "проект/main.pns");
    try std.testing.expect(!runtime.hasGraphErrors());
    try runtime.compile();
    try std.testing.expect(!runtime.hasCompilationErrors());

    switch (try runtime.call("обновить", &.{.{ .number = 21.0 }})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42.0), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "'внешний' still cannot be exported for a real dynlib library (\"libc\")" {
    const reader = MultiFileReader{ .files = &.{
        .{
            .path = "проект/main.pns",
            .bytes = "экспорт внешний \"libc\" функ getpid() -> Целое(32)\n" ++
                "экспорт функ старт() -> Целое\n" ++
                "0\n" ++
                "конец",
        },
    } };

    var runtime = panos.Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();
    try runtime.load(&reader, "проект/main.pns");
    try std.testing.expect(runtime.hasGraphErrors());
}

// `panos.alias(...)` — Zig-сторона держит латиницу (`scale`, обычный
// Zig-идентификатор поля таблицы), а `.pns`-скрипт видит кириллическое
// имя (`удвоить`) — не совпадает с именем Zig-поля вообще.
test "hostFunctions: panos.alias exposes a name different from the Zig field name" {
    const reader = MemoryReader{
        .source = "внешний \"хост\" функ удвоить(значение: Число(64)) -> Число(64)\n" ++
            "экспорт функ обновить(дельта: Число) -> Число\n" ++
            "удвоить(дельта)\n" ++
            "конец",
    };

    var runtime = panos.Runtime.init(std.testing.allocator, .{
        .host_functions = panos.hostFunctions(.{
            .scale = panos.alias("удвоить", scale),
        }),
    });
    defer runtime.deinit();
    try runtime.load(&reader, "сценарий.pns");
    try std.testing.expect(!runtime.hasGraphErrors());
    try runtime.compile();
    try std.testing.expect(!runtime.hasCompilationErrors());

    switch (try runtime.call("обновить", &.{.{ .number = 21.0 }})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42.0), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

// Именем, под которым скрипт видит функцию, ДОЛЖНО быть имя из
// `alias(...)` — под родным Zig-именем поля (`scale`, латиницей) она
// не должна быть видна вообще.
test "hostFunctions: the Zig field name itself is NOT exposed when aliased" {
    const reader = MemoryReader{
        .source = "внешний \"хост\" функ scale(значение: Число(64)) -> Число(64)\n" ++
            "экспорт функ старт() -> Число\n" ++
            "0\n" ++
            "конец",
    };

    var runtime = panos.Runtime.init(std.testing.allocator, .{
        .host_functions = panos.hostFunctions(.{
            .scale = panos.alias("удвоить", scale),
        }),
    });
    defer runtime.deinit();
    try runtime.load(&reader, "сценарий.pns");
    try std.testing.expect(!runtime.hasGraphErrors());
    try runtime.compile();
    try std.testing.expect(runtime.hasCompilationErrors());
}
