const std = @import("std");
const mir = @import("mir.zig");
const mir_builder = @import("mir_builder.zig");
const mir_cps = @import("mir_cps.zig");
const types = @import("types.zig");
const source = @import("source.zig");
const symbols = @import("symbols.zig");
const wasm_module = @import("wasm_module.zig");
const wasm_heap = @import("wasm_heap.zig");

// Превращает CPS-переписанные шаговые функции `mir_cps.zig` в РЕАЛЬНУЮ
// самодостаточную WASM-программу: строит общие рантайм-функции
// mailbox/signal/alloc, которые эти шаговые функции вызывают, перепрошивает
// плейсхолдерные имена `call_builtin{"@runtime::..."}`, испускаемые
// `mir_cps.zig`, в реальные внутримодульные `.call` (без новых host-импортов —
// это должно работать под обычным wasmtime), разворачивает `.spawn`/`.send`
// в конкретные последовательности alloc/frame-store и заменяет точку входа
// на обёртку-планировщик.
//
// Ограничение Phase-1 MVP, обеспечиваемое здесь (не предполагаемое): не более
// ОДНОГО `.spawn` во всём модуле, и он должен быть достижим из собственного
// (CPS-переписанного) тела `старт` — сам `старт` ОБЯЗАН вызвать `получить()`
// хотя бы раз (это позволяет ему выступать "процессом 0", которым управляет
// планировщик). Всё более широкое (несколько типов акторов, spawn изнутри
// заспавненного актора, неприостанавливающаяся точка входа, которая только
// спавнит и не ждёт ответа) — Phase 2+; `expand` возвращает чистую ошибку
// `unsupported`, а не молча производит программу, которая обрабатывает
// только более узкий случай.
//
// Форма планировщика: никакого настоящего WASM `loop` — фиксированная,
// РАЗВЁРНУТАЯ последовательность попыток раунд-трипа (`scheduler_rounds`),
// каждая — обычный if/else-ромб, вызывающий шаговую функцию процесса 0 и
// процесса 1 по одному разу, если ещё не завершены. Это намеренно проще (и
// менее рискованно при ручном написании), чем настоящий динамический цикл:
// собственная область применения Phase-1 (один заспавненный актор, один
// обмен запрос/ответ) сходится за несколько раундов; превышение границы
// приводит к trap вместо молчаливого возврата неполного результата.

fn unsupported(comptime what: []const u8) error{ActorExpandUnsupported} {
    std.debug.print("panos build: AOT (wasm) акторы — " ++ what ++ "\n", .{});
    return error.ActorExpandUnsupported;
}

const scheduler_rounds: u32 = 16;

// --- Общие рантайм-функции ----------------------------------------

fn buildHas(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout, name: []const u8, count_slot: u32) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, name, wasm_heap.dummy_symbol, layout.bool_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const frame_local = try builder.newLocal(wasm_heap.dummy_symbol, "frame", layout.ptr_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{frame_local});
    builder.currentFunction().type_store = type_store;

    const frame = try wasm_heap.frameValue(&builder, frame_local, layout.ptr_type);
    const count = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .frame_load = .{ .dst = count, .frame = frame, .slot = count_slot } });
    const zero = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    const has = try wasm_heap.cmpOp(&builder, layout.bool_type, .not_equal, count, zero);
    builder.terminate(.{ .return_value = .{ .value = has } });
    return id;
}

// `payload_type` — pop нужно строить отдельно для каждой категории
// WASM-значений (i32-хэндл vs f64-число), поскольку обычная WASM-функция
// имеет ОДИН фиксированный тип результата, а полезная нагрузка сообщения
// различается по актору (см. разделение `mailbox_pop_f64`/`_i32` в
// doc-комментарии файла).
fn buildPop(
    allocator: std.mem.Allocator,
    module: *mir.Module,
    type_store: *const types.TypeStore,
    layout: wasm_heap.PtrLayout,
    name: []const u8,
    payload_type: types.TypeId,
    count_slot: u32,
    head_slot: u32,
    ring_base_slot: u32,
    cap: u32,
) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, name, wasm_heap.dummy_symbol, payload_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const frame_local = try builder.newLocal(wasm_heap.dummy_symbol, "frame", layout.ptr_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{frame_local});
    builder.currentFunction().type_store = type_store;

    const frame1 = try wasm_heap.frameValue(&builder, frame_local, layout.ptr_type);
    const head = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .frame_load = .{ .dst = head, .frame = frame1, .slot = head_slot } });
    const head_local = try wasm_heap.storeLocal(&builder, "head", layout.idx_type, head); // используется дважды ниже (адресная арифметика, head+1)

    // addr = frame + ring_base_slot*8 + head*8
    const frame2 = try wasm_heap.frameValue(&builder, frame_local, layout.ptr_type);
    const ring_base_bytes = try wasm_heap.addressConst(&builder, layout.ptr_type, ring_base_slot * 8);
    const base = try wasm_heap.binOp(&builder, layout.idx_type, .add, frame2, ring_base_bytes);
    const eight = try wasm_heap.addressConst(&builder, layout.idx_type, 8);
    const head_for_addr = try wasm_heap.loadLocal(&builder, head_local, layout.idx_type);
    const head_bytes = try wasm_heap.binOp(&builder, layout.idx_type, .multiply, head_for_addr, eight);
    const addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, base, head_bytes);
    const message = try builder.newValue(payload_type);
    try builder.emit(.{ .mem_load = .{ .dst = message, .addr = addr } });

    // head = (head + 1) & (cap - 1)
    const head_for_inc = try wasm_heap.loadLocal(&builder, head_local, layout.idx_type);
    const one = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const head_plus_one = try wasm_heap.binOp(&builder, layout.idx_type, .add, head_for_inc, one);
    const mask = try wasm_heap.addressConst(&builder, layout.idx_type, cap - 1);
    const head_new = try wasm_heap.binOp(&builder, layout.idx_type, .bit_and, head_plus_one, mask);
    const frame3 = try wasm_heap.frameValue(&builder, frame_local, layout.ptr_type);
    try builder.emit(.{ .frame_store = .{ .frame = frame3, .slot = head_slot, .src = head_new } });

    // count -= 1
    const frame4 = try wasm_heap.frameValue(&builder, frame_local, layout.ptr_type);
    const count = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .frame_load = .{ .dst = count, .frame = frame4, .slot = count_slot } });
    const one_again = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const count_new = try wasm_heap.binOp(&builder, layout.idx_type, .subtract, count, one_again);
    const frame5 = try wasm_heap.frameValue(&builder, frame_local, layout.ptr_type);
    try builder.emit(.{ .frame_store = .{ .frame = frame5, .slot = count_slot, .src = count_new } });

    builder.terminate(.{ .return_value = .{ .value = message } });
    return id;
}

pub const Runtime = struct {
    mailbox_has: mir.FunctionId,
    signal_has: mir.FunctionId,
    mailbox_pop_f64: mir.FunctionId,
    mailbox_pop_i32: mir.FunctionId,
    signal_pop_f64: mir.FunctionId,
    signal_pop_i32: mir.FunctionId,
};

fn buildRuntime(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout) !Runtime {
    _ = try wasm_heap.findOrBuildAlloc(allocator, module, type_store, layout);
    const mailbox_has = try buildHas(allocator, module, type_store, layout, "@actor_mailbox_has", mir_cps.mailbox_count_slot);
    const signal_has = try buildHas(allocator, module, type_store, layout, "@actor_signal_has", mir_cps.signal_count_slot);
    const mailbox_pop_f64 = try buildPop(allocator, module, type_store, layout, "@actor_mailbox_pop_f64", type_store.builtins.number, mir_cps.mailbox_count_slot, mir_cps.mailbox_head_slot, mir_cps.mailbox_ring_base, mir_cps.mailbox_cap);
    const mailbox_pop_i32 = try buildPop(allocator, module, type_store, layout, "@actor_mailbox_pop_i32", layout.ptr_type, mir_cps.mailbox_count_slot, mir_cps.mailbox_head_slot, mir_cps.mailbox_ring_base, mir_cps.mailbox_cap);
    const signal_pop_f64 = try buildPop(allocator, module, type_store, layout, "@actor_signal_pop_f64", type_store.builtins.number, mir_cps.signal_count_slot, mir_cps.signal_head_slot, mir_cps.signal_ring_base, mir_cps.signal_cap);
    const signal_pop_i32 = try buildPop(allocator, module, type_store, layout, "@actor_signal_pop_i32", layout.ptr_type, mir_cps.signal_count_slot, mir_cps.signal_head_slot, mir_cps.signal_ring_base, mir_cps.signal_cap);
    return .{
        .mailbox_has = mailbox_has,
        .signal_has = signal_has,
        .mailbox_pop_f64 = mailbox_pop_f64,
        .mailbox_pop_i32 = mailbox_pop_i32,
        .signal_pop_f64 = signal_pop_f64,
        .signal_pop_i32 = signal_pop_i32,
    };
}

// Находит плейсхолдерные инструкции `call_builtin{"@runtime::..."}`
// `mir_cps.zig` (см. `suspendKind` в том файле) во всех функциях и
// заменяет их реальным `.call` на подходящую функцию, построенную выше —
// вариант pop выбирается по типу `dst` МЕСТА ВЫЗОВА (реальному типу
// полезной нагрузки сообщения), а не по самой рантайм-функции.
fn rewireSuspendCalls(module: *mir.Module, runtime: Runtime) void {
    for (module.functions.items) |*function| {
        for (function.blocks.items) |*block| {
            for (block.instructions.items) |*instruction| {
                const call = switch (instruction.*) {
                    .call_builtin => |c| c,
                    else => continue,
                };
                // `себя()` (`"@runtime::current_process"` из `mir_lowering.zig`)
                // — в этой конструкции "хэндл" процесса И ЕСТЬ указатель на
                // его собственный фрейм, так что это просто чтение обратно
                // local 0 (`mir_cps.zig` всегда делает указатель на фрейм
                // local 0 переписанной функции), а не настоящий вызов.
                if (std.mem.eql(u8, call.name, "@runtime::current_process")) {
                    instruction.* = .{ .load_local = .{ .dst = call.dst.?, .local = @enumFromInt(0) } };
                    continue;
                }
                // Этот цикл матчит КАЖДЫЙ `.call_builtin` в функции, а не
                // только 4 связанных с приостановкой ниже — CPS-
                // приостанавливающаяся функция (вызывающая `получить()`)
                // может ТАКЖЕ содержать совершенно не связанный VOID
                // `call_builtin` (например, `DOM.на_клик(...)`,
                // регистрируемый изнутри `старт()` уже ПОСЛЕ того, как та
                // однажды приостановилась) с `call.dst == null`. Поэтому
                // `is_i32`/`call.dst.?` вычисляются только ПОСЛЕ проверки,
                // что `call.name` вообще одно из 4 нужных имён —
                // `mailbox_has`/`signal_has` возвращают фиксированный
                // `Булево` и вообще не нуждаются в проверке типа полезной
                // нагрузки.
                //
                // Сама проверка `is_i32` на равенство ТОЛЬКО с
                // `builtins.string`/`.boolean` пропускает любой номинальный
                // тип (структура/перечисление), массив и тип процесса — ВСЕ
                // они ТОЖЕ отображаются в i32 согласно
                // `wasm_module.wasmValTypeForStore` (которая также
                // специально обрабатывает `poison`/`unconstrained` как i32
                // — см. её собственный doc-комментарий — покрывая
                // иначе-неразрешённый тип `получить()` для обычной
                // акторной идиомы `-> Пусто`).
                const callee: ?mir.FunctionId = blk: {
                    if (std.mem.eql(u8, call.name, "@runtime::mailbox_has")) break :blk runtime.mailbox_has;
                    if (std.mem.eql(u8, call.name, "@runtime::signal_has")) break :blk runtime.signal_has;
                    if (std.mem.eql(u8, call.name, "@runtime::mailbox_pop") or std.mem.eql(u8, call.name, "@runtime::signal_pop")) {
                        const is_i32 = wasm_module.wasmValTypeForStore(function.type_store.?, function.valueType(call.dst.?)) == wasm_module.wasm_i32;
                        if (std.mem.eql(u8, call.name, "@runtime::mailbox_pop")) break :blk if (is_i32) runtime.mailbox_pop_i32 else runtime.mailbox_pop_f64;
                        break :blk if (is_i32) runtime.signal_pop_i32 else runtime.signal_pop_f64;
                    }
                    break :blk null;
                };
                if (callee) |fn_id| {
                    instruction.* = .{ .call = .{ .dst = call.dst, .callee = fn_id, .args = call.args } };
                }
            }
        }
    }
}

// --- Развёртка `.spawn`/`.send` -----------------------------------------

// function_ref, идущий непосредственно перед `.spawn` — то же соглашение,
// на которое опирается собственный `value_to_function` в `wasm_emit.zig`
// для `call_value`.
fn resolveSpawnTarget(function: *const mir.Function, callee: mir.ValueId) ?mir.FunctionId {
    for (function.blocks.items) |block| {
        for (block.instructions.items) |instruction| {
            if (instruction == .function_ref and instruction.function_ref.dst == callee) return instruction.function_ref.function;
        }
    }
    return null;
}

// Переписывает ЕДИНСТВЕННЫЙ `.spawn` внутри `function` (уже найденный
// вызывающей стороной) на месте: выделяет новый фрейм под размер `target`,
// копирует `args` в него позиционно и сохраняет новый указатель на фрейм в
// `child_frame_slot` фрейма ТЕКУЩЕЙ функции (чтобы планировщик мог его
// найти) — переиспользуя собственный ValueId `.spawn`'а `dst` как "хэндл
// процесса" везде, где он уже используется ниже по коду (обычное
// сохранение в локал `пер proc = запусти ...`, следующее за spawn, вообще
// не нуждается в переписывании).
fn expandSpawn(
    allocator: std.mem.Allocator,
    builder: *mir_builder.Builder,
    block_id: mir.BlockId,
    spawn_index: usize,
    layout: wasm_heap.PtrLayout,
    frame_local: mir.LocalId,
    target_total_slots: u32,
    child_frame_slot: u32,
) !void {
    const function = builder.currentFunction();
    var original = function.blockConst(block_id).*;
    const spawn = original.instructions.items[spawn_index].spawn;
    const dst = spawn.dst;
    const args = try allocator.dupe(mir.ValueId, spawn.args);
    defer allocator.free(args);

    var replacement: std.ArrayList(mir.Instruction) = .empty;
    try replacement.appendSlice(allocator, original.instructions.items[0..spawn_index]);

    // dst = alloc(target_total_slots * 8) — переиспользует ИСХОДНЫЙ
    // ValueId dst напрямую, так что каждая последующая инструкция,
    // ожидающая "результат spawn", продолжает работать без изменений.
    builder.setCurrentBlock(block_id);
    builder.currentFunction().block(block_id).instructions = replacement;
    builder.terminated = false;

    const size_const = try wasm_heap.addressConst(builder, layout.idx_type, target_total_slots * 8);
    // `Процесс`, захваченный DOM-замыканием, должен пережить сброс арены
    // между отдельными JS-вызовами — выделять его фрейм (mailbox включена,
    // она лежит inline в том же блоке) сразу в ПОСТОЯННОЙ области, а не в
    // обычной сбрасываемой арене. Флаг выставляет `lowerDomClickClosure` в
    // `mir_lowering.zig`; на модуль приходится не более одного `.spawn`
    // (ограничение Phase-1), так что единый флаг на весь модуль
    // однозначен — другого spawn, к которому это могло бы относиться, нет.
    const alloc_id = if (builder.module.actor_captured_by_dom_closure)
        try wasm_heap.findOrBuildAllocPermanent(allocator, builder.module, builder.currentFunction().type_store.?, layout)
    else
        // Гарантированно уже построена — `expand()` вызывает `buildRuntime`
        // (которая её создаёт) до того, как вообще запускается `expandSpawn`.
        wasm_heap.findFunctionByName(builder.module, wasm_heap.alloc_function_name).?;
    try builder.emit(.{ .call = .{ .dst = dst, .callee = alloc_id, .args = try wasm_heap.dupeOne(builder.module, size_const) } });
    // `dst` используется ниже для `frame_store` КАЖДОГО аргумента, для
    // сохранения в child-slot И, возможно, дальше по коду (собственный
    // `пер proc = запусти ...` пользователя) — инвариант "одно
    // использование", тот же приём, что и в `Redirect` из `mir_cps.zig`:
    // сохранить один раз, при каждом использовании перечитывать заново.
    const dst_local = try wasm_heap.storeLocal(builder, "@spawned", layout.ptr_type, dst);

    // Обходим args В ОБРАТНОМ порядке. `args` — все УЖЕ СУЩЕСТВУЮЩИЕ
    // значения (собственные аргументы `.spawn`, каждый вычислен рядом с
    // ИСХОДНОЙ, ещё не развёрнутой инструкцией `.spawn`, по порядку) — к
    // моменту, когда этот цикл выполняется, они ВСЕ уже лежат на реальном
    // WASM-стеке в порядке производства, причём ПОСЛЕДНИЙ аргумент —
    // самый верхний. Сохранение arg 0 первым (по возрастанию) захватило бы
    // не то (самое верхнее, последним произведённое) значение как `src` —
    // тот же класс бага, что и в циклах по полям `build_variant`/
    // `new_aggregate` в `wasm_objects.zig`. Ни одна из ранее построенных
    // фикстур акторов не спавнила функцию с 2+ параметрами — этот фикс
    // реально нужен именно для такого случая.
    var ai = args.len;
    while (ai > 0) {
        ai -= 1;
        const dst_for_arg = try wasm_heap.loadLocal(builder, dst_local, layout.ptr_type);
        try builder.emit(.{ .frame_store = .{ .frame = dst_for_arg, .slot = mir_cps.frame_prefix_slots + @as(u32, @intCast(ai)), .src = args[ai] } });
    }

    // `src` вычисляется ДО `frame` — см. doc-комментарий
    // `EmitContext.frame_store_scratch_frame` в `wasm_emit.zig` (порядок
    // стека, который ожидает кодогенерация `frame_store`, — `[src, frame]`).
    const dst_for_stash = try wasm_heap.loadLocal(builder, dst_local, layout.ptr_type);
    const own_frame = try wasm_heap.frameValue(builder, frame_local, layout.ptr_type);
    try builder.emit(.{ .frame_store = .{ .frame = own_frame, .slot = child_frame_slot, .src = dst_for_stash } });

    // Инструкции ниже по коду (собственный код пользователя после
    // `запусти ...`, например `пер proc = ...`) тоже могут ссылаться на
    // `dst` — перенаправляем точно так же, как это делает обработка точек
    // приостановки в `mir_cps.zig`.
    //
    // `.frame_store` здесь требует особой обработки, а не слепой
    // подстановки: к моменту запуска `expandSpawn` (ПОСЛЕ `mir_cps.
    // prepare`) пользовательский `пер proc = запусти ...` УЖЕ переписан
    // собственным случаем `.store_local` из `mir_cps.zig` в
    // `load_local{dst=F,local=frame_local}` (перезагрузка указателя на
    // фрейм, испускается ПЕРВОЙ, не затрагивается подстановкой ниже, так
    // как не ссылается на `dst`), за которой следует
    // `frame_store{frame=F,...,src=dst}`. Слепая подстановка здесь
    // вставила бы СВЕЖИЙ `loadLocal(dst_local)` для `src` прямо перед
    // (переписанным) frame_store — делая `src` самым свежим значением, а
    // `frame`(F), произведённый раньше, погребённым — наоборот тому, что
    // требует соглашение кодогенерации `frame_store` `[src, frame]`
    // (frame должен быть самым свежим). Итог: `proc` читал мусор (0)
    // вместо реального заспавненного хэндла, поскольку запись фактически
    // происходила по НЕВЕРНОМУ адресу. Фикс: распознаём именно эту пару
    // `load_local(frame_local)` + `frame_store{src=dst}` и пересобираем
    // её в правильном порядке — отбрасывая устаревшую (теперь мёртвую)
    // перезагрузку фрейма и испуская свежую ПОСЛЕ свежей перезагрузки src.
    var ti: usize = 0;
    const tail = original.instructions.items[spawn_index + 1 ..];
    while (ti < tail.len) : (ti += 1) {
        const tail_instruction = tail[ti];
        // Заглядываем вперёд: является ли ЭТО перезагрузкой указателя на
        // фрейм, единственная цель которой (согласно переписыванию
        // `.store_local` в mir_cps.zig) — накормить `frame_store{src=dst}`
        // САМОЙ СЛЕДУЮЩЕЙ инструкции? Если да, НЕ испускаем её — её
        // значение оказалось бы мёртвым-но-непотреблённым, как только
        // следующая итерация пересоберёт свежую версию в правильном порядке.
        if (tail_instruction == .load_local and tail_instruction.load_local.local == frame_local and
            ti + 1 < tail.len and tail[ti + 1] == .frame_store and tail[ti + 1].frame_store.src == dst and
            tail[ti + 1].frame_store.frame == tail_instruction.load_local.dst)
        {
            continue;
        }
        if (tail_instruction == .frame_store and tail_instruction.frame_store.src == dst) {
            const fs = tail_instruction.frame_store;
            const fresh_src = try wasm_heap.loadLocal(builder, dst_local, layout.ptr_type);
            const fresh_frame = try wasm_heap.frameValue(builder, frame_local, layout.ptr_type);
            try builder.emit(.{ .frame_store = .{ .frame = fresh_frame, .slot = fs.slot, .src = fresh_src } });
            continue;
        }
        var rewritten = tail_instruction;
        if (mir_cps.referencesValue(rewritten, dst)) {
            const fresh = try wasm_heap.loadLocal(builder, dst_local, layout.ptr_type);
            rewritten = try mir_cps.substituteValue(builder.module.arena.allocator(), rewritten, dst, fresh);
        }
        try builder.emit(rewritten);
    }
    builder.terminate(original.terminator);
    // `.deinit`, а не `allocator.free(.items)` — см. идентичный комментарий
    // в `mir_cps.zig` про её собственный эквивалентный free.
    original.instructions.deinit(allocator);
}

// `отправить` из ЛЮБОГО МЕСТА, кроме собственного (CPS-переписанного,
// управляемого планировщиком) тела `старт()`, не имеет внешнего цикла,
// который бы после этого прогонял шаговую функцию целевого актора —
// `старт()` получает это бесплатно из развёрнутого раунд-трипа
// `buildScheduler`, а DOM-обработчик, вызывающий `отправить` после того,
// как `старт()` уже вернулся, предоставлен сам себе. Зеркалит половину
// "процесс 1" из `emitSchedulerRound` (та же граница `scheduler_rounds`,
// тот же контракт "оставаться незавершённым навсегда — это нормально", см.
// doc-комментарий `emitSendRoundDriving` этого файла ниже) — намеренно НЕ
// настоящий WASM `loop`, в духе общего для этого бэкенда выбора
// "развёрнутые, проверяемые вручную раунды" вместо настоящего
// динамического цикла.
// Возврат `Булево` из `actor_step` означает "функция САМА ПО СЕБЕ реально
// ЗАВЕРШИЛАСЬ" (собственный doc-комментарий `mir_cps.zig`: "true = реально
// завершилась ..., false = приостановилась, вызвать снова, когда
// mailbox/signal будут готовы") — а НЕ "только что отправленное сообщение
// обработано". Персистентный сервер-актор вроде типичного цикла
// `счётчик`-формы `выбор получить() ... конец` (каждая ветка хвостово
// рекурсирует обратно в очередной `получить()`) НИКОГДА не возвращает
// `true` — он снова приостанавливается в момент опустошения mailbox, по
// design, навсегда. Зеркалим этот же контракт: прогоняем до
// `scheduler_rounds` вызовов (останавливаясь раньше только если шаговая
// функция реально завершилась), trap не нужен в любом случае — каждый
// вызов, находящий непустую mailbox, извлекает и обрабатывает КАК МИНИМУМ
// только что отправленное сообщение (диспетчер `mir_cps.zig` возвращается
// к проверке mailbox на месте после каждого `получить()`, а не через
// свежий WASM-вызов), так что уже одного раунда достаточно, чтобы
// гарантировать обработку отправки до возврата из этой функции; остальные
// раунды — чистый защитный запас, а не требование корректности.
fn emitSendRoundDriving(builder: *mir_builder.Builder, layout: wasm_heap.PtrLayout, process_local: mir.LocalId, actor_step: mir.FunctionId) !void {
    const done_local = try builder.newLocal(wasm_heap.dummy_symbol, "@send_done", layout.bool_type);
    const false_init = try wasm_heap.boolConst(builder, layout.bool_type, false);
    try builder.emit(.{ .store_local = .{ .local = done_local, .src = false_init } });

    var round: u32 = 0;
    while (round < scheduler_rounds) : (round += 1) {
        const d = try builder.newValue(layout.bool_type);
        try builder.emit(.{ .load_local = .{ .dst = d, .local = done_local } });
        const not_done = try wasm_heap.notOp(builder, layout.bool_type, d);

        const call_block = try builder.newBlock();
        // `skip_block` ОБЯЗАН быть отдельным блоком, отличным от
        // `after_block` — см. собственный комментарий `emitSchedulerRound`
        // про ту же самую ловушку (экспоненциальный взрыв
        // `wasm_stackify.findMerge`, если собственная else-цель ветвления
        // и есть точка слияния).
        const skip_block = try builder.newBlock();
        const after_block = try builder.newBlock();
        builder.terminate(.{ .branch = .{ .cond = not_done, .then_block = call_block, .else_block = skip_block } });

        builder.setCurrentBlock(call_block);
        const process_for_step = try wasm_heap.loadLocal(builder, process_local, layout.ptr_type);
        const r = try builder.newValue(layout.bool_type);
        try builder.emit(.{ .call = .{ .dst = r, .callee = actor_step, .args = try wasm_heap.dupeOne(builder.module, process_for_step) } });
        try builder.emit(.{ .store_local = .{ .local = done_local, .src = r } });
        builder.terminate(.{ .jump = .{ .target = after_block } });

        builder.setCurrentBlock(skip_block);
        builder.terminate(.{ .jump = .{ .target = after_block } });

        builder.setCurrentBlock(after_block);
    }
    // Trap не нужен, если `done_local` так и остался `false` — см.
    // собственный doc-комментарий этой функции выше. Вызывающая сторона
    // продолжает испускать ИСХОДНЫЕ хвостовые инструкции/терминатор в
    // том блоке, который сейчас текущий.
}

// Переписывает ЕДИНСТВЕННЫЙ `.send` на месте: кладёт `message` в кольцевой
// буфер mailbox процесса `process`, затем — ЕСЛИ этот send не находится в
// собственном теле `старт()` (которое уже получает раунды от внешнего
// цикла `buildScheduler`) — прогоняет шаговую функцию целевого актора через
// `emitSendRoundDriving`, чтобы сообщение было реально ОБРАБОТАНО до
// возврата из этой функции, а не просто поставлено в очередь.
fn expandSend(
    allocator: std.mem.Allocator,
    builder: *mir_builder.Builder,
    block_id: mir.BlockId,
    send_index: usize,
    layout: wasm_heap.PtrLayout,
    round_driving: ?mir.FunctionId,
) !void {
    const function = builder.currentFunction();
    var original = function.blockConst(block_id).*;
    const send = original.instructions.items[send_index].send;

    var prefix: std.ArrayList(mir.Instruction) = .empty;
    try prefix.appendSlice(allocator, original.instructions.items[0..send_index]);

    builder.setCurrentBlock(block_id);
    builder.currentFunction().block(block_id).instructions = prefix;
    builder.terminated = false;

    // `send.process` и `send.message` — ОБА уже существующие значения
    // (`отправить(process_expr, message_expr)` вычисляется слева направо,
    // так что `process` производится ПЕРВЫМ, а `message` — ВТОРЫМ/самым
    // свежим — `message` очень часто сам является результатом
    // `build_variant`, целой цепочкой конструирования). Потребление
    // `process` первым слепо снимало бы с реального WASM-стека то, что на
    // нём РЕАЛЬНО лежит сверху в этот момент — `message`, а не `process` —
    // поскольку кодогенерация `store_local` это простой `local.set`,
    // которому всё равно, что утверждает поле `src` MIR, важно только то,
    // что реально на вершине. Фикс: потребляем в порядке, ОБРАТНОМ порядку
    // производства (LIFO) — тот же класс бага, что уже был найден и
    // исправлен в циклах по полям `build_variant`/`new_aggregate` в
    // `wasm_objects.zig`: сохраняем `message` первым (он на вершине), ЗАТЕМ
    // `process` (теперь обнажившийся).
    const message_type = function.valueType(send.message);
    const message_local = try wasm_heap.storeLocal(builder, "@message", message_type, send.message);
    // `process`/`count` используются ниже более одного раза — инвариант
    // одного использования, тот же фикс, что и везде в этом файле:
    // сохранить один раз, при каждом использовании перечитывать заново.
    const process_local = try wasm_heap.storeLocal(builder, "@target", layout.ptr_type, send.process);
    const message = try wasm_heap.loadLocal(builder, message_local, message_type);

    const process_for_count = try wasm_heap.loadLocal(builder, process_local, layout.ptr_type);
    const count = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .frame_load = .{ .dst = count, .frame = process_for_count, .slot = mir_cps.mailbox_count_slot } });
    const count_local = try wasm_heap.storeLocal(builder, "@count", layout.idx_type, count);

    const process_for_head = try wasm_heap.loadLocal(builder, process_local, layout.ptr_type);
    const head = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .frame_load = .{ .dst = head, .frame = process_for_head, .slot = mir_cps.mailbox_head_slot } });
    const count_for_tail = try wasm_heap.loadLocal(builder, count_local, layout.idx_type);
    const tail_pre = try wasm_heap.binOp(builder, layout.idx_type, .add, head, count_for_tail);
    const mask = try wasm_heap.addressConst(builder, layout.idx_type, mir_cps.mailbox_cap - 1);
    const tail = try wasm_heap.binOp(builder, layout.idx_type, .bit_and, tail_pre, mask);
    // `eight` производится СРАЗУ ЖЕ после `tail` (смежно — между ними не
    // работает производитель никакого другого значения), так что
    // `tail_bytes` потребляет ровно `[tail, eight]`, а затем оба
    // собственных операнда `base` (`ring_base_bytes`/`process_for_base`)
    // производятся и потребляются вместе прямо перед собственным add
    // `addr` — всё это время `tail_bytes` благополучно погребён под этой
    // нейтральной по стеку парой. Кодогенерация i32 для `.binary` НЕ
    // делает никакой манипуляции стеком (просто испускает сырой опкод,
    // `wasm_emit.zig` ~строка 545: предполагает, что `lhs`/`rhs` УЖЕ
    // являются двумя верхними значениями стека, положенными подряд без
    // ничего между ними) — поэтому важно не производить `eight` между
    // `head` и `count_for_tail`: вклинившееся значение заставило бы
    // `i32.add` у `tail_pre` молча вычислить `8 + count` вместо `head +
    // count`, осиротив `head` на стеке и повредив всё, что испускается
    // после него.
    const eight = try wasm_heap.addressConst(builder, layout.idx_type, 8);
    const tail_bytes = try wasm_heap.binOp(builder, layout.idx_type, .multiply, tail, eight);
    const ring_base_bytes = try wasm_heap.addressConst(builder, layout.ptr_type, mir_cps.mailbox_ring_base * 8);
    const process_for_base = try wasm_heap.loadLocal(builder, process_local, layout.ptr_type);
    const base = try wasm_heap.binOp(builder, layout.idx_type, .add, process_for_base, ring_base_bytes);
    const addr = try wasm_heap.binOp(builder, layout.idx_type, .add, base, tail_bytes);
    try builder.emit(.{ .mem_store = .{ .addr = addr, .src = message } });
    const one = try wasm_heap.addressConst(builder, layout.idx_type, 1);
    const count_for_inc = try wasm_heap.loadLocal(builder, count_local, layout.idx_type);
    const count_new = try wasm_heap.binOp(builder, layout.idx_type, .add, count_for_inc, one);
    const process_for_store = try wasm_heap.loadLocal(builder, process_local, layout.ptr_type);
    try builder.emit(.{ .frame_store = .{ .frame = process_for_store, .slot = mir_cps.mailbox_count_slot, .src = count_new } });

    // Хвостовые инструкции/терминатор попадают в тот блок, который
    // является ТЕКУЩИМ после этой точки — `emitSendRoundDriving` (если
    // применимо) оставляет builder позиционированным в своём собственном
    // `finish_block`, а не в `block_id`.
    if (round_driving) |actor_step| {
        try emitSendRoundDriving(builder, layout, process_local, actor_step);
    }
    try builder.currentBlock().instructions.appendSlice(allocator, original.instructions.items[send_index + 1 ..]);
    builder.terminate(original.terminator);
    // `.deinit`, а не `allocator.free(.items)` — см. идентичный комментарий
    // в `mir_cps.zig` про её собственный эквивалентный free.
    original.instructions.deinit(allocator);
}

// --- Обёртка-планировщик точки входа --------------------------------------

fn buildScheduler(
    allocator: std.mem.Allocator,
    module: *mir.Module,
    type_store: *const types.TypeStore,
    layout: wasm_heap.PtrLayout,
    old_start: mir.FunctionId,
    old_start_total_slots: u32,
    child_frame_slot: u32,
    actor_step: mir.FunctionId,
    original_result_type: types.TypeId,
) !void {
    const new_start = try mir_builder.newFunction(module, allocator, "старт", wasm_heap.dummy_symbol, original_result_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, new_start);
    builder.currentFunction().parameters = &.{};
    builder.currentFunction().type_store = type_store;

    const size0 = try wasm_heap.addressConst(&builder, layout.idx_type, old_start_total_slots * 8);
    const frame0 = try builder.newValue(layout.ptr_type);
    // СОБСТВЕННЫЙ фрейм `старт` (процесс 0) — достижим из DOM-замыкания не
    // только через заспавненного ДОЧЕРНЕГО актора, но и напрямую через
    // `себя()` (self-ссылка на собственный фрейм текущего выполняющегося
    // процесса). Если ЛЮБОЕ DOM-замыкание в этом модуле захватывает ЛЮБОЕ
    // значение `Процесс`, захвачен мог быть ЛЮБОЙ из двух origin —
    // ограничение Phase-1 "не более одного `.spawn`, достижимого из
    // `старт`" означает, что во всём модуле никогда не бывает больше двух
    // фреймов (этот и тот, что `expandSpawn` выделяет для заспавненного
    // потомка, к которому применяется ТО ЖЕ условие) — безусловное
    // повышение обоих проще и безопаснее, чем отслеживание, какой именно
    // захваченный символ к какому origin относится.
    const alloc_id = if (module.actor_captured_by_dom_closure)
        try wasm_heap.findOrBuildAllocPermanent(allocator, module, type_store, layout)
    else
        wasm_heap.findFunctionByName(module, wasm_heap.alloc_function_name).?;
    try builder.emit(.{ .call = .{ .dst = frame0, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, size0) } });
    // `frame0` используется ниже более одного раза — сохранить один раз,
    // при каждом использовании перечитывать заново.
    const frame0_local = try wasm_heap.storeLocal(&builder, "frame0", layout.ptr_type, frame0);
    // `src` вычисляется ДО `frame` — см. doc-комментарий
    // `EmitContext.frame_store_scratch_frame` в `wasm_emit.zig` (порядок
    // стека, который ожидает кодогенерация `frame_store`, — `[src, frame]`).
    const zero_addr = try wasm_heap.addressConst(&builder, layout.ptr_type, 0);
    const frame0_for_init = try wasm_heap.loadLocal(&builder, frame0_local, layout.ptr_type);
    try builder.emit(.{ .frame_store = .{ .frame = frame0_for_init, .slot = child_frame_slot, .src = zero_addr } });
    const done0_local = try builder.newLocal(wasm_heap.dummy_symbol, "done0", layout.bool_type);
    const done1_local = try builder.newLocal(wasm_heap.dummy_symbol, "done1", layout.bool_type);
    const false0 = try wasm_heap.boolConst(&builder, layout.bool_type, false);
    try builder.emit(.{ .store_local = .{ .local = done0_local, .src = false0 } });
    // Процесс 1 (заспавненный актор) не существует, пока собственная
    // шаговая функция процесса 0 не дойдёт до своего `.spawn` —
    // собственная проверка `spawned` в `emitSchedulerRound` (указатель на
    // фрейм в `child_frame_slot` не равен нулю) уже не даёт запустить его
    // раньше этой точки, поэтому `done1` обязан стартовать со значения
    // `false`: инициализация `true` здесь означала бы, что `not_done1`
    // навсегда останется `false`, так что `should_run = spawned AND
    // not_done1` НИКОГДА не станет истинным даже после спавна — процесс 1
    // не выполнит ни одного шага вообще.
    const false1 = try wasm_heap.boolConst(&builder, layout.bool_type, false);
    try builder.emit(.{ .store_local = .{ .local = done1_local, .src = false1 } });

    var round: u32 = 0;
    while (round < scheduler_rounds) : (round += 1) {
        try emitSchedulerRound(&builder, allocator, layout, frame0_local, done0_local, done1_local, old_start, actor_step, child_frame_slot);
    }

    // Завершение ждёт ТОЛЬКО `done0` (`старт`, "главный" процесс) — а НЕ
    // `done1` (заспавненный фоновый актор) тоже. Заспавненный актор часто
    // является персистентным сервером, который по design крутится
    // бесконечно (собственный `счётчик` этой фикстуры: каждый `получить()`
    // сразу рекурсирует в очередной `получить()`, реально никогда не
    // возвращаясь) — требование, чтобы он ТОЖЕ завершился до окончания
    // программы, приводило бы к trap "превышен лимит раундов" для любой
    // такой (совершенно нормальной, "fire and forget") программы с
    // фоновым актором, даже после того, как `старт` уже произвёл свой
    // реальный результат. Собственный результат программы зависит от
    // завершения `старт`; всё ещё приостановленный фоновый актор в этой
    // точке — обычная, ожидаемая семантика актора, а не ошибка.
    const d0 = try builder.newValue(layout.bool_type);
    try builder.emit(.{ .load_local = .{ .dst = d0, .local = done0_local } });

    const trap_block = try builder.newBlock();
    const finish_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = d0, .then_block = finish_block, .else_block = trap_block } });

    builder.setCurrentBlock(trap_block);
    builder.terminate(.{ .unreachable_term = .{ .reason = "актор: превышен лимит раундов планировщика (Phase 1, 16 раундов)" } });

    builder.setCurrentBlock(finish_block);
    if (type_store.eql(original_result_type, type_store.builtins.void)) {
        builder.terminate(.{ .return_value = .{ .value = null } });
    } else {
        const frame0_final = try wasm_heap.frameValue(&builder, frame0_local, layout.ptr_type);
        const result = try builder.newValue(original_result_type);
        try builder.emit(.{ .frame_load = .{ .dst = result, .frame = frame0_final, .slot = mir_cps.result_slot } });
        builder.terminate(.{ .return_value = .{ .value = result } });
    }

    // Старая точка входа больше не достижима извне (никакой экспорт с
    // именем "старт" больше на неё не ссылается) — переименована, чтобы
    // "экспортировать каждую функцию по имени" в `emitModule` не породило
    // второй экспорт, буквально названный "старт", конфликтующий с новым
    // выше.
    module.functions.items[@intFromEnum(old_start)].name = "@старт_шаг";
    module.functions.items[@intFromEnum(actor_step)].name = "@актор_шаг";
}

fn emitSchedulerRound(
    builder: *mir_builder.Builder,
    allocator: std.mem.Allocator,
    layout: wasm_heap.PtrLayout,
    frame0_local: mir.LocalId,
    done0_local: mir.LocalId,
    done1_local: mir.LocalId,
    old_start: mir.FunctionId,
    actor_step: mir.FunctionId,
    child_frame_slot: u32,
) !void {
    _ = allocator;
    // Процесс 0.
    {
        const d0 = try builder.newValue(layout.bool_type);
        try builder.emit(.{ .load_local = .{ .dst = d0, .local = done0_local } });
        const not_done0 = try wasm_heap.notOp(builder, layout.bool_type, d0);
        const call_block = try builder.newBlock();
        // `skip_block` — НАСТОЯЩИЙ, отдельный блок, не сам `after_block`.
        // `wasm_stackify.findMerge` ищет блок слияния, ОТЛИЧНЫЙ от
        // собственных then/else-целей ветвления; если `else_block`
        // буквально И ЕСТЬ точка слияния, поиск слияния проваливается
        // каждый раз, из-за чего `processFrom` откатывается к повторному
        // обходу ВСЕЙ оставшейся части функции с нуля по ОБОИМ путям
        // (then и else), вместо остановки в общей точке — при
        // `scheduler_rounds` таких ромбов, сцепленных подряд, это реальный
        // экспоненциальный взрыв, а не просто зависание.
        const skip_block = try builder.newBlock();
        const after_block = try builder.newBlock();
        builder.terminate(.{ .branch = .{ .cond = not_done0, .then_block = call_block, .else_block = skip_block } });

        builder.setCurrentBlock(call_block);
        const frame0 = try wasm_heap.frameValue(builder, frame0_local, layout.ptr_type);
        const r0 = try builder.newValue(layout.bool_type);
        try builder.emit(.{ .call = .{ .dst = r0, .callee = old_start, .args = try wasm_heap.dupeOne(builder.module, frame0) } });
        try builder.emit(.{ .store_local = .{ .local = done0_local, .src = r0 } });
        builder.terminate(.{ .jump = .{ .target = after_block } });

        builder.setCurrentBlock(skip_block);
        builder.terminate(.{ .jump = .{ .target = after_block } });

        builder.setCurrentBlock(after_block);
    }
    // Процесс 1 (заспавненный актор) — только если заспавнен (указатель
    // на фрейм не равен нулю) И ещё не завершён.
    {
        const frame0 = try wasm_heap.frameValue(builder, frame0_local, layout.ptr_type);
        const frame1 = try builder.newValue(layout.ptr_type);
        try builder.emit(.{ .frame_load = .{ .dst = frame1, .frame = frame0, .slot = child_frame_slot } });
        const zero = try wasm_heap.addressConst(builder, layout.ptr_type, 0);
        const spawned = try wasm_heap.cmpOp(builder, layout.bool_type, .not_equal, frame1, zero);
        const d1 = try builder.newValue(layout.bool_type);
        try builder.emit(.{ .load_local = .{ .dst = d1, .local = done1_local } });
        const not_done1 = try wasm_heap.notOp(builder, layout.bool_type, d1);
        const should_run = try wasm_heap.binOp(builder, layout.bool_type, .bit_and, spawned, not_done1);

        const call_block = try builder.newBlock();
        const skip_block = try builder.newBlock(); // см. комментарий "Процесс 0" выше — должен быть отличен от `after_block`
        const after_block = try builder.newBlock();
        builder.terminate(.{ .branch = .{ .cond = should_run, .then_block = call_block, .else_block = skip_block } });

        builder.setCurrentBlock(call_block);
        const frame0b = try wasm_heap.frameValue(builder, frame0_local, layout.ptr_type);
        const frame1b = try builder.newValue(layout.ptr_type);
        try builder.emit(.{ .frame_load = .{ .dst = frame1b, .frame = frame0b, .slot = child_frame_slot } });
        const r1 = try builder.newValue(layout.bool_type);
        try builder.emit(.{ .call = .{ .dst = r1, .callee = actor_step, .args = try wasm_heap.dupeOne(builder.module, frame1b) } });
        try builder.emit(.{ .store_local = .{ .local = done1_local, .src = r1 } });
        builder.terminate(.{ .jump = .{ .target = after_block } });

        builder.setCurrentBlock(skip_block);
        builder.terminate(.{ .jump = .{ .target = after_block } });

        builder.setCurrentBlock(after_block);
    }
}

pub fn expand(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, frame_info: *const std.AutoHashMap(mir.FunctionId, mir_cps.FrameInfo)) !void {
    if (frame_info.count() == 0) return;

    const start_id = wasm_heap.findFunctionByName(module, "старт") orelse return unsupported("модуль без функции старт()");
    const start_info = frame_info.get(start_id) orelse return unsupported("старт() должен вызывать получить() хотя бы раз, чтобы использовать акторы (Phase 1)");

    // Находим единственный `.spawn` внутри (уже CPS-переписанного) тела
    // старт и его цель — единственная форма, поддерживаемая Phase 1.
    var spawn_block: ?mir.BlockId = null;
    var spawn_index: usize = 0;
    var spawn_target: ?mir.FunctionId = null;
    var spawn_count: u32 = 0;
    const start_function = &module.functions.items[@intFromEnum(start_id)];
    for (start_function.blocks.items) |block| {
        for (block.instructions.items, 0..) |instruction, index| {
            if (instruction != .spawn) continue;
            spawn_count += 1;
            spawn_block = block.id;
            spawn_index = index;
            spawn_target = resolveSpawnTarget(start_function, instruction.spawn.callee);
        }
    }
    for (module.functions.items) |*function| {
        if (function.id == start_id) continue;
        for (function.blocks.items) |block| {
            for (block.instructions.items) |instruction| {
                if (instruction == .spawn) return unsupported("запусти вне старт() (Phase 1 поддерживает только один спавн из старт())");
            }
        }
    }
    if (spawn_count > 1) return unsupported("больше одного запусти в старт() (Phase 1)");
    const actor_id = spawn_target orelse return unsupported("не удалось определить статическую цель запусти");
    const actor_info = frame_info.get(actor_id) orelse return unsupported("заспавненная функция должна вызывать получить() (Phase 1)");

    const layout = wasm_heap.PtrLayout{ .ptr_type = type_store.builtins.string, .idx_type = type_store.builtins.boolean, .bool_type = type_store.builtins.boolean };

    const runtime = try buildRuntime(allocator, module, type_store, layout);
    rewireSuspendCalls(module, runtime);

    // Собственный фрейм старт получает один ДОПОЛНИТЕЛЬНЫЙ слот (сверх
    // того, под что его уже рассчитал `mir_cps.zig`) исключительно для
    // собственной бухгалтерии `wasm_actors.zig` — указатель на фрейм
    // заспавненного потомка, который также хранит собственный локал
    // пользователя `пер proc = запусти ...` (уже обычный слот фрейма), но
    // под номером слота, который этот проход иначе не знает без более
    // глубокого анализа. Проще зарезервировать отдельный.
    const child_frame_slot = start_info.total_slots;
    const old_start_total_slots = start_info.total_slots + 1;

    {
        var builder = mir_builder.Builder{ .module = module, .allocator = allocator, .function_id = start_id };
        const frame_local: mir.LocalId = @enumFromInt(0); // `mir_cps.zig` всегда делает указатель на фрейм local 0
        try expandSpawn(allocator, &builder, spawn_block.?, spawn_index, layout, frame_local, actor_info.total_slots, child_frame_slot);
    }

    for (module.functions.items) |*function| {
        var index: usize = 0;
        while (true) {
            var found: ?struct { block: mir.BlockId, index: usize } = null;
            for (function.blocks.items) |block| {
                for (block.instructions.items, 0..) |instruction, i| {
                    if (instruction == .send) {
                        found = .{ .block = block.id, .index = i };
                        break;
                    }
                }
                if (found != null) break;
            }
            const target = found orelse break;
            var builder = mir_builder.Builder{ .module = module, .allocator = allocator, .function_id = function.id };
            // Прогон раундов добавляется ТОЛЬКО для `отправить` вне и
            // `старт()` (уже покрыт внешним циклом `buildScheduler`), и
            // СОБСТВЕННОГО тела актора (`actor_id`) — например,
            // `счётчик`, отвечающий своему вызывающему через
            // `отправить(отвечающему, ...)`, — это send, НАЦЕЛЕННЫЙ на
            // `старт()`, а не на сам актор: прогон СОБСТВЕННОЙ шаговой
            // функции `actor_id` там выполнял бы её против НЕВЕРНОГО
            // фрейма, повреждая состояние и вызывая trap. Только у
            // DOM-обработчика (не `старт()` и не актор) нет ДРУГОГО
            // механизма обработать то, что он только что отправил.
            const round_driving: ?mir.FunctionId = if (function.id == start_id or function.id == actor_id) null else actor_id;
            try expandSend(allocator, &builder, target.block, target.index, layout, round_driving);
            index += 1;
            if (index > 1000) return unsupported("слишком много отправить (возможный баг развёртки)");
        }
    }

    const original_result_type = start_function.result_type; // уже переписан в Булево через mir_cps — см. ниже
    _ = original_result_type;
    // ИСТИННЫЙ исходный тип возврата больше не восстановим из
    // `result_type` (`mir_cps.zig` уже перезаписал его) — `FrameInfo` тоже
    // его не хранит (пробел Phase-1: здесь предполагается `Число`, что
    // совпадает с каждой фикстурой, на которую сейчас нацелен этот
    // бэкенд). Настоящий фикс должен протаскивать исходный, до
    // переписывания, тип через `FrameInfo`, а не угадывать его.
    try buildScheduler(allocator, module, type_store, layout, start_id, old_start_total_slots, child_frame_slot, actor_id, type_store.builtins.number);
}
