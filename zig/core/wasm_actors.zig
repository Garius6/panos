const std = @import("std");
const mir = @import("mir.zig");
const mir_builder = @import("mir_builder.zig");
const mir_cps = @import("mir_cps.zig");
const types = @import("types.zig");
const source = @import("source.zig");
const symbols = @import("symbols.zig");
const wasm_module = @import("wasm_module.zig");

// Turns `mir_cps.zig`'s CPS-rewritten step functions into a REAL,
// self-contained WASM program: builds the generic mailbox/signal/alloc
// runtime functions those step functions call into, rewires the
// placeholder `call_builtin{"@runtime::..."}` names `mir_cps.zig` emits
// into real in-module `.call`s (no new host imports — this must run
// under plain wasmtime), expands `.spawn`/`.send` into concrete
// alloc/frame-store sequences, and replaces the entry point with a
// scheduler wrapper.
//
// Phase-1 MVP constraint, enforced here (not assumed): at most ONE
// `.spawn` in the whole module, and it must be reachable from `старт`'s
// own (CPS-rewritten) body — `старт` itself MUST call `получить()` at
// least once (this is what lets it double as "process 0" the scheduler
// drives). Anything wider (multiple actor types, spawning from inside a
// spawned actor, a non-suspending entry point that only spawns
// fire-and-forget) is Phase 2+; `expand` returns a clean `unsupported`
// error rather than silently producing a program that only handles the
// narrower case.
//
// Scheduler shape: no real WASM `loop` at all — a fixed, UNROLLED
// sequence of round-trip attempts (`scheduler_rounds`), each an ordinary
// if/else diamond calling process 0's and process 1's step function once
// if not already done. This is deliberately simpler (and lower-risk to
// hand-author correctly) than a genuine dynamic loop: Phase-1's own
// scope (one spawned actor, one request/reply exchange) converges in a
// handful of rounds; exceeding the bound traps instead of silently
// returning an incomplete result.

fn unsupported(comptime what: []const u8) error{ActorExpandUnsupported} {
    std.debug.print("panos build: AOT (wasm) акторы — " ++ what ++ "\n", .{});
    return error.ActorExpandUnsupported;
}

const scheduler_rounds: u32 = 16;

fn findFunctionByName(module: *const mir.Module, name: []const u8) ?mir.FunctionId {
    for (module.functions.items) |function| {
        if (std.mem.eql(u8, function.name, name)) return function.id;
    }
    return null;
}

fn frameValue(builder: *mir_builder.Builder, frame_local: mir.LocalId, ptr_type: types.TypeId) !mir.ValueId {
    const dst = try builder.newValue(ptr_type);
    try builder.emit(.{ .load_local = .{ .dst = dst, .local = frame_local } });
    return dst;
}

fn addressConst(builder: *mir_builder.Builder, ptr_type: types.TypeId, value: u32) !mir.ValueId {
    const dst = try builder.newValue(ptr_type);
    try builder.emit(.{ .const_value = .{ .dst = dst, .value = .{ .address = value } } });
    return dst;
}

fn boolConst(builder: *mir_builder.Builder, bool_type: types.TypeId, value: bool) !mir.ValueId {
    const dst = try builder.newValue(bool_type);
    try builder.emit(.{ .const_value = .{ .dst = dst, .value = .{ .boolean = value } } });
    return dst;
}

fn binOp(builder: *mir_builder.Builder, result_type: types.TypeId, op: mir.BinOp, lhs: mir.ValueId, rhs: mir.ValueId) !mir.ValueId {
    const dst = try builder.newValue(result_type);
    try builder.emit(.{ .binary = .{ .dst = dst, .op = op, .lhs = lhs, .rhs = rhs } });
    return dst;
}

fn cmpOp(builder: *mir_builder.Builder, bool_type: types.TypeId, op: mir.CmpOp, lhs: mir.ValueId, rhs: mir.ValueId) !mir.ValueId {
    const dst = try builder.newValue(bool_type);
    try builder.emit(.{ .compare = .{ .dst = dst, .op = op, .lhs = lhs, .rhs = rhs } });
    return dst;
}

fn notOp(builder: *mir_builder.Builder, bool_type: types.TypeId, value: mir.ValueId) !mir.ValueId {
    const dst = try builder.newValue(bool_type);
    try builder.emit(.{ .unary = .{ .dst = dst, .op = .negate_bool, .src = value } });
    return dst;
}

// This whole file's #1 rule: a `ValueId` is a STACK VALUE, consumed
// by its single use the moment `wasm_emit.zig` replays it — reusing one
// across two or more later instructions (`mir_validate.zig`'s "single-
// use инвариант") is invalid MIR, not just a style question. Any value
// this file needs more than once MUST go through a real `Local` (store
// once, reload fresh at each use) — exactly what `frameValue` already
// does for the frame pointer; `storeLocal`/`loadLocal` below generalize
// that to every other repeated value (found by actually running
// `mir_validate.zig` over hand-built output, not by reading alone).
fn storeLocal(builder: *mir_builder.Builder, name: []const u8, type_id: types.TypeId, value: mir.ValueId) !mir.LocalId {
    const local = try builder.newLocal(dummy_symbol, name, type_id);
    try builder.emit(.{ .store_local = .{ .local = local, .src = value } });
    return local;
}

fn loadLocal(builder: *mir_builder.Builder, local: mir.LocalId, type_id: types.TypeId) !mir.ValueId {
    const dst = try builder.newValue(type_id);
    try builder.emit(.{ .load_local = .{ .dst = dst, .local = local } });
    return dst;
}

const dummy_span: source.Span = .{ .file_id = 0, .start = 0, .end = 0 };
const dummy_symbol: symbols.SymbolId = @enumFromInt(0);

const Layout = struct {
    ptr_type: types.TypeId,
    idx_type: types.TypeId, // reused `Булево` — plain i32, no string-concat codegen collision (see mir_cps.zig's own `ptr_type` comment)
    bool_type: types.TypeId,
};

// --- Generic runtime functions ----------------------------------------

fn buildAlloc(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: Layout) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@actor_alloc", dummy_symbol, layout.ptr_type, dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const size_local = try builder.newLocal(dummy_symbol, "size", layout.idx_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{size_local});
    builder.currentFunction().type_store = type_store;

    const size = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .load_local = .{ .dst = size, .local = size_local } });
    const ptr = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .global_get = .{ .dst = ptr, .global = 0 } });
    const ptr_local = try storeLocal(&builder, "ptr", layout.ptr_type, ptr); // `ptr` used twice below (add, return) — must go through a Local
    const ptr_for_add = try loadLocal(&builder, ptr_local, layout.ptr_type);
    const new_ptr = try binOp(&builder, layout.ptr_type, .add, ptr_for_add, size);
    try builder.emit(.{ .global_set = .{ .global = 0, .src = new_ptr } });
    const ptr_for_return = try loadLocal(&builder, ptr_local, layout.ptr_type);
    builder.terminate(.{ .return_value = .{ .value = ptr_for_return } });
    return id;
}

fn buildHas(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: Layout, name: []const u8, count_slot: u32) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, name, dummy_symbol, layout.bool_type, dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const frame_local = try builder.newLocal(dummy_symbol, "frame", layout.ptr_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{frame_local});
    builder.currentFunction().type_store = type_store;

    const frame = try frameValue(&builder, frame_local, layout.ptr_type);
    const count = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .frame_load = .{ .dst = count, .frame = frame, .slot = count_slot } });
    const zero = try addressConst(&builder, layout.idx_type, 0);
    const has = try cmpOp(&builder, layout.bool_type, .not_equal, count, zero);
    builder.terminate(.{ .return_value = .{ .value = has } });
    return id;
}

// `payload_type` — pop must be built once per WASM value category (i32
// handle vs f64 number), since a plain WASM function has ONE fixed
// result type and message payloads vary by actor (see the file doc
// comment's `mailbox_pop_f64`/`_i32` split).
fn buildPop(
    allocator: std.mem.Allocator,
    module: *mir.Module,
    type_store: *const types.TypeStore,
    layout: Layout,
    name: []const u8,
    payload_type: types.TypeId,
    count_slot: u32,
    head_slot: u32,
    ring_base_slot: u32,
    cap: u32,
) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, name, dummy_symbol, payload_type, dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const frame_local = try builder.newLocal(dummy_symbol, "frame", layout.ptr_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{frame_local});
    builder.currentFunction().type_store = type_store;

    const frame1 = try frameValue(&builder, frame_local, layout.ptr_type);
    const head = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .frame_load = .{ .dst = head, .frame = frame1, .slot = head_slot } });
    const head_local = try storeLocal(&builder, "head", layout.idx_type, head); // used twice below (addr math, head+1)

    // addr = frame + ring_base_slot*8 + head*8
    const frame2 = try frameValue(&builder, frame_local, layout.ptr_type);
    const ring_base_bytes = try addressConst(&builder, layout.ptr_type, ring_base_slot * 8);
    const base = try binOp(&builder, layout.ptr_type, .add, frame2, ring_base_bytes);
    const eight = try addressConst(&builder, layout.idx_type, 8);
    const head_for_addr = try loadLocal(&builder, head_local, layout.idx_type);
    const head_bytes = try binOp(&builder, layout.idx_type, .multiply, head_for_addr, eight);
    const addr = try binOp(&builder, layout.ptr_type, .add, base, head_bytes);
    const message = try builder.newValue(payload_type);
    try builder.emit(.{ .mem_load = .{ .dst = message, .addr = addr } });

    // head = (head + 1) & (cap - 1)
    const head_for_inc = try loadLocal(&builder, head_local, layout.idx_type);
    const one = try addressConst(&builder, layout.idx_type, 1);
    const head_plus_one = try binOp(&builder, layout.idx_type, .add, head_for_inc, one);
    const mask = try addressConst(&builder, layout.idx_type, cap - 1);
    const head_new = try binOp(&builder, layout.idx_type, .bit_and, head_plus_one, mask);
    const frame3 = try frameValue(&builder, frame_local, layout.ptr_type);
    try builder.emit(.{ .frame_store = .{ .frame = frame3, .slot = head_slot, .src = head_new } });

    // count -= 1
    const frame4 = try frameValue(&builder, frame_local, layout.ptr_type);
    const count = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .frame_load = .{ .dst = count, .frame = frame4, .slot = count_slot } });
    const one_again = try addressConst(&builder, layout.idx_type, 1);
    const count_new = try binOp(&builder, layout.idx_type, .subtract, count, one_again);
    const frame5 = try frameValue(&builder, frame_local, layout.ptr_type);
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

fn buildRuntime(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: Layout) !Runtime {
    _ = try buildAlloc(allocator, module, type_store, layout);
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

// Finds `mir_cps.zig`'s placeholder `call_builtin{"@runtime::..."}`
// instructions (see that file's `suspendKind`) across every function and
// replaces them with a real `.call` to the matching function built
// above — the pop variant is chosen from the CALL SITE's own `dst` type
// (the message's real payload type), never from the runtime function
// itself.
fn rewireSuspendCalls(module: *mir.Module, runtime: Runtime) void {
    for (module.functions.items) |*function| {
        for (function.blocks.items) |*block| {
            for (block.instructions.items) |*instruction| {
                const call = switch (instruction.*) {
                    .call_builtin => |c| c,
                    else => continue,
                };
                // `себя()` (`mir_lowering.zig`'s `"@runtime::current_process"`)
                // — in this design a process's "handle" IS its own frame
                // pointer, so this is just reading local 0 back (`mir_cps.zig`
                // always makes the frame pointer local 0 of a rewritten
                // function), not a call at all.
                if (std.mem.eql(u8, call.name, "@runtime::current_process")) {
                    instruction.* = .{ .load_local = .{ .dst = call.dst.?, .local = @enumFromInt(0) } };
                    continue;
                }
                // Real bug found running actual code, not just reading:
                // checking equality against ONLY `builtins.string`/
                // `.boolean` misses every nominal (struct/enum), array,
                // and process type — ALL of which ALSO map to i32 per
                // `wasm_module.wasmValTypeForStore` (which also now
                // special-cases `поison`/`unconstrained` as i32 — see
                // its own doc comment — covering `получить()`'s
                // otherwise-unresolved type for the common `-> Пусто`
                // actor idiom).
                const is_i32 = wasm_module.wasmValTypeForStore(function.type_store.?, function.valueType(call.dst.?)) == wasm_module.wasm_i32;
                const callee: ?mir.FunctionId = blk: {
                    if (std.mem.eql(u8, call.name, "@runtime::mailbox_has")) break :blk runtime.mailbox_has;
                    if (std.mem.eql(u8, call.name, "@runtime::signal_has")) break :blk runtime.signal_has;
                    if (std.mem.eql(u8, call.name, "@runtime::mailbox_pop")) break :blk if (is_i32) runtime.mailbox_pop_i32 else runtime.mailbox_pop_f64;
                    if (std.mem.eql(u8, call.name, "@runtime::signal_pop")) break :blk if (is_i32) runtime.signal_pop_i32 else runtime.signal_pop_f64;
                    break :blk null;
                };
                if (callee) |fn_id| {
                    instruction.* = .{ .call = .{ .dst = call.dst, .callee = fn_id, .args = call.args } };
                }
            }
        }
    }
}

// --- `.spawn`/`.send` expansion ----------------------------------------

// A function_ref immediately preceding `.spawn` — the same convention
// `wasm_emit.zig`'s own `value_to_function` relies on for `call_value`.
fn resolveSpawnTarget(function: *const mir.Function, callee: mir.ValueId) ?mir.FunctionId {
    for (function.blocks.items) |block| {
        for (block.instructions.items) |instruction| {
            if (instruction == .function_ref and instruction.function_ref.dst == callee) return instruction.function_ref.function;
        }
    }
    return null;
}

// Rewrites the SINGLE `.spawn` inside `function` (already located by the
// caller) in place: allocates a fresh frame sized for `target`, copies
// `args` into it positionally, and stashes the new frame pointer into
// `child_frame_slot` of the CURRENT function's own frame (for the
// scheduler to find) — reusing `.spawn`'s own `dst` ValueId as "the
// process handle" everywhere it's already used downstream (the ordinary
// `пер proc = запусти ...` local-store that follows needs no rewriting
// at all).
fn expandSpawn(
    allocator: std.mem.Allocator,
    builder: *mir_builder.Builder,
    block_id: mir.BlockId,
    spawn_index: usize,
    layout: Layout,
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

    // dst = alloc(target_total_slots * 8) — reuses the ORIGINAL dst
    // ValueId directly, so every later instruction that already expects
    // "the spawn result" keeps working unmodified.
    builder.setCurrentBlock(block_id);
    builder.currentFunction().block(block_id).instructions = replacement;
    builder.terminated = false;

    const size_const = try addressConst(builder, layout.idx_type, target_total_slots * 8);
    try builder.emit(.{ .call = .{ .dst = dst, .callee = findAllocId(module_of(builder)).?, .args = try dupeOne(module_of(builder), size_const) } });
    // `dst` is used below for EVERY arg's `frame_store`, the child-slot
    // stash, AND possibly further downstream (the user's own `пер proc =
    // запусти ...`) — single-use invariant, same fix as `mir_cps.zig`'s
    // `Redirect`: store once, reload fresh at each use.
    const dst_local = try storeLocal(builder, "@spawned", layout.ptr_type, dst);

    for (args, 0..) |arg, i| {
        const dst_for_arg = try loadLocal(builder, dst_local, layout.ptr_type);
        try builder.emit(.{ .frame_store = .{ .frame = dst_for_arg, .slot = mir_cps.frame_prefix_slots + @as(u32, @intCast(i)), .src = arg } });
    }

    // `src` computed BEFORE `frame` — see `wasm_emit.zig`'s
    // `EmitContext.frame_store_scratch_frame` doc comment (stack order
    // `frame_store` codegen expects is `[src, frame]`).
    const dst_for_stash = try loadLocal(builder, dst_local, layout.ptr_type);
    const own_frame = try frameValue(builder, frame_local, layout.ptr_type);
    try builder.emit(.{ .frame_store = .{ .frame = own_frame, .slot = child_frame_slot, .src = dst_for_stash } });

    // Downstream instructions (the user's own code after `запусти ...`,
    // e.g. `пер proc = ...`) may reference `dst` too — redirect exactly
    // like `mir_cps.zig`'s suspend-point handling does.
    for (original.instructions.items[spawn_index + 1 ..]) |tail_instruction| {
        var rewritten = tail_instruction;
        if (mir_cps.referencesValue(rewritten, dst)) {
            const fresh = try loadLocal(builder, dst_local, layout.ptr_type);
            rewritten = mir_cps.substituteValue(rewritten, dst, fresh);
        }
        try builder.emit(rewritten);
    }
    builder.terminate(original.terminator);
    // `.deinit`, not `allocator.free(.items)` — see `mir_cps.zig`'s
    // identical comment on its own equivalent free.
    original.instructions.deinit(allocator);
}

// Arena-allocated (`module.arena`), NOT the passed-in `allocator` —
// `.call.args` is an instruction slice field, freed all at once with the
// module (see `mir.Module.arena`'s own doc comment), never individually
// by `Function.deinit`. Using the wrong allocator here is a real,
// silent leak — found by running this code under a leak-checking
// allocator, not by reading alone.
fn dupeOne(module: *mir.Module, value: mir.ValueId) ![]const mir.ValueId {
    return module.arena.allocator().dupe(mir.ValueId, &.{value});
}

fn module_of(builder: *mir_builder.Builder) *mir.Module {
    return builder.module;
}

var g_alloc_id: ?mir.FunctionId = null;
fn findAllocId(module: *mir.Module) ?mir.FunctionId {
    if (g_alloc_id) |id| return id;
    for (module.functions.items) |function| {
        if (std.mem.eql(u8, function.name, "@actor_alloc")) {
            g_alloc_id = function.id;
            return function.id;
        }
    }
    return null;
}

// Rewrites the SINGLE `.send` in place: pushes `message` into `process`'s
// mailbox ring buffer.
fn expandSend(
    allocator: std.mem.Allocator,
    builder: *mir_builder.Builder,
    block_id: mir.BlockId,
    send_index: usize,
    layout: Layout,
) !void {
    const function = builder.currentFunction();
    var original = function.blockConst(block_id).*;
    const send = original.instructions.items[send_index].send;

    var prefix: std.ArrayList(mir.Instruction) = .empty;
    try prefix.appendSlice(allocator, original.instructions.items[0..send_index]);

    builder.setCurrentBlock(block_id);
    builder.currentFunction().block(block_id).instructions = prefix;
    builder.terminated = false;

    const message = send.message;
    // `process`/`count` are each used more than once below — single-use
    // invariant, same fix as everywhere else in this file: store once,
    // reload fresh per use.
    const process_local = try storeLocal(builder, "@target", layout.ptr_type, send.process);

    const process_for_count = try loadLocal(builder, process_local, layout.ptr_type);
    const count = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .frame_load = .{ .dst = count, .frame = process_for_count, .slot = mir_cps.mailbox_count_slot } });
    const count_local = try storeLocal(builder, "@count", layout.idx_type, count);

    const process_for_head = try loadLocal(builder, process_local, layout.ptr_type);
    const head = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .frame_load = .{ .dst = head, .frame = process_for_head, .slot = mir_cps.mailbox_head_slot } });
    const eight = try addressConst(builder, layout.idx_type, 8);
    const count_for_tail = try loadLocal(builder, count_local, layout.idx_type);
    const tail_pre = try binOp(builder, layout.idx_type, .add, head, count_for_tail);
    const mask = try addressConst(builder, layout.idx_type, mir_cps.mailbox_cap - 1);
    const tail = try binOp(builder, layout.idx_type, .bit_and, tail_pre, mask);
    const ring_base_bytes = try addressConst(builder, layout.ptr_type, mir_cps.mailbox_ring_base * 8);
    const process_for_base = try loadLocal(builder, process_local, layout.ptr_type);
    const base = try binOp(builder, layout.ptr_type, .add, process_for_base, ring_base_bytes);
    const tail_bytes = try binOp(builder, layout.idx_type, .multiply, tail, eight);
    const addr = try binOp(builder, layout.ptr_type, .add, base, tail_bytes);
    try builder.emit(.{ .mem_store = .{ .addr = addr, .src = message } });
    const one = try addressConst(builder, layout.idx_type, 1);
    const count_for_inc = try loadLocal(builder, count_local, layout.idx_type);
    const count_new = try binOp(builder, layout.idx_type, .add, count_for_inc, one);
    const process_for_store = try loadLocal(builder, process_local, layout.ptr_type);
    try builder.emit(.{ .frame_store = .{ .frame = process_for_store, .slot = mir_cps.mailbox_count_slot, .src = count_new } });

    try builder.currentFunction().block(block_id).instructions.appendSlice(allocator, original.instructions.items[send_index + 1 ..]);
    builder.terminate(original.terminator);
    // `.deinit`, not `allocator.free(.items)` — see `mir_cps.zig`'s
    // identical comment on its own equivalent free.
    original.instructions.deinit(allocator);
}

// --- Entry-point scheduler wrapper --------------------------------------

fn buildScheduler(
    allocator: std.mem.Allocator,
    module: *mir.Module,
    type_store: *const types.TypeStore,
    layout: Layout,
    old_start: mir.FunctionId,
    old_start_total_slots: u32,
    child_frame_slot: u32,
    actor_step: mir.FunctionId,
    original_result_type: types.TypeId,
) !void {
    const new_start = try mir_builder.newFunction(module, allocator, "старт", dummy_symbol, original_result_type, dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, new_start);
    builder.currentFunction().parameters = &.{};
    builder.currentFunction().type_store = type_store;

    const size0 = try addressConst(&builder, layout.idx_type, old_start_total_slots * 8);
    const frame0 = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = frame0, .callee = findAllocId(module).?, .args = try dupeOne(module, size0) } });
    // `frame0` used more than once below — store once, reload fresh per use.
    const frame0_local = try storeLocal(&builder, "frame0", layout.ptr_type, frame0);
    // `src` computed BEFORE `frame` — see `wasm_emit.zig`'s
    // `EmitContext.frame_store_scratch_frame` doc comment (stack order
    // `frame_store` codegen expects is `[src, frame]`).
    const zero_addr = try addressConst(&builder, layout.ptr_type, 0);
    const frame0_for_init = try loadLocal(&builder, frame0_local, layout.ptr_type);
    try builder.emit(.{ .frame_store = .{ .frame = frame0_for_init, .slot = child_frame_slot, .src = zero_addr } });
    const done0_local = try builder.newLocal(dummy_symbol, "done0", layout.bool_type);
    const done1_local = try builder.newLocal(dummy_symbol, "done1", layout.bool_type);
    const false0 = try boolConst(&builder, layout.bool_type, false);
    try builder.emit(.{ .store_local = .{ .local = done0_local, .src = false0 } });
    // process 1 (the spawned actor) doesn't exist until process 0's own
    // step function reaches its `.spawn` — treated as "done" (skip) until
    // its frame pointer (slot `child_frame_slot` of frame0) is non-zero.
    const true1 = try boolConst(&builder, layout.bool_type, true);
    try builder.emit(.{ .store_local = .{ .local = done1_local, .src = true1 } });

    var round: u32 = 0;
    while (round < scheduler_rounds) : (round += 1) {
        try emitSchedulerRound(&builder, allocator, layout, frame0_local, done0_local, done1_local, old_start, actor_step, child_frame_slot);
    }

    const d0 = try builder.newValue(layout.bool_type);
    try builder.emit(.{ .load_local = .{ .dst = d0, .local = done0_local } });
    const d1 = try builder.newValue(layout.bool_type);
    try builder.emit(.{ .load_local = .{ .dst = d1, .local = done1_local } });
    const both_done = try binOp(&builder, layout.bool_type, .bit_and, d0, d1);

    const trap_block = try builder.newBlock();
    const finish_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = both_done, .then_block = finish_block, .else_block = trap_block } });

    builder.setCurrentBlock(trap_block);
    builder.terminate(.{ .unreachable_term = .{ .reason = "актор: превышен лимит раундов планировщика (Phase 1, 16 раундов)" } });

    builder.setCurrentBlock(finish_block);
    if (type_store.eql(original_result_type, type_store.builtins.void)) {
        builder.terminate(.{ .return_value = .{ .value = null } });
    } else {
        const frame0_final = try frameValue(&builder, frame0_local, layout.ptr_type);
        const result = try builder.newValue(original_result_type);
        try builder.emit(.{ .frame_load = .{ .dst = result, .frame = frame0_final, .slot = mir_cps.result_slot } });
        builder.terminate(.{ .return_value = .{ .value = result } });
    }

    // Old entry point is no longer externally reachable (no export named
    // "старт" refers to it any more) — renamed so `emitModule`'s
    // "export every function by name" doesn't produce a second export
    // literally named "старт" colliding with the new one above.
    module.functions.items[@intFromEnum(old_start)].name = "@старт_шаг";
    module.functions.items[@intFromEnum(actor_step)].name = "@актор_шаг";
}

fn emitSchedulerRound(
    builder: *mir_builder.Builder,
    allocator: std.mem.Allocator,
    layout: Layout,
    frame0_local: mir.LocalId,
    done0_local: mir.LocalId,
    done1_local: mir.LocalId,
    old_start: mir.FunctionId,
    actor_step: mir.FunctionId,
    child_frame_slot: u32,
) !void {
    _ = allocator;
    // Process 0.
    {
        const d0 = try builder.newValue(layout.bool_type);
        try builder.emit(.{ .load_local = .{ .dst = d0, .local = done0_local } });
        const not_done0 = try notOp(builder, layout.bool_type, d0);
        const call_block = try builder.newBlock();
        // `skip_block` is a REAL, distinct block — not `after_block`
        // itself. `wasm_stackify.findMerge` looks for a merge block
        // OTHER than the branch's own then/else targets; making
        // `else_block` literally BE the merge point (as an earlier
        // version of this code did) makes every merge search fail,
        // which makes `processFrom` fall back to re-walking the ENTIRE
        // rest of the function from scratch down BOTH the then and else
        // paths instead of stopping at a shared point — with
        // `scheduler_rounds` copies of this diamond chained together,
        // that's real exponential blowup, not a hang: confirmed by
        // timing 1..11 rounds directly (8=4s, 9=7s, 10=20s, 11 exceeded
        // a 60s budget) before finding this, not by reading alone.
        const skip_block = try builder.newBlock();
        const after_block = try builder.newBlock();
        builder.terminate(.{ .branch = .{ .cond = not_done0, .then_block = call_block, .else_block = skip_block } });

        builder.setCurrentBlock(call_block);
        const frame0 = try frameValue(builder, frame0_local, layout.ptr_type);
        const r0 = try builder.newValue(layout.bool_type);
        try builder.emit(.{ .call = .{ .dst = r0, .callee = old_start, .args = try dupeOne(builder.module, frame0) } });
        try builder.emit(.{ .store_local = .{ .local = done0_local, .src = r0 } });
        builder.terminate(.{ .jump = .{ .target = after_block } });

        builder.setCurrentBlock(skip_block);
        builder.terminate(.{ .jump = .{ .target = after_block } });

        builder.setCurrentBlock(after_block);
    }
    // Process 1 (the spawned actor) — only if spawned (frame pointer
    // non-zero) AND not already done.
    {
        const frame0 = try frameValue(builder, frame0_local, layout.ptr_type);
        const frame1 = try builder.newValue(layout.ptr_type);
        try builder.emit(.{ .frame_load = .{ .dst = frame1, .frame = frame0, .slot = child_frame_slot } });
        const zero = try addressConst(builder, layout.ptr_type, 0);
        const spawned = try cmpOp(builder, layout.bool_type, .not_equal, frame1, zero);
        const d1 = try builder.newValue(layout.bool_type);
        try builder.emit(.{ .load_local = .{ .dst = d1, .local = done1_local } });
        const not_done1 = try notOp(builder, layout.bool_type, d1);
        const should_run = try binOp(builder, layout.bool_type, .bit_and, spawned, not_done1);

        const call_block = try builder.newBlock();
        const skip_block = try builder.newBlock(); // see the `Process 0` comment above — must be distinct from `after_block`
        const after_block = try builder.newBlock();
        builder.terminate(.{ .branch = .{ .cond = should_run, .then_block = call_block, .else_block = skip_block } });

        builder.setCurrentBlock(call_block);
        const frame0b = try frameValue(builder, frame0_local, layout.ptr_type);
        const frame1b = try builder.newValue(layout.ptr_type);
        try builder.emit(.{ .frame_load = .{ .dst = frame1b, .frame = frame0b, .slot = child_frame_slot } });
        const r1 = try builder.newValue(layout.bool_type);
        try builder.emit(.{ .call = .{ .dst = r1, .callee = actor_step, .args = try dupeOne(builder.module, frame1b) } });
        try builder.emit(.{ .store_local = .{ .local = done1_local, .src = r1 } });
        builder.terminate(.{ .jump = .{ .target = after_block } });

        builder.setCurrentBlock(skip_block);
        builder.terminate(.{ .jump = .{ .target = after_block } });

        builder.setCurrentBlock(after_block);
    }
}

pub fn expand(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, frame_info: *const std.AutoHashMap(mir.FunctionId, mir_cps.FrameInfo)) !void {
    if (frame_info.count() == 0) return;

    const start_id = findFunctionByName(module, "старт") orelse return unsupported("модуль без функции старт()");
    const start_info = frame_info.get(start_id) orelse return unsupported("старт() должен вызывать получить() хотя бы раз, чтобы использовать акторы (Phase 1)");

    // Locate the single `.spawn` inside старт's (already CPS-rewritten)
    // body, and its target — Phase 1's one supported shape.
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

    const layout = Layout{ .ptr_type = type_store.builtins.string, .idx_type = type_store.builtins.boolean, .bool_type = type_store.builtins.boolean };

    const runtime = try buildRuntime(allocator, module, type_store, layout);
    rewireSuspendCalls(module, runtime);

    // старт's own frame gains one EXTRA slot (beyond what `mir_cps.zig`
    // already sized it to) purely for `wasm_actors.zig`'s own bookkeeping
    // — the spawned child's frame pointer, which the user's own `пер proc
    // = запусти ...` local (already a normal frame slot) also holds, but
    // under a slot number this pass doesn't otherwise know without deeper
    // analysis. Simpler to reserve a dedicated one.
    const child_frame_slot = start_info.total_slots;
    const old_start_total_slots = start_info.total_slots + 1;

    {
        var builder = mir_builder.Builder{ .module = module, .allocator = allocator, .function_id = start_id };
        const frame_local: mir.LocalId = @enumFromInt(0); // `mir_cps.zig` always makes the frame pointer local 0
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
            try expandSend(allocator, &builder, target.block, target.index, layout);
            index += 1;
            if (index > 1000) return unsupported("слишком много отправить (возможный баг развёртки)");
        }
    }

    const original_result_type = start_function.result_type; // already rewritten to Булево by mir_cps — see below
    _ = original_result_type;
    // The TRUE original return type isn't recoverable from `result_type`
    // any more (`mir_cps.zig` already overwrote it) — `FrameInfo` doesn't
    // carry it either (Phase-1 gap: assumed `Число` here, matching every
    // fixture this backend currently targets). A real fix threads the
    // pre-rewrite type through `FrameInfo` instead of guessing.
    try buildScheduler(allocator, module, type_store, layout, start_id, old_start_total_slots, child_frame_slot, actor_id, type_store.builtins.number);
}
