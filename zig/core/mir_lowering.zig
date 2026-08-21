const std = @import("std");
const ast = @import("ast.zig");
const mir = @import("mir.zig");
const mir_builder = @import("mir_builder.zig");
const resolver = @import("resolver.zig");
const source = @import("source.zig");
const symbols = @import("symbols.zig");
const type_checker = @import("type_checker.zig");
const types = @import("types.zig");
const wasm_module = @import("wasm_module.zig");
const wasm_heap = @import("wasm_heap.zig");

// Не привязан ни к одной реальной объявленной переменной — то же
// соглашение о "заглушке", что уже установлено в `wasm_heap.zig` для
// локальных переменных, синтезированных компилятором.
const dummy_symbol: symbols.SymbolId = @enumFromInt(0);

// AST (после resolve+typecheck) → MIR. Работает в ТОЙ ЖЕ точке пайплайна,
// что и `compiler.zig`: читает уже вычисленные таблицы resolver/
// type-checker (`resolution.expr_symbols`/`decl_symbols`/
// `function_parameters`, `checked.expression_types`/`symbol_types`/
// `types`), НИКОГДА их не мутирует и не пересчитывает, не изменяет AST.
//
// ОБЛАСТЬ ПОКРЫТИЯ: числовые/булевы/строковые литералы, локальные
// переменные (объявление/чтение через `пер`/параметры), унарные/бинарные
// операторы (включая короткое замыкание `и`/`или`), `если`/`иначе`,
// `пока` (+ `прервать`/`продолжить`), обычные вызовы функций (по
// идентификатору ИЛИ по произвольному значению — общий запасной вариант
// `Call_Value_Instr`), `возврат`. НЕ покрыто (сообщается через
// `AotDiagnostic` + `error.AotUnsupported`, а не молча производит
// некорректный MIR): `выбор`/ADT, замыкания, интерфейсы, акторы,
// асинхронный I/O, generic'и, sugar операторной перегрузки
// (Сравниваемое/Арифметика), `для`/`для..in`, деструктуризация,
// builtin'ы, методы, `внешний`.

pub const FlowResult = enum { continues, terminates };

const ExprOutcome = struct {
    value: mir.ValueId,
    flow: FlowResult,
};

fn continuesWith(value: mir.ValueId) ExprOutcome {
    return .{ .value = value, .flow = .continues };
}

const terminated: ExprOutcome = .{ .value = mir.invalid_value, .flow = .terminates };

const LoopTargets = struct {
    continue_target: mir.BlockId,
    break_target: mir.BlockId,
};

// Одна попытка понижения останавливается на первой неподдержанной
// AOT-конструкции, поэтому одной структурированной диагностики достаточно.
// Все срезы заимствованы из статических строк или исходного AST и потому
// остаются валидными на весь вызов понижения (и пока вызывающая сторона
// сразу же сообщает об ошибке после возврата).
pub const AotDiagnostic = struct {
    reason: ?[]const u8 = null,
    subject: ?[]const u8 = null,

    fn reset(self: *AotDiagnostic) void {
        self.* = .{};
    }

    fn report(self: *AotDiagnostic, reason: []const u8, subject: ?[]const u8) void {
        if (self.reason != null) return;
        self.reason = reason;
        self.subject = subject;
    }
};

// Заполняется ТОЛЬКО во время понижения ТЕЛА лямбды (`lowerLambda` ниже) —
// захваченный символ разрешается через `frame_load{env_local, slot}`
// вместо обычной карты `symbol_to_local`, поскольку живёт в аллокации
// окружения замыкания, а не в настоящей WASM-локали самого тела лямбды.
// `env_local` — это собственный завершающий параметр `env_ptr` тела
// лямбды (`LocalId`, заново загружается через `load_local` при каждой
// надобности — та же дисциплина "перезагрузки из Local", что уже
// используется повсюду в этом файле).
const CaptureEnv = struct {
    env_local: mir.LocalId,
    index_of: std.AutoHashMap(symbols.SymbolId, u32),

    fn deinit(self: *CaptureEnv) void {
        self.index_of.deinit();
    }
};

const LoweringContext = struct {
    allocator: std.mem.Allocator,
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    checked: *const type_checker.CheckResult,
    builder: mir_builder.Builder,
    symbol_to_local: std.AutoHashMap(symbols.SymbolId, mir.LocalId),
    symbol_to_function: *const std.AutoHashMap(symbols.SymbolId, mir.FunctionId),
    // Известно, только пока локаль всё ещё держит литеральную лямбду,
    // присвоенную через `пер f = функ ... конец`. Это даёт DOM-промоушену
    // точную раскладку вложенного окружения без изменения рантайм-ABI
    // бокса замыкания. Любое последующее присваивание консервативно
    // инвалидирует запись.
    closure_origins: std.AutoHashMap(symbols.SymbolId, ast.ExprId),
    diagnostic: *AotDiagnostic,
    loops: std.ArrayList(LoopTargets) = .empty,
    capture_env: ?CaptureEnv = null,

    fn unsupported(self: *LoweringContext, comptime what: []const u8) error{AotUnsupported} {
        self.diagnostic.report(what, null);
        return error.AotUnsupported;
    }

    fn deinit(self: *LoweringContext) void {
        self.loops.deinit(self.allocator);
        self.closure_origins.deinit();
        self.symbol_to_local.deinit();
        if (self.capture_env) |*env| env.deinit();
        self.* = undefined;
    }
};

fn expressionSpan(tree: *const ast.Ast, expression: ast.ExprId) source.Span {
    return switch (tree.expr(expression).*) {
        .error_node => |span| span,
        inline else => |value| value.span,
    };
}

fn functionReturnType(checked: *const type_checker.CheckResult, symbol: symbols.SymbolId) types.TypeId {
    const signature_id = checked.symbol_types.get(symbol) orelse return checked.types.builtins.void;
    const entry = checked.types.get(signature_id) orelse return checked.types.builtins.void;
    return switch (entry.*) {
        .function => |value| value.return_type,
        else => checked.types.builtins.void,
    };
}

pub fn lowerModule(
    allocator: std.mem.Allocator,
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    checked: *const type_checker.CheckResult,
) !mir.Module {
    var diagnostic: AotDiagnostic = .{};
    return lowerModuleWithDiagnostic(allocator, tree, resolution, checked, &diagnostic);
}

pub fn lowerModuleWithDiagnostic(
    allocator: std.mem.Allocator,
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    checked: *const type_checker.CheckResult,
    diagnostic: *AotDiagnostic,
) !mir.Module {
    diagnostic.reset();
    var module = mir.Module.init(allocator);
    errdefer module.deinit(allocator);

    var symbol_to_function: std.AutoHashMap(symbols.SymbolId, mir.FunctionId) = .init(allocator);
    defer symbol_to_function.deinit();

    const program = tree.program orelse return module;

    // Два прохода — проход 1 резервирует каждую функцию (и опережающим
    // ссылкам, и рекурсии нужно, чтобы FunctionId вызываемой функции
    // существовал до понижения любого тела); проход 2 понижает тела.
    for (program.declarations) |decl_id| {
        const function = switch (tree.decl(decl_id).*) {
            .function => |value| value,
            else => continue,
        };
        // Generic-функции компилируются: generic'и панос никогда не
        // монoморфизируются (см. собственные doc-комментарии
        // `type_checker.zig`), поэтому тело generic-функции компилируется
        // ровно один раз, неспециализированным — та же логика, что и для
        // default-методов `.interface_decl` (см. собственный
        // doc-комментарий `reserveMethods` на этой ветке). Безопасно при
        // условии, что `T` затрагивается ТОЛЬКО через ограничение
        // интерфейса (обычная диспетчеризация `checked.interface_calls`/
        // `interface_casts`, УЖЕ обрабатываемая `lowerCall`/
        // `applyInterfaceCast` — обычной диспетчеризации интерфейса не
        // важно, пришло ли значение типа интерфейса из generic-приведения
        // по ограничению или из явного не-generic параметра интерфейса)
        // или как непрозрачный `.nominal`/`.function`/сквозной проброс
        // поля структуры (`frame_store`/`frame_load` в `wasm_objects.zig`
        // типизируют каждое значение по его СОБСТВЕННОМУ конкретному
        // производящему выражению в этом месте вызова, никогда по
        // объявленному generic-типу) — а НЕ как голое возвращаемое/
        // сохраняемое значение `T`, чьё СОБСТВЕННОЕ WASM-представление
        // (i32 против f64) могло бы законно различаться между разными
        // инстанциациями, достижимыми из одного скомпилированного тела
        // (этот более узкий случай потребовал бы настоящей специализации
        // по инстанциации, здесь не реализовано).
        const symbol = resolution.decl_symbols.get(decl_id) orelse continue;
        const result_type = functionReturnType(checked, symbol);
        const function_id = try mir_builder.newFunction(&module, allocator, function.name, symbol, result_type, function.span);
        module.functions.items[@intFromEnum(function_id)].type_store = &checked.types;
        try symbol_to_function.put(symbol, function_id);
    }
    try reserveMethods(&module, allocator, tree, resolution, checked, program, &symbol_to_function, null, 0);

    for (program.declarations) |decl_id| {
        const function = switch (tree.decl(decl_id).*) {
            .function => |value| value,
            else => continue,
        };
        const symbol = resolution.decl_symbols.get(decl_id) orelse continue;
        const function_id = symbol_to_function.get(symbol) orelse continue;
        try lowerFunctionBody(allocator, tree, resolution, checked, &module, function_id, decl_id, function.body, &symbol_to_function, diagnostic);
    }
    try lowerMethods(&module, allocator, tree, resolution, checked, program, &symbol_to_function, diagnostic);

    return module;
}

// Методы `реализация Тип ... конец` — компилируются НАТИВНЫМ bytecode-
// бэкендом (`compiler.zig`) как обычный дополнительный проход по
// `implementation.methods`, вызывающий те же `predeclareFunction`/
// `compileFunction`, что и для верхнеуровневых `.function`-деклараций
// (`это` — это просто `parameters[0]`, без специального связывания).
// `mir_lowering.zig` зеркалит нативный путь: `lowerFunctionBody` уже
// полностью обобщён по `decl_id`/`body`, методу здесь не нужно ничего
// специфичного.
//
// Единственное реальное отличие от обычной функции: имя, под которым
// резервируется `FunctionId` метода, MANGLED (`"{Тип}::{метод}"`, та же
// конвенция, которую нативная VM уже использует для своего реестра
// методов), а не голое имя метода, потому что секция экспорта
// `wasm_emit.zig` пишет имя КАЖДОЙ функции безусловно, без дедупликации
// — две разные структуры, объявляющие одноимённый метод (например,
// коллизии вида `.длина()`), иначе произвели бы дублирующиеся записи
// экспорта WASM.
fn mangledMethodName(module: *mir.Module, target_type: []const u8, method_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(module.arena.allocator(), "{s}::{s}", .{ target_type, method_name });
}

fn reserveMethods(
    module: *mir.Module,
    allocator: std.mem.Allocator,
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    checked: *const type_checker.CheckResult,
    program: anytype,
    symbol_to_function: *std.AutoHashMap(symbols.SymbolId, mir.FunctionId),
    reachable: ?*const ReachableSet,
    module_index: usize,
) !void {
    for (program.declarations) |decl_id| {
        switch (tree.decl(decl_id).*) {
            .impl => |implementation| for (implementation.methods) |method_decl_id| {
                const function = tree.decl(method_decl_id).function;
                const symbol = resolution.decl_symbols.get(method_decl_id) orelse continue;
                if (!isReachable(reachable, module_index, symbol)) continue;
                const result_type = functionReturnType(checked, symbol);
                const name = try mangledMethodName(module, implementation.target_type, function.name);
                const function_id = try mir_builder.newFunction(module, allocator, name, symbol, result_type, function.span);
                module.functions.items[@intFromEnum(function_id)].type_store = &checked.types;
                try symbol_to_function.put(symbol, function_id);
            },
            // Default-методы интерфейса (`тип X = интерфейс \n функ м(это:
            // X(...), ...) -> ... \n <тело> \n конец`) — ОТДЕЛЬНЫЙ вид
            // декларации от `.impl` (зеркалит собственный
            // `predeclareFunctions` из `compiler.zig`: `.impl` и
            // `.interface_decl` обрабатываются как две ветки одного
            // switch, не одна). Получатель `это` здесь — АБСТРАКТНЫЙ тип
            // интерфейса, а не конкретная структура — резервируется ТЕМ ЖЕ
            // способом в любом случае (mangled-имя
            // `"{Интерфейс}::{метод}"`, обычный `newFunction` — различие
            // интерфейс-vs-конкретный тип важно только для соглашения о
            // ВЫЗОВЕ, обрабатываемого отдельно в `wasm_interfaces.zig`).
            .interface_decl => |interface| for (interface.default_methods) |method_decl_id| {
                const function = tree.decl(method_decl_id).function;
                const symbol = resolution.decl_symbols.get(method_decl_id) orelse continue;
                if (!isReachable(reachable, module_index, symbol)) continue;
                const result_type = functionReturnType(checked, symbol);
                const name = try mangledMethodName(module, interface.name, function.name);
                const function_id = try mir_builder.newFunction(module, allocator, name, symbol, result_type, function.span);
                module.functions.items[@intFromEnum(function_id)].type_store = &checked.types;
                try symbol_to_function.put(symbol, function_id);
            },
            else => {},
        }
    }
}

fn lowerMethods(
    module: *mir.Module,
    allocator: std.mem.Allocator,
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    checked: *const type_checker.CheckResult,
    program: anytype,
    symbol_to_function: *const std.AutoHashMap(symbols.SymbolId, mir.FunctionId),
    diagnostic: *AotDiagnostic,
) !void {
    for (program.declarations) |decl_id| {
        switch (tree.decl(decl_id).*) {
            .impl => |implementation| for (implementation.methods) |method_decl_id| {
                const function = tree.decl(method_decl_id).function;
                const symbol = resolution.decl_symbols.get(method_decl_id) orelse continue;
                const function_id = symbol_to_function.get(symbol) orelse continue;
                try lowerFunctionBody(allocator, tree, resolution, checked, module, function_id, method_decl_id, function.body, symbol_to_function, diagnostic);
            },
            .interface_decl => |interface| for (interface.default_methods) |method_decl_id| {
                const function = tree.decl(method_decl_id).function;
                const symbol = resolution.decl_symbols.get(method_decl_id) orelse continue;
                const function_id = symbol_to_function.get(symbol) orelse continue;
                try lowerFunctionBody(allocator, tree, resolution, checked, module, function_id, method_decl_id, function.body, symbol_to_function, diagnostic);
            },
            else => {},
        }
    }
}

// --- Отсечение недостижимого кода (tree-shaking) -----------------------
//
// AOT-путь сборки в `cli/main.zig` безусловно линкует ПОЛНЫЙ prelude в
// граф модулей — каждую декларацию, независимо от того, вызывает ли её
// реальная программа. Без фильтрации по достижимости следующая незнакомая
// возможность prelude блокирует следующую программу тем же способом,
// навсегда. Это должно выполняться ДО lowering (а не как проход
// отсечения мёртвого кода над уже понижённым MIR-модулем) —
// недостижимая декларация, которую не удаётся ПОНИЗИТЬ, прерывает всю
// сборку раньше, чем у любого последующего прохода появился бы шанс её
// отбросить.
//
// `SymbolId` имеет область видимости per-module (свежий `Resolution` на
// файл), поэтому голый `SymbolId` не уникален глобально по всему графу;
// каждый ключ достижимости несёт вместе с символом индекс владеющего им
// модуля.
const ReachKey = struct {
    module_index: usize,
    symbol: symbols.SymbolId,
};
pub const ReachableSet = std.AutoHashMap(ReachKey, void);

// Параметр или тип возврата generic-функции/метода, остающийся ГОЛЫМ,
// необёрнутым `.generic_parameter` (в отличие от `.nominal`/`.function` —
// те безопасны неспециализированными), нуждается в ОДНОМ согласованном
// WASM-представлении на всех местах вызова, достижимых в скомпилированной
// программе. `Category` классифицирует форму WASM-значения конкретной
// инстанциации тем же способом, что и `wasm_module.wasmValTypeForStore`;
// `MixedMap` записывает, для каждого generic-символа, какие категории
// реально встретились — больше одной означает, что единственное
// неспециализированное скомпилированное тело должно было бы трактовать
// ОДИН И ТОТ ЖЕ слот локали/возврата и как i32-хендл, и как f64-число в
// зависимости от вызывающей стороны, что непредставимо без настоящей
// специализации по инстанциации (сознательно не реализовано).
const Category = enum { i32_like, f64_like };
const MixedMap = std.AutoHashMap(ReachKey, std.EnumSet(Category));

fn categoryOf(store: *const types.TypeStore, type_id: types.TypeId) Category {
    return if (wasm_module.wasmValTypeForStore(store, type_id) == wasm_module.wasm_i32) .i32_like else .f64_like;
}

fn isBareGenericParameter(store: *const types.TypeStore, type_id: types.TypeId) bool {
    const entry = store.get(type_id) orelse return false;
    return entry.* == .generic_parameter;
}

// Разрешает собственный тип СИГНАТУРЫ функции/метода `symbol` напрямую из
// `checked.symbol_types` (`.function{parameters, return_type}` —
// generic-сигнатуры панос хранятся как обычные функциональные типы,
// включая статус подстановки T, тот же lookup, что `functionReturnType`
// уже использует для половины с возвратом). Возвращает `null` для всего,
// что не является "рискованной" generic-сигнатурой (нигде нет голого
// `.generic_parameter`) — обычный, безопасный случай, пропускаемый без
// дальнейшей работы.
const RiskySignature = struct { parameters: []const types.TypeId, return_type: types.TypeId };

fn riskyGenericSignature(checked: *const type_checker.CheckResult, symbol: symbols.SymbolId) ?RiskySignature {
    const signature_id = checked.symbol_types.get(symbol) orelse return null;
    const entry = checked.types.get(signature_id) orelse return null;
    const function_type = switch (entry.*) {
        .function => |value| value,
        else => return null,
    };
    var risky = isBareGenericParameter(&checked.types, function_type.return_type);
    if (!risky) for (function_type.parameters) |parameter| {
        if (isBareGenericParameter(&checked.types, parameter)) {
            risky = true;
            break;
        }
    };
    if (!risky) return null;
    return RiskySignature{ .parameters = function_type.parameters, .return_type = function_type.return_type };
}

// Записывает, для ВЫЗОВА "рискованного" generic-символа, в какую
// категорию WASM-представления отображается ФАКТИЧЕСКИЙ конкретный тип
// каждого рискованно типизированного аргумента — вызывается из
// собственного случая `.call` в `walkExpr`, переиспользуя ТУ ЖЕ логику
// перенаправления импорта, что уже применяет `recordReference` (generic-
// функция, вызванная через границу модуля, должна отслеживаться под
// собственным символом ЭКСПОРТИРУЮЩЕГО модуля, а не импортирующим
// псевдонимом).
fn recordGenericInstantiation(
    compiled: anytype,
    resolution: *const resolver.Resolution,
    checked: *const type_checker.CheckResult,
    mixed: *MixedMap,
    module_index: usize,
    callee_symbol: symbols.SymbolId,
    call: anytype,
) !void {
    var target_module_index = module_index;
    var target_symbol = callee_symbol;
    if (resolution.imported_symbols.get(callee_symbol)) |origin| {
        const target_resolution = if (compiled.modules[origin.module].resolution) |*value| value else return;
        target_symbol = target_resolution.decl_symbols.get(origin.declaration) orelse return;
        target_module_index = origin.module;
    }
    const target_checked = if (compiled.modules[target_module_index].checked) |*value| value else return;
    const signature = riskyGenericSignature(target_checked, target_symbol) orelse return;

    const key = ReachKey{ .module_index = target_module_index, .symbol = target_symbol };
    const shared = @min(call.arguments.len, signature.parameters.len);
    for (call.arguments[0..shared], signature.parameters[0..shared]) |argument, parameter_type| {
        if (!isBareGenericParameter(&target_checked.types, parameter_type)) continue;
        const argument_type = checked.expression_types.get(argument) orelse continue;
        const category = categoryOf(&checked.types, argument_type);
        const entry = try mixed.getOrPut(key);
        if (!entry.found_existing) entry.value_ptr.* = .initEmpty();
        entry.value_ptr.insert(category);
    }
}

fn isReachable(reachable: ?*const ReachableSet, module_index: usize, symbol: symbols.SymbolId) bool {
    // `null` — фильтрации нет вовсе (путь `lowerModule` для одного файла,
    // используемый юнит-тестами, у которого нет настоящего графа модулей
    // / точки входа, от которой вычислять достижимость) — компилируется
    // каждая декларация, точно как до появления отсечения недостижимого
    // кода.
    const set = reachable orelse return true;
    return set.contains(.{ .module_index = module_index, .symbol = symbol });
}

fn markReachable(allocator: std.mem.Allocator, set: *ReachableSet, worklist: *std.ArrayList(ReachKey), module_index: usize, symbol: symbols.SymbolId) !void {
    const key = ReachKey{ .module_index = module_index, .symbol = symbol };
    if (set.contains(key)) return;
    try set.put(key, {});
    try worklist.append(allocator, key);
}

// Символ, на который есть ссылка, может быть ЛОКАЛЬНОЙ декларацией в
// собственном модуле `module_index`, либо ПСЕВДОНИМОМ ИМПОРТА —
// `resolution.imported_symbols` (свежеиспечён на каждый импортирующий
// модуль) перенаправляет псевдоним прямо на СОБСТВЕННЫЙ модуль + символ
// экспортирующей декларации — то же самое перенаправление, что уже
// выполняет существующий цикл `lowerGraph` для `function_maps`,
// переиспользуется здесь без изменений.
fn recordReference(
    allocator: std.mem.Allocator,
    compiled: anytype,
    resolution: *const resolver.Resolution,
    set: *ReachableSet,
    worklist: *std.ArrayList(ReachKey),
    module_index: usize,
    symbol: symbols.SymbolId,
) !void {
    if (resolution.imported_symbols.get(symbol)) |origin| {
        const target_resolution = if (compiled.modules[origin.module].resolution) |*value| value else return;
        const target_symbol = target_resolution.decl_symbols.get(origin.declaration) orelse return;
        try markReachable(allocator, set, worklist, origin.module, target_symbol);
        return;
    }
    try markReachable(allocator, set, worklist, module_index, symbol);
}

// Находит тело той декларации (верхнеуровневая функция, метод `.impl`
// или default-метод `.interface_decl`), которой в этом модуле принадлежит
// `symbol` — обычное линейное сканирование (не заранее построенный
// обратный индекс): это выполняется один раз на элемент worklist, не
// горячий путь, и размеры программ здесь достаточно малы, чтобы
// дополнительный учёт кэшируемой обратной карты того не стоил.
fn findSymbolBody(tree: *const ast.Ast, resolution: *const resolver.Resolution, symbol: symbols.SymbolId) ?[]const ast.StmtId {
    const program = tree.program orelse return null;
    for (program.declarations) |decl_id| {
        switch (tree.decl(decl_id).*) {
            .function => |function| {
                if ((resolution.decl_symbols.get(decl_id) orelse continue) == symbol) return function.body;
            },
            .impl => |implementation| for (implementation.methods) |method_decl_id| {
                if ((resolution.decl_symbols.get(method_decl_id) orelse continue) == symbol) return tree.decl(method_decl_id).function.body;
            },
            .interface_decl => |interface| for (interface.default_methods) |method_decl_id| {
                if ((resolution.decl_symbols.get(method_decl_id) orelse continue) == symbol) return tree.decl(method_decl_id).function.body;
            },
            else => {},
        }
    }
    return null;
}

// Каждое приведение к интерфейсу где-либо в достижимом коде подтягивает
// конкретную реализацию, к которой оно разрешается — точно зеркалит
// собственный цикл построения vtable в `applyInterfaceCast` (тот же
// вызов `findInterfaceImplementation`, тот же выбор
// default-vs-переопределённый метод), просто помечая символы
// достижимыми вместо испускания MIR. Проверяется на КАЖДОМ выражении (не
// только на вызовах) — `registerInterfaceCast` (type_checker.zig)
// прикрепляет приведение к let-связываниям/возвратам/параметрам/
// элементам массива-или-карты, не только к аргументам вызова.
fn recordInterfaceCastEdges(
    allocator: std.mem.Allocator,
    compiled: anytype,
    checked: *const type_checker.CheckResult,
    resolution: *const resolver.Resolution,
    set: *ReachableSet,
    worklist: *std.ArrayList(ReachKey),
    module_index: usize,
    expression: ast.ExprId,
) !void {
    const cast = checked.interface_casts.get(expression) orelse return;
    for (cast.entries) |entry| {
        var ambiguous = false;
        const implementation = type_checker.findInterfaceImplementation(checked, entry.interface, entry.arguments, entry.target, entry.target_arguments, &ambiguous) orelse continue;
        for (implementation.methods) |method_symbol| {
            try recordReference(allocator, compiled, resolution, set, worklist, module_index, method_symbol);
        }
    }
}

fn walkExpr(
    allocator: std.mem.Allocator,
    compiled: anytype,
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    checked: *const type_checker.CheckResult,
    set: *ReachableSet,
    worklist: *std.ArrayList(ReachKey),
    mixed: *MixedMap,
    module_index: usize,
    expression: ast.ExprId,
) anyerror!void {
    if (resolution.expr_symbols.get(expression)) |symbol| {
        try recordReference(allocator, compiled, resolution, set, worklist, module_index, symbol);
    }
    if (checked.method_calls.get(expression)) |symbol| {
        try recordReference(allocator, compiled, resolution, set, worklist, module_index, symbol);
    }
    try recordInterfaceCastEdges(allocator, compiled, checked, resolution, set, worklist, module_index, expression);

    switch (tree.expr(expression).*) {
        .number, .boolean, .string, .ident, .error_node => {},
        .unary => |v| try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.operand),
        .cast => |v| try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.operand),
        .binary => |v| {
            try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.left);
            try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.right);
        },
        .call => |v| {
            if (resolution.expr_symbols.get(v.callee)) |callee_symbol| {
                try recordGenericInstantiation(compiled, resolution, checked, mixed, module_index, callee_symbol, v);
            }
            if (checked.method_calls.get(expression)) |method_symbol| {
                try recordGenericInstantiation(compiled, resolution, checked, mixed, module_index, method_symbol, v);
            }
            try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.callee);
            for (v.arguments) |argument| try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, argument);
        },
        .spawn => |v| try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.call),
        .select_wait => |v| try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.source),
        .property => |v| try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.object),
        .if_expr => |v| {
            try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.condition);
            try walkStmts(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.then_branch);
            try walkStmts(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.else_branch);
        },
        .while_expr => |v| {
            try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.condition);
            try walkStmts(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.body);
        },
        .tuple => |v| for (v.elements) |element| try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, element),
        .lambda => |v| try walkStmts(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.body),
        .array => |v| for (v.elements) |element| try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, element),
        .map => |v| for (v.entries) |entry| {
            try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, entry.key);
            try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, entry.value);
        },
        .index => |v| {
            try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.object);
            try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.index);
        },
        .try_expr => |v| try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.value),
        .match_expr => |v| {
            try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.subject);
            for (v.arms) |arm| {
                if (tree.pattern(arm.pattern).* == .literal) try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, tree.pattern(arm.pattern).literal.value);
                try walkStmts(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, arm.body);
            }
        },
    }
}

fn walkStmts(
    allocator: std.mem.Allocator,
    compiled: anytype,
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    checked: *const type_checker.CheckResult,
    set: *ReachableSet,
    worklist: *std.ArrayList(ReachKey),
    mixed: *MixedMap,
    module_index: usize,
    statements: []const ast.StmtId,
) anyerror!void {
    for (statements) |statement| {
        switch (tree.stmt(statement).*) {
            .return_stmt => |v| if (v.value) |value| try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, value),
            .let => |v| try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.value),
            .expr => |v| try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.value),
            .for_in => |v| {
                try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.iterable);
                try walkStmts(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.body);
            },
            .for_range => |v| {
                try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.start);
                try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.end);
                try walkStmts(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.body);
            },
            .continue_stmt, .break_stmt, .error_node => {},
        }
    }
}

// `DOM.после_кадра` по-прежнему принимает ИМЯ функции-обработчика как
// СТРОКОВЫЙ ЛИТЕРАЛ (`instance.exports[name]` в `aot-dom-loader.js` —
// разрешается СТРОКОЙ во время выполнения, невидимо для обычного обхода
// графа вызовов выше). `DOM.на_клик` использует настоящее замыкание и
// потому не нуждается в строковом корне. Сканирует достижимый код на
// оставшийся коллбэк по имени, добавляет подходящую функцию как
// дополнительный корень, затем даёт вызывающей стороне заново
// продренировать worklist до неподвижной точки.
fn addDomHandlerRoots(
    allocator: std.mem.Allocator,
    graph: anytype,
    compiled: anytype,
    set: *ReachableSet,
    worklist: *std.ArrayList(ReachKey),
    handler_names: *std.ArrayList([]const u8),
) !void {
    for (graph.order.items) |module_index| {
        const resolution = if (compiled.modules[module_index].resolution) |*value| value else continue;
        const checked = if (compiled.modules[module_index].checked) |*value| value else continue;
        const tree = &graph.modules.items[module_index].tree;
        const program = tree.program orelse continue;
        try scanDomHandlerRootsInDecls(allocator, graph, compiled, tree, resolution, checked, set, worklist, handler_names, module_index, program.declarations);
    }
}

fn scanDomHandlerRootsInDecls(
    allocator: std.mem.Allocator,
    graph: anytype,
    compiled: anytype,
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    checked: *const type_checker.CheckResult,
    set: *ReachableSet,
    worklist: *std.ArrayList(ReachKey),
    handler_names: *std.ArrayList([]const u8),
    module_index: usize,
    declarations: []const ast.DeclId,
) !void {
    for (declarations) |decl_id| {
        const body: []const ast.StmtId = switch (tree.decl(decl_id).*) {
            .function => |function| function.body,
            .impl => |implementation| blk: {
                for (implementation.methods) |method_decl_id| try scanDomHandlerRootsInDecls(allocator, graph, compiled, tree, resolution, checked, set, worklist, handler_names, module_index, &.{method_decl_id});
                break :blk &.{};
            },
            .interface_decl => |interface| blk: {
                for (interface.default_methods) |method_decl_id| try scanDomHandlerRootsInDecls(allocator, graph, compiled, tree, resolution, checked, set, worklist, handler_names, module_index, &.{method_decl_id});
                break :blk &.{};
            },
            else => &.{},
        };
        const symbol = resolution.decl_symbols.get(decl_id);
        // Сканируем только декларацию, достижимую через основной
        // worklist — весь смысл в поиске строково-литеральных корней
        // внутри кода, УЖЕ известного как выполняемый, а не в
        // воскрешении мёртвого кода через его собственные вызовы
        // регистрации обработчика.
        if (symbol == null or !set.contains(.{ .module_index = module_index, .symbol = symbol.? })) continue;
        try scanDomHandlerRootsInStmts(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, body);
    }
}

fn scanDomHandlerRootsInStmts(
    allocator: std.mem.Allocator,
    graph: anytype,
    compiled: anytype,
    tree: *const ast.Ast,
    set: *ReachableSet,
    worklist: *std.ArrayList(ReachKey),
    handler_names: *std.ArrayList([]const u8),
    module_index: usize,
    statements: []const ast.StmtId,
) !void {
    for (statements) |statement| {
        switch (tree.stmt(statement).*) {
            .return_stmt => |v| if (v.value) |value| try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, value),
            .let => |v| try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.value),
            .expr => |v| try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.value),
            .for_in => |v| try scanDomHandlerRootsInStmts(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.body),
            .for_range => |v| try scanDomHandlerRootsInStmts(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.body),
            .continue_stmt, .break_stmt, .error_node => {},
        }
    }
}

fn scanDomHandlerRootsInExpr(
    allocator: std.mem.Allocator,
    graph: anytype,
    compiled: anytype,
    tree: *const ast.Ast,
    set: *ReachableSet,
    worklist: *std.ArrayList(ReachKey),
    handler_names: *std.ArrayList([]const u8),
    module_index: usize,
    expression: ast.ExprId,
) anyerror!void {
    switch (tree.expr(expression).*) {
        .call => |call| {
            if (tree.expr(call.callee).* == .property) {
                const property = tree.expr(call.callee).property;
                const is_handler_call = std.mem.eql(u8, property.property, "после_кадра");
                if (is_handler_call) {
                    for (call.arguments) |argument| {
                        if (tree.expr(argument).* != .string) continue;
                        const handler_name = tree.expr(argument).string.value;
                        try addRootByName(allocator, graph, compiled, set, worklist, handler_name);
                        try handler_names.append(allocator, handler_name);
                    }
                }
            }
            try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, call.callee);
            for (call.arguments) |argument| try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, argument);
        },
        .unary => |v| try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.operand),
        .cast => |v| try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.operand),
        .binary => |v| {
            try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.left);
            try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.right);
        },
        .spawn => |v| try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.call),
        .select_wait => |v| try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.source),
        .property => |v| try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.object),
        .if_expr => |v| {
            try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.condition);
            try scanDomHandlerRootsInStmts(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.then_branch);
            try scanDomHandlerRootsInStmts(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.else_branch);
        },
        .while_expr => |v| {
            try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.condition);
            try scanDomHandlerRootsInStmts(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.body);
        },
        .tuple => |v| for (v.elements) |element| try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, element),
        .lambda => |v| try scanDomHandlerRootsInStmts(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.body),
        .array => |v| for (v.elements) |element| try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, element),
        .map => |v| for (v.entries) |entry| {
            try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, entry.key);
            try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, entry.value);
        },
        .index => |v| {
            try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.object);
            try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.index);
        },
        .try_expr => |v| try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.value),
        .match_expr => |v| {
            try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.subject);
            for (v.arms) |arm| try scanDomHandlerRootsInStmts(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, arm.body);
        },
        .number, .boolean, .string, .ident, .error_node => {},
    }
}

// Имя DOM-обработчика — всегда обычный верхнеуровневый `функ`, никогда не
// метод — ищет совпадение имени среди верхнеуровневых деклараций функций
// каждого модуля, добавляет ПЕРВОЕ найденное (имена обработчиков
// задуманы как однозначные верхнеуровневые точки входа; настоящая
// коллизия между модулями уже была бы вопросом затенения внутри модуля,
// который резолвер обрабатывает где-то ещё, вне области этой функции).
fn addRootByName(allocator: std.mem.Allocator, graph: anytype, compiled: anytype, set: *ReachableSet, worklist: *std.ArrayList(ReachKey), name: []const u8) !void {
    for (graph.order.items) |module_index| {
        const resolution = if (compiled.modules[module_index].resolution) |*value| value else continue;
        const tree = &graph.modules.items[module_index].tree;
        const program = tree.program orelse continue;
        for (program.declarations) |decl_id| {
            const function = switch (tree.decl(decl_id).*) {
                .function => |value| value,
                else => continue,
            };
            if (!std.mem.eql(u8, function.name, name)) continue;
            const symbol = resolution.decl_symbols.get(decl_id) orelse continue;
            try markReachable(allocator, set, worklist, module_index, symbol);
            return;
        }
    }
}

pub const ReachabilityResult = struct {
    reachable: ReachableSet,
    // Generic-символы с голым типом параметра/возврата `.generic_parameter`,
    // вызванные где-то в достижимом коде И с i32-категорией, И с
    // f64-категорией конкретных аргументов — см. собственный
    // doc-комментарий `MixedMap`. Пусто в подавляющем большинстве
    // случаев; `lowerGraph` сообщает о них явной диагностикой вместо
    // того, чтобы молча некорректно скомпилировать одну из двух
    // инстанциаций.
    conflicts: std.ArrayList(ReachKey),
    // Каждое имя функции, найденное зарегистрированным как обработчик
    // `.после_кадра` во время `addDomHandlerRoots` — зачем это нужно
    // `wasm_gc_arena.zig`, см. собственный doc-комментарий
    // `mir.Module.dom_handler_names`. Заимствованные срезы в память AST
    // (живут, пока живы `graph`/`compiled`) — `lowerGraph` копирует их в
    // собственную арену `mir.Module`, прежде чем этот результат
    // уничтожается.
    dom_handler_names: std.ArrayList([]const u8),

    pub fn deinit(self: *ReachabilityResult, allocator: std.mem.Allocator) void {
        self.reachable.deinit();
        self.conflicts.deinit(allocator);
        self.dom_handler_names.deinit(allocator);
    }
};

// Собственное ИМЯ верхнеуровневой функции/метода символа (для
// диагностического сообщения о смешанной generic-инстанциации) — та же
// форма линейного сканирования, что и `findSymbolBody`, хранится
// отдельно, а не объединена с ней, поскольку большинству вызывающих
// сторон (самому обходу достижимости) нужно только тело.
fn findSymbolName(tree: *const ast.Ast, resolution: *const resolver.Resolution, symbol: symbols.SymbolId) ?[]const u8 {
    const program = tree.program orelse return null;
    for (program.declarations) |decl_id| {
        switch (tree.decl(decl_id).*) {
            .function => |function| {
                if ((resolution.decl_symbols.get(decl_id) orelse continue) == symbol) return function.name;
            },
            .impl => |implementation| for (implementation.methods) |method_decl_id| {
                if ((resolution.decl_symbols.get(method_decl_id) orelse continue) == symbol) return tree.decl(method_decl_id).function.name;
            },
            .interface_decl => |interface| for (interface.default_methods) |method_decl_id| {
                if ((resolution.decl_symbols.get(method_decl_id) orelse continue) == symbol) return tree.decl(method_decl_id).function.name;
            },
            else => {},
        }
    }
    return null;
}

pub fn computeReachableSymbols(allocator: std.mem.Allocator, graph: anytype, compiled: anytype) !ReachabilityResult {
    var set: ReachableSet = .init(allocator);
    errdefer set.deinit();
    var worklist: std.ArrayList(ReachKey) = .empty;
    defer worklist.deinit(allocator);
    var mixed: MixedMap = .init(allocator);
    defer mixed.deinit();

    // Индекс модуля 0 ВСЕГДА является входным модулем — `graph.load(...)`
    // (самый первый вызов, до `appendPreludeModule`/любого импорта)
    // назначает его, и сам `cli/main.zig` полагается именно на это
    // соглашение (`compiled.modules[0]`), а НЕ на
    // `graph.order.items[len - 1]` (тот порядок — топологический по
    // зависимостям, а prelude — добавленный отдельно, без явных рёбер
    // импорта, указывающих НА него — на самом деле оказывается ПЕРВЫМ, а
    // не последним).
    if (graph.modules.items.len == 0) return .{ .reachable = set, .conflicts = .empty, .dom_handler_names = .empty };
    const entry_module_index: usize = 0;
    const entry_resolution = if (compiled.modules[entry_module_index].resolution) |*value| value else return .{ .reachable = set, .conflicts = .empty, .dom_handler_names = .empty };
    const entry_tree = &graph.modules.items[entry_module_index].tree;
    const entry_program = entry_tree.program orelse return .{ .reachable = set, .conflicts = .empty, .dom_handler_names = .empty };
    for (entry_program.declarations) |decl_id| {
        const function = switch (entry_tree.decl(decl_id).*) {
            .function => |value| value,
            else => continue,
        };
        if (!std.mem.eql(u8, function.name, "старт")) continue;
        const symbol = entry_resolution.decl_symbols.get(decl_id) orelse continue;
        try markReachable(allocator, &set, &worklist, entry_module_index, symbol);
        break;
    }

    while (worklist.pop()) |item| {
        const resolution = if (compiled.modules[item.module_index].resolution) |*value| value else continue;
        const checked = if (compiled.modules[item.module_index].checked) |*value| value else continue;
        const tree = &graph.modules.items[item.module_index].tree;
        const body = findSymbolBody(tree, resolution, item.symbol) orelse continue;
        try walkStmts(allocator, compiled, tree, resolution, checked, &set, &worklist, &mixed, item.module_index, body);
    }

    var dom_handler_names: std.ArrayList([]const u8) = .empty;
    errdefer dom_handler_names.deinit(allocator);
    try addDomHandlerRoots(allocator, graph, compiled, &set, &worklist, &dom_handler_names);
    while (worklist.pop()) |item| {
        const resolution = if (compiled.modules[item.module_index].resolution) |*value| value else continue;
        const checked = if (compiled.modules[item.module_index].checked) |*value| value else continue;
        const tree = &graph.modules.items[item.module_index].tree;
        const body = findSymbolBody(tree, resolution, item.symbol) orelse continue;
        try walkStmts(allocator, compiled, tree, resolution, checked, &set, &worklist, &mixed, item.module_index, body);
    }

    var conflicts: std.ArrayList(ReachKey) = .empty;
    errdefer conflicts.deinit(allocator);
    var mixed_iter = mixed.iterator();
    while (mixed_iter.next()) |entry| {
        if (entry.value_ptr.count() > 1) try conflicts.append(allocator, entry.key_ptr.*);
    }

    return .{ .reachable = set, .conflicts = conflicts, .dom_handler_names = dom_handler_names };
}

// Связывает уже разрешённый и типопроверенный граф модулей в один AOT
// MIR-модуль. У bytecode-компилятора есть собственный линкер; здесь
// сознательно сохраняется небольшой AOT-специфичный аналог, чтобы WASM не
// наследовал допущения bytecode VM.
pub fn lowerGraph(
    allocator: std.mem.Allocator,
    graph: anytype,
    compiled: anytype,
) !mir.Module {
    var diagnostic: AotDiagnostic = .{};
    return lowerGraphWithDiagnostic(allocator, graph, compiled, &diagnostic);
}

pub fn lowerGraphWithDiagnostic(
    allocator: std.mem.Allocator,
    graph: anytype,
    compiled: anytype,
    diagnostic: *AotDiagnostic,
) !mir.Module {
    diagnostic.reset();
    var module = mir.Module.init(allocator);
    errdefer module.deinit(allocator);

    // Отсечение недостижимого кода — почему это ДОЛЖНО выполняться до
    // начала любого понижения, а не как проход отсечения мёртвого кода
    // после, см. собственный doc-комментарий `computeReachableSymbols`.
    var reachability = try computeReachableSymbols(allocator, graph, compiled);
    defer reachability.deinit(allocator);
    if (reachability.conflicts.items.len > 0) {
        const first = reachability.conflicts.items[0];
        const tree = &graph.modules.items[first.module_index].tree;
        var subject: ?[]const u8 = null;
        if (compiled.modules[first.module_index].resolution) |*resolution| {
            subject = findSymbolName(tree, resolution, first.symbol) orelse "<аноним>";
        }
        diagnostic.report("generic-функция/метод с несовместимыми инстанциациями T (число и структура/массив в одном скомпилированном теле — не монoморфизировано)", subject);
        return error.AotUnsupported;
    }
    const reachable = &reachability.reachable;

    var function_maps: std.ArrayList(std.AutoHashMap(symbols.SymbolId, mir.FunctionId)) = .empty;
    defer {
        for (function_maps.items) |*map| map.deinit();
        function_maps.deinit(allocator);
    }
    try function_maps.ensureTotalCapacity(allocator, graph.modules.items.len);
    for (0..graph.modules.items.len) |_| try function_maps.append(allocator, .init(allocator));

    // Резервирует каждую локальную функцию до понижения любого тела. Это
    // даёт опережающим ссылкам, рекурсии и прямым межмодульным вызовам
    // стабильные глобальные FunctionId в результирующем WASM-модуле.
    for (graph.order.items) |module_index| {
        const resolution = if (compiled.modules[module_index].resolution) |*value| value else continue;
        const checked = if (compiled.modules[module_index].checked) |*value| value else continue;
        const tree = &graph.modules.items[module_index].tree;
        const program = tree.program orelse continue;
        for (program.declarations) |decl_id| {
            const function = switch (tree.decl(decl_id).*) {
                .function => |value| value,
                else => continue,
            };
            const symbol = resolution.decl_symbols.get(decl_id) orelse continue;
            if (!isReachable(reachable, module_index, symbol)) continue;
            const result_type = functionReturnType(checked, symbol);
            const function_id = try mir_builder.newFunction(&module, allocator, function.name, symbol, result_type, function.span);
            module.functions.items[@intFromEnum(function_id)].type_store = &checked.types;
            try function_maps.items[module_index].put(symbol, function_id);
        }
        try reserveMethods(&module, allocator, tree, resolution, checked, program, &function_maps.items[module_index], reachable, module_index);
    }

    // Импортированные символы свежеиспечены в импортирующем Resolution.
    // Отображаем каждый обратно на зарезервированный FunctionId его
    // экспортирующей декларации.
    for (graph.order.items) |module_index| {
        const resolution = if (compiled.modules[module_index].resolution) |*value| value else continue;
        var imports = resolution.imported_symbols.iterator();
        while (imports.next()) |entry| {
            const origin = entry.value_ptr.*;
            const target_resolution = if (compiled.modules[origin.module].resolution) |*value| value else continue;
            const target_symbol = target_resolution.decl_symbols.get(origin.declaration) orelse continue;
            const target_function = function_maps.items[origin.module].get(target_symbol) orelse continue;
            try function_maps.items[module_index].put(entry.key_ptr.*, target_function);
        }
    }

    for (graph.order.items) |module_index| {
        const resolution = if (compiled.modules[module_index].resolution) |*value| value else continue;
        const checked = if (compiled.modules[module_index].checked) |*value| value else continue;
        const tree = &graph.modules.items[module_index].tree;
        const program = tree.program orelse continue;
        for (program.declarations) |decl_id| {
            const function = switch (tree.decl(decl_id).*) {
                .function => |value| value,
                else => continue,
            };
            const symbol = resolution.decl_symbols.get(decl_id) orelse continue;
            const function_id = function_maps.items[module_index].get(symbol) orelse continue;
            try lowerFunctionBody(allocator, tree, resolution, checked, &module, function_id, decl_id, function.body, &function_maps.items[module_index], diagnostic);
        }
        try lowerMethods(&module, allocator, tree, resolution, checked, program, &function_maps.items[module_index], diagnostic);
    }

    // `reachability.dom_handler_names` хранит заимствованные срезы в
    // память AST (живёт, пока жив `graph`) — копируем в `module.arena`
    // (с дедупликацией — одно и то же имя может быть зарегистрировано
    // более чем с одного места вызова), чтобы `wasm_gc_arena.zig` мог
    // полагаться на их валидность столько же, сколько живёт сам модуль,
    // без необходимости, чтобы `graph`/`compiled` всё ещё существовали.
    var seen_handler_names: std.StringHashMap(void) = .init(allocator);
    defer seen_handler_names.deinit();
    var handler_names_owned: std.ArrayList([]const u8) = .empty;
    const module_arena = module.arena.allocator();
    for (reachability.dom_handler_names.items) |name| {
        if (seen_handler_names.contains(name)) continue;
        try seen_handler_names.put(name, {});
        try handler_names_owned.append(module_arena, try module_arena.dupe(u8, name));
    }
    // У замыканий-кликов нет литерального имени экспорта, но единственный
    // фиксированный трамплин всё равно является точкой входа, вызываемой
    // из JS, и должен получить ту же обёртку checkpoint/restore арены,
    // что и коллбэки по имени.
    if (wasm_heap.findFunctionByName(&module, invoke_click_trampoline_name) != null) {
        try handler_names_owned.append(module_arena, invoke_click_trampoline_name);
    }
    module.dom_handler_names = try handler_names_owned.toOwnedSlice(module_arena);

    return module;
}

fn lowerFunctionBody(
    allocator: std.mem.Allocator,
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    checked: *const type_checker.CheckResult,
    module: *mir.Module,
    function_id: mir.FunctionId,
    decl_id: ast.DeclId,
    body: []const ast.StmtId,
    symbol_to_function: *const std.AutoHashMap(symbols.SymbolId, mir.FunctionId),
    diagnostic: *AotDiagnostic,
) !void {
    var ctx = LoweringContext{
        .allocator = allocator,
        .tree = tree,
        .resolution = resolution,
        .checked = checked,
        .builder = try mir_builder.Builder.beginFunction(module, allocator, function_id),
        .symbol_to_local = .init(allocator),
        .symbol_to_function = symbol_to_function,
        .closure_origins = .init(allocator),
        .diagnostic = diagnostic,
    };
    defer ctx.deinit();

    const parameter_symbols = resolution.function_parameters.get(decl_id) orelse &.{};
    var param_locals: std.ArrayList(mir.LocalId) = .empty;
    for (parameter_symbols) |symbol| {
        const type_id = checked.symbol_types.get(symbol) orelse checked.types.builtins.void;
        const local = try ctx.builder.newLocal(symbol, "", type_id);
        try ctx.symbol_to_local.put(symbol, local);
        try param_locals.append(allocator, local);
    }
    ctx.builder.currentFunction().parameters = try param_locals.toOwnedSlice(allocator);

    const result_type = ctx.builder.currentFunction().result_type;
    const want_value = !checked.types.eql(result_type, checked.types.builtins.void);
    const outcome = try lowerBlock(&ctx, body, want_value);
    if (outcome.flow == .continues) {
        ctx.builder.terminate(.{ .return_value = .{ .value = if (want_value) outcome.value else null } });
    }
}

// Блок как значение (тот же принцип, что и у `compileBlockValue`):
// последний expression-statement в контексте значения отдаёт своё
// значение как результат блока вместо того, чтобы быть отброшенным;
// более ранние операторы существуют только ради побочного эффекта.
// Пустой блок в контексте значения — заглушка 0.0.
fn lowerBlock(ctx: *LoweringContext, statements: []const ast.StmtId, want_value: bool) anyerror!ExprOutcome {
    if (statements.len == 0) {
        if (!want_value) return continuesWith(mir.invalid_value);
        return continuesWith(try emitConstNumber(ctx, 0));
    }
    for (statements, 0..) |statement, index| {
        const is_last = index == statements.len - 1;
        if (is_last and want_value) {
            const expression = switch (ctx.tree.stmt(statement).*) {
                .expr => |expr_stmt| expr_stmt.value,
                else => {
                    const flow = try lowerStmt(ctx, statement);
                    if (flow == .terminates) return terminated;
                    return continuesWith(try emitConstNumber(ctx, 0));
                },
            };
            return lowerExpr(ctx, expression);
        }
        const flow = try lowerStmt(ctx, statement);
        if (flow == .terminates) return terminated;
    }
    // Достижимо только когда `want_value == false` — последний statement в
    // контексте, требующем значение, всегда возвращается изнутри цикла
    // выше (либо через путь извлечённого выражения, либо через ранний
    // возврат для последнего statement, не являющегося выражением).
    return continuesWith(mir.invalid_value);
}

fn emitConstNumber(ctx: *LoweringContext, value: f64) !mir.ValueId {
    const dst = try ctx.builder.newValue(ctx.checked.types.builtins.number);
    try ctx.builder.emit(.{ .const_value = .{ .dst = dst, .value = .{ .number = value } } });
    return dst;
}

fn lowerStmt(ctx: *LoweringContext, statement: ast.StmtId) anyerror!FlowResult {
    switch (ctx.tree.stmt(statement).*) {
        .let => |let| {
            if (let.destructure_type != null) return ctx.unsupported("деструктурирующее объявление");
            const outcome = try lowerExpr(ctx, let.value);
            if (outcome.flow == .terminates) return .terminates;
            const bindings = ctx.resolution.stmt_bindings.get(statement) orelse &.{};
            if (bindings.len != 1) return ctx.unsupported("деструктурирующее объявление");
            const symbol = bindings[0];
            const local_type = ctx.checked.expression_types.get(let.value) orelse ctx.checked.types.builtins.void;
            const local = try ctx.builder.newLocal(symbol, let.name orelse "", local_type);
            try ctx.symbol_to_local.put(symbol, local);
            switch (ctx.tree.expr(let.value).*) {
                .lambda => try ctx.closure_origins.put(symbol, let.value),
                else => {},
            }
            try ctx.builder.emit(.{ .store_local = .{ .local = local, .src = outcome.value } });
            return .continues;
        },
        .return_stmt => |return_statement| {
            const return_value = return_statement.value orelse {
                ctx.builder.terminate(.{ .return_value = .{ .value = null } });
                return .terminates;
            };
            const outcome = try lowerExpr(ctx, return_value);
            if (outcome.flow == .terminates) return .terminates;
            ctx.builder.terminate(.{ .return_value = .{ .value = outcome.value } });
            return .terminates;
        },
        .expr => |expr_statement| {
            // `если` как голый statement: lowerIfExpr при вызове из
            // контекста выражения всегда понижает с want_value=true
            // (нужно для если-как-значения), но здесь (Expr_Stmt —
            // значение ВСЕГДА отбрасывается) это создало бы синтетический
            // слот слияния и попыталось бы сделать Store_Local с
            // недействительным значением в любой ветке без реального
            // значения (например, `если ... тогда сумма = сумма + i
            // конец` — присваивание не производит значения). Поэтому
            // здесь явно понижаем с want_value=false, а не идём через
            // захардкоженный true в lowerExpr.
            if (ctx.tree.expr(expr_statement.value).* == .if_expr) {
                const if_expr = ctx.tree.expr(expr_statement.value).if_expr;
                const outcome = try lowerIfExpr(ctx, expr_statement.value, if_expr, false);
                return outcome.flow;
            }
            const outcome = try lowerExpr(ctx, expr_statement.value);
            return outcome.flow;
        },
        .for_range => |range| return lowerForRange(ctx, statement, range),
        .for_in => |loop| return lowerForIn(ctx, statement, loop),
        .continue_stmt => {
            if (ctx.loops.items.len == 0) return ctx.unsupported("продолжить вне цикла");
            const target = ctx.loops.items[ctx.loops.items.len - 1].continue_target;
            ctx.builder.terminate(.{ .jump = .{ .target = target } });
            return .terminates;
        },
        .break_stmt => {
            if (ctx.loops.items.len == 0) return ctx.unsupported("прервать вне цикла");
            const target = ctx.loops.items[ctx.loops.items.len - 1].break_target;
            ctx.builder.terminate(.{ .jump = .{ .target = target } });
            return .terminates;
        },
        else => return ctx.unsupported("вид statement"),
    }
}

fn lowerForRange(ctx: *LoweringContext, statement: ast.StmtId, range: anytype) anyerror!FlowResult {
    const start = try lowerExpr(ctx, range.start);
    if (start.flow == .terminates) return .terminates;
    const end = try lowerExpr(ctx, range.end);
    if (end.flow == .terminates) return .terminates;
    const bindings = ctx.resolution.stmt_bindings.get(statement) orelse return ctx.unsupported("для без символа переменной");
    if (bindings.len != 1) return ctx.unsupported("для с несколькими переменными");
    const index_type = ctx.checked.expression_types.get(range.start) orelse ctx.checked.types.builtins.number;
    const index_local = try ctx.builder.newLocal(bindings[0], range.name, index_type);
    try ctx.symbol_to_local.put(bindings[0], index_local);
    const end_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$for_end", index_type);
    try ctx.builder.emit(.{ .store_local = .{ .local = end_local, .src = end.value } });
    try ctx.builder.emit(.{ .store_local = .{ .local = index_local, .src = start.value } });
    const header = try ctx.builder.newBlock();
    const body = try ctx.builder.newBlock();
    const step = try ctx.builder.newBlock();
    const exit = try ctx.builder.newBlock();
    ctx.builder.terminate(.{ .jump = .{ .target = header } });
    ctx.builder.setCurrentBlock(header);
    const index_value = try ctx.builder.newValue(index_type);
    const end_value = try ctx.builder.newValue(index_type);
    try ctx.builder.emit(.{ .load_local = .{ .dst = index_value, .local = index_local } });
    try ctx.builder.emit(.{ .load_local = .{ .dst = end_value, .local = end_local } });
    const cond = try emitCompare(ctx, .less_equal, index_value, end_value);
    ctx.builder.terminate(.{ .branch = .{ .cond = cond, .then_block = body, .else_block = exit } });
    ctx.builder.setCurrentBlock(body);
    try ctx.loops.append(ctx.allocator, .{ .continue_target = step, .break_target = exit });
    const body_outcome = try lowerBlock(ctx, range.body, false);
    _ = ctx.loops.pop();
    if (body_outcome.flow == .continues) ctx.builder.terminate(.{ .jump = .{ .target = step } });
    ctx.builder.setCurrentBlock(step);
    const current = try ctx.builder.newValue(index_type);
    try ctx.builder.emit(.{ .load_local = .{ .dst = current, .local = index_local } });
    const one = try emitConstNumber(ctx, 1);
    const next = try ctx.builder.newValue(index_type);
    try ctx.builder.emit(.{ .binary = .{ .dst = next, .op = .add, .lhs = current, .rhs = one } });
    try ctx.builder.emit(.{ .store_local = .{ .local = index_local, .src = next } });
    ctx.builder.terminate(.{ .jump = .{ .target = header } });
    ctx.builder.setCurrentBlock(exit);
    return .continues;
}

// `для x в массив цикл` — поддерживается только итерация вида `.array`
// (см. `type_checker.ForInInfo.kind`, `checked.for_in_infos`); зеркалит
// CFG `lowerForRange` (блоки header/body/step/exit, локаль индекса,
// обратное ребро `.jump`) с дополнительным `get_index` на каждой
// итерации вместо выдачи сырого счётчика, соответствуя нативному
// bytecode-эталону (`compileArrayForIn` в `compiler.zig`). Для for-in
// вида `.iterator` (на основе `следующее()`/`Опция`) в этом файле пока
// нет MIR-опкодов (нет эквивалента инструкции
// `match_enum`/`call_interface`) — остаётся `unsupported`, это отдельная,
// более крупная работа.
fn lowerForIn(ctx: *LoweringContext, statement: ast.StmtId, loop: anytype) anyerror!FlowResult {
    const info = ctx.checked.for_in_infos.get(statement) orelse return ctx.unsupported("для..в без определённой формы цикла");
    if (info.kind != .array) return ctx.unsupported("для..в по итератору (Фаза 2)");

    const bindings = ctx.resolution.stmt_bindings.get(statement) orelse return ctx.unsupported("для..в без символа переменной");
    if (bindings.len != 1) return ctx.unsupported("для..в с несколькими переменными");

    const iterable = try lowerExpr(ctx, loop.iterable);
    if (iterable.flow == .terminates) return .terminates;

    const array_type = ctx.checked.expression_types.get(loop.iterable) orelse return ctx.unsupported("для..в: массив без типа");
    const array_entry = ctx.checked.types.get(array_type) orelse return ctx.unsupported("для..в: массив с неизвестным типом");
    const element_type = switch (array_entry.*) {
        .array => |value| value,
        else => return ctx.unsupported("для..в: не массив"),
    };

    const array_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$for_in_array", array_type);
    try ctx.builder.emit(.{ .store_local = .{ .local = array_local, .src = iterable.value } });
    const index_type = ctx.checked.types.builtins.number;
    const index_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$for_in_index", index_type);
    const zero = try emitConstNumber(ctx, 0);
    try ctx.builder.emit(.{ .store_local = .{ .local = index_local, .src = zero } });
    const element_local = try ctx.builder.newLocal(bindings[0], loop.names[0], element_type);
    try ctx.symbol_to_local.put(bindings[0], element_local);

    const header = try ctx.builder.newBlock();
    const body = try ctx.builder.newBlock();
    const step = try ctx.builder.newBlock();
    const exit = try ctx.builder.newBlock();
    ctx.builder.terminate(.{ .jump = .{ .target = header } });
    ctx.builder.setCurrentBlock(header);
    // Порядок операндов здесь важен для БОЛЬШЕГО, чем читаемость:
    // `wasm_emit.zig` заново материализует каждое MIR-значение в порядке
    // СОЗДАНИЯ при понижении сравнения, не строго по порядку аргументов
    // `lhs`/`rhs`, переданному в `emitCompare` ниже — `index_value`
    // поэтому должен быть создан ДО `length` (зеркалит точный порядок
    // индекс-затем-граница у `lowerForRange`), иначе два операнда
    // окажутся на WASM-стеке переставленными местами, и `.less` молча
    // вычислит `length < index` вместо `index < length`.
    const index_value = try ctx.builder.newValue(index_type);
    try ctx.builder.emit(.{ .load_local = .{ .dst = index_value, .local = index_local } });
    const array_value = try ctx.builder.newValue(array_type);
    try ctx.builder.emit(.{ .load_local = .{ .dst = array_value, .local = array_local } });
    const length = try ctx.builder.newValue(index_type);
    try ctx.builder.emit(.{ .call_builtin = .{ .dst = length, .name = "@runtime::array_length", .args = try valuesInArena(ctx, &.{array_value}) } });
    const cond = try emitCompare(ctx, .less, index_value, length);
    ctx.builder.terminate(.{ .branch = .{ .cond = cond, .then_block = body, .else_block = exit } });
    ctx.builder.setCurrentBlock(body);
    const array_for_index = try ctx.builder.newValue(array_type);
    try ctx.builder.emit(.{ .load_local = .{ .dst = array_for_index, .local = array_local } });
    const index_for_get = try ctx.builder.newValue(index_type);
    try ctx.builder.emit(.{ .load_local = .{ .dst = index_for_get, .local = index_local } });
    const element = try ctx.builder.newValue(element_type);
    try ctx.builder.emit(.{ .get_index = .{ .dst = element, .object = array_for_index, .index = index_for_get } });
    try ctx.builder.emit(.{ .store_local = .{ .local = element_local, .src = element } });
    try ctx.loops.append(ctx.allocator, .{ .continue_target = step, .break_target = exit });
    const body_outcome = try lowerBlock(ctx, loop.body, false);
    _ = ctx.loops.pop();
    if (body_outcome.flow == .continues) ctx.builder.terminate(.{ .jump = .{ .target = step } });
    ctx.builder.setCurrentBlock(step);
    const current = try ctx.builder.newValue(index_type);
    try ctx.builder.emit(.{ .load_local = .{ .dst = current, .local = index_local } });
    const one = try emitConstNumber(ctx, 1);
    const next = try ctx.builder.newValue(index_type);
    try ctx.builder.emit(.{ .binary = .{ .dst = next, .op = .add, .lhs = current, .rhs = one } });
    try ctx.builder.emit(.{ .store_local = .{ .local = index_local, .src = next } });
    ctx.builder.terminate(.{ .jump = .{ .target = header } });
    ctx.builder.setCurrentBlock(exit);
    return .continues;
}

// Оборачивает понижение каждого выражения ТОЙ ЖЕ проверкой "было ли
// значение этого выражения только что приведено к типу интерфейса?", что
// нативный bytecode-компилятор применяет универсально
// (`compileExpression`/`emitInterfaceCast` в `compiler.zig` — вызывается
// после КАЖДОГО выражения, а не только вызовов, поскольку приведение
// может произойти при let-связывании, возврате, элементе массива/карты
// или обычном аргументе функции так же легко, как и при вызове).
// `lowerExprInner` — это настоящая диспетчеризация по виду; эта обёртка —
// единственное место, через которое уже проходит каждый рекурсивный
// вызов `lowerExpr`, поэтому подключение здесь бесплатно достигает всех
// мест приведения.
fn lowerExpr(ctx: *LoweringContext, expression: ast.ExprId) anyerror!ExprOutcome {
    const outcome = try lowerExprInner(ctx, expression);
    if (outcome.flow == .terminates) return outcome;
    return try applyInterfaceCast(ctx, expression, outcome);
}

// Точно зеркалит `emitInterfaceCast` из `compiler.zig` (тот же вызов
// разрешения, те же условия ошибки) — переиспользует
// `type_checker.findInterfaceImplementation` (разрешение
// точное-совпадение-затем-generic-паттерн-запасной-вариант на этапе
// компиляции) вместо повторного вывода логики сопоставления vtable
// здесь. Строит пары `mir.InterfaceMethodBinding{method_name, function}`,
// зипуя СОБСТВЕННЫЙ объявленный порядок методов интерфейса
// (`InterfaceDefinition.methods[i].name`) с символами методов реализации
// (`entry.methods[i]`, ТОТ ЖЕ индекс — `defineInterfaceImplementation`
// гарантирует это соответствие) — `wasm_interfaces.zig` (WASM-специфичное
// расширение `.cast_interface`) — это то, что превращает FunctionId в
// индексы WASM-таблицы; здесь же логика остаётся независимой от цели.
fn applyInterfaceCast(ctx: *LoweringContext, expression: ast.ExprId, outcome: ExprOutcome) anyerror!ExprOutcome {
    const cast = ctx.checked.interface_casts.get(expression) orelse return outcome;
    // `vtable` в `mir.Instruction.cast_interface` — ОДИН плоский список
    // (без вложенности вида `vtable_index`, которую константа
    // `interface_vtables` bytecode-бэкенда поддерживает для нескольких
    // одновременных интерфейсов на одно приведение) — поэтому собственное
    // поле `vtable_index` в `checked.interface_calls` ниже не
    // используется. Значение, приведённое сразу к НЕСКОЛЬКИМ интерфейсам
    // (например, удовлетворяющее двум ограничениям одновременно),
    // потребовало бы переинтерпретации `method_index` для каждой записи,
    // что эта плоская схема представить не может; явно отклоняется вместо
    // того, чтобы молча вызвать не тот метод.
    if (cast.entries.len > 1) return ctx.unsupported("значение приведено сразу к нескольким интерфейсам (Phase 2)");
    var vtable: std.ArrayList(mir.InterfaceMethodBinding) = .empty;
    for (cast.entries) |entry| {
        var ambiguous = false;
        const implementation = type_checker.findInterfaceImplementation(
            ctx.checked,
            entry.interface,
            entry.arguments,
            entry.target,
            entry.target_arguments,
            &ambiguous,
        ) orelse return ctx.unsupported("не удалось найти реализацию интерфейса");
        if (ambiguous) return ctx.unsupported("неоднозначная реализация интерфейса — несколько подходящих 'реализация' блоков");
        const definition = ctx.checked.interface_definitions.get(entry.interface) orelse return ctx.unsupported("интерфейс без определения");
        if (definition.methods.len != implementation.methods.len) return ctx.unsupported("несоответствие количества методов интерфейса");
        for (definition.methods, implementation.methods) |method, method_symbol| {
            const function_id = ctx.symbol_to_function.get(method_symbol) orelse return ctx.unsupported("не удалось найти метод интерфейса");
            const is_default = method.default_symbol != null and method.default_symbol.? == method_symbol;
            try vtable.append(ctx.builder.module.arena.allocator(), .{ .method_name = method.name, .function = function_id, .is_default = is_default });
        }
    }
    // В любом случае одно и то же WASM-представление (непрозрачный
    // i32-хендл) — переиспользуется собственный тип исходного выражения,
    // а не тип интерфейса как таковой (он отдельно на этом этапе не
    // отслеживается).
    const dst = try ctx.builder.newValue(ctx.builder.currentFunction().valueType(outcome.value));
    try ctx.builder.emit(.{ .cast_interface = .{ .dst = dst, .src = outcome.value, .vtable = try vtable.toOwnedSlice(ctx.builder.module.arena.allocator()) } });
    return continuesWith(dst);
}

fn lowerExprInner(ctx: *LoweringContext, expression: ast.ExprId) anyerror!ExprOutcome {
    return switch (ctx.tree.expr(expression).*) {
        .number => |number| continuesWith(try emitConstNumber(ctx, number.value)),
        .boolean => |boolean| blk: {
            const dst = try ctx.builder.newValue(ctx.checked.types.builtins.boolean);
            try ctx.builder.emit(.{ .const_value = .{ .dst = dst, .value = .{ .boolean = boolean.value } } });
            break :blk continuesWith(dst);
        },
        .string => |string| blk: {
            const dst = try ctx.builder.newValue(ctx.checked.types.builtins.string);
            try ctx.builder.emit(.{ .const_value = .{ .dst = dst, .value = .{ .string = string.value } } });
            break :blk continuesWith(dst);
        },
        .array => |array| lowerArrayLiteral(ctx, expression, array),
        .spawn => |spawn| lowerSpawn(ctx, expression, spawn),
        .index => |index| lowerIndex(ctx, expression, index),
        .ident => blk: {
            const symbol = ctx.resolution.expr_symbols.get(expression) orelse return ctx.unsupported("неразрешённый идентификатор");
            break :blk continuesWith(try lowerSymbolValueRef(ctx, symbol, expressionSpan(ctx.tree, expression)));
        },
        .unary => |unary| lowerUnary(ctx, expression, unary),
        .cast => |cast| lowerCast(ctx, expression, cast),
        .binary => |binary| lowerBinary(ctx, expression, binary),
        .call => |call| lowerCall(ctx, expression, call),
        .property => |property| lowerProperty(ctx, expression, property),
        .if_expr => |conditional| lowerIfExpr(ctx, expression, conditional, true),
        .match_expr => |match| lowerMatchExpr(ctx, expression, match),
        .while_expr => |loop| blk: {
            const flow = try lowerWhile(ctx, loop);
            if (flow == .terminates) break :blk terminated;
            break :blk continuesWith(try emitConstNumber(ctx, 0));
        },
        .lambda => |lambda| lowerLambda(ctx, expression, lambda),
        else => return ctx.unsupported("вид выражения"),
    };
}

// Создание актора остаётся явным в MIR. CPS-понижение потребляет это до
// WASM-эмиттера; представление этого обычным вызовом потеряло бы
// дочерний фрейм и сделало бы последующий `получить()` невозможным
// корректно возобновить.
fn lowerSpawn(ctx: *LoweringContext, expression: ast.ExprId, spawn: anytype) anyerror!ExprOutcome {
    const call = switch (ctx.tree.expr(spawn.call).*) {
        .call => |value| value,
        else => return ctx.unsupported("запусти не-вызов"),
    };
    const symbol = ctx.resolution.expr_symbols.get(call.callee) orelse return ctx.unsupported("запусти неразрешённую функцию");
    const function_id = ctx.symbol_to_function.get(symbol) orelse return ctx.unsupported("запусти не-статическую функцию");
    const callee = try emitFunctionRef(ctx, function_id);
    const args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
    const result_type = ctx.checked.expression_types.get(expression) orelse return ctx.unsupported("запусти без типа");
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .spawn = .{ .dst = dst, .callee = callee, .args = args } });
    return continuesWith(dst);
}

fn lowerMatchExpr(ctx: *LoweringContext, expression: ast.ExprId, match: anytype) anyerror!ExprOutcome {
    const subject = try lowerExpr(ctx, match.subject);
    if (subject.flow == .terminates) return terminated;
    const subject_type = ctx.checked.expression_types.get(match.subject) orelse return ctx.unsupported("выбор без типа subject");
    const subject_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$match", subject_type);
    try ctx.builder.emit(.{ .store_local = .{ .local = subject_local, .src = subject.value } });
    const result_type = ctx.checked.expression_types.get(expression) orelse ctx.checked.types.builtins.void;
    const has_result = !ctx.checked.types.eql(result_type, ctx.checked.types.builtins.void);
    const result_local: ?mir.LocalId = if (has_result) try ctx.builder.newLocal(symbols.invalid_symbol, "$match_result", result_type) else null;
    const merge = try ctx.builder.newBlock();

    for (match.arms, 0..) |arm, arm_index| {
        const next = if (arm_index + 1 < match.arms.len) try ctx.builder.newBlock() else mir.invalid_block;
        const variant = ctx.checked.pattern_variants.get(arm.pattern);
        if (variant) |variant_symbol| {
            const definition = ctx.checked.enum_definitions.get((ctx.resolution.symbols.get(variant_symbol) orelse unreachable).owner_type) orelse return ctx.unsupported("вариант без enum definition");
            var tag: u32 = 0;
            for (definition.variants, 0..) |candidate, index| if (candidate.symbol == variant_symbol) {
                tag = @intCast(index);
                break;
            };
            const condition = try ctx.builder.newValue(ctx.checked.types.builtins.boolean);
            const loaded_subject = try ctx.builder.newValue(subject_type);
            try ctx.builder.emit(.{ .load_local = .{ .dst = loaded_subject, .local = subject_local } });
            try ctx.builder.emit(.{ .match_tag = .{ .dst = condition, .subject = loaded_subject, .tag = tag } });
            const body = try ctx.builder.newBlock();
            if (next == mir.invalid_block) {
                const impossible = try ctx.builder.newBlock();
                ctx.builder.terminate(.{ .branch = .{ .cond = condition, .then_block = body, .else_block = impossible } });
                ctx.builder.setCurrentBlock(impossible);
                ctx.builder.terminate(.{ .unreachable_term = .{ .reason = "неисчерпывающий выбор" } });
            } else ctx.builder.terminate(.{ .branch = .{ .cond = condition, .then_block = body, .else_block = next } });
            ctx.builder.setCurrentBlock(body);
            try bindVariantPattern(ctx, arm.pattern, subject_local, subject_type);
        } else {
            try bindCatchAllPattern(ctx, arm.pattern, subject_local, subject_type);
        }
        const outcome = try lowerBlock(ctx, arm.body, has_result);
        if (outcome.flow == .continues) {
            if (result_local) |local| try ctx.builder.emit(.{ .store_local = .{ .local = local, .src = outcome.value } });
            ctx.builder.terminate(.{ .jump = .{ .target = merge } });
        }
        if (next != mir.invalid_block) ctx.builder.setCurrentBlock(next);
    }
    ctx.builder.setCurrentBlock(merge);
    if (!has_result) return continuesWith(mir.invalid_value);
    const result = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .load_local = .{ .dst = result, .local = result_local.? } });
    return continuesWith(result);
}

fn bindCatchAllPattern(ctx: *LoweringContext, pattern: ast.PatternId, subject_local: mir.LocalId, subject_type: types.TypeId) !void {
    const binding = ctx.resolution.pattern_symbols.get(pattern) orelse return;
    const local = try ctx.builder.newLocal(binding, "$pattern", subject_type);
    try ctx.symbol_to_local.put(binding, local);
    const value = try ctx.builder.newValue(subject_type);
    try ctx.builder.emit(.{ .load_local = .{ .dst = value, .local = subject_local } });
    try ctx.builder.emit(.{ .store_local = .{ .local = local, .src = value } });
}

fn bindVariantPattern(ctx: *LoweringContext, pattern: ast.PatternId, subject_local: mir.LocalId, subject_type: types.TypeId) !void {
    const constructor = switch (ctx.tree.pattern(pattern).*) {
        .constructor => |value| value,
        else => return,
    };
    for (constructor.arguments, 0..) |argument, index| {
        const binding = ctx.resolution.pattern_symbols.get(argument) orelse continue;
        const field_type = ctx.checked.pattern_types.get(argument) orelse blk: {
            // У `получить()` сознательно poison в качестве статического
            // типа субъекта. Type checker всё равно разрешил вариант
            // конструктора, поэтому восстанавливаем позиционный тип поля
            // из этого определения enum.
            const variant_symbol = ctx.checked.pattern_variants.get(pattern) orelse return ctx.unsupported("payload pattern без типа");
            const entry = ctx.resolution.symbols.get(variant_symbol) orelse return ctx.unsupported("payload variant без symbol");
            const definition = ctx.checked.enum_definitions.get(entry.owner_type) orelse return ctx.unsupported("payload variant без enum definition");
            for (definition.variants) |variant| {
                if (variant.symbol != variant_symbol) continue;
                if (index >= variant.fields.len) return ctx.unsupported("payload pattern вне variant fields");
                break :blk variant.fields[index];
            }
            return ctx.unsupported("payload variant не найден");
        };
        const local = try ctx.builder.newLocal(binding, "$payload", field_type);
        try ctx.symbol_to_local.put(binding, local);
        const loaded_subject = try ctx.builder.newValue(subject_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = loaded_subject, .local = subject_local } });
        const field = try ctx.builder.newValue(field_type);
        try ctx.builder.emit(.{ .get_variant_field = .{ .dst = field, .subject = loaded_subject, .field_index = @intCast(index) } });
        try ctx.builder.emit(.{ .store_local = .{ .local = local, .src = field } });
    }
}

fn valuesInArena(ctx: *LoweringContext, values: []const mir.ValueId) ![]const mir.ValueId {
    const out = try ctx.builder.module.arena.allocator().alloc(mir.ValueId, values.len);
    @memcpy(out, values);
    return out;
}

fn lowerArrayLiteral(ctx: *LoweringContext, expression: ast.ExprId, array: anytype) anyerror!ExprOutcome {
    const array_type = ctx.checked.expression_types.get(expression) orelse return ctx.unsupported("массив без типа");
    const entry = ctx.checked.types.get(array_type) orelse return ctx.unsupported("массив с неизвестным типом");
    const element_type = switch (entry.*) {
        .array => |value| value,
        else => return ctx.unsupported("литерал не-массива"),
    };
    const array_value = try ctx.builder.newValue(array_type);
    try ctx.builder.emit(.{ .new_array = .{ .dst = array_value, .elements = &.{} } });
    const local = try ctx.builder.newLocal(symbols.invalid_symbol, "$array", array_type);
    try ctx.builder.emit(.{ .store_local = .{ .local = local, .src = array_value } });
    const append_name = if (wasm_module.wasmValTypeForStore(&ctx.checked.types, element_type) == wasm_module.wasm_i32) "@runtime::array_append_i32" else "@runtime::array_append_f64";
    for (array.elements) |element| {
        const receiver = try ctx.builder.newValue(array_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = receiver, .local = local } });
        const value = try lowerExpr(ctx, element);
        if (value.flow == .terminates) return terminated;
        try ctx.builder.emit(.{ .call_builtin = .{ .dst = null, .name = append_name, .args = try valuesInArena(ctx, &.{ receiver, value.value }) } });
    }
    const result = try ctx.builder.newValue(array_type);
    try ctx.builder.emit(.{ .load_local = .{ .dst = result, .local = local } });
    return continuesWith(result);
}

fn lowerIndex(ctx: *LoweringContext, expression: ast.ExprId, index: anytype) anyerror!ExprOutcome {
    const object = try lowerExpr(ctx, index.object);
    if (object.flow == .terminates) return terminated;
    const subscript = try lowerExpr(ctx, index.index);
    if (subscript.flow == .terminates) return terminated;
    const result_type = ctx.checked.expression_types.get(expression) orelse return ctx.unsupported("индексирование без типа результата");
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .get_index = .{ .dst = dst, .object = object.value, .index = subscript.value } });
    return continuesWith(dst);
}

// В `nominal_fields` есть записи только для КОНКРЕТНЫХ (не generic)
// объявлений структур — generic-объявление (`тип X[T] = структура ...`,
// например собственный `МассивИтератор[T]` из prelude, задействуемый
// каждым обычным циклом `для x в массив`) имеет запись только в
// `generic_nominal_fields`, с тем же ключом. Поиск поля здесь нуждается
// только в ИМЕНИ и порядковой ПОЗИЦИИ поля (`field_index`, используется
// `.get_property`/`.set_property` на уровне MIR) — никогда в его типе с
// подставленным типовым параметром (тип результата вместо этого берётся
// из `ctx.checked.expression_types`, уже разрешённого ранее type
// checker'ом) — поэтому собственный неподставленный список `.fields`
// generic-объявления пригоден точно так же, как и у конкретной
// структуры, подстановка на этом этапе не нужна. Зеркалит собственный
// запасной вариант `fieldsForNominal` в `type_checker.zig` (тот ДЕЛАЕТ
// подстановку, поскольку ему нужно типопроверять выражения доступа к
// полю; этому же нужны только позиции).
fn fieldsForNominalSymbol(ctx: *LoweringContext, symbol: symbols.SymbolId) ?[]const type_checker.NominalField {
    if (ctx.checked.nominal_fields.get(symbol)) |fields| return fields;
    if (ctx.checked.generic_nominal_fields.get(symbol)) |generic_nominal| return generic_nominal.fields;
    return null;
}

fn lowerProperty(ctx: *LoweringContext, expression: ast.ExprId, property: anytype) anyerror!ExprOutcome {
    // Члены модуля и варианты enum — это разрешённые символы, и ими
    // занимаются вызывающие стороны. Оставшееся выражение-свойство — это
    // поле структуры.
    if (ctx.resolution.expr_symbols.contains(expression)) return ctx.unsupported("свойство-модуль или вариант перечисления вне вызова");
    const object = try lowerExpr(ctx, property.object);
    if (object.flow == .terminates) return terminated;
    const object_type = ctx.checked.expression_types.get(property.object) orelse return ctx.unsupported("свойство без типа объекта");
    const type_entry = ctx.checked.types.get(object_type) orelse return ctx.unsupported("свойство с неизвестным типом объекта");
    const nominal = switch (type_entry.*) {
        .nominal => |value| value,
        else => return ctx.unsupported("свойство не-структуры"),
    };
    const fields = fieldsForNominalSymbol(ctx, nominal.symbol) orelse return ctx.unsupported("поле generic-структуры");
    for (fields, 0..) |field, index| {
        if (!std.mem.eql(u8, field.name, property.property)) continue;
        const result_type = ctx.checked.expression_types.get(expression) orelse field.typ;
        const dst = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .get_property = .{ .dst = dst, .object = object.value, .field_index = @intCast(index) } });
        return continuesWith(dst);
    }
    return ctx.unsupported("неизвестное поле структуры");
}

fn lowerSymbolValueRef(ctx: *LoweringContext, symbol: symbols.SymbolId, span: source.Span) !mir.ValueId {
    // Захваченный символ, разрешаемый ВНУТРИ тела лямбды — см.
    // собственный doc-комментарий `CaptureEnv`. Проверяется ПЕРЕД
    // `symbol_to_local`: захват и обычная локаль тела лямбды никогда не
    // могут столкнуться (захваты вообще никогда не получают запись в
    // `symbol_to_local` внутреннего `LoweringContext`, см. `lowerLambda`),
    // но проверка первой делает приоритет явным, а не случайным.
    if (ctx.capture_env) |*env| {
        if (env.index_of.get(symbol)) |slot| {
            const type_id = ctx.checked.symbol_types.get(symbol) orelse ctx.checked.types.builtins.void;
            const env_ptr = try ctx.builder.newValue(ctx.checked.types.builtins.boolean);
            try ctx.builder.emit(.{ .load_local = .{ .dst = env_ptr, .local = env.env_local } });
            const dst = try ctx.builder.newValue(type_id);
            try ctx.builder.emit(.{ .frame_load = .{ .dst = dst, .frame = env_ptr, .slot = slot } });
            return dst;
        }
    }
    if (ctx.symbol_to_local.get(symbol)) |local| {
        const dst = try ctx.builder.newValue(ctx.builder.currentFunction().locals.items[@intFromEnum(local)].type_id);
        try ctx.builder.emit(.{ .load_local = .{ .dst = dst, .local = local } });
        return dst;
    }
    if (ctx.symbol_to_function.get(symbol)) |function_id| {
        // Обычная именованная функция, используемая как обычное ЗНАЧЕНИЕ
        // (не вызываемая немедленно — собственный быстрый путь
        // ident-callee в `lowerCall` вообще никогда не доходит до этой
        // функции) — единообразное представление замыкания, ноль
        // захватов, `already_env_aware = false`, поскольку у сигнатуры
        // ИСХОДНОЙ функции нет параметра `env_ptr`, и она должна остаться
        // нетронутой для собственных мест прямого вызова.
        // `wasm_interfaces.zig` синтезирует для этого случая тонкую
        // обёртку с игнорируемым `env_ptr`.
        const dst = try ctx.builder.newValue(ctx.checked.types.builtins.boolean);
        try ctx.builder.emit(.{ .build_closure = .{ .dst = dst, .function = function_id, .captured = &.{}, .already_env_aware = false } });
        return dst;
    }
    _ = span;
    return ctx.unsupported("символ не является локалью или функцией");
}

fn lambdaReturnType(checked: *const type_checker.CheckResult, expression: ast.ExprId) types.TypeId {
    const signature_id = checked.expression_types.get(expression) orelse return checked.types.builtins.void;
    const entry = checked.types.get(signature_id) orelse return checked.types.builtins.void;
    return switch (entry.*) {
        .function => |value| value.return_type,
        else => checked.types.builtins.void,
    };
}

// Настоящее понижение `.lambda`. Захваты БЕРУТСЯ ПО ЗНАЧЕНИЮ в момент
// СОЗДАНИЯ замыкания (точно соответствует семантике
// `.build_closure`/`compileLambda` самой bytecode VM, `compiler.zig`) —
// каждый захваченный символ читается через обычный
// `lowerSymbolValueRef` ВНЕШНЕГО `ctx` (поэтому захват сам может быть
// параметром, локалью или — рекурсивно — другим ВНЕШНИМ захватом) и
// сохраняется в свежую аллокацию окружения; резолвер распространяет
// захват "дедушки" в каждую промежуточную лямбду, поэтому каждое
// окружение остаётся плоским и рантайм-указатель на родителя не нужен.
// ТЕЛО лямбды понижается как настоящая отдельная MIR-функция, чей поиск
// захваченных символов перенаправлен через `CaptureEnv` вместо
// `symbol_to_local`.
fn lowerLambda(ctx: *LoweringContext, expression: ast.ExprId, lambda: anytype) anyerror!ExprOutcome {
    const captures = ctx.resolution.lambda_captures.get(expression) orelse &.{};
    if (captures.len > std.math.maxInt(u16)) return ctx.unsupported("лямбда захватывает слишком много значений");

    const arena = ctx.builder.module.arena.allocator();
    var captured_values: std.ArrayList(mir.ValueId) = .empty;
    for (captures) |capture_symbol| {
        const value = try lowerSymbolValueRef(ctx, capture_symbol, expressionSpan(ctx.tree, expression));
        try captured_values.append(arena, value);
    }
    const captured_slice = try captured_values.toOwnedSlice(arena);

    const lambda_result_type = lambdaReturnType(ctx.checked, expression);
    const lambda_name = try std.fmt.allocPrint(arena, "@lambda_{d}", .{ctx.builder.module.functions.items.len});
    const lambda_function_id = try mir_builder.newFunction(ctx.builder.module, ctx.allocator, lambda_name, dummy_symbol, lambda_result_type, expressionSpan(ctx.tree, expression));
    ctx.builder.module.functions.items[@intFromEnum(lambda_function_id)].type_store = &ctx.checked.types;

    var inner_ctx = LoweringContext{
        .allocator = ctx.allocator,
        .tree = ctx.tree,
        .resolution = ctx.resolution,
        .checked = ctx.checked,
        .builder = try mir_builder.Builder.beginFunction(ctx.builder.module, ctx.allocator, lambda_function_id),
        .symbol_to_local = .init(ctx.allocator),
        .symbol_to_function = ctx.symbol_to_function,
        .closure_origins = .init(ctx.allocator),
        .diagnostic = ctx.diagnostic,
    };
    defer inner_ctx.deinit();

    const parameter_symbols = ctx.resolution.lambda_parameters.get(expression) orelse &.{};
    var param_locals: std.ArrayList(mir.LocalId) = .empty;
    for (parameter_symbols) |symbol| {
        const type_id = ctx.checked.symbol_types.get(symbol) orelse ctx.checked.types.builtins.void;
        const local = try inner_ctx.builder.newLocal(symbol, "", type_id);
        try inner_ctx.symbol_to_local.put(symbol, local);
        try param_locals.append(ctx.allocator, local);
    }
    // `env_ptr` — единообразно ЗАВЕРШАЮЩИЙ параметр, соответствует
    // соглашению "добавлять env_ptr как завершающий аргумент
    // call_indirect" на СТОРОНЕ ВЫЗОВА (разворачивание `.call_value` в
    // `wasm_interfaces.zig`) — одно соглашение о вызове везде, где
    // вызывается значение типа `.function`, без ветвления между формами
    // "замыкание" и "обычная функция" в месте вызова.
    const env_param = try inner_ctx.builder.newLocal(dummy_symbol, "@env", ctx.checked.types.builtins.boolean);
    try param_locals.append(ctx.allocator, env_param);
    inner_ctx.builder.currentFunction().parameters = try param_locals.toOwnedSlice(ctx.allocator);
    inner_ctx.builder.currentFunction().type_store = &ctx.checked.types;

    var index_of: std.AutoHashMap(symbols.SymbolId, u32) = .init(ctx.allocator);
    for (captures, 0..) |capture_symbol, i| try index_of.put(capture_symbol, @intCast(i));
    inner_ctx.capture_env = .{ .env_local = env_param, .index_of = index_of };

    const want_value = !ctx.checked.types.eql(lambda_result_type, ctx.checked.types.builtins.void);
    const outcome = try lowerBlock(&inner_ctx, lambda.body, want_value);
    if (outcome.flow == .continues) {
        inner_ctx.builder.terminate(.{ .return_value = .{ .value = if (want_value) outcome.value else null } });
    }

    const dst = try ctx.builder.newValue(ctx.checked.expression_types.get(expression) orelse ctx.checked.types.builtins.boolean);
    try ctx.builder.emit(.{ .build_closure = .{ .dst = dst, .function = lambda_function_id, .captured = captured_slice, .already_env_aware = true } });
    return continuesWith(dst);
}

fn emitFunctionRef(ctx: *LoweringContext, function_id: mir.FunctionId) !mir.ValueId {
    // Ссылка на функцию — настоящее полноправное ЗНАЧЕНИЕ (может
    // храниться в локали/поле, передаваться как аргумент, вызываться
    // через `call_value`) — здесь типизировано как `boolean` исключительно
    // как заменитель для "непрозрачного i32-хендла" (см. случай
    // `.function` в `wasm_module.wasmValTypeForStore`: любое значение
    // функционального типа отображается в i32, та же категория, что и
    // nominal/array/process). Точный объявленный тип не важен, кроме как
    // для выбора этой WASM-категории типа.
    const dst = try ctx.builder.newValue(ctx.checked.types.builtins.boolean);
    try ctx.builder.emit(.{ .function_ref = .{ .dst = dst, .function = function_id } });
    return dst;
}

// Callee у `.call_value` должен быть ПОСЛЕДНИМ произведённым операндом к
// моменту, когда WASM-кодогенерация превращает его в `call_indirect`
// (`[args..., table_index]`, индекс снимается верхним) — но каждое место
// вызова здесь вычисляет callee ДО его аргументов (соответствует
// собственному порядку вычисления языка слева направо, callee перед
// аргументами, зеркалит `compileCall` из `compiler.zig`). Пропускает
// callee через обычную Local (MIR не зависит от цели, WASM-специфичное
// знание здесь не нужно), чтобы его можно было заново произвести,
// свежим, после каждого аргумента, прямо на месте вызова.
fn storeCalleeLocal(ctx: *LoweringContext, callee: mir.ValueId) !mir.LocalId {
    const callee_type = ctx.builder.currentFunction().valueType(callee);
    const local = try ctx.builder.newLocal(dummy_symbol, "@callee", callee_type);
    try ctx.builder.emit(.{ .store_local = .{ .local = local, .src = callee } });
    return local;
}

fn reloadCalleeLocal(ctx: *LoweringContext, local: mir.LocalId) !mir.ValueId {
    const callee_type = ctx.builder.currentFunction().locals.items[@intFromEnum(local)].type_id;
    const dst = try ctx.builder.newValue(callee_type);
    try ctx.builder.emit(.{ .load_local = .{ .dst = dst, .local = local } });
    return dst;
}

fn lowerUnary(ctx: *LoweringContext, expression: ast.ExprId, unary: anytype) anyerror!ExprOutcome {
    const src = try lowerExpr(ctx, unary.operand);
    if (src.flow == .terminates) return terminated;
    const op: mir.UnOp = switch (unary.operator) {
        .minus => .negate_number,
        .negate => .negate_bool,
        .tilde => .bit_not,
        else => return ctx.unsupported("унарный оператор"),
    };
    const result_type = ctx.checked.expression_types.get(expression) orelse ctx.checked.types.builtins.void;
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .unary = .{ .dst = dst, .op = op, .src = src.value } });
    return continuesWith(dst);
}

fn lowerBinary(ctx: *LoweringContext, expression: ast.ExprId, binary: anytype) anyerror!ExprOutcome {
    if (binary.operator == .assign) return lowerAssign(ctx, binary);
    if (binary.operator == .and_expr or binary.operator == .or_expr) return lowerShortCircuit(ctx, binary);

    const lhs = try lowerExpr(ctx, binary.left);
    if (lhs.flow == .terminates) return terminated;
    const rhs = try lowerExpr(ctx, binary.right);
    if (rhs.flow == .terminates) return terminated;

    const result_type = ctx.checked.expression_types.get(expression) orelse ctx.checked.types.builtins.void;
    const bin_op: mir.BinOp = switch (binary.operator) {
        .plus => .add,
        .minus => .subtract,
        .star => .multiply,
        .slash => if (ctx.checked.types.eql(ctx.checked.expression_types.get(binary.left) orelse ctx.checked.types.builtins.void, ctx.checked.types.builtins.integer)) mir.BinOp.int_divide else mir.BinOp.divide,
        .percent => .modulo,
        .ampersand => .bit_and,
        .pipe => .bit_or,
        .caret => .bit_xor,
        .less_less => .shift_left,
        .greater_greater => .shift_right,
        .less, .less_equal, .greater, .greater_equal, .equal, .not_equal => return continuesWith(try emitCompare(ctx, binary.operator, lhs.value, rhs.value)),
        else => return ctx.unsupported("бинарный оператор"),
    };
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .binary = .{ .dst = dst, .op = bin_op, .lhs = lhs.value, .rhs = rhs.value } });
    return continuesWith(dst);
}

// Присваивание НЕ производит значения (то же ограничение `y = (x = 1)`,
// что и у bytecode-компилятора) — корректно типизированная программа
// никогда не может это заметить, поскольку type checker требует, чтобы
// ветви if-выражения делили общий тип значения ещё до того, как это
// понижение вообще запускается.
fn lowerAssign(ctx: *LoweringContext, binary: anytype) anyerror!ExprOutcome {
    switch (ctx.tree.expr(binary.left).*) {
        .ident => {
            const symbol = ctx.resolution.expr_symbols.get(binary.left) orelse return ctx.unsupported("неразрешённый идентификатор в присваивании");
            const target = ctx.symbol_to_local.get(symbol) orelse return ctx.unsupported("присваивание не-локали (Фаза 3+)");
            const rhs = try lowerExpr(ctx, binary.right);
            if (rhs.flow == .terminates) return terminated;
            _ = ctx.closure_origins.remove(symbol);
            try ctx.builder.emit(.{ .store_local = .{ .local = target, .src = rhs.value } });
        },
        .property => |property| {
            const object = try lowerExpr(ctx, property.object);
            if (object.flow == .terminates) return terminated;
            const object_type = ctx.checked.expression_types.get(property.object) orelse return ctx.unsupported("присваивание свойства без типа");
            const entry = ctx.checked.types.get(object_type) orelse return ctx.unsupported("присваивание свойства с неизвестным типом");
            const nominal = switch (entry.*) {
                .nominal => |value| value,
                else => return ctx.unsupported("присваивание свойства не-структуры"),
            };
            const fields = fieldsForNominalSymbol(ctx, nominal.symbol) orelse return ctx.unsupported("присваивание поля generic-структуры");
            var field_index: ?u32 = null;
            for (fields, 0..) |field, index| {
                if (std.mem.eql(u8, field.name, property.property)) {
                    field_index = @intCast(index);
                    break;
                }
            }
            const index = field_index orelse return ctx.unsupported("присваивание неизвестному полю структуры");
            const rhs = try lowerExpr(ctx, binary.right);
            if (rhs.flow == .terminates) return terminated;
            try ctx.builder.emit(.{ .set_property = .{ .object = object.value, .field_index = index, .value = rhs.value } });
        },
        .index => |index| {
            const object = try lowerExpr(ctx, index.object);
            if (object.flow == .terminates) return terminated;
            const subscript = try lowerExpr(ctx, index.index);
            if (subscript.flow == .terminates) return terminated;
            const rhs = try lowerExpr(ctx, binary.right);
            if (rhs.flow == .terminates) return terminated;
            try ctx.builder.emit(.{ .set_index = .{ .object = object.value, .index = subscript.value, .value = rhs.value } });
        },
        else => return ctx.unsupported("цель присваивания (Фаза 3+)"),
    }
    return continuesWith(mir.invalid_value);
}

fn emitCompare(ctx: *LoweringContext, operator: anytype, lhs: mir.ValueId, rhs: mir.ValueId) !mir.ValueId {
    const cmp_op: mir.CmpOp = switch (operator) {
        .less => .less,
        .less_equal => .less_equal,
        .greater => .greater,
        .greater_equal => .greater_equal,
        .equal => .equal,
        .not_equal => .not_equal,
        else => unreachable,
    };
    const dst = try ctx.builder.newValue(ctx.checked.types.builtins.boolean);
    try ctx.builder.emit(.{ .compare = .{ .dst = dst, .op = cmp_op, .lhs = lhs, .rhs = rhs } });
    return dst;
}

// `и`/`или` — тот же не-SSA приём "слияние через временную локаль", что
// `lowerIfExpr` использует для результата ветки, через `lowerCondition`,
// строящий настоящие рёбра CFG вместо жадного вычисления bool.
fn lowerShortCircuit(ctx: *LoweringContext, binary: anytype) anyerror!ExprOutcome {
    const result_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$logic", ctx.checked.types.builtins.boolean);
    const rhs_block = try ctx.builder.newBlock();
    const short_block = try ctx.builder.newBlock();
    const merge_block = try ctx.builder.newBlock();
    const short_value = binary.operator == .or_expr;

    if (binary.operator == .and_expr) {
        try lowerCondition(ctx, binary.left, rhs_block, short_block);
    } else {
        try lowerCondition(ctx, binary.left, short_block, rhs_block);
    }

    ctx.builder.setCurrentBlock(short_block);
    const short_dst = try ctx.builder.newValue(ctx.checked.types.builtins.boolean);
    try ctx.builder.emit(.{ .const_value = .{ .dst = short_dst, .value = .{ .boolean = short_value } } });
    try ctx.builder.emit(.{ .store_local = .{ .local = result_local, .src = short_dst } });
    ctx.builder.terminate(.{ .jump = .{ .target = merge_block } });

    ctx.builder.setCurrentBlock(rhs_block);
    const rhs_outcome = try lowerExpr(ctx, binary.right);
    if (rhs_outcome.flow == .continues) {
        try ctx.builder.emit(.{ .store_local = .{ .local = result_local, .src = rhs_outcome.value } });
        ctx.builder.terminate(.{ .jump = .{ .target = merge_block } });
    }

    ctx.builder.setCurrentBlock(merge_block);
    const result = try ctx.builder.newValue(ctx.checked.types.builtins.boolean);
    try ctx.builder.emit(.{ .load_local = .{ .dst = result, .local = result_local } });
    return continuesWith(result);
}

// Понижение в контексте ветвления — строит рёбра CFG напрямую вместо
// вычисления bool-значения, нужно для короткого замыкания `и`/`или`
// (выше) и для условий `если`/`пока`. `a и b` понижается как:
// lowerCondition(a, rhs_block, false_target), внутри rhs_block —
// lowerCondition(b, true_target, false_target); `a или b` симметрично.
fn lowerCondition(ctx: *LoweringContext, expression: ast.ExprId, true_target: mir.BlockId, false_target: mir.BlockId) anyerror!void {
    if (ctx.tree.expr(expression).* == .binary) {
        const binary = ctx.tree.expr(expression).binary;
        if (binary.operator == .and_expr) {
            const rhs_block = try ctx.builder.newBlock();
            try lowerCondition(ctx, binary.left, rhs_block, false_target);
            ctx.builder.setCurrentBlock(rhs_block);
            try lowerCondition(ctx, binary.right, true_target, false_target);
            return;
        }
        if (binary.operator == .or_expr) {
            const rhs_block = try ctx.builder.newBlock();
            try lowerCondition(ctx, binary.left, true_target, rhs_block);
            ctx.builder.setCurrentBlock(rhs_block);
            try lowerCondition(ctx, binary.right, true_target, false_target);
            return;
        }
    }
    const outcome = try lowerExpr(ctx, expression);
    if (outcome.flow == .terminates) return;
    ctx.builder.terminate(.{ .branch = .{ .cond = outcome.value, .then_block = true_target, .else_block = false_target } });
}

// Не-SSA слияние через "временный слот" (Store_Local в каждой ЖИВОЙ —
// незавершающейся — ветке, Load_Local в блоке слияния), а не phi-узел —
// MIR сознательно не SSA.
fn lowerIfExpr(ctx: *LoweringContext, expression: ast.ExprId, conditional: anytype, want_value: bool) anyerror!ExprOutcome {
    const cond = try lowerExpr(ctx, conditional.condition);
    if (cond.flow == .terminates) return terminated;

    const then_block = try ctx.builder.newBlock();
    const else_block = try ctx.builder.newBlock();
    const merge_block = try ctx.builder.newBlock();
    ctx.builder.terminate(.{ .branch = .{ .cond = cond.value, .then_block = then_block, .else_block = else_block } });

    const result_type = ctx.checked.expression_types.get(expression) orelse ctx.checked.types.builtins.void;
    var result_local: mir.LocalId = undefined;
    if (want_value) result_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$if", result_type);

    ctx.builder.setCurrentBlock(then_block);
    const then_outcome = try lowerBlock(ctx, conditional.then_branch, want_value);
    const then_continues = then_outcome.flow == .continues;
    if (then_continues) {
        if (want_value) try ctx.builder.emit(.{ .store_local = .{ .local = result_local, .src = then_outcome.value } });
        ctx.builder.terminate(.{ .jump = .{ .target = merge_block } });
    }

    ctx.builder.setCurrentBlock(else_block);
    const else_outcome = try lowerBlock(ctx, conditional.else_branch, want_value);
    const else_continues = else_outcome.flow == .continues;
    if (else_continues) {
        if (want_value) try ctx.builder.emit(.{ .store_local = .{ .local = result_local, .src = else_outcome.value } });
        ctx.builder.terminate(.{ .jump = .{ .target = merge_block } });
    }

    if (!then_continues and !else_continues) {
        ctx.builder.setCurrentBlock(merge_block);
        ctx.builder.terminate(.{ .unreachable_term = .{ .reason = "обе ветки если завершают выполнение (возврат/прервать/продолжить)" } });
        return terminated;
    }

    ctx.builder.setCurrentBlock(merge_block);
    if (want_value) {
        const result = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = result, .local = result_local } });
        return continuesWith(result);
    }
    return continuesWith(mir.invalid_value);
}

// Всегда понижается только как statement — нет сценария, которому нужен
// `пока` как значение; единственный вызывающий в `lowerExpr` выше просто
// подставляет константную заглушку 0, та же трактовка, что и у пустого
// блока в контексте значения.
fn lowerWhile(ctx: *LoweringContext, loop: anytype) anyerror!FlowResult {
    const header_block = try ctx.builder.newBlock();
    const body_block = try ctx.builder.newBlock();
    const exit_block = try ctx.builder.newBlock();

    ctx.builder.terminate(.{ .jump = .{ .target = header_block } });
    ctx.builder.setCurrentBlock(header_block);
    const cond = try lowerExpr(ctx, loop.condition);
    if (cond.flow == .terminates) return .terminates;
    ctx.builder.terminate(.{ .branch = .{ .cond = cond.value, .then_block = body_block, .else_block = exit_block } });

    ctx.builder.setCurrentBlock(body_block);
    try ctx.loops.append(ctx.allocator, .{ .continue_target = header_block, .break_target = exit_block });
    const body_outcome = try lowerBlock(ctx, loop.body, false);
    _ = ctx.loops.pop();
    if (body_outcome.flow == .continues) {
        ctx.builder.terminate(.{ .jump = .{ .target = header_block } });
    }

    ctx.builder.setCurrentBlock(exit_block);
    return .continues;
}

// Заметка об области покрытия: понижаются только две формы —
// статически известная верхнеуровневая функция, вызванная по голому
// идентификатору (быстрый путь), и полностью общий запасной вариант
// (callee понижается как ОБЫЧНОЕ выражение, вызывается через
// `Call_Value_Instr` — покрывает значение замыкания/функции высшего
// порядка, разрешается бэкендом, не понижением).
fn lowerCall(ctx: *LoweringContext, expression: ast.ExprId, call: anytype) anyerror!ExprOutcome {
    const result_type = ctx.checked.expression_types.get(expression) orelse ctx.checked.types.builtins.void;

    if (ctx.tree.expr(call.callee).* == .ident) {
        const callee_symbol = ctx.resolution.expr_symbols.get(call.callee) orelse null;
        if (callee_symbol) |symbol| {
            if (ctx.symbol_to_function.get(symbol)) |function_id| {
                const function_ref = try emitFunctionRef(ctx, function_id);
                const args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
                return emitCallValue(ctx, function_ref, args, result_type);
            }
            if (try lowerEnumConstructor(ctx, symbol, call, result_type)) |outcome| return outcome;
            if (try lowerStructConstructor(ctx, expression, symbol, call, result_type)) |outcome| return outcome;
            if (try lowerLengthBuiltinCall(ctx, symbol, call, result_type)) |outcome| return outcome;
            if (try lowerPanicBuiltinCall(ctx, symbol, call)) |outcome| return outcome;
            if (try lowerProcessBuiltinCall(ctx, symbol, call, result_type)) |outcome| return outcome;
        }
    }

    if (ctx.tree.expr(call.callee).* == .property) {
        // `значение.метод(...)`, где статический тип `значение` — это
        // ИНТЕРФЕЙС (не конкретная структура — это `checked.method_calls`
        // ниже, разрешаемый в фиксированный `Symbol_Id`).
        // `checked.interface_calls` даёт `method_index` (СОБСТВЕННЫЙ
        // объявленный порядок методов интерфейса — соответствует
        // построению `vtable` в `applyInterfaceCast`, тот же порядок, тот
        // же источник: `InterfaceDefinition.methods`) — конкретная
        // функция известна только во ВРЕМЯ ВЫПОЛНЕНИЯ (читается из того,
        // какое приведение произвело именно это значение-приёмник),
        // отсюда `.invoke_interface`, а не обычный `.call`/`.call_value`.
        // `wasm_interfaces.zig` (WASM-специфичное расширение) превращает
        // это в цепочку распаковки бокса + `call_indirect`.
        if (ctx.checked.interface_calls.get(expression)) |interface_call| {
            const property = ctx.tree.expr(call.callee).property;
            const receiver = try lowerExpr(ctx, property.object);
            if (receiver.flow == .terminates) return terminated;
            const args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
            const dst = if (ctx.checked.types.eql(result_type, ctx.checked.types.builtins.void)) null else try ctx.builder.newValue(result_type);
            try ctx.builder.emit(.{ .invoke_interface = .{ .dst = dst, .receiver = receiver.value, .method_name = "", .method_index = interface_call.method_index, .args = args } });
            return .{ .value = dst orelse mir.invalid_value, .flow = .continues };
        }
        // `значение.метод(...)`, где статический тип `значение` —
        // конкретная структура — type checker уже разрешил это в
        // собственный `Symbol_Id` метода в `method_calls`, ту же самую
        // карту, что читает нативный bytecode-компилятор (случай
        // `Method_Struct` в `compiler.zig`), вместо повторного вывода
        // поиска поля структуры здесь. `это` — это просто
        // `parameters[0]` на стороне самого метода (см.
        // `reserveMethods`/`lowerMethods`) — приёмник (`property.object`)
        // понижается как обычный аргумент и ставится ПЕРВЫМ, соответствуя
        // этому.
        if (ctx.checked.method_calls.get(expression)) |method_symbol| {
            if (ctx.symbol_to_function.get(method_symbol)) |function_id| {
                const function_ref = try emitFunctionRef(ctx, function_id);
                const property = ctx.tree.expr(call.callee).property;
                const receiver = try lowerExpr(ctx, property.object);
                if (receiver.flow == .terminates) return terminated;
                const rest = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
                const arena = ctx.builder.module.arena.allocator();
                var args: std.ArrayList(mir.ValueId) = .empty;
                try args.append(arena, receiver.value);
                try args.appendSlice(arena, rest);
                return emitCallValue(ctx, function_ref, try args.toOwnedSlice(arena), result_type);
            }
        }
        // Функция, импортированная из локального файла, представлена в
        // AST как `модуль.функция`, а не как голый идентификатор.
        // Resolution уже связал это выражение-свойство с символом на
        // стороне импортёра; lowerGraph перепривязывает этот символ к
        // глобальному MIR FunctionId экспортёра.
        if (ctx.resolution.expr_symbols.get(call.callee)) |symbol| {
            if (ctx.symbol_to_function.get(symbol)) |function_id| {
                const function_ref = try emitFunctionRef(ctx, function_id);
                const args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
                return emitCallValue(ctx, function_ref, args, result_type);
            }
            if (try lowerEnumConstructor(ctx, symbol, call, result_type)) |outcome| return outcome;
        }
        if (try lowerTimeBuiltinCall(ctx, call, result_type)) |outcome| return outcome;
        if (try lowerNetworkBuiltinCall(ctx, call, result_type)) |outcome| return outcome;
        if (try lowerStringBuiltinCall(ctx, call, result_type)) |outcome| return outcome;
        if (try lowerDomBuiltinCall(ctx, call, result_type)) |outcome| return outcome;
        if (try lowerStateBuiltinCall(ctx, call, result_type)) |outcome| return outcome;
        if (try lowerArrayMethodCall(ctx, call, result_type)) |outcome| return outcome;
        if (try lowerOptionMethodCall(ctx, call, result_type)) |outcome| return outcome;
        if (try lowerResultMethodCall(ctx, call, result_type)) |outcome| return outcome;
    }

    const callee_outcome = try lowerExpr(ctx, call.callee);
    if (callee_outcome.flow == .terminates) return terminated;
    const callee_local = try storeCalleeLocal(ctx, callee_outcome.value);
    const args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
    const callee = try reloadCalleeLocal(ctx, callee_local);
    return emitCallValue(ctx, callee, args, result_type);
}

fn lowerEnumConstructor(ctx: *LoweringContext, symbol: symbols.SymbolId, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const entry = ctx.resolution.symbols.get(symbol) orelse return null;
    if (entry.kind != .enum_variant) return null;
    const definition = ctx.checked.enum_definitions.get(entry.owner_type) orelse return null;
    var tag: ?u32 = null;
    for (definition.variants, 0..) |variant, index| {
        if (variant.symbol == symbol) {
            tag = @intCast(index);
            break;
        }
    }
    const variant_tag = tag orelse return null;
    if (call.arguments.len > 3) return ctx.unsupported("вариант с более чем 3 полями");
    const fields = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .build_variant = .{ .dst = dst, .type_name = "", .variant_name = entry.name, .tag = variant_tag, .fields = fields } });
    return continuesWith(dst);
}

fn lowerArrayMethodCall(ctx: *LoweringContext, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const property = ctx.tree.expr(call.callee).property;
    const object_type = ctx.checked.expression_types.get(property.object) orelse return null;
    const entry = ctx.checked.types.get(object_type) orelse return null;
    const element_type = switch (entry.*) {
        .array => |value| value,
        else => return null,
    };
    const is_i32 = wasm_module.wasmValTypeForStore(&ctx.checked.types, element_type) == wasm_module.wasm_i32;
    const name = if (std.mem.eql(u8, property.property, "длина") and call.arguments.len == 0)
        "@runtime::array_length"
    else if (std.mem.eql(u8, property.property, "добавить") and call.arguments.len == 1)
        if (is_i32) "@runtime::array_append_i32" else "@runtime::array_append_f64"
    else if (std.mem.eql(u8, property.property, "получить") and call.arguments.len == 2)
        if (is_i32) "@runtime::array_get_or_i32" else "@runtime::array_get_or_f64"
    else
        return null;

    const receiver = try lowerExpr(ctx, property.object);
    if (receiver.flow == .terminates) return terminated;
    var values: std.ArrayList(mir.ValueId) = .empty;
    defer values.deinit(ctx.allocator);
    try values.append(ctx.allocator, receiver.value);
    for (call.arguments) |argument| {
        const value = try lowerExpr(ctx, argument);
        if (value.flow == .terminates) return terminated;
        try values.append(ctx.allocator, value.value);
    }
    const is_void = ctx.checked.types.eql(result_type, ctx.checked.types.builtins.void);
    const dst = if (is_void) null else try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .call_builtin = .{ .dst = dst, .name = name, .args = try valuesInArena(ctx, values.items) } });
    return continuesWith(dst orelse mir.invalid_value);
}

// `Опция` — двухтеговый ADT из prelude (`Нет = 0`, `Есть = 1`). Эти два
// метода-обёртки переиспользуют тот же ABI варианта, что и явный `выбор`.
fn lowerOptionMethodCall(ctx: *LoweringContext, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const property = ctx.tree.expr(call.callee).property;
    const object_type = ctx.checked.expression_types.get(property.object) orelse return null;
    const type_entry = ctx.checked.types.get(object_type) orelse return null;
    const nominal = switch (type_entry.*) {
        .nominal => |value| value,
        else => return null,
    };
    const owner = ctx.resolution.symbols.get(nominal.symbol) orelse return null;
    if (!std.mem.eql(u8, owner.name, "Опция")) return null;

    const receiver = try lowerExpr(ctx, property.object);
    if (receiver.flow == .terminates) return terminated;
    if (std.mem.eql(u8, property.property, "есть") and call.arguments.len == 0) {
        const dst = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .match_tag = .{ .dst = dst, .subject = receiver.value, .tag = 1 } });
        return continuesWith(dst);
    }
    if (std.mem.eql(u8, property.property, "получить") and call.arguments.len == 1) {
        // И приёмник, и запасное значение вычисляются до выбора
        // результата, точно как при обычном вызове метода панос.
        const option_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$option", object_type);
        try ctx.builder.emit(.{ .store_local = .{ .local = option_local, .src = receiver.value } });
        const fallback = try lowerExpr(ctx, call.arguments[0]);
        if (fallback.flow == .terminates) return terminated;
        const fallback_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$option_fallback", result_type);
        try ctx.builder.emit(.{ .store_local = .{ .local = fallback_local, .src = fallback.value } });
        const result_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$option_result", result_type);
        const condition = try ctx.builder.newValue(ctx.checked.types.builtins.boolean);
        const loaded_option = try ctx.builder.newValue(object_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = loaded_option, .local = option_local } });
        try ctx.builder.emit(.{ .match_tag = .{ .dst = condition, .subject = loaded_option, .tag = 1 } });
        const has_value = try ctx.builder.newBlock();
        const no_value = try ctx.builder.newBlock();
        const merge = try ctx.builder.newBlock();
        ctx.builder.terminate(.{ .branch = .{ .cond = condition, .then_block = has_value, .else_block = no_value } });

        ctx.builder.setCurrentBlock(has_value);
        const value_option = try ctx.builder.newValue(object_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = value_option, .local = option_local } });
        const value = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .get_variant_field = .{ .dst = value, .subject = value_option, .field_index = 0 } });
        try ctx.builder.emit(.{ .store_local = .{ .local = result_local, .src = value } });
        ctx.builder.terminate(.{ .jump = .{ .target = merge } });

        ctx.builder.setCurrentBlock(no_value);
        const default_value = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = default_value, .local = fallback_local } });
        try ctx.builder.emit(.{ .store_local = .{ .local = result_local, .src = default_value } });
        ctx.builder.terminate(.{ .jump = .{ .target = merge } });

        ctx.builder.setCurrentBlock(merge);
        const result = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = result, .local = result_local } });
        return continuesWith(result);
    }
    return null;
}

// Аналог `lowerOptionMethodCall` для `Результат(T,E)` — по той же
// причине: `inferPreludeEnumMethod` в `type_checker.zig` жёстко задаёт
// ТИП возврата для `.успех()`/`.ошибка()`/и т.д. сравнением строки имени
// свойства, полностью минуя `checked.method_calls` (карту, которую
// заполняют обычные `реализация`-объявленные методы), хотя `prelude.zig`
// ТАКЖЕ объявляет настоящие тела `реализация Результат` для этих же
// имён. Эти настоящие тела существуют для нативного bytecode-бэкенда
// (`compiler.zig` не разделяет этот быстрый путь type checker'а таким же
// образом), но фактически недостижимы с мест вызова ЭТОГО бэкенда:
// `checked.method_calls.get(expression)` равен null для каждого вызова
// вида `.успех()`, поэтому `lowerCall` их никогда не находит — вне
// зависимости от того, внешний ли это пользовательский код, ИЛИ
// СОБСТВЕННОЕ тело `Результат::ошибка`, внутренне вызывающее
// `это.успех()` — ручная реализация той же кодогенерации
// `match_tag`/`get_variant_field` здесь чинит ОБА случая разом, поскольку
// `lowerCall` используется единообразно повсюду. `Успех`=тег 0,
// `Неудача`=тег 1 (собственный порядок объявления `prelude.zig`). Область
// покрытия соответствует прецеденту `lowerOptionMethodCall` — покрывает
// методы, реально нужные на данный момент, а не всю поверхность из 13
// методов, которую типопроверяет `inferPreludeEnumMethod`
// (ожидать/ожидать_ошибку/запас/заменить_значение/заменить_ошибку/опция/
// ошибка_опция по-прежнему проваливаются в путь `unsupported` для
// обычного доступа к свойству — известный, сознательно более узкий
// пробел, не обрабатывается молча неправильно).
fn lowerResultMethodCall(ctx: *LoweringContext, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const property = ctx.tree.expr(call.callee).property;
    const object_type = ctx.checked.expression_types.get(property.object) orelse return null;
    const type_entry = ctx.checked.types.get(object_type) orelse return null;
    const nominal = switch (type_entry.*) {
        .nominal => |value| value,
        else => return null,
    };
    const owner = ctx.resolution.symbols.get(nominal.symbol) orelse return null;
    if (!std.mem.eql(u8, owner.name, "Результат")) return null;

    const receiver = try lowerExpr(ctx, property.object);
    if (receiver.flow == .terminates) return terminated;

    if (std.mem.eql(u8, property.property, "успех") and call.arguments.len == 0) {
        const dst = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .match_tag = .{ .dst = dst, .subject = receiver.value, .tag = 0 } });
        return continuesWith(dst);
    }
    if (std.mem.eql(u8, property.property, "ошибка") and call.arguments.len == 0) {
        const dst = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .match_tag = .{ .dst = dst, .subject = receiver.value, .tag = 1 } });
        return continuesWith(dst);
    }
    // `значение()`/`причина()`: извлекает поле подходящего варианта,
    // ловушка (`.unreachable_term`) при неверном теге — соответствует
    // собственным телам `паника("нет значения")`/`паника("нет ошибки")`
    // из `prelude.zig` (текст сообщения теряется под WASM AOT, тот же
    // задокументированный пробел, что и у `lowerPanicBuiltinCall`).
    if ((std.mem.eql(u8, property.property, "значение") or std.mem.eql(u8, property.property, "причина")) and call.arguments.len == 0) {
        const want_success = std.mem.eql(u8, property.property, "значение");
        const receiver_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$result", object_type);
        try ctx.builder.emit(.{ .store_local = .{ .local = receiver_local, .src = receiver.value } });
        const condition = try ctx.builder.newValue(ctx.checked.types.builtins.boolean);
        const loaded = try ctx.builder.newValue(object_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = loaded, .local = receiver_local } });
        try ctx.builder.emit(.{ .match_tag = .{ .dst = condition, .subject = loaded, .tag = if (want_success) 0 else 1 } });
        const ok_block = try ctx.builder.newBlock();
        const panic_block = try ctx.builder.newBlock();
        ctx.builder.terminate(.{ .branch = .{ .cond = condition, .then_block = ok_block, .else_block = panic_block } });

        ctx.builder.setCurrentBlock(panic_block);
        ctx.builder.terminate(.{ .unreachable_term = .{ .reason = if (want_success) "нет значения" else "нет ошибки" } });

        ctx.builder.setCurrentBlock(ok_block);
        const ok_loaded = try ctx.builder.newValue(object_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = ok_loaded, .local = receiver_local } });
        const dst = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .get_variant_field = .{ .dst = dst, .subject = ok_loaded, .field_index = 0 } });
        return continuesWith(dst);
    }
    // `получить(запасное)`/`получить_ошибку(запасное)`: та же форма
    // ветвление-извлечь-или-запасное-значение, что и у собственного
    // `получить` в `lowerOptionMethodCall`.
    if ((std.mem.eql(u8, property.property, "получить") or std.mem.eql(u8, property.property, "получить_ошибку")) and call.arguments.len == 1) {
        const want_success = std.mem.eql(u8, property.property, "получить");
        const result_local_name = if (want_success) "$result" else "$result_err";
        const receiver_local = try ctx.builder.newLocal(symbols.invalid_symbol, result_local_name, object_type);
        try ctx.builder.emit(.{ .store_local = .{ .local = receiver_local, .src = receiver.value } });
        const fallback = try lowerExpr(ctx, call.arguments[0]);
        if (fallback.flow == .terminates) return terminated;
        const fallback_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$result_fallback", result_type);
        try ctx.builder.emit(.{ .store_local = .{ .local = fallback_local, .src = fallback.value } });
        const out_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$result_out", result_type);
        const condition = try ctx.builder.newValue(ctx.checked.types.builtins.boolean);
        const loaded = try ctx.builder.newValue(object_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = loaded, .local = receiver_local } });
        try ctx.builder.emit(.{ .match_tag = .{ .dst = condition, .subject = loaded, .tag = if (want_success) 0 else 1 } });
        const matched = try ctx.builder.newBlock();
        const unmatched = try ctx.builder.newBlock();
        const merge = try ctx.builder.newBlock();
        ctx.builder.terminate(.{ .branch = .{ .cond = condition, .then_block = matched, .else_block = unmatched } });

        ctx.builder.setCurrentBlock(matched);
        const matched_loaded = try ctx.builder.newValue(object_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = matched_loaded, .local = receiver_local } });
        const value = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .get_variant_field = .{ .dst = value, .subject = matched_loaded, .field_index = 0 } });
        try ctx.builder.emit(.{ .store_local = .{ .local = out_local, .src = value } });
        ctx.builder.terminate(.{ .jump = .{ .target = merge } });

        ctx.builder.setCurrentBlock(unmatched);
        const default_value = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = default_value, .local = fallback_local } });
        try ctx.builder.emit(.{ .store_local = .{ .local = out_local, .src = default_value } });
        ctx.builder.terminate(.{ .jump = .{ .target = merge } });

        ctx.builder.setCurrentBlock(merge);
        const result = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = result, .local = out_local } });
        return continuesWith(result);
    }
    return null;
}

fn lowerStructConstructor(ctx: *LoweringContext, expression: ast.ExprId, symbol: symbols.SymbolId, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const entry = ctx.resolution.symbols.get(symbol) orelse return null;
    if (entry.kind != .type) return null;
    const type_entry = ctx.checked.types.get(result_type) orelse return null;
    const nominal = switch (type_entry.*) {
        .nominal => |value| value,
        else => return null,
    };
    if (nominal.symbol != symbol) return null;
    const fields = fieldsForNominalSymbol(ctx, symbol) orelse return null;
    if (fields.len > 3) return ctx.unsupported("структура с более чем 3 полями");
    const arguments = ctx.checked.call_arguments.get(expression) orelse call.arguments;
    const args = try lowerCallArgs(ctx, arguments) orelse return terminated;
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .new_aggregate = .{ .dst = dst, .type_name = entry.name, .elements = args } });
    return continuesWith(dst);
}

// `x как Целое` / `x как Число` — `mir_lowering.zig` нуждается в этой
// обработке независимо, поскольку никогда не проходит через
// `compiler.zig`. `Число` — чистый no-op (тождество — оба используют
// одно f64 MIR/WASM-представление), `Целое` усекает к нулю через
// `UnOp.int_trunc`.
fn lowerCast(ctx: *LoweringContext, expression: ast.ExprId, cast: anytype) anyerror!ExprOutcome {
    const argument_outcome = try lowerExpr(ctx, cast.operand);
    if (argument_outcome.flow == .terminates) return terminated;
    const cast_type = ctx.checked.expression_types.get(expression) orelse return ctx.unsupported("не удалось определить тип каста");
    if (!ctx.checked.types.eql(cast_type, ctx.checked.types.builtins.integer)) return continuesWith(argument_outcome.value);

    const dst = try ctx.builder.newValue(ctx.checked.types.builtins.integer);
    try ctx.builder.emit(.{ .unary = .{ .dst = dst, .op = .int_trunc, .src = argument_outcome.value } });
    return continuesWith(dst);
}

fn lowerLengthBuiltinCall(ctx: *LoweringContext, symbol: symbols.SymbolId, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const entry = ctx.resolution.symbols.get(symbol) orelse return null;
    if (entry.kind != .builtin or entry.module_path != null or !std.mem.eql(u8, entry.name, "длина")) return null;
    if (call.arguments.len != 1) return ctx.unsupported("длина с числом аргументов != 1");

    const argument_type = ctx.checked.expression_types.get(call.arguments[0]) orelse return null;
    const type_entry = ctx.checked.types.get(argument_type) orelse return null;
    if (type_entry.* != .primitive or type_entry.primitive != .string) return null;

    const args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .call_builtin = .{ .dst = dst, .name = "строки::длина", .args = args } });
    return continuesWith(dst);
}

// `паника(текст)` — нативный компилятор компилирует выражение сообщения,
// затем испускает bytecode-инструкцию `.panic`, останавливающуюся с этой
// точной строкой времени выполнения. У WASM нет аналогичного примитива
// "ловушка с сообщением времени выполнения" — `unreachable` (опкод
// `0x00`, уже используется через `.unreachable_term` для
// неисчерпывающего `выбор` и собственных паник invalid-UTF-8/выход-за-
// границы в `wasm_strings.zig`) вообще не принимает операнд. Аргумент-
// сообщение всё равно ПОНИЖАЕТСЯ (через `lowerCallArgs`, как и у любого
// другого builtin здесь), поэтому любой `unsupported()` внутри НЕГО всё
// равно корректно всплывает, но его ЗНАЧЕНИЕ отбрасывается — сам текст
// сообщения безвозвратно теряется под WASM AOT, известный, принятый
// пробел (соответствует уже устоявшейся практике этой кодовой базы для
// этого класса WASM-специфичных расхождений), а не блокирующая проблема.
fn lowerPanicBuiltinCall(ctx: *LoweringContext, symbol: symbols.SymbolId, call: anytype) anyerror!?ExprOutcome {
    const entry = ctx.resolution.symbols.get(symbol) orelse return null;
    if (entry.kind != .builtin or entry.module_path != null or !std.mem.eql(u8, entry.name, "паника")) return null;
    if (call.arguments.len != 1) return ctx.unsupported("паника ожидает 1 аргумент");

    const message = try lowerExpr(ctx, call.arguments[0]);
    if (message.flow == .terminates) return terminated;
    ctx.builder.terminate(.{ .unreachable_term = .{ .reason = "паника" } });
    return terminated;
}

fn lowerProcessBuiltinCall(ctx: *LoweringContext, symbol: symbols.SymbolId, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const entry = ctx.resolution.symbols.get(symbol) orelse return null;
    if (entry.kind != .builtin or entry.module_path != null) return null;
    if (std.mem.eql(u8, entry.name, "отправить") and call.arguments.len == 2) {
        const args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
        try ctx.builder.emit(.{ .send = .{ .process = args[0], .message = args[1] } });
        return continuesWith(mir.invalid_value);
    }
    if (std.mem.eql(u8, entry.name, "получить") and call.arguments.len == 0) {
        const dst = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .receive = .{ .dst = dst } });
        return continuesWith(dst);
    }
    if (std.mem.eql(u8, entry.name, "получить_сигнал") and call.arguments.len == 0) {
        const dst = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .receive_signal = .{ .dst = dst } });
        return continuesWith(dst);
    }
    if (std.mem.eql(u8, entry.name, "себя") and call.arguments.len == 0) {
        const dst = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .call_builtin = .{ .dst = dst, .name = "@runtime::current_process", .args = &.{} } });
        return continuesWith(dst);
    }
    return null;
}

// Фактическим хранилищем UTF-16 владеет JS string runtime; значения
// строк панос в WASM остаются непрозрачными i32-хендлами.
// `строки.срез`/`.найти` сознательно используют индексы юникодных
// скаляров, соответствуя контракту VM, а не смещениям JS UTF-16.
// `в_число` строит стандартный хендл Результат в том же хост-рантайме,
// так что обычный `выбор` панос обрабатывает оба исхода без изменений.
fn lowerStringBuiltinCall(ctx: *LoweringContext, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const symbol = ctx.resolution.expr_symbols.get(call.callee) orelse return null;
    const entry = ctx.resolution.symbols.get(symbol) orelse return null;
    if (entry.kind != .builtin or entry.module_path == null or !std.mem.eql(u8, entry.module_path.?, "строки")) return null;

    const property = ctx.tree.expr(call.callee).property;
    const name = if (std.mem.eql(u8, property.property, "срез"))
        "строки::срез"
    else if (std.mem.eql(u8, property.property, "найти"))
        "строки::найти"
    else if (std.mem.eql(u8, property.property, "начинается_с"))
        "строки::начинается_с"
    else if (std.mem.eql(u8, property.property, "заменить"))
        "строки::заменить"
    else if (std.mem.eql(u8, property.property, "разбить"))
        "строки::разбить"
    else if (std.mem.eql(u8, property.property, "из_числа"))
        "строки::из_числа"
    else if (std.mem.eql(u8, property.property, "в_число"))
        "строки::в_число"
    else
        return ctx.unsupported("строки.свойство вызов (неподдерживаемая строковая операция в AOT WASM)");

    const args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .call_builtin = .{ .dst = dst, .name = name, .args = args } });
    return continuesWith(dst);
}

// Сознательно узкий сетевой мост AOT для браузера. Хост выполняет
// синхронный same-origin XHR, поскольку у текущего WASM ABI нет
// поддержки приостановки или продолжений; успех — `Опция.Есть(тело)`,
// любой неудачный запрос — `Опция.Нет()`.
fn lowerNetworkBuiltinCall(ctx: *LoweringContext, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const symbol = ctx.resolution.expr_symbols.get(call.callee) orelse return null;
    const entry = ctx.resolution.symbols.get(symbol) orelse return null;
    if (entry.kind != .builtin or entry.module_path == null or !std.mem.eql(u8, entry.module_path.?, "сеть")) return null;

    const property = ctx.tree.expr(call.callee).property;
    const builtin_name = if (std.mem.eql(u8, property.property, "http_запрос_sync"))
        "сеть::http_запрос_sync"
    else if (std.mem.eql(u8, property.property, "http_запрос_sync_с_заголовками"))
        "сеть::http_запрос_sync_с_заголовками"
    else
        return ctx.unsupported("сеть.свойство вызов (неподдерживаемая сетевая операция в AOT WASM)");
    const args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .call_builtin = .{ .dst = dst, .name = builtin_name, .args = args } });
    return continuesWith(dst);
}

// `время.сейчас_мс`/`.монотонно_мс` — единственные вызовы builtin-модуля,
// которые понижает этот срез. Испускаются как `call_builtin` с ТЕМ ЖЕ
// соглашением об имени "модуль::имя", что уже использует `target.zig`
// для проверок доступности рантайма, а не новой схемой именования.
// `время.спать_мс` намеренно не имеет здесь case — это native-only
// builtin (`builtinAvailability` в `target.zig`), и остаётся паникой
// `unsupported()` в AOT WASM, тот же режим отказа, что и у любой другой
// native-only возможности в этом файле.
fn lowerTimeBuiltinCall(ctx: *LoweringContext, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const property = ctx.tree.expr(call.callee).property;
    const symbol = ctx.resolution.expr_symbols.get(call.callee) orelse return null;
    const entry = ctx.resolution.symbols.get(symbol) orelse return null;
    if (entry.kind != .builtin or entry.module_path == null or !std.mem.eql(u8, entry.module_path.?, "время")) return null;

    if (std.mem.eql(u8, property.property, "спать_мс")) return ctx.unsupported("время.спать_мс (native-only builtin, недоступен в AOT WASM)");

    const name = if (std.mem.eql(u8, property.property, "сейчас_мс"))
        "время::сейчас_мс"
    else if (std.mem.eql(u8, property.property, "монотонно_мс"))
        "время::монотонно_мс"
    else
        return ctx.unsupported("модуль.свойство вызов (только время.сейчас_мс/монотонно_мс поддержаны в AOT WASM)");

    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .call_builtin = .{ .dst = dst, .name = name, .args = &.{} } });
    return continuesWith(dst);
}

// DOM поддерживает совместимые числовые методы плюс методы
// текстового содержимого/ввода. Эмиттер браузера транспортирует каждую
// `Строка` панос как непрозрачный хендл JS-рантайма; обработчики клика
// пока остаются именованными экспортами с нулём аргументов и не могут
// захватывать контекст панос.
// Классификация захваченного значения по типу, решаемая полностью на
// ЭТАПЕ КОМПИЛЯЦИИ по собственному статическому типу захвата (нет
// рантайм-тега типа, который мог бы управлять настоящей рекурсией в
// испускаемом коде — та же логика, на которую уже опирается поэлементное
// разворачивание `.new_aggregate` в `wasm_objects.zig`).
//   `.scalar`        — Число/Булево/Целое: сырое копирование 8 байт,
//                       разыменование указателей вообще не нужно.
//   `.string`        — Строка: промоутируется через существующий
//                       `wasm_heap.findOrBuildPromoteToPermanent`.
//   `.structure`      — nominal-структура, чей полный граф полей можно
//                       промоутировать рекурсивно.
//   `.array`          — массив, чей граф элементов можно промоутировать
//                       рекурсивно рантайм-циклом.
//   `.function_ref`   — захват типа `.function`. Реальный, частый
//                       случай: `lookupTrackingCaptures` в `symbols.zig`
//                       регистрирует ЛЮБОЙ символ вида `.function`,
//                       упомянутый через границу лямбды, как захват —
//                       включая обычную верхнеуровневую функцию,
//                       вызванную НАПРЯМУЮ внутри тела обработчика
//                       (например, `обработать_переключить(id)`), хотя
//                       собственный быстрый путь прямого вызова в
//                       `mir_lowering.zig` означает, что этой ссылке в
//                       МЕСТЕ ВЫЗОВА вообще никогда не нужно
//                       упакованное значение замыкания. Шаг построения
//                       окружения в `lowerLambda` этого тоже не знает —
//                       он безусловно захватывает каждый символ, который
//                       перечислил резолвер. Локаль, чьё текущее
//                       происхождение — литеральная лямбда, несёт свой
//                       точный список захватов резолвера в
//                       `closure_origins`, поэтому её бокс+окружение
//                       промоутируются рекурсивно. Для значения-функции
//                       с неизвестным происхождением рантайм-проверка
//                       (`promoteFunctionRefCapture`) всё равно разрешает
//                       обычный бокс функции (`env_ptr == 0`) и
//                       ловушится на непрозрачном ненулевом окружении
//                       вместо того, чтобы угадывать его раскладку и
//                       производить висящий указатель.
//   `.unsupported`    — `Процесс` (его AOT-хендл — это указатель на
//                       фрейм актора, выделенный в сбрасываемой арене, а
//                       не постоянный скалярный ID), generic-структура,
//                       чьи конкретные поля здесь недоступны, или
//                       рекурсивный граф типов (сохранение цикла требует
//                       карты идентичности).
const CaptureKind = enum { scalar, string, structure, array, function_ref, unsupported };

fn classifyCapture(checked: *const type_checker.CheckResult, type_id: types.TypeId) CaptureKind {
    return classifyCaptureDepth(checked, type_id, 0);
}

// Generic nominal-объявления хранят типы своих полей в терминах
// параметров-заполнителей объявления. Конкретное значение, пересекающее
// границу DOM-замыкания, несёт реальные аргументы в своём nominal
// TypeId, поэтому прямые заполнители разрешаются здесь без выделения
// второго графа типов. Поле, чей СОБСТВЕННЫЙ тип сам является generic
// nominal-типом (`Коробка(T)` внутри `Коробка(Коробка(T))`), всё равно
// несёт голые заполнители ВНЕШНЕГО nominal-типа в своём списке
// аргументов — рекурсивно проходим через ту же подстановку перед
// возвратом, чтобы вложенные generic-захваты разрешались в полностью
// конкретный тип, а не частично подставленный. Материализация
// подставленного nominal-типа мутирует `checked.types` (TypeStore
// только-на-добавление — существующие TypeId остаются валидными);
// `@constCast` здесь безопасен, поскольку этот проход выполняется строго
// после того, как typecheck закончил читать хранилище.
fn concreteCaptureFieldType(checked: *const type_checker.CheckResult, nominal: types.Type, field_type: types.TypeId) ?types.TypeId {
    const entry = checked.types.get(field_type) orelse return field_type;
    switch (entry.*) {
        .generic_parameter => {
            const parameters = type_checker.nominalParametersOf(checked, nominal.nominal.symbol);
            for (parameters, 0..) |parameter, index| {
                if (checked.types.eql(field_type, parameter.typ)) {
                    if (index >= nominal.nominal.arguments.len) return null;
                    return nominal.nominal.arguments[index];
                }
            }
            return null;
        },
        .nominal => |inner| {
            var substituted_any = false;
            var arguments: std.ArrayList(types.TypeId) = .empty;
            defer arguments.deinit(checked.allocator);
            for (inner.arguments) |argument| {
                const resolved = concreteCaptureFieldType(checked, nominal, argument) orelse return null;
                if (!checked.types.eql(resolved, argument)) substituted_any = true;
                arguments.append(checked.allocator, resolved) catch return null;
            }
            if (!substituted_any) return field_type;
            const mutable_types: *types.TypeStore = @constCast(&checked.types);
            return mutable_types.nominalWithIdentity(inner.symbol, inner.identity, arguments.items) catch null;
        },
        else => return field_type,
    }
}

fn classifyCaptureDepth(checked: *const type_checker.CheckResult, type_id: types.TypeId, depth: u8) CaptureKind {
    if (depth == 64) return .unsupported;
    if (checked.types.eql(type_id, checked.types.builtins.string)) return .string;
    const entry = checked.types.get(type_id) orelse return .scalar;
    return switch (entry.*) {
        .nominal => |nominal| blk: {
            const fields = checked.nominal_fields.get(nominal.symbol) orelse
                if (checked.generic_nominal_fields.get(nominal.symbol)) |generic| generic.fields else break :blk .unsupported;
            for (fields) |field| {
                const concrete_type = concreteCaptureFieldType(checked, .{ .nominal = nominal }, field.typ) orelse break :blk .unsupported;
                // У функции, хранящейся внутри агрегата, на этой границе
                // нет метаданных символа захвата, поэтому раскладку её
                // окружения нельзя безопасно промоутировать. Напрямую
                // захваченные локальные функциональные значения остаются
                // поддержаны через путь ниже, знающий о символе.
                if (checked.types.get(concrete_type)) |field_entry| {
                    if (field_entry.* == .function) break :blk .unsupported;
                }
                if (classifyCaptureDepth(checked, concrete_type, depth + 1) == .unsupported) break :blk .unsupported;
            }
            break :blk .structure;
        },
        .function => .function_ref,
        .array => |element| if (classifyCaptureDepth(checked, element, depth + 1) == .unsupported) .unsupported else .array,
        // Значение `Процесс` — это обычный указатель на фрейм (`i32`, та
        // же форма, что и у любого другого захвата-указателя) —
        // копирование его в бокс замыкания не требует специальной логики
        // промоушена (тождественного копирования `.scalar` уже
        // достаточно). Безопасно ТОЛЬКО потому, что вызывающая сторона
        // (`lowerDomClickClosure`) помечает
        // `module.actor_captured_by_dom_closure` при каждом достижении
        // этого случая, поэтому `expandSpawn` в `wasm_actors.zig` с
        // самого начала выделяет базовый фрейм в ПОСТОЯННОЙ памяти — к
        // моменту, когда это захваченное значение действительно
        // читается, оно уже указывает в память, переживающую сброс арены
        // между вызовами.
        .process => .scalar,
        else => .scalar,
    };
}

fn isProcessCapture(checked: *const type_checker.CheckResult, type_id: types.TypeId) bool {
    const entry = checked.types.get(type_id) orelse return false;
    return entry.* == .process;
}

pub const invoke_click_trampoline_name = "@invoke_click";

// Единая фиксированная точка входа браузера для каждого замыкания-клика.
// JS передаёт постоянный бокс замыкания плюс развёрнутые скаляры
// MouseEvent. Трамплин строит публичное nominal-значение
// `DOM.СобытиеКлика` в сбрасываемой per-call арене, затем делегирует
// распаковку замыкания и `call_indirect` в
// `wasm_interfaces.expandCallValue`.
fn findOrBuildInvokeClickTrampoline(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout, event_type: types.TypeId) !mir.FunctionId {
    if (wasm_heap.findFunctionByName(module, invoke_click_trampoline_name)) |id| return id;
    const id = try mir_builder.newFunction(module, allocator, invoke_click_trampoline_name, dummy_symbol, type_store.builtins.void, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const box_local = try builder.newLocal(dummy_symbol, "box", layout.ptr_type);
    const client_x_local = try builder.newLocal(dummy_symbol, "клиент_x", type_store.builtins.number);
    const client_y_local = try builder.newLocal(dummy_symbol, "клиент_y", type_store.builtins.number);
    const button_local = try builder.newLocal(dummy_symbol, "кнопка", type_store.builtins.integer);
    const ctrl_local = try builder.newLocal(dummy_symbol, "ctrl", type_store.builtins.boolean);
    const shift_local = try builder.newLocal(dummy_symbol, "shift", type_store.builtins.boolean);
    const alt_local = try builder.newLocal(dummy_symbol, "alt", type_store.builtins.boolean);
    const meta_local = try builder.newLocal(dummy_symbol, "meta", type_store.builtins.boolean);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{ box_local, client_x_local, client_y_local, button_local, ctrl_local, shift_local, alt_local, meta_local });
    builder.currentFunction().type_store = type_store;

    const arena = module.arena.allocator();
    var fields: std.ArrayList(mir.ValueId) = .empty;
    try fields.append(arena, try wasm_heap.loadLocal(&builder, client_x_local, type_store.builtins.number));
    try fields.append(arena, try wasm_heap.loadLocal(&builder, client_y_local, type_store.builtins.number));
    try fields.append(arena, try wasm_heap.loadLocal(&builder, button_local, type_store.builtins.integer));
    try fields.append(arena, try wasm_heap.loadLocal(&builder, ctrl_local, type_store.builtins.boolean));
    try fields.append(arena, try wasm_heap.loadLocal(&builder, shift_local, type_store.builtins.boolean));
    try fields.append(arena, try wasm_heap.loadLocal(&builder, alt_local, type_store.builtins.boolean));
    try fields.append(arena, try wasm_heap.loadLocal(&builder, meta_local, type_store.builtins.boolean));
    const event = try builder.newValue(event_type);
    try builder.emit(.{ .new_aggregate = .{ .dst = event, .type_name = "DOM.СобытиеКлика", .elements = try fields.toOwnedSlice(arena) } });
    // Разворачивание `.call_value` потребляет callee до своих аргументов.
    // Заново загруженный бокс производится ПОСЛЕДНИМ, чтобы он оказался
    // на вершине WASM-стека; уже произведённое событие остаётся прямо
    // под ним.
    const box_val = try wasm_heap.loadLocal(&builder, box_local, layout.ptr_type);
    try builder.emit(.{ .call_value = .{ .dst = null, .callee = box_val, .args = try module.arena.allocator().dupe(mir.ValueId, &.{event}) } });
    builder.terminate(.{ .return_value = .{ .value = null } });
    return id;
}

// Промоутирует ОДНО уже загруженное значение (`old_value` типа
// `value_type`) в постоянный регион согласно классификации
// `classifyCapture` — общая листовая операция, к которой сводятся и
// `promoteClosureBoxToPermanent` (слоты окружения), и рекурсивный
// промоушен агрегатов. `.scalar` — no-op (сырое значение уже безопасно
// для постоянного региона — оно вообще не несёт указателя).
// `.unsupported` сюда никогда не доходит — отклоняется раньше, до
// начала любого понижения, собственной предварительной проверкой
// `lowerDomClickClosure`.
fn promoteCaptureValue(ctx: *LoweringContext, layout: wasm_heap.PtrLayout, value_type: types.TypeId, old_value: mir.ValueId, capture_symbol: ?symbols.SymbolId, closure_depth: u8) anyerror!mir.ValueId {
    return switch (classifyCapture(ctx.checked, value_type)) {
        .scalar => old_value,
        .string => blk: {
            const promote_id = try wasm_heap.findOrBuildPromoteToPermanent(ctx.allocator, ctx.builder.module, &ctx.checked.types, layout);
            const promoted = try ctx.builder.newValue(layout.ptr_type);
            try ctx.builder.emit(.{ .call = .{ .dst = promoted, .callee = promote_id, .args = try wasm_heap.dupeOne(ctx.builder.module, old_value) } });
            break :blk promoted;
        },
        .structure => try promoteStructToPermanent(ctx, layout, value_type, old_value, closure_depth),
        .array => try promoteArrayToPermanent(ctx, layout, value_type, old_value, closure_depth),
        .function_ref => blk: {
            if (capture_symbol) |symbol| {
                if (ctx.closure_origins.get(symbol)) |closure_expression| {
                    if (closure_depth == 64) return ctx.unsupported("слишком глубокая или рекурсивная цепочка захваченных замыканий");
                    const captures = ctx.resolution.lambda_captures.get(closure_expression) orelse &.{};
                    break :blk try promoteClosureBoxToPermanent(ctx, layout, old_value, captures, closure_depth + 1);
                }
            }
            break :blk try promoteFunctionRefCapture(ctx, layout, old_value);
        },
        .unsupported => unreachable,
    };
}

// Бокс захваченного значения типа `.function`, скопированный в
// постоянный регион — почему этот случай вообще существует, см.
// собственный doc-комментарий `CaptureKind.function_ref` (резолвер
// захватывает каждую ссылку на функцию, пересекающую границу лямбды,
// даже те, что быстрый путь прямого вызова во время понижения
// фактически никогда не боксирует). Это запасной вариант для
// НЕИЗВЕСТНОГО происхождения: у обычной именованной функции
// `env_ptr == 0`, и её можно безопасно скопировать, в то время как у
// ненулевого окружения нет доступной раскладки слотов. Известные
// локальные литеральные лямбды вместо этого идут по рекурсивному пути
// `promoteClosureBoxToPermanent` в `promoteCaptureValue`. Рантайм-
// проверка здесь ловушится вместо того, чтобы молча сохранить висящий
// указатель для непрозрачного замыкания из параметра/поля/
// переприсваивания.
fn promoteFunctionRefCapture(ctx: *LoweringContext, layout: wasm_heap.PtrLayout, old_box: mir.ValueId) anyerror!mir.ValueId {
    const module = ctx.builder.module;
    const old_box_local = try wasm_heap.storeLocal(&ctx.builder, "@click_old_fn_box", layout.ptr_type, old_box);

    const old_box_for_table = try wasm_heap.loadLocal(&ctx.builder, old_box_local, layout.ptr_type);
    const table_index = try ctx.builder.newValue(layout.idx_type);
    try ctx.builder.emit(.{ .mem_load = .{ .dst = table_index, .addr = old_box_for_table } });
    const table_index_local = try wasm_heap.storeLocal(&ctx.builder, "@click_fn_table_index", layout.idx_type, table_index);

    const old_box_for_env = try wasm_heap.loadLocal(&ctx.builder, old_box_local, layout.ptr_type);
    const four = try wasm_heap.addressConst(&ctx.builder, layout.idx_type, 4);
    const env_addr = try wasm_heap.binOp(&ctx.builder, layout.idx_type, .add, old_box_for_env, four);
    const env_ptr = try ctx.builder.newValue(layout.ptr_type);
    try ctx.builder.emit(.{ .mem_load = .{ .dst = env_ptr, .addr = env_addr } });

    const zero_check = try wasm_heap.addressConst(&ctx.builder, layout.ptr_type, 0);
    const is_plain = try wasm_heap.cmpOp(&ctx.builder, layout.bool_type, .equal, env_ptr, zero_check);

    const ok_block = try ctx.builder.newBlock();
    const trap_block = try ctx.builder.newBlock();
    ctx.builder.terminate(.{ .branch = .{ .cond = is_plain, .then_block = ok_block, .else_block = trap_block } });

    ctx.builder.setCurrentBlock(trap_block);
    ctx.builder.terminate(.{ .unreachable_term = .{ .reason = "DOM.на_клик(): нельзя безопасно продвинуть замыкание неизвестного происхождения с собственным окружением" } });

    ctx.builder.setCurrentBlock(ok_block);
    const alloc_permanent_id = try wasm_heap.findOrBuildAllocPermanent(ctx.allocator, module, &ctx.checked.types, layout);
    const box_size = try wasm_heap.addressConst(&ctx.builder, layout.idx_type, 8);
    const new_box = try ctx.builder.newValue(layout.ptr_type);
    try ctx.builder.emit(.{ .call = .{ .dst = new_box, .callee = alloc_permanent_id, .args = try wasm_heap.dupeOne(module, box_size) } });
    const new_box_local = try wasm_heap.storeLocal(&ctx.builder, "@click_new_fn_box", layout.ptr_type, new_box);

    const table_index_for_store = try wasm_heap.loadLocal(&ctx.builder, table_index_local, layout.idx_type);
    const new_box_for_table = try wasm_heap.loadLocal(&ctx.builder, new_box_local, layout.ptr_type);
    try ctx.builder.emit(.{ .mem_store = .{ .addr = new_box_for_table, .src = table_index_for_store } });

    const zero_store = try wasm_heap.addressConst(&ctx.builder, layout.idx_type, 0);
    const four2 = try wasm_heap.addressConst(&ctx.builder, layout.idx_type, 4);
    const new_box_for_env_addr = try wasm_heap.loadLocal(&ctx.builder, new_box_local, layout.ptr_type);
    const new_env_addr = try wasm_heap.binOp(&ctx.builder, layout.idx_type, .add, new_box_for_env_addr, four2);
    try ctx.builder.emit(.{ .mem_store = .{ .addr = new_env_addr, .src = zero_store } });

    return try wasm_heap.loadLocal(&ctx.builder, new_box_local, layout.ptr_type);
}

// Выделяет копию структуры с тем же числом полей в постоянном регионе и
// рекурсивно промоутирует каждое поле. Та же раскладка
// `frame_load`/`frame_store` со слотами по 8 байт, что уже установлена
// `wasm_objects.zig` для обычных структур (без слота тега — это
// соглашение только для вариантов).
fn promoteStructToPermanent(ctx: *LoweringContext, layout: wasm_heap.PtrLayout, struct_type: types.TypeId, old_struct_ptr: mir.ValueId, closure_depth: u8) anyerror!mir.ValueId {
    const module = ctx.builder.module;
    const type_entry = ctx.checked.types.get(struct_type) orelse return ctx.unsupported("захват структуры неизвестного типа (Stage C)");
    const nominal = switch (type_entry.*) {
        .nominal => |value| value,
        else => return ctx.unsupported("захват не-структуры как структуры (Stage C)"),
    };
    const fields = ctx.checked.nominal_fields.get(nominal.symbol) orelse
        if (ctx.checked.generic_nominal_fields.get(nominal.symbol)) |generic| generic.fields else return ctx.unsupported("захват структуры неизвестного типа (Stage C)");

    const old_struct_local = try wasm_heap.storeLocal(&ctx.builder, "@click_old_struct", layout.ptr_type, old_struct_ptr);

    const alloc_permanent_id = try wasm_heap.findOrBuildAllocPermanent(ctx.allocator, module, &ctx.checked.types, layout);
    const struct_size = try wasm_heap.addressConst(&ctx.builder, layout.idx_type, @intCast(fields.len * 8));
    const new_struct = try ctx.builder.newValue(layout.ptr_type);
    try ctx.builder.emit(.{ .call = .{ .dst = new_struct, .callee = alloc_permanent_id, .args = try wasm_heap.dupeOne(module, struct_size) } });
    const new_struct_local = try wasm_heap.storeLocal(&ctx.builder, "@click_new_struct", layout.ptr_type, new_struct);

    for (fields, 0..) |field, j| {
        const old_struct_for_load = try wasm_heap.loadLocal(&ctx.builder, old_struct_local, layout.ptr_type);
        const concrete_type = concreteCaptureFieldType(ctx.checked, .{ .nominal = nominal }, field.typ) orelse return ctx.unsupported("вложенный generic-тип в захвате структуры (Stage C)");
        const old_field_val = try ctx.builder.newValue(concrete_type);
        try ctx.builder.emit(.{ .frame_load = .{ .dst = old_field_val, .frame = old_struct_for_load, .slot = @intCast(j) } });

        const promoted_field = try promoteCaptureValue(ctx, layout, concrete_type, old_field_val, null, closure_depth);

        const new_struct_for_store = try wasm_heap.loadLocal(&ctx.builder, new_struct_local, layout.ptr_type);
        try ctx.builder.emit(.{ .frame_store = .{ .frame = new_struct_for_store, .slot = @intCast(j), .src = promoted_field } });
    }

    return try wasm_heap.loadLocal(&ctx.builder, new_struct_local, layout.ptr_type);
}

fn promoteArrayToPermanent(ctx: *LoweringContext, layout: wasm_heap.PtrLayout, array_type: types.TypeId, old_array_ptr: mir.ValueId, closure_depth: u8) anyerror!mir.ValueId {
    const type_entry = ctx.checked.types.get(array_type) orelse return ctx.unsupported("захват массива неизвестного типа (Stage C)");
    const element_type = switch (type_entry.*) {
        .array => |element| element,
        else => return ctx.unsupported("захват не-массива как массива (Stage C)"),
    };
    const module = ctx.builder.module;
    const old_array_local = try wasm_heap.storeLocal(&ctx.builder, "@click_old_array", layout.ptr_type, old_array_ptr);

    const old_for_length = try wasm_heap.loadLocal(&ctx.builder, old_array_local, layout.ptr_type);
    const length = try ctx.builder.newValue(layout.idx_type);
    try ctx.builder.emit(.{ .frame_load = .{ .dst = length, .frame = old_for_length, .slot = 0 } });
    const length_local = try wasm_heap.storeLocal(&ctx.builder, "@click_array_length", layout.idx_type, length);

    const old_for_data = try wasm_heap.loadLocal(&ctx.builder, old_array_local, layout.ptr_type);
    const old_data = try ctx.builder.newValue(layout.ptr_type);
    try ctx.builder.emit(.{ .frame_load = .{ .dst = old_data, .frame = old_for_data, .slot = 2 } });
    const old_data_local = try wasm_heap.storeLocal(&ctx.builder, "@click_old_array_data", layout.ptr_type, old_data);

    const alloc_permanent_id = try wasm_heap.findOrBuildAllocPermanent(ctx.allocator, module, &ctx.checked.types, layout);
    const header_size = try wasm_heap.addressConst(&ctx.builder, layout.idx_type, 3 * 8);
    const new_header = try ctx.builder.newValue(layout.ptr_type);
    try ctx.builder.emit(.{ .call = .{ .dst = new_header, .callee = alloc_permanent_id, .args = try wasm_heap.dupeOne(module, header_size) } });
    const new_header_local = try wasm_heap.storeLocal(&ctx.builder, "@click_new_array", layout.ptr_type, new_header);

    const length_for_size = try wasm_heap.loadLocal(&ctx.builder, length_local, layout.idx_type);
    const eight_for_size = try wasm_heap.addressConst(&ctx.builder, layout.idx_type, 8);
    const data_size = try wasm_heap.binOp(&ctx.builder, layout.idx_type, .multiply, length_for_size, eight_for_size);
    const new_data = try ctx.builder.newValue(layout.ptr_type);
    try ctx.builder.emit(.{ .call = .{ .dst = new_data, .callee = alloc_permanent_id, .args = try wasm_heap.dupeOne(module, data_size) } });
    const new_data_local = try wasm_heap.storeLocal(&ctx.builder, "@click_new_array_data", layout.ptr_type, new_data);

    inline for (.{ @as(u32, 0), @as(u32, 1) }) |slot| {
        const header_value = try wasm_heap.loadLocal(&ctx.builder, length_local, layout.idx_type);
        const header = try wasm_heap.loadLocal(&ctx.builder, new_header_local, layout.ptr_type);
        try ctx.builder.emit(.{ .frame_store = .{ .frame = header, .slot = slot, .src = header_value } });
    }
    const data_pointer = try wasm_heap.loadLocal(&ctx.builder, new_data_local, layout.ptr_type);
    const header_for_data = try wasm_heap.loadLocal(&ctx.builder, new_header_local, layout.ptr_type);
    try ctx.builder.emit(.{ .frame_store = .{ .frame = header_for_data, .slot = 2, .src = data_pointer } });

    const index_local = try ctx.builder.newLocal(dummy_symbol, "@click_array_index", layout.idx_type);
    const zero = try wasm_heap.addressConst(&ctx.builder, layout.idx_type, 0);
    try ctx.builder.emit(.{ .store_local = .{ .local = index_local, .src = zero } });

    const loop_header = try ctx.builder.newBlock();
    ctx.builder.terminate(.{ .jump = .{ .target = loop_header } });
    ctx.builder.setCurrentBlock(loop_header);
    const index_for_cmp = try wasm_heap.loadLocal(&ctx.builder, index_local, layout.idx_type);
    const length_for_cmp = try wasm_heap.loadLocal(&ctx.builder, length_local, layout.idx_type);
    const keep_going = try wasm_heap.cmpOp(&ctx.builder, layout.bool_type, .less, index_for_cmp, length_for_cmp);
    const loop_body = try ctx.builder.newBlock();
    const loop_exit = try ctx.builder.newBlock();
    ctx.builder.terminate(.{ .branch = .{ .cond = keep_going, .then_block = loop_body, .else_block = loop_exit } });

    ctx.builder.setCurrentBlock(loop_body);
    const index_for_old_offset = try wasm_heap.loadLocal(&ctx.builder, index_local, layout.idx_type);
    const eight_for_old_offset = try wasm_heap.addressConst(&ctx.builder, layout.idx_type, 8);
    const old_offset = try wasm_heap.binOp(&ctx.builder, layout.idx_type, .multiply, index_for_old_offset, eight_for_old_offset);
    const old_offset_local = try wasm_heap.storeLocal(&ctx.builder, "@click_old_array_offset", layout.idx_type, old_offset);
    const old_data_for_addr = try wasm_heap.loadLocal(&ctx.builder, old_data_local, layout.ptr_type);
    const old_offset_for_addr = try wasm_heap.loadLocal(&ctx.builder, old_offset_local, layout.idx_type);
    const old_element_addr = try wasm_heap.binOp(&ctx.builder, layout.idx_type, .add, old_data_for_addr, old_offset_for_addr);
    const old_element = try ctx.builder.newValue(element_type);
    try ctx.builder.emit(.{ .mem_load = .{ .dst = old_element, .addr = old_element_addr } });
    const promoted_element = try promoteCaptureValue(ctx, layout, element_type, old_element, null, closure_depth);
    const promoted_element_local = try wasm_heap.storeLocal(&ctx.builder, "@click_promoted_array_element", element_type, promoted_element);

    const index_for_new_offset = try wasm_heap.loadLocal(&ctx.builder, index_local, layout.idx_type);
    const eight_for_new_offset = try wasm_heap.addressConst(&ctx.builder, layout.idx_type, 8);
    const new_offset = try wasm_heap.binOp(&ctx.builder, layout.idx_type, .multiply, index_for_new_offset, eight_for_new_offset);
    const new_offset_local = try wasm_heap.storeLocal(&ctx.builder, "@click_new_array_offset", layout.idx_type, new_offset);
    const new_data_for_addr = try wasm_heap.loadLocal(&ctx.builder, new_data_local, layout.ptr_type);
    const new_offset_for_addr = try wasm_heap.loadLocal(&ctx.builder, new_offset_local, layout.idx_type);
    const new_element_addr = try wasm_heap.binOp(&ctx.builder, layout.idx_type, .add, new_data_for_addr, new_offset_for_addr);
    const new_element_addr_local = try wasm_heap.storeLocal(&ctx.builder, "@click_new_array_element_addr", layout.ptr_type, new_element_addr);
    const promoted_element_for_store = try wasm_heap.loadLocal(&ctx.builder, promoted_element_local, element_type);
    const new_element_addr_for_store = try wasm_heap.loadLocal(&ctx.builder, new_element_addr_local, layout.ptr_type);
    try ctx.builder.emit(.{ .mem_store = .{ .addr = new_element_addr_for_store, .src = promoted_element_for_store } });

    const index_for_next = try wasm_heap.loadLocal(&ctx.builder, index_local, layout.idx_type);
    const one = try wasm_heap.addressConst(&ctx.builder, layout.idx_type, 1);
    const next_index = try wasm_heap.binOp(&ctx.builder, layout.idx_type, .add, index_for_next, one);
    try ctx.builder.emit(.{ .store_local = .{ .local = index_local, .src = next_index } });
    ctx.builder.terminate(.{ .jump = .{ .target = loop_header } });

    ctx.builder.setCurrentBlock(loop_exit);
    return wasm_heap.loadLocal(&ctx.builder, new_header_local, layout.ptr_type);
}

// Перестраивает бокс, произведённый `.build_closure` (table_index +
// env_ptr, сейчас в обычной СБРАСЫВАЕМОЙ арене), прямо в ПОСТОЯННОМ
// регионе — нужно даже для захватов, состоящих только из СКАЛЯРОВ: сами
// АЛЛОКАЦИИ бокса+окружения остаются указателями, которые JS хранит
// сырыми через отдельный последующий экспортируемый вызов (клик),
// независимо от того, что внутри них. Копия по слотам, направленная по
// ТИПУ, вместо плоского побайтового копирования (корректного только
// когда каждый слот скалярен) — слот `Строка`/агрегата получает
// промоушен и СВОИХ данных, на которые указывает (`promoteCaptureValue`),
// а не только сырого битового паттерна указателя (который иначе повис
// бы после следующего сброса арены).
fn promoteClosureBoxToPermanent(ctx: *LoweringContext, layout: wasm_heap.PtrLayout, box_value: mir.ValueId, captures: []const symbols.SymbolId, closure_depth: u8) anyerror!mir.ValueId {
    const module = ctx.builder.module;
    const box_local = try wasm_heap.storeLocal(&ctx.builder, "@click_box", layout.ptr_type, box_value);

    const box_for_table = try wasm_heap.loadLocal(&ctx.builder, box_local, layout.ptr_type);
    const table_index = try ctx.builder.newValue(layout.idx_type);
    try ctx.builder.emit(.{ .mem_load = .{ .dst = table_index, .addr = box_for_table } });
    const table_index_local = try wasm_heap.storeLocal(&ctx.builder, "@click_table_index", layout.idx_type, table_index);

    const promoted_env_local = env_blk: {
        if (captures.len == 0) {
            const zero = try wasm_heap.addressConst(&ctx.builder, layout.ptr_type, 0);
            break :env_blk try wasm_heap.storeLocal(&ctx.builder, "@click_env", layout.ptr_type, zero);
        }
        const box_for_env = try wasm_heap.loadLocal(&ctx.builder, box_local, layout.ptr_type);
        const four = try wasm_heap.addressConst(&ctx.builder, layout.idx_type, 4);
        const env_addr = try wasm_heap.binOp(&ctx.builder, layout.idx_type, .add, box_for_env, four);
        const old_env_ptr = try ctx.builder.newValue(layout.ptr_type);
        try ctx.builder.emit(.{ .mem_load = .{ .dst = old_env_ptr, .addr = env_addr } });
        const old_env_local = try wasm_heap.storeLocal(&ctx.builder, "@click_old_env", layout.ptr_type, old_env_ptr);

        const alloc_permanent_id = try wasm_heap.findOrBuildAllocPermanent(ctx.allocator, module, &ctx.checked.types, layout);
        const new_env_size = try wasm_heap.addressConst(&ctx.builder, layout.idx_type, @intCast(captures.len * 8));
        const new_env = try ctx.builder.newValue(layout.ptr_type);
        try ctx.builder.emit(.{ .call = .{ .dst = new_env, .callee = alloc_permanent_id, .args = try wasm_heap.dupeOne(module, new_env_size) } });
        const new_env_local = try wasm_heap.storeLocal(&ctx.builder, "@click_new_env", layout.ptr_type, new_env);

        for (captures, 0..) |capture_symbol, i| {
            const capture_type = ctx.checked.symbol_types.get(capture_symbol) orelse ctx.checked.types.builtins.void;

            const old_env_for_load = try wasm_heap.loadLocal(&ctx.builder, old_env_local, layout.ptr_type);
            const old_slot_val = try ctx.builder.newValue(capture_type);
            try ctx.builder.emit(.{ .frame_load = .{ .dst = old_slot_val, .frame = old_env_for_load, .slot = @intCast(i) } });

            const promoted_val = try promoteCaptureValue(ctx, layout, capture_type, old_slot_val, capture_symbol, closure_depth);

            const new_env_for_store = try wasm_heap.loadLocal(&ctx.builder, new_env_local, layout.ptr_type);
            try ctx.builder.emit(.{ .frame_store = .{ .frame = new_env_for_store, .slot = @intCast(i), .src = promoted_val } });
        }

        break :env_blk new_env_local;
    };

    const alloc_permanent_id = try wasm_heap.findOrBuildAllocPermanent(ctx.allocator, module, &ctx.checked.types, layout);
    const box_size = try wasm_heap.addressConst(&ctx.builder, layout.idx_type, 8);
    const new_box = try ctx.builder.newValue(layout.ptr_type);
    try ctx.builder.emit(.{ .call = .{ .dst = new_box, .callee = alloc_permanent_id, .args = try wasm_heap.dupeOne(module, box_size) } });
    const new_box_local = try wasm_heap.storeLocal(&ctx.builder, "@click_new_box", layout.ptr_type, new_box);

    const table_index_for_store = try wasm_heap.loadLocal(&ctx.builder, table_index_local, layout.idx_type);
    const new_box_for_table = try wasm_heap.loadLocal(&ctx.builder, new_box_local, layout.ptr_type);
    try ctx.builder.emit(.{ .mem_store = .{ .addr = new_box_for_table, .src = table_index_for_store } });

    const env_for_store = try wasm_heap.loadLocal(&ctx.builder, promoted_env_local, layout.ptr_type);
    const four2 = try wasm_heap.addressConst(&ctx.builder, layout.idx_type, 4);
    const new_box_for_env_addr = try wasm_heap.loadLocal(&ctx.builder, new_box_local, layout.ptr_type);
    const env_field_addr = try wasm_heap.binOp(&ctx.builder, layout.idx_type, .add, new_box_for_env_addr, four2);
    try ctx.builder.emit(.{ .mem_store = .{ .addr = env_field_addr, .src = env_for_store } });

    return try wasm_heap.loadLocal(&ctx.builder, new_box_local, layout.ptr_type);
}

// `DOM.на_клик(selector, обработчик)` сознательно требует, чтобы
// аргумент обработчика был литеральным выражением `.lambda` ПРЯМО НА
// МЕСТЕ ВЫЗОВА (не произвольным значением типа замыкания откуда-то ещё)
// — именно это делает список захватов статически инспектируемым здесь
// через `lambda_captures`.
fn lowerDomClickClosure(ctx: *LoweringContext, call: anytype) anyerror!ExprOutcome {
    if (call.arguments.len != 2) return ctx.unsupported("DOM.на_клик() ожидает 2 аргумента");
    const handler_expr = call.arguments[1];
    switch (ctx.tree.expr(handler_expr).*) {
        .lambda => {},
        else => return ctx.unsupported("DOM.на_клик() ожидает лямбда-выражение непосредственно на месте вызова"),
    }
    const handler_type = ctx.checked.expression_types.get(handler_expr) orelse return ctx.unsupported("DOM.на_клик(): не удалось определить тип обработчика");
    const handler_signature = switch ((ctx.checked.types.get(handler_type) orelse return ctx.unsupported("DOM.на_клик(): неизвестный тип обработчика")).*) {
        .function => |function| function,
        else => return ctx.unsupported("DOM.на_клик(): обработчик не является функцией"),
    };
    if (handler_signature.parameters.len != 1) return ctx.unsupported("DOM.на_клик(): обработчик должен принимать DOM.СобытиеКлика");
    const event_type = handler_signature.parameters[0];
    const captures = ctx.resolution.lambda_captures.get(handler_expr) orelse &.{};
    for (captures) |capture_symbol| {
        const capture_type = ctx.checked.symbol_types.get(capture_symbol) orelse ctx.checked.types.builtins.void;
        // Захваченному `Процесс` нужно, чтобы его базовый фрейм был
        // выделен в ПОСТОЯННОЙ памяти — помечаем это для последующего
        // чтения `expandSpawn` в `wasm_actors.zig`; `.process => .scalar`
        // в `classifyCaptureDepth` уже трактует сам захват как обычное
        // копирование указателя, безопасное, как только этот флаг делает
        // базовую аллокацию постоянной.
        if (isProcessCapture(ctx.checked, capture_type)) {
            ctx.builder.module.actor_captured_by_dom_closure = true;
        }
        if (classifyCapture(ctx.checked, capture_type) == .unsupported) {
            return ctx.unsupported("DOM.на_клик(): захват рекурсивного/обобщённого агрегата или иного неподдержанного типа");
        }
    }

    const layout = wasm_heap.PtrLayout{
        .ptr_type = ctx.checked.types.builtins.string,
        .idx_type = ctx.checked.types.builtins.boolean,
        .bool_type = ctx.checked.types.builtins.boolean,
    };

    // Сохраняем порядок вычисления как в исходнике: сначала селектор,
    // затем обработчик. Оба результата пересекают возможный `if/else`
    // промоушена, поэтому храним их в настоящих MIR-локалях и заново
    // загружаем смежно непосредственно перед вызовом builtin. Голый
    // ValueId — это одноразовое стековое значение и не может безопасно
    // пережить эту ветку.
    const selector_outcome = try lowerExpr(ctx, call.arguments[0]);
    if (selector_outcome.flow == .terminates) return terminated;
    const selector_local = try wasm_heap.storeLocal(&ctx.builder, "@click_selector", ctx.checked.types.builtins.string, selector_outcome.value);

    const handler_outcome = try lowerExpr(ctx, handler_expr);
    if (handler_outcome.flow == .terminates) return terminated;

    _ = try findOrBuildInvokeClickTrampoline(ctx.allocator, ctx.builder.module, &ctx.checked.types, layout, event_type);
    const promoted_box = try promoteClosureBoxToPermanent(ctx, layout, handler_outcome.value, captures, 0);
    const promoted_box_local = try wasm_heap.storeLocal(&ctx.builder, "@click_promoted_box", layout.ptr_type, promoted_box);

    const selector_for_call = try wasm_heap.loadLocal(&ctx.builder, selector_local, ctx.checked.types.builtins.string);
    const promoted_box_for_call = try wasm_heap.loadLocal(&ctx.builder, promoted_box_local, layout.ptr_type);

    const arena = ctx.builder.module.arena.allocator();
    var args: std.ArrayList(mir.ValueId) = .empty;
    try args.append(arena, selector_for_call);
    try args.append(arena, promoted_box_for_call);
    try ctx.builder.emit(.{ .call_builtin = .{ .dst = null, .name = "DOM::на_клик", .args = try args.toOwnedSlice(arena) } });
    return continuesWith(mir.invalid_value);
}

fn lowerDomBuiltinCall(ctx: *LoweringContext, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const symbol = ctx.resolution.expr_symbols.get(call.callee) orelse return null;
    const entry = ctx.resolution.symbols.get(symbol) orelse return null;
    if (entry.kind != .builtin or entry.module_path == null or !std.mem.eql(u8, entry.module_path.?, "DOM")) return null;

    const property = ctx.tree.expr(call.callee).property;
    if (std.mem.eql(u8, property.property, "на_клик")) {
        return try lowerDomClickClosure(ctx, call);
    }
    const name = if (std.mem.eql(u8, property.property, "текст"))
        "DOM::текст"
    else if (std.mem.eql(u8, property.property, "установить_текст"))
        "DOM::установить_текст"
    else if (std.mem.eql(u8, property.property, "текст_строка"))
        "DOM::текст_строка"
    else if (std.mem.eql(u8, property.property, "установить_текст_строка"))
        "DOM::установить_текст_строка"
    else if (std.mem.eql(u8, property.property, "значение_поля"))
        "DOM::значение_поля"
    else if (std.mem.eql(u8, property.property, "установить_значение_поля"))
        "DOM::установить_значение_поля"
    else if (std.mem.eql(u8, property.property, "создать_и_добавить"))
        "DOM::создать_и_добавить"
    else if (std.mem.eql(u8, property.property, "после_кадра"))
        "DOM::после_кадра"
    else if (std.mem.eql(u8, property.property, "атрибут"))
        "DOM::атрибут"
    else if (std.mem.eql(u8, property.property, "установить_атрибут"))
        "DOM::установить_атрибут"
    else
        return ctx.unsupported("DOM.свойство вызов (неподдерживаемый DOM-метод)");

    var args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;

    // Аргумент-контекст `после_кадра` захватывается JS-загрузчиком СЫРЫМ
    // (`dom_after_frame` в `aot-dom-loader.js`) и передаётся обратно БЕЗ
    // ИЗМЕНЕНИЙ обработчику, вызываемому в совершенно ОТДЕЛЬНОМ, более
    // позднем экспортируемом вызове. Сброс per-call арены в
    // `wasm_gc_arena.zig` освободил бы это значение из-под JS уже на
    // следующем же событии, если бы оно оставалось в обычной арене.
    // Промоутируем (копируем) его здесь, в непересбрасываемый постоянный
    // регион, ровно в той точке, где оно вот-вот будет передано хост-
    // импорту — всё остальное продолжает идти через обычную арену, анализ
    // графа вызовов не нужен.
    const context_arg_index: ?usize = if (std.mem.eql(u8, name, "DOM::после_кадра"))
        1
    else
        null;
    if (context_arg_index) |idx| {
        const layout = wasm_heap.PtrLayout{
            .ptr_type = ctx.checked.types.builtins.string,
            .idx_type = ctx.checked.types.builtins.boolean,
            .bool_type = ctx.checked.types.builtins.boolean,
        };
        const promote_id = try wasm_heap.findOrBuildPromoteToPermanent(ctx.allocator, ctx.builder.module, &ctx.checked.types, layout);
        const promoted = try ctx.builder.newValue(layout.ptr_type);
        try ctx.builder.emit(.{ .call = .{ .dst = promoted, .callee = promote_id, .args = try wasm_heap.dupeOne(ctx.builder.module, args[idx]) } });
        const arena = ctx.builder.module.arena.allocator();
        const new_args = try arena.dupe(mir.ValueId, args);
        new_args[idx] = promoted;
        args = new_args;
    }

    const is_void = ctx.checked.types.eql(result_type, ctx.checked.types.builtins.void);
    if (is_void) {
        try ctx.builder.emit(.{ .call_builtin = .{ .dst = null, .name = name, .args = args } });
        return continuesWith(mir.invalid_value);
    }
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .call_builtin = .{ .dst = dst, .name = name, .args = args } });
    return continuesWith(dst);
}

// `состояние.прочитать`/`.записать` — Model, удерживаемая JS-загрузчиком
// (переменная-замыкание `heldModel` в `aot-dom-loader.js`), а НЕ атрибут
// DOM. В отличие от аргумента-контекста `после_кадра`, здесь НИЧЕГО не
// нуждается в `wasm_heap.findOrBuildPromoteToPermanent` — значение всегда
// проходит как полная побайтовая КОПИЯ через `readString`/`writeString`
// на стороне JS (никогда как сырой указатель, который JS удерживает
// между вызовами), поэтому оно автоматически безопасно под сбросом
// per-call арены в `wasm_gc_arena.zig` без специальной обработки.
fn lowerStateBuiltinCall(ctx: *LoweringContext, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const symbol = ctx.resolution.expr_symbols.get(call.callee) orelse return null;
    const entry = ctx.resolution.symbols.get(symbol) orelse return null;
    if (entry.kind != .builtin or entry.module_path == null or !std.mem.eql(u8, entry.module_path.?, "состояние")) return null;

    const property = ctx.tree.expr(call.callee).property;
    const name = if (std.mem.eql(u8, property.property, "прочитать"))
        "состояние::прочитать"
    else if (std.mem.eql(u8, property.property, "записать"))
        "состояние::записать"
    else
        return ctx.unsupported("состояние.свойство вызов (неподдерживаемый метод)");

    const args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
    const is_void = ctx.checked.types.eql(result_type, ctx.checked.types.builtins.void);
    if (is_void) {
        try ctx.builder.emit(.{ .call_builtin = .{ .dst = null, .name = name, .args = args } });
        return continuesWith(mir.invalid_value);
    }
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .call_builtin = .{ .dst = dst, .name = name, .args = args } });
    return continuesWith(dst);
}

fn lowerCallArgs(ctx: *LoweringContext, expressions: []const ast.ExprId) anyerror!?[]const mir.ValueId {
    // Выделяется в арене — этот срез хранится постоянно внутри
    // инструкции `call_value`, в отличие от временных значений на
    // `ctx.allocator`, которые освобождаются в рамках этого вызова.
    const arena = ctx.builder.module.arena.allocator();
    var args: std.ArrayList(mir.ValueId) = .empty;
    for (expressions) |expression| {
        const outcome = try lowerExpr(ctx, expression);
        if (outcome.flow == .terminates) return null;
        try args.append(arena, outcome.value);
    }
    return try args.toOwnedSlice(arena);
}

fn emitCallValue(ctx: *LoweringContext, callee: mir.ValueId, args: []const mir.ValueId, result_type: types.TypeId) anyerror!ExprOutcome {
    if (!ctx.checked.types.eql(result_type, ctx.checked.types.builtins.void)) {
        const dst = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .call_value = .{ .dst = dst, .callee = callee, .args = args } });
        return continuesWith(dst);
    }
    try ctx.builder.emit(.{ .call_value = .{ .dst = null, .callee = callee, .args = args } });
    return continuesWith(mir.invalid_value);
}

test "lowerModule lowers a recursive arithmetic function to a valid CFG" {
    const allocator = std.testing.allocator;
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const type_checker_mod = @import("type_checker.zig");
    const source_text =
        \\функ факториал(n: Число) -> Число
        \\    если n < 2.0 тогда
        \\        1.0
        \\    иначе
        \\        n * факториал(n - 1.0)
        \\    конец
        \\конец
    ;
    var lexed = try lexer.tokenize(allocator, source_text, 0);
    defer lexed.deinit();
    var parsed = try parser.parse(allocator, lexed.tokens.items);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    var resolved = try resolver.resolve(allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker_mod.check(allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);

    var module = try lowerModule(allocator, &parsed.ast, &resolved, &checked);
    defer module.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), module.functions.items.len);
    const function = &module.functions.items[0];
    try std.testing.expectEqualStrings("факториал", function.name);
    // entry (условие) + then + else + merge — собственная 4-блочная форма
    // if-выражения, не больше (тело этой функции И ЕСТЬ if-выражение).
    try std.testing.expectEqual(@as(usize, 4), function.blocks.items.len);

    var cfg = try @import("mir_cfg.zig").computeCfgInfo(allocator, function);
    defer cfg.deinit();
    for (cfg.reachable) |reachable| try std.testing.expect(reachable);
}

test "lowerModule lowers пока into header/body/exit blocks, no back-edge when the body always returns" {
    const allocator = std.testing.allocator;
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const type_checker_mod = @import("type_checker.zig");
    // Сознательно избегает присваивания здесь, чтобы изолировать монтаж
    // блоков header/body/exit и тело, которое ЗАВЕРШАЕТСЯ (return), что
    // должно подавить обратное ребро (back-edge) цикла — см. тест с
    // аккумулятором ниже для случая обратного ребра, вызванного
    // присваиванием.
    const source_text =
        \\функ цикл_тест(n: Число) -> Число
        \\    пока n > 0.0 цикл
        \\        возврат n
        \\    конец
        \\    0.0
        \\конец
    ;
    var lexed = try lexer.tokenize(allocator, source_text, 0);
    defer lexed.deinit();
    var parsed = try parser.parse(allocator, lexed.tokens.items);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    var resolved = try resolver.resolve(allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker_mod.check(allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);

    var module = try lowerModule(allocator, &parsed.ast, &resolved, &checked);
    defer module.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), module.functions.items.len);
    const function = &module.functions.items[0];
    // entry (переход к header) + header (условие) + body (возвращает) +
    // exit (проваливается в завершающий `0`).
    try std.testing.expectEqual(@as(usize, 4), function.blocks.items.len);

    const header = function.blockConst(@enumFromInt(1));
    try std.testing.expect(header.terminator == .branch);
    const body = function.blockConst(@enumFromInt(2));
    try std.testing.expect(body.terminator == .return_value);
    const exit = function.blockConst(@enumFromInt(3));
    try std.testing.expect(exit.terminator == .return_value);
}

test "lowerModule lowers an accumulator пока loop with assignment, back-edge present" {
    const allocator = std.testing.allocator;
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const type_checker_mod = @import("type_checker.zig");
    const source_text =
        \\функ сумма_до(предел: Число) -> Число
        \\    пер итог: Число = 0.0
        \\    пер i: Число = 1.0
        \\    пока i < предел цикл
        \\        итог = итог + i
        \\        i = i + 1.0
        \\    конец
        \\    итог
        \\конец
    ;
    var lexed = try lexer.tokenize(allocator, source_text, 0);
    defer lexed.deinit();
    var parsed = try parser.parse(allocator, lexed.tokens.items);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    var resolved = try resolver.resolve(allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker_mod.check(allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);

    var module = try lowerModule(allocator, &parsed.ast, &resolved, &checked);
    defer module.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), module.functions.items.len);
    const function = &module.functions.items[0];
    // entry (переход к header) + header (условие) + body (проваливается в
    // конец, должен перейти НАЗАД к header) + exit (проваливается в
    // завершающий `итог`).
    try std.testing.expectEqual(@as(usize, 4), function.blocks.items.len);

    const body = function.blockConst(@enumFromInt(2));
    try std.testing.expect(body.terminator == .jump);
    try std.testing.expectEqual(@as(mir.BlockId, @enumFromInt(1)), body.terminator.jump.target);
}

test "DOM click closure lowers selector before handler construction" {
    const allocator = std.testing.allocator;
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const type_checker_mod = @import("type_checker.zig");
    const source_text =
        \\импорт DOM
        \\функ селектор() -> Строка
        \\    "#кнопка"
        \\конец
        \\функ обработать(id: Число) -> Пусто
        \\конец
        \\функ старт() -> Пусто
        \\    пер id: Число = 1.0
        \\    DOM.на_клик(селектор(), функ(_: DOM.СобытиеКлика) -> Пусто
        \\        обработать(id)
        \\    конец)
        \\конец
    ;
    var lexed = try lexer.tokenize(allocator, source_text, 0);
    defer lexed.deinit();
    var parsed = try parser.parse(allocator, lexed.tokens.items);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    var resolved = try resolver.resolve(allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker_mod.checkWithImportsForTarget(allocator, &parsed.ast, &resolved, &.{}, .aot_js_wasm);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);

    var module = try lowerModule(allocator, &parsed.ast, &resolved, &checked);
    defer module.deinit(allocator);
    const selector_id = wasm_heap.findFunctionByName(&module, "селектор") orelse return error.TestExpectedEqual;
    const start_id = wasm_heap.findFunctionByName(&module, "старт") orelse return error.TestExpectedEqual;
    const entry = module.functions.items[@intFromEnum(start_id)].blockConst(@enumFromInt(0));

    var selector_evaluation_index: ?usize = null;
    var closure_index: ?usize = null;
    for (entry.instructions.items, 0..) |instruction, index| {
        switch (instruction) {
            .function_ref => |function_ref| if (function_ref.function == selector_id) {
                selector_evaluation_index = index;
            },
            .build_closure => closure_index = index,
            else => {},
        }
    }
    try std.testing.expect(selector_evaluation_index != null);
    try std.testing.expect(closure_index != null);
    try std.testing.expect(selector_evaluation_index.? < closure_index.?);
}
