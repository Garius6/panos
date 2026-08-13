const mir = @import("mir.zig");
const mir_builder = @import("mir_builder.zig");
const types = @import("types.zig");
const std = @import("std");

pub const SuspendPoint = struct {
    function: mir.FunctionId,
    block: mir.BlockId,
    instruction_index: u32,
    resume_state: u32,
};

pub const ResumeEdge = struct {
    state: u32,
    suspend_block: mir.BlockId,
    resume_block: mir.BlockId,
};

pub const FrameLayout = struct {
    function: mir.FunctionId,
    locals: []const mir.LocalId,
};

pub const FunctionPlan = struct {
    function: mir.FunctionId,
    frame: FrameLayout,
    suspend_points: []const SuspendPoint,
    resume_edges: []const ResumeEdge,
};

// Fixed frame-prefix layout, IDENTICAL for every actor frame regardless
// of the owning function's own locals/suspend-point count — this is what
// lets `wasm_actors.zig` implement mailbox_has/pop/signal_has/pop/result
// access ONCE, generically, as ordinary MIR functions taking a bare frame
// pointer, instead of needing one specialized per actor function.
pub const mailbox_cap: u32 = 4;
pub const signal_cap: u32 = 2;
pub const state_slot: u32 = 0;
pub const mailbox_count_slot: u32 = 1;
pub const mailbox_head_slot: u32 = 2;
pub const mailbox_ring_base: u32 = 3;
pub const signal_count_slot: u32 = mailbox_ring_base + mailbox_cap;
pub const signal_head_slot: u32 = signal_count_slot + 1;
pub const signal_ring_base: u32 = signal_head_slot + 1;
// Holds the function's REAL return value (whatever `Тип` it originally
// declared) once it actually completes — the function's own WASM result
// type is overridden to `Булево` (done/still-suspended status, see
// `rewriteFunction`), so the real value can't travel through the normal
// WASM return channel any more; the scheduler reads it from here after
// seeing `done`.
pub const result_slot: u32 = signal_ring_base + signal_cap;
pub const frame_prefix_slots: u32 = result_slot + 1;

// Per-function sizing `wasm_actors.zig`'s `.spawn` expansion needs to
// allocate and initialize a fresh frame: how many bytes to bump-allocate,
// and how many of the callee's original parameters must be copied in
// (positionally, slots `[frame_prefix_slots, frame_prefix_slots +
// param_count)`) from `.spawn`'s own `args`.
pub const FrameInfo = struct {
    param_count: u32,
    total_slots: u32,
};

// Groups the two analyses into the exact unit the rewrite consumes: one
// function, one durable frame, and monotonically numbered resume states.
pub fn plans(allocator: std.mem.Allocator, module: *const mir.Module) !std.ArrayList(FunctionPlan) {
    var all_points = try collectSuspendPoints(allocator, module);
    defer all_points.deinit(allocator);
    var layouts = try frameLayouts(allocator, module);
    errdefer {
        for (layouts.items) |layout| allocator.free(layout.locals);
        layouts.deinit(allocator);
    }
    var out: std.ArrayList(FunctionPlan) = .empty;
    errdefer out.deinit(allocator);
    for (layouts.items) |layout| {
        var count: usize = 0;
        for (all_points.items) |point| {
            if (point.function == layout.function) count += 1;
        }
        const points = try allocator.alloc(SuspendPoint, count);
        const edges = try allocator.alloc(ResumeEdge, count);
        var at: usize = 0;
        for (all_points.items) |point| {
            if (point.function == layout.function) {
                points[at] = point;
                // The mutating phase splits this block immediately after
                // the receive and replaces this placeholder with the new
                // continuation block id.
                edges[at] = .{ .state = point.resume_state, .suspend_block = point.block, .resume_block = mir.invalid_block };
                at += 1;
            }
        }
        try out.append(allocator, .{ .function = layout.function, .frame = layout, .suspend_points = points, .resume_edges = edges });
    }
    // ownership of locals moved into `out`.
    layouts.clearRetainingCapacity();
    layouts.deinit(allocator);
    return out;
}

pub fn deinitPlans(allocator: std.mem.Allocator, value: *std.ArrayList(FunctionPlan)) void {
    for (value.items) |plan| {
        allocator.free(plan.frame.locals);
        allocator.free(plan.suspend_points);
        allocator.free(plan.resume_edges);
    }
    value.deinit(allocator);
}

// All MIR locals are frame slots for a suspending function. This is larger
// than liveness-minimal spilling, but gives the first CPS backend a simple,
// correct invariant: any value that was materialized into a local survives
// every receive/resume boundary.
pub fn frameLayouts(allocator: std.mem.Allocator, module: *const mir.Module) !std.ArrayList(FrameLayout) {
    var layouts: std.ArrayList(FrameLayout) = .empty;
    errdefer layouts.deinit(allocator);
    for (module.functions.items) |function| {
        var suspends = false;
        for (function.blocks.items) |block| for (block.instructions.items) |instruction| switch (instruction) {
            .receive, .receive_signal => suspends = true,
            else => {},
        };
        if (!suspends) continue;
        const locals = try allocator.alloc(mir.LocalId, function.locals.items.len);
        for (locals, 0..) |*slot, index| slot.* = @enumFromInt(index);
        try layouts.append(allocator, .{ .function = function.id, .locals = locals });
    }
    return layouts;
}

// This scan is the stable input to the mutating CPS rewrite. State zero is
// normal entry; every receive-like instruction gets one later resume state.
pub fn collectSuspendPoints(allocator: std.mem.Allocator, module: *const mir.Module) !std.ArrayList(SuspendPoint) {
    var points: std.ArrayList(SuspendPoint) = .empty;
    errdefer points.deinit(allocator);
    var next_state: u32 = 1;
    for (module.functions.items) |function| for (function.blocks.items) |block| {
        for (block.instructions.items, 0..) |instruction, index| switch (instruction) {
            .receive, .receive_signal => {
                try points.append(allocator, .{ .function = function.id, .block = block.id, .instruction_index = @intCast(index), .resume_state = next_state });
                next_state += 1;
            },
            else => {},
        };
    };
    return points;
}

// CPS phase boundary. It is deliberately separate from AST lowering: the
// pass will turn spawn/receive into resumable process frames before WASM
// emission, preserving the regular MIR for non-suspending functions.
pub fn hasActorInstructions(module: *const mir.Module) bool {
    for (module.functions.items) |function| for (function.blocks.items) |block|
        for (block.instructions.items) |instruction| switch (instruction) {
            .spawn, .send, .receive, .receive_signal => return true,
            else => {},
        };
    return false;
}

// Unlike `hasActorInstructions`, still true AFTER `wasm_actors.zig` has
// run — `.expand()` rewrites away every `.spawn`/`.send`/`.receive`/
// `.receive_signal` into `frame_load`/`frame_store`/`global_get`/
// `global_set`/`mem_load`/`mem_store`, so by the time `wasm_emit.zig`'s
// `emitModule` runs, `hasActorInstructions` alone would (WRONGLY) report
// no actor code at all — found by actually running the full pipeline:
// `emitModule` skipped the memory/global sections entirely and wasmtime
// rejected the module ("unknown memory 0") the moment a function tried
// to use one of those instructions. These five are exclusively
// `mir_cps.zig` output — never emitted by ordinary `mir_lowering.zig`
// lowering — so their presence is an unambiguous "this module needs the
// actor heap/global" signal.
pub fn usesActorMemory(module: *const mir.Module) bool {
    for (module.functions.items) |function| for (function.blocks.items) |block|
        for (block.instructions.items) |instruction| switch (instruction) {
            .frame_load, .frame_store, .global_get, .global_set, .mem_load, .mem_store, .mem_load8, .mem_store8 => return true,
            else => {},
        };
    return false;
}

// --- Mutating rewrite ------------------------------------------------
//
// Turns a suspend-capable function's LOCALS from ordinary WASM locals
// (reset to zero on every fresh call — useless across a suspend, which is
// by definition a SEPARATE later call into the function) into slots inside
// an opaque, caller-allocated frame blob living in WASM linear memory
// (`wasm_actors.zig` owns the actual allocator — this pass only assigns
// LOGICAL slot numbers, never byte offsets). After rewrite:
//
//   - The function has exactly ONE real local/parameter left: the frame
//     pointer itself (opaque i32 handle — see `ptr_type`'s own comment
//     below for why it's typed the way it is).
//   - The function's OWN result type becomes `Булево` — `true` = really
//     finished (the real value, if any, is in the frame's `result_slot`),
//     `false` = suspended (call again once the mailbox/signal is ready).
//     This is what lets a plain WASM `call` (no exceptions/multi-value
//     tricks) tell the scheduler apart from a genuine completion,
//     INCLUDING a genuine `Пусто` one — seeread `result_slot`'s comment.
//   - Every ORIGINAL local (index 0..N-1) becomes frame slot
//     `[frame_prefix_slots, frame_prefix_slots + N)` — `load_local`/
//     `store_local` become `frame_load`/`frame_store` at that same
//     (offset) slot number.
//   - Slot `frame_prefix_slots + N` is the resume-dispatch state (0 =
//     fresh start, K = "resume right after suspend point K") — NOT
//     `state_slot`, which is a DIFFERENT, always-zero slot the scheduler
//     itself never touches; kept for symmetry/documentation only, actual
//     dispatch uses the function-relative slot computed below.
//   - Slots `[frame_prefix_slots + N + 1, frame_prefix_slots + N + 1 + S)`
//     hold each suspend point's OWN received value (`получить()`'s/
//     `получить_сигнал()`'s own `dst`) — the ONE value ALWAYS guaranteed
//     to be live across its own suspend boundary (the overwhelmingly
//     common `выбор получить() ... конец` shape uses it immediately as
//     the match scrutinee, never through a named local at all). This is
//     a REAL, explicitly accepted Phase-1 gap beyond what `frameLayouts`'s
//     "every local" policy alone covers: a value computed BEFORE a
//     receive from something OTHER than a local and used AFTER it
//     (bypassing both a local binding and the receive's own dst) is NOT
//     preserved — bind it to `пер` first. General cross-suspend liveness
//     analysis is Phase 2+.
//
// Each `.receive`/`.receive_signal` becomes a mailbox/signal check
// (`@runtime::mailbox_has`/`@runtime::signal_has`, real in-module
// functions `wasm_actors.zig` builds against the fixed prefix layout
// above — NOT host imports, this must run under plain wasmtime with no
// new host code) — empty means save state and `.suspend_return`; non-empty
// means pop (`@runtime::mailbox_pop`/`@runtime::signal_pop`) and fall
// straight through, mirroring the native VM's ip-rollback suspend
// contract (`vm.zig`'s `runProcessSlice`) semantically, reimplemented for
// WASM's structured (no goto) control flow instead of a bytecode
// instruction pointer.

fn frameValue(builder: *mir_builder.Builder, frame_local: mir.LocalId, ptr_type: anytype) !mir.ValueId {
    // Reloaded fresh at every use site, never cached across blocks — a
    // WASM local is always safely re-readable from any block in its own
    // function, sidestepping any cross-block SSA-liveness question this
    // rewrite would otherwise have to answer for a single shared value.
    const dst = try builder.newValue(ptr_type);
    try builder.emit(.{ .load_local = .{ .dst = dst, .local = frame_local } });
    return dst;
}

fn intConstant(builder: *mir_builder.Builder, ptr_type: anytype, value: u32) !mir.ValueId {
    // Real i32 literal (`mir.ConstValue.address`) — resume-state tags and
    // frame/heap pointers are never meant to be a user-visible `Число`,
    // so this skips `.number`'s f64 representation entirely.
    const dst = try builder.newValue(ptr_type);
    try builder.emit(.{ .const_value = .{ .dst = dst, .value = .{ .address = value } } });
    return dst;
}

const SuspendKind = struct {
    has: []const u8,
    pop: []const u8,
};

fn suspendKind(instruction: mir.Instruction) ?SuspendKind {
    return switch (instruction) {
        .receive => .{ .has = "@runtime::mailbox_has", .pop = "@runtime::mailbox_pop" },
        .receive_signal => .{ .has = "@runtime::signal_has", .pop = "@runtime::signal_pop" },
        else => null,
    };
}

fn suspendDst(instruction: mir.Instruction) ?mir.ValueId {
    return switch (instruction) {
        .receive => |r| r.dst,
        .receive_signal => |r| r.dst,
        else => null,
    };
}

fn rewriteOrdinaryInstruction(builder: *mir_builder.Builder, instruction: mir.Instruction, frame_local: mir.LocalId, ptr_type: anytype) !void {
    switch (instruction) {
        .load_local => |load| {
            const frame = try frameValue(builder, frame_local, ptr_type);
            try builder.emit(.{ .frame_load = .{ .dst = load.dst, .frame = frame, .slot = frame_prefix_slots + @intFromEnum(load.local) } });
        },
        .store_local => |store| {
            const frame = try frameValue(builder, frame_local, ptr_type);
            try builder.emit(.{ .frame_store = .{ .frame = frame, .slot = frame_prefix_slots + @intFromEnum(store.local), .src = store.src } });
        },
        else => try builder.emit(instruction),
    }
}

// Applies to whatever terminator a rewritten instruction stream ends
// with (whether or not it ever hit a suspend point) — the ONLY place a
// suspend-capable function's control flow may leave the function for
// real. `.return_value{null}`/`{value}` becomes: (optionally) stash the
// real value in `result_slot`, then `return_value{true}` (done).
// `.jump`/`.branch`/`.unreachable_term` pass through unchanged (they
// stay INSIDE the function, no frame/status bookkeeping needed).
// `.none`/`.suspend_return` can't legally appear in a pre-rewrite
// function body and are asserted against.
// `instruction`, if it's a call (direct `.call` or `function_ref`+
// `.call_value`) to `self_function`, returns its args — `preceding` is
// searched backward for the `function_ref` a `.call_value.callee`
// resolves through (same convention `wasm_emit.zig`'s own
// `value_to_function` map relies on).
fn selfCallArgs(instruction: mir.Instruction, preceding: []const mir.Instruction, self_function: mir.FunctionId) ?[]const mir.ValueId {
    switch (instruction) {
        .call => |c| return if (c.callee == self_function) c.args else null,
        .call_value => |c| {
            var i = preceding.len;
            while (i > 0) {
                i -= 1;
                if (preceding[i] == .function_ref and preceding[i].function_ref.dst == c.callee) {
                    return if (preceding[i].function_ref.function == self_function) c.args else null;
                }
            }
            return null;
        },
        else => return null,
    }
}

fn rewriteReturnTerminator(builder: *mir_builder.Builder, frame_local: mir.LocalId, ptr_type: anytype, bool_type: anytype, terminator: mir.Terminator) !mir.Terminator {
    switch (terminator) {
        .return_value => |ret| {
            if (ret.value) |value| {
                const frame = try frameValue(builder, frame_local, ptr_type);
                try builder.emit(.{ .frame_store = .{ .frame = frame, .slot = result_slot, .src = value } });
            }
            const done = try builder.newValue(bool_type);
            try builder.emit(.{ .const_value = .{ .dst = done, .value = .{ .boolean = true } } });
            return .{ .return_value = .{ .value = done } };
        },
        .jump, .branch, .unreachable_term => return terminator,
        .none, .suspend_return => unreachable,
    }
}

pub fn prepare(allocator: std.mem.Allocator, module: *mir.Module) !std.AutoHashMap(mir.FunctionId, FrameInfo) {
    var frame_info: std.AutoHashMap(mir.FunctionId, FrameInfo) = .init(allocator);
    errdefer frame_info.deinit();
    if (!hasActorInstructions(module)) return frame_info;
    var actor_plans = try plans(module.arena.allocator(), module);
    defer deinitPlans(module.arena.allocator(), &actor_plans);
    for (actor_plans.items) |plan| {
        const info = try rewriteFunction(allocator, module, plan);
        try frame_info.put(plan.function, info);
    }
    return frame_info;
}

fn rewriteFunction(allocator: std.mem.Allocator, module: *mir.Module, plan: FunctionPlan) !FrameInfo {
    const function_index: usize = @intFromEnum(plan.function);
    const type_store = module.functions.items[function_index].type_store orelse return error.MissingTypeStore;
    // Need a type that maps to a real WASM i32
    // (`wasm_module.wasmValTypeForStore`) — required, not cosmetic:
    // `frame_load`/`frame_store` codegen emits raw `i32.add` for the
    // slot-offset arithmetic assuming the frame value is ALREADY i32 on
    // the stack (`Целое` would be f64, Phase-1a's numeric convention,
    // producing an invalid module). `Type.process` would need a NEW
    // entry via the mutating `TypeStore.process(payload)` constructor —
    // wrong tool this late in compilation for a plain opaque-handle
    // marker. `builtins.string` already maps to i32 and is guaranteed to
    // exist in every `TypeStore`; reused here purely as "opaque i32
    // handle", never through any string-specific codegen path (no
    // `.binary` add, no property/index access — every frame-pointer
    // operation goes through `frame_load`/`frame_store`/`.address`
    // consts, none of which special-case this type).
    const ptr_type = type_store.builtins.string;
    const bool_type = type_store.builtins.boolean;

    const original_param_count: u32 = @intCast(module.functions.items[function_index].parameters.len);
    const original_local_count: u32 = @intCast(module.functions.items[function_index].locals.items.len);
    const local_state_slot: u32 = frame_prefix_slots + original_local_count;
    const message_slot_base: u32 = local_state_slot + 1;
    const total_slots: u32 = message_slot_base + @as(u32, @intCast(plan.suspend_points.len));

    // Snapshot BEFORE any mutation — `plan.suspend_points`/`.block`/
    // `.instruction_index` describe the function as it was when `plans`
    // ran, and every subsequent split/rewrite below is keyed off this
    // frozen list, never re-derived mid-rewrite.
    const original_blocks = try allocator.alloc(mir.BlockId, module.functions.items[function_index].blocks.items.len);
    for (original_blocks, 0..) |*id, i| id.* = @enumFromInt(i);
    defer allocator.free(original_blocks);
    const original_entry = module.functions.items[function_index].entry;

    // Step 1: replace `.locals`/`.parameters`/`.result_type` — the frame
    // pointer is the function's ONLY real local/parameter from here on,
    // and its result becomes a plain done/suspended status (see the file
    // doc comment's `result_slot` paragraph).
    const frame_local: mir.LocalId = @enumFromInt(0);
    module.functions.items[function_index].locals.clearRetainingCapacity();
    try module.functions.items[function_index].locals.append(allocator, .{ .id = frame_local, .symbol = @enumFromInt(0), .name = "@frame", .type_id = ptr_type });
    allocator.free(module.functions.items[function_index].parameters);
    const new_parameters = try allocator.alloc(mir.LocalId, 1);
    new_parameters[0] = frame_local;
    module.functions.items[function_index].parameters = new_parameters;
    module.functions.items[function_index].result_type = bool_type;

    var builder = mir_builder.Builder{ .module = module, .allocator = allocator, .function_id = plan.function };

    // Entry dispatch's id is reserved NOW (content filled in later, step
    // 3) so a self-tail-call (found while splitting, step 2) can target
    // it directly. This matters, not just convenience: jumping straight
    // to `original_entry` instead would give that block TWO incoming
    // edges from unrelated places (the dispatch's own "fresh start"
    // fallback, AND the tail-call's own loop-back) with NEITHER being
    // the block wasm_stackify treats as the function's entry — an
    // irreducible-looking shape it can't reconstruct (found by actually
    // running it and hitting unbounded recursion in `wasm_stackify.zig`,
    // not by reading alone). Routing the tail-call through
    // `dispatch_entry` instead makes it the loop's sole header — the
    // ONE block with an incoming edge from outside the function AND from
    // the back-edge, exactly the shape ordinary structured control flow
    // already knows how to fold into a real WASM `loop`.
    const dispatch_entry = try builder.newBlock();

    // Step 2: rewrite + split every ORIGINAL block. A suspend point's
    // resume block id is only known once we actually build it — recorded
    // here so step 3 (entry dispatch) can jump straight to it.
    var resume_blocks = std.AutoHashMap(u32, mir.BlockId).init(allocator);
    defer resume_blocks.deinit();

    for (original_blocks) |block_id| {
        try splitBlockAtSuspends(&builder, allocator, block_id, plan, frame_local, ptr_type, bool_type, local_state_slot, message_slot_base, &resume_blocks, dispatch_entry, plan.function);
    }

    // Step 3: entry dispatch — branching on `frame.state`: 0 -> the
    // (rewritten) original entry block, K -> suspend point K's resume
    // block.
    module.functions.items[function_index].entry = dispatch_entry;
    try emitDispatch(&builder, dispatch_entry, frame_local, ptr_type, local_state_slot, plan.suspend_points, &resume_blocks, original_entry);

    return .{ .param_count = original_param_count, .total_slots = total_slots };
}

// One `.equal` compare + `.branch` per candidate state, chained through
// fresh blocks — a linear scan, not a jump table (`br_table`'s WASM
// encoding needs a dense, compile-time-known range; Phase 1 has no more
// than a handful of suspend points per function, so the linear form is
// simplest and cheap enough — revisit only if profiling ever says
// otherwise).
fn emitDispatch(
    builder: *mir_builder.Builder,
    entry: mir.BlockId,
    frame_local: mir.LocalId,
    ptr_type: anytype,
    local_state_slot: u32,
    suspend_points: []const SuspendPoint,
    resume_blocks: *const std.AutoHashMap(u32, mir.BlockId),
    original_entry: mir.BlockId,
) !void {
    var current = entry;
    for (suspend_points) |point| {
        builder.setCurrentBlock(current);
        const frame = try frameValue(builder, frame_local, ptr_type);
        const state = try builder.newValue(ptr_type);
        try builder.emit(.{ .frame_load = .{ .dst = state, .frame = frame, .slot = local_state_slot } });
        const target_const = try intConstant(builder, ptr_type, point.resume_state);
        const is_this_state = try builder.newValue(builder.currentFunction().type_store.?.builtins.boolean);
        try builder.emit(.{ .compare = .{ .dst = is_this_state, .op = .equal, .lhs = state, .rhs = target_const } });
        const resume_block = resume_blocks.get(point.resume_state) orelse return error.MissingResumeBlock;
        const next = try builder.newBlock();
        builder.terminate(.{ .branch = .{ .cond = is_this_state, .then_block = resume_block, .else_block = next } });
        current = next;
    }
    // Nothing matched — state must be 0 (fresh start).
    builder.setCurrentBlock(current);
    builder.terminate(.{ .jump = .{ .target = original_entry } });
}

// Splits `block_id` at every `.receive`/`.receive_signal` it contains, in
// order. The block keeps its own id for its FIRST segment (every other
// block's Jump/Branch targeting it stays valid unchanged); later segments
// are fresh blocks. Ordinary instructions are frame-ified in place
// (`load_local`/`store_local` -> `frame_load`/`frame_store`) as they're
// copied across; the ORIGINAL terminator, once no more suspend points
// remain in the stream, is rewritten via `rewriteReturnTerminator`.
fn splitBlockAtSuspends(
    builder: *mir_builder.Builder,
    allocator: std.mem.Allocator,
    block_id: mir.BlockId,
    plan: FunctionPlan,
    frame_local: mir.LocalId,
    ptr_type: anytype,
    bool_type: anytype,
    local_state_slot: u32,
    message_slot_base: u32,
    resume_blocks: *std.AutoHashMap(u32, mir.BlockId),
    original_entry: mir.BlockId,
    self_function: mir.FunctionId,
) !void {
    const function = builder.currentFunction();
    const original = function.blockConst(block_id).*;
    const original_instructions = try allocator.dupe(mir.Instruction, original.instructions.items);
    defer allocator.free(original_instructions);
    const original_terminator = original.terminator;
    // `.deinit`, NOT `allocator.free(.items)` — `.items` is `ptr[0..len]`,
    // but the REAL allocation is `ptr[0..capacity]`
    // (`ArrayList.allocatedSlice()`); freeing the shorter `.items` slice
    // directly hands a debug allocator a length that doesn't match its
    // own bucket bookkeeping and panics ("Invalid free") the moment
    // `len != capacity` — found by actually running a real multi-
    // instruction block through this, not by reading alone.
    function.block(block_id).instructions.deinit(allocator);
    function.block(block_id).instructions = .empty;

    builder.setCurrentBlock(block_id);
    builder.terminated = false;

    try rewriteInstructionStream(
        builder,
        allocator,
        original_instructions,
        0,
        block_id,
        plan,
        frame_local,
        ptr_type,
        bool_type,
        local_state_slot,
        message_slot_base,
        resume_blocks,
        original_terminator,
        &.{},
        original_entry,
        self_function,
    );
}

// Shared implementation for both the FIRST segment of an original block
// (`splitBlockAtSuspends`) and every segment AFTER a split
// (`rewriteRemainingInstructions`'s old separate copy) — unified here so
// there's exactly one place that decides "found a suspend -> split" vs
// "ran out of instructions -> apply the (rewritten) original terminator".
// A receive's own `dst`, once resumed, is redirected to an ordinary WASM
// local (NOT a repeated `frame_load` from `message_slot`) — the same
// value can't be handed to two-or-more later instructions directly (the
// single-use invariant `mir_validate.zig` enforces: a `ValueId` is a
// stack value, consumed once), so every later REFERENCE gets its OWN
// fresh `load_local` from this local instead. Found by actually running
// `mir_validate.zig` over real output (`Сообщение.Вариант(a, b)` binds
// TWO fields off the same `получить()` result — `match_tag`'s subject
// AND two `get_variant_field`s all reference the receive's `dst`, three
// separate uses that a single shared replacement value can't satisfy).
pub const Redirect = struct { old: mir.ValueId, local: mir.LocalId, type_id: types.TypeId };

fn rewriteInstructionStream(
    builder: *mir_builder.Builder,
    allocator: std.mem.Allocator,
    instructions: []const mir.Instruction,
    start_index: usize,
    original_block: mir.BlockId,
    plan: FunctionPlan,
    frame_local: mir.LocalId,
    ptr_type: anytype,
    bool_type: anytype,
    local_state_slot: u32,
    message_slot_base: u32,
    resume_blocks: *std.AutoHashMap(u32, mir.BlockId),
    original_terminator: mir.Terminator,
    redirects: []const Redirect,
    original_entry: mir.BlockId,
    self_function: mir.FunctionId,
) !void {
    var index: usize = start_index;
    while (index < instructions.len) {
        var instruction = instructions[index];
        const kind = suspendKind(instruction);
        if (kind == null) {
            for (redirects) |redirect| {
                if (!referencesValue(instruction, redirect.old)) continue;
                const fresh = try builder.newValue(redirect.type_id);
                try builder.emit(.{ .load_local = .{ .dst = fresh, .local = redirect.local } });
                // Module arena, NOT the `allocator` parameter — a
                // substituted array field gets stored into a PERSISTED
                // instruction living in `module`, so it needs the same
                // module-owned lifetime every other instruction-owned
                // slice in this codebase uses (e.g. `wasm_heap.dupeOne`),
                // not a scratch allocator that may get freed out from
                // under it once this function returns.
                instruction = try substituteValue(builder.module.arena.allocator(), instruction, redirect.old, fresh);
            }

            // Self-tail-call: `функ ф(...) -> Т \n ... \n ф(new_args) \n
            // конец` (panos's own documented actor idiom — see
            // docs/processes.md's `счётчик`) — the recursive call's
            // result flows straight into this function's OWN return, no
            // further use. Compiling it as an ordinary call would be
            // doubly wrong here: (1) the callee's signature was already
            // rewritten to take a frame pointer, not the original args,
            // and (2) even fixed up, a real nested call would grow the
            // WASM call stack for what's semantically an unbounded loop.
            // Instead: write the new arguments into THIS SAME frame's
            // param slots and jump back to the entry-dispatch block —
            // turning recursion into an ordinary single-entry loop at
            // the CFG level, avoiding the irreducible (multi-entry) loop
            // a `получить()` inside a real `пока` produces (found by
            // actually running that shape through `wasm_stackify.zig`
            // and hitting unbounded recursion there, not by reading
            // alone — a `пока`-bodied receive is Phase-2+ until that
            // structured-control-flow gap is closed).
            //
            // A plain-named self-call (`ф(...)`, not `x.ф(...)`) never
            // lowers to a direct `.call` — `mir_lowering.zig` always goes
            // through `function_ref` (recorded earlier in this SAME
            // instruction stream) + `.call_value`, exactly the shape
            // `wasm_emit.zig`'s own `value_to_function` resolves at
            // codegen time (confirmed by actually dumping pre-CPS MIR,
            // not assumed). Detected as "last instruction of this
            // segment, resolves to `self_function`" — deliberately NOT
            // requiring `original_terminator == return_value`: the
            // typical `выбор`/`тогда` compiled shape jumps to a shared
            // join block that just forwards the (here, `Пусто`, unused)
            // result to the real return; being the segment's LAST
            // instruction already rules out anything ELSE meaningful
            // happening on this path, so skipping straight to the loop
            // header instead of visiting that trivial join block is
            // equivalent. A join block that does REAL extra work after
            // a tail-position recursive call is a real, undetected edge
            // case this heuristic accepts for Phase 1.
            if (index == instructions.len - 1) {
                if (selfCallArgs(instruction, instructions[0..index], self_function)) |args| {
                    for (args, 0..) |arg, i| {
                        const frame = try frameValue(builder, frame_local, ptr_type);
                        try builder.emit(.{ .frame_store = .{ .frame = frame, .slot = frame_prefix_slots + @as(u32, @intCast(i)), .src = arg } });
                    }
                    builder.terminate(.{ .jump = .{ .target = original_entry } });
                    return;
                }
            }

            try rewriteOrdinaryInstruction(builder, instruction, frame_local, ptr_type);
            index += 1;
            continue;
        }

        // Found a suspend point — locate its recorded resume_state (the
        // frozen `plan.suspend_points` list is keyed by ORIGINAL block +
        // instruction_index, unaffected by this rewrite since instructions
        // before it are only ever REWRITTEN in place, never reordered or
        // removed).
        var resume_state: ?u32 = null;
        for (plan.suspend_points) |point| {
            if (point.block == original_block and point.instruction_index == index) {
                resume_state = point.resume_state;
                break;
            }
        }
        const state = resume_state orelse return error.UnrecognizedSuspendPoint;
        const dst = suspendDst(instruction).?;
        const message_slot = message_slot_base + (state - 1);
        const function = builder.currentFunction();

        // Mailbox/signal check — lives in its OWN block (`recheck_block`),
        // not inlined into whatever block was current when this suspend
        // point was reached. This block is BOTH the natural fallthrough
        // from the code above AND (via `resume_blocks`, below) the entry
        // dispatch's OWN jump target for this state — the has()-check
        // must be genuinely RE-RUN on every resume, not skipped, because
        // `wasm_actors.zig`'s scheduler calls a suspended function's step
        // repeatedly, on every round, with NO guarantee a new message
        // has actually arrived by the time it's called again. Originally
        // the dispatch target was `have_block` directly (skipping the
        // check) — matching the file's own documented intent ("mirroring
        // the native VM's ip-rollback suspend contract", i.e. resuming
        // rolls back to BEFORE the check, not past it) but not what the
        // code actually did. Confirmed via wasmtime: this made a resumed
        // function unconditionally pop the mailbox even when empty,
        // underflowing the unsigned `count` field to a huge value that
        // then poisoned address arithmetic into an out-of-bounds write.
        const recheck_block = try builder.newBlock();
        builder.terminate(.{ .jump = .{ .target = recheck_block } });
        builder.setCurrentBlock(recheck_block);

        const check_frame = try frameValue(builder, frame_local, ptr_type);
        const has = try builder.newValue(bool_type);
        try builder.emit(.{ .call_builtin = .{ .dst = has, .name = kind.?.has, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{check_frame}) } });

        const suspend_block = try builder.newBlock();
        const have_block = try builder.newBlock();
        builder.terminate(.{ .branch = .{ .cond = has, .then_block = have_block, .else_block = suspend_block } });

        // Suspend path: save state, return "not done".
        builder.setCurrentBlock(suspend_block);
        // `src` computed BEFORE `frame` — `frame_store` codegen expects
        // stack order `[src, frame]` (see `wasm_emit.zig`'s
        // `EmitContext.frame_store_scratch_frame` doc comment).
        const state_value = try intConstant(builder, ptr_type, state);
        const suspend_frame = try frameValue(builder, frame_local, ptr_type);
        try builder.emit(.{ .frame_store = .{ .frame = suspend_frame, .slot = local_state_slot, .src = state_value } });
        builder.terminate(.suspend_return);

        // Resume path: pop the message, keep going with the REST of this
        // original instruction stream in `have_block` — this is both the
        // fallthrough (message was already there) AND the block the
        // entry dispatch jumps to when the scheduler resumes this exact
        // state later. The popped value goes straight into an ordinary
        // local (see the `Redirect` comment below) — `message_slot`
        // itself is reserved in the frame layout but otherwise unused now
        // (kept simple rather than reclaiming the slot).
        builder.setCurrentBlock(have_block);
        _ = message_slot;
        // `получить()`'s own declared type stays `poison` unless the
        // enclosing function is declared `-> Сообщение(T)`
        // (`type_checker.zig`, ~line 4146 — a real, separate limitation:
        // it never infers from match-arm narrowing for the far more
        // common `-> Пусто` idiom). Safe to use directly here —
        // `wasm_module.wasmValTypeForStore` now special-cases
        // `поison`/`unconstrained` as i32 (see its own doc comment),
        // consistently, everywhere this TypeId's WASM representation is
        // decided (this value's own local, every `frame_load`/
        // `frame_store` derived from it, `wasm_actors.zig`'s pop-variant
        // selection).
        const message_type = function.valueType(dst);
        const pop_frame = try frameValue(builder, frame_local, ptr_type);
        const popped = try builder.newValue(message_type);
        try builder.emit(.{ .call_builtin = .{ .dst = popped, .name = kind.?.pop, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{pop_frame}) } });
        try resume_blocks.put(state, recheck_block);

        // The ORIGINAL `dst` (the receive's own ValueId) is redirected to
        // an ordinary WASM local — every later instruction referencing it
        // gets its OWN fresh `load_local` (see `Redirect`'s doc comment;
        // a single shared reload can't satisfy more than one later use).
        const redirect_local = try builder.newLocal(@enumFromInt(0), "@msg", message_type);
        try builder.emit(.{ .store_local = .{ .local = redirect_local, .src = popped } });

        const new_redirects = try allocator.alloc(Redirect, redirects.len + 1);
        defer allocator.free(new_redirects);
        @memcpy(new_redirects[0..redirects.len], redirects);
        new_redirects[redirects.len] = .{ .old = dst, .local = redirect_local, .type_id = message_type };

        // `plan.suspend_points` matching (above, on the NEXT recursive
        // call) compares against ORIGINAL absolute indices — keep
        // recursing over the SAME (unsliced) `instructions` array with
        // `start_index = index + 1`, so a later suspend point's own
        // `instruction_index` still lines up.
        try rewriteInstructionStream(
            builder,
            allocator,
            instructions,
            index + 1,
            original_block,
            plan,
            frame_local,
            ptr_type,
            bool_type,
            local_state_slot,
            message_slot_base,
            resume_blocks,
            original_terminator,
            new_redirects,
            original_entry,
            self_function,
        );
        // The recursive call already applied (a rewritten form of) the
        // original terminator to whatever block it finished on — nothing
        // left to do for this call.
        return;
    }
    builder.terminate(try rewriteReturnTerminator(builder, frame_local, ptr_type, bool_type, original_terminator));
}

// Same field list as `substituteValue` below — kept in sync manually
// (both are small and rarely touched). NOTE: if `old` appears in TWO OR
// MORE fields of the SAME instruction (e.g. a hypothetical `binary{lhs =
// v, rhs = v}`), `substituteValue` maps both occurrences to the SAME
// fresh reload, which is itself a single-use violation — not hit by any
// current lowering shape (no MIR instruction happens to repeat one
// receive-result value across two of its own operand fields), but a
// real residual gap in this mechanism, not a solved case.
pub fn referencesValue(instruction: mir.Instruction, target: mir.ValueId) bool {
    return switch (instruction) {
        .copy => |i| i.src == target,
        .store_local => |i| i.src == target,
        .binary => |i| i.lhs == target or i.rhs == target,
        .compare => |i| i.lhs == target or i.rhs == target,
        .unary => |i| i.src == target,
        .get_property => |i| i.object == target,
        .set_property => |i| i.value == target,
        .get_index => |i| i.object == target or i.index == target,
        .set_index => |i| i.object == target or i.index == target or i.value == target,
        .cast_interface => |i| i.src == target,
        .invoke_interface => |i| i.receiver == target,
        .match_tag => |i| i.subject == target,
        .get_variant_field => |i| i.subject == target,
        .send => |i| i.process == target or i.message == target,
        .try_unwrap => |i| i.src == target,
        .frame_store => |i| i.src == target,
        // The RAW receive result (before any pattern-match field
        // extraction) flowing directly into a call/aggregate/spawn's
        // own argument list — no current fixture does this (every
        // actor idiom this codebase exercises destructures via
        // match_tag/get_variant_field first, both already covered
        // above), but it's the same class of gap the two ACTUALLY-HIT
        // bugs this session came from (wasm_objects.zig's build_variant/
        // new_aggregate field-order bug, wasm_actors.zig's expandSpawn
        // arg-order bug) — closing it defensively rather than waiting
        // for a third occurrence.
        .call => |i| for (i.args) |a| {
            if (a == target) break true;
        } else false,
        .call_value => |i| i.callee == target or for (i.args) |a| {
            if (a == target) break true;
        } else false,
        .new_aggregate => |i| for (i.elements) |e| {
            if (e == target) break true;
        } else false,
        .new_array => |i| for (i.elements) |e| {
            if (e == target) break true;
        } else false,
        .build_variant => |i| for (i.fields) |f| {
            if (f == target) break true;
        } else false,
        .spawn => |i| i.callee == target or for (i.args) |a| {
            if (a == target) break true;
        } else false,
        else => false,
    };
}

// `allocator` is ONLY needed for the array-field cases (`.call`/
// `.call_value`/`.new_aggregate`/`.new_array`/`.build_variant`/
// `.spawn`'s `args`/`elements`/`fields`) — substituting inside a `[]const
// ValueId` needs a fresh owned copy, unlike every other case here which
// just reassigns a single `ValueId` field in place.
pub fn substituteValue(allocator: std.mem.Allocator, instruction: mir.Instruction, old: mir.ValueId, new: mir.ValueId) !mir.Instruction {
    if (old == new) return instruction;
    const sub = struct {
        fn v(value: mir.ValueId, o: mir.ValueId, n: mir.ValueId) mir.ValueId {
            return if (value == o) n else value;
        }
    }.v;
    const subSlice = struct {
        fn f(alloc: std.mem.Allocator, values: []const mir.ValueId, o: mir.ValueId, n: mir.ValueId) ![]const mir.ValueId {
            const out_slice = try alloc.dupe(mir.ValueId, values);
            for (out_slice) |*value| {
                if (value.* == o) value.* = n;
            }
            return out_slice;
        }
    }.f;
    var out = instruction;
    switch (out) {
        .copy => |*i| i.src = sub(i.src, old, new),
        .store_local => |*i| i.src = sub(i.src, old, new),
        .binary => |*i| {
            i.lhs = sub(i.lhs, old, new);
            i.rhs = sub(i.rhs, old, new);
        },
        .compare => |*i| {
            i.lhs = sub(i.lhs, old, new);
            i.rhs = sub(i.rhs, old, new);
        },
        .unary => |*i| i.src = sub(i.src, old, new),
        .get_property => |*i| i.object = sub(i.object, old, new),
        .set_property => |*i| i.value = sub(i.value, old, new),
        .get_index => |*i| {
            i.object = sub(i.object, old, new);
            i.index = sub(i.index, old, new);
        },
        .set_index => |*i| {
            i.object = sub(i.object, old, new);
            i.index = sub(i.index, old, new);
            i.value = sub(i.value, old, new);
        },
        .cast_interface => |*i| i.src = sub(i.src, old, new),
        .invoke_interface => |*i| i.receiver = sub(i.receiver, old, new),
        .match_tag => |*i| i.subject = sub(i.subject, old, new),
        .get_variant_field => |*i| i.subject = sub(i.subject, old, new),
        .send => |*i| {
            i.process = sub(i.process, old, new);
            i.message = sub(i.message, old, new);
        },
        .try_unwrap => |*i| i.src = sub(i.src, old, new),
        .frame_store => |*i| i.src = sub(i.src, old, new),
        .call => |*i| i.args = try subSlice(allocator, i.args, old, new),
        .call_value => |*i| {
            i.callee = sub(i.callee, old, new);
            i.args = try subSlice(allocator, i.args, old, new);
        },
        .new_aggregate => |*i| i.elements = try subSlice(allocator, i.elements, old, new),
        .new_array => |*i| i.elements = try subSlice(allocator, i.elements, old, new),
        .build_variant => |*i| i.fields = try subSlice(allocator, i.fields, old, new),
        .spawn => |*i| {
            i.callee = sub(i.callee, old, new);
            i.args = try subSlice(allocator, i.args, old, new);
        },
        else => {},
    }
    return out;
}

test "hasActorInstructions detects receive" {
    var module = mir.Module.init(std.testing.allocator);
    defer module.deinit(std.testing.allocator);
    var function = mir.Function{ .id = @enumFromInt(0), .name = "actor", .symbol = @enumFromInt(0), .result_type = types.TypeId.raw(0), .span = .{ .file_id = 0, .start = 0, .end = 0 } };
    try function.value_types.append(std.testing.allocator, types.TypeId.raw(0));
    var block = mir.Block{ .id = @enumFromInt(0) };
    try block.instructions.append(std.testing.allocator, .{ .receive = .{ .dst = @enumFromInt(0) } });
    try function.blocks.append(std.testing.allocator, block);
    try module.functions.append(std.testing.allocator, function);
    try std.testing.expect(hasActorInstructions(&module));
    var points = try collectSuspendPoints(std.testing.allocator, &module);
    defer points.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), points.items.len);
    try std.testing.expectEqual(@as(u32, 1), points.items[0].resume_state);
    var layouts = try frameLayouts(std.testing.allocator, &module);
    defer {
        for (layouts.items) |layout| std.testing.allocator.free(layout.locals);
        layouts.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), layouts.items.len);
}
