const std = @import("std");
const panos_core = @import("panos_core");

/// Публичный API для встраивания панос в нативный Zig-процесс.
///
/// `Runtime` владеет графом модулей, скомпилированной программой и VM. Один
/// экземпляр загружает один корневой скрипт; вызывать экспортированные функции
/// можно многократно. `Value`, возвращённый из `call`/`runStart`, принадлежит
/// VM и действителен до следующего вызова или `deinit`.
///
/// Нативные возможности хоста описываются в панос как
/// `внешний "хост" функ ...`. Два способа опубликовать реализацию,
/// сочетаемые в одном приложении: `panos.hostFunctions(...)` (см. ниже) —
/// без `pub export fn`/`rdynamic`, без libffi на пути вызова; либо
/// экспорт C-ABI `pub export fn` + `rdynamic` в Zig-сборке (старый путь,
/// через `dlopen`/`dlsym`+libffi). Оба намеренно не требуют вносить
/// игровой API в VM панос.
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    graph_state: panos_core.module_loader.Graph,
    compiled_graph: ?panos_core.module_compiler.GraphCompileResult = null,
    machine: ?panos_core.vm.Vm = null,
    program_args: []const []const u8,
    foreign_profile_enabled: bool,
    abandon_background_async_on_root_exit: bool,
    live_stdout: bool,
    stage: Stage = .empty,

    const Stage = enum {
        empty,
        loaded,
        compiled,
    };

    pub const Config = struct {
        /// Дополнительные корни для разрешения "голых" импортов модулей.
        /// Вызывающий код обязан держать эти слайсы живыми до `Runtime.deinit`.
        global_search_roots: []const []const u8 = &.{},
        /// Значения, доступные скрипту через `ос.аргументы()` во время выполнения.
        program_args: []const []const u8 = &.{},
        foreign_profile_enabled: bool = false,
        /// `true` только для настоящего одноразового CLI-запуска, где
        /// процесс завершается сразу после `runStart()` — см. doc-комментарий
        /// `Vm.abandon_background_async_on_root_exit` (vm.zig). Держите
        /// `false` (умолчание), если `Runtime` переживёт `runStart()`/`call()`
        /// и может быть использован снова.
        abandon_background_async_on_root_exit: bool = false,
        /// `true` только для настоящего native CLI-запуска на реальном
        /// терминале/логе — `ввод_вывод.печать` пишет напрямую в
        /// реальный stdout СРАЗУ, а не только в буфер, читаемый через
        /// `output()` после возврата из `runStart()` (см. `Vm.
        /// live_stdout`, vm.zig — без этого печать внутри блокирующего
        /// `http.обслуживать` никогда не становится видимой). `false`
        /// (умолчание) для встраивающих хостов, читающих `output()`
        /// программно.
        live_stdout: bool = false,
        /// Host-функции, зарегистрированные через `panos.hostFunctions(...)`
        /// (specs/017-native-host-function-registry) — делает их видимыми
        /// `.pns`-скрипту через `внешний "хост" функ ...`, без `pub export
        /// fn`/`rdynamic`. Пусто по умолчанию — не встраивающие сценарии не
        /// затронуты; можно сочетать со старым `pub export fn`+`rdynamic`
        /// путём (см. `docs/src/architecture/embedding.md`) — при коллизии
        /// имени регистрация здесь имеет приоритет.
        host_functions: []const panos_core.host_registry.HostFunctionEntry = &.{},
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) Runtime {
        var graph_result = panos_core.module_loader.Graph.init(allocator);
        graph_result.global_search_roots = config.global_search_roots;
        graph_result.host_registry = config.host_functions;
        return .{
            .allocator = allocator,
            .graph_state = graph_result,
            .program_args = config.program_args,
            .foreign_profile_enabled = config.foreign_profile_enabled,
            .abandon_background_async_on_root_exit = config.abandon_background_async_on_root_exit,
            .live_stdout = config.live_stdout,
        };
    }

    pub fn deinit(self: *Runtime) void {
        if (self.machine) |*machine| machine.deinit();
        if (self.compiled_graph) |*compile_result| compile_result.deinit();
        self.graph_state.deinit();
        self.* = undefined;
    }

    /// Загружает корневой модуль и все достижимые импорты. `reader` должен
    /// предоставлять `read(allocator, path)`, как и `module_loader.Graph.load`.
    pub fn load(self: *Runtime, reader: anytype, entry_path: []const u8) !void {
        if (self.stage != .empty) return error.AlreadyLoaded;
        try self.graph_state.load(reader, entry_path);
        _ = try self.graph_state.appendPreludeModule(panos_core.prelude.SOURCE);
        self.stage = .loaded;
    }

    /// Компилирует успешно загруженный граф. Ошибки фронтенда остаются
    /// доступны через `compilationDiagnostics` — они не превращаются в
    /// Zig-ошибку, чтобы встраивающий хост мог отрисовать их вместе с
    /// местоположением в исходнике.
    pub fn compile(self: *Runtime) !void {
        if (self.stage == .empty) return error.NotLoaded;
        if (self.stage == .compiled) return error.AlreadyCompiled;
        if (self.hasGraphErrors()) return error.GraphHasErrors;

        self.compiled_graph = try panos_core.module_compiler.compileGraph(self.allocator, &self.graph_state);
        self.stage = .compiled;
        if (self.hasCompilationErrors()) return;

        const compile_result = &self.compiled_graph.?;
        var machine = panos_core.vm.Vm.init(self.allocator, &compile_result.program);
        machine.program_args = self.program_args;
        machine.foreign_profile_enabled = self.foreign_profile_enabled;
        machine.abandon_background_async_on_root_exit = self.abandon_background_async_on_root_exit;
        machine.live_stdout = self.live_stdout;
        self.machine = machine;
    }

    pub fn graph(self: *const Runtime) *const panos_core.module_loader.Graph {
        return &self.graph_state;
    }

    pub fn graphDiagnostics(self: *const Runtime) *const panos_core.diagnostic.DiagnosticList {
        return &self.graph_state.diagnostics;
    }

    pub fn compilationDiagnostics(self: *const Runtime) ?*const panos_core.diagnostic.DiagnosticList {
        if (self.compiled_graph) |*compile_result| return &compile_result.diagnostics;
        return null;
    }

    pub fn compiledGraph(self: *const Runtime) ?*const panos_core.module_compiler.GraphCompileResult {
        if (self.compiled_graph) |*compile_result| return compile_result;
        return null;
    }

    pub fn hasGraphErrors(self: *const Runtime) bool {
        return hasErrors(&self.graph_state.diagnostics);
    }

    pub fn hasCompilationErrors(self: *const Runtime) bool {
        if (self.compiled_graph) |*compile_result| return compile_result.hasErrors();
        return false;
    }

    /// Вызывает экспортированную функцию, объявленную в корневом модуле.
    /// Имена из импортов сюда намеренно не выведены: хост управляет
    /// видимой скрипту поверхностью обычными объявлениями `экспорт` в панос.
    pub fn call(self: *Runtime, name: []const u8, arguments: []const panos_core.value.Value) !panos_core.vm.Execution {
        const function = self.rootExportFunction(name) orelse return error.ExportNotFound;
        return self.run(function, arguments);
    }

    /// Запускает обычную функцию `старт`. В отличие от `call`, `старт`
    /// повторяет поведение CLI и не обязана быть экспортированной.
    pub fn runStart(self: *Runtime) !panos_core.vm.Execution {
        const compile_result = self.compiledGraph() orelse return error.NotCompiled;
        const start = compile_result.start orelse return error.StartNotFound;
        return self.run(start, &.{});
    }

    pub fn output(self: *const Runtime) []const u8 {
        const machine = self.machine orelse return &.{};
        return machine.output.items;
    }

    pub fn writeForeignProfile(self: *const Runtime, writer: *std.Io.Writer) !void {
        const machine = self.machine orelse return error.NotCompiled;
        try machine.writeForeignProfile(writer);
    }

    /// Отрисовывает `diagnostics` по одной строке на запись, разрешая
    /// исходный файл каждой записи через собственный граф модулей рантайма —
    /// хосту не нужно самому искать `SourceFile`. Обычно вызывается с
    /// `graphDiagnostics()` или `compilationDiagnostics().?`.
    pub fn formatDiagnostics(
        self: *const Runtime,
        writer: *std.Io.Writer,
        diagnostics: *const panos_core.diagnostic.DiagnosticList,
    ) !void {
        try panos_core.diagnostic.writeGraph(writer, self.graph(), diagnostics);
    }

    fn run(self: *Runtime, function: panos_core.bytecode.FunctionId, arguments: []const panos_core.value.Value) !panos_core.vm.Execution {
        const machine = if (self.machine) |*value| value else return error.NotRunnable;
        // Вывод отслеживается отдельно на каждый вызов хоста, чтобы вывод
        // `ввод_вывод.печать` из предыдущего кадра/события не просачивался в следующий.
        machine.output.clearRetainingCapacity();
        return machine.run(function, arguments);
    }

    fn rootExportFunction(self: *const Runtime, name: []const u8) ?panos_core.bytecode.FunctionId {
        const compile_result = self.compiledGraph() orelse return null;
        const exported = self.graph_state.exportForName(0, name) orelse return null;
        if (exported.kind != .function) return null;

        const module = compile_result.modules[exported.module];
        const resolution = module.resolution orelse return null;
        const module_compilation = module.compiled orelse return null;
        const symbol = resolution.decl_symbols.get(exported.declaration) orelse return null;
        return module_compilation.function_ids.get(symbol);
    }
};

pub const Value = panos_core.value.Value;
pub const Execution = panos_core.vm.Execution;
pub const HostFunctionEntry = panos_core.host_registry.HostFunctionEntry;

/// Регистрирует обычные Zig-функции как host-функции, видимые `.pns`-
/// скрипту через `внешний "хост" функ имя(...)` — БЕЗ `pub export fn`/
/// `rdynamic` (specs/017-native-host-function-registry). `table` — анонимный
/// структ, имя каждого поля становится именем host-функции, значение —
/// обычная Zig-функция:
///
/// ```zig
/// const entries = panos.hostFunctions(.{
///     .scale = struct {
///         fn call(x: f64) f64 { return x * 2.0; }
///     }.call,
/// });
/// var runtime = panos.Runtime.init(allocator, .{ .host_functions = entries });
/// ```
///
/// Несовместимый Zig-тип параметра/возврата (вне `u8`/`i32`/`i64`/`f32`/
/// `f64`/`[]const u8`/`void`, либо struct со скалярными полями того же
/// набора) — `@compileError` здесь, в месте вызова `hostFunctions(...)`, не
/// рантайм-ошибка панос (см. `host_registry.zig`, набор НЕ расширяет
/// существующие FFI marshal-kinds — `Указатель(T)` не поддерживается).
///
/// Поле таблицы — либо обычная функция (имя host-функции = имя поля,
/// как выше), либо `alias("своё_имя", func)` — тогда имя, видимое
/// `.pns`-скрипту, берётся из `alias(...)`, а НЕ из имени Zig-поля.
/// Практический случай: встраивающее приложение хочет держать сами
/// Zig-идентификаторы латиницей (обычный код), но выставить скрипту
/// имя на другом языке (кириллица и т.п.) — `.pns`-идентификаторы не
/// обязаны совпадать с Zig-стороной вообще.
///
/// ```zig
/// const entries = panos.hostFunctions(.{
///     .scale = panos.alias("удвоить", struct {
///         fn call(x: f64) f64 { return x * 2.0; }
///     }.call),
/// });
/// ```
pub fn hostFunctions(comptime table: anytype) []const HostFunctionEntry {
    // Явный `comptime`-блок обязателен: сам по себе вызов `hostFunctions(...)`
    // в обычной (не comptime) позиции — например, прямо внутри
    // `Runtime.Config`-литерала — НЕ гарантирует comptime-вычисление всего
    // тела только потому, что `table` помечен `comptime` (это фиксирует
    // только сам параметр, не форсирует comptime-выполнение вызывающей
    // функции целиком) — без этой обёртки `entries[index] = ...` падает с
    // "cannot store runtime value in compile time variable".
    return comptime blk: {
        const table_fields = @typeInfo(@TypeOf(table)).@"struct".fields;
        var entries: [table_fields.len]HostFunctionEntry = undefined;
        for (table_fields, 0..) |field, index| {
            const value = @field(table, field.name);
            entries[index] = if (isAlias(@TypeOf(value)))
                buildHostFunctionEntry(value.name, value.func)
            else
                buildHostFunctionEntry(field.name, value);
        }
        const frozen = entries;
        break :blk &frozen;
    };
}

/// Оборачивает `func` под ИМЕНЕМ, отличным от имени Zig-поля в таблице
/// `hostFunctions(...)` — см. её doc-комментарий выше.
pub fn alias(comptime name: []const u8, comptime func: anytype) Alias(@TypeOf(func)) {
    return .{ .name = name, .func = func };
}

fn Alias(comptime Func: type) type {
    return struct {
        name: []const u8,
        func: Func,
    };
}

// Отличает результат `alias(...)` (структ с полями `name`/`func`) от
// голой функции, переданной как значение поля напрямую — обычные
// Zig-функции никогда не имеют `.@"struct"` typeInfo, так что это
// безопасно как единственная проверка (не полагается на конкретное имя
// generic-типа `Alias(Func)`, тот меняется с каждым `Func`).
fn isAlias(comptime ValueType: type) bool {
    const info = @typeInfo(ValueType);
    if (info != .@"struct") return false;
    const fields = info.@"struct".fields;
    if (fields.len != 2) return false;
    return std.mem.eql(u8, fields[0].name, "name") and std.mem.eql(u8, fields[1].name, "func");
}

fn buildHostFunctionEntry(comptime name: []const u8, comptime func: anytype) HostFunctionEntry {
    const registry = panos_core.host_registry;
    const FuncType = @TypeOf(func);
    const func_info = @typeInfo(FuncType).@"fn";
    const ArgsTuple = std.meta.ArgsTuple(FuncType);
    const ReturnType = func_info.return_type.?;

    var param_kinds: [func_info.params.len]panos_core.ast.ForeignMarshalKind = undefined;
    var param_struct_layouts: [func_info.params.len][]const panos_core.ast.ForeignMarshalKind = undefined;
    for (func_info.params, 0..) |param, index| {
        param_kinds[index] = registry.marshalKindFor(param.type.?);
        param_struct_layouts[index] = registry.structLayoutFor(param.type.?);
    }
    const frozen_param_kinds = param_kinds;
    const frozen_param_struct_layouts = param_struct_layouts;
    const return_kind = registry.marshalKindFor(ReturnType);
    const return_struct_layout = registry.structLayoutFor(ReturnType);

    const Trampoline = struct {
        fn call(heap: *panos_core.gc.Heap, args: []const Value) anyerror!Value {
            if (args.len != func_info.params.len) return error.ForeignArgumentCountMismatch;
            var arguments: ArgsTuple = undefined;
            inline for (func_info.params, 0..) |param, index| {
                arguments[index] = unpackHostArg(param.type.?, args[index]);
            }
            const result = @call(.auto, func, arguments);
            return packHostResult(ReturnType, heap, result);
        }
    };

    return .{
        .name = name,
        .param_kinds = &frozen_param_kinds,
        .param_struct_layouts = &frozen_param_struct_layouts,
        .return_kind = return_kind,
        .return_struct_layout = return_struct_layout,
        .call = &Trampoline.call,
    };
}

// `source`/`T` уже гарантированно совместимы к моменту вызова —
// `resolver.zig`'s `findHostRegistryEntry`-ветка сверяет marshal kinds
// `.pns`-декларации с этой же зарегистрированной сигнатурой ДО того, как
// компилятор вообще выпускает `.call_foreign` на эту константу (см.
// `resolveForeignFunction`, specs/017-native-host-function-registry/
// spec.md, User Story 2) — несовпадение здесь означало бы дыру в той
// проверке, не штатный случай.
fn unpackHostArg(comptime T: type, source: Value) T {
    return switch (@typeInfo(T)) {
        .@"struct" => unpackHostStruct(T, source),
        else => switch (T) {
            void => {},
            u8, i32, i64 => @intFromFloat(source.number),
            f32 => @floatCast(source.number),
            f64 => source.number,
            []const u8 => source.stringBytes() orelse "",
            else => unreachable,
        },
    };
}

fn unpackHostStruct(comptime T: type, source: Value) T {
    const aggregate = switch (source) {
        .aggregate => |a| a,
        else => unreachable,
    };
    var result: T = undefined;
    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields, 0..) |field, index| {
        @field(result, field.name) = unpackHostArg(field.type, aggregate.elements[index]);
    }
    return result;
}

// Возврат `[]const u8`/`ff_структура`-совместимого struct всегда копируется
// в новую GC-отслеживаемую панос-строку/структуру через `heap` — та же
// конвенция, что уже использует dynlib-FFI путь в `vm.zig`'s
// `invokeForeign` для `КСтрока`/`ff_структура`-возвратов (panos никогда не
// заимствует чужую память для возвращаемых значений).
fn packHostResult(comptime T: type, heap: *panos_core.gc.Heap, result: T) anyerror!Value {
    return switch (@typeInfo(T)) {
        .@"struct" => packHostStruct(T, heap, result),
        else => switch (T) {
            void => .{ .void = {} },
            u8, i32, i64 => .{ .number = @floatFromInt(result) },
            f32, f64 => .{ .number = result },
            []const u8 => blk: {
                const heap_string = try heap.createString(try heap.allocator.dupe(u8, result));
                break :blk .{ .heap_string = heap_string };
            },
            else => unreachable,
        },
    };
}

fn packHostStruct(comptime T: type, heap: *panos_core.gc.Heap, result: T) anyerror!Value {
    const fields = @typeInfo(T).@"struct".fields;
    const elements = try heap.allocator.alloc(Value, fields.len);
    inline for (fields, 0..) |field, index| {
        elements[index] = try packHostResult(field.type, heap, @field(result, field.name));
    }
    const aggregate = try heap.createAggregate(null, elements);
    return .{ .aggregate = aggregate };
}

pub fn renderValue(allocator: std.mem.Allocator, runtime_value: Value) ![]const u8 {
    return panos_core.runner.renderValue(allocator, runtime_value);
}

/// Низкоуровневая отрисовка одной диагностики относительно уже известного
/// `SourceFile`. Большинству хостов нужен `Runtime.formatDiagnostics`,
/// который сам разрешает нужный файл для каждой диагностики из графа.
pub const formatDiagnostic = panos_core.diagnostic.format;

fn hasErrors(diagnostics: *const panos_core.diagnostic.DiagnosticList) bool {
    for (diagnostics.items.items) |item| {
        if (item.severity == .err) return true;
    }
    return false;
}

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

test "embedded runtime renders compilation diagnostics with source locations" {
    const reader = MemoryReader{ .files = &.{
        .{
            .path = "карта/main.pns",
            .bytes = "экспорт функ сломано() -> Число\n" ++
                "\"не число\"\n" ++
                "конец",
        },
    } };

    var runtime = Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();
    try runtime.load(&reader, "карта/main.pns");
    try std.testing.expect(!runtime.hasGraphErrors());
    try runtime.compile();
    try std.testing.expect(runtime.hasCompilationErrors());

    var allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer allocating.deinit();
    try runtime.formatDiagnostics(&allocating.writer, runtime.compilationDiagnostics().?);

    const rendered = allocating.written();
    try std.testing.expect(std.mem.startsWith(u8, rendered, "карта/main.pns:"));
}

test "embedded runtime executes root exports across a file graph" {
    const reader = MemoryReader{ .files = &.{
        .{
            .path = "карта/main.pns",
            .bytes = "импорт \"./математика\" как мат\n" ++
                "экспорт функ обновить(кадр: Число) -> Число\n" ++
                "мат.прибавить(кадр, 1.0)\n" ++
                "конец\n" ++
                "экспорт функ количество_аргументов() -> Целое\n" ++
                "ос.аргументы().длина()\n" ++
                "конец\n" ++
                "функ старт() -> Число\n" ++
                "обновить(41.0)\n" ++
                "конец",
        },
        .{
            .path = "карта/математика.pns",
            .bytes = "экспорт функ прибавить(a: Число, b: Число) -> Число\n" ++
                "a + b\n" ++
                "конец",
        },
    } };

    var runtime = Runtime.init(std.testing.allocator, .{ .program_args = &.{ "волна", "сложно" } });
    defer runtime.deinit();
    try runtime.load(&reader, "карта/main.pns");
    try std.testing.expect(!runtime.hasGraphErrors());
    try runtime.compile();
    try std.testing.expect(!runtime.hasCompilationErrors());

    switch (try runtime.call("обновить", &.{.{ .number = 41.0 }})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42.0), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
    switch (try runtime.call("количество_аргументов", &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 2.0), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
    switch (try runtime.runStart()) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42.0), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "a broken script never surfaces as a Zig error, only as diagnostics" {
    const reader = MemoryReader{ .files = &.{
        .{
            .path = "карта/main.pns",
            .bytes = "экспорт функ сломано(",
        },
    } };

    var runtime = Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();
    try runtime.load(&reader, "карта/main.pns");
    try std.testing.expect(runtime.hasGraphErrors());

    try std.testing.expectError(error.GraphHasErrors, runtime.compile());
    // `compiled_graph` ещё не существует (`compile()` возвращает ошибку до
    // его построения), поэтому поиск по имени экспорта завершается так же,
    // как и для действительно неизвестного имени — таблицы экспортов
    // просто нет.
    try std.testing.expectError(error.ExportNotFound, runtime.call("сломано", &.{}));
    try std.testing.expectError(error.NotCompiled, runtime.runStart());
}

test "call after a runtime panic leaves the runtime able to run other exports" {
    const reader = MemoryReader{ .files = &.{
        .{
            .path = "карта/main.pns",
            .bytes = "экспорт функ упасть() -> Число\n" ++
                "паника(\"специально для теста\")\n" ++
                "конец\n" ++
                "экспорт функ уцелеть() -> Число\n" ++
                "1.0\n" ++
                "конец",
        },
    } };

    var runtime = Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();
    try runtime.load(&reader, "карта/main.pns");
    try runtime.compile();
    try std.testing.expect(!runtime.hasCompilationErrors());

    switch (try runtime.call("упасть", &.{})) {
        .success => return error.TestUnexpectedResult,
        .runtime_error => {},
    }
    switch (try runtime.call("уцелеть", &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 1.0), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "calling an export name that does not exist returns ExportNotFound" {
    const reader = MemoryReader{ .files = &.{
        .{
            .path = "карта/main.pns",
            .bytes = "экспорт функ существует() -> Число\n" ++
                "1.0\n" ++
                "конец",
        },
    } };

    var runtime = Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();
    try runtime.load(&reader, "карта/main.pns");
    try runtime.compile();
    try std.testing.expect(!runtime.hasCompilationErrors());

    try std.testing.expectError(error.ExportNotFound, runtime.call("не_существует", &.{}));
}
