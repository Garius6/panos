const std = @import("std");
const builtin = @import("builtin");
const ast = @import("ast.zig");
const diagnostic = @import("diagnostic.zig");
const source = @import("source.zig");
const symbols = @import("symbols.zig");
const target_policy = @import("target.zig");

// Every ambient native builtin module name (`installBuiltins` below
// registers each of these) — `module_loader.zig`'s import search uses the
// SAME list to decide whether `импорт <имя>` with no `.ps` file anywhere
// on the search path should silently resolve to the native module instead
// of a `FileNotFound` error (documented behavior,
// `docs/src/getting-started/installation.md` § "Поиск модулей" — real
// gap found auditing panosiki: `импорт время`/`импорт фс`/etc. failed
// outright before this, since NOTHING taught the loader these names
// don't need a file at all).
pub const native_builtin_modules = [_][]const u8{
    "фс",
    "ос",
    "время",
    "ввод_вывод",
    "строки",
    "DOM",
    "сжатие",
    "синтаксис",
    "сеть",
    "бд",
};

// Export list per native module — the SAME data `installBuiltins` below
// passes to `installBuiltinModule` inline (kept separate rather than
// refactoring those call sites to read from this table, to avoid
// touching already-tested code for a second consumer). Used by
// `module_linker.zig` to bind an ALIASED native import (`импорт
// "ввод_вывод" как ио`) — `module_loader.zig`'s `native_module` field on
// `Import` says a name resolved natively, but the alias itself still
// needs SOMETHING declared as its exports, exactly like a real file
// import gets from `buildExportsForTarget`.
pub fn nativeModuleExports(name: []const u8) ?[]const []const u8 {
    const table = [_]struct { name: []const u8, exports: []const []const u8 }{
        .{ .name = "фс", .exports = &.{ "есть", "удалить", "прочитать", "записать", "открыть", "это_директория", "создать_директорию", "список_директории", "удалить_директорию" } },
        .{ .name = "ос", .exports = &.{ "аргументы", "версия_паноса", "окружение", "установить_окружение", "удалить_окружение", "выполнить", "завершить" } },
        .{ .name = "время", .exports = &.{ "сейчас_мс", "монотонно_мс", "спать_мс" } },
        .{ .name = "ввод_вывод", .exports = &.{ "печать", "строка", "прочитать_строку" } },
        .{ .name = "строки", .exports = &.{
            "байт",
            "длина_байт",
            "срез_байт",
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
        .{ .name = "DOM", .exports = &.{ "текст", "установить_текст", "на_клик", "текст_строка", "установить_текст_строка", "значение_поля", "установить_значение_поля", "создать_и_добавить", "после_кадра" } },
        .{ .name = "сжатие", .exports = &.{"разжать_gzip"} },
        .{ .name = "синтаксис", .exports = &.{ "структуры", "поля", "импорты", "аннотации", "аргумент_аннотации", "аннотации_поля", "аргумент_аннотации_поля" } },
        .{ .name = "сеть", .exports = &.{ "подключиться", "кодировать_url", "декодировать_url", "http_запрос", "http_запрос_sync", "http_сервер_слушать" } },
        .{ .name = "бд", .exports = &.{"открыть"} },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.exports;
    }
    return null;
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
    // Set ONLY for a native-builtin export reached through an ALIASED
    // `импорт "ввод_вывод" как ио` — the member's `module_path` must stay
    // the module's REAL name ("ввод_вывод"), never the local alias
    // ("ио"), because every `compileXBuiltin`/`isBuiltinModule` dispatch
    // in `compiler.zig`/`type_checker.zig` hardcodes the real name.
    // `null` (the overwhelmingly common case — a real file import) keeps
    // `predeclareImports`'s existing `module_path = import.alias`
    // behavior exactly as before.
    builtin_module_path: ?[]const u8 = null,
};

// A variant of an imported enum type — construction/matching is entirely
// name-string-based at compile time, so unlike methods no declaration or
// FunctionId needs to travel with it, just the bare name.
pub const ImportedVariantExport = struct {
    name: []const u8,
    span: source.Span,
};

pub const ImportedSymbolOrigin = struct {
    module: usize,
    declaration: ast.DeclId,
};

// A method declared on an imported owner type — dispatched structurally on
// the owner's value (`точка.метод()`), never bound to a name in scope, so it
// needs its own local Symbol_Id minted alongside the owner's, not a scope
// declaration like other imported exports.
pub const ImportedMethodExport = struct {
    name: []const u8,
    // The module where this method's `функ` body is physically written
    // (an impl block's own file) — needed separately from the owning
    // export's `origin.module` (the STRUCT's module) because a
    // qualified impl target (`реализация X для Модуль.Тип`) can live in
    // a THIRD file, distinct from both the struct's and the consumer's.
    // `declaration` below is a `DeclId` into THIS module's own AST, not
    // the struct's.
    module: usize,
    declaration: ast.DeclId,
    span: source.Span,
};

pub const ImportedModule = struct {
    alias: []const u8,
    span: source.Span,
    exports: []const ImportedExport,
    // True only for the implicit prelude import — merges `exports` DIRECTLY
    // into the importer's own bare scope (`Опция(T)`, not `alias.Опция`)
    // instead of nesting them under an `alias`-qualified module symbol.
    unqualified: bool = false,
};

// Binds a freshly-minted local Symbol_Id for an imported method to the owner
// type's own local Symbol_Id and the method's origin declaration in the
// exporting module — mirrors `imported_symbols` but keyed by owner+name
// instead of a scope-visible qualified name.
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
    // `внешний` (FFI) — resolved function pointer per symbol, as a plain
    // `usize` (0 = lookup failed, already reported as a diagnostic at
    // that point) rather than an actual pointer type or `std.DynLib`
    // value: this `Resolution` struct is compiled into the shared
    // `core_module`, which the wasm32-freestanding browser build also
    // imports, and `std.DynLib` doesn't need to (and shouldn't) ever
    // become a stored field type here — `predeclare`'s `.foreign`
    // handling only ever uses it as a local inside a real `if`/`else` on
    // `builtin.target.os.tag == .freestanding`, then deliberately lets it
    // go out of scope WITHOUT closing (the loaded library must outlive
    // this resolution pass — matches Odin's `module_graph.
    // foreign_libraries`, never explicitly unloaded either).
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

// Extracted as a standalone function (not just a `Resolver` method) so
// `bundle.zig` (standalone-executable embedding, `panos build --compile`)
// can resolve the SAME path-style `внешний "./lib.so"` a real compile
// would, WITHOUT needing a whole `Resolver` instance — it only ever needs
// this one pure computation (given a `.pns` file's own path and the
// logical library name as written, what real file path does `внешний`
// resolve it to). `Resolver.foreignLibraryFilename` below is now a thin
// wrapper supplying its own `self.source_path`.
pub fn resolveForeignLibraryPath(allocator: std.mem.Allocator, source_path: []const u8, logical_name: []const u8) ![]const u8 {
    const suffix = switch (builtin.target.os.tag) {
        .macos, .ios, .tvos, .watchos => ".dylib",
        .windows => ".dll",
        else => ".so",
    };
    // A path-like library reference (contains '/') is an explicit
    // file path, not a bare logical name resolved via the OS
    // loader's own search path (LD_LIBRARY_PATH/DYLD_.../PATH) — a
    // bare logical name (`"libc"`, `"raylib"`) never contains '/'.
    // Resolved the same way `импорт` resolves a relative module path
    // (`module_loader.resolveImportPath`): against the DIRECTORY of
    // THIS `.pns`/`.ps` file (`source_path`), not the process's
    // current working directory — a library shipped next to a
    // script keeps working regardless of where `panos` is invoked
    // from. An already-absolute path, or an inline/test caller with
    // no real `source_path` (empty — nothing to be relative
    // to), is used exactly as given, which then resolves against the
    // process's own CWD via the OS loader — the same fallback
    // `импорт` itself uses (`importer_path.len == 0`).
    if (std.mem.indexOfScalar(u8, logical_name, '/') != null) {
        const suffixed = if (std.mem.endsWith(u8, logical_name, suffix))
            logical_name
        else
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ logical_name, suffix });
        defer if (suffixed.ptr != logical_name.ptr) allocator.free(suffixed);

        if (suffixed[0] == '/' or source_path.len == 0) return allocator.dupe(u8, suffixed);
        const directory = std.fs.path.dirname(source_path) orelse "";
        if (directory.len == 0) return allocator.dupe(u8, suffixed);
        // Strips a leading "./" (but not "../", which is meaningful)
        // before joining — purely cosmetic, "dir/./libs/x.so" would
        // still resolve fine, this just keeps reported paths and
        // `Resolve Error` messages readable.
        const relative = if (std.mem.startsWith(u8, suffixed, "./")) suffixed[2..] else suffixed;
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, relative });
    }
    // Windows has no file called "libc.dll" — the C runtime there is
    // `msvcrt.dll` (present on every Windows version since NT4, the
    // same universal-CRT-analog role `dlopen(NULL)` fills on POSIX
    // above). Only "libc" gets this special case; any other bare
    // library name still goes through the generic `<name>.dll`
    // suffix rule.
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
    // The `.pns`/`.ps` file this module was loaded from (e.g.
    // "проект/main.ps") — empty for every inline/test caller of `resolve`
    // (no real file on disk to be relative to). Only consumed by
    // `resolveForeignFunction` to make an explicit relative `внешний`
    // library path (`"./libs/foo.so"`) resolve against THIS file's own
    // directory, not the process's current working directory — matching
    // `импорт`'s existing relative-path convention
    // (`module_loader.resolveImportPath`), so a library shipped alongside
    // a `.pns` file keeps working regardless of where `panos` is invoked
    // from.
    source_path: []const u8 = "",
    // Ported from `core/resolver.odin`'s `used_symbols`/
    // `unused_check_symbols` (`Symbol_Id -> bool` maps there, sets here) —
    // see `popScopeAndWarnUnused` for the actual warning.
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

    // Ported from `core/resolver.odin`'s `pop_scope` — checks the
    // ABOUT-TO-CLOSE scope's own symbols for unused `пер`-declared
    // variables before actually popping (`scopeByIdConst(self.scopes.
    // current)` reads the CURRENT scope, still valid at this point —
    // `self.scopes.pop()` only moves the cursor to the parent, it never
    // frees/invalidates the popped scope's storage).
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

    // Ported from `core/resolver.odin`'s `report_resolve_warning` — same
    // shape as `report` above, `.severity = .warning` instead of `.err`.
    fn reportWarning(self: *Resolver, span: source.Span, comptime format: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.result.arena.allocator(), format, args);
        _ = try self.result.diagnostics.appendUnique(self.result.allocator, .{
            .phase = .resolver,
            .severity = .warning,
            .span = span,
            .message = message,
        });
    }

    // `skip_prelude_hardcode` is true ONLY when resolving the embedded
    // prelude module itself (see `module_compiler.zig`'s `compileGraph`) —
    // its own real `тип Опция[T] = перечисление ...` declarations would
    // otherwise collide with these hand-installed duplicates. Every other
    // caller keeps the hardcode until the single-file (non-graph) pipeline
    // also merges the real prelude module (see `Recent Changes`/tasks.md
    // T032 for the remaining single-file-path work).
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
            // `ждать` — blocks until a process spawned via `запусти
            // <вызов>` completes or fails, returning `Результат(R,
            // Ошибка)` where R is the spawned function's return type.
            // Sibling to `получить`, not a replacement.
            "ждать",
            "встроку",
            "Целое",
            "Число",
            // Bounded mailbox (Phase F, item 6): `ограничить_почту(N)`
            // sets a capacity on the CURRENT process's own mailbox
            // (called from within an actor's body, mirrors `себя()`'s
            // "acts on current process" shape) — unbounded (no cap) stays
            // the default. `отправить_или` is a SEPARATE, opt-in send
            // that respects that cap and rejects with `Ошибка` instead of
            // appending when full; plain `отправить` is deliberately left
            // UNCHANGED (always succeeds) — bounded behavior only applies
            // when BOTH sides opt in.
            "ограничить_почту",
            "отправить_или",
            // Cooperative cancellation (Phase F, item 7): `отмена(proc)`
            // sets a flag on the TARGET process, `отменено()` polls the
            // CURRENT process's own flag — purely advisory, the target
            // must observe it itself via `отменено()`; forceful
            // `убить()`/`остановить()` (супервизор.ps) are unchanged and
            // unrelated.
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
        // дескриптора (`фс.открыть`), симметрично Odin'овскому TY_FILE
        // (core/type_cheker.odin) — никогда не парсится из исходника
        // (нет ни структуры, ни перечисления), поэтому объявляется прямо
        // здесь, как и модуль `фс` выше, а не через встроенную прелюдию.
        try self.installBuiltinType("Файл");
        try self.installBuiltinModule("ос", &.{ "аргументы", "версия_паноса", "окружение", "установить_окружение", "удалить_окружение", "выполнить", "завершить" });
        try self.installBuiltinModule("время", &.{ "сейчас_мс", "монотонно_мс", "спать_мс" });
        // `ввод_вывод` — real gap found auditing panosiki: this module
        // never existed in Zig at all (`Resolve Error: неопределённое имя
        // 'ввод_вывод'`), silently breaking EVERY consumer of `std/тест.ps`
        // (which itself does `импорт ввод_вывод` on line 1) across every
        // panosiki package. Scoped to `.печать`/`.строка` only for now —
        // `.прочитать_строку`/`.поток` (`target.zig`'s `native_only` list
        // already anticipates both by name) need the same async-stdin
        // machinery `Файл`'s streaming reads use, a separate follow-up.
        // `прочитать_строку` — real gap found auditing panosiki's
        // `cli-selector` package (an interactive menu that reads real
        // stdin lines to drive its prompts): blocking, native-only (see
        // `target.zig`'s `native_only` list, which already anticipated
        // this exact name) — returns `Опция(Строка)`, `Нет()` on EOF
        // rather than an empty string, so callers can distinguish "user
        // pressed Enter on an empty line" from "stdin closed".
        try self.installBuiltinModule("ввод_вывод", &.{ "печать", "строка", "прочитать_строку" });
        // `строки` — the other half of the panosiki audit's headline gap:
        // completely absent (not native, no `std/строки.ps`), yet docs
        // (`docs/src/language/basic-types.md` §"Байты") describe byte-level
        // primitives (`срез_байт`/`из_байтов`/`байт`) that can ONLY be
        // native (no way to build them out of other panos-level string
        // ops) — this was always meant to be a native module like `фс`/
        // `время`, not a `std/*.ps` library, and simply never got ported.
        // Scoped to the 18 functions panosiki/std actually calls, plus
        // the 4 mass-conversion primitives docs/src/language/basic-types.md
        // §"Байты" also documents (`в_байты`/`в_руны`/`из_рун`/
        // `кодовая_точка`) — real gap found via a docs-example sweep
        // (those 4 doc examples never compiled at all before this).
        try self.installBuiltinModule("строки", &.{
            "байт",
            "длина_байт",
            "срез_байт",
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
        // `DOM` — AOT WASM only (`target.zig`'s `builtinAvailability`), a
        // Numeric methods stay compatible with the first AOT DOM slice;
        // the string methods use opaque handles supplied by its JS runtime.
        try self.installBuiltinModule("DOM", &.{ "текст", "установить_текст", "на_клик", "текст_строка", "установить_текст_строка", "значение_поля", "установить_значение_поля", "создать_и_добавить", "после_кадра" });
        try self.installBuiltinModule("сжатие", &.{"разжать_gzip"});
        try self.installBuiltinModule("синтаксис", &.{ "структуры", "поля", "импорты", "аннотации", "аргумент_аннотации", "аннотации_поля", "аргумент_аннотации_поля" });
        try self.installBuiltinModule("сеть", &.{ "подключиться", "кодировать_url", "декодировать_url", "http_запрос", "http_запрос_sync", "http_сервер_слушать" });
        // `Соединение` — открытый TCP-сокет (`сеть.подключиться`), тот же
        // opaque-тип принцип, что `Файл` (см. коммент там) — но, в отличие
        // от `Файл`, здесь ДЕЙСТВИТЕЛЬНО хранится живой OS-дескриптор
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
        if (skip_prelude_hardcode) return;
        try self.installPreludeEnum("Опция", &.{ "Нет", "Есть" });
        try self.installPreludeEnum("Результат", &.{ "Успех", "Неудача" });
        // `выбор ожидание(...)` (select-style multi-source wait) matches
        // against this synthetic enum's variants the exact same way any
        // ordinary `выбор` matches `Опция`/`Результат` — same hardcoded
        // bare-name registration those two need for the identical reason
        // (panos never merges an imported module's names into scope, so
        // the prelude's own real declaration in `prelude.zig` alone isn't
        // enough to make `Сообщение`/`Сигнал`/`Готово` resolvable
        // unqualified).
        try self.installPreludeEnum("ИсточникОжидания", &.{ "Сообщение", "Сигнал", "Готово" });
        try self.installPreludeInterface("Сравниваемое");
        try self.installPreludeInterface("Итерируемое");
        // `Печатаемое` — real gap found auditing panosiki's `cli` package
        // (`реализация Печатаемое для X`): DECLARED in the embedded
        // prelude source (`prelude.zig`) alongside `Сравниваемое`/
        // `Итерируемое`, but the real CLI run path never actually loads
        // that embedded module at all (`zig/cli/main.zig`'s `main()`
        // never calls `graph.appendPreludeModule` — only the LSP/test-
        // harness entry points do) — so `Печатаемое` was NEVER resolvable
        // as a symbol for a normal `panos file.ps` run, unlike
        // `Сравниваемое`/`Итерируемое`, which work ONLY because of this
        // same hardcoded `installPreludeInterface` call plus a matching
        // hardcoded `interface_definitions` entry in `type_checker.zig`'s
        // `preludePass`. `Печатаемое`'s `вСтроку() -> Строка` has no
        // self-referencing parameter/return type at all (unlike
        // `Сравниваемое`'s `сравнить(другое: Сравниваемое) -> Число`),
        // so it needs none of that interface's `Никогда`-placeholder
        // workaround — a plain, ordinary interface method signature.
        try self.installPreludeInterface("Печатаемое");
        // `Копируемое` — needed to restore reflective deep-copy-on-send
        // (ROADMAP.md Стадия 24, "copy-on-send": reflective by default,
        // `реализация Копируемое` as an opt-in override — silently
        // dropped in the Zig migration, `отправить` currently does a bare
        // shallow copy sharing heap payloads by pointer between
        // processes). Earlier assumed (see the comment this replaces)
        // that a Self-typed return (`клонировать() -> Копируемое`) needed
        // "a substitution mechanism this hardcoded prelude has none of" —
        // verified false by reading `defineInterfaceImplementation`
        // directly: it already unifies an interface method's return type
        // against the impl's ACTUAL return type via the same
        // `inferGenericSubstitution`/`substituteGeneric` machinery used
        // for ordinary generic parameters, as long as the interface's
        // declared return type is some bare `.generic_parameter` — which
        // is exactly what `type_checker.zig`'s `preludePass` mints for
        // this entry (a throwaway placeholder, not tied to any real
        // declared type parameter).
        try self.installPreludeInterface("Копируемое");
        // `Складываемое`/`Вычитаемое`/`Умножаемое`/`Делимое`/`Равнозначное`
        // — same SAME technique as `Копируемое` just above, now applied
        // (`type_checker.zig`'s `preludePass` mints a placeholder per
        // interface). Real gap found via a docs-example sweep —
        // `prelude-interfaces.md` documents `Равнозначное`/`Складываемое`
        // with real code examples that never actually compiled, because
        // these 5 were declared in the embedded prelude source
        // (`prelude.zig`) but never installed here at all.
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

    // Merges the implicit prelude import's exports DIRECTLY into the current
    // scope — no module wrapper, no `alias.Имя` qualification, matching how
    // panos resolves a top-level local declaration (`Опция(T)`, not
    // `прелюдия.Опция(T)`). Methods/variants use the exact same mechanism as
    // `predeclareImports`'s qualified path (mint a local symbol per method/
    // variant, keyed by owner) — only the owner-type symbol's OWN visibility
    // differs.
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
                .import, .error_node => {},
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

    // Bare (unqualified, non-module-namespaced) builtin type names —
    // unlike `сеть.*`/`строки.*`/`бд.*` builtins, these collide directly
    // with any user `тип X = ...` of the same name (`installBuiltinType`
    // declares them straight into the root scope). Listed here just to
    // give a clearer diagnostic than the generic "уже объявлен" when a
    // user picks one of these fairly ordinary words for their own type —
    // most commonly `Запрос`, common enough to be a real trap (see
    // `installBuiltinType` call sites above for the authoritative list).
    fn isReservedBuiltinTypeName(name: []const u8) bool {
        const reserved = [_][]const u8{ "Файл", "Соединение", "Слушатель", "Запрос", "Соединение_БД" };
        for (reserved) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
        return false;
    }

    // Loads `foreign.library` (an ARBITRARY, user-named shared library —
    // not one of this project's own vendored dependencies) and resolves
    // `foreign.name` in it, caching the resulting function pointer on
    // `symbol` for `compiler.zig`/`vm.zig` to embed into the compiled
    // `Program` later. Mirrors Odin's `core/resolver.odin` `^Foreign_Decl`
    // case exactly (same load-once-per-declaration timing, same "leak the
    // library, never unload" contract) — see `Resolution.foreign_
    // functions`'s doc comment for why nothing here becomes a stored
    // field on `Resolution` itself.
    fn resolveForeignFunction(self: *Resolver, symbol: symbols.SymbolId, foreign: anytype) !void {
        // Two separate guards, not one: `comptime` handles the REAL
        // wasm32-freestanding compile (browser build) — Sema-eliminates
        // the `std.DynLib` branch entirely, see `Resolution.foreign_
        // functions`'s doc comment. The runtime `target_profile` check
        // handles every OTHER case that ALSO shouldn't load a native
        // library — e.g. the LSP/`checkSourceForTarget`-style "would this
        // program pass for `.browser_interpreter`" queries, which run
        // inside an ordinary NATIVE binary (so the comptime check alone
        // never fires for them).
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.report(foreign.span, "Resolve Error: 'внешний' недоступно в этом runtime-таргете", .{});
        } else if (self.target_profile != .native) {
            try self.report(foreign.span, "Resolve Error: 'внешний' недоступно в этом runtime-таргете", .{});
        } else if ((comptime builtin.target.os.tag != .windows and builtin.link_libc) and std.mem.eql(u8, foreign.library, "libc")) {
            // Real bug found via CI (not local — this machine always
            // links libc for every build): `std.c.dlopen` referenced
            // UNCONDITIONALLY (no `builtin.link_libc` guard) forces
            // EVERY test binary that merely compiles `resolver.zig`
            // (virtually all of them, via `predeclare`/
            // `resolveModuleForTarget` — reachable regardless of
            // whether that specific test ever declares `внешний`) to
            // link libc at compile time, even ones that otherwise never
            // needed it — Zig's own `std.DynLib` (the path this branch
            // replaces) avoids exactly this by internally picking a
            // libc-free pure-Zig ELF parser (`ElfDynLib`) instead of the
            // libc-`dlopen`-based one (`DlDynLib`) whenever `!builtin.
            // link_libc` — a fallback this direct `std.c.dlopen` call
            // doesn't get for free, so it needs the same guard here.
            //
            // `внешний "libc"` doesn't need to find and load a SEPARATE
            // shared object file at all — libc is ALREADY linked into
            // this very process (every native panos binary links libc).
            // `dlopen(NULL, ...)` is POSIX for exactly this: "give me a
            // handle to the running program's own already-loaded image"
            // (main executable + every shared library already mapped
            // in, libc included) — `std.c.dlopen`'s first param is
            // `?[*:0]const u8`, so `null` is directly expressible, no
            // need to drop to raw libc bindings by hand.
            //
            // Replaces an EARLIER version of this fix that hardcoded
            // the filename `"libc.so.6"` for non-macOS/Windows — found
            // wrong by inspection before it ever shipped: that's the
            // glibc SONAME specifically, and doesn't exist AT ALL on
            // musl-based Linux (Alpine and similar) — same class of
            // "guessed a filename, wrong on a platform nobody tested"
            // mistake the .so-vs-.so.6 fix was itself catching. dlopen
            // (NULL) needs no filename, no libc-flavor knowledge, and
            // is exactly as valid on macOS as it is on any POSIX system
            // — used unconditionally for "libc" on every non-Windows
            // target, not just Linux.
            const handle = std.c.dlopen(null, .{ .LAZY = true }) orelse {
                try self.report(foreign.span, "Resolve Error: библиотека 'libc' не найдена (dlopen(NULL) в этом процессе)", .{});
                return;
            };
            const name_z = try self.result.arena.allocator().dupeZ(u8, foreign.name);
            const fn_ptr = std.c.dlsym(handle, name_z) orelse {
                try self.report(foreign.span, "Resolve Error: библиотека 'libc' не экспортирует символ '{s}'", .{foreign.name});
                return;
            };
            try self.result.foreign_functions.put(symbol, @intFromPtr(fn_ptr));
        } else if (comptime builtin.target.os.tag == .windows) {
            // Real, previously-latent gap found via CI (not this
            // session's own commits — masked until now by an UNRELATED
            // broken `wasmtime` install step that failed before the
            // build ever got this far): `std.DynLib` in this Zig
            // version has NO Windows implementation at all
            // (`dynamic_library.zig`'s inner-type switch only lists
            // linux/macos/bsd-family, everything else — including
            // Windows — hits `@compileError("unsupported platform")`).
            // `внешний` has never actually worked on Windows through
            // this codebase; it just never got compile-tested there
            // until the wasmtime-install fix let CI reach this file.
            //
            // `std` also doesn't expose `LoadLibraryW`/`GetProcAddress`
            // bindings anywhere in this version — hand-rolled `extern
            // "kernel32"` declarations below are the direct Win32 API,
            // same shape `std.DynLib` used internally in Zig versions
            // where it DID support Windows.
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

    // Minimal direct Win32 bindings — `std.DynLib` doesn't cover Windows
    // in this Zig version (see `resolveForeignFunction`'s Windows
    // branch). `callconv(.winapi)` matches every other raw Win32 extern
    // already used where this project talks to Windows directly.
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
                .import, .struct_decl, .enum_decl, .foreign, .type_alias, .error_node => {},
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
            // `track_unused = false` — Odin deliberately excludes function
            // parameters from the unused-variable warning (see
            // `resolver.odin`'s own doc comment: often intentionally
            // unused when implementing an interface/callback signature
            // that requires an exact match).
            try parameter_symbols.append(self.result.allocator, try self.declareLocal(parameter.name, parameter.span, true, false, false));
        }
        return self.result.arena.allocator().dupe(symbols.SymbolId, parameter_symbols.items);
    }

    // `track_unused` — Odin's `unused_check_symbols` only ever covers
    // `пер`-declared variables (plain or destructured) and for-loop
    // variables, NEVER function parameters or match/pattern binders (see
    // `resolver.odin`'s own doc comment on `unused_check_symbols`) — `"_"`
    // is excluded by every CALLER already (the same opt-out `_` already
    // gets from pattern matching), not checked again here.
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
        // `_` is the universal discard binder (params, `пер`, pattern
        // binders alike) — it's meant to be written arbitrarily many
        // times in the same scope (e.g. two discarded lambda parameters,
        // `функ(_: А, _: Б)`) without ever being looked up again, so it's
        // deliberately exempt from the duplicate-declaration check that
        // every other name is subject to.
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
                // Ported from `core/resolver.odin`'s `used_symbols` — ANY
                // reference through a bare `.ident` (read OR assignment
                // target — `x = 5`'s left side resolves through this same
                // case, no separate handling needed) marks the symbol
                // used, for the unused-variable warning in `popScope`
                // below.
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
                try self.resolveExpression(tree, index.index);
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
                    // `parser.zig`'s 3-level qualified pattern
                    // (`алиас.Тип.Вариант(...)`) concatenates the first
                    // two segments into ONE `module_name` string
                    // ("алиас.Тип") rather than keeping them separate —
                    // a plain scope lookup of that compound string can
                    // never succeed (scopes only ever hold bare
                    // identifiers). Real gap found auditing panosiki's
                    // `скобки` package: matching an ALIASED cross-module
                    // enum in `выбор` (`алиас.Тип.Вариант(...)`, as
                    // opposed to the un-aliased same-module `Тип.
                    // Вариант(...)` case, which already worked via a
                    // direct single-name lookup) always failed
                    // "неопределённый тип перечисления". Fixed by
                    // splitting on the LAST '.' and resolving in two
                    // steps — module alias, then that module's own
                    // member — exactly like an ordinary `алиас.Тип`
                    // qualified type annotation already does elsewhere.
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

    // 2, not 0: `ключ`/`значение` (destructured, line 2) are never
    // referenced anywhere in this body — both now warn "неиспользованная
    // переменная" (the unused-variable check ported from `core/resolver.
    // odin`'s `pop_scope`). `элемент`/`индекс` ARE referenced inside their
    // own loop bodies, so neither warns. Order between the two warnings
    // is NOT asserted — `popScopeAndWarnUnused` iterates a `StringHashMap`
    // (`symbols.Scope.symbols`), whose iteration order is unspecified,
    // same as Odin's own equivalent map iteration.
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
    // `x = 2` resolves `x` through the same `.ident` case as a read (see
    // `resolveExpression`'s doc comment) — matches Odin's own documented
    // choice not to distinguish read vs. write-only uses.
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
