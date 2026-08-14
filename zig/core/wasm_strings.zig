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
    const runtime = StringRuntime{
        .concat = try buildConcat(allocator, module, type_store, layout),
        .equal = try buildEqual(allocator, module, type_store, layout),
        .byte_length = try buildByteLength(allocator, module, type_store, layout),
        .starts_with = try buildStartsWith(allocator, module, type_store, layout),
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
