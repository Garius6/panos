const std = @import("std");
const ast = @import("ast.zig");
const bytecode = @import("bytecode.zig");
const compiler = @import("compiler.zig");
const diagnostic = @import("diagnostic.zig");
const module_linker = @import("module_linker.zig");
const module_loader = @import("module_loader.zig");
const prelude = @import("prelude.zig");
const resolver = @import("resolver.zig");
const symbols = @import("symbols.zig");
const target_policy = @import("target.zig");
const type_checker = @import("type_checker.zig");
const types = @import("types.zig");
const vm = @import("vm.zig");

pub const ModuleCompilation = struct {
    resolution: ?resolver.Resolution = null,
    checked: ?type_checker.CheckResult = null,
    compiled: ?compiler.CompileResult = null,

    fn deinit(self: *ModuleCompilation) void {
        if (self.compiled) |*compiled| compiled.deinit();
        if (self.checked) |*checked| checked.deinit();
        if (self.resolution) |*resolution| resolution.deinit();
        self.* = undefined;
    }
};

pub const GraphCompileResult = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    diagnostics: diagnostic.DiagnosticList = .{},
    program: bytecode.Program,
    modules: []ModuleCompilation = &.{},
    start: ?bytecode.FunctionId = null,
    nominal_identities: std.AutoHashMap(resolver.ImportedSymbolOrigin, u32),
    next_nominal_identity: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) GraphCompileResult {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .program = bytecode.Program.init(allocator),
            .nominal_identities = .init(allocator),
        };
    }

    pub fn deinit(self: *GraphCompileResult) void {
        for (self.modules) |*module| module.deinit();
        if (self.modules.len != 0) self.allocator.free(self.modules);
        self.nominal_identities.deinit();
        self.program.deinit();
        self.diagnostics.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn hasErrors(self: *const GraphCompileResult) bool {
        for (self.diagnostics.items.items) |item| {
            if (item.severity == .err) return true;
        }
        return false;
    }

    fn appendDiagnostics(self: *GraphCompileResult, items: *const diagnostic.DiagnosticList) !void {
        for (items.items.items) |item| {
            _ = try self.diagnostics.appendUnique(self.allocator, .{
                .phase = item.phase,
                .severity = item.severity,
                .span = item.span,
                .message = try self.arena.allocator().dupe(u8, item.message),
            });
        }
    }
};

const ImportContext = struct {
    allocator: std.mem.Allocator,
    imported_types: std.ArrayList(type_checker.ImportedSymbolType) = .empty,
    type_aliases: std.ArrayList(type_checker.ImportedSymbolType) = .empty,
    nominals: std.ArrayList(type_checker.ImportedNominal) = .empty,
    methods: std.ArrayList(type_checker.ImportedMethod) = .empty,
    impls: std.ArrayList(type_checker.ImportedImpl) = .empty,
    functions: std.ArrayList(compiler.ImportedFunction) = .empty,
    constants: std.ArrayList(compiler.ImportedConstant) = .empty,
    // `ImportedNominal.default_method_symbols` (когда не null) — это
    // свежая аллокация, которую делает `bridgeDefaultMethodSymbols` через
    // `self.allocator` (в отличие от большинства того, что `nominals`
    // просто ЗАИМСТВУЕТ из arena) — отслеживается здесь, чтобы `deinit`
    // реально освобождал эти массивы, а не тёк по одному на каждый
    // межмодульный интерфейс со стандартными методами.
    default_method_symbol_arrays: std.ArrayList([]const ?symbols.SymbolId) = .empty,

    fn init(allocator: std.mem.Allocator) ImportContext {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *ImportContext) void {
        for (self.default_method_symbol_arrays.items) |array| self.allocator.free(array);
        self.default_method_symbol_arrays.deinit(self.allocator);
        self.constants.deinit(self.allocator);
        self.functions.deinit(self.allocator);
        self.impls.deinit(self.allocator);
        for (self.methods.items) |method| {
            if (method.parameter_names.len != 0) self.allocator.free(method.parameter_names);
            // `translateGenericParameterBounds` всегда выделяет заново
            // (`self.allocator.dupe`, не заимствует из arena) — и внешний
            // массив параметров, и `.bounds` каждого параметра отдельно.
            if (method.generic_parameters) |parameters| {
                for (parameters) |parameter| self.allocator.free(parameter.bounds);
                self.allocator.free(parameters);
            }
        }
        self.methods.deinit(self.allocator);
        self.nominals.deinit(self.allocator);
        self.type_aliases.deinit(self.allocator);
        for (self.imported_types.items) |imported| {
            // Тот же паттерн высвобождения, что и у `self.methods` выше —
            // free-функция верхнего уровня (`jwt_извлечь[Т: ...]`) хранит
            // свои переотображённые generic-параметры здесь, не в
            // `self.methods`, и `translateGenericParameterBounds` для НЕЁ
            // тоже всегда выделяет заново (см. её же комментарий) — без
            // этой пары свободных этот путь тихо тёк на каждую
            // скомпилированную генерик-функцию, импортированную напрямую
            // (`.function`-ветка в `collect()` выше).
            if (imported.generic_parameters) |parameters| {
                for (parameters) |parameter| self.allocator.free(parameter.bounds);
                self.allocator.free(parameters);
            }
        }
        self.imported_types.deinit(self.allocator);
        self.* = undefined;
    }

    // Чеканит ЛОКАЛЬНЫЙ синтетический символ на замену каждому методу по
    // умолчанию, объявленному ИСХОДНЫМ интерфейсом (параллельно `methods`,
    // `null` там, где у метода нет реализации по умолчанию) — тот же
    // паттерн "синтетический символ + запись в `imports.functions`", что
    // уже используется в этом файле для собственных методов, только для
    // скомпилированной функции метода по умолчанию. Возвращает `null`
    // (вообще без массива), если у интерфейса нет методов по умолчанию —
    // соответствует тому, что `ImportedNominal.interface_methods` тоже
    // остаётся `null` для не-интерфейсного номинального типа.
    //
    // ПРЕДУПРЕЖДЕНИЕ будущим вызывающим: при каждом вызове чеканится
    // НОВЫЙ синтетический символ, без собственной дедупликации — оба
    // существующих вызывающих (цикл прямого импорта в `collect` и
    // `collectTransitiveNominals`) безопасны только потому, что ОБА
    // добавляют в один и тот же массив `self.nominals` и дедуплицируют
    // ПЕРЕД вызовом этой функции (`collectTransitiveNominals` явно
    // сканирует `self.nominals.items` на уже известную пару `(store,
    // source_symbol)` и возвращается раньше). Третий путь сбора данных,
    // вызывающий эту функцию без такой же предварительной проверки
    // `self.nominals`, молча начеканит дубликаты символов для одного и
    // того же интерфейса — не крах, но дублирующиеся/утекающие
    // синтетические привязки.
    fn bridgeDefaultMethodSymbols(self: *ImportContext, resolution: *resolver.Resolution, definition_compiled: *const compiler.CompileResult, methods: []const type_checker.InterfaceMethod) !?[]const ?symbols.SymbolId {
        var any_default = false;
        for (methods) |method| {
            if (method.default_symbol != null) {
                any_default = true;
                break;
            }
        }
        if (!any_default) return null;
        const result = try self.allocator.alloc(?symbols.SymbolId, methods.len);
        errdefer self.allocator.free(result);
        for (methods, result) |method, *slot| {
            const source_default = method.default_symbol orelse {
                slot.* = null;
                continue;
            };
            const function_id = definition_compiled.function_ids.get(source_default) orelse {
                slot.* = null;
                continue;
            };
            const local_symbol = try resolution.symbols.add(.{
                .name = method.name,
                .kind = .function,
                .module_path = "@transitive",
                .is_exported = true,
                .span = .{ .file_id = 0, .start = 0, .end = 0 },
            });
            try self.functions.append(self.allocator, .{ .symbol = local_symbol, .function_id = function_id });
            slot.* = local_symbol;
        }
        try self.default_method_symbol_arrays.append(self.allocator, result);
        return result;
    }

    // Ссылается ли `target` (символ внутри `impl_resolution`, поле
    // `.target` реализации интерфейса) на ТОТ ЖЕ struct/enum, что и
    // `{origin_module, origin_declaration}`? Два случая: `target` сам
    // является импортом внутри `impl_resolution` (обычный межмодульный
    // случай, включая ТРЕТИЙ файл — сравниваем origin напрямую); либо у
    // `target` вообще нет origin импорта, значит это ЛОКАЛЬНОЕ
    // объявление в собственном модуле `impl_resolution` (случай реализации
    // в том же файле) — тогда совпадение только если этот модуль И ЕСТЬ
    // `origin_module`, а `target` — именно тот символ, который для
    // `origin_declaration` начеканил резолвер этого модуля.
    fn implementationTargetMatches(impl_resolution: *const resolver.Resolution, target: symbols.SymbolId, impl_own_module: usize, origin_module: usize, origin_declaration: ast.DeclId) bool {
        if (impl_resolution.imported_symbols.get(target)) |origin| {
            return origin.module == origin_module and origin.declaration == origin_declaration;
        }
        if (impl_own_module != origin_module) return false;
        return (impl_resolution.decl_symbols.get(origin_declaration) orelse return false) == target;
    }

    // Обратный поиск — есть ли в `resolution` (какой-то ДРУГОЙ модуль, не
    // обязательно модуль реализации) локальный символ на замену
    // `{module, declaration}`? Используется, чтобы привести
    // квалифицированный ИНТЕРФЕЙС (например `json.ВJSON` из codegen) к
    // символу, которым может пользоваться ПОТРЕБЛЯЮЩИЙ модуль — поиск по
    // голому имени там ничего не найдёт (он виден только как
    // `модуль.Интерфейс`). `resolution.imported_symbols` небольшой (одна
    // запись на именованную межмодульную ссылку в файле), линейный
    // перебор здесь не является узким местом.
    fn findLocalSymbolForOrigin(resolution: *const resolver.Resolution, module: usize, declaration: ast.DeclId) ?symbols.SymbolId {
        var it = resolution.imported_symbols.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.module == module and entry.value_ptr.declaration == declaration) return entry.key_ptr.*;
        }
        return null;
    }

    // Общая для пути прямого импорта (`collect`) и транзитивного импорта
    // (`collectTransitiveNominals`) — оба одинаково пересаживают
    // реализации интерфейса для номинального типа, различаясь лишь тем,
    // из какого модуля/резолюции/целевого символа берутся исходные данные.
    //
    // `impl_export.module` (где физически написан блок `реализация`)
    // может ОТЛИЧАТЬСЯ от `origin_module` (где объявлена целевая
    // структура) — квалифицированная цель реализации в ТРЕТЬЕМ файле
    // (паттерн `_gen.ps` codegen: `реализация json.ВJSON для
    // json_fixture.Заказ`, написано не в json_fixture.ps и не в
    // потребителе). Поэтому здесь `interface_implementations` берутся из
    // результатов проверки типов СОБСТВЕННОГО модуля реализации
    // (`modules[impl_export.module]`), а не модуля цели — и
    // `implementation.target` сравнивается с `{origin_module,
    // origin_declaration}` по ORIGIN, а не по равенству `SymbolId`
    // (`implementation.target` живёт в СОБСТВЕННОЙ таблице символов
    // модуля реализации — это ДРУГОЕ пространство, чем целевой модуль
    // `origin_declaration` или вызывающий эту функцию потребляющий
    // модуль).
    fn appendMatchingImpls(
        self: *ImportContext,
        graph: *const module_loader.Graph,
        modules: []const ModuleCompilation,
        resolution: *const resolver.Resolution,
        own_module: usize,
        origin_module: usize,
        origin_declaration: ast.DeclId,
        owner_symbol: symbols.SymbolId,
    ) !void {
        for (graph.impls.items) |impl_export| {
            if (impl_export.owner_module != origin_module or impl_export.owner_declaration != origin_declaration) continue;
            // Блок `реализация`, объявленный В ЭТОМ ЖЕ модуле (`own_module`
            // — например, файл-потребитель, который импортирует структуру
            // и тут же локально реализует для неё квалифицированный
            // интерфейс), уже зарегистрирован напрямую собственным
            // `signaturePass` этого модуля (`defineInterfaceImplementation`)
            // — пересадка его ещё и здесь потребовала бы чтения
            // `modules[own_module].checked`, которого пока не существует
            // (мы СЕЙЧАС ВНУТРИ сбора для `own_module`, его `checked`
            // устанавливается только после возврата из `collect()`).
            if (impl_export.module == own_module) continue;
            const impl_module = &modules[impl_export.module];
            const impl_resolution = if (impl_module.resolution) |*value| value else return error.ImportNotCompiled;
            const impl_checked = if (impl_module.checked) |*value| value else return error.ImportNotChecked;
            for (impl_checked.interface_implementations.items) |implementation| {
                if (!implementationTargetMatches(impl_resolution, implementation.target, impl_export.module, origin_module, origin_declaration)) continue;
                const interface_symbol = impl_resolution.symbols.get(implementation.interface) orelse continue;
                if (!std.mem.eql(u8, interface_symbol.name, impl_export.interface_name)) continue;
                // Квалифицированному интерфейсу (например, `json.ВJSON` из
                // codegen) нужен ЛОКАЛЬНЫЙ символ в собственной резолюции
                // ПОТРЕБЛЯЮЩЕГО модуля, чтобы им мог пользоваться
                // `type_checker.zig` (поиск по голому имени там его не
                // найдёт — он в области видимости только как
                // `модуль.Интерфейс`, никогда без квалификации). Ищем по
                // ORIGIN, тот же принцип, что и при сравнении цели выше;
                // если потребитель сам никогда не импортирует модуль
                // интерфейса, здесь получаем `null`, и эта реализация для
                // него пропускается (деградация до "не найдено", не крах —
                // тот же паттерн пропуска-при-неразрешимости, что и по
                // всей этой функции).
                const interface_local_symbol = if (impl_export.interface_module) |interface_module|
                    findLocalSymbolForOrigin(resolution, interface_module, impl_export.interface_declaration.?) orelse continue
                else
                    null;
                try self.impls.append(self.allocator, .{
                    .owner = owner_symbol,
                    .interface_name = impl_export.interface_name,
                    .interface_symbol = interface_local_symbol,
                    .method_symbols = implementation.methods,
                    .target_resolution = impl_resolution,
                    .store = &impl_checked.types,
                    .argument_type_ids = implementation.arguments,
                });
            }
        }
    }

    // Переводит bounds генерик-параметров МЕТОДА (`получить[Ответ:
    // валидация.ОтветJSON]`) из пространства символов модуля, где физически
    // объявлен метод (`owner_resolution`), в пространство символов модуля,
    // где ФИЗИЧЕСКИ объявлен интерфейс-ограничение — двухходовой случай:
    // приложение.pns ссылается на "валидация.ОтветJSON" через СОБСТВЕННЫЙ
    // локальный символ (свой `imported_symbols`-импорт валидация.pns), а
    // главный цикл `collect()` строит `imports.nominals` для ТОГО ЖЕ
    // интерфейса через СВОЙ собственный локальный импорт (main.pns может
    // импортировать валидация.pns напрямую или транзитивно через
    // реэкспорт) — сравнение сырых SymbolId между этими двумя НИКОГДА не
    // совпадает, хотя физически это один и тот же интерфейс в одном и том
    // же модуле. Без перевода bound молча считался неудовлетворённым
    // ("полный контракт или ничего" в checkWithImportContextForTarget),
    // метод пропускался целиком — `Type Error: у типа нет поля` при
    // обычном вызове `.метод(...)`, не диагностика про несовпадение
    // ограничения.
    fn translateGenericParameterBounds(
        self: *ImportContext,
        owner_resolution: *const resolver.Resolution,
        nominal_identities: *std.AutoHashMap(resolver.ImportedSymbolOrigin, u32),
        next_nominal_identity: *u32,
        parameters: []const type_checker.GenericParameter,
    ) ![]const type_checker.GenericParameter {
        var translated: std.ArrayList(type_checker.GenericParameter) = .empty;
        defer translated.deinit(self.allocator);
        for (parameters) |parameter| {
            var bounds: std.ArrayList(symbols.SymbolId) = .empty;
            defer bounds.deinit(self.allocator);
            for (parameter.bounds) |bound| {
                // Сырое сравнение SymbolId между модулями небезопасно — это
                // per-модульный индекс, не глобально уникальный (символ #1
                // существует почти в КАЖДОМ модуле). identity —
                // единственный УЖЕ существующий механизм, однозначно
                // связывающий origin{module, declaration} с конкретным
                // ImportedNominal независимо от того, через сколько
                // хопов/алиасов до него дошли — тот же механизм, что уже
                // используют интерфейсы (см. checkWithImportContextForTarget).
                const translated_bound = blk: {
                    const origin = owner_resolution.imported_symbols.get(bound) orelse break :blk bound;
                    const identity = nominalIdentity(nominal_identities, next_nominal_identity, origin) catch break :blk bound;
                    for (self.nominals.items) |nominal| {
                        if (nominal.identity == identity) break :blk nominal.local_symbol;
                    }
                    break :blk bound;
                };
                try bounds.append(self.allocator, translated_bound);
            }
            try translated.append(self.allocator, .{
                .name = parameter.name,
                .typ = parameter.typ,
                .bounds = try self.allocator.dupe(symbols.SymbolId, bounds.items),
            });
        }
        return self.allocator.dupe(type_checker.GenericParameter, translated.items);
    }

    // Пересаживает КОНКРЕТНЫЕ (не интерфейсные) методы для `owner_symbol`
    // — аналог `appendMatchingImpls` выше для `graph.methods` (та же
    // схема "сканировать ВЕСЬ граф по owner_module/owner_declaration, а
    // не только собственные импорты `own_module`", поскольку `реализация
    // X для Модуль.Тип` может находиться в ТРЕТЬЕМ файле относительно и
    // собственного модуля типа, и любого потребителя — паттерн `_gen.ps`
    // codegen).
    //
    // Нужна вместе с `appendMatchingImpls` (а не вместо неё), потому что
    // номинальный тип, достигнутый ТОЛЬКО ТРАНЗИТИВНО — через поле или
    // тип возврата другого модуля, никогда не названный/импортированный
    // напрямую `own_module` — раньше получал пересадку методов ТОЛЬКО из
    // `definition_checked.methods` (результатов проверки типов
    // СОБСТВЕННОГО объявляющего модуля типа), где могут быть только блоки
    // `реализация` В ТОМ ЖЕ ФАЙЛЕ: объявляющий модуль никогда не
    // импортирует свой собственный аналог `_gen.ps`, поэтому присоединение
    // метода из третьего файла было для него невидимо.
    fn appendMatchingMethods(
        self: *ImportContext,
        graph: *const module_loader.Graph,
        modules: []const ModuleCompilation,
        resolution: *resolver.Resolution,
        nominal_identities: *std.AutoHashMap(resolver.ImportedSymbolOrigin, u32),
        next_nominal_identity: *u32,
        own_module: usize,
        origin_module: usize,
        origin_declaration: ast.DeclId,
        owner_symbol: symbols.SymbolId,
    ) !void {
        for (graph.methods.items) |method_export| {
            if (method_export.owner_module != origin_module or method_export.owner_declaration != origin_declaration) continue;
            // То же основание, что и у идентичной проверки в
            // `appendMatchingImpls` — метод, объявленный В САМОМ
            // `own_module`, уже является обычным локальным объявлением
            // там, пересаживать нечего (а `modules[own_module].checked`/
            // `.compiled` ещё не существуют, пока `own_module` всё ещё
            // собирается).
            if (method_export.module == own_module) continue;
            const method_module = &modules[method_export.module];
            const method_resolution = if (method_module.resolution) |*value| value else return error.ImportNotCompiled;
            const method_checked = if (method_module.checked) |*value| value else return error.ImportNotChecked;
            const method_compiled = if (method_module.compiled) |*value| value else return error.ImportNotCompiled;
            const source_method_symbol = method_resolution.decl_symbols.get(method_export.declaration) orelse continue;
            const source_method = method_resolution.symbols.get(source_method_symbol) orelse continue;
            const function_id = method_compiled.function_ids.get(source_method_symbol) orelse continue;
            const signature = method_checked.symbol_types.get(source_method_symbol) orelse continue;
            const local_method = try resolution.symbols.add(.{
                .name = source_method.name,
                .kind = .function,
                .module_path = "@transitive",
                .is_exported = true,
                .span = source_method.span,
            });
            const parameters = method_resolution.function_parameters.get(method_export.declaration) orelse &.{};
            const parameter_names: []const []const u8 = if (parameters.len == 0) &.{} else blk: {
                const names = try self.allocator.alloc([]const u8, parameters.len);
                for (parameters, names) |parameter, *name| name.* = method_resolution.symbols.get(parameter).?.name;
                break :blk names;
            };
            // Собственные generic-параметры МЕТОДА (не владельца-структуры)
            // — `отправить_пост[Тело: ИзJSON, ...]` — переносятся отдельно
            // от `signature`/`store` выше (см. `ImportedMethod.
            // generic_parameters`'s doc-комментарий: без этого `Тело`,
            // встреченный ВНУТРИ типа параметра типа функции, молча
            // вырождался в `poison` при импорте).
            var method_generic_parameters: ?[]const type_checker.GenericParameter = null;
            for (method_checked.methods.items) |definition| {
                if (definition.symbol == source_method_symbol and definition.function_parameters.len != 0) {
                    method_generic_parameters = try self.translateGenericParameterBounds(method_resolution, nominal_identities, next_nominal_identity, definition.function_parameters);
                    break;
                }
            }
            try self.methods.append(self.allocator, .{
                .owner = owner_symbol,
                .name = source_method.name,
                .symbol = local_method,
                .store = &method_checked.types,
                .type_id = signature,
                .parameter_names = parameter_names,
                .generic_parameters = method_generic_parameters,
            });
            try self.functions.append(self.allocator, .{ .symbol = local_method, .function_id = function_id });
        }
    }

    fn collect(
        self: *ImportContext,
        resolution: *resolver.Resolution,
        modules: []const ModuleCompilation,
        nominal_identities: *std.AutoHashMap(resolver.ImportedSymbolOrigin, u32),
        next_nominal_identity: *u32,
        graph: *const module_loader.Graph,
        own_module: usize,
    ) !void {
        // `Результат`/`Опция` — типы прелюдии: КАЖДЫЙ модуль получает
        // СВОЙ собственный свежечеканенный символ для них (встроенный
        // исходник прелюдии подмешивается без квалификации в резолюцию
        // каждого файла, см. `predeclareUnqualifiedImport` в
        // `resolver.zig`), поэтому тип экспортируемой функции/поля,
        // ссылающийся на "Результат исходного модуля", структурно не
        // связан с "Результат этого модуля" с точки зрения ветки
        // `.nominal` в `copyImportedType` — это не НАСТОЯЩИЙ межмодульный
        // импорт (`resolution.imported_symbols` его не содержит), так что
        // ничего их не связывает. Мостик строится ОДИН РАЗ на каждый
        // отдельный целевой модуль, из которого этот файл реально что-то
        // импортирует: собственный символ `Результат`/`Опция` того
        // модуля → собственный символ `Результат`/`Опция` ЭТОГО модуля, с
        // `identity = 0`, чтобы сравнение номинальных типов в
        // `TypeStore.eql` откатилось к прямому сравнению символов — точно
        // так же, как уже происходит при чисто ЛОКАЛЬНОМ (никогда не
        // импортированном) использовании `Результат` в этом же файле.
        var bridged_modules: std.AutoHashMap(usize, void) = .init(self.allocator);
        defer bridged_modules.deinit();

        var imported_symbols = resolution.imported_symbols.iterator();
        while (imported_symbols.next()) |entry| {
            const imported_symbol = entry.key_ptr.*;
            const origin = entry.value_ptr.*;
            try bridged_modules.put(origin.module, {});
            const exported = resolution.symbols.get(imported_symbol) orelse continue;
            const target = &modules[origin.module];
            const target_resolution = if (target.resolution) |*value| value else return error.ImportNotCompiled;
            const target_checked = if (target.checked) |*value| value else return error.ImportNotChecked;
            const target_compiled = if (target.compiled) |*value| value else return error.ImportNotCompiled;
            const target_symbol = target_resolution.decl_symbols.get(origin.declaration) orelse continue;

            switch (exported.kind) {
                .type => {
                    // ПСЕВДОНИМ ТИПА (`тип Обработчик = функ(Число) ->
                    // Число`) — это вообще не номинальный тип: нет полей/
                    // вариантов перечисления/методов интерфейса,
                    // `target_checked.enum_definitions`/
                    // `generic_nominal_fields`/`interface_definitions` для
                    // него корректно равны null, поэтому блок пересадки
                    // номинального типа ниже начеканил бы ПУСТОЙ непрозрачный
                    // номинальный тип без пригодной формы. Вместо этого
                    // пересаживаем его как псевдоним — `target_checked.
                    // type_aliases` к этому моменту всегда заполнен для
                    // каждого объявленного псевдонима (`eagerAliasResolutionPass`
                    // в `type_checker.zig`, выполняется принудительно
                    // независимо от того, ссылается ли ОБЪЯВЛЯЮЩИЙ модуль
                    // на свой псевдоним локально).
                    if (target_checked.type_aliases.get(target_symbol)) |aliased_type| {
                        try self.type_aliases.append(self.allocator, .{
                            .symbol = imported_symbol,
                            .store = &target_checked.types,
                            .type_id = aliased_type,
                        });
                        continue;
                    }
                    const identity = if (isPreludeTypeName(exported.name)) 0 else try nominalIdentity(nominal_identities, next_nominal_identity, origin);
                    const enum_definition = target_checked.enum_definitions.get(target_symbol);
                    const generic_struct = target_checked.generic_nominal_fields.get(target_symbol);
                    const interface_definition = target_checked.interface_definitions.get(target_symbol);
                    const generic_parameters: ?[]const type_checker.GenericParameter = if (generic_struct) |value|
                        value.parameters
                    else if (enum_definition) |value|
                        (if (value.parameters.len != 0) value.parameters else null)
                    else if (interface_definition) |value|
                        (if (value.parameters.len != 0) value.parameters else null)
                    else
                        null;
                    const fields = if (generic_struct) |value| value.fields else target_checked.nominal_fields.get(target_symbol);
                    const enum_variants = if (enum_definition) |value| value.variants else null;
                    const interface_methods = if (interface_definition) |value| value.methods else null;
                    const default_method_symbols = if (interface_methods) |value| try self.bridgeDefaultMethodSymbols(resolution, target_compiled, value) else null;
                    try self.nominals.append(self.allocator, .{
                        .store = &target_checked.types,
                        .definition_store = &target_checked.types,
                        .source_symbol = target_symbol,
                        .local_symbol = imported_symbol,
                        .identity = identity,
                        .fields = fields,
                        .enum_variants = enum_variants,
                        .generic_parameters = generic_parameters,
                        .interface_methods = interface_methods,
                        .default_method_symbols = default_method_symbols,
                    });
                    try self.appendMatchingImpls(graph, modules, resolution, own_module, origin.module, origin.declaration, imported_symbol);
                },
                .function => {
                    const signature = target_checked.symbol_types.get(target_symbol) orelse continue;
                    const function_id = target_compiled.function_ids.get(target_symbol) orelse continue;
                    // Тот же двухходовой перевод bounds, что уже применяется
                    // к МЕТОДАМ ниже (`translateGenericParameterBounds`,
                    // см. её doc-комментарий) — без него генерик-ограничение
                    // свободной функции (`jwt_извлечь[Т: валидация.ТелоJSON]`),
                    // объявленное в ТРЕТЬЕМ модуле относительно и функции, и
                    // потребителя, сравнивалось по сырому SymbolId и никогда
                    // не совпадало с собственным импортом потребителя того
                    // же интерфейса — "полный контракт или ничего" молча
                    // помечало функцию unsupported (`Type Error:
                    // импортированный экспорт '...' использует пока
                    // неподдерживаемый тип`) при первом же вызове.
                    const raw_generic_parameters = target_checked.generic_function_parameters.get(target_symbol);
                    const translated_generic_parameters = if (raw_generic_parameters) |value|
                        try self.translateGenericParameterBounds(target_resolution, nominal_identities, next_nominal_identity, value)
                    else
                        null;
                    try self.imported_types.append(self.allocator, .{
                        .symbol = imported_symbol,
                        .store = &target_checked.types,
                        .type_id = signature,
                        .generic_parameters = translated_generic_parameters,
                    });
                    try self.functions.append(self.allocator, .{
                        .symbol = imported_symbol,
                        .function_id = function_id,
                    });
                },
                .constant => {
                    const signature = target_checked.symbol_types.get(target_symbol) orelse continue;
                    const value = target_compiled.top_level_constants.get(target_symbol) orelse continue;
                    try self.imported_types.append(self.allocator, .{
                        .symbol = imported_symbol,
                        .store = &target_checked.types,
                        .type_id = signature,
                    });
                    try self.constants.append(self.allocator, .{
                        .symbol = imported_symbol,
                        .value = value,
                    });
                },
                else => {},
            }
        }
        for (resolution.imported_methods.items) |binding| {
            try bridged_modules.put(binding.origin.module, {});
            const target = &modules[binding.origin.module];
            const target_resolution = if (target.resolution) |*value| value else return error.ImportNotCompiled;
            const target_checked = if (target.checked) |*value| value else return error.ImportNotChecked;
            const target_compiled = if (target.compiled) |*value| value else return error.ImportNotCompiled;
            const target_symbol = target_resolution.decl_symbols.get(binding.origin.declaration) orelse continue;
            const signature = target_checked.symbol_types.get(target_symbol) orelse continue;
            const function_id = target_compiled.function_ids.get(target_symbol) orelse continue;
            const parameters = target_resolution.function_parameters.get(binding.origin.declaration) orelse &.{};
            const parameter_names: []const []const u8 = if (parameters.len == 0) &.{} else blk: {
                const names = try self.allocator.alloc([]const u8, parameters.len);
                for (parameters, names) |parameter, *name| name.* = target_resolution.symbols.get(parameter).?.name;
                break :blk names;
            };
            // См. идентичный комментарий в `appendMatchingMethods` —
            // собственные generic-параметры МЕТОДА (не владельца-структуры)
            // теряются без этого при прямом импорте (это ТОТ путь, что
            // реально используется для `объект.метод(...)`, в отличие от
            // `appendMatchingMethods`, который только для транзитивного
            // ре-экспорта через промежуточный модуль).
            var method_generic_parameters: ?[]const type_checker.GenericParameter = null;
            for (target_checked.methods.items) |definition| {
                if (definition.symbol == target_symbol and definition.function_parameters.len != 0) {
                    method_generic_parameters = try self.translateGenericParameterBounds(target_resolution, nominal_identities, next_nominal_identity, definition.function_parameters);
                    break;
                }
            }
            try self.methods.append(self.allocator, .{
                .owner = binding.owner,
                .name = binding.name,
                .symbol = binding.symbol,
                .store = &target_checked.types,
                .type_id = signature,
                .parameter_names = parameter_names,
                .generic_parameters = method_generic_parameters,
            });
            try self.functions.append(self.allocator, .{
                .symbol = binding.symbol,
                .function_id = function_id,
            });
        }

        // У каждого модуля отдельно разрешённые символы прелюдии.
        // Пересаживаем все типы прелюдии, которые могут встретиться в
        // экспортируемой сигнатуре или generic-ограничении; иначе
        // импортированный, например, `[T: Сравниваемое]` молча теряет своё
        // ограничение, потому что исходный SymbolId нельзя сравнить с
        // локальным SymbolId импортёра.
        var touched = bridged_modules.keyIterator();
        while (touched.next()) |module_index_ptr| {
            const target = &modules[module_index_ptr.*];
            const target_resolution = if (target.resolution) |*value| value else return error.ImportNotCompiled;
            const target_checked = if (target.checked) |*value| value else return error.ImportNotChecked;
            for (prelude_type_names) |name| {
                const source_symbol = findLocalTypeSymbol(target_resolution, name, null) orelse continue;
                const local_symbol = findLocalTypeSymbol(resolution, name, null) orelse continue;
                // Намеренно только identity — запись с полными данными
                // (как в обычном межмодульном случае `.type` выше) была
                // бы ДУБЛИРУЮЩЕЙ регистрацией: раз в графе есть настоящий
                // модуль прелюдии, собственная копия `Опция`/
                // `Сравниваемое`/... этого модуля уже полностью
                // заполняется через обычный цикл
                // `resolution.imported_symbols` выше (они импортированы
                // без квалификации из модуля прелюдии, как любой
                // настоящий `импорт`) — вторая полная запись для того же
                // `local_symbol` здесь перезаписала бы первую в
                // `owner_remaps` и привела бы к утечке. Этот цикл
                // существует ТОЛЬКО чтобы выровнять собственную отдельную
                // копию ТРЕТЬЕГО модуля (`target`) с этой для сравнения
                // сигнатур/ограничений — чистая identity, без данных.
                try self.nominals.append(self.allocator, .{
                    .store = &target_checked.types,
                    .definition_store = &target_checked.types,
                    .source_symbol = source_symbol,
                    .local_symbol = local_symbol,
                    .identity = 0,
                });
            }
        }

        // Публичная сигнатура может содержать номинальный тип из
        // зависимости напрямую импортированного модуля. У него нет имени
        // в исходнике этого модуля, но всё равно нужен ЛОКАЛЬНЫЙ
        // представитель: поля и методы в checker'е ключуются по SymbolId,
        // а TypeId никогда не должен покидать свой владеющий TypeStore.
        // Пересаживаем полное достижимое замыкание номинальных типов
        // прежде, чем importSignaturePass скопирует хоть одну сигнатуру.
        var nominal_index: usize = 0;
        while (nominal_index < self.nominals.items.len) : (nominal_index += 1) {
            const imported = self.nominals.items[nominal_index];
            if (imported.fields) |fields| {
                for (fields) |field| {
                    try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, graph, own_module, imported.definition_store, field.typ);
                }
            }
            if (imported.enum_variants) |variants| {
                for (variants) |variant| {
                    for (variant.fields) |field| {
                        try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, graph, own_module, imported.definition_store, field);
                    }
                }
            }
            if (imported.interface_methods) |methods| {
                for (methods) |method| {
                    for (method.parameters) |parameter| {
                        try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, graph, own_module, imported.definition_store, parameter);
                    }
                    try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, graph, own_module, imported.definition_store, method.return_type);
                }
            }
        }
        var imported_type_index: usize = 0;
        while (imported_type_index < self.imported_types.items.len) : (imported_type_index += 1) {
            const imported = self.imported_types.items[imported_type_index];
            try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, graph, own_module, imported.store, imported.type_id);
        }
        // По индексу, перечитывая `self.methods.items` заново на каждой
        // итерации — НЕ `for (self.methods.items) |method|`, который
        // захватывает фиксированный срез. Транзитивно обнаруженный
        // номинальный тип с СОБСТВЕННЫМИ методами (ниже, ветка
        // `.nominal`) добавляет ЕЩЁ записи в этот же список изнутри этого
        // же цикла — захваченный срез продолжил бы обход СТАРОГО
        // массива после того, как `ArrayList.append` его переаллоцирует,
        // то есть обход освобождённой памяти.
        var method_index: usize = 0;
        while (method_index < self.methods.items.len) : (method_index += 1) {
            const method = self.methods.items[method_index];
            try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, graph, own_module, method.store, method.type_id);
        }
    }

    fn collectTransitiveNominals(
        self: *ImportContext,
        resolution: *resolver.Resolution,
        modules: []const ModuleCompilation,
        nominal_identities: *std.AutoHashMap(resolver.ImportedSymbolOrigin, u32),
        next_nominal_identity: *u32,
        graph: *const module_loader.Graph,
        own_module: usize,
        external_store: *const types.TypeStore,
        external_type: types.TypeId,
    ) !void {
        const entry = external_store.get(external_type) orelse return error.InvalidImportedType;
        switch (entry.*) {
            .tuple => |elements| for (elements) |element| try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, graph, own_module, external_store, element),
            .function => |function| {
                for (function.parameters) |parameter| try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, graph, own_module, external_store, parameter);
                try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, graph, own_module, external_store, function.return_type);
            },
            .nominal => |nominal| {
                for (nominal.arguments) |argument| try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, graph, own_module, external_store, argument);
                for (self.nominals.items) |known| {
                    if (known.store == external_store and known.source_symbol == nominal.symbol) return;
                }
                const reference_module = moduleForTypeStore(modules, external_store) orelse return error.UnsupportedImportedType;
                const target = &modules[reference_module];
                const target_resolution = if (target.resolution) |*value| value else return error.ImportNotCompiled;
                const origin: resolver.ImportedSymbolOrigin = target_resolution.imported_symbols.get(nominal.symbol) orelse blk: {
                    const declaration = declarationForSymbol(target_resolution, nominal.symbol);
                    if (declaration) |value| break :blk .{ .module = reference_module, .declaration = value };
                    // Встроенные типы, устанавливаемые резолвером, не
                    // имеют AST-объявления и существуют независимо в
                    // каждом модуле. Пересаживаем их по имени, как и типы
                    // прелюдии; их операции распознаются локальным
                    // checker'ом.
                    const source_symbol = target_resolution.symbols.get(nominal.symbol) orelse return error.UnsupportedImportedType;
                    const local_symbol = findLocalTypeSymbol(resolution, source_symbol.name, source_symbol.module_path) orelse return error.UnsupportedImportedType;
                    try self.nominals.append(self.allocator, .{
                        .store = external_store,
                        .definition_store = external_store,
                        .source_symbol = nominal.symbol,
                        .local_symbol = local_symbol,
                        .identity = 0,
                    });
                    return;
                };
                const definition = &modules[origin.module];
                const definition_resolution = if (definition.resolution) |*value| value else return error.ImportNotCompiled;
                const definition_checked = if (definition.checked) |*value| value else return error.ImportNotChecked;
                const definition_compiled = if (definition.compiled) |*value| value else return error.ImportNotCompiled;
                const definition_symbol = definition_resolution.decl_symbols.get(origin.declaration) orelse return error.UnsupportedImportedType;
                const source_symbol = definition_resolution.symbols.get(definition_symbol) orelse return error.UnsupportedImportedType;
                const local_symbol = try resolution.symbols.add(.{
                    .name = source_symbol.name,
                    .kind = .type,
                    .module_path = "@transitive",
                    .is_exported = true,
                    .span = source_symbol.span,
                });
                // Записываем мостик и в `imported_symbols` этого модуля,
                // не только в `self.nominals` (видимый только ВНУТРИ этого
                // прохода `collect()`) — иначе ВТОРОЙ, независимый
                // потребитель (например, модуль, импортирующий И этот
                // модуль напрямую, И ещё один модуль, который транзитивно
                // ссылается на этот же номинальный тип через сигнатуру
                // функции этого модуля) не находит происхождение при
                // СВОЁМ собственном `collectTransitiveNominals`-обходе
                // (строка ниже, `target_resolution.imported_symbols.get`)
                // — символ технически never `импорт`-ирован буквально,
                // только структурно унаследован, поэтому без этой записи
                // резолвер ошибочно принимал бы его за builtin-тип без
                // AST-объявления (тот же fallback, что для `Массив`/
                // `Запрос` выше) и не находил бы одноимённый ЛОКАЛЬНЫЙ
                // символ у ВТОРОГО потребителя — `UnsupportedImportedType`
                // на совершенно валидной программе (найдено вживую:
                // `быстряга`'s `авторизация.pns` транзитивно ссылается на
                // `http.ОтветСервера` через `приложение.Middleware`, а
                // потребитель, импортирующий и `приложение.pns`, и
                // `авторизация.pns` напрямую, ловил эту ошибку).
                try resolution.imported_symbols.put(local_symbol, origin);
                const identity = try nominalIdentity(nominal_identities, next_nominal_identity, origin);
                const enum_definition = definition_checked.enum_definitions.get(definition_symbol);
                const generic_struct = definition_checked.generic_nominal_fields.get(definition_symbol);
                const interface_definition = definition_checked.interface_definitions.get(definition_symbol);
                const generic_parameters: ?[]const type_checker.GenericParameter = if (generic_struct) |value|
                    value.parameters
                else if (enum_definition) |value|
                    (if (value.parameters.len != 0) value.parameters else null)
                else if (interface_definition) |value|
                    (if (value.parameters.len != 0) value.parameters else null)
                else
                    null;
                const transitive_interface_methods = if (interface_definition) |value| value.methods else null;
                const transitive_default_method_symbols = if (transitive_interface_methods) |value| try self.bridgeDefaultMethodSymbols(resolution, definition_compiled, value) else null;
                try self.nominals.append(self.allocator, .{
                    .store = external_store,
                    .definition_store = &definition_checked.types,
                    .source_symbol = nominal.symbol,
                    .local_symbol = local_symbol,
                    .identity = identity,
                    .fields = if (generic_struct) |value| value.fields else definition_checked.nominal_fields.get(definition_symbol),
                    .enum_variants = if (enum_definition) |value| value.variants else null,
                    .generic_parameters = generic_parameters,
                    .interface_methods = transitive_interface_methods,
                    .default_method_symbols = transitive_default_method_symbols,
                });
                // Тот же мостик, что и цикл прямого импорта выше строит
                // для символа, достигнутого через
                // `resolution.imported_symbols` — номинальный тип,
                // достигнутый ТОЛЬКО транзитивно (через сигнатуру другой
                // функции, никогда не названный/импортированный напрямую),
                // без этого получал бы пересадку только СТРУКТУРНОЙ формы
                // (поля/методы, чуть выше), но никогда — РЕАЛИЗАЦИЙ
                // ИНТЕРФЕЙСА, поскольку вся эта ветка `.nominal` вообще
                // не обращалась к `graph.impls`.
                try self.appendMatchingImpls(graph, modules, resolution, own_module, origin.module, origin.declaration, local_symbol);
                // Сканирование всего `graph.methods` (а не только
                // `definition_checked.methods`, где видны только блоки
                // `реализация` В ТОМ ЖЕ ФАЙЛЕ — собственный объявляющий
                // модуль типа никогда не импортирует свой аналог
                // `_gen.ps` в третьем файле) — см. doc-комментарий
                // `appendMatchingMethods`.
                try self.appendMatchingMethods(graph, modules, resolution, nominal_identities, next_nominal_identity, own_module, origin.module, origin.declaration, local_symbol);
            },
            .array => |element| try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, graph, own_module, external_store, element),
            .map => |map| {
                try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, graph, own_module, external_store, map.key);
                try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, graph, own_module, external_store, map.value);
            },
            .process => |message| try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, graph, own_module, external_store, message),
            .pointer => |pointee| try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, graph, own_module, external_store, pointee),
            else => {},
        }
    }
};

fn moduleForTypeStore(modules: []const ModuleCompilation, store: *const types.TypeStore) ?usize {
    for (modules, 0..) |*module, index| {
        if (module.checked) |*checked| {
            if (&checked.types == store) return index;
        }
    }
    return null;
}

fn declarationForSymbol(resolution: *const resolver.Resolution, symbol: symbols.SymbolId) ?ast.DeclId {
    var declarations = resolution.decl_symbols.iterator();
    while (declarations.next()) |entry| {
        if (entry.value_ptr.* == symbol) return entry.key_ptr.*;
    }
    return null;
}

// `expected_module_path` distinguishes an UNQUALIFIED builtin/prelude
// type (`Опция`, `Результат`, `module_path == null`, mixed into every
// module without qualification) from a QUALIFIED builtin type accessed
// through a module import (`DOM.СобытиеКлика`, `module_path ==
// "DOM"`). Matching on name alone (the old behavior) silently matched
// the FIRST same-named local type regardless of which module it came
// from — for `null` that's harmless (there IS only ever one), but for
// a qualified name it could never match anything (a local module's own
// `DOM.SobytieKlika` import also carries `module_path == "DOM"`, never
// `null`), producing `error.UnsupportedImportedType` for ANY struct
// field whose type transitively references a qualified builtin type
// declared in a THIRD module (e.g. a library's `Опция(функ(DOM.
// СобытиеКлика) -> Пусто)` struct field, imported by an application
// that itself also imports `DOM` — confirmed via a real crash, not
// speculative).
fn findLocalTypeSymbol(resolution: *const resolver.Resolution, name: []const u8, expected_module_path: ?[]const u8) ?symbols.SymbolId {
    for (resolution.symbols.symbols.items[1..], 1..) |entry, index| {
        if (entry.kind != .type or !std.mem.eql(u8, entry.name, name)) continue;
        const module_paths_match = switch (entry.module_path == null) {
            true => expected_module_path == null,
            false => expected_module_path != null and std.mem.eql(u8, entry.module_path.?, expected_module_path.?),
        };
        if (module_paths_match) return @enumFromInt(index);
    }
    return null;
}

// `Опция`/`Результат`/6 интерфейсов — существует лишь ОДНО настоящее
// объявление (`prelude.zig`), подмешиваемое без квалификации в каждый
// модуль, поэтому в отличие от обычной межмодульной структуры/перечисления
// (где два ОТДЕЛЬНО объявленных одноимённых типа НЕ должны смешиваться),
// любые две реконструкции одного из этих типов должны всегда сравниваться
// как равные. Используется в ДВУХ местах: (1) в месте вызова
// `nominalIdentity` ниже — принудительно даёт identity 0 (так же, как
// уже получает identity 0 прямое локальное использование модулем,
// например, `Опция(Число)`, никогда не затрагивая `nominalIdentity`)
// вместо чеканки новой ненулевой межмодульной identity; (2) цикл
// мостика прелюдии, выравнивающий собственную копию ТРЕТЬЕГО модуля.
const prelude_type_names = [_][]const u8{
    "Результат",
    "Опция",
    "Сравниваемое",
    "Итерируемое",
    "Печатаемое",
    "Копируемое",
    "Равнозначное",
    "Складываемое",
    "Вычитаемое",
    "Умножаемое",
    "Делимое",
};

fn isPreludeTypeName(name: []const u8) bool {
    for (prelude_type_names) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}

fn nominalIdentity(
    identities: *std.AutoHashMap(resolver.ImportedSymbolOrigin, u32),
    next_identity: *u32,
    origin: resolver.ImportedSymbolOrigin,
) !u32 {
    if (identities.get(origin)) |identity| return identity;
    if (next_identity.* == 0) return error.NominalIdentityLimitReached;
    const identity = next_identity.*;
    next_identity.* += 1;
    try identities.put(origin, identity);
    return identity;
}

pub fn compileGraph(allocator: std.mem.Allocator, graph: *const module_loader.Graph) !GraphCompileResult {
    return compileGraphForTarget(allocator, graph, .native);
}

pub fn compileGraphForTarget(allocator: std.mem.Allocator, graph: *const module_loader.Graph, target_profile: target_policy.TargetProfile) !GraphCompileResult {
    var result = GraphCompileResult.init(allocator);
    errdefer result.deinit();
    try result.appendDiagnostics(&graph.diagnostics);
    if (result.hasErrors()) return result;

    // Определяется по зарезервированному пути, а не параметром — граф,
    // построенный без вызова `appendPreludeModule` (любой ранее написанный
    // тест, любой не обновлённый вызывающий код), компилируется точно как
    // раньше, без слияния прелюдии где-либо.
    const prelude_module = graph.module_indices.get("@prelude");

    result.modules = try allocator.alloc(ModuleCompilation, graph.modules.items.len);
    @memset(result.modules, .{});
    // Фаза 1: сначала резолвим КАЖДЫЙ модуль, в любом порядке — `ImportScope`
    // строится исключительно из `graph.exports`/`graph.imports` (вычислены
    // один раз при загрузке `collectExports`/`registerModule`, см.
    // `buildExportsForTarget` в `module_linker.zig`), никогда — из
    // результатов резолва/проверки/компиляции ДРУГОГО модуля, поэтому у
    // резолва вообще нет реальной межмодульной зависимости по порядку, в
    // отличие от Фазы 2 ниже.
    for (graph.order.items) |module_index| {
        const module = &graph.modules.items[module_index];
        var scope = try module_linker.ImportScope.initWithPrelude(allocator, graph, module_index, prelude_module);
        defer scope.deinit();

        // Пропускается для КАЖДОГО модуля, если в графе уже есть модуль
        // прелюдии — сама прелюдия получает свои настоящие объявления, а
        // каждый ДРУГОЙ модуль получает их через неявный неквалифицированный
        // импорт выше, так что вручную установленные дубликаты
        // конфликтовали бы с любым из путей, не только с самой прелюдией.
        result.modules[module_index].resolution = try resolver.resolveModuleForTarget(allocator, &module.tree, scope.modules, prelude_module != null, target_profile, module.file.path);
        const resolution = &result.modules[module_index].resolution.?;
        try result.appendDiagnostics(&resolution.diagnostics);
        if (result.hasErrors()) return result;
    }

    // Фаза 2: проверка типов + компиляция. `graph.order` (обычный
    // топологический порядок по рёбрам импорта) используется как
    // НАЧАЛЬНАЯ очередь, но сам по себе недостаточен:
    // `ImportContext.appendMatchingImpls` сканирует `graph.impls` на ЛЮБУЮ
    // `реализация`, соответствующую origin импортированного типа, ВНЕ
    // ЗАВИСИМОСТИ от того, импортирован ли модуль-объявитель реализации
    // самим обрабатываемым модулем — форма "реализация в третьем файле"
    // (паттерн codegen `_gen.ps`: `реализация json.ВJSON для
    // json_fixture.Заказ`, написанная ни в `json_fixture.ps`, ни в
    // потребителе) означает, что модуль может зависеть от состояния
    // `.checked`/`.compiled` ДРУГОГО модуля БЕЗ какого-либо ребра импорта
    // между ними вообще — ограничение порядка, которое обычный DFS
    // `graph.order` по рёбрам импорта не может увидеть или закодировать.
    //
    // Поэтому вместо одного топологического прохода используется рабочая
    // очередь: модуль, чей `collect()` натыкается на ещё не готовую
    // зависимость (это скрытое ребро, порождённое реализацией — ЕДИНСТВЕННОЕ,
    // что может это вызвать: любое ДРУГОЕ место `ImportNotCompiled`/
    // `ImportNotChecked` в `ImportContext` обращается к модулю, который
    // `own_module` РЕАЛЬНО импортирует, и уже гарантированно готов по
    // `graph.order`), откладывается в конец очереди и повторяется позже,
    // вместо немедленного отказа. `stalled` считает подряд идущие
    // переоткладывания без единого продвижения вперёд — если счётчик
    // достигает текущей длины очереди, значит каждый оставшийся модуль
    // провалился за полный проход — это по-настоящему неразрешимый случай
    // (на практике не встречался; потребовал бы настоящего цикла между
    // квалифицированными целями реализации через файлы) — тогда исходная
    // ошибка пробрасывается наружу вместо бесконечного цикла.
    var queue: std.ArrayList(usize) = .empty;
    defer queue.deinit(allocator);
    try queue.appendSlice(allocator, graph.order.items);
    var stalled: usize = 0;
    while (queue.items.len != 0) {
        if (stalled >= queue.items.len) {
            // Ни один элемент очереди не продвинулся за полный проход —
            // состояние графа не изменилось с прошлой попытки для этого же
            // модуля, поэтому повторный `collect` должен провалиться
            // идентично, и `try` пробрасывает эту ошибку из
            // `compileGraphForTarget`. Достижимо только при настоящем цикле
            // между квалифицированными целями реализации через файлы (см.
            // doc-комментарий выше) — не встречается ни в каком существующем
            // коде панос.
            const module_index = queue.items[0];
            const resolution = &result.modules[module_index].resolution.?;
            var imports = ImportContext.init(allocator);
            defer imports.deinit();
            try imports.collect(resolution, result.modules, &result.nominal_identities, &result.next_nominal_identity, graph, module_index);
            unreachable;
        }

        const module_index = queue.orderedRemove(0);
        const module = &graph.modules.items[module_index];
        const resolution = &result.modules[module_index].resolution.?;

        var imports = ImportContext.init(allocator);
        defer imports.deinit();
        imports.collect(resolution, result.modules, &result.nominal_identities, &result.next_nominal_identity, graph, module_index) catch |err| switch (err) {
            error.ImportNotCompiled, error.ImportNotChecked => {
                try queue.append(allocator, module_index);
                stalled += 1;
                continue;
            },
            else => return err,
        };
        stalled = 0;

        result.modules[module_index].checked = try type_checker.checkWithImportContextForTarget(allocator, &module.tree, resolution, .{
            .symbols = imports.imported_types.items,
            .type_aliases = imports.type_aliases.items,
            .nominals = imports.nominals.items,
            .methods = imports.methods.items,
            .impls = imports.impls.items,
            .has_real_prelude = prelude_module != null,
        }, target_profile);
        const checked = &result.modules[module_index].checked.?;
        try result.appendDiagnostics(&checked.diagnostics);
        if (result.hasErrors()) return result;

        result.modules[module_index].compiled = try compiler.compileWithOptions(allocator, &module.tree, resolution, checked, .{
            .program = &result.program,
            .functions = imports.functions.items,
            .constants = imports.constants.items,
        });
        const compiled = &result.modules[module_index].compiled.?;
        try result.appendDiagnostics(&compiled.diagnostics);
        if (result.hasErrors()) return result;
    }
    if (result.modules.len != 0) result.start = findStart(&result.modules[0]);
    return result;
}

fn findStart(module: *const ModuleCompilation) ?bytecode.FunctionId {
    const resolution = module.resolution orelse return null;
    const compiled = module.compiled orelse return null;
    for (resolution.symbols.symbols.items, 0..) |symbol, index| {
        if (symbol.kind != .function or !std.mem.eql(u8, symbol.name, "старт")) continue;
        const id: symbols.SymbolId = @enumFromInt(index);
        return compiled.function_ids.get(id);
    }
    return null;
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

test "module compiler executes imported primitive functions and constants" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./математика\" как мат\nэкспорт функ старт() -> Число\nмат.сложить(мат.ОТВЕТ, 2.0)\nконец" },
        .{ .path = "проект/математика.ps", .bytes = "экспорт конст ОТВЕТ = 40.0\nэкспорт функ сложить(a: Число, b: Число) -> Число\na + b\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler checks imported function arguments" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./математика\" как мат\nэкспорт функ старт() -> Число\nмат.сложить(\"ошибка\", 2)\nконец" },
        .{ .path = "проект/математика.ps", .bytes = "экспорт функ сложить(a: Число, b: Число) -> Число\na + b\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expect(compiled.hasErrors());
    try std.testing.expectEqualStrings("Type Error: аргумент не совпадает с типом параметра", compiled.diagnostics.items.items[0].message);
}

test "module compiler executes a transitive imported function" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./удвоение\" как удв\nэкспорт функ старт() -> Число\nудв.применить(21.0)\nконец" },
        .{ .path = "проект/удвоение.ps", .bytes = "импорт \"./математика\" как мат\nэкспорт функ применить(x: Число) -> Число\nмат.сложить(x, x)\nконец" },
        .{ .path = "проект/математика.ps", .bytes = "экспорт функ сложить(a: Число, b: Число) -> Число\na + b\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler retains imported string constants in the shared program" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./сообщения\" как сообщ\nэкспорт функ старт() -> Строка\nсообщ.ПРИВЕТ + \"!\"\nконец" },
        .{ .path = "проект/сообщения.ps", .bytes = "экспорт конст ПРИВЕТ = \"привет\"" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| {
            const rendered = result.stringBytes() orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("привет!", rendered);
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler preserves opaque exported nominal types across function calls" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./точки\" как точки\nэкспорт функ старт() -> Число\nпер точка: точки.Точка = точки.создать(40.0)\nточки.добавить(точка, 2.0)\nконец" },
        .{ .path = "проект/точки.ps", .bytes = "экспорт тип Точка = структура\nx: Число\nконец\nэкспорт функ создать(x: Число) -> Точка\nТочка(x)\nконец\nэкспорт функ добавить(точка: Точка, значение: Число) -> Число\nточка.x + значение\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler keeps same-named nominal exports distinct" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./левый\" как лев\nимпорт \"./правый\" как прав\nэкспорт функ старт() -> Число\nлев.значение(прав.создать(1))\nконец" },
        .{ .path = "проект/левый.ps", .bytes = "экспорт тип Значение = структура\nx: Число\nконец\nэкспорт функ значение(значение: Значение) -> Число\nзначение.x\nконец" },
        .{ .path = "проект/правый.ps", .bytes = "экспорт тип Значение = структура\nx: Число\nконец\nэкспорт функ создать(x: Число) -> Значение\nЗначение(x)\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expect(compiled.hasErrors());
    try std.testing.expectEqualStrings("Type Error: аргумент не совпадает с типом параметра", compiled.diagnostics.items.items[0].message);
}

test "module compiler dispatches a same-file impl method on an imported nominal type" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./точки\" как точки\nэкспорт функ старт() -> Число\nпер точка: точки.Точка = точки.Точка(41.0)\nточка.увеличить()\nконец" },
        .{ .path = "проект/точки.ps", .bytes = "экспорт тип Точка = структура\nx: Число\nконец\nреализация Точка\nфунк увеличить(это: Точка) -> Число\nэто.x + 1.0\nконец\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler constructs and matches an imported enum variant with no fields" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./цвета\" как цвета\nэкспорт функ старт() -> Число\nпер c: цвета.Цвет = цвета.Цвет.Красный()\nвыбор c\nКрасный -> 42.0\nЗелёный -> 0.0\nконец\nконец" },
        .{ .path = "проект/цвета.ps", .bytes = "экспорт тип Цвет = перечисление\nКрасный\nЗелёный\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler constructs and matches an imported enum variant carrying a field" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./итог\" как итог\nэкспорт функ старт() -> Число\nпер r: итог.Итог = итог.Итог.Готово(41.0)\nвыбор r\nГотово(x) -> x + 1.0\nПусто -> 0.0\nконец\nконец" },
        .{ .path = "проект/итог.ps", .bytes = "экспорт тип Итог = перечисление\nГотово(Число)\nПусто\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler still rejects an unknown variant on an imported enum type" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./цвета\" как цвета\nэкспорт функ старт() -> Число\nпер c: цвета.Цвет = цвета.Цвет.Синий()\n1\nконец" },
        .{ .path = "проект/цвета.ps", .bytes = "экспорт тип Цвет = перечисление\nКрасный\nЗелёный\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expect(compiled.hasErrors());
}

test "module compiler rejects a non-exhaustive match on an imported enum type" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./цвета\" как цвета\nэкспорт функ старт() -> Число\nпер c: цвета.Цвет = цвета.Цвет.Красный()\nвыбор c\nКрасный -> 1\nконец\nконец" },
        .{ .path = "проект/цвета.ps", .bytes = "экспорт тип Цвет = перечисление\nКрасный\nЗелёный\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expect(compiled.hasErrors());
}

test "module compiler dispatches an impl method on a value returned from an imported constructor function" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./точки\" как точки\nэкспорт функ старт() -> Число\nпер точка: точки.Точка = точки.создать(41.0)\nточка.увеличить()\nконец" },
        .{ .path = "проект/точки.ps", .bytes = "экспорт тип Точка = структура\nx: Число\nконец\nэкспорт функ создать(x: Число) -> Точка\nТочка(x)\nконец\nреализация Точка\nфунк увеличить(это: Точка) -> Число\nэто.x + 1.0\nконец\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler still rejects an unknown method on an imported nominal type" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./точки\" как точки\nэкспорт функ старт() -> Число\nпер точка: точки.Точка = точки.Точка(1)\nточка.нет_такого()\nконец" },
        .{ .path = "проект/точки.ps", .bytes = "экспорт тип Точка = структура\nx: Число\nконец\nреализация Точка\nфунк увеличить(это: Точка) -> Число\nэто.x + 1\nконец\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expect(compiled.hasErrors());
}

test "module compiler instantiates an imported generic struct's field with a concrete type argument" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./короб\" как короб\nэкспорт функ старт() -> Число\nпер к: короб.Коробка(Число) = короб.Коробка(42.0)\nк.значение\nконец" },
        .{ .path = "проект/короб.ps", .bytes = "экспорт тип Коробка[T] = структура\nзначение: T\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler dispatches a method on an imported generic struct with a concrete type argument" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./короб\" как короб\nэкспорт функ старт() -> Число\nпер к: короб.Коробка(Число) = короб.Коробка(42.0)\nк.развернуть(0.0)\nконец" },
        .{ .path = "проект/короб.ps", .bytes = "экспорт тип Коробка[T] = структура\nзначение: T\nконец\nреализация Коробка\nфунк развернуть(это: Коробка, запас: T) -> T\nэто.значение\nконец\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler constructs and matches an imported generic enum variant carrying a concrete-type field" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./короб\" как короб\nэкспорт функ старт() -> Число\nпер к: короб.Ящик(Число) = короб.Ящик.Есть(42.0)\nвыбор к\nЕсть(x) -> x\nПусто -> 0.0\nконец\nконец" },
        .{ .path = "проект/короб.ps", .bytes = "экспорт тип Ящик[T] = перечисление\nПусто\nЕсть(T)\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler dispatches a method on an imported generic enum with a concrete type argument" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./короб\" как короб\nэкспорт функ старт() -> Число\nпер к: короб.Ящик(Число) = короб.Ящик.Есть(42.0)\nк.развернуть(0.0)\nконец" },
        .{ .path = "проект/короб.ps", .bytes = "экспорт тип Ящик[T] = перечисление\nПусто\nЕсть(T)\nконец\nреализация Ящик\nфунк развернуть(это: Ящик, запас: T) -> T\nвыбор это\nЕсть(x) -> x\nПусто -> запас\nконец\nконец\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler dispatches an interface-impl method as an ordinary cross-module call" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./точки\" как точки\nэкспорт функ старт() -> Число\nпер первая: точки.Точка = точки.Точка(40.0)\nпер вторая: точки.Точка = точки.Точка(2.0)\nпервая.сравнить(вторая)\nконец" },
        .{ .path = "проект/точки.ps", .bytes = "экспорт тип Точка = структура\nx: Число\nконец\nреализация Сравниваемое для Точка\nфунк сравнить(это: Точка, другое: Точка) -> Число\nэто.x - другое.x\nконец\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 38), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

// И интерфейс, И цель квалифицированы (`реализация
// интерфейсы.МойИнтерфейс для точки.Точка`), причём сам блок реализации
// написан в ПОТРЕБЛЯЮЩЕМ файле (main.ps). `signaturePass` (обрабатывает
// блоки `реализация`, включая проверку `isImplementableNominal`) должен
// выполняться ПОСЛЕ `importSignaturePass` (заполняет `nominal_fields` для
// импортированных номинальных типов) — иначе запись `nominal_fields` для
// квалифицированной цели ещё не существует на момент проверки.
// `interfaceMethodMatches` сравнивает тип получателя через `nominalType`
// (реальную мостовую identity), а не через сырой `types.nominal(owner,
// ...)` (identity=0) — `TypeStore.eql` для номинальных типов переключается
// на строгое сравнение identity, как только хотя бы одна сторона не равна
// нулю, поэтому получатель должен совпадать с типом параметра метода
// `это: точки.Точка`, разрешённым через собственную ветку `.qualified`
// `resolveType`.
//
// НЕ покрыто здесь (отдельный, более крупный пробел, всё ещё открыт): блок
// реализации, написанный в ТРЕТЬЕМ файле — не в файле самой структуры и не
// в файле потребителя — невидим для любого ДРУГОГО файла, импортирующего
// только модуль структуры (`collectMethods` в module_loader.zig пропускает
// квалифицированные цели целиком, `target_module != null => continue`, так
// что такие реализации вообще никогда не попадают в
// `graph.methods`/`graph.impls`) — именно такая форма нужна файлу
// `_gen.ps`, сгенерированному codegen (отдельному и от файла исходной
// структуры, и от того, что импортирует сгенерированный файл).
test "module compiler resolves both qualified interface and qualified target declared in the consumer" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./интерфейсы\" как интерфейсы\nимпорт \"./точки\" как точки\nреализация интерфейсы.МойИнтерфейс для точки.Точка\nфунк значение(это: точки.Точка) -> Число\nэто.x\nконец\nконец\nэкспорт функ старт() -> Число\nточки.Точка(40.0).значение()\nконец" },
        .{ .path = "проект/интерфейсы.ps", .bytes = "экспорт тип МойИнтерфейс = интерфейс\nфунк значение() -> Число\nконец" },
        .{ .path = "проект/точки.ps", .bytes = "экспорт тип Точка = структура\nx: Число\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 40), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

// Реализация объявлена в ТРЕТЬЕМ файле — не в собственном файле структуры
// (точки.ps) и не в файле, который реально вызывает метод (main.ps) — это
// повторяет форму сгенерированного codegen `_gen.ps`: отдельно и от файла
// исходной структуры, и от того, что импортирует сгенерированный файл.
// main.ps импортирует точки.ps напрямую (ради конструктора) И связка.ps
// (ради побочного эффекта регистрации реализации — именно это делает
// сгенерированный `импорт "./<файл>_gen"`).
test "module compiler resolves an impl declared in a third file, separate from both the struct and the consumer" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./точки\" как точки\nимпорт \"./связка\" как связка\nэкспорт функ старт() -> Число\nточки.Точка(40.0).значение()\nконец" },
        .{ .path = "проект/интерфейсы.ps", .bytes = "экспорт тип МойИнтерфейс = интерфейс\nфунк значение() -> Число\nконец" },
        .{ .path = "проект/точки.ps", .bytes = "экспорт тип Точка = структура\nx: Число\nконец" },
        .{ .path = "проект/связка.ps", .bytes = "импорт \"./интерфейсы\" как интерфейсы\nимпорт \"./точки\" как точки\nреализация интерфейсы.МойИнтерфейс для точки.Точка\nфунк значение(это: точки.Точка) -> Число\nэто.x\nконец\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 40), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler resolves a qualified impl target within its own declaring module" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./методы\"\nэкспорт функ старт() -> Число\nметоды.проверить()\nконец" },
        .{ .path = "проект/точки.ps", .bytes = "экспорт тип Точка = структура\nx: Число\nконец" },
        .{ .path = "проект/методы.ps", .bytes = "импорт \"./точки\" как точки\nреализация точки.Точка\nфунк увеличить(это: точки.Точка) -> Число\nэто.x + 1.0\nконец\nконец\nэкспорт функ проверить() -> Число\nпер точка: точки.Точка = точки.Точка(41.0)\nточка.увеличить()\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler resolves a qualified interface-side impl target across a third module" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./точки\" как точки\nэкспорт функ старт() -> Число\nпер a: точки.Точка = точки.Точка(40.0)\na.значение()\nконец" },
        .{ .path = "проект/интерфейсы.ps", .bytes = "экспорт тип МойИнтерфейс = интерфейс\nфунк значение() -> Число\nконец" },
        .{ .path = "проект/точки.ps", .bytes = "импорт \"./интерфейсы\" как интерфейсы\nэкспорт тип Точка = структура\nx: Число\nконец\nреализация интерфейсы.МойИнтерфейс для Точка\nфунк значение(это: Точка) -> Число\nэто.x\nконец\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 40), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler dispatches an imported struct's interface implementation via a generic bound" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./точки\" как точки\nфунк макс[T: Сравниваемое](a: T, b: T) -> T\nесли a > b тогда a иначе b конец\nконец\nэкспорт функ старт() -> Число\nпер a: точки.Точка = точки.Точка(40.0)\nпер b: точки.Точка = точки.Точка(2.0)\nмакс(a, b).x\nконец" },
        .{ .path = "проект/точки.ps", .bytes = "экспорт тип Точка = структура\nx: Число\nконец\nреализация Сравниваемое для Точка\nфунк сравнить(это: Точка, другое: Точка) -> Число\nэто.x - другое.x\nконец\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 40), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler preserves a prelude bound on an imported generic function" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./библиотека\" как библиотека\nэкспорт функ старт() -> Число\nпер a: библиотека.Точка = библиотека.Точка(40.0)\nпер b: библиотека.Точка = библиотека.Точка(2.0)\nбиблиотека.макс(a, b).x\nконец" },
        .{ .path = "проект/библиотека.ps", .bytes = "экспорт тип Точка = структура\nx: Число\nконец\nреализация Сравниваемое для Точка\nфунк сравнить(это: Точка, другое: Точка) -> Число\nэто.x - другое.x\nконец\nконец\nэкспорт функ макс[T: Сравниваемое](a: T, b: T) -> T\nесли a > b тогда a иначе b конец\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 40), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler rejects a value outside an imported generic function bound" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./библиотека\" как библиотека\nэкспорт функ старт() -> Строка\nбиблиотека.макс(\"a\", \"b\")\nконец" },
        .{ .path = "проект/библиотека.ps", .bytes = "экспорт функ макс[T: Сравниваемое](a: T, b: T) -> T\nесли a > b тогда a иначе b конец\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expect(compiled.hasErrors());
    try std.testing.expectEqualStrings("Type Error: тип аргумента не реализует ограничение 'Сравниваемое'", compiled.diagnostics.items.items[0].message);
}

test "module compiler dispatches through a direct interface-typed cast on an imported struct" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./точки\" как точки\nэкспорт функ старт() -> Число\nпер a: точки.Точка = точки.Точка(40.0)\nпер b: точки.Точка = точки.Точка(2.0)\nпер x: Сравниваемое = a\nx.сравнить(b)\nконец" },
        .{ .path = "проект/точки.ps", .bytes = "экспорт тип Точка = структура\nx: Число\nконец\nреализация Сравниваемое для Точка\nфунк сравнить(это: Точка, другое: Точка) -> Число\nэто.x - другое.x\nконец\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 38), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

// `inferInterfaceCall`/`inferGenericBoundInterfaceCall` пробуются
// спекулятивно для КАЖДОГО вызова `.property(...)` и при несовпадении
// откатываются к следующему кандидату (здесь — квалифицированный
// конструктор структуры); важно, чтобы диагностика "именованные аргументы
// не поддержаны для интерфейсного вызова" не всплывала раньше, чем
// подтверждено, что вызов действительно относится к интерфейсу — иначе
// обычный межмодульный вызов конструктора с именованными аргументами
// (`модуль.Тип(поле = x, ...)`), не имеющий отношения к интерфейсам,
// был бы ошибочно отклонён.
test "module compiler accepts a qualified struct constructor with named arguments" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./основа\" как основа\nэкспорт функ старт() -> Строка\nпер s = основа.Спавн(имя = \"рабочий\", приоритет = 1)\ns.имя\nконец" },
        .{ .path = "проект/основа.ps", .bytes = "экспорт тип Спавн = структура\nимя: Строка\nприоритет: Целое\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| {
            const bytes = result.stringBytes() orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("рабочий", bytes);
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler merges an appended prelude module unqualified into every real module" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "экспорт функ старт() -> Число\nпер к: Коробочка(Число) = Коробочка.Есть(42.0)\nк.развернуть(0.0)\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");
    _ = try graph.appendPreludeModule(
        \\экспорт тип Коробочка[T] = перечисление
        \\Пусто
        \\Есть(T)
        \\конец
        \\реализация Коробочка
        \\функ развернуть(это: Коробочка, запас: T) -> T
        \\выбор это
        \\Есть(x) -> x
        \\Пусто -> запас
        \\конец
        \\конец
        \\конец
    );

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler constructs and reads exported structure fields" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./точки\" как точки\nэкспорт функ старт() -> Число\nпер точка: точки.Точка = точки.Точка(1.0)\nточка.x = 40.0\nточка.x + 2.0\nконец" },
        .{ .path = "проект/точки.ps", .bytes = "экспорт тип Точка = структура\nx: Число\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler preserves a transitive nominal field type" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./api\" как api\nэкспорт функ старт() -> Число\napi.создать().элемент.значение\nконец" },
        .{ .path = "проект/api.ps", .bytes = "импорт \"./модель\" как модель\nэкспорт тип Ответ = структура\nэлемент: модель.Элемент\nконец\nэкспорт функ создать() -> Ответ\nОтвет(модель.Элемент(42.0))\nконец" },
        .{ .path = "проект/модель.ps", .bytes = "экспорт тип Элемент = структура\nзначение: Число\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler accepts an imported nominal in an imported generic callback" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./коллекции\" как кол\nимпорт \"./модель\" как модель\nфунк в_число(x: модель.Элемент) -> Число\nx.значение\nконец\nэкспорт функ старт() -> Число\nпер значения = кол.отобразить(массив(модель.Элемент(42.0)), в_число)\nзначения.получить(0, 0.0)\nконец" }, // index arg (Целое ok), default value arg fixed to Число
        .{ .path = "проект/коллекции.ps", .bytes = "экспорт функ отобразить[T, U](значения: Массив(T), преобразовать: функ(T) -> U) -> Массив(U)\nпер результат: Массив(U) = массив()\nдля значение в значения цикл\nрезультат.добавить(преобразовать(значение))\nконец\nрезультат\nконец" },
        .{ .path = "проект/модель.ps", .bytes = "экспорт тип Элемент = структура\nзначение: Число\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

// Импорт функции, чья сигнатура сочетает ТРАНЗИТИВНО импортированный
// номинальный тип (здесь `модель.Элемент`, импортированный только через
// `сервис.ps`, никогда напрямую `main.ps`) с ЛОКАЛЬНО объявленной
// структурой, у которой есть СОБСТВЕННЫЕ методы `реализация` (здесь
// `Обёртка.развернуть`), затрагивает цикл `ImportContext.collect`'а `for
// (self.methods.items) |method|`: `collectTransitiveNominals` (вызывается
// изнутри именно этого цикла, для случая `Обёртка`) сам добавляет ЕЩЁ
// записи в `self.methods` (ветка `.nominal` "у определения есть свои
// методы"), что может переаллоцировать резервный массив прямо под уже
// захваченным срезом цикла `for` — классический use-after-free "мутация
// коллекции во время итерации по её захваченному срезу". Нужны ОБА
// условия одновременно (только `модель.Элемент` без локальной структуры с
// методами не задействует эту ветку; только `Обёртка` без транзитивного
// импорта — тоже), как в `отправить_json` (`json.Значение` транзитивно +
// локальный `Ответ` с блоком `реализация`).
test "module compiler imports a function combining a transitive nominal with a local struct that has methods" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./сервис\" как сервис\nимпорт \"./модель\" как модель\nэкспорт функ старт() -> Число\nвыбор сервис.обернуть(модель.Элемент(42.0))\nРезультат.Успех(о) -> о.развернуть()\nРезультат.Неудача(_) -> -1.0\nконец\nконец" },
        .{ .path = "проект/сервис.ps", .bytes = "импорт \"./модель\" как модель\nэкспорт тип Обёртка = структура\nзначение: Число\nконец\nреализация Обёртка\nфунк развернуть(это: Обёртка) -> Число\nэто.значение\nконец\nконец\nэкспорт функ обернуть(значение: модель.Элемент) -> Результат(Обёртка, Ошибка)\nРезультат.Успех(Обёртка(значение.значение))\nконец" },
        .{ .path = "проект/модель.ps", .bytes = "экспорт тип Элемент = структура\nзначение: Число\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

// `panos run` (`main` в `cli/main.zig`) загружает НАСТОЯЩИЙ модуль
// прелюдии (`graph.appendPreludeModule(prelude.SOURCE)`) вместо того,
// чтобы полагаться на захардкоженные Опция/Результат/интерфейсные
// заглушки `type_checker.zig` — это графовый эквивалент того, что уже
// делает однофайловый пайплайн `runner.zig`. Проверяет: методы `Опция`
// (`.получить`) работают через настоящий модуль прелюдии, и межмодульный
// `импорт` + `<` через `Сравниваемое` тоже работает с настоящим модулем
// прелюдии в графе — этот путь требует, чтобы мостовой цикл прелюдии в
// `ImportContext.collect` оставался чисто identity-based (без дублирования
// записей `ImportedNominal` для собственных generic-типов прелюдии).
test "module compiler works end to end with a real prelude module in the graph" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./точки\" как точки\nэкспорт функ старт() -> Число\nпер o: Опция(Число) = Опция.Есть(42.0)\nпер cmp = точки.Точка(1.0) < точки.Точка(2.0)\nвыбор cmp\nистина -> o.получить(0.0)\nложь -> -1.0\nконец\nконец" },
        .{ .path = "проект/точки.ps", .bytes = "экспорт тип Точка = структура\nx: Число\nконец\nреализация Сравниваемое для Точка\nфунк сравнить(это: Точка, другое: Точка) -> Число\nэто.x - другое.x\nконец\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");
    _ = try graph.appendPreludeModule(prelude.SOURCE);
    try std.testing.expectEqual(@as(usize, 0), graph.diagnostics.items.items.len);

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

// Метод по умолчанию у `Итерируемое` (прелюдия), вызываемый из ДРУГОГО
// модуля, чем тот, где объявлен конкретный реализующий тип, и достигнутый
// ТОЛЬКО транзитивно (через тип возврата функции, никогда не
// именованный/импортированный напрямую) — например,
// `итератор(массив).отфильтровать(...).отобразить(...).взять(...)
// .собрать()`. `default_symbol` метода `собрать` (символ в собственном
// пространстве символов модуля ПРЕЛЮДИИ) не имеет смысла в потребляющем
// модуле сам по себе — `ImportedNominal.default_method_symbols` +
// `bridgeDefaultMethodSymbols` (чеканят локальный синтетический символ на
// каждый метод по умолчанию, тот же паттерн, что уже используется для
// собственных методов) мостят и структурную форму, и РЕАЛИЗАЦИИ интерфейса
// для транзитивно достигнутого номинального типа.
test "module compiler dispatches a chain of interface default methods across a module boundary" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "экспорт функ старт() -> Массив(Число)\nпер числа = массив(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0)\nитератор(числа).отфильтровать(функ(x: Число) -> Булево\nx > 2.0\nконец).отобразить(функ(x: Число) -> Число\nx * 10.0\nконец).взять(3).собрать()\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");
    _ = try graph.appendPreludeModule(prelude.SOURCE);
    try std.testing.expectEqual(@as(usize, 0), graph.diagnostics.items.items.len);

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .array => |array| {
                try std.testing.expectEqual(@as(usize, 3), array.elements.len);
                try std.testing.expectEqual(@as(f64, 30), array.elements[0].number);
                try std.testing.expectEqual(@as(f64, 40), array.elements[1].number);
                try std.testing.expectEqual(@as(f64, 50), array.elements[2].number);
            },
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}
