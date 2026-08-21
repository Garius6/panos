const std = @import("std");
const builtin = @import("builtin");
const ast = @import("ast.zig");
const diagnostic = @import("diagnostic.zig");
const source = @import("source.zig");
const symbols = @import("symbols.zig");
const target_policy = @import("target.zig");

// Полный список имён встроенных нативных модулей (каждый регистрируется
// ниже в `installBuiltins`) — поиск импортов в `module_loader.zig`
// использует ЭТОТ ЖЕ список, чтобы понять, что `импорт <имя>` без файла
// `.ps` на пути поиска должен молча разрешиться в нативный модуль, а не
// выдать ошибку `FileNotFound` (документированное поведение,
// `docs/src/getting-started/installation.md` § "Поиск модулей").
pub const native_builtin_modules = [_][]const u8{
    "фс",
    "ос",
    "время",
    "ввод_вывод",
    "строки",
    "DOM",
    "состояние",
    "сжатие",
    "синтаксис",
    "сеть",
    "бд",
    "криптография",
};

// Экспортируемые имена по каждому нативному модулю. Значения — builtin'ы,
// если `nativeModuleExportKind` не пометит имя как публичный нативный тип.
// Используется `module_linker.zig` для привязки АЛИАСИРОВАННОГО нативного
// импорта (`импорт "ввод_вывод" как ио`) — поле `native_module` у `Import`
// в `module_loader.zig` говорит, что имя разрешилось нативно, но самому
// алиасу всё равно нужно ЧТО-ТО объявленное как его экспорты, так же как
// обычный файловый импорт получает их из `buildExportsForTarget`.
pub fn nativeModuleExports(name: []const u8) ?[]const []const u8 {
    const table = [_]struct { name: []const u8, exports: []const []const u8 }{
        .{ .name = "фс", .exports = &.{ "есть", "удалить", "прочитать", "записать", "открыть", "это_директория", "создать_директорию", "список_директории", "удалить_директорию" } },
        .{ .name = "ос", .exports = &.{ "аргументы", "версия_паноса", "окружение", "установить_окружение", "удалить_окружение", "выполнить", "завершить" } },
        .{ .name = "время", .exports = &.{ "сейчас_мс", "монотонно_мс", "спать_мс" } },
        .{ .name = "ввод_вывод", .exports = &.{ "печать", "строка", "прочитать_строку" } },
        .{ .name = "строки", .exports = &.{
            "из_байтов",
            "в_число",
            "из_числа",
            "из_целого",
            "верхний_регистр",
            "нижний_регистр",
            "заканчивается_на",
            "начинается_с",
            "содержит",
            "найти",
            "заменить",
            "обрезать",
            "разбить",
            "соединить",
            "срез",
            "цифра_или_буква",
            "это_буква",
            "это_цифра",
            "в_байты",
            "в_руны",
            "из_рун",
            "кодовая_точка",
        } },
        .{ .name = "DOM", .exports = &.{ "текст", "установить_текст", "на_клик", "СобытиеКлика", "текст_строка", "установить_текст_строка", "значение_поля", "установить_значение_поля", "создать_и_добавить", "после_кадра", "атрибут", "установить_атрибут", "удалить", "путь", "перейти" } },
        .{ .name = "состояние", .exports = &.{ "прочитать", "записать" } },
        .{ .name = "сжатие", .exports = &.{"разжать_gzip"} },
        .{ .name = "синтаксис", .exports = &.{ "структуры", "поля", "импорты", "аннотации", "аргумент_аннотации", "аннотации_поля", "аргумент_аннотации_поля" } },
        .{ .name = "сеть", .exports = &.{ "подключиться", "кодировать_url", "декодировать_url", "http_запрос", "http_запрос_без_редиректа", "http_запрос_sync", "http_запрос_sync_с_заголовками", "http_сервер_слушать" } },
        .{ .name = "бд", .exports = &.{"открыть"} },
        .{ .name = "криптография", .exports = &.{ "hmac_sha256_base64url", "base64url_кодировать", "base64url_декодировать", "сравнить_константное_время", "sha256_base64url", "pbkdf2_sha256_base64url", "случайные_байты_base64url", "es256_сгенерировать_ключи", "es256_подписать", "es256_проверить" } },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.exports;
    }
    return null;
}

pub fn nativeModuleExportKind(module_name: []const u8, export_name: []const u8) symbols.SymbolKind {
    if (std.mem.eql(u8, module_name, "DOM") and std.mem.eql(u8, export_name, "СобытиеКлика")) return .type;
    return .builtin;
}

const EnumVariants = struct {
    owner: symbols.SymbolId,
    values: std.StringHashMap(symbols.SymbolId),
};

pub const ImportedExport = struct {
    name: []const u8,
    kind: symbols.SymbolKind,
    span: source.Span,
    origin: ?ImportedSymbolOrigin = null,
    methods: []const ImportedMethodExport = &.{},
    variants: []const ImportedVariantExport = &.{},
    // Заполняется ТОЛЬКО для нативного builtin-экспорта, достигнутого через
    // АЛИАСИРОВАННЫЙ `импорт "ввод_вывод" как ио` — `module_path` у члена
    // должен оставаться РЕАЛЬНЫМ именем модуля ("ввод_вывод"), никогда не
    // локальным алиасом ("ио"), потому что каждый диспетчер
    // `compileXBuiltin`/`isBuiltinModule` в `compiler.zig`/`type_checker.zig`
    // жёстко завязан на реальное имя. `null` (подавляющее большинство
    // случаев — обычный файловый импорт) сохраняет существующее поведение
    // `predeclareImports` (`module_path = import.alias`) без изменений.
    builtin_module_path: ?[]const u8 = null,
};

// Вариант импортированного перечисления — конструирование/сопоставление
// целиком основано на имени-строке во время компиляции, поэтому, в отличие
// от методов, с ним не нужно тащить декларацию или FunctionId — только
// голое имя.
pub const ImportedVariantExport = struct {
    name: []const u8,
    span: source.Span,
};

pub const ImportedSymbolOrigin = struct {
    module: usize,
    declaration: ast.DeclId,
};

// Метод, объявленный на импортированном типе-владельце — диспетчеризуется
// структурно по значению владельца (`точка.метод()`), никогда не
// привязывается к имени в области видимости, поэтому ему нужен собственный
// локальный Symbol_Id, заведённый рядом с владельцем, а не декларация в
// области видимости, как у других импортируемых экспортов.
pub const ImportedMethodExport = struct {
    name: []const u8,
    // Модуль, где физически написано тело `функ` этого метода (файл
    // самого impl-блока) — нужен отдельно от `origin.module` владеющего
    // экспорта (модуль СТРУКТУРЫ), потому что квалифицированная цель impl
    // (`реализация X для Модуль.Тип`) может жить в ТРЕТЬЕМ файле, отличном
    // и от файла структуры, и от файла потребителя. `declaration` ниже —
    // это `DeclId` в AST ЭТОГО модуля, не структуры.
    module: usize,
    declaration: ast.DeclId,
    span: source.Span,
};

pub const ImportedModule = struct {
    alias: []const u8,
    span: source.Span,
    exports: []const ImportedExport,
    // Истинно только для неявного импорта прелюдии — сливает `exports`
    // НАПРЯМУЮ в собственную область видимости импортёра (`Опция(T)`, а не
    // `alias.Опция`), вместо вложения под символ модуля, квалифицированный
    // `alias`.
    unqualified: bool = false,
};

// Привязывает свежесозданный локальный Symbol_Id импортированного метода к
// собственному локальному Symbol_Id типа-владельца и к декларации-источнику
// метода в экспортирующем модуле — зеркалит `imported_symbols`, но с ключом
// владелец+имя вместо видимого в области видимости квалифицированного имени.
pub const ImportedMethodBinding = struct {
    owner: symbols.SymbolId,
    name: []const u8,
    symbol: symbols.SymbolId,
    origin: ImportedSymbolOrigin,
};

const ModuleMembers = struct {
    module: symbols.SymbolId,
    values: std.StringHashMap(symbols.SymbolId),
};

pub const Resolution = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    symbols: symbols.SymbolStore,
    diagnostics: diagnostic.DiagnosticList = .{},
    decl_symbols: std.AutoHashMap(ast.DeclId, symbols.SymbolId),
    stmt_symbols: std.AutoHashMap(ast.StmtId, symbols.SymbolId),
    stmt_bindings: std.AutoHashMap(ast.StmtId, []const symbols.SymbolId),
    expr_symbols: std.AutoHashMap(ast.ExprId, symbols.SymbolId),
    pattern_symbols: std.AutoHashMap(ast.PatternId, symbols.SymbolId),
    function_parameters: std.AutoHashMap(ast.DeclId, []const symbols.SymbolId),
    lambda_parameters: std.AutoHashMap(ast.ExprId, []const symbols.SymbolId),
    lambda_captures: std.AutoHashMap(ast.ExprId, []const symbols.SymbolId),
    imported_symbols: std.AutoHashMap(symbols.SymbolId, ImportedSymbolOrigin),
    imported_methods: std.ArrayList(ImportedMethodBinding) = .empty,
    enum_variants: std.ArrayList(EnumVariants) = .empty,
    // `внешний` (FFI) — разрешённый указатель на функцию для каждого
    // символа хранится как обычный `usize` (0 = поиск не удался, диагностика
    // уже выдана в этот момент), а не как настоящий тип указателя или
    // значение `std.DynLib`: структура `Resolution` компилируется в общий
    // `core_module`, который также импортирует сборка браузера
    // wasm32-freestanding, и `std.DynLib` не должен становиться здесь типом
    // хранимого поля — обработка `.foreign` в `predeclare` использует его
    // только как локальную переменную внутри `if`/`else` по
    // `builtin.target.os.tag == .freestanding`, затем сознательно даёт ей
    // выйти из области видимости БЕЗ закрытия (загруженная библиотека
    // должна пережить этот проход разрешения — как и `module_graph.
    // foreign_libraries` в Odin, тоже никогда явно не выгружаемая).
    foreign_functions: std.AutoHashMap(symbols.SymbolId, usize),

    pub fn init(allocator: std.mem.Allocator) !Resolution {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .symbols = try symbols.SymbolStore.init(allocator),
            .decl_symbols = .init(allocator),
            .stmt_symbols = .init(allocator),
            .stmt_bindings = .init(allocator),
            .expr_symbols = .init(allocator),
            .pattern_symbols = .init(allocator),
            .function_parameters = .init(allocator),
            .lambda_parameters = .init(allocator),
            .lambda_captures = .init(allocator),
            .imported_symbols = .init(allocator),
            .foreign_functions = .init(allocator),
        };
    }

    pub fn deinit(self: *Resolution) void {
        self.foreign_functions.deinit();
        self.imported_methods.deinit(self.allocator);
        for (self.enum_variants.items) |*variants| variants.values.deinit();
        self.enum_variants.deinit(self.allocator);
        self.imported_symbols.deinit();
        self.lambda_captures.deinit();
        self.lambda_parameters.deinit();
        self.function_parameters.deinit();
        self.pattern_symbols.deinit();
        self.expr_symbols.deinit();
        self.stmt_bindings.deinit();
        self.stmt_symbols.deinit();
        self.decl_symbols.deinit();
        self.diagnostics.deinit(self.allocator);
        self.symbols.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn findEnumVariant(self: *const Resolution, owner: symbols.SymbolId, name: []const u8) ?symbols.SymbolId {
        for (self.enum_variants.items) |variants| {
            if (variants.owner == owner) return variants.values.get(name);
        }
        return null;
    }
};

// Вынесено в отдельную функцию (а не оставлено только методом `Resolver`),
// чтобы `bundle.zig` (встраивание автономного исполняемого файла, `panos
// build --compile`) мог разрешать ТОТ ЖЕ путь-подобный `внешний "./lib.so"`,
// что и обычная компиляция, БЕЗ необходимости в целом экземпляре
// `Resolver` — ему нужно только это одно чистое вычисление (по пути файла
// `.pns` и логическому имени библиотеки как оно написано — в какой
// реальный путь файла его разрешает `внешний`). `Resolver.
// foreignLibraryFilename` ниже — теперь тонкая обёртка, подставляющая
// собственный `self.source_path`.
pub fn resolveForeignLibraryPath(allocator: std.mem.Allocator, source_path: []const u8, logical_name: []const u8) ![]const u8 {
    const suffix = switch (builtin.target.os.tag) {
        .macos, .ios, .tvos, .watchos => ".dylib",
        .windows => ".dll",
        else => ".so",
    };
    // Путь-подобная ссылка на библиотеку (содержит '/') — это явный путь к
    // файлу, а не голое логическое имя, разрешаемое через собственный путь
    // поиска загрузчика ОС (LD_LIBRARY_PATH/DYLD_.../PATH) — голое
    // логическое имя (`"libc"`, `"raylib"`) никогда не содержит '/'.
    // Разрешается так же, как `импорт` разрешает относительный путь модуля
    // (`module_loader.resolveImportPath`): относительно ДИРЕКТОРИИ этого
    // файла `.pns`/`.ps` (`source_path`), а не текущей рабочей директории
    // процесса — библиотека, поставляемая рядом со скриптографиям, продолжает
    // работать независимо от того, откуда запущен `panos`. Уже абсолютный
    // путь, либо inline/тестовый вызывающий без реального `source_path`
    // (пустой — относительно нечего разрешать), используется как есть и
    // затем разрешается относительно CWD процесса через загрузчик ОС — тот
    // же резервный путь, что использует сам `импорт`
    // (`importer_path.len == 0`).
    if (std.mem.indexOfScalar(u8, logical_name, '/') != null) {
        const suffixed = if (std.mem.endsWith(u8, logical_name, suffix))
            logical_name
        else
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ logical_name, suffix });
        defer if (suffixed.ptr != logical_name.ptr) allocator.free(suffixed);

        if (suffixed[0] == '/' or source_path.len == 0) return allocator.dupe(u8, suffixed);
        const directory = std.fs.path.dirname(source_path) orelse "";
        if (directory.len == 0) return allocator.dupe(u8, suffixed);
        // Убирает ведущее "./" (но не "../", оно значимо) перед
        // объединением — чисто косметически, "dir/./libs/x.so" и так бы
        // разрешился нормально, это просто держит выводимые пути и
        // сообщения `Resolve Error` читаемыми.
        const relative = if (std.mem.startsWith(u8, suffixed, "./")) suffixed[2..] else suffixed;
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, relative });
    }
    // В Windows нет файла "libc.dll" — тамошний C runtime это
    // `msvcrt.dll` (присутствует в каждой версии Windows начиная с NT4,
    // ту же роль универсального аналога CRT на POSIX выше выполняет
    // `dlopen(NULL)`). Этот особый случай только для "libc"; любое другое
    // голое имя библиотеки всё равно проходит через общее правило
    // суффикса `<name>.dll`.
    if (comptime builtin.target.os.tag == .windows) {
        if (std.mem.eql(u8, logical_name, "libc")) return allocator.dupe(u8, "msvcrt.dll");
    }
    if (std.mem.endsWith(u8, logical_name, suffix)) return allocator.dupe(u8, logical_name);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ logical_name, suffix });
}

const Resolver = struct {
    result: *Resolution,
    scopes: symbols.ScopeStack,
    tree: *const ast.Ast = undefined,
    module_members: std.ArrayList(ModuleMembers) = .empty,
    target_profile: target_policy.TargetProfile = .native,
    // Файл `.pns`/`.ps`, из которого загружен этот модуль (например,
    // "проект/main.ps") — пустой для любого inline/тестового вызывающего
    // `resolve` (нет реального файла на диске, относительно которого
    // считать путь). Используется только `resolveForeignFunction`, чтобы
    // разрешать явный относительный путь библиотеки `внешний`
    // (`"./libs/foo.so"`) относительно директории ЭТОГО файла, а не
    // текущей рабочей директории процесса — соответствует существующему
    // соглашению `импорт` об относительных путях
    // (`module_loader.resolveImportPath`), поэтому библиотека, поставляемая
    // рядом с `.pns`-файлом, продолжает работать независимо от того,
    // откуда запущен `panos`.
    source_path: []const u8 = "",
    // См. `popScopeAndWarnUnused` — фактическое предупреждение.
    used_symbols: std.AutoHashMap(symbols.SymbolId, void),
    unused_check_symbols: std.AutoHashMap(symbols.SymbolId, void),

    fn init(result: *Resolution) !Resolver {
        return .{
            .result = result,
            .scopes = try symbols.ScopeStack.init(result.allocator),
            .used_symbols = .init(result.allocator),
            .unused_check_symbols = .init(result.allocator),
        };
    }

    fn deinit(self: *Resolver) void {
        for (self.module_members.items) |*members| members.values.deinit();
        self.module_members.deinit(self.result.allocator);
        self.used_symbols.deinit();
        self.unused_check_symbols.deinit();
        self.scopes.deinit();
        self.* = undefined;
    }

    // Проверяет символы ЗАКРЫВАЕМОЙ области видимости на неиспользованные
    // переменные, объявленные через `пер`, перед фактическим извлечением из
    // стека (`scopeByIdConst(self.scopes.current)` читает ТЕКУЩУЮ область
    // видимости, всё ещё валидную в этот момент — `self.scopes.pop()`
    // только сдвигает курсор к родителю, никогда не освобождает/делает
    // невалидным хранилище извлечённой области видимости).
    fn popScopeAndWarnUnused(self: *Resolver) !void {
        const scope = self.scopes.scopeByIdConst(self.scopes.current);
        var iterator = scope.symbols.valueIterator();
        while (iterator.next()) |symbol_id| {
            if (!self.unused_check_symbols.contains(symbol_id.*)) continue;
            if (self.used_symbols.contains(symbol_id.*)) continue;
            const symbol = self.result.symbols.get(symbol_id.*) orelse continue;
            try self.reportWarning(symbol.span, "неиспользованная переменная '{s}'", .{symbol.name});
        }
        _ = try self.scopes.pop();
    }

    fn report(self: *Resolver, span: source.Span, comptime format: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.result.arena.allocator(), format, args);
        _ = try self.result.diagnostics.appendUnique(self.result.allocator, .{
            .phase = .resolver,
            .severity = .err,
            .span = span,
            .message = message,
        });
    }

    // Та же форма, что у `report` выше, только `.severity = .warning`
    // вместо `.err`.
    fn reportWarning(self: *Resolver, span: source.Span, comptime format: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.result.arena.allocator(), format, args);
        _ = try self.result.diagnostics.appendUnique(self.result.allocator, .{
            .phase = .resolver,
            .severity = .warning,
            .span = span,
            .message = message,
        });
    }

    // `skip_prelude_hardcode` истинно ТОЛЬКО при разрешении самого
    // встроенного модуля прелюдии (см. `compileGraph` в
    // `module_compiler.zig`) — иначе его собственные реальные декларации
    // `тип Опция[T] = перечисление ...` столкнулись бы с этими вручную
    // установленными дубликатами. Все прочие вызывающие сохраняют этот
    // хардкод.
    fn installBuiltins(self: *Resolver, skip_prelude_hardcode: bool) !void {
        const builtin_names = [_][]const u8{
            "Ошибка",
            "длина",
            "паника",
            "получить",
            "отправить",
            "себя",
            "наблюдать",
            "получить_сигнал",
            "убить",
            "связать",
            // `ждать` — блокируется до завершения или падения процесса,
            // запущенного через `запусти <вызов>`, возвращая
            // `Результат(R, Ошибка)`, где R — тип возврата запущенной
            // функции. Соседствует с `получить`, не заменяет его.
            "ждать",
            "встроку",
            "Целое",
            "Число",
            // Ограниченный почтовый ящик: `ограничить_почту(N)`
            // устанавливает ёмкость почтового ящика ТЕКУЩЕГО процесса
            // (вызывается изнутри тела актора, зеркалит поведение
            // `себя()` — "действует на текущий процесс") — по умолчанию
            // ящик остаётся неограниченным. `отправить_или` — ОТДЕЛЬНАЯ,
            // добровольная отправка, которая учитывает этот лимит и
            // отклоняет с `Ошибка` вместо добавления при переполнении;
            // обычный `отправить` намеренно ОСТАВЛЕН БЕЗ ИЗМЕНЕНИЙ (всегда
            // успешен) — ограниченное поведение действует, только когда
            // ОБЕ стороны согласны на него явно.
            "ограничить_почту",
            "отправить_или",
            // Кооперативная отмена: `отмена(proc)` устанавливает флаг на
            // ЦЕЛЕВОМ процессе, `отменено()` опрашивает собственный флаг
            // ТЕКУЩЕГО процесса — чисто рекомендательно, цель должна сама
            // наблюдать за ним через `отменено()`; принудительные
            // `убить()`/`остановить()` (супервизор.ps) не изменяются и не
            // связаны с этим механизмом.
            "отмена",
            "отменено",
        };
        for (builtin_names) |name| {
            const symbol = try self.result.symbols.add(.{
                .name = name,
                .kind = .builtin,
                .span = .{ .file_id = 0, .start = 0, .end = 0 },
            });
            try self.scopes.declare(&self.result.symbols, symbol);
        }
        try self.installBuiltinModule("фс", &.{ "есть", "удалить", "прочитать", "записать", "открыть", "это_директория", "создать_директорию", "список_директории", "удалить_директорию" });
        // `Файл` — непараметрический opaque-тип открытого файлового
        // дескриптографияра (`фс.открыть`), симметрично Odin'овскому TY_FILE
        // (core/type_cheker.odin) — никогда не парсится из исходника
        // (нет ни структуры, ни перечисления), поэтому объявляется прямо
        // здесь, как и модуль `фс` выше, а не через встроенную прелюдию.
        try self.installBuiltinType("Файл");
        try self.installBuiltinModule("ос", &.{ "аргументы", "версия_паноса", "окружение", "установить_окружение", "удалить_окружение", "выполнить", "завершить" });
        try self.installBuiltinModule("время", &.{ "сейчас_мс", "монотонно_мс", "спать_мс" });
        // `ввод_вывод` — ограничен только `.печать`/`.строка` пока что —
        // `.прочитать_строку`/`.поток` (список `native_only` в
        // `target.zig` уже предусматривает оба этих имени) нуждаются в той
        // же асинхронной машинерии stdin, что и потоковое чтение `Файл`, —
        // отдельная последующая работа.
        // `прочитать_строку` — блокирующая, только для нативной сборки
        // (см. список `native_only` в `target.zig`) — возвращает
        // `Опция(Строка)`, `Нет()` при EOF, а не пустую строку, чтобы
        // вызывающий мог отличить "пользователь нажал Enter на пустой
        // строке" от "stdin закрыт".
        try self.installBuiltinModule("ввод_вывод", &.{ "печать", "строка", "прочитать_строку" });
        // `строки` — нативный модуль (`std/*.ps` не может собрать эти
        // строковые примитивы из других операций уровня panos). `байт`/
        // `длина_байт`/`срез_байт` были УДАЛЕНЫ (не устарели) — они
        // выставляли БАЙТОВЫЙ индекс на `Строка` рядом с РУНОВЫМ индексом
        // `найти`/`срез`, оба типизированные просто как `Целое`, ничто не
        // мешало их перепутать (см. `docs/src/language/standard-library.md`
        // §"Байты"). Исправление в стиле Go: работа с байтами теперь идёт
        // через `строки.в_байты(s) -> Массив(Целое)` + обычные методы
        // массива (`.длина()`/`.получить()`/`.срез()`, уже существующие) —
        // руновый индекс и индекс байтового массива теперь разные
        // индексные пространства на уровне языка (`Строка` vs `Массив`), а
        // не просто предупреждение в документации.
        try self.installBuiltinModule("строки", &.{
            "из_байтов",
            "в_число",
            "из_числа",
            "из_целого",
            "верхний_регистр",
            "нижний_регистр",
            "заканчивается_на",
            "начинается_с",
            "содержит",
            "найти",
            "заменить",
            "обрезать",
            "разбить",
            "соединить",
            "срез",
            "цифра_или_буква",
            "это_буква",
            "это_цифра",
            "в_байты",
            "в_руны",
            "из_рун",
            "кодовая_точка",
        });
        // `DOM` — только AOT WASM (`target.zig`'s `builtinAvailability`).
        // Числовые методы совместимы с первым AOT DOM-срезом; строковые
        // методы используют opaque-хендлы, предоставляемые его JS-рантаймом.
        try self.installBuiltinModule("DOM", &.{ "текст", "установить_текст", "на_клик", "текст_строка", "установить_текст_строка", "значение_поля", "установить_значение_поля", "создать_и_добавить", "после_кадра", "атрибут", "установить_атрибут", "удалить", "путь", "перейти" });
        try self.installBuiltinModuleType("DOM", "СобытиеКлика");
        // `состояние` — Model, хранимая JS-загрузчиком, только AOT WASM
        // (то же ограничение `target.zig`, что и у `DOM`, по той же причине:
        // опирается на JS-замыкание-переменную, существующую только в
        // `aot-dom-loader.js`).
        try self.installBuiltinModule("состояние", &.{ "прочитать", "записать" });
        try self.installBuiltinModule("сжатие", &.{"разжать_gzip"});
        try self.installBuiltinModule("синтаксис", &.{ "структуры", "поля", "импорты", "аннотации", "аргумент_аннотации", "аннотации_поля", "аргумент_аннотации_поля" });
        try self.installBuiltinModule("сеть", &.{ "подключиться", "кодировать_url", "декодировать_url", "http_запрос", "http_запрос_без_редиректа", "http_запрос_sync", "http_запрос_sync_с_заголовками", "http_сервер_слушать" });
        // `Соединение` — открытый TCP-сокет (`сеть.подключиться`), тот же
        // opaque-тип принцип, что `Файл` (см. коммент там) — но, в отличие
        // от `Файл`, здесь ДЕЙСТВИТЕЛЬНО хранится живой OS-дескриптографияр
        // (сокет нельзя "переоткрыть по пути" между вызовами, как файл —
        // соединение либо живое, либо разорвано навсегда).
        try self.installBuiltinType("Соединение");
        // `Слушатель`/`Запрос` — TCP-сервер (`сеть.http_сервер_слушать`) и
        // один принятый HTTP-запрос (`Слушатель.принять_запрос()`), тем же
        // opaque-типом принципом, что `Соединение` выше.
        try self.installBuiltinType("Слушатель");
        try self.installBuiltinType("Запрос");
        try self.installBuiltinModule("бд", &.{"открыть"});
        // `Соединение_БД` — открытое SQLite-соединение (`бд.открыть`),
        // тем же принципом opaque-типа, что `Файл`/`Соединение` — но, как
        // и `Соединение`, хранит живой ресурс (открытый `sqlite3*`), не
        // "путь для переоткрытия".
        try self.installBuiltinType("Соединение_БД");
        // `криптография` — HMAC-SHA256/base64url/константное-время-сравнение,
        // достаточное подмножество для подписи/проверки JWT (`std/
        // кодирование/jwt.pns`) — чистые функции над `std.crypto`
        // (Zig stdlib, ничего не вендорится, в отличие от `бд`/libffi),
        // но всё равно `native_only` (`target.zig`): выполняются только
        // через байткод-VM, у AOT WASM-кодогенерации (`wasm_emit.zig`)
        // нет своего пути для них — тот же практический предел, что и у
        // `сеть`/`бд` (быстряга/HTTP-сервер всё равно недоступны в WASM).
        try self.installBuiltinModule("криптография", &.{ "hmac_sha256_base64url", "base64url_кодировать", "base64url_декодировать", "сравнить_константное_время", "sha256_base64url", "pbkdf2_sha256_base64url", "случайные_байты_base64url", "es256_сгенерировать_ключи", "es256_подписать", "es256_проверить" });
        if (skip_prelude_hardcode) return;
        try self.installPreludeEnum("Опция", &.{ "Нет", "Есть" });
        try self.installPreludeEnum("Результат", &.{ "Успех", "Неудача" });
        // `выбор ожидание(...)` (мультиисточниковое ожидание в стиле select)
        // сопоставляется с вариантами этого синтетического перечисления
        // точно так же, как обычный `выбор` сопоставляется с
        // `Опция`/`Результат` — та же жёстко прописанная регистрация
        // голых имён нужна по той же причине (панос никогда не сливает
        // имена импортированного модуля в область видимости, поэтому
        // одного лишь реального объявления в `prelude.zig` недостаточно,
        // чтобы `Сообщение`/`Сигнал`/`Готово` разрешались без квалификации).
        try self.installPreludeEnum("ИсточникОжидания", &.{ "Сообщение", "Сигнал", "Готово" });
        try self.installPreludeInterface("Сравниваемое");
        try self.installPreludeInterface("Итерируемое");
        // `Печатаемое`'s `вСтроку() -> Строка` не имеет
        // самоссылающегося параметра/возврата вообще (в отличие от
        // `Сравниваемое.сравнить(другое: Сравниваемое) -> Число`), поэтому
        // ему не нужен обходной приём с `Никогда`-плейсхолдером этого
        // интерфейса — обычная, ничем не примечательная сигнатура метода
        // интерфейса.
        try self.installPreludeInterface("Печатаемое");
        // `Копируемое` — восстанавливает рефлективное глубокое
        // копирование при отправке (`отправить` иначе делает голое
        // поверхностное копирование, разделяя heap-payload'ы по указателю
        // между процессами); `реализация Копируемое` — опциональное
        // переопределение. `defineInterfaceImplementation` уже унифицирует
        // тип возврата метода интерфейса с ФАКТИЧЕСКИМ типом возврата impl
        // через тот же механизм `inferGenericSubstitution`/
        // `substituteGeneric`, что используется для обычных generic-
        // параметров, пока объявленный тип возврата интерфейса — голый
        // `.generic_parameter` (именно это `type_checker.zig`'s
        // `preludePass` создаёт для этой записи — одноразовый плейсхолдер,
        // не привязанный ни к одному реально объявленному параметру типа).
        try self.installPreludeInterface("Копируемое");
        // `Складываемое`/`Вычитаемое`/`Умножаемое`/`Делимое`/`Равнозначное`
        // — тот же приём, что у `Копируемое` выше (`type_checker.zig`'s
        // `preludePass` создаёт плейсхолдер на каждый интерфейс).
        try self.installPreludeInterface("Равнозначное");
        try self.installPreludeInterface("Складываемое");
        try self.installPreludeInterface("Вычитаемое");
        try self.installPreludeInterface("Умножаемое");
        try self.installPreludeInterface("Делимое");
    }

    fn installBuiltinModule(self: *Resolver, name: []const u8, exports: []const []const u8) !void {
        const module = try self.result.symbols.add(.{
            .name = name,
            .kind = .module,
            .span = .{ .file_id = 0, .start = 0, .end = 0 },
        });
        try self.scopes.declare(&self.result.symbols, module);
        var members = ModuleMembers{
            .module = module,
            .values = .init(self.result.allocator),
        };
        errdefer members.values.deinit();
        for (exports) |exported| {
            const symbol = try self.result.symbols.add(.{
                .name = exported,
                .kind = .builtin,
                .module_path = name,
                .span = .{ .file_id = 0, .start = 0, .end = 0 },
            });
            try members.values.put(exported, symbol);
        }
        try self.module_members.append(self.result.allocator, members);
    }

    fn installBuiltinType(self: *Resolver, name: []const u8) !void {
        const symbol = try self.result.symbols.add(.{
            .name = name,
            .kind = .type,
            .span = .{ .file_id = 0, .start = 0, .end = 0 },
        });
        try self.scopes.declare(&self.result.symbols, symbol);
    }

    fn installBuiltinModuleType(self: *Resolver, module_name: []const u8, name: []const u8) !void {
        const module = self.scopes.lookup(module_name) orelse return error.InvalidSymbol;
        const symbol = try self.result.symbols.add(.{
            .name = name,
            .kind = .type,
            .module_path = module_name,
            .span = .{ .file_id = 0, .start = 0, .end = 0 },
        });
        for (self.module_members.items) |*members| {
            if (members.module != module) continue;
            try members.values.put(name, symbol);
            return;
        }
        return error.InvalidSymbol;
    }

    fn predeclareImports(self: *Resolver, imports: []const ImportedModule) !void {
        for (imports) |import| {
            if (import.unqualified) {
                try self.predeclareUnqualifiedImport(import);
                continue;
            }
            const module = try self.result.symbols.add(.{
                .name = import.alias,
                .kind = .module,
                .span = import.span,
            });
            self.scopes.declare(&self.result.symbols, module) catch |err| switch (err) {
                error.DuplicateSymbol => try self.report(import.span, "Resolve Error: символ '{s}' уже объявлен", .{import.alias}),
                else => return err,
            };
            var members = ModuleMembers{
                .module = module,
                .values = .init(self.result.allocator),
            };
            errdefer members.values.deinit();
            for (import.exports) |exported| {
                const member = try self.result.symbols.add(.{
                    .name = exported.name,
                    .kind = exported.kind,
                    .module_path = exported.builtin_module_path orelse import.alias,
                    .is_exported = true,
                    .span = exported.span,
                });
                if (exported.origin) |origin| try self.result.imported_symbols.put(member, origin);
                if (members.values.contains(exported.name)) {
                    try self.report(exported.span, "Resolve Error: экспорт '{s}' повторён в модуле '{s}'", .{ exported.name, import.alias });
                } else {
                    try members.values.put(exported.name, member);
                }
                if (exported.origin == null) continue;
                for (exported.methods) |method| {
                    const method_symbol = try self.result.symbols.add(.{
                        .name = method.name,
                        .kind = .function,
                        .span = method.span,
                    });
                    try self.result.imported_methods.append(self.result.allocator, .{
                        .owner = member,
                        .name = method.name,
                        .symbol = method_symbol,
                        .origin = .{ .module = method.module, .declaration = method.declaration },
                    });
                }
                if (exported.variants.len != 0) {
                    var variants = EnumVariants{
                        .owner = member,
                        .values = .init(self.result.allocator),
                    };
                    errdefer variants.values.deinit();
                    for (exported.variants) |variant| {
                        const variant_symbol = try self.result.symbols.add(.{
                            .name = variant.name,
                            .kind = .enum_variant,
                            .owner_type = member,
                            .span = variant.span,
                        });
                        try variants.values.put(variant.name, variant_symbol);
                    }
                    try self.result.enum_variants.append(self.result.allocator, variants);
                }
            }
            try self.module_members.append(self.result.allocator, members);
        }
    }

    // Сливает экспорты неявного импорта прелюдии НАПРЯМУЮ в текущую
    // область видимости — без обёртки-модуля, без квалификации
    // `alias.Имя`, соответствуя тому, как панос разрешает обычную
    // top-level локальную декларацию (`Опция(T)`, а не `прелюдия.Опция(T)`).
    // Методы/варианты используют тот же самый механизм, что и
    // квалифицированный путь `predeclareImports` (заводят локальный символ
    // на каждый метод/вариант, ключ — владелец) — отличается только
    // видимость самого символа типа-владельца.
    fn predeclareUnqualifiedImport(self: *Resolver, import: ImportedModule) !void {
        for (import.exports) |exported| {
            const member = try self.result.symbols.add(.{
                .name = exported.name,
                .kind = exported.kind,
                .is_exported = true,
                .span = exported.span,
            });
            self.scopes.declare(&self.result.symbols, member) catch |err| switch (err) {
                error.DuplicateSymbol => try self.report(exported.span, "Resolve Error: символ '{s}' уже объявлен", .{exported.name}),
                else => return err,
            };
            if (exported.origin) |origin| try self.result.imported_symbols.put(member, origin);
            if (exported.origin == null) continue;
            for (exported.methods) |method| {
                const method_symbol = try self.result.symbols.add(.{
                    .name = method.name,
                    .kind = .function,
                    .span = method.span,
                });
                try self.result.imported_methods.append(self.result.allocator, .{
                    .owner = member,
                    .name = method.name,
                    .symbol = method_symbol,
                    .origin = .{ .module = method.module, .declaration = method.declaration },
                });
            }
            if (exported.variants.len != 0) {
                var variants = EnumVariants{
                    .owner = member,
                    .values = .init(self.result.allocator),
                };
                errdefer variants.values.deinit();
                for (exported.variants) |variant| {
                    const variant_symbol = try self.result.symbols.add(.{
                        .name = variant.name,
                        .kind = .enum_variant,
                        .owner_type = member,
                        .span = variant.span,
                    });
                    try variants.values.put(variant.name, variant_symbol);
                }
                try self.result.enum_variants.append(self.result.allocator, variants);
            }
        }
    }

    fn moduleMember(self: *const Resolver, module: symbols.SymbolId, name: []const u8) ?symbols.SymbolId {
        for (self.module_members.items) |members| {
            if (members.module == module) return members.values.get(name);
        }
        return null;
    }

    fn installPreludeInterface(self: *Resolver, name: []const u8) !void {
        const symbol = try self.result.symbols.add(.{
            .name = name,
            .kind = .type,
            .is_exported = true,
            .span = .{ .file_id = 0, .start = 0, .end = 0 },
        });
        try self.scopes.declare(&self.result.symbols, symbol);
    }

    fn installPreludeEnum(self: *Resolver, name: []const u8, variant_names: []const []const u8) !void {
        const owner = try self.result.symbols.add(.{
            .name = name,
            .kind = .type,
            .is_exported = true,
            .span = .{ .file_id = 0, .start = 0, .end = 0 },
        });
        try self.scopes.declare(&self.result.symbols, owner);
        var variants = EnumVariants{
            .owner = owner,
            .values = .init(self.result.allocator),
        };
        errdefer variants.values.deinit();
        for (variant_names) |variant_name| {
            const variant = try self.result.symbols.add(.{
                .name = variant_name,
                .kind = .enum_variant,
                .is_exported = true,
                .owner_type = owner,
                .span = .{ .file_id = 0, .start = 0, .end = 0 },
            });
            try variants.values.put(variant_name, variant);
        }
        try self.result.enum_variants.append(self.result.allocator, variants);
    }

    fn predeclare(self: *Resolver, tree: *const ast.Ast) !void {
        for (tree.program.?.declarations) |declaration| {
            switch (tree.decl(declaration).*) {
                .function => |value| {
                    _ = try self.registerDeclaration(declaration, value.name, .function, value.span, value.is_exported, false);
                },
                .constant => |value| {
                    _ = try self.registerDeclaration(declaration, value.name, .constant, value.span, value.is_exported, true);
                },
                .struct_decl => |value| {
                    _ = try self.registerDeclaration(declaration, value.name, .type, value.span, value.is_exported, false);
                },
                .interface_decl => |value| {
                    _ = try self.registerDeclaration(declaration, value.name, .type, value.span, value.is_exported, false);
                    for (value.default_methods) |method| {
                        const function = tree.decl(method).function;
                        _ = try self.registerMethod(method, function.name, function.span);
                    }
                },
                .type_alias => |value| {
                    _ = try self.registerDeclaration(declaration, value.name, .type, value.span, value.is_exported, false);
                },
                .enum_decl => |value| try self.registerEnumDeclaration(declaration, value),
                .foreign => |value| {
                    const symbol = try self.registerDeclaration(declaration, value.name, .function, value.span, false, false);
                    try self.resolveForeignFunction(symbol, value);
                },
                .impl => |value| for (value.methods) |method| {
                    const function = tree.decl(method).function;
                    _ = try self.registerMethod(method, function.name, function.span);
                },
                .import, .reexport, .error_node => {},
            }
        }
    }

    fn registerEnumDeclaration(self: *Resolver, declaration: ast.DeclId, value: anytype) !void {
        const owner = try self.registerDeclaration(declaration, value.name, .type, value.span, value.is_exported, false);
        var variants = EnumVariants{
            .owner = owner,
            .values = .init(self.result.allocator),
        };
        errdefer variants.values.deinit();
        for (value.variants) |variant| {
            const symbol = try self.result.symbols.add(.{
                .name = variant.name,
                .kind = .enum_variant,
                .is_exported = value.is_exported,
                .owner_type = owner,
                .span = variant.span,
            });
            if (variants.values.contains(variant.name)) {
                try self.report(variant.span, "Resolve Error: вариант '{s}' уже объявлен", .{variant.name});
            } else {
                try variants.values.put(variant.name, symbol);
            }
        }
        try self.result.enum_variants.append(self.result.allocator, variants);
    }

    fn registerDeclaration(
        self: *Resolver,
        declaration: ast.DeclId,
        name: []const u8,
        kind: symbols.SymbolKind,
        span: source.Span,
        is_exported: bool,
        is_const: bool,
    ) !symbols.SymbolId {
        const symbol = try self.result.symbols.add(.{
            .name = name,
            .kind = kind,
            .is_exported = is_exported,
            .is_const = is_const,
            .span = span,
        });
        self.scopes.declare(&self.result.symbols, symbol) catch |err| switch (err) {
            error.DuplicateSymbol => {
                if (kind == .type and isReservedBuiltinTypeName(name)) {
                    try self.report(span, "Resolve Error: имя '{s}' зарезервировано встроенным типом, выберите другое имя для своего типа", .{name});
                } else {
                    try self.report(span, "Resolve Error: символ '{s}' уже объявлен", .{name});
                }
            },
            else => return err,
        };
        try self.result.decl_symbols.put(declaration, symbol);
        return symbol;
    }

    // Голые (неквалифицированные, вне пространства имён модуля) имена
    // встроенных типов — в отличие от `сеть.*`/`строки.*`/`бд.*` builtin'ов,
    // эти напрямую сталкиваются с любым пользовательским `тип X = ...` с
    // тем же именем (`installBuiltinType` объявляет их прямо в корневую
    // область видимости). Перечислены здесь только чтобы дать более
    // понятную диагностику, чем общее "уже объявлен", когда пользователь
    // выбирает одно из этих довольно обычных слов для своего типа —
    // чаще всего `Запрос`, достаточно частое имя, чтобы быть реальной
    // ловушкой (авторитетный список — сайты вызова `installBuiltinType`
    // выше).
    fn isReservedBuiltinTypeName(name: []const u8) bool {
        const reserved = [_][]const u8{ "Файл", "Соединение", "Слушатель", "Запрос", "Соединение_БД" };
        for (reserved) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
        return false;
    }

    // Загружает `foreign.library` (ПРОИЗВОЛЬНУЮ, заданную пользователем
    // разделяемую библиотеку — не одну из собственных вендоренных
    // зависимостей проекта) и разрешает в ней `foreign.name`, кэшируя
    // полученный указатель на функцию в `symbol` — `compiler.zig`/`vm.zig`
    // позже встроит его в скомпилированную `Program`. См. doc-комментарий
    // `Resolution.foreign_functions` — почему ничто здесь не становится
    // хранимым полем самой `Resolution`.
    fn resolveForeignFunction(self: *Resolver, symbol: symbols.SymbolId, foreign: anytype) !void {
        // Два отдельных guard'а, не один: `comptime` обрабатывает РЕАЛЬНУЮ
        // компиляцию wasm32-freestanding (браузерная сборка) — Sema
        // полностью исключает ветку `std.DynLib`, см. doc-комментарий
        // `Resolution.foreign_functions`. Проверка `target_profile` в
        // рантайме обрабатывает все ОСТАЛЬНЫЕ случаи, которым ТАКЖЕ не
        // следует загружать нативную библиотеку — например, запросы вида
        // LSP/`checkSourceForTarget` "прошла бы эта программа для
        // `.browser_interpreter`", которые выполняются внутри обычного
        // НАТИВНОГО бинарника (поэтому одна лишь comptime-проверка для
        // них никогда не сработает).
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.report(foreign.span, "Resolve Error: 'внешний' недоступно в этом runtime-таргете", .{});
        } else if (self.target_profile != .native) {
            try self.report(foreign.span, "Resolve Error: 'внешний' недоступно в этом runtime-таргете", .{});
        } else if ((comptime builtin.target.os.tag != .windows and builtin.link_libc) and
            (std.mem.eql(u8, foreign.library, "libc") or std.mem.eql(u8, foreign.library, "хост")))
        {
            // `std.c.dlopen`, использованный БЕЗУСЛОВНО (без guard'а
            // `builtin.link_libc`), заставил бы КАЖДЫЙ тестовый бинарник,
            // который просто компилирует `resolver.zig` (практически все
            // — через `predeclare`/`resolveModuleForTarget`, независимо
            // от того, объявляет ли конкретный тест `внешний`), линковать
            // libc на этапе компиляции, даже если он иначе никогда бы в
            // ней не нуждался — собственный `std.DynLib` из Zig (путь,
            // который заменяет эта ветка) избегает именно этого, внутренне
            // выбирая чистый Zig-парсер ELF без libc (`ElfDynLib`) вместо
            // основанного на libc-`dlopen` (`DlDynLib`), когда `!builtin.
            // link_libc` — этот резервный вариант прямой вызов `std.c.
            // dlopen` бесплатно не получает, поэтому здесь нужен тот же
            // guard.
            //
            // `внешний "libc"` вообще не нужно искать и загружать
            // ОТДЕЛЬНЫЙ файл разделяемого объекта — libc УЖЕ слинкована
            // в этот самый процесс (каждый нативный бинарник паноса
            // линкует libc). `внешний "хост"` использует тот же POSIX-
            // механизм для Zig-исполняемого файла, встраивающего Panos:
            // его точки входа `pub export fn` в C-ABI живут в образе
            // основного процесса, а не в поддельной динамической
            // библиотеке рядом с картой. Хост должен включить `rdynamic`,
            // чтобы эти экспорты попали в таблицу динамических символов.
            // `dlopen(NULL, ...)` — это POSIX-способ получить хендл на
            // уже загруженный образ самой запущенной программы (основной
            // исполняемый файл + каждая уже отображённая разделяемая
            // библиотека, включая libc) — первый параметр `std.c.dlopen`
            // это `?[*:0]const u8`, так что `null` выражается напрямую,
            // без необходимости опускаться до сырых libc-биндингов
            // вручную.
            //
            // dlopen(NULL) не требует ни имени файла, ни знания о
            // конкретном варианте libc, и одинаково валиден на macOS и
            // на любой POSIX-системе — используется безусловно и для
            // библиотек процесс-образа на любой не-Windows платформе, не
            // только на Linux.
            const handle = std.c.dlopen(null, .{ .LAZY = true }) orelse {
                try self.report(foreign.span, "Resolve Error: библиотека '{s}' не найдена (dlopen(NULL) в этом процессе)", .{foreign.library});
                return;
            };
            const name_z = try self.result.arena.allocator().dupeZ(u8, foreign.name);
            const fn_ptr = std.c.dlsym(handle, name_z) orelse {
                try self.report(foreign.span, "Resolve Error: библиотека '{s}' не экспортирует символ '{s}'", .{ foreign.library, foreign.name });
                return;
            };
            try self.result.foreign_functions.put(symbol, @intFromPtr(fn_ptr));
        } else if (comptime builtin.target.os.tag == .windows) {
            // `std.DynLib` в этой версии Zig вообще не имеет реализации
            // для Windows (внутренний switch по типам в
            // `dynamic_library.zig` перечисляет только linux/macos/
            // bsd-семейство, всё остальное — включая Windows — попадает
            // в `@compileError("unsupported platform")`).
            //
            // `std` также нигде в этой версии не предоставляет биндинги
            // `LoadLibraryW`/`GetProcAddress` — самодельные декларации
            // `extern "kernel32"` ниже — это прямой Win32 API, той же
            // формы, что `std.DynLib` использовал внутри себя в версиях
            // Zig, где Windows ПОДДЕРЖИВАЛАСЬ.
            const filename = try self.foreignLibraryFilename(self.result.arena.allocator(), foreign.library);
            const filename_w = std.unicode.utf8ToUtf16LeAllocZ(self.result.arena.allocator(), filename) catch {
                try self.report(foreign.span, "Resolve Error: имя библиотеки '{s}' не в UTF-8", .{filename});
                return;
            };
            const handle = WindowsDynLib.LoadLibraryW(filename_w.ptr) orelse {
                try self.report(foreign.span, "Resolve Error: библиотека '{s}' не найдена ({s})", .{ foreign.library, filename });
                return;
            };
            const name_z = try self.result.arena.allocator().dupeZ(u8, foreign.name);
            const fn_ptr = WindowsDynLib.GetProcAddress(handle, name_z) orelse {
                try self.report(foreign.span, "Resolve Error: библиотека '{s}' не экспортирует символ '{s}'", .{ foreign.library, foreign.name });
                return;
            };
            try self.result.foreign_functions.put(symbol, @intFromPtr(fn_ptr));
        } else {
            const filename = try self.foreignLibraryFilename(self.result.arena.allocator(), foreign.library);
            const filename_z = try self.result.arena.allocator().dupeZ(u8, filename);
            var library = std.DynLib.openZ(filename_z) catch {
                try self.report(foreign.span, "Resolve Error: библиотека '{s}' не найдена ({s})", .{ foreign.library, filename });
                return;
            };
            const name_z = try self.result.arena.allocator().dupeZ(u8, foreign.name);
            const fn_ptr = library.lookup(*anyopaque, name_z) orelse {
                try self.report(foreign.span, "Resolve Error: библиотека '{s}' не экспортирует символ '{s}'", .{ foreign.library, foreign.name });
                return;
            };
            try self.result.foreign_functions.put(symbol, @intFromPtr(fn_ptr));
        }
    }

    // Минимальные прямые биндинги Win32 — `std.DynLib` не покрывает
    // Windows в этой версии Zig (см. ветку Windows в
    // `resolveForeignFunction`). `callconv(.winapi)` соответствует
    // каждому другому сырому Win32 extern, уже используемому там, где
    // проект напрямую обращается к Windows.
    const WindowsDynLib = if (builtin.target.os.tag == .windows) struct {
        extern "kernel32" fn LoadLibraryW(lpLibFileName: [*:0]const u16) callconv(.winapi) ?*anyopaque;
        extern "kernel32" fn GetProcAddress(hModule: *anyopaque, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    } else struct {};

    fn foreignLibraryFilename(self: *Resolver, allocator: std.mem.Allocator, logical_name: []const u8) ![]const u8 {
        return resolveForeignLibraryPath(allocator, self.source_path, logical_name);
    }

    fn registerMethod(self: *Resolver, declaration: ast.DeclId, name: []const u8, span: source.Span) !symbols.SymbolId {
        const symbol = try self.result.symbols.add(.{
            .name = name,
            .kind = .function,
            .span = span,
        });
        try self.result.decl_symbols.put(declaration, symbol);
        return symbol;
    }

    fn resolveDeclarations(self: *Resolver, tree: *const ast.Ast) !void {
        for (tree.program.?.declarations) |declaration| {
            switch (tree.decl(declaration).*) {
                .function => |value| try self.resolveFunction(declaration, value.parameters, value.body),
                .constant => |value| try self.resolveExpression(tree, value.value),
                .impl => |value| for (value.methods) |method| {
                    const function = tree.decl(method).function;
                    try self.resolveFunction(method, function.parameters, function.body);
                },
                .interface_decl => |value| for (value.default_methods) |method| {
                    const function = tree.decl(method).function;
                    try self.resolveFunction(method, function.parameters, function.body);
                },
                .import, .reexport, .struct_decl, .enum_decl, .foreign, .type_alias, .error_node => {},
            }
        }
    }

    fn resolveFunction(self: *Resolver, declaration: ast.DeclId, parameters: []const ast.ParamDecl, body: []const ast.StmtId) !void {
        _ = try self.scopes.push();
        defer self.popScopeAndWarnUnused() catch unreachable;
        const parameter_symbols = try self.declareParameters(parameters);
        try self.result.function_parameters.put(declaration, parameter_symbols);
        try self.resolveStatements(body);
    }

    fn declareParameters(self: *Resolver, parameters: []const ast.ParamDecl) ![]const symbols.SymbolId {
        var parameter_symbols: std.ArrayList(symbols.SymbolId) = .empty;
        defer parameter_symbols.deinit(self.result.allocator);
        for (parameters) |parameter| {
            // `track_unused = false` — параметры функции намеренно
            // исключены из предупреждения о неиспользованных переменных:
            // часто намеренно не используются при реализации сигнатуры
            // интерфейса/колбэка, требующей точного соответствия.
            try parameter_symbols.append(self.result.allocator, try self.declareLocal(parameter.name, parameter.span, true, false, false));
        }
        return self.result.arena.allocator().dupe(symbols.SymbolId, parameter_symbols.items);
    }

    // `track_unused` — `unused_check_symbols` покрывает ТОЛЬКО переменные,
    // объявленные через `пер` (обычные или деструктурированные), и
    // переменные for-цикла, НИКОГДА параметры функции или биндеры
    // match/pattern. `"_"` уже исключается каждым ВЫЗЫВАЮЩИМ (тот же
    // opt-out, что `_` уже получает при сопоставлении с образцом), здесь
    // повторно не проверяется.
    fn declareLocal(self: *Resolver, name: []const u8, span: source.Span, is_const: bool, is_pattern_binder: bool, track_unused: bool) !symbols.SymbolId {
        if (isReservedBuiltin(name)) {
            try self.report(span, "Resolve Error: '{s}' — зарезервированное имя, нельзя использовать", .{name});
        }
        const symbol = try self.result.symbols.add(.{
            .name = name,
            .kind = .variable,
            .is_const = is_const,
            .is_pattern_binder = is_pattern_binder,
            .span = span,
        });
        // `_` — универсальный биндер-заглушка (параметры, `пер`, биндеры
        // образцов — все одинаково), рассчитан на то, чтобы писаться
        // произвольное число раз в одной области видимости (например,
        // два отброшенных параметра лямбды, `функ(_: А, _: Б)`) без
        // последующего поиска, поэтому намеренно освобождён от проверки
        // на повторное объявление, которой подчиняется любое другое имя.
        if (!std.mem.eql(u8, name, "_")) {
            self.scopes.declare(&self.result.symbols, symbol) catch |err| switch (err) {
                error.DuplicateSymbol => try self.report(span, "Resolve Error: символ '{s}' уже объявлен", .{name}),
                else => return err,
            };
        }
        if (track_unused and !std.mem.eql(u8, name, "_")) try self.unused_check_symbols.put(symbol, {});
        return symbol;
    }

    fn resolveStatements(self: *Resolver, statements: []const ast.StmtId) anyerror!void {
        for (statements) |statement| try self.resolveStatement(statement);
    }

    fn resolveStatement(self: *Resolver, statement: ast.StmtId) anyerror!void {
        const value = self.tree.stmt(statement).*;
        switch (value) {
            .let => |let| {
                try self.resolveExpression(self.tree, let.value);
                var bindings: std.ArrayList(symbols.SymbolId) = .empty;
                defer bindings.deinit(self.result.allocator);
                if (let.name) |name| {
                    const symbol = try self.declareLocal(name, let.span, let.is_const, false, true);
                    try self.result.stmt_symbols.put(statement, symbol);
                    try bindings.append(self.result.allocator, symbol);
                } else {
                    for (let.destructure_names) |name| {
                        try bindings.append(self.result.allocator, try self.declareLocal(name, let.span, let.is_const, false, true));
                    }
                }
                if (bindings.items.len != 0) try self.result.stmt_bindings.put(statement, try self.result.arena.allocator().dupe(symbols.SymbolId, bindings.items));
            },
            .return_stmt => |return_stmt| if (return_stmt.value) |return_value| try self.resolveExpression(self.tree, return_value),
            .expr => |expression| try self.resolveExpression(self.tree, expression.value),
            .for_in => |loop| {
                try self.resolveExpression(self.tree, loop.iterable);
                _ = try self.scopes.push();
                defer self.popScopeAndWarnUnused() catch unreachable;
                var bindings: std.ArrayList(symbols.SymbolId) = .empty;
                defer bindings.deinit(self.result.allocator);
                for (loop.names) |name| try bindings.append(self.result.allocator, try self.declareLocal(name, loop.span, false, false, true));
                try self.result.stmt_bindings.put(statement, try self.result.arena.allocator().dupe(symbols.SymbolId, bindings.items));
                try self.resolveStatements(loop.body);
            },
            .for_range => |range| {
                try self.resolveExpression(self.tree, range.start);
                try self.resolveExpression(self.tree, range.end);
                _ = try self.scopes.push();
                defer self.popScopeAndWarnUnused() catch unreachable;
                const symbol = try self.declareLocal(range.name, range.span, false, false, true);
                try self.result.stmt_bindings.put(statement, try self.result.arena.allocator().dupe(symbols.SymbolId, &.{symbol}));
                try self.resolveStatements(range.body);
            },
            .continue_stmt, .break_stmt, .error_node => {},
        }
    }

    fn resolveExpression(self: *Resolver, tree: *const ast.Ast, expression: ast.ExprId) anyerror!void {
        self.tree = tree;
        switch (tree.expr(expression).*) {
            .ident => |ident| {
                const symbol = try self.scopes.lookupTrackingCaptures(&self.result.symbols, ident.name) orelse blk: {
                    try self.report(ident.span, "Resolve Error: неопределённое имя '{s}'", .{ident.name});
                    break :blk symbols.invalid_symbol;
                };
                try self.result.expr_symbols.put(expression, symbol);
                // ЛЮБАЯ ссылка через голый `.ident` (чтение ИЛИ цель
                // присваивания — левая часть `x = 5` разрешается через
                // тот же самый case, отдельная обработка не нужна) метит
                // символ как использованный, для предупреждения о
                // неиспользованной переменной в `popScope` ниже.
                if (symbol != symbols.invalid_symbol) try self.used_symbols.put(symbol, {});
            },
            .unary => |unary| try self.resolveExpression(tree, unary.operand),
            .cast => |cast| try self.resolveExpression(tree, cast.operand),
            .binary => |binary| {
                try self.resolveExpression(tree, binary.left);
                try self.resolveExpression(tree, binary.right);
            },
            .call => |call| {
                try self.resolveExpression(tree, call.callee);
                for (call.arguments) |argument| try self.resolveExpression(tree, argument);
            },
            .spawn => |spawn| try self.resolveExpression(tree, spawn.call),
            .select_wait => |select| try self.resolveExpression(tree, select.source),
            .property => |property| {
                try self.resolveExpression(tree, property.object);
                if (self.result.expr_symbols.get(property.object)) |object_symbol| {
                    const entry = self.result.symbols.get(object_symbol) orelse return;
                    if (entry.kind == .module) {
                        if (self.moduleMember(object_symbol, property.property)) |member| {
                            try self.result.expr_symbols.put(expression, member);
                        } else {
                            try self.report(property.span, "Resolve Error: у модуля '{s}' нет экспорта '{s}'", .{ entry.name, property.property });
                        }
                    } else if (entry.kind == .type) {
                        if (self.result.findEnumVariant(object_symbol, property.property)) |variant| {
                            try self.result.expr_symbols.put(expression, variant);
                        }
                    }
                }
            },
            .if_expr => |conditional| {
                try self.resolveExpression(tree, conditional.condition);
                try self.resolveScopedStatements(conditional.then_branch);
                try self.resolveScopedStatements(conditional.else_branch);
            },
            .while_expr => |loop| {
                try self.resolveExpression(tree, loop.condition);
                try self.resolveScopedStatements(loop.body);
            },
            .tuple => |tuple| for (tuple.elements) |element| try self.resolveExpression(tree, element),
            .lambda => |lambda| try self.resolveLambda(tree, expression, lambda),
            .array => |array| for (array.elements) |element| try self.resolveExpression(tree, element),
            .map => |map| for (map.entries) |entry| {
                try self.resolveExpression(tree, entry.key);
                try self.resolveExpression(tree, entry.value);
            },
            .index => |index| {
                try self.resolveExpression(tree, index.object);
                // `ф[Тип](...)` — вызов с явным generic-аргументом
                // парсится как обычный `Index_Expr`. Индексация голого
                // символа ФУНКЦИИ никогда не была валидной обычной
                // семантикой (индексируемы только массивы/соответствия)
                // — когда `index.object` разрешается в такой символ,
                // `index.index` может быть именем ТИПА (у встроенного
                // примитива вроде `Число`/`Строка` вообще нет
                // разрешимого символа-значения в этой таблице областей
                // видимости, в отличие от автозарегистрированного
                // конструктора пользовательской структуры), а не обычной
                // ссылкой на значение. У резолвера нет понятия о
                // generic'ах (это вычисляется позже, `type_checker.zig`),
                // поэтому он не может отличить явный generic-вызов от
                // реально сломанной индексации здесь — он просто
                // пропускает разрешение `index.index` как значения в
                // этой одной узкой форме, полностью откладывая решение
                // на `resolveTypeFromExpr` (делает собственный
                // независимый поиск, не нуждается в `expr_symbols` этого
                // прохода) — является ли это реальным аргументом типа.
                // Любая ДРУГАЯ цель индексации (массивы, соответствия,
                // неразрешённые имена) сохраняет сегодняшнее поведение
                // без изменений — неразрешённая индексация там остаётся
                // жёсткой Resolve Error.
                const indexes_a_function = if (self.result.expr_symbols.get(index.object)) |object_symbol|
                    if (self.result.symbols.get(object_symbol)) |entry| entry.kind == .function else false
                else
                    false;
                if (!indexes_a_function) try self.resolveExpression(tree, index.index);
            },
            .try_expr => |try_expression| try self.resolveExpression(tree, try_expression.value),
            .match_expr => |match| {
                try self.resolveExpression(tree, match.subject);
                for (match.arms) |arm| {
                    _ = try self.scopes.push();
                    defer self.popScopeAndWarnUnused() catch unreachable;
                    try self.resolvePattern(tree, arm.pattern);
                    try self.resolveStatements(arm.body);
                }
            },
            .number, .boolean, .string, .error_node => {},
        }
    }

    fn resolveScopedStatements(self: *Resolver, statements: []const ast.StmtId) anyerror!void {
        _ = try self.scopes.push();
        defer self.popScopeAndWarnUnused() catch unreachable;
        try self.resolveStatements(statements);
    }

    fn resolveLambda(self: *Resolver, tree: *const ast.Ast, expression: ast.ExprId, lambda: anytype) anyerror!void {
        _ = try self.scopes.enterLambda();
        const parameter_symbols = try self.declareParameters(lambda.parameters);
        try self.result.lambda_parameters.put(expression, parameter_symbols);
        try self.resolveStatements(lambda.body);
        var captures = try self.scopes.leaveLambda();
        defer captures.deinit();
        try self.result.lambda_captures.put(expression, try self.result.arena.allocator().dupe(symbols.SymbolId, captures.values.items));
        _ = tree;
    }

    fn resolvePattern(self: *Resolver, tree: *const ast.Ast, pattern: ast.PatternId) anyerror!void {
        switch (tree.pattern(pattern).*) {
            .literal => |literal| try self.resolveExpression(tree, literal.value),
            .ident => |ident| {
                const symbol = try self.declareLocal(ident.name, ident.span, false, true, false);
                try self.result.pattern_symbols.put(pattern, symbol);
            },
            .constructor => |constructor| {
                if (constructor.module_name) |owner_name| {
                    // 3-уровневый квалифицированный образец из `parser.zig`
                    // (`алиас.Тип.Вариант(...)`) склеивает первые два
                    // сегмента в ОДНУ строку `module_name` ("алиас.Тип"),
                    // а не хранит их раздельно — обычный поиск в области
                    // видимости по этой составной строке никогда не
                    // может увенчаться успехом (области видимости
                    // хранят только голые идентификаторы). Исправляется
                    // разбиением по ПОСЛЕДНЕЙ '.' и разрешением в два
                    // шага — сначала алиас модуля, затем собственный член
                    // этого модуля — точно так же, как это уже делает
                    // обычная квалифицированная аннотация типа
                    // `алиас.Тип` в других местах.
                    const owner_symbol = self.scopes.lookupTrackingCaptures(&self.result.symbols, owner_name) catch null orelse blk: {
                        const separator = std.mem.lastIndexOfScalar(u8, owner_name, '.') orelse break :blk null;
                        const module_alias = owner_name[0..separator];
                        const type_name = owner_name[separator + 1 ..];
                        const module_symbol = try self.scopes.lookupTrackingCaptures(&self.result.symbols, module_alias) orelse break :blk null;
                        break :blk self.moduleMember(module_symbol, type_name);
                    } orelse symbols.invalid_symbol;
                    const owner = self.result.symbols.get(owner_symbol);
                    if (owner) |entry| {
                        if (entry.kind == .type) {
                            if (self.result.findEnumVariant(owner_symbol, constructor.name)) |variant| {
                                try self.result.pattern_symbols.put(pattern, variant);
                            } else {
                                try self.report(constructor.span, "Resolve Error: у перечисления '{s}' нет варианта '{s}'", .{ owner_name, constructor.name });
                            }
                        } else {
                            try self.report(constructor.span, "Resolve Error: '{s}' не является перечислением", .{owner_name});
                        }
                    } else {
                        try self.report(constructor.span, "Resolve Error: неопределённый тип перечисления '{s}'", .{owner_name});
                    }
                }
                for (constructor.arguments) |argument| try self.resolvePattern(tree, argument);
            },
            .wildcard, .error_node => {},
        }
    }
};

pub fn resolve(allocator: std.mem.Allocator, tree: *const ast.Ast) !Resolution {
    return resolveWithImports(allocator, tree, &.{});
}

pub fn resolveWithImports(allocator: std.mem.Allocator, tree: *const ast.Ast, imports: []const ImportedModule) !Resolution {
    return resolveModule(allocator, tree, imports, false);
}

pub fn resolveModule(allocator: std.mem.Allocator, tree: *const ast.Ast, imports: []const ImportedModule, skip_prelude_hardcode: bool) !Resolution {
    return resolveModuleForTarget(allocator, tree, imports, skip_prelude_hardcode, .native, "");
}

pub fn resolveModuleForTarget(allocator: std.mem.Allocator, tree: *const ast.Ast, imports: []const ImportedModule, skip_prelude_hardcode: bool, target_profile: target_policy.TargetProfile, source_path: []const u8) !Resolution {
    var result = try Resolution.init(allocator);
    errdefer result.deinit();
    var resolver = try Resolver.init(&result);
    defer resolver.deinit();
    resolver.tree = tree;
    resolver.target_profile = target_profile;
    resolver.source_path = source_path;

    try resolver.installBuiltins(skip_prelude_hardcode);
    try resolver.predeclareImports(imports);
    try resolver.predeclare(tree);
    try resolver.resolveDeclarations(tree);
    return result;
}

fn isReservedBuiltin(name: []const u8) bool {
    const names = [_][]const u8{
        "Ошибка",
        "длина",
        "паника",
        "получить",
        "отправить",
        "себя",
        "наблюдать",
        "получить_сигнал",
        "убить",
        "связать",
        "ждать",
        "встроку",
        "Целое",
        "Число",
        "Итерируемое",
        "ограничить_почту",
        "отправить_или",
        "отмена",
        "отменено",
    };
    for (names) |reserved| {
        if (std.mem.eql(u8, name, reserved)) return true;
    }
    return false;
}

test "resolver links closures to outer locals and functions" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(
        std.testing.allocator,
        "функ внешняя(значение: Число) -> Число\nзначение\nконец\nфунк вычислить(параметр: Число) -> Число\nпер локальная = параметр\nпер замыкание = функ(добавка)\nлокальная + добавка + внешняя(1)\nконец\nзамыкание(2)\nконец",
        0,
    );
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();

    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
    const function = parsed.ast.decl(parsed.ast.program.?.declarations[1]).function;
    const lambda = parsed.ast.stmt(function.body[1]).let.value;
    const captures = resolved.lambda_captures.get(lambda).?;
    try std.testing.expectEqual(@as(usize, 2), captures.len);
    try std.testing.expectEqualStrings("локальная", resolved.symbols.get(captures[0]).?.name);
    try std.testing.expectEqualStrings("внешняя", resolved.symbols.get(captures[1]).?.name);
}

test "resolver accumulates undefined and duplicate name diagnostics" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ f() -> Число\nпер x = нет\nпер x = 1\nx\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();

    try std.testing.expectEqual(@as(usize, 2), resolved.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Resolve Error: неопределённое имя 'нет'", resolved.diagnostics.items.items[0].message);
    try std.testing.expectEqualStrings("Resolve Error: символ 'x' уже объявлен", resolved.diagnostics.items.items[1].message);
}

test "resolver links qualified enum constructors to variant symbols" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип Ответ = перечисление\nДа\nНет\nконец\nфунк f() -> Ответ\nОтвет.Да()\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();

    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
    const function = parsed.ast.decl(parsed.ast.program.?.declarations[1]).function;
    const call = parsed.ast.stmt(function.body[0]).expr.value;
    const property = parsed.ast.expr(call).call.callee;
    const variant = resolved.expr_symbols.get(property).?;
    try std.testing.expectEqual(symbols.SymbolKind.enum_variant, resolved.symbols.get(variant).?.kind);
    try std.testing.expectEqualStrings("Да", resolved.symbols.get(variant).?.name);
}

test "resolver links qualified module exports without global leakage" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "импорт \"./математика\" как мат\nфунк старт() -> Число\nмат.сложить(1, 2)\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    const imports = [_]ImportedModule{.{
        .alias = "мат",
        .span = .{ .file_id = 0, .start = 0, .end = 1 },
        .exports = &.{.{
            .name = "сложить",
            .kind = .function,
            .span = .{ .file_id = 1, .start = 0, .end = 7 },
        }},
    }};
    var resolved = try resolveWithImports(std.testing.allocator, &parsed.ast, &imports);
    defer resolved.deinit();

    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
    const start = parsed.ast.decl(parsed.ast.program.?.declarations[1]).function;
    const callee = parsed.ast.stmt(start.body[0]).expr.value;
    const call = parsed.ast.expr(callee).call;
    const symbol = resolved.expr_symbols.get(call.callee).?;
    const entry = resolved.symbols.get(symbol).?;
    try std.testing.expectEqual(symbols.SymbolKind.function, entry.kind);
    try std.testing.expectEqualStrings("мат::сложить", entry.full_name);
}

test "resolver reports unknown qualified module exports" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "импорт \"./математика\" как мат\nфунк старт() -> Число\nмат.нет(1)\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    const imports = [_]ImportedModule{.{
        .alias = "мат",
        .span = .{ .file_id = 0, .start = 0, .end = 1 },
        .exports = &.{},
    }};
    var resolved = try resolveWithImports(std.testing.allocator, &parsed.ast, &imports);
    defer resolved.deinit();

    try std.testing.expectEqual(@as(usize, 1), resolved.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Resolve Error: у модуля 'мат' нет экспорта 'нет'", resolved.diagnostics.items.items[0].message);
}

test "resolver records all statement binders for destructuring and loops" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ f() -> Пусто\nпер (ключ, значение) = (\"a\", 1)\nдля элемент в массив(1) цикл\nэлемент\nконец\nдля индекс = 1 по 2 цикл\nиндекс\nконец\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();

    // 2, а не 0: `ключ`/`значение` (деструктурированы, строка 2) нигде
    // в этом теле не упоминаются — оба теперь выдают предупреждение
    // "неиспользованная переменная". `элемент`/`индекс` действительно
    // упоминаются внутри своих циклов, поэтому ни один из них не
    // предупреждает. Порядок между двумя предупреждениями НЕ
    // гарантируется — `popScopeAndWarnUnused` обходит `StringHashMap`
    // (`symbols.Scope.symbols`), чей порядок итерации не определён.
    try std.testing.expectEqual(@as(usize, 2), resolved.diagnostics.items.items.len);
    try std.testing.expectEqual(diagnostic.Severity.warning, resolved.diagnostics.items.items[0].severity);
    try std.testing.expectEqual(diagnostic.Severity.warning, resolved.diagnostics.items.items[1].severity);
    const has_klyuch = std.mem.eql(u8, resolved.diagnostics.items.items[0].message, "неиспользованная переменная 'ключ'") or
        std.mem.eql(u8, resolved.diagnostics.items.items[1].message, "неиспользованная переменная 'ключ'");
    const has_znachenie = std.mem.eql(u8, resolved.diagnostics.items.items[0].message, "неиспользованная переменная 'значение'") or
        std.mem.eql(u8, resolved.diagnostics.items.items[1].message, "неиспользованная переменная 'значение'");
    try std.testing.expect(has_klyuch);
    try std.testing.expect(has_znachenie);
    const function = parsed.ast.decl(parsed.ast.program.?.declarations[0]).function;
    const destructure = resolved.stmt_bindings.get(function.body[0]).?;
    const for_in = resolved.stmt_bindings.get(function.body[1]).?;
    const for_range = resolved.stmt_bindings.get(function.body[2]).?;
    try std.testing.expectEqual(@as(usize, 2), destructure.len);
    try std.testing.expectEqualStrings("ключ", resolved.symbols.get(destructure[0]).?.name);
    try std.testing.expectEqual(@as(usize, 1), for_in.len);
    try std.testing.expectEqualStrings("элемент", resolved.symbols.get(for_in[0]).?.name);
    try std.testing.expectEqual(@as(usize, 1), for_range.len);
    try std.testing.expectEqualStrings("индекс", resolved.symbols.get(for_range[0]).?.name);
}

test "resolver warns on an unused пер-variable" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ f() -> Число\nпер x: Число = 1\n2\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();

    try std.testing.expectEqual(@as(usize, 1), resolved.diagnostics.items.items.len);
    try std.testing.expectEqual(diagnostic.Severity.warning, resolved.diagnostics.items.items[0].severity);
    try std.testing.expectEqualStrings("неиспользованная переменная 'x'", resolved.diagnostics.items.items[0].message);
}

test "resolver does not warn on a used пер-variable" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ f() -> Число\nпер x: Число = 1\nx\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();

    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
}

test "resolver does not warn on пер-variable used only as an assignment target" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    // `x = 2` разрешает `x` через тот же case `.ident`, что и чтение
    // (см. doc-комментарий `resolveExpression`) — сознательный выбор не
    // различать чтение и использование только для записи.
    var lexed = try lexer.tokenize(std.testing.allocator, "функ f() -> Число\nпер x: Число = 1\nx = 2\nx\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();

    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
}

test "resolver does not warn on an unused function parameter" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ f(x: Число) -> Число\n1\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();

    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
}

test "resolver does not warn on an underscore-named пер-variable" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ f() -> Число\nпер _: Число = 1\n2\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();

    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
}
