const std = @import("std");
const ast = @import("ast.zig");
const bytecode = @import("bytecode.zig");
const source = @import("source.zig");
const symbols = @import("symbols.zig");
const types = @import("types.zig");

// MIR (mid-level IR) — стадия понижения bytecode→WASM в пайплайне AOT
// `panos build --target=wasm`. Полный набор инструкций/терминаторов
// объявлен здесь ИСЧЕРПЫВАЮЩЕ с самого начала (чтобы switch-ы валидации/
// печати/эмиссии никогда не требовали новых веток задним числом), но
// проход понижения (bytecode → MIR, отдельный файл) сегодня ПОРОЖДАЕТ
// только подмножество «Фазы 1» — литералы, локальные переменные,
// бинарные/унарные/сравнивающие операторы (включая короткое замыкание
// `и`/`или`, понижаемое до настоящих ветвлений), вызовы и управление
// потоком (`если`/`пока`/`для` через терминаторы Jump/Branch). Интерфейсы,
// замыкания, акторы (спавн/отправить/получить), `внешний`, ADT и
// коллекции объявлены, но пока не понижаются — сознательное разделение
// на «Фазу 2», а не недосмотр.
//
// `symbols.SymbolId`/`types.TypeId`/`source.Span` переиспользуются
// напрямую из резолвера/тайпчекера — MIR никогда не пересчитывает
// семантическую информацию, только читает её.

pub const ValueId = enum(u32) { _ };
pub const LocalId = enum(u32) { _ };
pub const BlockId = enum(u32) { _ };
pub const FunctionId = enum(u32) { _ };

pub const invalid_block: BlockId = @enumFromInt(std.math.maxInt(u32));
pub const invalid_value: ValueId = @enumFromInt(std.math.maxInt(u32));

pub const BinOp = enum {
    add,
    subtract,
    multiply,
    divide,
    int_divide,
    modulo,
    bit_and,
    bit_or,
    bit_xor,
    shift_left,
    shift_right,
};

pub const CmpOp = enum {
    less,
    greater,
    equal,
    less_equal,
    greater_equal,
    not_equal,
};

pub const UnOp = enum {
    negate_number,
    negate_bool,
    bit_not,
    int_trunc,
    // `wasm_objects.zig` — индексы массивов приходят из пользовательского
    // кода как `Число` (f64), но адресация линейной памяти требует i32.
    // Отличается от `int_trunc` (который остаётся в пространстве f64 —
    // усечение `Число`, а не смена представления на уровне WASM). `to_i32`
    // паникует (`i32.trunc_f64_s`) на отрицательном после усечения или
    // выходящем за диапазон i32 значении — плохой индекс массива роняет
    // модуль вместо чистой диагностики уровня панос; известный, принятый
    // пробел Фазы 1 (см. doc-комментарий самого `wasm_objects.zig`).
    to_i32,
    from_i32,
};

pub const ConstValue = union(enum) {
    number: f64,
    boolean: bool,
    string: []const u8,
    // Голый литерал i32 (`i32.const`, в отличие от `.number`, всегда
    // представляющего `Целое`/`Число` через f64) — `mir_cps.zig`/
    // `wasm_actors.zig` нужны настоящие константы i32 для арифметики
    // указателей кадра/кучи и тегов состояния возобновления, которые
    // должны точно проходить туда-обратно через операции i32 (пляска
    // конверсий f64->i64->i32 у `.number`, используемая в других местах
    // для `%`/битовых операций, — лишние накладные расходы для значений,
    // которые в принципе никогда не станут видимым пользователю `Число`).
    address: u32,
};

pub const InterfaceMethodBinding = struct {
    method_name: []const u8,
    function: FunctionId,
    // Истинно, когда `function` — это тело метода по умолчанию САМОГО
    // интерфейса (`тип X = интерфейс \n функ м(это: X, ...) -> ... \n
    // <тело> \n конец`), а не переопределение `реализация` конкретного
    // типа. Параметр `это` метода по умолчанию — это АБСТРАКТНОЕ значение
    // интерфейса (чтобы можно было продолжать полиморфную диспетчеризацию
    // через `это.другой_метод()`), а не сырое конкретное значение, которого
    // ждёт обычное переопределение — `wasm_interfaces.zig` нужно это знать,
    // чтобы решить, какую форму `это` ожидает callee данного слота vtable.
    // Отражает ту же логику, что и `bytecode.Function.is_default_interface_method`
    // в нативном бэкенде (`callInterface` в `vm.zig`).
    is_default: bool = false,
};

// Трёхадресный код, одна простая операция на инструкцию — форма
// union(enum) повторяет `bytecode.Instruction`, но каждое значение MIR
// именовано (`dst: ValueId`), а не лежит на неявном стеке: MIR потребляет
// структурное (блочно-CFG) понижение, а не стековая машина.
pub const Instruction = union(enum) {
    const_value: struct { dst: ValueId, value: ConstValue },
    copy: struct { dst: ValueId, src: ValueId },
    load_local: struct { dst: ValueId, local: LocalId },
    store_local: struct { local: LocalId, src: ValueId },
    load_captured: struct { dst: ValueId, index: u32 },
    binary: struct { dst: ValueId, op: BinOp, lhs: ValueId, rhs: ValueId },
    compare: struct { dst: ValueId, op: CmpOp, lhs: ValueId, rhs: ValueId },
    unary: struct { dst: ValueId, op: UnOp, src: ValueId },
    call: struct { dst: ?ValueId, callee: FunctionId, args: []const ValueId },
    call_value: struct { dst: ?ValueId, callee: ValueId, args: []const ValueId },
    call_builtin: struct { dst: ?ValueId, name: []const u8, args: []const ValueId },
    call_method: struct { dst: ?ValueId, receiver: ValueId, name: []const u8, args: []const ValueId },
    // Синхронность/асинхронность — решение БЭКЕНДА (та же проверка в духе
    // `is_async_builtin_name`, только применяется на этапе MIR→bytecode,
    // а не AST→bytecode) — одна форма инструкции покрывает оба случая.
    call_async: struct { dst: ?ValueId, receiver: ?ValueId, name: []const u8, args: []const ValueId },
    call_foreign: struct { dst: ?ValueId, foreign: bytecode.ForeignFunctionConstant, args: []const ValueId },
    new_aggregate: struct { dst: ValueId, type_name: []const u8, elements: []const ValueId },
    get_property: struct { dst: ValueId, object: ValueId, field_index: u32 },
    set_property: struct { object: ValueId, field_index: u32, value: ValueId },
    new_array: struct { dst: ValueId, elements: []const ValueId },
    new_map: struct { dst: ValueId, keys: []const ValueId, values: []const ValueId },
    get_index: struct { dst: ValueId, object: ValueId, index: ValueId },
    set_index: struct { object: ValueId, index: ValueId, value: ValueId },
    cast_interface: struct { dst: ValueId, src: ValueId, vtable: []const InterfaceMethodBinding },
    invoke_interface: struct { dst: ?ValueId, receiver: ValueId, method_name: []const u8, method_index: u16 = 0, args: []const ValueId },
    // Только для WASM (собственное расширение `.invoke_interface` в
    // `wasm_interfaces.zig` — никогда не порождается `mir_lowering.zig`,
    // никогда не видно нативному компилятору bytecode). `table_index` —
    // значение ВРЕМЕНИ ВЫПОЛНЕНИЯ (загружается из vtable интерфейсной
    // обёртки в точке вызова — какая конкретная функция разрешится,
    // известно только во время выполнения программы), в отличие от
    // фиксированного во время компиляции `callee: FunctionId` у `.call`.
    // `wasm_emit.zig` выводит проверку типов `call_indirect` исключительно
    // из собственных MIR-типов `args`/`dst` (как и у `.call`) и отдельно
    // гарантирует (при построении секции функций), что каждая функция,
    // когда-либо попадающая в таблицу функций WASM, разделяет одну
    // дедуплицированную запись типа на форму сигнатуры — `call_indirect`
    // паникует на ЛЮБОМ буквальном несовпадении индекса типа, даже для
    // структурно идентичных сигнатур под двумя разными записями секции
    // типов.
    call_indirect: struct { dst: ?ValueId, table_index: ValueId, args: []const ValueId },
    build_variant: struct { dst: ValueId, type_name: []const u8, variant_name: []const u8, tag: u32, fields: []const ValueId },
    match_tag: struct { dst: ValueId, subject: ValueId, tag: u32 },
    get_variant_field: struct { dst: ValueId, subject: ValueId, field_index: u32 },
    // Поддержка замыканий в WASM AOT — `function` это ЛИБО тело лямбды,
    // уже синтезированное с собственным завершающим параметром `env_ptr`
    // (`already_env_aware = true`, `lowerLambda` в `mir_lowering.zig`),
    // ЛИБО уже существующая именованная функция, используемая как
    // значение первого класса (`already_env_aware = false`, фолбэк
    // `.function` в `lowerSymbolValueRef`) — второму случаю нужна тонкая
    // ОБЁРТКА, игнорирующая завершающий `env_ptr`, синтезируемая на этапе
    // раскрытия (`wasm_interfaces.zig`, по образцу уже устоявшегося
    // `wrapperFor`), поскольку сигнатура и точки прямого вызова ИСХОДНОЙ
    // функции должны остаться нетронутыми. Пустой `captured` — обычный
    // случай «просто значение-функция, без захватов». Раскрывается
    // `wasm_interfaces.zig` (тем же проходом, что уже переписывает
    // `.function_ref`/`.cast_interface`) в реальное выделение окружения
    // (по слоту на каждое захваченное значение) плюс 2-слотовую обёртку
    // `{table_index, env_ptr}` — см. doc-комментарий того файла.
    build_closure: struct { dst: ValueId, function: FunctionId, captured: []const ValueId, already_env_aware: bool },
    // Стабильный адрес captureless closure-box из data-секции WASM.
    // Порождается только `wasm_interfaces.zig` вместо
    // `.build_closure` без захватов; `slot` индексирует
    // `Module.static_closure_table_indices`.
    static_closure_ref: struct { dst: ValueId, slot: u32 },
    function_ref: struct { dst: ValueId, function: FunctionId },
    spawn: struct { dst: ValueId, callee: ValueId, args: []const ValueId },
    send: struct { process: ValueId, message: ValueId },
    receive: struct { dst: ValueId },
    receive_signal: struct { dst: ValueId },
    // Результат CPS-переписывания (`mir_cps.zig`) — локальные переменные
    // способной приостанавливаться функции НЕ являются обычными
    // локальными переменными WASM (те обнуляются при каждом новом вызове
    // функции; возобновляемый шаг актора должен переживать состояние
    // МЕЖДУ отдельными вызовами WASM). `frame` — собственный указатель
    // кадра функции (непрозрачный адрес в линейной памяти, передаваемый
    // как единственный настоящий параметр шаговой функции — см.
    // `wasm_actors.zig`), `slot` — назначаемое компилятором смещение
    // внутри него. Встречаются только в функции, уже переписанной
    // `mir_cps.zig` — функция, которая никогда не приостанавливается,
    // сохраняет обычные `load_local`/`store_local` нетронутыми.
    frame_load: struct { dst: ValueId, frame: ValueId, slot: u32 },
    frame_store: struct { frame: ValueId, slot: u32, src: ValueId },
    // Указатель кучи bump-аллокатора из `wasm_actors.zig` — ЕДИНСТВЕННЫЙ
    // кусок изменяемого состояния уровня процесса, который не может жить
    // в кадре какой-то одной функции (аллокации всех процессов делят его
    // между собой). Настоящий Global WASM (изменяемый i32), `global` —
    // индекс в секцию глобалей модуля (сейчас с одной записью) — вовсе
    // не эмитится для модуля без инструкций акторов.
    global_get: struct { dst: ValueId, global: u32 },
    global_set: struct { global: u32, src: ValueId },
    // `memory.size`/`memory.grow` WASM (опкоды 0x3F/0x40, за обоими
    // следует фиксированный байт индекса памяти `0x00` — у этого бэкенда
    // всегда ровно одна память) — только для WASM, порождаются
    // исключительно `buildAlloc` в `wasm_heap.zig` для роста линейной
    // памяти до того, как bump-указатель выйдет за её конец. `memory.size`
    // возвращает текущий размер в СТРАНИЦАХ по 64 КиБ (не в байтах);
    // `memory.grow` принимает ДЕЛЬТУ страниц и возвращает предыдущее
    // число страниц, либо `-1` при неудаче (достигнут лимит памяти
    // хоста).
    memory_size: struct { dst: ValueId },
    memory_grow: struct { dst: ValueId, pages: ValueId },
    // Как `frame_load`/`frame_store`, но адрес — полностью вычисленное
    // значение i32 ВРЕМЕНИ ВЫПОЛНЕНИЯ, а не `frame + слот времени
    // компиляции*8` — нужно для кольцевого буфера почтового ящика в
    // `wasm_actors.zig` (индекс сообщения известен только во время
    // выполнения, например `frame + ring_base_bytes + head*8`).
    // `frame_load`/`frame_store` в принципе не могут это выразить
    // (`slot: u32` — поле структуры Zig, никогда не `ValueId`) — оставлены
    // отдельными вместо обобщения, поскольку все ОСТАЛЬНЫЕ вызывающие
    // (само CPS-переписывание) нуждаются только в слотах, известных на
    // этапе компиляции, и выигрывают от того, что это видно прямо в форме
    // инструкции.
    mem_load: struct { dst: ValueId, addr: ValueId },
    mem_store: struct { addr: ValueId, src: ValueId },
    // Побайтовые аналоги `mem_load`/`mem_store` выше — те всегда работают
    // словами (4 или 8 байт, выбирается по типу `dst`/`src`). Работа со
    // строками (`wasm_strings.zig`) требует однобайтового доступа: разбор
    // байт UTF-8, побайтовые циклы копирования, построение строк цифр.
    // `dst`/`src` здесь всегда `idx_type` (i32) — байт расширяется нулями
    // до i32 при загрузке, при сохранении пишется только младший байт
    // (`i32.load8_u`/`i32.store8`).
    mem_load8: struct { dst: ValueId, addr: ValueId },
    mem_store8: struct { addr: ValueId, src: ValueId },
    // Оператор `?` — обычная инструкция, не терминатор: ранний возврат
    // при неудаче уже сегодня является семантикой времени выполнения
    // ВНУТРИ одного опкода (распаковывает Опция/Результат/любой ADT из
    // 2 вариантов, паникует либо возвращает раньше) — невидим для
    // MIR/CFG, тот же принцип, что уже применён к Receive/Await_Async.
    try_unwrap: struct { dst: ValueId, src: ValueId },
};

// Цель присваивания — не инструкция сама по себе, используется понижением
// для выбора, какую Store_Local/Set_Property/Set_Index эмитить для
// `место = выражение`.
pub const Place = union(enum) {
    local: LocalId,
    property: struct { object: ValueId, field_index: u32 },
    index: struct { object: ValueId, index: ValueId },
};

// Ровно один на блок — источник истины для CFG (отдельный граф нигде не
// хранится; см. `mir_cfg.zig`).
pub const Terminator = union(enum) {
    none, // блок ещё не закрыт — валиден только временно, во время построения
    jump: struct { target: BlockId },
    branch: struct { cond: ValueId, then_block: BlockId, else_block: BlockId },
    return_value: struct { value: ?ValueId },
    unreachable_term: struct { reason: []const u8 },
    // Результат CPS-переписывания (`mir_cps.zig`) — шаговый блок способной
    // приостанавливаться функции попадает сюда вместо `return_value`,
    // когда проверка почтового ящика/сигнала не даёт результата: слот
    // `state` кадра уже установлен в соответствующее `ResumeEdge.state`
    // через `frame_store` (см. `Instruction.frame_store`), и этому
    // терминатору остаётся лишь дать планировщику `wasm_actors.zig`
    // увидеть «ещё не готово» отдельно от обычного значения завершения —
    // включая настоящее завершение `Пусто` (`return_value{.value = null}`),
    // которое НЕЛЬЗЯ путать с «ещё выполняется».
    suspend_return,
};

pub const Local = struct {
    id: LocalId,
    symbol: symbols.SymbolId,
    name: []const u8,
    type_id: types.TypeId,
};

pub const Block = struct {
    id: BlockId,
    instructions: std.ArrayList(Instruction) = .empty,
    terminator: Terminator = .none,
    span: source.Span = .{ .file_id = 0, .start = 0, .end = 0 },

    pub fn deinit(self: *Block, allocator: std.mem.Allocator) void {
        self.instructions.deinit(allocator);
        self.* = undefined;
    }
};

pub const Function = struct {
    id: FunctionId,
    name: []const u8,
    symbol: symbols.SymbolId,
    parameters: []const LocalId = &.{},
    locals: std.ArrayList(Local) = .empty,
    // value_types.items[i] — статический тип ValueId(i) — ValueId/LocalId/
    // BlockId это простые индексы в эти массивы (не указатели в
    // растущий массив, которые могли бы стать недействительными после
    // `append`).
    value_types: std.ArrayList(types.TypeId) = .empty,
    blocks: std.ArrayList(Block) = .empty,
    entry: BlockId = invalid_block,
    result_type: types.TypeId,
    // Слинкованный AOT-модуль может содержать функции, понижённые из
    // нескольких исходных модулей панос. Их TypeId привязаны к разным
    // TypeStore, поэтому эмиттер WASM должен классифицировать значения
    // функции через то хранилище, что их создало, а не через один
    // произвольный чекер входного модуля.
    type_store: ?*const types.TypeStore = null,
    span: source.Span,

    pub fn deinit(self: *Function, allocator: std.mem.Allocator) void {
        for (self.blocks.items) |*b| b.deinit(allocator);
        self.blocks.deinit(allocator);
        self.locals.deinit(allocator);
        self.value_types.deinit(allocator);
        allocator.free(self.parameters);
        self.* = undefined;
    }

    pub fn block(self: *Function, id: BlockId) *Block {
        return &self.blocks.items[@intFromEnum(id)];
    }

    pub fn blockConst(self: *const Function, id: BlockId) *const Block {
        return &self.blocks.items[@intFromEnum(id)];
    }

    pub fn valueType(self: *const Function, id: ValueId) types.TypeId {
        return self.value_types.items[@intFromEnum(id)];
    }
};

pub const Module = struct {
    functions: std.ArrayList(Function) = .empty,
    // Ключ — тот же человекочитаемый ключ инстанциации "имя$Тип1,Тип2",
    // который компилятор bytecode уже использует для мономорфизации
    // generic-ов — у клона generic-а нет единого стабильного SymbolId,
    // общего для всех инстанциаций, поэтому он не может жить в обычной
    // карте символ→функция.
    generic_instantiations: std.StringHashMap(FunctionId),
    // Держит все поля-срезы переменной длины ВНУТРИ инструкции (аргументы
    // вызова, элементы агрегата, vtable-ы, ...) — таких полей по всему
    // набору инструкций слишком много, чтобы отслеживать и освобождать
    // каждое по отдельности (в отличие от `blocks`/`locals`/`value_types`
    // самой `Function`, которые ЯВЛЯЮТСЯ настоящими `ArrayList` с обычным
    // `deinit`). Одна арена на модуль, разбирается целиком в `deinit`.
    arena: std.heap.ArenaAllocator,
    // Имя каждой внешней entry-point функции: явно экспортированной из
    // корневого модуля либо зарегистрированной как обработчик
    // `DOM.после_кадра` (по строковому литералу-аргументу),
    // собирается один раз во время обхода достижимости
    // tree-shaking в `mir_lowering.zig` (`computeReachableSymbols`) —
    // переиспользуется `wasm_gc_arena.zig`, чтобы точно знать, какие
    // функции — настоящие вызываемые из JS точки входа (наряду со
    // `старт`), которым нужна обёртка checkpoint/restore bump-указателя.
    // Выделяется в арене выше, отдельного времени жизни не требует.
    dom_handler_names: [][]const u8 = &.{},
    // Устанавливается во время понижения захватов DOM-замыканий в
    // `mir_lowering.zig` (`lowerDomClickClosure`), когда значение
    // `Процесс` захватывается DOM-замыканием. Читается `expandSpawn` в
    // `wasm_actors.zig` — в модуле НЕ БОЛЕЕ одной `.spawn` (ограничение
    // Фазы 1), поэтому одного флага достаточно, чтобы решить, нужно ли
    // выделять ЕЁ кадр сразу в постоянной (несбрасываемой) области, а не
    // в обычной bump-арене. `mir_lowering.zig` в пайплайне выполняется
    // ДО `mir_cps.prepare`/`wasm_actors.expand` — на момент понижения
    // захватов `.spawn` ещё нераскрытая инструкция MIR без конкретного
    // кадра, поэтому РЕАЛЬНЫЙ выбор выделения может сделать только тот
    // проход, что её раскрывает позже; этот флаг — способ передать
    // решение через границу проходов.
    actor_captured_by_dom_closure: bool = false,
    // По одному дедуплицированному 8-байтному static box на индекс
    // таблицы функций: `[u32 table_index][u32 env=0]`.
    static_closure_table_indices: std.ArrayList(u32) = .empty,

    pub fn init(allocator: std.mem.Allocator) Module {
        return .{
            .generic_instantiations = .init(allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Module, allocator: std.mem.Allocator) void {
        for (self.functions.items) |*function| function.deinit(allocator);
        self.functions.deinit(allocator);
        self.static_closure_table_indices.deinit(allocator);
        self.generic_instantiations.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

test "mir Function.block/valueType index correctly by id" {
    const allocator = std.testing.allocator;
    var function = Function{
        .id = @enumFromInt(0),
        .name = "тест",
        .symbol = @enumFromInt(0),
        .result_type = types.TypeId.raw(0),
        .span = .{ .file_id = 0, .start = 0, .end = 0 },
    };
    defer function.deinit(allocator);
    try function.blocks.append(allocator, .{ .id = @enumFromInt(0), .span = .{ .file_id = 0, .start = 0, .end = 0 } });
    try function.value_types.append(allocator, types.TypeId.raw(7));
    try std.testing.expectEqual(@as(BlockId, @enumFromInt(0)), function.block(@enumFromInt(0)).id);
    try std.testing.expectEqual(types.TypeId.raw(7), function.valueType(@enumFromInt(0)));
}

test "mir Module tracks generic instantiations by name" {
    const allocator = std.testing.allocator;
    var module = Module.init(allocator);
    defer module.deinit(allocator);
    try module.generic_instantiations.put("идентичность$Число", @enumFromInt(3));
    try std.testing.expectEqual(@as(?FunctionId, @enumFromInt(3)), module.generic_instantiations.get("идентичность$Число"));
}
