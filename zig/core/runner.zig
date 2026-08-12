const std = @import("std");
const builtin = @import("builtin");
const ast = @import("ast.zig");
const bytecode = @import("bytecode.zig");
const compiler = @import("compiler.zig");
const diagnostic = @import("diagnostic.zig");
const lexer = @import("lexer.zig");
const module_compiler = @import("module_compiler.zig");
const module_loader = @import("module_loader.zig");
const parser = @import("parser.zig");
const prelude = @import("prelude.zig");
const resolver = @import("resolver.zig");
const source = @import("source.zig");
const symbols = @import("symbols.zig");
const target_policy = @import("target.zig");
const type_checker = @import("type_checker.zig");
const types = @import("types.zig");
const value = @import("value.zig");
const vm = @import("vm.zig");

// A single-file program has exactly one real module — this reader only ever
// serves that one path; the embedded prelude is appended separately via
// `Graph.appendPreludeModule`, never through this reader.
const SingleFileReader = struct {
    path: []const u8,
    bytes: []const u8,

    pub fn read(self: *const SingleFileReader, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        if (!std.mem.eql(u8, path, self.path)) return error.FileNotFound;
        return allocator.dupe(u8, self.bytes);
    }
};

pub const Execution = union(enum) {
    success: []const u8,
    runtime_error: []const u8,
};

pub const VerboseInfo = struct {
    declarations: usize = 0,
    symbols: ?usize = null,
    types: ?usize = null,
    functions: ?usize = null,
};

pub const SourceAnalysis = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    diagnostics: diagnostic.DiagnosticList = .{},
    // The user's own file is always module 0 — it's loaded via `graph.load`
    // before the embedded prelude is appended, and `appendPreludeModule`
    // only ever adds modules AFTER whatever's already there.
    graph: ?module_loader.Graph = null,
    compiled: ?module_compiler.GraphCompileResult = null,

    pub fn init(allocator: std.mem.Allocator) SourceAnalysis {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *SourceAnalysis) void {
        if (self.compiled) |*compiled| compiled.deinit();
        if (self.graph) |*graph| graph.deinit();
        self.diagnostics.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn hasErrors(self: *const SourceAnalysis) bool {
        for (self.diagnostics.items.items) |item| {
            if (item.severity == .err) return true;
        }
        return false;
    }

    pub fn tree(self: *const SourceAnalysis) ?*const ast.Ast {
        const graph = if (self.graph) |*value_| value_ else return null;
        if (graph.modules.items.len == 0) return null;
        return &graph.modules.items[0].tree;
    }

    pub fn resolution(self: *const SourceAnalysis) ?*const resolver.Resolution {
        const compiled = if (self.compiled) |*value_| value_ else return null;
        if (compiled.modules.len == 0) return null;
        return if (compiled.modules[0].resolution) |*value_| value_ else null;
    }

    pub fn checkedResult(self: *const SourceAnalysis) ?*const type_checker.CheckResult {
        const compiled = if (self.compiled) |*value_| value_ else return null;
        if (compiled.modules.len == 0) return null;
        return if (compiled.modules[0].checked) |*value_| value_ else null;
    }

    pub fn expressionTypeName(self: *SourceAnalysis, expression: ast.ExprId) anyerror!?[]const u8 {
        const checked = self.checkedResult() orelse return null;
        const type_id = checked.expression_types.get(expression) orelse return null;
        const resolved = self.resolution() orelse return null;
        return @as(?[]const u8, try formatTypeName(self.arena.allocator(), &checked.types, &resolved.symbols, type_id));
    }

    fn appendDiagnostics(self: *SourceAnalysis, items: *const diagnostic.DiagnosticList) !void {
        for (items.items.items) |item| {
            const message = try self.arena.allocator().dupe(u8, item.message);
            _ = try self.diagnostics.appendUnique(self.allocator, .{
                .phase = item.phase,
                .severity = item.severity,
                .span = item.span,
                .message = message,
            });
        }
    }

    fn report(self: *SourceAnalysis, phase: diagnostic.Phase, span: source.Span, message: []const u8) !void {
        _ = try self.diagnostics.appendUnique(self.allocator, .{
            .phase = phase,
            .severity = .err,
            .span = span,
            .message = try self.arena.allocator().dupe(u8, message),
        });
    }
};

fn formatTypeName(
    allocator: std.mem.Allocator,
    store: *const types.TypeStore,
    symbol_store: *const symbols.SymbolStore,
    type_id: types.TypeId,
) anyerror![]const u8 {
    const entry = store.get(type_id) orelse return allocator.dupe(u8, "<неизвестный тип>");
    return switch (entry.*) {
        .primitive => |primitive| allocator.dupe(u8, primitiveTypeName(primitive)),
        .tuple => |elements| formatTypeSequence(allocator, store, symbol_store, elements, "(", ")"),
        .function => |signature| blk: {
            const parameters = try formatTypeSequence(allocator, store, symbol_store, signature.parameters, "функ(", ")");
            const return_type = try formatTypeName(allocator, store, symbol_store, signature.return_type);
            break :blk std.fmt.allocPrint(allocator, "{s} -> {s}", .{ parameters, return_type });
        },
        .nominal => |nominal| blk: {
            const name = (symbol_store.get(nominal.symbol) orelse break :blk allocator.dupe(u8, "<неизвестный тип>")).name;
            if (nominal.arguments.len == 0) break :blk allocator.dupe(u8, name);
            const arguments = try formatTypeSequence(allocator, store, symbol_store, nominal.arguments, "", "");
            break :blk std.fmt.allocPrint(allocator, "{s}({s})", .{ name, arguments });
        },
        .array => |element| formatWrappedType(allocator, store, symbol_store, "Массив", element),
        .map => |map| blk: {
            const key = try formatTypeName(allocator, store, symbol_store, map.key);
            const mapped_value = try formatTypeName(allocator, store, symbol_store, map.value);
            break :blk std.fmt.allocPrint(allocator, "Соответствие({s}, {s})", .{ key, mapped_value });
        },
        .process => |message| formatWrappedType(allocator, store, symbol_store, "Процесс", message),
        .message => |payload| formatWrappedType(allocator, store, symbol_store, "Сообщение", payload),
        .pointer => |pointee| formatWrappedType(allocator, store, symbol_store, "Указатель", pointee),
        .generic_parameter => |identifier| std.fmt.allocPrint(allocator, "T{d}", .{identifier}),
        .poison => allocator.dupe(u8, "<ошибка типа>"),
        .unconstrained => allocator.dupe(u8, "<неограниченный тип>"),
    };
}

fn formatWrappedType(
    allocator: std.mem.Allocator,
    store: *const types.TypeStore,
    symbol_store: *const symbols.SymbolStore,
    name: []const u8,
    element: types.TypeId,
) anyerror![]const u8 {
    const rendered = try formatTypeName(allocator, store, symbol_store, element);
    return std.fmt.allocPrint(allocator, "{s}({s})", .{ name, rendered });
}

fn formatTypeSequence(
    allocator: std.mem.Allocator,
    store: *const types.TypeStore,
    symbol_store: *const symbols.SymbolStore,
    values: []const types.TypeId,
    prefix: []const u8,
    suffix: []const u8,
) anyerror![]const u8 {
    var result = try allocator.dupe(u8, prefix);
    for (values, 0..) |type_value, index| {
        const rendered = try formatTypeName(allocator, store, symbol_store, type_value);
        const separator: []const u8 = if (index == 0) "" else ", ";
        result = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ result, separator, rendered });
    }
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ result, suffix });
}

fn primitiveTypeName(primitive: types.Primitive) []const u8 {
    return switch (primitive) {
        .number => "Число",
        .integer => "Целое",
        .boolean => "Булево",
        .void => "Пусто",
        .never => "Никогда",
        .string => "Строка",
        .error_value => "Ошибка",
    };
}

pub const SourceRun = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    diagnostics: diagnostic.DiagnosticList = .{},
    execution: ?Execution = null,
    verbose: ?VerboseInfo = null,

    pub fn init(allocator: std.mem.Allocator) SourceRun {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *SourceRun) void {
        self.diagnostics.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn hasErrors(self: *const SourceRun) bool {
        for (self.diagnostics.items.items) |item| {
            if (item.severity == .err) return true;
        }
        return false;
    }

    fn appendDiagnostics(self: *SourceRun, items: *const diagnostic.DiagnosticList) !void {
        for (items.items.items) |item| {
            const message = try self.arena.allocator().dupe(u8, item.message);
            _ = try self.diagnostics.appendUnique(self.allocator, .{
                .phase = item.phase,
                .severity = item.severity,
                .span = item.span,
                .message = message,
            });
        }
    }

    fn report(self: *SourceRun, phase: diagnostic.Phase, span: source.Span, message: []const u8) !void {
        _ = try self.diagnostics.appendUnique(self.allocator, .{
            .phase = phase,
            .severity = .err,
            .span = span,
            .message = try self.arena.allocator().dupe(u8, message),
        });
    }
};

pub fn runSource(allocator: std.mem.Allocator, path: []const u8, input: []const u8) !SourceRun {
    return runSourceForTarget(allocator, path, input, .native);
}

pub fn checkSource(allocator: std.mem.Allocator, path: []const u8, input: []const u8) !SourceRun {
    return checkSourceForTarget(allocator, path, input, .native);
}

pub fn checkSourceForTarget(allocator: std.mem.Allocator, path: []const u8, input: []const u8, target_profile: target_policy.TargetProfile) !SourceRun {
    var analysis = try analyzeSourceForTarget(allocator, path, input, target_profile);
    defer analysis.deinit();

    var result = SourceRun.init(allocator);
    errdefer result.deinit();
    try result.appendDiagnostics(&analysis.diagnostics);
    return result;
}

pub fn analyzeSource(allocator: std.mem.Allocator, path: []const u8, input: []const u8) !SourceAnalysis {
    return analyzeSourceForTarget(allocator, path, input, .native);
}

pub fn analyzeSourceForTarget(
    allocator: std.mem.Allocator,
    path: []const u8,
    input: []const u8,
    target_profile: target_policy.TargetProfile,
) !SourceAnalysis {
    var analysis = SourceAnalysis.init(allocator);
    errdefer analysis.deinit();

    // A real `импорт` isn't supported by this single-file entry point (the
    // embedded prelude below is injected separately, never through user
    // `импорт` syntax) — checked with a throwaway parse so the rejection
    // keeps its own specific message instead of surfacing as a confusing
    // "не удалось загрузить модуль" from the graph loader, which has no
    // other file to find.
    if (try reportUnsupportedImports(allocator, input, &analysis)) return analysis;

    var graph = module_loader.Graph.init(allocator);
    errdefer graph.deinit();
    const canonical_path = try module_loader.resolveImportPath(allocator, path, "", ".pns");
    defer allocator.free(canonical_path);
    const reader = SingleFileReader{ .path = canonical_path, .bytes = input };
    try graph.load(&reader, path);
    _ = try graph.appendPreludeModule(prelude.SOURCE);
    analysis.graph = graph;

    var compiled = try module_compiler.compileGraphForTarget(allocator, &analysis.graph.?, target_profile);
    errdefer compiled.deinit();
    try analysis.appendDiagnostics(&compiled.diagnostics);
    analysis.compiled = compiled;
    return analysis;
}

pub fn runSourceWithVerbose(allocator: std.mem.Allocator, path: []const u8, input: []const u8, verbose: bool) !SourceRun {
    return runSourceWithVerboseForTarget(allocator, path, input, verbose, .native);
}

pub fn runSourceForTarget(allocator: std.mem.Allocator, path: []const u8, input: []const u8, target_profile: target_policy.TargetProfile) !SourceRun {
    return runSourceWithVerboseForTarget(allocator, path, input, false, target_profile);
}

pub fn runSourceWithVerboseForTarget(
    allocator: std.mem.Allocator,
    path: []const u8,
    input: []const u8,
    verbose: bool,
    target_profile: target_policy.TargetProfile,
) !SourceRun {
    var result = SourceRun.init(allocator);
    errdefer result.deinit();
    var analysis = try analyzeSourceForTarget(allocator, path, input, target_profile);
    defer analysis.deinit();
    try result.appendDiagnostics(&analysis.diagnostics);

    const tree = analysis.tree() orelse return result;
    if (verbose) result.verbose = .{ .declarations = tree.program.?.declarations.len };
    const resolved = analysis.resolution() orelse return result;
    if (result.verbose) |*info| info.symbols = resolved.symbols.symbols.items.len - 1;
    const checked = analysis.checkedResult() orelse return result;
    if (result.verbose) |*info| info.types = checked.types.types.items.len - 1;
    if (result.hasErrors()) return result;

    const compiled = &analysis.compiled.?;
    if (result.verbose) |*info| info.functions = compiled.program.functions.items.len;

    const start = compiled.start orelse {
        try result.report(.compiler, .{ .file_id = 0, .start = 0, .end = 0 }, "Compiler Error: не определена функция 'старт'");
        return result;
    };
    var machine = vm.Vm.initForTarget(allocator, &compiled.program, target_profile);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |runtime_value| {
            const rendered = try renderValue(result.arena.allocator(), runtime_value);
            result.execution = .{ .success = try std.fmt.allocPrint(result.arena.allocator(), "{s}{s}", .{ machine.output.items, rendered }) };
        },
        .runtime_error => |message| {
            result.execution = .{ .runtime_error = try std.fmt.allocPrint(result.arena.allocator(), "{s}{s}", .{ machine.output.items, message }) };
        },
    }
    return result;
}

fn reportUnsupportedImports(allocator: std.mem.Allocator, input: []const u8, analysis: *SourceAnalysis) !bool {
    var lexed = try lexer.tokenize(allocator, input, 0);
    defer lexed.deinit();
    var parsed = try parser.parse(allocator, lexed.tokens.items);
    defer parsed.deinit();
    for (parsed.ast.program.?.declarations) |declaration| {
        const import = switch (parsed.ast.decl(declaration).*) {
            .import => |entry| entry,
            else => continue,
        };
        try analysis.report(.compiler, import.span, "Compiler Error: выполнение импортов ещё не поддержано Zig-версией");
    }
    return analysis.hasErrors();
}

// Thin re-export — the real implementation lives in `vm.zig`
// (`renderRuntimeValue`) since `ввод_вывод.печать`/`.строка` need the
// SAME value-to-text conversion at RUNTIME, not just here at the final
// return-value line.
pub fn renderValue(allocator: std.mem.Allocator, runtime_value: value.Value) ![]const u8 {
    return vm.renderRuntimeValue(allocator, runtime_value);
}

test "runner executes an exported start function" {
    var result = try runSource(std.testing.allocator, "пример.ps", "экспорт функ старт() -> Число\n2.0 + 3.0\nконец");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("5", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "runner accumulates frontend diagnostics without executing" {
    var result = try runSource(std.testing.allocator, "ошибка.ps", "функ старт() -> Число\nнеизвестно\nконец");
    defer result.deinit();

    try std.testing.expect(result.hasErrors());
    try std.testing.expect(result.execution == null);
}

test "checker accepts a valid program without an entry function" {
    var result = try checkSource(std.testing.allocator, "библиотека.ps", "экспорт функ значение() -> Число\n42.0\nконец");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    try std.testing.expect(result.execution == null);
}

test "runner executes the native filesystem existence builtin" {
    var result = try runSource(std.testing.allocator, "пример.ps", "экспорт функ старт() -> Булево\nфс.есть(\"build.zig\")\nконец");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("true", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "runner executes the native filesystem delete builtin" {
    const path = "zzz_runner_delete_probe.tmp";
    var io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io.deinit();
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = path, .data = "probe" });

    var result = try runSource(std.testing.allocator, "пример.ps", "экспорт функ старт() -> Булево\nфс.удалить(\"" ++ path ++ "\")\nконец");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("true", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io.io(), path, .{}));
}

test "runner reports false when deleting a missing file" {
    var result = try runSource(std.testing.allocator, "пример.ps", "экспорт функ старт() -> Булево\nфс.удалить(\"zzz_runner_delete_missing.tmp\")\nконец");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("false", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "browser target rejects the native filesystem delete builtin before compilation" {
    var result = try checkSourceForTarget(std.testing.allocator, "плейграунд.ps", "экспорт функ старт() -> Булево\nфс.удалить(\"build.zig\")\nконец", .browser_interpreter);
    defer result.deinit();

    try std.testing.expect(result.hasErrors());
    try std.testing.expectEqualStrings("Type Error: builtin 'фс::удалить' недоступен для WASM-таргета", result.diagnostics.items.items[0].message);
}

test "browser target rejects the native filesystem builtin before compilation" {
    var result = try checkSourceForTarget(std.testing.allocator, "плейграунд.ps", "экспорт функ старт() -> Булево\nфс.есть(\"build.zig\")\nконец", .browser_interpreter);
    defer result.deinit();

    try std.testing.expect(result.hasErrors());
    try std.testing.expectEqualStrings("Type Error: builtin 'фс::есть' недоступен для WASM-таргета", result.diagnostics.items.items[0].message);
}

test "runner rejects imports before a single-file execution" {
    var result = try runSource(std.testing.allocator, "main.ps", "импорт \"математика\"\nэкспорт функ старт() -> Число\n1\nконец");
    defer result.deinit();

    try std.testing.expect(result.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Compiler Error: выполнение импортов ещё не поддержано Zig-версией", result.diagnostics.items.items[0].message);
    try std.testing.expect(result.execution == null);
}

test "analysis retains expressions and their inferred types" {
    const input = "экспорт функ старт() -> Число\n42.0\nконец";
    var analysis = try analyzeSource(std.testing.allocator, "пример.ps", input);
    defer analysis.deinit();

    const offset = std.mem.indexOf(u8, input, "42").?;
    const expression = analysis.tree().?.findExpressionAt(0, @intCast(offset)).?;
    const checked = analysis.checkedResult().?;
    const inferred = checked.expression_types.get(expression).?;
    try std.testing.expectEqual(checked.types.builtins.number, inferred);
    try std.testing.expectEqualStrings("Число", (try analysis.expressionTypeName(expression)).?);
}

test "runner executes the real embedded prelude's Option methods, not a hardcoded stand-in" {
    var result = try runSource(std.testing.allocator, "пример.ps",
        \\экспорт функ старт() -> Число
        \\пер есть: Опция(Число) = Опция.Есть(41.0)
        \\пер нет: Опция(Число) = Опция.Нет()
        \\есть.получить(0.0) + нет.получить(1.0)
        \\конец
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("42", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "runner writes then reads a file through фс.записать/фс.прочитать" {
    const path = "zzz_runner_read_write_probe.tmp";
    var io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io.deinit();
    defer std.Io.Dir.cwd().deleteFile(io.io(), path) catch {};

    var result = try runSource(std.testing.allocator, "пример.ps", "экспорт функ старт() -> Строка\nфс.записать(\"" ++ path ++ "\", \"привет\")\nвыбор фс.прочитать(\"" ++ path ++ "\")\nУспех(содержимое) -> содержимое\nНеудача(ошибка) -> ошибка.сообщение\nконец\nконец");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("привет", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

// Доказывает, что фс.прочитать НЕ блокирует весь VM целиком: процесс А
// уходит в фоновое чтение (await_async суспендит его), а НЕЗАВИСИМЫЙ
// процесс Б, ничего не ждущий, успевает полностью отработать и прислать
// свой ответ раньше, чем родитель получает результат чтения А — оба
// сообщения приходят родителю, но именно в этом порядке (Б первым).
test "runner runs an independent process to completion while another awaits async фс.прочитать" {
    const path = "zzz_runner_async_concurrency_probe.tmp";
    var io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io.deinit();
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = path, .data = "содержимое" });
    defer std.Io.Dir.cwd().deleteFile(io.io(), path) catch {};

    var result = try runSource(std.testing.allocator, "пример.ps",
        \\функ читатель(родитель: Процесс(Строка)) -> Пусто
        \\    выбор фс.прочитать("
    ++ path ++
        \\")
        \\        Успех(_) -> отправить(родитель, "чтение")
        \\        Неудача(_) -> отправить(родитель, "ошибка")
        \\    конец
        \\конец
        \\функ быстрый(родитель: Процесс(Строка)) -> Пусто
        \\    отправить(родитель, "быстрый")
        \\конец
        \\экспорт функ старт() -> Строка
        \\    запусти читатель(себя())
        \\    запусти быстрый(себя())
        \\    пер первое: Строка = получить()
        \\    пер второе: Строка = получить()
        \\    первое + "," + второе
        \\конец
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("быстрый,чтение", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "runner reports a Result failure when reading a missing file" {
    var result = try runSource(std.testing.allocator, "пример.ps", "экспорт функ старт() -> Булево\nфс.прочитать(\"zzz_runner_read_missing.tmp\").успех()\nконец");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("false", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "browser target rejects the native filesystem read/write builtins before compilation" {
    var read_result = try checkSourceForTarget(std.testing.allocator, "плейграунд.ps", "экспорт функ старт() -> Число\nфс.прочитать(\"build.zig\").успех()\n1\nконец", .browser_interpreter);
    defer read_result.deinit();
    try std.testing.expect(read_result.hasErrors());
    try std.testing.expectEqualStrings("Type Error: builtin 'фс::прочитать' недоступен для WASM-таргета", read_result.diagnostics.items.items[0].message);

    var write_result = try checkSourceForTarget(std.testing.allocator, "плейграунд.ps", "экспорт функ старт() -> Число\nфс.записать(\"build.zig\", \"x\").успех()\n1\nконец", .browser_interpreter);
    defer write_result.deinit();
    try std.testing.expect(write_result.hasErrors());
    try std.testing.expectEqualStrings("Type Error: builtin 'фс::записать' недоступен для WASM-таргета", write_result.diagnostics.items.items[0].message);
}

test "runner creates, lists and deletes a directory through фс.создать_директорию/список_директории/удалить_директорию" {
    const dir_path = "zzz_runner_dir_probe";
    var io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io.deinit();
    defer std.Io.Dir.cwd().deleteTree(io.io(), dir_path) catch {};

    var result = try runSource(std.testing.allocator, "пример.ps",
        \\экспорт функ старт() -> Строка
        \\фс.создать_директорию("zzz_runner_dir_probe")
        \\фс.записать("zzz_runner_dir_probe/a.txt", "x")
        \\пер до = фс.это_директория("zzz_runner_dir_probe")
        \\выбор фс.список_директории("zzz_runner_dir_probe")
        \\Успех(имена) -> если до тогда имена.получить(0, "?") иначе "не директория" конец
        \\Неудача(ошибка) -> ошибка.сообщение
        \\конец
        \\конец
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("a.txt", output),
        .runtime_error => return error.TestUnexpectedResult,
    }

    var delete_result = try runSource(std.testing.allocator, "пример.ps", "экспорт функ старт() -> Булево\nфс.удалить_директорию(\"" ++ dir_path ++ "\").успех()\nконец");
    defer delete_result.deinit();
    try std.testing.expectEqual(@as(usize, 0), delete_result.diagnostics.items.items.len);
    switch (delete_result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("true", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io.io(), dir_path, .{}));
}

test "runner reports это_директория is false for a plain file" {
    var result = try runSource(std.testing.allocator, "пример.ps", "экспорт функ старт() -> Булево\nфс.это_директория(\"build.zig\")\nконец");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("false", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "browser target rejects the native directory builtins before compilation" {
    var is_dir_result = try checkSourceForTarget(std.testing.allocator, "плейграунд.ps", "экспорт функ старт() -> Булево\nфс.это_директория(\"build.zig\")\nконец", .browser_interpreter);
    defer is_dir_result.deinit();
    try std.testing.expect(is_dir_result.hasErrors());
    try std.testing.expectEqualStrings("Type Error: builtin 'фс::это_директория' недоступен для WASM-таргета", is_dir_result.diagnostics.items.items[0].message);

    var create_result = try checkSourceForTarget(std.testing.allocator, "плейграунд.ps", "экспорт функ старт() -> Число\nфс.создать_директорию(\"x\").успех()\n1\nконец", .browser_interpreter);
    defer create_result.deinit();
    try std.testing.expect(create_result.hasErrors());
    try std.testing.expectEqualStrings("Type Error: builtin 'фс::создать_директорию' недоступен для WASM-таргета", create_result.diagnostics.items.items[0].message);

    var list_result = try checkSourceForTarget(std.testing.allocator, "плейграунд.ps", "экспорт функ старт() -> Число\nфс.список_директории(\"x\").успех()\n1\nконец", .browser_interpreter);
    defer list_result.deinit();
    try std.testing.expect(list_result.hasErrors());
    try std.testing.expectEqualStrings("Type Error: builtin 'фс::список_директории' недоступен для WASM-таргета", list_result.diagnostics.items.items[0].message);

    var delete_result = try checkSourceForTarget(std.testing.allocator, "плейграунд.ps", "экспорт функ старт() -> Число\nфс.удалить_директорию(\"x\").успех()\n1\nконец", .browser_interpreter);
    defer delete_result.deinit();
    try std.testing.expect(delete_result.hasErrors());
    try std.testing.expectEqualStrings("Type Error: builtin 'фс::удалить_директорию' недоступен для WASM-таргета", delete_result.diagnostics.items.items[0].message);
}

test "runner opens a file handle and reads back successive lines through фс.открыть" {
    const path = "zzz_runner_handle_probe.tmp";
    var io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io.deinit();
    defer std.Io.Dir.cwd().deleteFile(io.io(), path) catch {};

    var result = try runSource(std.testing.allocator, "пример.ps",
        \\экспорт функ старт() -> Строка
        \\выбор фс.открыть("zzz_runner_handle_probe.tmp")
        \\Успех(ф) тогда
        \\    ф.записать("первая\nвторая\n")
        \\    ф.закрыть()
        \\    выбор фс.открыть("zzz_runner_handle_probe.tmp")
        \\    Успех(ф2) тогда
        \\        пер строка1 = ф2.прочитать_строку().получить("?")
        \\        пер строка2 = ф2.прочитать_строку().получить("?")
        \\        пер остаток = ф2.прочитать().получить("?")
        \\        ф2.закрыть()
        \\        строка1 + "|" + строка2 + "|" + остаток
        \\    конец
        \\    Неудача(ошибка) -> ошибка.сообщение
        \\    конец
        \\конец
        \\Неудача(ошибка) -> ошибка.сообщение
        \\конец
        \\конец
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("первая|вторая|", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "runner overwrites at the current offset when записать is called again without closing" {
    const path = "zzz_runner_handle_overwrite_probe.tmp";
    var io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io.deinit();
    defer std.Io.Dir.cwd().deleteFile(io.io(), path) catch {};

    var result = try runSource(std.testing.allocator, "пример.ps",
        \\экспорт функ старт() -> Строка
        \\выбор фс.открыть("zzz_runner_handle_overwrite_probe.tmp")
        \\Успех(ф) тогда
        \\    ф.записать("abcdef")
        \\    ф.закрыть()
        \\    выбор фс.открыть("zzz_runner_handle_overwrite_probe.tmp")
        \\    Успех(ф2) тогда
        \\        ф2.записать("XY")
        \\        ф2.закрыть()
        \\        выбор фс.прочитать("zzz_runner_handle_overwrite_probe.tmp")
        \\        Успех(содержимое) -> содержимое
        \\        Неудача(ошибка) -> ошибка.сообщение
        \\        конец
        \\    конец
        \\    Неудача(ошибка) -> ошибка.сообщение
        \\    конец
        \\конец
        \\Неудача(ошибка) -> ошибка.сообщение
        \\конец
        \\конец
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("XYcdef", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "runner reports файл уже закрыт when reading a closed handle" {
    const path = "zzz_runner_handle_closed_probe.tmp";
    var io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io.deinit();
    defer std.Io.Dir.cwd().deleteFile(io.io(), path) catch {};

    var result = try runSource(std.testing.allocator, "пример.ps",
        \\экспорт функ старт() -> Строка
        \\выбор фс.открыть("zzz_runner_handle_closed_probe.tmp")
        \\Успех(ф) тогда
        \\    ф.закрыть()
        \\    выбор ф.прочитать()
        \\    Успех(содержимое) -> содержимое
        \\    Неудача(ошибка) -> ошибка.сообщение
        \\    конец
        \\конец
        \\Неудача(ошибка) -> ошибка.сообщение
        \\конец
        \\конец
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("файл уже закрыт", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "browser target rejects фс.открыть before compilation" {
    var result = try checkSourceForTarget(std.testing.allocator, "плейграунд.ps", "экспорт функ старт() -> Число\nфс.открыть(\"x\").успех()\n1\nконец", .browser_interpreter);
    defer result.deinit();
    try std.testing.expect(result.hasErrors());
    try std.testing.expectEqualStrings("Type Error: builtin 'фс::открыть' недоступен для WASM-таргета", result.diagnostics.items.items[0].message);
}

test "runner returns an empty argument array when program_args was never set" {
    var result = try runSource(std.testing.allocator, "пример.ps", "экспорт функ старт() -> Целое\nос.аргументы().длина()\nконец");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("0", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "runner returns the embedded panos version string" {
    var result = try runSource(std.testing.allocator, "пример.ps", "экспорт функ старт() -> Строка\nос.версия_паноса()\nконец");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expect(output.len > 0),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "runner round-trips an environment variable through установить_окружение/окружение/удалить_окружение" {
    var result = try runSource(std.testing.allocator, "пример.ps",
        \\экспорт функ старт() -> Строка
        \\ос.установить_окружение("ZZZ_RUNNER_ENV_PROBE", "значение")
        \\пер до = ос.окружение("ZZZ_RUNNER_ENV_PROBE").получить("?")
        \\ос.удалить_окружение("ZZZ_RUNNER_ENV_PROBE")
        \\пер после = ос.окружение("ZZZ_RUNNER_ENV_PROBE").получить("нет")
        \\до + "|" + после
        \\конец
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("значение|нет", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "runner captures exit code and stdout through ос.выполнить" {
    // `/bin/echo` doesn't exist on Windows at all (no POSIX filesystem
    // layout, and there's no single universal standalone echo.exe path —
    // `echo` there is a `cmd.exe` builtin, not a real executable file) —
    // this was never a real cross-platform test, just never compile-
    // tested on Windows until `внешний`/FFI itself started working there.
    if (comptime builtin.target.os.tag == .windows) return error.SkipZigTest;
    var result = try runSource(std.testing.allocator, "пример.ps",
        \\экспорт функ старт() -> Строка
        \\выбор ос.выполнить("/bin/echo", массив("привет"), ".")
        \\Успех(результат) -> результат.1
        \\Неудача(ошибка) -> ошибка.сообщение
        \\конец
        \\конец
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("привет\n", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "runner reports a Result failure when ос.выполнить can't find the program" {
    var result = try runSource(std.testing.allocator, "пример.ps", "экспорт функ старт() -> Булево\nос.выполнить(\"zzz_no_such_program_anywhere\", массив(), \".\").успех()\nконец");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("false", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "browser target rejects native ос builtins before compilation" {
    var env_result = try checkSourceForTarget(std.testing.allocator, "плейграунд.ps", "экспорт функ старт() -> Число\nос.окружение(\"x\").есть()\n1\nконец", .browser_interpreter);
    defer env_result.deinit();
    try std.testing.expect(env_result.hasErrors());
    try std.testing.expectEqualStrings("Type Error: builtin 'ос::окружение' недоступен для WASM-таргета", env_result.diagnostics.items.items[0].message);

    var exec_result = try checkSourceForTarget(std.testing.allocator, "плейграунд.ps", "экспорт функ старт() -> Число\nос.выполнить(\"x\", массив(), \".\").успех()\n1\nконец", .browser_interpreter);
    defer exec_result.deinit();
    try std.testing.expect(exec_result.hasErrors());
    try std.testing.expectEqualStrings("Type Error: builtin 'ос::выполнить' недоступен для WASM-таргета", exec_result.diagnostics.items.items[0].message);

    var exit_result = try checkSourceForTarget(std.testing.allocator, "плейграунд.ps", "экспорт функ старт() -> Число\nос.завершить(1)\nконец", .browser_interpreter);
    defer exit_result.deinit();
    try std.testing.expect(exit_result.hasErrors());
    try std.testing.expectEqualStrings("Type Error: builtin 'ос::завершить' недоступен для WASM-таргета", exit_result.diagnostics.items.items[0].message);
}

test "browser target still allows ос.аргументы/ос.версия_паноса" {
    var args_result = try checkSourceForTarget(std.testing.allocator, "плейграунд.ps", "экспорт функ старт() -> Целое\nос.аргументы().длина()\nконец", .browser_interpreter);
    defer args_result.deinit();
    try std.testing.expectEqual(@as(usize, 0), args_result.diagnostics.items.items.len);

    var version_result = try checkSourceForTarget(std.testing.allocator, "плейграунд.ps", "экспорт функ старт() -> Строка\nос.версия_паноса()\nконец", .browser_interpreter);
    defer version_result.deinit();
    try std.testing.expectEqual(@as(usize, 0), version_result.diagnostics.items.items.len);
}

test "runner decompresses a real gzip file through фс.прочитать + сжатие.разжать_gzip" {
    // Real gzip bytes for "hello world" (`gzip.compress(b"hello world", mtime=0)` in
    // Python) — a Panos source LITERAL can't hold this (arbitrary bytes, not
    // valid UTF-8), so this goes through a file on disk exactly like real
    // usage would (read a `.gz` file, decompress its raw byte content),
    // never through source-embedded string escapes.
    const gzip_bytes = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0xcb, 0x48, 0xcd,
        0xc9, 0xc9, 0x57, 0x28, 0xcf, 0x2f, 0xca, 0x49, 0x01, 0x00, 0x85, 0x11, 0x4a,
        0x0d, 0x0b, 0x00, 0x00, 0x00,
    };
    const path = "zzz_runner_gzip_probe.tmp";
    var io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io.deinit();
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = path, .data = &gzip_bytes });
    defer std.Io.Dir.cwd().deleteFile(io.io(), path) catch {};

    var result = try runSource(std.testing.allocator, "пример.ps", "экспорт функ старт() -> Строка\nвыбор фс.прочитать(\"" ++ path ++ "\")\nУспех(содержимое) -> выбор сжатие.разжать_gzip(содержимое)\nУспех(разжатое) -> разжатое\nНеудача(ошибка) -> ошибка.сообщение\nконец\nНеудача(ошибка) -> ошибка.сообщение\nконец\nконец");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("hello world", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "runner reports a Result failure for invalid gzip input" {
    var result = try runSource(std.testing.allocator, "пример.ps", "экспорт функ старт() -> Булево\nсжатие.разжать_gzip(\"не gzip\").успех()\nконец");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("false", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "browser target rejects сжатие.разжать_gzip before compilation" {
    var result = try checkSourceForTarget(std.testing.allocator, "плейграунд.ps", "экспорт функ старт() -> Число\nсжатие.разжать_gzip(\"x\").успех()\n1\nконец", .browser_interpreter);
    defer result.deinit();
    try std.testing.expect(result.hasErrors());
    try std.testing.expectEqualStrings("Type Error: builtin 'сжатие::разжать_gzip' недоступен для WASM-таргета", result.diagnostics.items.items[0].message);
}

test "runner introspects a real target file through синтаксис.*" {
    const target_path = "zzz_runner_syntax_target.ps";
    var io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io.deinit();
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = target_path, .data =
        \\&Json("товар")
        \\тип Товар = структура
        \\    &Json("название_поля")
        \\    имя: Строка
        \\    цена: Число
        \\конец
    });
    defer std.Io.Dir.cwd().deleteFile(io.io(), target_path) catch {};

    var result = try runSource(std.testing.allocator, "пример.ps",
        \\экспорт функ старт() -> Строка
        \\пер путь = "zzz_runner_syntax_target.ps"
        \\выбор синтаксис.структуры(путь)
        \\Успех(структуры) тогда
        \\    выбор синтаксис.поля(путь, "Товар")
        \\    Успех(поля) тогда
        \\        выбор синтаксис.аргумент_аннотации(путь, "Товар", "Json")
        \\        Успех(аргумент) тогда
        \\            выбор синтаксис.аннотации_поля(путь, "Товар", "имя")
        \\            Успех(аннполя) тогда
        \\                пер первое_поле = поля.получить(0, ("?", "?"))
        \\                структуры.получить(0, "?") + "|" + первое_поле.0 + "|" + первое_поле.1 + "|" + аргумент.получить("нет") + "|" + аннполя.получить(0, "?")
        \\            конец
        \\            Неудача(о) -> о.сообщение
        \\            конец
        \\        конец
        \\        Неудача(о) -> о.сообщение
        \\        конец
        \\    конец
        \\    Неудача(о) -> о.сообщение
        \\    конец
        \\конец
        \\Неудача(о) -> о.сообщение
        \\конец
        \\конец
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("Товар|имя|Строка|товар|Json", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "синтаксис.поля renders full generic type text, not a literal placeholder" {
    const target_path = "zzz_runner_syntax_generic_field.ps";
    var io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io.deinit();
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = target_path, .data =
        \\тип Заказ = структура
        \\    позиции: Массив(Число)
        \\    примечание: Опция(Строка)
        \\конец
    });
    defer std.Io.Dir.cwd().deleteFile(io.io(), target_path) catch {};

    var result = try runSource(std.testing.allocator, "пример.ps",
        \\экспорт функ старт() -> Строка
        \\пер путь = "zzz_runner_syntax_generic_field.ps"
        \\выбор синтаксис.поля(путь, "Заказ")
        \\Успех(поля) тогда
        \\    пер первое = поля.получить(0, ("?", "?"))
        \\    пер второе = поля.получить(1, ("?", "?"))
        \\    первое.1 + "|" + второе.1
        \\конец
        \\Неудача(о) -> о.сообщение
        \\конец
        \\конец
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("Массив(Число)|Опция(Строка)", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "runner reports Опция.Нет when an annotation argument is absent" {
    const target_path = "zzz_runner_syntax_no_arg.ps";
    var io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io.deinit();
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = target_path, .data =
        \\&Json
        \\тип Пусто = структура
        \\    значение: Число
        \\конец
    });
    defer std.Io.Dir.cwd().deleteFile(io.io(), target_path) catch {};

    var result = try runSource(std.testing.allocator, "пример.ps", "экспорт функ старт() -> Строка\nвыбор синтаксис.аргумент_аннотации(\"zzz_runner_syntax_no_arg.ps\", \"Пусто\", \"Json\")\nУспех(аргумент) -> аргумент.получить(\"нет-аргумента\")\nНеудача(о) -> о.сообщение\nконец\nконец");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("нет-аргумента", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "runner reports a Result failure for a missing struct or field" {
    const target_path = "zzz_runner_syntax_missing.ps";
    var io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io.deinit();
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = target_path, .data = "тип Товар = структура\nимя: Строка\nконец" });
    defer std.Io.Dir.cwd().deleteFile(io.io(), target_path) catch {};

    var struct_result = try runSource(std.testing.allocator, "пример.ps", "экспорт функ старт() -> Булево\nсинтаксис.поля(\"zzz_runner_syntax_missing.ps\", \"НетТакого\").успех()\nконец");
    defer struct_result.deinit();
    try std.testing.expectEqual(@as(usize, 0), struct_result.diagnostics.items.items.len);
    switch (struct_result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("false", output),
        .runtime_error => return error.TestUnexpectedResult,
    }

    var field_result = try runSource(std.testing.allocator, "пример.ps", "экспорт функ старт() -> Булево\nсинтаксис.аннотации_поля(\"zzz_runner_syntax_missing.ps\", \"Товар\", \"нетполя\").успех()\nконец");
    defer field_result.deinit();
    try std.testing.expectEqual(@as(usize, 0), field_result.diagnostics.items.items.len);
    switch (field_result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("false", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "runner reports a Result failure when the target file doesn't exist" {
    var result = try runSource(std.testing.allocator, "пример.ps", "экспорт функ старт() -> Булево\nсинтаксис.структуры(\"zzz_no_such_syntax_target.ps\").успех()\nконец");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("false", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "runner reports a Result failure when the target file has a syntax error" {
    const target_path = "zzz_runner_syntax_broken.ps";
    var io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io.deinit();
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = target_path, .data = "тип Товар = структура\n$$$\nконец" });
    defer std.Io.Dir.cwd().deleteFile(io.io(), target_path) catch {};

    var result = try runSource(std.testing.allocator, "пример.ps", "экспорт функ старт() -> Булево\nсинтаксис.структуры(\"zzz_runner_syntax_broken.ps\").успех()\nконец");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("false", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "browser target rejects all синтаксис.* builtins before compilation" {
    const names = [_][]const u8{ "структуры", "поля", "аннотации", "аргумент_аннотации", "аннотации_поля", "аргумент_аннотации_поля" };
    const arities = [_]usize{ 1, 2, 2, 3, 3, 4 };
    for (names, arities) |name, arity| {
        var call_buffer: [256]u8 = undefined;
        var args_buffer: [64]u8 = undefined;
        var written: usize = 0;
        var index: usize = 0;
        while (index < arity) : (index += 1) {
            const piece = try std.fmt.bufPrint(args_buffer[0..], "{s}\"x\"", .{if (index == 0) "" else ", "});
            @memcpy(call_buffer[written .. written + piece.len], piece);
            written += piece.len;
        }
        const test_source = try std.fmt.allocPrint(std.testing.allocator, "экспорт функ старт() -> Число\nсинтаксис.{s}({s}).успех()\n1\nконец", .{ name, call_buffer[0..written] });
        defer std.testing.allocator.free(test_source);

        var result = try checkSourceForTarget(std.testing.allocator, "плейграунд.ps", test_source, .browser_interpreter);
        defer result.deinit();
        try std.testing.expect(result.hasErrors());
        const expected = try std.fmt.allocPrint(std.testing.allocator, "Type Error: builtin 'синтаксис::{s}' недоступен для WASM-таргета", .{name});
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, result.diagnostics.items.items[0].message);
    }
}

test "runner percent-encodes reserved bytes through сеть.кодировать_url" {
    var result = try runSource(std.testing.allocator, "пример.ps", "экспорт функ старт() -> Строка\nсеть.кодировать_url(\"a b/c~d_e.f-g\")\nконец");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("a%20b%2Fc~d_e.f-g", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "runner reports a Result failure when сеть.подключиться can't reach the host" {
    // Port 1 is a reserved low port almost never bound on a dev/CI machine —
    // deterministic connection-refused without needing a real listener in
    // this test (the success path — real bytes over a real accepted TCP
    // connection — was verified manually against a live Python socket
    // server during development, see progress-report.md).
    var result = try runSource(std.testing.allocator, "пример.ps", "экспорт функ старт() -> Булево\nсеть.подключиться(\"127.0.0.1\", 1.0).успех()\nконец");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("false", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "browser target rejects сеть.подключиться before compilation" {
    var result = try checkSourceForTarget(std.testing.allocator, "плейграунд.ps", "экспорт функ старт() -> Число\nсеть.подключиться(\"x\", 1).успех()\n1\nконец", .browser_interpreter);
    defer result.deinit();
    try std.testing.expect(result.hasErrors());
    try std.testing.expectEqualStrings("Type Error: builtin 'сеть::подключиться' недоступен для WASM-таргета", result.diagnostics.items.items[0].message);
}

test "browser target still allows сеть.кодировать_url" {
    var result = try checkSourceForTarget(std.testing.allocator, "плейграунд.ps", "экспорт функ старт() -> Строка\nсеть.кодировать_url(\"x\")\nконец", .browser_interpreter);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
}

test "runner reports a Result failure when сеть.http_запрос can't reach the host" {
    // Deterministic connection-refused (port 1, almost never bound) without
    // needing a real listener in this test — the happy path (real request
    // to a real server, headers sent, body/status/headers read back
    // correctly) was verified manually against a live Python
    // `http.server` during development, see progress-report.md.
    var result = try runSource(std.testing.allocator, "пример.ps", "экспорт функ старт() -> Булево\nпер пусто: Соответствие(Строка, Строка) = соответствие()\nсеть.http_запрос(\"GET\", \"http://127.0.0.1:1/\", \"\", пусто).успех()\nконец");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("false", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "runner reports a Result failure for an unsupported HTTP method or malformed URL" {
    var bad_method = try runSource(std.testing.allocator, "пример.ps", "экспорт функ старт() -> Булево\nпер пусто: Соответствие(Строка, Строка) = соответствие()\nсеть.http_запрос(\"НЕВЕРНЫЙ\", \"http://127.0.0.1:1/\", \"\", пусто).успех()\nконец");
    defer bad_method.deinit();
    try std.testing.expectEqual(@as(usize, 0), bad_method.diagnostics.items.items.len);
    switch (bad_method.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("false", output),
        .runtime_error => return error.TestUnexpectedResult,
    }

    var bad_url = try runSource(std.testing.allocator, "пример.ps", "экспорт функ старт() -> Булево\nпер пусто: Соответствие(Строка, Строка) = соответствие()\nсеть.http_запрос(\"GET\", \"не url\", \"\", пусто).успех()\nконец");
    defer bad_url.deinit();
    try std.testing.expectEqual(@as(usize, 0), bad_url.diagnostics.items.items.len);
    switch (bad_url.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("false", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "browser target rejects сеть.http_запрос before compilation" {
    var result = try checkSourceForTarget(std.testing.allocator, "плейграунд.ps", "экспорт функ старт() -> Число\nпер пусто: Соответствие(Строка, Строка) = соответствие()\nсеть.http_запрос(\"GET\", \"x\", \"\", пусто).успех()\n1\nконец", .browser_interpreter);
    defer result.deinit();
    try std.testing.expect(result.hasErrors());
    try std.testing.expectEqualStrings("Type Error: builtin 'сеть::http_запрос' недоступен для WASM-таргета", result.diagnostics.items.items[0].message);
}

test "runner performs a full CRUD round-trip through бд.открыть/выполнить/запрос, omitting NULL columns" {
    const db_path = "zzz_runner_sql_probe.sqlite";
    var io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io.deinit();
    defer std.Io.Dir.cwd().deleteFile(io.io(), db_path) catch {};

    var result = try runSource(std.testing.allocator, "пример.ps",
        \\экспорт функ старт() -> Строка
        \\выбор бд.открыть("zzz_runner_sql_probe.sqlite")
        \\Успех(соединение) тогда
        \\    соединение.выполнить("CREATE TABLE товары (имя TEXT, цена TEXT)", массив())
        \\    соединение.выполнить("INSERT INTO товары (имя, цена) VALUES (?, ?)", массив("яблоко", "10"))
        \\    соединение.выполнить("INSERT INTO товары (имя, цена) VALUES (?, NULL)", массив("груша"))
        \\    выбор соединение.запрос("SELECT имя, цена FROM товары ORDER BY имя", массив())
        \\    Успех(строки) тогда
        \\        соединение.закрыть()
        \\        пер первая = строки.получить(0, соответствие())
        \\        пер вторая = строки.получить(1, соответствие())
        \\        пер есть_цена = если вторая.есть("цена") тогда "есть" иначе "нет" конец
        \\        первая.получить("имя", "?") + "|" + первая.получить("цена", "?") + "|" + вторая.получить("имя", "?") + "|" + есть_цена
        \\    конец
        \\    Неудача(о) -> о.сообщение
        \\    конец
        \\конец
        \\Неудача(о) -> о.сообщение
        \\конец
        \\конец
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        // Order: "груша" sorts before "яблоко" (Cyrillic г < я) — its
        // NULL цена is omitted from the map entirely (`получить` falls
        // back to "?"), "яблоко" has a real цена and `.есть("цена")`
        // confirms it.
        .success => |output| try std.testing.expectEqualStrings("груша|?|яблоко|есть", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "runner reports a Result failure for bad SQL and for a closed connection" {
    const db_path = "zzz_runner_sql_errors.sqlite";
    var io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io.deinit();
    defer std.Io.Dir.cwd().deleteFile(io.io(), db_path) catch {};

    var bad_sql = try runSource(std.testing.allocator, "пример.ps", "экспорт функ старт() -> Булево\nвыбор бд.открыть(\"zzz_runner_sql_errors.sqlite\")\nУспех(с) -> с.выполнить(\"НЕ SQL СОВСЕМ\", массив()).успех()\nНеудача(о) -> ложь\nконец\nконец");
    defer bad_sql.deinit();
    try std.testing.expectEqual(@as(usize, 0), bad_sql.diagnostics.items.items.len);
    switch (bad_sql.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("false", output),
        .runtime_error => return error.TestUnexpectedResult,
    }

    var closed = try runSource(std.testing.allocator, "пример.ps", "экспорт функ старт() -> Булево\nвыбор бд.открыть(\"zzz_runner_sql_errors.sqlite\")\nУспех(с) тогда\n    с.закрыть()\n    с.выполнить(\"SELECT 1\", массив()).успех()\nконец\nНеудача(о) -> ложь\nконец\nконец");
    defer closed.deinit();
    try std.testing.expectEqual(@as(usize, 0), closed.diagnostics.items.items.len);
    switch (closed.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("false", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "runner reports a Result failure when opening an invalid database path" {
    var result = try runSource(std.testing.allocator, "пример.ps", "экспорт функ старт() -> Булево\nбд.открыть(\"/несуществующая/директория/нет.sqlite\").успех()\nконец");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("false", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "browser target rejects бд.открыть before compilation" {
    var result = try checkSourceForTarget(std.testing.allocator, "плейграунд.ps", "экспорт функ старт() -> Число\nбд.открыть(\"x\").успех()\n1\nконец", .browser_interpreter);
    defer result.deinit();
    try std.testing.expect(result.hasErrors());
    try std.testing.expectEqualStrings("Type Error: builtin 'бд::открыть' недоступен для WASM-таргета", result.diagnostics.items.items[0].message);
}

test "runner calls a real libc function through внешний, marshaling Int32 args and return" {
    var result = try runSource(std.testing.allocator, "пример.ps", "внешний \"libc\" функ abs(значение: Целое(32)) -> Целое(32)\nэкспорт функ старт() -> Целое\nabs(-42)\nконец");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("42", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "runner reuses prepared внешний ABI across repeated calls" {
    var result = try runSource(std.testing.allocator, "пример.ps", "внешний \"libc\" функ abs(значение: Целое(32)) -> Целое(32)\nэкспорт функ старт() -> Целое\nпер сумма: Целое = 0\nпер i: Целое = 0\nпока i < 100 цикл\n    сумма = сумма + abs(i - 50)\n    i = i + 1\nконец\nсумма\nконец");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("2500", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "runner marshals КСтрока arguments and return through внешний" {
    var length_result = try runSource(std.testing.allocator, "пример.ps", "внешний \"libc\" функ strlen(текст: КСтрока) -> Целое(64)\nэкспорт функ старт() -> Целое\nstrlen(\"привет\")\nконец");
    defer length_result.deinit();
    try std.testing.expectEqual(@as(usize, 0), length_result.diagnostics.items.items.len);
    switch (length_result.execution orelse return error.TestUnexpectedResult) {
        // "привет" — 6 Cyrillic letters, 2 UTF-8 bytes each — strlen
        // counts bytes, not runes.
        .success => |output| try std.testing.expectEqualStrings("12", output),
        .runtime_error => return error.TestUnexpectedResult,
    }

    var getenv_result = try runSource(std.testing.allocator, "пример.ps", "внешний \"libc\" функ getenv(имя: КСтрока) -> КСтрока\nэкспорт функ старт() -> Строка\ngetenv(\"ZZZ_PANOS_FFI_MISSING_VAR_XYZ\")\nконец");
    defer getenv_result.deinit();
    try std.testing.expectEqual(@as(usize, 0), getenv_result.diagnostics.items.items.len);
    switch (getenv_result.execution orelse return error.TestUnexpectedResult) {
        // A real C NULL return, coerced to an empty `Строка` by
        // `std.mem.span` on a null pointer would itself crash — this
        // just confirms a genuinely-missing env var round-trips without
        // panicking; a real end-to-end non-empty round-trip was verified
        // manually (`PANOS_FFI_TEST_VAR=... zig build run -- ...`, see
        // progress-report.md) since setting real process environment for
        // a `std.testing`-run test is its own can of worms.
        .success => |output| try std.testing.expect(output.len == 0),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "runner reports a Resolve Error for a missing внешний library or symbol" {
    var missing_library = try runSource(std.testing.allocator, "пример.ps", "внешний \"zzz_no_such_library_anywhere\" функ f() -> Целое(32)\nэкспорт функ старт() -> Целое\n0\nконец");
    defer missing_library.deinit();
    try std.testing.expect(missing_library.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, missing_library.diagnostics.items.items[0].message, "не найдена") != null);

    var missing_symbol = try runSource(std.testing.allocator, "пример.ps", "внешний \"libc\" функ zzz_no_such_symbol_anywhere() -> Целое(32)\nэкспорт функ старт() -> Целое\n0\nконец");
    defer missing_symbol.deinit();
    try std.testing.expect(missing_symbol.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, missing_symbol.diagnostics.items.items[0].message, "не экспортирует") != null);
}

test "runner resolves a relative внешний library path against the script's own directory, not cwd" {
    // No real shared library needs to exist on disk for this — a
    // missing-library error still reports the path the resolver
    // actually TRIED, which is enough to confirm it joined against
    // "проект" (the script's directory) rather than leaving
    // "./libs/zzz_missing" untouched (which would mean cwd-relative
    // resolution, not script-relative).
    var result = try runSource(std.testing.allocator, "проект/main.ps", "внешний \"./libs/zzz_missing_lib\" функ f() -> Целое(32)\nэкспорт функ старт() -> Целое\n0\nконец");
    defer result.deinit();
    try std.testing.expect(result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.diagnostics.items.items[0].message, "проект/libs/zzz_missing_lib") != null);
}

test "browser target rejects внешний before compilation" {
    var result = try checkSourceForTarget(std.testing.allocator, "плейграунд.ps", "внешний \"libc\" функ getpid() -> Целое(32)\nэкспорт функ старт() -> Целое\ngetpid()\nконец", .browser_interpreter);
    defer result.deinit();
    try std.testing.expect(result.hasErrors());
    try std.testing.expectEqualStrings("Resolve Error: 'внешний' недоступно в этом runtime-таргете", result.diagnostics.items.items[0].message);
}

// Best-effort single HTTP/1.0 GET over a raw socket — `null` on connection
// failure (server not listening YET — the accept happens on a background
// worker thread only after the VM scheduler actually reaches it, so the
// caller retries instead of assuming a fixed startup delay).
fn tryHttpGetOnce(allocator: std.mem.Allocator, port: u16, path: []const u8) !?[]u8 {
    return tryHttpGetOnceWithHeader(allocator, port, path, null);
}

fn tryHttpGetOnceWithHeader(allocator: std.mem.Allocator, port: u16, path: []const u8, extra_header: ?[]const u8) !?[]u8 {
    var io = std.Io.Threaded.init(allocator, .{});
    defer io.deinit();
    const address = std.Io.net.IpAddress.parse("127.0.0.1", port) catch return null;
    const stream = std.Io.net.IpAddress.connect(&address, io.io(), .{ .mode = .stream }) catch return null;
    defer stream.close(io.io());
    var writer = stream.writer(io.io(), &.{});
    const request_text = try std.fmt.allocPrint(allocator, "GET {s} HTTP/1.0\r\nHost: 127.0.0.1\r\n{s}Connection: close\r\n\r\n", .{ path, extra_header orelse "" });
    defer allocator.free(request_text);
    writer.interface.writeAll(request_text) catch return null;
    writer.interface.flush() catch return null;
    var reader = stream.reader(io.io(), &.{});
    var collected: std.ArrayList(u8) = .empty;
    errdefer collected.deinit(allocator);
    var temp: [4096]u8 = undefined;
    while (true) {
        const n = reader.interface.readSliceShort(&temp) catch break;
        if (n == 0) break;
        try collected.appendSlice(allocator, temp[0..n]);
    }
    return try collected.toOwnedSlice(allocator);
}

test "runner serves a real HTTP request through сеть.http_сервер_слушать" {
    const port: u16 = 18933;
    const source_text = std.fmt.comptimePrint(
        \\функ отработать(запрос: Запрос) -> Строка
        \\    запрос.ответить(200.0, "text/plain", "привет-с-сервера")
        \\    запрос.путь()
        \\конец
        \\функ обработать(слушатель: Слушатель) -> Строка
        \\    выбор слушатель.принять_запрос()
        \\        Успех(запрос) -> отработать(запрос)
        \\        Неудача(ошибка) -> "accept-ошибка:" + ошибка.сообщение
        \\    конец
        \\конец
        \\экспорт функ старт() -> Строка
        \\    выбор сеть.http_сервер_слушать({d}.0)
        \\        Успех(слушатель) -> обработать(слушатель)
        \\        Неудача(ошибка) -> "listen-ошибка:" + ошибка.сообщение
        \\    конец
        \\конец
    , .{port});

    const ServerRun = struct {
        result: ?(anyerror!SourceRun) = null,

        fn run(self: *@This(), src: []const u8) void {
            self.result = runSource(std.testing.allocator, "сервер.ps", src);
        }
    };
    var server_run: ServerRun = .{};
    const thread = try std.Thread.spawn(.{}, ServerRun.run, .{ &server_run, source_text });

    var poll_io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer poll_io.deinit();
    var response: ?[]u8 = null;
    var attempt: usize = 0;
    while (attempt < 200) : (attempt += 1) {
        response = tryHttpGetOnce(std.testing.allocator, port, "/probe") catch null;
        if (response != null) break;
        std.Io.sleep(poll_io.io(), .fromMilliseconds(10), .awake) catch {};
    }
    thread.join();

    var result = try (server_run.result orelse return error.TestUnexpectedResult);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("/probe", output),
        .runtime_error => return error.TestUnexpectedResult,
    }

    const body = response orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.startsWith(u8, body, "HTTP/1.1 200 "));
    try std.testing.expect(std.mem.indexOf(u8, body, "привет-с-сервера") != null);
}

test "runner reads a custom request header through Запрос.заголовок" {
    const port: u16 = 18934;
    const source_text = std.fmt.comptimePrint(
        \\функ отработать(запрос: Запрос) -> Строка
        \\    пер значение: Строка = выбор запрос.заголовок("X-Panos-Test")
        \\        Есть(текст) -> текст
        \\        Нет -> "отсутствует"
        \\    конец
        \\    запрос.ответить(200.0, "text/plain", значение)
        \\    значение
        \\конец
        \\функ обработать(слушатель: Слушатель) -> Строка
        \\    выбор слушатель.принять_запрос()
        \\        Успех(запрос) -> отработать(запрос)
        \\        Неудача(ошибка) -> "accept-ошибка:" + ошибка.сообщение
        \\    конец
        \\конец
        \\экспорт функ старт() -> Строка
        \\    выбор сеть.http_сервер_слушать({d}.0)
        \\        Успех(слушатель) -> обработать(слушатель)
        \\        Неудача(ошибка) -> "listen-ошибка:" + ошибка.сообщение
        \\    конец
        \\конец
    , .{port});

    const ServerRun = struct {
        result: ?(anyerror!SourceRun) = null,

        fn run(self: *@This(), src: []const u8) void {
            self.result = runSource(std.testing.allocator, "сервер.ps", src);
        }
    };
    var server_run: ServerRun = .{};
    const thread = try std.Thread.spawn(.{}, ServerRun.run, .{ &server_run, source_text });

    var poll_io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer poll_io.deinit();
    var response: ?[]u8 = null;
    var attempt: usize = 0;
    while (attempt < 200) : (attempt += 1) {
        response = tryHttpGetOnceWithHeader(std.testing.allocator, port, "/", "X-Panos-Test: заголовок-ok\r\n") catch null;
        if (response != null) break;
        std.Io.sleep(poll_io.io(), .fromMilliseconds(10), .awake) catch {};
    }
    thread.join();

    var result = try (server_run.result orelse return error.TestUnexpectedResult);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("заголовок-ok", output),
        .runtime_error => return error.TestUnexpectedResult,
    }

    const body = response orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "заголовок-ok") != null);
}

// Crash-oracle fuzz test over the ENTIRE pipeline (lex → parse → resolve →
// typecheck → compile → run) — the class of bug this session actually
// found in panosiki was never a lexer/parser crash, it was VM/typechecker
// invariants breaking on legitimate-looking but unusual programs (empty
// collection literals feeding generic inference, named-argument
// constructors, cross-pass argument-order desync, ...). Random bytes
// essentially never get past parsing, so the corpus below seeds a handful
// of REAL near-miss shapes (empty generic literals, reordered named args,
// nested match/if with mixed interface types) that the mutator can then
// perturb — closer to what actually broke than pure byte noise. Diagnostics
// and runtime errors are both an expected, PASSING outcome here; only an
// actual panic/crash fails this test.
test "full pipeline never panics on arbitrary or near-valid programs" {
    try std.testing.fuzz(std.testing.allocator, testPipelineNeverPanics, .{
        .corpus = &.{
            "",
            "экспорт функ старт() -> Число\n0\nконец",
            "тип Т[T] = структура\nx: Массив(T)\nконец\nфунк ф[T](a: T) -> Т(T)\nТ(массив())\nконец",
            "тип Т = структура\nx: Число\ny: Число\nконец\nэкспорт функ старт() -> Число\nТ(y = 1, x = 2).x\nконец",
            "экспорт функ старт() -> Число\nвыбор 1\n1 -> 2\n_ -> 3\nконец\nконец",
            "экспорт функ старт() -> Пусто\nпер x: Соответствие(Строка, Число) = соответствие()\nx[\"a\"] = 1\nконец",
            "функ ф() -> Никогда\nпаника(\"x\")\nконец",
            // Return-only generic type parameter, seeded from an
            // annotated `пер` (bidirectional inference, added this
            // session) — both the resolvable and genuinely-unresolvable
            // shapes.
            "тип К[T] = структура\nэ: Массив(T)\nконец\nфунк ф[T]() -> К(T)\nК(массив())\nконец\nэкспорт функ старт() -> Пусто\nпер к: К(Число) = ф()\nконец",
            "тип К[T] = структура\nэ: Массив(T)\nконец\nфунк ф[T]() -> К(T)\nК(массив())\nконец\nэкспорт функ старт() -> Пусто\nпер к: Строка = ф()\nконец",
            // Cross-module-shaped generic interface bound (single-file
            // approximation) — the class of bug that broke `pan init`.
            "тип Т = структура\nx: Число\nконец\nреализация Печатаемое для Т\nфунк вСтроку(это: Т) -> Строка\n\"т\"\nконец\nконец\nфунк ф[T: Печатаемое](x: T) -> Строка\nx.вСтроку()\nконец\nэкспорт функ старт() -> Строка\nф(Т(1))\nконец",
        },
    });
}

fn testPipelineNeverPanics(allocator: std.mem.Allocator, smith: *std.testing.Smith) anyerror!void {
    var buffer: [4096]u8 = undefined;
    const len = smith.slice(&buffer);
    var result = try runSource(allocator, "фазз.ps", buffer[0..len]);
    defer result.deinit();
}
