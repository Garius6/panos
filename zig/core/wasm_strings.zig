const std = @import("std");
const mir = @import("mir.zig");
const mir_builder = @import("mir_builder.zig");
const types = @import("types.zig");
const wasm_heap = @import("wasm_heap.zig");
const wasm_module = @import("wasm_module.zig");

// Eliminates string JS-host imports (`@runtime::строка_литерал`/
// `строка_сложить`, `строки::*`) — replaces string `.binary{.add}`/
// `.compare{.equal,.not_equal}`/`.call_builtin{"строки::..."}` with real
// in-module linear-memory code, reusing `wasm_heap.zig`'s bump allocator
// (shared with `wasm_objects.zig`/`wasm_actors.zig`). Runs in the SAME
// pass slot as `wasm_objects.expand` (before `mir_cps.prepare`).
//
// Representation: a `Строка` handle is an i32 pointer to a
// LENGTH-PREFIXED UTF-8 byte buffer — `[u32 byte_length][raw bytes...]`,
// no null terminator (the explicit length makes one unnecessary, and
// panos strings can contain embedded NUL bytes like any other byte).
// String LITERALS need ZERO runtime work under this layout: their
// length-prefixed bytes are written directly into the WASM data section
// at COMPILE TIME (`wasm_emit.zig`'s `collectStringConstants`/
// `.const_value{.string}` case), so a literal's handle is just a bare
// `i32.const <data_offset>` — no host call, no allocation. Every string
// OPERATION (concat, equality, length, slice, ...) only ever needs a
// valid pointer to this `[len][bytes]` shape, never caring whether it
// points into the read-only data section or the writable bump heap —
// one uniform representation for both origins.
//
// Byte-level access (UTF-8 decoding, byte-copy loops) uses the new
// `mem_load8`/`mem_store8` MIR instructions (`mir.zig`) — `mem_load`/
// `mem_store` are word-granular (4/8 bytes), too coarse for this.
//
// Landing incrementally (see the plan this session is following):
// concat + equality first (the smallest slice that makes any string
// program correct under wasmtime), then the read-only builtins
// (длина/длина_байт/начинается_с/etc), then слice/find, then the
// numeric-formatting builtins last (из_числа's exact-decimal-parity
// risk is isolated so it doesn't block everything else).

fn unsupported(comptime what: []const u8) error{StringExpandUnsupported} {
    std.debug.print("panos build: AOT (wasm) строки — " ++ what ++ "\n", .{});
    return error.StringExpandUnsupported;
}

const StringRuntime = struct {
    concat: mir.FunctionId,
    equal: mir.FunctionId,
    byte_length: mir.FunctionId,
    starts_with: mir.FunctionId,
    utf8_width: mir.FunctionId,
    length: mir.FunctionId,
    rune_byte_offset: mir.FunctionId,
    byte_to_rune_count: mir.FunctionId,
    index_of: mir.FunctionId,
    slice: mir.FunctionId,
    find: mir.FunctionId,
    replace: mir.FunctionId,
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
    const runtime = StringRuntime{
        .concat = concat,
        .equal = try buildEqual(allocator, module, type_store, layout),
        .byte_length = try buildByteLength(allocator, module, type_store, layout),
        .starts_with = try buildStartsWith(allocator, module, type_store, layout),
        .utf8_width = utf8_width,
        .length = length,
        .rune_byte_offset = rune_byte_offset,
        .byte_to_rune_count = byte_to_rune_count,
        .index_of = index_of,
        .slice = slice,
        .find = find,
        .replace = try buildReplace(allocator, module, type_store, layout, length, slice, find, concat),
    };
    const ctx = ExpandCtx{ .layout = layout, .type_store = type_store, .runtime = runtime };

    // Same "re-scan module.functions.items fresh each time" reasoning as
    // wasm_objects.zig: buildConcat/buildEqual above already appended
    // new functions, but neither's OWN body contains string ops itself
    // (hand-built, not user code), so no frozen snapshot is needed.
    var index: usize = 0;
    while (index < module.functions.items.len) : (index += 1) {
        const function_id: mir.FunctionId = @enumFromInt(index);
        const block_count = module.functions.items[index].blocks.items.len;
        var block_index: usize = 0;
        while (block_index < block_count) : (block_index += 1) {
            var builder = mir_builder.Builder{ .module = module, .allocator = allocator, .function_id = function_id };
            try expandBlock(&builder, allocator, @enumFromInt(block_index), ctx);
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
                    // `dst` becomes the call's own result directly — it's
                    // exactly the ONE value the original instruction's
                    // surrounding code already expects, no reordering
                    // concern (a `.call`'s result is simply produced by
                    // the call itself, nothing to interleave).
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
                if (std.mem.eql(u8, v.name, "строки::длина_байт")) break :blk ctx.runtime.byte_length;
                if (std.mem.eql(u8, v.name, "строки::начинается_с")) break :blk ctx.runtime.starts_with;
                if (std.mem.eql(u8, v.name, "строки::длина")) break :blk ctx.runtime.length;
                if (std.mem.eql(u8, v.name, "строки::срез")) break :blk ctx.runtime.slice;
                if (std.mem.eql(u8, v.name, "строки::найти")) break :blk ctx.runtime.find;
                if (std.mem.eql(u8, v.name, "строки::заменить")) break :blk ctx.runtime.replace;
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

// Copies `count` bytes from `src_base_local[0..count)` to
// `dst_base_local[0..count)` — callers pre-add any fixed header offset
// (e.g. `+4` to skip the length prefix) into the base pointers before
// calling. Same loop shape as `wasm_objects.zig`'s `buildEnsureCapacity`
// copy loop (real WASM `loop`, ordinary single-header/single-exit,
// no suspend involved — hits `wasm_stackify.zig`'s existing fast path).
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
    // `byte` reloaded BEFORE `dst_addr` is computed — `mem_store8` needs
    // stack order `[src, addr]` (addr freshest), same convention
    // `mem_store` established (`wasm_emit.zig`'s
    // `EmitContext.frame_store_scratch_frame` doc comment).
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

// `@string_concat(a, b) -> handle`: alloc `4 + len_a + len_b` bytes,
// write the combined length header, byte-copy A then B.
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

    // Write the length header: src (total) produced BEFORE addr (handle
    // reload) — `mem_store` needs `[src, addr]` with addr freshest.
    const total_r2 = try wasm_heap.loadLocal(&builder, total_local, layout.idx_type);
    const handle_for_header = try wasm_heap.loadLocal(&builder, handle_local, layout.ptr_type);
    try builder.emit(.{ .mem_store = .{ .addr = handle_for_header, .src = total_r2 } });

    // Copy A into handle+4.
    const four_for_src_a = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const a_for_copy = try wasm_heap.loadLocal(&builder, a_local, layout.ptr_type);
    const a_base = try wasm_heap.binOp(&builder, layout.idx_type, .add, a_for_copy, four_for_src_a);
    const a_base_local = try wasm_heap.storeLocal(&builder, "a_base", layout.idx_type, a_base);
    const four_for_dst_a = try wasm_heap.addressConst(&builder, layout.idx_type, 4);
    const handle_for_a = try wasm_heap.loadLocal(&builder, handle_local, layout.ptr_type);
    const dst_base_a = try wasm_heap.binOp(&builder, layout.idx_type, .add, handle_for_a, four_for_dst_a);
    const dst_base_a_local = try wasm_heap.storeLocal(&builder, "dst_base_a", layout.idx_type, dst_base_a);
    try emitByteCopyLoop(&builder, layout, a_base_local, dst_base_a_local, len_a_local);

    // Copy B into handle+4+len_a.
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

// `@string_equal(a, b) -> bool`: length check first, then byte-compare
// loop with early exit on first mismatch. Fixes a real, standing
// correctness bug — the old codegen path did raw `i32.eq` on the
// HANDLE (pointer equality), silently wrong for any two independently
// built equal strings (only literal-vs-identical-literal happened to
// work, and only by accident of how the old host model interned them).
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

// `@string_byte_length(s) -> Число`: trivial, the length header IS the
// byte length. Matches `строки.длина_байт`'s native semantics exactly
// (`vm.zig`'s `strLenBytes` — plain `string.len`).
fn buildByteLength(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@string_byte_length", wasm_heap.dummy_symbol, type_store.builtins.number, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const s_local = try builder.newLocal(wasm_heap.dummy_symbol, "s", layout.ptr_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{s_local});
    builder.currentFunction().type_store = type_store;

    const s1 = try wasm_heap.loadLocal(&builder, s_local, layout.ptr_type);
    const len_i32 = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load = .{ .dst = len_i32, .addr = s1 } });
    const len_f64 = try builder.newValue(type_store.builtins.number);
    try builder.emit(.{ .unary = .{ .dst = len_f64, .op = .from_i32, .src = len_i32 } });
    builder.terminate(.{ .return_value = .{ .value = len_f64 } });
    return id;
}

// `@string_starts_with(s, prefix) -> Булево`: byte-level, case-sensitive
// (`vm.zig`'s `strStartsWith` — `std.mem.startsWith(u8, string, prefix)`).
// If prefix is longer than s, false (never reads out of bounds).
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

// `@string_utf8_width(byte) -> i32`: classifies a UTF-8 leading byte's
// sequence length (1-4), matching `std.unicode.utf8ByteSequenceLength`'s
// own classification. Panics (matching native's "строка содержит
// некорректный UTF-8" fault) on a byte that can't start a sequence
// (a stray continuation byte 0x80-0xBF, or 0xF8+).
fn buildUtf8Width(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@string_utf8_width", wasm_heap.dummy_symbol, layout.idx_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const byte_local = try builder.newLocal(wasm_heap.dummy_symbol, "byte", layout.idx_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{byte_local});
    builder.currentFunction().type_store = type_store;

    // byte & 0x80 == 0 -> ASCII, width 1.
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

// `@string_length(s) -> Число`: rune count via a full UTF-8 walk from
// byte 0 to the length header's byte count (`vm.zig`'s `stringLength`
// via `std.unicode.utf8CountCodepoints` — same panic-on-invalid-UTF-8
// contract, delegated to `@string_utf8_width`).
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

// `@string_rune_byte_offset(s, target_rune) -> byte_offset`: walks
// runes from the start, converting a rune index to a byte offset
// (RELATIVE to the string's own data, 0-based — callers add `+4` for
// an absolute address). Matches `vm.zig`'s `runeByteOffset` exactly,
// including its bounds check INSIDE the loop (panics the moment more
// runes are needed than remain, not just at the very end) — this is
// what makes an out-of-range rune index a clean panic rather than an
// out-of-bounds read.
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

// `@string_byte_to_rune_count(s, byte_limit) -> rune_count`: counts
// complete UTF-8 sequences in `s[0..byte_limit)` — the inverse
// direction of `@string_rune_byte_offset`, needed by `найти` to convert
// a found BYTE offset back into the rune index it must return
// (`vm.zig`'s `strFind` — `std.unicode.utf8CountCodepoints(string[0 ..
// start_byte + relative_offset])`).
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

// `@string_index_of(s, needle, start_byte) -> i32`: byte offset of the
// first occurrence of `needle` in `s` at or after `start_byte`, or -1.
// Empty needle matches immediately at `start_byte` (matches
// `std.mem.indexOf`'s own behavior — `vm.zig`'s `strReplace`/`strSplit`
// both special-case empty separately at their OWN call sites, but the
// underlying search primitive agreeing with `std.mem.indexOf` here
// keeps this one function correct for both).
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

    // Empty needle: return start immediately.
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

    // Outer loop condition: i + needle_len <= s_len.
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
    // -1 computed as 0-1 (wrapping i32 subtraction), NOT a raw constant
    // — `wasm_heap.addressConst` takes a `u32` and value-preserving-casts
    // it to i64 for SLEB128 encoding, which does NOT reinterpret a large
    // u32 bit pattern as the intended negative i32; runtime subtraction
    // sidesteps the whole question (guaranteed correct two's-complement
    // wraparound, well-defined by the WASM spec).
    const zero_nf = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    const one_nf = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const neg_one = try wasm_heap.binOp(&builder, layout.idx_type, .subtract, zero_nf, one_nf);
    builder.terminate(.{ .return_value = .{ .value = neg_one } });

    // Inner loop: compare needle_len bytes at s_base+i vs n_base.
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

// `@string_slice(s, start, end) -> Строка`: RUNE-indexed (not byte),
// half-open `[start, end)`. `start`/`end` arrive as `Число` (f64) —
// converted to i32 once via `.to_i32`. Panics (matching native's own
// fault, no clamping) if `start > end` or the resulting end byte
// offset runs past the string.
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

// `@string_find(s, needle, start_rune) -> Число`: rune-indexed (both
// `start` and the return value), returns -1 on not-found (matching
// `vm.zig`'s `strFind` exactly — a plain `Число`, not `Опция`).
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

// `@string_replace(s, target, replacement) -> Строка`: replaces ALL
// occurrences of `target` with `replacement`. Empty `target` returns a
// copy of `s` unchanged (matches `vm.zig`'s `strReplace` exactly).
// Deliberately built on TOP of the already-verified @string_find/
// @string_slice/@string_concat/@string_length rather than a second
// hand-rolled byte-manipulation pass — an earlier from-scratch
// two-pass byte-copy version had a real, hard-to-isolate bug (silently
// undercounting matches for one input, genuinely infinite-looping for
// another) that this reuse-based version avoids by construction: all
// the byte-level arithmetic risk is already covered by those other
// functions' own tests.
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

    // result starts as a fresh empty string (alloc(4), header=0).
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
    // `cond` must be the KEEP-GOING condition with `then_block` as the
    // loop body (matching every other loop in this file, e.g. line 213
    // above) — an earlier version used `not_found` (the STOP condition)
    // with `then=tail(exit)`/`else=match(continue)`, backwards from that
    // convention. `wasm_stackify`'s loop-header detection picks body/exit
    // by which target can reach back to the header (`canReach`), NOT by
    // trusting the then/else labels at face value — with the polarity
    // inverted, it reassigned body/exit to match reachability but left
    // the branch CONDITION itself untouched, so the emitted `if` tested
    // "not found" while running the loop-continuing code, and the
    // exit/tail code fell through unconditionally after the loop instead
    // of only running on non-match. Found via wasm-objdump: the `if`
    // (cond=not_found) body contained the match/concat/br-back logic, and
    // the `else` was empty with tail code unconditionally following the
    // loop.
    const found = try wasm_heap.cmpOp(&builder, layout.bool_type, .not_equal, found_rune_for_cmp, neg_one_number);
    const tail_block = try builder.newBlock();
    const match_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = found, .then_block = match_block, .else_block = tail_block } });

    builder.setCurrentBlock(tail_block);
    {
        // `s_rune_len` (the 3rd `@string_slice` arg) must be produced
        // LAST, immediately before the call — `.call`'s args are
        // replayed in the order listed, assuming each is genuinely
        // fresh/adjacent (same convention this whole file follows);
        // producing it FIRST left it buried under the other two args,
        // a real bug caught by wasmtime's own validator ("type mismatch:
        // expected f64, found i32" — the args ended up shifted by one).
        //
        // `result_for_final` must be produced BEFORE `remaining` — the
        // final concat's args are `[result_for_final, remaining]`, so
        // `result_for_final` needs to be earliest-produced/bottom and
        // `remaining` freshest/top. An earlier version computed
        // `remaining` first (to keep it adjacent to its own 3-arg slice
        // call) then loaded `result_for_final` last — which put it on
        // TOP of `remaining` instead of underneath, silently producing a
        // rotated result ("bbxbbx" instead of "xbbxbb") rather than a
        // validator error, since both operands are the same i32 handle
        // type (no type mismatch to catch it).
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
    // `result_for_partial1` loaded BEFORE `segment` is computed — the
    // concat call below needs args `[result, segment]` in that
    // PRODUCTION order (result first/bottom, segment last/freshest);
    // computing segment first (as an earlier version of this code did)
    // left it buried under the later-loaded result, backwards from
    // what `.call`'s "args replayed in listed order" codegen assumes
    // (caught by wasmtime's validator — a type mismatch one arg over).
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
