const std = @import("std");
const mir = @import("mir.zig");
const mir_builder = @import("mir_builder.zig");
const types = @import("types.zig");
const wasm_heap = @import("wasm_heap.zig");
const wasm_module = @import("wasm_module.zig");
const wasm_objects = @import("wasm_objects.zig");

// Раскрывает `Соответствие` (map) под AOT WASM — новая runtime-структура,
// СТРОГО с СТРОКОВЫМИ ключами (см. обсуждение при реализации: в
// байткод-VM ключом может быть значение любого типа, `Value.eql`
// диспетчеризует по тегу; полное соответствие этому под AOT потребовало
// бы структурную равность с типовым dispatch для произвольных агрегатов/
// массивов — заметно больше объёма, чем оправдано текущим реальным
// использованием, где КАЖДЫЙ вызывающий код — и `std/кодирование/
// json.pns`, и марьяшка — использует только `Строка` в качестве ключа).
// Нестроковый ключ — явная ошибка компиляции под `--target=wasm`
// (`lowerMapLiteral`/`lowerMapMethodCall`, `mir_lowering.zig`), а не
// молчаливо неверное поведение.
//
// Представление — тот же 3-слотовый заголовок `{length, capacity,
// data_ptr}` в бамп-куче, что и `wasm_objects.zig`'s ArrayRuntime, но с
// ШИРИНОЙ ЗАПИСИ 16 БАЙТ (не 8) — пара [key: i32-хендл строки, value:
// raw 8 байт] на запись, `length`/`capacity` считаются в ЗАПИСЯХ, не в
// байтах/слотах (так `.длина()` не требует деления). Поиск по ключу —
// линейное сканирование с побайтовым сравнением через уже существующий
// `@string_equal` (`wasm_strings.zig`) — та же дисциплина "association
// list, не хэш-таблица", что и в байткод-VM (`value.zig`'s `Map`).

pub const MapRuntime = struct {
    new: mir.FunctionId,
    set_i32: mir.FunctionId,
    set_f64: mir.FunctionId,
    get_i32: mir.FunctionId,
    get_f64: mir.FunctionId,
    get_or_i32: mir.FunctionId,
    get_or_f64: mir.FunctionId,
    has: mir.FunctionId,
    length: mir.FunctionId,
    entries_i32: mir.FunctionId,
    entries_f64: mir.FunctionId,
};

const map_length_slot: u32 = 0;
const map_capacity_slot: u32 = 1;
const map_data_ptr_slot: u32 = 2;
// `frame_store`/`frame_load` адресуют по `slot*8` (`wasm_emit.zig`,
// "i32.const slot*8") — заголовок из 3 слотов занимает 24 байта, НЕ 12
// (реальный найденный баг: изначально было 12, `map_data_ptr_slot`
// писал/читал за границей аллокации — `.записи()` тихо возвращал
// пустой массив, `.длина()` — 0, при том что `[]=`/перезапись работали
// случайно правильно, потому что capacity/length оказывались рядом по
// памяти с чем-то, что тоже читалось как 0).
const map_header_bytes: u32 = 24;
const map_entry_bytes: u32 = 16;

fn isMapBuiltinCall(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "@runtime::map_");
}

pub fn usesMaps(module: *const mir.Module) bool {
    for (module.functions.items) |function| for (function.blocks.items) |block|
        for (block.instructions.items) |instruction| switch (instruction) {
            .call_builtin => |v| if (isMapBuiltinCall(v.name)) return true,
            else => {},
        };
    return false;
}

// Не зависит от `wasm_strings.zig`'s `@string_equal` — тот строится
// только если `wasm_strings.expand` увидел строковую операцию в ИСХОДНОМ
// пользовательском коде (`usesStringOps`), а карта с ключами-литералами,
// которые нигде больше не сравниваются/не конкатенируются явно, могла бы
// не вызвать эту постройку вообще (проходы независимы, порядок в
// `cli/main.zig` не гарантия видимости друг для друга на уровне
// сканирования). Строит собственную копию сравнения строк — тот же
// побайтовый цикл, что `buildEqual` в `wasm_strings.zig`, самодостаточно.
pub fn expand(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore) !void {
    if (!usesMaps(module)) return;

    const layout = wasm_heap.PtrLayout{
        .ptr_type = type_store.builtins.string,
        .idx_type = type_store.builtins.boolean,
        .bool_type = type_store.builtins.boolean,
    };
    _ = try wasm_heap.findOrBuildAlloc(allocator, module, type_store, layout);
    const array_runtime = try wasm_objects.findOrBuildArrayRuntime(allocator, module, type_store, layout);
    const string_equal = try buildStringEqual(allocator, module, type_store, layout);

    const new_fn = try buildMapNew(allocator, module, type_store, layout);
    const ensure = try buildMapEnsureCapacity(allocator, module, type_store, layout);
    const find = try buildMapFind(allocator, module, type_store, layout, string_equal);
    const set_i32 = try buildMapSet(allocator, module, type_store, layout, "@map_set_i32", layout.ptr_type, ensure, find);
    const set_f64 = try buildMapSet(allocator, module, type_store, layout, "@map_set_f64", type_store.builtins.number, ensure, find);
    const get_i32 = try buildMapGet(allocator, module, type_store, layout, "@map_get_i32", layout.ptr_type, find);
    const get_f64 = try buildMapGet(allocator, module, type_store, layout, "@map_get_f64", type_store.builtins.number, find);
    const get_or_i32 = try buildMapGetOr(allocator, module, type_store, layout, "@map_get_or_i32", layout.ptr_type, find);
    const get_or_f64 = try buildMapGetOr(allocator, module, type_store, layout, "@map_get_or_f64", type_store.builtins.number, find);
    const has = try buildMapHas(allocator, module, type_store, layout, find);
    const length_fn = try buildMapLength(allocator, module, type_store, layout);
    const entries_i32 = try buildMapEntries(allocator, module, type_store, layout, array_runtime, "@map_entries_i32", layout.ptr_type);
    const entries_f64 = try buildMapEntries(allocator, module, type_store, layout, array_runtime, "@map_entries_f64", type_store.builtins.number);

    const runtime = MapRuntime{
        .new = new_fn,
        .set_i32 = set_i32,
        .set_f64 = set_f64,
        .get_i32 = get_i32,
        .get_f64 = get_f64,
        .get_or_i32 = get_or_i32,
        .get_or_f64 = get_or_f64,
        .has = has,
        .length = length_fn,
        .entries_i32 = entries_i32,
        .entries_f64 = entries_f64,
    };

    var index: usize = 0;
    while (index < module.functions.items.len) : (index += 1) {
        const function_id: mir.FunctionId = @enumFromInt(index);
        const block_count = module.functions.items[index].blocks.items.len;
        var block_index: usize = 0;
        while (block_index < block_count) : (block_index += 1) {
            var builder = mir_builder.Builder{ .module = module, .allocator = allocator, .function_id = function_id };
            try expandBlock(&builder, allocator, @enumFromInt(block_index), runtime);
        }
    }
}

fn expandBlock(builder: *mir_builder.Builder, allocator: std.mem.Allocator, block_id: mir.BlockId, runtime: MapRuntime) !void {
    const function = builder.currentFunction();
    var original = function.blockConst(block_id).*;
    function.block(block_id).instructions = .empty;
    builder.setCurrentBlock(block_id);
    builder.terminated = false;

    for (original.instructions.items) |instruction| {
        switch (instruction) {
            .call_builtin => |v| {
                const callee: ?mir.FunctionId = blk: {
                    if (std.mem.eql(u8, v.name, "@runtime::map_new")) break :blk runtime.new;
                    if (std.mem.eql(u8, v.name, "@runtime::map_set_i32")) break :blk runtime.set_i32;
                    if (std.mem.eql(u8, v.name, "@runtime::map_set_f64")) break :blk runtime.set_f64;
                    if (std.mem.eql(u8, v.name, "@runtime::map_get_i32")) break :blk runtime.get_i32;
                    if (std.mem.eql(u8, v.name, "@runtime::map_get_f64")) break :blk runtime.get_f64;
                    if (std.mem.eql(u8, v.name, "@runtime::map_get_or_i32")) break :blk runtime.get_or_i32;
                    if (std.mem.eql(u8, v.name, "@runtime::map_get_or_f64")) break :blk runtime.get_or_f64;
                    if (std.mem.eql(u8, v.name, "@runtime::map_has")) break :blk runtime.has;
                    if (std.mem.eql(u8, v.name, "@runtime::map_length")) break :blk runtime.length;
                    if (std.mem.eql(u8, v.name, "@runtime::map_entries_i32")) break :blk runtime.entries_i32;
                    if (std.mem.eql(u8, v.name, "@runtime::map_entries_f64")) break :blk runtime.entries_f64;
                    break :blk null;
                };
                if (callee) |fn_id| {
                    try builder.emit(.{ .call = .{ .dst = v.dst, .callee = fn_id, .args = v.args } });
                    continue;
                }
                try builder.emit(instruction);
            },
            else => try builder.emit(instruction),
        }
    }
    builder.terminate(original.terminator);
    original.instructions.deinit(allocator);
}

// `@map_new() -> handle`: тот же паттерн, что `buildArrayNew`
// (`wasm_objects.zig`), просто отдельная функция — map и array рантаймы
// не разделяют аллокатор функций (нет смысла, размер тела тривиален).
fn buildMapNew(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@map_new", wasm_heap.dummy_symbol, layout.ptr_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    builder.currentFunction().parameters = &.{};
    builder.currentFunction().type_store = type_store;

    const size_const = try wasm_heap.addressConst(&builder, layout.idx_type, map_header_bytes);
    const alloc_id = wasm_heap.findFunctionByName(module, wasm_heap.alloc_function_name).?;
    const handle = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = handle, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, size_const) } });
    const handle_local = try wasm_heap.storeLocal(&builder, "@h", layout.ptr_type, handle);

    inline for (.{ map_length_slot, map_capacity_slot, map_data_ptr_slot }) |slot| {
        const zero = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
        const frame = try wasm_heap.loadLocal(&builder, handle_local, layout.ptr_type);
        try builder.emit(.{ .frame_store = .{ .frame = frame, .slot = slot, .src = zero } });
    }
    const result = try wasm_heap.loadLocal(&builder, handle_local, layout.ptr_type);
    builder.terminate(.{ .return_value = .{ .value = result } });
    return id;
}

// `@map_ensure_capacity(handle, needed_entries)`: тот же копирующий цикл,
// что `buildEnsureCapacity` (`wasm_objects.zig`), но со страйдом 16 байт
// (2 слота на запись — key+value) вместо 8.
fn buildMapEnsureCapacity(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@map_ensure_capacity", wasm_heap.dummy_symbol, type_store.builtins.void, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const handle_local = try builder.newLocal(wasm_heap.dummy_symbol, "handle", layout.ptr_type);
    const needed_local = try builder.newLocal(wasm_heap.dummy_symbol, "needed", layout.idx_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{ handle_local, needed_local });
    builder.currentFunction().type_store = type_store;

    const alloc_id = wasm_heap.findFunctionByName(module, wasm_heap.alloc_function_name).?;

    const frame1 = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    const capacity = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .frame_load = .{ .dst = capacity, .frame = frame1, .slot = map_capacity_slot } });
    const needed = try wasm_heap.loadLocal(&builder, needed_local, layout.idx_type);
    const enough = try wasm_heap.cmpOp(&builder, layout.bool_type, .greater_equal, capacity, needed);

    const grow_block = try builder.newBlock();
    const skip_block = try builder.newBlock();
    const after_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = enough, .then_block = skip_block, .else_block = grow_block } });

    builder.setCurrentBlock(skip_block);
    builder.terminate(.{ .jump = .{ .target = after_block } });

    builder.setCurrentBlock(grow_block);
    const new_cap_bytes_src = try wasm_heap.loadLocal(&builder, needed_local, layout.idx_type);
    const sixteen = try wasm_heap.addressConst(&builder, layout.idx_type, map_entry_bytes);
    const new_cap_bytes = try wasm_heap.binOp(&builder, layout.idx_type, .multiply, new_cap_bytes_src, sixteen);
    const new_data = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = new_data, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, new_cap_bytes) } });
    const new_data_local = try wasm_heap.storeLocal(&builder, "@newdata", layout.ptr_type, new_data);

    // Копируем `length*2` 8-байтовых слотов (key+value на запись) —
    // ровно тот же цикл, что `buildEnsureCapacity`, просто с удвоенным
    // счётчиком слотов.
    const length_for_loop = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    const length = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .frame_load = .{ .dst = length, .frame = length_for_loop, .slot = map_length_slot } });
    const two_a = try wasm_heap.addressConst(&builder, layout.idx_type, 2);
    const slot_count = try wasm_heap.binOp(&builder, layout.idx_type, .multiply, length, two_a);
    const slot_count_local = try wasm_heap.storeLocal(&builder, "@slots", layout.idx_type, slot_count);
    const old_data_for_loop = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    const old_data = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .frame_load = .{ .dst = old_data, .frame = old_data_for_loop, .slot = map_data_ptr_slot } });
    const old_data_local = try wasm_heap.storeLocal(&builder, "@olddata", layout.ptr_type, old_data);
    const i_local = try builder.newLocal(wasm_heap.dummy_symbol, "@i", layout.idx_type);
    const zero_i = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    try builder.emit(.{ .store_local = .{ .local = i_local, .src = zero_i } });

    const loop_header = try builder.newBlock();
    builder.terminate(.{ .jump = .{ .target = loop_header } });

    builder.setCurrentBlock(loop_header);
    const i_for_cmp = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const slots_for_cmp = try wasm_heap.loadLocal(&builder, slot_count_local, layout.idx_type);
    const keep_going = try wasm_heap.cmpOp(&builder, layout.bool_type, .less, i_for_cmp, slots_for_cmp);
    const loop_body = try builder.newBlock();
    const loop_exit = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = keep_going, .then_block = loop_body, .else_block = loop_exit } });

    builder.setCurrentBlock(loop_body);
    const i_for_addr1 = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const eight_a = try wasm_heap.addressConst(&builder, layout.idx_type, 8);
    const i_bytes_old = try wasm_heap.binOp(&builder, layout.idx_type, .multiply, i_for_addr1, eight_a);
    const old_data_for_addr = try wasm_heap.loadLocal(&builder, old_data_local, layout.idx_type);
    const old_addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, old_data_for_addr, i_bytes_old);
    const elem = try builder.newValue(type_store.builtins.number);
    try builder.emit(.{ .mem_load = .{ .dst = elem, .addr = old_addr } });
    const elem_local = try wasm_heap.storeLocal(&builder, "@elem", type_store.builtins.number, elem);
    const elem_reload = try wasm_heap.loadLocal(&builder, elem_local, type_store.builtins.number);

    const i_for_addr2 = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const eight_b = try wasm_heap.addressConst(&builder, layout.idx_type, 8);
    const i_bytes_new = try wasm_heap.binOp(&builder, layout.idx_type, .multiply, i_for_addr2, eight_b);
    const new_data_for_addr = try wasm_heap.loadLocal(&builder, new_data_local, layout.idx_type);
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
    try builder.emit(.{ .frame_store = .{ .frame = handle_for_cap, .slot = map_capacity_slot, .src = new_cap_for_store } });
    const new_data_for_store = try wasm_heap.loadLocal(&builder, new_data_local, layout.ptr_type);
    const handle_for_data = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    try builder.emit(.{ .frame_store = .{ .frame = handle_for_data, .slot = map_data_ptr_slot, .src = new_data_for_store } });
    builder.terminate(.{ .jump = .{ .target = after_block } });

    builder.setCurrentBlock(after_block);
    builder.terminate(.{ .return_value = .{ .value = null } });
    return id;
}

// Побайтовое сравнение строк — самодостаточная копия `buildEqual`
// (`wasm_strings.zig`), см. doc-комментарий `expand` выше про причину
// дублирования вместо переиспользования.
fn buildStringEqual(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@map_string_equal", wasm_heap.dummy_symbol, layout.bool_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const a_local = try builder.newLocal(wasm_heap.dummy_symbol, "a", layout.ptr_type);
    const b_local = try builder.newLocal(wasm_heap.dummy_symbol, "b", layout.ptr_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{ a_local, b_local });
    builder.currentFunction().type_store = type_store;

    const a1 = try wasm_heap.loadLocal(&builder, a_local, layout.ptr_type);
    const len_a = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load = .{ .dst = len_a, .addr = a1 } });
    const len_a_local = try wasm_heap.storeLocal(&builder, "len_a", layout.idx_type, len_a);

    const b1 = try wasm_heap.loadLocal(&builder, b_local, layout.ptr_type);
    const len_b = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load = .{ .dst = len_b, .addr = b1 } });
    const len_b_local = try wasm_heap.storeLocal(&builder, "len_b", layout.idx_type, len_b);

    const len_a_for_cmp = try wasm_heap.loadLocal(&builder, len_a_local, layout.idx_type);
    const len_b_for_cmp = try wasm_heap.loadLocal(&builder, len_b_local, layout.idx_type);
    const same_len = try wasm_heap.cmpOp(&builder, layout.bool_type, .equal, len_a_for_cmp, len_b_for_cmp);

    const compare_block = try builder.newBlock();
    const not_equal_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = same_len, .then_block = compare_block, .else_block = not_equal_block } });

    builder.setCurrentBlock(not_equal_block);
    const false_val = try wasm_heap.boolConst(&builder, layout.bool_type, false);
    builder.terminate(.{ .return_value = .{ .value = false_val } });

    builder.setCurrentBlock(compare_block);
    const four = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const a_for_base = try wasm_heap.loadLocal(&builder, a_local, layout.ptr_type);
    const a_base = try wasm_heap.binOp(&builder, layout.idx_type, .add, a_for_base, four);
    const a_base_local = try wasm_heap.storeLocal(&builder, "a_base", layout.idx_type, a_base);
    const four2 = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const b_for_base = try wasm_heap.loadLocal(&builder, b_local, layout.ptr_type);
    const b_base = try wasm_heap.binOp(&builder, layout.idx_type, .add, b_for_base, four2);
    const b_base_local = try wasm_heap.storeLocal(&builder, "b_base", layout.idx_type, b_base);

    const i_local = try builder.newLocal(wasm_heap.dummy_symbol, "@i", layout.idx_type);
    const zero = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    try builder.emit(.{ .store_local = .{ .local = i_local, .src = zero } });

    const loop_header = try builder.newBlock();
    builder.terminate(.{ .jump = .{ .target = loop_header } });

    builder.setCurrentBlock(loop_header);
    const i_for_cmp = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const len_for_cmp = try wasm_heap.loadLocal(&builder, len_a_local, layout.idx_type);
    const keep_going = try wasm_heap.cmpOp(&builder, layout.bool_type, .less, i_for_cmp, len_for_cmp);
    const loop_body = try builder.newBlock();
    const loop_exit = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = keep_going, .then_block = loop_body, .else_block = loop_exit } });

    builder.setCurrentBlock(loop_body);
    const i_for_a = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const a_base_r = try wasm_heap.loadLocal(&builder, a_base_local, layout.idx_type);
    const a_addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, a_base_r, i_for_a);
    const byte_a = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load8 = .{ .dst = byte_a, .addr = a_addr } });
    const byte_a_local = try wasm_heap.storeLocal(&builder, "@byte_a", layout.idx_type, byte_a);

    const i_for_b = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const b_base_r = try wasm_heap.loadLocal(&builder, b_base_local, layout.idx_type);
    const b_addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, b_base_r, i_for_b);
    const byte_b = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load8 = .{ .dst = byte_b, .addr = b_addr } });

    const byte_a_reload = try wasm_heap.loadLocal(&builder, byte_a_local, layout.idx_type);
    const bytes_equal = try wasm_heap.cmpOp(&builder, layout.bool_type, .equal, byte_a_reload, byte_b);
    const mismatch_block = try builder.newBlock();
    const continue_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = bytes_equal, .then_block = continue_block, .else_block = mismatch_block } });

    builder.setCurrentBlock(mismatch_block);
    const false_val2 = try wasm_heap.boolConst(&builder, layout.bool_type, false);
    builder.terminate(.{ .return_value = .{ .value = false_val2 } });

    builder.setCurrentBlock(continue_block);
    const i_next_src = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const one = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const i_next = try wasm_heap.binOp(&builder, layout.idx_type, .add, i_next_src, one);
    try builder.emit(.{ .store_local = .{ .local = i_local, .src = i_next } });
    builder.terminate(.{ .jump = .{ .target = loop_header } });

    builder.setCurrentBlock(loop_exit);
    const true_val = try wasm_heap.boolConst(&builder, layout.bool_type, true);
    builder.terminate(.{ .return_value = .{ .value = true_val } });

    return id;
}

// `@map_find(handle, key) -> i32`: линейное сканирование, возвращает
// индекс ЗАПИСИ (не байтовый offset) первого совпадения по `@string_equal`,
// либо -1. Общий примитив для get/get_or/has/set (все они начинают с
// поиска существующей записи) — тот же принцип "один примитив, много
// вызывающих", что `@string_index_of` в `wasm_strings.zig`.
fn buildMapFind(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout, string_equal: mir.FunctionId) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@map_find", wasm_heap.dummy_symbol, layout.idx_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const handle_local = try builder.newLocal(wasm_heap.dummy_symbol, "handle", layout.ptr_type);
    const key_local = try builder.newLocal(wasm_heap.dummy_symbol, "key", layout.ptr_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{ handle_local, key_local });
    builder.currentFunction().type_store = type_store;

    const frame_len = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    const length = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .frame_load = .{ .dst = length, .frame = frame_len, .slot = map_length_slot } });
    const length_local = try wasm_heap.storeLocal(&builder, "@len", layout.idx_type, length);

    const frame_data = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    const data_ptr = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .frame_load = .{ .dst = data_ptr, .frame = frame_data, .slot = map_data_ptr_slot } });
    const data_local = try wasm_heap.storeLocal(&builder, "@data", layout.idx_type, data_ptr);

    const i_local = try builder.newLocal(wasm_heap.dummy_symbol, "@i", layout.idx_type);
    const zero_i = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    try builder.emit(.{ .store_local = .{ .local = i_local, .src = zero_i } });

    const loop_header = try builder.newBlock();
    builder.terminate(.{ .jump = .{ .target = loop_header } });

    builder.setCurrentBlock(loop_header);
    const i_for_cmp = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const len_for_cmp = try wasm_heap.loadLocal(&builder, length_local, layout.idx_type);
    const keep_going = try wasm_heap.cmpOp(&builder, layout.bool_type, .less, i_for_cmp, len_for_cmp);
    const loop_body = try builder.newBlock();
    const not_found_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = keep_going, .then_block = loop_body, .else_block = not_found_block } });

    builder.setCurrentBlock(not_found_block);
    const zero_nf = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    const one_nf = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const neg_one = try wasm_heap.binOp(&builder, layout.idx_type, .subtract, zero_nf, one_nf);
    builder.terminate(.{ .return_value = .{ .value = neg_one } });

    builder.setCurrentBlock(loop_body);
    const i_for_off = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const sixteen = try wasm_heap.addressConst(&builder, layout.idx_type, map_entry_bytes);
    const byte_off = try wasm_heap.binOp(&builder, layout.idx_type, .multiply, i_for_off, sixteen);
    const data_for_addr = try wasm_heap.loadLocal(&builder, data_local, layout.idx_type);
    const key_addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, data_for_addr, byte_off);
    const stored_key = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .mem_load = .{ .dst = stored_key, .addr = key_addr } });

    const key_for_call = try wasm_heap.loadLocal(&builder, key_local, layout.ptr_type);
    const matches = try builder.newValue(layout.bool_type);
    try builder.emit(.{ .call = .{ .dst = matches, .callee = string_equal, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ stored_key, key_for_call }) } });

    const found_block = try builder.newBlock();
    const next_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = matches, .then_block = found_block, .else_block = next_block } });

    builder.setCurrentBlock(found_block);
    const i_final = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    builder.terminate(.{ .return_value = .{ .value = i_final } });

    builder.setCurrentBlock(next_block);
    const i_next = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const one_n = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const i_incr = try wasm_heap.binOp(&builder, layout.idx_type, .add, i_next, one_n);
    try builder.emit(.{ .store_local = .{ .local = i_local, .src = i_incr } });
    builder.terminate(.{ .jump = .{ .target = loop_header } });

    return id;
}

// `@map_set_{i32,f64}(handle, key, value)`: `@map_find` — если найдено,
// перезаписывает value на месте (ключ уникален для `[]=`, в отличие от
// литерала — см. doc-комментарий файла-заголовка про `buildMap` в
// `vm.zig`, где ЛИТЕРАЛ не дедуплицирует, а `[]=` перезаписывает); иначе
// растит и добавляет новую запись — тот же ensure+append принцип, что
// `buildAppend` (`wasm_objects.zig`).
fn buildMapSet(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout, name: []const u8, payload_type: types.TypeId, ensure_capacity: mir.FunctionId, find: mir.FunctionId) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, name, wasm_heap.dummy_symbol, type_store.builtins.void, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const handle_local = try builder.newLocal(wasm_heap.dummy_symbol, "handle", layout.ptr_type);
    const key_local = try builder.newLocal(wasm_heap.dummy_symbol, "key", layout.ptr_type);
    const value_local = try builder.newLocal(wasm_heap.dummy_symbol, "value", payload_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{ handle_local, key_local, value_local });
    builder.currentFunction().type_store = type_store;

    const handle_for_find = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    const key_for_find = try wasm_heap.loadLocal(&builder, key_local, layout.ptr_type);
    const found_index = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .call = .{ .dst = found_index, .callee = find, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ handle_for_find, key_for_find }) } });
    const found_index_local = try wasm_heap.storeLocal(&builder, "@found", layout.idx_type, found_index);

    const found_for_cmp = try wasm_heap.loadLocal(&builder, found_index_local, layout.idx_type);
    const neg_one_c = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    const one_c = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const neg_one_const = try wasm_heap.binOp(&builder, layout.idx_type, .subtract, neg_one_c, one_c);
    const is_new = try wasm_heap.cmpOp(&builder, layout.bool_type, .equal, found_for_cmp, neg_one_const);

    const insert_block = try builder.newBlock();
    const overwrite_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = is_new, .then_block = insert_block, .else_block = overwrite_block } });

    builder.setCurrentBlock(overwrite_block);
    {
        // Каждый промежуточный адрес-компонент сразу уходит в свою
        // локаль — избегает хрупкого ручного отслеживания порядка стека
        // между несвязанными вычислениями (адрес vs значение).
        const idx_for_off = try wasm_heap.loadLocal(&builder, found_index_local, layout.idx_type);
        const sixteen = try wasm_heap.addressConst(&builder, layout.idx_type, map_entry_bytes);
        const byte_off = try wasm_heap.binOp(&builder, layout.idx_type, .multiply, idx_for_off, sixteen);
        const eight = try wasm_heap.addressConst(&builder, layout.idx_type, 8);
        const value_off = try wasm_heap.binOp(&builder, layout.idx_type, .add, byte_off, eight);
        const value_off_local = try wasm_heap.storeLocal(&builder, "@voff", layout.idx_type, value_off);

        const frame_data = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
        const data_ptr = try builder.newValue(layout.ptr_type);
        try builder.emit(.{ .frame_load = .{ .dst = data_ptr, .frame = frame_data, .slot = map_data_ptr_slot } });
        const value_off_reload = try wasm_heap.loadLocal(&builder, value_off_local, layout.idx_type);
        const value_addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, data_ptr, value_off_reload);
        const value_addr_local = try wasm_heap.storeLocal(&builder, "@vaddr", layout.idx_type, value_addr);

        const value_for_store = try wasm_heap.loadLocal(&builder, value_local, payload_type);
        const value_addr_reload = try wasm_heap.loadLocal(&builder, value_addr_local, layout.idx_type);
        try builder.emit(.{ .mem_store = .{ .addr = value_addr_reload, .src = value_for_store } });
        builder.terminate(.{ .return_value = .{ .value = null } });
    }

    builder.setCurrentBlock(insert_block);
    {
        const frame_len = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
        const length = try builder.newValue(layout.idx_type);
        try builder.emit(.{ .frame_load = .{ .dst = length, .frame = frame_len, .slot = map_length_slot } });
        const length_local = try wasm_heap.storeLocal(&builder, "@len", layout.idx_type, length);

        const handle_for_ensure = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
        const length_for_needed = try wasm_heap.loadLocal(&builder, length_local, layout.idx_type);
        const one_e = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
        const needed = try wasm_heap.binOp(&builder, layout.idx_type, .add, length_for_needed, one_e);
        try builder.emit(.{ .call = .{ .dst = null, .callee = ensure_capacity, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ handle_for_ensure, needed }) } });

        const length_for_off = try wasm_heap.loadLocal(&builder, length_local, layout.idx_type);
        const sixteen2 = try wasm_heap.addressConst(&builder, layout.idx_type, map_entry_bytes);
        const byte_off2 = try wasm_heap.binOp(&builder, layout.idx_type, .multiply, length_for_off, sixteen2);
        const byte_off2_local = try wasm_heap.storeLocal(&builder, "@boff", layout.idx_type, byte_off2);
        const frame_data2 = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
        const data_ptr2 = try builder.newValue(layout.ptr_type);
        try builder.emit(.{ .frame_load = .{ .dst = data_ptr2, .frame = frame_data2, .slot = map_data_ptr_slot } });
        const byte_off2_reload = try wasm_heap.loadLocal(&builder, byte_off2_local, layout.idx_type);
        const entry_addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, data_ptr2, byte_off2_reload);
        const entry_addr_local = try wasm_heap.storeLocal(&builder, "@eaddr", layout.idx_type, entry_addr);

        const key_for_store = try wasm_heap.loadLocal(&builder, key_local, layout.ptr_type);
        const key_addr = try wasm_heap.loadLocal(&builder, entry_addr_local, layout.idx_type);
        try builder.emit(.{ .mem_store = .{ .addr = key_addr, .src = key_for_store } });

        const value_for_store2 = try wasm_heap.loadLocal(&builder, value_local, payload_type);
        const eight2 = try wasm_heap.addressConst(&builder, layout.idx_type, 8);
        const entry_addr_for_value = try wasm_heap.loadLocal(&builder, entry_addr_local, layout.idx_type);
        const value_addr2 = try wasm_heap.binOp(&builder, layout.idx_type, .add, entry_addr_for_value, eight2);
        try builder.emit(.{ .mem_store = .{ .addr = value_addr2, .src = value_for_store2 } });

        const length_for_inc = try wasm_heap.loadLocal(&builder, length_local, layout.idx_type);
        const one_i = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
        const length_new = try wasm_heap.binOp(&builder, layout.idx_type, .add, length_for_inc, one_i);
        const frame_for_store = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
        try builder.emit(.{ .frame_store = .{ .frame = frame_for_store, .slot = map_length_slot, .src = length_new } });
        builder.terminate(.{ .return_value = .{ .value = null } });
    }

    return id;
}

// `@map_get_{i32,f64}(handle, key) -> value`: `[key]` без запасного —
// трапает при отсутствии ключа, тот же контракт, что `getIndex`'s
// `.map`-ветка в `vm.zig` ("ключ отсутствует в соответствии").
fn buildMapGet(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout, name: []const u8, payload_type: types.TypeId, find: mir.FunctionId) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, name, wasm_heap.dummy_symbol, payload_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const handle_local = try builder.newLocal(wasm_heap.dummy_symbol, "handle", layout.ptr_type);
    const key_local = try builder.newLocal(wasm_heap.dummy_symbol, "key", layout.ptr_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{ handle_local, key_local });
    builder.currentFunction().type_store = type_store;

    const handle_for_find = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    const key_for_find = try wasm_heap.loadLocal(&builder, key_local, layout.ptr_type);
    const found_index = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .call = .{ .dst = found_index, .callee = find, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ handle_for_find, key_for_find }) } });
    const found_index_local = try wasm_heap.storeLocal(&builder, "@found", layout.idx_type, found_index);

    const found_for_cmp = try wasm_heap.loadLocal(&builder, found_index_local, layout.idx_type);
    const zero_c = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    const one_c = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const neg_one_const = try wasm_heap.binOp(&builder, layout.idx_type, .subtract, zero_c, one_c);
    const missing = try wasm_heap.cmpOp(&builder, layout.bool_type, .equal, found_for_cmp, neg_one_const);

    const trap_block = try builder.newBlock();
    const found_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = missing, .then_block = trap_block, .else_block = found_block } });

    builder.setCurrentBlock(trap_block);
    builder.terminate(.{ .unreachable_term = .{ .reason = "ключ отсутствует в соответствии" } });

    builder.setCurrentBlock(found_block);
    const idx_for_off = try wasm_heap.loadLocal(&builder, found_index_local, layout.idx_type);
    const sixteen = try wasm_heap.addressConst(&builder, layout.idx_type, map_entry_bytes);
    const byte_off = try wasm_heap.binOp(&builder, layout.idx_type, .multiply, idx_for_off, sixteen);
    const eight = try wasm_heap.addressConst(&builder, layout.idx_type, 8);
    const value_off = try wasm_heap.binOp(&builder, layout.idx_type, .add, byte_off, eight);
    const frame_data = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    const data_ptr = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .frame_load = .{ .dst = data_ptr, .frame = frame_data, .slot = map_data_ptr_slot } });
    const value_addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, data_ptr, value_off);
    const value = try builder.newValue(payload_type);
    try builder.emit(.{ .mem_load = .{ .dst = value, .addr = value_addr } });
    builder.terminate(.{ .return_value = .{ .value = value } });
    return id;
}

// `.получить(key, default)` — то же самое, что `@map_get_*`, только
// возвращает `default` вместо трапа при отсутствии ключа.
fn buildMapGetOr(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout, name: []const u8, payload_type: types.TypeId, find: mir.FunctionId) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, name, wasm_heap.dummy_symbol, payload_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const handle_local = try builder.newLocal(wasm_heap.dummy_symbol, "handle", layout.ptr_type);
    const key_local = try builder.newLocal(wasm_heap.dummy_symbol, "key", layout.ptr_type);
    const default_local = try builder.newLocal(wasm_heap.dummy_symbol, "default", payload_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{ handle_local, key_local, default_local });
    builder.currentFunction().type_store = type_store;

    const handle_for_find = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    const key_for_find = try wasm_heap.loadLocal(&builder, key_local, layout.ptr_type);
    const found_index = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .call = .{ .dst = found_index, .callee = find, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ handle_for_find, key_for_find }) } });
    const found_index_local = try wasm_heap.storeLocal(&builder, "@found", layout.idx_type, found_index);

    const found_for_cmp = try wasm_heap.loadLocal(&builder, found_index_local, layout.idx_type);
    const zero_c = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    const one_c = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const neg_one_const = try wasm_heap.binOp(&builder, layout.idx_type, .subtract, zero_c, one_c);
    const missing = try wasm_heap.cmpOp(&builder, layout.bool_type, .equal, found_for_cmp, neg_one_const);

    const default_block = try builder.newBlock();
    const found_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = missing, .then_block = default_block, .else_block = found_block } });

    builder.setCurrentBlock(default_block);
    const default_value = try wasm_heap.loadLocal(&builder, default_local, payload_type);
    builder.terminate(.{ .return_value = .{ .value = default_value } });

    builder.setCurrentBlock(found_block);
    const idx_for_off = try wasm_heap.loadLocal(&builder, found_index_local, layout.idx_type);
    const sixteen = try wasm_heap.addressConst(&builder, layout.idx_type, map_entry_bytes);
    const byte_off = try wasm_heap.binOp(&builder, layout.idx_type, .multiply, idx_for_off, sixteen);
    const eight = try wasm_heap.addressConst(&builder, layout.idx_type, 8);
    const value_off = try wasm_heap.binOp(&builder, layout.idx_type, .add, byte_off, eight);
    const frame_data = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    const data_ptr = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .frame_load = .{ .dst = data_ptr, .frame = frame_data, .slot = map_data_ptr_slot } });
    const value_addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, data_ptr, value_off);
    const value = try builder.newValue(payload_type);
    try builder.emit(.{ .mem_load = .{ .dst = value, .addr = value_addr } });
    builder.terminate(.{ .return_value = .{ .value = value } });
    return id;
}

// `.есть(key) -> Булево`.
fn buildMapHas(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout, find: mir.FunctionId) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@map_has", wasm_heap.dummy_symbol, layout.bool_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const handle_local = try builder.newLocal(wasm_heap.dummy_symbol, "handle", layout.ptr_type);
    const key_local = try builder.newLocal(wasm_heap.dummy_symbol, "key", layout.ptr_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{ handle_local, key_local });
    builder.currentFunction().type_store = type_store;

    const handle_for_find = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    const key_for_find = try wasm_heap.loadLocal(&builder, key_local, layout.ptr_type);
    const found_index = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .call = .{ .dst = found_index, .callee = find, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ handle_for_find, key_for_find }) } });

    const zero_c = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    const one_c = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const neg_one_const = try wasm_heap.binOp(&builder, layout.idx_type, .subtract, zero_c, one_c);
    const result = try wasm_heap.cmpOp(&builder, layout.bool_type, .not_equal, found_index, neg_one_const);
    builder.terminate(.{ .return_value = .{ .value = result } });
    return id;
}

// `.длина() -> Число`.
fn buildMapLength(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@map_length", wasm_heap.dummy_symbol, type_store.builtins.number, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const handle_local = try builder.newLocal(wasm_heap.dummy_symbol, "handle", layout.ptr_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{handle_local});
    builder.currentFunction().type_store = type_store;

    const frame = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    const length_i32 = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .frame_load = .{ .dst = length_i32, .frame = frame, .slot = map_length_slot } });
    const length_f64 = try builder.newValue(type_store.builtins.number);
    try builder.emit(.{ .unary = .{ .dst = length_f64, .op = .from_i32, .src = length_i32 } });
    builder.terminate(.{ .return_value = .{ .value = length_f64 } });
    return id;
}

// `.записи() -> Массив((Строка, V))`: строит массив 2-элементных кортежей
// [key, value] — та же runtime-форма, что и обычный кортеж (2-слотовый
// фрейм в бамп-куче), но построенный НАПРЯМУЮ через `alloc`+`frame_store`
// (НЕ через `.new_aggregate`) — `.new_aggregate` раскрывается ТОЛЬКО
// проходом `wasm_objects.expand`, который в конвейере (`cli/main.zig`)
// запускается ДО `wasm_maps.expand`; функции, построенные ЭТИМ проходом,
// никогда бы не попались тому более раннему проходу для раскрытия. Прямая
// сборка избегает этой хрупкой межпроходной зависимости от порядка
// целиком, тот же принцип, что у собственной копии `@map_string_equal`
// выше.
//
// `payload_type` — i32 или f64 вариант значения карты (реальный
// найденный баг: первая версия ВСЕГДА читала/писала значение как i32,
// что для `Соответствие(Строка, Число)` тихо давало 0/мусор вместо
// настоящего f64-значения — тот же класс бага, что get/get_or/set уже
// решают своим i32/f64 расщеплением, просто изначально забытый именно
// здесь).
fn buildMapEntries(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout, array_runtime: wasm_objects.ArrayRuntime, name: []const u8, payload_type: types.TypeId) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, name, wasm_heap.dummy_symbol, layout.ptr_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const handle_local = try builder.newLocal(wasm_heap.dummy_symbol, "handle", layout.ptr_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{handle_local});
    builder.currentFunction().type_store = type_store;

    const frame_len = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    const length = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .frame_load = .{ .dst = length, .frame = frame_len, .slot = map_length_slot } });
    const length_local = try wasm_heap.storeLocal(&builder, "@len", layout.idx_type, length);

    const arr = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = arr, .callee = array_runtime.new, .args = &.{} } });
    const arr_local = try wasm_heap.storeLocal(&builder, "@arr", layout.ptr_type, arr);

    const i_local = try builder.newLocal(wasm_heap.dummy_symbol, "@i", layout.idx_type);
    const zero_i = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    try builder.emit(.{ .store_local = .{ .local = i_local, .src = zero_i } });

    const loop_header = try builder.newBlock();
    builder.terminate(.{ .jump = .{ .target = loop_header } });

    builder.setCurrentBlock(loop_header);
    const i_for_cmp = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const len_for_cmp = try wasm_heap.loadLocal(&builder, length_local, layout.idx_type);
    const keep_going = try wasm_heap.cmpOp(&builder, layout.bool_type, .less, i_for_cmp, len_for_cmp);
    const loop_body = try builder.newBlock();
    const loop_exit = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = keep_going, .then_block = loop_body, .else_block = loop_exit } });

    builder.setCurrentBlock(loop_body);
    const i_for_off = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const sixteen = try wasm_heap.addressConst(&builder, layout.idx_type, map_entry_bytes);
    const byte_off = try wasm_heap.binOp(&builder, layout.idx_type, .multiply, i_for_off, sixteen);
    const frame_data = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    const data_ptr = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .frame_load = .{ .dst = data_ptr, .frame = frame_data, .slot = map_data_ptr_slot } });
    const key_addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, data_ptr, byte_off);
    const key_addr_local = try wasm_heap.storeLocal(&builder, "@kaddr", layout.idx_type, key_addr);
    const key_addr_for_load = try wasm_heap.loadLocal(&builder, key_addr_local, layout.idx_type);
    const key = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .mem_load = .{ .dst = key, .addr = key_addr_for_load } });
    // `key`/`value` каждый сразу уходит в свою локаль — иначе оба висели
    // бы непотреблёнными через несколько несвязанных промежуточных
    // вычислений (адрес значения, аллокация пары), ломая порядок стека
    // (тот же класс бага, что был найден и исправлен в `buildMapSet`).
    const key_local = try wasm_heap.storeLocal(&builder, "@key", layout.ptr_type, key);

    const eight = try wasm_heap.addressConst(&builder, layout.idx_type, 8);
    const key_addr_for_value = try wasm_heap.loadLocal(&builder, key_addr_local, layout.idx_type);
    const value_addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, key_addr_for_value, eight);
    const value = try builder.newValue(payload_type);
    try builder.emit(.{ .mem_load = .{ .dst = value, .addr = value_addr } });
    const value_local = try wasm_heap.storeLocal(&builder, "@value", payload_type, value);

    const pair_size = try wasm_heap.addressConst(&builder, layout.idx_type, 16);
    const alloc_id = wasm_heap.findFunctionByName(module, wasm_heap.alloc_function_name).?;
    const pair = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = pair, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, pair_size) } });
    const pair_local = try wasm_heap.storeLocal(&builder, "@pair", layout.ptr_type, pair);
    const key_reload = try wasm_heap.loadLocal(&builder, key_local, layout.ptr_type);
    const pair_for_key = try wasm_heap.loadLocal(&builder, pair_local, layout.ptr_type);
    try builder.emit(.{ .frame_store = .{ .frame = pair_for_key, .slot = 0, .src = key_reload } });
    const value_reload = try wasm_heap.loadLocal(&builder, value_local, payload_type);
    const pair_for_value = try wasm_heap.loadLocal(&builder, pair_local, layout.ptr_type);
    try builder.emit(.{ .frame_store = .{ .frame = pair_for_value, .slot = 1, .src = value_reload } });

    // `.call`'s аргументы протолкнуты в ТОЧНОМ порядке списка (см.
    // doc-комментарии `wasm_strings.zig`/`wasm_objects.zig`) — `arr_for_append`
    // должен быть произведён ПЕРВЫМ (глубже), `pair_final` ВТОРЫМ
    // (свежайшим), соответствуя порядку `[arr_for_append, pair_final]`
    // ниже; реальный найденный баг — `pair_final` раньше загружался
    // ДО `arr_for_append`, из-за чего `append_i32` получал аргументы
    // переставленными местами (handle и value поменяны), и итоговый
    // массив оставался пустым.
    const arr_for_append = try wasm_heap.loadLocal(&builder, arr_local, layout.ptr_type);
    const pair_final = try wasm_heap.loadLocal(&builder, pair_local, layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = null, .callee = array_runtime.append_i32, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ arr_for_append, pair_final }) } });

    const i_for_inc = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const one_i = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const i_next = try wasm_heap.binOp(&builder, layout.idx_type, .add, i_for_inc, one_i);
    try builder.emit(.{ .store_local = .{ .local = i_local, .src = i_next } });
    builder.terminate(.{ .jump = .{ .target = loop_header } });

    builder.setCurrentBlock(loop_exit);
    const arr_final = try wasm_heap.loadLocal(&builder, arr_local, layout.ptr_type);
    builder.terminate(.{ .return_value = .{ .value = arr_final } });
    return id;
}
