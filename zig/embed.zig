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
/// `внешний "хост" функ ...`. Встраивающее приложение экспортирует
/// соответствующие C-ABI `pub export fn` и включает `rdynamic` в своей
/// Zig-сборке; это намеренно не требует вносить игровой API в VM панос.
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
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) Runtime {
        var graph_result = panos_core.module_loader.Graph.init(allocator);
        graph_result.global_search_roots = config.global_search_roots;
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
