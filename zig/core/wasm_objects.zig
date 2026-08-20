const std = @import("std");
const mir = @import("mir.zig");
const mir_builder = @import("mir_builder.zig");
const types = @import("types.zig");
const wasm_heap = @import("wasm_heap.zig");
const wasm_module = @import("wasm_module.zig");

// Устраняет импорты JS-хостовой таблицы объектов для структур/
// массивов/вариантов (`@runtime::struct_*`/`array_*`/`variant_*`) —
// заменяет `.new_aggregate`/`.get_property`/`.set_property`/
// `.build_variant`/`.match_tag`/`.get_variant_field`/`.new_array`/
// `.get_index`/`.set_index` настоящим кодом в линейной памяти модуля,
// переиспользуя bump-аллокатор `wasm_heap.zig` (общий с
// `wasm_actors.zig` — оба прохода делят одну кучу global-0). Выполняется
// ДО `mir_cps.prepare` (лоуеринг структур данных до лоуеринга
// преобразования потока управления — переписывание в `mir_cps.zig`
// обрабатывает всё нераспознанное как обычную сквозную инструкцию,
// так что порядок безопасен в любом случае, но такая
// последовательность чище).
//
// Представление структуры/варианта: N смежных 8-байтовых слотов (та
// же форма, что у фрейма актора), bump-аллоцируется. `field_index`
// структуры (уже compile-time `u32`) отображается НАПРЯМУЮ на
// существующий `slot: u32` в `frame_load`/`frame_store` — новых
// инструкций не требуется. Вариант — та же форма со слотом 0,
// зарезервированным под тег. Это снимает два реальных ограничения:
// старая схема именования хостовых импортов (в духе `struct_new_iff`)
// жёстко ограничивала структуры тремя полями, а варианты двумя —
// у обобщённой последовательности alloc+store такого предела нет.
//
// Представлению массива, в отличие от структур/вариантов
// (фиксированное число полей известно при конструировании), нужен
// настоящий динамический рост: 3-слотовый заголовок (`length`,
// `capacity`, `data_ptr`, все внутренне `idx_type`/i32) плюс ОТДЕЛЬНО
// bump-аллоцируемый буфер данных. `@array_ensure_capacity` — единственное
// место, которому нужен настоящий (неразвёрнутый) `loop` WASM — но это
// обычная форма с одним заголовком/одним выходом (без CPS/suspend),
// так что она попадает в существующий быстрый путь
// `wasm_stackify.zig` без изменений. Цикл копирования переносит 8
// сырых байт на элемент через `f64.load`/`f64.store` НЕЗАВИСИМО от
// реального типа элемента массива — переинтерпретация битового
// паттерна i32-хэндла как f64 для чистого раунд-трипа load+store
// ничего не портит (никакая арифметика значение не трогает), и это
// избавляет от необходимости в двух вариантах цикла копирования.
//
// Пользовательские индексы массива — `Число` (f64); реальная
// адресация памяти требует i32 — `mir.UnOp.to_i32`/`from_i32`
// конвертируют на границе, один раз, внутри обобщённых функций
// массива.

fn unsupported(comptime what: []const u8) error{ObjectExpandUnsupported} {
    std.debug.print("panos build: AOT (wasm) объекты — " ++ what ++ "\n", .{});
    return error.ObjectExpandUnsupported;
}

const length_slot: u32 = 0;
const capacity_slot: u32 = 1;
const data_ptr_slot: u32 = 2;
const array_header_slots: u32 = 3;

pub const ArrayRuntime = struct {
    new: mir.FunctionId,
    ensure_capacity: mir.FunctionId,
    append_i32: mir.FunctionId,
    append_f64: mir.FunctionId,
    get_i32: mir.FunctionId,
    get_f64: mir.FunctionId,
    get_or_i32: mir.FunctionId,
    get_or_f64: mir.FunctionId,
    set_i32: mir.FunctionId,
    set_f64: mir.FunctionId,
    length: mir.FunctionId,
};

const ExpandCtx = struct {
    layout: wasm_heap.PtrLayout,
    type_store: *const types.TypeStore,
    array_runtime: ?ArrayRuntime,
};

pub fn expand(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore) !void {
    if (!usesObjects(module)) return;

    const layout = wasm_heap.PtrLayout{
        .ptr_type = type_store.builtins.string,
        .idx_type = type_store.builtins.boolean,
        .bool_type = type_store.builtins.boolean,
    };

    // `buildAllocInto` (структуры/варианты) тоже нуждается в
    // `@runtime_alloc`, не только массивы — строится безусловно, если
    // присутствует ЛЮБОЙ вид объектов (идемпотентно: no-op, если массивы
    // уже его построили). Модуль только со структурами/вариантами (без
    // массивов) никогда не вызывает `buildArrayRuntime`, так что без
    // этого `findFunctionByName(..., alloc_function_name)` вернул бы
    // null, а `.?`-развёртка в `buildAllocInto` запаниковала бы.
    _ = try wasm_heap.findOrBuildAlloc(allocator, module, type_store, layout);

    var array_runtime: ?ArrayRuntime = null;
    if (usesArrays(module)) array_runtime = try buildArrayRuntime(allocator, module, type_store, layout);

    // Тела новых функций, добавленных `buildArrayRuntime` выше в
    // `module.functions`, никогда САМИ не содержат инструкций
    // структур/массивов/вариантов (написаны вручную, не пользовательский
    // код), поэтому безопасно просто пересканировать
    // `module.functions.items` заново на каждой итерации ниже, а не
    // требовать замороженный снимок (в отличие от разбиения блоков в
    // `mir_cps.zig`, здесь ничего не добавляет ЕЩЁ функции по ходу
    // обхода).
    var index: usize = 0;
    while (index < module.functions.items.len) : (index += 1) {
        const function_id: mir.FunctionId = @enumFromInt(index);
        // Каждая функция может принадлежать РАЗНОМУ исходному модулю,
        // а значит РАЗНОМУ экземпляру `types.TypeStore` (`TypeId.owner`
        // намеренно специфичен для хранилища — см. doc-комментарий
        // `types.zig` о том, что это "делает случайное межхранилищное
        // использование ошибочным"). Новые локали, создаваемые ниже
        // (`dst_local` и т.п.), должны быть типизированы относительно
        // СОБСТВЕННОГО хранилища ЭТОЙ функции, а не переданного вызывающим
        // кодом верхнеуровневого `type_store` (это хранилище только
        // ВХОДНОГО модуля) — тот же класс межмодульной ошибки уже был
        // найден и исправлен в собственном поэкземплярном выводе
        // `wasm_interfaces.zig`. Собственные функции `array_runtime`
        // остаются на глобальном хранилище входного модуля — это
        // синтезированные компилятором помощники, внутренне
        // самосогласованные, и каждый ВЫЗЫВАЮЩИЙ код уже типизирует свой
        // `dst` независимо (то же рассуждение, что уже установлено для
        // `@runtime_alloc`).
        const function_store = module.functions.items[index].type_store orelse type_store;
        const function_layout = wasm_heap.PtrLayout{
            .ptr_type = function_store.builtins.string,
            .idx_type = function_store.builtins.boolean,
            .bool_type = function_store.builtins.boolean,
        };
        const function_ctx = ExpandCtx{ .layout = function_layout, .type_store = function_store, .array_runtime = array_runtime };
        const block_count = module.functions.items[index].blocks.items.len;
        var block_index: usize = 0;
        while (block_index < block_count) : (block_index += 1) {
            var builder = mir_builder.Builder{ .module = module, .allocator = allocator, .function_id = function_id };
            try expandBlock(&builder, allocator, @enumFromInt(block_index), function_ctx);
        }
    }
}

fn usesObjects(module: *const mir.Module) bool {
    for (module.functions.items) |function| for (function.blocks.items) |block|
        for (block.instructions.items) |instruction| switch (instruction) {
            .new_aggregate, .get_property, .set_property, .build_variant, .match_tag, .get_variant_field, .new_array, .get_index, .set_index => return true,
            .call_builtin => |v| if (isArrayBuiltinCall(v.name)) return true,
            else => {},
        };
    return false;
}

fn usesArrays(module: *const mir.Module) bool {
    for (module.functions.items) |function| for (function.blocks.items) |block|
        for (block.instructions.items) |instruction| switch (instruction) {
            .new_array, .get_index, .set_index => return true,
            .call_builtin => |v| if (isArrayBuiltinCall(v.name)) return true,
            else => {},
        };
    return false;
}

// Вызовы МЕТОДОВ массива `.длина()`/`.добавить(x)`/`.получить(i,
// запасное)` лоуерятся (`lowerArrayMethodCall` в `mir_lowering.zig`) в
// обобщённый `.call_builtin{name="@runtime::array_*"}`, а НЕ в
// `.new_array`/`.get_index`/`.set_index` (эти три покрывают только
// конструирование МАССИВА-ЛИТЕРАЛА и индексацию через `[]`). Эти имена
// тоже нужно переписать в настоящие `.call` к функциям `ArrayRuntime`
// здесь, аналогично формам через вид инструкции выше.
fn isArrayBuiltinCall(name: []const u8) bool {
    return std.mem.eql(u8, name, "@runtime::array_length") or
        std.mem.eql(u8, name, "@runtime::array_append_i32") or
        std.mem.eql(u8, name, "@runtime::array_append_f64") or
        std.mem.eql(u8, name, "@runtime::array_get_or_i32") or
        std.mem.eql(u8, name, "@runtime::array_get_or_f64");
}

// Переписывает инструкции `block_id` на месте, прямолинейно (раскрытие
// структур/массивов/вариантов никогда не требует разбивать блок или
// трогать его терминатор — каждая инструкция здесь превращается в
// короткую ПОСЛЕДОВАТЕЛЬНОСТЬ на ТОМ ЖЕ месте, а не в новый поток
// управления; настоящее ветвление/цикл есть только в общих функциях
// array runtime, построенных один раз в `buildArrayRuntime`).
fn expandBlock(builder: *mir_builder.Builder, allocator: std.mem.Allocator, block_id: mir.BlockId, ctx: ExpandCtx) !void {
    const function = builder.currentFunction();
    var original = function.blockConst(block_id).*;
    function.block(block_id).instructions = .empty;
    builder.setCurrentBlock(block_id);
    builder.terminated = false;

    for (original.instructions.items) |instruction| {
        try expandInstruction(builder, allocator, instruction, ctx);
    }
    builder.terminate(original.terminator);
    original.instructions.deinit(allocator);
}

fn expandInstruction(builder: *mir_builder.Builder, allocator: std.mem.Allocator, instruction: mir.Instruction, ctx: ExpandCtx) !void {
    const layout = ctx.layout;
    switch (instruction) {
        .new_aggregate => |v| {
            const dst_local = try buildAllocInto(builder, allocator, layout, @as(u32, @intCast(v.elements.len)) * 8);
            // Обходим элементы в ОБРАТНОМ порядке. `v.elements` — все
            // ПРЕДСУЩЕСТВУЮЩИЕ значения (каждое выражение поля вычислено
            // рядом с ОРИГИНАЛЬНОЙ, ещё не раскрытой инструкцией
            // `.new_aggregate`, по порядку) — то есть к моменту этого
            // раскрытия они ВСЕ уже лежат на настоящем стеке WASM в
            // порядке производства, с ПОСЛЕДНИМ элементом наверху.
            // Сохранение элемента 0 ПЕРВЫМ (по возрастанию) забрало бы
            // не то (верхнее, последнее произведённое) значение как
            // `src` для `frame_store`. Сохранение в обратном порядке
            // потребляет каждый элемент ровно тогда, когда он
            // действительно наверху; `slot` по-прежнему равен
            // собственному индексу элемента, независимо от порядка
            // потребления.
            var i = v.elements.len;
            while (i > 0) {
                i -= 1;
                const frame = try wasm_heap.loadLocal(builder, dst_local, layout.ptr_type);
                try builder.emit(.{ .frame_store = .{ .frame = frame, .slot = @intCast(i), .src = v.elements[i] } });
            }
            try builder.emit(.{ .load_local = .{ .dst = v.dst, .local = dst_local } });
        },
        .get_property => |v| {
            try builder.emit(.{ .frame_load = .{ .dst = v.dst, .frame = v.object, .slot = v.field_index } });
        },
        .set_property => |v| {
            try emitReorderedStore(builder, layout, v.object, v.value, v.field_index);
        },
        .build_variant => |v| {
            const dst_local = try buildAllocInto(builder, allocator, layout, (1 + @as(u32, @intCast(v.fields.len))) * 8);
            // `src` (`tag_const`) должен быть произведён ДО `frame`
            // (`tag_frame`) — `frame_store` требует стек `[src, frame]`,
            // где `frame` наверху/свежайший (см. doc-комментарий
            // `EmitContext.frame_store_scratch_frame` в `wasm_emit.zig`).
            // Цикл по полям ниже уже делает это правильно (его
            // собственная перезагрузка `frame` идёт прямо перед каждым
            // `frame_store`, после предсуществующего значения `field`).
            // `v.fields` — тоже предсуществующие значения, тот же
            // порядок в обратную сторону, что и в `.new_aggregate` выше
            // (сохраняются ПОСЛЕ тега, поскольку запись тега происходит
            // первой и не затронута: `tag_const` производится свежим,
            // прямо здесь, а не является предсуществующим значением).
            var i = v.fields.len;
            while (i > 0) {
                i -= 1;
                const frame = try wasm_heap.loadLocal(builder, dst_local, layout.ptr_type);
                try builder.emit(.{ .frame_store = .{ .frame = frame, .slot = @intCast(1 + i), .src = v.fields[i] } });
            }
            const tag_const = try wasm_heap.addressConst(builder, layout.idx_type, v.tag);
            const tag_frame = try wasm_heap.loadLocal(builder, dst_local, layout.ptr_type);
            try builder.emit(.{ .frame_store = .{ .frame = tag_frame, .slot = 0, .src = tag_const } });
            try builder.emit(.{ .load_local = .{ .dst = v.dst, .local = dst_local } });
        },
        .match_tag => |v| {
            const tag_value = try builder.newValue(layout.idx_type);
            try builder.emit(.{ .frame_load = .{ .dst = tag_value, .frame = v.subject, .slot = 0 } });
            const tag_const = try wasm_heap.addressConst(builder, layout.idx_type, v.tag);
            try builder.emit(.{ .compare = .{ .dst = v.dst, .op = .equal, .lhs = tag_value, .rhs = tag_const } });
        },
        .get_variant_field => |v| {
            try builder.emit(.{ .frame_load = .{ .dst = v.dst, .frame = v.subject, .slot = 1 + v.field_index } });
        },
        .new_array => |v| {
            // `.copy` вообще не имеет поддержки кодогенерации в
            // `wasm_emit.zig` (Phase 2, согласно собственной заметке о
            // границах объёма в том файле). Как и в `.new_aggregate`/
            // `.build_variant`: аллоцируем в СВЕЖЕЕ внутреннее значение,
            // всю внутреннюю работу делаем через локаль, и лишь в
            // самом конце производим `v.dst` через один свежий
            // `load_local` — иначе `v.dst` потреблялся бы дважды
            // (нарушение инварианта единственного использования,
            // `mir_validate.zig`: "v0 используется 2 раз(а)"), так как
            // исходный поток инструкций уже держит для него ровно
            // одного потребителя (например, собственный `store_local`
            // от `пер числа = ...`).
            const rt = ctx.array_runtime.?;
            const handle = try builder.newValue(layout.ptr_type);
            try builder.emit(.{ .call = .{ .dst = handle, .callee = rt.new, .args = &.{} } });
            const dst_local = try wasm_heap.storeLocal(builder, "@arr", layout.ptr_type, handle);
            for (v.elements) |element| {
                const is_i32 = wasm_module.wasmValTypeForStore(ctx.type_store, builder.currentFunction().valueType(element)) == wasm_module.wasm_i32;
                const append_fn = if (is_i32) rt.append_i32 else rt.append_f64;
                const arr = try wasm_heap.loadLocal(builder, dst_local, layout.ptr_type);
                try builder.emit(.{ .call = .{ .dst = null, .callee = append_fn, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ arr, element }) } });
            }
            try builder.emit(.{ .load_local = .{ .dst = v.dst, .local = dst_local } });
        },
        .get_index => |v| {
            const rt = ctx.array_runtime.?;
            const is_i32 = wasm_module.wasmValTypeForStore(ctx.type_store, builder.currentFunction().valueType(v.dst)) == wasm_module.wasm_i32;
            const get_fn = if (is_i32) rt.get_i32 else rt.get_f64;
            try builder.emit(.{ .call = .{ .dst = v.dst, .callee = get_fn, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ v.object, v.index }) } });
        },
        .set_index => |v| {
            const rt = ctx.array_runtime.?;
            const is_i32 = wasm_module.wasmValTypeForStore(ctx.type_store, builder.currentFunction().valueType(v.value)) == wasm_module.wasm_i32;
            const set_fn = if (is_i32) rt.set_i32 else rt.set_f64;
            // `object`/`index`/`value` — все предсуществующие операнды
            // (произведены своими более ранними инструкциями,
            // неперемещаемы) — здесь нет проблемы с переупорядочиванием,
            // так как аргументы `.call` воспроизводятся в ТОЧНОМ
            // порядке, в котором перечислены, совпадающем с тем, как
            // они УЖЕ были протолкнуты исходным (неизменённым) потоком
            // инструкций — в отличие от `frame_store`/`mem_store`,
            // `.call` не навязывает фиксированное соглашение
            // поле-против-свежести.
            try builder.emit(.{ .call = .{ .dst = null, .callee = set_fn, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ v.object, v.index, v.value }) } });
        },
        .call_builtin => |v| if (isArrayBuiltinCall(v.name)) {
            const rt = ctx.array_runtime.?;
            // `args`/`dst` — все предсуществующие операнды (уже
            // произведены исходным потоком инструкций, в ИСХОДНОМ
            // порядке) — аргументы `.call` воспроизводятся точно в
            // перечисленном порядке, как и у `.get_index`/`.set_index`
            // выше, так что переупорядочивание не требуется.
            const callee = if (std.mem.eql(u8, v.name, "@runtime::array_length"))
                rt.length
            else if (std.mem.eql(u8, v.name, "@runtime::array_append_i32"))
                rt.append_i32
            else if (std.mem.eql(u8, v.name, "@runtime::array_append_f64"))
                rt.append_f64
            else if (std.mem.eql(u8, v.name, "@runtime::array_get_or_i32"))
                rt.get_or_i32
            else
                rt.get_or_f64;
            try builder.emit(.{ .call = .{ .dst = v.dst, .callee = callee, .args = v.args } });
        } else {
            try builder.emit(instruction);
        },
        else => try builder.emit(instruction),
    }
}

// `.new_aggregate`/`.build_variant`: `dst` — СОВЕРШЕННО НОВОЕ значение
// (собственный результат вызова alloc) — переиспользуется ниже
// несколько раз (по разу на каждое сохранение поля), поэтому нуждается
// в том же обращении сохранить-раз/перезагрузить-заново, что и везде в
// рукописном MIR этой кодовой базы (инвариант единственного
// использования). Возвращает локаль, которая его держит. `dst`,
// переданный вызывающим кодом, нельзя использовать напрямую как
// результат вызова alloc и ЗАТЕМ ещё раз потреблять его внутренне для
// повторных перезагрузок при сохранении полей — это тот же самый
// ValueId, для которого исходный (до раскрытия) поток инструкций уже
// держит РОВНО ОДНОГО потребителя (например, собственный `store_local`
// от `пер задача = Задача(...)`), сразу после позиции, где раньше
// стояла `.new_aggregate`/`.build_variant`. Поэтому здесь аллоцируем в
// СВЕЖЕЕ внутреннее значение, всю внутреннюю работу ведём через
// локаль, держащую ЕГО, и только в самом конце — через возвращённый
// `LocalId` — вызывающий код обязан эмитировать `load_local{dst,
// local}`, чтобы сделать переданный `dst` валидным, свежо, ровно один
// раз, на позиции, которую занимала исходная инструкция.
fn buildAllocInto(builder: *mir_builder.Builder, allocator: std.mem.Allocator, layout: wasm_heap.PtrLayout, size: u32) !mir.LocalId {
    _ = allocator;
    const size_const = try wasm_heap.addressConst(builder, layout.idx_type, size);
    const alloc_id = wasm_heap.findFunctionByName(builder.module, wasm_heap.alloc_function_name).?;
    const handle = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = handle, .callee = alloc_id, .args = try wasm_heap.dupeOne(builder.module, size_const) } });
    return wasm_heap.storeLocal(builder, "@obj", layout.ptr_type, handle);
}

// `object`/`value` у `set_property` — ОБА предсуществующие операнды
// (произведены своими более ранними инструкциями, в ИСХОДНОМ порядке
// `object`, затем `value`). Кодогенерации `frame_store` нужен
// ОБРАТНЫЙ порядок: `frame` (здесь — `object`) должен быть тем из
// двух, что протолкнут ПОЗЖЕ. Поскольку производителя ни одного из
// операндов сдвинуть нельзя, меняем их местами через две временные
// локали — забираем `value` (сейчас наверху) в локаль, забираем
// `object` (теперь открылся) в другую, затем проталкиваем `value`
// первым и `object` вторым, давая `frame_store` ровно нужный ему
// порядок `[src, frame]`. Это единственное место в ЭТОМ файле, где
// не работает применяемый повсюду сокращённый путь "свежее значение
// всегда последним", поскольку ОБА операнда предсуществующие.
fn emitReorderedStore(builder: *mir_builder.Builder, layout: wasm_heap.PtrLayout, object: mir.ValueId, value: mir.ValueId, field_index: u32) !void {
    const value_type = builder.currentFunction().valueType(value);
    const value_local = try wasm_heap.storeLocal(builder, "@val", value_type, value);
    const object_local = try wasm_heap.storeLocal(builder, "@obj", layout.ptr_type, object);
    const value_reload = try wasm_heap.loadLocal(builder, value_local, value_type);
    const object_reload = try wasm_heap.loadLocal(builder, object_local, layout.ptr_type);
    try builder.emit(.{ .frame_store = .{ .frame = object_reload, .slot = field_index, .src = value_reload } });
}

// --- Array runtime -------------------------------------------------------

// Публичная и идемпотентная (в отличие от подхода без кэширования в
// `wasm_heap.findOrBuildAlloc` — у `ArrayRuntime` целых 11 функций,
// которые пришлось бы заново находить по имени, так что здесь оправдан
// настоящий короткий путь через поиск по имени вместо поэлементного
// повторного вывода): вызывается также из `wasm_strings.zig`
// (`разбить` возвращает `Массив(Строка)`, нужны `@array_new`/
// `@array_append_i32`) — для модуля, у которого НЕТ другого
// собственного использования массивов, собственная проверка
// `usesArrays` в `wasm_objects.expand` сканирует только на
// `.new_array`/`.get_index`/`.set_index`/`@runtime::array_*`, под
// которые ещё не раскрытый вызов `строки::разбить` пока не подпадает
// (он становится массиво-возвращающим вызовом только ПОСЛЕ того, как
// его перепишет `wasm_strings.expand`) — поэтому `wasm_objects.expand`
// может вовсе пропустить построение array runtime к моменту, когда
// выполнится `wasm_strings.expand`.
pub fn findOrBuildArrayRuntime(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout) !ArrayRuntime {
    if (wasm_heap.findFunctionByName(module, "@array_new")) |new_id| {
        return .{
            .new = new_id,
            .ensure_capacity = wasm_heap.findFunctionByName(module, "@array_ensure_capacity").?,
            .append_i32 = wasm_heap.findFunctionByName(module, "@array_append_i32").?,
            .append_f64 = wasm_heap.findFunctionByName(module, "@array_append_f64").?,
            .get_i32 = wasm_heap.findFunctionByName(module, "@array_get_i32").?,
            .get_f64 = wasm_heap.findFunctionByName(module, "@array_get_f64").?,
            .get_or_i32 = wasm_heap.findFunctionByName(module, "@array_get_or_i32").?,
            .get_or_f64 = wasm_heap.findFunctionByName(module, "@array_get_or_f64").?,
            .set_i32 = wasm_heap.findFunctionByName(module, "@array_set_i32").?,
            .set_f64 = wasm_heap.findFunctionByName(module, "@array_set_f64").?,
            .length = wasm_heap.findFunctionByName(module, "@array_length").?,
        };
    }
    return buildArrayRuntime(allocator, module, type_store, layout);
}

fn buildArrayRuntime(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout) !ArrayRuntime {
    _ = try wasm_heap.findOrBuildAlloc(allocator, module, type_store, layout);
    const new_fn = try buildArrayNew(allocator, module, type_store, layout);
    const ensure = try buildEnsureCapacity(allocator, module, type_store, layout);
    const append_i32 = try buildAppend(allocator, module, type_store, layout, "@array_append_i32", layout.ptr_type, ensure);
    const append_f64 = try buildAppend(allocator, module, type_store, layout, "@array_append_f64", type_store.builtins.number, ensure);
    const get_i32 = try buildGet(allocator, module, type_store, layout, "@array_get_i32", layout.ptr_type);
    const get_f64 = try buildGet(allocator, module, type_store, layout, "@array_get_f64", type_store.builtins.number);
    const get_or_i32 = try buildGetOr(allocator, module, type_store, layout, "@array_get_or_i32", layout.ptr_type);
    const get_or_f64 = try buildGetOr(allocator, module, type_store, layout, "@array_get_or_f64", type_store.builtins.number);
    const set_i32 = try buildSet(allocator, module, type_store, layout, "@array_set_i32", layout.ptr_type);
    const set_f64 = try buildSet(allocator, module, type_store, layout, "@array_set_f64", type_store.builtins.number);
    const length_fn = try buildLength(allocator, module, type_store, layout);
    return .{
        .new = new_fn,
        .ensure_capacity = ensure,
        .append_i32 = append_i32,
        .append_f64 = append_f64,
        .get_i32 = get_i32,
        .get_f64 = get_f64,
        .get_or_i32 = get_or_i32,
        .get_or_f64 = get_or_f64,
        .set_i32 = set_i32,
        .set_f64 = set_f64,
        .length = length_fn,
    };
}

fn buildArrayNew(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@array_new", wasm_heap.dummy_symbol, layout.ptr_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    builder.currentFunction().parameters = &.{};
    builder.currentFunction().type_store = type_store;

    const size_const = try wasm_heap.addressConst(&builder, layout.idx_type, array_header_slots * 8);
    const alloc_id = wasm_heap.findFunctionByName(module, wasm_heap.alloc_function_name).?;
    const handle = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = handle, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, size_const) } });
    const handle_local = try wasm_heap.storeLocal(&builder, "@h", layout.ptr_type, handle);

    inline for (.{ length_slot, capacity_slot, data_ptr_slot }) |slot| {
        const zero = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
        const frame = try wasm_heap.loadLocal(&builder, handle_local, layout.ptr_type);
        try builder.emit(.{ .frame_store = .{ .frame = frame, .slot = slot, .src = zero } });
    }
    const result = try wasm_heap.loadLocal(&builder, handle_local, layout.ptr_type);
    builder.terminate(.{ .return_value = .{ .value = result } });
    return id;
}

// Единственное место, которому нужен настоящий (неразвёрнутый) `loop`
// WASM — количество элементов известно только во время выполнения.
// Обычная форма с одним заголовком/одним выходом (без suspend/CPS),
// в точности повторяющая собственный вывод `lowerWhile` в
// `mir_lowering.zig` (переход в заголовок, заголовок ветвится на
// тело/выход, тело заканчивается переходом обратно в заголовок) —
// попадает в существующий быстрый путь `wasm_stackify.zig`
// (`identifyLoopBodyAndExit`) без изменений.
fn buildEnsureCapacity(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@array_ensure_capacity", wasm_heap.dummy_symbol, type_store.builtins.void, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const handle_local = try builder.newLocal(wasm_heap.dummy_symbol, "handle", layout.ptr_type);
    const needed_local = try builder.newLocal(wasm_heap.dummy_symbol, "needed", layout.idx_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{ handle_local, needed_local });
    builder.currentFunction().type_store = type_store;

    const alloc_id = wasm_heap.findFunctionByName(module, wasm_heap.alloc_function_name).?;

    const frame1 = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    const capacity = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .frame_load = .{ .dst = capacity, .frame = frame1, .slot = capacity_slot } });
    const needed = try wasm_heap.loadLocal(&builder, needed_local, layout.idx_type);
    const enough = try wasm_heap.cmpOp(&builder, layout.bool_type, .greater_equal, capacity, needed);

    const grow_block = try builder.newBlock();
    const skip_block = try builder.newBlock();
    const after_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = enough, .then_block = skip_block, .else_block = grow_block } });

    builder.setCurrentBlock(skip_block);
    builder.terminate(.{ .jump = .{ .target = after_block } });

    builder.setCurrentBlock(grow_block);
    // Упрощено намеренно: `new_capacity = needed`, без амортизированного
    // удвоения. В худшем случае O(n^2) для повторяющихся добавлений по
    // одному элементу, зато корректно и НАМНОГО меньше поверхность
    // ветвлений, чем вычисление max(needed, capacity*2, 4). Пересмотреть
    // только если на практике это окажется значимым.
    const new_cap_bytes_src = try wasm_heap.loadLocal(&builder, needed_local, layout.idx_type);
    const eight = try wasm_heap.addressConst(&builder, layout.idx_type, 8);
    const new_cap_bytes = try wasm_heap.binOp(&builder, layout.idx_type, .multiply, new_cap_bytes_src, eight);
    const new_data = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = new_data, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, new_cap_bytes) } });
    const new_data_local = try wasm_heap.storeLocal(&builder, "@newdata", layout.ptr_type, new_data);

    // Copy loop: i = 0; while i < length { new_data[i] = old_data[i]; i += 1; }
    const length_for_loop = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    const length = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .frame_load = .{ .dst = length, .frame = length_for_loop, .slot = length_slot } });
    const length_local = try wasm_heap.storeLocal(&builder, "@len", layout.idx_type, length);
    const old_data_for_loop = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    const old_data = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .frame_load = .{ .dst = old_data, .frame = old_data_for_loop, .slot = data_ptr_slot } });
    const old_data_local = try wasm_heap.storeLocal(&builder, "@olddata", layout.ptr_type, old_data);
    const i_local = try builder.newLocal(wasm_heap.dummy_symbol, "@i", layout.idx_type);
    const zero_i = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    try builder.emit(.{ .store_local = .{ .local = i_local, .src = zero_i } });

    const loop_header = try builder.newBlock();
    builder.terminate(.{ .jump = .{ .target = loop_header } });

    builder.setCurrentBlock(loop_header);
    const i_for_cmp = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const length_for_cmp = try wasm_heap.loadLocal(&builder, length_local, layout.idx_type);
    const keep_going = try wasm_heap.cmpOp(&builder, layout.bool_type, .less, i_for_cmp, length_for_cmp);
    const loop_body = try builder.newBlock();
    const loop_exit = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = keep_going, .then_block = loop_body, .else_block = loop_exit } });

    builder.setCurrentBlock(loop_body);
    // Сырое копирование 8 байт через f64 load/store НЕЗАВИСИМО от
    // реального типа элемента — см. doc-комментарий файла.
    const i_for_addr1 = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const eight_a = try wasm_heap.addressConst(&builder, layout.idx_type, 8);
    const i_bytes_old = try wasm_heap.binOp(&builder, layout.idx_type, .multiply, i_for_addr1, eight_a);
    const old_data_for_addr = try wasm_heap.loadLocal(&builder, old_data_local, layout.ptr_type);
    const old_addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, old_data_for_addr, i_bytes_old);
    const elem = try builder.newValue(type_store.builtins.number);
    try builder.emit(.{ .mem_load = .{ .dst = elem, .addr = old_addr } });
    // `elem` (src) перезагружается ДО вычисления `new_addr` —
    // `mem_store` требует порядок стека `[src, addr]` (addr наверху,
    // свежайший — см. doc-комментарий `EmitContext.
    // frame_store_scratch_frame` в `wasm_emit.zig`, то же соглашение
    // разделяет `mem_store`).
    const elem_local = try wasm_heap.storeLocal(&builder, "@elem", type_store.builtins.number, elem);
    const elem_reload = try wasm_heap.loadLocal(&builder, elem_local, type_store.builtins.number);

    const i_for_addr2 = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const eight_b = try wasm_heap.addressConst(&builder, layout.idx_type, 8);
    const i_bytes_new = try wasm_heap.binOp(&builder, layout.idx_type, .multiply, i_for_addr2, eight_b);
    const new_data_for_addr = try wasm_heap.loadLocal(&builder, new_data_local, layout.ptr_type);
    const new_addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, new_data_for_addr, i_bytes_new);
    try builder.emit(.{ .mem_store = .{ .addr = new_addr, .src = elem_reload } });

    const i_next = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const one = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const i_incremented = try wasm_heap.binOp(&builder, layout.idx_type, .add, i_next, one);
    try builder.emit(.{ .store_local = .{ .local = i_local, .src = i_incremented } });
    builder.terminate(.{ .jump = .{ .target = loop_header } });

    builder.setCurrentBlock(loop_exit);
    const new_cap_for_store = try wasm_heap.loadLocal(&builder, needed_local, layout.idx_type);
    const handle_for_cap = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    try builder.emit(.{ .frame_store = .{ .frame = handle_for_cap, .slot = capacity_slot, .src = new_cap_for_store } });
    const new_data_for_store = try wasm_heap.loadLocal(&builder, new_data_local, layout.ptr_type);
    const handle_for_data = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    try builder.emit(.{ .frame_store = .{ .frame = handle_for_data, .slot = data_ptr_slot, .src = new_data_for_store } });
    builder.terminate(.{ .jump = .{ .target = after_block } });

    builder.setCurrentBlock(after_block);
    builder.terminate(.{ .return_value = .{ .value = null } });
    return id;
}

fn buildAppend(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout, name: []const u8, payload_type: types.TypeId, ensure_capacity: mir.FunctionId) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, name, wasm_heap.dummy_symbol, type_store.builtins.void, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const handle_local = try builder.newLocal(wasm_heap.dummy_symbol, "handle", layout.ptr_type);
    const value_local = try builder.newLocal(wasm_heap.dummy_symbol, "value", payload_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{ handle_local, value_local });
    builder.currentFunction().type_store = type_store;

    const frame_for_length = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    const length = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .frame_load = .{ .dst = length, .frame = frame_for_length, .slot = length_slot } });
    const length_local = try wasm_heap.storeLocal(&builder, "@len", layout.idx_type, length);

    // Собственные операнды `.call` должны быть ПРОИЗВЕДЕНЫ в порядке
    // параметров (производящая инструкция каждого аргумента сама его
    // проталкивает — кодогенерация `.call` сама по себе ничего не
    // делает) — сначала `handle`, потом `needed`, соответствуя сигнатуре
    // `@array_ensure_capacity(handle, needed)`.
    const handle_for_ensure = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    const length_for_needed = try wasm_heap.loadLocal(&builder, length_local, layout.idx_type);
    const one = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const needed = try wasm_heap.binOp(&builder, layout.idx_type, .add, length_for_needed, one);
    try builder.emit(.{ .call = .{ .dst = null, .callee = ensure_capacity, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ handle_for_ensure, needed }) } });

    // `value` перезагружается ДО вычисления `addr` — `mem_store`
    // требует `[src, addr]` (addr наверху/свежайший).
    const value_reload = try wasm_heap.loadLocal(&builder, value_local, payload_type);
    const length_for_addr = try wasm_heap.loadLocal(&builder, length_local, layout.idx_type);
    const eight = try wasm_heap.addressConst(&builder, layout.idx_type, 8);
    const byte_offset = try wasm_heap.binOp(&builder, layout.idx_type, .multiply, length_for_addr, eight);
    const frame_for_data = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    const data_ptr = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .frame_load = .{ .dst = data_ptr, .frame = frame_for_data, .slot = data_ptr_slot } });
    const addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, data_ptr, byte_offset);
    try builder.emit(.{ .mem_store = .{ .addr = addr, .src = value_reload } });

    const length_for_inc = try wasm_heap.loadLocal(&builder, length_local, layout.idx_type);
    const one_again = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const length_new = try wasm_heap.binOp(&builder, layout.idx_type, .add, length_for_inc, one_again);
    const frame_for_store = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    try builder.emit(.{ .frame_store = .{ .frame = frame_for_store, .slot = length_slot, .src = length_new } });
    builder.terminate(.{ .return_value = .{ .value = null } });
    return id;
}

// Общий для get/get_or/set помощник проверки границ: `index` (Число,
// f64, от пользователя) конвертируется в i32 один раз, сравнивается с
// `length`. Возвращает i32-индекс как ЛОКАЛЬ (не голый `ValueId`) —
// `fits` потребляется немедленно терминатором ветвления вызывающего
// кода, но индекс нужен только ПОЗЖЕ, внутри true-ветки
// (`elementAddr`), пересекая границу блока. `ValueId`, произведённый
// здесь и потреблённый после границы блока, невалиден по соглашению
// воспроизведения стека — вызывающие должны вместо этого перезагружать
// заново через `wasm_heap.loadLocal` в своей точке использования.
fn boundsCheck(builder: *mir_builder.Builder, layout: wasm_heap.PtrLayout, handle_local: mir.LocalId, index_local: mir.LocalId) !struct { index_local: mir.LocalId, fits: mir.ValueId } {
    const index_f64 = try wasm_heap.loadLocal(builder, index_local, builder.currentFunction().type_store.?.builtins.number);
    const index_i32 = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .unary = .{ .dst = index_i32, .op = .to_i32, .src = index_f64 } });
    const index_local2 = try wasm_heap.storeLocal(builder, "@idx", layout.idx_type, index_i32);
    const index_for_cmp = try wasm_heap.loadLocal(builder, index_local2, layout.idx_type);
    const in_bounds_low = try wasm_heap.addressConst(builder, layout.idx_type, 0);
    const not_negative = try wasm_heap.cmpOp(builder, layout.bool_type, .greater_equal, index_for_cmp, in_bounds_low);
    // `length` вычисляется и используется вплотную к `less_than_length`
    // ниже (между ними не производится/потребляется никакое другое
    // значение) — значения SSA с единственным использованием являются
    // настоящими значениями стека, а не регистрами, так что вычисление
    // `length` раньше операндов `not_negative` погребло бы его под ними
    // на реальном стеке WASM.
    const index_for_cmp2 = try wasm_heap.loadLocal(builder, index_local2, layout.idx_type);
    const frame_for_length = try wasm_heap.frameValue(builder, handle_local, layout.ptr_type);
    const length = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .frame_load = .{ .dst = length, .frame = frame_for_length, .slot = length_slot } });
    const less_than_length = try wasm_heap.cmpOp(builder, layout.bool_type, .less, index_for_cmp2, length);
    const fits = try wasm_heap.binOp(builder, layout.bool_type, .bit_and, not_negative, less_than_length);
    return .{ .index_local = index_local2, .fits = fits };
}

fn elementAddr(builder: *mir_builder.Builder, layout: wasm_heap.PtrLayout, handle_local: mir.LocalId, index_i32: mir.ValueId) !mir.ValueId {
    const eight = try wasm_heap.addressConst(builder, layout.idx_type, 8);
    const byte_offset = try wasm_heap.binOp(builder, layout.idx_type, .multiply, index_i32, eight);
    const frame_for_data = try wasm_heap.frameValue(builder, handle_local, layout.ptr_type);
    const data_ptr = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .frame_load = .{ .dst = data_ptr, .frame = frame_for_data, .slot = data_ptr_slot } });
    return wasm_heap.binOp(builder, layout.idx_type, .add, data_ptr, byte_offset);
}

// Выход за границы трапает (соответствует прежнему выбросу
// `RangeError` со стороны JS-хоста для обычных геттеров — принятая
// граница объёма Phase 1, тот же класс, что и трап при переполнении в
// `to_i32`).
fn buildGet(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout, name: []const u8, payload_type: types.TypeId) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, name, wasm_heap.dummy_symbol, payload_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const handle_local = try builder.newLocal(wasm_heap.dummy_symbol, "handle", layout.ptr_type);
    const index_local = try builder.newLocal(wasm_heap.dummy_symbol, "index", type_store.builtins.number);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{ handle_local, index_local });
    builder.currentFunction().type_store = type_store;

    const bounds = try boundsCheck(&builder, layout, handle_local, index_local);
    const ok_block = try builder.newBlock();
    const trap_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = bounds.fits, .then_block = ok_block, .else_block = trap_block } });

    builder.setCurrentBlock(trap_block);
    builder.terminate(.{ .unreachable_term = .{ .reason = "массив: индекс вне диапазона" } });

    builder.setCurrentBlock(ok_block);
    const index_reload = try wasm_heap.loadLocal(&builder, bounds.index_local, layout.idx_type);
    const addr = try elementAddr(&builder, layout, handle_local, index_reload);
    const value = try builder.newValue(payload_type);
    try builder.emit(.{ .mem_load = .{ .dst = value, .addr = addr } });
    builder.terminate(.{ .return_value = .{ .value = value } });
    return id;
}

fn buildGetOr(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout, name: []const u8, payload_type: types.TypeId) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, name, wasm_heap.dummy_symbol, payload_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const handle_local = try builder.newLocal(wasm_heap.dummy_symbol, "handle", layout.ptr_type);
    const index_local = try builder.newLocal(wasm_heap.dummy_symbol, "index", type_store.builtins.number);
    const fallback_local = try builder.newLocal(wasm_heap.dummy_symbol, "fallback", payload_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{ handle_local, index_local, fallback_local });
    builder.currentFunction().type_store = type_store;

    const bounds = try boundsCheck(&builder, layout, handle_local, index_local);
    const ok_block = try builder.newBlock();
    const fallback_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = bounds.fits, .then_block = ok_block, .else_block = fallback_block } });

    builder.setCurrentBlock(ok_block);
    const index_reload = try wasm_heap.loadLocal(&builder, bounds.index_local, layout.idx_type);
    const addr = try elementAddr(&builder, layout, handle_local, index_reload);
    const value = try builder.newValue(payload_type);
    try builder.emit(.{ .mem_load = .{ .dst = value, .addr = addr } });
    builder.terminate(.{ .return_value = .{ .value = value } });

    builder.setCurrentBlock(fallback_block);
    const fallback = try wasm_heap.loadLocal(&builder, fallback_local, payload_type);
    builder.terminate(.{ .return_value = .{ .value = fallback } });
    return id;
}

fn buildSet(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout, name: []const u8, payload_type: types.TypeId) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, name, wasm_heap.dummy_symbol, type_store.builtins.void, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const handle_local = try builder.newLocal(wasm_heap.dummy_symbol, "handle", layout.ptr_type);
    const index_local = try builder.newLocal(wasm_heap.dummy_symbol, "index", type_store.builtins.number);
    const value_local = try builder.newLocal(wasm_heap.dummy_symbol, "value", payload_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{ handle_local, index_local, value_local });
    builder.currentFunction().type_store = type_store;

    const bounds = try boundsCheck(&builder, layout, handle_local, index_local);
    const ok_block = try builder.newBlock();
    const trap_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = bounds.fits, .then_block = ok_block, .else_block = trap_block } });

    builder.setCurrentBlock(trap_block);
    builder.terminate(.{ .unreachable_term = .{ .reason = "массив: индекс вне диапазона" } });

    builder.setCurrentBlock(ok_block);
    // `value` перезагружается ДО вычисления `addr` — `mem_store`
    // требует `[src, addr]` (addr наверху/свежайший).
    const value_reload = try wasm_heap.loadLocal(&builder, value_local, payload_type);
    const index_reload = try wasm_heap.loadLocal(&builder, bounds.index_local, layout.idx_type);
    const addr = try elementAddr(&builder, layout, handle_local, index_reload);
    try builder.emit(.{ .mem_store = .{ .addr = addr, .src = value_reload } });
    builder.terminate(.{ .return_value = .{ .value = null } });
    return id;
}

fn buildLength(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@array_length", wasm_heap.dummy_symbol, type_store.builtins.number, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const handle_local = try builder.newLocal(wasm_heap.dummy_symbol, "handle", layout.ptr_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{handle_local});
    builder.currentFunction().type_store = type_store;

    const frame = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    const length_i32 = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .frame_load = .{ .dst = length_i32, .frame = frame, .slot = length_slot } });
    const length_f64 = try builder.newValue(type_store.builtins.number);
    try builder.emit(.{ .unary = .{ .dst = length_f64, .op = .from_i32, .src = length_i32 } });
    builder.terminate(.{ .return_value = .{ .value = length_f64 } });
    return id;
}
