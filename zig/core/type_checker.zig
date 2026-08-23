const std = @import("std");
const ast = @import("ast.zig");
const diagnostic = @import("diagnostic.zig");
const resolver = @import("resolver.zig");
const source = @import("source.zig");
const symbols = @import("symbols.zig");
const target_policy = @import("target.zig");
const types = @import("types.zig");

pub const NominalField = struct {
    name: []const u8,
    typ: types.TypeId,
};

pub const GenericParameter = struct {
    name: []const u8,
    typ: types.TypeId,
    bounds: []const symbols.SymbolId = &.{},
};

pub const GenericNominal = struct {
    parameters: []const GenericParameter,
    fields: []const NominalField,
};

pub const EnumVariant = struct {
    symbol: symbols.SymbolId,
    name: []const u8,
    fields: []const types.TypeId,
};

pub const EnumDefinition = struct {
    parameters: []const GenericParameter,
    variants: []const EnumVariant,
};

pub const InterfaceMethod = struct {
    name: []const u8,
    parameters: []const types.TypeId,
    return_type: types.TypeId,
    // Не null, если у метода есть тело по умолчанию (`interfacePass`) —
    // скомпилированная функция, к которой откатывается реализация, не
    // переопределившая этот метод сама (`defineInterfaceImplementation`).
    default_symbol: ?symbols.SymbolId = null,
};

pub const InterfaceDefinition = struct {
    parameters: []const GenericParameter,
    methods: []const InterfaceMethod,
};

pub const InterfaceImplementation = struct {
    interface: symbols.SymbolId,
    arguments: []const types.TypeId,
    target: symbols.SymbolId,
    methods: []const symbols.SymbolId,
};

pub const InterfaceCastEntry = struct {
    interface: symbols.SymbolId,
    arguments: []const types.TypeId,
    target: symbols.SymbolId,
    // Собственная генерик-инстанциация target в точке приведения (например,
    // `[Число, Строка]` для `Отображённый(Число, Строка)`) — нужна
    // резервному пути по генерик-шаблону в `findInterfaceImplementation`,
    // когда компилятор повторно разрешает vtable на этапе кодогенерации.
    target_arguments: []const types.TypeId,
};

pub const InterfaceCast = struct {
    entries: []const InterfaceCastEntry,
};

pub const InterfaceCall = struct {
    interface: symbols.SymbolId,
    method_index: u16,
    vtable_index: u16 = 0,
};

pub const ForInKind = enum {
    array,
    iterator,
};

pub const ImportedSymbolType = struct {
    symbol: symbols.SymbolId,
    store: *const types.TypeStore,
    type_id: types.TypeId,
    // Не null, если импортируемый символ — ГЕНЕРИК-ФУНКЦИЯ верхнего уровня
    // (`функ ф[T: Интерфейс](...)`): собственные, НЕ ПЕРЕОТОБРАЖЁННЫЕ
    // TypeId/ограничения генерик-параметров исходного модуля (символы
    // ограничивающих интерфейсов здесь всё ещё локальные символы ИСХОДНОГО
    // модуля; импортёр переотображает их через `imports.nominals` при
    // использовании). Без этого поля `copyImportedType` в ветке
    // `.generic_parameter` не имела бы соответствия для переотображения и
    // молча вырождала бы `T` в `poison` для любого межмодульного вызова
    // генерик-функции — `poison` совместим с чем угодно, поэтому вызов
    // проходил тайпчек без единой диагностики, но скомпилированное тело
    // вызываемой функции всё равно ожидало, что `это` придёт уже
    // приведённым через `Cast_Interface`.
    generic_parameters: ?[]const GenericParameter = null,
};

pub const ImportedNominal = struct {
    // Хранилище, в котором `source_symbol` встречается в импортируемой сигнатуре.
    store: *const types.TypeStore,
    // Хранилище, владеющее полями, вариантами и генерик-параметрами
    // объявления номинального типа. Они различаются для транзитивного
    // импорта: модуль B ссылается на C.Тип через собственный локальный
    // TypeStore модуля B, тогда как определением Тип владеет C.
    definition_store: *const types.TypeStore,
    source_symbol: symbols.SymbolId,
    local_symbol: symbols.SymbolId,
    identity: u32,
    fields: ?[]const NominalField = null,
    // Прямая ссылка на `EnumDefinition.variants` исходного модуля (живо
    // на весь компилируемый граф) — используются только `.name`/`.fields`;
    // `.symbol` — собственный символ варианта исходного модуля, здесь не
    // важен, так как локальный символ варианта ищется по имени отдельно.
    enum_variants: ?[]const EnumVariant = null,
    // Не null для генерик-владельца (структура, перечисление или
    // интерфейс) — собственные TypeId генерик-параметров исходного
    // модуля; importSignaturePass чеканит свежие локальные, переотображает
    // через них `fields`/`enum_variants`/`interface_methods`, и то же
    // переотображение переиспользуется для импортированных методов этого
    // владельца.
    generic_parameters: ?[]const GenericParameter = null,
    // Прямая ссылка на `InterfaceDefinition.methods` исходного модуля
    // (живо на весь компилируемый граф), не null, если этот номинальный
    // тип сам является ИНТЕРФЕЙСОМ, объявленным в другом модуле —
    // позволяет ТРЕТЬЕМУ модулю реализовать интерфейс/проверить
    // ограничение по интерфейсу, который он сам никогда не объявлял
    // (`реализация чужой_модуль.Интерфейс для Тип`).
    interface_methods: ?[]const InterfaceMethod = null,
    // Параллельно `interface_methods` (та же длина) — ЛОКАЛЬНЫЙ (этого
    // модуля) синтетический символ, замещающий тело метода по умолчанию
    // `interface_methods[i]`, либо `null`, если у метода нет значения по
    // умолчанию. Сам `interface_methods[i].default_symbol` — символ в
    // пространстве символов ИСХОДНОГО модуля, здесь бессмыслен —
    // `module_compiler.zig` чеканит настоящий локальный заменитель (тот
    // же паттерн "синтетический символ + imports.functions", что уже
    // используется для собственных методов) и прокидывает его сюда, так
    // как только он владеет изменяемым `resolver.Resolution` для чеканки.
    default_method_symbols: ?[]const ?symbols.SymbolId = null,
};

pub const ImportedMethod = struct {
    owner: symbols.SymbolId,
    name: []const u8,
    symbol: symbols.SymbolId,
    store: *const types.TypeStore,
    type_id: types.TypeId,
    parameter_names: []const []const u8 = &.{},
    // Собственные (не владельца-структуры) generic-параметры МЕТОДА —
    // например `Тело`/`Ответ` в `функ отправить_пост[Тело: ИзJSON,
    // Ответ: ВJSON](это: Приложение, ...)`. Симметрично `ImportedSymbolType.
    // generic_parameters` (тот же перенос нужен для импортированных
    // СВОБОДНЫХ generic-функций) — до появления этого поля метод,
    // ссылающийся на СОБСТВЕННЫЙ generic-параметр где угодно, кроме
    // непосредственно самого себя (например, ВНУТРИ типа функции —
    // `функ() -> Тело` как тип параметра), при импорте молча
    // вырождался в `poison` (`copyImportedType`'s `.generic_parameter`
    // ветка: `generic_remap orelse return error.UnsupportedImportedType`,
    // а `owner_remap` покрывает только generic-параметры ВЛАДЕЮЩЕЙ
    // структуры, не собственные параметры метода) — найдено при
    // реализации `быстряга` (panosiki), где `Приложение.отправить_пост`
    // именно такой формы.
    generic_parameters: ?[]const GenericParameter = null,
};

// Реализация интерфейса владельцем, перенесённая из исходного модуля.
// `interface_name` разрешается по имени в собственной области видимости
// ИМПОРТЁРА (у каждого файла свой локальный символ прелюдии "Сравниваемое",
// поэтому исходный Symbol_Id интерфейса здесь никогда не валиден) —
// `method_names` сопоставляются по имени с методами, уже
// зарегистрированными через `ImportContext.methods` (методы реализации
// интерфейса — это обычные собственные методы, см. `collectMethods` в
// `module_loader.zig`), так что отдельного переноса FunctionId для этого
// списка не требуется.
pub const ImportedImpl = struct {
    owner: symbols.SymbolId,
    interface_name: []const u8,
    // Задано, если сам интерфейс КВАЛИФИЦИРОВАН (`реализация
    // Модуль.Интерфейс для ...`, например `json.ВJSON` из codegen) И
    // импортирующий модуль имеет для него собственный локальный символ —
    // в этом случае `interface_name` сам по себе не разрешается через
    // `findTypeSymbol` (он в области видимости только как
    // `модуль.Интерфейс`, никогда без квалификации). `null` откатывается
    // к обычному поиску по голому имени (локальный/неквалифицированный
    // интерфейс, обычный случай).
    interface_symbol: ?symbols.SymbolId = null,
    // Прямая ссылка на `InterfaceImplementation.methods` и `Resolution`
    // исходного модуля (оба живы на весь компилируемый граф) — имена
    // ищутся по требованию, отдельного списка имён не выделяется.
    method_symbols: []const symbols.SymbolId,
    target_resolution: *const resolver.Resolution,
    store: *const types.TypeStore,
    argument_type_ids: []const types.TypeId,
};

pub const ImportContext = struct {
    symbols: []const ImportedSymbolType = &.{},
    // Квалифицированная ссылка на ПСЕВДОНИМ ТИПА (`lib.Обработчик`, где
    // `тип Обработчик = функ(Число) -> Число` объявлен в `lib`) —
    // переиспользует ту же форму `ImportedSymbolType` (symbol/store/
    // type_id), поскольку перенос псевдонима структурно идентичен
    // переносу сигнатуры импортированной функции (`imports.symbols`
    // ниже): УЖЕ РАЗРЕШЁННЫЙ `TypeId` псевдонима копируется из
    // хранилища определяющего модуля в хранилище этого модуля через
    // `copyImportedType`. Хранится ОТДЕЛЬНЫМ списком (не объединяется с
    // `symbols`), так как они наполняют разные результирующие карты —
    // `symbols` наполняет `symbol_types` (символы ЗНАЧЕНИЙ: функции/
    // константы), этот список наполняет `type_aliases` (символы ТИПОВ,
    // используемые веткой `.qualified` в `resolveType`). Генерик-
    // псевдонимы типов здесь вне области действия (`ImportedSymbolType.
    // generic_parameters` игнорируется для записей в этом списке).
    type_aliases: []const ImportedSymbolType = &.{},
    nominals: []const ImportedNominal = &.{},
    methods: []const ImportedMethod = &.{},
    impls: []const ImportedImpl = &.{},
    // Истина, если в графе присутствует настоящий модуль прелюдии
    // (`module_loader.Graph.appendPreludeModule`) — в этом случае
    // `preludePass` пропускает собственные захардкоженные заглушки
    // Опция/Результат/интерфейсов (собственные `interfacePass`/
    // `enumPass` этого модуля обрабатывают их напрямую, если ОН сам и
    // есть модуль прелюдии; каждый другой модуль получает настоящие
    // определения, перенесённые через `nominals`/`importIdentityPass`).
    // По умолчанию false — каждый СУЩЕСТВУЮЩИЙ вызывающий (встроенные
    // однофайловые тесты, любой граф, построенный без
    // `appendPreludeModule`) сохраняет прежнее поведение без изменений.
    has_real_prelude: bool = false,
};

pub const IteratorDispatch = enum {
    direct,
    interface,
};

pub const ForInInfo = struct {
    kind: ForInKind,
    iterator_dispatch: IteratorDispatch = .direct,
    next_method: symbols.SymbolId = symbols.invalid_symbol,
    // Позиция `следующий` в собственной vtable интерфейса — используется
    // только при `.iterator_dispatch = .interface`. Вычисляется явно, а
    // не полагается на порядок объявления (`следующий` идёт первым в
    // `prelude.zig`), поскольку после появления у Итерируемое методов по
    // умолчанию этот порядок больше не гарантирован.
    next_method_index: u16 = 0,
};

pub const MethodDefinition = struct {
    owner: symbols.SymbolId,
    interface: ?symbols.SymbolId,
    symbol: symbols.SymbolId,
    name: []const u8,
    owner_parameters: []const GenericParameter,
    function_parameters: []const GenericParameter,
    all_parameters: []const GenericParameter,
};

const NominalOwner = struct {
    symbol: symbols.SymbolId,
    parameters: []const GenericParameter,
};

pub const CheckResult = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    types: types.TypeStore,
    diagnostics: diagnostic.DiagnosticList = .{},
    expression_types: std.AutoHashMap(ast.ExprId, types.TypeId),
    symbol_types: std.AutoHashMap(symbols.SymbolId, types.TypeId),
    unsupported_imports: std.AutoHashMap(symbols.SymbolId, void),
    imported_nominal_identities: std.AutoHashMap(symbols.SymbolId, u32),
    nominal_fields: std.AutoHashMap(symbols.SymbolId, []const NominalField),
    // Виды маршалинга полей (в порядке объявления) ТОЛЬКО для типов
    // `ff_структура` — нужны в точках вызова `внешний` со структурой по
    // значению для построения libffi-структуры `ffi_type` (её массива
    // `elements`) и для упаковки/распаковки сырых байт по смещению
    // каждого поля в C ABI. У обычных (не-`ff_структура`) номинальных
    // типов записи здесь никогда не бывает.
    ffi_struct_layouts: std.AutoHashMap(symbols.SymbolId, []const ast.ForeignMarshalKind),
    type_aliases: std.AutoHashMap(symbols.SymbolId, types.TypeId),
    alias_type_nodes: std.AutoHashMap(symbols.SymbolId, ast.TypeId),
    generic_function_parameters: std.AutoHashMap(symbols.SymbolId, []const GenericParameter),
    generic_nominal_fields: std.AutoHashMap(symbols.SymbolId, GenericNominal),
    enum_definitions: std.AutoHashMap(symbols.SymbolId, EnumDefinition),
    interface_definitions: std.AutoHashMap(symbols.SymbolId, InterfaceDefinition),
    // Какая одноразовая заглушка `genericParameter` (`preludePass`,
    // например `Сравниваемое.сравнить(другое: <заглушка>)`) обозначает
    // "тот же тип, что и реализующий этот интерфейс" — нужна ТОЛЬКО в
    // точке вызова через значение с ИНТЕРФЕЙСНЫМ типом (`x: Сравниваемое;
    // x.сравнить(y)`, `inferInterfaceCall`). Проверка в момент реализации
    // (`defineInterfaceImplementation`) уже разрешает заглушку корректно
    // через обычную генерик-унификацию с конкретной реализацией; в точке
    // вызова конкретного типа для унификации нет (значением может быть
    // ЛЮБОЙ реализующий тип), поэтому единственная корректная подстановка
    // — сам тип ИНТЕРФЕЙСА.
    interface_self_placeholders: std.AutoHashMap(symbols.SymbolId, types.TypeId),
    interface_implementations: std.ArrayList(InterfaceImplementation) = .empty,
    pattern_variants: std.AutoHashMap(ast.PatternId, symbols.SymbolId),
    pattern_types: std.AutoHashMap(ast.PatternId, types.TypeId),
    methods: std.ArrayList(MethodDefinition) = .empty,
    imported_method_parameter_names: std.AutoHashMap(symbols.SymbolId, []const []const u8),
    method_calls: std.AutoHashMap(ast.ExprId, symbols.SymbolId),
    interface_calls: std.AutoHashMap(ast.ExprId, InterfaceCall),
    interface_casts: std.AutoHashMap(ast.ExprId, InterfaceCast),
    call_arguments: std.AutoHashMap(ast.ExprId, []const ast.ExprId),
    for_in_infos: std.AutoHashMap(ast.StmtId, ForInInfo),

    pub fn init(allocator: std.mem.Allocator) !CheckResult {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .types = try types.TypeStore.init(allocator),
            .expression_types = .init(allocator),
            .symbol_types = .init(allocator),
            .unsupported_imports = .init(allocator),
            .imported_nominal_identities = .init(allocator),
            .nominal_fields = .init(allocator),
            .ffi_struct_layouts = .init(allocator),
            .type_aliases = .init(allocator),
            .alias_type_nodes = .init(allocator),
            .generic_function_parameters = .init(allocator),
            .generic_nominal_fields = .init(allocator),
            .enum_definitions = .init(allocator),
            .interface_definitions = .init(allocator),
            .interface_self_placeholders = .init(allocator),
            .pattern_variants = .init(allocator),
            .pattern_types = .init(allocator),
            .method_calls = .init(allocator),
            .interface_calls = .init(allocator),
            .interface_casts = .init(allocator),
            .call_arguments = .init(allocator),
            .for_in_infos = .init(allocator),
            .imported_method_parameter_names = .init(allocator),
        };
    }

    pub fn deinit(self: *CheckResult) void {
        self.for_in_infos.deinit();
        self.call_arguments.deinit();
        self.interface_casts.deinit();
        self.interface_calls.deinit();
        self.method_calls.deinit();
        self.methods.deinit(self.allocator);
        self.imported_method_parameter_names.deinit();
        self.pattern_types.deinit();
        self.pattern_variants.deinit();
        self.interface_implementations.deinit(self.allocator);
        self.interface_definitions.deinit();
        self.interface_self_placeholders.deinit();
        self.enum_definitions.deinit();
        self.generic_nominal_fields.deinit();
        self.generic_function_parameters.deinit();
        self.alias_type_nodes.deinit();
        self.type_aliases.deinit();
        self.nominal_fields.deinit();
        self.ffi_struct_layouts.deinit();
        self.imported_nominal_identities.deinit();
        self.unsupported_imports.deinit();
        self.symbol_types.deinit();
        self.expression_types.deinit();
        self.diagnostics.deinit(self.allocator);
        self.types.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn nominalParametersOf(checked: *const CheckResult, symbol: symbols.SymbolId) []const GenericParameter {
    if (checked.generic_nominal_fields.get(symbol)) |nominal| return nominal.parameters;
    if (checked.enum_definitions.get(symbol)) |enumeration| return enumeration.parameters;
    if (checked.interface_definitions.get(symbol)) |interface| return interface.parameters;
    return &.{};
}

const generic_substitution_pair_limit = 8;
const GenericSubstitutionPair = struct { placeholder: types.TypeId, concrete: types.TypeId };

// `target_arguments` — ФАКТИЧЕСКИЕ/инстанцированные генерик-аргументы
// `target` в ЭТОЙ точке вызова (например, `[Число, Строка]` для
// `Отображённый(Число, Строка)`), отдельно от `InterfaceImplementation.
// arguments` кандидата (ВЫРАЖЕНИЯ над СОБСТВЕННЫМИ объявленными
// заглушками `target`, например `[U_of_Отображённый]` для `реализация
// Итерируемое для Отображённый`, поскольку именно собственный `U`
// Отображённый унифицировался с `T` интерфейса Итерируемое). Быстрый
// путь (точное совпадение) идёт первым — покрывает подавляющее
// большинство не-генерик случаев (ВКЛЮЧАЯ не-генерик target, реализующий
// ОДИН И ТОТ ЖЕ интерфейс с несколькими разными наборами конкретных
// аргументов, например `реализация Получатель(Число)` И `реализация
// Получатель(Строка)` для одной структуры) без лишней работы; резервный
// путь с подстановкой запускается только когда сам target генерик и
// точное совпадение не найдено. Свободная функция (не метод `Checker`),
// чтобы разрешение vtable в `compiler.zig` — у которого есть только
// `*const CheckResult`, а не полный `Checker` — могло переиспользовать
// ТУ ЖЕ логику сопоставления вместо второй, независимо расходящейся
// копии.
// `ambiguous` — опциональный параметр (по умолчанию `null`, сохраняя
// исходное поведение "первое совпадение побеждает" для каждого
// СУЩЕСТВУЮЩЕГО вызывающего — все они проходят через повсеместные
// спекулятивные проверки совместимости в `assignable` и им важен только
// ответ да/нет). Если передан, резервная ветка с генериками продолжает
// сканирование после первого совпадения вместо немедленного возврата и
// выставляет `ambiguous.*`, если найдено ВТОРОЕ генерик-совпадение —
// `emitInterfaceCast` в `compiler.zig` (единственный вызывающий, который
// разрешает РЕАЛЬНУЮ vtable для кодогенерации, где выбор не того
// кандидата означает компиляцию не того метода, а не просто неверный
// статический тип) использует эту опцию.
pub fn findInterfaceImplementation(checked: *const CheckResult, interface: symbols.SymbolId, arguments: []const types.TypeId, target: symbols.SymbolId, target_arguments: []const types.TypeId, ambiguous: ?*bool) ?InterfaceImplementation {
    var found: ?InterfaceImplementation = null;
    for (checked.interface_implementations.items) |implementation| {
        if (implementation.interface != interface or implementation.target != target or implementation.arguments.len != arguments.len) continue;
        var exact = true;
        for (implementation.arguments, arguments) |actual, expected| {
            if (!checked.types.eql(actual, expected)) {
                exact = false;
                break;
            }
        }
        if (exact) return implementation;
        const target_params = nominalParametersOf(checked, target);
        // target с числом генерик-параметров больше
        // `generic_substitution_pair_limit` здесь молча проваливается в
        // "не найдено" вместо более понятной диагностики "слишком много
        // генерик-параметров" — эта функция вызывается через `assignable`,
        // крайне часто вызываемый СПЕКУЛЯТИВНЫЙ запрос совместимости
        // (многим точкам вызова нужен только булев ответ, без утверждения
        // "это ОШИБКА типов" — реальную диагностику, если она нужна,
        // сообщает тот вызывающий, которому действительно требовался
        // ответ). Отчёт отсюда потребовал бы сделать сам `assignable`
        // изменяемым/фаллибельным — большая волна изменений ради случая,
        // который на практике не встречается (8 генерик-параметров на
        // одном target — нереалистичная программа). "Отказ закрытым"
        // (молчаливое "не найдено", как и при любом другом несовпадении)
        // безопасен; вводящим в заблуждение был бы только ТЕКСТ ошибки.
        if (target_params.len != target_arguments.len or target_params.len > generic_substitution_pair_limit) continue;
        var buffer: [generic_substitution_pair_limit]GenericSubstitutionPair = undefined;
        for (target_params, target_arguments, 0..) |param, concrete, i| buffer[i] = .{ .placeholder = param.typ, .concrete = concrete };
        const pairs = buffer[0..target_params.len];
        var matches_generically = true;
        for (implementation.arguments, arguments) |pattern, expected| {
            if (!matchesGenericPatternOf(checked, pattern, expected, pairs)) {
                matches_generically = false;
                break;
            }
        }
        if (matches_generically) {
            if (ambiguous) |flag| {
                if (found != null) {
                    flag.* = true;
                    break;
                }
                found = implementation;
            } else {
                return implementation;
            }
        }
    }
    return found;
}

// Структурная проверка "совпадает ли `pattern` (выражение над TypeId-
// заглушками из `pairs`) с `concrete` после подстановки этих заглушек" —
// неаллоцирующий аналог связки `substituteGeneric` + `TypeStore.eql`,
// намеренно НЕ вызывающий сам `substituteGeneric` (которому нужны
// изменяемый `*Checker`, `!types.TypeId` и `AutoHashMap` в куче — это
// заставило бы `assignable`, одну из самых часто вызываемых функций в
// этом файле, стать фаллибельной/изменяемой — большая волна изменений
// ради проверки, которой нужен только ответ да/нет).
fn matchesGenericPatternOf(checked: *const CheckResult, pattern: types.TypeId, concrete: types.TypeId, pairs: []const GenericSubstitutionPair) bool {
    const pattern_entry = checked.types.get(pattern) orelse return false;
    if (pattern_entry.* == .generic_parameter) {
        for (pairs) |pair| {
            if (pair.placeholder.eql(pattern)) return checked.types.eql(pair.concrete, concrete);
        }
        // `pattern` — генерик-заглушка без записи в `pairs`: она
        // принадлежит какой-то ДРУГОЙ генерик-области, чем та, что
        // подставляется здесь (ошибка вызывающего: `pairs` должен всегда
        // покрывать каждую заглушку, реально достижимую из `pattern`).
        // Откатывается к простому сравнению идентичности, которое почти
        // всегда false и потому безопасно ("отказ закрытым": ложное "не
        // совпадает" безопасно, ложное совпадение — нет) — не сообщается
        // как ошибка, поскольку это внутренняя проверка инварианта, а не
        // пользовательское несоответствие типов.
        return checked.types.eql(pattern, concrete);
    }
    const concrete_entry = checked.types.get(concrete) orelse return false;
    return switch (pattern_entry.*) {
        .tuple => |elements| switch (concrete_entry.*) {
            .tuple => |concrete_elements| matchesGenericPatternSlicesOf(checked, elements, concrete_elements, pairs),
            else => false,
        },
        .array => |element| switch (concrete_entry.*) {
            .array => |concrete_element| matchesGenericPatternOf(checked, element, concrete_element, pairs),
            else => false,
        },
        .map => |map| switch (concrete_entry.*) {
            .map => |concrete_map| matchesGenericPatternOf(checked, map.key, concrete_map.key, pairs) and matchesGenericPatternOf(checked, map.value, concrete_map.value, pairs),
            else => false,
        },
        .function => |function| switch (concrete_entry.*) {
            .function => |concrete_function| matchesGenericPatternSlicesOf(checked, function.parameters, concrete_function.parameters, pairs) and matchesGenericPatternOf(checked, function.return_type, concrete_function.return_type, pairs),
            else => false,
        },
        .nominal => |nominal| switch (concrete_entry.*) {
            .nominal => |concrete_nominal| nominal.symbol == concrete_nominal.symbol and matchesGenericPatternSlicesOf(checked, nominal.arguments, concrete_nominal.arguments, pairs),
            else => false,
        },
        .process => |message| switch (concrete_entry.*) {
            .process => |concrete_message| matchesGenericPatternOf(checked, message, concrete_message, pairs),
            else => false,
        },
        .pointer => |pointee| switch (concrete_entry.*) {
            .pointer => |concrete_pointee| matchesGenericPatternOf(checked, pointee, concrete_pointee, pairs),
            else => false,
        },
        else => checked.types.eql(pattern, concrete),
    };
}

fn matchesGenericPatternSlicesOf(checked: *const CheckResult, patterns: []const types.TypeId, concretes: []const types.TypeId, pairs: []const GenericSubstitutionPair) bool {
    if (patterns.len != concretes.len) return false;
    for (patterns, concretes) |pattern, concrete| {
        if (!matchesGenericPatternOf(checked, pattern, concrete, pairs)) return false;
    }
    return true;
}

const Checker = struct {
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    result: *CheckResult,
    current_return: ?types.TypeId = null,
    current_generic_parameters: []const GenericParameter = &.{},
    current_nominal_owner: ?NominalOwner = null,
    loop_depth: usize = 0,
    next_generic_parameter: u32 = 1,
    target_profile: target_policy.TargetProfile,
    resolving_aliases: std.AutoHashMap(symbols.SymbolId, void),
    has_real_prelude: bool = false,

    fn report(self: *Checker, span: source.Span, comptime format: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.result.arena.allocator(), format, args);
        _ = try self.result.diagnostics.appendUnique(self.result.allocator, .{
            .phase = .type_checker,
            .severity = .err,
            .span = span,
            .message = message,
        });
    }

    // Та же форма, что и `report` выше, но `.severity = .warning` вместо
    // `.err`. Отбор по наличию ошибок (`SourceRun.hasErrors`) уже
    // трактует `.warning` как неблокирующую; именно эта функция и
    // ПОРОЖДАЕТ такую диагностику.
    fn reportWarning(self: *Checker, span: source.Span, comptime format: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.result.arena.allocator(), format, args);
        _ = try self.result.diagnostics.appendUnique(self.result.allocator, .{
            .phase = .type_checker,
            .severity = .warning,
            .span = span,
            .message = message,
        });
    }

    fn signaturePass(self: *Checker) !void {
        for (self.tree.program.?.declarations) |declaration| {
            switch (self.tree.decl(declaration).*) {
                .function => |function| try self.defineFunctionSignature(declaration, function.type_parameters, function.parameters, function.return_type),
                .foreign => |foreign| try self.defineForeignSignature(declaration, foreign),
                .impl => |implementation| {
                    const owner = (if (implementation.target_module) |module_name|
                        self.findQualifiedTypeSymbol(module_name, implementation.target_type)
                    else
                        self.findTypeSymbol(implementation.target_type)) orelse {
                        try self.report(implementation.span, "Type Error: неизвестный тип реализации '{s}'", .{implementation.target_type});
                        continue;
                    };
                    const owner_parameters = self.nominalParameters(owner);
                    if (implementation.interface_name) |interface_name| {
                        try self.defineInterfaceImplementation(implementation, owner, owner_parameters, interface_name, implementation.interface_module);
                    } else {
                        for (implementation.methods) |method| {
                            const function = self.tree.decl(method).function;
                            try self.defineMethodSignature(method, owner, null, owner_parameters, function.type_parameters, function.parameters, function.return_type);
                        }
                    }
                },
                else => {},
            }
        }
    }

    // Регистрирует непрозрачную межмодульную идентичность для каждого
    // импортируемого номинального типа ДО запуска `signaturePass` —
    // `signaturePass` уже разрешает квалифицированные аннотации типов
    // (например, параметр-получатель импла, `это: точки.Точка`) через
    // `nominalType`, которая читает `imported_nominal_identities`; запуск
    // этого после `signaturePass` оставлял бы каждую квалифицированную
    // аннотацию, разрешённую во время `signaturePass`, молча со значением
    // по умолчанию identity=0 вместо настоящей непрозрачной идентичности,
    // вызывая "получатель метода имеет неверный тип" для
    // квалифицированной цели импла внутри одного модуля (`реализация
    // точки.Точка ... конец`) — аннотация и собственное значение точки
    // вызова получали бы РАЗНЫЕ идентичности для одного и того же типа.
    // Также строит переотображение генерик-параметров по владельцам и,
    // для импортированного типа-ИНТЕРФЕЙСА, его `InterfaceDefinition` —
    // оба должны существовать до запуска `signaturePass`, так как она
    // разрешает квалифицированные цели импла (`реализация
    // чужой_модуль.Интерфейс для Тип`) и сразу нуждается в
    // `interface_definitions` для проверки реализации. `owner_remaps`/
    // `owner_parameters_by_symbol` затем переиспользуются как есть в
    // `importSignaturePass` для полей/вариантов перечисления/методов/
    // реализаций, которым не нужен настолько ранний запуск.
    fn importIdentityPass(
        self: *Checker,
        imports: ImportContext,
        owner_remaps: *std.AutoHashMap(symbols.SymbolId, std.AutoHashMap(types.TypeId, types.TypeId)),
        owner_parameters_by_symbol: *std.AutoHashMap(symbols.SymbolId, []const GenericParameter),
    ) !void {
        for (imports.nominals) |imported| {
            try self.result.imported_nominal_identities.put(imported.local_symbol, imported.identity);
            if (imported.generic_parameters) |source_parameters| {
                var remap = std.AutoHashMap(types.TypeId, types.TypeId).init(self.result.allocator);
                var owner_parameters: std.ArrayList(GenericParameter) = .empty;
                defer owner_parameters.deinit(self.result.allocator);
                for (source_parameters) |parameter| {
                    const local_typ = try self.result.types.genericParameter(self.next_generic_parameter);
                    self.next_generic_parameter += 1;
                    try remap.put(parameter.typ, local_typ);
                    try owner_parameters.append(self.result.allocator, .{
                        .name = try self.result.arena.allocator().dupe(u8, parameter.name),
                        .typ = local_typ,
                    });
                }
                try owner_remaps.put(imported.local_symbol, remap);
                try owner_parameters_by_symbol.put(imported.local_symbol, try self.result.arena.allocator().dupe(GenericParameter, owner_parameters.items));
            }
            const owner_remap = owner_remaps.getPtr(imported.local_symbol);
            if (imported.interface_methods) |source_methods| {
                var methods: std.ArrayList(InterfaceMethod) = .empty;
                defer methods.deinit(self.result.allocator);
                var unsupported = false;
                for (source_methods, 0..) |source_method, method_index| {
                    var parameters: std.ArrayList(types.TypeId) = .empty;
                    defer parameters.deinit(self.result.allocator);
                    for (source_method.parameters) |parameter| {
                        const copied = self.copyImportedType(imported.definition_store, parameter, imports.nominals, owner_remap) catch |err| switch (err) {
                            error.UnsupportedImportedType => {
                                unsupported = true;
                                break;
                            },
                            else => return err,
                        };
                        try parameters.append(self.result.allocator, copied);
                    }
                    if (unsupported) break;
                    const return_type = self.copyImportedType(imported.definition_store, source_method.return_type, imports.nominals, owner_remap) catch |err| switch (err) {
                        error.UnsupportedImportedType => {
                            unsupported = true;
                            break;
                        },
                        else => return err,
                    };
                    const default_symbol = if (imported.default_method_symbols) |defaults| defaults[method_index] else null;
                    try methods.append(self.result.allocator, .{
                        .name = try self.result.arena.allocator().dupe(u8, source_method.name),
                        .parameters = try self.result.arena.allocator().dupe(types.TypeId, parameters.items),
                        .return_type = return_type,
                        .default_symbol = default_symbol,
                    });
                }
                if (!unsupported) {
                    const parameters = owner_parameters_by_symbol.get(imported.local_symbol) orelse &.{};
                    try self.result.interface_definitions.put(imported.local_symbol, .{
                        .parameters = parameters,
                        .methods = try self.result.arena.allocator().dupe(InterfaceMethod, methods.items),
                    });
                }
            }
        }
    }

    fn importSignaturePass(
        self: *Checker,
        imports: ImportContext,
        owner_remaps: *std.AutoHashMap(symbols.SymbolId, std.AutoHashMap(types.TypeId, types.TypeId)),
        owner_parameters_by_symbol: *std.AutoHashMap(symbols.SymbolId, []const GenericParameter),
    ) !void {
        for (imports.nominals) |imported| {
            const owner_remap = owner_remaps.getPtr(imported.local_symbol);
            if (imported.fields) |source_fields| {
                var fields: std.ArrayList(NominalField) = .empty;
                defer fields.deinit(self.result.allocator);
                for (source_fields) |field| {
                    // Тип поля может ссылаться на номинальный тип из
                    // модуля, который ТЕКУЩИЙ файл никогда не импортирует
                    // напрямую (поле импортированной структуры,
                    // указывающее на тип ТРЕТЬЕГО модуля, например
                    // `слог.Логгер`, достижимый через `Менеджер.логгер`,
                    // когда здесь импортирован только модуль-владелец
                    // `Менеджер`) — `imports.nominals` перечисляет только
                    // СОБСТВЕННЫЕ прямые импорты локального файла, поэтому
                    // `copyImportedType` закономерно не может его
                    // разрешить. Откатывается к `poison` (совместим с чем
                    // угодно в обе стороны, см. верхнюю проверку в самом
                    // `assignable`) вместо того, чтобы дать
                    // `error.UnsupportedImportedType` распространиться
                    // необработанным.
                    const field_type = self.copyImportedType(imported.definition_store, field.typ, imports.nominals, owner_remap) catch |err| switch (err) {
                        error.UnsupportedImportedType => try self.result.types.poison(),
                        else => return err,
                    };
                    try fields.append(self.result.allocator, .{
                        .name = try self.result.arena.allocator().dupe(u8, field.name),
                        .typ = field_type,
                    });
                }
                const copied_fields = try self.result.arena.allocator().dupe(NominalField, fields.items);
                if (owner_parameters_by_symbol.get(imported.local_symbol)) |parameters| {
                    try self.result.generic_nominal_fields.put(imported.local_symbol, .{ .parameters = parameters, .fields = copied_fields });
                } else {
                    try self.result.nominal_fields.put(imported.local_symbol, copied_fields);
                }
            }
            if (imported.enum_variants) |source_variants| {
                var variants: std.ArrayList(EnumVariant) = .empty;
                defer variants.deinit(self.result.allocator);
                for (source_variants) |source_variant| {
                    const variant_symbol = self.resolution.findEnumVariant(imported.local_symbol, source_variant.name) orelse continue;
                    var fields: std.ArrayList(types.TypeId) = .empty;
                    defer fields.deinit(self.result.allocator);
                    for (source_variant.fields) |field| {
                        const field_type = self.copyImportedType(imported.definition_store, field, imports.nominals, owner_remap) catch |err| switch (err) {
                            error.UnsupportedImportedType => try self.result.types.poison(),
                            else => return err,
                        };
                        try fields.append(self.result.allocator, field_type);
                    }
                    try variants.append(self.result.allocator, .{
                        .symbol = variant_symbol,
                        .name = try self.result.arena.allocator().dupe(u8, source_variant.name),
                        .fields = try self.result.arena.allocator().dupe(types.TypeId, fields.items),
                    });
                }
                const parameters = owner_parameters_by_symbol.get(imported.local_symbol) orelse &.{};
                try self.result.enum_definitions.put(imported.local_symbol, .{
                    .parameters = parameters,
                    .variants = try self.result.arena.allocator().dupe(EnumVariant, variants.items),
                });
            }
        }
        for (imports.symbols) |imported| {
            // Импортированная ГЕНЕРИК-ФУНКЦИЯ верхнего уровня — чеканим
            // свежие ЛОКАЛЬНЫЕ TypeId генерик-параметров (по одному на
            // параметр цели), переотображаем сигнатуру через них (вместо
            // `null`, который молча превращает в poison каждую ссылку на
            // `T` — см. doc-комментарий у `ImportedSymbolType.
            // generic_parameters`), и регистрируем переотображённые
            // параметры/ограничения в `generic_function_parameters`, чтобы
            // существующий механизм точки вызова этого же файла
            // (`interfaceBoundOf`/подстановка при генерик-вызове) работал
            // идентично и для межмодульного вызова.
            var local_generic_remap: ?std.AutoHashMap(types.TypeId, types.TypeId) = null;
            defer if (local_generic_remap) |*map| map.deinit();
            if (imported.generic_parameters) |target_parameters| {
                var remap = std.AutoHashMap(types.TypeId, types.TypeId).init(self.result.allocator);
                var local_parameters: std.ArrayList(GenericParameter) = .empty;
                defer local_parameters.deinit(self.result.allocator);
                var unsupported_contract = false;
                for (target_parameters) |target_parameter| {
                    const local_typ = try self.result.types.genericParameter(self.next_generic_parameter);
                    self.next_generic_parameter += 1;
                    try remap.put(target_parameter.typ, local_typ);
                    var local_bounds: std.ArrayList(symbols.SymbolId) = .empty;
                    defer local_bounds.deinit(self.result.allocator);
                    for (target_parameter.bounds) |target_bound| {
                        var remapped = false;
                        // Двухходовой bound (интерфейс объявлен в ТРЕТЬЕМ
                        // модуле относительно и функции, и потребителя) уже
                        // переведён в ЛОКАЛЬНЫЙ символ ЭТОГО потребителя
                        // module_compiler.zig's translateGenericParameterBounds
                        // (identity-based) — совпадение по local_symbol
                        // проверяется первым, тот же порядок, что и у
                        // импортированных МЕТОДОВ ниже. Одноходовой (bound
                        // объявлен в том же модуле, что и функция) остаётся
                        // непереведённым — совпадает по старому пути.
                        for (imports.nominals) |nominal| {
                            if (nominal.local_symbol == target_bound) {
                                try local_bounds.append(self.result.allocator, nominal.local_symbol);
                                remapped = true;
                                break;
                            }
                        }
                        if (!remapped) for (imports.nominals) |nominal| {
                            if (nominal.store != imported.store or nominal.source_symbol != target_bound) continue;
                            try local_bounds.append(self.result.allocator, nominal.local_symbol);
                            remapped = true;
                            break;
                        };
                        // Ограничение — часть контракта экспортируемой
                        // функции. Отбросить его — значит превратить
                        // `[T: Интерфейс]` в `[T]` и позволить неприведённому
                        // значению дойти до интерфейсной диспетчеризации
                        // исходного модуля во время выполнения. Импортируем
                        // только полный контракт.
                        if (!remapped) {
                            unsupported_contract = true;
                            break;
                        }
                    }
                    if (unsupported_contract) break;
                    try local_parameters.append(self.result.allocator, .{
                        .name = target_parameter.name,
                        .typ = local_typ,
                        .bounds = try self.result.arena.allocator().dupe(symbols.SymbolId, local_bounds.items),
                    });
                }
                if (unsupported_contract) {
                    remap.deinit();
                    try self.result.unsupported_imports.put(imported.symbol, {});
                    continue;
                }
                // Инвариант, на котором держится весь этот шаг переноса:
                // один свежий локальный TypeId на параметр цели, без
                // коллизий, ничего не потеряно. Нарушение здесь молча
                // породило бы НЕВЕРНУЮ межмодульную генерик-сигнатуру —
                // громко проверяем через assert в Debug вместо
                // компиляции тонко некорректной сигнатуры, которая
                // проявится позже как непонятный крах на этапе
                // выполнения, тремя слоями дальше, в ДРУГОМ файле.
                std.debug.assert(remap.count() == target_parameters.len);
                std.debug.assert(local_parameters.items.len == target_parameters.len);
                try self.result.generic_function_parameters.put(imported.symbol, try self.result.arena.allocator().dupe(GenericParameter, local_parameters.items));
                local_generic_remap = remap;
            }
            const copied = self.copyImportedType(imported.store, imported.type_id, imports.nominals, if (local_generic_remap) |*map| map else null) catch |err| switch (err) {
                error.UnsupportedImportedType => {
                    try self.result.unsupported_imports.put(imported.symbol, {});
                    continue;
                },
                else => return err,
            };
            try self.result.symbol_types.put(imported.symbol, copied);
        }
        for (imports.type_aliases) |imported| {
            const copied = self.copyImportedType(imported.store, imported.type_id, imports.nominals, null) catch |err| switch (err) {
                error.UnsupportedImportedType => continue,
                else => return err,
            };
            try self.result.type_aliases.put(imported.symbol, copied);
        }
        for (imports.methods) |imported| {
            // Собственные generic-параметры МЕТОДА (`отправить_пост[Тело:
            // ИзJSON, ...]`) переносятся ОТДЕЛЬНО от `owner_remap` (тот
            // покрывает только generic-параметры ВЛАДЕЮЩЕЙ структуры,
            // например `Коробка[T]`) — тот же приём, что уже применяется
            // чуть выше для импортированных СВОБОДНЫХ generic-функций
            // (`imports.symbols`, см. `local_generic_remap`), просто
            // объединённый с `owner_remap` в ОДНУ карту, потому что метод
            // может одновременно ссылаться на generic-параметры и
            // владельца, и свои собственные. Без этого `Тело`, встреченный
            // ВНУТРИ типа параметра-функции (`функ() -> Тело`), молча
            // вырождался в `poison` — `owner_remap` не содержал для него
            // записи (см. `ImportedMethod.generic_parameters`'s
            // doc-комментарий).
            var combined_remap: ?std.AutoHashMap(types.TypeId, types.TypeId) = null;
            defer if (combined_remap) |*map| map.deinit();
            var method_parameters: []const GenericParameter = &.{};
            if (imported.generic_parameters) |target_parameters| method_build: {
                var remap = std.AutoHashMap(types.TypeId, types.TypeId).init(self.result.allocator);
                if (owner_remaps.getPtr(imported.owner)) |existing| {
                    var it = existing.iterator();
                    while (it.next()) |entry| try remap.put(entry.key_ptr.*, entry.value_ptr.*);
                }
                var local_parameters: std.ArrayList(GenericParameter) = .empty;
                defer local_parameters.deinit(self.result.allocator);
                var unsupported_contract = false;
                for (target_parameters) |target_parameter| {
                    const local_typ = try self.result.types.genericParameter(self.next_generic_parameter);
                    self.next_generic_parameter += 1;
                    try remap.put(target_parameter.typ, local_typ);
                    var local_bounds: std.ArrayList(symbols.SymbolId) = .empty;
                    defer local_bounds.deinit(self.result.allocator);
                    for (target_parameter.bounds) |target_bound| {
                        var remapped = false;
                        // Двухходовой bound (интерфейс объявлен в ТРЕТЬЕМ
                        // модуле относительно и метода, и потребителя) уже
                        // переведён в ЛОКАЛЬНЫЙ символ ЭТОГО потребителя
                        // module_compiler.zig's translateGenericParameterBounds
                        // (identity-based, надёжно через любое число хопов/
                        // реэкспортов) — совпадение по local_symbol
                        // проверяется первым и не требует дополнительно
                        // store/source_symbol. Одноходовой (локально
                        // объявленный в том же файле, что и метод) bound
                        // остаётся непереведённым — совпадает по старому
                        // пути ниже.
                        for (imports.nominals) |nominal| {
                            if (nominal.local_symbol == target_bound) {
                                try local_bounds.append(self.result.allocator, nominal.local_symbol);
                                remapped = true;
                                break;
                            }
                        }
                        if (!remapped) for (imports.nominals) |nominal| {
                            if (nominal.store != imported.store or nominal.source_symbol != target_bound) continue;
                            try local_bounds.append(self.result.allocator, nominal.local_symbol);
                            remapped = true;
                            break;
                        };
                        // Тот же принцип "полный контракт или ничего", что
                        // и у свободных generic-функций выше — отбросить
                        // ограничение значило бы позволить неприведённому
                        // значению дойти до интерфейсной диспетчеризации
                        // исходного модуля во время выполнения.
                        if (!remapped) {
                            unsupported_contract = true;
                            break;
                        }
                    }
                    if (unsupported_contract) break;
                    try local_parameters.append(self.result.allocator, .{
                        .name = target_parameter.name,
                        .typ = local_typ,
                        .bounds = try self.result.arena.allocator().dupe(symbols.SymbolId, local_bounds.items),
                    });
                }
                if (unsupported_contract) {
                    remap.deinit();
                    try self.result.unsupported_imports.put(imported.symbol, {});
                    continue;
                }
                method_parameters = try self.result.arena.allocator().dupe(GenericParameter, local_parameters.items);
                combined_remap = remap;
                break :method_build;
            }
            const owner_remap = if (combined_remap) |*map| map else owner_remaps.getPtr(imported.owner);
            const copied = self.copyImportedType(imported.store, imported.type_id, imports.nominals, owner_remap) catch |err| switch (err) {
                error.UnsupportedImportedType => continue,
                else => return err,
            };
            try self.result.symbol_types.put(imported.symbol, copied);
            try self.result.imported_method_parameter_names.put(imported.symbol, imported.parameter_names);
            const owner_parameters = owner_parameters_by_symbol.get(imported.owner) orelse &.{};
            var all_parameters: std.ArrayList(GenericParameter) = .empty;
            defer all_parameters.deinit(self.result.allocator);
            try all_parameters.appendSlice(self.result.allocator, owner_parameters);
            try all_parameters.appendSlice(self.result.allocator, method_parameters);
            try self.result.methods.append(self.result.allocator, .{
                .owner = imported.owner,
                .interface = null,
                .symbol = imported.symbol,
                .name = imported.name,
                .owner_parameters = owner_parameters,
                .function_parameters = method_parameters,
                .all_parameters = try self.result.arena.allocator().dupe(GenericParameter, all_parameters.items),
            });
        }
        for (imports.impls) |imported| {
            const interface_symbol = imported.interface_symbol orelse self.findTypeSymbol(imported.interface_name) orelse continue;
            const owner_remap = owner_remaps.getPtr(imported.owner);
            var arguments: std.ArrayList(types.TypeId) = .empty;
            defer arguments.deinit(self.result.allocator);
            var unsupported = false;
            for (imported.argument_type_ids) |argument| {
                const copied = self.copyImportedType(imported.store, argument, imports.nominals, owner_remap) catch |err| switch (err) {
                    error.UnsupportedImportedType => {
                        unsupported = true;
                        break;
                    },
                    else => return err,
                };
                try arguments.append(self.result.allocator, copied);
            }
            if (unsupported) continue;
            var methods: std.ArrayList(symbols.SymbolId) = .empty;
            defer methods.deinit(self.result.allocator);
            const local_definition = self.result.interface_definitions.get(interface_symbol);
            for (imported.method_symbols) |source_method_symbol| {
                const source_method = imported.target_resolution.symbols.get(source_method_symbol) orelse continue;
                if (self.inherentMethod(imported.owner, source_method.name)) |method| {
                    try methods.append(self.result.allocator, method.symbol);
                    continue;
                }
                // Не переопределение — `source_method_symbol` — символ
                // метода ПО УМОЛЧАНИЮ (из пространства символов ИСХОДНОГО
                // модуля, здесь бессмыслен). Откатываемся к копии
                // значения по умолчанию для метода с этим именем из ТОГО
                // ЖЕ интерфейса, но уже принадлежащей ЭТОМУ модулю (уже
                // корректно перенесённой, см. `default_method_symbols`).
                if (local_definition) |definition| {
                    if (self.interfaceMethod(definition, source_method.name)) |interface_method| {
                        if (interface_method.default_symbol) |default_symbol| {
                            try methods.append(self.result.allocator, default_symbol);
                        }
                    }
                }
            }
            if (methods.items.len != imported.method_symbols.len) continue;
            try self.result.interface_implementations.append(self.result.allocator, .{
                .interface = interface_symbol,
                .arguments = try self.result.arena.allocator().dupe(types.TypeId, arguments.items),
                .target = imported.owner,
                .methods = try self.result.arena.allocator().dupe(symbols.SymbolId, methods.items),
            });
        }
    }

    // `generic_remap` отображает внешний TypeId генерик-параметра в
    // СВЕЖИЙ локальный TypeId генерик-параметра, чеканится один раз на
    // импортируемого генерик-владельца и переиспользуется во всех его
    // полях/вариантах/методах, чтобы `T` в поле структуры и `T` в одном
    // из её импортированных методов оказались ОДНИМ И ТЕМ ЖЕ локальным
    // типом — без него (null) `.generic_parameter` остаётся
    // неподдерживаемым, сохраняя прежнее поведение для не-генерик
    // импортов.
    // ВЛОЖЕННАЯ ссылка на тип, которую нельзя скопировать (см. ветку
    // `.nominal` в `copyImportedType`), здесь вырождается в `poison`
    // вместо провала ВСЕГО содержащего типа — `poison` совместим с чем
    // угодно в обе стороны (см. верхнюю проверку в самом `assignable`),
    // поэтому одно поле/параметр/возврат, достигающее типа из модуля,
    // который текущий файл не импортирует напрямую
    // (`Менеджер.логгер: слог.Логгер`, когда импортирован только модуль
    // `Менеджер`), больше не обрушивает всю сигнатуру структуры/метода
    // целиком. ВЕРХНЕУРОВНЕВЫЙ вызов (собственный `try
    // self.copyImportedType(...)` из `imports.symbols`) по-прежнему
    // пробрасывает ошибку необработанной — этому пути нужна диагностика
    // "импортированный экспорт '...' использует пока неподдерживаемый
    // тип", а не тихий poison.
    fn copyImportedTypeOrPoison(self: *Checker, external_store: *const types.TypeStore, external_type: types.TypeId, nominals: []const ImportedNominal, generic_remap: ?*const std.AutoHashMap(types.TypeId, types.TypeId)) anyerror!types.TypeId {
        return self.copyImportedType(external_store, external_type, nominals, generic_remap) catch |err| switch (err) {
            error.UnsupportedImportedType => self.result.types.poison(),
            else => err,
        };
    }

    fn copyImportedType(self: *Checker, external_store: *const types.TypeStore, external_type: types.TypeId, nominals: []const ImportedNominal, generic_remap: ?*const std.AutoHashMap(types.TypeId, types.TypeId)) !types.TypeId {
        const entry = try external_store.require(external_type);
        return switch (entry.*) {
            .primitive => |primitive| switch (primitive) {
                .number => self.result.types.builtins.number,
                .integer => self.result.types.builtins.integer,
                .boolean => self.result.types.builtins.boolean,
                .void => self.result.types.builtins.void,
                .never => self.result.types.builtins.never,
                .string => self.result.types.builtins.string,
                .error_value => self.result.types.builtins.error_value,
            },
            .tuple => |elements| blk: {
                var copied: std.ArrayList(types.TypeId) = .empty;
                defer copied.deinit(self.result.allocator);
                for (elements) |element| try copied.append(self.result.allocator, try self.copyImportedTypeOrPoison(external_store, element, nominals, generic_remap));
                break :blk self.result.types.tuple(copied.items);
            },
            .function => |function| blk: {
                var copied: std.ArrayList(types.TypeId) = .empty;
                defer copied.deinit(self.result.allocator);
                for (function.parameters) |parameter| try copied.append(self.result.allocator, try self.copyImportedTypeOrPoison(external_store, parameter, nominals, generic_remap));
                break :blk self.result.types.function(copied.items, try self.copyImportedTypeOrPoison(external_store, function.return_type, nominals, generic_remap));
            },
            .nominal => |nominal| blk: {
                for (nominals) |imported| {
                    if (imported.store != external_store or imported.source_symbol != nominal.symbol) continue;
                    var arguments: std.ArrayList(types.TypeId) = .empty;
                    defer arguments.deinit(self.result.allocator);
                    for (nominal.arguments) |argument| try arguments.append(self.result.allocator, try self.copyImportedTypeOrPoison(external_store, argument, nominals, generic_remap));
                    break :blk self.result.types.nominalWithIdentity(imported.local_symbol, imported.identity, arguments.items);
                }
                return error.UnsupportedImportedType;
            },
            .array => |element| self.result.types.array(try self.copyImportedTypeOrPoison(external_store, element, nominals, generic_remap)),
            .map => |map| self.result.types.map(
                try self.copyImportedTypeOrPoison(external_store, map.key, nominals, generic_remap),
                try self.copyImportedTypeOrPoison(external_store, map.value, nominals, generic_remap),
            ),
            .process => |message| self.result.types.process(try self.copyImportedTypeOrPoison(external_store, message, nominals, generic_remap)),
            // `Сообщение(T)` на практике никогда не нуждается в
            // межмодульном копировании (встречается только как
            // СОБСТВЕННЫЙ объявленный тип возврата функции, используется
            // локально в `checkFunction`/`inferSpawn`/встроенной
            // `получить` — никогда не хранится в поле, переменной или
            // генерик-аргументе, которым потребовался бы перенос в
            // хранилище другого модуля) — тем не менее обрабатывается
            // здесь структурно, той же формой, что и `.process`, ради
            // полноты, а не в расчёте на то, что этот switch останется
            // молча неисчерпывающим.
            .message => |payload| self.result.types.message(try self.copyImportedTypeOrPoison(external_store, payload, nominals, generic_remap)),
            .pointer => |pointee| self.result.types.pointer(try self.copyImportedTypeOrPoison(external_store, pointee, nominals, generic_remap)),
            .generic_parameter => blk: {
                const remap = generic_remap orelse return error.UnsupportedImportedType;
                break :blk remap.get(external_type) orelse return error.UnsupportedImportedType;
            },
            .poison, .unconstrained => error.UnsupportedImportedType,
        };
    }

    fn typeAliasPass(self: *Checker) !void {
        for (self.tree.program.?.declarations) |declaration| {
            const alias = switch (self.tree.decl(declaration).*) {
                .type_alias => |value| value,
                else => continue,
            };
            const symbol = self.resolution.decl_symbols.get(declaration) orelse continue;
            try self.result.alias_type_nodes.put(symbol, alias.aliased_type);
        }
    }

    // Принудительно разрешает КАЖДЫЙ объявленный псевдоним в
    // `self.result.type_aliases`, независимо от того, ссылается ли на
    // него СОБСТВЕННЫЙ код этого модуля — иначе `resolveAlias` чисто
    // ленивая (разрешается только при первом тайпчеке ССЫЛКИ), что
    // нормально для использования внутри модуля, но оставляет
    // ТОЛЬКО-ЭКСПОРТИРУЕМЫЙ псевдоним (объявлен, но никогда не
    // используется локально — например, псевдоним типа, предназначенный
    // исключительно для импорта другими модулями) вовсе без записи к
    // моменту завершения `CheckResult` этого модуля. Межмодульному
    // переносу в `module_compiler.zig` эта запись нужна безусловно,
    // чтобы квалифицированная ссылка (`lib.Обработчик`) в ДРУГОМ модуле
    // могла найти настоящую форму псевдонима (например, тип функции)
    // вместо отката к непрозрачному номинальному типу вовсе без
    // вызываемой формы.
    fn eagerAliasResolutionPass(self: *Checker) !void {
        var it = self.result.alias_type_nodes.keyIterator();
        while (it.next()) |symbol_ptr| {
            const symbol = symbol_ptr.*;
            if (self.result.type_aliases.contains(symbol)) continue;
            const span = if (self.resolution.symbols.get(symbol)) |entry| entry.span else source.Span{ .file_id = 0, .start = 0, .end = 0 };
            _ = try self.resolveAlias(symbol, span);
        }
    }

    fn nominalPass(self: *Checker) !void {
        for (self.tree.program.?.declarations) |declaration| {
            const structure = switch (self.tree.decl(declaration).*) {
                .struct_decl => |value| value,
                else => continue,
            };
            const symbol = self.resolution.decl_symbols.get(declaration) orelse continue;
            if (structure.is_ffi) {
                // Поля `ff_структура` несут вид маршалинга, а не
                // настоящую аннотацию типа (`parseFfiStructDeclaration` в
                // parser.zig ограничивает их значениями
                // Целое(8|32|64)/Число(32|64) — всегда скаляр, никогда
                // не вложенный тип) — панос-ТИП поля выводится из этого
                // вида маршалинга тем же способом, что и тип обычного
                // параметра `внешний функ` (`foreignMarshalType`), так
                // что конструирование `Вектор2(x, y)`/`.x` и доступ к
                // полям получают ту же настоящую проверку арности/типов,
                // что уже есть у полей обычной структуры.
                var ffi_fields: std.ArrayList(NominalField) = .empty;
                defer ffi_fields.deinit(self.result.allocator);
                var layout: std.ArrayList(ast.ForeignMarshalKind) = .empty;
                defer layout.deinit(self.result.allocator);
                for (structure.fields) |field| {
                    const kind = field.marshal orelse .int32;
                    try ffi_fields.append(self.result.allocator, .{
                        .name = field.name,
                        .typ = try self.foreignMarshalType(kind, null, null, field.span),
                    });
                    try layout.append(self.result.allocator, kind);
                }
                try self.result.nominal_fields.put(symbol, try self.result.arena.allocator().dupe(NominalField, ffi_fields.items));
                try self.result.ffi_struct_layouts.put(symbol, try self.result.arena.allocator().dupe(ast.ForeignMarshalKind, layout.items));
                continue;
            }
            var fields: std.ArrayList(NominalField) = .empty;
            defer fields.deinit(self.result.allocator);
            const generic_parameters = try self.defineGenericNominalParameters(symbol, structure.type_parameters);
            const resolved_fields = blk: {
                const previous_generic_parameters = self.current_generic_parameters;
                self.current_generic_parameters = generic_parameters;
                defer self.current_generic_parameters = previous_generic_parameters;
                for (structure.fields) |field| {
                    const annotation = field.type_annotation orelse continue;
                    try fields.append(self.result.allocator, .{
                        .name = field.name,
                        .typ = try self.resolveType(annotation),
                    });
                }
                break :blk try self.result.arena.allocator().dupe(NominalField, fields.items);
            };
            if (generic_parameters.len == 0) {
                try self.result.nominal_fields.put(symbol, resolved_fields);
            } else {
                try self.result.generic_nominal_fields.put(symbol, .{
                    .parameters = generic_parameters,
                    .fields = resolved_fields,
                });
            }
        }
    }

    // У нативных модулей нет AST-объявления, из которого `nominalPass`
    // могла бы прочитать поля. Материализуем публичную раскладку
    // события клика прямо здесь; порядок объявления — это же порядок
    // полей в памяти у WASM-трамплина.
    fn nativeNominalPass(self: *Checker) !void {
        for (self.resolution.symbols.symbols.items[1..], 1..) |entry, index| {
            if (entry.kind != .type or entry.module_path == null) continue;
            if (!std.mem.eql(u8, entry.module_path.?, "DOM") or !std.mem.eql(u8, entry.name, "СобытиеКлика")) continue;
            const symbol: symbols.SymbolId = @enumFromInt(index);
            const fields = try self.result.arena.allocator().alloc(NominalField, 7);
            fields[0] = .{ .name = "клиент_x", .typ = self.result.types.builtins.number };
            fields[1] = .{ .name = "клиент_y", .typ = self.result.types.builtins.number };
            fields[2] = .{ .name = "кнопка", .typ = self.result.types.builtins.integer };
            fields[3] = .{ .name = "ctrl", .typ = self.result.types.builtins.boolean };
            fields[4] = .{ .name = "shift", .typ = self.result.types.builtins.boolean };
            fields[5] = .{ .name = "alt", .typ = self.result.types.builtins.boolean };
            fields[6] = .{ .name = "meta", .typ = self.result.types.builtins.boolean };
            try self.result.nominal_fields.put(symbol, fields);
        }
    }

    fn enumPass(self: *Checker) !void {
        for (self.tree.program.?.declarations) |declaration| {
            const enumeration = switch (self.tree.decl(declaration).*) {
                .enum_decl => |value| value,
                else => continue,
            };
            const symbol = self.resolution.decl_symbols.get(declaration) orelse continue;
            const parameters = try self.defineGenericEnumParameters(enumeration.type_parameters);
            var variants: std.ArrayList(EnumVariant) = .empty;
            defer variants.deinit(self.result.allocator);
            const previous_generic_parameters = self.current_generic_parameters;
            self.current_generic_parameters = parameters;
            defer self.current_generic_parameters = previous_generic_parameters;
            for (enumeration.variants) |variant| {
                const variant_symbol = self.resolution.findEnumVariant(symbol, variant.name) orelse continue;
                var fields: std.ArrayList(types.TypeId) = .empty;
                defer fields.deinit(self.result.allocator);
                for (variant.types) |field| try fields.append(self.result.allocator, try self.resolveType(field));
                try variants.append(self.result.allocator, .{
                    .symbol = variant_symbol,
                    .name = variant.name,
                    .fields = try self.result.arena.allocator().dupe(types.TypeId, fields.items),
                });
            }
            try self.result.enum_definitions.put(symbol, .{
                .parameters = parameters,
                .variants = try self.result.arena.allocator().dupe(EnumVariant, variants.items),
            });
        }
    }

    fn interfacePass(self: *Checker) !void {
        for (self.tree.program.?.declarations) |declaration| {
            const interface = switch (self.tree.decl(declaration).*) {
                .interface_decl => |value| value,
                else => continue,
            };
            const symbol = self.resolution.decl_symbols.get(declaration) orelse continue;
            const parameters = try self.defineGenericNominalParameters(symbol, interface.type_parameters);
            const previous_generic_parameters = self.current_generic_parameters;
            self.current_generic_parameters = parameters;
            defer self.current_generic_parameters = previous_generic_parameters;
            var owner_arguments: std.ArrayList(types.TypeId) = .empty;
            defer owner_arguments.deinit(self.result.allocator);
            for (parameters) |parameter| try owner_arguments.append(self.result.allocator, parameter.typ);
            const receiver = try self.result.types.nominal(symbol, owner_arguments.items);
            var methods: std.ArrayList(InterfaceMethod) = .empty;
            defer methods.deinit(self.result.allocator);
            for (interface.methods) |method| {
                const default_decl = self.findDefaultMethodDecl(interface.default_methods, method.name);
                var default_symbol: ?symbols.SymbolId = null;
                // СОБСТВЕННЫЕ параметры типа метода по умолчанию
                // (`отобразить[U](...)`) должны быть в области видимости
                // ДО разрешения чего бы то ни было — включая
                // АБСТРАКТНУЮ сигнатуру `method.parameters`/`.return_type`
                // ниже, которая ссылается на тот же `U`.
                var method_scope = parameters;
                if (default_decl) |decl| {
                    const function = self.tree.decl(decl).function;
                    default_symbol = self.resolution.decl_symbols.get(decl);
                    if (default_symbol) |sym| {
                        const method_own = try self.defineGenericParameters(sym, function.type_parameters);
                        if (method_own.len != 0) {
                            var combined: std.ArrayList(GenericParameter) = .empty;
                            defer combined.deinit(self.result.allocator);
                            try combined.appendSlice(self.result.allocator, parameters);
                            try combined.appendSlice(self.result.allocator, method_own);
                            method_scope = try self.result.arena.allocator().dupe(GenericParameter, combined.items);
                        }
                    }
                }
                const previous_method_scope = self.current_generic_parameters;
                self.current_generic_parameters = method_scope;
                defer self.current_generic_parameters = previous_method_scope;

                var method_parameters: std.ArrayList(types.TypeId) = .empty;
                defer method_parameters.deinit(self.result.allocator);
                for (method.parameters) |parameter| try method_parameters.append(self.result.allocator, try self.resolveType(parameter.type_annotation.?));
                const return_type = try self.resolveType(method.return_type);
                if (default_decl) |decl| {
                    const function = self.tree.decl(decl).function;
                    try self.defineMethodSignature(decl, symbol, symbol, parameters, function.type_parameters, function.parameters, function.return_type);
                    if (function.parameters.len == 0 or !std.mem.eql(u8, function.parameters[0].name, "это")) {
                        try self.report(function.span, "Type Error: первый параметр default-метода должен называться 'это'", .{});
                    } else if (!self.result.types.eql(try self.resolveType(function.parameters[0].type_annotation.?), receiver)) {
                        try self.report(function.span, "Type Error: получатель default-метода должен иметь тип реализуемого интерфейса", .{});
                    }
                }
                try methods.append(self.result.allocator, .{
                    .name = method.name,
                    .parameters = try self.result.arena.allocator().dupe(types.TypeId, method_parameters.items),
                    .return_type = return_type,
                    .default_symbol = default_symbol,
                });
            }
            try self.result.interface_definitions.put(symbol, .{
                .parameters = parameters,
                .methods = try self.result.arena.allocator().dupe(InterfaceMethod, methods.items),
            });
        }
    }

    fn findDefaultMethodDecl(self: *const Checker, default_methods: []const ast.DeclId, name: []const u8) ?ast.DeclId {
        for (default_methods) |decl| {
            if (std.mem.eql(u8, self.tree.decl(decl).function.name, name)) return decl;
        }
        return null;
    }

    fn preludePass(self: *Checker) !void {
        // В графе присутствует настоящий модуль прелюдии
        // (`appendPreludeModule`) — либо ЭТОТ модуль сам и есть модуль
        // прелюдии (его собственные `enumPass`/`interfacePass`
        // обрабатывают настоящие объявления `тип Опция[T] = перечисление
        // ...`/`тип Сравниваемое = интерфейс ...` напрямую, из его же
        // AST), либо он импортирует их из другого модуля (перенос
        // прелюдии в `module_compiler.zig` подаёт настоящие определения
        // через `imports.nominals`/`importIdentityPass`). В обоих
        // случаях захардкоженные заглушки ниже были бы в лучшем случае
        // избыточны — а с появлением методов по умолчанию у интерфейсов
        // ещё и НЕВЕРНЫ (они ничего не знают о теле метода по умолчанию,
        // только об абстрактной сигнатуре).
        if (self.has_real_prelude) return;
        const option_symbol = self.findTypeSymbol("Опция") orelse return;
        const result_symbol = self.findTypeSymbol("Результат") orelse return;
        const comparable_symbol = self.findTypeSymbol("Сравниваемое") orelse return;
        const comparable_self = try self.result.types.genericParameter(self.next_generic_parameter);
        self.next_generic_parameter += 1;
        const iterable_symbol = self.findTypeSymbol("Итерируемое") orelse return;
        const printable_symbol = self.findTypeSymbol("Печатаемое");
        const option_parameters = try self.defineGenericEnumParameters(&.{"T"});
        const result_parameters = try self.defineGenericEnumParameters(&.{ "T", "E" });
        const option_variants = try self.result.arena.allocator().alloc(EnumVariant, 2);
        option_variants[0] = .{
            .symbol = self.resolution.findEnumVariant(option_symbol, "Нет") orelse return,
            .name = "Нет",
            .fields = &.{},
        };
        option_variants[1] = .{
            .symbol = self.resolution.findEnumVariant(option_symbol, "Есть") orelse return,
            .name = "Есть",
            .fields = try self.result.arena.allocator().dupe(types.TypeId, &.{option_parameters[0].typ}),
        };
        try self.result.enum_definitions.put(option_symbol, .{
            .parameters = option_parameters,
            .variants = option_variants,
        });
        const result_variants = try self.result.arena.allocator().alloc(EnumVariant, 2);
        result_variants[0] = .{
            .symbol = self.resolution.findEnumVariant(result_symbol, "Успех") orelse return,
            .name = "Успех",
            .fields = try self.result.arena.allocator().dupe(types.TypeId, &.{result_parameters[0].typ}),
        };
        result_variants[1] = .{
            .symbol = self.resolution.findEnumVariant(result_symbol, "Неудача") orelse return,
            .name = "Неудача",
            .fields = try self.result.arena.allocator().dupe(types.TypeId, &.{result_parameters[1].typ}),
        };
        try self.result.enum_definitions.put(result_symbol, .{
            .parameters = result_parameters,
            .variants = result_variants,
        });
        select_source: {
            const select_symbol = self.findTypeSymbol("ИсточникОжидания") orelse break :select_source;
            const select_parameters = try self.defineGenericEnumParameters(&.{ "T", "R" });
            const message_type = select_parameters[0].typ;
            const result_type = select_parameters[1].typ;
            const select_variants = try self.result.arena.allocator().alloc(EnumVariant, 3);
            select_variants[0] = .{
                .symbol = self.resolution.findEnumVariant(select_symbol, "Сообщение") orelse break :select_source,
                .name = "Сообщение",
                .fields = try self.result.arena.allocator().dupe(types.TypeId, &.{message_type}),
            };
            // `Сигнал` несёт ту же форму `(Число, Опция(Строка))`, что и
            // собственное возвращаемое значение `получить_сигнал()`,
            // единым полем-кортежем — поэтому ветка `Сигнал(с)`
            // связывает `с` так же, как это уже делал бы прямой вызов
            // `получить_сигнал()`.
            select_variants[1] = .{
                .symbol = self.resolution.findEnumVariant(select_symbol, "Сигнал") orelse break :select_source,
                .name = "Сигнал",
                .fields = try self.result.arena.allocator().dupe(types.TypeId, &.{
                    try self.result.types.tuple(&.{
                        self.result.types.builtins.integer,
                        try self.result.types.nominal(option_symbol, &.{self.result.types.builtins.string}),
                    }),
                }),
            };
            select_variants[2] = .{
                .symbol = self.resolution.findEnumVariant(select_symbol, "Готово") orelse break :select_source,
                .name = "Готово",
                .fields = try self.result.arena.allocator().dupe(types.TypeId, &.{
                    try self.result.types.process(result_type),
                    try self.result.types.nominal(result_symbol, &.{ result_type, self.result.types.builtins.error_value }),
                }),
            };
            try self.result.enum_definitions.put(select_symbol, .{
                .parameters = select_parameters,
                .variants = select_variants,
            });
        }
        const comparable_methods = try self.result.arena.allocator().alloc(InterfaceMethod, 1);
        // `.parameters` ОБЯЗАН быть выделен в arena, а не `&.{x}` (в Zig
        // анонимный литерал массива с одним рантайм-значением
        // материализуется на стеке ЭТОЙ ФУНКЦИИ, а не в статическом/
        // arena-хранилище — срез молча повисает сразу после возврата из
        // `preludePass`).
        //
        // Параметр — настоящая заглушка Self-типа. Соответствует технике
        // заглушек, которую используют остальные 5 интерфейсов с
        // Self-типом ниже; именно `interface_self_placeholders` (см. его
        // собственный doc-комментарий) заставляет её реально разрешаться
        // в точке вызова.
        comparable_methods[0] = .{
            .name = "сравнить",
            .parameters = try self.result.arena.allocator().dupe(types.TypeId, &.{comparable_self}),
            .return_type = self.result.types.builtins.number,
        };
        try self.result.interface_definitions.put(comparable_symbol, .{
            .parameters = &.{},
            .methods = comparable_methods,
        });
        try self.result.interface_self_placeholders.put(comparable_symbol, comparable_self);
        const iterable_parameters = try self.defineGenericEnumParameters(&.{"T"});
        const iterable_methods = try self.result.arena.allocator().alloc(InterfaceMethod, 1);
        iterable_methods[0] = .{
            .name = "следующий",
            .parameters = &.{},
            .return_type = try self.result.types.nominal(option_symbol, &.{iterable_parameters[0].typ}),
        };
        try self.result.interface_definitions.put(iterable_symbol, .{
            .parameters = iterable_parameters,
            .methods = iterable_methods,
        });
        if (printable_symbol) |symbol| {
            const printable_methods = try self.result.arena.allocator().alloc(InterfaceMethod, 1);
            printable_methods[0] = .{
                .name = "вСтроку",
                .parameters = &.{},
                .return_type = self.result.types.builtins.string,
            };
            try self.result.interface_definitions.put(symbol, .{
                .parameters = &.{},
                .methods = printable_methods,
            });
        }
        // `Копируемое` — `клонировать() -> Копируемое` возвращает сам
        // реализующий тип ("Self") — свежий, одноразовый генерик-параметр
        // здесь (никогда не привязанный к реальному объявленному списку
        // параметров типа) позволяет существующему механизму
        // генерик-подстановки в `defineInterfaceImplementation`
        // унифицировать его с тем конкретным типом возврата, который
        // объявляет каждая отдельная `реализация Копируемое для X`, в
        // точности как обычный генерик-параметр метода — не нужно
        // никакой особой обработки сверх чеканки заглушки.
        if (self.findTypeSymbol("Копируемое")) |symbol| {
            const self_placeholder = try self.result.types.genericParameter(self.next_generic_parameter);
            self.next_generic_parameter += 1;
            const clone_methods = try self.result.arena.allocator().alloc(InterfaceMethod, 1);
            clone_methods[0] = .{
                .name = "клонировать",
                .parameters = &.{},
                .return_type = self_placeholder,
            };
            try self.result.interface_definitions.put(symbol, .{
                .parameters = &.{},
                .methods = clone_methods,
            });
            try self.result.interface_self_placeholders.put(symbol, self_placeholder);
        }
        // `Равнозначное`/`Складываемое`/`Вычитаемое`/`Умножаемое`/`Делимое`
        // — та же техника, что уже использует `Копируемое` для своего
        // ВОЗВРАТА с Self-типом: одноразовая заглушка генерик-параметра,
        // чеканится здесь один раз на интерфейс, унифицируется с тем
        // конкретным типом, что объявляет каждая `реализация X для Y`.
        // ПАРАМЕТР `равно` тоже Self-типа (`равно(другое: Равнозначное)
        // -> Булево`) — на этот раз та же заглушка используется для типа
        // параметра, особой обработки не нужно: `defineInterfaceImplementation`
        // уже унифицирует типы параметров тем же механизмом
        // генерик-подстановки, что и типы возврата.
        const equatable_self = try self.result.types.genericParameter(self.next_generic_parameter);
        self.next_generic_parameter += 1;
        if (self.findTypeSymbol("Равнозначное")) |symbol| {
            const equatable_methods = try self.result.arena.allocator().alloc(InterfaceMethod, 1);
            equatable_methods[0] = .{
                .name = "равно",
                .parameters = try self.result.arena.allocator().dupe(types.TypeId, &.{equatable_self}),
                .return_type = self.result.types.builtins.boolean,
            };
            try self.result.interface_definitions.put(symbol, .{
                .parameters = &.{},
                .methods = equatable_methods,
            });
            try self.result.interface_self_placeholders.put(symbol, equatable_self);
        }
        // `Складываемое`/`Вычитаемое`/`Умножаемое`/`Делимое` имеют в
        // точности одну и ту же форму — `функ X(другое: Тип) -> Тип`,
        // и параметр, и возврат Self-типа — поэтому единый цикл чеканит
        // одну свежую заглушку на интерфейс (Self каждого интерфейса —
        // его СОБСТВЕННЫЙ тип, не общий между интерфейсами) и
        // переиспользует её для обеих позиций.
        const arithmetic_interfaces = [_]struct { name: []const u8, method: []const u8 }{
            .{ .name = "Складываемое", .method = "сложить" },
            .{ .name = "Вычитаемое", .method = "вычесть" },
            .{ .name = "Умножаемое", .method = "умножить" },
            .{ .name = "Делимое", .method = "разделить" },
        };
        for (arithmetic_interfaces) |entry| {
            const symbol = self.findTypeSymbol(entry.name) orelse continue;
            const self_placeholder = try self.result.types.genericParameter(self.next_generic_parameter);
            self.next_generic_parameter += 1;
            const methods = try self.result.arena.allocator().alloc(InterfaceMethod, 1);
            methods[0] = .{
                .name = entry.method,
                .parameters = try self.result.arena.allocator().dupe(types.TypeId, &.{self_placeholder}),
                .return_type = self_placeholder,
            };
            try self.result.interface_definitions.put(symbol, .{
                .parameters = &.{},
                .methods = methods,
            });
            try self.result.interface_self_placeholders.put(symbol, self_placeholder);
        }
    }

    // Панос-тип для вида маршалинга параметра/возврата `внешний` — вид
    // маршалинга это чисто ABI-метаданные (в какую C-разрядность
    // упаковывать), сам панос-тип, в котором он проявляется, от этой
    // разрядности не зависит: Int8/32/64 — все просто `Целое` (та же
    // целочисленная разновидность `Число`, что использует счётчик цикла
    // `для`), Float32/64 — оба `Число`, `CString` — обычная `Строка`
    // (копируется в настоящую GC-строку при возврате, заимствуется на
    // входе — см. `vm.zig`).
    fn foreignMarshalType(self: *Checker, marshal: ast.ForeignMarshalKind, pointee: ?ast.TypeId, struct_type_name: ?[]const u8, span: source.Span) anyerror!types.TypeId {
        return switch (marshal) {
            .void => self.result.types.builtins.void,
            .int8, .int32, .int64 => self.result.types.builtins.integer,
            .float32, .float64 => self.result.types.builtins.number,
            .c_string => self.result.types.builtins.string,
            // Настоящий, вполне определённый вид маршалинга — отклоняется
            // здесь только потому, что у этой VM пока нет
            // RUNTIME-представления значения `Указатель`, в которое его
            // можно было бы промаршалить (система типов уже моделирует
            // `Указатель(T)`, например `.pointer` в `types.zig` — просто
            // ничто пока не конструирует живое значение этого типа).
            .pointer => blk: {
                _ = pointee;
                try self.report(span, "Type Error: 'внешний' с Указатель(T) ещё не поддержан Zig-версией", .{});
                break :blk try self.result.types.poison();
            },
            // Панос-тип параметра/возврата "структура по значению" — сама
            // `ff_структура`, обычный номинальный тип, как и любой другой
            // параметр-структура (ветка `is_ffi` в `nominalPass` уже
            // зарегистрировала для неё настоящие поля и запись
            // `ffi_struct_layouts` под тем же символом, что найден здесь).
            // Парсер уже ограничил поля `ff_структура` плоскими скалярами
            // (без вложенности) — `invokeForeign` (vm.zig) полагается на
            // этот инвариант при упаковке/распаковке сырых байт.
            .struct_value => blk: {
                const name = struct_type_name orelse {
                    try self.report(span, "Type Error: 'внешний' ожидает имя ff_структура", .{});
                    break :blk try self.result.types.poison();
                };
                const symbol = self.findTypeSymbol(name) orelse {
                    try self.report(span, "Type Error: неизвестная структура '{s}'", .{name});
                    break :blk try self.result.types.poison();
                };
                if (!self.result.ffi_struct_layouts.contains(symbol)) {
                    try self.report(span, "Type Error: '{s}' не является ff_структура", .{name});
                    break :blk try self.result.types.poison();
                }
                break :blk try self.result.types.nominal(symbol, &.{});
            },
        };
    }

    fn defineForeignSignature(self: *Checker, declaration: ast.DeclId, foreign: anytype) !void {
        const symbol = self.resolution.decl_symbols.get(declaration) orelse return;
        var parameter_types: std.ArrayList(types.TypeId) = .empty;
        defer parameter_types.deinit(self.result.allocator);
        for (foreign.parameters) |parameter| {
            try parameter_types.append(self.result.allocator, try self.foreignMarshalType(parameter.marshal, parameter.pointee, parameter.struct_type_name, parameter.span));
        }
        const return_type = try self.foreignMarshalType(foreign.return_marshal, foreign.return_pointee, foreign.return_struct_type_name, foreign.span);
        const signature = try self.result.types.function(parameter_types.items, return_type);
        try self.result.symbol_types.put(symbol, signature);
    }

    fn defineFunctionSignature(self: *Checker, declaration: ast.DeclId, type_parameters: []const ast.TypeParameter, parameters: []const ast.ParamDecl, return_type: ast.TypeId) !void {
        const symbol = self.resolution.decl_symbols.get(declaration) orelse return;
        const generic_parameters = try self.defineGenericParameters(symbol, type_parameters);
        const previous_generic_parameters = self.current_generic_parameters;
        self.current_generic_parameters = generic_parameters;
        defer self.current_generic_parameters = previous_generic_parameters;
        const previous_nominal_owner = self.current_nominal_owner;
        self.current_nominal_owner = null;
        defer self.current_nominal_owner = previous_nominal_owner;
        var parameter_types: std.ArrayList(types.TypeId) = .empty;
        defer parameter_types.deinit(self.result.allocator);
        for (parameters) |parameter| {
            try parameter_types.append(self.result.allocator, try self.resolveType(parameter.type_annotation.?));
        }
        const signature = try self.result.types.function(parameter_types.items, try self.resolveType(return_type));
        try self.result.symbol_types.put(symbol, signature);
    }

    fn defineMethodSignature(self: *Checker, declaration: ast.DeclId, owner: symbols.SymbolId, interface: ?symbols.SymbolId, owner_parameters: []const GenericParameter, function_parameters: []const ast.TypeParameter, parameters: []const ast.ParamDecl, return_type: ast.TypeId) !void {
        const symbol = self.resolution.decl_symbols.get(declaration) orelse return;
        const method_parameters = try self.defineGenericParameters(symbol, function_parameters);
        var all_parameters: std.ArrayList(GenericParameter) = .empty;
        defer all_parameters.deinit(self.result.allocator);
        try all_parameters.appendSlice(self.result.allocator, owner_parameters);
        try all_parameters.appendSlice(self.result.allocator, method_parameters);
        const parameter_scope = try self.result.arena.allocator().dupe(GenericParameter, all_parameters.items);
        const previous_generic_parameters = self.current_generic_parameters;
        self.current_generic_parameters = parameter_scope;
        defer self.current_generic_parameters = previous_generic_parameters;
        const previous_nominal_owner = self.current_nominal_owner;
        self.current_nominal_owner = .{ .symbol = owner, .parameters = owner_parameters };
        defer self.current_nominal_owner = previous_nominal_owner;
        var parameter_types: std.ArrayList(types.TypeId) = .empty;
        defer parameter_types.deinit(self.result.allocator);
        for (parameters) |parameter| {
            try parameter_types.append(self.result.allocator, try self.resolveType(parameter.type_annotation.?));
        }
        const signature = try self.result.types.function(parameter_types.items, try self.resolveType(return_type));
        try self.result.symbol_types.put(symbol, signature);
        try self.result.methods.append(self.result.allocator, .{
            .owner = owner,
            .interface = interface,
            .symbol = symbol,
            .name = self.tree.decl(declaration).function.name,
            .owner_parameters = owner_parameters,
            .function_parameters = method_parameters,
            .all_parameters = parameter_scope,
        });
    }

    fn defineInterfaceImplementation(self: *Checker, implementation: anytype, owner: symbols.SymbolId, owner_parameters: []const GenericParameter, interface_name: []const u8, interface_module: ?[]const u8) !void {
        const interface_symbol = (if (interface_module) |module_name|
            self.findQualifiedTypeSymbol(module_name, interface_name)
        else
            self.findTypeSymbol(interface_name)) orelse {
            try self.report(implementation.span, "Type Error: неизвестный интерфейс '{s}'", .{interface_name});
            return;
        };
        const definition = self.result.interface_definitions.get(interface_symbol) orelse {
            try self.report(implementation.span, "Type Error: '{s}' не является интерфейсом", .{interface_name});
            return;
        };
        if (!self.isImplementableNominal(owner)) {
            try self.report(implementation.span, "Type Error: интерфейс может реализовать только структура или перечисление", .{});
            return;
        }
        for (implementation.methods) |method| {
            const function = self.tree.decl(method).function;
            try self.defineMethodSignature(method, owner, interface_symbol, owner_parameters, function.type_parameters, function.parameters, function.return_type);
        }

        var implementation_methods: std.ArrayList(symbols.SymbolId) = .empty;
        defer implementation_methods.deinit(self.result.allocator);
        var substitutions = std.AutoHashMap(types.TypeId, types.TypeId).init(self.result.allocator);
        defer substitutions.deinit();
        var valid = true;
        for (definition.methods) |interface_method| {
            var matched: ?ast.DeclId = null;
            for (implementation.methods) |method| {
                const function = self.tree.decl(method).function;
                if (!std.mem.eql(u8, function.name, interface_method.name)) continue;
                if (matched != null) {
                    try self.report(function.span, "Type Error: метод '{s}' повторён в реализации интерфейса", .{interface_method.name});
                    valid = false;
                    continue;
                }
                matched = method;
            }
            const method = matched orelse {
                if (interface_method.default_symbol) |default_symbol| {
                    // Не переопределён — откатывается к собственному
                    // телу метода по умолчанию интерфейса, уже полностью
                    // проверенному один раз в месте своего объявления
                    // (`interfacePass`); повторная проверка сигнатуры
                    // здесь не нужна.
                    try implementation_methods.append(self.result.allocator, default_symbol);
                    continue;
                }
                try self.report(implementation.span, "Type Error: в реализации отсутствует метод '{s}'", .{interface_method.name});
                valid = false;
                continue;
            };
            const method_symbol = self.resolution.decl_symbols.get(method) orelse {
                valid = false;
                continue;
            };
            try implementation_methods.append(self.result.allocator, method_symbol);
            const signature_id = self.result.symbol_types.get(method_symbol) orelse {
                valid = false;
                continue;
            };
            const signature = self.result.types.get(signature_id) orelse {
                valid = false;
                continue;
            };
            const implementation_function = self.tree.decl(method).function;
            const function = switch (signature.*) {
                .function => |value| value,
                else => continue,
            };
            if (function.parameters.len == interface_method.parameters.len + 1) {
                for (interface_method.parameters, function.parameters[1..]) |expected, actual| {
                    try self.inferGenericSubstitution(expected, actual, &substitutions, implementation_function.span);
                }
                try self.inferGenericSubstitution(interface_method.return_type, function.return_type, &substitutions, implementation_function.span);
            }
            if (!try self.interfaceMethodMatches(interface_symbol, owner, owner_parameters, method_symbol, interface_method, &substitutions)) valid = false;
        }
        for (implementation.methods) |method| {
            const function = self.tree.decl(method).function;
            if (self.interfaceMethod(definition, function.name) == null) {
                try self.report(function.span, "Type Error: метод '{s}' отсутствует в интерфейсе", .{function.name});
                valid = false;
            }
        }
        if (!valid or implementation_methods.items.len != definition.methods.len) return;
        var arguments: std.ArrayList(types.TypeId) = .empty;
        defer arguments.deinit(self.result.allocator);
        for (definition.parameters) |parameter| {
            const argument = substitutions.get(parameter.typ) orelse {
                try self.report(implementation.span, "Type Error: не удалось вывести параметр типа интерфейса '{s}'", .{parameter.name});
                return;
            };
            try arguments.append(self.result.allocator, argument);
        }
        try self.result.interface_implementations.append(self.result.allocator, .{
            .interface = interface_symbol,
            .arguments = try self.result.arena.allocator().dupe(types.TypeId, arguments.items),
            .target = owner,
            .methods = try self.result.arena.allocator().dupe(symbols.SymbolId, implementation_methods.items),
        });
    }

    fn interfaceMethodMatches(self: *Checker, interface: symbols.SymbolId, owner: symbols.SymbolId, owner_parameters: []const GenericParameter, method_symbol: symbols.SymbolId, interface_method: InterfaceMethod, substitutions: *const std.AutoHashMap(types.TypeId, types.TypeId)) !bool {
        const signature_id = self.result.symbol_types.get(method_symbol) orelse return false;
        const signature = self.result.types.get(signature_id) orelse return false;
        const function = switch (signature.*) {
            .function => |value| value,
            else => return false,
        };
        if (function.parameters.len != interface_method.parameters.len + 1) {
            try self.report(self.resolution.symbols.get(method_symbol).?.span, "Type Error: сигнатура метода не совпадает с интерфейсом", .{});
            return false;
        }
        var owner_arguments: std.ArrayList(types.TypeId) = .empty;
        defer owner_arguments.deinit(self.result.allocator);
        for (owner_parameters) |parameter| try owner_arguments.append(self.result.allocator, parameter.typ);
        // `nominalType` (не сырой `types.nominal`) — для КВАЛИФИЦИРОВАННОЙ
        // цели импла (`owner` разрешён межмодульно через
        // `findQualifiedTypeSymbol`) собственная ветка `.qualified` в
        // `resolveType` (которая разрешала параметр-получатель метода
        // `это: Модуль.Тип`) уже проходит через `nominalType`, чтобы
        // прикрепить настоящее перенесённое значение
        // `imported_nominal_identities`. Построение `receiver` здесь
        // через сырой `types.nominal` оставило бы его со значением
        // identity=0 по умолчанию — сравнение номинальных типов в
        // `TypeStore.eql` переключается на СТРОГОЕ сравнение по
        // идентичности, как только у любой стороны ненулевая identity
        // (ветка `.nominal` в `types.zig`), так что настоящее совпадение
        // (тот же символ) отклонялось бы как "первый аргумент должен
        // иметь реализующий тип" исключительно из-за несовпадения
        // identity, а не реального несовпадения типов.
        const receiver = try self.nominalType(owner, owner_arguments.items);
        if (!self.result.types.eql(function.parameters[0], receiver)) {
            try self.report(self.resolution.symbols.get(method_symbol).?.span, "Type Error: первый аргумент метода должен иметь тип реализующего типа", .{});
            return false;
        }
        if (self.isComparableInterface(interface)) {
            if (function.parameters.len != 2 or !self.result.types.eql(function.parameters[1], receiver) or !self.result.types.eql(function.return_type, self.result.types.builtins.number)) {
                try self.report(self.resolution.symbols.get(method_symbol).?.span, "Type Error: сигнатура метода 'сравнить' должна принимать реализующий тип и возвращать Число", .{});
                return false;
            }
            return true;
        }
        for (function.parameters[1..], interface_method.parameters) |parameter, expected| {
            if (!try self.matchesInterfaceMethodType(interface, receiver, parameter, expected, substitutions)) {
                try self.report(self.resolution.symbols.get(method_symbol).?.span, "Type Error: сигнатура метода не совпадает с интерфейсом", .{});
                return false;
            }
        }
        if (!try self.matchesInterfaceMethodType(interface, receiver, function.return_type, interface_method.return_type, substitutions)) {
            try self.report(self.resolution.symbols.get(method_symbol).?.span, "Type Error: сигнатура метода не совпадает с интерфейсом", .{});
            return false;
        }
        return true;
    }

    // НАСТОЯЩЕЕ объявление интерфейса (встроенный исходник `prelude.zig`
    // либо любой пользовательский `тип X = интерфейс ... конец`) пишет
    // "Self" просто как СОБСТВЕННОЕ имя интерфейса — `равно(другое:
    // Равнозначное) -> Булево`, а не синтезированную генерик-заглушку
    // (этот приём с заглушкой существует только в захардкоженных
    // заменителях `preludePass`). Буквальная self-ссылка — не
    // `.generic_parameter`, поэтому `substituteGeneric` оставляет её
    // нетронутой, и обычный `eql` с конкретным типом параметра импла
    // всегда бы проваливался.
    fn isSelfReference(self: *const Checker, interface: symbols.SymbolId, type_id: types.TypeId) bool {
        const entry = self.result.types.get(type_id) orelse return false;
        return switch (entry.*) {
            .nominal => |nominal| nominal.symbol == interface,
            else => false,
        };
    }

    fn matchesInterfaceMethodType(self: *Checker, interface: symbols.SymbolId, receiver: types.TypeId, actual: types.TypeId, expected: types.TypeId, substitutions: *const std.AutoHashMap(types.TypeId, types.TypeId)) !bool {
        if (self.isSelfReference(interface, expected)) return self.result.types.eql(actual, receiver);
        return self.result.types.eql(actual, try self.substituteGeneric(expected, substitutions));
    }

    fn bodyPass(self: *Checker) !void {
        for (self.tree.program.?.declarations) |declaration| {
            switch (self.tree.decl(declaration).*) {
                .function => |function| try self.checkFunction(declaration, function.body),
                .impl => |implementation| for (implementation.methods) |method| {
                    const function = self.tree.decl(method).function;
                    _ = function;
                    try self.checkFunction(method, self.tree.decl(method).function.body);
                },
                .interface_decl => |interface| for (interface.default_methods) |method| {
                    try self.checkFunction(method, self.tree.decl(method).function.body);
                },
                else => {},
            }
        }
    }

    fn constantPass(self: *Checker) !void {
        for (self.tree.program.?.declarations) |declaration| {
            const constant = switch (self.tree.decl(declaration).*) {
                .constant => |value| value,
                else => continue,
            };
            if (!self.isTopLevelConstantLiteral(constant.value)) {
                try self.report(constant.span, "Type Error: константа верхнего уровня должна быть числовым, строковым или булевым литералом", .{});
            }
            const value_type = try self.infer(constant.value);
            if (self.resolution.decl_symbols.get(declaration)) |symbol| try self.result.symbol_types.put(symbol, value_type);
        }
    }

    fn isTopLevelConstantLiteral(self: *const Checker, expression: ast.ExprId) bool {
        return switch (self.tree.expr(expression).*) {
            .number, .boolean, .string => true,
            .unary => |unary| unary.operator == .minus and self.tree.expr(unary.operand).* == .number,
            else => false,
        };
    }

    fn checkFunction(self: *Checker, declaration: ast.DeclId, body: []const ast.StmtId) !void {
        const function_symbol = self.resolution.decl_symbols.get(declaration) orelse return;
        const signature = self.result.symbol_types.get(function_symbol) orelse return;
        const function_type = self.result.types.get(signature).?.function;
        const method = self.methodBySymbol(function_symbol);
        const previous_generic_parameters = self.current_generic_parameters;
        self.current_generic_parameters = if (method) |definition| definition.all_parameters else self.result.generic_function_parameters.get(function_symbol) orelse &.{};
        defer self.current_generic_parameters = previous_generic_parameters;
        const previous_nominal_owner = self.current_nominal_owner;
        self.current_nominal_owner = if (method) |definition| .{ .symbol = definition.owner, .parameters = definition.owner_parameters } else null;
        defer self.current_nominal_owner = previous_nominal_owner;
        const previous_return = self.current_return;
        self.current_return = function_type.return_type;
        defer self.current_return = previous_return;
        const parameter_symbols = self.resolution.function_parameters.get(declaration) orelse &.{};
        for (parameter_symbols, function_type.parameters) |parameter_symbol, parameter_type| {
            try self.result.symbol_types.put(parameter_symbol, parameter_type);
        }
        // `Сообщение(T)` is void-shaped for THIS purpose — declared purely
        // to tell a caller's `запусти` what message type the body's
        // `получить()` accepts, not a real value the body needs to
        // produce (same exemption `Пусто` already gets: an infinite
        // `получить()`-loop actor never "returns" in the normal sense).
        const is_void_like = self.isType(function_type.return_type, self.result.types.builtins.void) or self.isMessageType(function_type.return_type);
        const expected_body = if (is_void_like) null else function_type.return_type;
        const actual = try self.inferBlockExpected(body, expected_body, false);
        if (!is_void_like and !self.assignable(actual, function_type.return_type)) {
            const span = self.tree.decl(declaration).function.span;
            try self.report(span, "Type Error: функция должна возвращать объявленный тип", .{});
        }
        try self.checkUnreachableCode(body);
    }

    // Предупреждает (`.severity = .warning`, выполнение НЕ блокируется)
    // о коде, следующем за гарантированно расходящимся оператором в ТОМ
    // ЖЕ блоке. `если` без `иначе` никогда не считается расходящимся
    // (путь при ложном условии проходит насквозь) — здесь важен только
    // случай `.if_expr` в `stmtAlwaysDiverges`, достигаемый через
    // `exprAlwaysDiverges`.
    fn stmtAlwaysDiverges(self: *const Checker, statement: ast.StmtId) bool {
        return switch (self.tree.stmt(statement).*) {
            .return_stmt => true,
            .defer_stmt => false,
            .expr => |value| self.exprAlwaysDiverges(value.value),
            else => false,
        };
    }

    fn blockAlwaysDiverges(self: *const Checker, body: []const ast.StmtId) bool {
        for (body) |statement| {
            if (self.stmtAlwaysDiverges(statement)) return true;
        }
        return false;
    }

    fn exprAlwaysDiverges(self: *const Checker, expression: ast.ExprId) bool {
        switch (self.tree.expr(expression).*) {
            .if_expr => |conditional| {
                // Нет `иначе` — путь при ложном условии проходит
                // насквозь, никогда не расходится.
                if (conditional.else_branch.len == 0) return false;
                return self.blockAlwaysDiverges(conditional.then_branch) and self.blockAlwaysDiverges(conditional.else_branch);
            },
            .match_expr => |match| {
                if (match.arms.len == 0) return false;
                for (match.arms) |arm| {
                    if (!self.blockAlwaysDiverges(arm.body)) return false;
                }
                return true;
            },
            else => {},
        }
        // Всё остальное (паника/бесконечная рекурсия и т.п.) уже имеет
        // тип `Никогда` благодаря обычному распространению Never —
        // `expression_types` к моменту этого вызова уже полностью
        // заполнена (после того как всё тело один раз выведено).
        const expression_type = self.result.expression_types.get(expression) orelse return false;
        return self.isType(expression_type, self.result.types.builtins.never);
    }

    // Надмножество `stmtAlwaysDiverges` — `прервать`/`продолжить` тоже
    // делают ОСТАТОК ЭТОГО БЛОКА недостижимым (но не заставляют
    // расходиться саму охватывающую функцию/блок, поэтому это ОТДЕЛЬНАЯ
    // функция от `stmtAlwaysDiverges`, не общая с ней).
    fn stmtDivergesForReachability(self: *const Checker, statement: ast.StmtId) bool {
        return switch (self.tree.stmt(statement).*) {
            .return_stmt, .break_stmt, .continue_stmt => true,
            .expr => |value| self.exprAlwaysDiverges(value.value),
            else => false,
        };
    }

    fn stmtSpan(self: *const Checker, statement: ast.StmtId) source.Span {
        return switch (self.tree.stmt(statement).*) {
            .return_stmt => |value| value.span,
            .defer_stmt => |value| value.span,
            .let => |value| value.span,
            .expr => |value| value.span,
            .continue_stmt => |span| span,
            .break_stmt => |span| span,
            .for_in => |value| value.span,
            .for_range => |value| value.span,
            .error_node => |span| span,
        };
    }

    fn checkUnreachableCode(self: *Checker, body: []const ast.StmtId) anyerror!void {
        for (body, 0..) |statement, index| {
            switch (self.tree.stmt(statement).*) {
                .expr => |value| try self.checkUnreachableCodeExpr(value.value),
                .for_in => |value| try self.checkUnreachableCode(value.body),
                .for_range => |value| try self.checkUnreachableCode(value.body),
                else => {},
            }
            if (self.stmtDivergesForReachability(statement) and index + 1 < body.len) {
                const first = self.stmtSpan(body[index + 1]);
                const last = self.stmtSpan(body[body.len - 1]);
                try self.reportWarning(.{ .file_id = first.file_id, .start = first.start, .end = last.end }, "недостижимый код", .{});
                return;
            }
        }
    }

    fn checkUnreachableCodeExpr(self: *Checker, expression: ast.ExprId) anyerror!void {
        switch (self.tree.expr(expression).*) {
            .if_expr => |conditional| {
                try self.checkUnreachableCode(conditional.then_branch);
                try self.checkUnreachableCode(conditional.else_branch);
            },
            .match_expr => |match| {
                for (match.arms) |arm| try self.checkUnreachableCode(arm.body);
            },
            .while_expr => |loop| try self.checkUnreachableCode(loop.body),
            else => {},
        }
    }

    fn inferStatement(self: *Checker, statement: ast.StmtId, expected_return: types.TypeId, expected_value: ?types.TypeId, tail_value_needed: bool) anyerror!types.TypeId {
        return switch (self.tree.stmt(statement).*) {
            .let => |let| blk: {
                const expected = if (let.type_annotation) |annotation| try self.resolveType(annotation) else null;
                const value_type = if (expected) |type_id| try self.inferExpected(let.value, type_id) else try self.infer(let.value);
                if (expected) |type_id| {
                    if (!self.assignable(value_type, type_id)) {
                        try self.report(let.span, "Type Error: значение переменной не совпадает с аннотацией", .{});
                    } else {
                        try self.registerInterfaceCast(let.value, value_type, type_id);
                    }
                }
                const binding_type = expected orelse value_type;
                if (self.isType(binding_type, self.result.types.builtins.void)) try self.report(let.span, "Type Error: переменная не может иметь тип 'Пусто'", .{});
                if (let.destructure_type != null) {
                    try self.bindNominalDestructure(statement, let, binding_type);
                } else {
                    try self.bindStatementValue(statement, binding_type, let.span, "Type Error: деструктуризация ожидает тупл с соответствующим числом значений");
                }
                break :blk self.result.types.builtins.void;
            },
            .return_stmt => |return_statement| blk: {
                const return_value = return_statement.value orelse {
                    // Пустой `возврат` — возврат Пусто, допустим только
                    // там, где объявленный тип возврата функции
                    // действительно `Пусто` (как у обычной функции,
                    // возвращающей `Пусто` просто выпадением из конца
                    // своего тела).
                    if (!self.isType(expected_return, self.result.types.builtins.void)) {
                        try self.report(return_statement.span, "Type Error: 'возврат' без значения допустим только в функции, возвращающей Пусто", .{});
                    }
                    break :blk self.result.types.builtins.never;
                };
                const value_type = try self.inferExpected(return_value, expected_return);
                if (!self.assignable(value_type, expected_return)) {
                    try self.report(return_statement.span, "Type Error: возвращаемое значение не совпадает с типом функции", .{});
                } else {
                    try self.registerInterfaceCast(return_value, value_type, expected_return);
                }
                // `Никогда`, НЕ `expected_return` — `возврат` расходится с
                // ОХВАТЫВАЮЩЕЙ ФУНКЦИЕЙ, сам по себе он вообще не
                // производит значения в этой точке. `inferIfExpected` уже
                // содержит освобождающую логику на основе
                // `isNever(then_type)` именно для такой формы (`если n
                // == 0 тогда возврат 1 конец` без `иначе`), но она может
                // сработать только если здесь возвращается `Никогда`, а
                // не `expected_return`.
                break :blk self.result.types.builtins.never;
            },
            .defer_stmt => |defer_statement| blk: {
                if (self.tree.expr(defer_statement.value).* != .call) {
                    try self.report(defer_statement.span, "Type Error: 'отложить' ожидает вызов функции или метода", .{});
                }
                const value_type = try self.inferExpected(defer_statement.value, self.result.types.builtins.void);
                if (!self.assignable(value_type, self.result.types.builtins.void)) {
                    try self.report(defer_statement.span, "Type Error: отложенный вызов должен возвращать Пусто", .{});
                }
                break :blk self.result.types.builtins.void;
            },
            .expr => |expression| if (expected_value) |expected| blk: {
                const actual = try self.inferExpected(expression.value, expected);
                if (self.assignable(actual, expected)) try self.registerInterfaceCast(expression.value, actual, expected);
                break :blk actual;
            } else if (!tail_value_needed and self.tree.expr(expression.value).* == .if_expr)
                // `если`, используемый как ГОЛЫЙ ОПЕРАТОР (не хвостовое
                // значение блока), никогда не требует согласования типов
                // своих ветвей — его результат безусловно отбрасывается,
                // отражая собственный комментарий `compileStatement` в
                // `compiler.zig` для этой же формы ("Expr_Stmt — значение
                // ВСЕГДА отбрасывается... компилировать с
                // want_value=false").
                //
                // `tail_value_needed` — НЕ то же самое, что
                // `expected_value != null`: ХВОСТОВОЙ оператор блока, чьё
                // значение реально потребляется (тело функции/лямбды,
                // ветвь if-выражения, ветвь match), но без конкретного
                // ожидаемого типа, доведённого до ЭТОЙ точки
                // (expected_value == null), всё равно должен пройти
                // полную унификацию ветвей — иначе вложенное if-выражение
                // в хвосте else-ветви молча уходило бы по пути отбрасывания,
                // всегда выводясь как `Пусто` независимо от своих реальных
                // ветвей, и ВНЕШНЕЕ if-выражение проваливалось бы с
                // "ветви 'если' возвращают разные типы" для двух ветвей с
                // на самом деле идентичными типами.
                try self.inferIfAsStatement(self.tree.expr(expression.value).if_expr)
            else
                self.infer(expression.value),
            .for_in => |loop| try self.inferForIn(statement, loop),
            .for_range => |range| try self.inferForRange(statement, range),
            .continue_stmt => |span| blk: {
                if (self.loop_depth == 0) try self.report(span, "Type Error: 'продолжить' можно использовать только внутри цикла", .{});
                break :blk self.result.types.builtins.void;
            },
            .break_stmt => |span| blk: {
                if (self.loop_depth == 0) try self.report(span, "Type Error: 'прервать' можно использовать только внутри цикла", .{});
                break :blk self.result.types.builtins.void;
            },
            else => self.result.types.builtins.void,
        };
    }

    fn infer(self: *Checker, expression: ast.ExprId) anyerror!types.TypeId {
        const inferred = switch (self.tree.expr(expression).*) {
            // Чисто синтаксически — `1` всегда `Целое`, `1.0` всегда
            // `Число`, независимо от окружающего контекста (никакого
            // неявного приведения ни в ту, ни в другую сторону,
            // требуется явное преобразование даже для расширения
            // int->float).
            .number => |number| if (number.is_integer_literal) self.result.types.builtins.integer else self.result.types.builtins.number,
            .boolean => self.result.types.builtins.boolean,
            .string => self.result.types.builtins.string,
            .ident => |ident| blk: {
                const symbol = self.resolution.expr_symbols.get(expression) orelse break :blk try self.result.types.poison();
                if (self.resolution.symbols.get(symbol)) |entry| {
                    if (entry.kind == .type) break :blk try self.result.types.nominal(symbol, &.{});
                }
                if (self.result.unsupported_imports.contains(symbol)) {
                    try self.report(ident.span, "Type Error: импортированный экспорт '{s}' использует пока неподдерживаемый тип", .{self.resolution.symbols.get(symbol).?.name});
                }
                break :blk self.result.symbol_types.get(symbol) orelse try self.result.types.poison();
            },
            .unary => |unary| try self.inferUnary(unary),
            .cast => |cast| try self.inferCast(cast),
            .binary => |binary| try self.inferBinary(binary),
            .call => |call| try self.inferCall(expression, call),
            .tuple => |tuple| blk: {
                var element_types: std.ArrayList(types.TypeId) = .empty;
                defer element_types.deinit(self.result.allocator);
                for (tuple.elements) |element| try element_types.append(self.result.allocator, try self.infer(element));
                break :blk try self.result.types.tuple(element_types.items);
            },
            .array => |array| blk: {
                if (array.elements.len == 0) break :blk try self.result.types.array(try self.result.types.unconstrained());
                const element_type = try self.infer(array.elements[0]);
                for (array.elements[1..]) |element| {
                    if (!self.assignable(try self.infer(element), element_type)) try self.report(array.span, "Type Error: элементы массива имеют разные типы", .{});
                }
                break :blk try self.result.types.array(element_type);
            },
            .map => |map| blk: {
                if (map.entries.len == 0) break :blk try self.result.types.map(try self.result.types.unconstrained(), try self.result.types.unconstrained());
                const key = try self.infer(map.entries[0].key);
                const value = try self.infer(map.entries[0].value);
                for (map.entries[1..]) |entry| {
                    if (!self.assignable(try self.infer(entry.key), key)) try self.report(entry.span, "Type Error: ключи соответствия имеют разные типы", .{});
                    if (!self.assignable(try self.infer(entry.value), value)) try self.report(entry.span, "Type Error: значения соответствия имеют разные типы", .{});
                }
                break :blk try self.result.types.map(key, value);
            },
            .index => |index| try self.inferIndex(index),
            .property => |property| try self.inferProperty(expression, property),
            .lambda => |lambda| try self.inferLambda(expression, lambda, null),
            .if_expr => |conditional| try self.inferIf(conditional),
            .while_expr => |loop| try self.inferWhile(loop),
            .spawn => |spawn| try self.inferSpawn(spawn),
            .try_expr => |try_expression| try self.inferTry(try_expression),
            .match_expr => |match| try self.inferMatch(match),
            .select_wait => |select| try self.inferSelectWait(select),
            else => try self.result.types.poison(),
        };
        return self.recordExpressionType(expression, inferred);
    }

    fn inferTry(self: *Checker, try_expression: anytype) !types.TypeId {
        const value_type = try self.infer(try_expression.value);
        const value_entry = self.result.types.get(value_type) orelse return self.result.types.poison();
        const value_nominal = switch (value_entry.*) {
            .nominal => |nominal| nominal,
            else => {
                try self.report(try_expression.span, "Type Error: оператор '?' ожидает Опцию или Результат", .{});
                return self.result.types.poison();
            },
        };
        const value_owner = self.resolution.symbols.get(value_nominal.symbol) orelse return self.result.types.poison();
        const return_type = self.current_return orelse {
            try self.report(try_expression.span, "Type Error: оператор '?' можно использовать только внутри функции", .{});
            return self.result.types.poison();
        };
        if (std.mem.eql(u8, value_owner.name, "Опция")) {
            if (value_nominal.arguments.len != 1) return self.result.types.poison();
            const return_entry = self.result.types.get(return_type) orelse return self.result.types.poison();
            const return_nominal = switch (return_entry.*) {
                .nominal => |nominal| nominal,
                else => {
                    try self.report(try_expression.span, "Type Error: оператор '?' для Опции можно использовать только в функции, возвращающей Опцию", .{});
                    return self.result.types.poison();
                },
            };
            const return_owner = self.resolution.symbols.get(return_nominal.symbol) orelse return self.result.types.poison();
            if (!std.mem.eql(u8, return_owner.name, "Опция")) {
                try self.report(try_expression.span, "Type Error: оператор '?' для Опции можно использовать только в функции, возвращающей Опцию", .{});
                return self.result.types.poison();
            }
            return value_nominal.arguments[0];
        }
        if (std.mem.eql(u8, value_owner.name, "Результат")) {
            if (value_nominal.arguments.len != 2) return self.result.types.poison();
            const return_entry = self.result.types.get(return_type) orelse return self.result.types.poison();
            const return_nominal = switch (return_entry.*) {
                .nominal => |nominal| nominal,
                else => {
                    try self.report(try_expression.span, "Type Error: оператор '?' можно использовать только в функции, возвращающей Результат", .{});
                    return self.result.types.poison();
                },
            };
            const return_owner = self.resolution.symbols.get(return_nominal.symbol) orelse return self.result.types.poison();
            if (!std.mem.eql(u8, return_owner.name, "Результат")) {
                try self.report(try_expression.span, "Type Error: оператор '?' можно использовать только в функции, возвращающей Результат", .{});
                return self.result.types.poison();
            }
            if (return_nominal.arguments.len != 2 or !self.result.types.eql(value_nominal.arguments[1], return_nominal.arguments[1])) {
                try self.report(try_expression.span, "Type Error: оператор '?' возвращает ошибку другого типа", .{});
                return self.result.types.poison();
            }
            return value_nominal.arguments[0];
        }
        try self.report(try_expression.span, "Type Error: оператор '?' ожидает Опцию или Результат", .{});
        return self.result.types.poison();
    }

    // `выбор ожидание(источник) ... конец` — `источник` должен быть
    // `Массив(Процесс(R))`; R берётся прямо из типа элемента этого
    // массива (обычная унификация литерала массива уже отклоняет
    // разнородные элементы `Процесс(T)`, как и у любого другого
    // массива). Полезная нагрузка сообщения в ветке `Сообщение` остаётся
    // poison/нетипизированной, как и собственный тип возврата
    // `получить()` — у почтового ящика тоже нет статического типа
    // элемента.
    fn inferSelectWait(self: *Checker, select: anytype) !types.TypeId {
        const source_type = try self.infer(select.source);
        const source_entry = self.result.types.get(source_type) orelse return self.result.types.poison();
        const result_r = switch (source_entry.*) {
            .array => |element_type| blk: {
                const element_entry = self.result.types.get(element_type) orelse break :blk try self.result.types.poison();
                break :blk switch (element_entry.*) {
                    .process => |r| r,
                    // `массив()` (пустой, нет элементов для вывода их
                    // типа) — после разделения poison/`unconstrained`
                    // пустой литерал массива выводится как
                    // `Массив(unconstrained)`, а НЕ `Массив(poison)`
                    // (ветка `.array` в `infer`).
                    .poison, .unconstrained => try self.result.types.poison(),
                    else => blk2: {
                        try self.report(select.span, "Type Error: 'ожидание' ожидает Массив(Процесс(R))", .{});
                        break :blk2 try self.result.types.poison();
                    },
                };
            },
            .poison, .unconstrained => return self.result.types.poison(),
            else => blk: {
                try self.report(select.span, "Type Error: 'ожидание' ожидает Массив(Процесс(R))", .{});
                break :blk try self.result.types.poison();
            },
        };
        const symbol = self.findTypeSymbol("ИсточникОжидания") orelse return self.result.types.poison();
        return self.result.types.nominal(symbol, &.{ try self.result.types.poison(), result_r });
    }

    fn inferSpawn(self: *Checker, spawn: anytype) !types.TypeId {
        const call = switch (self.tree.expr(spawn.call).*) {
            .call => |value| value,
            else => {
                try self.report(spawn.span, "Type Error: 'запусти' ожидает вызов функции", .{});
                return self.result.types.process(try self.result.types.poison());
            },
        };
        const call_return_type = try self.inferCall(spawn.call, call);
        // Долгоживущий актор ОБЪЯВЛЯЕТ принимаемый тип сообщения через
        // `-> Сообщение(T)` (см. doc-комментарий `Type.message` в
        // `types.zig`) — читается прямо из собственной сигнатуры
        // вызываемого, анализ тела не нужен. Простое `-> Пусто` (старая,
        // всё ещё поддерживаемая форма актора без объявленного типа
        // сообщения) остаётся `Процесс(poison)`, без проверки, как и
        // раньше — это опциональная аннотация, а не требование, так что
        // каждый актор, не обновлённый до объявления `Сообщение(T)`,
        // продолжает работать так же.
        if (self.messagePayload(call_return_type)) |payload| {
            return self.result.types.process(payload);
        }
        // Функция, которая действительно ВОЗВРАЩАЕТ значение,
        // используется в стиле задачи (одноразовое вычисление,
        // результат читается через `ждать`) — в этом случае T становится
        // настоящим типом возврата, чтобы `ждать` мог его доставить.
        if (self.isType(call_return_type, self.result.types.builtins.void)) {
            return self.result.types.process(try self.result.types.poison());
        }
        return self.result.types.process(call_return_type);
    }

    fn inferExpected(self: *Checker, expression: ast.ExprId, expected: types.TypeId) anyerror!types.TypeId {
        return switch (self.tree.expr(expression).*) {
            .lambda => |lambda| self.recordExpressionType(expression, try self.inferLambda(expression, lambda, expected)),
            .tuple => |tuple| blk: {
                const expected_type = self.result.types.get(expected) orelse break :blk self.infer(expression);
                if (expected_type.* != .tuple or expected_type.tuple.len != tuple.elements.len) break :blk self.infer(expression);
                for (tuple.elements, expected_type.tuple) |element, element_type| {
                    const actual = try self.inferExpected(element, element_type);
                    if (self.assignable(actual, element_type)) {
                        try self.registerInterfaceCast(element, actual, element_type);
                    } else {
                        try self.report(tuple.span, "Type Error: элемент тупла не совпадает с ожидаемым типом", .{});
                    }
                }
                break :blk self.recordExpressionType(expression, expected);
            },
            // `Массив(Интерфейс) = массив(КонкретныйТип(...), ...)` —
            // в отличие от точки `пер`/return/аргумент (все они вызывают
            // `registerInterfaceCast` при совместимом несовпадении),
            // элемент коллекции-ЛИТЕРАЛА здесь раньше только проходил
            // `assignable()`, но никогда не записывал приведение,
            // которое нужно КОМПИЛЯТОРУ, чтобы реально УПАКОВАТЬ
            // конкретное значение структуры как интерфейс во время
            // выполнения — иначе каждый элемент хранился бы неупакованным,
            // и любой последующий вызов с интерфейсной диспетчеризацией
            // через него паниковал бы.
            .array => |array| blk: {
                const expected_type = self.result.types.get(expected) orelse break :blk self.infer(expression);
                const element_type = switch (expected_type.*) {
                    .array => |element| element,
                    else => break :blk self.infer(expression),
                };
                for (array.elements) |element| {
                    const actual = try self.inferExpected(element, element_type);
                    if (self.assignable(actual, element_type)) {
                        try self.registerInterfaceCast(element, actual, element_type);
                    } else {
                        try self.report(array.span, "Type Error: элемент массива не совпадает с ожидаемым типом", .{});
                    }
                }
                break :blk self.recordExpressionType(expression, expected);
            },
            .map => |map| blk: {
                const expected_type = self.result.types.get(expected) orelse break :blk self.infer(expression);
                const expected_map = switch (expected_type.*) {
                    .map => |value| value,
                    else => break :blk self.infer(expression),
                };
                for (map.entries) |entry| {
                    const key = try self.inferExpected(entry.key, expected_map.key);
                    const value = try self.inferExpected(entry.value, expected_map.value);
                    if (self.assignable(key, expected_map.key)) {
                        try self.registerInterfaceCast(entry.key, key, expected_map.key);
                    } else {
                        try self.report(entry.span, "Type Error: ключ соответствия не совпадает с ожидаемым типом", .{});
                    }
                    if (self.assignable(value, expected_map.value)) {
                        try self.registerInterfaceCast(entry.value, value, expected_map.value);
                    } else {
                        try self.report(entry.span, "Type Error: значение соответствия не совпадает с ожидаемым типом", .{});
                    }
                }
                break :blk self.recordExpressionType(expression, expected);
            },
            .call => |call| blk: {
                const variant = if (self.resolution.expr_symbols.get(call.callee)) |symbol| self.enumVariant(symbol) else null;
                if (variant) |value| break :blk self.recordExpressionType(expression, try self.inferEnumVariantCallExpected(call, value, expected));
                break :blk self.recordExpressionType(expression, try self.inferCallExpected(expression, call, expected));
            },
            .if_expr => |conditional| self.recordExpressionType(expression, try self.inferIfExpected(conditional, expected)),
            .match_expr => |match| self.recordExpressionType(expression, try self.inferMatchExpected(match, expected)),
            .spawn => |spawn| blk: {
                const actual = try self.inferSpawn(spawn);
                if (!self.assignable(actual, expected)) {
                    try self.report(spawn.span, "Type Error: тип 'запусти' не совпадает с ожидаемым Процесс(T)", .{});
                }
                break :blk self.recordExpressionType(expression, actual);
            },
            else => self.infer(expression),
        };
    }

    // `inferBlock` используется ТОЛЬКО для тел циклов (см. `inferForIn`/
    // `inferForRange`/`выбор` над `получить`) — значение тела цикла
    // НИКОГДА никем не потребляется, так что его хвостовой оператор
    // отбрасывается точно так же, как два подблока `inferIfAsStatement`,
    // а не по схеме "значение нужно, тип неизвестен" (`discard_tail =
    // true`, см. `inferBlockExpected`).
    fn inferBlock(self: *Checker, statements: []const ast.StmtId) anyerror!types.TypeId {
        return self.inferBlockExpected(statements, null, true);
    }

    // `discard_tail` различает две РАЗНЫЕ причины, по которым
    // `expected_last` хвостового оператора может быть `null`: (1)
    // значение блока вообще никогда не потребляется (тела циклов, два
    // подблока `inferIfAsStatement` — `discard_tail = true`, хвостовой
    // `если` может по-прежнему пойти дешёвым путём отбрасывания в
    // `inferStatement`), в отличие от (2) значение блока действительно
    // важно (тело функции/лямбды, ветвь if-выражения, ветвь match), но
    // конкретный тип не был доведён ДО этой точки (`discard_tail =
    // false` — хвостовой оператор всё равно должен быть полностью
    // выведен/унифицирован, см. `tail_value_needed` в `inferStatement`).
    // Смешивание этих двух случаев в единый `null` было реальной
    // ошибкой: вложенное if-выражение в хвосте else-ветви молча
    // отбрасывалось вместо унификации, и ВНЕШНЕЕ if-выражение затем
    // проваливалось с "ветви 'если' возвращают разные типы" для двух
    // ветвей с фактически идентичными типами.
    fn inferBlockExpected(self: *Checker, statements: []const ast.StmtId, expected_last: ?types.TypeId, discard_tail: bool) anyerror!types.TypeId {
        var result_type = self.result.types.builtins.void;
        for (statements, 0..) |statement, index| {
            const is_last = index + 1 == statements.len;
            const expected_value = if (is_last) expected_last else null;
            const tail_value_needed = is_last and !discard_tail;
            result_type = try self.inferStatement(statement, self.current_return orelse self.result.types.builtins.void, expected_value, tail_value_needed);
        }
        return result_type;
    }

    fn inferIf(self: *Checker, conditional: anytype) anyerror!types.TypeId {
        return self.inferIfExpected(conditional, null);
    }

    fn inferIfExpected(self: *Checker, conditional: anytype, expected: ?types.TypeId) anyerror!types.TypeId {
        const condition = try self.infer(conditional.condition);
        if (!self.assignable(condition, self.result.types.builtins.boolean)) {
            try self.report(conditional.span, "Type Error: условие 'если' должно иметь тип Булево", .{});
        }
        const diagnostics_before_then = self.result.diagnostics.items.items.len;
        var then_type = try self.inferBlockExpected(conditional.then_branch, expected, false);
        const then_failed = self.result.diagnostics.items.items.len > diagnostics_before_then;
        const diagnostics_before_else = self.result.diagnostics.items.items.len;
        var else_type = try self.inferBlockExpected(conditional.else_branch, expected, false);
        const else_failed = self.result.diagnostics.items.items.len > diagnostics_before_else;
        // Без доведённого `expected` у `Опция.Нет()` НОЛЬ аргументов,
        // из которых можно вывести собственный `T`
        // (`inferEnumVariantCall` сообщает "не удалось вывести
        // type-параметр 'T'" и откатывается к `poison`) — вполне обычная
        // распространённая идиома панос, которая никогда не работала бы
        // без явной аннотации. Если ровно ОДНА ветвь проваливается таким
        // образом, а другая выводится чисто, повторяем ПРОВАЛИВШУЮСЯ
        // ветвь, используя выведенный тип УСПЕШНОЙ ветви как `expected`
        // — это направляет обратно через ТОТ ЖЕ механизм
        // `inferEnumVariantCallExpected`, который уже заставляет
        // `Опция.Нет()` работать в любом ДРУГОМ контексте с ожидаемым
        // типом (поле структуры, позиция возврата, ...). Диагностика
        // проваленной попытки откатывается (`shrinkRetainingCapacity`)
        // перед повтором, чтобы уже исправленная ошибка не осталась
        // висеть.
        if (expected == null and then_failed and !else_failed and !self.isNever(else_type)) {
            self.result.diagnostics.items.shrinkRetainingCapacity(diagnostics_before_then);
            then_type = try self.inferBlockExpected(conditional.then_branch, else_type, false);
        } else if (expected == null and else_failed and !then_failed and !self.isNever(then_type)) {
            self.result.diagnostics.items.shrinkRetainingCapacity(diagnostics_before_else);
            else_type = try self.inferBlockExpected(conditional.else_branch, then_type, false);
        }
        const joined = if (self.isNever(then_type)) else_type else if (self.isNever(else_type)) then_type else null;
        // `both_satisfy_expected` — когда `expected` известен И обе
        // ветви УЖЕ по отдельности валидны против него (проверяется
        // явно ещё раз чуть ниже), взаимная попарная проверка
        // пропускается: `assignable` не симметричен для интерфейсов,
        // поэтому две ветви, каждая из которых удовлетворяет
        // интерфейсному `expected` (одна через голое значение
        // интерфейсного типа, другая через конкретную реализацию —
        // например `слог.Логгер` против голого `СтандартныйЛоггер`),
        // всё ещё могли бы провалить СТАРУЮ взаимную проверку друг с
        // другом, хотя объединение совершенно корректно. Ограничено
        // узко этим случаем (не "пропускать всегда, когда expected !=
        // null"), чтобы ДЕЙСТВИТЕЛЬНО несовпадающая пара по-прежнему
        // проваливалась в попарную проверку ниже.
        const both_satisfy_expected = if (expected) |expected_type|
            (self.isNever(then_type) or self.assignable(then_type, expected_type)) and (self.isNever(else_type) or self.assignable(else_type, expected_type))
        else
            false;
        if (joined == null and !both_satisfy_expected and (!self.assignable(then_type, else_type) or !self.assignable(else_type, then_type))) {
            try self.report(conditional.span, "Type Error: ветви 'если' возвращают разные типы", .{});
            return self.result.types.poison();
        }
        if (expected) |expected_type| {
            if (!self.assignable(then_type, expected_type) or !self.assignable(else_type, expected_type)) {
                try self.report(conditional.span, "Type Error: ветви 'если' не совпадают с ожидаемым типом", .{});
                return self.result.types.poison();
            }
            return expected_type;
        }
        return joined orelse then_type;
    }

    // `если` как голый оператор — проверяет типы условия и ОБЕИХ тел
    // ветвей независимо (у каждой `expected_value = null`, так что
    // ВЛОЖЕННЫЙ хвостовой если/выбор внутри любой ветви всё равно
    // получает собственную корректную обработку), но никогда не требует
    // их согласования друг с другом или получения полезного значения.
    fn inferIfAsStatement(self: *Checker, conditional: anytype) anyerror!types.TypeId {
        const condition = try self.infer(conditional.condition);
        if (!self.assignable(condition, self.result.types.builtins.boolean)) {
            try self.report(conditional.span, "Type Error: условие 'если' должно иметь тип Булево", .{});
        }
        _ = try self.inferBlockExpected(conditional.then_branch, null, true);
        _ = try self.inferBlockExpected(conditional.else_branch, null, true);
        return self.result.types.builtins.void;
    }

    fn inferMatch(self: *Checker, match: anytype) anyerror!types.TypeId {
        return self.inferMatchExpected(match, null);
    }

    fn inferMatchExpected(self: *Checker, match: anytype, expected: ?types.TypeId) anyerror!types.TypeId {
        const subject_type = try self.infer(match.subject);
        const subject_entry = self.result.types.get(subject_type) orelse return self.result.types.poison();
        const enum_definition = switch (subject_entry.*) {
            .nominal => |nominal| self.result.enum_definitions.get(nominal.symbol),
            else => null,
        };
        const supports_patterns = switch (subject_entry.*) {
            .primitive => |primitive| primitive == .number or primitive == .integer or primitive == .boolean or primitive == .string,
            .nominal => |nominal| enum_definition != null or (try self.fieldsForNominal(nominal)) != null,
            .poison => true,
            else => false,
        };
        if (!supports_patterns) {
            try self.report(match.span, "Type Error: выбор не поддерживает этот тип", .{});
            return self.result.types.poison();
        }
        // Значение = "уже встречена полностью универсальная
        // (неуточнённая) ветка для этого варианта". Две ветки для ОДНОГО
        // варианта по-настоящему дублируют/недостижимы только когда одна
        // из них вовсе не сужает поля (`Клик -> ...` после более раннего
        // `Клик -> ...`, или любая ветка после этого) — `выбор` пробует
        // ветки по порядку, так что универсальная ветка делает каждую
        // последующую ветку для этого варианта мёртвым кодом независимо
        // от её собственного сужения. Две ветки с РАЗНЫМИ шаблонами
        // полей (например `Клик(x: 0, y)`, затем `Клик(x, y)` —
        // сначала сужение литералом, потом обычное связывание) НЕ
        // дублируют друг друга: вторая ловит только то, что не поймала
        // первая.
        var covered = std.AutoHashMap(symbols.SymbolId, bool).init(self.result.allocator);
        defer covered.deinit();
        var fallback_seen = false;
        var true_covered = false;
        var false_covered = false;
        var result_type: ?types.TypeId = null;
        for (match.arms) |arm| {
            if (fallback_seen) try self.report(arm.span, "Type Error: шаблон после универсальной ветки недостижим", .{});
            if (try self.inferMatchPattern(arm.pattern, subject_type, true)) |variant| {
                if (enum_definition != null) {
                    // В отличие от `isCatchAllPattern` (используется
                    // ниже для `fallback_seen`, спрашивающего "универсальна
                    // ли ветка для ВСЕГО match"), здесь вопрос "раз уже
                    // известно, что эта ветка нацелена на `variant`,
                    // сужает ли она СОБСТВЕННЫЕ поля варианта вообще?" —
                    // голый `Клик` или `Клик(x, y)` (обычные связывания)
                    // полностью универсален для этого варианта;
                    // `Клик(x: 0, y)` — нет.
                    const is_fully_generic = self.isVariantPatternFullyGeneric(arm.pattern);
                    if (covered.get(variant)) |already_catch_all| {
                        if (already_catch_all) {
                            try self.report(arm.span, "Type Error: вариант перечисления повторён в выборе", .{});
                        } else if (is_fully_generic) {
                            try covered.put(variant, true);
                        }
                    } else {
                        try covered.put(variant, is_fully_generic);
                    }
                }
            }
            if (self.isCatchAllPattern(arm.pattern)) {
                fallback_seen = true;
            } else if (subject_entry.* == .primitive and subject_entry.primitive == .boolean) {
                if (patternBooleanLiteral(self.tree, arm.pattern)) |value| {
                    if (value) true_covered = true else false_covered = true;
                }
            }
            const arm_type = try self.inferBlockExpected(arm.body, expected, false);
            // Когда `expected` известен (match находится в контексте с
            // объявленным типом — позиция возврата функции,
            // аннотированный `пер`, ...), каждая ветка УЖЕ проверена
            // против него по отдельности чуть ниже — этого достаточно,
            // чтобы доказать корректность объединения, поэтому отдельная
            // попарная проверка взаимной совместимости между ветками в
            // этом случае полностью пропускается: `assignable` НЕ
            // симметричен для интерфейсных типов (конкретная структура
            // совместима С интерфейсом, который реализует, но не
            // наоборот) — старая попарная проверка сравнивала две ветки
            // напрямую ДРУГ С ДРУГОМ (взаимно, в обе стороны) и всегда
            // проваливалась именно на этом законном паттерне.
            if (expected == null) {
                if (result_type) |previous| {
                    if (self.isNever(previous)) {
                        result_type = arm_type;
                    } else if (!self.isNever(arm_type) and (!self.assignable(previous, arm_type) or !self.assignable(arm_type, previous))) {
                        try self.report(arm.span, "Type Error: ветви выбора возвращают разные типы", .{});
                    }
                } else {
                    result_type = arm_type;
                }
            }
            if (expected) |expected_type| {
                if (!self.assignable(arm_type, expected_type)) try self.report(arm.span, "Type Error: ветвь выбора не совпадает с ожидаемым типом", .{});
            }
        }
        if (!fallback_seen and subject_entry.* != .poison) {
            if (enum_definition) |definition| {
                for (definition.variants) |variant| {
                    if (!covered.contains(variant.symbol)) try self.report(match.span, "Type Error: выбор не исчерпывает вариант '{s}'", .{variant.name});
                }
            } else if (subject_entry.* == .primitive and subject_entry.primitive == .boolean) {
                if (!true_covered) try self.report(match.span, "Type Error: выбор не исчерпывает значение 'истина'", .{});
                if (!false_covered) try self.report(match.span, "Type Error: выбор не исчерпывает значение 'ложь'", .{});
            } else {
                try self.report(match.span, "Type Error: выбор требует универсальную ветку", .{});
            }
        }
        return expected orelse result_type orelse self.result.types.builtins.void;
    }

    fn inferMatchPattern(self: *Checker, pattern_id: ast.PatternId, subject_type: types.TypeId, allow_short_variant: bool) !?symbols.SymbolId {
        try self.result.pattern_types.put(pattern_id, subject_type);
        switch (self.tree.pattern(pattern_id).*) {
            .wildcard => return null,
            .ident => |ident| {
                if (allow_short_variant) {
                    const subject_entry = self.result.types.get(subject_type) orelse return null;
                    if (subject_entry.* == .nominal) {
                        if (self.resolution.findEnumVariant(subject_entry.nominal.symbol, ident.name)) |variant_symbol| {
                            if (self.enumVariant(variant_symbol)) |variant| {
                                if (variant.fields.len == 0) {
                                    try self.result.pattern_variants.put(pattern_id, variant_symbol);
                                    return variant_symbol;
                                }
                            }
                        }
                    }
                }
                const binding = self.resolution.pattern_symbols.get(pattern_id) orelse return null;
                try self.result.symbol_types.put(binding, subject_type);
                return null;
            },
            .literal => |literal| {
                const literal_type = try self.inferExpected(literal.value, subject_type);
                if (!self.assignable(literal_type, subject_type)) try self.report(literal.span, "Type Error: литеральный шаблон не совпадает с типом значения выбора", .{});
                return null;
            },
            .constructor => |constructor| {
                const subject_entry = self.result.types.get(subject_type) orelse return null;
                if (subject_entry.* == .poison or subject_entry.* == .unconstrained) {
                    if (self.resolution.pattern_symbols.get(pattern_id)) |variant| {
                        try self.result.pattern_variants.put(pattern_id, variant);
                        // `Тип.Вариант` явно квалифицирован — идентичность
                        // ПЕРЕЧИСЛЕНИЯ вообще не нуждается в
                        // `subject_type`, в нём нуждаются только его
                        // (возможно генерик) АРГУМЕНТЫ ТИПА; для
                        // обычного не-генерик случая их не существует,
                        // так что можно напрямую использовать
                        // собственные объявленные типы полей варианта.
                        if (self.enumVariant(variant)) |enum_variant| {
                            const owner = self.resolution.symbols.get(variant);
                            const definition = if (owner) |o| self.result.enum_definitions.get(o.owner_type) else null;
                            if (definition != null and definition.?.parameters.len == 0) {
                                if (constructor.field_names != null) try self.report(constructor.span, "Type Error: именованные поля шаблона перечисления пока не поддержаны", .{});
                                const fields = enum_variant.fields;
                                if (constructor.arguments.len != fields.len) try self.report(constructor.span, "Type Error: неверное количество полей шаблона варианта", .{});
                                const shared = @min(constructor.arguments.len, fields.len);
                                for (constructor.arguments[0..shared], fields[0..shared]) |argument, field| {
                                    _ = try self.inferMatchPattern(argument, field, false);
                                }
                            }
                            // Типы полей ГЕНЕРИК-перечисления зависят от
                            // собственных (неизвестных, поскольку это
                            // poison) аргументов типа `subject_type` —
                            // здесь нет способа разрешить конкретные типы
                            // полей; эти связывания остаются poison.
                        }
                        return variant;
                    }
                    return null;
                }
                const subject = switch (subject_entry.*) {
                    .nominal => |value| value,
                    else => {
                        try self.report(constructor.span, "Type Error: шаблон-конструктор ожидает структуру или перечисление", .{});
                        return null;
                    },
                };
                if (self.result.enum_definitions.contains(subject.symbol)) {
                    if (constructor.field_names != null) try self.report(constructor.span, "Type Error: именованные поля шаблона перечисления пока не поддержаны", .{});
                    const resolved_variant = self.resolution.pattern_symbols.get(pattern_id) orelse (if (constructor.module_name == null) self.resolution.findEnumVariant(subject.symbol, constructor.name) else null);
                    const variant_symbol = resolved_variant orelse {
                        try self.report(constructor.span, "Type Error: неизвестный вариант перечисления в шаблоне", .{});
                        return null;
                    };
                    const variant_entry = self.resolution.symbols.get(variant_symbol) orelse return null;
                    if (variant_entry.kind != .enum_variant or variant_entry.owner_type != subject.symbol) {
                        try self.report(constructor.span, "Type Error: вариант шаблона не принадлежит типу значения выбора", .{});
                        return null;
                    }
                    try self.result.pattern_variants.put(pattern_id, variant_symbol);
                    const variant = self.enumVariant(variant_symbol) orelse return null;
                    const fields = try self.enumVariantFields(variant, subject_type) orelse return null;
                    if (constructor.arguments.len != fields.len) try self.report(constructor.span, "Type Error: неверное количество полей шаблона варианта", .{});
                    const shared = @min(constructor.arguments.len, fields.len);
                    for (constructor.arguments[0..shared], fields[0..shared]) |argument, field| {
                        _ = try self.inferMatchPattern(argument, field, false);
                    }
                    return variant_symbol;
                }
                const constructor_symbol = self.findTypeSymbol(constructor.name) orelse {
                    try self.report(constructor.span, "Type Error: неизвестный тип структуры в шаблоне", .{});
                    return null;
                };
                if (constructor_symbol != subject.symbol or constructor.module_name != null) {
                    try self.report(constructor.span, "Type Error: шаблон структуры не совпадает с типом значения выбора", .{});
                    return null;
                }
                const fields = try self.fieldsForNominal(subject) orelse {
                    try self.report(constructor.span, "Type Error: шаблон-конструктор ожидает структуру", .{});
                    return null;
                };
                if (constructor.field_names) |field_names| {
                    if (field_names.len != constructor.arguments.len) try self.report(constructor.span, "Type Error: некорректные именованные поля шаблона", .{});
                    var seen = std.StringHashMap(void).init(self.result.allocator);
                    defer seen.deinit();
                    const shared = @min(field_names.len, constructor.arguments.len);
                    for (field_names[0..shared], constructor.arguments[0..shared]) |field_name, argument| {
                        if (seen.contains(field_name)) {
                            try self.report(constructor.span, "Type Error: поле '{s}' повторено в шаблоне", .{field_name});
                            continue;
                        }
                        try seen.put(field_name, {});
                        const field = findNominalField(fields, field_name) orelse {
                            try self.report(constructor.span, "Type Error: у структуры нет поля '{s}'", .{field_name});
                            continue;
                        };
                        _ = try self.inferMatchPattern(argument, field.typ, false);
                    }
                } else {
                    if (constructor.arguments.len != fields.len) try self.report(constructor.span, "Type Error: неверное количество полей шаблона структуры", .{});
                    const shared = @min(constructor.arguments.len, fields.len);
                    for (constructor.arguments[0..shared], fields[0..shared]) |argument, field| {
                        _ = try self.inferMatchPattern(argument, field.typ, false);
                    }
                }
                return null;
            },
            .error_node => return null,
        }
    }

    fn isCatchAllPattern(self: *const Checker, pattern_id: ast.PatternId) bool {
        if (self.patternVariant(pattern_id) != null) return false;
        return switch (self.tree.pattern(pattern_id).*) {
            .wildcard, .ident => true,
            .constructor => |constructor| blk: {
                for (constructor.arguments) |argument| {
                    if (!self.isCatchAllPattern(argument)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        };
    }

    // Та же рекурсивная проверка "все подшаблоны неуточнены", что и
    // ветка `.constructor` в `isCatchAllPattern`, но БЕЗ её собственной
    // верхнеуровневой защиты `patternVariant != null` — эта защита
    // означает "этот шаблон нацелен на один конкретный вариант, значит
    // не универсален для всего `выбор`", что здесь не тот вопрос (см.
    // точку вызова в `inferMatchExpected`).
    fn isVariantPatternFullyGeneric(self: *const Checker, pattern_id: ast.PatternId) bool {
        return switch (self.tree.pattern(pattern_id).*) {
            .wildcard, .ident => true,
            .constructor => |constructor| blk: {
                for (constructor.arguments) |argument| {
                    if (!self.isCatchAllPattern(argument)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        };
    }

    fn patternVariant(self: *const Checker, pattern_id: ast.PatternId) ?symbols.SymbolId {
        return self.result.pattern_variants.get(pattern_id);
    }

    fn recordExpressionType(self: *Checker, expression: ast.ExprId, inferred: types.TypeId) !types.TypeId {
        try self.result.expression_types.put(expression, inferred);
        return inferred;
    }

    fn inferWhile(self: *Checker, loop: anytype) anyerror!types.TypeId {
        const condition = try self.infer(loop.condition);
        if (!self.assignable(condition, self.result.types.builtins.boolean)) {
            try self.report(loop.span, "Type Error: условие 'пока' должно иметь тип Булево", .{});
        }
        self.loop_depth += 1;
        defer self.loop_depth -= 1;
        _ = try self.inferBlock(loop.body);
        return self.result.types.builtins.void;
    }

    fn inferForIn(self: *Checker, statement: ast.StmtId, loop: anytype) anyerror!types.TypeId {
        const iterable_type = try self.infer(loop.iterable);
        const iterable = self.result.types.get(iterable_type) orelse return self.result.types.builtins.void;
        switch (iterable.*) {
            .array => |element| {
                try self.bindStatementValue(statement, element, loop.span, "Type Error: шаблон 'для (...)' не совпадает с элементом массива");
                try self.result.for_in_infos.put(statement, .{ .kind = .array });
            },
            .map => {
                try self.report(loop.span, "Type Error: Соответствие не поддерживает позиционный доступ; для перебора элементов используйте .записи() и 'для (ключ, значение) в ...'", .{});
                try self.bindStatementPoison(statement);
            },
            .poison => try self.bindStatementPoison(statement),
            else => {
                if (try self.iterableForIn(iterable_type)) |info| {
                    try self.bindStatementValue(statement, info.element_type, loop.span, "Type Error: шаблон 'для (...)' не совпадает со значением Итерируемое");
                    try self.result.for_in_infos.put(statement, .{ .kind = .iterator, .next_method = info.next_method });
                } else if (try self.interfaceIterableElement(iterable_type)) |info| {
                    try self.bindStatementValue(statement, info.element_type, loop.span, "Type Error: шаблон 'для (...)' не совпадает со значением Итерируемое");
                    try self.result.for_in_infos.put(statement, .{ .kind = .iterator, .iterator_dispatch = .interface, .next_method_index = info.method_index });
                } else {
                    try self.report(loop.span, "Type Error: тип не поддерживает 'для x в' (нужен Массив или Итерируемое)", .{});
                    try self.bindStatementPoison(statement);
                }
            },
        }
        self.loop_depth += 1;
        defer self.loop_depth -= 1;
        _ = try self.inferBlock(loop.body);
        return self.result.types.builtins.void;
    }

    const IterableForIn = struct {
        element_type: types.TypeId,
        next_method: symbols.SymbolId,
    };

    fn iterableForIn(self: *Checker, iterable_type: types.TypeId) !?IterableForIn {
        const iterable_entry = self.result.types.get(iterable_type) orelse return null;
        const target = switch (iterable_entry.*) {
            .nominal => |nominal| nominal.symbol,
            else => return null,
        };
        const iterable = self.findTypeSymbol("Итерируемое") orelse return null;
        const definition = self.result.interface_definitions.get(iterable) orelse return null;
        if (definition.parameters.len != 1) return null;
        // `следующий` ищется ПО ИМЕНИ/индексу, а не предполагается
        // единственным методом интерфейса — это важно после появления у
        // `Итерируемое` методов по умолчанию (`отобразить`/
        // `отфильтровать`/`взять`/`собрать`). `implementation.methods`
        // всегда параллелен `definition.methods` (тот же порядок, та же
        // длина — так строит его `defineInterfaceImplementation`), так
        // что ТОТ ЖЕ индекс выбирает соответствующую скомпилированную
        // функцию.
        const next_index = self.findMethodIndex(definition, "следующий") orelse return null;
        for (self.result.interface_implementations.items) |implementation| {
            if (implementation.interface != iterable or implementation.target != target or implementation.arguments.len != 1 or implementation.methods.len <= next_index) continue;
            return .{
                .element_type = implementation.arguments[0],
                .next_method = implementation.methods[next_index],
            };
        }
        return null;
    }

    fn findMethodIndex(_: *const Checker, definition: InterfaceDefinition, name: []const u8) ?usize {
        for (definition.methods, 0..) |method, index| {
            if (std.mem.eql(u8, method.name, name)) return index;
        }
        return null;
    }

    const InterfaceIterableElement = struct { element_type: types.TypeId, method_index: u16 };

    fn interfaceIterableElement(self: *Checker, iterable_type: types.TypeId) !?InterfaceIterableElement {
        const iterable_entry = self.result.types.get(iterable_type) orelse return null;
        const nominal = switch (iterable_entry.*) {
            .nominal => |value| value,
            else => return null,
        };
        const iterable = self.findTypeSymbol("Итерируемое") orelse return null;
        if (nominal.symbol != iterable or nominal.arguments.len != 1) return null;
        const definition = self.result.interface_definitions.get(iterable) orelse return null;
        if (definition.parameters.len != 1) return null;
        const index = self.findMethodIndex(definition, "следующий") orelse return null;
        if (index > std.math.maxInt(u16)) return null;
        return .{ .element_type = nominal.arguments[0], .method_index = @intCast(index) };
    }

    fn inferForRange(self: *Checker, statement: ast.StmtId, range: anytype) anyerror!types.TypeId {
        const integer = self.result.types.builtins.integer;
        const start = try self.infer(range.start);
        const end = try self.infer(range.end);
        if (!self.assignable(start, integer) and !self.assignable(start, self.result.types.builtins.number)) {
            try self.report(range.span, "Type Error: начало диапазона 'для' должно быть числом", .{});
        }
        if (!self.assignable(end, integer) and !self.assignable(end, self.result.types.builtins.number)) {
            try self.report(range.span, "Type Error: конец диапазона 'для' должен быть числом", .{});
        }
        try self.bindStatementValue(statement, integer, range.span, "Type Error: диапазон 'для' объявляет одну переменную");
        self.loop_depth += 1;
        defer self.loop_depth -= 1;
        _ = try self.inferBlock(range.body);
        return self.result.types.builtins.void;
    }

    fn bindStatementValue(self: *Checker, statement: ast.StmtId, value_type: types.TypeId, span: source.Span, mismatch_message: []const u8) !void {
        const bindings = self.resolution.stmt_bindings.get(statement) orelse return;
        if (bindings.len == 1) {
            try self.result.symbol_types.put(bindings[0], value_type);
            return;
        }
        const value = self.result.types.get(value_type) orelse return;
        if (value.* == .tuple and value.tuple.len == bindings.len) {
            for (bindings, value.tuple) |symbol, element_type| try self.result.symbol_types.put(symbol, element_type);
            return;
        }
        try self.report(span, "{s}", .{mismatch_message});
        try self.bindStatementPoison(statement);
    }

    fn bindStatementPoison(self: *Checker, statement: ast.StmtId) !void {
        const bindings = self.resolution.stmt_bindings.get(statement) orelse return;
        const poison = try self.result.types.poison();
        for (bindings) |symbol| try self.result.symbol_types.put(symbol, poison);
    }

    fn bindNominalDestructure(self: *Checker, statement: ast.StmtId, let: anytype, value_type: types.TypeId) !void {
        const bindings = self.resolution.stmt_bindings.get(statement) orelse return;
        const expected_name = let.destructure_type orelse return;
        const value = self.result.types.get(value_type) orelse return;
        const nominal = switch (value.*) {
            .nominal => |entry| entry,
            else => {
                try self.report(let.span, "Type Error: деструктуризация '{s}' ожидает структуру", .{expected_name});
                try self.bindStatementPoison(statement);
                return;
            },
        };
        const symbol = self.resolution.symbols.get(nominal.symbol) orelse {
            try self.bindStatementPoison(statement);
            return;
        };
        if (!std.mem.eql(u8, symbol.name, expected_name)) {
            try self.report(let.span, "Type Error: деструктуризация ожидает структуру '{s}'", .{expected_name});
            try self.bindStatementPoison(statement);
            return;
        }
        const fields = try self.fieldsForNominal(nominal) orelse {
            try self.report(let.span, "Type Error: тип '{s}' нельзя деструктурировать", .{expected_name});
            try self.bindStatementPoison(statement);
            return;
        };
        if (let.destructure_field_names) |names| {
            if (names.len != bindings.len) {
                try self.report(let.span, "Type Error: именованная деструктуризация имеет неверное число полей", .{});
                try self.bindStatementPoison(statement);
                return;
            }
            for (bindings, names) |binding, name| {
                for (fields) |field| {
                    if (!std.mem.eql(u8, field.name, name)) continue;
                    try self.result.symbol_types.put(binding, field.typ);
                    break;
                } else {
                    try self.report(let.span, "Type Error: у структуры '{s}' нет поля '{s}'", .{ expected_name, name });
                    try self.result.symbol_types.put(binding, try self.result.types.poison());
                }
            }
            return;
        }
        if (fields.len != bindings.len) {
            try self.report(let.span, "Type Error: деструктуризация структуры ожидает все поля по порядку", .{});
            try self.bindStatementPoison(statement);
            return;
        }
        for (bindings, fields) |binding, field| try self.result.symbol_types.put(binding, field.typ);
    }

    fn inferIndex(self: *Checker, index: anytype) anyerror!types.TypeId {
        const object_type = try self.infer(index.object);
        const index_type = try self.infer(index.index);
        const object = self.result.types.get(object_type) orelse return self.result.types.poison();
        return switch (object.*) {
            .primitive => |primitive| if (primitive == .string) blk: {
                if (!self.assignable(index_type, self.result.types.builtins.integer) and !self.assignable(index_type, self.result.types.builtins.number)) {
                    try self.report(index.span, "Type Error: индекс строки должен быть числом", .{});
                }
                break :blk self.result.types.builtins.string;
            } else blk: {
                try self.report(index.span, "Type Error: индексирование поддержано только для строки, массива и соответствия", .{});
                break :blk try self.result.types.poison();
            },
            .array => |element| blk: {
                if (!self.assignable(index_type, self.result.types.builtins.integer) and !self.assignable(index_type, self.result.types.builtins.number)) {
                    try self.report(index.span, "Type Error: индекс массива должен быть числом", .{});
                }
                break :blk element;
            },
            .map => |map| blk: {
                if (!self.assignable(index_type, map.key)) try self.report(index.span, "Type Error: ключ соответствия имеет неверный тип", .{});
                break :blk map.value;
            },
            else => blk: {
                try self.report(index.span, "Type Error: индексирование поддержано только для строки, массива и соответствия", .{});
                break :blk try self.result.types.poison();
            },
        };
    }

    fn inferProperty(self: *Checker, expression: ast.ExprId, property: anytype) anyerror!types.TypeId {
        if (self.resolution.expr_symbols.get(expression)) |symbol| {
            if (self.resolution.symbols.get(symbol)) |entry| {
                if (entry.kind == .enum_variant) return self.nominalType(entry.owner_type, &.{});
                if (entry.kind == .type) return self.nominalType(symbol, &.{});
                if (self.result.unsupported_imports.contains(symbol)) {
                    try self.report(property.span, "Type Error: импортированный экспорт '{s}' использует пока неподдерживаемый тип", .{entry.name});
                    return self.result.types.poison();
                }
            }
            if (self.result.symbol_types.get(symbol)) |typ| return typ;
        }
        const object_type = try self.infer(property.object);
        if (self.isType(object_type, self.result.types.builtins.error_value)) {
            if (std.mem.eql(u8, property.property, "код") or std.mem.eql(u8, property.property, "сообщение")) return self.result.types.builtins.string;
        }
        const object = self.result.types.get(object_type) orelse return self.result.types.poison();
        switch (object.*) {
            .tuple => |elements| if (tuplePropertyIndex(property.property)) |index| {
                if (index < elements.len) return elements[index];
            },
            .nominal => |nominal| if (try self.fieldsForNominal(nominal)) |fields| {
                for (fields) |field| {
                    if (std.mem.eql(u8, field.name, property.property)) return field.typ;
                }
            },
            else => {},
        }
        try self.report(property.span, "Type Error: у типа нет поля '{s}'", .{property.property});
        return self.result.types.poison();
    }

    fn inferLambda(self: *Checker, expression: ast.ExprId, lambda: anytype, expected: ?types.TypeId) anyerror!types.TypeId {
        var parameter_types: std.ArrayList(types.TypeId) = .empty;
        defer parameter_types.deinit(self.result.allocator);
        var return_type = self.result.types.builtins.void;
        if (expected) |expected_type| {
            const signature = self.result.types.get(expected_type) orelse return self.result.types.poison();
            switch (signature.*) {
                .function => |function| {
                    if (lambda.parameters.len != function.parameters.len) {
                        try self.report(lambda.span, "Type Error: лямбда имеет неверное количество параметров", .{});
                    }
                    for (lambda.parameters, 0..) |parameter, index| {
                        if (index < function.parameters.len) {
                            try parameter_types.append(self.result.allocator, function.parameters[index]);
                        } else {
                            try parameter_types.append(self.result.allocator, try self.result.types.poison());
                        }
                        if (parameter.type_annotation) |annotation| {
                            const declared = try self.resolveType(annotation);
                            if (!self.assignable(declared, parameter_types.items[index])) try self.report(parameter.span, "Type Error: параметр лямбды не совпадает с ожидаемым типом", .{});
                        }
                    }
                    return_type = function.return_type;
                },
                else => {
                    try self.report(lambda.span, "Type Error: лямбда ожидает тип функции", .{});
                    return self.result.types.poison();
                },
            }
        } else {
            for (lambda.parameters) |parameter| {
                try parameter_types.append(self.result.allocator, if (parameter.type_annotation) |annotation| try self.resolveType(annotation) else try self.result.types.poison());
            }
            return_type = if (lambda.return_type) |annotation| try self.resolveType(annotation) else try self.result.types.poison();
        }

        const parameter_symbols = self.resolution.lambda_parameters.get(expression) orelse &.{};
        for (parameter_symbols, parameter_types.items) |symbol, parameter_type| try self.result.symbol_types.put(symbol, parameter_type);
        const previous_return = self.current_return;
        self.current_return = return_type;
        defer self.current_return = previous_return;
        // Отражает СОБСТВЕННОЕ освобождение для возврата Пусто у
        // `checkFunction` — обычная `функ ... -> Пусто ... конец`, чей
        // последний оператор — не-void выражение (значение просто
        // отбрасывается), всегда допускалась (`checkFunction` вовсе
        // пропускает проверку совместимости, когда объявленный тип
        // возврата — `Пусто`); ЛЯМБДА той же формы (`функ(x) -> Пусто
        // ... конец`) должна получать то же освобождение.
        const expected_body = if (self.isType(return_type, self.result.types.builtins.void)) null else return_type;
        const body_type = try self.inferBlockExpected(lambda.body, expected_body, false);
        if (!self.isType(return_type, self.result.types.builtins.void) and !self.assignable(body_type, return_type)) {
            try self.report(lambda.span, "Type Error: тело лямбды не совпадает с типом возврата", .{});
        }
        return self.result.types.function(parameter_types.items, return_type);
    }

    fn inferUnary(self: *Checker, unary: anytype) anyerror!types.TypeId {
        const operand = try self.infer(unary.operand);
        return switch (unary.operator) {
            .negate => blk: {
                if (!self.isType(operand, self.result.types.builtins.boolean)) try self.report(unary.span, "Type Error: оператор 'не' ожидает Булево", .{});
                break :blk self.result.types.builtins.boolean;
            },
            .tilde => blk: {
                if (!self.isType(operand, self.result.types.builtins.integer)) try self.report(unary.span, "Type Error: оператор '~' ожидает Целое", .{});
                break :blk self.result.types.builtins.integer;
            },
            .minus => blk: {
                if (!self.isNumeric(operand)) {
                    try self.report(unary.span, "Type Error: унарный '-' ожидает число", .{});
                    break :blk try self.result.types.poison();
                }
                break :blk operand;
            },
            else => operand,
        };
    }

    // `x как Тип` — пока ограничено только Число<->Целое (намеренно не
    // объединено с приведением интерфейсов, у которого уже есть
    // собственный отдельный неявный механизм на границе присваивания —
    // `registerInterfaceCast`/`Cast_Interface`). Оба направления ВСЕГДА
    // явные, никакого неявного расширения (Целое->Число) тоже нет —
    // как в Rust `as`/Haskell `fromIntegral`.
    fn inferCast(self: *Checker, cast: anytype) anyerror!types.TypeId {
        const operand = try self.infer(cast.operand);
        const target = try self.resolveType(cast.target);
        if (!self.isPoison(operand) and !self.isNumeric(operand)) {
            try self.report(cast.span, "Type Error: каст 'как' поддержан только между Число и Целое", .{});
            return self.result.types.poison();
        }
        if (!self.isPoison(target) and !self.isNumeric(target)) {
            try self.report(cast.target_span, "Type Error: каст 'как' поддержан только между Число и Целое", .{});
            return self.result.types.poison();
        }
        return target;
    }

    fn inferBinary(self: *Checker, binary: anytype) anyerror!types.TypeId {
        // `.assign` обрабатывается ДО безусловного вывода `left`/`right`
        // ниже — в отличие от любого другого оператора, его правой части
        // нужен тип левой части как КОНТЕКСТ ВЫВОДА (`inferExpected`, тот
        // же механизм, что уже использует привязка `пер x: T = ...`), а
        // не просто проверка совместимости постфактум. `это.поле =
        // Опция.Нет()` (голый вызов конструктора варианта перечисления
        // без аргумента, из которого можно вывести T) без этого
        // проваливался бы, поскольку `Опция.Нет()` выводился бы ВСЛЕПУЮ
        // (`self.infer`, без ожидаемого типа в области видимости) до
        // того, как тип `left` вообще был бы учтён.
        if (binary.operator == .assign) {
            const left = try self.infer(binary.left);
            try self.checkAssignmentTarget(binary.left, binary.span);
            const right = try self.inferExpected(binary.right, left);
            if (!self.assignable(right, left)) try self.report(binary.span, "Type Error: присваивание несовместимых типов", .{});
            return self.result.types.builtins.void;
        }
        const left = try self.infer(binary.left);
        const right = try self.infer(binary.right);
        return switch (binary.operator) {
            .equal, .not_equal => blk: {
                if (!self.isPoison(left) and !self.isPoison(right) and !self.result.types.eql(left, right)) {
                    try self.report(binary.span, "Type Error: оператор сравнения ожидает значения одного типа", .{});
                }
                break :blk self.result.types.builtins.boolean;
            },
            .less, .less_equal, .greater, .greater_equal => blk: {
                const comparable = (self.isComparableGeneric(left) or self.isComparableNominal(left)) and self.result.types.eql(left, right);
                if (!self.isPoison(left) and !self.isPoison(right) and !comparable and (!self.isNumeric(left) or !self.isNumeric(right) or !self.result.types.eql(left, right))) {
                    try self.report(binary.span, "Type Error: оператор сравнения ожидает два числа одного типа", .{});
                }
                break :blk self.result.types.builtins.boolean;
            },
            .and_expr, .or_expr => blk: {
                if (!self.isPoison(left) and !self.isPoison(right) and (!self.isType(left, self.result.types.builtins.boolean) or !self.isType(right, self.result.types.builtins.boolean))) {
                    try self.report(binary.span, "Type Error: логический оператор ожидает два значения Булево", .{});
                }
                break :blk self.result.types.builtins.boolean;
            },
            .plus => blk: {
                if (self.isType(left, self.result.types.builtins.string) and self.isType(right, self.result.types.builtins.string)) break :blk self.result.types.builtins.string;
                if (self.isPoison(left) or self.isPoison(right)) break :blk try self.result.types.poison();
                if (!self.isNumeric(left) or !self.isNumeric(right) or !self.result.types.eql(left, right)) {
                    try self.report(binary.span, "Type Error: оператор '+' ожидает два числа одного типа или две строки", .{});
                    break :blk try self.result.types.poison();
                }
                break :blk left;
            },
            .minus, .star, .slash => blk: {
                if (self.isPoison(left) or self.isPoison(right)) break :blk try self.result.types.poison();
                if (!self.isNumeric(left) or !self.isNumeric(right) or !self.result.types.eql(left, right)) {
                    try self.report(binary.span, "Type Error: арифметический оператор ожидает два числа одного типа", .{});
                    break :blk try self.result.types.poison();
                }
                break :blk left;
            },
            .percent, .ampersand, .pipe, .caret, .less_less, .greater_greater => blk: {
                if (self.isPoison(left) or self.isPoison(right)) break :blk try self.result.types.poison();
                if (!self.isType(left, self.result.types.builtins.integer) or !self.isType(right, self.result.types.builtins.integer)) {
                    try self.report(binary.span, "Type Error: целочисленный оператор ожидает два значения Целое", .{});
                    break :blk try self.result.types.poison();
                }
                break :blk self.result.types.builtins.integer;
            },
            else => try self.result.types.poison(),
        };
    }

    fn checkAssignmentTarget(self: *Checker, expression: ast.ExprId, span: source.Span) !void {
        switch (self.tree.expr(expression).*) {
            .ident => {
                const symbol = self.resolution.expr_symbols.get(expression) orelse return;
                const entry = self.resolution.symbols.get(symbol) orelse return;
                if (entry.kind == .constant or entry.is_const) {
                    try self.report(span, "Type Error: нельзя присваивать константе", .{});
                } else if (entry.kind != .variable) {
                    try self.report(span, "Type Error: присваивание возможно только переменной, полю или индексу", .{});
                }
            },
            .property => {},
            .index => |index| {
                const object_type = try self.infer(index.object);
                const object = self.result.types.get(object_type) orelse return;
                switch (object.*) {
                    .array, .map => {},
                    else => try self.report(span, "Type Error: присваивание по индексу возможно только массиву или соответствию", .{}),
                }
            },
            else => try self.report(span, "Type Error: присваивание возможно только переменной, полю или индексу", .{}),
        }
    }

    fn isType(self: *const Checker, actual: types.TypeId, expected: types.TypeId) bool {
        return self.result.types.eql(actual, expected);
    }

    fn isNumeric(self: *const Checker, type_id: types.TypeId) bool {
        return self.isType(type_id, self.result.types.builtins.number) or self.isType(type_id, self.result.types.builtins.integer);
    }

    fn isComparableGeneric(self: *const Checker, type_id: types.TypeId) bool {
        for (self.current_generic_parameters) |parameter| {
            if (!parameter.typ.eql(type_id)) continue;
            for (parameter.bounds) |bound| {
                if (self.isComparableInterface(bound)) return true;
            }
        }
        return false;
    }

    // `isComparableGeneric` покрывает только `<`/`>` внутри генерика,
    // ограниченного `[T: Сравниваемое]` — КОНКРЕТНЫЙ тип (`тип Деньги =
    // структура ... конец`) с `реализация Сравниваемое для Деньги`,
    // используемый напрямую (`Деньги(1.0) < Деньги(2.0)`, без всякого
    // генерика), не имеет ограничения для проверки, поэтому проваливался
    // бы в обычный отказ `isNumeric`. Эта функция проверяет путь
    // конкретного типа: существует ли ЛЮБАЯ зарегистрированная
    // `реализация Сравниваемое для <собственный символ структуры/
    // перечисления этого типа>`.
    fn isComparableNominal(self: *const Checker, type_id: types.TypeId) bool {
        const entry = self.result.types.get(type_id) orelse return false;
        const nominal = switch (entry.*) {
            .nominal => |value| value,
            else => return false,
        };
        const comparable_symbol = self.findTypeSymbol("Сравниваемое") orelse return false;
        for (self.result.interface_implementations.items) |implementation| {
            if (implementation.interface == comparable_symbol and implementation.target == nominal.symbol) return true;
        }
        return false;
    }

    // Также совпадает с `.unconstrained` — каждый СУЩЕСТВУЮЩИЙ вызывающий
    // `isPoison` использует его в значении "здесь нет реальной информации
    // о типе, дальнейшую проверку ограничений пропустить" (равно
    // подходит и восстановлению после ошибки, и намеренно разрешающему
    // генерик-случаю). Различение этих двух вариантов существует только
    // в самом представлении типа (`Type.unconstrained` в `types.zig`),
    // но не меняет, когда каждый из них трактуется как "без ограничений"
    // при проверке.
    fn isPoison(self: *const Checker, type_id: types.TypeId) bool {
        const entry = self.result.types.get(type_id) orelse return false;
        return entry.* == .poison or entry.* == .unconstrained;
    }

    fn isNever(self: *const Checker, type_id: types.TypeId) bool {
        return self.isType(type_id, self.result.types.builtins.never);
    }

    // Общая для `отправить`/`отправить_или` — проверяет аргумент
    // сообщения против T из `Процесс(T)` дескриптографияра (`inferExpected`,
    // тот же механизм, что использует привязка `пер x: T = ...`, так что
    // конструктор варианта перечисления вроде `Команда.Пинг(...)`,
    // отправленный напрямую, всё равно выводится корректно). T
    // становится РЕАЛЬНЫМ только когда целевой актор объявил `->
    // Сообщение(T)`; обычные акторы `-> Пусто` сохраняют
    // `Процесс(poison)` (см. `inferSpawn`), так что для любого актора,
    // не использующего эту опцию, эта проверка — no-op.
    fn checkSendMessageType(self: *Checker, span: source.Span, handle: ast.ExprId, message: ast.ExprId) !void {
        const handle_type = try self.infer(handle);
        const handle_entry = self.result.types.get(handle_type) orelse return;
        const expected = switch (handle_entry.*) {
            .process => |payload| payload,
            .poison => {
                _ = try self.infer(message);
                return;
            },
            else => {
                try self.report(span, "Type Error: отправить() ожидает Процесс(T) первым аргументом", .{});
                _ = try self.infer(message);
                return;
            },
        };
        const actual = try self.inferExpected(message, expected);
        if (self.assignable(actual, expected)) {
            try self.registerInterfaceCast(message, actual, expected);
        } else if (!self.isPoison(expected)) {
            try self.report(span, "Type Error: отправляемое значение не совпадает с типом сообщения процесса", .{});
        }
    }

    fn isMessageType(self: *const Checker, type_id: types.TypeId) bool {
        const entry = self.result.types.get(type_id) orelse return false;
        return entry.* == .message;
    }

    // `T` внутри аннотации типа возврата `-> Сообщение(T)` — `null` для
    // всего остального (включая простое `Пусто`, которое вызывающие
    // должны проверять отдельно, если хотят отличить "тип сообщения не
    // объявлен" от "объявлен void").
    fn messagePayload(self: *const Checker, type_id: types.TypeId) ?types.TypeId {
        const entry = self.result.types.get(type_id) orelse return null;
        return switch (entry.*) {
            .message => |payload| payload,
            else => null,
        };
    }

    fn isErrorConstructor(self: *const Checker, symbol: symbols.SymbolId) bool {
        const entry = self.resolution.symbols.get(symbol) orelse return false;
        return entry.kind == .builtin and std.mem.eql(u8, entry.name, "Ошибка");
    }

    fn isLengthBuiltin(self: *const Checker, symbol: symbols.SymbolId) bool {
        const entry = self.resolution.symbols.get(symbol) orelse return false;
        return entry.kind == .builtin and std.mem.eql(u8, entry.name, "длина");
    }

    fn isPanicBuiltin(self: *const Checker, symbol: symbols.SymbolId) bool {
        const entry = self.resolution.symbols.get(symbol) orelse return false;
        return entry.kind == .builtin and std.mem.eql(u8, entry.name, "паника");
    }

    fn isBuiltin(self: *const Checker, symbol: symbols.SymbolId, name: []const u8) bool {
        const entry = self.resolution.symbols.get(symbol) orelse return false;
        return entry.kind == .builtin and std.mem.eql(u8, entry.name, name);
    }

    fn isBuiltinModule(self: *const Checker, symbol: symbols.SymbolId, module: []const u8, name: []const u8) bool {
        const entry = self.resolution.symbols.get(symbol) orelse return false;
        return entry.kind == .builtin and entry.module_path != null and std.mem.eql(u8, entry.module_path.?, module) and std.mem.eql(u8, entry.name, name);
    }

    // `Результат(value_type, Ошибка)` для нативного встроенного, который
    // может завершиться неудачей — `Результат` предоставляется прелюдией
    // (захардкожен для прямых конвейеров, настоящий-и-импортированный,
    // когда граф сливается со встроенной прелюдией, см.
    // `zig/core/prelude.zig`); `nominalType` выбирает правильную
    // идентичность для обоих случаев.
    fn resultOfString(self: *Checker, value_type: types.TypeId) ?types.TypeId {
        const result_symbol = self.findTypeSymbol("Результат") orelse return null;
        return self.nominalType(result_symbol, &.{ value_type, self.result.types.builtins.error_value }) catch null;
    }

    // `Опция(value_type)` — симметрично `resultOfString` выше, для
    // нативных встроенных, чья "неудача" — это отсутствие значения, а не
    // `Ошибка` (`ос.окружение`).
    fn optionOf(self: *Checker, value_type: types.TypeId) ?types.TypeId {
        const option_symbol = self.findTypeSymbol("Опция") orelse return null;
        return self.nominalType(option_symbol, &.{value_type}) catch null;
    }

    fn rejectUnavailableBuiltin(self: *Checker, callee: ast.ExprId, span: source.Span) !bool {
        const symbol = self.resolution.expr_symbols.get(callee) orelse return false;
        const entry = self.resolution.symbols.get(symbol) orelse return false;
        if (entry.kind != .builtin) return false;
        const name = if (entry.module_path) |module|
            try std.fmt.allocPrint(self.result.arena.allocator(), "{s}::{s}", .{ module, entry.name })
        else
            entry.name;
        if (target_policy.builtinAvailableForTarget(name, self.target_profile)) return false;
        _ = try self.result.diagnostics.appendUnique(self.result.allocator, .{
            .phase = .type_checker,
            .severity = .err,
            .span = span,
            .message = try target_policy.typeErrorMessage(self.result.arena.allocator(), name, self.target_profile),
        });
        return true;
    }

    fn inferCall(self: *Checker, expression: ast.ExprId, call: anytype) anyerror!types.TypeId {
        return self.inferCallExpected(expression, call, null);
    }

    // `expected_return` — не null только когда этот вызов — значение
    // выражения с ИЗВЕСТНЫМ ожидаемым типом (сейчас: правая часть
    // аннотированного `пер`, через ветку `.call` в `inferExpected`).
    // Используется для затравки генерик-подстановок из типа ВОЗВРАТА
    // функции перед откатом к выводу только по аргументам — та
    // двунаправленная половина, что нужна `funcё[T](x: Строка) ->
    // Тип(T)`, когда `T` никогда не встречается ни в одном параметре. Без
    // этого `Тип(T)` мог бы выводиться ТОЛЬКО из аргументов, так что
    // параметр типа, используемый исключительно в позиции возврата,
    // молча вырождался бы в `poison`, даже когда вызывающий явно написал
    // ожидаемый тип (`пер к: Коробка(Число) = новая_коробка("x")`) прямо
    // здесь. Намеренно НЕ пытается выполнить полную унификацию
    // Хиндли-Милнера (никакого межоператорного/отложенного вывода) —
    // только этот один контекст, прилегающий к вызывающему.
    fn inferCallExpected(self: *Checker, expression: ast.ExprId, call: anytype, expected_return: ?types.TypeId) anyerror!types.TypeId {
        if (try self.rejectUnavailableBuiltin(call.callee, call.span)) {
            for (call.arguments) |argument| _ = try self.infer(argument);
            return self.result.types.poison();
        }
        if (self.resolution.expr_symbols.get(call.callee)) |symbol| {
            if (self.enumVariant(symbol)) |variant| return self.inferEnumVariantCall(call, variant);
            if (self.isErrorConstructor(symbol)) {
                if (call.arguments.len != 2) {
                    try self.report(call.span, "Type Error: Ошибка ожидает 2 аргумент(а)", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.error_value;
                }
                for (call.arguments) |argument| {
                    if (!self.assignable(try self.inferExpected(argument, self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: Ошибка ожидает строки кода и сообщения", .{});
                    }
                }
                return self.result.types.builtins.error_value;
            }
            if (self.isBuiltin(symbol, "встроку")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: встроку(x) ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                _ = try self.infer(call.arguments[0]);
                return self.result.types.builtins.string;
            }
            if (self.isPanicBuiltin(symbol)) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: паника ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.never;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: паника ожидает строку", .{});
                }
                return self.result.types.builtins.never;
            }
            if (self.isBuiltinModule(symbol, "фс", "есть")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: фс.есть() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.boolean;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: фс.есть() ожидает путь типа Строка", .{});
                }
                return self.result.types.builtins.boolean;
            }
            if (self.isBuiltinModule(symbol, "фс", "удалить")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: фс.удалить() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.boolean;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: фс.удалить() ожидает путь типа Строка", .{});
                }
                return self.result.types.builtins.boolean;
            }
            if (self.isBuiltinModule(symbol, "фс", "прочитать")) {
                const result_type = self.resultOfString(self.result.types.builtins.string) orelse return self.result.types.poison();
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: фс.прочитать() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return result_type;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: фс.прочитать() ожидает путь типа Строка", .{});
                }
                return result_type;
            }
            if (self.isBuiltinModule(symbol, "фс", "записать")) {
                const result_type = self.resultOfString(self.result.types.builtins.number) orelse return self.result.types.poison();
                if (call.arguments.len != 2) {
                    try self.report(call.span, "Type Error: фс.записать() ожидает 2 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return result_type;
                }
                for (call.arguments) |argument| {
                    if (!self.assignable(try self.inferExpected(argument, self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: фс.записать() ожидает путь и содержимое типа Строка", .{});
                    }
                }
                return result_type;
            }
            if (self.isBuiltinModule(symbol, "фс", "открыть")) {
                const file_symbol = self.findTypeSymbol("Файл") orelse return self.result.types.poison();
                const file_type = try self.nominalType(file_symbol, &.{});
                const result_type = self.resultOfString(file_type) orelse return self.result.types.poison();
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: фс.открыть() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return result_type;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: фс.открыть() ожидает путь типа Строка", .{});
                }
                return result_type;
            }
            if (self.isBuiltinModule(symbol, "фс", "это_директория")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: фс.это_директория() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.boolean;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: фс.это_директория() ожидает путь типа Строка", .{});
                }
                return self.result.types.builtins.boolean;
            }
            if (self.isBuiltinModule(symbol, "фс", "создать_директорию")) {
                const result_type = self.resultOfString(self.result.types.builtins.number) orelse return self.result.types.poison();
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: фс.создать_директорию() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return result_type;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: фс.создать_директорию() ожидает путь типа Строка", .{});
                }
                return result_type;
            }
            if (self.isBuiltinModule(symbol, "фс", "список_директории")) {
                const array_type = try self.result.types.array(self.result.types.builtins.string);
                const result_type = self.resultOfString(array_type) orelse return self.result.types.poison();
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: фс.список_директории() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return result_type;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: фс.список_директории() ожидает путь типа Строка", .{});
                }
                return result_type;
            }
            if (self.isBuiltinModule(symbol, "фс", "удалить_директорию")) {
                const result_type = self.resultOfString(self.result.types.builtins.number) orelse return self.result.types.poison();
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: фс.удалить_директорию() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return result_type;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: фс.удалить_директорию() ожидает путь типа Строка", .{});
                }
                return result_type;
            }
            if (self.isBuiltinModule(symbol, "ос", "аргументы")) {
                if (call.arguments.len != 0) try self.report(call.span, "Type Error: ос.аргументы() не принимает аргументы", .{});
                for (call.arguments) |argument| _ = try self.infer(argument);
                return self.result.types.array(self.result.types.builtins.string);
            }
            if (self.isBuiltinModule(symbol, "ос", "версия_паноса")) {
                if (call.arguments.len != 0) try self.report(call.span, "Type Error: ос.версия_паноса() не принимает аргументы", .{});
                for (call.arguments) |argument| _ = try self.infer(argument);
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "ос", "окружение")) {
                const option_type = self.optionOf(self.result.types.builtins.string) orelse return self.result.types.poison();
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: ос.окружение() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return option_type;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: ос.окружение() ожидает имя переменной типа Строка", .{});
                }
                return option_type;
            }
            if (self.isBuiltinModule(symbol, "ос", "установить_окружение")) {
                const result_type = self.resultOfString(self.result.types.builtins.number) orelse return self.result.types.poison();
                if (call.arguments.len != 2) {
                    try self.report(call.span, "Type Error: ос.установить_окружение() ожидает 2 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return result_type;
                }
                for (call.arguments) |argument| {
                    if (!self.assignable(try self.inferExpected(argument, self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: ос.установить_окружение() ожидает имя и значение типа Строка", .{});
                    }
                }
                return result_type;
            }
            if (self.isBuiltinModule(symbol, "ос", "удалить_окружение")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: ос.удалить_окружение() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.boolean;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: ос.удалить_окружение() ожидает имя переменной типа Строка", .{});
                }
                return self.result.types.builtins.boolean;
            }
            if (self.isBuiltinModule(symbol, "ос", "выполнить")) {
                // (код_завершения, stdout, stderr) — плоский tuple, тот же
                // паттерн, что и у Odin (`builtin_export_type`, `core/
                // stdlib.odin`): core-builtin возвращает сырые данные,
                // именованная обёртка (если понадобится) — задача panos-
                // уровня, не системы типов.
                const exec_tuple = try self.result.types.tuple(&.{ self.result.types.builtins.number, self.result.types.builtins.string, self.result.types.builtins.string });
                const result_type = self.resultOfString(exec_tuple) orelse return self.result.types.poison();
                if (call.arguments.len != 3) {
                    try self.report(call.span, "Type Error: ос.выполнить() ожидает 3 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return result_type;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: ос.выполнить() ожидает программу типа Строка первым аргументом", .{});
                }
                const args_array = try self.result.types.array(self.result.types.builtins.string);
                if (!self.assignable(try self.inferExpected(call.arguments[1], args_array), args_array)) {
                    try self.report(call.span, "Type Error: ос.выполнить() ожидает Массив(Строка) вторым аргументом", .{});
                }
                if (!self.assignable(try self.inferExpected(call.arguments[2], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: ос.выполнить() ожидает рабочую директорию типа Строка третьим аргументом", .{});
                }
                return result_type;
            }
            if (self.isBuiltinModule(symbol, "ос", "завершить")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: ос.завершить() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.never;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.number), self.result.types.builtins.number)) {
                    try self.report(call.span, "Type Error: ос.завершить() ожидает код завершения типа Число", .{});
                }
                return self.result.types.builtins.never;
            }
            if (self.isBuiltinModule(symbol, "время", "сейчас_мс")) {
                if (call.arguments.len != 0) try self.report(call.span, "Type Error: время.сейчас_мс() не принимает аргументы", .{});
                for (call.arguments) |argument| _ = try self.infer(argument);
                return self.result.types.builtins.number;
            }
            if (self.isBuiltinModule(symbol, "время", "монотонно_мс")) {
                if (call.arguments.len != 0) try self.report(call.span, "Type Error: время.монотонно_мс() не принимает аргументы", .{});
                for (call.arguments) |argument| _ = try self.infer(argument);
                return self.result.types.builtins.number;
            }
            if (self.isBuiltinModule(symbol, "время", "спать_мс")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: время.спать_мс() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.number;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.number), self.result.types.builtins.number)) {
                    try self.report(call.span, "Type Error: время.спать_мс() ожидает миллисекунды типа Число", .{});
                }
                return self.result.types.builtins.number;
            }
            if (self.isBuiltinModule(symbol, "DOM", "текст")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: DOM.текст() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.number;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: DOM.текст() ожидает CSS-селектор типа Строка", .{});
                }
                return self.result.types.builtins.number;
            }
            if (self.isBuiltinModule(symbol, "DOM", "установить_текст")) {
                if (call.arguments.len != 2) {
                    try self.report(call.span, "Type Error: DOM.установить_текст() ожидает 2 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.void;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: DOM.установить_текст() ожидает CSS-селектор типа Строка первым аргументом", .{});
                }
                if (!self.assignable(try self.inferExpected(call.arguments[1], self.result.types.builtins.number), self.result.types.builtins.number)) {
                    try self.report(call.span, "Type Error: DOM.установить_текст() ожидает значение типа Число вторым аргументом", .{});
                }
                return self.result.types.builtins.void;
            }
            if (self.isBuiltinModule(symbol, "DOM", "на_клик")) {
                if (call.arguments.len != 2) {
                    try self.report(call.span, "Type Error: DOM.на_клик() ожидает 2 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.void;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: DOM.на_клик() ожидает CSS-селектор типа Строка первым аргументом", .{});
                }
                const event_symbol = self.findQualifiedTypeSymbol("DOM", "СобытиеКлика") orelse return self.result.types.poison();
                const event_type = try self.nominalType(event_symbol, &.{});
                const expected_handler = try self.result.types.function(&.{event_type}, self.result.types.builtins.void);
                const handler_type = try self.inferExpected(call.arguments[1], expected_handler);
                if (!self.assignable(handler_type, expected_handler)) {
                    try self.report(call.span, "Type Error: DOM.на_клик() ожидает обработчик (функ(DOM.СобытиеКлика) -> Пусто) вторым аргументом", .{});
                }
                return self.result.types.builtins.void;
            }
            if (self.isBuiltinModule(symbol, "DOM", "данные_клика")) {
                if (call.arguments.len != 0) {
                    try self.report(call.span, "Type Error: DOM.данные_клика() не принимает аргументы", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "DOM", "атрибут_клика")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: DOM.атрибут_клика() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: DOM.атрибут_клика() ожидает имя атрибута типа Строка", .{});
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "DOM", "текст_строка") or self.isBuiltinModule(symbol, "DOM", "значение_поля")) {
                const name = if (self.isBuiltinModule(symbol, "DOM", "текст_строка")) "текст_строка" else "значение_поля";
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: DOM.{s}() ожидает 1 аргумент", .{name});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: DOM.{s}() ожидает CSS-селектор типа Строка", .{name});
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "DOM", "установить_текст_строка") or self.isBuiltinModule(symbol, "DOM", "установить_значение_поля")) {
                const name = if (self.isBuiltinModule(symbol, "DOM", "установить_текст_строка")) "установить_текст_строка" else "установить_значение_поля";
                if (call.arguments.len != 2) {
                    try self.report(call.span, "Type Error: DOM.{s}() ожидает 2 аргумента", .{name});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.void;
                }
                for (call.arguments) |argument| {
                    if (!self.assignable(try self.inferExpected(argument, self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: DOM.{s}() ожидает селектор и значение типа Строка", .{name});
                    }
                }
                return self.result.types.builtins.void;
            }
            if (self.isBuiltinModule(symbol, "DOM", "создать_и_добавить")) {
                if (call.arguments.len != 3) {
                    try self.report(call.span, "Type Error: DOM.создать_и_добавить() ожидает 3 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.void;
                }
                for (call.arguments) |argument| {
                    if (!self.assignable(try self.inferExpected(argument, self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: DOM.создать_и_добавить() ожидает родительский CSS-селектор, тег и id типа Строка", .{});
                    }
                }
                return self.result.types.builtins.void;
            }
            // Пустой третий селектор означает append в конец
            // родителя; непустой — insertBefore перед опорным узлом.
            if (self.isBuiltinModule(symbol, "DOM", "переместить")) {
                if (call.arguments.len != 3) {
                    try self.report(call.span, "Type Error: DOM.переместить() ожидает 3 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.void;
                }
                for (call.arguments) |argument| {
                    if (!self.assignable(try self.inferExpected(argument, self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: DOM.переместить() ожидает селектор узла, родителя и опорного узла типа Строка", .{});
                    }
                }
                return self.result.types.builtins.void;
            }
            if (self.isBuiltinModule(symbol, "DOM", "атрибут")) {
                if (call.arguments.len != 2) {
                    try self.report(call.span, "Type Error: DOM.атрибут() ожидает 2 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                for (call.arguments) |argument| {
                    if (!self.assignable(try self.inferExpected(argument, self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: DOM.атрибут() ожидает селектор и имя атрибута типа Строка", .{});
                    }
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "DOM", "установить_атрибут")) {
                if (call.arguments.len != 3) {
                    try self.report(call.span, "Type Error: DOM.установить_атрибут() ожидает 3 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.void;
                }
                for (call.arguments) |argument| {
                    if (!self.assignable(try self.inferExpected(argument, self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: DOM.установить_атрибут() ожидает селектор, имя и значение атрибута типа Строка", .{});
                    }
                }
                return self.result.types.builtins.void;
            }
            // `DOM.удалить_атрибут` — симметрично `DOM.установить_атрибут`,
            // но без 3-го (значение) аргумента. Нужен диф.pns'у: атрибут,
            // пропавший из нового дерева, раньше не мог быть снят с
            // реального DOM-элемента вообще (никакого builtin'а для этого
            // не было) и молча оставался висеть навсегда.
            if (self.isBuiltinModule(symbol, "DOM", "удалить_атрибут")) {
                if (call.arguments.len != 2) {
                    try self.report(call.span, "Type Error: DOM.удалить_атрибут() ожидает 2 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.void;
                }
                for (call.arguments) |argument| {
                    if (!self.assignable(try self.inferExpected(argument, self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: DOM.удалить_атрибут() ожидает селектор и имя атрибута типа Строка", .{});
                    }
                }
                return self.result.types.builtins.void;
            }
            if (self.isBuiltinModule(symbol, "DOM", "после_кадра")) {
                if (call.arguments.len != 2) {
                    try self.report(call.span, "Type Error: DOM.после_кадра() ожидает имя обработчика и контекст", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.void;
                }
                for (call.arguments) |argument| {
                    if (!self.assignable(try self.inferExpected(argument, self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: DOM.после_кадра() ожидает имя обработчика и контекст типа Строка", .{});
                    }
                }
                return self.result.types.builtins.void;
            }
            if (self.isBuiltinModule(symbol, "DOM", "через_мс")) {
                if (call.arguments.len != 2) {
                    try self.report(call.span, "Type Error: DOM.через_мс() ожидает имя обработчика и задержку", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.void;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: DOM.через_мс() ожидает имя обработчика типа Строка", .{});
                }
                if (!self.assignable(try self.inferExpected(call.arguments[1], self.result.types.builtins.integer), self.result.types.builtins.integer)) {
                    try self.report(call.span, "Type Error: DOM.через_мс() ожидает задержку типа Целое", .{});
                }
                return self.result.types.builtins.void;
            }
            // `DOM.удалить` — единственный способ убрать ОДИН узел (до
            // этого — только `установить_текст_строка(родитель, "")`,
            // стирающее ВСЁ содержимое родителя). Нужен vdom-diff'у для
            // удаления узлов, переставших существовать в новом дереве.
            if (self.isBuiltinModule(symbol, "DOM", "удалить")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: DOM.удалить() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.void;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: DOM.удалить() ожидает CSS-селектор типа Строка", .{});
                }
                return self.result.types.builtins.void;
            }
            // `DOM.путь`/`DOM.перейти` — маршрутизация. Отдельно от
            // `состояние.*` намеренно: текущий путь браузера — факт
            // окружения, не поле модели приложения, смешивать со
            // строкой `состояние.записать` означало бы каждому фреймворку
            // самому парсить путь из чужого формата состояния.
            if (self.isBuiltinModule(symbol, "DOM", "путь")) {
                if (call.arguments.len != 0) {
                    try self.report(call.span, "Type Error: DOM.путь() не принимает аргументы", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "DOM", "перейти")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: DOM.перейти() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.void;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: DOM.перейти() ожидает путь типа Строка", .{});
                }
                return self.result.types.builtins.void;
            }
            // `состояние.прочитать`/`.записать` — модель, хранимая JS-
            // загрузчиком (собственная замыкающая переменная `heldModel`
            // из aot-dom-loader.js), НЕ атрибут DOM: в отличие от
            // `DOM.атрибут`, значение никогда не касается реального
            // элемента — хост просто возвращает ту строку, что сохранил
            // предыдущий вызов `.записать`, через отдельные экспортные
            // вызовы. Намеренно чтение без аргументов / запись с одним
            // аргументом, та же форма, что у `DOM.атрибут`/
            // `установить_атрибут`, но опирается на другой механизм хоста.
            if (self.isBuiltinModule(symbol, "состояние", "прочитать")) {
                if (call.arguments.len != 0) {
                    try self.report(call.span, "Type Error: состояние.прочитать() не принимает аргументов", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "состояние", "записать")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: состояние.записать() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.void;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: состояние.записать() ожидает значение типа Строка", .{});
                }
                return self.result.types.builtins.void;
            }
            if (self.isBuiltinModule(symbol, "ввод_вывод", "печать") or self.isBuiltinModule(symbol, "ввод_вывод", "строка")) {
                const name = if (self.isBuiltinModule(symbol, "ввод_вывод", "печать")) "печать" else "строка";
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: ввод_вывод.{s}() ожидает 1 аргумент", .{name});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.void;
                }
                // "любой тип" — без проверки совместимости, в отличие от
                // любого другого встроенного здесь: `.печать`/`.строка`
                // принимают буквально что угодно (отображается через
                // `renderRuntimeValue` в `vm.zig`, структурный дамп для
                // составных значений — диспетчеризация через интерфейс
                // Печатаемое пока не подключена).
                _ = try self.infer(call.arguments[0]);
                return self.result.types.builtins.void;
            }
            if (self.isBuiltinModule(symbol, "ввод_вывод", "прочитать_строку")) {
                if (call.arguments.len != 0) {
                    try self.report(call.span, "Type Error: ввод_вывод.прочитать_строку() не принимает аргументов", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                }
                // `Результат(Строка, Ошибка)`, а НЕ `Опция(Строка)` — EOF
                // сообщается как настоящая `Неудача(Ошибка(...))`, как и
                // любой ДРУГОЙ нативный I/O встроенный, который может
                // завершиться неудачей (`фс.прочитать`,
                // `сеть.http_запрос`, ...).
                const result_symbol = self.findTypeSymbol("Результат") orelse return self.result.types.poison();
                return self.nominalType(result_symbol, &.{ self.result.types.builtins.string, self.result.types.builtins.error_value });
            }
            if (self.isBuiltinModule(symbol, "строки", "из_байтов")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: строки.из_байтов() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                const array_type = try self.result.types.array(self.result.types.builtins.integer);
                if (!self.assignable(try self.inferExpected(call.arguments[0], array_type), array_type)) {
                    try self.report(call.span, "Type Error: строки.из_байтов() ожидает Массив(Целое)", .{});
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "строки", "в_байты")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: строки.в_байты() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return try self.result.types.array(self.result.types.builtins.integer);
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: строки.в_байты() ожидает строку", .{});
                }
                return try self.result.types.array(self.result.types.builtins.integer);
            }
            if (self.isBuiltinModule(symbol, "строки", "в_руны")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: строки.в_руны() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return try self.result.types.array(self.result.types.builtins.integer);
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: строки.в_руны() ожидает строку", .{});
                }
                return try self.result.types.array(self.result.types.builtins.integer);
            }
            if (self.isBuiltinModule(symbol, "строки", "из_рун")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: строки.из_рун() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                const array_type = try self.result.types.array(self.result.types.builtins.integer);
                if (!self.assignable(try self.inferExpected(call.arguments[0], array_type), array_type)) {
                    try self.report(call.span, "Type Error: строки.из_рун() ожидает Массив(Целое)", .{});
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "строки", "кодовая_точка")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: строки.кодовая_точка() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.integer;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: строки.кодовая_точка() ожидает строку", .{});
                }
                return self.result.types.builtins.integer;
            }
            if (self.isBuiltinModule(symbol, "строки", "в_число")) {
                const result_type = self.resultOfString(self.result.types.builtins.number) orelse return self.result.types.poison();
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: строки.в_число() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return result_type;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: строки.в_число() ожидает строку", .{});
                }
                return result_type;
            }
            if (self.isBuiltinModule(symbol, "строки", "из_числа")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: строки.из_числа() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                // Принимает Число ИЛИ Целое напрямую — оба разделяют
                // одно рантайм-представление f64, так что нет разницы в
                // форматировании, теряемой отказом от принудительного
                // приведения, а требовать `значение как Число` в каждой
                // точке вызова только чтобы застрочковать Целое (длина
                // массива, счётчик цикла и т.п.) — чистая формальность,
                // именно для избежания которой уже существует
                // `строки.из_целого`.
                const argument_type = try self.infer(call.arguments[0]);
                if (!self.isPoison(argument_type) and !self.isNumeric(argument_type)) {
                    try self.report(call.span, "Type Error: строки.из_числа() ожидает Число или Целое", .{});
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "строки", "из_целого")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: строки.из_целого() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.integer), self.result.types.builtins.integer)) {
                    try self.report(call.span, "Type Error: строки.из_целого() ожидает Целое", .{});
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "строки", "верхний_регистр") or self.isBuiltinModule(symbol, "строки", "нижний_регистр") or self.isBuiltinModule(symbol, "строки", "обрезать")) {
                const name = if (self.isBuiltinModule(symbol, "строки", "верхний_регистр"))
                    "верхний_регистр"
                else if (self.isBuiltinModule(symbol, "строки", "нижний_регистр"))
                    "нижний_регистр"
                else
                    "обрезать";
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: строки.{s}() ожидает 1 аргумент", .{name});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: строки.{s}() ожидает строку", .{name});
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "строки", "цифра_или_буква")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: строки.цифра_или_буква() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.boolean;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: строки.цифра_или_буква() ожидает строку", .{});
                }
                return self.result.types.builtins.boolean;
            }
            if (self.isBuiltinModule(symbol, "строки", "это_буква") or self.isBuiltinModule(symbol, "строки", "это_цифра")) {
                const name = if (self.isBuiltinModule(symbol, "строки", "это_буква")) "это_буква" else "это_цифра";
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: строки.{s}() ожидает 1 аргумент", .{name});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.boolean;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: строки.{s}() ожидает строку", .{name});
                }
                return self.result.types.builtins.boolean;
            }
            if (self.isBuiltinModule(symbol, "строки", "заканчивается_на") or
                self.isBuiltinModule(symbol, "строки", "начинается_с") or
                self.isBuiltinModule(symbol, "строки", "содержит"))
            {
                const name = if (self.isBuiltinModule(symbol, "строки", "заканчивается_на"))
                    "заканчивается_на"
                else if (self.isBuiltinModule(symbol, "строки", "начинается_с"))
                    "начинается_с"
                else
                    "содержит";
                if (call.arguments.len != 2) {
                    try self.report(call.span, "Type Error: строки.{s}() ожидает 2 аргумента", .{name});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.boolean;
                }
                for (call.arguments) |argument| {
                    if (!self.assignable(try self.inferExpected(argument, self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: строки.{s}() ожидает строки", .{name});
                    }
                }
                return self.result.types.builtins.boolean;
            }
            if (self.isBuiltinModule(symbol, "строки", "найти")) {
                // (s, подстрока, начало: Целое) -> Целое (-1, если не
                // найдено).
                if (call.arguments.len != 3) {
                    try self.report(call.span, "Type Error: строки.найти() ожидает 3 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.integer;
                }
                for (call.arguments[0..2]) |argument| {
                    if (!self.assignable(try self.inferExpected(argument, self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: строки.найти() ожидает строки первым и вторым аргументом", .{});
                    }
                }
                if (!self.isNumeric(try self.infer(call.arguments[2]))) {
                    try self.report(call.span, "Type Error: строки.найти() ожидает начальный индекс-число третьим аргументом", .{});
                }
                return self.result.types.builtins.integer;
            }
            if (self.isBuiltinModule(symbol, "строки", "заменить")) {
                if (call.arguments.len != 3) {
                    try self.report(call.span, "Type Error: строки.заменить() ожидает 3 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                for (call.arguments) |argument| {
                    if (!self.assignable(try self.inferExpected(argument, self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: строки.заменить() ожидает строки", .{});
                    }
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "строки", "срез")) {
                if (call.arguments.len != 3) {
                    try self.report(call.span, "Type Error: строки.срез() ожидает 3 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: строки.срез() ожидает строку первым аргументом", .{});
                }
                for (call.arguments[1..3]) |argument| {
                    if (!self.isNumeric(try self.infer(argument))) {
                        try self.report(call.span, "Type Error: строки.срез() ожидает границы-числа", .{});
                    }
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "строки", "разбить")) {
                const array_type = try self.result.types.array(self.result.types.builtins.string);
                if (call.arguments.len != 2) {
                    try self.report(call.span, "Type Error: строки.разбить() ожидает 2 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return array_type;
                }
                for (call.arguments) |argument| {
                    if (!self.assignable(try self.inferExpected(argument, self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: строки.разбить() ожидает строки", .{});
                    }
                }
                return array_type;
            }
            if (self.isBuiltinModule(symbol, "строки", "соединить")) {
                const array_type = try self.result.types.array(self.result.types.builtins.string);
                if (call.arguments.len != 2) {
                    try self.report(call.span, "Type Error: строки.соединить() ожидает 2 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], array_type), array_type)) {
                    try self.report(call.span, "Type Error: строки.соединить() ожидает Массив(Строка) первым аргументом", .{});
                }
                if (!self.assignable(try self.inferExpected(call.arguments[1], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: строки.соединить() ожидает разделитель типа Строка", .{});
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "сжатие", "разжать_gzip")) {
                const result_type = self.resultOfString(self.result.types.builtins.string) orelse return self.result.types.poison();
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: сжатие.разжать_gzip() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return result_type;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: сжатие.разжать_gzip() ожидает Строку", .{});
                }
                return result_type;
            }
            if (self.isBuiltinModule(symbol, "синтаксис", "структуры")) {
                const array_type = try self.result.types.array(self.result.types.builtins.string);
                const result_type = self.resultOfString(array_type) orelse return self.result.types.poison();
                return self.checkStringArgsBuiltin(call, "синтаксис.структуры", 1, result_type);
            }
            if (self.isBuiltinModule(symbol, "синтаксис", "поля")) {
                const field_pair = try self.result.types.tuple(&.{ self.result.types.builtins.string, self.result.types.builtins.string });
                const array_type = try self.result.types.array(field_pair);
                const result_type = self.resultOfString(array_type) orelse return self.result.types.poison();
                return self.checkStringArgsBuiltin(call, "синтаксис.поля", 2, result_type);
            }
            if (self.isBuiltinModule(symbol, "синтаксис", "импорты")) {
                const import_pair = try self.result.types.tuple(&.{ self.result.types.builtins.string, self.result.types.builtins.string });
                const array_type = try self.result.types.array(import_pair);
                const result_type = self.resultOfString(array_type) orelse return self.result.types.poison();
                return self.checkStringArgsBuiltin(call, "синтаксис.импорты", 1, result_type);
            }
            if (self.isBuiltinModule(symbol, "синтаксис", "аннотации")) {
                const array_type = try self.result.types.array(self.result.types.builtins.string);
                const result_type = self.resultOfString(array_type) orelse return self.result.types.poison();
                return self.checkStringArgsBuiltin(call, "синтаксис.аннотации", 2, result_type);
            }
            if (self.isBuiltinModule(symbol, "синтаксис", "аргумент_аннотации")) {
                const option_type = self.optionOf(self.result.types.builtins.string) orelse return self.result.types.poison();
                const result_type = self.resultOfString(option_type) orelse return self.result.types.poison();
                return self.checkStringArgsBuiltin(call, "синтаксис.аргумент_аннотации", 3, result_type);
            }
            if (self.isBuiltinModule(symbol, "синтаксис", "аннотации_поля")) {
                const array_type = try self.result.types.array(self.result.types.builtins.string);
                const result_type = self.resultOfString(array_type) orelse return self.result.types.poison();
                return self.checkStringArgsBuiltin(call, "синтаксис.аннотации_поля", 3, result_type);
            }
            if (self.isBuiltinModule(symbol, "синтаксис", "аргумент_аннотации_поля")) {
                const option_type = self.optionOf(self.result.types.builtins.string) orelse return self.result.types.poison();
                const result_type = self.resultOfString(option_type) orelse return self.result.types.poison();
                return self.checkStringArgsBuiltin(call, "синтаксис.аргумент_аннотации_поля", 4, result_type);
            }
            if (self.isBuiltinModule(symbol, "сеть", "подключиться")) {
                const connection_symbol = self.findTypeSymbol("Соединение") orelse return self.result.types.poison();
                const connection_type = try self.nominalType(connection_symbol, &.{});
                const result_type = self.resultOfString(connection_type) orelse return self.result.types.poison();
                if (call.arguments.len != 2) {
                    try self.report(call.span, "Type Error: сеть.подключиться() ожидает 2 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return result_type;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: сеть.подключиться() ожидает хост типа Строка первым аргументом", .{});
                }
                if (!self.assignable(try self.inferExpected(call.arguments[1], self.result.types.builtins.integer), self.result.types.builtins.integer)) {
                    try self.report(call.span, "Type Error: сеть.подключиться() ожидает порт типа Целое вторым аргументом", .{});
                }
                return result_type;
            }
            if (self.isBuiltinModule(symbol, "сеть", "кодировать_url")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: сеть.кодировать_url() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: сеть.кодировать_url() ожидает Строку", .{});
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "сеть", "декодировать_url")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: сеть.декодировать_url() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: сеть.декодировать_url() ожидает Строку", .{});
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "сеть", "http_запрос")) {
                // (статус, заголовки, тело) — плоский tuple, тот же
                // паттерн, что и у `ос.выполнить`: сырые данные, не
                // именованная структура (см. Odin's `core/stdlib.odin`
                // комментарий про `сеть::http_запрос`).
                const pair_type = try self.result.types.tuple(&.{ self.result.types.builtins.string, self.result.types.builtins.string });
                const headers_array = try self.result.types.array(pair_type);
                const success_type = try self.result.types.tuple(&.{ self.result.types.builtins.integer, headers_array, self.result.types.builtins.string });
                const result_type = self.resultOfString(success_type) orelse return self.result.types.poison();
                if (call.arguments.len != 4) {
                    try self.report(call.span, "Type Error: сеть.http_запрос() ожидает 4 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return result_type;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: сеть.http_запрос() ожидает метод типа Строка первым аргументом", .{});
                }
                if (!self.assignable(try self.inferExpected(call.arguments[1], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: сеть.http_запрос() ожидает url типа Строка вторым аргументом", .{});
                }
                if (!self.assignable(try self.inferExpected(call.arguments[2], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: сеть.http_запрос() ожидает тело типа Строка третьим аргументом", .{});
                }
                const headers_map_type = try self.result.types.map(self.result.types.builtins.string, self.result.types.builtins.string);
                if (!self.assignable(try self.inferExpected(call.arguments[3], headers_map_type), headers_map_type)) {
                    try self.report(call.span, "Type Error: сеть.http_запрос() ожидает Соответствие(Строка, Строка) четвёртым аргументом", .{});
                }
                return result_type;
            }
            if (self.isBuiltinModule(symbol, "сеть", "http_запрос_без_редиректа")) {
                const pair_type = try self.result.types.tuple(&.{ self.result.types.builtins.string, self.result.types.builtins.string });
                const headers_array = try self.result.types.array(pair_type);
                const success_type = try self.result.types.tuple(&.{ self.result.types.builtins.integer, headers_array, self.result.types.builtins.string });
                const result_type = self.resultOfString(success_type) orelse return self.result.types.poison();
                if (call.arguments.len != 4) {
                    try self.report(call.span, "Type Error: сеть.http_запрос_без_редиректа() ожидает 4 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return result_type;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: сеть.http_запрос_без_редиректа() ожидает метод типа Строка первым аргументом", .{});
                }
                if (!self.assignable(try self.inferExpected(call.arguments[1], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: сеть.http_запрос_без_редиректа() ожидает url типа Строка вторым аргументом", .{});
                }
                if (!self.assignable(try self.inferExpected(call.arguments[2], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: сеть.http_запрос_без_редиректа() ожидает тело типа Строка третьим аргументом", .{});
                }
                const headers_map_type = try self.result.types.map(self.result.types.builtins.string, self.result.types.builtins.string);
                if (!self.assignable(try self.inferExpected(call.arguments[3], headers_map_type), headers_map_type)) {
                    try self.report(call.span, "Type Error: сеть.http_запрос_без_редиректа() ожидает Соответствие(Строка, Строка) четвёртым аргументом", .{});
                }
                return result_type;
            }
            if (self.isBuiltinModule(symbol, "сеть", "http_запрос_sync")) {
                const option_type = self.optionOf(self.result.types.builtins.string) orelse return self.result.types.poison();
                if (call.arguments.len != 3) {
                    try self.report(call.span, "Type Error: сеть.http_запрос_sync() ожидает 3 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return option_type;
                }
                for (call.arguments) |argument| {
                    if (!self.assignable(try self.inferExpected(argument, self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: сеть.http_запрос_sync() ожидает метод, url и тело типа Строка", .{});
                    }
                }
                return option_type;
            }
            if (self.isBuiltinModule(symbol, "сеть", "http_запрос_sync_с_заголовками")) {
                // Симметрично http_запрос_sync — четвёртый аргумент:
                // дополнительные заголовки одной строкой, "Имя: значение"
                // на строку, разделённые "\n" (не Соответствие — тот же
                // "плоские данные" принцип, что и у самого http_запрос_sync;
                // хост-функция (JS) сама разбирает и добавляет через
                // setRequestHeader). Нужен для авторизованных вызовов
                // admin API из WASM-фронтенда (Authorization: Bearer ...).
                const option_type = self.optionOf(self.result.types.builtins.string) orelse return self.result.types.poison();
                if (call.arguments.len != 4) {
                    try self.report(call.span, "Type Error: сеть.http_запрос_sync_с_заголовками() ожидает 4 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return option_type;
                }
                for (call.arguments) |argument| {
                    if (!self.assignable(try self.inferExpected(argument, self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: сеть.http_запрос_sync_с_заголовками() ожидает метод, url, тело и заголовки типа Строка", .{});
                    }
                }
                return option_type;
            }
            if (self.isBuiltinModule(symbol, "сеть", "http_сервер_слушать")) {
                const listener_symbol = self.findTypeSymbol("Слушатель") orelse return self.result.types.poison();
                const listener_type = try self.nominalType(listener_symbol, &.{});
                const result_type = self.resultOfString(listener_type) orelse return self.result.types.poison();
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: сеть.http_сервер_слушать() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return result_type;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.integer), self.result.types.builtins.integer)) {
                    try self.report(call.span, "Type Error: сеть.http_сервер_слушать() ожидает порт типа Целое", .{});
                }
                return result_type;
            }
            if (self.isBuiltinModule(symbol, "бд", "открыть")) {
                const connection_symbol = self.findTypeSymbol("Соединение_БД") orelse return self.result.types.poison();
                const connection_type = try self.nominalType(connection_symbol, &.{});
                const result_type = self.resultOfString(connection_type) orelse return self.result.types.poison();
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: бд.открыть() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return result_type;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: бд.открыть() ожидает путь типа Строка", .{});
                }
                return result_type;
            }
            if (self.isBuiltinModule(symbol, "криптография", "hmac_sha256_base64url")) {
                if (call.arguments.len != 2) {
                    try self.report(call.span, "Type Error: криптография.hmac_sha256_base64url() ожидает 2 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: криптография.hmac_sha256_base64url() ожидает ключ типа Строка первым аргументом", .{});
                }
                if (!self.assignable(try self.inferExpected(call.arguments[1], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: криптография.hmac_sha256_base64url() ожидает сообщение типа Строка вторым аргументом", .{});
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "криптография", "base64url_кодировать")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: криптография.base64url_кодировать() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: криптография.base64url_кодировать() ожидает Строку", .{});
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "криптография", "base64url_декодировать")) {
                const result_type = self.resultOfString(self.result.types.builtins.string) orelse return self.result.types.poison();
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: криптография.base64url_декодировать() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return result_type;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: криптография.base64url_декодировать() ожидает Строку", .{});
                }
                return result_type;
            }
            if (self.isBuiltinModule(symbol, "криптография", "сравнить_константное_время")) {
                if (call.arguments.len != 2) {
                    try self.report(call.span, "Type Error: криптография.сравнить_константное_время() ожидает 2 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.boolean;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: криптография.сравнить_константное_время() ожидает Строку первым аргументом", .{});
                }
                if (!self.assignable(try self.inferExpected(call.arguments[1], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: криптография.сравнить_константное_время() ожидает Строку вторым аргументом", .{});
                }
                return self.result.types.builtins.boolean;
            }
            if (self.isBuiltinModule(symbol, "криптография", "sha256_base64url")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: криптография.sha256_base64url() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: криптография.sha256_base64url() ожидает Строку", .{});
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "криптография", "pbkdf2_sha256_base64url")) {
                if (call.arguments.len != 3) {
                    try self.report(call.span, "Type Error: криптография.pbkdf2_sha256_base64url() ожидает 3 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: криптография.pbkdf2_sha256_base64url() ожидает пароль типа Строка первым аргументом", .{});
                }
                if (!self.assignable(try self.inferExpected(call.arguments[1], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: криптография.pbkdf2_sha256_base64url() ожидает соль типа Строка вторым аргументом", .{});
                }
                if (!self.assignable(try self.inferExpected(call.arguments[2], self.result.types.builtins.number), self.result.types.builtins.number)) {
                    try self.report(call.span, "Type Error: криптография.pbkdf2_sha256_base64url() ожидает итерации типа Число третьим аргументом", .{});
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "криптография", "случайные_байты_base64url")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: криптография.случайные_байты_base64url() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.integer), self.result.types.builtins.integer)) {
                    try self.report(call.span, "Type Error: криптография.случайные_байты_base64url() ожидает количество байт типа Целое", .{});
                }
                return self.result.types.builtins.string;
            }
            // TOTP (RFC 6238) — целиком инкапсулированный алгоритм, не
            // отдельный голый hmac_sha1: сырые байты секрета никогда не
            // покидают native-код (base64url_декодировать выше явно
            // отклоняет НЕ-UTF8 результат — случайный секрет почти
            // никогда валидный UTF-8, значит Строка в принципе не может
            // безопасно нести сырые байты HMAC-ключа панос-стороной).
            if (self.isBuiltinModule(symbol, "криптография", "totp_секрет")) {
                for (call.arguments) |argument| _ = try self.infer(argument);
                if (call.arguments.len != 0) {
                    try self.report(call.span, "Type Error: криптография.totp_секрет() не принимает аргументы", .{});
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "криптография", "totp_код")) {
                if (call.arguments.len != 3) {
                    try self.report(call.span, "Type Error: криптография.totp_код() ожидает 3 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: криптография.totp_код() ожидает base32-секрет типа Строка первым аргументом", .{});
                }
                if (!self.assignable(try self.inferExpected(call.arguments[1], self.result.types.builtins.number), self.result.types.builtins.number)) {
                    try self.report(call.span, "Type Error: криптография.totp_код() ожидает время (секунды) типа Число вторым аргументом", .{});
                }
                if (!self.assignable(try self.inferExpected(call.arguments[2], self.result.types.builtins.number), self.result.types.builtins.number)) {
                    try self.report(call.span, "Type Error: криптография.totp_код() ожидает шаг (секунды) типа Число третьим аргументом", .{});
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "криптография", "es256_сгенерировать_ключи")) {
                for (call.arguments) |argument| _ = try self.infer(argument);
                if (call.arguments.len != 0) {
                    try self.report(call.span, "Type Error: криптография.es256_сгенерировать_ключи() не принимает аргументы", .{});
                }
                return try self.result.types.tuple(&.{ self.result.types.builtins.string, self.result.types.builtins.string, self.result.types.builtins.string });
            }
            if (self.isBuiltinModule(symbol, "криптография", "es256_подписать")) {
                if (call.arguments.len != 2) {
                    try self.report(call.span, "Type Error: криптография.es256_подписать() ожидает 2 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: криптография.es256_подписать() ожидает приватный ключ типа Строка первым аргументом", .{});
                }
                if (!self.assignable(try self.inferExpected(call.arguments[1], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: криптография.es256_подписать() ожидает сообщение типа Строка вторым аргументом", .{});
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "криптография", "es256_проверить")) {
                if (call.arguments.len != 4) {
                    try self.report(call.span, "Type Error: криптография.es256_проверить() ожидает 4 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.boolean;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: криптография.es256_проверить() ожидает x-координату типа Строка первым аргументом", .{});
                }
                if (!self.assignable(try self.inferExpected(call.arguments[1], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: криптография.es256_проверить() ожидает y-координату типа Строка вторым аргументом", .{});
                }
                if (!self.assignable(try self.inferExpected(call.arguments[2], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: криптография.es256_проверить() ожидает сообщение типа Строка третьим аргументом", .{});
                }
                if (!self.assignable(try self.inferExpected(call.arguments[3], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: криптография.es256_проверить() ожидает подпись типа Строка четвёртым аргументом", .{});
                }
                return self.result.types.builtins.boolean;
            }
            if (self.isBuiltin(symbol, "получить")) {
                if (call.arguments.len != 0) try self.report(call.span, "Type Error: получить() не принимает аргументы", .{});
                for (call.arguments) |argument| _ = try self.infer(argument);
                // Типизировано, когда ОХВАТЫВАЮЩАЯ функция объявила `->
                // Сообщение(T)` (`self.current_return`, установлено на
                // время проверки тела в `checkFunction`) — чисто
                // ЛОКАЛЬНОЕ чтение уже объявленной сигнатуры, не вывод.
                // Остаётся poison для любой другой формы функции
                // (включая простое `Пусто`).
                if (self.current_return) |return_type| {
                    if (self.messagePayload(return_type)) |payload| return payload;
                }
                return self.result.types.poison();
            }
            if (self.isBuiltin(symbol, "себя")) {
                if (call.arguments.len != 0) try self.report(call.span, "Type Error: себя() не принимает аргументы", .{});
                for (call.arguments) |argument| _ = try self.infer(argument);
                return self.result.types.process(try self.result.types.poison());
            }
            if (self.isBuiltin(symbol, "убить")) {
                if (call.arguments.len != 1) try self.report(call.span, "Type Error: убить() ожидает 1 аргумент", .{});
                for (call.arguments, 0..) |argument, index| {
                    const argument_type = try self.infer(argument);
                    if (index != 0) continue;
                    const argument_entry = self.result.types.get(argument_type) orelse continue;
                    switch (argument_entry.*) {
                        .process, .poison => {},
                        else => try self.report(call.span, "Type Error: убить() ожидает Процесс(T) первым аргументом", .{}),
                    }
                }
                return self.result.types.builtins.void;
            }
            if (self.isBuiltin(symbol, "связать")) {
                if (call.arguments.len != 1) try self.report(call.span, "Type Error: связать() ожидает 1 аргумент", .{});
                for (call.arguments, 0..) |argument, index| {
                    const argument_type = try self.infer(argument);
                    if (index != 0) continue;
                    const argument_entry = self.result.types.get(argument_type) orelse continue;
                    switch (argument_entry.*) {
                        .process, .poison => {},
                        else => try self.report(call.span, "Type Error: связать() ожидает Процесс(T) первым аргументом", .{}),
                    }
                }
                return self.result.types.builtins.void;
            }
            if (self.isBuiltin(symbol, "отправить")) {
                if (call.arguments.len != 2) {
                    try self.report(call.span, "Type Error: отправить() ожидает 2 аргумент(а)", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.void;
                }
                try self.checkSendMessageType(call.span, call.arguments[0], call.arguments[1]);
                return self.result.types.builtins.void;
            }
            if (self.isBuiltin(symbol, "наблюдать")) {
                if (call.arguments.len != 1) try self.report(call.span, "Type Error: наблюдать() ожидает 1 аргумент", .{});
                for (call.arguments) |argument| _ = try self.infer(argument);
                return self.result.types.builtins.void;
            }
            if (self.isBuiltin(symbol, "ждать")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: ждать() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.poison();
                }
                const argument_type = try self.infer(call.arguments[0]);
                const argument_entry = self.result.types.get(argument_type) orelse return self.result.types.poison();
                const result_type = switch (argument_entry.*) {
                    .process => |value_type| value_type,
                    .poison => return self.result.types.poison(),
                    else => blk: {
                        try self.report(call.span, "Type Error: ждать() ожидает Процесс(T) первым аргументом", .{});
                        break :blk try self.result.types.poison();
                    },
                };
                return self.resultOfString(result_type) orelse self.result.types.poison();
            }
            if (self.isBuiltin(symbol, "получить_сигнал")) {
                if (call.arguments.len != 0) try self.report(call.span, "Type Error: получить_сигнал() не принимает аргументы", .{});
                for (call.arguments) |argument| _ = try self.infer(argument);
                const option = self.findTypeSymbol("Опция") orelse return self.result.types.poison();
                const reason = try self.result.types.nominal(option, &.{self.result.types.builtins.string});
                // Идентификатор процесса дискретен (`Целое`), как и в
                // документации, и как ожидаемый тип аргумента у
                // `строки.из_целого` — фактическое рантайм-значение VM
                // всё равно простой f64 (`@floatFromInt` в
                // `queueSignal`), так что это исправление только для
                // тайпчекера, изменений байткода не требует.
                return self.result.types.tuple(&.{ self.result.types.builtins.integer, reason });
            }
            if (self.isBuiltin(symbol, "ограничить_почту")) {
                if (call.arguments.len != 1) try self.report(call.span, "Type Error: ограничить_почту() ожидает 1 аргумент", .{});
                for (call.arguments) |argument| _ = try self.infer(argument);
                return self.result.types.builtins.void;
            }
            if (self.isBuiltin(symbol, "отправить_или")) {
                if (call.arguments.len != 2) {
                    try self.report(call.span, "Type Error: отправить_или() ожидает 2 аргумент(а)", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.resultOfString(self.result.types.builtins.void) orelse self.result.types.poison();
                }
                try self.checkSendMessageType(call.span, call.arguments[0], call.arguments[1]);
                return self.resultOfString(self.result.types.builtins.void) orelse self.result.types.poison();
            }
            if (self.isBuiltin(symbol, "отмена")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: отмена() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.void;
                }
                const argument_type = try self.infer(call.arguments[0]);
                const argument_entry = self.result.types.get(argument_type) orelse return self.result.types.builtins.void;
                switch (argument_entry.*) {
                    .process, .poison => {},
                    else => try self.report(call.span, "Type Error: отмена() ожидает Процесс(T) первым аргументом", .{}),
                }
                return self.result.types.builtins.void;
            }
            if (self.isBuiltin(symbol, "отменено")) {
                if (call.arguments.len != 0) try self.report(call.span, "Type Error: отменено() не принимает аргументы", .{});
                for (call.arguments) |argument| _ = try self.infer(argument);
                return self.result.types.builtins.boolean;
            }
            if (self.isLengthBuiltin(symbol)) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: длина ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.integer;
                }
                const argument_type = try self.infer(call.arguments[0]);
                const argument = self.result.types.get(argument_type) orelse return self.result.types.poison();
                switch (argument.*) {
                    .primitive => |primitive| if (primitive == .string) return self.result.types.builtins.integer,
                    .array, .map => return self.result.types.builtins.integer,
                    .poison => return argument_type,
                    else => {},
                }
                try self.report(call.span, "Type Error: длина ожидает строку, массив или соответствие", .{});
                return self.result.types.poison();
            }
        }
        switch (self.tree.expr(call.callee).*) {
            .property => |property| {
                const object_type = try self.infer(property.object);
                if (try self.inferProcessMethod(call, property, object_type)) |method_type| return method_type;
                if (try self.inferPreludeEnumMethod(call, property, object_type)) |method_type| return method_type;
                if (try self.inferInterfaceCall(expression, call, property, object_type)) |method_type| return method_type;
                if (try self.inferGenericBoundInterfaceCall(expression, call, property, object_type)) |method_type| return method_type;
                if (try self.inferMethodCall(expression, call, property, object_type, null)) |method_type| return method_type;
                if (try self.inferDefaultInterfaceMethodCall(expression, call, property, object_type)) |method_type| return method_type;
                const object = self.result.types.get(object_type) orelse return self.result.types.poison();
                switch (object.*) {
                    .array => |element| {
                        if (std.mem.eql(u8, property.property, "длина")) {
                            try self.checkMethodArity(call, "длина", 0);
                            return self.result.types.builtins.integer;
                        }
                        if (std.mem.eql(u8, property.property, "есть")) {
                            try self.checkMethodArity(call, "есть", 1);
                            if (call.arguments.len != 0) {
                                const index = try self.infer(call.arguments[0]);
                                if (!self.isNumeric(index)) try self.report(call.span, "Type Error: индекс массива должен быть числом", .{});
                            }
                            return self.result.types.builtins.boolean;
                        }
                        if (std.mem.eql(u8, property.property, "получить")) {
                            try self.checkMethodArity(call, "получить", 2);
                            if (call.arguments.len != 0) {
                                const index = try self.infer(call.arguments[0]);
                                if (!self.isNumeric(index)) try self.report(call.span, "Type Error: индекс массива должен быть числом", .{});
                            }
                            if (call.arguments.len > 1 and !self.assignable(try self.inferExpected(call.arguments[1], element), element)) {
                                try self.report(call.span, "Type Error: значение по умолчанию имеет неверный тип", .{});
                            }
                            return element;
                        }
                        if (std.mem.eql(u8, property.property, "добавить")) {
                            try self.checkMethodArity(call, "добавить", 1);
                            if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], element), element)) {
                                try self.report(call.span, "Type Error: элемент массива имеет неверный тип", .{});
                            }
                            return self.result.types.builtins.void;
                        }
                        if (std.mem.eql(u8, property.property, "содержит")) {
                            try self.checkMethodArity(call, "содержит", 1);
                            if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], element), element)) {
                                try self.report(call.span, "Type Error: элемент массива имеет неверный тип", .{});
                            }
                            return self.result.types.builtins.boolean;
                        }
                        if (std.mem.eql(u8, property.property, "срез")) {
                            try self.checkMethodArity(call, "срез", 2);
                            for (call.arguments) |argument| {
                                if (!self.isNumeric(try self.infer(argument))) {
                                    try self.report(call.span, "Type Error: .срез() ожидает границы-числа", .{});
                                }
                            }
                            return object_type;
                        }
                    },
                    .primitive => |primitive| {
                        // Использует тот же путь выполнения
                        // `.string_length`/`строки::длина`, что уже
                        // использует свободная функция `длина(x)` —
                        // изменений VM не требуется, чисто пробел в
                        // диспетчеризации метода.
                        if (primitive == .string and std.mem.eql(u8, property.property, "длина")) {
                            try self.checkMethodArity(call, "длина", 0);
                            return self.result.types.builtins.integer;
                        }
                    },
                    .map => |map| {
                        if (std.mem.eql(u8, property.property, "длина")) {
                            try self.checkMethodArity(call, "длина", 0);
                            return self.result.types.builtins.integer;
                        }
                        if (std.mem.eql(u8, property.property, "есть")) {
                            try self.checkMethodArity(call, "есть", 1);
                            if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], map.key), map.key)) {
                                try self.report(call.span, "Type Error: ключ соответствия имеет неверный тип", .{});
                            }
                            return self.result.types.builtins.boolean;
                        }
                        if (std.mem.eql(u8, property.property, "получить")) {
                            try self.checkMethodArity(call, "получить", 2);
                            if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], map.key), map.key)) {
                                try self.report(call.span, "Type Error: ключ соответствия имеет неверный тип", .{});
                            }
                            if (call.arguments.len > 1 and !self.assignable(try self.inferExpected(call.arguments[1], map.value), map.value)) {
                                try self.report(call.span, "Type Error: значение по умолчанию имеет неверный тип", .{});
                            }
                            return map.value;
                        }
                        if (std.mem.eql(u8, property.property, "записи")) {
                            try self.checkMethodArity(call, "записи", 0);
                            const entry = try self.result.types.tuple(&.{ map.key, map.value });
                            return self.result.types.array(entry);
                        }
                        if (std.mem.eql(u8, property.property, "удалить")) {
                            try self.checkMethodArity(call, "удалить", 1);
                            if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], map.key), map.key)) {
                                try self.report(call.span, "Type Error: ключ соответствия имеет неверный тип", .{});
                            }
                            return self.result.types.builtins.boolean;
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
        // `о.метод[Тип](...)` — тот же паттерн, что `ф[Тип](...)` ниже,
        // только callee — `Index{ object: Property{object, property} }`
        // (метод), не `Index{ object: identifier }` (свободная функция).
        // Если `property.property` называет generic-МЕТОД получателя,
        // `[Тип]` — явные type-аргументы метода, не индексирование.
        if (self.tree.expr(call.callee).* == .index) {
            const index = self.tree.expr(call.callee).index;
            if (self.tree.expr(index.object).* == .property) {
                const inner_property = self.tree.expr(index.object).property;
                const receiver_type = try self.infer(inner_property.object);
                if (self.result.types.get(receiver_type)) |receiver_entry| {
                    if (receiver_entry.* == .nominal) {
                        if (self.inherentMethod(receiver_entry.nominal.symbol, inner_property.property)) |method| {
                            if (method.function_parameters.len != 0) {
                                const explicit_types = try self.resolveExplicitGenericArguments(index.index, method.function_parameters, call.span);
                                if (try self.inferMethodCall(expression, call, inner_property, receiver_type, explicit_types)) |method_type| return method_type;
                            }
                        }
                    }
                }
            }
        }
        // `ф[Тип](...)` — вызов с явным генерик-аргументом — парсится
        // как `Call_Expr{ callee: Index_Expr{ object, index } }` (та же
        // форма, что и "индексировать массив функций, затем вызвать
        // результат", например `функции[0](args)`). Неоднозначность
        // разрешается ЗДЕСЬ, семантически, а не парсером (у которого нет
        // отката назад и он не может знать во время парсинга, генерик ли
        // `ф`): если `index.object` разрешается в символ с
        // генерик-параметрами, `ф[Тип](...)` переинтерпретируется как
        // явный вызов — `effective_callee` становится `index.object`, а
        // `explicit_type_arguments` затравливается из `Тип`. Когда
        // `index.object` НЕ генерик-функция (обычное индексируемое
        // значение), ни то ни другое не меняется — существующий путь
        // "индекс затем вызов" ниже работает точно как и раньше.
        var effective_callee = call.callee;
        var explicit_type_arguments: ?[]const types.TypeId = null;
        if (self.tree.expr(call.callee).* == .index) {
            const index = self.tree.expr(call.callee).index;
            if (self.resolution.expr_symbols.get(index.object)) |object_symbol| {
                const generic_parameters = self.result.generic_function_parameters.get(object_symbol) orelse &.{};
                if (generic_parameters.len != 0) {
                    effective_callee = index.object;
                    explicit_type_arguments = try self.resolveExplicitGenericArguments(index.index, generic_parameters, call.span);
                }
            }
        }
        const callee_type = try self.infer(effective_callee);
        const entry = self.result.types.get(callee_type) orelse return self.result.types.poison();
        switch (entry.*) {
            .function => |function| {
                const callee_symbol = self.resolution.expr_symbols.get(effective_callee);
                const arguments = if (call.argument_names) |_| blk: {
                    const symbol = callee_symbol orelse {
                        try self.report(call.span, "Type Error: именованные аргументы не поддержаны для этого вызова", .{});
                        break :blk call.arguments;
                    };
                    const parameter_names = (try self.functionParameterNames(symbol)) orelse {
                        try self.report(call.span, "Type Error: именованные аргументы не поддержаны для этого вызова", .{});
                        break :blk call.arguments;
                    };
                    break :blk try self.reorderNamedArguments(expression, call, parameter_names);
                } else call.arguments;
                if (arguments.len != function.parameters.len) try self.report(call.span, "Type Error: неверное количество аргументов функции", .{});
                const shared = @min(arguments.len, function.parameters.len);
                const generic_parameters: []const GenericParameter = if (callee_symbol) |symbol|
                    self.result.generic_function_parameters.get(symbol) orelse &.{}
                else
                    &.{};
                if (generic_parameters.len != 0) {
                    var substitutions = std.AutoHashMap(types.TypeId, types.TypeId).init(self.result.allocator);
                    defer substitutions.deinit();
                    // Явные генерик-аргументы (`ф[Тип](...)`, обнаружены
                    // выше) затравливаются ПЕРВЫМИ, до всего, выведенного
                    // из контекста — расходящийся выведенный аргумент
                    // ниже (собственная проверка "запись уже
                    // существует" в `inferGenericSubstitution`) тогда
                    // сообщает конфликт как обычную неоднозначность
                    // подстановки, без отдельного механизма.
                    if (explicit_type_arguments) |explicit_types| {
                        for (generic_parameters, explicit_types) |parameter, resolved| {
                            try substitutions.put(parameter.typ, resolved);
                        }
                    }
                    // Затравка из ИЗВЕСТНОГО ожидаемого типа вызывающего
                    // ПЕРВОЙ (двунаправленная половина) — см.
                    // doc-комментарий `inferCallExpected`. Структурная
                    // унификация против `function.return_type`, тот же
                    // механизм, что уже использует вывод аргументов,
                    // просто пройденный в другую сторону (форма
                    // параметра = тип возврата, форма аргумента =
                    // ожидаемый тип вызывающего).
                    if (expected_return) |expected_type| {
                        try self.inferGenericSubstitution(function.return_type, expected_type, &substitutions, call.span);
                    }
                    for (arguments[0..shared], function.parameters[0..shared]) |argument, parameter| {
                        try self.inferGenericSubstitution(parameter, try self.infer(argument), &substitutions, call.span);
                    }
                    // Параметр типа, встречающийся ТОЛЬКО в типе
                    // ВОЗВРАТА (никогда ни в одном параметре), нельзя
                    // вывести из одних лишь аргументов вызова — шаг
                    // затравки выше обрабатывает случай, когда
                    // ВЫЗЫВАЮЩИЙ предоставил ожидаемый тип; если его ТОЖЕ
                    // нет, контекста для разрешения действительно нет
                    // нигде (у панос нет межоператорного/отложенного
                    // вывода и нет синтаксиса вызова с явным
                    // генерик-типом-аргументом в этом месте). Молчаливая
                    // подстановка `poison` в этом полностью
                    // неограниченном случае (без сообщения об ошибке) —
                    // не новая снисходительность: до того как
                    // межмодульные сигнатуры генерик-функций начали
                    // по-настоящему отслеживать `T` (см.
                    // `ImportedSymbolType.generic_parameters`), КАЖДЫЙ
                    // такой вызов уже получал ровно это поведение
                    // случайно. Но когда `expected_return` БЫЛ доступен,
                    // а подстановка ВСЁ РАВНО провалилась (шаг затравки
                    // выше отработал и не разрешил каждый параметр) — это
                    // настоящий сбой вывода, а не случай отсутствия
                    // контекста — сообщаем об этом вместо молчаливого
                    // poison.
                    for (generic_parameters) |parameter| {
                        if (substitutions.contains(parameter.typ)) continue;
                        if (expected_return != null) {
                            try self.report(call.span, "Type Error: не удалось вывести type-параметр '{s}'", .{parameter.name});
                            try substitutions.put(parameter.typ, try self.result.types.poison());
                        } else {
                            try substitutions.put(parameter.typ, try self.result.types.unconstrained());
                        }
                    }
                    for (generic_parameters) |parameter| {
                        // Цикл заполнения прямо выше гарантирует, что к
                        // этому моменту у каждой записи
                        // `generic_parameters` есть подстановка (найдена
                        // из контекста либо явно заполнена poison) —
                        // `orelse` здесь означал бы, что эта гарантия
                        // молча нарушилась; делаем это громко вместо
                        // этого.
                        const actual = substitutions.get(parameter.typ) orelse unreachable;
                        if (self.isPoison(actual)) continue;
                        for (parameter.bounds) |bound| {
                            if (!self.satisfiesInterfaceBound(actual, bound)) {
                                const interface = self.resolution.symbols.get(bound) orelse continue;
                                try self.report(call.span, "Type Error: тип аргумента не реализует ограничение '{s}'", .{interface.name});
                            }
                        }
                    }
                    for (arguments[0..shared], function.parameters[0..shared]) |argument, parameter| {
                        const expected = try self.substituteGeneric(parameter, &substitutions);
                        const actual = try self.inferExpected(argument, expected);
                        if (!self.assignable(actual, expected)) {
                            try self.report(call.span, "Type Error: аргумент не совпадает с типом параметра", .{});
                        } else if (try self.genericInterfaceBounds(parameter, generic_parameters)) |bounds| {
                            // Генерик-функция, параметр которой ограничен
                            // пользовательским интерфейсом (`функ ф[T:
                            // ИзTOML](это: T, ...)`), вызвана с
                            // конкретным аргументом-структурой. Генерик-
                            // функции панос НЕ мономорфизируются
                            // (компилируются один раз, генерически — вовсе
                            // не существует специализации по точке
                            // вызова), так что `это.метод()` внутри
                            // генерик-тела не имеет конкретного типа для
                            // диспетчеризации; ЕДИНСТВЕННЫЙ механизм,
                            // который у этой VM есть для диспетчеризации
                            // вызова метода без знания конкретного типа во
                            // время компиляции — существующая vtable
                            // интерфейса (`Cast_Interface`/
                            // `Invoke_Interface`). Приведение АРГУМЕНТА к
                            // ограничивающему интерфейсному типу здесь
                            // (вместо `expected`, что — поскольку
                            // подстановка разрешает T в собственный
                            // конкретный тип аргумента — всегда
                            // приведение-заглушка того же типа) — именно
                            // то, что делает такую диспетчеризацию
                            // возможной: значение, реально попадающее в
                            // слот параметра `T` генерик-функции — это
                            // рантайм-представление, обёрнутое интерфейсом,
                            // так что параллельная обработка типов
                            // получателя `.generic_parameter` в
                            // `inferMethodCall` (см. `interfaceBoundOf`/
                            // `inferInterfaceCall`) может скомпилировать
                            // `это.метод()` как обычный `call_interface`
                            // против той же vtable — мономорфизация не
                            // нужна.
                            try self.registerGenericInterfaceCasts(argument, actual, bounds);
                        } else {
                            try self.registerInterfaceCast(argument, actual, expected);
                        }
                    }
                    return self.substituteGeneric(function.return_type, &substitutions);
                }
                for (arguments[0..shared], function.parameters[0..shared]) |argument, parameter| {
                    const actual = try self.inferExpected(argument, parameter);
                    if (!self.assignable(actual, parameter)) {
                        try self.report(call.span, "Type Error: аргумент не совпадает с типом параметра", .{});
                    } else {
                        try self.registerInterfaceCast(argument, actual, parameter);
                    }
                }
                return function.return_type;
            },
            .nominal => |nominal| {
                if (self.result.generic_nominal_fields.get(nominal.symbol)) |generic_nominal| {
                    // Использует тот же кэш `reorderNamedArguments`/
                    // `call_arguments`, что уже применяется выше для
                    // обычного вызова ФУНКЦИИ с именованными аргументами
                    // — `compileCall` в `compiler.zig` уже читает ТОТ ЖЕ
                    // кэш для кодогенерации, так что исправления порядка
                    // здесь достаточно и для тайпчека, И для
                    // кодогенерации.
                    const arguments = if (call.argument_names) |_| blk: {
                        const names = try self.result.arena.allocator().alloc([]const u8, generic_nominal.fields.len);
                        for (generic_nominal.fields, names) |field, *name| name.* = field.name;
                        break :blk try self.reorderNamedArguments(expression, call, names);
                    } else call.arguments;
                    if (arguments.len != generic_nominal.fields.len) try self.report(call.span, "Type Error: неверное количество аргументов конструктора структуры", .{});
                    const shared = @min(arguments.len, generic_nominal.fields.len);
                    var substitutions = std.AutoHashMap(types.TypeId, types.TypeId).init(self.result.allocator);
                    defer substitutions.deinit();
                    var seeded_from_expected = false;
                    // Конструктор generic-структуры участвует в том же
                    // двунаправленном выводе, что generic-функция выше.
                    // Без этой затравки `Обновление(модель,
                    // Команда.Нет())` не могло вывести `Сообщение`, хотя
                    // окружающий return уже ожидал
                    // `Обновление(Модель, Сообщение)`: внутренний
                    // `Команда.Нет()` получал poison вместо конкретного
                    // expected-типа поля. Сопоставляем декларации через
                    // стабильный nominal identity, как `assignable` и
                    // `inferGenericSubstitution`, чтобы это работало и
                    // для импортированных типов.
                    if (expected_return) |expected_type| {
                        if (self.result.types.get(expected_type)) |expected_entry| {
                            if (expected_entry.* == .nominal) {
                                const expected_nominal = expected_entry.nominal;
                                const same_declaration = if (nominal.identity != 0 or expected_nominal.identity != 0)
                                    nominal.identity != 0 and nominal.identity == expected_nominal.identity
                                else
                                    nominal.symbol == expected_nominal.symbol;
                                if (same_declaration and generic_nominal.parameters.len == expected_nominal.arguments.len) {
                                    for (generic_nominal.parameters, expected_nominal.arguments) |parameter, argument| {
                                        try substitutions.put(parameter.typ, argument);
                                    }
                                    seeded_from_expected = true;
                                }
                            }
                        }
                    }
                    for (arguments[0..shared], generic_nominal.fields[0..shared]) |argument, field| {
                        const actual = if (seeded_from_expected)
                            try self.inferExpected(argument, try self.substituteGeneric(field.typ, &substitutions))
                        else
                            try self.infer(argument);
                        try self.inferGenericSubstitution(field.typ, actual, &substitutions, call.span);
                    }
                    var type_arguments: std.ArrayList(types.TypeId) = .empty;
                    defer type_arguments.deinit(self.result.allocator);
                    for (generic_nominal.parameters) |parameter| {
                        if (substitutions.get(parameter.typ)) |argument| {
                            try type_arguments.append(self.result.allocator, argument);
                        } else {
                            try self.report(call.span, "Type Error: не удалось вывести type-параметр '{s}'", .{parameter.name});
                            try type_arguments.append(self.result.allocator, try self.result.types.poison());
                        }
                    }
                    const constructor_type = try self.nominalType(nominal.symbol, type_arguments.items);
                    for (arguments[0..shared], generic_nominal.fields[0..shared]) |argument, field| {
                        const expected = try self.substituteGeneric(field.typ, &substitutions);
                        const actual = try self.inferExpected(argument, expected);
                        if (!self.assignable(actual, expected)) {
                            try self.report(call.span, "Type Error: аргумент конструктора не совпадает с типом поля", .{});
                        } else {
                            try self.registerInterfaceCast(argument, actual, expected);
                        }
                    }
                    return constructor_type;
                }
                if (self.result.nominal_fields.get(nominal.symbol)) |fields| {
                    const arguments = if (call.argument_names) |_| blk: {
                        const names = try self.result.arena.allocator().alloc([]const u8, fields.len);
                        for (fields, names) |field, *name| name.* = field.name;
                        break :blk try self.reorderNamedArguments(expression, call, names);
                    } else call.arguments;
                    if (arguments.len != fields.len) try self.report(call.span, "Type Error: неверное количество аргументов конструктора структуры", .{});
                    const shared = @min(arguments.len, fields.len);
                    for (arguments[0..shared], fields[0..shared]) |argument, field| {
                        // `registerInterfaceCast` — каждая ДРУГАЯ точка
                        // проверки аргумента (возврат, вызов метода,
                        // вариант перечисления) уже вызывает это при
                        // успехе; обычный конструктор структуры этого
                        // не делал, так что поле с интерфейсным типом,
                        // получившее конкретное значение, хранило бы сырое
                        // значение неприведённым — вызов метода на этом
                        // поле позже падал бы во время выполнения, так
                        // как у компилятора не было записанного
                        // приведения для компиляции настоящего
                        // `Cast_Interface`.
                        const actual = try self.inferExpected(argument, field.typ);
                        if (!self.assignable(actual, field.typ)) {
                            try self.report(call.span, "Type Error: аргумент конструктора не совпадает с типом поля", .{});
                        } else {
                            try self.registerInterfaceCast(argument, actual, field.typ);
                        }
                    }
                    return callee_type;
                }
                try self.report(call.span, "Type Error: вызвано значение, не являющееся функцией", .{});
                return self.result.types.poison();
            },
            else => {
                try self.report(call.span, "Type Error: вызвано значение, не являющееся функцией", .{});
                return self.result.types.poison();
            },
        }
    }

    fn checkMethodArity(self: *Checker, call: anytype, name: []const u8, expected: usize) !void {
        if (call.arguments.len == expected) return;
        try self.report(call.span, "Type Error: метод '{s}' ожидает {d} аргумент(а)", .{ name, expected });
        for (call.arguments) |argument| _ = try self.infer(argument);
    }

    // Общая проверка арности + все-аргументы-Строка для `синтаксис.*`
    // (2-4 обычных аргумента-Строка путь/имя, различать по отдельности
    // не имеет смысла — в отличие от `ос.выполнить`, где смешаны
    // `Строка`/`Массив(Строка)`).
    fn checkStringArgsBuiltin(self: *Checker, call: anytype, name: []const u8, expected_arity: usize, result_type: types.TypeId) !types.TypeId {
        if (call.arguments.len != expected_arity) {
            try self.report(call.span, "Type Error: {s}() ожидает {d} аргумент(а)", .{ name, expected_arity });
            for (call.arguments) |argument| _ = try self.infer(argument);
            return result_type;
        }
        for (call.arguments) |argument| {
            if (!self.assignable(try self.inferExpected(argument, self.result.types.builtins.string), self.result.types.builtins.string)) {
                try self.report(call.span, "Type Error: {s}() ожидает аргументы типа Строка", .{name});
            }
        }
        return result_type;
    }

    fn functionParameterNames(self: *Checker, symbol: symbols.SymbolId) !?[]const []const u8 {
        if (self.result.imported_method_parameter_names.get(symbol)) |names| return names;
        var functions = self.resolution.function_parameters.iterator();
        while (functions.next()) |entry| {
            const declaration = entry.key_ptr.*;
            const function_symbol = self.resolution.decl_symbols.get(declaration) orelse continue;
            if (function_symbol != symbol) continue;
            const parameters = entry.value_ptr.*;
            const names = try self.result.arena.allocator().alloc([]const u8, parameters.len);
            for (parameters, names) |parameter, *name| name.* = self.resolution.symbols.get(parameter).?.name;
            return names;
        }
        return null;
    }

    fn reorderNamedArguments(self: *Checker, expression: ast.ExprId, call: anytype, parameter_names: []const []const u8) ![]const ast.ExprId {
        const argument_names = call.argument_names orelse return call.arguments;
        if (argument_names.len != parameter_names.len) {
            try self.report(call.span, "Type Error: ожидалось {d} именованных аргументов, получено {d}", .{ parameter_names.len, argument_names.len });
            return call.arguments;
        }
        const ordered = try self.result.arena.allocator().alloc(ast.ExprId, argument_names.len);
        const matched = try self.result.allocator.alloc(bool, parameter_names.len);
        defer self.result.allocator.free(matched);
        @memset(matched, false);
        var valid = true;
        for (argument_names, call.arguments) |argument_name, argument| {
            var parameter_index: ?usize = null;
            for (parameter_names, 0..) |parameter_name, index| {
                if (std.mem.eql(u8, argument_name, parameter_name)) {
                    parameter_index = index;
                    break;
                }
            }
            const index = parameter_index orelse {
                try self.report(call.span, "Type Error: неизвестный именованный аргумент '{s}'", .{argument_name});
                valid = false;
                continue;
            };
            if (matched[index]) {
                try self.report(call.span, "Type Error: именованный аргумент '{s}' указан повторно", .{argument_name});
                valid = false;
                continue;
            }
            matched[index] = true;
            ordered[index] = argument;
        }
        if (!valid) return call.arguments;
        try self.result.call_arguments.put(expression, ordered);
        return ordered;
    }

    fn resolveType(self: *Checker, type_node: ast.TypeId) !types.TypeId {
        return switch (self.tree.typeNode(type_node).*) {
            .ident => |ident| self.findGenericParameter(ident.name) orelse builtinType(&self.result.types, ident.name) orelse blk: {
                if (self.findTypeSymbol(ident.name)) |symbol| {
                    if (self.result.alias_type_nodes.contains(symbol)) break :blk try self.resolveAlias(symbol, ident.span);
                    if (self.current_nominal_owner) |owner| {
                        if (owner.symbol == symbol) {
                            var arguments: std.ArrayList(types.TypeId) = .empty;
                            defer arguments.deinit(self.result.allocator);
                            for (owner.parameters) |parameter| try arguments.append(self.result.allocator, parameter.typ);
                            break :blk try self.result.types.nominal(symbol, arguments.items);
                        }
                    }
                    break :blk try self.nominalType(symbol, &.{});
                }
                try self.report(ident.span, "Type Error: неизвестный тип '{s}'", .{ident.name});
                break :blk try self.result.types.poison();
            },
            .generic => |generic| blk: {
                if (std.mem.eql(u8, generic.name, "Массив") and generic.parameters.len == 1) break :blk try self.result.types.array(try self.resolveType(generic.parameters[0]));
                if (std.mem.eql(u8, generic.name, "Соответствие") and generic.parameters.len == 2) break :blk try self.result.types.map(try self.resolveType(generic.parameters[0]), try self.resolveType(generic.parameters[1]));
                if (std.mem.eql(u8, generic.name, "Процесс") and generic.parameters.len == 1) break :blk try self.result.types.process(try self.resolveType(generic.parameters[0]));
                if (std.mem.eql(u8, generic.name, "Сообщение") and generic.parameters.len == 1) break :blk try self.result.types.message(try self.resolveType(generic.parameters[0]));
                if (self.findTypeSymbol(generic.name)) |symbol| {
                    var arguments: std.ArrayList(types.TypeId) = .empty;
                    defer arguments.deinit(self.result.allocator);
                    for (generic.parameters) |parameter| try arguments.append(self.result.allocator, try self.resolveType(parameter));
                    break :blk try self.nominalType(symbol, arguments.items);
                }
                try self.report(generic.span, "Type Error: неизвестный generic-тип '{s}'", .{generic.name});
                break :blk try self.result.types.poison();
            },
            .tuple => |tuple| blk: {
                var elements: std.ArrayList(types.TypeId) = .empty;
                defer elements.deinit(self.result.allocator);
                for (tuple.elements) |element| try elements.append(self.result.allocator, try self.resolveType(element));
                break :blk try self.result.types.tuple(elements.items);
            },
            .function => |function| blk: {
                var parameters: std.ArrayList(types.TypeId) = .empty;
                defer parameters.deinit(self.result.allocator);
                for (function.parameters) |parameter| try parameters.append(self.result.allocator, try self.resolveType(parameter));
                break :blk try self.result.types.function(parameters.items, try self.resolveType(function.return_type));
            },
            .qualified => |qualified| blk: {
                const symbol = self.findQualifiedTypeSymbol(qualified.module_name, qualified.name) orelse {
                    try self.report(qualified.span, "Type Error: неизвестный тип '{s}.{s}'", .{ qualified.module_name, qualified.name });
                    break :blk try self.result.types.poison();
                };
                // Квалифицированный ПСЕВДОНИМ ТИПА (`lib.Обработчик`),
                // перенесённый через `ImportContext.type_aliases` —
                // проверяется ДО `nominalType` ниже, которая иначе
                // обернула бы его непрозрачным номинальным типом вовсе
                // без вызываемой/структурной формы (см. ветку `.ident` в
                // `resolveType`, которая уже проверяет `alias_type_nodes`
                // таким же образом для случая внутри одного модуля).
                if (self.result.type_aliases.get(symbol)) |aliased| break :blk aliased;
                var arguments: std.ArrayList(types.TypeId) = .empty;
                defer arguments.deinit(self.result.allocator);
                for (qualified.parameters) |parameter| try arguments.append(self.result.allocator, try self.resolveType(parameter));
                break :blk try self.nominalType(symbol, arguments.items);
            },
            else => try self.result.types.poison(),
        };
    }

    // Параллельна `resolveType` (`ast.TypeId -> types.TypeId`), но
    // отправляется от ОБЫЧНОГО ВЫРАЖЕНИЯ вместо настоящего `TypeNode`.
    // Нужна для вызовов с явным генерик-аргументом `ф[Тип](...)`: `Тип`
    // парсится как поле `index` у `Index_Expr` — это `Expr`, а не
    // `TypeNode` — реального AST узла типа для передачи в `resolveType`
    // нет, а синтезировать его означало бы изменять `self.tree`, который
    // здесь `*const Ast`. Переиспользует ТЕ ЖЕ вспомогательные функции
    // поиска символов, что уже вызывает `resolveType`
    // (`findGenericParameter`, `builtinType`, `findTypeSymbol`,
    // `findQualifiedTypeSymbol`, `nominalType`) — отличается только форма
    // входа.
    //
    // Возвращает `null`, когда форма `expr` ВООБЩЕ не может обозначать
    // тип (арифметика, произвольные вызовы, строковые/числовые
    // литералы, ...) — вызывающий (обнаружение явного генерик-вызова в
    // `inferCallExpected`) сообщает ЭТОТ случай сам, с сообщением,
    // отличным от "похоже на тип, но имя неизвестно" (которое эта
    // функция сообщает напрямую, отражая собственную диагностику
    // `resolveType`).
    fn resolveTypeFromExpr(self: *Checker, expr: ast.ExprId) anyerror!?types.TypeId {
        return switch (self.tree.expr(expr).*) {
            .ident => |ident| self.findGenericParameter(ident.name) orelse builtinType(&self.result.types, ident.name) orelse blk: {
                if (self.findTypeSymbol(ident.name)) |symbol| {
                    if (self.result.alias_type_nodes.contains(symbol)) break :blk try self.resolveAlias(symbol, ident.span);
                    break :blk try self.nominalType(symbol, &.{});
                }
                try self.report(ident.span, "Type Error: неизвестный тип '{s}'", .{ident.name});
                break :blk try self.result.types.poison();
            },
            // `модуль.Тип` — квалифицированное имя типа. Только голый
            // объект `.ident` похож на тип (более глубоких цепочек вроде
            // `а.б.Тип` для модулей панос не существует, они никогда не
            // вложены); всё остальное означает, что этот `.property` —
            // обычное выражение-значение, не ссылка на тип.
            .property => |property| blk: {
                if (self.tree.expr(property.object).* != .ident) break :blk null;
                const module_name = self.tree.expr(property.object).ident.name;
                const symbol = self.findQualifiedTypeSymbol(module_name, property.property) orelse {
                    try self.report(property.span, "Type Error: неизвестный тип '{s}.{s}'", .{ module_name, property.property });
                    break :blk try self.result.types.poison();
                };
                if (self.result.type_aliases.get(symbol)) |aliased| break :blk aliased;
                break :blk try self.nominalType(symbol, &.{});
            },
            // `Тип(Аргумент, ...)` — генерик-инстанциация, написанная в
            // точке вызова, той же формы, что и вызов конструктора.
            // `callee` сам должен быть похож на тип (`.ident`/`.property`
            // как выше); каждый аргумент разрешается рекурсивно через ЭТУ
            // ЖЕ функцию, так что вложенные инстанциации
            // (`Список(Коробка(Число))`) работают без дополнительных
            // случаев.
            .call => |call| blk: {
                const callee_expr = self.tree.expr(call.callee).*;
                const symbol = switch (callee_expr) {
                    .ident => |ident| self.findTypeSymbol(ident.name) orelse break :blk null,
                    .property => |property| prop_blk: {
                        if (self.tree.expr(property.object).* != .ident) break :blk null;
                        const module_name = self.tree.expr(property.object).ident.name;
                        break :prop_blk self.findQualifiedTypeSymbol(module_name, property.property) orelse break :blk null;
                    },
                    else => break :blk null,
                };
                var arguments: std.ArrayList(types.TypeId) = .empty;
                defer arguments.deinit(self.result.allocator);
                for (call.arguments) |argument_expr| {
                    const argument_type = (try self.resolveTypeFromExpr(argument_expr)) orelse break :blk null;
                    try arguments.append(self.result.allocator, argument_type);
                }
                break :blk try self.nominalType(symbol, arguments.items);
            },
            else => null,
        };
    }

    // Извлекает список явных type-аргументов из поля `index` у
    // `Index_Expr` для подтверждённой точки явного генерик-вызова (см.
    // `inferCallExpected`). Один аргумент — само голое выражение
    // (`ф[Тип](...)`); несколько — существующий `Tuple_Expr`,
    // переиспользуемый как контейнер (`ф[(Т1, Т2)](...)`). Всегда
    // возвращает ровно `generic_parameters.len` записей (заполнено
    // poison при несовпадении арности или неразрешённой форме), так что
    // цикл затравки подстановок у вызывающего никогда не должен
    // отдельно обрабатывать короткий список.
    fn resolveExplicitGenericArguments(
        self: *Checker,
        index_value: ast.ExprId,
        generic_parameters: []const GenericParameter,
        span: source.Span,
    ) anyerror![]const types.TypeId {
        const type_exprs: []const ast.ExprId = switch (self.tree.expr(index_value).*) {
            .tuple => |tuple| tuple.elements,
            else => &[_]ast.ExprId{index_value},
        };
        const resolved = try self.result.arena.allocator().alloc(types.TypeId, generic_parameters.len);
        if (type_exprs.len != generic_parameters.len) {
            try self.report(span, "Type Error: неверное количество явных type-аргументов", .{});
            for (resolved) |*slot| slot.* = try self.result.types.poison();
            return resolved;
        }
        for (type_exprs, resolved) |type_expr, *slot| {
            slot.* = (try self.resolveTypeFromExpr(type_expr)) orelse blk: {
                try self.report(ast.exprSpan(self.tree.expr(type_expr).*), "Type Error: явный generic-аргумент должен быть именем типа", .{});
                break :blk try self.result.types.poison();
            };
        }
        return resolved;
    }

    // Возвращает ПЕРВОЕ интерфейсное ограничение `parameter`, если
    // `parameter` (как записан в объявлении, до генерик-подстановки) —
    // тип `.generic_parameter` хотя бы с одним интерфейсным
    // ограничением. "первое" — на практике ни один параметр не объявляет
    // больше одного ограничения; значение в любом случае можно привести
    // через `Cast_Interface` только к ОДНОМУ интерфейсному типу за раз
    // (см. единственную запись `interface_casts` на выражение в
    // `registerInterfaceCast`), так что несколько ограничений
    // потребовали бы принципиально другого механизма, который здесь не
    // реализован.
    fn interfaceBoundOf(self: *const Checker, parameter: types.TypeId, generic_parameters: []const GenericParameter) !?symbols.SymbolId {
        const entry = self.result.types.get(parameter) orelse return null;
        if (entry.* != .generic_parameter) return null;
        for (generic_parameters) |candidate| {
            if (!candidate.typ.eql(parameter)) continue;
            for (candidate.bounds) |bound| {
                // `Сравниваемое` намеренно ИСКЛЮЧЕНО здесь — у него
                // собственный, более старый, не через vtable механизм
                // диспетчеризации для сравнений с генерик-ограничением
                // (`registerComparableMethods`/`addComparableMethod` в
                // `compiler.zig`, VM ищет метод по СОБСТВЕННОМУ имени
                // структуры рантайм-значения, не по vtable интерфейса).
                // Этот механизм требует, чтобы значение поступало в
                // генерик-функцию НЕИЗМЕНЁННЫМ (без приведения) — обычное
                // Число или обычный агрегат структуры — так что
                // приведение его здесь к интерфейсному типу (превращение
                // в обёрнутое интерфейсом рантайм-значение) сломало бы
                // диспетчеризацию `a > b` для каждого существующего
                // вызывающего `[T: Сравниваемое]`. У каждого ДРУГОГО
                // пользовательского интерфейсного ограничения нет такого
                // ранее существовавшего механизма, так что приведение —
                // единственный способ, которым `это.метод()` внутри
                // генерик-тела вообще может диспетчеризоваться (см.
                // `inferGenericBoundInterfaceCall`).
                if (self.isComparableInterface(bound)) continue;
                return bound;
            }
            return null;
        }
        return null;
    }

    fn genericInterfaceBounds(self: *const Checker, parameter: types.TypeId, generic_parameters: []const GenericParameter) !?[]const symbols.SymbolId {
        const entry = self.result.types.get(parameter) orelse return null;
        if (entry.* != .generic_parameter) return null;
        for (generic_parameters) |candidate| {
            if (!candidate.typ.eql(parameter)) continue;
            var count: usize = 0;
            for (candidate.bounds) |bound| {
                if (!self.isComparableInterface(bound)) count += 1;
            }
            if (count == 0) return null;
            const result = try self.result.arena.allocator().alloc(symbols.SymbolId, count);
            var index: usize = 0;
            for (candidate.bounds) |bound| {
                if (self.isComparableInterface(bound)) continue;
                result[index] = bound;
                index += 1;
            }
            return result;
        }
        return null;
    }

    fn nominalType(self: *Checker, symbol: symbols.SymbolId, arguments: []const types.TypeId) !types.TypeId {
        if (self.result.imported_nominal_identities.get(symbol)) |identity| {
            return self.result.types.nominalWithIdentity(symbol, identity, arguments);
        }
        return self.result.types.nominal(symbol, arguments);
    }

    fn assignable(self: *const Checker, actual: types.TypeId, expected: types.TypeId) bool {
        const actual_type = self.result.types.get(actual) orelse return false;
        const expected_type = self.result.types.get(expected) orelse return false;
        if (actual_type.* == .poison or expected_type.* == .poison) return true;
        if (actual_type.* == .unconstrained or expected_type.* == .unconstrained) return true;
        if (actual.eql(self.result.types.builtins.never)) return true;
        if (actual_type.* == .process and self.isPoison(actual_type.process)) return true;
        if (self.result.types.eql(actual, expected)) return true;
        // ПУСТОЙ литерал массива/соответствия (`массив()`/
        // `соответствие()`) выводится как `Массив(poison)`/
        // `Соответствие(poison, poison)` (веткам `.array`/`.map` в
        // `inferBinary` не из чего вывести настоящий тип) — `eql` выше
        // уже отклоняет это против любого конкретно типизированного
        // массива/соответствия (poison структурно не равен ничему), так
        // что совершенно обычное `это.поле = массив()` (сброс
        // типизированного поля/переменной в пустое) проваливалось бы с
        // "присваивание несовместимых типов". Рекурсия через сам
        // `assignable` (не `eql`) позволяет сработать проверке poison в
        // начале функции для типа ЭЛЕМЕНТА.
        switch (actual_type.*) {
            .array => |actual_element| switch (expected_type.*) {
                .array => |expected_element| return self.assignable(actual_element, expected_element),
                else => {},
            },
            .map => |actual_map| switch (expected_type.*) {
                .map => |expected_map| return self.assignable(actual_map.key, expected_map.key) and self.assignable(actual_map.value, expected_map.value),
                else => {},
            },
            .function => |actual_function| switch (expected_type.*) {
                .function => |expected_function| {
                    if (actual_function.parameters.len != expected_function.parameters.len) return false;
                    for (actual_function.parameters, expected_function.parameters) |actual_parameter, expected_parameter| {
                        if (!self.isPoison(actual_parameter) and !self.isPoison(expected_parameter) and !self.result.types.eql(actual_parameter, expected_parameter)) return false;
                    }
                    return self.isPoison(actual_function.return_type) or self.isPoison(expected_function.return_type) or
                        self.result.types.eql(actual_function.return_type, expected_function.return_type) or
                        self.isType(actual_function.return_type, self.result.types.builtins.never);
                },
                else => {},
            },
            else => {},
        }
        const actual_nominal = switch (actual_type.*) {
            .nominal => |value| value,
            else => return false,
        };
        const expected_nominal = switch (expected_type.*) {
            .nominal => |value| value,
            else => return false,
        };
        if (self.result.interface_definitions.get(expected_nominal.symbol)) |interface| {
            if (interface.parameters.len != expected_nominal.arguments.len) return false;
            return self.interfaceImplementation(expected_nominal.symbol, expected_nominal.arguments, actual_nominal.symbol, actual_nominal.arguments) != null;
        }
        // Одна и та же генерик-структура/перечисление, аргументы типа
        // совместимы поэлементно (не `eql`) — например `Селектор(poison)`
        // против объявленного `Селектор(T)`. Отражает поэлементную
        // рекурсию массива/соответствия чуть выше.
        const same_declaration = if (actual_nominal.identity != 0 or expected_nominal.identity != 0)
            actual_nominal.identity != 0 and actual_nominal.identity == expected_nominal.identity
        else
            actual_nominal.symbol == expected_nominal.symbol;
        if (same_declaration and actual_nominal.arguments.len == expected_nominal.arguments.len) {
            for (actual_nominal.arguments, expected_nominal.arguments) |actual_argument, expected_argument| {
                if (!self.assignable(actual_argument, expected_argument)) return false;
            }
            return true;
        }
        return false;
    }

    fn findTypeSymbol(self: *const Checker, name: []const u8) ?symbols.SymbolId {
        for (self.resolution.symbols.symbols.items[1..], 1..) |entry, index| {
            if (entry.kind == .type and std.mem.eql(u8, entry.name, name)) return @enumFromInt(index);
        }
        return null;
    }

    fn findQualifiedTypeSymbol(self: *const Checker, module_name: []const u8, name: []const u8) ?symbols.SymbolId {
        for (self.resolution.symbols.symbols.items[1..], 1..) |entry, index| {
            if (entry.kind == .type and entry.module_path != null and std.mem.eql(u8, entry.module_path.?, module_name) and std.mem.eql(u8, entry.name, name)) {
                return @enumFromInt(index);
            }
        }
        return null;
    }

    fn nominalParameters(self: *const Checker, symbol: symbols.SymbolId) []const GenericParameter {
        return nominalParametersOf(self.result, symbol);
    }

    fn methodBySymbol(self: *const Checker, symbol: symbols.SymbolId) ?MethodDefinition {
        for (self.result.methods.items) |method| {
            if (method.symbol == symbol) return method;
        }
        return null;
    }

    fn inherentMethod(self: *const Checker, owner: symbols.SymbolId, name: []const u8) ?MethodDefinition {
        for (self.result.methods.items) |method| {
            if (method.owner == owner and std.mem.eql(u8, method.name, name)) return method;
        }
        return null;
    }

    fn interfaceMethod(_: *const Checker, definition: InterfaceDefinition, name: []const u8) ?InterfaceMethod {
        for (definition.methods) |method| {
            if (std.mem.eql(u8, method.name, name)) return method;
        }
        return null;
    }

    // `target_arguments` — ФАКТИЧЕСКИЕ/инстанцированные генерик-аргументы
    // `target` в ЭТОЙ точке вызова (например, `[Число, Строка]` для
    // `Отображённый(Число, Строка)`), отдельно от `implementation.
    // arguments` (сохранённой записи в `interface_implementations` —
    // ВЫРАЖЕНИЯ над СОБСТВЕННЫМИ объявленными заглушками `target`,
    // например `[U_of_Отображённый]` для `реализация Итерируемое для
    // Отображённый`). Быстрый путь (точное совпадение) идёт первым —
    // покрывает подавляющее большинство не-генерик случаев без лишней
    // работы; резервный путь с подстановкой запускается только когда
    // это не сработало.
    fn interfaceImplementation(self: *const Checker, interface: symbols.SymbolId, arguments: []const types.TypeId, target: symbols.SymbolId, target_arguments: []const types.TypeId) ?InterfaceImplementation {
        return findInterfaceImplementation(self.result, interface, arguments, target, target_arguments, null);
    }

    fn isComparableInterface(self: *const Checker, interface: symbols.SymbolId) bool {
        const entry = self.resolution.symbols.get(interface) orelse return false;
        return std.mem.eql(u8, entry.name, "Сравниваемое");
    }

    fn satisfiesInterfaceBound(self: *const Checker, actual: types.TypeId, interface: symbols.SymbolId) bool {
        if (self.isComparableInterface(interface) and self.isNumeric(actual)) return true;
        const actual_entry = self.result.types.get(actual) orelse return false;
        if (actual_entry.* == .generic_parameter) {
            for (self.current_generic_parameters) |parameter| {
                if (!parameter.typ.eql(actual)) continue;
                for (parameter.bounds) |bound| if (bound == interface) return true;
            }
            return false;
        }
        const nominal = switch (actual_entry.*) {
            .nominal => |value| value,
            else => return false,
        };
        return self.interfaceImplementation(interface, &.{}, nominal.symbol, nominal.arguments) != null;
    }

    fn isImplementableNominal(self: *const Checker, symbol: symbols.SymbolId) bool {
        return self.result.nominal_fields.contains(symbol) or self.result.generic_nominal_fields.contains(symbol) or self.result.enum_definitions.contains(symbol);
    }

    fn registerInterfaceCast(self: *Checker, expression: ast.ExprId, actual: types.TypeId, expected: types.TypeId) !void {
        if (self.result.types.eql(actual, expected)) return;
        const actual_entry = self.result.types.get(actual) orelse return;
        const expected_entry = self.result.types.get(expected) orelse return;
        const actual_nominal = switch (actual_entry.*) {
            .nominal => |value| value,
            else => return,
        };
        const expected_nominal = switch (expected_entry.*) {
            .nominal => |value| value,
            else => return,
        };
        if (!self.result.interface_definitions.contains(expected_nominal.symbol)) return;
        if (self.result.interface_definitions.contains(actual_nominal.symbol)) return;
        if (self.interfaceImplementation(expected_nominal.symbol, expected_nominal.arguments, actual_nominal.symbol, actual_nominal.arguments) == null) return;
        const entries = try self.result.arena.allocator().dupe(InterfaceCastEntry, &.{.{
            .interface = expected_nominal.symbol,
            .arguments = expected_nominal.arguments,
            .target = actual_nominal.symbol,
            .target_arguments = actual_nominal.arguments,
        }});
        try self.result.interface_casts.put(expression, .{ .entries = entries });
    }

    fn registerGenericInterfaceCasts(self: *Checker, expression: ast.ExprId, actual: types.TypeId, bounds: []const symbols.SymbolId) !void {
        const actual_entry = self.result.types.get(actual) orelse return;
        const nominal = switch (actual_entry.*) {
            .nominal => |value| value,
            else => return,
        };
        const target = nominal.symbol;
        var entries: std.ArrayList(InterfaceCastEntry) = .empty;
        defer entries.deinit(self.result.allocator);
        for (bounds) |bound| {
            if (self.interfaceImplementation(bound, &.{}, target, nominal.arguments) == null) continue;
            try entries.append(self.result.allocator, .{ .interface = bound, .arguments = &.{}, .target = target, .target_arguments = nominal.arguments });
        }
        if (entries.items.len != 0) try self.result.interface_casts.put(expression, .{ .entries = try self.result.arena.allocator().dupe(InterfaceCastEntry, entries.items) });
    }

    fn inferInterfaceCall(self: *Checker, expression: ast.ExprId, call: anytype, property: anytype, object_type: types.TypeId) !?types.TypeId {
        const object = self.result.types.get(object_type) orelse return null;
        const nominal = switch (object.*) {
            .nominal => |value| value,
            else => return null,
        };
        const definition = self.result.interface_definitions.get(nominal.symbol) orelse return null;
        if (nominal.arguments.len != definition.parameters.len) {
            try self.report(call.span, "Type Error: неверное количество параметров типа интерфейса", .{});
            return @as(?types.TypeId, try self.result.types.poison());
        }
        var method_index: ?usize = null;
        for (definition.methods, 0..) |method, index| {
            if (std.mem.eql(u8, method.name, property.property)) {
                method_index = index;
                break;
            }
        }
        const index = method_index orelse return null;
        const method = definition.methods[index];
        // Намеренно отложено ДО ЭТОГО МОМЕНТА (не в начало функции) —
        // этот диспетчер пробуется спекулятивно для каждого вызова
        // `.property` и проваливается к следующему кандидату (вызов
        // конструктора, обычный вызов метода, ...) при `null`; отчёт в
        // начале срабатывал бы побочным эффектом для вызовов, которые
        // ВООБЩЕ не интерфейсные и разрешаются более поздним резервным
        // путём.
        if (call.argument_names != null) try self.report(call.span, "Type Error: именованные аргументы не поддержаны для интерфейсного вызова", .{});
        if (call.arguments.len != method.parameters.len) try self.report(call.span, "Type Error: неверное количество аргументов метода", .{});
        var substitutions = std.AutoHashMap(types.TypeId, types.TypeId).init(self.result.allocator);
        defer substitutions.deinit();
        for (definition.parameters, nominal.arguments) |parameter, argument| try substitutions.put(parameter.typ, argument);
        // Метод Self-типа (`сравнить(другое: Сравниваемое) -> Число`,
        // `равно`, 4 арифметических операции, `клонировать() ->
        // Копируемое`), диспетчеризуемый через значение ИНТЕРФЕЙСНОГО
        // типа (не конкретная структура) — здесь нет конкретного типа,
        // к которому можно разрешить "Self" (значением может быть любой
        // реализующий тип), так что единственная корректная подстановка
        // — сам тип интерфейса; `assignable` уже принимает конкретный
        // аргумент против ожидаемого интерфейсного типа через поиск
        // `interfaceImplementation`.
        const self_type = self.result.interface_self_placeholders.get(nominal.symbol);
        if (self_type) |placeholder| try substitutions.put(placeholder, object_type);
        const shared = @min(call.arguments.len, method.parameters.len);
        // Метод по умолчанию может объявлять СОБСТВЕННЫЕ генерик-
        // параметры (`отобразить[U](это: Итерируемое(T), ф: функ(T) ->
        // U) -> Итерируемое(U)`) — отдельно от собственного `T`
        // интерфейса (уже связан выше через `definition.parameters`).
        // Тот же предпроход, что уже использует `inferMethodCall` для
        // собственных генериков обычного метода структуры: сначала
        // вывести СЫРОЙ тип каждого аргумента и унифицировать против
        // (ещё не подставленного) типа параметра, чтобы `U` был связан
        // до того, как что-либо ниже в нём нуждается.
        if (method.default_symbol) |default_symbol| {
            if (self.methodBySymbol(default_symbol)) |definition_info| {
                for (call.arguments[0..shared], method.parameters[0..shared]) |argument, parameter| {
                    try self.inferGenericSubstitution(parameter, try self.infer(argument), &substitutions, call.span);
                }
                for (definition_info.function_parameters) |parameter| {
                    if (!substitutions.contains(parameter.typ)) try self.report(call.span, "Type Error: не удалось вывести type-параметр '{s}'", .{parameter.name});
                }
            }
        }
        for (call.arguments[0..shared], method.parameters[0..shared]) |argument, parameter| {
            const expected = try self.substituteGeneric(parameter, &substitutions);
            const actual = try self.inferExpected(argument, expected);
            if (!self.assignable(actual, expected)) {
                try self.report(call.span, "Type Error: аргумент метода не совпадает с типом параметра", .{});
            } else if ((self_type == null or !parameter.eql(self_type.?)) and !self.isSelfReference(nominal.symbol, parameter)) {
                // ПАРАМЕТР Self-типа — единственный случай, когда
                // упаковка НЕ ДОЛЖНА происходить: разрешённый через
                // vtable конкретный метод (`callInterface`, `vm.zig`)
                // ожидает ТО ЖЕ сырое конкретное значение, что несёт сам
                // получатель (он был скомпилирован как, например,
                // `сравнить(это: Точка, другое: Точка)`, а не `другое:
                // <интерфейс>`) — приведение аргумента к интерфейсному
                // типу здесь передало бы в точку вызова упакованное
                // `.interface` значение, которое затем провалило бы
                // обычный доступ к полю внутри вызываемого ("доступ к
                // полю поддержан только для структуры"). Подстановка
                // ТИПА всё ещё нужна (чтобы отклонять посторонние
                // нереализующие значения), просто не рантайм-приведение.
                // `!self.isSelfReference(...)` покрывает ТУ ЖЕ ловушку
                // для НАСТОЯЩЕГО (не захардкоженного) объявления
                // интерфейса, где Self записан прямо как голое имя
                // самого интерфейса (`другое: Равнозначное`), а не
                // синтезированная заглушка — `interface_self_placeholders`
                // для таких пуста (никто её не чеканил), так что одной
                // проверки заглушки недостаточно, когда захардкоженный
                // путь `preludePass` пропущен.
                try self.registerInterfaceCast(argument, actual, expected);
            }
        }
        if (index > std.math.maxInt(u16)) return error.MethodLimitReached;
        try self.result.interface_calls.put(expression, .{
            .interface = nominal.symbol,
            .method_index = @intCast(index),
        });
        return @as(?types.TypeId, try self.substituteGeneric(method.return_type, &substitutions));
    }

    // `a.взять(3)`, где статический тип `a` — КОНКРЕТНАЯ структура/
    // перечисление (не сам интерфейс, не ограниченный генерик-параметр),
    // реализующая интерфейс, объявляющий `взять` как метод ПО УМОЛЧАНИЮ,
    // не переопределённый — в этом весь смысл методов по умолчанию
    // (цепочки вызовов, начинающиеся с обычного конкретного значения,
    // например `коллекции.итератор(массив).отобразить(f)`): не
    // срабатывает ни `inferInterfaceCall` (объект не интерфейсного
    // типа), ни `inferMethodCall` (нет собственного метода с этим
    // именем). Упаковывает получателя (`registerInterfaceCast`, тот же
    // механизм, что уже использует приведение `пер x: Интерфейс = a`) и
    // делегирует остальное `inferInterfaceCall` — без дублирования
    // логики подстановки параметров/возврата. Любой ДАЛЬНЕЙШИЙ вызов в
    // цепочке (`.взять(3).отобразить(g)`) не требует здесь особой
    // обработки вообще: тип возврата предыдущего метода по умолчанию —
    // АБСТРАКТНЫЙ интерфейсный тип (через `interface_self_placeholders`/
    // `isSelfReference`), так что он идёт напрямую через обычный путь
    // `inferInterfaceCall`.
    fn inferDefaultInterfaceMethodCall(self: *Checker, expression: ast.ExprId, call: anytype, property: anytype, object_type: types.TypeId) !?types.TypeId {
        const object = self.result.types.get(object_type) orelse return null;
        const nominal = switch (object.*) {
            .nominal => |value| value,
            else => return null,
        };
        // Сканируем ПОЛНЫЙ список реализаций перед принятием решения —
        // значение, чья конкретная структура реализует два РАЗНЫХ
        // интерфейса, оба объявляющих метод по умолчанию с одинаковым
        // именем, должно быть отклонено как неоднозначное, а не молча
        // разрешено в тот интерфейс, что первым оказался в
        // `interface_implementations` (случайный артефакт порядка
        // проходов тайпчекера, никак не контролируемый пользователем).
        var matched_interface_type: ?types.TypeId = null;
        for (self.result.interface_implementations.items) |implementation| {
            if (implementation.target != nominal.symbol) continue;
            const definition = self.result.interface_definitions.get(implementation.interface) orelse continue;
            var has_default_method = false;
            for (definition.methods) |method| {
                if (std.mem.eql(u8, method.name, property.property) and method.default_symbol != null) {
                    has_default_method = true;
                    break;
                }
            }
            if (!has_default_method) continue;
            // `implementation.arguments` выражены через СОБСТВЕННЫЕ
            // объявленные заглушки `nominal.symbol` (например,
            // собственный `T` у `МассивИт[T]`, унифицированный с `T` у
            // `Ит` при проверке импла) — НЕ конкретные типы, если сам
            // target генерик. Нужно подставить через `nominal.arguments`
            // (фактическую, конкретную инстанциацию ЭТОЙ точки вызова),
            // чтобы получить настоящий интерфейсный тип — использование
            // `implementation.arguments` как есть оставляло бы
            // `interface_type` всё ещё абстрактным.
            const target_params = self.nominalParameters(nominal.symbol);
            var substitutions = std.AutoHashMap(types.TypeId, types.TypeId).init(self.result.allocator);
            defer substitutions.deinit();
            if (target_params.len == nominal.arguments.len) {
                for (target_params, nominal.arguments) |parameter, argument| try substitutions.put(parameter.typ, argument);
            }
            var interface_arguments: std.ArrayList(types.TypeId) = .empty;
            defer interface_arguments.deinit(self.result.allocator);
            for (implementation.arguments) |argument| try interface_arguments.append(self.result.allocator, try self.substituteGeneric(argument, &substitutions));
            const interface_type = try self.result.types.nominal(implementation.interface, interface_arguments.items);
            if (!self.assignable(object_type, interface_type)) continue;
            if (matched_interface_type) |_| {
                try self.report(call.span, "Type Error: неоднозначный вызов default-метода '{s}' — реализован несколькими интерфейсами", .{property.property});
                return try self.result.types.poison();
            }
            matched_interface_type = interface_type;
        }
        const interface_type = matched_interface_type orelse return null;
        try self.registerInterfaceCast(property.object, object_type, interface_type);
        return try self.inferInterfaceCall(expression, call, property, interface_type);
    }

    // `это.метод()`, где статический тип `это` — голый ГЕНЕРИК-ПАРАМЕТР,
    // ограниченный пользовательским интерфейсом (внутри тела
    // генерик-функции вроде `функ разобрать_в[T: ИзTOML](это: T, ...)`).
    // Генерики панос никогда не мономорфизируются, так что здесь нет
    // конкретного типа для разрешения `.метод`; компилирует вызов точно
    // как `inferInterfaceCall` (обычная диспетчеризация
    // `call_interface`/vtable) против того ограничивающего интерфейса,
    // что объявляет метод — безопасно ТОЛЬКО потому, что вызывающие
    // обязаны (см. `interfaceBoundOf`, используется в каждой точке
    // вызова генерик-функции) уже привести свой конкретный аргумент к
    // ТОМУ ЖЕ интерфейсному типу до того, как он достигнет этого
    // параметра, так что рантайм-значение здесь уже несёт настоящую
    // vtable для диспетчеризации.
    fn inferGenericBoundInterfaceCall(self: *Checker, expression: ast.ExprId, call: anytype, property: anytype, object_type: types.TypeId) !?types.TypeId {
        const object = self.result.types.get(object_type) orelse return null;
        if (object.* != .generic_parameter) return null;
        var bounds: []const symbols.SymbolId = &.{};
        for (self.current_generic_parameters) |parameter| {
            if (!parameter.typ.eql(object_type)) continue;
            bounds = parameter.bounds;
            break;
        }
        var vtable_index: usize = 0;
        for (bounds) |bound| {
            if (self.isComparableInterface(bound)) continue;
            const definition = self.result.interface_definitions.get(bound) orelse continue;
            var method_index: ?usize = null;
            for (definition.methods, 0..) |method, index| {
                if (std.mem.eql(u8, method.name, property.property)) {
                    method_index = index;
                    break;
                }
            }
            const index = method_index orelse {
                vtable_index += 1;
                continue;
            };
            const method = definition.methods[index];
            // Отложено сюда (не в начало функции), по той же причине,
            // что и у идентичного исправления в `inferInterfaceCall` —
            // этот диспетчер тоже пробуется спекулятивно по каждому
            // ограничению и проваливается дальше при `null`.
            if (call.argument_names != null) try self.report(call.span, "Type Error: именованные аргументы не поддержаны для интерфейсного вызова", .{});
            if (call.arguments.len != method.parameters.len) try self.report(call.span, "Type Error: неверное количество аргументов метода", .{});
            const shared = @min(call.arguments.len, method.parameters.len);
            for (call.arguments[0..shared], method.parameters[0..shared]) |argument, parameter| {
                const actual = try self.inferExpected(argument, parameter);
                if (!self.assignable(actual, parameter)) {
                    try self.report(call.span, "Type Error: аргумент метода не совпадает с типом параметра", .{});
                } else {
                    try self.registerInterfaceCast(argument, actual, parameter);
                }
            }
            if (index > std.math.maxInt(u16)) return error.MethodLimitReached;
            try self.result.interface_calls.put(expression, .{
                .interface = bound,
                .method_index = @intCast(index),
                .vtable_index = @intCast(vtable_index),
            });
            return @as(?types.TypeId, method.return_type);
        }
        return null;
    }

    fn inferProcessMethod(self: *Checker, call: anytype, property: anytype, object_type: types.TypeId) !?types.TypeId {
        const object = self.result.types.get(object_type) orelse return null;
        if (object.* != .process) return null;
        if (!std.mem.eql(u8, property.property, "номер")) return null;
        try self.checkMethodArity(call, "номер", 0);
        // Дискретный идентификатор процесса — должен совпадать с `id` из
        // `получить_сигнал()` (тоже `Целое`), чтобы `id == p.номер()`
        // проходил тайпчек; оба всё равно один и тот же u64
        // идентификатор процесса во время выполнения.
        return self.result.types.builtins.integer;
    }

    fn inferMethodCall(self: *Checker, expression: ast.ExprId, call: anytype, property: anytype, object_type: types.TypeId, explicit_type_arguments: ?[]const types.TypeId) !?types.TypeId {
        const object = self.result.types.get(object_type) orelse return null;
        const nominal = switch (object.*) {
            .nominal => |value| value,
            else => return null,
        };
        const method = self.inherentMethod(nominal.symbol, property.property) orelse return null;
        const signature_id = self.result.symbol_types.get(method.symbol) orelse return null;
        const signature = self.result.types.get(signature_id) orelse return null;
        const function = switch (signature.*) {
            .function => |value| value,
            else => return null,
        };
        if (function.parameters.len == 0) {
            try self.report(call.span, "Type Error: метод '{s}' должен принимать получатель первым параметром", .{property.property});
            return @as(?types.TypeId, try self.result.types.poison());
        }
        const arguments = if (call.argument_names) |_| blk: {
            const names = (try self.functionParameterNames(method.symbol)) orelse {
                try self.report(call.span, "Type Error: именованные аргументы не поддержаны для этого вызова", .{});
                break :blk call.arguments;
            };
            if (names.len == 0) break :blk call.arguments;
            break :blk try self.reorderNamedArguments(expression, call, names[1..]);
        } else call.arguments;
        if (arguments.len != function.parameters.len - 1) try self.report(call.span, "Type Error: неверное количество аргументов метода", .{});
        if (nominal.arguments.len != method.owner_parameters.len) {
            try self.report(call.span, "Type Error: неверное количество параметров типа получателя", .{});
            return @as(?types.TypeId, try self.result.types.poison());
        }
        var substitutions = std.AutoHashMap(types.TypeId, types.TypeId).init(self.result.allocator);
        defer substitutions.deinit();
        for (method.owner_parameters, nominal.arguments) |parameter, argument| try substitutions.put(parameter.typ, argument);
        // Явные генерик-аргументы (`о.метод[Тип](...)`) затравливаются
        // ПЕРВЫМИ, до всего, выведенного из аргументов — симметрично
        // свободным generic-функциям (см. `ф[Тип](...)` в `inferCall`).
        if (explicit_type_arguments) |explicit_types| {
            if (explicit_types.len == method.function_parameters.len) {
                for (method.function_parameters, explicit_types) |parameter, resolved| {
                    try substitutions.put(parameter.typ, resolved);
                }
            }
        }
        const shared = @min(arguments.len, function.parameters.len - 1);
        for (arguments[0..shared], function.parameters[1 .. shared + 1]) |argument, parameter| {
            try self.inferGenericSubstitution(parameter, try self.infer(argument), &substitutions, call.span);
        }
        for (method.function_parameters) |parameter| {
            if (!substitutions.contains(parameter.typ)) try self.report(call.span, "Type Error: не удалось вывести type-параметр '{s}'", .{parameter.name});
        }
        // Симметрично свободным generic-функциям (см. основной путь
        // `.call` чуть выше в файле) — без этой проверки interface-bound
        // (`[T: Интерфейс]`) на МЕТОДЕ молча не проверялся вообще: тип
        // аргумента мог не реализовывать заявленный интерфейс, и об этом
        // не сообщалось на этапе тайпчека (нашлось только в рантайме,
        // как `Runtime Error: попытка вызвать интерфейсный метод у
        // не-интерфейса` — компилятор ниже эмитил `call_interface`
        // против аргумента, для которого так и не был сгенерирован
        // `cast_interface`, потому что до этой правки единственная ветка
        // ниже (`registerInterfaceCast`) молча ничего не делала для
        // generic-параметра — actual/expected совпадали после подстановки
        // T -> сам конкретный тип аргумента).
        for (method.function_parameters) |parameter| {
            const actual = substitutions.get(parameter.typ) orelse continue;
            if (self.isPoison(actual)) continue;
            for (parameter.bounds) |bound| {
                if (!self.satisfiesInterfaceBound(actual, bound)) {
                    const interface = self.resolution.symbols.get(bound) orelse continue;
                    try self.report(call.span, "Type Error: тип аргумента не реализует ограничение '{s}'", .{interface.name});
                }
            }
        }
        const receiver = try self.substituteGeneric(function.parameters[0], &substitutions);
        if (!self.assignable(object_type, receiver)) try self.report(call.span, "Type Error: получатель метода имеет неверный тип", .{});
        for (arguments[0..shared], function.parameters[1 .. shared + 1]) |argument, parameter| {
            const expected = try self.substituteGeneric(parameter, &substitutions);
            const actual = try self.inferExpected(argument, expected);
            if (!self.assignable(actual, expected)) {
                try self.report(call.span, "Type Error: аргумент метода не совпадает с типом параметра", .{});
            } else if (try self.genericInterfaceBounds(parameter, method.function_parameters)) |bounds| {
                // Метод, чей type-параметр ограничен интерфейсом,
                // вызванный с конкретным аргументом-структурой — та же
                // причина, что у идентичной ветки в свободных
                // generic-функциях (см. комментарий там): приведение
                // АРГУМЕНТА к интерфейсу, а не к `expected` (который
                // после подстановки — тот же конкретный тип, приведение-
                // заглушка), позволяет `Cast_Interface`/`Invoke_Interface`
                // диспетчеризовать вызов без мономорфизации.
                try self.registerGenericInterfaceCasts(argument, actual, bounds);
            } else {
                try self.registerInterfaceCast(argument, actual, expected);
            }
            // Аргумент сам ФУНКЦИОНАЛЬНОГО типа (`нулевое_тело: функ() ->
            // Тело`, `обработчик: функ(Тело) -> Отклик(Ответ)`), чья
            // позиция ВОЗВРАТА — bound generic-параметр этого метода:
            // ветка выше кастует АРГУМЕНТ целиком (саму функцию/
            // замыкание) только когда generic-параметр — ТИП аргумента
            // напрямую; она не применяется здесь (тип аргумента —
            // `.function`, не сам bound generic-параметр). Значение,
            // которое ВЕРНЁТ вызов этого замыкания ВНУТРИ ТЕЛА метода,
            // никогда не приводится к интерфейсу — там оно всё ещё
            // абстрактно (метод компилируется ОДИН раз, не мономорфно),
            // конкретный тип известен ТОЛЬКО здесь, в точке ВЫЗОВА
            // метода, где `actual`/аргумент — реальное замыкание с
            // конкретным типом возврата. См. `registerNestedFunctionReturnInterfaceCasts`.
            try self.registerNestedFunctionReturnInterfaceCasts(argument, parameter, method.function_parameters);
        }
        try self.result.method_calls.put(expression, method.symbol);
        return @as(?types.TypeId, try self.substituteGeneric(function.return_type, &substitutions));
    }

    // Находит СОБСТВЕННОЕ возвращаемое ВЫРАЖЕНИЕ лямбды-аргумента
    // (`argument`), когда параметр метода, которому она соответствует
    // (`raw_parameter`, ДО подстановки), — функциональный тип, чья
    // позиция возврата ограничена интерфейсом (bound generic-параметр
    // окружающего generic-метода/функции, `generic_parameters`) — и
    // приводит ЭТО выражение к интерфейсу тем же `registerGenericInterfaceCasts`,
    // что уже используется для АРГУМЕНТОВ, ограниченных напрямую.
    // Реальный, найденный вживую (не вычитыванием кода) пробел: значение,
    // ВОЗВРАЩЁННОЕ вызовом замыкания-параметра ВНУТРИ generic-тела
    // (`панос build: аргумент.метод()` там, где `аргумент = нулевое_тело()`
    // или `обработчик(x)`), никогда не оборачивалось интерфейсом — только
    // значения, поступившие в generic-функцию НАПРЯМУЮ параметром,
    // оборачивались (на этой, ВНЕШНЕЙ, конкретной стороне вызова).
    // Обрабатывает только САМЫЙ частый практический случай — тело лямбды
    // из ОДНОГО statement'а (обычный `функ(...) -> Т выражение конец`,
    // без промежуточных `пер`/if/match) — оператор `возврат` где угодно
    // внутри произвольного тела остаётся неподдержанным (см. research.md/
    // tasks.md пакета `быстряга`, panosiki — там и была найдена вся эта
    // цепочка).
    fn registerNestedFunctionReturnInterfaceCasts(self: *Checker, argument: ast.ExprId, raw_parameter: types.TypeId, generic_parameters: []const GenericParameter) !void {
        const parameter_entry = self.result.types.get(raw_parameter) orelse return;
        const function_type = switch (parameter_entry.*) {
            .function => |value| value,
            else => return,
        };
        const bounds = try self.genericInterfaceBounds(function_type.return_type, generic_parameters) orelse return;
        const lambda = switch (self.tree.expr(argument).*) {
            .lambda => |value| value,
            else => return,
        };
        if (lambda.body.len == 0) return;
        const last_statement = self.tree.stmt(lambda.body[lambda.body.len - 1]).*;
        const value_expression = switch (last_statement) {
            .expr => |value| value.value,
            .return_stmt => |value| value.value orelse return,
            else => return,
        };
        const value_type = self.result.expression_types.get(value_expression) orelse return;
        if (self.isPoison(value_type)) return;
        try self.registerGenericInterfaceCasts(value_expression, value_type, bounds);
    }

    fn inferPreludeEnumMethod(self: *Checker, call: anytype, property: anytype, object_type: types.TypeId) !?types.TypeId {
        const object = self.result.types.get(object_type) orelse return null;
        const nominal = switch (object.*) {
            .nominal => |value| value,
            else => return null,
        };
        const owner = self.resolution.symbols.get(nominal.symbol) orelse return null;
        if (std.mem.eql(u8, owner.name, "Опция")) {
            if (nominal.arguments.len != 1) return null;
            const element = nominal.arguments[0];
            if (std.mem.eql(u8, property.property, "есть") or std.mem.eql(u8, property.property, "пусто")) {
                try self.checkMethodArity(call, property.property, 0);
                return self.result.types.builtins.boolean;
            }
            if (std.mem.eql(u8, property.property, "получить")) {
                try self.checkMethodArity(call, "получить", 1);
                if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], element), element)) try self.report(call.span, "Type Error: значение по умолчанию имеет неверный тип", .{});
                return element;
            }
            if (std.mem.eql(u8, property.property, "значение")) {
                try self.checkMethodArity(call, "значение", 0);
                return element;
            }
            if (std.mem.eql(u8, property.property, "ожидать")) {
                try self.checkMethodArity(call, "ожидать", 1);
                if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) try self.report(call.span, "Type Error: сообщение ожидания должно быть строкой", .{});
                return element;
            }
            if (std.mem.eql(u8, property.property, "запас")) {
                try self.checkMethodArity(call, "запас", 1);
                if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], object_type), object_type)) try self.report(call.span, "Type Error: запасная опция имеет неверный тип", .{});
                return object_type;
            }
            if (std.mem.eql(u8, property.property, "заменить_значение")) {
                try self.checkMethodArity(call, "заменить_значение", 1);
                if (call.arguments.len == 0) return @as(?types.TypeId, try self.result.types.poison());
                return @as(?types.TypeId, try self.result.types.nominal(nominal.symbol, &.{try self.infer(call.arguments[0])}));
            }
            if (std.mem.eql(u8, property.property, "результат_или")) {
                try self.checkMethodArity(call, "результат_или", 1);
                if (call.arguments.len == 0) return @as(?types.TypeId, try self.result.types.poison());
                const result_symbol = self.findTypeSymbol("Результат") orelse return @as(?types.TypeId, try self.result.types.poison());
                return @as(?types.TypeId, try self.result.types.nominal(result_symbol, &.{ element, try self.infer(call.arguments[0]) }));
            }
        }
        if (std.mem.eql(u8, owner.name, "Результат")) {
            if (nominal.arguments.len != 2) return null;
            const success = nominal.arguments[0];
            const failure = nominal.arguments[1];
            if (std.mem.eql(u8, property.property, "успех") or std.mem.eql(u8, property.property, "ошибка")) {
                try self.checkMethodArity(call, property.property, 0);
                return self.result.types.builtins.boolean;
            }
            if (std.mem.eql(u8, property.property, "получить")) {
                try self.checkMethodArity(call, "получить", 1);
                if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], success), success)) try self.report(call.span, "Type Error: значение по умолчанию имеет неверный тип", .{});
                return success;
            }
            if (std.mem.eql(u8, property.property, "значение")) {
                try self.checkMethodArity(call, "значение", 0);
                return success;
            }
            if (std.mem.eql(u8, property.property, "причина")) {
                try self.checkMethodArity(call, "причина", 0);
                return failure;
            }
            if (std.mem.eql(u8, property.property, "ожидать")) {
                try self.checkMethodArity(call, "ожидать", 1);
                if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) try self.report(call.span, "Type Error: сообщение ожидания должно быть строкой", .{});
                return success;
            }
            if (std.mem.eql(u8, property.property, "ожидать_ошибку")) {
                try self.checkMethodArity(call, "ожидать_ошибку", 1);
                if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) try self.report(call.span, "Type Error: сообщение ожидания должно быть строкой", .{});
                return failure;
            }
            if (std.mem.eql(u8, property.property, "получить_ошибку")) {
                try self.checkMethodArity(call, "получить_ошибку", 1);
                if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], failure), failure)) try self.report(call.span, "Type Error: ошибка по умолчанию имеет неверный тип", .{});
                return failure;
            }
            if (std.mem.eql(u8, property.property, "запас")) {
                try self.checkMethodArity(call, "запас", 1);
                if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], object_type), object_type)) try self.report(call.span, "Type Error: запасной результат имеет неверный тип", .{});
                return object_type;
            }
            if (std.mem.eql(u8, property.property, "заменить_значение")) {
                try self.checkMethodArity(call, "заменить_значение", 1);
                if (call.arguments.len == 0) return @as(?types.TypeId, try self.result.types.poison());
                return @as(?types.TypeId, try self.result.types.nominal(nominal.symbol, &.{ try self.infer(call.arguments[0]), failure }));
            }
            if (std.mem.eql(u8, property.property, "заменить_ошибку")) {
                try self.checkMethodArity(call, "заменить_ошибку", 1);
                if (call.arguments.len == 0) return @as(?types.TypeId, try self.result.types.poison());
                return @as(?types.TypeId, try self.result.types.nominal(nominal.symbol, &.{ success, try self.infer(call.arguments[0]) }));
            }
            if (std.mem.eql(u8, property.property, "опция")) {
                try self.checkMethodArity(call, "опция", 0);
                const option_symbol = self.findTypeSymbol("Опция") orelse return @as(?types.TypeId, try self.result.types.poison());
                return @as(?types.TypeId, try self.result.types.nominal(option_symbol, &.{success}));
            }
            if (std.mem.eql(u8, property.property, "ошибка_опция")) {
                try self.checkMethodArity(call, "ошибка_опция", 0);
                const option_symbol = self.findTypeSymbol("Опция") orelse return @as(?types.TypeId, try self.result.types.poison());
                return @as(?types.TypeId, try self.result.types.nominal(option_symbol, &.{failure}));
            }
        }
        if (std.mem.eql(u8, owner.name, "Файл")) {
            if (std.mem.eql(u8, property.property, "прочитать") or std.mem.eql(u8, property.property, "прочитать_строку")) {
                try self.checkMethodArity(call, property.property, 0);
                return @as(?types.TypeId, self.resultOfString(self.result.types.builtins.string) orelse try self.result.types.poison());
            }
            if (std.mem.eql(u8, property.property, "записать")) {
                try self.checkMethodArity(call, "записать", 1);
                if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: Файл.записать() ожидает содержимое типа Строка", .{});
                }
                return @as(?types.TypeId, self.resultOfString(self.result.types.builtins.number) orelse try self.result.types.poison());
            }
            if (std.mem.eql(u8, property.property, "закрыть")) {
                try self.checkMethodArity(call, "закрыть", 0);
                return self.result.types.builtins.void;
            }
        }
        if (std.mem.eql(u8, owner.name, "Соединение")) {
            if (std.mem.eql(u8, property.property, "получить") or std.mem.eql(u8, property.property, "получить_строку")) {
                try self.checkMethodArity(call, property.property, 0);
                return @as(?types.TypeId, self.resultOfString(self.result.types.builtins.string) orelse try self.result.types.poison());
            }
            if (std.mem.eql(u8, property.property, "отправить")) {
                try self.checkMethodArity(call, "отправить", 1);
                if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: Соединение.отправить() ожидает содержимое типа Строка", .{});
                }
                return @as(?types.TypeId, self.resultOfString(self.result.types.builtins.number) orelse try self.result.types.poison());
            }
            if (std.mem.eql(u8, property.property, "закрыть")) {
                try self.checkMethodArity(call, "закрыть", 0);
                return self.result.types.builtins.void;
            }
        }
        if (std.mem.eql(u8, owner.name, "Слушатель")) {
            if (std.mem.eql(u8, property.property, "принять_запрос")) {
                try self.checkMethodArity(call, "принять_запрос", 0);
                const request_symbol = self.findTypeSymbol("Запрос") orelse return @as(?types.TypeId, try self.result.types.poison());
                const request_type = try self.nominalType(request_symbol, &.{});
                return @as(?types.TypeId, self.resultOfString(request_type) orelse try self.result.types.poison());
            }
        }
        if (std.mem.eql(u8, owner.name, "Запрос")) {
            if (std.mem.eql(u8, property.property, "метод") or std.mem.eql(u8, property.property, "путь")) {
                try self.checkMethodArity(call, property.property, 0);
                return @as(?types.TypeId, self.result.types.builtins.string);
            }
            if (std.mem.eql(u8, property.property, "тело")) {
                try self.checkMethodArity(call, "тело", 0);
                return @as(?types.TypeId, self.result.types.builtins.string);
            }
            if (std.mem.eql(u8, property.property, "заголовок")) {
                try self.checkMethodArity(call, "заголовок", 1);
                if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: Запрос.заголовок() ожидает имя типа Строка", .{});
                }
                const option_type = self.optionOf(self.result.types.builtins.string) orelse return @as(?types.TypeId, try self.result.types.poison());
                return @as(?types.TypeId, option_type);
            }
            if (std.mem.eql(u8, property.property, "ответить")) {
                try self.checkMethodArity(call, "ответить", 3);
                if (call.arguments.len == 3) {
                    if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.integer), self.result.types.builtins.integer)) {
                        try self.report(call.span, "Type Error: Запрос.ответить() ожидает статус типа Целое первым аргументом", .{});
                    }
                    if (!self.assignable(try self.inferExpected(call.arguments[1], self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: Запрос.ответить() ожидает тип содержимого типа Строка вторым аргументом", .{});
                    }
                    if (!self.assignable(try self.inferExpected(call.arguments[2], self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: Запрос.ответить() ожидает тело типа Строка третьим аргументом", .{});
                    }
                }
                return @as(?types.TypeId, self.result.types.builtins.void);
            }
            if (std.mem.eql(u8, property.property, "ответить_с_заголовками")) {
                try self.checkMethodArity(call, "ответить_с_заголовками", 4);
                if (call.arguments.len == 4) {
                    if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.integer), self.result.types.builtins.integer)) {
                        try self.report(call.span, "Type Error: Запрос.ответить_с_заголовками() ожидает статус типа Целое первым аргументом", .{});
                    }
                    if (!self.assignable(try self.inferExpected(call.arguments[1], self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: Запрос.ответить_с_заголовками() ожидает тип содержимого типа Строка вторым аргументом", .{});
                    }
                    if (!self.assignable(try self.inferExpected(call.arguments[2], self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: Запрос.ответить_с_заголовками() ожидает тело типа Строка третьим аргументом", .{});
                    }
                    const headers_map_type = try self.result.types.map(self.result.types.builtins.string, self.result.types.builtins.string);
                    if (!self.assignable(try self.inferExpected(call.arguments[3], headers_map_type), headers_map_type)) {
                        try self.report(call.span, "Type Error: Запрос.ответить_с_заголовками() ожидает Соответствие(Строка, Строка) четвёртым аргументом", .{});
                    }
                }
                return @as(?types.TypeId, self.result.types.builtins.void);
            }
        }
        if (std.mem.eql(u8, owner.name, "Соединение_БД")) {
            if (std.mem.eql(u8, property.property, "выполнить")) {
                try self.checkMethodArity(call, "выполнить", 2);
                if (call.arguments.len == 2) try self.checkSqlArgs(call);
                return @as(?types.TypeId, self.resultOfString(self.result.types.builtins.number) orelse try self.result.types.poison());
            }
            if (std.mem.eql(u8, property.property, "запрос")) {
                try self.checkMethodArity(call, "запрос", 2);
                if (call.arguments.len == 2) try self.checkSqlArgs(call);
                const row_type = try self.result.types.map(self.result.types.builtins.string, self.result.types.builtins.string);
                const rows_type = try self.result.types.array(row_type);
                return @as(?types.TypeId, self.resultOfString(rows_type) orelse try self.result.types.poison());
            }
            if (std.mem.eql(u8, property.property, "закрыть")) {
                try self.checkMethodArity(call, "закрыть", 0);
                return self.result.types.builtins.void;
            }
        }
        return null;
    }

    // Shared arg-type check for `Соединение_БД.выполнить`/`.запрос` —
    // both take `(sql: Строка, параметры: Массив(Строка))`.
    fn checkSqlArgs(self: *Checker, call: anytype) !void {
        if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
            try self.report(call.span, "Type Error: ожидается SQL типа Строка первым аргументом", .{});
        }
        const params_type = try self.result.types.array(self.result.types.builtins.string);
        if (!self.assignable(try self.inferExpected(call.arguments[1], params_type), params_type)) {
            try self.report(call.span, "Type Error: ожидается Массив(Строка) вторым аргументом", .{});
        }
    }

    fn resolveAlias(self: *Checker, symbol: symbols.SymbolId, span: source.Span) anyerror!types.TypeId {
        if (self.result.type_aliases.get(symbol)) |resolved| return resolved;
        const target = self.result.alias_type_nodes.get(symbol) orelse return self.result.types.poison();
        if (self.resolving_aliases.contains(symbol)) {
            try self.report(span, "Type Error: циклический псевдоним типа", .{});
            return self.result.types.poison();
        }
        try self.resolving_aliases.put(symbol, {});
        defer _ = self.resolving_aliases.remove(symbol);
        const resolved = try self.resolveType(target);
        try self.result.type_aliases.put(symbol, resolved);
        return resolved;
    }

    fn defineGenericParameters(self: *Checker, symbol: symbols.SymbolId, parameters: []const ast.TypeParameter) ![]const GenericParameter {
        if (self.result.generic_function_parameters.get(symbol)) |existing| return existing;
        const generic_parameters = try self.result.arena.allocator().alloc(GenericParameter, parameters.len);
        for (parameters, generic_parameters) |parameter, *generic_parameter| {
            var bounds: std.ArrayList(symbols.SymbolId) = .empty;
            defer bounds.deinit(self.result.allocator);
            var seen_bounds = std.AutoHashMap(symbols.SymbolId, void).init(self.result.allocator);
            defer seen_bounds.deinit();
            for (parameter.bounds) |bound_name| {
                // Квалифицированное ограничение (`json.ВJSON`, см.
                // `parser.zig`'s `parseTypeParameters`) закодировано как
                // одна строка "модуль.Имя" через точку — разрешается
                // через `findQualifiedTypeSymbol`, а не обычный
                // `findTypeSymbol`, чтобы указывать НАПРЯМУЮ на реальный
                // символ интерфейса исходного модуля, а не на локальный
                // алиас-обходной путь (тот транзитивно ломал разрешение
                // символа при межмодульном импорте метода, чей bound на
                // него ссылается).
                const bound = if (std.mem.indexOfScalar(u8, bound_name, '.')) |dot_index|
                    self.findQualifiedTypeSymbol(bound_name[0..dot_index], bound_name[dot_index + 1 ..]) orelse {
                        try self.report(self.resolution.symbols.get(symbol).?.span, "Type Error: неизвестный интерфейс '{s}'", .{bound_name});
                        continue;
                    }
                else
                    self.findTypeSymbol(bound_name) orelse {
                        try self.report(self.resolution.symbols.get(symbol).?.span, "Type Error: неизвестный интерфейс '{s}'", .{bound_name});
                        continue;
                    };
                if (!self.result.interface_definitions.contains(bound)) {
                    try self.report(self.resolution.symbols.get(symbol).?.span, "Type Error: ограничение '{s}' должно быть интерфейсом", .{bound_name});
                    continue;
                }
                if (seen_bounds.contains(bound)) {
                    try self.report(self.resolution.symbols.get(symbol).?.span, "Type Error: ограничение '{s}' указано повторно", .{bound_name});
                    continue;
                }
                try seen_bounds.put(bound, {});
                try bounds.append(self.result.allocator, bound);
            }
            generic_parameter.* = .{
                .name = parameter.name,
                .typ = try self.result.types.genericParameter(self.next_generic_parameter),
                .bounds = try self.result.arena.allocator().dupe(symbols.SymbolId, bounds.items),
            };
            self.next_generic_parameter += 1;
        }
        try self.result.generic_function_parameters.put(symbol, generic_parameters);
        return generic_parameters;
    }

    fn defineGenericNominalParameters(self: *Checker, symbol: symbols.SymbolId, parameters: []const []const u8) ![]const GenericParameter {
        if (self.result.generic_nominal_fields.get(symbol)) |existing| return existing.parameters;
        const generic_parameters = try self.result.arena.allocator().alloc(GenericParameter, parameters.len);
        for (parameters, generic_parameters) |parameter, *generic_parameter| {
            generic_parameter.* = .{
                .name = parameter,
                .typ = try self.result.types.genericParameter(self.next_generic_parameter),
            };
            self.next_generic_parameter += 1;
        }
        return generic_parameters;
    }

    fn defineGenericEnumParameters(self: *Checker, parameters: []const []const u8) ![]const GenericParameter {
        const generic_parameters = try self.result.arena.allocator().alloc(GenericParameter, parameters.len);
        for (parameters, generic_parameters) |parameter, *generic_parameter| {
            generic_parameter.* = .{
                .name = parameter,
                .typ = try self.result.types.genericParameter(self.next_generic_parameter),
            };
            self.next_generic_parameter += 1;
        }
        return generic_parameters;
    }

    fn findGenericParameter(self: *const Checker, name: []const u8) ?types.TypeId {
        for (self.current_generic_parameters) |parameter| {
            if (std.mem.eql(u8, parameter.name, name)) return parameter.typ;
        }
        return null;
    }

    fn enumVariant(self: *const Checker, symbol: symbols.SymbolId) ?EnumVariant {
        const entry = self.resolution.symbols.get(symbol) orelse return null;
        if (entry.kind != .enum_variant) return null;
        const definition = self.result.enum_definitions.get(entry.owner_type) orelse return null;
        for (definition.variants) |variant| {
            if (variant.symbol == symbol) return variant;
        }
        return null;
    }

    fn enumVariantFields(self: *Checker, variant: EnumVariant, nominal_type: types.TypeId) !?[]const types.TypeId {
        const entry = self.resolution.symbols.get(variant.symbol) orelse return null;
        const definition = self.result.enum_definitions.get(entry.owner_type) orelse return null;
        const type_entry = self.result.types.get(nominal_type) orelse return null;
        const nominal = switch (type_entry.*) {
            .nominal => |value| value,
            else => return null,
        };
        if (definition.parameters.len != nominal.arguments.len) return null;
        if (definition.parameters.len == 0) return variant.fields;
        var substitutions = std.AutoHashMap(types.TypeId, types.TypeId).init(self.result.allocator);
        defer substitutions.deinit();
        for (definition.parameters, nominal.arguments) |parameter, argument| {
            try substitutions.put(parameter.typ, argument);
        }
        var fields: std.ArrayList(types.TypeId) = .empty;
        defer fields.deinit(self.result.allocator);
        for (variant.fields) |field| try fields.append(self.result.allocator, try self.substituteGeneric(field, &substitutions));
        return try self.result.arena.allocator().dupe(types.TypeId, fields.items);
    }

    fn inferEnumVariantCall(self: *Checker, call: anytype, variant: EnumVariant) !types.TypeId {
        if (call.argument_names != null) try self.report(call.span, "Type Error: именованные аргументы не поддержаны для конструктора варианта", .{});
        const entry = self.resolution.symbols.get(variant.symbol) orelse return self.result.types.poison();
        const definition = self.result.enum_definitions.get(entry.owner_type) orelse return self.result.types.poison();
        if (call.arguments.len != variant.fields.len) try self.report(call.span, "Type Error: неверное количество аргументов конструктора варианта", .{});
        const shared = @min(call.arguments.len, variant.fields.len);
        var substitutions = std.AutoHashMap(types.TypeId, types.TypeId).init(self.result.allocator);
        defer substitutions.deinit();
        for (call.arguments[0..shared], variant.fields[0..shared]) |argument, field| {
            try self.inferGenericSubstitution(field, try self.infer(argument), &substitutions, call.span);
        }
        var arguments: std.ArrayList(types.TypeId) = .empty;
        defer arguments.deinit(self.result.allocator);
        for (definition.parameters) |parameter| {
            if (substitutions.get(parameter.typ)) |argument| {
                try arguments.append(self.result.allocator, argument);
            } else {
                try self.report(call.span, "Type Error: не удалось вывести type-параметр '{s}'", .{parameter.name});
                try arguments.append(self.result.allocator, try self.result.types.poison());
            }
        }
        for (call.arguments[0..shared], variant.fields[0..shared]) |argument, field| {
            const expected = try self.substituteGeneric(field, &substitutions);
            const actual = try self.inferExpected(argument, expected);
            if (self.assignable(actual, expected)) {
                try self.registerInterfaceCast(argument, actual, expected);
            } else {
                try self.report(call.span, "Type Error: аргумент конструктора варианта не совпадает с типом поля", .{});
            }
        }
        return self.nominalType(entry.owner_type, arguments.items);
    }

    fn inferEnumVariantCallExpected(self: *Checker, call: anytype, variant: EnumVariant, expected: types.TypeId) !types.TypeId {
        if (call.argument_names != null) try self.report(call.span, "Type Error: именованные аргументы не поддержаны для конструктора варианта", .{});
        const entry = self.resolution.symbols.get(variant.symbol) orelse return self.result.types.poison();
        const expected_entry = self.result.types.get(expected) orelse return self.inferEnumVariantCall(call, variant);
        const nominal = switch (expected_entry.*) {
            .nominal => |value| value,
            else => return self.inferEnumVariantCall(call, variant),
        };
        if (nominal.symbol != entry.owner_type) return self.inferEnumVariantCall(call, variant);
        const definition = self.result.enum_definitions.get(entry.owner_type) orelse return self.result.types.poison();
        if (definition.parameters.len != nominal.arguments.len) {
            try self.report(call.span, "Type Error: неверное количество параметров типа перечисления", .{});
            return self.result.types.poison();
        }
        if (call.arguments.len != variant.fields.len) try self.report(call.span, "Type Error: неверное количество аргументов конструктора варианта", .{});
        var substitutions = std.AutoHashMap(types.TypeId, types.TypeId).init(self.result.allocator);
        defer substitutions.deinit();
        for (definition.parameters, nominal.arguments) |parameter, argument| {
            try substitutions.put(parameter.typ, argument);
        }
        const shared = @min(call.arguments.len, variant.fields.len);
        for (call.arguments[0..shared], variant.fields[0..shared]) |argument, field| {
            const expected_field = try self.substituteGeneric(field, &substitutions);
            const actual = try self.inferExpected(argument, expected_field);
            if (self.assignable(actual, expected_field)) {
                try self.registerInterfaceCast(argument, actual, expected_field);
            } else {
                try self.report(call.span, "Type Error: аргумент конструктора варианта не совпадает с типом поля", .{});
            }
        }
        return expected;
    }

    // Структурно обходит `type_id`, заполняя `substitutions` значением
    // `poison` для каждого достигнутого голого генерик-параметра, ещё не
    // ограниченного — используется, когда `inferGenericSubstitution`
    // натыкается на форму, с которой не может унифицироваться (чаще
    // всего ПУСТОЙ литерал массива/соответствия, `массив()`/
    // `соответствие()`, чей тип элемента уже `poison` по собственному
    // правилу вывода — см. случаи массива/соответствия в `assignable`).
    // Без этого `T` вообще НИКОГДА не добавлялся бы в `substitutions`
    // (старый код просто молча делал `return` при несовпадении формы),
    // так что самый следующий проход сообщал бы "не удалось вывести
    // type-параметр", хотя недостающий тип доказуемо безопасно оставить
    // как `poison` (совместим с чем угодно в обе стороны, та же логика,
    // что `assignable` уже применяет к элементам пустого литерала
    // напрямую).
    // `placeholder` — тот из `poison()`/`unconstrained()`, которым уже
    // был ИСХОДНЫЙ аргумент, вызвавший это заполнение (см. точку вызова
    // в `inferGenericSubstitution`) — единственный экземпляр TypeId,
    // переиспользуемый для каждой вложенной позиции генерик-параметра,
    // найденной этим обходом (оба варианта несут `void`-полезную
    // нагрузку, так что один экземпляр структурно взаимозаменяем со
    // свежим везде, где на него смотрят `.eql`/`assignable`). Это
    // распространяет ОДИН И ТОТ ЖЕ вид (настоящая ошибка против
    // намеренно-неограниченного) до самого конца, вместо схлопывания
    // каждого заполнения обратно в захардкоженный `.poison`.
    fn fillUnknownWithPoison(self: *Checker, type_id: types.TypeId, substitutions: *std.AutoHashMap(types.TypeId, types.TypeId), placeholder: types.TypeId) !void {
        const entry = self.result.types.get(type_id) orelse return;
        switch (entry.*) {
            .generic_parameter => {
                if (!substitutions.contains(type_id)) try substitutions.put(type_id, placeholder);
            },
            .tuple => |elements| for (elements) |element| try self.fillUnknownWithPoison(element, substitutions, placeholder),
            .array => |element| try self.fillUnknownWithPoison(element, substitutions, placeholder),
            .map => |map| {
                try self.fillUnknownWithPoison(map.key, substitutions, placeholder);
                try self.fillUnknownWithPoison(map.value, substitutions, placeholder);
            },
            .nominal => |nominal| for (nominal.arguments) |argument| try self.fillUnknownWithPoison(argument, substitutions, placeholder),
            else => {},
        }
    }

    fn inferGenericSubstitution(self: *Checker, parameter: types.TypeId, argument: types.TypeId, substitutions: *std.AutoHashMap(types.TypeId, types.TypeId), span: source.Span) !void {
        const parameter_type = self.result.types.get(parameter) orelse return;
        if (self.isPoison(argument)) return self.fillUnknownWithPoison(parameter, substitutions, argument);
        switch (parameter_type.*) {
            .generic_parameter => {
                if (substitutions.get(parameter)) |existing| {
                    // Число/Целое разделяют ОДНО рантайм-представление
                    // f64 (см. приведения `Целое(x)`/`Число(x)` — `Число`
                    // именно поэтому чистый no-op) — унификация
                    // генерик-параметра между ДВУМЯ вхождениями, где один
                    // аргумент — нетипизированный числовой литерал (`0`,
                    // выведенный как обычное `Число` без контекста
                    // ожидаемого типа для сужения) а другой — настоящее
                    // `Целое` (например, `.длина()`), полностью
                    // безопасна, не настоящая неоднозначность.
                    if (self.isNumeric(argument) and self.isNumeric(existing)) {
                        if (self.isType(existing, self.result.types.builtins.integer) or self.isType(argument, self.result.types.builtins.integer)) {
                            try substitutions.put(parameter, self.result.types.builtins.integer);
                        }
                    } else if (!self.assignable(argument, existing) or !self.assignable(existing, argument)) {
                        try self.report(span, "Type Error: type-параметр выведен неоднозначно", .{});
                    }
                } else {
                    try substitutions.put(parameter, argument);
                }
            },
            .tuple => |parameters| {
                const argument_type = self.result.types.get(argument) orelse return;
                if (argument_type.* != .tuple or argument_type.tuple.len != parameters.len) return;
                for (parameters, argument_type.tuple) |nested_parameter, nested_argument| try self.inferGenericSubstitution(nested_parameter, nested_argument, substitutions, span);
            },
            .array => |element| {
                const argument_type = self.result.types.get(argument) orelse return;
                if (argument_type.* == .array) try self.inferGenericSubstitution(element, argument_type.array, substitutions, span);
            },
            .map => |map| {
                const argument_type = self.result.types.get(argument) orelse return;
                if (argument_type.* != .map) return;
                try self.inferGenericSubstitution(map.key, argument_type.map.key, substitutions, span);
                try self.inferGenericSubstitution(map.value, argument_type.map.value, substitutions, span);
            },
            // Без ветки `.function` параметр типа, встречающийся ТОЛЬКО
            // внутри поля/аргумента функционального типа (например, `U`
            // здесь — он никогда не встречается больше нигде в
            // структуре), никогда не мог бы быть выведен ("не удалось
            // вывести type-параметр").
            .function => |parameter_function| {
                const argument_type = self.result.types.get(argument) orelse return;
                if (argument_type.* != .function or argument_type.function.parameters.len != parameter_function.parameters.len) return;
                for (parameter_function.parameters, argument_type.function.parameters) |nested_parameter, nested_argument| {
                    try self.inferGenericSubstitution(nested_parameter, nested_argument, substitutions, span);
                }
                try self.inferGenericSubstitution(parameter_function.return_type, argument_type.function.return_type, substitutions, span);
            },
            .nominal => |nominal| {
                const argument_type = self.result.types.get(argument) orelse return;
                if (argument_type.* != .nominal or argument_type.nominal.arguments.len != nominal.arguments.len) return;
                const argument_nominal = argument_type.nominal;
                // Тот же `identity`-приоритетный fallback, что уже `assignable`
                // (выше в этом файле) и `TypeStore.eql` (types.zig) — та же
                // структура, импортированная в ТЕКУЩИЙ модуль ДВУМЯ разными
                // путями (например, обычный `импорт "lib.pns" как lib` для
                // сигнатуры метода И транзитивный барrel-реэкспорт для
                // отдельно импортированной функции-аргумента), заводит ДВА
                // РАЗНЫХ локальных `Symbol_Id` в `self.resolution.symbols` —
                // валидных внутри своего модуля, но НЕ взаимно сравнимых
                // напрямую. Раньше эта ветка сравнивала только `.symbol`,
                // из-за чего generic-параметр, встречающийся ТОЛЬКО внутри
                // такого номинального типа (например, `Ответ` в
                // `функ(Данные, Тело) -> Отклик(Ответ)`), никогда не
                // выводился при межмодульном вызове — "не удалось вывести
                // type-параметр" на полностью корректном коде (найдено при
                // реализации дозорного, см. отдельную memory-запись).
                const same_declaration = if (nominal.identity != 0 or argument_nominal.identity != 0)
                    nominal.identity != 0 and nominal.identity == argument_nominal.identity
                else
                    nominal.symbol == argument_nominal.symbol;
                if (!same_declaration) return;
                for (nominal.arguments, argument_nominal.arguments) |nested_parameter, nested_argument| {
                    try self.inferGenericSubstitution(nested_parameter, nested_argument, substitutions, span);
                }
            },
            else => {},
        }
    }

    fn fieldsForNominal(self: *Checker, nominal: anytype) !?[]const NominalField {
        if (self.result.nominal_fields.get(nominal.symbol)) |fields| return fields;
        const generic_nominal = self.result.generic_nominal_fields.get(nominal.symbol) orelse return null;
        if (nominal.arguments.len != generic_nominal.parameters.len) return null;
        var substitutions = std.AutoHashMap(types.TypeId, types.TypeId).init(self.result.allocator);
        defer substitutions.deinit();
        for (generic_nominal.parameters, nominal.arguments) |parameter, argument| {
            try substitutions.put(parameter.typ, argument);
        }
        var fields: std.ArrayList(NominalField) = .empty;
        defer fields.deinit(self.result.allocator);
        for (generic_nominal.fields) |field| {
            try fields.append(self.result.allocator, .{
                .name = field.name,
                .typ = try self.substituteGeneric(field.typ, &substitutions),
            });
        }
        return try self.result.arena.allocator().dupe(NominalField, fields.items);
    }

    fn substituteGeneric(self: *Checker, type_id: types.TypeId, substitutions: *const std.AutoHashMap(types.TypeId, types.TypeId)) !types.TypeId {
        const entry = self.result.types.get(type_id) orelse return self.result.types.poison();
        return switch (entry.*) {
            .generic_parameter => substitutions.get(type_id) orelse type_id,
            .tuple => |elements| blk: {
                var substituted: std.ArrayList(types.TypeId) = .empty;
                defer substituted.deinit(self.result.allocator);
                for (elements) |element| try substituted.append(self.result.allocator, try self.substituteGeneric(element, substitutions));
                break :blk self.result.types.tuple(substituted.items);
            },
            .function => |function| blk: {
                var parameters: std.ArrayList(types.TypeId) = .empty;
                defer parameters.deinit(self.result.allocator);
                for (function.parameters) |parameter| try parameters.append(self.result.allocator, try self.substituteGeneric(parameter, substitutions));
                break :blk self.result.types.function(parameters.items, try self.substituteGeneric(function.return_type, substitutions));
            },
            .nominal => |nominal| blk: {
                var arguments: std.ArrayList(types.TypeId) = .empty;
                defer arguments.deinit(self.result.allocator);
                for (nominal.arguments) |argument| try arguments.append(self.result.allocator, try self.substituteGeneric(argument, substitutions));
                break :blk self.result.types.nominalWithIdentity(nominal.symbol, nominal.identity, arguments.items);
            },
            .array => |element| self.result.types.array(try self.substituteGeneric(element, substitutions)),
            .map => |map| self.result.types.map(try self.substituteGeneric(map.key, substitutions), try self.substituteGeneric(map.value, substitutions)),
            .process => |message| self.result.types.process(try self.substituteGeneric(message, substitutions)),
            .pointer => |pointee| self.result.types.pointer(try self.substituteGeneric(pointee, substitutions)),
            else => type_id,
        };
    }
};

pub fn check(allocator: std.mem.Allocator, tree: *const ast.Ast, resolution: *const resolver.Resolution) !CheckResult {
    return checkWithImports(allocator, tree, resolution, &.{});
}

pub fn checkWithImports(
    allocator: std.mem.Allocator,
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    imports: []const ImportedSymbolType,
) !CheckResult {
    return checkWithImportContextForTarget(allocator, tree, resolution, .{ .symbols = imports }, .native);
}

pub fn checkWithImportsForTarget(
    allocator: std.mem.Allocator,
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    imports: []const ImportedSymbolType,
    target_profile: target_policy.TargetProfile,
) !CheckResult {
    return checkWithImportContextForTarget(allocator, tree, resolution, .{ .symbols = imports }, target_profile);
}

pub fn checkWithImportContext(
    allocator: std.mem.Allocator,
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    imports: ImportContext,
) !CheckResult {
    return checkWithImportContextForTarget(allocator, tree, resolution, imports, .native);
}

pub fn checkWithImportContextForTarget(
    allocator: std.mem.Allocator,
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    imports: ImportContext,
    target_profile: target_policy.TargetProfile,
) !CheckResult {
    var result = try CheckResult.init(allocator);
    errdefer result.deinit();
    var checker = Checker{
        .tree = tree,
        .resolution = resolution,
        .result = &result,
        .target_profile = target_profile,
        .resolving_aliases = .init(allocator),
        .has_real_prelude = imports.has_real_prelude,
    };
    defer checker.resolving_aliases.deinit();
    var owner_remaps = std.AutoHashMap(symbols.SymbolId, std.AutoHashMap(types.TypeId, types.TypeId)).init(allocator);
    defer {
        var it = owner_remaps.valueIterator();
        while (it.next()) |remap| remap.deinit();
        owner_remaps.deinit();
    }
    var owner_parameters_by_symbol = std.AutoHashMap(symbols.SymbolId, []const GenericParameter).init(allocator);
    defer owner_parameters_by_symbol.deinit();
    try checker.typeAliasPass();
    try checker.preludePass();
    try checker.enumPass();
    // `interfacePass`/`eagerAliasResolutionPass` (сигнатуры методов
    // интерфейса И псевдонимы типа функции, ВКЛЮЧАЯ квалифицированные
    // типы вроде `json.Значение`/`http.ОтветСервера`) должны
    // запускаться ПОСЛЕ `importIdentityPass` — та же причина, что уже
    // задокументирована ниже для `nominalPass` (`nominalType` читает
    // `imported_nominal_identities`). До этой правки метод интерфейса
    // ИЛИ псевдоним функционального типа, объявленный С
    // КВАЛИФИЦИРОВАННЫМ ТИПОМ (например `тип X = интерфейс \n функ м()
    // -> чужой_модуль.Тип \n конец` или `тип Далее = функ(Запрос) ->
    // чужой_модуль.Тип`), получал identity=0 для этого типа — а любая
    // РЕАЛИЗАЦИЯ метода/значение того же квалифицированного типа
    // (обрабатывается позже, `importSignaturePass`/`signaturePass`,
    // ОБЕ уже после `importIdentityPass`) получала настоящую identity —
    // `TypeStore.eql`'s `.nominal`-ветка переключается на СТРОГОЕ
    // сравнение по identity, как только у ЛЮБОЙ стороны она ненулевая,
    // так что совпадающий (тот же символ) тип отклонялся как
    // "сигнатура метода не совпадает с интерфейсом"/"тело лямбды не
    // совпадает с типом возврата" ИСКЛЮЧИТЕЛЬНО из-за этой
    // рассинхронизации, не реального несовпадения типов. Найдено при
    // реализации `быстряга` (panosiki) — интерфейсный случай сначала
    // (`ОтветJSON = интерфейс \n функ в_json() -> json.Значение \n
    // конец`), псевдонимный случай позже (`тип Далее = функ(Запрос) ->
    // http.ОтветСервера`, использованный как явный тип локальной
    // переменной с лямбда-инициализатором).
    try checker.importIdentityPass(imports, &owner_remaps, &owner_parameters_by_symbol);
    try checker.interfacePass();
    try checker.eagerAliasResolutionPass();
    try checker.nominalPass();
    try checker.nativeNominalPass();
    // Должна запускаться ДО `signaturePass` — `реализация Интерфейс для
    // Модуль.Тип` (квалифицированная ЦЕЛЬ импла) обрабатывается
    // `signaturePass` и нуждается в уже заполненных `nominal_fields`/
    // `generic_nominal_fields` для ИМПОРТИРОВАННОГО символа цели (через
    // `isImplementableNominal`, вызываемую из
    // `defineInterfaceImplementation`) — именно `importSignaturePass`
    // заполняет эти карты для импортированных номинальных типов. Запуск
    // её после `signaturePass` означал бы, что КАЖДАЯ квалифицированная
    // цель импла безусловно проваливала бы `isImplementableNominal`
    // (nominal_fields на тот момент всё ещё была бы для неё пуста),
    // отклоняя все такие блоки `реализация` с "интерфейс может
    // реализовать только структура или перечисление" даже для настоящей
    // структуры. `importSignaturePass` сама зависит только от
    // `owner_remaps`/`owner_parameters_by_symbol` (из `importIdentityPass`,
    // уже выполнена) и `imports.nominals` (статический вход) — ничего из
    // того, что производит `signaturePass`, так что этот порядок
    // безопасен.
    try checker.importSignaturePass(imports, &owner_remaps, &owner_parameters_by_symbol);
    try checker.signaturePass();
    try checker.constantPass();
    try checker.bodyPass();
    return result;
}

fn tuplePropertyIndex(property: []const u8) ?usize {
    if (property.len == 0) return null;
    return std.fmt.parseInt(usize, property, 10) catch null;
}

fn findNominalField(fields: []const NominalField, name: []const u8) ?NominalField {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field;
    }
    return null;
}

fn patternBooleanLiteral(tree: *const ast.Ast, pattern: ast.PatternId) ?bool {
    const literal = switch (tree.pattern(pattern).*) {
        .literal => |value| value,
        else => return null,
    };
    return switch (tree.expr(literal.value).*) {
        .boolean => |value| value.value,
        else => null,
    };
}

fn builtinType(store: *types.TypeStore, name: []const u8) ?types.TypeId {
    if (std.mem.eql(u8, name, "Число")) return store.builtins.number;
    if (std.mem.eql(u8, name, "Целое")) return store.builtins.integer;
    if (std.mem.eql(u8, name, "Булево")) return store.builtins.boolean;
    if (std.mem.eql(u8, name, "Строка")) return store.builtins.string;
    if (std.mem.eql(u8, name, "Пусто")) return store.builtins.void;
    if (std.mem.eql(u8, name, "Никогда")) return store.builtins.never;
    if (std.mem.eql(u8, name, "Ошибка")) return store.builtins.error_value;
    return null;
}

test "type checker verifies local arithmetic and direct calls" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ сложить(a: Число, b: Число) -> Число\na + b\nконец\nфунк старт() -> Число\nпер сумма: Число = сложить(1.0, 2.0)\nсумма\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}

test "type checker accumulates argument type diagnostics" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ число(x: Число) -> Число\nx\nконец\nфунк старт() -> Число\nчисло(\"нет\")\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 1), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Type Error: аргумент не совпадает с типом параметра", checked.diagnostics.items.items[0].message);
}

test "type checker checks control-flow conditions and branch results" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ выбрать(условие: Булево) -> Число\nесли условие тогда\n1.0\nиначе\n2.0\nконец\nконец\nфунк ошибка() -> Число\nесли 1 тогда\n\"нет\"\nиначе\n2.0\nконец\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 2), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Type Error: условие 'если' должно иметь тип Булево", checked.diagnostics.items.items[0].message);
    try std.testing.expectEqualStrings("Type Error: ветви 'если' возвращают разные типы", checked.diagnostics.items.items[1].message);
}

test "type checker infers collection elements through indexing" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ элемент() -> Число\nпер числа = массив(1.0, 2.0)\nпер цены = соответствие(\"яблоко\" = числа[0])\nцены[\"яблоко\"]\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    const function = parsed.ast.decl(parsed.ast.program.?.declarations[0]).function;
    const index = parsed.ast.stmt(function.body[2]).expr.value;
    try std.testing.expectEqual(checked.types.builtins.number, checked.expression_types.get(index).?);
}

test "type checker allows .длина() as a method on Строка, matching Массив/Соответствие" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ f() -> Целое\nпер s = \"привет\"\ns.длина()\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}

test "type checker infers lambda parameters from a function annotation" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ применить(f: функ(Число) -> Число, x: Число) -> Число\nf(x)\nконец\nфунк старт() -> Число\nпер удвоить: функ(Число) -> Число = функ(значение)\nзначение * 2.0\nконец\nприменить(удвоить, 3.0)\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}

test "type checker exposes all DOM click event fields" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(
        std.testing.allocator,
        "импорт DOM\n" ++
            "функ старт() -> Пусто\n" ++
            "DOM.на_клик(\"#кнопка\", функ(событие: DOM.СобытиеКлика) -> Пусто\n" ++
            "DOM.установить_текст(\"#x\", событие.клиент_x)\n" ++
            "DOM.установить_текст(\"#y\", событие.клиент_y)\n" ++
            "событие.кнопка == 0\n" ++
            "событие.ctrl\n" ++
            "событие.shift\n" ++
            "событие.alt\n" ++
            "событие.meta\n" ++
            "конец)\n" ++
            "конец",
        0,
    );
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try checkWithImportsForTarget(std.testing.allocator, &parsed.ast, &resolved, &.{}, .aot_js_wasm);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}

test "type checker requires an exact DOM click event handler signature" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(
        std.testing.allocator,
        "импорт DOM\n" ++
            "функ без_аргумента() -> Пусто\n" ++
            "конец\n" ++
            "функ неверный_аргумент(x: Число) -> Пусто\n" ++
            "конец\n" ++
            "функ с_результатом(_: DOM.СобытиеКлика) -> Число\n" ++
            "1.0\n" ++
            "конец\n" ++
            "функ старт() -> Пусто\n" ++
            "DOM.на_клик(\"#a\", без_аргумента)\n" ++
            "DOM.на_клик(\"#b\", неверный_аргумент)\n" ++
            "DOM.на_клик(\"#c\", с_результатом)\n" ++
            "конец",
        0,
    );
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try checkWithImportsForTarget(std.testing.allocator, &parsed.ast, &resolved, &.{}, .aot_js_wasm);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 3), checked.diagnostics.items.items.len);
    for (checked.diagnostics.items.items) |item| {
        try std.testing.expectEqualStrings("Type Error: DOM.на_клик() ожидает обработчик (функ(DOM.СобытиеКлика) -> Пусто) вторым аргументом", item.message);
    }
}

test "type checker accepts DOM.удалить/переместить/click-data/путь/перейти with correct usage" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(
        std.testing.allocator,
        "импорт DOM\n" ++
            "функ старт() -> Пусто\n" ++
            "DOM.удалить(\"#строка\")\n" ++
            "DOM.переместить(\"#строка\", \"#список\", \"\")\n" ++
            "пер данные = DOM.данные_клика()\n" ++
            "пер сообщение = DOM.атрибут_клика(\"data-message\")\n" ++
            "DOM.установить_текст_строка(\"#данные\", данные)\n" ++
            "DOM.установить_текст_строка(\"#сообщение\", сообщение)\n" ++
            "пер путь = DOM.путь()\n" ++
            "DOM.перейти(путь)\n" ++
            "конец",
        0,
    );
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try checkWithImportsForTarget(std.testing.allocator, &parsed.ast, &resolved, &.{}, .aot_js_wasm);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}

test "type checker rejects wrong arity/types for DOM.удалить/переместить/click-data/путь/перейти" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(
        std.testing.allocator,
        "импорт DOM\n" ++
            "функ старт() -> Пусто\n" ++
            "DOM.удалить(1.0)\n" ++
            "DOM.переместить(\"#строка\", \"#список\", 1.0)\n" ++
            "DOM.данные_клика(\"лишний\")\n" ++
            "DOM.атрибут_клика(1.0)\n" ++
            "DOM.путь(\"лишний\")\n" ++
            "DOM.перейти(1.0)\n" ++
            "конец",
        0,
    );
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try checkWithImportsForTarget(std.testing.allocator, &parsed.ast, &resolved, &.{}, .aot_js_wasm);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 6), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Type Error: DOM.удалить() ожидает CSS-селектор типа Строка", checked.diagnostics.items.items[0].message);
    try std.testing.expectEqualStrings("Type Error: DOM.переместить() ожидает селектор узла, родителя и опорного узла типа Строка", checked.diagnostics.items.items[1].message);
    try std.testing.expectEqualStrings("Type Error: DOM.данные_клика() не принимает аргументы", checked.diagnostics.items.items[2].message);
    try std.testing.expectEqualStrings("Type Error: DOM.атрибут_клика() ожидает имя атрибута типа Строка", checked.diagnostics.items.items[3].message);
    try std.testing.expectEqualStrings("Type Error: DOM.путь() не принимает аргументы", checked.diagnostics.items.items[4].message);
    try std.testing.expectEqualStrings("Type Error: DOM.перейти() ожидает путь типа Строка", checked.diagnostics.items.items[5].message);
}

test "type checker preserves nominal user types in function signatures" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип Точка = структура\nx: Число\nконец\nфунк та_же(точка: Точка) -> Точка\nточка\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}

test "type checker checks struct constructors and field access" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип Точка = структура\nx: Число\ny: Число\nконец\nфунк взять_x() -> Число\nпер точка = Точка(3.0, 4.0)\nточка.x\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    const function = parsed.ast.decl(parsed.ast.program.?.declarations[1]).function;
    const property = parsed.ast.stmt(function.body[1]).expr.value;
    try std.testing.expectEqual(checked.types.builtins.number, checked.expression_types.get(property).?);
}

test "type checker infers generic struct and nested enum constructors from return context" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const source_text =
        "тип Команда[M] = перечисление\n" ++
        "Нет\n" ++
        "Перейти(Строка)\n" ++
        "конец\n" ++
        "тип Обновление[A, M] = структура\n" ++
        "модель: A\n" ++
        "команда: Команда(M)\n" ++
        "конец\n" ++
        "функ обновить(переход: Булево) -> Обновление(Число, Строка)\n" ++
        "если переход тогда\n" ++
        "Обновление(1.0, Команда.Перейти(\"/about\"))\n" ++
        "иначе\n" ++
        "Обновление(2.0, Команда.Нет())\n" ++
        "конец\n" ++
        "конец";
    var lexed = try lexer.tokenize(std.testing.allocator, source_text, 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}

test "type checker types destructuring and loop binders" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ сумма() -> Число\nпер (x, y) = (1.0, 2.0)\nпер результат = 0.0\nдля значение в массив(x, y) цикл\nрезультат = результат + значение\nконец\nпер целый_результат: Целое = 0\nдля индекс = 1 по 2 цикл\nцелый_результат = целый_результат + индекс\nконец\nрезультат\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    const function = parsed.ast.decl(parsed.ast.program.?.declarations[0]).function;
    const for_in_binder = resolved.stmt_bindings.get(function.body[2]).?[0];
    const for_range_binder = resolved.stmt_bindings.get(function.body[4]).?[0];
    try std.testing.expectEqual(checked.types.builtins.number, checked.symbol_types.get(for_in_binder).?);
    try std.testing.expectEqual(checked.types.builtins.integer, checked.symbol_types.get(for_range_binder).?);
}

test "type checker rejects loop control outside a loop" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ f() -> Пусто\nпродолжить\nпрервать\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    // 3, а не 2: `продолжить` (безусловно расходится для достижимости)
    // сразу следует `прервать` в том же блоке — настоящее предупреждение
    // "недостижимый код" вдобавок к этим двум изначальным ошибкам.
    try std.testing.expectEqual(@as(usize, 3), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Type Error: 'продолжить' можно использовать только внутри цикла", checked.diagnostics.items.items[0].message);
    try std.testing.expectEqualStrings("Type Error: 'прервать' можно использовать только внутри цикла", checked.diagnostics.items.items[1].message);
    try std.testing.expectEqualStrings("недостижимый код", checked.diagnostics.items.items[2].message);
}

// Название теста устарело: голые целочисленные литералы теперь
// безусловно Целое, неявного приведения Целое<->Число нет — сужать
// нечего. `пер дробь: Целое = 1.5` теперь проваливается через обычную
// проверку совместимости ("значение переменной не совпадает с
// аннотацией").
test "type checker narrows integer literals in an expected context" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ взять(значение: Целое) -> Целое\nзначение\nконец\nфунк сумма() -> Целое\nпер значения: Массив(Целое) = массив(1, 2)\nвзять(значения[0]) + 3\nконец\nфунк ошибка() -> Целое\nпер дробь: Целое = 1.5\nдробь\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 1), checked.diagnostics.items.items.len);
    const sum = parsed.ast.decl(parsed.ast.program.?.declarations[1]).function;
    const expression = parsed.ast.stmt(sum.body[1]).expr.value;
    try std.testing.expectEqual(checked.types.builtins.integer, checked.expression_types.get(expression).?);
}

test "type checker validates operators and assignment targets" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ проверить(целое: Целое) -> Пусто\nконст неизменно = 1\nнеизменно = 2\nпер отрицание = не 1\nпер сумма = 1 + истина\nпер биты = целое & 2\nесли 1 и ложь тогда\n0\nиначе\n0\nконец\nпер финал = 0\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 4), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Type Error: нельзя присваивать константе", checked.diagnostics.items.items[0].message);
    try std.testing.expectEqualStrings("Type Error: оператор 'не' ожидает Булево", checked.diagnostics.items.items[1].message);
    try std.testing.expectEqualStrings("Type Error: оператор '+' ожидает два числа одного типа или две строки", checked.diagnostics.items.items[2].message);
    try std.testing.expectEqualStrings("Type Error: логический оператор ожидает два значения Булево", checked.diagnostics.items.items[3].message);
    const function = parsed.ast.decl(parsed.ast.program.?.declarations[0]).function;
    const bitwise_value = parsed.ast.stmt(function.body[4]).let.value;
    try std.testing.expectEqual(checked.types.builtins.integer, checked.expression_types.get(bitwise_value).?);
}

test "type checker restricts top-level constants to literals" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "конст ПЛОХО = массив(1)\nконст НОРМА = -1.0\nфунк старт() -> Число\nНОРМА\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 1), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Type Error: константа верхнего уровня должна быть числовым, строковым или булевым литералом", checked.diagnostics.items.items[0].message);
}

test "type checker resolves aliases before and after their declaration" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип Первый = Второй\nтип Второй = Число\nфунк взять(значение: Первый) -> Второй\nпер копия: Первый = значение\nкопия\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}

test "type checker infers a bare enum-variant constructor assigned to a property from the field's declared type" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(
        std.testing.allocator,
        "тип Т = структура\n" ++
            "примечание: Опция(Строка)\n" ++
            "конец\n" ++
            "функ f() -> Пусто\n" ++
            "пер t = Т(Опция.Нет())\n" ++
            "t.примечание = Опция.Нет()\n" ++
            "конец",
        0,
    );
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}

test "type checker rejects local values of type void" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ f() -> Пусто\nпер пусто: Пусто = пока ложь цикл\nконец\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 1), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Type Error: переменная не может иметь тип 'Пусто'", checked.diagnostics.items.items[0].message);
}

test "type checker accepts generic interface implementations and records casts" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(
        std.testing.allocator,
        "тип Печатаемый = интерфейс\n" ++
            "функ вСтроку() -> Строка\n" ++
            "конец\n" ++
            "тип Коробка[T] = структура\n" ++
            "значение: T\n" ++
            "конец\n" ++
            "реализация Печатаемый для Коробка\n" ++
            "функ вСтроку(это: Коробка) -> Строка\n" ++
            "\"коробка\"\n" ++
            "конец\n" ++
            "конец\n" ++
            "функ показать(значение: Печатаемый) -> Строка\n" ++
            "значение.вСтроку()\n" ++
            "конец\n" ++
            "функ старт() -> Строка\n" ++
            "показать(Коробка(\"готово\"))\n" ++
            "конец",
        0,
    );
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 1), checked.interface_implementations.items.len);
    try std.testing.expectEqual(@as(usize, 1), checked.interface_calls.count());
    try std.testing.expectEqual(@as(usize, 1), checked.interface_casts.count());
}

test "type checker restricts try expressions to compatible return envelopes" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ неверная_опция(значение: Опция(Число)) -> Число\nзначение?\nконец\nфунк неверный_результат(значение: Результат(Число, Строка)) -> Результат(Число, Число)\nзначение?\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 2), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Type Error: оператор '?' для Опции можно использовать только в функции, возвращающей Опцию", checked.diagnostics.items.items[0].message);
    try std.testing.expectEqualStrings("Type Error: оператор '?' возвращает ошибку другого типа", checked.diagnostics.items.items[1].message);
}

test "type checker enforces Comparable generic bounds" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ макс[T: Сравниваемое](a: T, b: T) -> T\nесли a > b тогда a иначе b конец\nконец\nфунк неверно() -> Строка\nмакс(\"a\", \"b\")\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 1), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Type Error: тип аргумента не реализует ограничение 'Сравниваемое'", checked.diagnostics.items.items[0].message);
}

test "type checker rejects invalid index writes and unsupported named enum calls" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип Ответ = перечисление\nДа(Число)\nконец\nфунк f() -> Пусто\n\"строка\"[0] = \"x\"\nпер ответ = Ответ.Да(значение = 1.0)\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 2), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Type Error: присваивание по индексу возможно только массиву или соответствию", checked.diagnostics.items.items[0].message);
    try std.testing.expectEqualStrings("Type Error: именованные аргументы не поддержаны для конструктора варианта", checked.diagnostics.items.items[1].message);
}

test "type checker warns on code after an unconditional возврат" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ f() -> Число\nвозврат 1.0\n2.0\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 1), checked.diagnostics.items.items.len);
    try std.testing.expectEqual(diagnostic.Severity.warning, checked.diagnostics.items.items[0].severity);
    try std.testing.expectEqualStrings("недостижимый код", checked.diagnostics.items.items[0].message);
}

test "type checker warns on code after an if/else where both branches return" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ f(x: Булево) -> Число\nесли x тогда\nвозврат 1.0\nиначе\nвозврат 2.0\nконец\n3.0\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 1), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("недостижимый код", checked.diagnostics.items.items[0].message);
}

// Вложенное if-выражение, используемое как ХВОСТ else-ветви, без
// аннотации типа где-либо, доводящей ожидаемый тип до этой точки — обе
// ветви должны унифицироваться в один и тот же номинальный тип
// структуры, а не молча выводиться как `Пусто` через путь отбрасывания
// для тел циклов/голого `если`-как-оператора.
test "type checker unifies branches of a nested if-expression used as an else-branch's tail, with no type annotation anywhere" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип Т = структура\nx: Число\nконец\nфунк f(a: Т) -> Число\nпер b = если истина тогда\nТ(2.0)\nиначе\nесли ложь тогда\nТ(3.0)\nиначе\na\nконец\nконец\nb.x\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}

// `inferMatchExpected` уже прокидывает `expected` корректно в каждую
// ветку через `inferBlockExpected(arm.body, expected, false)` — пустой
// литерал `массив()` внутри ветки `выбор` должен наследовать тип
// элемента от объявленного типа возврата `-> Массив(T)` охватывающей
// функции.
test "type checker infers массив() element type inside a выбор arm from the function's declared return type" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип E = перечисление\nА\nБ\nконец\nфунк f(e: E) -> Массив(Число)\nвыбор e\nE.А -> массив()\nE.Б -> массив(1.0)\nконец\nконец\nфунк старт() -> Массив(Число)\nf(E.А)\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}

// Две ветки `выбор` для ОДНОГО варианта перечисления с РАЗНЫМИ
// шаблонами полей (одна сужена литералом, другая — обычное связывание)
// не должны считаться дубликатом — вторая ловит только то, что не
// поймала первая.
test "type checker allows a literal-narrowed match arm followed by a plain binder for the same variant" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип Событие = перечисление\nКлик(Число, Число)\nконец\nфунк f() -> Строка\nпер e = Событие.Клик(1.0, 2.0)\nвыбор e\nСобытие.Клик(1.0, y) -> \"a\"\nСобытие.Клик(x, y) -> \"b\"\nконец\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}

// Две ПОЛНОСТЬЮ УНИВЕРСАЛЬНЫЕ (несуженные) ветки для одного варианта
// всё ещё настоящая ошибка дубликата/недостижимой ветки.
test "type checker still rejects two fully generic match arms for the same variant" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип Событие = перечисление\nКлик(Число, Число)\nконец\nфунк f() -> Строка\nпер e = Событие.Клик(1.0, 2.0)\nвыбор e\nСобытие.Клик(x, y) -> \"a\"\nСобытие.Клик(a, b) -> \"b\"\nконец\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 1), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Type Error: вариант перечисления повторён в выборе", checked.diagnostics.items.items[0].message);
}

// `Сравниваемое` (`<`) должен работать не только внутри генерика,
// ограниченного `[T: Сравниваемое]` (`isComparableGeneric`), но и для
// собственной `реализация Сравниваемое` у КОНКРЕТНОГО типа,
// используемой напрямую, без всякого генерика.
test "type checker allows Сравниваемое comparison on a concrete type outside any generic context" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип Деньги = структура\nкопейки: Число\nконец\nреализация Сравниваемое для Деньги\nфунк сравнить(это: Деньги, другое: Деньги) -> Число\nэто.копейки - другое.копейки\nконец\nконец\nфунк f() -> Булево\nДеньги(150.0) < Деньги(300.0)\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}

// Вызов метода Self-типа (`сравнить(другое: Сравниваемое) -> Число`)
// напрямую через переменную ИНТЕРФЕЙСНОГО типа (`x: Сравниваемое`)
// должен разрешать заглушку Self в точке вызова (см.
// `interface_self_placeholders`), иначе конкретный аргумент
// реализующего типа никогда не был бы совместим с ней.
test "type checker allows a self-typed interface method call through an interface-typed variable" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип Деньги = структура\nкопейки: Число\nконец\nреализация Сравниваемое для Деньги\nфунк сравнить(это: Деньги, другое: Деньги) -> Число\nэто.копейки - другое.копейки\nконец\nконец\nфунк f() -> Число\nпер x: Сравниваемое = Деньги(1.0)\nx.сравнить(Деньги(2.0))\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}

test "type checker rejects a default-method call ambiguous between two interfaces" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(
        std.testing.allocator,
        "тип А = интерфейс\n" ++
            "функ обязательныйА() -> Число\n" ++
            "функ показать(это: А) -> Строка\n" ++
            "\"a\"\n" ++
            "конец\n" ++
            "конец\n" ++
            "тип Б = интерфейс\n" ++
            "функ обязательныйБ() -> Число\n" ++
            "функ показать(это: Б) -> Строка\n" ++
            "\"b\"\n" ++
            "конец\n" ++
            "конец\n" ++
            "тип Коробка = структура\n" ++
            "х: Число\n" ++
            "конец\n" ++
            "реализация А для Коробка\n" ++
            "функ обязательныйА(это: Коробка) -> Число\n" ++
            "1.0\n" ++
            "конец\n" ++
            "конец\n" ++
            "реализация Б для Коробка\n" ++
            "функ обязательныйБ(это: Коробка) -> Число\n" ++
            "2.0\n" ++
            "конец\n" ++
            "конец\n" ++
            "функ старт() -> Строка\n" ++
            "Коробка(1.0).показать()\n" ++
            "конец",
        0,
    );
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 1), checked.diagnostics.items.items.len);
    try std.testing.expect(std.mem.indexOf(u8, checked.diagnostics.items.items[0].message, "неоднозначный вызов default-метода") != null);
}

test "type checker does not warn when an if has no else (false path falls through)" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    // `если x тогда паника("boom") конец` — then-ветвь типа `Никогда`,
    // без `иначе`, так что весь `если` никогда не утверждает, что всегда
    // расходится (путь при ложном условии проходит насквозь) — хвостовой
    // `2` НЕ должен помечаться как недостижимый.
    var lexed = try lexer.tokenize(std.testing.allocator, "функ f(x: Булево) -> Число\nесли x тогда\nпаника(\"boom\")\nконец\n2.0\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}
// `ф[Тип](...)` — вызовы с явным генерик-аргументом. Тела с
// возвращающим `Никогда` `паника(...)` держат эти фикстуры минимальными
// (совместимы с любым объявленным типом возврата) — под тестом именно
// обработка явного аргумента в ТОЧКЕ ВЫЗОВА, а не собственное тело
// генерик-функции.

test "explicit generic argument resolves a type parameter absent from any inferrable context" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator,
        \\тип Коробка[T] = структура
        \\    значение: T
        \\конец
        \\функ ф[T](x: Строка) -> Коробка(T)
        \\    паника("не реализовано")
        \\конец
        \\функ вызов() -> Пусто
        \\    ф[Число]("42")
        \\конец
    , 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}

test "without an explicit generic argument, an unconstrained type parameter still degrades silently (no regression)" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator,
        \\тип Коробка[T] = структура
        \\    значение: T
        \\конец
        \\функ ф[T](x: Строка) -> Коробка(T)
        \\    паника("не реализовано")
        \\конец
        \\функ вызов() -> Пусто
        \\    ф("42")
        \\конец
    , 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}

// Настоящий межмодульный (`module_loader`/`module_compiler`) тест для
// `либ.ф[Тип](...)` намеренно опущен здесь: подключение
// `module_compiler.zig` в `type_checker_unit_tests` транзитивно тянет за
// собой нативный SQL/FFI код `vm.zig`, с которым ЭТОТ тестовый бинарник
// не слинкован (в отличие от `vm_unit_tests`) — настоящий,
// воспроизводимый сбой линковки, не флейк. Не стоит подключать новую
// зависимость линковки в этот бинарник ради одного теста: путь
// обнаружения квалифицированного вызова (`self.resolution.expr_symbols.
// get(index.object)`, где `index.object` — `Property_Expr`) — ТОТ ЖЕ
// поиск, что уже использует существующий, доказанно работающий путь
// ОБЫЧНОГО квалифицированного генерик-вызова (`callee_symbol =
// self.resolution.expr_symbols.get(call.callee)` для `модуль.ф(...)`,
// не изменённый этой возможностью) — квалифицированные явные вызовы
// структурно покрыты этим существующим поведением, отдельно end-to-end
// здесь не перепроверяются.

test "explicit generic argument conflicting with the actual argument type is a Type Error" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator,
        \\функ ф[T](x: T) -> T
        \\    x
        \\конец
        \\функ вызов() -> Пусто
        \\    ф[Число]("текст")
        \\конец
    , 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expect(checked.diagnostics.items.items.len >= 1);
}

test "explicit generic argument matching what would have been inferred anyway compiles cleanly" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator,
        \\функ ф[T](x: T) -> T
        \\    x
        \\конец
        \\функ вызов() -> Пусто
        \\    ф[Число](1.0)
        \\конец
    , 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}

test "explicit generic argument violating an interface bound is a Type Error" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator,
        \\тип Точка = структура
        \\    x: Число
        \\конец
        \\функ макс[T: Сравниваемое](a: T) -> T
        \\    a
        \\конец
        \\функ вызов() -> Пусто
        \\    макс[Точка](Точка(1.0))
        \\конец
    , 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 1), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Type Error: тип аргумента не реализует ограничение 'Сравниваемое'", checked.diagnostics.items.items[0].message);
}

test "explicit generic argument on a non-type-shaped expression is a clear diagnostic, not silent indexing" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator,
        \\функ ф[T](x: T) -> T
        \\    x
        \\конец
        \\функ вызов() -> Пусто
        \\    ф[1.0 + 2.0]("x")
        \\конец
    , 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expect(checked.diagnostics.items.items.len >= 1);
    try std.testing.expect(std.mem.indexOf(u8, checked.diagnostics.items.items[0].message, "явный generic-аргумент должен быть именем типа") != null);
}

test "explicit generic argument on an unknown type name is a clear diagnostic" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator,
        \\функ ф[T](x: T) -> T
        \\    x
        \\конец
        \\функ вызов() -> Пусто
        \\    ф[НесуществующийТип]("x")
        \\конец
    , 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expect(checked.diagnostics.items.items.len >= 1);
    try std.testing.expect(std.mem.indexOf(u8, checked.diagnostics.items.items[0].message, "неизвестный тип") != null);
}

test "multiple explicit generic arguments via an existing tuple literal" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator,
        \\функ пара[T, U](a: T, b: U) -> T
        \\    a
        \\конец
        \\функ вызов() -> Пусто
        \\    пара[(Число, Строка)](1.0, "x")
        \\конец
    , 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}

test "indexing an array of functions and calling the result is unaffected by explicit generic-call detection" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator,
        \\функ удвоить(x: Число) -> Число
        \\    x * 2.0
        \\конец
        \\функ вызов() -> Число
        \\    пер функции: Массив(функ(Число) -> Число) = массив(удвоить)
        \\    функции[0.0](21.0)
        \\конец
    , 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}

// Метаморфное тестирование. Фаззинг по краш-оракулу (`zig build fuzz`)
// спрашивает только "запаниковало ли" — реальный класс багов, с которым
// на практике сталкивался этот проект (ложный дубликат варианта,
// `Сравниваемое` вне генерика, неверный тип `получить()`, ...) — это
// ТИХО НЕВЕРНЫЙ ответ, никогда не крах. Оракул здесь вместо этого: две
// формы исходного текста, семантически эквивалентные, ДОЛЖНЫ давать
// одинаковое число диагностик и одинаковый мультисет уровней серьёзности.
// В этой кодовой базе нет анпарсера/pretty-printer'а — это буквальные
// пары ИСХОДНОГО ТЕКСТА, не мутация-AST-и-перепечать; каждая пара ниже —
// прямая, намеренно минимальная кодировка одного из 5 задокументированных
// инвариантов.
fn expectEquivalentDiagnostics(comptime label: []const u8, variant_a: []const u8, variant_b: []const u8) !void {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");

    const Summary = struct { errors: usize, warnings: usize };
    const summarize = struct {
        fn run(allocator: std.mem.Allocator, source_text: []const u8) !Summary {
            var lexed = try lexer.tokenize(allocator, source_text, 0);
            defer lexed.deinit();
            var parsed = try parser.parse(allocator, lexed.tokens.items);
            defer parsed.deinit();
            var resolved = try resolver.resolve(allocator, &parsed.ast);
            defer resolved.deinit();
            var checked = try check(allocator, &parsed.ast, &resolved);
            defer checked.deinit();

            var summary = Summary{ .errors = 0, .warnings = 0 };
            for (resolved.diagnostics.items.items) |item| switch (item.severity) {
                .err => summary.errors += 1,
                .warning => summary.warnings += 1,
            };
            for (checked.diagnostics.items.items) |item| switch (item.severity) {
                .err => summary.errors += 1,
                .warning => summary.warnings += 1,
            };
            return summary;
        }
    }.run;

    const a = try summarize(std.testing.allocator, variant_a);
    const b = try summarize(std.testing.allocator, variant_b);
    if (a.errors != b.errors or a.warnings != b.warnings) {
        std.debug.print(
            "metamorphic mismatch ({s}): variant A -> {d} error(s)/{d} warning(s), variant B -> {d} error(s)/{d} warning(s)\n",
            .{ label, a.errors, a.warnings, b.errors, b.warnings },
        );
        return error.MetamorphicDiagnosticMismatch;
    }
}

test "metamorphic: untyped пер vs explicitly typed пер infer identically" {
    try expectEquivalentDiagnostics(
        "untyped vs typed let binding",
        "функ ф() -> Массив(Число)\n" ++
            "выбор истина\n" ++
            "истина -> массив()\n" ++
            "ложь -> массив(1.0)\n" ++
            "конец\n" ++
            "конец",
        "функ ф() -> Массив(Число)\n" ++
            "пер x: Массив(Число) = выбор истина\n" ++
            "истина -> массив()\n" ++
            "ложь -> массив(1.0)\n" ++
            "конец\n" ++
            "x\n" ++
            "конец",
    );
}

test "metamorphic: named struct constructor argument order doesn't affect diagnostics" {
    const decl =
        "тип Точка = структура\n" ++
        "x: Число\n" ++
        "y: Число\n" ++
        "конец\n";
    try expectEquivalentDiagnostics(
        "named constructor argument order",
        decl ++ "функ старт() -> Точка\n" ++ "Точка(x = 1.0, y = 2.0)\n" ++ "конец",
        decl ++ "функ старт() -> Точка\n" ++ "Точка(y = 2.0, x = 1.0)\n" ++ "конец",
    );
}

test "metamorphic: reordering two independent top-level declarations doesn't affect diagnostics" {
    try expectEquivalentDiagnostics(
        "top-level declaration order",
        "функ а() -> Число\n1.0\nконец\n" ++
            "функ б() -> Число\n2.0\nконец\n" ++
            "функ старт() -> Число\nа() + б()\nконец",
        "функ б() -> Число\n2.0\nконец\n" ++
            "функ а() -> Число\n1.0\nконец\n" ++
            "функ старт() -> Число\nа() + б()\nконец",
    );
}

test "metamorphic: method call through concrete type vs through interface-typed variable" {
    const decl =
        "тип Печатаемый = интерфейс\n" ++
        "функ показать() -> Строка\n" ++
        "конец\n" ++
        "тип Точка = структура\n" ++
        "x: Число\n" ++
        "конец\n" ++
        "реализация Печатаемый для Точка\n" ++
        "функ показать(это: Точка) -> Строка\n" ++
        "\"точка\"\n" ++
        "конец\n" ++
        "конец\n";
    try expectEquivalentDiagnostics(
        "concrete vs interface-typed receiver",
        decl ++ "функ старт() -> Строка\n" ++ "пер t = Точка(1.0)\n" ++ "t.показать()\n" ++ "конец",
        decl ++ "функ старт() -> Строка\n" ++ "пер t: Печатаемый = Точка(1.0)\n" ++ "t.показать()\n" ++ "конец",
    );
}

test "metamorphic: reordering two non-conflicting match arms doesn't affect diagnostics" {
    const decl =
        "тип Ответ = перечисление\n" ++
        "Да(Число)\n" ++
        "Нет\n" ++
        "конец\n" ++
        "функ ф(о: Ответ) -> Число\n";
    try expectEquivalentDiagnostics(
        "match arm order",
        decl ++ "выбор о\n" ++ "Ответ.Да(x) -> x\n" ++ "Ответ.Нет -> 0.0\n" ++ "конец\n" ++ "конец",
        decl ++ "выбор о\n" ++ "Ответ.Нет -> 0.0\n" ++ "Ответ.Да(x) -> x\n" ++ "конец\n" ++ "конец",
    );
}
