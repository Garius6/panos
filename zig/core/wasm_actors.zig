const std = @import("std");
const mir = @import("mir.zig");
const mir_builder = @import("mir_builder.zig");
const mir_cps = @import("mir_cps.zig");
const types = @import("types.zig");
const source = @import("source.zig");
const symbols = @import("symbols.zig");
const wasm_module = @import("wasm_module.zig");
const wasm_heap = @import("wasm_heap.zig");

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

// --- Generic runtime functions ----------------------------------------

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

// `payload_type` — pop must be built once per WASM value category (i32
// handle vs f64 number), since a plain WASM function has ONE fixed
// result type and message payloads vary by actor (see the file doc
// comment's `mailbox_pop_f64`/`_i32` split).
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
    const head_local = try wasm_heap.storeLocal(&builder, "head", layout.idx_type, head); // used twice below (addr math, head+1)

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

    // dst = alloc(target_total_slots * 8) — reuses the ORIGINAL dst
    // ValueId directly, so every later instruction that already expects
    // "the spawn result" keeps working unmodified.
    builder.setCurrentBlock(block_id);
    builder.currentFunction().block(block_id).instructions = replacement;
    builder.terminated = false;

    const size_const = try wasm_heap.addressConst(builder, layout.idx_type, target_total_slots * 8);
    // Guaranteed already built — `expand()` calls `buildRuntime` (which
    // creates it) before `expandSpawn` ever runs.
    const alloc_id = wasm_heap.findFunctionByName(builder.module, wasm_heap.alloc_function_name).?;
    try builder.emit(.{ .call = .{ .dst = dst, .callee = alloc_id, .args = try wasm_heap.dupeOne(builder.module, size_const) } });
    // `dst` is used below for EVERY arg's `frame_store`, the child-slot
    // stash, AND possibly further downstream (the user's own `пер proc =
    // запусти ...`) — single-use invariant, same fix as `mir_cps.zig`'s
    // `Redirect`: store once, reload fresh at each use.
    const dst_local = try wasm_heap.storeLocal(builder, "@spawned", layout.ptr_type, dst);

    // Iterate args in REVERSE. `args` are all PRE-EXISTING values
    // (`.spawn`'s own arguments, each evaluated adjacent to the
    // ORIGINAL, unexpanded `.spawn` instruction, in order) — by the
    // time this loop runs they're ALL already sitting on the real WASM
    // stack in production order, with the LAST arg topmost. Storing
    // arg 0 first (ascending) would grab the wrong (topmost, last-
    // produced) value as `src` — same bug class already found and fixed
    // in `wasm_objects.zig`'s `build_variant`/`new_aggregate` field
    // loops (`888a0c0`). Never exercised until now since every actor
    // fixture built so far spawns a function with 0 or 1 parameters —
    // 2+ genuinely needs this fix.
    var ai = args.len;
    while (ai > 0) {
        ai -= 1;
        const dst_for_arg = try wasm_heap.loadLocal(builder, dst_local, layout.ptr_type);
        try builder.emit(.{ .frame_store = .{ .frame = dst_for_arg, .slot = mir_cps.frame_prefix_slots + @as(u32, @intCast(ai)), .src = args[ai] } });
    }

    // `src` computed BEFORE `frame` — see `wasm_emit.zig`'s
    // `EmitContext.frame_store_scratch_frame` doc comment (stack order
    // `frame_store` codegen expects is `[src, frame]`).
    const dst_for_stash = try wasm_heap.loadLocal(builder, dst_local, layout.ptr_type);
    const own_frame = try wasm_heap.frameValue(builder, frame_local, layout.ptr_type);
    try builder.emit(.{ .frame_store = .{ .frame = own_frame, .slot = child_frame_slot, .src = dst_for_stash } });

    // Downstream instructions (the user's own code after `запусти ...`,
    // e.g. `пер proc = ...`) may reference `dst` too — redirect exactly
    // like `mir_cps.zig`'s suspend-point handling does.
    //
    // `.frame_store` needs special handling here, not just a blind
    // substitute: by the time `expandSpawn` runs (AFTER `mir_cps.
    // prepare`), the user's `пер proc = запусти ...` has ALREADY been
    // rewritten by `mir_cps.zig`'s own `.store_local` case into
    // `load_local{dst=F,local=frame_local}` (frame pointer reload,
    // emitted FIRST, unchanged by the substitution below since it
    // doesn't reference `dst`) followed by `frame_store{frame=F,...,
    // src=dst}`. A blind substitute here inserts a FRESH `loadLocal
    // (dst_local)` for `src` right before the (rewritten) frame_store —
    // making `src` the freshest value, with `frame`(F) produced earlier/
    // buried — backwards from `frame_store` codegen's `[src, frame]`
    // convention (frame must be freshest). Confirmed via wasmtime: `proc`
    // ended up reading garbage (0) instead of the real spawned handle,
    // since the write actually happened at the WRONG address. Fix:
    // detect this exact `load_local(frame_local)` + `frame_store{src=
    // dst}` pair and re-synthesize it in the correct order — dropping
    // the stale frame reload (now dead) and emitting a fresh one AFTER
    // the fresh src reload.
    var ti: usize = 0;
    const tail = original.instructions.items[spawn_index + 1 ..];
    while (ti < tail.len) : (ti += 1) {
        const tail_instruction = tail[ti];
        // Lookahead: is THIS a frame-pointer reload whose sole purpose
        // (per mir_cps.zig's `.store_local` rewrite) is feeding the VERY
        // NEXT instruction's `frame_store{src=dst}`? If so, DON'T emit
        // it — its value would be dead-but-unconsumed once the next
        // iteration re-synthesizes a fresh one in the correct order.
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
    // `.deinit`, not `allocator.free(.items)` — see `mir_cps.zig`'s
    // identical comment on its own equivalent free.
    original.instructions.deinit(allocator);
}

// Rewrites the SINGLE `.send` in place: pushes `message` into `process`'s
// mailbox ring buffer.
fn expandSend(
    allocator: std.mem.Allocator,
    builder: *mir_builder.Builder,
    block_id: mir.BlockId,
    send_index: usize,
    layout: wasm_heap.PtrLayout,
) !void {
    const function = builder.currentFunction();
    var original = function.blockConst(block_id).*;
    const send = original.instructions.items[send_index].send;

    var prefix: std.ArrayList(mir.Instruction) = .empty;
    try prefix.appendSlice(allocator, original.instructions.items[0..send_index]);

    builder.setCurrentBlock(block_id);
    builder.currentFunction().block(block_id).instructions = prefix;
    builder.terminated = false;

    // `send.process` and `send.message` are BOTH pre-existing values
    // (`отправить(process_expr, message_expr)` evaluates left to right,
    // so `process` is produced FIRST and `message` SECOND/freshest —
    // `message` is very often itself a `build_variant` result, an
    // entire construction sequence deep). Consuming `process` first (the
    // original code's order) blindly popped whatever was ACTUALLY on
    // top of the real WASM stack at that point — `message`, not
    // `process` — since `store_local`'s codegen is just a raw
    // `local.set`, it doesn't care what the MIR's `src` field claims,
    // only what's really on top. Confirmed via wasmtime: this silently
    // swapped `message`/`process`. Fix: consume in REVERSE-of-production
    // (LIFO) order, same class of bug already found and fixed in
    // `wasm_objects.zig`'s `build_variant`/`new_aggregate` field loops —
    // store `message` first (it's topmost), THEN `process` (now exposed).
    const message_type = function.valueType(send.message);
    const message_local = try wasm_heap.storeLocal(builder, "@message", message_type, send.message);
    // `process`/`count` are each used more than once below — single-use
    // invariant, same fix as everywhere else in this file: store once,
    // reload fresh per use.
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
    // `eight` produced IMMEDIATELY after `tail` (adjacent — no other
    // value's producer runs between them) so `tail_bytes` consumes
    // exactly `[tail, eight]`, then `base`'s own two operands
    // (`ring_base_bytes`/`process_for_base`) are produced and consumed
    // together right before `addr`'s own add — `tail_bytes` sits safely
    // buried underneath that net-stack-neutral pair the whole time.
    // Originally `eight` was produced between `head` and `count_for_tail`
    // — `.binary`'s i32 codegen does ZERO stack manipulation (just emits
    // the raw opcode, `wasm_emit.zig` ~line 545: assumes `lhs`/`rhs` are
    // ALREADY the top two stack values, pushed back-to-back with nothing
    // interposed) — so the wedged `eight` made `tail_pre`'s `i32.add`
    // silently compute `8 + count` instead of `head + count`, orphaning
    // `head` on the stack to corrupt everything emitted after it.
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
    const alloc_id = wasm_heap.findFunctionByName(module, wasm_heap.alloc_function_name).?;
    try builder.emit(.{ .call = .{ .dst = frame0, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, size0) } });
    // `frame0` used more than once below — store once, reload fresh per use.
    const frame0_local = try wasm_heap.storeLocal(&builder, "frame0", layout.ptr_type, frame0);
    // `src` computed BEFORE `frame` — see `wasm_emit.zig`'s
    // `EmitContext.frame_store_scratch_frame` doc comment (stack order
    // `frame_store` codegen expects is `[src, frame]`).
    const zero_addr = try wasm_heap.addressConst(&builder, layout.ptr_type, 0);
    const frame0_for_init = try wasm_heap.loadLocal(&builder, frame0_local, layout.ptr_type);
    try builder.emit(.{ .frame_store = .{ .frame = frame0_for_init, .slot = child_frame_slot, .src = zero_addr } });
    const done0_local = try builder.newLocal(wasm_heap.dummy_symbol, "done0", layout.bool_type);
    const done1_local = try builder.newLocal(wasm_heap.dummy_symbol, "done1", layout.bool_type);
    const false0 = try wasm_heap.boolConst(&builder, layout.bool_type, false);
    try builder.emit(.{ .store_local = .{ .local = done0_local, .src = false0 } });
    // process 1 (the spawned actor) doesn't exist until process 0's own
    // step function reaches its `.spawn` — `emitSchedulerRound`'s own
    // `spawned` check (frame pointer at `child_frame_slot` non-zero)
    // already gates against running it before that point, so `done1`
    // itself must start `false`: initializing it `true` here meant
    // `not_done1` was permanently `false`, so `should_run = spawned AND
    // not_done1` could NEVER become true even after spawning — process 1
    // never ran a single step, ever. Confirmed via wasmtime: the actor
    // round-trip compiled and ran without trapping/crashing but always
    // returned the receiver's zero-initialized mailbox slot instead of
    // the real reply, because the reply was never actually produced.
    const false1 = try wasm_heap.boolConst(&builder, layout.bool_type, false);
    try builder.emit(.{ .store_local = .{ .local = done1_local, .src = false1 } });

    var round: u32 = 0;
    while (round < scheduler_rounds) : (round += 1) {
        try emitSchedulerRound(&builder, allocator, layout, frame0_local, done0_local, done1_local, old_start, actor_step, child_frame_slot);
    }

    // Termination only waits on `done0` (`старт`, the "main" process) —
    // NOT `done1` (the spawned background actor) too. A spawned actor is
    // routinely a persistent server that loops forever by design (this
    // fixture's own `счётчик`: every `получить()` immediately recurses
    // into another `получить()`, never actually returning) — requiring
    // it to ALSO finish before the program can end made every such
    // (entirely normal, "fire and forget" background actor) program
    // trap on "превышен лимит раундов" after `старт` had already
    // produced its real result. `старт` finishing is what the program's
    // own result depends on; a still-suspended background actor at that
    // point is ordinary, expected actor semantics, not an error.
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
    layout: wasm_heap.PtrLayout,
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
        const not_done0 = try wasm_heap.notOp(builder, layout.bool_type, d0);
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
        const frame0 = try wasm_heap.frameValue(builder, frame0_local, layout.ptr_type);
        const r0 = try builder.newValue(layout.bool_type);
        try builder.emit(.{ .call = .{ .dst = r0, .callee = old_start, .args = try wasm_heap.dupeOne(builder.module, frame0) } });
        try builder.emit(.{ .store_local = .{ .local = done0_local, .src = r0 } });
        builder.terminate(.{ .jump = .{ .target = after_block } });

        builder.setCurrentBlock(skip_block);
        builder.terminate(.{ .jump = .{ .target = after_block } });

        builder.setCurrentBlock(after_block);
    }
    // Process 1 (the spawned actor) — only if spawned (frame pointer
    // non-zero) AND not already done.
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
        const skip_block = try builder.newBlock(); // see the `Process 0` comment above — must be distinct from `after_block`
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

    const layout = wasm_heap.PtrLayout{ .ptr_type = type_store.builtins.string, .idx_type = type_store.builtins.boolean, .bool_type = type_store.builtins.boolean };

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
