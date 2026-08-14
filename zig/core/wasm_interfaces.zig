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

    // Assigned in first-seen order while rewriting `.cast_interface`
    // sites below — a plain `AutoHashMap` walk order isn't stable across
    // runs, so the assignment MUST happen via a single linear scan (not
    // e.g. iterating some hash map of "every method ever seen"), which
    // `expandBlock`'s own block-by-block, instruction-by-instruction
    // walk already naturally gives for free.
    var table: std.ArrayList(mir.FunctionId) = .empty;
    var table_index_of: std.AutoHashMap(mir.FunctionId, u32) = .init(allocator);
    defer table_index_of.deinit();
    // Ordinary (non-default) methods placed in an interface vtable need
    // a thin unwrap-the-box WRAPPER (see `wrapperFor`'s own doc comment)
    // — memoized per ORIGINAL FunctionId so the same method reached via
    // multiple casts only gets ONE wrapper, appended to `module.functions`
    // lazily the first time it's needed (safe mid-loop: the outer `while`
    // below re-checks `module.functions.items.len` every iteration, same
    // pattern `wasm_objects.zig`'s own runtime-function construction
    // already established).
    var wrapper_of: std.AutoHashMap(mir.FunctionId, mir.FunctionId) = .init(allocator);
    defer wrapper_of.deinit();

    var index: usize = 0;
    while (index < module.functions.items.len) : (index += 1) {
        const function_id: mir.FunctionId = @enumFromInt(index);
        // Each function in the module graph may belong to a DIFFERENT
        // source file/module, hence a DIFFERENT `types.TypeStore`
        // instance (`TypeId.owner` is deliberately store-specific — see
        // `types.zig`'s own doc comment: "makes accidental cross-store
        // use fail"). Box/vtable-array values created below must be
        // typed against THIS function's own store, not the caller-
        // supplied top-level `type_store` (which is only the ENTRY
        // module's) — using the wrong store here silently produced a
        // `TypeId` that `wasm_emit.zig` could never look up later
        // (`store.get` returns null for a foreign owner), defaulting
        // that value's WASM type to f64 instead of i32 and corrupting
        // the `call_indirect` type-index computation. Found by tracing
        // `Итерируемое::собрать` (a prelude function, non-entry module)
        // failing `call_indirect: тип не найден` — `это`'s own type
        // resolved fine (same store), but the box value built here for
        // `.следующий()`'s receiver did not.
        const function_store = module.functions.items[index].type_store orelse type_store;
        const function_layout = wasm_heap.PtrLayout{
            .ptr_type = function_store.builtins.string,
            .idx_type = function_store.builtins.boolean,
            .bool_type = function_store.builtins.boolean,
        };
        const function_ctx = ExpandCtx{ .layout = function_layout, .type_store = function_store };
        var direct_call_callees = try directCallCallees(allocator, &module.functions.items[index]);
        defer direct_call_callees.deinit();
        const block_count = module.functions.items[index].blocks.items.len;
        var block_index: usize = 0;
        while (block_index < block_count) : (block_index += 1) {
            var builder = mir_builder.Builder{ .module = module, .allocator = allocator, .function_id = function_id };
            try expandBlock(&builder, allocator, @enumFromInt(block_index), function_ctx, &table, &table_index_of, &wrapper_of, &direct_call_callees);
        }
    }

    return .{ .table = try table.toOwnedSlice(allocator) };
}

// Ordinary `реализация X для Y` methods expect `это` as the RAW
// underlying concrete value (real field access on a real struct) —
// but every interface vtable slot is called uniformly through the SAME
// boxed `это` (see `expandInvokeInterface`), since a DEFAULT interface
// method's `это` must stay the ABSTRACT boxed value (to keep
// dispatching polymorphically via `это.другой_метод()` — mirrors
// `vm.zig`'s own `callInterface`/`is_default_interface_method` split
// exactly, same reasoning, WASM-shaped). Rather than making
// `expandInvokeInterface` runtime-branch on which kind of callee it
// might hit (WASM has no "inspect this function" reflection), every
// ORDINARY method gets a trampoline here instead: unwrap the box once
// (`mem_load` box+0), forward to the real method with the raw receiver
// + the rest of the args unchanged. Default methods need NO wrapper —
// the box IS already the shape they expect.
fn wrapperFor(module: *mir.Module, allocator: std.mem.Allocator, fallback_type_store: *const types.TypeStore, wrapper_of: *std.AutoHashMap(mir.FunctionId, mir.FunctionId), target: mir.FunctionId) !mir.FunctionId {
    if (wrapper_of.get(target)) |existing| return existing;

    // Copy everything needed from the target BEFORE calling
    // `mir_builder.newFunction`/`beginFunction` below — both APPEND to
    // `module.functions`, which can reallocate the backing array and
    // invalidate a raw `*mir.Function` held across the call (`mir_builder
    // .zig`'s own module doc comment).
    const target_function = &module.functions.items[@intFromEnum(target)];
    // The wrapper's own types (box param, receiver, result) must come
    // from the TARGET's store, not the CALLER's (`.cast_interface` site)
    // — the target may live in a different module than the cast site
    // (e.g. a prelude default method casting a struct declared in the
    // SAME prelude module, wrapped and called from an entry-module
    // function). Using the caller's store here would reproduce the
    // exact cross-store `TypeId` bug `expand()`'s own per-function
    // `type_store` derivation was added to fix.
    const target_type_store = target_function.type_store orelse fallback_type_store;
    const target_layout = wasm_heap.PtrLayout{
        .ptr_type = target_type_store.builtins.string,
        .idx_type = target_type_store.builtins.boolean,
        .bool_type = target_type_store.builtins.boolean,
    };
    const target_name = try module.arena.allocator().dupe(u8, target_function.name);
    const target_result_type = target_function.result_type;
    const target_extra_param_types = try allocator.alloc(types.TypeId, target_function.parameters.len - 1);
    defer allocator.free(target_extra_param_types);
    for (target_function.parameters[1..], target_extra_param_types) |local, *out| {
        out.* = target_function.locals.items[@intFromEnum(local)].type_id;
    }

    const wrapper_name = try std.fmt.allocPrint(module.arena.allocator(), "@iface_wrap_{s}", .{target_name});
    const wrapper_id = try mir_builder.newFunction(module, allocator, wrapper_name, wasm_heap.dummy_symbol, target_result_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, wrapper_id);

    const box_param = try builder.newLocal(wasm_heap.dummy_symbol, "box", target_layout.ptr_type);
    var params: std.ArrayList(mir.LocalId) = .empty;
    try params.append(allocator, box_param);
    var extra_locals: std.ArrayList(mir.LocalId) = .empty;
    for (target_extra_param_types) |t| {
        const p = try builder.newLocal(wasm_heap.dummy_symbol, "a", t);
        try params.append(allocator, p);
        try extra_locals.append(allocator, p);
    }
    builder.currentFunction().parameters = try params.toOwnedSlice(allocator);
    builder.currentFunction().type_store = target_type_store;

    const box_val = try wasm_heap.loadLocal(&builder, box_param, target_layout.ptr_type);
    const receiver = try builder.newValue(target_layout.ptr_type);
    try builder.emit(.{ .mem_load = .{ .dst = receiver, .addr = box_val } });

    const arena = module.arena.allocator();
    var args: std.ArrayList(mir.ValueId) = .empty;
    try args.append(arena, receiver);
    for (extra_locals.items) |local| {
        const t = builder.currentFunction().locals.items[@intFromEnum(local)].type_id;
        try args.append(arena, try wasm_heap.loadLocal(&builder, local, t));
    }

    const is_void = target_type_store.eql(target_result_type, target_type_store.builtins.void);
    const dst = if (is_void) null else try builder.newValue(target_result_type);
    try builder.emit(.{ .call = .{ .dst = dst, .callee = target, .args = try args.toOwnedSlice(arena) } });
    builder.terminate(.{ .return_value = .{ .value = dst } });

    try wrapper_of.put(target, wrapper_id);
    return wrapper_id;
}

// Also gates first-class function VALUES (`.function_ref` used as
// anything other than `.spawn`'s own statically-resolved callee — see
// `directCallCallees`/`.function_ref`'s rewrite in `expandInstruction`) —
// both features share this pass's alloc/table infrastructure, and a
// program using ONE without the OTHER shouldn't pay for either's setup.
fn usesInterfaces(module: *const mir.Module) bool {
    for (module.functions.items) |function| for (function.blocks.items) |block|
        for (block.instructions.items) |instruction| switch (instruction) {
            .cast_interface, .invoke_interface, .function_ref, .call_value => return true,
            else => {},
        };
    return false;
}

// Two callee kinds must NEVER have their `.function_ref` rewritten into
// a real i32 table constant — both stay as a literal, no-op-producing
// `.function_ref`, resolved by a downstream direct-call scan instead of
// `call_indirect`:
//
// 1. `.spawn`'s own callee — `wasm_actors.zig`'s `resolveSpawnTarget`
//    scans for a matching `.function_ref` instruction (`wasm_actors.
//    expand` runs AFTER this pass, so rewriting it away here would
//    silently break every `запусти` call).
//
// 2. `.call_value`'s own callee, for every STATICALLY known named call
//    (`mir_lowering.zig`'s ident/method_calls/module-import fast paths
//    — the common case, `.function_ref` feeds `call_value.callee`
//    DIRECTLY, no intervening store/reload). `wasm_emit.zig`'s
//    `value_to_function` map resolves these into an ordinary direct
//    `call`, no indirection needed. Rewriting these into table entries
//    is not just wasted work — for a SELF-recursive call specifically,
//    it is actively wrong: `wasm_actors.zig` reuses/renames a function's
//    OWN `FunctionId` in place when turning it into an actor scheduler
//    function, so a table entry registered against that `FunctionId`
//    BEFORE the rename ends up pointing at the WRONG (post-rename)
//    signature by the time `emitModule` builds the Table/Element
//    sections — confirmed via `wasmtime`: "indirect call type mismatch"
//    trapping a recursive actor message handler calling itself. (A
//    call_value whose callee comes from `mir_lowering.zig`'s
//    `storeCalleeLocal`/`reloadCalleeLocal` — the genuinely dynamic
//    fallback path — uses a FRESH `ValueId` from the reload, never the
//    original `.function_ref`'s own `dst`, so it's naturally excluded
//    from this set and still gets rewritten as needed.)
//
// Collected per-function (matching `resolveSpawnTarget`'s own
// whole-function scan) before any rewriting happens.
fn directCallCallees(allocator: std.mem.Allocator, function: *const mir.Function) !std.AutoHashMap(mir.ValueId, void) {
    var set: std.AutoHashMap(mir.ValueId, void) = .init(allocator);
    for (function.blocks.items) |block| for (block.instructions.items) |instruction| switch (instruction) {
        .spawn => |v| try set.put(v.callee, {}),
        .call_value => |v| try set.put(v.callee, {}),
        else => {},
    };
    return set;
}

fn tableIndexFor(table: *std.ArrayList(mir.FunctionId), table_index_of: *std.AutoHashMap(mir.FunctionId, u32), allocator: std.mem.Allocator, function_id: mir.FunctionId) !u32 {
    if (table_index_of.get(function_id)) |existing| return existing;
    const index: u32 = @intCast(table.items.len);
    try table.append(allocator, function_id);
    try table_index_of.put(function_id, index);
    return index;
}

fn expandBlock(builder: *mir_builder.Builder, allocator: std.mem.Allocator, block_id: mir.BlockId, ctx: ExpandCtx, table: *std.ArrayList(mir.FunctionId), table_index_of: *std.AutoHashMap(mir.FunctionId, u32), wrapper_of: *std.AutoHashMap(mir.FunctionId, mir.FunctionId), direct_call_callees: *const std.AutoHashMap(mir.ValueId, void)) !void {
    const function = builder.currentFunction();
    var original = function.blockConst(block_id).*;
    function.block(block_id).instructions = .empty;
    builder.setCurrentBlock(block_id);
    builder.terminated = false;

    for (original.instructions.items) |instruction| {
        try expandInstruction(builder, allocator, instruction, ctx, table, table_index_of, wrapper_of, direct_call_callees);
    }
    builder.terminate(original.terminator);
    original.instructions.deinit(allocator);
}

fn expandInstruction(builder: *mir_builder.Builder, allocator: std.mem.Allocator, instruction: mir.Instruction, ctx: ExpandCtx, table: *std.ArrayList(mir.FunctionId), table_index_of: *std.AutoHashMap(mir.FunctionId, u32), wrapper_of: *std.AutoHashMap(mir.FunctionId, mir.FunctionId), direct_call_callees: *const std.AutoHashMap(mir.ValueId, void)) !void {
    switch (instruction) {
        .cast_interface => |v| {
            try expandCastInterface(builder, allocator, v, ctx, table, table_index_of, wrapper_of);
        },
        .invoke_interface => |v| {
            try expandInvokeInterface(builder, ctx, v);
        },
        // Rewrites a function reference into a real i32 WASM table
        // index (`.const_value{.address}`) — see `usesInterfaces`'s and
        // `directCallCallees`'s own doc comments for why `.spawn`'s own
        // callee is deliberately excluded.
        .function_ref => |v| {
            if (direct_call_callees.contains(v.dst)) {
                try builder.emit(instruction);
                return;
            }
            const table_index = try tableIndexFor(table, table_index_of, allocator, v.function);
            try builder.emit(.{ .const_value = .{ .dst = v.dst, .value = .{ .address = table_index } } });
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
fn expandCastInterface(builder: *mir_builder.Builder, allocator: std.mem.Allocator, v: anytype, ctx: ExpandCtx, table: *std.ArrayList(mir.FunctionId), table_index_of: *std.AutoHashMap(mir.FunctionId, u32), wrapper_of: *std.AutoHashMap(mir.FunctionId, mir.FunctionId)) !void {
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
        // Ordinary (non-default) methods get routed through a thin
        // unwrap-the-box wrapper — see `wrapperFor`'s own doc comment for
        // why. Default methods use their own FunctionId directly (the
        // box IS the shape they expect for `это`).
        const callee = if (binding.is_default) binding.function else try wrapperFor(module, allocator, ctx.type_store, wrapper_of, binding.function);
        const table_index = try tableIndexFor(table, table_index_of, allocator, callee);
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

// Reads the vtable slot at `method_index*4` (the ONLY genuinely dynamic
// part — a runtime i32, not known until the program actually runs),
// then `.call_indirect` with `[box] ++ args` — the BOX ITSELF (not an
// unwrapped receiver) is passed uniformly to every vtable slot; see
// `wrapperFor`'s doc comment for why (ordinary methods get a thin
// unwrap-the-box wrapper generated at their `.cast_interface` site,
// default methods already expect the box directly as `это`).
fn expandInvokeInterface(builder: *mir_builder.Builder, ctx: ExpandCtx, v: anytype) !void {
    const layout = ctx.layout;

    const box_for_receiver = v.receiver;
    const box_local = try wasm_heap.storeLocal(builder, "@iface_box", layout.ptr_type, box_for_receiver);

    // `v.args` are ALSO pre-existing values (from the original
    // instruction stream, produced before this `.invoke_interface`) —
    // routed through Locals immediately, same reasoning as `v.receiver`
    // above and `v.src` in `expandCastInterface`, since they're only
    // actually needed much later (after the vtable-lookup code below).
    const arg_locals = try builder.module.arena.allocator().alloc(mir.LocalId, v.args.len);
    for (v.args, arg_locals) |arg, *local| {
        local.* = try wasm_heap.storeLocal(builder, "@iface_arg", builder.currentFunction().valueType(arg), arg);
    }

    const four = try wasm_heap.addressConst(builder, layout.idx_type, 4);
    const box_for_vtable = try wasm_heap.loadLocal(builder, box_local, layout.ptr_type);
    const vtable_field_addr = try wasm_heap.binOp(builder, layout.idx_type, .add, box_for_vtable, four);
    const vtable_array = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .mem_load = .{ .dst = vtable_array, .addr = vtable_field_addr } });
    const vtable_array_local = try wasm_heap.storeLocal(builder, "@vtable", layout.ptr_type, vtable_array);

    // `call_indirect`'s WASM stack requirement is `[args..., table_index]`
    // (the index popped FIRST/topmost) — args (box + real args) must
    // therefore be produced BEFORE `table_index`, not after, even though
    // the vtable slot needed to COMPUTE `table_index` was already read
    // above; the read (`mem_load` into `table_index`'s own ValueId) is
    // deferred to right before the call specifically to keep it the
    // LAST-produced operand.
    const box_for_call = try wasm_heap.loadLocal(builder, box_local, layout.ptr_type);
    const arena = builder.module.arena.allocator();
    var args: std.ArrayList(mir.ValueId) = .empty;
    try args.append(arena, box_for_call);
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
