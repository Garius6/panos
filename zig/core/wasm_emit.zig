const std = @import("std");
const mir = @import("mir.zig");
const mir_cps = @import("mir_cps.zig");
const mir_cfg = @import("mir_cfg.zig");
const mir_validate = @import("mir_validate.zig");
const type_checker = @import("type_checker.zig");
const types = @import("types.zig");
const wasm_module = @import("wasm_module.zig");
const wasm_stackify = @import("wasm_stackify.zig");
const wasm_heap = @import("wasm_heap.zig");

// Область действия строго ограничена тем, что может произвести
// `mir_lowering.zig` (см. собственную заметку об области видимости в
// этом файле): числовые/булевы константы, локальные переменные,
// арифметические/сравнивающие/унарные операторы, `если`/`пока`, прямые
// вызовы функций, `возврат`. Нет агрегатов/массивов/карт/интерфейсов/
// замыканий/оператора `?`/строк — для них нужен рантайм с таблицей
// объектов, которого здесь пока нет. Всё, что встречается в MIR за
// пределами этого набора — баг понижения (lowering), а не пробел в
// генерации кода: MIR в принципе не может это содержать (`unsupported`
// в `mir_lowering.zig` паникует раньше, чем такая инструкция вообще
// будет построена).

const ScopeKind = enum { loop, if_scope };
const Scope = struct { kind: ScopeKind, header: mir.BlockId = mir.invalid_block };

// Сериализует сигнатуру WASM-функции (типы параметров + опциональный
// тип результата) в байтовый ключ для `StringHashMap` — используется,
// чтобы дать КАЖДОЙ функции, вызываемой через таблицу интерфейса, ОБЩИЙ
// индекс типа для её структурной формы, вместо обычной схемы
// "один тип на функцию", которую использует остальной код в этом файле.
// `call_indirect` проверяет СОБСТВЕННЫЙ индекс типа реального вызываемого
// объекта в секции типов против literal typeidx, зашитого в место
// вызова — он НЕ делает структурное сопоставление между отдельными (даже
// побайтово идентичными) записями типов, поэтому разные конкретные
// реализации одного и того же метода интерфейса (разные функции, значит
// разные индивидуальные индексы типов при обычной схеме) заставили бы
// `call_indirect` паниковать (trap) для всех реализаций, кроме той,
// чей индекс случайно совпал с использованным в месте вызова. `0xFE`
// отделяет параметры от байта результата (`0xFD` для void) — ни один не
// пересекается с `wasm_i32`(0x7F)/`wasm_f64`(0x7C), единственными двумя
// типами значений WASM, которые генерирует этот бэкенд.
fn signatureShapeKey(allocator: std.mem.Allocator, params: []const u8, result: ?u8) ![]u8 {
    var key: std.ArrayList(u8) = .empty;
    try key.appendSlice(allocator, params);
    try key.append(allocator, 0xFE);
    try key.append(allocator, result orelse 0xFD);
    return try key.toOwnedSlice(allocator);
}

// Используется обоими сканами `emitModule`, собирающими формы (функции-
// члены таблицы интерфейса и требуемая форма каждого места вызова
// `.call_value`) — регистрирует одну новую запись в секции типов для
// КАЖДОЙ РАЗЛИЧНОЙ формы, не-операция если уже зарегистрирована.
// `total_functions` — это `module.functions.items.len` (общие записи
// секции типов начинаются сразу после собственной уникальной записи
// каждой обычной функции).
fn registerInterfaceShape(
    allocator: std.mem.Allocator,
    interface_type_index: *std.StringHashMap(u32),
    interface_shape_types: *std.ArrayList(u8),
    interface_shape_count: *u32,
    builtin_count: usize,
    total_functions: usize,
    params: []const u8,
    result: ?u8,
) !void {
    const key = try signatureShapeKey(allocator, params, result);
    if (interface_type_index.contains(key)) {
        allocator.free(key);
        return;
    }
    try interface_type_index.put(key, @as(u32, @intCast(builtin_count)) + @as(u32, @intCast(total_functions)) + interface_shape_count.*);
    interface_shape_count.* += 1;
    interface_shape_types.append(allocator, 0x60) catch unreachable; // functype
    try wasm_module.writeUleb128(interface_shape_types, allocator, params.len);
    try interface_shape_types.appendSlice(allocator, params);
    try wasm_module.writeUleb128(interface_shape_types, allocator, if (result != null) 1 else 0);
    if (result) |result_type| try interface_shape_types.append(allocator, result_type);
}

const EmitContext = struct {
    allocator: std.mem.Allocator,
    checked: *const type_checker.CheckResult,
    type_store: *const types.TypeStore,
    function: *const mir.Function,
    func_index: *const std.AutoHashMap(mir.FunctionId, u32),
    cfg: mir_cfg.CfgInfo,
    rpo_index: std.AutoHashMap(mir.BlockId, usize),
    idom: std.AutoHashMap(mir.BlockId, mir.BlockId),
    visited: std.AutoHashMap(mir.BlockId, void),
    scope_stack: std.ArrayList(Scope) = .empty,
    code: std.ArrayList(u8) = .empty,
    // У `Function_Ref_Instr` нет собственного представления на стеке WASM
    // (пока нет поддержки замыканий/таблиц) — он всегда только питает
    // СТАТИЧЕСКИ известный `call_value` сразу после себя (это единственная
    // форма, которую `lowerCall` в `mir_lowering.zig` вообще производит).
    // Записывается здесь вместо того, чтобы попадать на стек WASM;
    // `call_value` ищет здесь вызываемую функцию и генерирует прямой `call`.
    value_to_function: std.AutoHashMap(mir.ValueId, mir.FunctionId),
    use_count: std.AutoHashMap(mir.ValueId, u32),
    // "модуль::имя" из `call_builtin` (строки `time_now`/`time_monotonic`)
    // → индекс импортируемой функции WASM — пусто для любого модуля,
    // который никогда не вызывает builtin (обычный случай; см.
    // `collectBuiltinNames`).
    builtin_index: *const std.StringHashMap(u32),
    // Каждый строковый КОНСТАНТНЫЙ литерал модуля → его байтовое смещение
    // в собственной статической секции данных модуля (см.
    // `collectStringConstants`) — пусто для любого модуля без строковых
    // литералов вообще.
    string_offsets: *const std.StringHashMap(u32),
    // `signatureShapeKey(params, result) -> общий индекс в секции типов` —
    // заполняется только для модулей с непустой таблицей функций
    // интерфейса; собственная кодогенерация `.call_indirect` ищет здесь
    // форму (args, dst) своего места вызова, чтобы найти ТОТ ЖЕ общий
    // индекс типа, который функциям-членам таблицы присвоили переопределения
    // секции Function в `emitModule`.
    interface_type_index: *const std.StringHashMap(u32),
    // Резервируется лениво при первой потребности функции в `%`/побитовых
    // операциях (см. случаи `.modulo`/`.bit_*`/`.shift_*` в `.binary`) —
    // у f64 в WASM вообще нет инструкций modulo/побитовых операций, только
    // у i32/i64, а числа Phase-1a единообразно представлены как f64 (см.
    // собственный комментарий `.binary` об этом соглашении). Преобразование
    // ОБОИХ операндов в i32 требует scratch-локали: оба уже живут на стеке
    // значений WASM к моменту выполнения этой инструкции (стековая машина —
    // нет способа добраться до НИЖНЕГО, `lhs`, не вытолкнув сначала верхний,
    // `rhs`, куда-то). Одной локали хватает на всю функцию — каждое
    // использование полностью потребляется (сохраняется и сразу же
    // перезагружается) перед следующим, без пересечений. Объявляется в
    // секции локальных переменных функции в `emitFunctionWasm` только если
    // `scratch_i32_local != null` после того, как тело полностью
    // сгенерировано (её индекс фиксируется в момент первого резервирования:
    // `function.locals.items.len`, то есть сразу за каждой реальной
    // локалью MIR).
    scratch_i32_local: ?u32 = null,
    // `frame_store` (вывод CPS-переписывания `mir_cps.zig`, и
    // вручную построенные функции `wasm_actors.zig`) должен вычислить
    // АДРЕС (frame + slot*8, реальная арифметика i32). Реальный порядок
    // стека в этом месте инструкции: `[src, frame]` — `frame` это
    // значение, которое ОБА вызывающих строят через свежий вызов
    // `frameValue()`/`loadLocal()`, генерируемый непосредственно рядом с
    // этой инструкцией (поэтому это всегда ПОСЛЕДНЕЕ, то есть самое
    // верхнее, что попадает на стек), тогда как `src` очень часто —
    // значение, произведённое намного РАНЬШЕ (например, при превращении
    // существующего `store_local{src}` в `frame_store` — собственный
    // производитель `src` находится там, где он уже был в потоке
    // инструкций, и его нельзя переместить) — обратный порядок по
    // сравнению с соглашением "операнды предварительно помещаются в
    // порядке объявления полей", на которое опираются `.binary` и другие.
    // Требуются ДВЕ живые scratch-локали одновременно (сначала вытолкнуть
    // frame сверху, затем src, чтобы адресная арифметика работала на
    // чистом стеке) — `frame` всегда `ptr_type` (i32), тип WASM для `src`
    // (i32-хэндл или f64-число) зависит от того, что сохраняется, поэтому
    // (как и `scratch_i32_local` выше) нужна одна локаль на тип src ПЛЮС
    // одна выделенная под frame; объявляется только если функция
    // действительно содержит `frame_store`.
    frame_store_scratch_frame: ?u32 = null,
    frame_store_scratch_i32: ?u32 = null,
    frame_store_scratch_f64: ?u32 = null,

    fn reserveScratchLocal(self: *EmitContext) u32 {
        if (self.scratch_i32_local) |index| return index;
        const index: u32 = @intCast(self.function.locals.items.len);
        self.scratch_i32_local = index;
        return index;
    }

    fn nextFrameStoreScratchIndex(self: *const EmitContext) u32 {
        var index: u32 = @intCast(self.function.locals.items.len);
        if (self.scratch_i32_local != null) index += 1;
        if (self.frame_store_scratch_frame != null) index += 1;
        if (self.frame_store_scratch_i32 != null) index += 1;
        if (self.frame_store_scratch_f64 != null) index += 1;
        return index;
    }

    fn reserveFrameScratch(self: *EmitContext) u32 {
        if (self.frame_store_scratch_frame) |index| return index;
        const index = self.nextFrameStoreScratchIndex();
        self.frame_store_scratch_frame = index;
        return index;
    }

    fn reserveFrameStoreScratch(self: *EmitContext, wasm_type: u8) u32 {
        if (wasm_type == wasm_module.wasm_i32) {
            if (self.frame_store_scratch_i32) |index| return index;
        } else {
            if (self.frame_store_scratch_f64) |index| return index;
        }
        const index = self.nextFrameStoreScratchIndex();
        if (wasm_type == wasm_module.wasm_i32) {
            self.frame_store_scratch_i32 = index;
        } else {
            self.frame_store_scratch_f64 = index;
        }
        return index;
    }

    fn init(allocator: std.mem.Allocator, checked: *const type_checker.CheckResult, function: *const mir.Function, func_index: *const std.AutoHashMap(mir.FunctionId, u32), builtin_index: *const std.StringHashMap(u32), string_offsets: *const std.StringHashMap(u32), interface_type_index: *const std.StringHashMap(u32)) !EmitContext {
        var cfg = try mir_cfg.computeCfgInfo(allocator, function);
        errdefer cfg.deinit();
        var rpo_index = try wasm_stackify.buildRpoIndex(allocator, &cfg);
        errdefer rpo_index.deinit();
        var idom = try wasm_stackify.computeIdom(allocator, function, &cfg, &rpo_index);
        errdefer idom.deinit();
        const use_count = try computeUseCount(allocator, function);
        return .{
            .allocator = allocator,
            .checked = checked,
            .type_store = function.type_store orelse &checked.types,
            .function = function,
            .func_index = func_index,
            .cfg = cfg,
            .rpo_index = rpo_index,
            .idom = idom,
            .visited = .init(allocator),
            .value_to_function = .init(allocator),
            .use_count = use_count,
            .builtin_index = builtin_index,
            .string_offsets = string_offsets,
            .interface_type_index = interface_type_index,
        };
    }

    fn deinit(self: *EmitContext) void {
        self.use_count.deinit();
        self.value_to_function.deinit();
        self.code.deinit(self.allocator);
        self.scope_stack.deinit(self.allocator);
        self.visited.deinit();
        self.idom.deinit();
        self.rpo_index.deinit();
        self.cfg.deinit();
        self.* = undefined;
    }
};

// То же обращение, что и с `unsupported()` в `mir_lowering.zig` (см.
// doc-комментарий того файла) — возвращает управляемую ошибку вместо
// краша всего процесса `panos build --target=wasm` со стек-трейсом Zig
// при любом пробеле в кодогенерации Phase-1a. `cli/main.zig` уже
// оборачивает `emitModule(...)` в `catch |err| { print; exit(1); }`.
fn unsupported(comptime what: []const u8) error{WasmEmitUnsupported} {
    std.debug.print("panos build: AOT (wasm) кодогенерация не поддерживает — " ++ what ++ "\n", .{});
    return error.WasmEmitUnsupported;
}

fn countUse(counts: *std.AutoHashMap(mir.ValueId, u32), value: mir.ValueId) !void {
    const entry = try counts.getOrPutValue(value, 0);
    entry.value_ptr.* += 1;
}

// Только те формы операндов, которые может содержать MIR Phase-1a — см.
// собственный doc-комментарий этого файла о том, почему исчерпывающий
// switch по `mir.Instruction`/`mir.Terminator` не нужен (lowering
// никогда не производит ничего другого).
fn computeUseCount(allocator: std.mem.Allocator, function: *const mir.Function) !std.AutoHashMap(mir.ValueId, u32) {
    var counts: std.AutoHashMap(mir.ValueId, u32) = .init(allocator);
    for (function.blocks.items) |block| {
        for (block.instructions.items) |instruction| {
            switch (instruction) {
                .store_local => |store| try countUse(&counts, store.src),
                .binary => |binary| {
                    try countUse(&counts, binary.lhs);
                    try countUse(&counts, binary.rhs);
                },
                .compare => |compare| {
                    try countUse(&counts, compare.lhs);
                    try countUse(&counts, compare.rhs);
                },
                .unary => |unary| try countUse(&counts, unary.src),
                .call_value => |call| {
                    try countUse(&counts, call.callee);
                    for (call.args) |arg| try countUse(&counts, arg);
                },
                .call_indirect => |call| {
                    try countUse(&counts, call.table_index);
                    for (call.args) |arg| try countUse(&counts, arg);
                },
                .call_builtin => |call| for (call.args) |arg| try countUse(&counts, arg),
                .new_aggregate => |aggregate| for (aggregate.elements) |element| try countUse(&counts, element),
                .get_property => |property| try countUse(&counts, property.object),
                .set_property => |property| {
                    try countUse(&counts, property.object);
                    try countUse(&counts, property.value);
                },
                .new_array => |array| for (array.elements) |element| try countUse(&counts, element),
                .get_index => |index| {
                    try countUse(&counts, index.object);
                    try countUse(&counts, index.index);
                },
                .set_index => |index| {
                    try countUse(&counts, index.object);
                    try countUse(&counts, index.index);
                    try countUse(&counts, index.value);
                },
                .build_variant => |variant| for (variant.fields) |field| try countUse(&counts, field),
                .match_tag => |match| try countUse(&counts, match.subject),
                .get_variant_field => |field| try countUse(&counts, field.subject),
                .frame_load => |load| try countUse(&counts, load.frame),
                .frame_store => |store| {
                    try countUse(&counts, store.frame);
                    try countUse(&counts, store.src);
                },
                .call => |call| for (call.args) |arg| try countUse(&counts, arg),
                .global_set => |set| try countUse(&counts, set.src),
                .memory_grow => |v| try countUse(&counts, v.pages),
                .mem_load => |load| try countUse(&counts, load.addr),
                .mem_store => |store| {
                    try countUse(&counts, store.addr);
                    try countUse(&counts, store.src);
                },
                .mem_load8 => |load| try countUse(&counts, load.addr),
                .mem_store8 => |store| {
                    try countUse(&counts, store.addr);
                    try countUse(&counts, store.src);
                },
                .const_value, .load_local, .function_ref, .global_get, .memory_size => {},
                else => return unsupported("вид MIR-инструкции при подсчёте использований"),
            }
        }
        switch (block.terminator) {
            .branch => |branch| try countUse(&counts, branch.cond),
            .return_value => |return_term| if (return_term.value) |value| try countUse(&counts, value),
            .jump, .unreachable_term, .none, .suspend_return => {},
        }
    }
    return counts;
}

fn findBrDepth(ctx: *EmitContext, target: mir.BlockId) !usize {
    var i = ctx.scope_stack.items.len;
    while (i > 0) {
        i -= 1;
        const scope = ctx.scope_stack.items[i];
        if (scope.kind == .loop and scope.header == target) return (ctx.scope_stack.items.len - 1) - i;
    }
    return unsupported("br-цель не найдена среди открытых scope (нарушен структурный инвариант)");
}

const ProcessOutcome = struct { fallthrough: mir.BlockId, ok: bool };

// Генерирует блок `start` и всё, что структурно принадлежит его региону,
// до `stop_at` (граница, уже известная вызывающей стороне) или
// Return/Unreachable/обратного ребра. Возвращает `{stop_at, true}`, если
// регион обычным образом проваливается в `stop_at` (вызывающая сторона
// продолжает оттуда), иначе `{_, false}` — каждый путь в регионе либо
// вернул значение/запаниковал, либо ушёл в цикл через `br`.
// `anyerror`, не выводимый автоматически — `processFrom`/`emitBranch`
// теперь взаимно рекурсивны (случай заголовка цикла может вызвать
// `emitBranch`, который вызывает `processFrom`), а Zig не может вывести
// набор ошибок через цикл зависимостей между двумя функциями.
fn processFrom(ctx: *EmitContext, start: mir.BlockId, stop_at: mir.BlockId) anyerror!ProcessOutcome {
    var b = start;
    while (true) {
        if (b == stop_at) return .{ .fallthrough = b, .ok = true };

        if (wasm_stackify.isLoopHeader(&ctx.cfg, &ctx.rpo_index, b) and !ctx.visited.contains(b)) {
            try ctx.visited.put(b, {});
            const block = ctx.function.blockConst(b);
            const branch = switch (block.terminator) {
                .branch => |value| value,
                else => return unsupported("loop header без branch-terminator'а"),
            };

            try ctx.code.appendSlice(ctx.allocator, &.{ 0x03, 0x40 }); // loop (empty blocktype)
            try ctx.scope_stack.append(ctx.allocator, .{ .kind = .loop, .header = b });
            // Собственные инструкции заголовка (вычисление cond) идут
            // ВНУТРИ цикла, а не до него — cond является частью тела
            // цикла (`пока cond цикл`), его нужно пересчитывать каждую
            // итерацию через `br 0` обратно к началу цикла, а не один раз
            // перед первым входом.
            try emitBlockInstructions(ctx, block);

            // Предположение `identifyLoopBodyAndExit` — ровно ОДНА сторона
            // собственного branch заголовка уходит назад (тело), другая
            // проваливается в блок после цикла (выход) — выполняется для
            // каждого обычного цикла `пока` (`lowerWhile` в
            // `mir_lowering.zig` производит только эту форму
            // "одно тело — один выход"). Оно НЕ выполняется для заголовка
            // цикла диспетчеризации `mir_cps.zig`: самохвостовой вызов
            // может заставить ОБЕ ветви в итоге уйти назад (или
            // вернуть/приостановить выполнение глубоко внутри), без
            // какого-либо CFG-ребра к "после цикла" вообще. Проверяется
            // напрямую через `canReach` (не через `identifyLoopBodyAndExit`,
            // который не может выразить "обе/ни одна"), поэтому обычный
            // случай ниже остаётся ПОБАЙТОВО ИДЕНТИЧНЫМ — никакого
            // изменения поведения для уже скомпилированных программ.
            const then_reaches_header = try wasm_stackify.canReach(ctx.allocator, ctx.function, branch.then_block, b);
            const else_reaches_header = try wasm_stackify.canReach(ctx.allocator, ctx.function, branch.else_block, b);

            var loop_outcome: ProcessOutcome = undefined;
            if (then_reaches_header != else_reaches_header) {
                const identified: struct { body: mir.BlockId, exit: mir.BlockId } = if (then_reaches_header)
                    .{ .body = branch.then_block, .exit = branch.else_block }
                else
                    .{ .body = branch.else_block, .exit = branch.then_block };
                try ctx.code.appendSlice(ctx.allocator, &.{ 0x04, 0x40 }); // if (empty blocktype)
                try ctx.scope_stack.append(ctx.allocator, .{ .kind = .if_scope });
                // Возврат processFrom(body, ...) намеренно игнорируется:
                // тело ВСЕГДА либо достигает stop_at=exit (например через
                // прервать, возможно из вложенного если/иначе), либо
                // завершается через обратное ребро-br/return/unreachable —
                // в любом случае тело к этому моменту полностью
                // сгенерировано; что именно произошло здесь не важно,
                // exit_block следует в любом случае.
                _ = try processFrom(ctx, identified.body, identified.exit);
                _ = ctx.scope_stack.pop(); // if
                try ctx.code.append(ctx.allocator, 0x05); // else — empty
                try ctx.code.append(ctx.allocator, 0x0B); // end if
                loop_outcome = .{ .fallthrough = identified.exit, .ok = true };
            } else {
                // ОБЕ (или, вырожденно, НИ ОДНА) стороны уходят назад —
                // чистого разделения тело/выход для этого branch не
                // существует. Используется тот же общий механизм
                // объединения/расхождения, который уже применяется для
                // обычных (не заголовочных) branch — по-прежнему вложенный
                // в этот ЖЕ открытый scope `loop`, так что `br`, найденный
                // глубоко внутри любой стороны, всё ещё корректно
                // разрешается через `findBrDepth`.
                loop_outcome = try emitBranch(ctx, b, branch, mir.invalid_block);
            }

            _ = ctx.scope_stack.pop(); // loop
            try ctx.code.append(ctx.allocator, 0x0B); // end loop

            if (!loop_outcome.ok) {
                // Каждый ДРУГОЙ расходящийся путь в этом файле (собственный
                // фолбэк `.branch` при расхождении обеих сторон,
                // `.return_value`, `.unreachable_term`, `.suspend_return`)
                // пишет явный завершающий байт (`return`/`unreachable`)
                // перед тем как сигнализировать `ok = false` наверх — это
                // ЕДИНСТВЕННОЕ место, где это не делалось: собственный
                // внутренний `unreachable` в `emitBranch` (когда ОН не
                // может найти fallthrough) удовлетворяет ТОЛЬКО
                // собственному (void) blocktype блока if/else, а не тому,
                // что идёт ПОСЛЕ закрытия цикла. Без этого байта
                // требование `i32`-результата у функции, способной на
                // приостановку, на собственном завершающем `end` функции
                // оставалось бы без значения на стеке.
                try ctx.code.append(ctx.allocator, 0x00); // unreachable
                return .{ .fallthrough = mir.invalid_block, .ok = false };
            }
            b = loop_outcome.fallthrough;
            continue;
        }

        try ctx.visited.put(b, {});
        const block = ctx.function.blockConst(b);
        try emitBlockInstructions(ctx, block);

        switch (block.terminator) {
            .jump => |jump| {
                if (ctx.visited.contains(jump.target) and wasm_stackify.isLoopHeader(&ctx.cfg, &ctx.rpo_index, jump.target)) {
                    const depth = try findBrDepth(ctx, jump.target);
                    try ctx.code.append(ctx.allocator, 0x0C); // br
                    try wasm_module.writeUleb128(&ctx.code, ctx.allocator, depth);
                    return .{ .fallthrough = mir.invalid_block, .ok = false };
                }
                b = jump.target;
                continue;
            },
            .branch => |branch| {
                const outcome = try emitBranch(ctx, b, branch, stop_at);
                if (!outcome.ok) return .{ .fallthrough = mir.invalid_block, .ok = false };
                b = outcome.fallthrough;
                continue;
            },
            .return_value => {
                try ctx.code.append(ctx.allocator, 0x0F); // return
                return .{ .fallthrough = mir.invalid_block, .ok = false };
            },
            .unreachable_term => {
                try ctx.code.append(ctx.allocator, 0x00); // unreachable
                return .{ .fallthrough = mir.invalid_block, .ok = false };
            },
            .none => return unsupported("блок без terminator'а"),
            // Тот же управляющий опкод, что и у `.return_value` (`0x0F`,
            // WASM `return`), но, В ОТЛИЧИЕ от него, никакая предыдущая
            // инструкция значение не проталкивала — `mir_cps.zig`
            // переписывает тип результата КАЖДОЙ функции, способной на
            // приостановку, в `Булево` (статус done/suspended, см.
            // doc-комментарий `result_slot` в `mir_cps.zig`), поэтому этот
            // terminator сам, здесь же, безусловно, проталкивает статус
            // `false` ("всё ещё выполняется").
            .suspend_return => {
                try ctx.code.append(ctx.allocator, 0x41); // i32.const 0 (false — suspended)
                try wasm_module.writeSleb128(&ctx.code, ctx.allocator, 0);
                try ctx.code.append(ctx.allocator, 0x0F); // return
                return .{ .fallthrough = mir.invalid_block, .ok = false };
            },
        }
    }
}

// Используется для обычных (не заголовочных) терминаторов `.branch`, а
// также для собственного branch заголовка цикла, когда он не имеет
// простой формы "одна сторона зацикливается, другая выходит", которую
// предполагает `identifyLoopBodyAndExit` — см. случай заголовка цикла в
// `processFrom` для объяснения. `stop_at` — точка схождения, если ОБЕ
// стороны действительно проваливаются без объединения через доминирование
// (актуально только для места вызова с обычным branch — вызов из
// заголовка цикла передаёт `mir.invalid_block`, который никогда не может
// совпасть, намеренно: там нет осмысленной внешней границы для отката).
fn emitBranch(ctx: *EmitContext, b: mir.BlockId, branch: anytype, stop_at: mir.BlockId) !ProcessOutcome {
    const merge = wasm_stackify.findMerge(ctx.function, &ctx.idom, b, branch.then_block, branch.else_block);
    const sub_stop = merge orelse stop_at;

    // cond уже на стеке.
    try ctx.code.appendSlice(ctx.allocator, &.{ 0x04, 0x40 }); // if (empty blocktype)
    try ctx.scope_stack.append(ctx.allocator, .{ .kind = .if_scope });
    const then_outcome = try processFrom(ctx, branch.then_block, sub_stop);
    try ctx.code.append(ctx.allocator, 0x05); // else
    const else_outcome = try processFrom(ctx, branch.else_block, sub_stop);
    try ctx.code.append(ctx.allocator, 0x0B); // end if
    _ = ctx.scope_stack.pop();

    if (merge != null) return .{ .fallthrough = merge.?, .ok = true };
    if (then_outcome.ok) return .{ .fallthrough = then_outcome.fallthrough, .ok = true };
    if (else_outcome.ok) return .{ .fallthrough = else_outcome.fallthrough, .ok = true };
    // Этот `if`/`else` эмитируется с пустым (void) blocktype (см. `0x04,
    // 0x40` выше) — это корректно ТОЛЬКО если код, достижимый ХОТЯ БЫ ИЗ
    // ОДНОЙ ветви, может провалиться в собственный `end` блока `if`, не
    // меняя высоту стека. Здесь ни одна из ветвей этого не делает (обе
    // разошлись — `возврат`, `прервать`/`продолжить` или паника —
    // `then_outcome.ok`/`else_outcome.ok` оба false); под это попадает
    // любая реальная расходящаяся форма `если`+`иначе` (чаще всего `если
    // x тогда возврат Y конец` без `иначе`, то есть ЛЮБОЙ ранний возврат).
    // Семантически точка кода сразу после `end` недостижима, но реальные
    // валидаторы WASM (`wat2wasm` и `wasmtime`) НЕ выводят это автоматически
    // из "обе ветви разошлись" — им нужен ЯВНЫЙ маркер `unreachable` здесь,
    // иначе весь модуль отвергается как невалидный (это не ошибка времени
    // выполнения — модуль вообще не ЗАГРУЖАЕТСЯ).
    try ctx.code.append(ctx.allocator, 0x00); // unreachable
    return .{ .fallthrough = mir.invalid_block, .ok = false };
}

// Модели воспроизведения байткода не важно, используется ли `dst`
// инструкции (неиспользуемое значение — просто "мусор", живущий на стеке
// до Return, который отбрасывает весь стек фрейма целиком) — структурный
// валидатор WASM этого не терпит: у каждого block/if/loop/function должна
// быть СТАТИЧЕСКИ сбалансированная высота стека на границах. Поэтому
// значение с нулевым числом использований (см. `computeUseCount` выше)
// сразу же `drop`ится.
fn emitBlockInstructions(ctx: *EmitContext, block: *const mir.Block) !void {
    for (block.instructions.items) |instruction| {
        const dst = try emitMirInstr(ctx, instruction);
        if (dst) |value| {
            if ((ctx.use_count.get(value) orelse 0) == 0) try ctx.code.append(ctx.allocator, 0x1A); // drop
        }
    }
}

fn wasmType(ctx: *EmitContext, value: mir.ValueId) u8 {
    return wasm_module.wasmValTypeForStore(ctx.type_store, ctx.function.valueType(value));
}

// Возвращает `dst` инструкции, если он есть (для проверки drop-if-unused
// у вызывающей стороны) — `function_ref` имеет `dst` в терминах MIR, но
// ничего не проталкивает на реальный стек WASM (см. doc-комментарий
// `EmitContext.value_to_function`), поэтому здесь возвращается `null`,
// несмотря на наличие dst на уровне MIR.
fn emitMirInstr(ctx: *EmitContext, instruction: mir.Instruction) !?mir.ValueId {
    const code = &ctx.code;
    const allocator = ctx.allocator;
    switch (instruction) {
        .const_value => |c| {
            switch (c.value) {
                .number => |n| {
                    try code.append(allocator, 0x44); // f64.const
                    try wasm_module.writeF64Le(code, allocator, n);
                },
                .boolean => |b| {
                    try code.append(allocator, 0x41); // i32.const
                    try wasm_module.writeSleb128(code, allocator, if (b) 1 else 0);
                },
                .string => |s| {
                    // Хэндл литерала НАПРЯМУЮ и есть его смещение в
                    // data-секции — layout с префиксом длины
                    // `[len][bytes]`, который устанавливает
                    // `wasm_strings.zig`, вообще не требует рантайм-
                    // построения для литералов (см. doc-комментарий того
                    // файла). Вызова хоста не требуется.
                    const offset = ctx.string_offsets.get(s) orelse return unsupported("строковая константа без выделенного смещения (баг сборки data-секции)");
                    try code.append(allocator, 0x41); // i32.const
                    try wasm_module.writeSleb128(code, allocator, @intCast(offset));
                },
                .address => |a| {
                    try code.append(allocator, 0x41); // i32.const
                    try wasm_module.writeSleb128(code, allocator, @intCast(a));
                },
            }
            return c.dst;
        },
        .load_local => |load| {
            try code.append(allocator, 0x20); // local.get
            try wasm_module.writeUleb128(code, allocator, @intFromEnum(load.local));
            return load.dst;
        },
        .store_local => |store| {
            try code.append(allocator, 0x21); // local.set
            try wasm_module.writeUleb128(code, allocator, @intFromEnum(store.local));
            return null;
        },
        .binary => |binary| {
            // `expand()` в `wasm_strings.zig` переписывает каждый
            // строково-типизированный `.binary{.add}` в реальный
            // `.call(@string_concat, ...)` ДО того, как эта кодогенерация
            // вообще запускается (тот же инвариант "должно быть развёрнуто
            // до кодогенерации", который уже установлен для struct/array/
            // variant инструкций в `wasm_objects.zig`) — если сюда попал
            // строково-типизированный `.binary`, значит разворачивание
            // где-то было пропущено, это реальный баг, не случай для
            // тихой обработки здесь.
            if (ctx.type_store.eql(ctx.function.valueType(binary.dst), ctx.type_store.builtins.string)) {
                return unsupported("строковая конкатенация должна быть развёрнута wasm_strings.zig до кодогенерации");
            }
            // Пользовательские числа Phase-1a (`Целое`/`Число`) всегда f64
            // (см. комментарий про modulo/побитовые операции ниже) —
            // ДЕЙСТВИТЕЛЬНО i32-типизированный dst встречается только в
            // собственных, вручную построенных рантайм-функциях
            // `wasm_actors.zig` (арифметика head/count/mask кольцевого
            // буфера), никогда — в обычном выводе `mir_lowering.zig`. В
            // этом случае оба операнда уже реальные i32-значения на стеке
            // (никакого преобразования в f64 не нужно вообще — проще, чем
            // путь для f64 ниже, а не просто его вариант).
            if (wasmType(ctx, binary.dst) == wasm_module.wasm_i32) {
                const int_opcode: u8 = switch (binary.op) {
                    .add => 0x6A, // i32.add
                    .subtract => 0x6B, // i32.sub
                    .multiply => 0x6C, // i32.mul
                    .divide, .int_divide => 0x6D, // i32.div_s
                    .modulo => 0x6F, // i32.rem_s
                    .bit_and => 0x71, // i32.and
                    .bit_or => 0x72, // i32.or
                    .bit_xor => 0x73, // i32.xor
                    .shift_left => 0x74, // i32.shl
                    .shift_right => 0x75, // i32.shr_s
                };
                try code.append(allocator, int_opcode);
                return binary.dst;
            }
            switch (binary.op) {
                .modulo, .bit_and, .bit_or, .bit_xor, .shift_left, .shift_right => {
                    // Стек на входе: [lhs_f64, rhs_f64] (оба уже
                    // проталкиваются предыдущими инструкциями — см.
                    // doc-комментарий `scratch_i32_local` о том, почему
                    // scratch-локаль здесь неизбежна). rhs прогоняется
                    // через scratch-локаль, чтобы оба операнда можно было
                    // преобразовать в правильном порядке, затем выполняется
                    // целочисленная операция, результат преобразуется
                    // обратно в f64 (соответствует представлению f64 любой
                    // другой числовой операции Phase-1a).
                    //
                    // i64, а НЕ i32: `Целое` документирован (см.
                    // математика.pns) как точный вплоть до 2^53 в своём
                    // представлении f64 — i32 с потолком ~2.1e9 для этого
                    // категорически недостаточно (например, unix-ms
                    // временная метка из `время.сейчас_мс()` уже ~1.8e12),
                    // а i64 покрывает диапазон с огромным запасом.
                    const scratch = ctx.reserveScratchLocal();
                    try code.append(allocator, 0x21); // local.set scratch  (pops rhs_f64)
                    try wasm_module.writeUleb128(code, allocator, scratch);
                    try code.append(allocator, 0xB0); // i64.trunc_f64_s   (lhs_f64 -> lhs_i64)
                    try code.append(allocator, 0x20); // local.get scratch (push rhs_f64 back)
                    try wasm_module.writeUleb128(code, allocator, scratch);
                    try code.append(allocator, 0xB0); // i64.trunc_f64_s   (rhs_f64 -> rhs_i64)
                    const int_opcode: u8 = switch (binary.op) {
                        .modulo => 0x81, // i64.rem_s
                        .bit_and => 0x83, // i64.and
                        .bit_or => 0x84, // i64.or
                        .bit_xor => 0x85, // i64.xor
                        .shift_left => 0x86, // i64.shl
                        .shift_right => 0x87, // i64.shr_s
                        else => unreachable,
                    };
                    try code.append(allocator, int_opcode);
                    try code.append(allocator, 0xB9); // f64.convert_i64_s
                    return binary.dst;
                },
                else => {},
            }
            const opcode: u8 = switch (binary.op) {
                .add => 0xA0, // f64.add
                .subtract => 0xA1, // f64.sub
                .multiply => 0xA2, // f64.mul
                .divide => 0xA3, // f64.div
                .int_divide => 0xA3, // f64.div, truncated below
                .modulo, .bit_and, .bit_or, .bit_xor, .shift_left, .shift_right => unreachable, // handled above
            };
            try code.append(allocator, opcode);
            if (binary.op == .int_divide) try code.append(allocator, 0x9C); // f64.trunc — toward zero, matches Целое/Целое semantics
            return binary.dst;
        },
        .compare => |compare| {
            // Числа (включая panos `Целое`) используют f64; строки,
            // булевы, variant и агрегаты — непрозрачные i32-хэндлы.
            // Сравнение на равенство последних должно использовать
            // семейство i32 — эмиссия f64.eq для сравнения строк даёт
            // формально невалидный модуль WASM.
            const opcode: u8 = if (wasmType(ctx, compare.lhs) == wasm_module.wasm_i32) switch (compare.op) {
                .less => 0x48, // i32.lt_s
                .greater => 0x4A, // i32.gt_s
                .equal => 0x46, // i32.eq
                .less_equal => 0x4C, // i32.le_s
                .greater_equal => 0x4E, // i32.ge_s
                .not_equal => 0x47, // i32.ne
            } else switch (compare.op) {
                .less => 0x63, // f64.lt
                .greater => 0x64, // f64.gt
                .equal => 0x61, // f64.eq
                .less_equal => 0x65, // f64.le
                .greater_equal => 0x66, // f64.ge
                .not_equal => 0x62, // f64.ne
            };
            try code.append(allocator, opcode);
            return compare.dst;
        },
        .unary => |unary| {
            switch (unary.op) {
                .negate_number => try code.append(allocator, 0x9A), // f64.neg
                .negate_bool => try code.append(allocator, 0x45), // i32.eqz
                .int_trunc => try code.append(allocator, 0x9C), // f64.trunc
                .to_i32 => try code.append(allocator, 0xAA), // i32.trunc_f64_s
                .from_i32 => try code.append(allocator, 0xB7), // f64.convert_i32_s
                .bit_not => return unsupported("побитовое НЕ (вне Phase 1a)"),
            }
            return unary.dst;
        },
        .function_ref => |function_ref| {
            try ctx.value_to_function.put(function_ref.dst, function_ref.function);
            return null;
        },
        // Сюда попадают две формы: (1) СТАТИЧЕСКИ известный вызов именованной
        // функции (обычный случай — быстрые пути ident/method_calls/module-
        // import в `mir_lowering.zig`) — `callee` восходит к `.function_ref`
        // в ЭТОЙ ЖЕ функции, отслеживается в `value_to_function`, и это
        // обычный прямой `call` (косвенность не нужна, и критично важно:
        // `.function_ref` для таких случаев НИЧЕГО не проталкивает на
        // реальный стек, поэтому `call.args` — ЕДИНСТВЕННОЕ реальное
        // содержимое стека, а вызываемая функция разрешается чисто на
        // этапе компиляции через карту). (2) по-настоящему динамическое
        // функциональное ЗНАЧЕНИЕ (`ф(x)`, где `ф` — параметр/поле/локаль,
        // а не статически известная вызываемая функция, либо значение,
        // прошедшее через `storeCalleeLocal`/`reloadCalleeLocal` в
        // `mir_lowering.zig`) — `call_indirect`, тот же механизм, что
        // использует сам `.call_indirect` (общая схема индекса типа по
        // форме). `.function_ref` для ЭТИХ случаев переписывается
        // `wasm_interfaces.zig` в реальную i32-константу индекса таблицы
        // до того, как этот код вообще запускается. Два случая намеренно
        // исключены из этого переписывания и поэтому ДОЛЖНЫ попадать в
        // быстрый путь value_to_function здесь, никогда в call_indirect:
        // (a) собственная вызываемая функция `.spawn` (`resolveSpawnTarget`
        // в `wasm_actors.zig` ищет буквальный непереписанный
        // `.function_ref`), и (b) САМО-рекурсивный вызов, поскольку
        // `wasm_actors.zig` переиспользует/переименовывает СОБСТВЕННЫЙ
        // `FunctionId` функции на месте, превращая её в функцию-планировщик
        // актора — запись таблицы, зарегистрированная под этим FunctionId
        // ДО переименования, указывала бы на НЕПРАВИЛЬНУЮ (пост-
        // переименование) сигнатуру к моменту, когда `emitModule` строит
        // секции Table/Element — trap "indirect call type mismatch"
        // (рекурсивный обработчик актора, вызывающий сам себя; то же
        // исключение в стиле `spawnCallees` из `wasm_interfaces.zig`,
        // распространённое ниже на собственную вызываемую функцию
        // `.call_value`).
        .call_value => |call| {
            for (call.args) |_| {} // аргументы уже на стеке — воспроизведены раньше, по порядку, собственными инструкциями.
            if (ctx.value_to_function.get(call.callee)) |function_id| {
                const function_index = ctx.func_index.get(function_id) orelse return unsupported("функция не найдена в индексе модуля");
                try code.append(allocator, 0x10); // call
                try wasm_module.writeUleb128(code, allocator, function_index);
                return call.dst;
            }
            var params: std.ArrayList(u8) = .empty;
            defer params.deinit(allocator);
            for (call.args) |arg| try params.append(allocator, wasmType(ctx, arg));
            const result: ?u8 = if (call.dst) |dst| wasmType(ctx, dst) else null;
            const key = try signatureShapeKey(allocator, params.items, result);
            defer allocator.free(key);
            const type_index = ctx.interface_type_index.get(key) orelse return unsupported("вызов через динамическое значение: тип не найден в общей таблице типов интерфейса");
            try code.append(allocator, 0x11); // call_indirect
            try wasm_module.writeUleb128(code, allocator, type_index);
            try code.append(allocator, 0x00); // tableidx 0
            return call.dst;
        },
        .call => |call| {
            for (call.args) |_| {} // уже на стеке, то же соглашение, что и у `.call_value`.
            const function_index = ctx.func_index.get(call.callee) orelse return unsupported("функция не найдена в индексе модуля");
            try code.append(allocator, 0x10); // call
            try wasm_module.writeUleb128(code, allocator, function_index);
            return call.dst;
        },
        // Только для WASM, производится исключительно собственным
        // разворачиванием `.invoke_interface` в `wasm_interfaces.zig`.
        // Стек на входе: `[args..., table_index]` — `table_index`
        // (разрешённый в рантайме слот таблицы WASM) должен быть
        // ПОСЛЕДНИМ-произведённым/верхним операндом, что соответствует
        // собственной семантике WASM у `call_indirect` (сначала выталкивает
        // индекс, аргументы под ним по сигнатуре типа). Индекс типа
        // выводится из СОБСТВЕННЫХ MIR-типов `args`/`dst` (никогда из
        // сырого `FunctionId` — вызываемая функция статически не известна),
        // ищется в `interface_type_index` — см. doc-комментарий
        // `signatureShapeKey` о том, почему у каждой кандидатной вызываемой
        // функции ДОЛЖНА уже быть та же самая запись секции типов
        // (переопределение секции Function для членов `interface_table` в
        // `emitModule`).
        .call_indirect => |call| {
            for (call.args) |_| {} // уже на стеке, то же соглашение, что и у `.call`.
            var params: std.ArrayList(u8) = .empty;
            defer params.deinit(allocator);
            for (call.args) |arg| try params.append(allocator, wasmType(ctx, arg));
            const result: ?u8 = if (call.dst) |dst| wasmType(ctx, dst) else null;
            const key = try signatureShapeKey(allocator, params.items, result);
            defer allocator.free(key);
            const type_index = ctx.interface_type_index.get(key) orelse return unsupported("call_indirect: тип не найден в общей таблице типов интерфейса");
            try code.append(allocator, 0x11); // call_indirect
            try wasm_module.writeUleb128(code, allocator, type_index);
            try code.append(allocator, 0x00); // tableidx 0
            return call.dst;
        },
        // Вывод CPS-переписывания (`mir_cps.zig`) — `frame` это непрозрачный
        // i32-адрес в линейной памяти, `slot` — известный на этапе
        // компиляции индекс слова внутри него (8 байт на слот, достаточно
        // и для f64-числа, и для i32-хэндла). `frame` — единственный
        // операнд, уже на стеке (протолкнут собственным производителем до
        // выполнения этой ветви) — переупорядочивание не нужно, в отличие
        // от `frame_store` ниже.
        .frame_load => |load| {
            try code.append(allocator, 0x41); // i32.const slot*8
            try wasm_module.writeSleb128(code, allocator, @as(i64, load.slot) * 8);
            try code.append(allocator, 0x6A); // i32.add
            const dst_type = wasmType(ctx, load.dst);
            try code.append(allocator, if (dst_type == wasm_module.wasm_i32) 0x28 else 0x2B); // i32.load / f64.load
            try wasm_module.writeUleb128(code, allocator, if (dst_type == wasm_module.wasm_i32) 2 else 3); // align
            try wasm_module.writeUleb128(code, allocator, 0); // offset
            return load.dst;
        },
        // И `frame`, и `src` уже протолкнуты (стек: [frame, src]) к моменту
        // выполнения этой ветви — то же соглашение, что и у `.binary`.
        // Чтобы вычислить АДРЕС записи (frame + slot*8), не потеряв `src`,
        // `src` временно паркуется в scratch-локали подходящего типа,
        // адресная арифметика выполняется над теперь-открытым `frame`,
        // затем `src` перезагружается — тот же трюк переупорядочивания
        // через scratch-локаль, что уже используется в операциях
        // modulo/побитовых у `.binary` выше.
        .frame_store => |store| {
            // Стек на входе: [src, frame] — см. doc-комментарий
            // `EmitContext.frame_store_scratch_frame`. Сначала выталкивается
            // frame (он сверху), затем src, чтобы адресная арифметика ниже
            // выполнялась над чистым стеком.
            const frame_scratch = ctx.reserveFrameScratch();
            try code.append(allocator, 0x21); // local.set frame_scratch (pops frame)
            try wasm_module.writeUleb128(code, allocator, frame_scratch);
            const src_type = wasmType(ctx, store.src);
            const value_scratch = ctx.reserveFrameStoreScratch(src_type);
            try code.append(allocator, 0x21); // local.set value_scratch (pops src)
            try wasm_module.writeUleb128(code, allocator, value_scratch);

            try code.append(allocator, 0x20); // local.get frame_scratch
            try wasm_module.writeUleb128(code, allocator, frame_scratch);
            try code.append(allocator, 0x41); // i32.const slot*8
            try wasm_module.writeSleb128(code, allocator, @as(i64, store.slot) * 8);
            try code.append(allocator, 0x6A); // i32.add -> address
            try code.append(allocator, 0x20); // local.get value_scratch (push src back)
            try wasm_module.writeUleb128(code, allocator, value_scratch);
            try code.append(allocator, if (src_type == wasm_module.wasm_i32) 0x36 else 0x39); // i32.store / f64.store
            try wasm_module.writeUleb128(code, allocator, if (src_type == wasm_module.wasm_i32) 2 else 3); // align
            try wasm_module.writeUleb128(code, allocator, 0); // offset
            return null;
        },
        .global_get => |get| {
            try code.append(allocator, 0x23); // global.get
            try wasm_module.writeUleb128(code, allocator, get.global);
            return get.dst;
        },
        .global_set => |set| {
            try code.append(allocator, 0x24); // global.set
            try wasm_module.writeUleb128(code, allocator, set.global);
            return null;
        },
        .memory_size => |v| {
            try code.append(allocator, 0x3F); // memory.size
            try code.append(allocator, 0x00); // memory index (always 0)
            return v.dst;
        },
        .memory_grow => |v| {
            // `pages` уже на стеке, произведён собственной инструкцией.
            try code.append(allocator, 0x40); // memory.grow
            try code.append(allocator, 0x00); // memory index (always 0)
            return v.dst;
        },
        // Единственный операнд (`addr`), уже полностью вычислен и на стеке
        // собственным производителем — арифметика смещения здесь не
        // нужна, в отличие от `frame_load` выше.
        .mem_load => |load| {
            const dst_type = wasmType(ctx, load.dst);
            try code.append(allocator, if (dst_type == wasm_module.wasm_i32) 0x28 else 0x2B); // i32.load / f64.load
            try wasm_module.writeUleb128(code, allocator, if (dst_type == wasm_module.wasm_i32) 2 else 3);
            try wasm_module.writeUleb128(code, allocator, 0);
            return load.dst;
        },
        // Стек на входе: `[src, addr]`, НЕ `[addr, src]` — та же первопричина,
        // что и у `frame_store` выше (`addr` вычисляется заново, вплотную
        // к этой инструкции, каждым текущим вызывающим, тогда как `src`
        // очень часто — уже существующее значение из более раннего кода,
        // например `expandSend` в `wasm_actors.zig`, где `src` — это
        // собственный, уже произведённый операнд `message` инструкции
        // `.send`). Переиспользует ТЕ ЖЕ scratch-локали, что и
        // `frame_store` (`addr` имеет `ptr_type`/i32, точно как `frame`) —
        // эти две инструкции никогда не пересекаются в пределах одного
        // store, так что совместное использование безопасно.
        .mem_store => |store| {
            const addr_scratch = ctx.reserveFrameScratch();
            try code.append(allocator, 0x21); // local.set addr_scratch (pops addr)
            try wasm_module.writeUleb128(code, allocator, addr_scratch);
            const src_type = wasmType(ctx, store.src);
            const value_scratch = ctx.reserveFrameStoreScratch(src_type);
            try code.append(allocator, 0x21); // local.set value_scratch (pops src)
            try wasm_module.writeUleb128(code, allocator, value_scratch);

            try code.append(allocator, 0x20); // local.get addr_scratch
            try wasm_module.writeUleb128(code, allocator, addr_scratch);
            try code.append(allocator, 0x20); // local.get value_scratch
            try wasm_module.writeUleb128(code, allocator, value_scratch);
            try code.append(allocator, if (src_type == wasm_module.wasm_i32) 0x36 else 0x39); // i32.store / f64.store
            try wasm_module.writeUleb128(code, allocator, if (src_type == wasm_module.wasm_i32) 2 else 3);
            try wasm_module.writeUleb128(code, allocator, 0);
            return null;
        },
        // Побайтовые аналоги `mem_load`/`mem_store` выше — те же соглашения
        // о стеке (единственный операнд для load; `[src, addr]` с addr
        // самым свежим для store, те же общие scratch-локали, так как
        // `src` здесь всегда i32), только `i32.load8_u`/`i32.store8`
        // (опкоды `0x2D`/`0x3A`) с байтовым выравниванием (0) вместо
        // словных опкодов/выравнивания выше.
        .mem_load8 => |load| {
            try code.append(allocator, 0x2D); // i32.load8_u
            try wasm_module.writeUleb128(code, allocator, 0); // align (byte)
            try wasm_module.writeUleb128(code, allocator, 0); // offset
            return load.dst;
        },
        .mem_store8 => {
            const addr_scratch = ctx.reserveFrameScratch();
            try code.append(allocator, 0x21); // local.set addr_scratch (pops addr)
            try wasm_module.writeUleb128(code, allocator, addr_scratch);
            const value_scratch = ctx.reserveFrameStoreScratch(wasm_module.wasm_i32);
            try code.append(allocator, 0x21); // local.set value_scratch (pops src)
            try wasm_module.writeUleb128(code, allocator, value_scratch);

            try code.append(allocator, 0x20); // local.get addr_scratch
            try wasm_module.writeUleb128(code, allocator, addr_scratch);
            try code.append(allocator, 0x20); // local.get value_scratch
            try wasm_module.writeUleb128(code, allocator, value_scratch);
            try code.append(allocator, 0x3A); // i32.store8
            try wasm_module.writeUleb128(code, allocator, 0); // align (byte)
            try wasm_module.writeUleb128(code, allocator, 0); // offset
            return null;
        },
        .call_builtin => |call| {
            for (call.args) |_| {} // время.сейчас_мс/монотонно_мс не принимают аргументов — воспроизводить пока нечего.
            const import_index = ctx.builtin_index.get(call.name) orelse return unsupported("call_builtin без соответствующего host-импорта");
            try code.append(allocator, 0x10); // call
            try wasm_module.writeUleb128(code, allocator, import_index);
            return call.dst;
        },
        // `expand()` в `wasm_objects.zig` запускается на каждом модуле ДО
        // этого эмиттера и переписывает каждый из этих девяти видов
        // инструкций в `frame_load`/`frame_store`/`mem_load`/`mem_store`/
        // `.call` — реальный внутримодульный код линейной памяти, ноль
        // host-импортов. Попадание в эту ветвь вообще означает, что
        // `expand()` был пропущен или упустил случай — настоящий баг
        // `wasm_objects.zig`, не обычный пробел "функция ещё не
        // поддерживается" (отражает тот же инвариант, который
        // `mir_cps.zig` документирует для actor-инструкций, никогда не
        // достигающих кодогенерации непереписанными).
        .new_aggregate, .get_property, .set_property, .new_array, .get_index, .set_index, .build_variant, .match_tag, .get_variant_field => return unsupported("структура/массив/вариант должны быть развёрнуты wasm_objects.zig до кодогенерации"),
        else => return unsupported("вид MIR-инструкции"),
    }
}

pub fn emitFunctionWasm(
    allocator: std.mem.Allocator,
    checked: *const type_checker.CheckResult,
    function: *const mir.Function,
    func_index: *const std.AutoHashMap(mir.FunctionId, u32),
    builtin_index: *const std.StringHashMap(u32),
    string_offsets: *const std.StringHashMap(u32),
    interface_type_index: *const std.StringHashMap(u32),
) ![]u8 {
    var ctx = try EmitContext.init(allocator, checked, function, func_index, builtin_index, string_offsets, interface_type_index);
    defer ctx.deinit();

    _ = try processFrom(&ctx, function.entry, mir.invalid_block);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var extra_scratch_count: usize = 0;
    if (ctx.scratch_i32_local != null) extra_scratch_count += 1;
    if (ctx.frame_store_scratch_frame != null) extra_scratch_count += 1;
    if (ctx.frame_store_scratch_i32 != null) extra_scratch_count += 1;
    if (ctx.frame_store_scratch_f64 != null) extra_scratch_count += 1;
    const n_body_locals = function.locals.items.len - function.parameters.len + extra_scratch_count;
    try wasm_module.writeUleb128(&out, allocator, n_body_locals);
    for (function.parameters.len..function.locals.items.len) |i| {
        try wasm_module.writeUleb128(&out, allocator, 1);
        const store = function.type_store orelse &checked.types;
        try out.append(allocator, wasm_module.wasmValTypeForStore(store, function.locals.items[i].type_id));
    }
    // Порядок деклараций должен соответствовать РЕАЛЬНОМУ индексу, под
    // которым каждая scratch-локаль была выдана
    // `reserveScratchLocal`/`reserveFrameScratch`/`reserveFrameStoreScratch`
    // (`nextFrameStoreScratchIndex`) — индексы назначаются в порядке
    // ВСТРЕЧИ (какой бы вид scratch ни понадобился потоку инструкций
    // функции первым, тот и получает наименьший индекс), что НЕ обязательно
    // совпадает с порядком объявления полей scratch_i32_local/frame/i32/f64
    // (например, функция, чей первый `mem_store` имеет f64-типизированный
    // `src`, резервирует `frame_store_scratch_f64` раньше, чем вообще
    // затрагивается `frame_store_scratch_i32`). Эмиссия деклараций в
    // фиксированном порядке полей независимо от этого дала бы локаль по
    // данному индексу с НЕПРАВИЛЬНЫМ типом значения WASM ("type mismatch").
    // Вместо этого присутствующие scratch-локали сортируются по их
    // реально назначенному индексу.
    var scratch_decls: [4]struct { index: u32, wasm_type: u8 } = undefined;
    var scratch_decl_count: usize = 0;
    if (ctx.scratch_i32_local) |index| {
        scratch_decls[scratch_decl_count] = .{ .index = index, .wasm_type = wasm_module.wasm_f64 };
        scratch_decl_count += 1;
    }
    if (ctx.frame_store_scratch_frame) |index| {
        scratch_decls[scratch_decl_count] = .{ .index = index, .wasm_type = wasm_module.wasm_i32 };
        scratch_decl_count += 1;
    }
    if (ctx.frame_store_scratch_i32) |index| {
        scratch_decls[scratch_decl_count] = .{ .index = index, .wasm_type = wasm_module.wasm_i32 };
        scratch_decl_count += 1;
    }
    if (ctx.frame_store_scratch_f64) |index| {
        scratch_decls[scratch_decl_count] = .{ .index = index, .wasm_type = wasm_module.wasm_f64 };
        scratch_decl_count += 1;
    }
    std.mem.sort(@TypeOf(scratch_decls[0]), scratch_decls[0..scratch_decl_count], {}, struct {
        fn lessThan(_: void, a: @TypeOf(scratch_decls[0]), b: @TypeOf(scratch_decls[0])) bool {
            return a.index < b.index;
        }
    }.lessThan);
    for (scratch_decls[0..scratch_decl_count]) |decl| {
        try wasm_module.writeUleb128(&out, allocator, 1);
        try out.append(allocator, decl.wasm_type);
    }
    try out.appendSlice(allocator, ctx.code.items);
    try out.append(allocator, 0x0B); // end функции
    return try out.toOwnedSlice(allocator);
}

// Имя "модуль::имя" из `call_builtin` → нужный ему хост-рантайм-экспорт
// (`pw_now_ms`/`pw_monotonic_ms` из `zig/wasm_runtime/runtime_wasi.zig`/
// `runtime_js.zig`). `время.спать_мс` до этой функции вообще не доходит —
// `lowerTimeBuiltinCall` в `mir_lowering.zig` паникует раньше, чем
// произведёт для него `call_builtin` (только native builtin, не хост-вызов
// AOT WASM).
fn hostImportNameForBuiltin(name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, name, "время::сейчас_мс")) return "pw_now_ms";
    if (std.mem.eql(u8, name, "время::монотонно_мс")) return "pw_monotonic_ms";
    if (std.mem.eql(u8, name, "сеть::http_запрос_sync")) return "pw_http_request_sync";
    // Строковые аргументы `DOM::*` — непрозрачные i32-хэндлы, которые
    // поддерживает JS-хост. `@runtime::строка_литерал` преобразует смещения
    // в data-секции в эти хэндлы, а `@runtime::строка_сложить` создаёт
    // динамические значения.
    if (std.mem.eql(u8, name, "DOM::текст")) return "dom_get_text_num";
    if (std.mem.eql(u8, name, "DOM::установить_текст")) return "dom_set_text_num";
    if (std.mem.eql(u8, name, "DOM::на_клик")) return "dom_on_click";
    if (std.mem.eql(u8, name, "DOM::текст_строка")) return "dom_get_text_string";
    if (std.mem.eql(u8, name, "DOM::установить_текст_строка")) return "dom_set_text_string";
    if (std.mem.eql(u8, name, "DOM::значение_поля")) return "dom_get_input_value";
    if (std.mem.eql(u8, name, "DOM::установить_значение_поля")) return "dom_set_input_value";
    if (std.mem.eql(u8, name, "DOM::создать_и_добавить")) return "dom_create_append";
    if (std.mem.eql(u8, name, "DOM::после_кадра")) return "dom_after_frame";
    if (std.mem.eql(u8, name, "DOM::атрибут")) return "dom_get_attribute";
    if (std.mem.eql(u8, name, "DOM::установить_атрибут")) return "dom_set_attribute";
    if (std.mem.eql(u8, name, "состояние::прочитать")) return "state_read";
    if (std.mem.eql(u8, name, "состояние::записать")) return "state_write";
    if (std.mem.eql(u8, name, "строки::длина")) return "pw_string_length";
    if (std.mem.eql(u8, name, "строки::срез")) return "pw_string_slice";
    if (std.mem.eql(u8, name, "строки::найти")) return "pw_string_find";
    if (std.mem.eql(u8, name, "строки::начинается_с")) return "pw_string_starts_with";
    if (std.mem.eql(u8, name, "строки::заменить")) return "pw_string_replace";
    if (std.mem.eql(u8, name, "строки::разбить")) return "pw_string_split";
    if (std.mem.eql(u8, name, "строки::из_числа")) return "pw_string_from_number";
    if (std.mem.eql(u8, name, "строки::в_число")) return "pw_string_to_number";
    if (std.mem.eql(u8, name, "@runtime::строка_литерал")) return "pw_string_literal";
    if (std.mem.eql(u8, name, "@runtime::строка_сложить")) return "pw_string_concat";
    if (std.mem.startsWith(u8, name, "@runtime::struct_")) return name["@runtime::".len..];
    if (std.mem.startsWith(u8, name, "@runtime::variant_")) return name["@runtime::".len..];
    if (std.mem.startsWith(u8, name, "@runtime::array_")) return name["@runtime::".len..];
    return unsupported("call_builtin с именем без известного host-импорта");
}

const BuiltinSignature = struct { params: []const u8, result: ?u8 };

fn builtinSignature(name: []const u8) !BuiltinSignature {
    if (std.mem.eql(u8, name, "время::сейчас_мс") or std.mem.eql(u8, name, "время::монотонно_мс"))
        return .{ .params = &.{}, .result = wasm_module.wasm_f64 };
    if (std.mem.eql(u8, name, "сеть::http_запрос_sync"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "DOM::текст"))
        return .{ .params = &.{wasm_module.wasm_i32}, .result = wasm_module.wasm_f64 };
    if (std.mem.eql(u8, name, "DOM::установить_текст"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_f64 }, .result = null };
    if (std.mem.eql(u8, name, "DOM::на_клик"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = null };
    if (std.mem.eql(u8, name, "DOM::текст_строка") or std.mem.eql(u8, name, "DOM::значение_поля"))
        return .{ .params = &.{wasm_module.wasm_i32}, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "DOM::установить_текст_строка") or std.mem.eql(u8, name, "DOM::установить_значение_поля"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = null };
    if (std.mem.eql(u8, name, "DOM::создать_и_добавить"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = null };
    if (std.mem.eql(u8, name, "DOM::после_кадра"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = null };
    if (std.mem.eql(u8, name, "DOM::атрибут"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "DOM::установить_атрибут"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = null };
    if (std.mem.eql(u8, name, "состояние::прочитать"))
        return .{ .params = &.{}, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "состояние::записать"))
        return .{ .params = &.{wasm_module.wasm_i32}, .result = null };
    if (std.mem.eql(u8, name, "@runtime::строка_литерал"))
        return .{ .params = &.{wasm_module.wasm_i32}, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "@runtime::строка_сложить"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "строки::длина"))
        return .{ .params = &.{wasm_module.wasm_i32}, .result = wasm_module.wasm_f64 };
    if (std.mem.eql(u8, name, "строки::срез"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_f64, wasm_module.wasm_f64 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "строки::найти"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32, wasm_module.wasm_f64 }, .result = wasm_module.wasm_f64 };
    if (std.mem.eql(u8, name, "строки::начинается_с"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "строки::заменить"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "строки::разбить"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "строки::из_числа"))
        return .{ .params = &.{wasm_module.wasm_f64}, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "строки::в_число"))
        return .{ .params = &.{wasm_module.wasm_i32}, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "@runtime::struct_get_i32"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "@runtime::struct_get_f64"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = wasm_module.wasm_f64 };
    if (std.mem.eql(u8, name, "@runtime::struct_set_i32"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = null };
    if (std.mem.eql(u8, name, "@runtime::struct_set_f64"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_f64, wasm_module.wasm_i32 }, .result = null };
    if (std.mem.startsWith(u8, name, "@runtime::struct_new_")) return try structNewSignature(name["@runtime::struct_new_".len..]);
    if (std.mem.eql(u8, name, "@runtime::variant_new_f")) return .{ .params = &.{ wasm_module.wasm_f64, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "@runtime::variant_new_i")) return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "@runtime::variant_new_ff")) return .{ .params = &.{ wasm_module.wasm_f64, wasm_module.wasm_f64, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "@runtime::variant_new_fi")) return .{ .params = &.{ wasm_module.wasm_f64, wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "@runtime::variant_new_if")) return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_f64, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "@runtime::variant_new_ii")) return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "@runtime::variant_new_")) return .{ .params = &.{wasm_module.wasm_i32}, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "@runtime::array_new"))
        return .{ .params = &.{}, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "@runtime::array_length"))
        return .{ .params = &.{wasm_module.wasm_i32}, .result = wasm_module.wasm_f64 };
    if (std.mem.eql(u8, name, "@runtime::array_append_i32"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = null };
    if (std.mem.eql(u8, name, "@runtime::array_append_f64"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_f64 }, .result = null };
    if (std.mem.eql(u8, name, "@runtime::array_set_i32"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_f64, wasm_module.wasm_i32 }, .result = null };
    if (std.mem.eql(u8, name, "@runtime::array_set_f64"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_f64, wasm_module.wasm_f64 }, .result = null };
    if (std.mem.eql(u8, name, "@runtime::array_get_i32"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_f64 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "@runtime::array_get_f64"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_f64 }, .result = wasm_module.wasm_f64 };
    if (std.mem.eql(u8, name, "@runtime::array_get_or_i32"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_f64, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "@runtime::array_get_or_f64"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_f64, wasm_module.wasm_f64 }, .result = wasm_module.wasm_f64 };
    if (std.mem.eql(u8, name, "@runtime::variant_match"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "@runtime::variant_get_i32"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "@runtime::variant_get_f64"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = wasm_module.wasm_f64 };
    return unsupported("call_builtin с именем без известной сигнатуры импорта");
}

// Каждый РАЗЛИЧНЫЙ строковый литерал, используемый любой функцией в
// `module`, конкатенированный в один blob — каждая запись с ПРЕФИКСОМ
// ДЛИНЫ (`u32` little-endian количество байт, затем сырые байты, без
// нуль-терминатора; собственный doc-комментарий `wasm_strings.zig`
// объясняет, почему именно такой layout ожидает каждая строковая операция,
// литеральная или выделенная в куче). `offsets.get(s)` указывает на
// НАЧАЛО префикса длины, поэтому кодогенерация `.const_value{.string}`
// может превратить литерал напрямую в голый `i32.const <offset>` —
// полностью сформированный строковый хэндл, не требующий НИКАКОЙ рантайм-
// работы, даже вызова хоста. Пусто для модуля вообще без строковых
// литералов.
fn collectStringConstants(allocator: std.mem.Allocator, module: *const mir.Module) !struct {
    data: []u8,
    offsets: std.StringHashMap(u32),
} {
    var offsets: std.StringHashMap(u32) = .init(allocator);
    errdefer offsets.deinit();
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(allocator);
    for (module.functions.items) |function| {
        for (function.blocks.items) |block| {
            for (block.instructions.items) |instruction| {
                switch (instruction) {
                    .const_value => |c| switch (c.value) {
                        .string => |s| {
                            if (!offsets.contains(s)) {
                                try offsets.put(s, @intCast(data.items.len));
                                var len_bytes: [4]u8 = undefined;
                                std.mem.writeInt(u32, &len_bytes, @intCast(s.len), .little);
                                try data.appendSlice(allocator, &len_bytes);
                                try data.appendSlice(allocator, s);
                            }
                        },
                        else => {},
                    },
                    else => {},
                }
            }
        }
    }
    return .{ .data = try data.toOwnedSlice(allocator), .offsets = offsets };
}

// Каждое РАЗЛИЧНОЕ имя builtin, которое вызывает любая функция в `module`,
// в порядке первого появления — в обычном случае (нигде нет вызовов
// builtin) возвращается пустой список, поэтому программа, которая никогда
// не трогает `время.*`, получает WASM-модуль вообще БЕЗ секции импорта
// (хосту не нужно ничего предоставлять для его запуска).
fn collectBuiltinNames(allocator: std.mem.Allocator, module: *const mir.Module) !std.ArrayList([]const u8) {
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(allocator);
    for (module.functions.items) |function| {
        for (function.blocks.items) |block| {
            for (block.instructions.items) |instruction| {
                switch (instruction) {
                    .call_builtin => |call| {
                        try appendBuiltinName(allocator, &seen, &names, call.name);
                    },
                    // Строковые литералы/конкатенация не требуют
                    // host-импорта вообще — `wasm_strings.zig` обрабатывает
                    // оба случая полностью внутримодульно (см. собственный
                    // doc-комментарий того файла). Регистрация здесь
                    // `@runtime::строка_литерал`/`строка_сложить` объявила
                    // бы импорт, который под чистым wasmtime никто не
                    // предоставляет, что провалит инстанциирование, даже
                    // если он реально никогда не вызывается.
                    .const_value => {},
                    .binary => {},
                    .new_aggregate => |aggregate| {
                        try appendBuiltinName(allocator, &seen, &names, try structNewBuiltinName(&function, aggregate.elements));
                    },
                    .get_property => {
                        const getter_name = if (wasm_module.wasmValTypeForStore(function.type_store orelse continue, function.valueType(instruction.get_property.dst)) == wasm_module.wasm_i32) "@runtime::struct_get_i32" else "@runtime::struct_get_f64";
                        try appendBuiltinName(allocator, &seen, &names, getter_name);
                    },
                    .set_property => |property| {
                        const setter_name = if (wasm_module.wasmValTypeForStore(function.type_store orelse continue, function.valueType(property.value)) == wasm_module.wasm_i32) "@runtime::struct_set_i32" else "@runtime::struct_set_f64";
                        try appendBuiltinName(allocator, &seen, &names, setter_name);
                    },
                    .new_array => try appendBuiltinName(allocator, &seen, &names, "@runtime::array_new"),
                    .get_index => |index| {
                        const getter_name = if (wasm_module.wasmValTypeForStore(function.type_store orelse continue, function.valueType(index.dst)) == wasm_module.wasm_i32) "@runtime::array_get_i32" else "@runtime::array_get_f64";
                        try appendBuiltinName(allocator, &seen, &names, getter_name);
                    },
                    .set_index => |index| {
                        const setter_name = if (wasm_module.wasmValTypeForStore(function.type_store orelse continue, function.valueType(index.value)) == wasm_module.wasm_i32) "@runtime::array_set_i32" else "@runtime::array_set_f64";
                        try appendBuiltinName(allocator, &seen, &names, setter_name);
                    },
                    .build_variant => |variant| try appendBuiltinName(allocator, &seen, &names, try variantNewBuiltinName(&function, variant.fields)),
                    .match_tag => try appendBuiltinName(allocator, &seen, &names, "@runtime::variant_match"),
                    .get_variant_field => |field| {
                        const name = if (wasm_module.wasmValTypeForStore(function.type_store orelse continue, function.valueType(field.dst)) == wasm_module.wasm_i32) "@runtime::variant_get_i32" else "@runtime::variant_get_f64";
                        try appendBuiltinName(allocator, &seen, &names, name);
                    },
                    else => {},
                }
            }
        }
    }
    return names;
}

fn structNewBuiltinName(function: *const mir.Function, elements: []const mir.ValueId) ![]const u8 {
    if (elements.len > 3) return unsupported("структура с более чем 3 полями");
    const store = function.type_store orelse return unsupported("структура без TypeStore");
    var mask: u3 = 0;
    for (elements, 0..) |element, index| {
        if (wasm_module.wasmValTypeForStore(store, function.valueType(element)) == wasm_module.wasm_i32) {
            mask |= @as(u3, 1) << @intCast(index);
        }
    }
    return switch (elements.len) {
        0 => "@runtime::struct_new_",
        1 => if (mask == 0) "@runtime::struct_new_f" else "@runtime::struct_new_i",
        2 => switch (mask) {
            0 => "@runtime::struct_new_ff",
            1 => "@runtime::struct_new_if",
            2 => "@runtime::struct_new_fi",
            3 => "@runtime::struct_new_ii",
            else => unreachable,
        },
        3 => switch (mask) {
            0 => "@runtime::struct_new_fff",
            1 => "@runtime::struct_new_iff",
            2 => "@runtime::struct_new_fif",
            3 => "@runtime::struct_new_iif",
            4 => "@runtime::struct_new_ffi",
            5 => "@runtime::struct_new_ifi",
            6 => "@runtime::struct_new_fii",
            7 => "@runtime::struct_new_iii",
        },
        else => unreachable,
    };
}

fn structNewSignature(pattern: []const u8) !BuiltinSignature {
    const params: []const u8 = switch (pattern.len) {
        0 => &.{},
        1 => if (pattern[0] == 'i') &.{wasm_module.wasm_i32} else &.{wasm_module.wasm_f64},
        2 => if (std.mem.eql(u8, pattern, "ii")) &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 } else if (std.mem.eql(u8, pattern, "if")) &.{ wasm_module.wasm_i32, wasm_module.wasm_f64 } else if (std.mem.eql(u8, pattern, "fi")) &.{ wasm_module.wasm_f64, wasm_module.wasm_i32 } else &.{ wasm_module.wasm_f64, wasm_module.wasm_f64 },
        3 => if (std.mem.eql(u8, pattern, "iii")) &.{ wasm_module.wasm_i32, wasm_module.wasm_i32, wasm_module.wasm_i32 } else if (std.mem.eql(u8, pattern, "iif")) &.{ wasm_module.wasm_i32, wasm_module.wasm_i32, wasm_module.wasm_f64 } else if (std.mem.eql(u8, pattern, "ifi")) &.{ wasm_module.wasm_i32, wasm_module.wasm_f64, wasm_module.wasm_i32 } else if (std.mem.eql(u8, pattern, "iff")) &.{ wasm_module.wasm_i32, wasm_module.wasm_f64, wasm_module.wasm_f64 } else if (std.mem.eql(u8, pattern, "fii")) &.{ wasm_module.wasm_f64, wasm_module.wasm_i32, wasm_module.wasm_i32 } else if (std.mem.eql(u8, pattern, "fif")) &.{ wasm_module.wasm_f64, wasm_module.wasm_i32, wasm_module.wasm_f64 } else if (std.mem.eql(u8, pattern, "ffi")) &.{ wasm_module.wasm_f64, wasm_module.wasm_f64, wasm_module.wasm_i32 } else &.{ wasm_module.wasm_f64, wasm_module.wasm_f64, wasm_module.wasm_f64 },
        else => return unsupported("сигнатура структуры с более чем 3 полями"),
    };
    return .{ .params = params, .result = wasm_module.wasm_i32 };
}

fn variantNewBuiltinName(function: *const mir.Function, fields: []const mir.ValueId) ![]const u8 {
    const struct_name = try structNewBuiltinName(function, fields);
    const pattern = struct_name["@runtime::struct_new_".len..];
    if (pattern.len > 2) return unsupported("variant с более чем 2 полями");
    if (pattern.len == 0) return "@runtime::variant_new_";
    if (std.mem.eql(u8, pattern, "i")) return "@runtime::variant_new_i";
    if (std.mem.eql(u8, pattern, "f")) return "@runtime::variant_new_f";
    if (std.mem.eql(u8, pattern, "ii")) return "@runtime::variant_new_ii";
    if (std.mem.eql(u8, pattern, "if")) return "@runtime::variant_new_if";
    if (std.mem.eql(u8, pattern, "fi")) return "@runtime::variant_new_fi";
    return "@runtime::variant_new_ff";
}

fn variantNewSignature(pattern: []const u8) !BuiltinSignature {
    const base = try structNewSignature(pattern);
    const params = switch (pattern.len) {
        0 => &.{wasm_module.wasm_i32},
        1 => if (pattern[0] == 'i') &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 } else &.{ wasm_module.wasm_f64, wasm_module.wasm_i32 },
        2 => if (std.mem.eql(u8, pattern, "ii")) &.{ wasm_module.wasm_i32, wasm_module.wasm_i32, wasm_module.wasm_i32 } else if (std.mem.eql(u8, pattern, "if")) &.{ wasm_module.wasm_i32, wasm_module.wasm_f64, wasm_module.wasm_i32 } else if (std.mem.eql(u8, pattern, "fi")) &.{ wasm_module.wasm_f64, wasm_module.wasm_i32, wasm_module.wasm_i32 } else &.{ wasm_module.wasm_f64, wasm_module.wasm_f64, wasm_module.wasm_i32 },
        else => return unsupported("variant с более чем 2 полями"),
    };
    return .{ .params = params, .result = base.result };
}

fn appendBuiltinName(
    allocator: std.mem.Allocator,
    seen: *std.StringHashMap(void),
    names: *std.ArrayList([]const u8),
    name: []const u8,
) !void {
    if (!seen.contains(name)) {
        try seen.put(name, {});
        try names.append(allocator, name);
    }
}

// Собирает полный, самодостаточный `.wasm`-бинарник — секции Type/Import/
// Function/Export/Code, один тип функции на каждую MIR-функцию (без
// дедупликации — расточительно, но валидно), каждая функция экспортируется
// под своим MIR-именем. Пространство индексов функций WASM начинается с
// импортов: каждое имя `call_builtin`, используемое где-либо в `module`,
// становится ОДНИМ импортом (модуль "env", поле = имя хост-экспорта из
// `hostImportNameForBuiltin`) в НАЧАЛЕ пространства индексов, поэтому
// реальный индекс каждой определённой в модуле функции —
// `builtin_count + порядок_объявления` — `func_index`/`function_section`/
// `export_section` все последовательно применяют это же смещение.
// Собственные инварианты времени построения `mir_validate.zig` уже
// гарантируют, что СОБСТВЕННЫЙ вывод `mir_lowering.zig` корректен — но
// безусловный прогон здесь превращает БУДУЩИЙ баг lowering в чистое
// сообщение об ошибке ("v3 используется 2 раза") вместо panic
// out-of-bounds или тихо-неправильных байт WASM глубоко внутри
// стек-машинного воспроизведения `processFrom`. Предупреждения
// (недостижимые блоки) логируются, не фатальны — то же разделение по
// серьёзности, что документирует сам `mir_validate.zig`.
fn validateOrFail(allocator: std.mem.Allocator, checked: *const type_checker.CheckResult, module: *const mir.Module) !void {
    for (module.functions.items) |*function| {
        const store = function.type_store orelse &checked.types;
        const issues = try mir_validate.validateFunction(allocator, module, function, store.builtins.void);
        defer mir_validate.freeIssues(allocator, issues);
        for (issues) |issue| {
            if (issue.is_error) {
                return error.InvalidMir;
            }
        }
    }
}

// Обе константы используются `wasm_actors.zig` при синтезе MIR-функций
// bump-аллокатора/планировщика — оставлены здесь, так как описывают
// свойство СБОРКИ МОДУЛЯ (layout секций memory/global), а не собственной
// логики actor-рантайма.
pub const actor_heap_global_index: u32 = 0;
pub const actor_heap_bytes: u32 = 1 << 20;

// `interface_table`: каждый `mir.FunctionId`, который должен быть достижим
// через `call_indirect` (запись таблицы функций WASM), в точном порядке,
// в котором они должны быть размещены в таблице (индекс таблицы == позиция
// в этом срезе). Пусто для любого модуля без диспетчеризации интерфейсов —
// в этом случае секции Table/Element полностью опускаются (WASM делает обе
// полностью опциональными). Намеренно простой список, предоставляемый
// вызывающей стороной, а не выводимый внутренне: ПОРЯДОК должен совпадать
// с тем, что вызывающая сторона уже зашила в константы table-index на
// местах вызова `.call_indirect` в остальной части модуля.
pub fn emitModule(allocator: std.mem.Allocator, checked: *const type_checker.CheckResult, module: *const mir.Module, interface_table: []const mir.FunctionId) ![]u8 {
    try validateOrFail(allocator, checked, module);

    var builtin_names = try collectBuiltinNames(allocator, module);
    defer builtin_names.deinit(allocator);
    const builtin_count: u32 = @intCast(builtin_names.items.len);

    var builtin_index: std.StringHashMap(u32) = .init(allocator);
    defer builtin_index.deinit();
    for (builtin_names.items, 0..) |name, i| try builtin_index.put(name, @intCast(i));

    var strings = try collectStringConstants(allocator, module);
    defer allocator.free(strings.data);
    defer strings.offsets.deinit();
    const has_actors = mir_cps.usesActorMemory(module);
    const needs_memory = strings.data.len != 0 or has_actors;
    // Записи actor-процесса/фрейма/почтового ящика живут в ТОЙ ЖЕ линейной
    // памяти, что и строковые литералы, сразу после blob строковых данных
    // (выровнено по 8 байт — достаточно и для i32-хэндла, и для f64-числа
    // в каждом слоте `frame_load`/`frame_store`). `@max(_, 8)` — планировщик
    // `wasm_actors.zig` использует адрес 0 как сторожевое значение "ещё не
    // порождён" для единственного слота дочернего процесса; модуль с нулём
    // строковых литералов иначе начал бы кучу буквально с байта 0, сделав
    // реальное первое выделение неотличимым от "ничего ещё не выделено".
    const actor_heap_base: u32 = @max(@as(u32, @intCast(std.mem.alignForward(usize, strings.data.len, 8))), 8);

    var func_index: std.AutoHashMap(mir.FunctionId, u32) = .init(allocator);
    defer func_index.deinit();
    for (module.functions.items, 0..) |function, i| try func_index.put(function.id, builtin_count + @as(u32, @intCast(i)));

    // Для каждой функции, достижимой через `call_indirect` (`interface_table`),
    // вычисляется её форма параметров/результата WASM и назначается ОДИН
    // ОБЩИЙ индекс секции типов на каждую отдельную форму (см. собственный
    // doc-комментарий `signatureShapeKey` о том, почему нельзя просто
    // переиспользовать обычный индивидуальный индекс типа каждой функции).
    // Новые записи добавляются в секцию типов ПОСЛЕ собственной
    // (уникальной) записи каждого builtin/функции, начиная с индекса
    // `builtin_count + module.functions.items.len`.
    var interface_type_index: std.StringHashMap(u32) = .init(allocator);
    defer {
        var it = interface_type_index.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        interface_type_index.deinit();
    }
    var interface_shape_types: std.ArrayList(u8) = .empty;
    defer interface_shape_types.deinit(allocator);
    var interface_shape_count: u32 = 0;
    for (interface_table) |function_id| {
        const function = &module.functions.items[@intFromEnum(function_id)];
        const store = function.type_store orelse &checked.types;
        var params: std.ArrayList(u8) = .empty;
        defer params.deinit(allocator);
        for (function.parameters) |local| {
            const local_type = function.locals.items[@intFromEnum(local)].type_id;
            try params.append(allocator, wasm_module.wasmValTypeForStore(store, local_type));
        }
        const is_void = store.eql(function.result_type, store.builtins.void);
        const result: ?u8 = if (is_void) null else wasm_module.wasmValTypeForStore(store, function.result_type);
        try registerInterfaceShape(allocator, &interface_type_index, &interface_shape_types, &interface_shape_count, builtin_count, module.functions.items.len, params.items, result);
    }

    // У СОБСТВЕННОЙ требуемой формы места вызова `.call_value` (по типам
    // его args/dst) может НЕ быть реальной зарегистрированной вызываемой
    // функции нигде в скомпилированной программе — весь prelude
    // компилируется безусловно, так что типовое тело callback'а (например,
    // `ф(значение)` у `отобразить`) может быть скомпилировано и в принципе
    // достижимо из кодогенерации `call_indirect`, даже когда НИЧТО в этой
    // конкретной программе реально не вызывает его с реальным замыканием.
    // Без этого у такого места вызова вообще не было бы записи секции
    // типов, и эмиссия провалилась бы, хотя на практике код мёртв.
    // Безвредно, если действительно недостижимо в рантайме; если бы это
    // БЫЛО достижимо с несовпадающей реальной вызываемой функцией,
    // `call_indirect` в этой точке паникует (trap) — то же поведение, что
    // любой движок WASM даёт при настоящем несовпадении типов.
    for (module.functions.items) |function| {
        const store = function.type_store orelse &checked.types;
        for (function.blocks.items) |block| for (block.instructions.items) |instruction| {
            const call = switch (instruction) {
                .call_value => |v| v,
                else => continue,
            };
            var params: std.ArrayList(u8) = .empty;
            defer params.deinit(allocator);
            for (call.args) |arg| try params.append(allocator, wasm_module.wasmValTypeForStore(store, function.valueType(arg)));
            const result: ?u8 = if (call.dst) |dst| wasm_module.wasmValTypeForStore(store, function.valueType(dst)) else null;
            try registerInterfaceShape(allocator, &interface_type_index, &interface_shape_types, &interface_shape_count, builtin_count, module.functions.items.len, params.items, result);
        };
    }

    // Типы импортов идут ПЕРВЫМИ в секции типов — индекс типа импорта `i`
    // просто равен `i` для `i < builtin_count`, по собственной
    // `builtinSignature` каждого builtin (уже НЕ единообразно `() -> f64` —
    // `DOM.*` тоже нужны реальные параметры/void-результаты).
    var type_section: std.ArrayList(u8) = .empty;
    defer type_section.deinit(allocator);
    try wasm_module.writeUleb128(&type_section, allocator, builtin_count + module.functions.items.len + interface_shape_count);
    for (builtin_names.items) |name| {
        const signature = try builtinSignature(name);
        try type_section.append(allocator, 0x60); // functype
        try wasm_module.writeUleb128(&type_section, allocator, signature.params.len);
        for (signature.params) |param_type| try type_section.append(allocator, param_type);
        try wasm_module.writeUleb128(&type_section, allocator, if (signature.result != null) 1 else 0);
        if (signature.result) |result_type| try type_section.append(allocator, result_type);
    }
    for (module.functions.items) |function| {
        const store = function.type_store orelse &checked.types;
        try type_section.append(allocator, 0x60); // functype
        try wasm_module.writeUleb128(&type_section, allocator, function.parameters.len);
        for (function.parameters) |local| {
            const local_type = function.locals.items[@intFromEnum(local)].type_id;
            try type_section.append(allocator, wasm_module.wasmValTypeForStore(store, local_type));
        }
        const is_void = store.eql(function.result_type, store.builtins.void);
        try wasm_module.writeUleb128(&type_section, allocator, if (is_void) 0 else 1);
        if (!is_void) try type_section.append(allocator, wasm_module.wasmValTypeForStore(store, function.result_type));
    }
    try type_section.appendSlice(allocator, interface_shape_types.items);

    var import_section: std.ArrayList(u8) = .empty;
    defer import_section.deinit(allocator);
    if (builtin_count != 0) {
        try wasm_module.writeUleb128(&import_section, allocator, builtin_count);
        for (builtin_names.items, 0..) |name, i| {
            const host_name = try hostImportNameForBuiltin(name);
            try wasm_module.writeUleb128(&import_section, allocator, "env".len);
            try import_section.appendSlice(allocator, "env");
            try wasm_module.writeUleb128(&import_section, allocator, host_name.len);
            try import_section.appendSlice(allocator, host_name);
            try import_section.append(allocator, 0x00); // func import kind
            try wasm_module.writeUleb128(&import_section, allocator, i); // typeidx
        }
    }

    var interface_table_members: std.AutoHashMap(mir.FunctionId, void) = .init(allocator);
    defer interface_table_members.deinit();
    for (interface_table) |function_id| try interface_table_members.put(function_id, {});

    var function_section: std.ArrayList(u8) = .empty;
    defer function_section.deinit(allocator);
    try wasm_module.writeUleb128(&function_section, allocator, module.functions.items.len);
    for (module.functions.items, 0..) |function, i| {
        // Функция, достижимая через `call_indirect`, получает ОБЩИЙ индекс
        // типа для своей формы вместо собственного уникального — см.
        // построение `interface_type_index` выше.
        if (interface_table_members.contains(function.id)) {
            const store = function.type_store orelse &checked.types;
            var params: std.ArrayList(u8) = .empty;
            defer params.deinit(allocator);
            for (function.parameters) |local| {
                const local_type = function.locals.items[@intFromEnum(local)].type_id;
                try params.append(allocator, wasm_module.wasmValTypeForStore(store, local_type));
            }
            const is_void = store.eql(function.result_type, store.builtins.void);
            const result: ?u8 = if (is_void) null else wasm_module.wasmValTypeForStore(store, function.result_type);
            const key = try signatureShapeKey(allocator, params.items, result);
            defer allocator.free(key);
            const shared_index = interface_type_index.get(key).?;
            try wasm_module.writeUleb128(&function_section, allocator, shared_index);
            continue;
        }
        try wasm_module.writeUleb128(&function_section, allocator, builtin_count + i);
    }

    // Сброс арены при каждом вызове (`wasm_gc_arena.zig`, Phase 1 GC)
    // требует ВТОРОЙ, несбрасываемой bump-области для значений, которые
    // должны пережить отдельные экспортные вызовы со стороны JS (контекстные
    // указатели DOM-обработчиков, продвигаемые на месте своего lowering в
    // `mir_lowering.zig` через `wasm_heap.findOrBuildAllocPermanent`) —
    // резервируется только когда модуль реально построил эту функцию
    // (`uses_permanent_heap`), располагается в фиксированном промежутке
    // сразу после строковых данных, а обычная bump-арена (`global 0`)
    // начинается уже ПОСЛЕ НЕЁ, а не сразу после строковых данных, как
    // раньше.
    const uses_permanent_heap = wasm_heap.findFunctionByName(module, wasm_heap.permanent_alloc_function_name) != null;
    const permanent_reserved_bytes: u32 = if (uses_permanent_heap) wasm_heap.permanent_reserved_bytes else 0;
    const arena_base: u32 = actor_heap_base + permanent_reserved_bytes;

    // Линейная память хранит только плоский blob строковых литералов.
    // Динамические строки — хэндлы хоста; это намеренно избегает GC/кучи
    // WASM в первом ABI браузерного рантайма.
    var memory_section: std.ArrayList(u8) = .empty;
    defer memory_section.deinit(allocator);
    var data_section: std.ArrayList(u8) = .empty;
    defer data_section.deinit(allocator);
    if (needs_memory) {
        const total_bytes: u32 = arena_base + (if (has_actors) actor_heap_bytes else 0);
        const pages: u32 = (total_bytes + 65535) / 65536;
        try wasm_module.writeUleb128(&memory_section, allocator, 1); // 1 memory
        try memory_section.append(allocator, 0x00); // limits: min only, no max
        try wasm_module.writeUleb128(&memory_section, allocator, @max(pages, 1));

        if (strings.data.len != 0) {
            try wasm_module.writeUleb128(&data_section, allocator, 1); // 1 active segment
            try data_section.append(allocator, 0x00); // flags: active, memory 0
            try data_section.append(allocator, 0x41); // i32.const
            try wasm_module.writeSleb128(&data_section, allocator, 0); // offset 0
            try data_section.append(allocator, 0x0B); // end
            try wasm_module.writeUleb128(&data_section, allocator, strings.data.len);
            try data_section.appendSlice(allocator, strings.data);
        }
    }

    // Global 0: bump-указатель арены (`actor_heap_global_index`),
    // инициализируется после промежутка постоянной области (если он есть).
    // Полностью отсутствует для любого модуля, который вообще никогда не
    // трогает кучу. Globals 1/2 (постоянный bump-указатель + его
    // неизменяемый потолок) присутствуют ТОЛЬКО когда `uses_permanent_heap` —
    // большинству модулей (без аргументов контекста DOM-обработчика) они
    // никогда не нужны.
    var global_section: std.ArrayList(u8) = .empty;
    defer global_section.deinit(allocator);
    if (has_actors) {
        try wasm_module.writeUleb128(&global_section, allocator, @as(usize, if (uses_permanent_heap) 3 else 1));
        try global_section.append(allocator, wasm_module.wasm_i32);
        try global_section.append(allocator, 0x01); // mutable
        try global_section.append(allocator, 0x41); // i32.const
        try wasm_module.writeSleb128(&global_section, allocator, @intCast(arena_base));
        try global_section.append(allocator, 0x0B); // end
        if (uses_permanent_heap) {
            // Global 1: постоянный bump-указатель, изменяемый, начинается
            // сразу после строковых данных (`actor_heap_base`).
            try global_section.append(allocator, wasm_module.wasm_i32);
            try global_section.append(allocator, 0x01); // mutable
            try global_section.append(allocator, 0x41); // i32.const
            try wasm_module.writeSleb128(&global_section, allocator, @intCast(actor_heap_base));
            try global_section.append(allocator, 0x0B); // end
            // Global 2: потолок постоянной области — НЕИЗМЕНЯЕМЫЙ, то же
            // значение, что и собственное начальное значение global 0
            // (`arena_base`). `buildAllocPermanent` (`wasm_heap.zig`)
            // на этапе построения MIR нуждается только в ИНДЕКСЕ этой
            // глобали, не в реальном числе — реальное значение известно
            // только здесь, после того как `strings.data.len` окончательно
            // определён.
            try global_section.append(allocator, wasm_module.wasm_i32);
            try global_section.append(allocator, 0x00); // immutable
            try global_section.append(allocator, 0x41); // i32.const
            try wasm_module.writeSleb128(&global_section, allocator, @intCast(arena_base));
            try global_section.append(allocator, 0x0B); // end
        }
    }

    var export_section: std.ArrayList(u8) = .empty;
    defer export_section.deinit(allocator);
    try wasm_module.writeUleb128(&export_section, allocator, module.functions.items.len + @as(usize, if (needs_memory) 1 else 0));
    for (module.functions.items, 0..) |function, i| {
        try wasm_module.writeUleb128(&export_section, allocator, function.name.len);
        try export_section.appendSlice(allocator, function.name);
        try export_section.append(allocator, 0x00); // func export kind
        try wasm_module.writeUleb128(&export_section, allocator, builtin_count + i);
    }
    if (needs_memory) {
        try wasm_module.writeUleb128(&export_section, allocator, "memory".len);
        try export_section.appendSlice(allocator, "memory");
        try export_section.append(allocator, 0x02); // memory export kind
        try wasm_module.writeUleb128(&export_section, allocator, 0); // memidx 0
    }

    // Одна таблица `funcref`, размер точно как у `interface_table` —
    // каждая запись заполняется единым активным element-сегментом
    // (смещение 0), без дыр. Полностью опускается (обе секции), когда
    // `interface_table` пуста, как и любая другая опциональная секция в
    // этой функции (`needs_memory`/`has_actors`).
    var table_section: std.ArrayList(u8) = .empty;
    defer table_section.deinit(allocator);
    var element_section: std.ArrayList(u8) = .empty;
    defer element_section.deinit(allocator);
    if (interface_table.len != 0) {
        try wasm_module.writeUleb128(&table_section, allocator, 1); // 1 table
        try table_section.append(allocator, 0x70); // funcref
        try table_section.append(allocator, 0x00); // limits: min only, no max
        try wasm_module.writeUleb128(&table_section, allocator, interface_table.len);

        try wasm_module.writeUleb128(&element_section, allocator, 1); // 1 active segment
        try element_section.append(allocator, 0x00); // flags: active, table 0
        try element_section.append(allocator, 0x41); // i32.const
        try wasm_module.writeSleb128(&element_section, allocator, 0); // offset 0
        try element_section.append(allocator, 0x0B); // end
        try wasm_module.writeUleb128(&element_section, allocator, interface_table.len);
        for (interface_table) |function_id| {
            const index = func_index.get(function_id) orelse return unsupported("функция интерфейсной таблицы не найдена в индексе модуля");
            try wasm_module.writeUleb128(&element_section, allocator, index);
        }
    }

    var code_section: std.ArrayList(u8) = .empty;
    defer code_section.deinit(allocator);
    try wasm_module.writeUleb128(&code_section, allocator, module.functions.items.len);
    for (module.functions.items) |function| {
        const body = try emitFunctionWasm(allocator, checked, &function, &func_index, &builtin_index, &strings.offsets, &interface_type_index);
        defer allocator.free(body);
        try wasm_module.writeUleb128(&code_section, allocator, body.len);
        try code_section.appendSlice(allocator, body);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &wasm_module.magic_and_version);
    try wasm_module.writeSection(&out, allocator, 1, type_section.items);
    if (builtin_count != 0) try wasm_module.writeSection(&out, allocator, 2, import_section.items);
    try wasm_module.writeSection(&out, allocator, 3, function_section.items);
    if (interface_table.len != 0) try wasm_module.writeSection(&out, allocator, 4, table_section.items);
    if (needs_memory) try wasm_module.writeSection(&out, allocator, 5, memory_section.items);
    if (has_actors) try wasm_module.writeSection(&out, allocator, 6, global_section.items);
    try wasm_module.writeSection(&out, allocator, 7, export_section.items);
    // Секция Element (9) между Export(7)/Start(8, не используется) и
    // Code(10) — фиксированный канонический порядок секций WASM.
    if (interface_table.len != 0) try wasm_module.writeSection(&out, allocator, 9, element_section.items);
    try wasm_module.writeSection(&out, allocator, 10, code_section.items);
    // `strings.data.len != 0`, а НЕ `needs_memory` — модулю может требоваться
    // память чисто под actor-кучу при НУЛЕ строковых литералов (писать
    // сегмент данных вообще нечего); секция Data полностью опциональна
    // в WASM, но запись её с ПУСТЫМ содержимым (даже без счётчика
    // "0 сегментов") даёт усечённую секцию, которую реальный парсер
    // отвергает ("unable to read u32 leb128: data segment count").
    if (strings.data.len != 0) try wasm_module.writeSection(&out, allocator, 11, data_section.items);
    return try out.toOwnedSlice(allocator);
}

test "emitModule produces a valid, executable .wasm for a recursive MIR function" {
    const allocator = std.testing.allocator;
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker_mod = @import("type_checker.zig");
    const mir_lowering = @import("mir_lowering.zig");

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

    var module = try mir_lowering.lowerModule(allocator, &parsed.ast, &resolved, &checked);
    defer module.deinit(allocator);

    // Рекурсивный самовызов здесь компилируется в `.function_ref` +
    // `.call_value` (см. `lowerCall` в `mir_lowering.zig`) — `.call_value`
    // теперь ВСЕГДА понижается в `call_indirect` (это нужно не только
    // интерфейсам, но и полноценным функциональным значениям — см.
    // собственный doc-комментарий `wasm_interfaces.zig`), что зависит от
    // того, что `wasm_interfaces.expand` уже переписал `.function_ref` в
    // реальную i32-константу индекса таблицы. Каждый реальный вызывающий
    // (`cli/main.zig`) всегда прогоняет этот проход до `emitModule`.
    const wasm_interfaces = @import("wasm_interfaces.zig");
    const iface_result = try wasm_interfaces.expand(allocator, &module, &checked.types);
    defer allocator.free(iface_result.table);

    const wasm_bytes = try emitModule(allocator, &checked, &module, iface_result.table);
    defer allocator.free(wasm_bytes);
    try std.testing.expect(std.mem.eql(u8, wasm_bytes[0..4], &.{ 0x00, 0x61, 0x73, 0x6D }));

    // `Io.Threaded.Options.environ` по умолчанию ПУСТ (осознанно —
    // порождение дочернего процесса с реальным окружением должно быть
    // явным выбором) — собственный поиск по `$PATH` у `expand_arg0 =
    // .expand` читает ИМЕННО это поле, а не реальное окружение ОС, поэтому
    // без передачи `std.testing.environ` (заполняется стандартным тестовым
    // раннером из реального окружения процесса) он тихо откатывается к
    // крошечному захардкоженному значению по умолчанию (`/usr/local/bin:
    // /bin/:/usr/bin`) и сообщает `FileNotFound`, даже если `wasmtime`
    // реально есть в `$PATH`.
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();
    const path = "zzz_wasm_emit_test.wasm";
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = path, .data = wasm_bytes });
    defer std.Io.Dir.cwd().deleteFile(io.io(), path) catch {};

    const result = std.process.run(allocator, io.io(), .{
        .argv = &.{ "wasmtime", "run", "--invoke", "факториал", path, "5" },
        .expand_arg0 = .expand,
    }) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exited_zero = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!exited_zero) {
        std.debug.print("wasmtime failed: {s}\n", .{result.stderr});
        return error.WasmtimeFailed;
    }
    // 5! == 120
    try std.testing.expectEqualStrings("120\n", result.stdout);
}

test "emitModule produces a valid, executable .wasm for a real iterating пока loop with assignment" {
    const allocator = std.testing.allocator;
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker_mod = @import("type_checker.zig");
    const mir_lowering = @import("mir_lowering.zig");

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

    var module = try mir_lowering.lowerModule(allocator, &parsed.ast, &resolved, &checked);
    defer module.deinit(allocator);

    const wasm_bytes = try emitModule(allocator, &checked, &module, &.{});
    defer allocator.free(wasm_bytes);

    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();
    const path = "zzz_wasm_emit_loop_test.wasm";
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = path, .data = wasm_bytes });
    defer std.Io.Dir.cwd().deleteFile(io.io(), path) catch {};

    const result = std.process.run(allocator, io.io(), .{
        .argv = &.{ "wasmtime", "run", "--invoke", "сумма_до", path, "10" },
        .expand_arg0 = .expand,
    }) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exited_zero = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!exited_zero) {
        std.debug.print("wasmtime failed: {s}\n", .{result.stderr});
        return error.WasmtimeFailed;
    }
    // 1+2+...+9 == 45 (i < предел, не <=)
    try std.testing.expectEqualStrings("45\n", result.stdout);
}

test "emitModule fails cleanly on a malformed MIR module instead of crashing" {
    const allocator = std.testing.allocator;
    const mir_builder = @import("mir_builder.zig");

    var checked = try type_checker.CheckResult.init(allocator);
    defer checked.deinit();

    var module = mir.Module.init(allocator);
    defer module.deinit(allocator);
    const function_id = try mir_builder.newFunction(&module, allocator, "сломано", @enumFromInt(0), checked.types.builtins.void, .{ .file_id = 0, .start = 0, .end = 0 });
    var builder = try mir_builder.Builder.beginFunction(&module, allocator, function_id);
    // Переход на несуществующий блок — именно тот инвариант, который
    // `mir_validate.zig` призван поймать до того, как это дойдёт до
    // стек-машинного воспроизведения в `processFrom` (которое иначе вышло
    // бы за границы индекса).
    builder.terminate(.{ .jump = .{ .target = @enumFromInt(99) } });

    try std.testing.expectError(error.InvalidMir, emitModule(allocator, &checked, &module, &.{}));
}
