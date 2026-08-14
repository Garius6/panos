const std = @import("std");
const mir = @import("mir.zig");
const mir_builder = @import("mir_builder.zig");
const types = @import("types.zig");
const wasm_heap = @import("wasm_heap.zig");

// Eliminates interface dynamic dispatch's LAST remaining gap after
// `mir_lowering.zig` starts emitting `.cast_interface`/`.invoke_interface`
// (both target-agnostic MIR, computed via `type_checker.
// findInterfaceImplementation` — the SAME compile-time resolution the
// native bytecode backend already uses) — turns them into real
// in-module linear-memory code + `call_indirect`, reusing `wasm_heap.zig`'s
// bump allocator (shared with `wasm_objects.zig`/`wasm_strings.zig`/
// `wasm_actors.zig`). Runs in the SAME pass slot as those (before
// `mir_cps.prepare`).
//
// Representation: an interface value is a boxed heap value — `alloc(8)`,
// `receiver: i32` at offset 0 (the underlying concrete struct/enum's own
// handle, untouched), `vtable_ptr: i32` at offset 4 (a small flat array
// of i32 WASM TABLE INDICES, one per interface method, in the
// interface's own declared method order — `InterfaceMethodBinding`'s
// order, already resolved by `mir_lowering.zig`). Both the vtable array
// and the box are allocated fresh every time a `.cast_interface`
// executes (the RECEIVER is a genuine runtime value — which concrete
// struct backs it can differ per call — so the box itself can't be a
// compile-time constant, unlike `wasm_strings.zig`'s literal strings);
// the CONTENT of the vtable array (which table indices) is compile-time
// constant, written via ordinary `mem_store` of `.const_value{.address}`
// constants, same pattern as `wasm_strings.zig`'s `emitConstString`.
//
// `.invoke_interface`'s dispatch chain: unwrap the box (two `mem_load`s
// — receiver, vtable_ptr), read the vtable slot at `method_index*4` (a
// WASM table index, resolved only at RUNTIME — this is genuinely
// dynamic dispatch, not a compile-time-resolvable call), then
// `.call_indirect` with `[receiver] ++ args`.
//
// The WASM function TABLE itself (every function ever placed in ANY
// vtable, deduplicated, in first-seen order) is accumulated as a side
// effect of this pass and returned to the caller — `wasm_emit.
// emitModule`'s `interface_table` parameter needs the EXACT same list,
// in the EXACT same order, that this pass already baked as literal
// table-index constants into every `.cast_interface`'s vtable-array
// construction.

fn unsupported(comptime what: []const u8) error{InterfaceExpandUnsupported} {
    std.debug.print("panos build: AOT (wasm) интерфейсы — " ++ what ++ "\n", .{});
    return error.InterfaceExpandUnsupported;
}

pub const ExpansionResult = struct {
    table: []const mir.FunctionId,
};

const ExpandCtx = struct {
    layout: wasm_heap.PtrLayout,
    type_store: *const types.TypeStore,
};

pub fn expand(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore) !ExpansionResult {
    if (!usesInterfaces(module)) return .{ .table = &.{} };

    const layout = wasm_heap.PtrLayout{
        .ptr_type = type_store.builtins.string,
        .idx_type = type_store.builtins.boolean,
        .bool_type = type_store.builtins.boolean,
    };
    _ = try wasm_heap.findOrBuildAlloc(allocator, module, type_store, layout);
    const ctx = ExpandCtx{ .layout = layout, .type_store = type_store };

    // Assigned in first-seen order while rewriting `.cast_interface`
    // sites below — a plain `AutoHashMap` walk order isn't stable across
    // runs, so the assignment MUST happen via a single linear scan (not
    // e.g. iterating some hash map of "every method ever seen"), which
    // `expandBlock`'s own block-by-block, instruction-by-instruction
    // walk already naturally gives for free.
    var table: std.ArrayList(mir.FunctionId) = .empty;
    var table_index_of: std.AutoHashMap(mir.FunctionId, u32) = .init(allocator);
    defer table_index_of.deinit();

    var index: usize = 0;
    while (index < module.functions.items.len) : (index += 1) {
        const function_id: mir.FunctionId = @enumFromInt(index);
        const block_count = module.functions.items[index].blocks.items.len;
        var block_index: usize = 0;
        while (block_index < block_count) : (block_index += 1) {
            var builder = mir_builder.Builder{ .module = module, .allocator = allocator, .function_id = function_id };
            try expandBlock(&builder, allocator, @enumFromInt(block_index), ctx, &table, &table_index_of);
        }
    }

    return .{ .table = try table.toOwnedSlice(allocator) };
}

fn usesInterfaces(module: *const mir.Module) bool {
    for (module.functions.items) |function| for (function.blocks.items) |block|
        for (block.instructions.items) |instruction| switch (instruction) {
            .cast_interface, .invoke_interface => return true,
            else => {},
        };
    return false;
}

fn tableIndexFor(table: *std.ArrayList(mir.FunctionId), table_index_of: *std.AutoHashMap(mir.FunctionId, u32), allocator: std.mem.Allocator, function_id: mir.FunctionId) !u32 {
    if (table_index_of.get(function_id)) |existing| return existing;
    const index: u32 = @intCast(table.items.len);
    try table.append(allocator, function_id);
    try table_index_of.put(function_id, index);
    return index;
}

fn expandBlock(builder: *mir_builder.Builder, allocator: std.mem.Allocator, block_id: mir.BlockId, ctx: ExpandCtx, table: *std.ArrayList(mir.FunctionId), table_index_of: *std.AutoHashMap(mir.FunctionId, u32)) !void {
    const function = builder.currentFunction();
    var original = function.blockConst(block_id).*;
    function.block(block_id).instructions = .empty;
    builder.setCurrentBlock(block_id);
    builder.terminated = false;

    for (original.instructions.items) |instruction| {
        try expandInstruction(builder, allocator, instruction, ctx, table, table_index_of);
    }
    builder.terminate(original.terminator);
    original.instructions.deinit(allocator);
}

fn expandInstruction(builder: *mir_builder.Builder, allocator: std.mem.Allocator, instruction: mir.Instruction, ctx: ExpandCtx, table: *std.ArrayList(mir.FunctionId), table_index_of: *std.AutoHashMap(mir.FunctionId, u32)) !void {
    switch (instruction) {
        .cast_interface => |v| {
            try expandCastInterface(builder, allocator, v, ctx, table, table_index_of);
        },
        .invoke_interface => |v| {
            try expandInvokeInterface(builder, ctx, v);
        },
        else => try builder.emit(instruction),
    }
}

// `alloc(vtable.len * 4)`, one `mem_store` per entry (each a
// compile-time-constant WASM table index — resolved via `tableIndexFor`,
// same alloc-a-fresh-array-of-constants shape `wasm_strings.zig`'s
// `emitConstString` already established for per-byte string content),
// then `alloc(8)` for the box itself (`receiver` at offset 0, the
// vtable array's own address at offset 4).
fn expandCastInterface(builder: *mir_builder.Builder, allocator: std.mem.Allocator, v: anytype, ctx: ExpandCtx, table: *std.ArrayList(mir.FunctionId), table_index_of: *std.AutoHashMap(mir.FunctionId, u32)) !void {
    const layout = ctx.layout;
    const module = builder.module;
    const alloc_id = wasm_heap.findFunctionByName(module, wasm_heap.alloc_function_name).?;

    // `v.src` is a PRE-EXISTING value, already produced (and left on the
    // real WASM stack) by whatever instruction came immediately before
    // the original (now-being-expanded) `.cast_interface` — it must be
    // routed through a Local IMMEDIATELY, before any of this function's
    // OWN instructions run, or it ends up buried under everything this
    // function inserts (vtable-array alloc/stores, box alloc) with no
    // way to reach it again. The single most load-bearing lesson of this
    // whole multi-session WASM-AOT initiative — see `wasm_strings.zig`'s
    // own arg-order bug history for the same mistake recurring.
    const src_local = try wasm_heap.storeLocal(builder, "@src", layout.ptr_type, v.src);

    const vtable_size = try wasm_heap.addressConst(builder, layout.idx_type, @intCast(v.vtable.len * 4));
    const vtable_array = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = vtable_array, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, vtable_size) } });
    const vtable_array_local = try wasm_heap.storeLocal(builder, "@vtable", layout.ptr_type, vtable_array);

    for (v.vtable, 0..) |binding, i| {
        const table_index = try tableIndexFor(table, table_index_of, allocator, binding.function);
        const table_index_const = try wasm_heap.addressConst(builder, layout.idx_type, table_index);
        const offset = try wasm_heap.addressConst(builder, layout.idx_type, @intCast(i * 4));
        const vtable_array_for_addr = try wasm_heap.loadLocal(builder, vtable_array_local, layout.ptr_type);
        const addr = try wasm_heap.binOp(builder, layout.idx_type, .add, vtable_array_for_addr, offset);
        try builder.emit(.{ .mem_store = .{ .addr = addr, .src = table_index_const } });
    }

    const box_size = try wasm_heap.addressConst(builder, layout.idx_type, 8);
    const box = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = box, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, box_size) } });
    const box_local = try wasm_heap.storeLocal(builder, "@box", layout.ptr_type, box);

    // `src` (the receiver) reloaded fresh from `src_local`, BEFORE `box`
    // (reloaded fresh too) — the established `mem_store` stack
    // convention (`src` first, `addr` last/adjacent).
    const src_for_receiver = try wasm_heap.loadLocal(builder, src_local, layout.ptr_type);
    const box_for_receiver = try wasm_heap.loadLocal(builder, box_local, layout.ptr_type);
    try builder.emit(.{ .mem_store = .{ .addr = box_for_receiver, .src = src_for_receiver } });

    // `src` (`vtable_array_for_store`) produced BEFORE `addr`
    // (`vtable_field_addr`) — an earlier version computed the ADDRESS
    // first (via the `box+4` arithmetic) and loaded `src` LAST, backwards
    // from `mem_store`'s convention. Since `mem_store`'s codegen just
    // pops whatever's on top as `addr` and the next as `src` with no
    // semantic check, the swap silently stored `vtable_field_addr`'s
    // VALUE (the address itself) INTO `vtable_array`'s own first slot
    // instead of writing `vtable_array`'s address into the box — for the
    // single-method-interface fixtures this file's own tests use, that
    // clobbered the just-written table index with the box's own address,
    // and the box's vtable-pointer FIELD was left holding stale
    // (zero-initialized) memory. Found via wasm-objdump byte tracing
    // after runtime dispatch consistently picked the first-ever-cast
    // implementation regardless of which was actually passed.
    const vtable_array_for_store = try wasm_heap.loadLocal(builder, vtable_array_local, layout.ptr_type);
    const four = try wasm_heap.addressConst(builder, layout.idx_type, 4);
    const box_for_vtable_addr = try wasm_heap.loadLocal(builder, box_local, layout.ptr_type);
    const vtable_field_addr = try wasm_heap.binOp(builder, layout.idx_type, .add, box_for_vtable_addr, four);
    try builder.emit(.{ .mem_store = .{ .addr = vtable_field_addr, .src = vtable_array_for_store } });

    try builder.emit(.{ .load_local = .{ .dst = v.dst, .local = box_local } });
}

// Unwraps the box (`receiver`, `vtable_ptr`), reads the vtable slot at
// `method_index*4` (the ONLY genuinely dynamic part — a runtime i32,
// not known until the program actually runs), then `.call_indirect`
// with `[receiver] ++ args` (receiver first, matching every OTHER
// method-call convention in this codebase — `это` is `parameters[0]`,
// see `reserveMethods`/`lowerMethods`).
fn expandInvokeInterface(builder: *mir_builder.Builder, ctx: ExpandCtx, v: anytype) !void {
    const layout = ctx.layout;

    const box_for_receiver = v.receiver;
    const receiver_local = try wasm_heap.storeLocal(builder, "@iface_box", layout.ptr_type, box_for_receiver);

    // `v.args` are ALSO pre-existing values (from the original
    // instruction stream, produced before this `.invoke_interface`) —
    // routed through Locals immediately, same reasoning as `v.receiver`
    // above and `v.src` in `expandCastInterface`, since they're only
    // actually needed much later (after the box-unwrap/vtable-lookup
    // code below).
    const arg_locals = try builder.module.arena.allocator().alloc(mir.LocalId, v.args.len);
    for (v.args, arg_locals) |arg, *local| {
        local.* = try wasm_heap.storeLocal(builder, "@iface_arg", builder.currentFunction().valueType(arg), arg);
    }

    const box_for_load = try wasm_heap.loadLocal(builder, receiver_local, layout.ptr_type);
    const receiver = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .mem_load = .{ .dst = receiver, .addr = box_for_load } });
    const receiver_value_local = try wasm_heap.storeLocal(builder, "@receiver", layout.ptr_type, receiver);

    const four = try wasm_heap.addressConst(builder, layout.idx_type, 4);
    const box_for_vtable = try wasm_heap.loadLocal(builder, receiver_local, layout.ptr_type);
    const vtable_field_addr = try wasm_heap.binOp(builder, layout.idx_type, .add, box_for_vtable, four);
    const vtable_array = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .mem_load = .{ .dst = vtable_array, .addr = vtable_field_addr } });
    const vtable_array_local = try wasm_heap.storeLocal(builder, "@vtable", layout.ptr_type, vtable_array);

    // `call_indirect`'s WASM stack requirement is `[args..., table_index]`
    // (the index popped FIRST/topmost) — args (receiver + real args) must
    // therefore be produced BEFORE `table_index`, not after, even though
    // the vtable slot needed to COMPUTE `table_index` was already read
    // above; the read (`mem_load` into `table_index`'s own ValueId) is
    // deferred to right before the call specifically to keep it the
    // LAST-produced operand.
    const receiver_for_call = try wasm_heap.loadLocal(builder, receiver_value_local, layout.ptr_type);
    const arena = builder.module.arena.allocator();
    var args: std.ArrayList(mir.ValueId) = .empty;
    try args.append(arena, receiver_for_call);
    for (arg_locals) |local| {
        const arg_type = builder.currentFunction().locals.items[@intFromEnum(local)].type_id;
        try args.append(arena, try wasm_heap.loadLocal(builder, local, arg_type));
    }

    const method_offset = try wasm_heap.addressConst(builder, layout.idx_type, @as(u32, v.method_index) * 4);
    const vtable_array_for_addr = try wasm_heap.loadLocal(builder, vtable_array_local, layout.ptr_type);
    const method_addr = try wasm_heap.binOp(builder, layout.idx_type, .add, vtable_array_for_addr, method_offset);
    const table_index = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load = .{ .dst = table_index, .addr = method_addr } });

    try builder.emit(.{ .call_indirect = .{ .dst = v.dst, .table_index = table_index, .args = try args.toOwnedSlice(arena) } });
}
