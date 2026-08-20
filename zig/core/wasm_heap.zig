const std = @import("std");
const mir = @import("mir.zig");
const mir_builder = @import("mir_builder.zig");
const types = @import("types.zig");
const source = @import("source.zig");
const symbols = @import("symbols.zig");

// Общие помощники построения MIR + единственный bump-аллокатор,
// используемые ОБОИМИ проходами `wasm_actors.zig` и `wasm_objects.zig` —
// вынесены сюда, чтобы оба прохода безопасно делили ОДНУ кучу
// (global 0): какой проход выполнится первым, тот и создаст функцию
// `@runtime_alloc`, другой переиспользует её через поиск по имени
// (`findOrBuildAlloc`). Вызовы `alloc` из любого прохода читают/пишут
// один и тот же global, поэтому чередующиеся аллокации из обоих
// проходов безопасны по построению — ни одному из них не нужно знать,
// какой ДРУГОЙ проход тоже использует кучу.

pub const dummy_span: source.Span = .{ .file_id = 0, .start = 0, .end = 0 };
pub const dummy_symbol: symbols.SymbolId = @enumFromInt(0);

// Типы, достаточно широкие для настоящего WASM i32
// (`wasm_module.wasmValTypeForStore`) без изобретения нового типа
// уровня панос — `ptr_type` (переиспользует `Строка`) для адресов/
// хэндлов, `idx_type` (переиспользует `Булево`) для обычной целочисленной
// арифметики (индексы кольца/массива, счётчики), которая не должна
// пересекаться со спецкейсом конкатенации строк в `.binary` (тот
// проверяет равенство именно с `builtins.string` — `idx_type`
// намеренно этого избегает).
pub const PtrLayout = struct {
    ptr_type: types.TypeId,
    idx_type: types.TypeId,
    bool_type: types.TypeId,
};

pub fn findFunctionByName(module: *const mir.Module, name: []const u8) ?mir.FunctionId {
    for (module.functions.items) |function| {
        if (std.mem.eql(u8, function.name, name)) return function.id;
    }
    return null;
}

pub fn frameValue(builder: *mir_builder.Builder, frame_local: mir.LocalId, ptr_type: types.TypeId) !mir.ValueId {
    const dst = try builder.newValue(ptr_type);
    try builder.emit(.{ .load_local = .{ .dst = dst, .local = frame_local } });
    return dst;
}

pub fn addressConst(builder: *mir_builder.Builder, ptr_type: types.TypeId, value: u32) !mir.ValueId {
    const dst = try builder.newValue(ptr_type);
    try builder.emit(.{ .const_value = .{ .dst = dst, .value = .{ .address = value } } });
    return dst;
}

pub fn boolConst(builder: *mir_builder.Builder, bool_type: types.TypeId, value: bool) !mir.ValueId {
    const dst = try builder.newValue(bool_type);
    try builder.emit(.{ .const_value = .{ .dst = dst, .value = .{ .boolean = value } } });
    return dst;
}

// `addressConst` выше всегда эмитит `.address` (i32.const) — это не
// годится для значения типа f64 (`Число`), которому нужен `.number`
// (f64.const).
pub fn numberConst(builder: *mir_builder.Builder, number_type: types.TypeId, value: f64) !mir.ValueId {
    const dst = try builder.newValue(number_type);
    try builder.emit(.{ .const_value = .{ .dst = dst, .value = .{ .number = value } } });
    return dst;
}

pub fn binOp(builder: *mir_builder.Builder, result_type: types.TypeId, op: mir.BinOp, lhs: mir.ValueId, rhs: mir.ValueId) !mir.ValueId {
    const dst = try builder.newValue(result_type);
    try builder.emit(.{ .binary = .{ .dst = dst, .op = op, .lhs = lhs, .rhs = rhs } });
    return dst;
}

pub fn cmpOp(builder: *mir_builder.Builder, bool_type: types.TypeId, op: mir.CmpOp, lhs: mir.ValueId, rhs: mir.ValueId) !mir.ValueId {
    const dst = try builder.newValue(bool_type);
    try builder.emit(.{ .compare = .{ .dst = dst, .op = op, .lhs = lhs, .rhs = rhs } });
    return dst;
}

pub fn notOp(builder: *mir_builder.Builder, bool_type: types.TypeId, value: mir.ValueId) !mir.ValueId {
    const dst = try builder.newValue(bool_type);
    try builder.emit(.{ .unary = .{ .dst = dst, .op = .negate_bool, .src = value } });
    return dst;
}

// Главное правило всего файла (наследуется каждым вызывающим кодом):
// `ValueId` — это ЗНАЧЕНИЕ СТЕКА, потребляемое своим единственным
// использованием в момент, когда `wasm_emit.zig` его воспроизводит —
// повторное использование в двух и более последующих инструкциях
// (инвариант единственного использования в `mir_validate.zig`) — это
// невалидный MIR, а не вопрос стиля. Любое значение, нужное более
// одного раза, ДОЛЖНО пройти через настоящий `Local` (сохранить один
// раз, перезагружать заново при каждом использовании) — именно это
// `frameValue` уже делает для указателя на фрейм; `storeLocal`/
// `loadLocal` обобщают это на любое другое повторно используемое
// значение.
pub fn storeLocal(builder: *mir_builder.Builder, name: []const u8, type_id: types.TypeId, value: mir.ValueId) !mir.LocalId {
    const local = try builder.newLocal(dummy_symbol, name, type_id);
    try builder.emit(.{ .store_local = .{ .local = local, .src = value } });
    return local;
}

pub fn loadLocal(builder: *mir_builder.Builder, local: mir.LocalId, type_id: types.TypeId) !mir.ValueId {
    const dst = try builder.newValue(type_id);
    try builder.emit(.{ .load_local = .{ .dst = dst, .local = local } });
    return dst;
}

pub fn dupeOne(module: *mir.Module, value: mir.ValueId) ![]const mir.ValueId {
    return module.arena.allocator().dupe(mir.ValueId, &.{value});
}

pub const alloc_function_name = "@runtime_alloc";

// 64 KiB — фиксированный размер страницы WASM (`memory.size`/
// `memory.grow` всегда оперируют в этих единицах, никогда напрямую в
// байтах).
const wasm_page_bytes: u32 = 65536;

fn buildAlloc(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: PtrLayout) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, alloc_function_name, dummy_symbol, layout.ptr_type, dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const size_local = try builder.newLocal(dummy_symbol, "size", layout.idx_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{size_local});
    builder.currentFunction().type_store = type_store;

    const size = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .load_local = .{ .dst = size, .local = size_local } });
    const ptr = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .global_get = .{ .dst = ptr, .global = 0 } });
    const ptr_local = try storeLocal(&builder, "ptr", layout.ptr_type, ptr); // `ptr` используется ниже дважды (сложение, возврат) — обязан идти через Local
    const ptr_for_add = try loadLocal(&builder, ptr_local, layout.ptr_type);
    // Результат типизирован как `idx_type`, а не `ptr_type`
    // (`builtins.string`) — кодогенерация `.binary` спецкейсит ЛЮБОЙ
    // результат типа `builtins.string` как конкатенацию строк
    // (`wasm_emit.zig`), что превратило бы эту арифметику
    // bump-указателя в вызов хостового string-concat импорта.
    // `global_set` заботится только о базовом примитиве WASM (i32,
    // одинаковом для `idx_type`/`ptr_type` здесь), так что конвертация
    // не нужна.
    const new_ptr = try binOp(&builder, layout.idx_type, .add, ptr_for_add, size);
    const new_ptr_local = try storeLocal(&builder, "new_ptr", layout.idx_type, new_ptr);

    // Bump-указатель нужно сверять с ФАКТИЧЕСКИМ размером памяти
    // модуля — аллокация за пределами начального числа страниц
    // (зафиксированного на этапе компиляции, `wasm_emit.zig`'s
    // `actor_heap_base`) иначе трапнет с "memory access out of bounds"
    // при первом же чтении/записи через возвращённый указатель. Память
    // нужно растить СНАЧАЛА, только когда это реально требуется, до
    // того как указатель за текущей границей будет кому-то отдан.
    // Инструкция MIR `compare`/`binary` не проталкивает свои операнды
    // заново — она потребляет то, что уже лежит на стеке WASM, в
    // порядке ЭМИССИИ (порядке программы), независимо от того, что
    // в этом Zig-коде записано как `lhs`/`rhs`. `new_ptr_for_cmp`
    // ОБЯЗАН быть загружен первым здесь, чтобы оказаться снизу
    // двухоперандного окна стека, соответствуя аргументу `lhs` в
    // `cmpOp`.
    const new_ptr_for_cmp = try loadLocal(&builder, new_ptr_local, layout.idx_type);
    const pages = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .memory_size = .{ .dst = pages } });
    const page_bytes_const = try addressConst(&builder, layout.idx_type, wasm_page_bytes);
    const current_bytes = try binOp(&builder, layout.idx_type, .multiply, pages, page_bytes_const);
    const needs_growth = try cmpOp(&builder, layout.bool_type, .greater, new_ptr_for_cmp, current_bytes);

    // Только один уровень ветвления — определение точки слияния
    // (`findMerge`) в `wasm_stackify.zig` полагается на то, что CFG
    // остаётся РЕДУЦИРУЕМЫМ, как его всегда порождает лоуеринг если/
    // иначе в `mir_lowering.zig` (слияние каждой ветви — блок,
    // доминируемый ТОЛЬКО этой ветвью). Второе, вложенное ветвление
    // внутри `grow_block`, делящее ТО ЖЕ слияние `ok_block`, что и
    // внешняя ветвь, это нарушает (доминатором `ok_block` становится
    // внешняя ветвь, а не `grow_block`). Поэтому по результату
    // `memory.grow` ветвление вообще не делается второй раз: реальный
    // сбой роста (упёрлись в лимит памяти хоста) просто проваливается
    // в тот же трап "memory access out of bounds" при следующем
    // чтении/записи за границей — по-настоящему закончившаяся память
    // хоста всё равно не то, из чего этот аллокатор способен
    // восстановиться.
    const grow_block = try builder.newBlock();
    const ok_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = needs_growth, .then_block = grow_block, .else_block = ok_block } });

    builder.setCurrentBlock(grow_block);
    const new_ptr_for_grow = try loadLocal(&builder, new_ptr_local, layout.idx_type);
    // `pages`/`page_bytes_const` (использованы выше, в условии ветвления)
    // — значения стека, уже потреблённые тем единственным
    // использованием — здесь заново выводим свежие копии вместо
    // переиспользования (инвариант единственного использования, см.
    // комментарий на уровне файла про `ValueId`).
    const pages_fresh = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .memory_size = .{ .dst = pages_fresh } });
    const page_bytes_const2 = try addressConst(&builder, layout.idx_type, wasm_page_bytes);
    const current_bytes_for_grow = try binOp(&builder, layout.idx_type, .multiply, pages_fresh, page_bytes_const2);
    const additional_bytes = try binOp(&builder, layout.idx_type, .subtract, new_ptr_for_grow, current_bytes_for_grow);
    const round_up_const = try addressConst(&builder, layout.idx_type, wasm_page_bytes - 1);
    const rounded_bytes = try binOp(&builder, layout.idx_type, .add, additional_bytes, round_up_const);
    const page_bytes_const3 = try addressConst(&builder, layout.idx_type, wasm_page_bytes);
    const additional_pages = try binOp(&builder, layout.idx_type, .int_divide, rounded_bytes, page_bytes_const3);
    const grow_result = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .memory_grow = .{ .dst = grow_result, .pages = additional_pages } });
    builder.terminate(.{ .jump = .{ .target = ok_block } });

    builder.setCurrentBlock(ok_block);
    const new_ptr_for_set = try loadLocal(&builder, new_ptr_local, layout.idx_type);
    try builder.emit(.{ .global_set = .{ .global = 0, .src = new_ptr_for_set } });
    const ptr_for_return = try loadLocal(&builder, ptr_local, layout.ptr_type);
    builder.terminate(.{ .return_value = .{ .value = ptr_for_return } });
    return id;
}

pub const permanent_alloc_function_name = "@runtime_alloc_permanent";

// Global 1: bump-указатель постоянной области (изменяемый, стартует с
// `actor_heap_base` по разметке памяти из `wasm_emit.zig`). Global 2:
// НЕИЗМЕНЯЕМАЯ константа-потолок — фиксированная граница между
// постоянной областью и ареной (`global 0`) — `wasm_emit.zig`
// вычисляет и записывает её реальное значение при финальной сборке
// модуля, УЖЕ ПОСЛЕ того, как эта функция построена как MIR;
// обращение к ней по ИНДЕКСУ global (а не по фактическому числовому
// значению на момент построения MIR) — то, что делает этот порядок
// рабочим, точно так же как `buildAlloc` выше нужен только ИНДЕКС
// global 0, но никогда не его значение.
pub const permanent_heap_global_index: u32 = 1;
pub const permanent_ceiling_global_index: u32 = 2;

// Фиксированный бюджет постоянной области — одна страница WASM. С
// запасом для реального сценария использования (горстка мелких строк
// context-id обработчиков DOM), задокументированное ограничение Phase 1
// в остальном (см. doc-комментарий `buildAllocPermanent`) —
// используется `wasm_emit.zig` для расчёта размера зарезервированного
// промежутка в разметке памяти модуля.
pub const permanent_reserved_bytes: u32 = 65536;

// Сборщику мусора Phase 1 (сброс арены при каждом вызове точки входа
// со стороны JS, `wasm_gc_arena.zig`) нужно, чтобы ЧТО-ТО пережило
// сброс — контекст отложенного колбэка DOM (`DOM.после_кадра`) или
// замыкание клика, которые JS захватывает НАПРЯМУЮ через два ОТДЕЛЬНЫХ
// будущих вызова экспорта. Безусловный сброс арены освободил бы эту
// строку из-под JS на самом следующем клике. Эта вторая,
// не сбрасываемая bump-область — куда такие значения ПРОМОУТЯТСЯ
// (копируются) точно на месте лоуеринга отложенного колбэка/замыкания
// (`mir_lowering.zig`) — всё остальное продолжает идти через обычную
// арену (`buildAlloc`/global 0).
//
// Намеренно НЕ растёт через `memory.grow`, в отличие от арены —
// фиксированный бюджет (зарезервированный промежуток в
// `wasm_emit.zig`), трапает с понятной диагностикой при превышении.
// Настоящий поэкземплярный сборщик (Phase 2) заменил бы этот обходной
// путь настоящим корнем GC вместо ограничения ёмкости; Phase 1
// принимает лимит как задокументированную границу объёма, а не тихий
// отказ.
fn buildAllocPermanent(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: PtrLayout) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, permanent_alloc_function_name, dummy_symbol, layout.ptr_type, dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const size_local = try builder.newLocal(dummy_symbol, "size", layout.idx_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{size_local});
    builder.currentFunction().type_store = type_store;

    const size = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .load_local = .{ .dst = size, .local = size_local } });
    const ptr = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .global_get = .{ .dst = ptr, .global = permanent_heap_global_index } });
    const ptr_local = try storeLocal(&builder, "ptr", layout.ptr_type, ptr);
    const ptr_for_add = try loadLocal(&builder, ptr_local, layout.ptr_type);
    const new_ptr = try binOp(&builder, layout.idx_type, .add, ptr_for_add, size);
    const new_ptr_local = try storeLocal(&builder, "new_ptr", layout.idx_type, new_ptr);

    // Для стековой машины важен порядок ЭМИССИИ операндов, а не то,
    // что объявлено как `lhs`/`rhs` — см. комментарий `buildAlloc` про
    // этот же класс проблемы. `new_ptr` загружается первым, `ceiling`
    // вторым, чтобы `lhs`/`rhs` в `.greater` действительно совпадали
    // с порядком на стеке.
    const new_ptr_for_cmp = try loadLocal(&builder, new_ptr_local, layout.idx_type);
    const ceiling = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .global_get = .{ .dst = ceiling, .global = permanent_ceiling_global_index } });
    const overflow = try cmpOp(&builder, layout.bool_type, .greater, new_ptr_for_cmp, ceiling);

    const overflow_block = try builder.newBlock();
    const ok_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = overflow, .then_block = overflow_block, .else_block = ok_block } });

    builder.setCurrentBlock(overflow_block);
    builder.terminate(.{ .unreachable_term = .{ .reason = "постоянная область WASM-кучи исчерпана (Phase 1 GC, фиксированный бюджет)" } });

    builder.setCurrentBlock(ok_block);
    const new_ptr_for_set = try loadLocal(&builder, new_ptr_local, layout.idx_type);
    try builder.emit(.{ .global_set = .{ .global = permanent_heap_global_index, .src = new_ptr_for_set } });
    const ptr_for_return = try loadLocal(&builder, ptr_local, layout.ptr_type);
    builder.terminate(.{ .return_value = .{ .value = ptr_for_return } });
    return id;
}

pub fn findOrBuildAllocPermanent(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: PtrLayout) !mir.FunctionId {
    if (findFunctionByName(module, permanent_alloc_function_name)) |id| return id;
    return buildAllocPermanent(allocator, module, type_store, layout);
}

// Побайтовый цикл копирования `count_local` байт из `src_base_local` в
// `dst_base_local` — продублирован из собственной (приватной)
// `emitByteCopyLoop` в `wasm_strings.zig`, а не импортирован оттуда:
// `wasm_strings.zig` уже импортирует ЭТОТ файл (`wasm_heap.zig`) как
// общий низкоуровневый субстрат, так что обратный импорт был бы
// циклическим. Держится в точном соответствии с той версией (та же
// последовательность инструкций, тот же порядок стека — байт
// перезагружается до вычисления `dst_addr`).
fn emitByteCopyLoop(builder: *mir_builder.Builder, layout: PtrLayout, src_base_local: mir.LocalId, dst_base_local: mir.LocalId, count_local: mir.LocalId) !void {
    const i_local = try builder.newLocal(dummy_symbol, "@i", layout.idx_type);
    const zero = try addressConst(builder, layout.idx_type, 0);
    try builder.emit(.{ .store_local = .{ .local = i_local, .src = zero } });

    const loop_header = try builder.newBlock();
    builder.terminate(.{ .jump = .{ .target = loop_header } });

    builder.setCurrentBlock(loop_header);
    const i_for_cmp = try loadLocal(builder, i_local, layout.idx_type);
    const count_for_cmp = try loadLocal(builder, count_local, layout.idx_type);
    const keep_going = try cmpOp(builder, layout.bool_type, .less, i_for_cmp, count_for_cmp);
    const loop_body = try builder.newBlock();
    const loop_exit = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = keep_going, .then_block = loop_body, .else_block = loop_exit } });

    builder.setCurrentBlock(loop_body);
    const i_for_src = try loadLocal(builder, i_local, layout.idx_type);
    const src_base_r = try loadLocal(builder, src_base_local, layout.idx_type);
    const src_addr = try binOp(builder, layout.idx_type, .add, src_base_r, i_for_src);
    const byte = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load8 = .{ .dst = byte, .addr = src_addr } });
    const byte_local = try storeLocal(builder, "@byte", layout.idx_type, byte);
    const byte_reload = try loadLocal(builder, byte_local, layout.idx_type);

    const i_for_dst = try loadLocal(builder, i_local, layout.idx_type);
    const dst_base_r = try loadLocal(builder, dst_base_local, layout.idx_type);
    const dst_addr = try binOp(builder, layout.idx_type, .add, dst_base_r, i_for_dst);
    try builder.emit(.{ .mem_store8 = .{ .addr = dst_addr, .src = byte_reload } });

    const i_next_src = try loadLocal(builder, i_local, layout.idx_type);
    const one = try addressConst(builder, layout.idx_type, 1);
    const i_next = try binOp(builder, layout.idx_type, .add, i_next_src, one);
    try builder.emit(.{ .store_local = .{ .local = i_local, .src = i_next } });
    builder.terminate(.{ .jump = .{ .target = loop_header } });

    builder.setCurrentBlock(loop_exit);
}

pub const promote_to_permanent_function_name = "@promote_to_permanent";

// `@promote_to_permanent(src: Строка) -> Строка`: копирует целиком
// строку с префиксом длины (`[u32 byte_length][bytes...]` — см. про
// эту раскладку doc-комментарий `wasm_strings.zig`) откуда бы она ни
// жила сейчас (арена или даже секция read-only данных для литерала) в
// постоянную область, байт-в-байт вместе с заголовком длины — копии не
// нужно интерпретировать длину вообще, кроме как использовать её как
// счётчик байт, поскольку заголовок — это просто первые 4 байта того
// же самого копируемого буфера.
fn buildPromoteToPermanent(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: PtrLayout) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, promote_to_permanent_function_name, dummy_symbol, layout.ptr_type, dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const src_local = try builder.newLocal(dummy_symbol, "src", layout.ptr_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{src_local});
    builder.currentFunction().type_store = type_store;

    const src_for_len = try loadLocal(&builder, src_local, layout.ptr_type);
    const len = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load = .{ .dst = len, .addr = src_for_len } });
    const four = try addressConst(&builder, layout.idx_type, 4);
    const total_size = try binOp(&builder, layout.idx_type, .add, len, four);
    const total_size_local = try storeLocal(&builder, "total_size", layout.idx_type, total_size);

    const alloc_id = try findOrBuildAllocPermanent(allocator, module, type_store, layout);
    const size_for_call = try loadLocal(&builder, total_size_local, layout.idx_type);
    const dst = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = dst, .callee = alloc_id, .args = try dupeOne(module, size_for_call) } });
    const dst_local = try storeLocal(&builder, "dst", layout.ptr_type, dst);

    try emitByteCopyLoop(&builder, layout, src_local, dst_local, total_size_local);

    const dst_for_return = try loadLocal(&builder, dst_local, layout.ptr_type);
    builder.terminate(.{ .return_value = .{ .value = dst_for_return } });
    return id;
}

pub fn findOrBuildPromoteToPermanent(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: PtrLayout) !mir.FunctionId {
    if (findFunctionByName(module, promote_to_permanent_function_name)) |id| return id;
    return buildPromoteToPermanent(allocator, module, type_store, layout);
}

pub const promote_bytes_to_permanent_function_name = "@promote_bytes_to_permanent";

// `@promote_bytes_to_permanent(src: Строка, size: idx) -> Строка`: как
// `@promote_to_permanent` выше, но `size` — явный аргумент ВРЕМЕНИ
// ВЫПОЛНЕНИЯ, а не читается из заголовка-префикса длины — для
// копирования сырого блока фиксированного размера без такого
// заголовка, например аллокации окружения замыкания WASM AOT (лоуеринг
// `на_клик` на основе замыканий в `mir_lowering.zig` — ENV/BOX
// замыкания тоже должны жить в постоянной области, не только его
// (пока только скалярные) захваченные ЗНАЧЕНИЯ, иначе сам указатель
// box повис бы после следующего сброса арены — тот же класс проблемы,
// что `@promote_to_permanent` уже решает для строки контекста
// отложенного колбэка, на уровень выше по цепочке указателей).
fn buildPromoteBytesToPermanent(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: PtrLayout) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, promote_bytes_to_permanent_function_name, dummy_symbol, layout.ptr_type, dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const src_local = try builder.newLocal(dummy_symbol, "src", layout.ptr_type);
    const size_local = try builder.newLocal(dummy_symbol, "size", layout.idx_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{ src_local, size_local });
    builder.currentFunction().type_store = type_store;

    const alloc_id = try findOrBuildAllocPermanent(allocator, module, type_store, layout);
    const size_for_call = try loadLocal(&builder, size_local, layout.idx_type);
    const dst = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = dst, .callee = alloc_id, .args = try dupeOne(module, size_for_call) } });
    const dst_local = try storeLocal(&builder, "dst", layout.ptr_type, dst);

    try emitByteCopyLoop(&builder, layout, src_local, dst_local, size_local);

    const dst_for_return = try loadLocal(&builder, dst_local, layout.ptr_type);
    builder.terminate(.{ .return_value = .{ .value = dst_for_return } });
    return id;
}

pub fn findOrBuildPromoteBytesToPermanent(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: PtrLayout) !mir.FunctionId {
    if (findFunctionByName(module, promote_bytes_to_permanent_function_name)) |id| return id;
    return buildPromoteBytesToPermanent(allocator, module, type_store, layout);
}

// Кэш по имени функции не хранится намеренно: `FunctionId` валиден
// только для ОДНОГО `mir.Module`, в котором был выделен — процесс-
// глобальный кэш был бы устаревшим между отдельными компиляциями в
// рамках одного процесса (например, между кейсами `zig test`).
// `findFunctionByName` — дешёвое линейное сканирование, вызывается не
// более нескольких раз за компиляцию, кэшировать между компиляциями
// незачем вовсе.
pub fn findOrBuildAlloc(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: PtrLayout) !mir.FunctionId {
    if (findFunctionByName(module, alloc_function_name)) |id| return id;
    return buildAlloc(allocator, module, type_store, layout);
}
