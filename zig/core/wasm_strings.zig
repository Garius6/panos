const std = @import("std");
const mir = @import("mir.zig");
const mir_builder = @import("mir_builder.zig");
const types = @import("types.zig");
const wasm_heap = @import("wasm_heap.zig");
const wasm_module = @import("wasm_module.zig");
const wasm_objects = @import("wasm_objects.zig");

// Убирает JS-host импорты для строк (`@runtime::строка_литерал`/
// `строка_сложить`, `строки::*`) — заменяет `.binary{.add}`/
// `.compare{.equal,.not_equal}`/`.call_builtin{"строки::..."}` над
// строками на настоящий внутримодульный код над линейной памятью,
// переиспользуя bump-аллокатор `wasm_heap.zig` (общий с
// `wasm_objects.zig`/`wasm_actors.zig`). Выполняется в ТОМ ЖЕ слоте
// прохода, что и `wasm_objects.expand` (до `mir_cps.prepare`).
//
// Представление: хэндл `Строка` — это i32-указатель на UTF-8 буфер
// байт С ДЛИНОЙ В ПРЕФИКСЕ — `[u32 byte_length][raw bytes...]`, без
// нуль-терминатора (явная длина делает его ненужным, а строки панос
// могут содержать вложенные NUL-байты как любые другие байты). Строковые
// ЛИТЕРАЛЫ не требуют вообще никакой работы в рантайме при такой
// раскладке: их байты с префиксом длины записываются прямо в секцию
// данных WASM ВО ВРЕМЯ КОМПИЛЯЦИИ (`wasm_emit.zig`, `collectStringConstants`/
// случай `.const_value{.string}`), так что хэндл литерала — это просто
// голый `i32.const <data_offset>` — без host-вызова, без аллокации.
// Любой строковой ОПЕРАЦИИ (конкатенация, сравнение на равенство, длина,
// срез, ...) нужен лишь валидный указатель на форму `[len][bytes]` — ей
// неважно, указывает ли он в read-only секцию данных или в записываемую
// bump-кучу — одно единообразное представление для обоих источников.
//
// Побайтовый доступ (UTF-8-декодирование, циклы копирования байт)
// использует новые MIR-инструкции `mem_load8`/`mem_store8` (`mir.zig`) —
// `mem_load`/`mem_store` работают пословно (4/8 байт), это слишком грубо
// для такой задачи.

fn unsupported(comptime what: []const u8) error{StringExpandUnsupported} {
    std.debug.print("panos build: AOT (wasm) строки — " ++ what ++ "\n", .{});
    return error.StringExpandUnsupported;
}

const StringRuntime = struct {
    concat: mir.FunctionId,
    equal: mir.FunctionId,
    starts_with: mir.FunctionId,
    utf8_width: mir.FunctionId,
    length: mir.FunctionId,
    rune_byte_offset: mir.FunctionId,
    byte_to_rune_count: mir.FunctionId,
    index_of: mir.FunctionId,
    slice: mir.FunctionId,
    find: mir.FunctionId,
    replace: mir.FunctionId,
    split: ?mir.FunctionId,
    from_int: mir.FunctionId,
    from_number: mir.FunctionId,
    to_number: mir.FunctionId,
    is_digit: mir.FunctionId,
    is_letter: mir.FunctionId,
    from_runes: ?mir.FunctionId,
    to_bytes: ?mir.FunctionId,
};

const ExpandCtx = struct {
    layout: wasm_heap.PtrLayout,
    type_store: *const types.TypeStore,
    runtime: StringRuntime,
};

pub fn expand(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore) !void {
    if (!usesStringOps(module, type_store)) return;

    const layout = wasm_heap.PtrLayout{
        .ptr_type = type_store.builtins.string,
        .idx_type = type_store.builtins.boolean,
        .bool_type = type_store.builtins.boolean,
    };

    _ = try wasm_heap.findOrBuildAlloc(allocator, module, type_store, layout);
    const utf8_width = try buildUtf8Width(allocator, module, type_store, layout);
    const rune_byte_offset = try buildRuneByteOffset(allocator, module, type_store, layout, utf8_width);
    const byte_to_rune_count = try buildByteToRuneCount(allocator, module, type_store, layout, utf8_width);
    const index_of = try buildIndexOf(allocator, module, type_store, layout);
    const concat = try buildConcat(allocator, module, type_store, layout);
    const length = try buildLength(allocator, module, type_store, layout, utf8_width);
    const slice = try buildSlice(allocator, module, type_store, layout, rune_byte_offset);
    const find = try buildFind(allocator, module, type_store, layout, rune_byte_offset, index_of, byte_to_rune_count);
    // `разбить` возвращает `Массив(Строка)` — подключаем (более тяжёлый)
    // рантайм массивов только если исходник реально его использует, та
    // же дисциплина «строить только нужное», что и во всём этом файле.
    const split: ?mir.FunctionId = if (usesSplit(module)) blk: {
        const array_runtime = try wasm_objects.findOrBuildArrayRuntime(allocator, module, type_store, layout);
        const slice_bytes = try buildSliceBytes(allocator, module, type_store, layout);
        break :blk try buildSplit(allocator, module, type_store, layout, index_of, slice_bytes, array_runtime);
    } else null;
    const format_digits = try buildFormatUnsignedDigits(allocator, module, type_store, layout);
    const from_int = try buildFromInt(allocator, module, type_store, layout, format_digits, concat);
    const from_number = try buildFromNumber(allocator, module, type_store, layout, format_digits, concat);
    const to_number = try buildToNumber(allocator, module, type_store, layout);
    // `из_рун` возвращает `Строка` из `Массив(Целое)` — подключаем array
    // runtime только если исходник реально его использует, та же
    // дисциплина, что и у `разбить` выше (`findOrBuildArrayRuntime`
    // идемпотентна: если `разбить` уже построил его, здесь просто
    // находит существующие функции по имени, не строит заново).
    const from_runes: ?mir.FunctionId = if (usesFromRunes(module)) blk: {
        const array_runtime = try wasm_objects.findOrBuildArrayRuntime(allocator, module, type_store, layout);
        break :blk try buildFromRunes(allocator, module, type_store, layout, array_runtime);
    } else null;
    const to_bytes: ?mir.FunctionId = if (usesToBytes(module)) blk: {
        const array_runtime = try wasm_objects.findOrBuildArrayRuntime(allocator, module, type_store, layout);
        break :blk try buildToBytes(allocator, module, type_store, layout, array_runtime);
    } else null;
    const runtime = StringRuntime{
        .concat = concat,
        .equal = try buildEqual(allocator, module, type_store, layout),
        .starts_with = try buildStartsWith(allocator, module, type_store, layout),
        .utf8_width = utf8_width,
        .length = length,
        .rune_byte_offset = rune_byte_offset,
        .byte_to_rune_count = byte_to_rune_count,
        .index_of = index_of,
        .slice = slice,
        .find = find,
        .replace = try buildReplace(allocator, module, type_store, layout, length, slice, find, concat),
        .split = split,
        .from_int = from_int,
        .from_number = from_number,
        .to_number = to_number,
        .is_digit = try buildIsDigit(allocator, module, type_store, layout),
        .is_letter = try buildIsLetter(allocator, module, type_store, layout, utf8_width),
        .from_runes = from_runes,
        .to_bytes = to_bytes,
    };
    // То же рассуждение «пересканировать module.functions.items заново
    // каждый раз», что и в wasm_objects.zig: buildConcat/buildEqual выше
    // уже добавили новые функции, но тело САМИХ этих функций строковых
    // операций не содержит (они написаны руками, не пользовательский
    // код), поэтому замороженный снимок не нужен.
    var index: usize = 0;
    while (index < module.functions.items.len) : (index += 1) {
        const function_id: mir.FunctionId = @enumFromInt(index);
        // Store/layout на каждую функцию отдельно: строковая операция
        // внутри функции НЕ из входного модуля должна типизировать любой
        // создаваемый ею локал против СВОЕГО store (см. `wasm_objects.zig`/
        // `wasm_interfaces.zig` — то же ограничение кросс-модульного
        // `TypeId`). Собственные вспомогательные функции `runtime`
        // остаются на глобальном store входного модуля
        // (сгенерированы компилятором, самосогласованы, вызывающие
        // типизируют свой `dst` независимо).
        const function_store = module.functions.items[index].type_store orelse type_store;
        const function_layout = wasm_heap.PtrLayout{
            .ptr_type = function_store.builtins.string,
            .idx_type = function_store.builtins.boolean,
            .bool_type = function_store.builtins.boolean,
        };
        const function_ctx = ExpandCtx{ .layout = function_layout, .type_store = function_store, .runtime = runtime };
        const block_count = module.functions.items[index].blocks.items.len;
        var block_index: usize = 0;
        while (block_index < block_count) : (block_index += 1) {
            var builder = mir_builder.Builder{ .module = module, .allocator = allocator, .function_id = function_id };
            try expandBlock(&builder, allocator, @enumFromInt(block_index), function_ctx);
        }
    }
}

fn isStringType(type_store: *const types.TypeStore, id: types.TypeId) bool {
    return type_store.eql(id, type_store.builtins.string);
}

fn usesStringOps(module: *const mir.Module, type_store: *const types.TypeStore) bool {
    for (module.functions.items) |function| for (function.blocks.items) |block|
        for (block.instructions.items) |instruction| switch (instruction) {
            .binary => |v| if (v.op == .add and isStringType(type_store, function.valueType(v.dst))) return true,
            .compare => |v| if ((v.op == .equal or v.op == .not_equal) and isStringType(type_store, function.valueType(v.lhs))) return true,
            .call_builtin => |v| if (std.mem.startsWith(u8, v.name, "строки::")) return true,
            else => {},
        };
    return false;
}

fn usesSplit(module: *const mir.Module) bool {
    for (module.functions.items) |function| for (function.blocks.items) |block|
        for (block.instructions.items) |instruction| switch (instruction) {
            .call_builtin => |v| if (std.mem.eql(u8, v.name, "строки::разбить")) return true,
            else => {},
        };
    return false;
}

fn usesFromRunes(module: *const mir.Module) bool {
    for (module.functions.items) |function| for (function.blocks.items) |block|
        for (block.instructions.items) |instruction| switch (instruction) {
            .call_builtin => |v| if (std.mem.eql(u8, v.name, "строки::из_рун")) return true,
            else => {},
        };
    return false;
}

fn usesToBytes(module: *const mir.Module) bool {
    for (module.functions.items) |function| for (function.blocks.items) |block|
        for (block.instructions.items) |instruction| switch (instruction) {
            .call_builtin => |v| if (std.mem.eql(u8, v.name, "строки::в_байты")) return true,
            else => {},
        };
    return false;
}

fn expandBlock(builder: *mir_builder.Builder, allocator: std.mem.Allocator, block_id: mir.BlockId, ctx: ExpandCtx) !void {
    const function = builder.currentFunction();
    var original = function.blockConst(block_id).*;
    function.block(block_id).instructions = .empty;
    builder.setCurrentBlock(block_id);
    builder.terminated = false;

    for (original.instructions.items) |instruction| {
        try expandInstruction(builder, instruction, ctx);
    }
    builder.terminate(original.terminator);
    original.instructions.deinit(allocator);
}

fn expandInstruction(builder: *mir_builder.Builder, instruction: mir.Instruction, ctx: ExpandCtx) !void {
    const function = builder.currentFunction();
    switch (instruction) {
        .binary => |v| {
            if (v.op == .add and isStringType(ctx.type_store, function.valueType(v.dst))) {
                try builder.emit(.{ .call = .{ .dst = v.dst, .callee = ctx.runtime.concat, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ v.lhs, v.rhs }) } });
                return;
            }
            try builder.emit(instruction);
        },
        .compare => |v| {
            if ((v.op == .equal or v.op == .not_equal) and isStringType(ctx.type_store, function.valueType(v.lhs))) {
                if (v.op == .equal) {
                    // `dst` становится напрямую результатом вызова — это
                    // ровно ТО ОДНО значение, которое уже ожидает
                    // окружающий код исходной инструкции, без риска
                    // переупорядочивания (результат `.call` просто
                    // производится самим вызовом, перемежать нечего).
                    try builder.emit(.{ .call = .{ .dst = v.dst, .callee = ctx.runtime.equal, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ v.lhs, v.rhs }) } });
                } else {
                    const eq = try builder.newValue(ctx.layout.bool_type);
                    try builder.emit(.{ .call = .{ .dst = eq, .callee = ctx.runtime.equal, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ v.lhs, v.rhs }) } });
                    try builder.emit(.{ .unary = .{ .dst = v.dst, .op = .negate_bool, .src = eq } });
                }
                return;
            }
            try builder.emit(instruction);
        },
        .call_builtin => |v| {
            const callee: ?mir.FunctionId = blk: {
                if (std.mem.eql(u8, v.name, "строки::начинается_с")) break :blk ctx.runtime.starts_with;
                if (std.mem.eql(u8, v.name, "строки::длина")) break :blk ctx.runtime.length;
                if (std.mem.eql(u8, v.name, "строки::срез")) break :blk ctx.runtime.slice;
                if (std.mem.eql(u8, v.name, "строки::найти")) break :blk ctx.runtime.find;
                if (std.mem.eql(u8, v.name, "строки::заменить")) break :blk ctx.runtime.replace;
                if (std.mem.eql(u8, v.name, "строки::разбить")) break :blk ctx.runtime.split.?;
                if (std.mem.eql(u8, v.name, "строки::из_числа")) break :blk ctx.runtime.from_number;
                // `Целое` и `Число` имеют одно f64-представление в AOT;
                // общий форматтер уже выдаёт для целого ровно десятичные
                // цифры без дробной части. Старый внутренний `from_int`
                // не был подключён ни к одному builtin и нарушает
                // stack-order при возврате строки из ветвящегося CFG.
                if (std.mem.eql(u8, v.name, "строки::из_целого")) break :blk ctx.runtime.from_number;
                if (std.mem.eql(u8, v.name, "строки::в_число")) break :blk ctx.runtime.to_number;
                if (std.mem.eql(u8, v.name, "строки::это_цифра")) break :blk ctx.runtime.is_digit;
                if (std.mem.eql(u8, v.name, "строки::это_буква")) break :blk ctx.runtime.is_letter;
                if (std.mem.eql(u8, v.name, "строки::из_рун")) break :blk ctx.runtime.from_runes.?;
                if (std.mem.eql(u8, v.name, "строки::в_байты")) break :blk ctx.runtime.to_bytes.?;
                break :blk null;
            };
            if (callee) |fn_id| {
                try builder.emit(.{ .call = .{ .dst = v.dst, .callee = fn_id, .args = v.args } });
                return;
            }
            try builder.emit(instruction);
        },
        else => try builder.emit(instruction),
    }
}

// Копирует `count` байт из `src_base_local[0..count)` в
// `dst_base_local[0..count)` — вызывающие сами прибавляют любой
// фиксированный offset заголовка (например, `+4`, чтобы пропустить
// префикс длины) к базовым указателям перед вызовом. Та же форма цикла,
// что и копирующий цикл `buildEnsureCapacity` в `wasm_objects.zig`
// (настоящий WASM `loop`, обычный один-заголовок/один-выход, без
// suspend — попадает в уже существующий быстрый путь
// `wasm_stackify.zig`).
// Строит свежую 1-байтовую `Строка` (`[len=1][byte_value]`) в рантайме —
// используется для знака "-" и особого случая строки-цифры "0", ни один
// из которых не приходит из пользовательского исходника (поэтому нет
// литерала в секции данных, на который можно было бы указать; их нужно
// строить так же, как и любую другую строку в куче).
fn emitOneByteString(builder: *mir_builder.Builder, module: *mir.Module, layout: wasm_heap.PtrLayout, byte_value: u32) !mir.ValueId {
    const alloc_id = wasm_heap.findFunctionByName(module, wasm_heap.alloc_function_name).?;
    const five = try wasm_heap.addressConst(builder, layout.idx_type, 5);
    const handle = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = handle, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, five) } });
    const handle_local = try wasm_heap.storeLocal(builder, "@h", layout.ptr_type, handle);
    const one_len = try wasm_heap.addressConst(builder, layout.idx_type, 1);
    const handle_for_hdr = try wasm_heap.loadLocal(builder, handle_local, layout.ptr_type);
    try builder.emit(.{ .mem_store = .{ .addr = handle_for_hdr, .src = one_len } });
    const the_byte = try wasm_heap.addressConst(builder, layout.idx_type, byte_value);
    const four = try wasm_heap.addressConst(builder, layout.idx_type, 4);
    const handle_for_byte = try wasm_heap.loadLocal(builder, handle_local, layout.ptr_type);
    const byte_addr = try wasm_heap.binOp(builder, layout.idx_type, .add, handle_for_byte, four);
    try builder.emit(.{ .mem_store8 = .{ .addr = byte_addr, .src = the_byte } });
    return try wasm_heap.loadLocal(builder, handle_local, layout.ptr_type);
}

fn emitByteCopyLoop(builder: *mir_builder.Builder, layout: wasm_heap.PtrLayout, src_base_local: mir.LocalId, dst_base_local: mir.LocalId, count_local: mir.LocalId) !void {
    const i_local = try builder.newLocal(wasm_heap.dummy_symbol, "@i", layout.idx_type);
    const zero = try wasm_heap.addressConst(builder, layout.idx_type, 0);
    try builder.emit(.{ .store_local = .{ .local = i_local, .src = zero } });

    const loop_header = try builder.newBlock();
    builder.terminate(.{ .jump = .{ .target = loop_header } });

    builder.setCurrentBlock(loop_header);
    const i_for_cmp = try wasm_heap.loadLocal(builder, i_local, layout.idx_type);
    const count_for_cmp = try wasm_heap.loadLocal(builder, count_local, layout.idx_type);
    const keep_going = try wasm_heap.cmpOp(builder, layout.bool_type, .less, i_for_cmp, count_for_cmp);
    const loop_body = try builder.newBlock();
    const loop_exit = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = keep_going, .then_block = loop_body, .else_block = loop_exit } });

    builder.setCurrentBlock(loop_body);
    const i_for_src = try wasm_heap.loadLocal(builder, i_local, layout.idx_type);
    const src_base_r = try wasm_heap.loadLocal(builder, src_base_local, layout.idx_type);
    const src_addr = try wasm_heap.binOp(builder, layout.idx_type, .add, src_base_r, i_for_src);
    const byte = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load8 = .{ .dst = byte, .addr = src_addr } });
    // `byte` перезагружается ДО вычисления `dst_addr` — `mem_store8`
    // требует порядок на стеке `[src, addr]` (addr — самое свежее),
    // та же конвенция, что установил `mem_store` (см. doc-комментарий
    // `EmitContext.frame_store_scratch_frame` в `wasm_emit.zig`).
    const byte_local = try wasm_heap.storeLocal(builder, "@byte", layout.idx_type, byte);
    const byte_reload = try wasm_heap.loadLocal(builder, byte_local, layout.idx_type);

    const i_for_dst = try wasm_heap.loadLocal(builder, i_local, layout.idx_type);
    const dst_base_r = try wasm_heap.loadLocal(builder, dst_base_local, layout.idx_type);
    const dst_addr = try wasm_heap.binOp(builder, layout.idx_type, .add, dst_base_r, i_for_dst);
    try builder.emit(.{ .mem_store8 = .{ .addr = dst_addr, .src = byte_reload } });

    const i_next_src = try wasm_heap.loadLocal(builder, i_local, layout.idx_type);
    const one = try wasm_heap.addressConst(builder, layout.idx_type, 1);
    const i_next = try wasm_heap.binOp(builder, layout.idx_type, .add, i_next_src, one);
    try builder.emit(.{ .store_local = .{ .local = i_local, .src = i_next } });
    builder.terminate(.{ .jump = .{ .target = loop_header } });

    builder.setCurrentBlock(loop_exit);
}

// `@string_concat(a, b) -> handle`: аллоцирует `4 + len_a + len_b` байт,
// пишет объединённый заголовок длины, копирует байты A, затем B.
fn buildConcat(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@string_concat", wasm_heap.dummy_symbol, layout.ptr_type, wasm_heap.dummy_span);
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

    const len_a_r1 = try wasm_heap.loadLocal(&builder, len_a_local, layout.idx_type);
    const len_b_r1 = try wasm_heap.loadLocal(&builder, len_b_local, layout.idx_type);
    const total = try wasm_heap.binOp(&builder, layout.idx_type, .add, len_a_r1, len_b_r1);
    const total_local = try wasm_heap.storeLocal(&builder, "total", layout.idx_type, total);

    const four = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const total_r1 = try wasm_heap.loadLocal(&builder, total_local, layout.idx_type);
    const alloc_size = try wasm_heap.binOp(&builder, layout.idx_type, .add, four, total_r1);
    const alloc_id = wasm_heap.findFunctionByName(module, wasm_heap.alloc_function_name).?;
    const handle = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = handle, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, alloc_size) } });
    const handle_local = try wasm_heap.storeLocal(&builder, "handle", layout.ptr_type, handle);

    // Пишем заголовок длины: src (total) вычисляется ДО addr (перезагрузки
    // handle) — `mem_store` требует `[src, addr]` с самым свежим addr.
    const total_r2 = try wasm_heap.loadLocal(&builder, total_local, layout.idx_type);
    const handle_for_header = try wasm_heap.loadLocal(&builder, handle_local, layout.ptr_type);
    try builder.emit(.{ .mem_store = .{ .addr = handle_for_header, .src = total_r2 } });

    // Копируем A в handle+4.
    const four_for_src_a = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const a_for_copy = try wasm_heap.loadLocal(&builder, a_local, layout.ptr_type);
    const a_base = try wasm_heap.binOp(&builder, layout.idx_type, .add, a_for_copy, four_for_src_a);
    const a_base_local = try wasm_heap.storeLocal(&builder, "a_base", layout.idx_type, a_base);
    const four_for_dst_a = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const handle_for_a = try wasm_heap.loadLocal(&builder, handle_local, layout.ptr_type);
    const dst_base_a = try wasm_heap.binOp(&builder, layout.idx_type, .add, handle_for_a, four_for_dst_a);
    const dst_base_a_local = try wasm_heap.storeLocal(&builder, "dst_base_a", layout.idx_type, dst_base_a);
    try emitByteCopyLoop(&builder, layout, a_base_local, dst_base_a_local, len_a_local);

    // Копируем B в handle+4+len_a.
    const b_for_copy = try wasm_heap.loadLocal(&builder, b_local, layout.ptr_type);
    const four_for_src_b = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const b_base = try wasm_heap.binOp(&builder, layout.idx_type, .add, b_for_copy, four_for_src_b);
    const b_base_local = try wasm_heap.storeLocal(&builder, "b_base", layout.idx_type, b_base);
    const four_for_dst_b = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const handle_for_b = try wasm_heap.loadLocal(&builder, handle_local, layout.ptr_type);
    const handle_plus_four = try wasm_heap.binOp(&builder, layout.idx_type, .add, handle_for_b, four_for_dst_b);
    const len_a_for_dst = try wasm_heap.loadLocal(&builder, len_a_local, layout.idx_type);
    const dst_base_b = try wasm_heap.binOp(&builder, layout.idx_type, .add, handle_plus_four, len_a_for_dst);
    const dst_base_b_local = try wasm_heap.storeLocal(&builder, "dst_base_b", layout.idx_type, dst_base_b);
    try emitByteCopyLoop(&builder, layout, b_base_local, dst_base_b_local, len_b_local);

    const handle_final = try wasm_heap.loadLocal(&builder, handle_local, layout.ptr_type);
    builder.terminate(.{ .return_value = .{ .value = handle_final } });
    return id;
}

// `@string_equal(a, b) -> bool`: сначала проверка длины, затем цикл
// побайтового сравнения с ранним выходом при первом несовпадении —
// сравнивает СОДЕРЖИМОЕ строки, а не хэндл (сравнение указателей было бы
// неверным для любых двух независимо построенных равных строк).
fn buildEqual(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@string_equal", wasm_heap.dummy_symbol, layout.bool_type, wasm_heap.dummy_span);
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

// `@string_starts_with(s, prefix) -> Булево`: побайтово, с учётом
// регистра (как `strStartsWith` в `vm.zig` — `std.mem.startsWith(u8,
// string, prefix)`). Если prefix длиннее s — false (никогда не читает за
// границы).
fn buildStartsWith(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@string_starts_with", wasm_heap.dummy_symbol, layout.bool_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const s_local = try builder.newLocal(wasm_heap.dummy_symbol, "s", layout.ptr_type);
    const prefix_local = try builder.newLocal(wasm_heap.dummy_symbol, "prefix", layout.ptr_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{ s_local, prefix_local });
    builder.currentFunction().type_store = type_store;

    const s1 = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const len_s = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load = .{ .dst = len_s, .addr = s1 } });
    const len_s_local = try wasm_heap.storeLocal(&builder, "len_s", layout.idx_type, len_s);

    const p1 = try wasm_heap.loadLocal(&builder, prefix_local, layout.ptr_type);
    const len_p = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load = .{ .dst = len_p, .addr = p1 } });
    const len_p_local = try wasm_heap.storeLocal(&builder, "len_p", layout.idx_type, len_p);

    const len_p_for_cmp = try wasm_heap.loadLocal(&builder, len_p_local, layout.idx_type);
    const len_s_for_cmp = try wasm_heap.loadLocal(&builder, len_s_local, layout.idx_type);
    const fits = try wasm_heap.cmpOp(&builder, layout.bool_type, .less_equal, len_p_for_cmp, len_s_for_cmp);

    const compare_block = try builder.newBlock();
    const too_long_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = fits, .then_block = compare_block, .else_block = too_long_block } });

    builder.setCurrentBlock(too_long_block);
    const false_val = try wasm_heap.boolConst(&builder, layout.bool_type, false);
    builder.terminate(.{ .return_value = .{ .value = false_val } });

    builder.setCurrentBlock(compare_block);
    const four = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const s_for_base = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const s_base = try wasm_heap.binOp(&builder, layout.idx_type, .add, s_for_base, four);
    const s_base_local = try wasm_heap.storeLocal(&builder, "s_base", layout.idx_type, s_base);
    const four2 = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const p_for_base = try wasm_heap.loadLocal(&builder, prefix_local, layout.ptr_type);
    const p_base = try wasm_heap.binOp(&builder, layout.idx_type, .add, p_for_base, four2);
    const p_base_local = try wasm_heap.storeLocal(&builder, "p_base", layout.idx_type, p_base);

    const i_local = try builder.newLocal(wasm_heap.dummy_symbol, "@i", layout.idx_type);
    const zero = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    try builder.emit(.{ .store_local = .{ .local = i_local, .src = zero } });

    const loop_header = try builder.newBlock();
    builder.terminate(.{ .jump = .{ .target = loop_header } });

    builder.setCurrentBlock(loop_header);
    const i_for_cmp = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const len_p_for_loop = try wasm_heap.loadLocal(&builder, len_p_local, layout.idx_type);
    const keep_going = try wasm_heap.cmpOp(&builder, layout.bool_type, .less, i_for_cmp, len_p_for_loop);
    const loop_body = try builder.newBlock();
    const loop_exit = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = keep_going, .then_block = loop_body, .else_block = loop_exit } });

    builder.setCurrentBlock(loop_body);
    const i_for_s = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const s_base_r = try wasm_heap.loadLocal(&builder, s_base_local, layout.idx_type);
    const s_addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, s_base_r, i_for_s);
    const byte_s = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load8 = .{ .dst = byte_s, .addr = s_addr } });
    const byte_s_local = try wasm_heap.storeLocal(&builder, "@byte_s", layout.idx_type, byte_s);

    const i_for_p = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const p_base_r = try wasm_heap.loadLocal(&builder, p_base_local, layout.idx_type);
    const p_addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, p_base_r, i_for_p);
    const byte_p = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load8 = .{ .dst = byte_p, .addr = p_addr } });

    const byte_s_reload = try wasm_heap.loadLocal(&builder, byte_s_local, layout.idx_type);
    const bytes_equal = try wasm_heap.cmpOp(&builder, layout.bool_type, .equal, byte_s_reload, byte_p);
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

// `@string_utf8_width(byte) -> i32`: определяет длину UTF-8
// последовательности (1-4) по стартовому байту, совпадает с
// классификацией `std.unicode.utf8ByteSequenceLength`. Паникует (как и
// нативная ошибка "строка содержит некорректный UTF-8") на байте,
// который не может начинать последовательность (одинокий
// continuation-байт 0x80-0xBF, либо 0xF8+).
fn buildUtf8Width(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@string_utf8_width", wasm_heap.dummy_symbol, layout.idx_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const byte_local = try builder.newLocal(wasm_heap.dummy_symbol, "byte", layout.idx_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{byte_local});
    builder.currentFunction().type_store = type_store;

    // byte & 0x80 == 0 -> ASCII, ширина 1.
    const mask1 = try wasm_heap.addressConst(&builder, layout.idx_type, 0x80);
    const byte1 = try wasm_heap.loadLocal(&builder, byte_local, layout.idx_type);
    const anded1 = try wasm_heap.binOp(&builder, layout.idx_type, .bit_and, byte1, mask1);
    const zero1 = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    const is_ascii = try wasm_heap.cmpOp(&builder, layout.bool_type, .equal, anded1, zero1);
    const ascii_block = try builder.newBlock();
    const check2_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = is_ascii, .then_block = ascii_block, .else_block = check2_block } });

    builder.setCurrentBlock(ascii_block);
    const one = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    builder.terminate(.{ .return_value = .{ .value = one } });

    builder.setCurrentBlock(check2_block);
    const mask2 = try wasm_heap.addressConst(&builder, layout.idx_type, 0xE0);
    const byte2 = try wasm_heap.loadLocal(&builder, byte_local, layout.idx_type);
    const anded2 = try wasm_heap.binOp(&builder, layout.idx_type, .bit_and, byte2, mask2);
    const pattern2 = try wasm_heap.addressConst(&builder, layout.idx_type, 0xC0);
    const is_2byte = try wasm_heap.cmpOp(&builder, layout.bool_type, .equal, anded2, pattern2);
    const two_block = try builder.newBlock();
    const check3_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = is_2byte, .then_block = two_block, .else_block = check3_block } });

    builder.setCurrentBlock(two_block);
    const two = try wasm_heap.addressConst(&builder, layout.idx_type, 2);
    builder.terminate(.{ .return_value = .{ .value = two } });

    builder.setCurrentBlock(check3_block);
    const mask3 = try wasm_heap.addressConst(&builder, layout.idx_type, 0xF0);
    const byte3 = try wasm_heap.loadLocal(&builder, byte_local, layout.idx_type);
    const anded3 = try wasm_heap.binOp(&builder, layout.idx_type, .bit_and, byte3, mask3);
    const pattern3 = try wasm_heap.addressConst(&builder, layout.idx_type, 0xE0);
    const is_3byte = try wasm_heap.cmpOp(&builder, layout.bool_type, .equal, anded3, pattern3);
    const three_block = try builder.newBlock();
    const check4_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = is_3byte, .then_block = three_block, .else_block = check4_block } });

    builder.setCurrentBlock(three_block);
    const three = try wasm_heap.addressConst(&builder, layout.idx_type, 3);
    builder.terminate(.{ .return_value = .{ .value = three } });

    builder.setCurrentBlock(check4_block);
    const mask4 = try wasm_heap.addressConst(&builder, layout.idx_type, 0xF8);
    const byte4 = try wasm_heap.loadLocal(&builder, byte_local, layout.idx_type);
    const anded4 = try wasm_heap.binOp(&builder, layout.idx_type, .bit_and, byte4, mask4);
    const pattern4 = try wasm_heap.addressConst(&builder, layout.idx_type, 0xF0);
    const is_4byte = try wasm_heap.cmpOp(&builder, layout.bool_type, .equal, anded4, pattern4);
    const four_block = try builder.newBlock();
    const invalid_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = is_4byte, .then_block = four_block, .else_block = invalid_block } });

    builder.setCurrentBlock(four_block);
    const four = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    builder.terminate(.{ .return_value = .{ .value = four } });

    builder.setCurrentBlock(invalid_block);
    builder.terminate(.{ .unreachable_term = .{ .reason = "строка содержит некорректный UTF-8" } });

    return id;
}

// `@string_length(s) -> Число`: счётчик рун через полный обход UTF-8 от
// байта 0 до количества байт из заголовка длины (как `stringLength` в
// `vm.zig` через `std.unicode.utf8CountCodepoints` — тот же контракт
// «паника на невалидном UTF-8», делегированный `@string_utf8_width`).
fn buildLength(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout, utf8_width: mir.FunctionId) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@string_length", wasm_heap.dummy_symbol, type_store.builtins.number, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const s_local = try builder.newLocal(wasm_heap.dummy_symbol, "s", layout.ptr_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{s_local});
    builder.currentFunction().type_store = type_store;

    const s1 = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const len = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load = .{ .dst = len, .addr = s1 } });
    const len_local = try wasm_heap.storeLocal(&builder, "len", layout.idx_type, len);

    const four = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const s_for_base = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const base = try wasm_heap.binOp(&builder, layout.idx_type, .add, s_for_base, four);
    const base_local = try wasm_heap.storeLocal(&builder, "base", layout.idx_type, base);

    const offset_local = try builder.newLocal(wasm_heap.dummy_symbol, "@offset", layout.idx_type);
    const zero1 = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    try builder.emit(.{ .store_local = .{ .local = offset_local, .src = zero1 } });
    const count_local = try builder.newLocal(wasm_heap.dummy_symbol, "@count", layout.idx_type);
    const zero2 = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    try builder.emit(.{ .store_local = .{ .local = count_local, .src = zero2 } });

    const loop_header = try builder.newBlock();
    builder.terminate(.{ .jump = .{ .target = loop_header } });

    builder.setCurrentBlock(loop_header);
    const offset_for_cmp = try wasm_heap.loadLocal(&builder, offset_local, layout.idx_type);
    const len_for_cmp = try wasm_heap.loadLocal(&builder, len_local, layout.idx_type);
    const keep_going = try wasm_heap.cmpOp(&builder, layout.bool_type, .less, offset_for_cmp, len_for_cmp);
    const loop_body = try builder.newBlock();
    const loop_exit = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = keep_going, .then_block = loop_body, .else_block = loop_exit } });

    builder.setCurrentBlock(loop_body);
    const offset_for_addr = try wasm_heap.loadLocal(&builder, offset_local, layout.idx_type);
    const base_for_addr = try wasm_heap.loadLocal(&builder, base_local, layout.idx_type);
    const addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, base_for_addr, offset_for_addr);
    const byte = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load8 = .{ .dst = byte, .addr = addr } });
    const width = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .call = .{ .dst = width, .callee = utf8_width, .args = try wasm_heap.dupeOne(module, byte) } });
    const width_local = try wasm_heap.storeLocal(&builder, "@width", layout.idx_type, width);

    const offset_for_inc = try wasm_heap.loadLocal(&builder, offset_local, layout.idx_type);
    const width_for_inc = try wasm_heap.loadLocal(&builder, width_local, layout.idx_type);
    const offset_next = try wasm_heap.binOp(&builder, layout.idx_type, .add, offset_for_inc, width_for_inc);
    try builder.emit(.{ .store_local = .{ .local = offset_local, .src = offset_next } });

    const count_for_inc = try wasm_heap.loadLocal(&builder, count_local, layout.idx_type);
    const one = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const count_next = try wasm_heap.binOp(&builder, layout.idx_type, .add, count_for_inc, one);
    try builder.emit(.{ .store_local = .{ .local = count_local, .src = count_next } });
    builder.terminate(.{ .jump = .{ .target = loop_header } });

    builder.setCurrentBlock(loop_exit);
    const count_final = try wasm_heap.loadLocal(&builder, count_local, layout.idx_type);
    const count_f64 = try builder.newValue(type_store.builtins.number);
    try builder.emit(.{ .unary = .{ .dst = count_f64, .op = .from_i32, .src = count_final } });
    builder.terminate(.{ .return_value = .{ .value = count_f64 } });
    return id;
}

// `@string_rune_byte_offset(s, target_rune) -> byte_offset`: обходит
// руны с начала, переводя индекс руны в байтовый offset (ОТНОСИТЕЛЬНО
// собственных данных строки, с нуля — вызывающие сами прибавляют `+4`
// для абсолютного адреса). Точно соответствует `runeByteOffset` из
// `vm.zig`, включая проверку границ ВНУТРИ цикла (паникует в момент,
// когда нужна ещё одна руна, а их больше не осталось, а не только в
// самом конце) — именно это превращает индекс руны вне диапазона в
// чистую панику, а не в чтение за границами.
fn buildRuneByteOffset(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout, utf8_width: mir.FunctionId) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@string_rune_byte_offset", wasm_heap.dummy_symbol, layout.idx_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const s_local = try builder.newLocal(wasm_heap.dummy_symbol, "s", layout.ptr_type);
    const target_local = try builder.newLocal(wasm_heap.dummy_symbol, "target", layout.idx_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{ s_local, target_local });
    builder.currentFunction().type_store = type_store;

    const s1 = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const len = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load = .{ .dst = len, .addr = s1 } });
    const len_local = try wasm_heap.storeLocal(&builder, "len", layout.idx_type, len);

    const four = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const s_for_base = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const base = try wasm_heap.binOp(&builder, layout.idx_type, .add, s_for_base, four);
    const base_local = try wasm_heap.storeLocal(&builder, "base", layout.idx_type, base);

    const offset_local = try builder.newLocal(wasm_heap.dummy_symbol, "@offset", layout.idx_type);
    const zero1 = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    try builder.emit(.{ .store_local = .{ .local = offset_local, .src = zero1 } });
    const current_local = try builder.newLocal(wasm_heap.dummy_symbol, "@current", layout.idx_type);
    const zero2 = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    try builder.emit(.{ .store_local = .{ .local = current_local, .src = zero2 } });

    const loop_header = try builder.newBlock();
    builder.terminate(.{ .jump = .{ .target = loop_header } });

    builder.setCurrentBlock(loop_header);
    const current_for_cmp = try wasm_heap.loadLocal(&builder, current_local, layout.idx_type);
    const target_for_cmp = try wasm_heap.loadLocal(&builder, target_local, layout.idx_type);
    const need_more = try wasm_heap.cmpOp(&builder, layout.bool_type, .less, current_for_cmp, target_for_cmp);
    const check_bounds_block = try builder.newBlock();
    const done_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = need_more, .then_block = check_bounds_block, .else_block = done_block } });

    builder.setCurrentBlock(check_bounds_block);
    const offset_for_bounds = try wasm_heap.loadLocal(&builder, offset_local, layout.idx_type);
    const len_for_bounds = try wasm_heap.loadLocal(&builder, len_local, layout.idx_type);
    const in_bounds = try wasm_heap.cmpOp(&builder, layout.bool_type, .less, offset_for_bounds, len_for_bounds);
    const decode_block = try builder.newBlock();
    const panic_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = in_bounds, .then_block = decode_block, .else_block = panic_block } });

    builder.setCurrentBlock(panic_block);
    builder.terminate(.{ .unreachable_term = .{ .reason = "индекс строки вне границ" } });

    builder.setCurrentBlock(decode_block);
    const offset_for_addr = try wasm_heap.loadLocal(&builder, offset_local, layout.idx_type);
    const base_for_addr = try wasm_heap.loadLocal(&builder, base_local, layout.idx_type);
    const addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, base_for_addr, offset_for_addr);
    const byte = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load8 = .{ .dst = byte, .addr = addr } });
    const width = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .call = .{ .dst = width, .callee = utf8_width, .args = try wasm_heap.dupeOne(module, byte) } });
    const width_local = try wasm_heap.storeLocal(&builder, "@width", layout.idx_type, width);

    const offset_for_inc = try wasm_heap.loadLocal(&builder, offset_local, layout.idx_type);
    const width_for_inc = try wasm_heap.loadLocal(&builder, width_local, layout.idx_type);
    const offset_next = try wasm_heap.binOp(&builder, layout.idx_type, .add, offset_for_inc, width_for_inc);
    try builder.emit(.{ .store_local = .{ .local = offset_local, .src = offset_next } });

    const current_for_inc = try wasm_heap.loadLocal(&builder, current_local, layout.idx_type);
    const one = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const current_next = try wasm_heap.binOp(&builder, layout.idx_type, .add, current_for_inc, one);
    try builder.emit(.{ .store_local = .{ .local = current_local, .src = current_next } });
    builder.terminate(.{ .jump = .{ .target = loop_header } });

    builder.setCurrentBlock(done_block);
    const offset_final = try wasm_heap.loadLocal(&builder, offset_local, layout.idx_type);
    builder.terminate(.{ .return_value = .{ .value = offset_final } });
    return id;
}

// `@string_byte_to_rune_count(s, byte_limit) -> rune_count`: считает
// полные UTF-8-последовательности в `s[0..byte_limit)` — обратное
// направление к `@string_rune_byte_offset`, нужно `найти`, чтобы
// перевести найденный БАЙТОВЫЙ offset обратно в индекс руны, который
// она должна вернуть (`strFind` в `vm.zig` —
// `std.unicode.utf8CountCodepoints(string[0 .. start_byte +
// relative_offset])`).
fn buildByteToRuneCount(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout, utf8_width: mir.FunctionId) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@string_byte_to_rune_count", wasm_heap.dummy_symbol, layout.idx_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const s_local = try builder.newLocal(wasm_heap.dummy_symbol, "s", layout.ptr_type);
    const limit_local = try builder.newLocal(wasm_heap.dummy_symbol, "limit", layout.idx_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{ s_local, limit_local });
    builder.currentFunction().type_store = type_store;

    const four = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const s_for_base = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const base = try wasm_heap.binOp(&builder, layout.idx_type, .add, s_for_base, four);
    const base_local = try wasm_heap.storeLocal(&builder, "base", layout.idx_type, base);

    const offset_local = try builder.newLocal(wasm_heap.dummy_symbol, "@offset", layout.idx_type);
    const zero1 = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    try builder.emit(.{ .store_local = .{ .local = offset_local, .src = zero1 } });
    const count_local = try builder.newLocal(wasm_heap.dummy_symbol, "@count", layout.idx_type);
    const zero2 = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    try builder.emit(.{ .store_local = .{ .local = count_local, .src = zero2 } });

    const loop_header = try builder.newBlock();
    builder.terminate(.{ .jump = .{ .target = loop_header } });

    builder.setCurrentBlock(loop_header);
    const offset_for_cmp = try wasm_heap.loadLocal(&builder, offset_local, layout.idx_type);
    const limit_for_cmp = try wasm_heap.loadLocal(&builder, limit_local, layout.idx_type);
    const keep_going = try wasm_heap.cmpOp(&builder, layout.bool_type, .less, offset_for_cmp, limit_for_cmp);
    const loop_body = try builder.newBlock();
    const loop_exit = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = keep_going, .then_block = loop_body, .else_block = loop_exit } });

    builder.setCurrentBlock(loop_body);
    const offset_for_addr = try wasm_heap.loadLocal(&builder, offset_local, layout.idx_type);
    const base_for_addr = try wasm_heap.loadLocal(&builder, base_local, layout.idx_type);
    const addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, base_for_addr, offset_for_addr);
    const byte = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load8 = .{ .dst = byte, .addr = addr } });
    const width = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .call = .{ .dst = width, .callee = utf8_width, .args = try wasm_heap.dupeOne(module, byte) } });
    const width_local = try wasm_heap.storeLocal(&builder, "@width", layout.idx_type, width);

    const offset_for_inc = try wasm_heap.loadLocal(&builder, offset_local, layout.idx_type);
    const width_for_inc = try wasm_heap.loadLocal(&builder, width_local, layout.idx_type);
    const offset_next = try wasm_heap.binOp(&builder, layout.idx_type, .add, offset_for_inc, width_for_inc);
    try builder.emit(.{ .store_local = .{ .local = offset_local, .src = offset_next } });

    const count_for_inc = try wasm_heap.loadLocal(&builder, count_local, layout.idx_type);
    const one = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const count_next = try wasm_heap.binOp(&builder, layout.idx_type, .add, count_for_inc, one);
    try builder.emit(.{ .store_local = .{ .local = count_local, .src = count_next } });
    builder.terminate(.{ .jump = .{ .target = loop_header } });

    builder.setCurrentBlock(loop_exit);
    const count_final = try wasm_heap.loadLocal(&builder, count_local, layout.idx_type);
    builder.terminate(.{ .return_value = .{ .value = count_final } });
    return id;
}

// `@string_index_of(s, needle, start_byte) -> i32`: байтовый offset
// первого вхождения `needle` в `s` начиная с `start_byte` включительно,
// либо -1. Пустой needle сразу совпадает на `start_byte` (совпадает с
// поведением `std.mem.indexOf` — `strReplace`/`strSplit` в `vm.zig` оба
// отдельно обрабатывают пустой needle на СВОИХ местах вызова, но то, что
// базовый примитив поиска здесь согласован с `std.mem.indexOf`, делает
// эту одну функцию корректной для обоих случаев).
fn buildIndexOf(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@string_index_of", wasm_heap.dummy_symbol, layout.idx_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const s_local = try builder.newLocal(wasm_heap.dummy_symbol, "s", layout.ptr_type);
    const needle_local = try builder.newLocal(wasm_heap.dummy_symbol, "needle", layout.ptr_type);
    const start_local = try builder.newLocal(wasm_heap.dummy_symbol, "start", layout.idx_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{ s_local, needle_local, start_local });
    builder.currentFunction().type_store = type_store;

    const s1 = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const s_len = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load = .{ .dst = s_len, .addr = s1 } });
    const s_len_local = try wasm_heap.storeLocal(&builder, "s_len", layout.idx_type, s_len);

    const n1 = try wasm_heap.loadLocal(&builder, needle_local, layout.ptr_type);
    const needle_len = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load = .{ .dst = needle_len, .addr = n1 } });
    const needle_len_local = try wasm_heap.storeLocal(&builder, "needle_len", layout.idx_type, needle_len);

    // Пустой needle: сразу вернуть start.
    const needle_len_for_cmp = try wasm_heap.loadLocal(&builder, needle_len_local, layout.idx_type);
    const zero_c = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    const needle_empty = try wasm_heap.cmpOp(&builder, layout.bool_type, .equal, needle_len_for_cmp, zero_c);
    const empty_block = try builder.newBlock();
    const search_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = needle_empty, .then_block = empty_block, .else_block = search_block } });

    builder.setCurrentBlock(empty_block);
    const start_for_empty = try wasm_heap.loadLocal(&builder, start_local, layout.idx_type);
    builder.terminate(.{ .return_value = .{ .value = start_for_empty } });

    builder.setCurrentBlock(search_block);
    const four_s = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const s_for_base = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const s_base = try wasm_heap.binOp(&builder, layout.idx_type, .add, s_for_base, four_s);
    const s_base_local = try wasm_heap.storeLocal(&builder, "s_base", layout.idx_type, s_base);
    const four_n = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const n_for_base = try wasm_heap.loadLocal(&builder, needle_local, layout.ptr_type);
    const n_base = try wasm_heap.binOp(&builder, layout.idx_type, .add, n_for_base, four_n);
    const n_base_local = try wasm_heap.storeLocal(&builder, "n_base", layout.idx_type, n_base);

    const i_local = try builder.newLocal(wasm_heap.dummy_symbol, "@i", layout.idx_type);
    const start_reload = try wasm_heap.loadLocal(&builder, start_local, layout.idx_type);
    try builder.emit(.{ .store_local = .{ .local = i_local, .src = start_reload } });

    const outer_header = try builder.newBlock();
    builder.terminate(.{ .jump = .{ .target = outer_header } });

    // Условие внешнего цикла: i + needle_len <= s_len.
    builder.setCurrentBlock(outer_header);
    const i_for_bound = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const needle_len_for_bound = try wasm_heap.loadLocal(&builder, needle_len_local, layout.idx_type);
    const i_plus_needle = try wasm_heap.binOp(&builder, layout.idx_type, .add, i_for_bound, needle_len_for_bound);
    const s_len_for_bound = try wasm_heap.loadLocal(&builder, s_len_local, layout.idx_type);
    const outer_keep_going = try wasm_heap.cmpOp(&builder, layout.bool_type, .less_equal, i_plus_needle, s_len_for_bound);
    const outer_body = try builder.newBlock();
    const not_found_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = outer_keep_going, .then_block = outer_body, .else_block = not_found_block } });

    builder.setCurrentBlock(not_found_block);
    // -1 вычисляется как 0-1 (wrapping i32-вычитание), НЕ сырой
    // константой — `wasm_heap.addressConst` принимает `u32` и
    // value-preserving-приводит его к i64 для SLEB128-кодирования, что
    // НЕ переинтерпретирует битовый паттерн большого u32 как задуманный
    // отрицательный i32; вычитание в рантайме обходит весь этот вопрос
    // (гарантированно корректный переполняющий two's-complement,
    // определённый спецификацией WASM).
    const zero_nf = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    const one_nf = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const neg_one = try wasm_heap.binOp(&builder, layout.idx_type, .subtract, zero_nf, one_nf);
    builder.terminate(.{ .return_value = .{ .value = neg_one } });

    // Внутренний цикл: сравнить needle_len байт по адресу s_base+i с
    // n_base.
    builder.setCurrentBlock(outer_body);
    const j_local = try builder.newLocal(wasm_heap.dummy_symbol, "@j", layout.idx_type);
    const zero_j = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    try builder.emit(.{ .store_local = .{ .local = j_local, .src = zero_j } });

    const inner_header = try builder.newBlock();
    builder.terminate(.{ .jump = .{ .target = inner_header } });

    builder.setCurrentBlock(inner_header);
    const j_for_cmp = try wasm_heap.loadLocal(&builder, j_local, layout.idx_type);
    const needle_len_for_inner = try wasm_heap.loadLocal(&builder, needle_len_local, layout.idx_type);
    const inner_keep_going = try wasm_heap.cmpOp(&builder, layout.bool_type, .less, j_for_cmp, needle_len_for_inner);
    const inner_body = try builder.newBlock();
    const matched_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = inner_keep_going, .then_block = inner_body, .else_block = matched_block } });

    builder.setCurrentBlock(inner_body);
    const j_for_s = try wasm_heap.loadLocal(&builder, j_local, layout.idx_type);
    const i_for_s = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const s_off = try wasm_heap.binOp(&builder, layout.idx_type, .add, i_for_s, j_for_s);
    const s_base_for_addr = try wasm_heap.loadLocal(&builder, s_base_local, layout.idx_type);
    const s_addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, s_base_for_addr, s_off);
    const s_byte = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load8 = .{ .dst = s_byte, .addr = s_addr } });
    const s_byte_local = try wasm_heap.storeLocal(&builder, "@s_byte", layout.idx_type, s_byte);

    const j_for_n = try wasm_heap.loadLocal(&builder, j_local, layout.idx_type);
    const n_base_for_addr = try wasm_heap.loadLocal(&builder, n_base_local, layout.idx_type);
    const n_addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, n_base_for_addr, j_for_n);
    const n_byte = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load8 = .{ .dst = n_byte, .addr = n_addr } });

    const s_byte_reload = try wasm_heap.loadLocal(&builder, s_byte_local, layout.idx_type);
    const byte_matches = try wasm_heap.cmpOp(&builder, layout.bool_type, .equal, s_byte_reload, n_byte);
    const inner_continue = try builder.newBlock();
    const inner_mismatch = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = byte_matches, .then_block = inner_continue, .else_block = inner_mismatch } });

    builder.setCurrentBlock(inner_mismatch);
    const i_for_advance = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const one_a = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const i_advanced = try wasm_heap.binOp(&builder, layout.idx_type, .add, i_for_advance, one_a);
    try builder.emit(.{ .store_local = .{ .local = i_local, .src = i_advanced } });
    builder.terminate(.{ .jump = .{ .target = outer_header } });

    builder.setCurrentBlock(inner_continue);
    const j_for_inc = try wasm_heap.loadLocal(&builder, j_local, layout.idx_type);
    const one_b = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const j_next = try wasm_heap.binOp(&builder, layout.idx_type, .add, j_for_inc, one_b);
    try builder.emit(.{ .store_local = .{ .local = j_local, .src = j_next } });
    builder.terminate(.{ .jump = .{ .target = inner_header } });

    builder.setCurrentBlock(matched_block);
    const i_final = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    builder.terminate(.{ .return_value = .{ .value = i_final } });

    return id;
}

// `@string_slice(s, start, end) -> Строка`: индексация по РУНАМ (не по
// байтам), полуоткрытый интервал `[start, end)`. `start`/`end` приходят
// как `Число` (f64) — приводятся к i32 один раз через `.to_i32`.
// Паникует (как и нативная реализация, без клэмпинга), если `start >
// end` или итоговый байтовый offset конца выходит за пределы строки.
fn buildSlice(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout, rune_byte_offset: mir.FunctionId) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@string_slice", wasm_heap.dummy_symbol, layout.ptr_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const s_local = try builder.newLocal(wasm_heap.dummy_symbol, "s", layout.ptr_type);
    const start_local = try builder.newLocal(wasm_heap.dummy_symbol, "start", type_store.builtins.number);
    const end_local = try builder.newLocal(wasm_heap.dummy_symbol, "end", type_store.builtins.number);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{ s_local, start_local, end_local });
    builder.currentFunction().type_store = type_store;

    const start_f64 = try wasm_heap.loadLocal(&builder, start_local, type_store.builtins.number);
    const start_i32 = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .unary = .{ .dst = start_i32, .op = .to_i32, .src = start_f64 } });
    const start_i32_local = try wasm_heap.storeLocal(&builder, "start_i32", layout.idx_type, start_i32);

    const end_f64 = try wasm_heap.loadLocal(&builder, end_local, type_store.builtins.number);
    const end_i32 = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .unary = .{ .dst = end_i32, .op = .to_i32, .src = end_f64 } });
    const end_i32_local = try wasm_heap.storeLocal(&builder, "end_i32", layout.idx_type, end_i32);

    const start_for_cmp = try wasm_heap.loadLocal(&builder, start_i32_local, layout.idx_type);
    const end_for_cmp = try wasm_heap.loadLocal(&builder, end_i32_local, layout.idx_type);
    const range_ok = try wasm_heap.cmpOp(&builder, layout.bool_type, .less_equal, start_for_cmp, end_for_cmp);
    const proceed_block = try builder.newBlock();
    const bad_range_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = range_ok, .then_block = proceed_block, .else_block = bad_range_block } });

    builder.setCurrentBlock(bad_range_block);
    builder.terminate(.{ .unreachable_term = .{ .reason = "строки.срез(): границы вне диапазона" } });

    builder.setCurrentBlock(proceed_block);
    const s_for_start = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const start_for_call = try wasm_heap.loadLocal(&builder, start_i32_local, layout.idx_type);
    const start_byte = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .call = .{ .dst = start_byte, .callee = rune_byte_offset, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ s_for_start, start_for_call }) } });
    const start_byte_local = try wasm_heap.storeLocal(&builder, "start_byte", layout.idx_type, start_byte);

    const s_for_end = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const end_for_call = try wasm_heap.loadLocal(&builder, end_i32_local, layout.idx_type);
    const end_byte = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .call = .{ .dst = end_byte, .callee = rune_byte_offset, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ s_for_end, end_for_call }) } });
    const end_byte_local = try wasm_heap.storeLocal(&builder, "end_byte", layout.idx_type, end_byte);

    const s_for_len = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const s_len = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load = .{ .dst = s_len, .addr = s_for_len } });
    const s_len_local = try wasm_heap.storeLocal(&builder, "s_len", layout.idx_type, s_len);

    const end_byte_for_cmp = try wasm_heap.loadLocal(&builder, end_byte_local, layout.idx_type);
    const s_len_for_cmp = try wasm_heap.loadLocal(&builder, s_len_local, layout.idx_type);
    const end_ok = try wasm_heap.cmpOp(&builder, layout.bool_type, .less_equal, end_byte_for_cmp, s_len_for_cmp);
    const copy_block = try builder.newBlock();
    const bad_end_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = end_ok, .then_block = copy_block, .else_block = bad_end_block } });

    builder.setCurrentBlock(bad_end_block);
    builder.terminate(.{ .unreachable_term = .{ .reason = "строки.срез(): границы вне диапазона" } });

    builder.setCurrentBlock(copy_block);
    const end_byte_for_len = try wasm_heap.loadLocal(&builder, end_byte_local, layout.idx_type);
    const start_byte_for_len = try wasm_heap.loadLocal(&builder, start_byte_local, layout.idx_type);
    const result_len = try wasm_heap.binOp(&builder, layout.idx_type, .subtract, end_byte_for_len, start_byte_for_len);
    const result_len_local = try wasm_heap.storeLocal(&builder, "result_len", layout.idx_type, result_len);

    const four1 = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const result_len_for_size = try wasm_heap.loadLocal(&builder, result_len_local, layout.idx_type);
    const alloc_size = try wasm_heap.binOp(&builder, layout.idx_type, .add, four1, result_len_for_size);
    const alloc_id = wasm_heap.findFunctionByName(module, wasm_heap.alloc_function_name).?;
    const handle = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = handle, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, alloc_size) } });
    const handle_local = try wasm_heap.storeLocal(&builder, "handle", layout.ptr_type, handle);

    const result_len_for_header = try wasm_heap.loadLocal(&builder, result_len_local, layout.idx_type);
    const handle_for_header = try wasm_heap.loadLocal(&builder, handle_local, layout.ptr_type);
    try builder.emit(.{ .mem_store = .{ .addr = handle_for_header, .src = result_len_for_header } });

    const four2 = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const s_for_src_base = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const s_data_base = try wasm_heap.binOp(&builder, layout.idx_type, .add, s_for_src_base, four2);
    const start_byte_for_src = try wasm_heap.loadLocal(&builder, start_byte_local, layout.idx_type);
    const src_base = try wasm_heap.binOp(&builder, layout.idx_type, .add, s_data_base, start_byte_for_src);
    const src_base_local = try wasm_heap.storeLocal(&builder, "src_base", layout.idx_type, src_base);

    const four3 = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const handle_for_dst_base = try wasm_heap.loadLocal(&builder, handle_local, layout.ptr_type);
    const dst_base = try wasm_heap.binOp(&builder, layout.idx_type, .add, handle_for_dst_base, four3);
    const dst_base_local = try wasm_heap.storeLocal(&builder, "dst_base", layout.idx_type, dst_base);

    try emitByteCopyLoop(&builder, layout, src_base_local, dst_base_local, result_len_local);

    const handle_final = try wasm_heap.loadLocal(&builder, handle_local, layout.ptr_type);
    builder.terminate(.{ .return_value = .{ .value = handle_final } });
    return id;
}

// `@string_find(s, needle, start_rune) -> Число`: индексация по рунам
// (и `start`, и возвращаемое значение), при отсутствии совпадения
// возвращает -1 (точно как `strFind` в `vm.zig` — обычное `Число`, не
// `Опция`).
fn buildFind(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout, rune_byte_offset: mir.FunctionId, index_of: mir.FunctionId, byte_to_rune_count: mir.FunctionId) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@string_find", wasm_heap.dummy_symbol, type_store.builtins.number, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const s_local = try builder.newLocal(wasm_heap.dummy_symbol, "s", layout.ptr_type);
    const needle_local = try builder.newLocal(wasm_heap.dummy_symbol, "needle", layout.ptr_type);
    const start_local = try builder.newLocal(wasm_heap.dummy_symbol, "start", type_store.builtins.number);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{ s_local, needle_local, start_local });
    builder.currentFunction().type_store = type_store;

    const start_f64 = try wasm_heap.loadLocal(&builder, start_local, type_store.builtins.number);
    const start_i32 = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .unary = .{ .dst = start_i32, .op = .to_i32, .src = start_f64 } });
    const start_i32_local = try wasm_heap.storeLocal(&builder, "start_i32", layout.idx_type, start_i32);

    const s_for_offset = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const start_for_offset = try wasm_heap.loadLocal(&builder, start_i32_local, layout.idx_type);
    const start_byte = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .call = .{ .dst = start_byte, .callee = rune_byte_offset, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ s_for_offset, start_for_offset }) } });
    const start_byte_local = try wasm_heap.storeLocal(&builder, "start_byte", layout.idx_type, start_byte);

    const s_for_search = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const needle_for_search = try wasm_heap.loadLocal(&builder, needle_local, layout.ptr_type);
    const start_byte_for_search = try wasm_heap.loadLocal(&builder, start_byte_local, layout.idx_type);
    const found_byte = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .call = .{ .dst = found_byte, .callee = index_of, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ s_for_search, needle_for_search, start_byte_for_search }) } });
    const found_byte_local = try wasm_heap.storeLocal(&builder, "found_byte", layout.idx_type, found_byte);

    const found_for_cmp = try wasm_heap.loadLocal(&builder, found_byte_local, layout.idx_type);
    const zero_cmp = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    const zero_for_neg = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const neg_one_cmp = try wasm_heap.binOp(&builder, layout.idx_type, .subtract, zero_cmp, zero_for_neg);
    const not_found = try wasm_heap.cmpOp(&builder, layout.bool_type, .equal, found_for_cmp, neg_one_cmp);
    const not_found_block = try builder.newBlock();
    const found_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = not_found, .then_block = not_found_block, .else_block = found_block } });

    builder.setCurrentBlock(not_found_block);
    const zero_r = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    const one_r = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const neg_one_result_i32 = try wasm_heap.binOp(&builder, layout.idx_type, .subtract, zero_r, one_r);
    const neg_one_f64 = try builder.newValue(type_store.builtins.number);
    try builder.emit(.{ .unary = .{ .dst = neg_one_f64, .op = .from_i32, .src = neg_one_result_i32 } });
    builder.terminate(.{ .return_value = .{ .value = neg_one_f64 } });

    builder.setCurrentBlock(found_block);
    const s_for_count = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const found_for_count = try wasm_heap.loadLocal(&builder, found_byte_local, layout.idx_type);
    const rune_index = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .call = .{ .dst = rune_index, .callee = byte_to_rune_count, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ s_for_count, found_for_count }) } });
    const rune_index_f64 = try builder.newValue(type_store.builtins.number);
    try builder.emit(.{ .unary = .{ .dst = rune_index_f64, .op = .from_i32, .src = rune_index } });
    builder.terminate(.{ .return_value = .{ .value = rune_index_f64 } });
    return id;
}

// `@string_replace(s, target, replacement) -> Строка`: заменяет ВСЕ
// вхождения `target` на `replacement`. Пустой `target` возвращает копию
// `s` без изменений (точно как `strReplace` в `vm.zig`). Намеренно
// построена ПОВЕРХ уже проверенных @string_find/@string_slice/
// @string_concat/@string_length, а не как второй самописный проход
// побайтовой обработки — такой подход через переиспользование оставляет
// весь риск побайтовой арифметики покрытым тестами тех других функций,
// вместо второй с нуля написанной двухпроходной реализации копирования
// байт.
fn buildReplace(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout, length: mir.FunctionId, slice: mir.FunctionId, find: mir.FunctionId, concat: mir.FunctionId) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@string_replace", wasm_heap.dummy_symbol, layout.ptr_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const s_local = try builder.newLocal(wasm_heap.dummy_symbol, "s", layout.ptr_type);
    const target_local = try builder.newLocal(wasm_heap.dummy_symbol, "target", layout.ptr_type);
    const replacement_local = try builder.newLocal(wasm_heap.dummy_symbol, "replacement", layout.ptr_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{ s_local, target_local, replacement_local });
    builder.currentFunction().type_store = type_store;
    const alloc_id = wasm_heap.findFunctionByName(module, wasm_heap.alloc_function_name).?;
    const number_type = type_store.builtins.number;

    const t1 = try wasm_heap.loadLocal(&builder, target_local, layout.ptr_type);
    const target_byte_len = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load = .{ .dst = target_byte_len, .addr = t1 } });
    const target_byte_len_local = try wasm_heap.storeLocal(&builder, "target_byte_len", layout.idx_type, target_byte_len);

    const target_byte_len_for_cmp = try wasm_heap.loadLocal(&builder, target_byte_len_local, layout.idx_type);
    const zero_t = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    const target_empty = try wasm_heap.cmpOp(&builder, layout.bool_type, .equal, target_byte_len_for_cmp, zero_t);
    const copy_verbatim_block = try builder.newBlock();
    const do_replace_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = target_empty, .then_block = copy_verbatim_block, .else_block = do_replace_block } });

    builder.setCurrentBlock(copy_verbatim_block);
    {
        const s1 = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
        const s_len = try builder.newValue(layout.idx_type);
        try builder.emit(.{ .mem_load = .{ .dst = s_len, .addr = s1 } });
        const s_len_local = try wasm_heap.storeLocal(&builder, "s_len", layout.idx_type, s_len);

        const four1 = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
        const s_len_for_size = try wasm_heap.loadLocal(&builder, s_len_local, layout.idx_type);
        const alloc_size = try wasm_heap.binOp(&builder, layout.idx_type, .add, four1, s_len_for_size);
        const handle = try builder.newValue(layout.ptr_type);
        try builder.emit(.{ .call = .{ .dst = handle, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, alloc_size) } });
        const handle_local = try wasm_heap.storeLocal(&builder, "handle", layout.ptr_type, handle);

        const s_len_for_header = try wasm_heap.loadLocal(&builder, s_len_local, layout.idx_type);
        const handle_for_header = try wasm_heap.loadLocal(&builder, handle_local, layout.ptr_type);
        try builder.emit(.{ .mem_store = .{ .addr = handle_for_header, .src = s_len_for_header } });

        const four2 = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
        const s_for_src = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
        const src_base = try wasm_heap.binOp(&builder, layout.idx_type, .add, s_for_src, four2);
        const src_base_local = try wasm_heap.storeLocal(&builder, "src_base", layout.idx_type, src_base);
        const four3 = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
        const handle_for_dst = try wasm_heap.loadLocal(&builder, handle_local, layout.ptr_type);
        const dst_base = try wasm_heap.binOp(&builder, layout.idx_type, .add, handle_for_dst, four3);
        const dst_base_local = try wasm_heap.storeLocal(&builder, "dst_base", layout.idx_type, dst_base);
        try emitByteCopyLoop(&builder, layout, src_base_local, dst_base_local, s_len_local);

        const handle_final = try wasm_heap.loadLocal(&builder, handle_local, layout.ptr_type);
        builder.terminate(.{ .return_value = .{ .value = handle_final } });
    }

    builder.setCurrentBlock(do_replace_block);
    const target_for_len = try wasm_heap.loadLocal(&builder, target_local, layout.ptr_type);
    const target_rune_len = try builder.newValue(number_type);
    try builder.emit(.{ .call = .{ .dst = target_rune_len, .callee = length, .args = try wasm_heap.dupeOne(module, target_for_len) } });
    const target_rune_len_local = try wasm_heap.storeLocal(&builder, "target_rune_len", number_type, target_rune_len);

    // result начинается как свежая пустая строка (alloc(4), header=0).
    const four_r = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const result_init = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = result_init, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, four_r) } });
    const result_init_local = try wasm_heap.storeLocal(&builder, "@result_init", layout.ptr_type, result_init);
    const zero_hdr = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    const result_init_for_header = try wasm_heap.loadLocal(&builder, result_init_local, layout.ptr_type);
    try builder.emit(.{ .mem_store = .{ .addr = result_init_for_header, .src = zero_hdr } });
    const result_local = try builder.newLocal(wasm_heap.dummy_symbol, "@result", layout.ptr_type);
    const result_init_reload = try wasm_heap.loadLocal(&builder, result_init_local, layout.ptr_type);
    try builder.emit(.{ .store_local = .{ .local = result_local, .src = result_init_reload } });

    const search_start_local = try builder.newLocal(wasm_heap.dummy_symbol, "@search_start", number_type);
    const zero_ss = try wasm_heap.numberConst(&builder, number_type, 0);
    try builder.emit(.{ .store_local = .{ .local = search_start_local, .src = zero_ss } });

    const loop_header = try builder.newBlock();
    builder.terminate(.{ .jump = .{ .target = loop_header } });

    builder.setCurrentBlock(loop_header);
    const s_for_find = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const target_for_find = try wasm_heap.loadLocal(&builder, target_local, layout.ptr_type);
    const search_start_for_find = try wasm_heap.loadLocal(&builder, search_start_local, number_type);
    const found_rune = try builder.newValue(number_type);
    try builder.emit(.{ .call = .{ .dst = found_rune, .callee = find, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ s_for_find, target_for_find, search_start_for_find }) } });
    const found_rune_local = try wasm_heap.storeLocal(&builder, "@found_rune", number_type, found_rune);

    const found_rune_for_cmp = try wasm_heap.loadLocal(&builder, found_rune_local, number_type);
    const neg_one_number = try wasm_heap.numberConst(&builder, number_type, -1);
    // `cond` обязан быть условием ПРОДОЛЖЕНИЯ цикла, где `then_block` —
    // тело цикла (как и в любом другом цикле в этом файле, см. выше).
    // Определение loop-заголовка в `wasm_stackify` выбирает тело/выход
    // по тому, какая цель может вернуться обратно к заголовку
    // (`canReach`), а НЕ по буквальному доверию меткам then/else —
    // инвертирование полярности условия оставит branch переназначенным
    // под достижимость, но само УСЛОВИЕ будет по-прежнему проверять не
    // то, так что итоговый `if` будет выполнять продолжающий цикл код
    // при "не найдено" и безусловно проваливаться в код выхода/хвоста
    // вместо того, чтобы делать это только при отсутствии совпадения.
    const found = try wasm_heap.cmpOp(&builder, layout.bool_type, .not_equal, found_rune_for_cmp, neg_one_number);
    const tail_block = try builder.newBlock();
    const match_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = found, .then_block = match_block, .else_block = tail_block } });

    builder.setCurrentBlock(tail_block);
    {
        // `s_rune_len` (3-й аргумент `@string_slice`) обязан
        // производиться ПОСЛЕДНИМ, непосредственно перед вызовом —
        // аргументы `.call` воспроизводятся в перечисленном порядке в
        // предположении, что каждый по-настоящему свежий/смежный (та же
        // конвенция, которой следует весь этот файл).
        //
        // `result_for_final` обязан производиться ДО `remaining` —
        // аргументы финального concat — это `[result_for_final,
        // remaining]`, поэтому `result_for_final` должен быть
        // произведён раньше всех/лежать снизу, а `remaining` — самым
        // свежим/сверху. Если вычислить `remaining` первым (чтобы
        // держать его рядом с его же 3-аргументным вызовом slice), он
        // окажется ПОВЕРХ `result_for_final` вместо того, чтобы быть
        // под ним, что молча даёт развёрнутый результат ("bbxbbx"
        // вместо "xbbxbb"), а не ошибку валидатора — оба операнда имеют
        // один и тот же тип i32-хэндла, несовпадения типов, которое бы
        // это поймало, не возникает.
        const result_for_final = try wasm_heap.loadLocal(&builder, result_local, layout.ptr_type);
        const s_for_remaining = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
        const search_start_for_remaining = try wasm_heap.loadLocal(&builder, search_start_local, number_type);
        const s_for_slen = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
        const s_rune_len = try builder.newValue(number_type);
        try builder.emit(.{ .call = .{ .dst = s_rune_len, .callee = length, .args = try wasm_heap.dupeOne(module, s_for_slen) } });
        const remaining = try builder.newValue(layout.ptr_type);
        try builder.emit(.{ .call = .{ .dst = remaining, .callee = slice, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ s_for_remaining, search_start_for_remaining, s_rune_len }) } });
        const final_result = try builder.newValue(layout.ptr_type);
        try builder.emit(.{ .call = .{ .dst = final_result, .callee = concat, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ result_for_final, remaining }) } });
        builder.terminate(.{ .return_value = .{ .value = final_result } });
    }

    builder.setCurrentBlock(match_block);
    // `result_for_partial1` загружается ДО вычисления `segment` —
    // вызову concat ниже нужны аргументы `[result, segment]` именно в
    // этом порядке ПРОИЗВОДСТВА (result первым/снизу, segment
    // последним/сверху); вычисление segment первым оставило бы его
    // погребённым под позже загруженным result — наоборот тому, что
    // предполагает кодогенерация «.call воспроизводит аргументы в
    // перечисленном порядке».
    const result_for_partial1 = try wasm_heap.loadLocal(&builder, result_local, layout.ptr_type);
    const s_for_segment = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const search_start_for_segment = try wasm_heap.loadLocal(&builder, search_start_local, number_type);
    const found_rune_for_segment = try wasm_heap.loadLocal(&builder, found_rune_local, number_type);
    const segment = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = segment, .callee = slice, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ s_for_segment, search_start_for_segment, found_rune_for_segment }) } });
    const partial1 = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = partial1, .callee = concat, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ result_for_partial1, segment }) } });
    const partial1_local = try wasm_heap.storeLocal(&builder, "@partial1", layout.ptr_type, partial1);

    const partial1_reload = try wasm_heap.loadLocal(&builder, partial1_local, layout.ptr_type);
    const replacement_reload = try wasm_heap.loadLocal(&builder, replacement_local, layout.ptr_type);
    const partial2 = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = partial2, .callee = concat, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ partial1_reload, replacement_reload }) } });
    try builder.emit(.{ .store_local = .{ .local = result_local, .src = partial2 } });

    const found_rune_for_next = try wasm_heap.loadLocal(&builder, found_rune_local, number_type);
    const target_rune_len_for_next = try wasm_heap.loadLocal(&builder, target_rune_len_local, number_type);
    const search_start_next = try wasm_heap.binOp(&builder, number_type, .add, found_rune_for_next, target_rune_len_for_next);
    try builder.emit(.{ .store_local = .{ .local = search_start_local, .src = search_start_next } });
    builder.terminate(.{ .jump = .{ .target = loop_header } });

    return id;
}

// `@string_slice_bytes(s, start_byte, end_byte) -> Строка`: сырая
// подстрока с индексацией по БАЙТАМ, без проверки границ — приватна для
// этого файла (никогда не экспонируется как `строки.*`, за это отвечает
// `срез`, работающий по рунам). Вызывающие сами обязаны гарантировать
// `0 <= start_byte <= end_byte <= длина_байт(s)`; `@string_split`
// (единственный вызывающий) всегда выводит свои диапазоны из настоящего
// совпадения `@string_index_of` либо из собственной байтовой длины
// строки, так что этот инвариант выполняется по построению.
fn buildSliceBytes(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@string_slice_bytes", wasm_heap.dummy_symbol, layout.ptr_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const s_local = try builder.newLocal(wasm_heap.dummy_symbol, "s", layout.ptr_type);
    const start_local = try builder.newLocal(wasm_heap.dummy_symbol, "start", layout.idx_type);
    const end_local = try builder.newLocal(wasm_heap.dummy_symbol, "end", layout.idx_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{ s_local, start_local, end_local });
    builder.currentFunction().type_store = type_store;

    const end_for_len = try wasm_heap.loadLocal(&builder, end_local, layout.idx_type);
    const start_for_len = try wasm_heap.loadLocal(&builder, start_local, layout.idx_type);
    const result_len = try wasm_heap.binOp(&builder, layout.idx_type, .subtract, end_for_len, start_for_len);
    const result_len_local = try wasm_heap.storeLocal(&builder, "result_len", layout.idx_type, result_len);

    const four1 = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const result_len_for_size = try wasm_heap.loadLocal(&builder, result_len_local, layout.idx_type);
    const alloc_size = try wasm_heap.binOp(&builder, layout.idx_type, .add, four1, result_len_for_size);
    const alloc_id = wasm_heap.findFunctionByName(module, wasm_heap.alloc_function_name).?;
    const handle = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = handle, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, alloc_size) } });
    const handle_local = try wasm_heap.storeLocal(&builder, "handle", layout.ptr_type, handle);

    const result_len_for_header = try wasm_heap.loadLocal(&builder, result_len_local, layout.idx_type);
    const handle_for_header = try wasm_heap.loadLocal(&builder, handle_local, layout.ptr_type);
    try builder.emit(.{ .mem_store = .{ .addr = handle_for_header, .src = result_len_for_header } });

    const four2 = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const s_for_src_base = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const s_data_base = try wasm_heap.binOp(&builder, layout.idx_type, .add, s_for_src_base, four2);
    const start_for_src = try wasm_heap.loadLocal(&builder, start_local, layout.idx_type);
    const src_base = try wasm_heap.binOp(&builder, layout.idx_type, .add, s_data_base, start_for_src);
    const src_base_local = try wasm_heap.storeLocal(&builder, "src_base", layout.idx_type, src_base);

    const four3 = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const handle_for_dst_base = try wasm_heap.loadLocal(&builder, handle_local, layout.ptr_type);
    const dst_base = try wasm_heap.binOp(&builder, layout.idx_type, .add, handle_for_dst_base, four3);
    const dst_base_local = try wasm_heap.storeLocal(&builder, "dst_base", layout.idx_type, dst_base);

    try emitByteCopyLoop(&builder, layout, src_base_local, dst_base_local, result_len_local);

    const handle_final = try wasm_heap.loadLocal(&builder, handle_local, layout.ptr_type);
    builder.terminate(.{ .return_value = .{ .value = handle_final } });
    return id;
}

// `@string_split(s, separator) -> Массив(Строка)`: сопоставление
// разделителя как буквальной байтовой подстроки, точно как `strSplit` в
// `vm.zig` — пустой разделитель возвращает одноэлементный массив со
// всей исходной строкой без изменений (НЕ массив отдельных байт/рун).
fn buildSplit(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout, index_of: mir.FunctionId, slice_bytes: mir.FunctionId, array_runtime: wasm_objects.ArrayRuntime) !mir.FunctionId {
    const array_type = type_store.builtins.string; // непрозрачный i32-хэндл, как и любой другой ссылочный тип в этом файле
    const id = try mir_builder.newFunction(module, allocator, "@string_split", wasm_heap.dummy_symbol, array_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const s_local = try builder.newLocal(wasm_heap.dummy_symbol, "s", layout.ptr_type);
    const sep_local = try builder.newLocal(wasm_heap.dummy_symbol, "sep", layout.ptr_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{ s_local, sep_local });
    builder.currentFunction().type_store = type_store;

    const sep1 = try wasm_heap.loadLocal(&builder, sep_local, layout.ptr_type);
    const sep_len = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load = .{ .dst = sep_len, .addr = sep1 } });
    const sep_len_local = try wasm_heap.storeLocal(&builder, "sep_len", layout.idx_type, sep_len);

    const sep_len_for_cmp = try wasm_heap.loadLocal(&builder, sep_len_local, layout.idx_type);
    const zero_sep = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    const sep_empty = try wasm_heap.cmpOp(&builder, layout.bool_type, .equal, sep_len_for_cmp, zero_sep);
    const single_block = try builder.newBlock();
    const search_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = sep_empty, .then_block = single_block, .else_block = search_block } });

    builder.setCurrentBlock(single_block);
    {
        const arr = try builder.newValue(array_type);
        try builder.emit(.{ .call = .{ .dst = arr, .callee = array_runtime.new, .args = &.{} } });
        const arr_local = try wasm_heap.storeLocal(&builder, "@arr", array_type, arr);
        const arr_for_append = try wasm_heap.loadLocal(&builder, arr_local, array_type);
        const s_for_append = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
        try builder.emit(.{ .call = .{ .dst = null, .callee = array_runtime.append_i32, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ arr_for_append, s_for_append }) } });
        const arr_final = try wasm_heap.loadLocal(&builder, arr_local, array_type);
        builder.terminate(.{ .return_value = .{ .value = arr_final } });
    }

    builder.setCurrentBlock(search_block);
    const arr2 = try builder.newValue(array_type);
    try builder.emit(.{ .call = .{ .dst = arr2, .callee = array_runtime.new, .args = &.{} } });
    const arr2_local = try wasm_heap.storeLocal(&builder, "@arr", array_type, arr2);

    const s_for_len = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const s_len = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load = .{ .dst = s_len, .addr = s_for_len } });
    const s_len_local = try wasm_heap.storeLocal(&builder, "s_len", layout.idx_type, s_len);

    const cursor_local = try builder.newLocal(wasm_heap.dummy_symbol, "@cursor", layout.idx_type);
    const zero_cursor = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    try builder.emit(.{ .store_local = .{ .local = cursor_local, .src = zero_cursor } });

    const loop_header = try builder.newBlock();
    builder.terminate(.{ .jump = .{ .target = loop_header } });

    builder.setCurrentBlock(loop_header);
    const s_for_find = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const sep_for_find = try wasm_heap.loadLocal(&builder, sep_local, layout.ptr_type);
    const cursor_for_find = try wasm_heap.loadLocal(&builder, cursor_local, layout.idx_type);
    const found = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .call = .{ .dst = found, .callee = index_of, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ s_for_find, sep_for_find, cursor_for_find }) } });
    const found_local = try wasm_heap.storeLocal(&builder, "@found", layout.idx_type, found);

    const found_for_cmp = try wasm_heap.loadLocal(&builder, found_local, layout.idx_type);
    const zero_nf = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    const one_nf = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const neg_one = try wasm_heap.binOp(&builder, layout.idx_type, .subtract, zero_nf, one_nf);
    const found_here = try wasm_heap.cmpOp(&builder, layout.bool_type, .not_equal, found_for_cmp, neg_one);
    const match_block = try builder.newBlock();
    const tail_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = found_here, .then_block = match_block, .else_block = tail_block } });

    builder.setCurrentBlock(match_block);
    {
        // `arr_for_append` обязан производиться ДО `segment` — аргументы
        // вызова append — это `[arr_for_append, segment]`, поэтому
        // `arr_for_append` должен быть произведён раньше всех/лежать
        // снизу. Если вычислить `segment` первым (чтобы держать его
        // рядом с его же 3-аргументным вызовом slice_bytes), он окажется
        // ПОВЕРХ `arr_for_append` вместо того, чтобы быть под ним, так
        // что `@array_append_i32` молча получит (handle=segment,
        // value=arr) переставленными местами (оба операнда i32, ошибки
        // валидатора, которая бы это поймала, нет) — тот же риск
        // порядка, что и с `result_for_final`/`remaining` в
        // `@string_replace`.
        const arr_for_append = try wasm_heap.loadLocal(&builder, arr2_local, array_type);
        const s_for_seg = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
        const cursor_for_seg = try wasm_heap.loadLocal(&builder, cursor_local, layout.idx_type);
        const found_for_seg = try wasm_heap.loadLocal(&builder, found_local, layout.idx_type);
        const segment = try builder.newValue(layout.ptr_type);
        try builder.emit(.{ .call = .{ .dst = segment, .callee = slice_bytes, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ s_for_seg, cursor_for_seg, found_for_seg }) } });
        try builder.emit(.{ .call = .{ .dst = null, .callee = array_runtime.append_i32, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ arr_for_append, segment }) } });

        const found_for_next = try wasm_heap.loadLocal(&builder, found_local, layout.idx_type);
        const sep_len_for_next = try wasm_heap.loadLocal(&builder, sep_len_local, layout.idx_type);
        const next_cursor = try wasm_heap.binOp(&builder, layout.idx_type, .add, found_for_next, sep_len_for_next);
        try builder.emit(.{ .store_local = .{ .local = cursor_local, .src = next_cursor } });
        builder.terminate(.{ .jump = .{ .target = loop_header } });
    }

    builder.setCurrentBlock(tail_block);
    {
        // То же исправление, что и выше в `match_block`: хэндл массива
        // производится первым.
        const arr_for_final_append = try wasm_heap.loadLocal(&builder, arr2_local, array_type);
        const s_for_tail = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
        const cursor_for_tail = try wasm_heap.loadLocal(&builder, cursor_local, layout.idx_type);
        const s_len_for_tail = try wasm_heap.loadLocal(&builder, s_len_local, layout.idx_type);
        const tail_segment = try builder.newValue(layout.ptr_type);
        try builder.emit(.{ .call = .{ .dst = tail_segment, .callee = slice_bytes, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ s_for_tail, cursor_for_tail, s_len_for_tail }) } });
        try builder.emit(.{ .call = .{ .dst = null, .callee = array_runtime.append_i32, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ arr_for_final_append, tail_segment }) } });
        const arr_final = try wasm_heap.loadLocal(&builder, arr2_local, array_type);
        builder.terminate(.{ .return_value = .{ .value = arr_final } });
    }

    return id;
}

// `@string_format_unsigned_digits(n) -> Строка`: `n` — НЕОТРИЦАТЕЛЬНОЕ
// целочисленное `Число` (вызывающий уже применил `int_trunc` и обработку
// знака) — пишет его десятичные цифры в маленький scratch-буфер с КОНЦА
// в обратном направлении (младшая значащая цифра первой — то, что
// естественно даёт цикл `% 10`), затем копирует ровно записанный
// диапазон в настоящую строку с префиксом длины. `n == 0` — особый
// случай (цикл ниже для него не даёт ни одной цифры, а не "0").
fn buildFormatUnsignedDigits(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout) !mir.FunctionId {
    const number_type = type_store.builtins.number;
    const id = try mir_builder.newFunction(module, allocator, "@string_format_unsigned_digits", wasm_heap.dummy_symbol, layout.ptr_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const n_local = try builder.newLocal(wasm_heap.dummy_symbol, "n", number_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{n_local});
    builder.currentFunction().type_store = type_store;
    const alloc_id = wasm_heap.findFunctionByName(module, wasm_heap.alloc_function_name).?;

    const n_for_zero_cmp = try wasm_heap.loadLocal(&builder, n_local, number_type);
    const zero_n = try wasm_heap.numberConst(&builder, number_type, 0);
    const is_zero = try wasm_heap.cmpOp(&builder, layout.bool_type, .equal, n_for_zero_cmp, zero_n);
    const zero_block = try builder.newBlock();
    const nonzero_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = is_zero, .then_block = zero_block, .else_block = nonzero_block } });

    builder.setCurrentBlock(zero_block);
    {
        const handle_final = try emitOneByteString(&builder, module, layout, '0');
        builder.terminate(.{ .return_value = .{ .value = handle_final } });
    }

    builder.setCurrentBlock(nonzero_block);
    // Диапазон i64 с запасом покрывает любое целочисленное `Число`,
    // которое сюда попадает (вплоть до ровно 2^53, согласно
    // задокументированному диапазону `Целое`) — 24 scratch-байта заметно
    // больше, чем максимум i64 в 19 цифр.
    const scratch_size = try wasm_heap.addressConst(&builder, layout.idx_type, 24);
    const scratch = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = scratch, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, scratch_size) } });
    const scratch_local = try wasm_heap.storeLocal(&builder, "@scratch", layout.ptr_type, scratch);

    const pos_local = try builder.newLocal(wasm_heap.dummy_symbol, "@pos", layout.idx_type);
    const twentyfour = try wasm_heap.addressConst(&builder, layout.idx_type, 24);
    try builder.emit(.{ .store_local = .{ .local = pos_local, .src = twentyfour } });

    const cur_local = try builder.newLocal(wasm_heap.dummy_symbol, "@cur", number_type);
    const n_reload = try wasm_heap.loadLocal(&builder, n_local, number_type);
    try builder.emit(.{ .store_local = .{ .local = cur_local, .src = n_reload } });

    const loop_header = try builder.newBlock();
    builder.terminate(.{ .jump = .{ .target = loop_header } });

    builder.setCurrentBlock(loop_header);
    const cur_for_cmp = try wasm_heap.loadLocal(&builder, cur_local, number_type);
    const zero_cur = try wasm_heap.numberConst(&builder, number_type, 0);
    const keep_going = try wasm_heap.cmpOp(&builder, layout.bool_type, .greater, cur_for_cmp, zero_cur);
    const loop_body = try builder.newBlock();
    const loop_exit = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = keep_going, .then_block = loop_body, .else_block = loop_exit } });

    builder.setCurrentBlock(loop_body);
    // `digit = cur - trunc(cur/10)*10` вместо `.modulo` — `.modulo` над
    // операндами f64 (`wasm_emit.zig`) идёт через общий трюк со
    // scratch-локалом i64 (`reserveScratchLocal`, жёстко привязанный к
    // `wasm_f64`), который конфликтует с СОБСТВЕННЫМ резервированием
    // scratch-локала у `mem_store`/`mem_store8`
    // (`reserveFrameScratch`/`reserveFrameStoreScratch`), когда оба
    // встречаются в одной функции. Здесь этого просто избегаем, вместо
    // того чтобы трогать общий механизм scratch в `wasm_emit.zig`.
    const cur_for_div = try wasm_heap.loadLocal(&builder, cur_local, number_type);
    const ten_div = try wasm_heap.numberConst(&builder, number_type, 10);
    const q = try wasm_heap.binOp(&builder, number_type, .int_divide, cur_for_div, ten_div);
    const q_local = try wasm_heap.storeLocal(&builder, "@q", number_type, q);
    // `cur_for_digit` (lhs) загружается ДО вычисления `q_times_10` (rhs)
    // — кодогенерация `.binary` предполагает, что операнды производятся
    // в порядке lhs-затем-rhs, rhs — самый свежий непосредственно перед
    // операцией.
    const cur_for_digit = try wasm_heap.loadLocal(&builder, cur_local, number_type);
    const q_for_mul = try wasm_heap.loadLocal(&builder, q_local, number_type);
    const ten_mul = try wasm_heap.numberConst(&builder, number_type, 10);
    const q_times_10 = try wasm_heap.binOp(&builder, number_type, .multiply, q_for_mul, ten_mul);
    const digit_f = try wasm_heap.binOp(&builder, number_type, .subtract, cur_for_digit, q_times_10);
    const digit_i32 = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .unary = .{ .dst = digit_i32, .op = .to_i32, .src = digit_f } });
    const zero_char2 = try wasm_heap.addressConst(&builder, layout.idx_type, '0');
    const digit_byte = try wasm_heap.binOp(&builder, layout.idx_type, .add, zero_char2, digit_i32);
    const digit_byte_local = try wasm_heap.storeLocal(&builder, "@digit_byte", layout.idx_type, digit_byte);

    const pos_for_dec = try wasm_heap.loadLocal(&builder, pos_local, layout.idx_type);
    const one_p = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const new_pos = try wasm_heap.binOp(&builder, layout.idx_type, .subtract, pos_for_dec, one_p);
    try builder.emit(.{ .store_local = .{ .local = pos_local, .src = new_pos } });

    const digit_byte_reload = try wasm_heap.loadLocal(&builder, digit_byte_local, layout.idx_type);
    const scratch_for_addr = try wasm_heap.loadLocal(&builder, scratch_local, layout.ptr_type);
    const new_pos_for_addr = try wasm_heap.loadLocal(&builder, pos_local, layout.idx_type);
    const byte_addr2 = try wasm_heap.binOp(&builder, layout.idx_type, .add, scratch_for_addr, new_pos_for_addr);
    try builder.emit(.{ .mem_store8 = .{ .addr = byte_addr2, .src = digit_byte_reload } });

    const q_for_next = try wasm_heap.loadLocal(&builder, q_local, number_type);
    try builder.emit(.{ .store_local = .{ .local = cur_local, .src = q_for_next } });
    builder.terminate(.{ .jump = .{ .target = loop_header } });

    builder.setCurrentBlock(loop_exit);
    // `twentyfour2` (lhs) обязан производиться ДО `pos_for_len` (rhs) —
    // кодогенерация `.binary` просто выдаёт опкод вычитания над тем, что
    // уже лежит на стеке, в порядке производства, она не переупорядочивает
    // под `lhs`/`rhs`; если сначала загрузить `pos`, молча вычислится
    // `pos - 24` (маленькое отрицательное, затем переинтерпретированное
    // как огромная беззнаковая длина) вместо `24 - pos`.
    const twentyfour2 = try wasm_heap.addressConst(&builder, layout.idx_type, 24);
    const pos_for_len = try wasm_heap.loadLocal(&builder, pos_local, layout.idx_type);
    const digit_count = try wasm_heap.binOp(&builder, layout.idx_type, .subtract, twentyfour2, pos_for_len);
    const digit_count_local = try wasm_heap.storeLocal(&builder, "@count", layout.idx_type, digit_count);

    const four_a = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const digit_count_for_size = try wasm_heap.loadLocal(&builder, digit_count_local, layout.idx_type);
    const alloc_size = try wasm_heap.binOp(&builder, layout.idx_type, .add, four_a, digit_count_for_size);
    const result = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = result, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, alloc_size) } });
    const result_local = try wasm_heap.storeLocal(&builder, "@result", layout.ptr_type, result);

    const digit_count_for_hdr = try wasm_heap.loadLocal(&builder, digit_count_local, layout.idx_type);
    const result_for_hdr = try wasm_heap.loadLocal(&builder, result_local, layout.ptr_type);
    try builder.emit(.{ .mem_store = .{ .addr = result_for_hdr, .src = digit_count_for_hdr } });

    // Здесь нет offset `+4` для заголовка (в отличие от любого другого
    // src_base в этом файле) — `scratch` — это сырой scratch-буфер, а не
    // строка формы `[len][bytes]`.
    const scratch_for_src = try wasm_heap.loadLocal(&builder, scratch_local, layout.ptr_type);
    const pos_for_src = try wasm_heap.loadLocal(&builder, pos_local, layout.idx_type);
    const src_base = try wasm_heap.binOp(&builder, layout.idx_type, .add, scratch_for_src, pos_for_src);
    const src_base_local = try wasm_heap.storeLocal(&builder, "@src_base", layout.idx_type, src_base);

    const four_c = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const result_for_dst = try wasm_heap.loadLocal(&builder, result_local, layout.ptr_type);
    const dst_base = try wasm_heap.binOp(&builder, layout.idx_type, .add, result_for_dst, four_c);
    const dst_base_local = try wasm_heap.storeLocal(&builder, "@dst_base", layout.idx_type, dst_base);

    try emitByteCopyLoop(&builder, layout, src_base_local, dst_base_local, digit_count_local);

    const result_final = try wasm_heap.loadLocal(&builder, result_local, layout.ptr_type);
    builder.terminate(.{ .return_value = .{ .value = result_final } });
    return id;
}

// `@string_from_int(x) -> Строка`: `x` (`Целое`, уже целое число)
// форматируется как обычное десятичное целое — совпадает с
// `strIntToStr` в `vm.zig` (`{d}` над `@intFromFloat(x)`) для любого
// значения в задокументированном точном диапазоне `Целое` (вплоть до
// 2^53).
fn buildFromInt(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout, format_digits: mir.FunctionId, concat: mir.FunctionId) !mir.FunctionId {
    const number_type = type_store.builtins.number;
    const id = try mir_builder.newFunction(module, allocator, "@string_from_int", wasm_heap.dummy_symbol, layout.ptr_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const x_local = try builder.newLocal(wasm_heap.dummy_symbol, "x", number_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{x_local});
    builder.currentFunction().type_store = type_store;

    const x_for_cmp = try wasm_heap.loadLocal(&builder, x_local, number_type);
    const zero_x = try wasm_heap.numberConst(&builder, number_type, 0);
    const is_neg = try wasm_heap.cmpOp(&builder, layout.bool_type, .less, x_for_cmp, zero_x);
    const neg_block = try builder.newBlock();
    const pos_block = try builder.newBlock();
    const abs_local = try builder.newLocal(wasm_heap.dummy_symbol, "@abs", number_type);
    builder.terminate(.{ .branch = .{ .cond = is_neg, .then_block = neg_block, .else_block = pos_block } });

    builder.setCurrentBlock(neg_block);
    // `zero_neg` (lhs) обязан производиться ДО `x_for_neg` (rhs) — если
    // сначала загрузить `x`, молча вычислится `x - 0` (без изменений,
    // всё ещё отрицательное) вместо `0 - x`, то же ограничение порядка
    // производства, что и в других местах этого файла.
    const zero_neg = try wasm_heap.numberConst(&builder, number_type, 0);
    const x_for_neg = try wasm_heap.loadLocal(&builder, x_local, number_type);
    const negated = try wasm_heap.binOp(&builder, number_type, .subtract, zero_neg, x_for_neg);
    try builder.emit(.{ .store_local = .{ .local = abs_local, .src = negated } });
    const after_block = try builder.newBlock();
    builder.terminate(.{ .jump = .{ .target = after_block } });

    builder.setCurrentBlock(pos_block);
    const x_for_pos = try wasm_heap.loadLocal(&builder, x_local, number_type);
    try builder.emit(.{ .store_local = .{ .local = abs_local, .src = x_for_pos } });
    builder.terminate(.{ .jump = .{ .target = after_block } });

    builder.setCurrentBlock(after_block);
    const abs_for_digits = try wasm_heap.loadLocal(&builder, abs_local, number_type);
    const digits_str = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = digits_str, .callee = format_digits, .args = try wasm_heap.dupeOne(module, abs_for_digits) } });

    const is_neg_for_sign = try wasm_heap.loadLocal(&builder, x_local, number_type); // перезагрузка x (свежая) — снова используется ниже для проверки знака
    const zero_sign = try wasm_heap.numberConst(&builder, number_type, 0);
    const is_neg2 = try wasm_heap.cmpOp(&builder, layout.bool_type, .less, is_neg_for_sign, zero_sign);
    const sign_block = try builder.newBlock();
    const no_sign_block = try builder.newBlock();
    const digits_str_local = try wasm_heap.storeLocal(&builder, "@digits", layout.ptr_type, digits_str);
    builder.terminate(.{ .branch = .{ .cond = is_neg2, .then_block = sign_block, .else_block = no_sign_block } });

    builder.setCurrentBlock(sign_block);
    {
        const minus = try emitOneByteString(&builder, module, layout, '-');
        const digits_reload = try wasm_heap.loadLocal(&builder, digits_str_local, layout.ptr_type);
        const with_sign = try builder.newValue(layout.ptr_type);
        try builder.emit(.{ .call = .{ .dst = with_sign, .callee = concat, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ minus, digits_reload }) } });
        builder.terminate(.{ .return_value = .{ .value = with_sign } });
    }

    builder.setCurrentBlock(no_sign_block);
    const digits_final = try wasm_heap.loadLocal(&builder, digits_str_local, layout.ptr_type);
    builder.terminate(.{ .return_value = .{ .value = digits_final } });

    return id;
}

// `@string_from_number(x) -> Строка`: практичный форматтер через
// извлечение цифр, а НЕ побитово точный порт `{d}` из Zig (который
// использует алгоритм кратчайшего round-trip-десятичного представления
// класса Ryu — по-настоящему сложно воспроизвести в сырой WASM-арифметике
// без произвольной точности). Извлекает до 15 дробных цифр через
// повторяющееся `frac *= 10; digit = trunc(frac); frac -= digit`, затем
// обрезает хвостовые нули — корректно для точных/коротких десятичных
// значений (подавляющее большинство реального вывода программ панос:
// счётчики циклов, простые результаты арифметики, денежные значения) и
// для целой части в точном диапазоне `Целое` (там точно совпадает с
// `@string_from_int`). Известное, осознанно принятое расхождение с
// нативной реализацией (задокументировано, не тихо): значениям, которым
// для round-trip нужно БОЛЬШЕ 15 значащих дробных цифр, может показать
// лишние шумовые хвостовые цифры или расхождение в округлении последней
// сохранённой цифры; экстремальные величины (~1e17+) теряют точность
// целой части так же, как это уже делает собственное f64-представление
// `Число`; NaN/Infinity НЕ обрабатываются особым образом (деление на
// ноль, дающее любое из них, отформатируется тем же путём извлечения
// цифр, что не совпадает с нативным выводом `"nan"`/`"inf"`) — ни один
// из этих случаев не встречается в обычной арифметике панос, и
// устоявшаяся практика этого файла — документировать такой пробел, а не
// блокироваться на полном порте Ryu.
fn buildFromNumber(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout, format_digits: mir.FunctionId, concat: mir.FunctionId) !mir.FunctionId {
    const number_type = type_store.builtins.number;
    const id = try mir_builder.newFunction(module, allocator, "@string_from_number", wasm_heap.dummy_symbol, layout.ptr_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const x_local = try builder.newLocal(wasm_heap.dummy_symbol, "x", number_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{x_local});
    builder.currentFunction().type_store = type_store;
    const alloc_id = wasm_heap.findFunctionByName(module, wasm_heap.alloc_function_name).?;

    const x_for_cmp = try wasm_heap.loadLocal(&builder, x_local, number_type);
    const zero_x = try wasm_heap.numberConst(&builder, number_type, 0);
    const is_neg = try wasm_heap.cmpOp(&builder, layout.bool_type, .less, x_for_cmp, zero_x);
    const neg_block = try builder.newBlock();
    const pos_block = try builder.newBlock();
    const abs_local = try builder.newLocal(wasm_heap.dummy_symbol, "@abs", number_type);
    builder.terminate(.{ .branch = .{ .cond = is_neg, .then_block = neg_block, .else_block = pos_block } });

    builder.setCurrentBlock(neg_block);
    // `zero_neg` (lhs) обязан производиться ДО `x_for_neg` (rhs) — если
    // сначала загрузить `x`, молча вычислится `x - 0` (без изменений,
    // всё ещё отрицательное) вместо `0 - x`, то же ограничение порядка
    // производства, что и в других местах этого файла.
    const zero_neg = try wasm_heap.numberConst(&builder, number_type, 0);
    const x_for_neg = try wasm_heap.loadLocal(&builder, x_local, number_type);
    const negated = try wasm_heap.binOp(&builder, number_type, .subtract, zero_neg, x_for_neg);
    try builder.emit(.{ .store_local = .{ .local = abs_local, .src = negated } });
    const after_abs = try builder.newBlock();
    builder.terminate(.{ .jump = .{ .target = after_abs } });

    builder.setCurrentBlock(pos_block);
    const x_for_pos = try wasm_heap.loadLocal(&builder, x_local, number_type);
    try builder.emit(.{ .store_local = .{ .local = abs_local, .src = x_for_pos } });
    builder.terminate(.{ .jump = .{ .target = after_abs } });

    builder.setCurrentBlock(after_abs);
    const abs_for_trunc = try wasm_heap.loadLocal(&builder, abs_local, number_type);
    const int_part = try builder.newValue(number_type);
    try builder.emit(.{ .unary = .{ .dst = int_part, .op = .int_trunc, .src = abs_for_trunc } });
    const int_part_local = try wasm_heap.storeLocal(&builder, "@int_part", number_type, int_part);

    const abs_for_frac = try wasm_heap.loadLocal(&builder, abs_local, number_type);
    const int_part_for_frac = try wasm_heap.loadLocal(&builder, int_part_local, number_type);
    const frac0 = try wasm_heap.binOp(&builder, number_type, .subtract, abs_for_frac, int_part_for_frac);
    const frac_local = try builder.newLocal(wasm_heap.dummy_symbol, "@frac", number_type);
    try builder.emit(.{ .store_local = .{ .local = frac_local, .src = frac0 } });

    const int_part_for_digits = try wasm_heap.loadLocal(&builder, int_part_local, number_type);
    const int_digits = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = int_digits, .callee = format_digits, .args = try wasm_heap.dupeOne(module, int_part_for_digits) } });
    const int_digits_local = try wasm_heap.storeLocal(&builder, "@int_digits", layout.ptr_type, int_digits);

    // Извлекаем до 15 дробных цифр в сырой scratch-буфер.
    const max_frac_digits = 15;
    const scratch_size = try wasm_heap.addressConst(&builder, layout.idx_type, max_frac_digits);
    const scratch = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = scratch, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, scratch_size) } });
    const scratch_local = try wasm_heap.storeLocal(&builder, "@fscratch", layout.ptr_type, scratch);

    const i_local = try builder.newLocal(wasm_heap.dummy_symbol, "@fi", layout.idx_type);
    const zero_i = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    try builder.emit(.{ .store_local = .{ .local = i_local, .src = zero_i } });

    const frac_loop_header = try builder.newBlock();
    builder.terminate(.{ .jump = .{ .target = frac_loop_header } });

    builder.setCurrentBlock(frac_loop_header);
    const i_for_cmp = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const max_c = try wasm_heap.addressConst(&builder, layout.idx_type, max_frac_digits);
    const frac_keep_going = try wasm_heap.cmpOp(&builder, layout.bool_type, .less, i_for_cmp, max_c);
    const frac_loop_body = try builder.newBlock();
    const frac_loop_exit = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = frac_keep_going, .then_block = frac_loop_body, .else_block = frac_loop_exit } });

    builder.setCurrentBlock(frac_loop_body);
    const frac_for_mul = try wasm_heap.loadLocal(&builder, frac_local, number_type);
    const ten_f = try wasm_heap.numberConst(&builder, number_type, 10);
    const frac_x10 = try wasm_heap.binOp(&builder, number_type, .multiply, frac_for_mul, ten_f);
    try builder.emit(.{ .store_local = .{ .local = frac_local, .src = frac_x10 } });

    const frac_for_trunc = try wasm_heap.loadLocal(&builder, frac_local, number_type);
    const digit_f = try builder.newValue(number_type);
    try builder.emit(.{ .unary = .{ .dst = digit_f, .op = .int_trunc, .src = frac_for_trunc } });
    const digit_f_local = try wasm_heap.storeLocal(&builder, "@fdigit", number_type, digit_f);

    const frac_for_sub = try wasm_heap.loadLocal(&builder, frac_local, number_type);
    const digit_for_sub = try wasm_heap.loadLocal(&builder, digit_f_local, number_type);
    const frac_next = try wasm_heap.binOp(&builder, number_type, .subtract, frac_for_sub, digit_for_sub);
    try builder.emit(.{ .store_local = .{ .local = frac_local, .src = frac_next } });

    const digit_for_i32 = try wasm_heap.loadLocal(&builder, digit_f_local, number_type);
    const digit_i32 = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .unary = .{ .dst = digit_i32, .op = .to_i32, .src = digit_for_i32 } });
    const zero_char = try wasm_heap.addressConst(&builder, layout.idx_type, '0');
    const digit_byte = try wasm_heap.binOp(&builder, layout.idx_type, .add, zero_char, digit_i32);
    const digit_byte_local = try wasm_heap.storeLocal(&builder, "@fdigit_byte", layout.idx_type, digit_byte);

    const digit_byte_reload = try wasm_heap.loadLocal(&builder, digit_byte_local, layout.idx_type);
    const scratch_for_addr = try wasm_heap.loadLocal(&builder, scratch_local, layout.ptr_type);
    const i_for_addr = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const byte_addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, scratch_for_addr, i_for_addr);
    try builder.emit(.{ .mem_store8 = .{ .addr = byte_addr, .src = digit_byte_reload } });

    const i_for_next = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const one_i = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const i_next = try wasm_heap.binOp(&builder, layout.idx_type, .add, i_for_next, one_i);
    try builder.emit(.{ .store_local = .{ .local = i_local, .src = i_next } });
    builder.terminate(.{ .jump = .{ .target = frac_loop_header } });

    builder.setCurrentBlock(frac_loop_exit);
    // Обрезаем хвостовые нули: count начинается с max_frac_digits и идёт
    // назад, пока байт непосредственно перед `count` равен '0'.
    const count_local = try builder.newLocal(wasm_heap.dummy_symbol, "@fcount", layout.idx_type);
    const max_c2 = try wasm_heap.addressConst(&builder, layout.idx_type, max_frac_digits);
    try builder.emit(.{ .store_local = .{ .local = count_local, .src = max_c2 } });

    const trim_header = try builder.newBlock();
    builder.terminate(.{ .jump = .{ .target = trim_header } });

    builder.setCurrentBlock(trim_header);
    const count_for_zero_cmp = try wasm_heap.loadLocal(&builder, count_local, layout.idx_type);
    const zero_tc = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    const count_nonzero = try wasm_heap.cmpOp(&builder, layout.bool_type, .greater, count_for_zero_cmp, zero_tc);
    const trim_check_last_block = try builder.newBlock();
    const trim_exit_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = count_nonzero, .then_block = trim_check_last_block, .else_block = trim_exit_block } });

    builder.setCurrentBlock(trim_check_last_block);
    const scratch_for_last = try wasm_heap.loadLocal(&builder, scratch_local, layout.ptr_type);
    const count_for_last = try wasm_heap.loadLocal(&builder, count_local, layout.idx_type);
    const one_tl = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const last_offset = try wasm_heap.binOp(&builder, layout.idx_type, .subtract, count_for_last, one_tl);
    const last_addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, scratch_for_last, last_offset);
    const last_byte = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load8 = .{ .dst = last_byte, .addr = last_addr } });
    const zero_char2 = try wasm_heap.addressConst(&builder, layout.idx_type, '0');
    const last_is_zero = try wasm_heap.cmpOp(&builder, layout.bool_type, .equal, last_byte, zero_char2);
    const trim_continue_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = last_is_zero, .then_block = trim_continue_block, .else_block = trim_exit_block } });

    builder.setCurrentBlock(trim_continue_block);
    const count_for_dec = try wasm_heap.loadLocal(&builder, count_local, layout.idx_type);
    const one_td = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const count_dec = try wasm_heap.binOp(&builder, layout.idx_type, .subtract, count_for_dec, one_td);
    try builder.emit(.{ .store_local = .{ .local = count_local, .src = count_dec } });
    builder.terminate(.{ .jump = .{ .target = trim_header } });

    builder.setCurrentBlock(trim_exit_block);
    const count_for_final_cmp = try wasm_heap.loadLocal(&builder, count_local, layout.idx_type);
    const zero_fc = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    const no_frac_digits = try wasm_heap.cmpOp(&builder, layout.bool_type, .equal, count_for_final_cmp, zero_fc);
    const int_only_block = try builder.newBlock();
    const with_frac_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = no_frac_digits, .then_block = int_only_block, .else_block = with_frac_block } });

    const sign_join_local = try builder.newLocal(wasm_heap.dummy_symbol, "@unsigned_result", layout.ptr_type);

    builder.setCurrentBlock(int_only_block);
    const int_digits_for_only = try wasm_heap.loadLocal(&builder, int_digits_local, layout.ptr_type);
    try builder.emit(.{ .store_local = .{ .local = sign_join_local, .src = int_digits_for_only } });
    const after_frac_block = try builder.newBlock();
    builder.terminate(.{ .jump = .{ .target = after_frac_block } });

    builder.setCurrentBlock(with_frac_block);
    {
        const four_a = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
        const count_for_size = try wasm_heap.loadLocal(&builder, count_local, layout.idx_type);
        const frac_alloc_size = try wasm_heap.binOp(&builder, layout.idx_type, .add, four_a, count_for_size);
        const frac_str = try builder.newValue(layout.ptr_type);
        try builder.emit(.{ .call = .{ .dst = frac_str, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, frac_alloc_size) } });
        const frac_str_local = try wasm_heap.storeLocal(&builder, "@frac_str", layout.ptr_type, frac_str);

        const count_for_hdr = try wasm_heap.loadLocal(&builder, count_local, layout.idx_type);
        const frac_str_for_hdr = try wasm_heap.loadLocal(&builder, frac_str_local, layout.ptr_type);
        try builder.emit(.{ .mem_store = .{ .addr = frac_str_for_hdr, .src = count_for_hdr } });

        const scratch_for_copy_src = try wasm_heap.loadLocal(&builder, scratch_local, layout.ptr_type);
        const src_base_local = try wasm_heap.storeLocal(&builder, "@fsrc_base", layout.idx_type, scratch_for_copy_src);

        const four_b = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
        const frac_str_for_dst = try wasm_heap.loadLocal(&builder, frac_str_local, layout.ptr_type);
        const dst_base = try wasm_heap.binOp(&builder, layout.idx_type, .add, frac_str_for_dst, four_b);
        const dst_base_local = try wasm_heap.storeLocal(&builder, "@fdst_base", layout.idx_type, dst_base);

        try emitByteCopyLoop(&builder, layout, src_base_local, dst_base_local, count_local);

        // `int_digits_for_cat` (arg0) обязан производиться ДО `dot`
        // (arg1) — та же конвенция порядка аргументов, что и везде в
        // этом файле; если построить `dot` первым, молча
        // сконкатенируется "." + digits вместо digits + "." (оба —
        // i32-хэндлы, ошибки валидатора, которая бы это поймала, нет).
        const int_digits_for_cat = try wasm_heap.loadLocal(&builder, int_digits_local, layout.ptr_type);
        const dot = try emitOneByteString(&builder, module, layout, '.');
        const with_dot = try builder.newValue(layout.ptr_type);
        try builder.emit(.{ .call = .{ .dst = with_dot, .callee = concat, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ int_digits_for_cat, dot }) } });
        const with_dot_local = try wasm_heap.storeLocal(&builder, "@with_dot", layout.ptr_type, with_dot);

        const with_dot_reload = try wasm_heap.loadLocal(&builder, with_dot_local, layout.ptr_type);
        const frac_str_reload = try wasm_heap.loadLocal(&builder, frac_str_local, layout.ptr_type);
        const full = try builder.newValue(layout.ptr_type);
        try builder.emit(.{ .call = .{ .dst = full, .callee = concat, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ with_dot_reload, frac_str_reload }) } });
        try builder.emit(.{ .store_local = .{ .local = sign_join_local, .src = full } });
        builder.terminate(.{ .jump = .{ .target = after_frac_block } });
    }

    builder.setCurrentBlock(after_frac_block);
    const x_for_sign = try wasm_heap.loadLocal(&builder, x_local, number_type);
    const zero_sign = try wasm_heap.numberConst(&builder, number_type, 0);
    const is_neg_final = try wasm_heap.cmpOp(&builder, layout.bool_type, .less, x_for_sign, zero_sign);
    const sign_block = try builder.newBlock();
    const no_sign_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = is_neg_final, .then_block = sign_block, .else_block = no_sign_block } });

    builder.setCurrentBlock(sign_block);
    const minus = try emitOneByteString(&builder, module, layout, '-');
    const unsigned_reload = try wasm_heap.loadLocal(&builder, sign_join_local, layout.ptr_type);
    const signed_result = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = signed_result, .callee = concat, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ minus, unsigned_reload }) } });
    builder.terminate(.{ .return_value = .{ .value = signed_result } });

    builder.setCurrentBlock(no_sign_block);
    const unsigned_final = try wasm_heap.loadLocal(&builder, sign_join_local, layout.ptr_type);
    builder.terminate(.{ .return_value = .{ .value = unsigned_final } });

    return id;
}

// `Ошибка` — встроенная структура из 2 полей (`module: Строка`,
// `message: Строка`), без тега (форма `.new_aggregate` в
// `wasm_objects.zig` — N слотов, без тега) — эталон
// `pushErrorResultForModule` в vm.zig
// (`heap.createAggregate("Ошибка", [module, message])`). `Результат` —
// обычная форма с тегированным вариантом (`Успех`=tag 0, `Неудача`=tag
// 1, порядок объявления из `prelude.zig`) с ОДНИМ полем полезной
// нагрузки в слоте 1. Обе строятся вручную здесь (сырой alloc +
// `frame_store`, собственные примитивы `wasm_objects.zig`), а не через
// выпуск `Ошибка(...)` как обычного исходника панос с последующей
// обработкой `wasm_objects.expand` — `Ошибка` это ПРИМИТИВ TypeStore
// (`.error_value` в `types.zig`, не обычный символ struct/enum), и у
// `mir_lowering.zig` вообще нет пути понижения для пользовательского
// ВЫЗОВА `Ошибка(a, b)` (подтверждено: `panos build: AOT (wasm) не
// поддерживает — символ не является локалью или функцией` — реальный,
// отдельный, ранее существовавший пробел, который этому файлу не
// следует молча обходить, обучая `mir_lowering.zig` новой конструкции).
// Ручная сборка обоих агрегатов полностью обходит этот пробел:
// собственное представление объектов WASM AOT (alloc + `frame_store`)
// не заботится о том, как ТИП значения записан в исходнике панос, лишь
// о том, чтобы байты совпадали с тем, что ожидает прочитать
// существующий код доступа к полям `Ошибка`/`Результат.Неудача`
// (`.получить_ошибку`, `.код`, `.сообщение` и т.д. — обычные
// `.get_property`/`.get_variant_field`/`.match_tag`, уже обрабатываемые
// `wasm_objects.zig`).
// Строит ОБА — и структуру `Ошибка`, и оборачивающий её вариант
// `Результат.Неудача(...)` — полностью самодостаточно (оба текстовых
// аргумента — заранее известные во время компиляции Zig-строки,
// материализуемые здесь через `emitConstString` — никогда не заранее
// существующий `ValueId`, переданный вызывающим, что рисковало бы как
// раз той устарелостью «значение произведено слишком рано, между ним и
// использованием выпущены другие инструкции», которую вся конвенция
// «производить смежно с единственным использованием» этого файла
// призвана предотвратить).
fn buildFailResultNamed(builder: *mir_builder.Builder, module: *mir.Module, layout: wasm_heap.PtrLayout, module_name_text: []const u8, message_text: []const u8) !mir.ValueId {
    const alloc_id = wasm_heap.findFunctionByName(module, wasm_heap.alloc_function_name).?;

    const err_size = try wasm_heap.addressConst(builder, layout.idx_type, 16);
    const err_frame = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = err_frame, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, err_size) } });
    const err_frame_local = try wasm_heap.storeLocal(builder, "@err", layout.ptr_type, err_frame);

    // `src` производится раньше `frame` (перезагруженного заново) —
    // собственная конвенция стека `frame_store`, см. `wasm_emit.zig`.
    const message_str = try emitConstString(builder, module, layout, message_text);
    const err_frame_for_msg = try wasm_heap.loadLocal(builder, err_frame_local, layout.ptr_type);
    try builder.emit(.{ .frame_store = .{ .frame = err_frame_for_msg, .slot = 1, .src = message_str } });

    const module_name = try emitConstString(builder, module, layout, module_name_text);
    const err_frame_for_mod = try wasm_heap.loadLocal(builder, err_frame_local, layout.ptr_type);
    try builder.emit(.{ .frame_store = .{ .frame = err_frame_for_mod, .slot = 0, .src = module_name } });

    const result_size = try wasm_heap.addressConst(builder, layout.idx_type, 16);
    const result_frame = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = result_frame, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, result_size) } });
    const result_frame_local = try wasm_heap.storeLocal(builder, "@result", layout.ptr_type, result_frame);

    const err_handle = try wasm_heap.loadLocal(builder, err_frame_local, layout.ptr_type);
    const result_frame_for_payload = try wasm_heap.loadLocal(builder, result_frame_local, layout.ptr_type);
    try builder.emit(.{ .frame_store = .{ .frame = result_frame_for_payload, .slot = 1, .src = err_handle } });

    const tag_neudacha = try wasm_heap.addressConst(builder, layout.idx_type, 1);
    const result_frame_for_tag = try wasm_heap.loadLocal(builder, result_frame_local, layout.ptr_type);
    try builder.emit(.{ .frame_store = .{ .frame = result_frame_for_tag, .slot = 0, .src = tag_neudacha } });

    return try wasm_heap.loadLocal(builder, result_frame_local, layout.ptr_type);
}

// Материализует известную во время компиляции (Zig-side) строку как
// свежую строку в куче `[len][bytes]` в рантайме — для текста, у
// которого нет собственной записи в секции данных (не литерал в
// компилируемом ИСХОДНИКЕ панос, например, константный текст
// имени-модуля/сообщения у `Ошибка`). Каждая запись байта развёрнута
// (текст короткий и имеет фиксированную длину во время СБОРКИ), а не
// настоящий WASM-цикл.
fn emitConstString(builder: *mir_builder.Builder, module: *mir.Module, layout: wasm_heap.PtrLayout, text: []const u8) !mir.ValueId {
    const alloc_id = wasm_heap.findFunctionByName(module, wasm_heap.alloc_function_name).?;
    const size = try wasm_heap.addressConst(builder, layout.idx_type, @intCast(4 + text.len));
    const handle = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = handle, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, size) } });
    const handle_local = try wasm_heap.storeLocal(builder, "@h", layout.ptr_type, handle);

    const len_val = try wasm_heap.addressConst(builder, layout.idx_type, @intCast(text.len));
    const handle_for_hdr = try wasm_heap.loadLocal(builder, handle_local, layout.ptr_type);
    try builder.emit(.{ .mem_store = .{ .addr = handle_for_hdr, .src = len_val } });

    for (text, 0..) |byte_val, i| {
        const byte_const = try wasm_heap.addressConst(builder, layout.idx_type, byte_val);
        const offset = try wasm_heap.addressConst(builder, layout.idx_type, @intCast(4 + i));
        const handle_for_byte = try wasm_heap.loadLocal(builder, handle_local, layout.ptr_type);
        const byte_addr = try wasm_heap.binOp(builder, layout.idx_type, .add, handle_for_byte, offset);
        try builder.emit(.{ .mem_store8 = .{ .addr = byte_addr, .src = byte_const } });
    }
    return try wasm_heap.loadLocal(builder, handle_local, layout.ptr_type);
}

// Проверка: `'0' <= byte <= '9'`.
fn emitIsDigit(builder: *mir_builder.Builder, layout: wasm_heap.PtrLayout, byte_local: mir.LocalId) !mir.ValueId {
    const byte_for_lo = try wasm_heap.loadLocal(builder, byte_local, layout.idx_type);
    const zero_char = try wasm_heap.addressConst(builder, layout.idx_type, '0');
    const ge_zero = try wasm_heap.cmpOp(builder, layout.bool_type, .greater_equal, byte_for_lo, zero_char);
    const byte_for_hi = try wasm_heap.loadLocal(builder, byte_local, layout.idx_type);
    const nine_char = try wasm_heap.addressConst(builder, layout.idx_type, '9');
    const le_nine = try wasm_heap.cmpOp(builder, layout.bool_type, .less_equal, byte_for_hi, nine_char);
    return try wasm_heap.binOp(builder, layout.bool_type, .bit_and, ge_zero, le_nine);
}

fn buildSuccessResult(builder: *mir_builder.Builder, module: *mir.Module, layout: wasm_heap.PtrLayout, number_type: types.TypeId, payload: mir.ValueId) !mir.ValueId {
    const alloc_id = wasm_heap.findFunctionByName(module, wasm_heap.alloc_function_name).?;
    _ = number_type;
    const result_size = try wasm_heap.addressConst(builder, layout.idx_type, 16);
    const result_frame = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = result_frame, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, result_size) } });
    const result_frame_local = try wasm_heap.storeLocal(builder, "@result", layout.ptr_type, result_frame);

    const result_frame_for_payload = try wasm_heap.loadLocal(builder, result_frame_local, layout.ptr_type);
    try builder.emit(.{ .frame_store = .{ .frame = result_frame_for_payload, .slot = 1, .src = payload } });

    const tag_uspeh = try wasm_heap.addressConst(builder, layout.idx_type, 0);
    const result_frame_for_tag = try wasm_heap.loadLocal(builder, result_frame_local, layout.ptr_type);
    try builder.emit(.{ .frame_store = .{ .frame = result_frame_for_tag, .slot = 0, .src = tag_uspeh } });

    return try wasm_heap.loadLocal(builder, result_frame_local, layout.ptr_type);
}

// `@string_to_number(s) -> Результат(Число, Ошибка)`: ПРАКТИЧНЫЙ парсер
// (необязательный знак, цифры, необязательные `.` + цифры) — совпадает
// с `std.fmt.parseFloat` для распространённых форм, которые
// действительно выдают программы панос (простые целые/десятичные, со
// знаком в начале или без него). Известный, задокументированный пробел
// (в том же духе, что и заметка о расхождении у `из_числа`): научная
// нотация (`1e10`), литералы `"inf"`/`"nan"` и ведущие/хвостовые пробелы
// НЕ принимаются — `std.fmt.parseFloat` принимает всё это, этот парсер
// отвергает их как `Неудача`. Пустой ввод, голый знак без цифр или
// ЛЮБОЙ нераспознанный хвостовой байт — всё это аккуратно проваливается
// (никогда не crash/trap) — совпадает с контрактом «никогда не
// паникует» у нативной реализации `в_число`.
fn buildToNumber(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout) !mir.FunctionId {
    const number_type = type_store.builtins.number;
    const id = try mir_builder.newFunction(module, allocator, "@string_to_number", wasm_heap.dummy_symbol, layout.ptr_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const s_local = try builder.newLocal(wasm_heap.dummy_symbol, "s", layout.ptr_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{s_local});
    builder.currentFunction().type_store = type_store;

    const s_for_len = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const len = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load = .{ .dst = len, .addr = s_for_len } });
    const len_local = try wasm_heap.storeLocal(&builder, "@len", layout.idx_type, len);

    const len_for_zero_cmp = try wasm_heap.loadLocal(&builder, len_local, layout.idx_type);
    const zero_len = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    const is_empty = try wasm_heap.cmpOp(&builder, layout.bool_type, .equal, len_for_zero_cmp, zero_len);
    const empty_fail_block = try builder.newBlock();
    const parse_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = is_empty, .then_block = empty_fail_block, .else_block = parse_block } });

    builder.setCurrentBlock(empty_fail_block);
    {
        const result = try buildFailResultNamed(&builder, module, layout, "строки", "не удалось разобрать число");
        builder.terminate(.{ .return_value = .{ .value = result } });
    }

    builder.setCurrentBlock(parse_block);
    const pos_local = try builder.newLocal(wasm_heap.dummy_symbol, "@pos", layout.idx_type);
    const zero_pos = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    try builder.emit(.{ .store_local = .{ .local = pos_local, .src = zero_pos } });

    const sign_local = try builder.newLocal(wasm_heap.dummy_symbol, "@sign", number_type);
    const one_sign = try wasm_heap.numberConst(&builder, number_type, 1);
    try builder.emit(.{ .store_local = .{ .local = sign_local, .src = one_sign } });

    const s_for_first = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const four_first = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const first_addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, s_for_first, four_first);
    const first_byte = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load8 = .{ .dst = first_byte, .addr = first_addr } });
    const first_byte_local = try wasm_heap.storeLocal(&builder, "@first_byte", layout.idx_type, first_byte);

    const first_byte_for_minus = try wasm_heap.loadLocal(&builder, first_byte_local, layout.idx_type);
    const minus_char = try wasm_heap.addressConst(&builder, layout.idx_type, '-');
    const is_minus = try wasm_heap.cmpOp(&builder, layout.bool_type, .equal, first_byte_for_minus, minus_char);
    const minus_block = try builder.newBlock();
    const check_plus_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = is_minus, .then_block = minus_block, .else_block = check_plus_block } });

    builder.setCurrentBlock(minus_block);
    const neg_one_sign = try wasm_heap.numberConst(&builder, number_type, -1);
    try builder.emit(.{ .store_local = .{ .local = sign_local, .src = neg_one_sign } });
    const one_pos1 = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    try builder.emit(.{ .store_local = .{ .local = pos_local, .src = one_pos1 } });
    const after_sign_block = try builder.newBlock();
    builder.terminate(.{ .jump = .{ .target = after_sign_block } });

    builder.setCurrentBlock(check_plus_block);
    const first_byte_for_plus = try wasm_heap.loadLocal(&builder, first_byte_local, layout.idx_type);
    const plus_char = try wasm_heap.addressConst(&builder, layout.idx_type, '+');
    const is_plus = try wasm_heap.cmpOp(&builder, layout.bool_type, .equal, first_byte_for_plus, plus_char);
    const plus_block = try builder.newBlock();
    const no_sign_char_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = is_plus, .then_block = plus_block, .else_block = no_sign_char_block } });

    builder.setCurrentBlock(plus_block);
    const one_pos2 = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    try builder.emit(.{ .store_local = .{ .local = pos_local, .src = one_pos2 } });
    builder.terminate(.{ .jump = .{ .target = after_sign_block } });

    builder.setCurrentBlock(no_sign_char_block);
    builder.terminate(.{ .jump = .{ .target = after_sign_block } });

    builder.setCurrentBlock(after_sign_block);
    const int_value_local = try builder.newLocal(wasm_heap.dummy_symbol, "@int_value", number_type);
    const zero_iv = try wasm_heap.numberConst(&builder, number_type, 0);
    try builder.emit(.{ .store_local = .{ .local = int_value_local, .src = zero_iv } });
    const saw_digit_local = try builder.newLocal(wasm_heap.dummy_symbol, "@saw_digit", layout.bool_type);
    const false_sd = try wasm_heap.boolConst(&builder, layout.bool_type, false);
    try builder.emit(.{ .store_local = .{ .local = saw_digit_local, .src = false_sd } });

    const int_loop_header = try builder.newBlock();
    builder.terminate(.{ .jump = .{ .target = int_loop_header } });

    builder.setCurrentBlock(int_loop_header);
    const pos_for_int_cmp = try wasm_heap.loadLocal(&builder, pos_local, layout.idx_type);
    const len_for_int_cmp = try wasm_heap.loadLocal(&builder, len_local, layout.idx_type);
    const in_bounds1 = try wasm_heap.cmpOp(&builder, layout.bool_type, .less, pos_for_int_cmp, len_for_int_cmp);
    const check_digit1_block = try builder.newBlock();
    const int_loop_exit = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = in_bounds1, .then_block = check_digit1_block, .else_block = int_loop_exit } });

    builder.setCurrentBlock(check_digit1_block);
    const s_for_int_byte = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const four_int = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const pos_for_int_addr = try wasm_heap.loadLocal(&builder, pos_local, layout.idx_type);
    const s_plus4 = try wasm_heap.binOp(&builder, layout.idx_type, .add, s_for_int_byte, four_int);
    const int_byte_addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, s_plus4, pos_for_int_addr);
    const int_byte = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load8 = .{ .dst = int_byte, .addr = int_byte_addr } });
    const int_byte_local = try wasm_heap.storeLocal(&builder, "@int_byte", layout.idx_type, int_byte);

    const is_digit1 = try emitIsDigit(&builder, layout, int_byte_local);
    const int_digit_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = is_digit1, .then_block = int_digit_block, .else_block = int_loop_exit } });

    builder.setCurrentBlock(int_digit_block);
    const int_value_for_mul = try wasm_heap.loadLocal(&builder, int_value_local, number_type);
    const ten_iv = try wasm_heap.numberConst(&builder, number_type, 10);
    const int_value_x10 = try wasm_heap.binOp(&builder, number_type, .multiply, int_value_for_mul, ten_iv);
    const int_byte_for_digit = try wasm_heap.loadLocal(&builder, int_byte_local, layout.idx_type);
    const zero_char_iv = try wasm_heap.addressConst(&builder, layout.idx_type, '0');
    const digit_i32_iv = try wasm_heap.binOp(&builder, layout.idx_type, .subtract, int_byte_for_digit, zero_char_iv);
    const digit_f_iv = try builder.newValue(number_type);
    try builder.emit(.{ .unary = .{ .dst = digit_f_iv, .op = .from_i32, .src = digit_i32_iv } });
    const new_int_value = try wasm_heap.binOp(&builder, number_type, .add, int_value_x10, digit_f_iv);
    try builder.emit(.{ .store_local = .{ .local = int_value_local, .src = new_int_value } });
    const true_sd = try wasm_heap.boolConst(&builder, layout.bool_type, true);
    try builder.emit(.{ .store_local = .{ .local = saw_digit_local, .src = true_sd } });
    const pos_for_int_inc = try wasm_heap.loadLocal(&builder, pos_local, layout.idx_type);
    const one_int_inc = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const pos_int_next = try wasm_heap.binOp(&builder, layout.idx_type, .add, pos_for_int_inc, one_int_inc);
    try builder.emit(.{ .store_local = .{ .local = pos_local, .src = pos_int_next } });
    builder.terminate(.{ .jump = .{ .target = int_loop_header } });

    builder.setCurrentBlock(int_loop_exit);
    const frac_value_local = try builder.newLocal(wasm_heap.dummy_symbol, "@frac_value", number_type);
    const zero_fv = try wasm_heap.numberConst(&builder, number_type, 0);
    try builder.emit(.{ .store_local = .{ .local = frac_value_local, .src = zero_fv } });

    const pos_for_dot_cmp = try wasm_heap.loadLocal(&builder, pos_local, layout.idx_type);
    const len_for_dot_cmp = try wasm_heap.loadLocal(&builder, len_local, layout.idx_type);
    const dot_in_bounds = try wasm_heap.cmpOp(&builder, layout.bool_type, .less, pos_for_dot_cmp, len_for_dot_cmp);
    const check_dot_block = try builder.newBlock();
    const after_frac_parse_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = dot_in_bounds, .then_block = check_dot_block, .else_block = after_frac_parse_block } });

    builder.setCurrentBlock(check_dot_block);
    const s_for_dot = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const four_dot = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const pos_for_dot_addr = try wasm_heap.loadLocal(&builder, pos_local, layout.idx_type);
    const s_plus4_dot = try wasm_heap.binOp(&builder, layout.idx_type, .add, s_for_dot, four_dot);
    const dot_addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, s_plus4_dot, pos_for_dot_addr);
    const dot_byte = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load8 = .{ .dst = dot_byte, .addr = dot_addr } });
    const dot_char = try wasm_heap.addressConst(&builder, layout.idx_type, '.');
    const is_dot = try wasm_heap.cmpOp(&builder, layout.bool_type, .equal, dot_byte, dot_char);
    const has_dot_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = is_dot, .then_block = has_dot_block, .else_block = after_frac_parse_block } });

    builder.setCurrentBlock(has_dot_block);
    const pos_after_dot = try wasm_heap.loadLocal(&builder, pos_local, layout.idx_type);
    const one_dot = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const pos_skip_dot = try wasm_heap.binOp(&builder, layout.idx_type, .add, pos_after_dot, one_dot);
    try builder.emit(.{ .store_local = .{ .local = pos_local, .src = pos_skip_dot } });

    const frac_scale_local = try builder.newLocal(wasm_heap.dummy_symbol, "@frac_scale", number_type);
    const one_fs = try wasm_heap.numberConst(&builder, number_type, 1);
    try builder.emit(.{ .store_local = .{ .local = frac_scale_local, .src = one_fs } });

    const frac_loop_header2 = try builder.newBlock();
    builder.terminate(.{ .jump = .{ .target = frac_loop_header2 } });

    builder.setCurrentBlock(frac_loop_header2);
    const pos_for_frac_cmp = try wasm_heap.loadLocal(&builder, pos_local, layout.idx_type);
    const len_for_frac_cmp = try wasm_heap.loadLocal(&builder, len_local, layout.idx_type);
    const in_bounds2 = try wasm_heap.cmpOp(&builder, layout.bool_type, .less, pos_for_frac_cmp, len_for_frac_cmp);
    const check_digit2_block = try builder.newBlock();
    const frac_loop_exit = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = in_bounds2, .then_block = check_digit2_block, .else_block = frac_loop_exit } });

    builder.setCurrentBlock(check_digit2_block);
    const s_for_frac_byte = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const four_frac = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const pos_for_frac_addr = try wasm_heap.loadLocal(&builder, pos_local, layout.idx_type);
    const s_plus4_frac = try wasm_heap.binOp(&builder, layout.idx_type, .add, s_for_frac_byte, four_frac);
    const frac_byte_addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, s_plus4_frac, pos_for_frac_addr);
    const frac_byte = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load8 = .{ .dst = frac_byte, .addr = frac_byte_addr } });
    const frac_byte_local = try wasm_heap.storeLocal(&builder, "@frac_byte", layout.idx_type, frac_byte);

    const is_digit2 = try emitIsDigit(&builder, layout, frac_byte_local);
    const frac_digit_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = is_digit2, .then_block = frac_digit_block, .else_block = frac_loop_exit } });

    builder.setCurrentBlock(frac_digit_block);
    const frac_scale_for_div = try wasm_heap.loadLocal(&builder, frac_scale_local, number_type);
    const ten_fs = try wasm_heap.numberConst(&builder, number_type, 10);
    const new_frac_scale = try wasm_heap.binOp(&builder, number_type, .divide, frac_scale_for_div, ten_fs);
    try builder.emit(.{ .store_local = .{ .local = frac_scale_local, .src = new_frac_scale } });

    const frac_byte_for_digit = try wasm_heap.loadLocal(&builder, frac_byte_local, layout.idx_type);
    const zero_char_fv = try wasm_heap.addressConst(&builder, layout.idx_type, '0');
    const digit_i32_fv = try wasm_heap.binOp(&builder, layout.idx_type, .subtract, frac_byte_for_digit, zero_char_fv);
    const digit_f_fv = try builder.newValue(number_type);
    try builder.emit(.{ .unary = .{ .dst = digit_f_fv, .op = .from_i32, .src = digit_i32_fv } });
    const frac_scale_for_mul = try wasm_heap.loadLocal(&builder, frac_scale_local, number_type);
    const digit_scaled = try wasm_heap.binOp(&builder, number_type, .multiply, digit_f_fv, frac_scale_for_mul);
    const frac_value_for_add = try wasm_heap.loadLocal(&builder, frac_value_local, number_type);
    const new_frac_value = try wasm_heap.binOp(&builder, number_type, .add, frac_value_for_add, digit_scaled);
    try builder.emit(.{ .store_local = .{ .local = frac_value_local, .src = new_frac_value } });

    const true_sd2 = try wasm_heap.boolConst(&builder, layout.bool_type, true);
    try builder.emit(.{ .store_local = .{ .local = saw_digit_local, .src = true_sd2 } });
    const pos_for_frac_inc = try wasm_heap.loadLocal(&builder, pos_local, layout.idx_type);
    const one_frac_inc = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const pos_frac_next = try wasm_heap.binOp(&builder, layout.idx_type, .add, pos_for_frac_inc, one_frac_inc);
    try builder.emit(.{ .store_local = .{ .local = pos_local, .src = pos_frac_next } });
    builder.terminate(.{ .jump = .{ .target = frac_loop_header2 } });

    builder.setCurrentBlock(frac_loop_exit);
    builder.terminate(.{ .jump = .{ .target = after_frac_parse_block } });

    builder.setCurrentBlock(after_frac_parse_block);
    // Валидно тогда и только тогда, когда была замечена хотя бы одна
    // цифра И потреблены все байты (нет нераспознанного хвостового
    // содержимого — экспоненты, мусора и т.п.).
    const saw_digit_final = try wasm_heap.loadLocal(&builder, saw_digit_local, layout.bool_type);
    const pos_final = try wasm_heap.loadLocal(&builder, pos_local, layout.idx_type);
    const len_final = try wasm_heap.loadLocal(&builder, len_local, layout.idx_type);
    const fully_consumed = try wasm_heap.cmpOp(&builder, layout.bool_type, .equal, pos_final, len_final);
    const both_ok = try wasm_heap.binOp(&builder, layout.bool_type, .bit_and, saw_digit_final, fully_consumed);
    const success_block = try builder.newBlock();
    const parse_fail_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = both_ok, .then_block = success_block, .else_block = parse_fail_block } });

    builder.setCurrentBlock(success_block);
    const sign_for_result = try wasm_heap.loadLocal(&builder, sign_local, number_type);
    const int_value_for_result = try wasm_heap.loadLocal(&builder, int_value_local, number_type);
    const frac_value_for_result = try wasm_heap.loadLocal(&builder, frac_value_local, number_type);
    const magnitude = try wasm_heap.binOp(&builder, number_type, .add, int_value_for_result, frac_value_for_result);
    const final_value = try wasm_heap.binOp(&builder, number_type, .multiply, sign_for_result, magnitude);
    const success_result = try buildSuccessResult(&builder, module, layout, number_type, final_value);
    builder.terminate(.{ .return_value = .{ .value = success_result } });

    builder.setCurrentBlock(parse_fail_block);
    const fail_result = try buildFailResultNamed(&builder, module, layout, "строки", "не удалось разобрать число");
    builder.terminate(.{ .return_value = .{ .value = fail_result } });

    return id;
}

// `@string_is_digit(s) -> Булево`: пустая строка -> false, иначе сырой
// первый БАЙТ сравнивается с '0'..'9' напрямую (переиспользует уже
// существующий `emitIsDigit`, которым пользуется `@string_to_number`
// выше) — полное UTF-8-декодирование не нужно: ASCII-цифры всегда
// однобайтовые, а ведущий байт ЛЮБОЙ многобайтовой последовательности
// (0xC0+) заведомо вне диапазона 0x30-0x39, так что байтовое сравнение
// даёт тот же результат, что декодирование кодпоинта — соответствует
// `strIsDigit` в `vm.zig`.
fn buildIsDigit(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@string_is_digit", wasm_heap.dummy_symbol, layout.bool_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const s_local = try builder.newLocal(wasm_heap.dummy_symbol, "s", layout.ptr_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{s_local});
    builder.currentFunction().type_store = type_store;

    const s1 = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const len = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load = .{ .dst = len, .addr = s1 } });
    const len_local = try wasm_heap.storeLocal(&builder, "len", layout.idx_type, len);

    const len_for_cmp = try wasm_heap.loadLocal(&builder, len_local, layout.idx_type);
    const zero_len = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    const is_empty = try wasm_heap.cmpOp(&builder, layout.bool_type, .equal, len_for_cmp, zero_len);
    const empty_block = try builder.newBlock();
    const check_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = is_empty, .then_block = empty_block, .else_block = check_block } });

    builder.setCurrentBlock(empty_block);
    const false_val = try wasm_heap.boolConst(&builder, layout.bool_type, false);
    builder.terminate(.{ .return_value = .{ .value = false_val } });

    builder.setCurrentBlock(check_block);
    const four = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const s_for_addr = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, s_for_addr, four);
    const byte0 = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load8 = .{ .dst = byte0, .addr = addr } });
    const byte0_local = try wasm_heap.storeLocal(&builder, "@byte0", layout.idx_type, byte0);

    const is_digit = try emitIsDigit(&builder, layout, byte0_local);
    builder.terminate(.{ .return_value = .{ .value = is_digit } });
    return id;
}

// a-z/A-Z по сырому байту — оба однобайтовые в UTF-8.
fn emitIsAsciiLetter(builder: *mir_builder.Builder, layout: wasm_heap.PtrLayout, byte_local: mir.LocalId) !mir.ValueId {
    const b1 = try wasm_heap.loadLocal(builder, byte_local, layout.idx_type);
    const a_lo = try wasm_heap.addressConst(builder, layout.idx_type, 'a');
    const ge_a = try wasm_heap.cmpOp(builder, layout.bool_type, .greater_equal, b1, a_lo);
    const b2 = try wasm_heap.loadLocal(builder, byte_local, layout.idx_type);
    const z_hi = try wasm_heap.addressConst(builder, layout.idx_type, 'z');
    const le_z = try wasm_heap.cmpOp(builder, layout.bool_type, .less_equal, b2, z_hi);
    const is_lower = try wasm_heap.binOp(builder, layout.bool_type, .bit_and, ge_a, le_z);

    const b3 = try wasm_heap.loadLocal(builder, byte_local, layout.idx_type);
    const a_upper_lo = try wasm_heap.addressConst(builder, layout.idx_type, 'A');
    const ge_upper_a = try wasm_heap.cmpOp(builder, layout.bool_type, .greater_equal, b3, a_upper_lo);
    const b4 = try wasm_heap.loadLocal(builder, byte_local, layout.idx_type);
    const z_upper_hi = try wasm_heap.addressConst(builder, layout.idx_type, 'Z');
    const le_upper_z = try wasm_heap.cmpOp(builder, layout.bool_type, .less_equal, b4, z_upper_hi);
    const is_upper = try wasm_heap.binOp(builder, layout.bool_type, .bit_and, ge_upper_a, le_upper_z);

    return try wasm_heap.binOp(builder, layout.bool_type, .bit_or, is_lower, is_upper);
}

// `@string_is_letter(s) -> Булево`: ASCII (a-z/A-Z, ширина-1 путь по
// сырому байту) ИЛИ кириллица (А-Я/а-я/Ё/ё, все ширина-2 в UTF-8 —
// требуют настоящего декодирования 2-байтовой последовательности, не
// достаточно посмотреть на ведущий байт) — точно тот же диапазон, что
// `strIsLetter` в `vm.zig`. Ширина 3/4 никогда не бывает буквой в этом
// срезе языка (только ASCII+кириллица) -> false без декодирования.
fn buildIsLetter(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout, utf8_width: mir.FunctionId) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@string_is_letter", wasm_heap.dummy_symbol, layout.bool_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const s_local = try builder.newLocal(wasm_heap.dummy_symbol, "s", layout.ptr_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{s_local});
    builder.currentFunction().type_store = type_store;

    const s1 = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const len = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load = .{ .dst = len, .addr = s1 } });
    const len_local = try wasm_heap.storeLocal(&builder, "len", layout.idx_type, len);

    const len_for_cmp = try wasm_heap.loadLocal(&builder, len_local, layout.idx_type);
    const zero_len = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    const is_empty = try wasm_heap.cmpOp(&builder, layout.bool_type, .equal, len_for_cmp, zero_len);
    const empty_block = try builder.newBlock();
    const nonempty_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = is_empty, .then_block = empty_block, .else_block = nonempty_block } });

    builder.setCurrentBlock(empty_block);
    const false_val1 = try wasm_heap.boolConst(&builder, layout.bool_type, false);
    builder.terminate(.{ .return_value = .{ .value = false_val1 } });

    builder.setCurrentBlock(nonempty_block);
    const four = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const s_for_base = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const base = try wasm_heap.binOp(&builder, layout.idx_type, .add, s_for_base, four);
    const base_local = try wasm_heap.storeLocal(&builder, "base", layout.idx_type, base);

    const base_for_byte0 = try wasm_heap.loadLocal(&builder, base_local, layout.idx_type);
    const byte0 = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load8 = .{ .dst = byte0, .addr = base_for_byte0 } });
    const byte0_local = try wasm_heap.storeLocal(&builder, "@byte0", layout.idx_type, byte0);

    const byte0_for_width = try wasm_heap.loadLocal(&builder, byte0_local, layout.idx_type);
    const width = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .call = .{ .dst = width, .callee = utf8_width, .args = try wasm_heap.dupeOne(module, byte0_for_width) } });
    const width_local = try wasm_heap.storeLocal(&builder, "@width", layout.idx_type, width);

    const width_for_cmp1 = try wasm_heap.loadLocal(&builder, width_local, layout.idx_type);
    const one_w = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const is_w1 = try wasm_heap.cmpOp(&builder, layout.bool_type, .equal, width_for_cmp1, one_w);
    const ascii_block = try builder.newBlock();
    const check2_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = is_w1, .then_block = ascii_block, .else_block = check2_block } });

    builder.setCurrentBlock(ascii_block);
    const ascii_result = try emitIsAsciiLetter(&builder, layout, byte0_local);
    builder.terminate(.{ .return_value = .{ .value = ascii_result } });

    builder.setCurrentBlock(check2_block);
    const width_for_cmp2 = try wasm_heap.loadLocal(&builder, width_local, layout.idx_type);
    const two_w = try wasm_heap.addressConst(&builder, layout.idx_type, 2);
    const is_w2 = try wasm_heap.cmpOp(&builder, layout.bool_type, .equal, width_for_cmp2, two_w);
    const two_byte_block = try builder.newBlock();
    const not_letter_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = is_w2, .then_block = two_byte_block, .else_block = not_letter_block } });

    builder.setCurrentBlock(not_letter_block);
    const false_val2 = try wasm_heap.boolConst(&builder, layout.bool_type, false);
    builder.terminate(.{ .return_value = .{ .value = false_val2 } });

    builder.setCurrentBlock(two_byte_block);
    const byte0_for_cp = try wasm_heap.loadLocal(&builder, byte0_local, layout.idx_type);
    const mask_1f = try wasm_heap.addressConst(&builder, layout.idx_type, 0x1F);
    const b0_masked = try wasm_heap.binOp(&builder, layout.idx_type, .bit_and, byte0_for_cp, mask_1f);
    const six = try wasm_heap.addressConst(&builder, layout.idx_type, 6);
    const b0_shifted = try wasm_heap.binOp(&builder, layout.idx_type, .shift_left, b0_masked, six);

    const base_for_byte1 = try wasm_heap.loadLocal(&builder, base_local, layout.idx_type);
    const one_off = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const byte1_addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, base_for_byte1, one_off);
    const byte1 = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load8 = .{ .dst = byte1, .addr = byte1_addr } });
    const byte1_local = try wasm_heap.storeLocal(&builder, "@byte1", layout.idx_type, byte1);
    const byte1_for_cp = try wasm_heap.loadLocal(&builder, byte1_local, layout.idx_type);
    const mask_3f = try wasm_heap.addressConst(&builder, layout.idx_type, 0x3F);
    const b1_masked = try wasm_heap.binOp(&builder, layout.idx_type, .bit_and, byte1_for_cp, mask_3f);

    const codepoint = try wasm_heap.binOp(&builder, layout.idx_type, .bit_or, b0_shifted, b1_masked);
    const codepoint_local = try wasm_heap.storeLocal(&builder, "@cp", layout.idx_type, codepoint);

    // А-Я/а-я — один непрерывный диапазон 0x0410..0x044F; Ё/ё вне его,
    // проверяются отдельно — те же три условия, что и `strIsLetter`.
    const cp_for_lo = try wasm_heap.loadLocal(&builder, codepoint_local, layout.idx_type);
    const range_lo_const = try wasm_heap.addressConst(&builder, layout.idx_type, 0x0410);
    const ge_lo = try wasm_heap.cmpOp(&builder, layout.bool_type, .greater_equal, cp_for_lo, range_lo_const);
    const cp_for_hi = try wasm_heap.loadLocal(&builder, codepoint_local, layout.idx_type);
    const range_hi_const = try wasm_heap.addressConst(&builder, layout.idx_type, 0x044F);
    const le_hi = try wasm_heap.cmpOp(&builder, layout.bool_type, .less_equal, cp_for_hi, range_hi_const);
    const in_range = try wasm_heap.binOp(&builder, layout.bool_type, .bit_and, ge_lo, le_hi);

    const cp_for_yo1 = try wasm_heap.loadLocal(&builder, codepoint_local, layout.idx_type);
    const yo_upper_const = try wasm_heap.addressConst(&builder, layout.idx_type, 0x0401);
    const eq_yo_upper = try wasm_heap.cmpOp(&builder, layout.bool_type, .equal, cp_for_yo1, yo_upper_const);
    const cp_for_yo2 = try wasm_heap.loadLocal(&builder, codepoint_local, layout.idx_type);
    const yo_lower_const = try wasm_heap.addressConst(&builder, layout.idx_type, 0x0451);
    const eq_yo_lower = try wasm_heap.cmpOp(&builder, layout.bool_type, .equal, cp_for_yo2, yo_lower_const);

    const or1 = try wasm_heap.binOp(&builder, layout.bool_type, .bit_or, in_range, eq_yo_upper);
    const is_cyrillic = try wasm_heap.binOp(&builder, layout.bool_type, .bit_or, or1, eq_yo_lower);
    builder.terminate(.{ .return_value = .{ .value = is_cyrillic } });

    return id;
}

// `@string_from_runes(codes: Массив(Целое)) -> Строка`: обратное к
// декодированию UTF-8 — кодирует каждый элемент массива (кодпоинт,
// физически Число/f64, как и все элементы Массив(Целое) в этом
// представлении) обратно в 1-4 байта, конкатенируя результат. Верхняя
// граница размера аллокации — 4 байта/кодпоинт (реальная длина обычно
// меньше; лишнее место в bump-куче не освобождается — та же экономия
// сложности, что и во всём этом файле). Намеренно БЕЗ явной проверки
// суррогатного диапазона (0xD800-0xDFFF) в отличие от `strFromRunes` в
// `vm.zig` — единственный вызывающий это в панос-коде (json.pns) уже
// сам комбинирует суррогатные пары в один настоящий кодпоинт ДО вызова
// `из_рун`, так что в реальной практике сюда суррогатный codepoint не
// попадает; несостоятельный ручной вызов извне даст неверные, но не
// небезопасные байты (не читает/не пишет за пределы аллоцированного).
fn buildFromRunes(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout, array_runtime: wasm_objects.ArrayRuntime) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@string_from_runes", wasm_heap.dummy_symbol, layout.ptr_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const arr_local = try builder.newLocal(wasm_heap.dummy_symbol, "arr", layout.ptr_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{arr_local});
    builder.currentFunction().type_store = type_store;

    const arr_for_len = try wasm_heap.loadLocal(&builder, arr_local, layout.ptr_type);
    const len_f64 = try builder.newValue(type_store.builtins.number);
    try builder.emit(.{ .call = .{ .dst = len_f64, .callee = array_runtime.length, .args = try wasm_heap.dupeOne(module, arr_for_len) } });
    const len_i32 = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .unary = .{ .dst = len_i32, .op = .to_i32, .src = len_f64 } });
    const len_local = try wasm_heap.storeLocal(&builder, "@len", layout.idx_type, len_i32);

    const len_for_size = try wasm_heap.loadLocal(&builder, len_local, layout.idx_type);
    const four_per = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const max_bytes = try wasm_heap.binOp(&builder, layout.idx_type, .multiply, len_for_size, four_per);
    const header = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const alloc_size = try wasm_heap.binOp(&builder, layout.idx_type, .add, max_bytes, header);
    const alloc_id = wasm_heap.findFunctionByName(module, wasm_heap.alloc_function_name).?;
    const handle = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = handle, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, alloc_size) } });
    const handle_local = try wasm_heap.storeLocal(&builder, "handle", layout.ptr_type, handle);

    const offset_local = try builder.newLocal(wasm_heap.dummy_symbol, "@offset", layout.idx_type);
    const zero_off = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    try builder.emit(.{ .store_local = .{ .local = offset_local, .src = zero_off } });
    const i_local = try builder.newLocal(wasm_heap.dummy_symbol, "@i", layout.idx_type);
    const zero_i = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    try builder.emit(.{ .store_local = .{ .local = i_local, .src = zero_i } });

    const loop_header = try builder.newBlock();
    builder.terminate(.{ .jump = .{ .target = loop_header } });

    builder.setCurrentBlock(loop_header);
    const i_for_cmp = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const len_for_cmp = try wasm_heap.loadLocal(&builder, len_local, layout.idx_type);
    const keep_going = try wasm_heap.cmpOp(&builder, layout.bool_type, .less, i_for_cmp, len_for_cmp);
    const loop_body = try builder.newBlock();
    const loop_exit = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = keep_going, .then_block = loop_body, .else_block = loop_exit } });

    builder.setCurrentBlock(loop_body);
    const arr_for_get = try wasm_heap.loadLocal(&builder, arr_local, layout.ptr_type);
    const i_for_idx = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const idx_f64 = try builder.newValue(type_store.builtins.number);
    try builder.emit(.{ .unary = .{ .dst = idx_f64, .op = .from_i32, .src = i_for_idx } });
    const cp_f64 = try builder.newValue(type_store.builtins.number);
    try builder.emit(.{ .call = .{ .dst = cp_f64, .callee = array_runtime.get_f64, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ arr_for_get, idx_f64 }) } });
    const cp_i32 = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .unary = .{ .dst = cp_i32, .op = .to_i32, .src = cp_f64 } });
    const cp_local = try wasm_heap.storeLocal(&builder, "@cp", layout.idx_type, cp_i32);

    // Базовый адрес записи ДЛЯ ЭТОГО кодпоинта — handle+4+offset.
    const handle_for_base = try wasm_heap.loadLocal(&builder, handle_local, layout.ptr_type);
    const four_hdr = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const handle_plus4 = try wasm_heap.binOp(&builder, layout.idx_type, .add, handle_for_base, four_hdr);
    const offset_for_base = try wasm_heap.loadLocal(&builder, offset_local, layout.idx_type);
    const write_base = try wasm_heap.binOp(&builder, layout.idx_type, .add, handle_plus4, offset_for_base);
    const write_base_local = try wasm_heap.storeLocal(&builder, "@wbase", layout.idx_type, write_base);

    const width_local = try builder.newLocal(wasm_heap.dummy_symbol, "@width", layout.idx_type);
    const advance_block = try builder.newBlock();

    const cp_for_c1 = try wasm_heap.loadLocal(&builder, cp_local, layout.idx_type);
    const c1_bound = try wasm_heap.addressConst(&builder, layout.idx_type, 0x80);
    const is_1byte = try wasm_heap.cmpOp(&builder, layout.bool_type, .less, cp_for_c1, c1_bound);
    const b1_block = try builder.newBlock();
    const check2_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = is_1byte, .then_block = b1_block, .else_block = check2_block } });

    builder.setCurrentBlock(b1_block);
    {
        const cp_r = try wasm_heap.loadLocal(&builder, cp_local, layout.idx_type);
        const addr0 = try wasm_heap.loadLocal(&builder, write_base_local, layout.idx_type);
        try builder.emit(.{ .mem_store8 = .{ .addr = addr0, .src = cp_r } });
        const one_w = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
        try builder.emit(.{ .store_local = .{ .local = width_local, .src = one_w } });
        builder.terminate(.{ .jump = .{ .target = advance_block } });
    }

    builder.setCurrentBlock(check2_block);
    const cp_for_c2 = try wasm_heap.loadLocal(&builder, cp_local, layout.idx_type);
    const c2_bound = try wasm_heap.addressConst(&builder, layout.idx_type, 0x800);
    const is_2byte = try wasm_heap.cmpOp(&builder, layout.bool_type, .less, cp_for_c2, c2_bound);
    const b2_block = try builder.newBlock();
    const check3_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = is_2byte, .then_block = b2_block, .else_block = check3_block } });

    builder.setCurrentBlock(b2_block);
    {
        const cp_for_b0 = try wasm_heap.loadLocal(&builder, cp_local, layout.idx_type);
        const shift6 = try wasm_heap.addressConst(&builder, layout.idx_type, 6);
        const b0_shifted = try wasm_heap.binOp(&builder, layout.idx_type, .shift_right, cp_for_b0, shift6);
        const c0_tag = try wasm_heap.addressConst(&builder, layout.idx_type, 0xC0);
        const byte0 = try wasm_heap.binOp(&builder, layout.idx_type, .bit_or, b0_shifted, c0_tag);
        const addr0 = try wasm_heap.loadLocal(&builder, write_base_local, layout.idx_type);
        try builder.emit(.{ .mem_store8 = .{ .addr = addr0, .src = byte0 } });

        const cp_for_b1 = try wasm_heap.loadLocal(&builder, cp_local, layout.idx_type);
        const mask3f_1 = try wasm_heap.addressConst(&builder, layout.idx_type, 0x3F);
        const b1_masked = try wasm_heap.binOp(&builder, layout.idx_type, .bit_and, cp_for_b1, mask3f_1);
        const tag80_1 = try wasm_heap.addressConst(&builder, layout.idx_type, 0x80);
        const byte1 = try wasm_heap.binOp(&builder, layout.idx_type, .bit_or, b1_masked, tag80_1);
        const wbase_r1 = try wasm_heap.loadLocal(&builder, write_base_local, layout.idx_type);
        const one_o1 = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
        const addr1 = try wasm_heap.binOp(&builder, layout.idx_type, .add, wbase_r1, one_o1);
        try builder.emit(.{ .mem_store8 = .{ .addr = addr1, .src = byte1 } });

        const two_w = try wasm_heap.addressConst(&builder, layout.idx_type, 2);
        try builder.emit(.{ .store_local = .{ .local = width_local, .src = two_w } });
        builder.terminate(.{ .jump = .{ .target = advance_block } });
    }

    builder.setCurrentBlock(check3_block);
    const cp_for_c3 = try wasm_heap.loadLocal(&builder, cp_local, layout.idx_type);
    const c3_bound = try wasm_heap.addressConst(&builder, layout.idx_type, 0x10000);
    const is_3byte = try wasm_heap.cmpOp(&builder, layout.bool_type, .less, cp_for_c3, c3_bound);
    const b3_block = try builder.newBlock();
    const b4_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = is_3byte, .then_block = b3_block, .else_block = b4_block } });

    builder.setCurrentBlock(b3_block);
    {
        const cp_for_b0 = try wasm_heap.loadLocal(&builder, cp_local, layout.idx_type);
        const shift12 = try wasm_heap.addressConst(&builder, layout.idx_type, 12);
        const b0_shifted = try wasm_heap.binOp(&builder, layout.idx_type, .shift_right, cp_for_b0, shift12);
        const e0_tag = try wasm_heap.addressConst(&builder, layout.idx_type, 0xE0);
        const byte0 = try wasm_heap.binOp(&builder, layout.idx_type, .bit_or, b0_shifted, e0_tag);
        const addr0 = try wasm_heap.loadLocal(&builder, write_base_local, layout.idx_type);
        try builder.emit(.{ .mem_store8 = .{ .addr = addr0, .src = byte0 } });

        const cp_for_b1 = try wasm_heap.loadLocal(&builder, cp_local, layout.idx_type);
        const shift6_2 = try wasm_heap.addressConst(&builder, layout.idx_type, 6);
        const b1_shifted = try wasm_heap.binOp(&builder, layout.idx_type, .shift_right, cp_for_b1, shift6_2);
        const mask3f_2 = try wasm_heap.addressConst(&builder, layout.idx_type, 0x3F);
        const b1_masked = try wasm_heap.binOp(&builder, layout.idx_type, .bit_and, b1_shifted, mask3f_2);
        const tag80_2 = try wasm_heap.addressConst(&builder, layout.idx_type, 0x80);
        const byte1 = try wasm_heap.binOp(&builder, layout.idx_type, .bit_or, b1_masked, tag80_2);
        const wbase_r1 = try wasm_heap.loadLocal(&builder, write_base_local, layout.idx_type);
        const one_o1 = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
        const addr1 = try wasm_heap.binOp(&builder, layout.idx_type, .add, wbase_r1, one_o1);
        try builder.emit(.{ .mem_store8 = .{ .addr = addr1, .src = byte1 } });

        const cp_for_b2 = try wasm_heap.loadLocal(&builder, cp_local, layout.idx_type);
        const mask3f_3 = try wasm_heap.addressConst(&builder, layout.idx_type, 0x3F);
        const b2_masked = try wasm_heap.binOp(&builder, layout.idx_type, .bit_and, cp_for_b2, mask3f_3);
        const tag80_3 = try wasm_heap.addressConst(&builder, layout.idx_type, 0x80);
        const byte2 = try wasm_heap.binOp(&builder, layout.idx_type, .bit_or, b2_masked, tag80_3);
        const wbase_r2 = try wasm_heap.loadLocal(&builder, write_base_local, layout.idx_type);
        const two_o2 = try wasm_heap.addressConst(&builder, layout.idx_type, 2);
        const addr2 = try wasm_heap.binOp(&builder, layout.idx_type, .add, wbase_r2, two_o2);
        try builder.emit(.{ .mem_store8 = .{ .addr = addr2, .src = byte2 } });

        const three_w = try wasm_heap.addressConst(&builder, layout.idx_type, 3);
        try builder.emit(.{ .store_local = .{ .local = width_local, .src = three_w } });
        builder.terminate(.{ .jump = .{ .target = advance_block } });
    }

    builder.setCurrentBlock(b4_block);
    {
        const cp_for_b0 = try wasm_heap.loadLocal(&builder, cp_local, layout.idx_type);
        const shift18 = try wasm_heap.addressConst(&builder, layout.idx_type, 18);
        const b0_shifted = try wasm_heap.binOp(&builder, layout.idx_type, .shift_right, cp_for_b0, shift18);
        const f0_tag = try wasm_heap.addressConst(&builder, layout.idx_type, 0xF0);
        const byte0 = try wasm_heap.binOp(&builder, layout.idx_type, .bit_or, b0_shifted, f0_tag);
        const addr0 = try wasm_heap.loadLocal(&builder, write_base_local, layout.idx_type);
        try builder.emit(.{ .mem_store8 = .{ .addr = addr0, .src = byte0 } });

        const cp_for_b1 = try wasm_heap.loadLocal(&builder, cp_local, layout.idx_type);
        const shift12_2 = try wasm_heap.addressConst(&builder, layout.idx_type, 12);
        const b1_shifted = try wasm_heap.binOp(&builder, layout.idx_type, .shift_right, cp_for_b1, shift12_2);
        const mask3f_4 = try wasm_heap.addressConst(&builder, layout.idx_type, 0x3F);
        const b1_masked = try wasm_heap.binOp(&builder, layout.idx_type, .bit_and, b1_shifted, mask3f_4);
        const tag80_4 = try wasm_heap.addressConst(&builder, layout.idx_type, 0x80);
        const byte1 = try wasm_heap.binOp(&builder, layout.idx_type, .bit_or, b1_masked, tag80_4);
        const wbase_r1 = try wasm_heap.loadLocal(&builder, write_base_local, layout.idx_type);
        const one_o1 = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
        const addr1 = try wasm_heap.binOp(&builder, layout.idx_type, .add, wbase_r1, one_o1);
        try builder.emit(.{ .mem_store8 = .{ .addr = addr1, .src = byte1 } });

        const cp_for_b2 = try wasm_heap.loadLocal(&builder, cp_local, layout.idx_type);
        const shift6_3 = try wasm_heap.addressConst(&builder, layout.idx_type, 6);
        const b2_shifted = try wasm_heap.binOp(&builder, layout.idx_type, .shift_right, cp_for_b2, shift6_3);
        const mask3f_5 = try wasm_heap.addressConst(&builder, layout.idx_type, 0x3F);
        const b2_masked = try wasm_heap.binOp(&builder, layout.idx_type, .bit_and, b2_shifted, mask3f_5);
        const tag80_5 = try wasm_heap.addressConst(&builder, layout.idx_type, 0x80);
        const byte2 = try wasm_heap.binOp(&builder, layout.idx_type, .bit_or, b2_masked, tag80_5);
        const wbase_r2 = try wasm_heap.loadLocal(&builder, write_base_local, layout.idx_type);
        const two_o2 = try wasm_heap.addressConst(&builder, layout.idx_type, 2);
        const addr2 = try wasm_heap.binOp(&builder, layout.idx_type, .add, wbase_r2, two_o2);
        try builder.emit(.{ .mem_store8 = .{ .addr = addr2, .src = byte2 } });

        const cp_for_b3 = try wasm_heap.loadLocal(&builder, cp_local, layout.idx_type);
        const mask3f_6 = try wasm_heap.addressConst(&builder, layout.idx_type, 0x3F);
        const b3_masked = try wasm_heap.binOp(&builder, layout.idx_type, .bit_and, cp_for_b3, mask3f_6);
        const tag80_6 = try wasm_heap.addressConst(&builder, layout.idx_type, 0x80);
        const byte3 = try wasm_heap.binOp(&builder, layout.idx_type, .bit_or, b3_masked, tag80_6);
        const wbase_r3 = try wasm_heap.loadLocal(&builder, write_base_local, layout.idx_type);
        const three_o3 = try wasm_heap.addressConst(&builder, layout.idx_type, 3);
        const addr3 = try wasm_heap.binOp(&builder, layout.idx_type, .add, wbase_r3, three_o3);
        try builder.emit(.{ .mem_store8 = .{ .addr = addr3, .src = byte3 } });

        const four_w = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
        try builder.emit(.{ .store_local = .{ .local = width_local, .src = four_w } });
        builder.terminate(.{ .jump = .{ .target = advance_block } });
    }

    builder.setCurrentBlock(advance_block);
    const offset_for_inc = try wasm_heap.loadLocal(&builder, offset_local, layout.idx_type);
    const width_for_inc = try wasm_heap.loadLocal(&builder, width_local, layout.idx_type);
    const offset_next = try wasm_heap.binOp(&builder, layout.idx_type, .add, offset_for_inc, width_for_inc);
    try builder.emit(.{ .store_local = .{ .local = offset_local, .src = offset_next } });
    const i_for_inc = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const one_i = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const i_next = try wasm_heap.binOp(&builder, layout.idx_type, .add, i_for_inc, one_i);
    try builder.emit(.{ .store_local = .{ .local = i_local, .src = i_next } });
    builder.terminate(.{ .jump = .{ .target = loop_header } });

    builder.setCurrentBlock(loop_exit);
    const offset_final = try wasm_heap.loadLocal(&builder, offset_local, layout.idx_type);
    const handle_for_header = try wasm_heap.loadLocal(&builder, handle_local, layout.ptr_type);
    try builder.emit(.{ .mem_store = .{ .addr = handle_for_header, .src = offset_final } });
    const handle_final = try wasm_heap.loadLocal(&builder, handle_local, layout.ptr_type);
    builder.terminate(.{ .return_value = .{ .value = handle_final } });
    return id;
}

// `@string_to_bytes(s) -> Массив(Целое)`: обратное к `@string_from_runes`
// на уровне БАЙТ, не рун — каждый сырой байт строки как отдельный
// элемент, совпадает с `strToBytes` в `vm.zig`.
fn buildToBytes(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout, array_runtime: wasm_objects.ArrayRuntime) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@string_to_bytes", wasm_heap.dummy_symbol, layout.ptr_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const s_local = try builder.newLocal(wasm_heap.dummy_symbol, "s", layout.ptr_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{s_local});
    builder.currentFunction().type_store = type_store;

    const s1 = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const len = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load = .{ .dst = len, .addr = s1 } });
    const len_local = try wasm_heap.storeLocal(&builder, "@len", layout.idx_type, len);

    const four = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const s_for_base = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const base = try wasm_heap.binOp(&builder, layout.idx_type, .add, s_for_base, four);
    const base_local = try wasm_heap.storeLocal(&builder, "base", layout.idx_type, base);

    const arr = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = arr, .callee = array_runtime.new, .args = &.{} } });
    const arr_local = try wasm_heap.storeLocal(&builder, "arr", layout.ptr_type, arr);

    const i_local = try builder.newLocal(wasm_heap.dummy_symbol, "@i", layout.idx_type);
    const zero_i = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    try builder.emit(.{ .store_local = .{ .local = i_local, .src = zero_i } });

    const loop_header = try builder.newBlock();
    builder.terminate(.{ .jump = .{ .target = loop_header } });

    builder.setCurrentBlock(loop_header);
    const i_for_cmp = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const len_for_cmp = try wasm_heap.loadLocal(&builder, len_local, layout.idx_type);
    const keep_going = try wasm_heap.cmpOp(&builder, layout.bool_type, .less, i_for_cmp, len_for_cmp);
    const loop_body = try builder.newBlock();
    const loop_exit = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = keep_going, .then_block = loop_body, .else_block = loop_exit } });

    builder.setCurrentBlock(loop_body);
    const i_for_addr = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const base_for_addr = try wasm_heap.loadLocal(&builder, base_local, layout.idx_type);
    const addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, base_for_addr, i_for_addr);
    const byte = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load8 = .{ .dst = byte, .addr = addr } });
    const byte_f64 = try builder.newValue(type_store.builtins.number);
    try builder.emit(.{ .unary = .{ .dst = byte_f64, .op = .from_i32, .src = byte } });
    const byte_f64_local = try wasm_heap.storeLocal(&builder, "@byte_f64", type_store.builtins.number, byte_f64);

    // `.call`'s аргументы протолкнуты в ТОЧНОМ порядке списка — `arr_for_append`
    // должен быть произведён ПЕРВЫМ (реальный найденный баг, тот же класс,
    // что в `wasm_maps.zig`'s `buildMapEntries`: `byte_f64` раньше
    // производился ДО `arr_for_append`, `append_f64` получал аргументы
    // переставленными местами).
    const arr_for_append = try wasm_heap.loadLocal(&builder, arr_local, layout.ptr_type);
    const byte_f64_reload = try wasm_heap.loadLocal(&builder, byte_f64_local, type_store.builtins.number);
    try builder.emit(.{ .call = .{ .dst = null, .callee = array_runtime.append_f64, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ arr_for_append, byte_f64_reload }) } });

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
