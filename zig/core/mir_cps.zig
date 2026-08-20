const mir = @import("mir.zig");
const mir_builder = @import("mir_builder.zig");
const types = @import("types.zig");
const std = @import("std");

pub const SuspendPoint = struct {
    function: mir.FunctionId,
    block: mir.BlockId,
    instruction_index: u32,
    resume_state: u32,
};

pub const ResumeEdge = struct {
    state: u32,
    suspend_block: mir.BlockId,
    resume_block: mir.BlockId,
};

pub const FrameLayout = struct {
    function: mir.FunctionId,
    locals: []const mir.LocalId,
};

pub const FunctionPlan = struct {
    function: mir.FunctionId,
    frame: FrameLayout,
    suspend_points: []const SuspendPoint,
    resume_edges: []const ResumeEdge,
};

// Фиксированный префикс кадра, ОДИНАКОВЫЙ для каждого кадра актора вне
// зависимости от числа собственных локальных переменных/точек остановки
// владеющей функции — это позволяет `wasm_actors.zig` реализовать доступ
// mailbox_has/pop/signal_has/pop/result ОДИН раз, обобщённо, как обычные
// MIR-функции, принимающие голый указатель на кадр, вместо отдельной
// специализации на каждую функцию-актора.
pub const mailbox_cap: u32 = 4;
pub const signal_cap: u32 = 2;
pub const state_slot: u32 = 0;
pub const mailbox_count_slot: u32 = 1;
pub const mailbox_head_slot: u32 = 2;
pub const mailbox_ring_base: u32 = 3;
pub const signal_count_slot: u32 = mailbox_ring_base + mailbox_cap;
pub const signal_head_slot: u32 = signal_count_slot + 1;
pub const signal_ring_base: u32 = signal_head_slot + 1;
// Хранит РЕАЛЬНОЕ возвращаемое значение функции (каким бы `Тип` она ни
// объявляла изначально) после фактического завершения — собственный тип
// результата функции в WASM заменён на `Булево` (статус done/ещё
// приостановлена, см. `rewriteFunction`), поэтому реальное значение больше
// не может пройти через обычный канал возврата WASM; планировщик читает
// его отсюда, увидев `done`.
pub const result_slot: u32 = signal_ring_base + signal_cap;
pub const frame_prefix_slots: u32 = result_slot + 1;

// Размеры для конкретной функции, нужные раскрытию `.spawn` в
// `wasm_actors.zig` для выделения и инициализации нового кадра: сколько
// байт выделить bump-аллокатором и сколько исходных параметров вызываемой
// функции нужно скопировать (позиционно, слоты `[frame_prefix_slots,
// frame_prefix_slots + param_count)`) из собственных `args` `.spawn`.
pub const FrameInfo = struct {
    param_count: u32,
    total_slots: u32,
};

// Объединяет два анализа в ровно ту единицу, которую потребляет
// переписывание: одна функция, один долгоживущий кадр и монотонно
// пронумерованные состояния возобновления.
pub fn plans(allocator: std.mem.Allocator, module: *const mir.Module) !std.ArrayList(FunctionPlan) {
    var all_points = try collectSuspendPoints(allocator, module);
    defer all_points.deinit(allocator);
    var layouts = try frameLayouts(allocator, module);
    errdefer {
        for (layouts.items) |layout| allocator.free(layout.locals);
        layouts.deinit(allocator);
    }
    var out: std.ArrayList(FunctionPlan) = .empty;
    errdefer out.deinit(allocator);
    for (layouts.items) |layout| {
        var count: usize = 0;
        for (all_points.items) |point| {
            if (point.function == layout.function) count += 1;
        }
        const points = try allocator.alloc(SuspendPoint, count);
        const edges = try allocator.alloc(ResumeEdge, count);
        var at: usize = 0;
        for (all_points.items) |point| {
            if (point.function == layout.function) {
                points[at] = point;
                // Мутирующая фаза разбивает этот блок сразу после receive
                // и заменяет заглушку на id нового блока продолжения.
                edges[at] = .{ .state = point.resume_state, .suspend_block = point.block, .resume_block = mir.invalid_block };
                at += 1;
            }
        }
        try out.append(allocator, .{ .function = layout.function, .frame = layout, .suspend_points = points, .resume_edges = edges });
    }
    // владение локальными переменными перешло в `out`.
    layouts.clearRetainingCapacity();
    layouts.deinit(allocator);
    return out;
}

pub fn deinitPlans(allocator: std.mem.Allocator, value: *std.ArrayList(FunctionPlan)) void {
    for (value.items) |plan| {
        allocator.free(plan.frame.locals);
        allocator.free(plan.suspend_points);
        allocator.free(plan.resume_edges);
    }
    value.deinit(allocator);
}

// Все локальные переменные MIR для приостанавливаемой функции — это слоты
// кадра. Это больше, чем минимально необходимая по анализу живости выгрузка,
// но даёт первому CPS-бэкенду простой и корректный инвариант: любое
// значение, материализованное в локальную переменную, переживает любую
// границу receive/resume.
pub fn frameLayouts(allocator: std.mem.Allocator, module: *const mir.Module) !std.ArrayList(FrameLayout) {
    var layouts: std.ArrayList(FrameLayout) = .empty;
    errdefer layouts.deinit(allocator);
    for (module.functions.items) |function| {
        var suspends = false;
        for (function.blocks.items) |block| for (block.instructions.items) |instruction| switch (instruction) {
            .receive, .receive_signal => suspends = true,
            else => {},
        };
        if (!suspends) continue;
        const locals = try allocator.alloc(mir.LocalId, function.locals.items.len);
        for (locals, 0..) |*slot, index| slot.* = @enumFromInt(index);
        try layouts.append(allocator, .{ .function = function.id, .locals = locals });
    }
    return layouts;
}

// Этот проход — стабильные входные данные для мутирующего CPS-переписывания.
// Состояние ноль — обычный вход; каждая receive-подобная инструкция получает
// одно последующее состояние возобновления.
pub fn collectSuspendPoints(allocator: std.mem.Allocator, module: *const mir.Module) !std.ArrayList(SuspendPoint) {
    var points: std.ArrayList(SuspendPoint) = .empty;
    errdefer points.deinit(allocator);
    var next_state: u32 = 1;
    for (module.functions.items) |function| for (function.blocks.items) |block| {
        for (block.instructions.items, 0..) |instruction, index| switch (instruction) {
            .receive, .receive_signal => {
                try points.append(allocator, .{ .function = function.id, .block = block.id, .instruction_index = @intCast(index), .resume_state = next_state });
                next_state += 1;
            },
            else => {},
        };
    };
    return points;
}

// Граница CPS-фазы. Намеренно отделена от понижения из AST: проход
// превращает spawn/receive в возобновляемые кадры процессов перед
// генерацией WASM, сохраняя обычный MIR для неприостанавливаемых функций.
pub fn hasActorInstructions(module: *const mir.Module) bool {
    for (module.functions.items) |function| for (function.blocks.items) |block|
        for (block.instructions.items) |instruction| switch (instruction) {
            .spawn, .send, .receive, .receive_signal => return true,
            else => {},
        };
    return false;
}

// В отличие от `hasActorInstructions`, остаётся истинным ПОСЛЕ прохода
// `wasm_actors.zig` — `.expand()` переписывает каждую `.spawn`/`.send`/
// `.receive`/`.receive_signal` в `frame_load`/`frame_store`/`global_get`/
// `global_set`/`mem_load`/`mem_store`, поэтому к моменту вызова
// `emitModule` из `wasm_emit.zig` одного `hasActorInstructions` уже
// недостаточно, чтобы обнаружить код актора. Эти пять инструкций —
// исключительно результат `mir_cps.zig`, обычное понижение
// `mir_lowering.zig` их никогда не порождает, так что их наличие —
// однозначный сигнал "этому модулю нужны куча/глобали актора".
pub fn usesActorMemory(module: *const mir.Module) bool {
    for (module.functions.items) |function| for (function.blocks.items) |block|
        for (block.instructions.items) |instruction| switch (instruction) {
            .frame_load, .frame_store, .global_get, .global_set, .mem_load, .mem_store, .mem_load8, .mem_store8, .memory_size, .memory_grow => return true,
            else => {},
        };
    return false;
}

// --- Мутирующее переписывание -----------------------------------------
//
// Превращает ЛОКАЛЬНЫЕ ПЕРЕМЕННЫЕ приостанавливаемой функции из обычных
// локальных переменных WASM (обнуляются при каждом новом вызове —
// бесполезны через границу приостановки, которая по определению является
// ОТДЕЛЬНЫМ последующим вызовом функции) в слоты внутри непрозрачного
// блока кадра, выделяемого вызывающей стороной в линейной памяти WASM
// (реальным аллокатором владеет `wasm_actors.zig` — этот проход назначает
// только ЛОГИЧЕСКИЕ номера слотов, никогда байтовые смещения). После
// переписывания:
//
//   - У функции остаётся ровно ОДНА настоящая локальная переменная/
//     параметр: сам указатель на кадр (непрозрачный дескриптор i32 — см.
//     комментарий к `ptr_type` ниже про выбор типа).
//   - СОБСТВЕННЫЙ тип результата функции становится `Булево` — `true` =
//     действительно завершена (реальное значение, если есть, лежит в
//     `result_slot` кадра), `false` = приостановлена (вызвать снова, как
//     только почта/сигнал будут готовы). Это позволяет обычному вызову
//     WASM `call` (без исключений/трюков с multi-value) отличить для
//     планировщика настоящее завершение от приостановки, ВКЛЮЧАЯ
//     настоящее завершение с результатом `Пусто` — см. комментарий к
//     `result_slot`.
//   - Каждая ИСХОДНАЯ локальная переменная (индекс 0..N-1) становится
//     слотом кадра `[frame_prefix_slots, frame_prefix_slots + N)` —
//     `load_local`/`store_local` превращаются в `frame_load`/`frame_store`
//     по тому же (со смещением) номеру слота.
//   - Слот `frame_prefix_slots + N` — состояние диспетчеризации
//     возобновления (0 = свежий старт, K = "возобновить сразу после точки
//     остановки K") — это НЕ `state_slot`, который является ДРУГИМ, всегда
//     нулевым слотом, которого планировщик никогда не касается; оставлен
//     только для симметрии/документации, реальная диспетчеризация
//     использует слот, вычисляемый относительно функции ниже.
//   - Слоты `[frame_prefix_slots + N + 1, frame_prefix_slots + N + 1 + S)`
//     хранят СОБСТВЕННОЕ полученное значение каждой точки остановки
//     (`dst` вызова `получить()`/`получить_сигнал()`) — единственное
//     значение, живость которого через собственную границу остановки
//     гарантирована ВСЕГДА (подавляющее большинство случаев формы `выбор
//     получить() ... конец` использует его немедленно как объект
//     сопоставления, вообще без именованной локальной переменной). Это
//     РЕАЛЬНЫЙ, осознанно принятый пробел Фазы 1 сверх того, что покрывает
//     политика `frameLayouts` "каждая локальная переменная": значение,
//     вычисленное ДО receive из чего-то, отличного от локальной
//     переменной, и использованное ПОСЛЕ него (минуя и привязку к
//     локальной переменной, и собственный dst receive), НЕ сохраняется —
//     сначала привяжите его через `пер`. Общий анализ живости через
//     границы остановки — Фаза 2+.
//
// Каждая `.receive`/`.receive_signal` становится проверкой почты/сигнала
// (`@runtime::mailbox_has`/`@runtime::signal_has`, реальные функции внутри
// модуля, которые строит `wasm_actors.zig` относительно фиксированного
// префикса кадра выше — НЕ хостовые импорты, это должно работать под
// обычным wasmtime без нового хостового кода) — пусто означает сохранить
// состояние и `.suspend_return`; непусто означает извлечь
// (`@runtime::mailbox_pop`/`@runtime::signal_pop`) и провалиться дальше,
// семантически отражая контракт приостановки нативной VM с откатом ip
// (`runProcessSlice` в `vm.zig`), переосмысленный для структурированного
// (без goto) потока управления WASM вместо указателя байткод-инструкции.

fn frameValue(builder: *mir_builder.Builder, frame_local: mir.LocalId, ptr_type: anytype) !mir.ValueId {
    // Каждый раз перечитывается заново в месте использования, никогда не
    // кэшируется между блоками — локальная переменная WASM всегда
    // безопасно перечитываема из любого блока своей функции, что снимает
    // вопрос межблоковой SSA-живости, который иначе пришлось бы решать
    // для одного общего значения.
    const dst = try builder.newValue(ptr_type);
    try builder.emit(.{ .load_local = .{ .dst = dst, .local = frame_local } });
    return dst;
}

fn intConstant(builder: *mir_builder.Builder, ptr_type: anytype, value: u32) !mir.ValueId {
    // Настоящий литерал i32 (`mir.ConstValue.address`) — метки состояний
    // возобновления и указатели на кадр/кучу никогда не предназначены
    // быть видимым пользователю `Число`, так что f64-представление
    // `.number` здесь полностью не нужно.
    const dst = try builder.newValue(ptr_type);
    try builder.emit(.{ .const_value = .{ .dst = dst, .value = .{ .address = value } } });
    return dst;
}

const SuspendKind = struct {
    has: []const u8,
    pop: []const u8,
};

fn suspendKind(instruction: mir.Instruction) ?SuspendKind {
    return switch (instruction) {
        .receive => .{ .has = "@runtime::mailbox_has", .pop = "@runtime::mailbox_pop" },
        .receive_signal => .{ .has = "@runtime::signal_has", .pop = "@runtime::signal_pop" },
        else => null,
    };
}

fn suspendDst(instruction: mir.Instruction) ?mir.ValueId {
    return switch (instruction) {
        .receive => |r| r.dst,
        .receive_signal => |r| r.dst,
        else => null,
    };
}

fn rewriteOrdinaryInstruction(builder: *mir_builder.Builder, instruction: mir.Instruction, frame_local: mir.LocalId, ptr_type: anytype) !void {
    switch (instruction) {
        .load_local => |load| {
            const frame = try frameValue(builder, frame_local, ptr_type);
            try builder.emit(.{ .frame_load = .{ .dst = load.dst, .frame = frame, .slot = frame_prefix_slots + @intFromEnum(load.local) } });
        },
        .store_local => |store| {
            const frame = try frameValue(builder, frame_local, ptr_type);
            try builder.emit(.{ .frame_store = .{ .frame = frame, .slot = frame_prefix_slots + @intFromEnum(store.local), .src = store.src } });
        },
        else => try builder.emit(instruction),
    }
}

// Применяется к тому терминатору, которым заканчивается переписанный
// поток инструкций (независимо от того, встретилась ли точка остановки) —
// ЕДИНСТВЕННОЕ место, откуда поток управления приостанавливаемой функции
// может по-настоящему покинуть функцию. `.return_value{null}`/`{value}`
// становится: (опционально) сохранить реальное значение в `result_slot`,
// затем `return_value{true}` (готово). `.jump`/`.branch`/
// `.unreachable_term` проходят без изменений (они остаются ВНУТРИ функции,
// учёт кадра/статуса не нужен). `.none`/`.suspend_return` не могут законно
// встретиться в теле функции до переписывания — на них стоит assert.
// Если `instruction` — вызов (прямой `.call` или `function_ref`+
// `.call_value`) `self_function`, возвращает его аргументы — `preceding`
// просматривается назад в поисках `function_ref`, через который
// разрешается `.call_value.callee` (то же соглашение, на которое
// опирается собственная карта `value_to_function` в `wasm_emit.zig`).
fn selfCallArgs(instruction: mir.Instruction, preceding: []const mir.Instruction, self_function: mir.FunctionId) ?[]const mir.ValueId {
    switch (instruction) {
        .call => |c| return if (c.callee == self_function) c.args else null,
        .call_value => |c| {
            var i = preceding.len;
            while (i > 0) {
                i -= 1;
                if (preceding[i] == .function_ref and preceding[i].function_ref.dst == c.callee) {
                    return if (preceding[i].function_ref.function == self_function) c.args else null;
                }
            }
            return null;
        },
        else => return null,
    }
}

fn rewriteReturnTerminator(builder: *mir_builder.Builder, frame_local: mir.LocalId, ptr_type: anytype, bool_type: anytype, terminator: mir.Terminator) !mir.Terminator {
    switch (terminator) {
        .return_value => |ret| {
            if (ret.value) |value| {
                const frame = try frameValue(builder, frame_local, ptr_type);
                try builder.emit(.{ .frame_store = .{ .frame = frame, .slot = result_slot, .src = value } });
            }
            const done = try builder.newValue(bool_type);
            try builder.emit(.{ .const_value = .{ .dst = done, .value = .{ .boolean = true } } });
            return .{ .return_value = .{ .value = done } };
        },
        .jump, .branch, .unreachable_term => return terminator,
        .none, .suspend_return => unreachable,
    }
}

pub fn prepare(allocator: std.mem.Allocator, module: *mir.Module) !std.AutoHashMap(mir.FunctionId, FrameInfo) {
    var frame_info: std.AutoHashMap(mir.FunctionId, FrameInfo) = .init(allocator);
    errdefer frame_info.deinit();
    if (!hasActorInstructions(module)) return frame_info;
    var actor_plans = try plans(module.arena.allocator(), module);
    defer deinitPlans(module.arena.allocator(), &actor_plans);
    for (actor_plans.items) |plan| {
        const info = try rewriteFunction(allocator, module, plan);
        try frame_info.put(plan.function, info);
    }
    return frame_info;
}

fn rewriteFunction(allocator: std.mem.Allocator, module: *mir.Module, plan: FunctionPlan) !FrameInfo {
    const function_index: usize = @intFromEnum(plan.function);
    const type_store = module.functions.items[function_index].type_store orelse return error.MissingTypeStore;
    // Нужен тип, отображаемый в настоящий i32 WASM
    // (`wasm_module.wasmValTypeForStore`) — это требование, а не
    // косметика: кодогенерация `frame_load`/`frame_store` выдаёт голый
    // `i32.add` для арифметики смещения слота, предполагая, что значение
    // кадра УЖЕ i32 на стеке (`Целое` было бы f64 — числовое соглашение
    // Фазы 1a — что дало бы невалидный модуль). `Type.process` потребовал
    // бы НОВОЙ записи через мутирующий конструктор `TypeStore.process(payload)`
    // — не тот инструмент на этой поздней стадии компиляции для простой
    // метки непрозрачного дескриптора. `builtins.string` уже отображается
    // в i32 и гарантированно существует в каждом `TypeStore`; переиспользован
    // здесь исключительно как "непрозрачный дескриптор i32", никогда через
    // строкоспецифичный путь кодогенерации (нет `.binary`-сложения, нет
    // доступа к свойству/индексу — каждая операция с указателем кадра идёт
    // через `frame_load`/`frame_store`/константы `.address`, ни одна из
    // которых не выделяет этот тип особым образом).
    const ptr_type = type_store.builtins.string;
    const bool_type = type_store.builtins.boolean;

    const original_param_count: u32 = @intCast(module.functions.items[function_index].parameters.len);
    const original_local_count: u32 = @intCast(module.functions.items[function_index].locals.items.len);
    const local_state_slot: u32 = frame_prefix_slots + original_local_count;
    const message_slot_base: u32 = local_state_slot + 1;
    const total_slots: u32 = message_slot_base + @as(u32, @intCast(plan.suspend_points.len));

    // Снимок ДО любой мутации — `plan.suspend_points`/`.block`/
    // `.instruction_index` описывают функцию такой, какой она была на
    // момент работы `plans`, и каждое последующее разбиение/переписывание
    // ниже опирается на этот замороженный список, никогда не выводится
    // заново по ходу переписывания.
    const original_blocks = try allocator.alloc(mir.BlockId, module.functions.items[function_index].blocks.items.len);
    for (original_blocks, 0..) |*id, i| id.* = @enumFromInt(i);
    defer allocator.free(original_blocks);
    const original_entry = module.functions.items[function_index].entry;

    // Шаг 1: заменить `.locals`/`.parameters`/`.result_type` — указатель
    // на кадр отныне ЕДИНСТВЕННАЯ настоящая локальная переменная/параметр
    // функции, а её результат становится простым статусом
    // готово/приостановлено (см. абзац про `result_slot` в комментарии к
    // файлу).
    const frame_local: mir.LocalId = @enumFromInt(0);
    module.functions.items[function_index].locals.clearRetainingCapacity();
    try module.functions.items[function_index].locals.append(allocator, .{ .id = frame_local, .symbol = @enumFromInt(0), .name = "@frame", .type_id = ptr_type });
    allocator.free(module.functions.items[function_index].parameters);
    const new_parameters = try allocator.alloc(mir.LocalId, 1);
    new_parameters[0] = frame_local;
    module.functions.items[function_index].parameters = new_parameters;
    module.functions.items[function_index].result_type = bool_type;

    var builder = mir_builder.Builder{ .module = module, .allocator = allocator, .function_id = plan.function };

    // Id входной диспетчеризации резервируется УЖЕ СЕЙЧАС (содержимое
    // заполняется позже, шаг 3), чтобы собственный хвостовой вызов
    // (обнаруживается при разбиении, шаг 2) мог указывать на него напрямую.
    // Это принципиально, а не просто удобство: прыжок сразу на
    // `original_entry` дал бы этому блоку ДВА входящих ребра из
    // несвязанных мест (собственный откат диспетчеризации на "свежий
    // старт" И собственную обратную петлю хвостового вызова), причём НИ
    // ОДНО из них не тот блок, который `wasm_stackify` считает входом
    // функции — неприводимая на вид форма, которую он не может
    // восстановить. Направление хвостового вызова через `dispatch_entry`
    // вместо этого делает его единственным заголовком цикла — ЕДИНСТВЕННЫМ
    // блоком с входящим ребром снаружи функции И с обратного ребра, ровно
    // той формой, которую обычный структурированный поток управления уже
    // умеет сворачивать в настоящий `loop` WASM.
    const dispatch_entry = try builder.newBlock();

    // Шаг 2: переписать и разбить каждый ИСХОДНЫЙ блок. Id блока
    // возобновления точки остановки известен только после его фактического
    // построения — записывается здесь, чтобы шаг 3 (входная
    // диспетчеризация) мог прыгнуть прямо на него.
    var resume_blocks = std.AutoHashMap(u32, mir.BlockId).init(allocator);
    defer resume_blocks.deinit();

    for (original_blocks) |block_id| {
        try splitBlockAtSuspends(&builder, allocator, block_id, plan, frame_local, ptr_type, bool_type, local_state_slot, message_slot_base, &resume_blocks, dispatch_entry, plan.function);
    }

    // Шаг 3: входная диспетчеризация — ветвление по `frame.state`:
    // 0 -> (переписанный) исходный входной блок, K -> блок возобновления
    // точки остановки K.
    module.functions.items[function_index].entry = dispatch_entry;
    try emitDispatch(&builder, dispatch_entry, frame_local, ptr_type, local_state_slot, plan.suspend_points, &resume_blocks, original_entry);

    return .{ .param_count = original_param_count, .total_slots = total_slots };
}

// По одному сравнению `.equal` + `.branch` на каждое состояние-кандидат,
// сцепленных через новые блоки — линейный проход, а не таблица переходов
// (кодировка `br_table` в WASM требует плотного, известного на этапе
// компиляции диапазона; в Фазе 1 не больше горстки точек остановки на
// функцию, так что линейная форма проще всего и достаточно дёшева —
// пересмотреть только если профилирование когда-нибудь скажет иначе).
fn emitDispatch(
    builder: *mir_builder.Builder,
    entry: mir.BlockId,
    frame_local: mir.LocalId,
    ptr_type: anytype,
    local_state_slot: u32,
    suspend_points: []const SuspendPoint,
    resume_blocks: *const std.AutoHashMap(u32, mir.BlockId),
    original_entry: mir.BlockId,
) !void {
    var current = entry;
    for (suspend_points) |point| {
        builder.setCurrentBlock(current);
        const frame = try frameValue(builder, frame_local, ptr_type);
        const state = try builder.newValue(ptr_type);
        try builder.emit(.{ .frame_load = .{ .dst = state, .frame = frame, .slot = local_state_slot } });
        const target_const = try intConstant(builder, ptr_type, point.resume_state);
        const is_this_state = try builder.newValue(builder.currentFunction().type_store.?.builtins.boolean);
        try builder.emit(.{ .compare = .{ .dst = is_this_state, .op = .equal, .lhs = state, .rhs = target_const } });
        const resume_block = resume_blocks.get(point.resume_state) orelse return error.MissingResumeBlock;
        const next = try builder.newBlock();
        builder.terminate(.{ .branch = .{ .cond = is_this_state, .then_block = resume_block, .else_block = next } });
        current = next;
    }
    // Ничего не совпало — состояние должно быть 0 (свежий старт).
    builder.setCurrentBlock(current);
    builder.terminate(.{ .jump = .{ .target = original_entry } });
}

// Разбивает `block_id` по каждой содержащейся в нём `.receive`/
// `.receive_signal`, по порядку. Блок сохраняет свой id для ПЕРВОГО
// сегмента (Jump/Branch любого другого блока, указывающие на него,
// остаются валидными без изменений); последующие сегменты — новые блоки.
// Обычные инструкции переводятся на кадр на месте (`load_local`/
// `store_local` -> `frame_load`/`frame_store`) по мере копирования;
// ИСХОДНЫЙ терминатор, когда в потоке больше не остаётся точек остановки,
// переписывается через `rewriteReturnTerminator`.
fn splitBlockAtSuspends(
    builder: *mir_builder.Builder,
    allocator: std.mem.Allocator,
    block_id: mir.BlockId,
    plan: FunctionPlan,
    frame_local: mir.LocalId,
    ptr_type: anytype,
    bool_type: anytype,
    local_state_slot: u32,
    message_slot_base: u32,
    resume_blocks: *std.AutoHashMap(u32, mir.BlockId),
    original_entry: mir.BlockId,
    self_function: mir.FunctionId,
) !void {
    const function = builder.currentFunction();
    const original = function.blockConst(block_id).*;
    const original_instructions = try allocator.dupe(mir.Instruction, original.instructions.items);
    defer allocator.free(original_instructions);
    const original_terminator = original.terminator;
    // `.deinit`, а НЕ `allocator.free(.items)` — `.items` это `ptr[0..len]`,
    // а РЕАЛЬНОЕ выделение — `ptr[0..capacity]` (`ArrayList.allocatedSlice()`);
    // освобождение более короткого среза `.items` напрямую передаёт
    // отладочному аллокатору длину, не совпадающую с его собственным учётом
    // бакетов, и вызывает панику ("Invalid free"), как только
    // `len != capacity`.
    function.block(block_id).instructions.deinit(allocator);
    function.block(block_id).instructions = .empty;

    builder.setCurrentBlock(block_id);
    builder.terminated = false;

    try rewriteInstructionStream(
        builder,
        allocator,
        original_instructions,
        0,
        block_id,
        plan,
        frame_local,
        ptr_type,
        bool_type,
        local_state_slot,
        message_slot_base,
        resume_blocks,
        original_terminator,
        &.{},
        original_entry,
        self_function,
    );
}

// Общая реализация как для ПЕРВОГО сегмента исходного блока
// (`splitBlockAtSuspends`), так и для каждого сегмента ПОСЛЕ разбиения —
// объединено здесь так, чтобы существовало ровно одно место, решающее
// "найдена точка остановки -> разбить" против "инструкции закончились ->
// применить (переписанный) исходный терминатор". Собственный `dst`
// receive, после возобновления, перенаправляется на обычную локальную
// переменную WASM (а НЕ на повторный `frame_load` из `message_slot`) —
// одно и то же значение нельзя передать напрямую в две и более
// последующих инструкции (инвариант единственного использования,
// который навязывает `mir_validate.zig`: `ValueId` — это значение стека,
// потребляемое один раз), поэтому каждая последующая ССЫЛКА получает
// СОБСТВЕННЫЙ свежий `load_local` из этой локальной переменной.
pub const Redirect = struct { old: mir.ValueId, local: mir.LocalId, type_id: types.TypeId };

fn rewriteInstructionStream(
    builder: *mir_builder.Builder,
    allocator: std.mem.Allocator,
    instructions: []const mir.Instruction,
    start_index: usize,
    original_block: mir.BlockId,
    plan: FunctionPlan,
    frame_local: mir.LocalId,
    ptr_type: anytype,
    bool_type: anytype,
    local_state_slot: u32,
    message_slot_base: u32,
    resume_blocks: *std.AutoHashMap(u32, mir.BlockId),
    original_terminator: mir.Terminator,
    redirects: []const Redirect,
    original_entry: mir.BlockId,
    self_function: mir.FunctionId,
) !void {
    var index: usize = start_index;
    while (index < instructions.len) {
        var instruction = instructions[index];
        const kind = suspendKind(instruction);
        if (kind == null) {
            for (redirects) |redirect| {
                if (!referencesValue(instruction, redirect.old)) continue;
                const fresh = try builder.newValue(redirect.type_id);
                try builder.emit(.{ .load_local = .{ .dst = fresh, .local = redirect.local } });
                // Арена модуля, а НЕ параметр `allocator` — заменённое
                // поле-массив сохраняется в СОХРАНЯЕМУЮ инструкцию,
                // живущую в `module`, поэтому ему нужно то же время
                // жизни, принадлежащее модулю, что использует любой
                // другой срез, принадлежащий инструкции, в этой кодовой
                // базе (например, `wasm_heap.dupeOne`), а не временный
                // аллокатор, который может освободиться из-под него
                // после возврата этой функции.
                instruction = try substituteValue(builder.module.arena.allocator(), instruction, redirect.old, fresh);
            }

            // Само-хвостовой вызов: `функ ф(...) -> Т \n ... \n
            // ф(new_args) \n конец` (документированная идиома акторов
            // паноса — см. `счётчик` в docs/processes.md) — результат
            // рекурсивного вызова течёт напрямую в СОБСТВЕННЫЙ возврат
            // этой функции, других использований нет. Компилировать это
            // как обычный вызов было бы дважды неверно: (1) сигнатура
            // callee уже переписана на приём указателя на кадр, а не
            // исходных аргументов, и (2) даже после исправления,
            // настоящий вложенный вызов растил бы стек вызовов WASM для
            // того, что семантически является неограниченным циклом.
            // Вместо этого: записываем новые аргументы в слоты параметров
            // ЭТОГО ЖЕ САМОГО кадра и прыгаем обратно на блок диспетчеризации
            // входа — превращая рекурсию в обычный цикл с одной точкой
            // входа на уровне CFG, избегая несводимого (с несколькими
            // точками входа) цикла, который производит `получить()`
            // внутри настоящего `пока` (`пока`-тело с receive — задача
            // Фазы 2+, пока этот пробел в структурированном потоке
            // управления не закрыт).
            //
            // Обычный само-вызов по имени (`ф(...)`, не `x.ф(...)`)
            // никогда не опускается напрямую в `.call` —
            // `mir_lowering.zig` всегда идёт через `function_ref`
            // (записанный ранее в ЭТОМ ЖЕ потоке инструкций) +
            // `.call_value` — именно ту форму, которую `value_to_function`
            // из `wasm_emit.zig` разрешает во время кодогенерации.
            // Определяется как "последняя инструкция этого сегмента,
            // разрешается в `self_function`" — намеренно БЕЗ требования
            // `original_terminator == return_value`: типичная
            // скомпилированная форма `выбор`/`тогда` прыгает в общий
            // join-блок, который просто пробрасывает (здесь — `Пусто`,
            // неиспользуемый) результат в реальный возврат; будучи
            // ПОСЛЕДНЕЙ инструкцией сегмента, это уже исключает
            // что-либо ЕЩЁ значимое на этом пути, поэтому переход сразу
            // к заголовку цикла вместо посещения этого тривиального
            // join-блока эквивалентен. Join-блок, выполняющий РЕАЛЬНУЮ
            // дополнительную работу после рекурсивного вызова в
            // хвостовой позиции — реальный, необнаруживаемый граничный
            // случай, который эта эвристика допускает для Фазы 1.
            if (index == instructions.len - 1) {
                if (selfCallArgs(instruction, instructions[0..index], self_function)) |args| {
                    for (args, 0..) |arg, i| {
                        const frame = try frameValue(builder, frame_local, ptr_type);
                        try builder.emit(.{ .frame_store = .{ .frame = frame, .slot = frame_prefix_slots + @as(u32, @intCast(i)), .src = arg } });
                    }
                    builder.terminate(.{ .jump = .{ .target = original_entry } });
                    return;
                }
            }

            try rewriteOrdinaryInstruction(builder, instruction, frame_local, ptr_type);
            index += 1;
            continue;
        }

        // Найдена точка остановки — находим её записанный resume_state
        // (замороженный список `plan.suspend_points` ключуется по
        // ИСХОДНОМУ блоку + instruction_index, не затрагивается этим
        // переписыванием, поскольку инструкции перед ним только
        // ПЕРЕПИСЫВАЮТСЯ на месте, никогда не переупорядочиваются и не
        // удаляются).
        var resume_state: ?u32 = null;
        for (plan.suspend_points) |point| {
            if (point.block == original_block and point.instruction_index == index) {
                resume_state = point.resume_state;
                break;
            }
        }
        const state = resume_state orelse return error.UnrecognizedSuspendPoint;
        const dst = suspendDst(instruction).?;
        const message_slot = message_slot_base + (state - 1);
        const function = builder.currentFunction();

        // Проверка почты/сигнала — живёт в СОБСТВЕННОМ блоке
        // (`recheck_block`), не встроена в тот блок, что был текущим,
        // когда эта точка остановки была достигнута. Этот блок — ОДНОВРЕМЕННО
        // естественный fallthrough из кода выше И (через `resume_blocks`
        // ниже) СОБСТВЕННАЯ цель прыжка диспетчеризации входа для этого
        // состояния — проверка has() должна ДЕЙСТВИТЕЛЬНО ПЕРЕЗАПУСКАТЬСЯ
        // при каждом возобновлении, не пропускаться, потому что
        // планировщик `wasm_actors.zig` вызывает шаг приостановленной
        // функции многократно, на каждом раунде, БЕЗ гарантии, что новое
        // сообщение действительно придёт к моменту следующего вызова.
        const recheck_block = try builder.newBlock();
        builder.terminate(.{ .jump = .{ .target = recheck_block } });
        builder.setCurrentBlock(recheck_block);

        const check_frame = try frameValue(builder, frame_local, ptr_type);
        const has = try builder.newValue(bool_type);
        try builder.emit(.{ .call_builtin = .{ .dst = has, .name = kind.?.has, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{check_frame}) } });

        const suspend_block = try builder.newBlock();
        const have_block = try builder.newBlock();
        builder.terminate(.{ .branch = .{ .cond = has, .then_block = have_block, .else_block = suspend_block } });

        // Путь приостановки: сохранить состояние, вернуть "не завершено".
        builder.setCurrentBlock(suspend_block);
        // `src` вычисляется ПЕРЕД `frame` — кодогенерация `frame_store`
        // ожидает порядок стека `[src, frame]` (см. doc-комментарий
        // `EmitContext.frame_store_scratch_frame` в `wasm_emit.zig`).
        const state_value = try intConstant(builder, ptr_type, state);
        const suspend_frame = try frameValue(builder, frame_local, ptr_type);
        try builder.emit(.{ .frame_store = .{ .frame = suspend_frame, .slot = local_state_slot, .src = state_value } });
        builder.terminate(.suspend_return);

        // Путь возобновления: снять сообщение с очереди, продолжить с
        // ОСТАВШЕЙСЯ частью исходного потока инструкций в `have_block` —
        // это одновременно fallthrough (сообщение уже было) И блок,
        // на который прыгает диспетчеризация входа, когда планировщик
        // позже возобновляет это точное состояние. Снятое значение идёт
        // напрямую в обычную локальную переменную (см. комментарий
        // `Redirect` ниже) — сам `message_slot` зарезервирован в
        // раскладке кадра, но сейчас больше не используется (оставлено
        // просто, вместо переиспользования слота).
        builder.setCurrentBlock(have_block);
        _ = message_slot;
        // Собственный объявленный тип `получить()` остаётся `poison`,
        // если только охватывающая функция не объявлена как
        // `-> Сообщение(T)` (реальное, отдельное ограничение
        // `type_checker.zig`: он никогда не выводит тип из сужения по
        // ветке match для гораздо более распространённой идиомы
        // `-> Пусто`). Здесь безопасно использовать напрямую —
        // `wasm_module.wasmValTypeForStore` теперь особо обрабатывает
        // `poison`/`unconstrained` как i32 (см. его собственный
        // doc-комментарий), последовательно, везде, где решается WASM-
        // представление этого TypeId (собственная локальная переменная
        // этого значения, каждый `frame_load`/`frame_store`, производный
        // от неё, выбор pop-варианта в `wasm_actors.zig`).
        const message_type = function.valueType(dst);
        const pop_frame = try frameValue(builder, frame_local, ptr_type);
        const popped = try builder.newValue(message_type);
        try builder.emit(.{ .call_builtin = .{ .dst = popped, .name = kind.?.pop, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{pop_frame}) } });
        try resume_blocks.put(state, recheck_block);

        // ИСХОДНЫЙ `dst` (собственный ValueId receive) перенаправляется
        // на обычную локальную переменную WASM — каждая последующая
        // инструкция, ссылающаяся на него, получает СОБСТВЕННЫЙ свежий
        // `load_local` (см. doc-комментарий `Redirect`; одна общая
        // перезагрузка не может удовлетворить более одного последующего
        // использования).
        const redirect_local = try builder.newLocal(@enumFromInt(0), "@msg", message_type);
        try builder.emit(.{ .store_local = .{ .local = redirect_local, .src = popped } });

        const new_redirects = try allocator.alloc(Redirect, redirects.len + 1);
        defer allocator.free(new_redirects);
        @memcpy(new_redirects[0..redirects.len], redirects);
        new_redirects[redirects.len] = .{ .old = dst, .local = redirect_local, .type_id = message_type };

        // Сопоставление `plan.suspend_points` (выше, при СЛЕДУЮЩЕМ
        // рекурсивном вызове) сравнивает с ИСХОДНЫМИ абсолютными
        // индексами — продолжаем рекурсию по ТОМУ ЖЕ (не нарезанному)
        // массиву `instructions` с `start_index = index + 1`, чтобы
        // собственный `instruction_index` более поздней точки остановки
        // по-прежнему совпадал.
        try rewriteInstructionStream(
            builder,
            allocator,
            instructions,
            index + 1,
            original_block,
            plan,
            frame_local,
            ptr_type,
            bool_type,
            local_state_slot,
            message_slot_base,
            resume_blocks,
            original_terminator,
            new_redirects,
            original_entry,
            self_function,
        );
        // Рекурсивный вызов уже применил (переписанную форму) исходного
        // терминатора к тому блоку, на котором он завершился — для
        // этого вызова больше ничего не остаётся сделать.
        return;
    }
    builder.terminate(try rewriteReturnTerminator(builder, frame_local, ptr_type, bool_type, original_terminator));
}

// Тот же список полей, что у `substituteValue` ниже — поддерживается в
// синхронизации вручную (оба маленькие и редко меняются). ПРИМЕЧАНИЕ:
// если `old` встречается в ДВУХ ИЛИ БОЛЕЕ полях ОДНОЙ И ТОЙ ЖЕ инструкции
// (например, гипотетический `binary{lhs = v, rhs = v}`), `substituteValue`
// отображает оба вхождения на ОДНУ И ТУ ЖЕ свежую перезагрузку, что само
// по себе — нарушение инварианта единственного использования — ни одна
// текущая форма опускания этого не порождает (ни одна MIR-инструкция не
// повторяет одно значение-результат receive в двух своих полях-
// операндах), но это реальный, необнаруженный пробел этого механизма,
// а не решённый случай.
pub fn referencesValue(instruction: mir.Instruction, target: mir.ValueId) bool {
    return switch (instruction) {
        .copy => |i| i.src == target,
        .store_local => |i| i.src == target,
        .binary => |i| i.lhs == target or i.rhs == target,
        .compare => |i| i.lhs == target or i.rhs == target,
        .unary => |i| i.src == target,
        .get_property => |i| i.object == target,
        .set_property => |i| i.value == target,
        .get_index => |i| i.object == target or i.index == target,
        .set_index => |i| i.object == target or i.index == target or i.value == target,
        .cast_interface => |i| i.src == target,
        .invoke_interface => |i| i.receiver == target or for (i.args) |a| {
            if (a == target) break true;
        } else false,
        .match_tag => |i| i.subject == target,
        .get_variant_field => |i| i.subject == target,
        .send => |i| i.process == target or i.message == target,
        .try_unwrap => |i| i.src == target,
        .frame_store => |i| i.src == target,
        // СЫРОЙ результат receive (до какого-либо извлечения полей через
        // сопоставление с образцом), текущий напрямую в собственный
        // список аргументов call/aggregate/spawn — ни один текущий
        // фикстур этого не делает (каждая идиома акторов, задействованная
        // в этой кодовой базе, сначала деструктурирует через
        // match_tag/get_variant_field, оба уже покрыты выше), но это тот
        // же класс пробела, что и баги с build_variant/new_aggregate
        // (порядок полей, `wasm_objects.zig`) и expandSpawn (порядок
        // аргументов, `wasm_actors.zig`) — закрывается защитно, не
        // дожидаясь третьего случая.
        .call => |i| for (i.args) |a| {
            if (a == target) break true;
        } else false,
        .call_value => |i| i.callee == target or for (i.args) |a| {
            if (a == target) break true;
        } else false,
        .call_indirect => |i| i.table_index == target or for (i.args) |a| {
            if (a == target) break true;
        } else false,
        .new_aggregate => |i| for (i.elements) |e| {
            if (e == target) break true;
        } else false,
        .new_array => |i| for (i.elements) |e| {
            if (e == target) break true;
        } else false,
        .build_variant => |i| for (i.fields) |f| {
            if (f == target) break true;
        } else false,
        .spawn => |i| i.callee == target or for (i.args) |a| {
            if (a == target) break true;
        } else false,
        else => false,
    };
}

// `allocator` нужен ТОЛЬКО для случаев с полями-массивами (`args`/
// `elements`/`fields` у `.call`/`.call_value`/`.new_aggregate`/
// `.new_array`/`.build_variant`/`.spawn`) — замена внутри `[]const
// ValueId` требует свежей владеемой копии, в отличие от любого другого
// случая здесь, который просто переприсваивает одно поле `ValueId` на
// месте.
pub fn substituteValue(allocator: std.mem.Allocator, instruction: mir.Instruction, old: mir.ValueId, new: mir.ValueId) !mir.Instruction {
    if (old == new) return instruction;
    const sub = struct {
        fn v(value: mir.ValueId, o: mir.ValueId, n: mir.ValueId) mir.ValueId {
            return if (value == o) n else value;
        }
    }.v;
    const subSlice = struct {
        fn f(alloc: std.mem.Allocator, values: []const mir.ValueId, o: mir.ValueId, n: mir.ValueId) ![]const mir.ValueId {
            const out_slice = try alloc.dupe(mir.ValueId, values);
            for (out_slice) |*value| {
                if (value.* == o) value.* = n;
            }
            return out_slice;
        }
    }.f;
    var out = instruction;
    switch (out) {
        .copy => |*i| i.src = sub(i.src, old, new),
        .store_local => |*i| i.src = sub(i.src, old, new),
        .binary => |*i| {
            i.lhs = sub(i.lhs, old, new);
            i.rhs = sub(i.rhs, old, new);
        },
        .compare => |*i| {
            i.lhs = sub(i.lhs, old, new);
            i.rhs = sub(i.rhs, old, new);
        },
        .unary => |*i| i.src = sub(i.src, old, new),
        .get_property => |*i| i.object = sub(i.object, old, new),
        .set_property => |*i| i.value = sub(i.value, old, new),
        .get_index => |*i| {
            i.object = sub(i.object, old, new);
            i.index = sub(i.index, old, new);
        },
        .set_index => |*i| {
            i.object = sub(i.object, old, new);
            i.index = sub(i.index, old, new);
            i.value = sub(i.value, old, new);
        },
        .cast_interface => |*i| i.src = sub(i.src, old, new),
        .invoke_interface => |*i| {
            i.receiver = sub(i.receiver, old, new);
            i.args = try subSlice(allocator, i.args, old, new);
        },
        .match_tag => |*i| i.subject = sub(i.subject, old, new),
        .get_variant_field => |*i| i.subject = sub(i.subject, old, new),
        .send => |*i| {
            i.process = sub(i.process, old, new);
            i.message = sub(i.message, old, new);
        },
        .try_unwrap => |*i| i.src = sub(i.src, old, new),
        .frame_store => |*i| i.src = sub(i.src, old, new),
        .call => |*i| i.args = try subSlice(allocator, i.args, old, new),
        .call_value => |*i| {
            i.callee = sub(i.callee, old, new);
            i.args = try subSlice(allocator, i.args, old, new);
        },
        .call_indirect => |*i| {
            i.table_index = sub(i.table_index, old, new);
            i.args = try subSlice(allocator, i.args, old, new);
        },
        .new_aggregate => |*i| i.elements = try subSlice(allocator, i.elements, old, new),
        .new_array => |*i| i.elements = try subSlice(allocator, i.elements, old, new),
        .build_variant => |*i| i.fields = try subSlice(allocator, i.fields, old, new),
        .spawn => |*i| {
            i.callee = sub(i.callee, old, new);
            i.args = try subSlice(allocator, i.args, old, new);
        },
        else => {},
    }
    return out;
}

test "hasActorInstructions detects receive" {
    var module = mir.Module.init(std.testing.allocator);
    defer module.deinit(std.testing.allocator);
    var function = mir.Function{ .id = @enumFromInt(0), .name = "actor", .symbol = @enumFromInt(0), .result_type = types.TypeId.raw(0), .span = .{ .file_id = 0, .start = 0, .end = 0 } };
    try function.value_types.append(std.testing.allocator, types.TypeId.raw(0));
    var block = mir.Block{ .id = @enumFromInt(0) };
    try block.instructions.append(std.testing.allocator, .{ .receive = .{ .dst = @enumFromInt(0) } });
    try function.blocks.append(std.testing.allocator, block);
    try module.functions.append(std.testing.allocator, function);
    try std.testing.expect(hasActorInstructions(&module));
    var points = try collectSuspendPoints(std.testing.allocator, &module);
    defer points.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), points.items.len);
    try std.testing.expectEqual(@as(u32, 1), points.items[0].resume_state);
    var layouts = try frameLayouts(std.testing.allocator, &module);
    defer {
        for (layouts.items) |layout| std.testing.allocator.free(layout.locals);
        layouts.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), layouts.items.len);
}
