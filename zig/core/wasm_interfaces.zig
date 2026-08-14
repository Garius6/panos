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
    // Same memoization shape as `wrapper_of` above, for `.build_closure`'s
    // OWN wrapper need — see `closureWrapperFor`'s doc comment. Separate
    // map (not shared with `wrapper_of`) since the two wrappers have
    // different shapes (box-unwrap-receiver vs. trailing-ignored-env_ptr)
    // and could, in principle, both be needed for the SAME target
    // function (used both as an interface method AND passed around as a
    // first-class value).
    var closure_wrapper_of: std.AutoHashMap(mir.FunctionId, mir.FunctionId) = .init(allocator);
    defer closure_wrapper_of.deinit();

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
        // Populated by the `.function_ref` case below, WHENEVER it hits
        // the `direct_call_callees` exclusion (i.e. this function_ref's
        // `dst` feeds a SAME-function `call_value`'s callee directly) —
        // this is the correct "is this call_value's callee actually a
        // known-static function" signal for `expandCallValue` to use.
        // `direct_call_callees` ITSELF is the wrong thing to check there:
        // it's populated by scanning `.call_value.callee` fields
        // directly, so a call_value's OWN callee is trivially always a
        // member of that set — checking it against itself is a tautology
        // that made `expandCallValue` treat EVERY closure call as a
        // static direct call, silently passing the raw (unboxed) box
        // pointer straight to `call_indirect` as a table index. Real bug,
        // found via `wasmtime`: "undefined element: out of bounds table
        // access" on the very first closure invocation tested.
        var static_callees: std.AutoHashMap(mir.ValueId, mir.FunctionId) = .init(allocator);
        defer static_callees.deinit();
        const block_count = module.functions.items[index].blocks.items.len;
        var block_index: usize = 0;
        while (block_index < block_count) : (block_index += 1) {
            var builder = mir_builder.Builder{ .module = module, .allocator = allocator, .function_id = function_id };
            try expandBlock(&builder, allocator, @enumFromInt(block_index), function_ctx, &table, &table_index_of, &wrapper_of, &closure_wrapper_of, &direct_call_callees, &static_callees);
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

// A plain named function used as a first-class closure VALUE
// (`.build_closure{already_env_aware: false}` — `mir_lowering.zig`'s
// `lowerSymbolValueRef`) needs a thin WRAPPER placed in the table
// instead of the original function itself: every closure is called
// uniformly through `call_indirect` with a TRAILING `env_ptr` argument
// (see `expandCallValue`), but the original function's own real
// signature/direct-call sites must stay untouched — adding a param to
// the function ITSELF would break every ordinary `f(x)` call to it
// elsewhere. The wrapper forwards to the real function unchanged,
// simply dropping the trailing `env_ptr` (a plain function-ref-turned-
// value never has real captures). Memoized per ORIGINAL FunctionId in
// `closure_wrapper_of`, same "build once, first time needed" shape as
// `wrapperFor` above.
fn closureWrapperFor(module: *mir.Module, allocator: std.mem.Allocator, fallback_type_store: *const types.TypeStore, closure_wrapper_of: *std.AutoHashMap(mir.FunctionId, mir.FunctionId), target: mir.FunctionId) !mir.FunctionId {
    if (closure_wrapper_of.get(target)) |existing| return existing;

    // Same "copy everything BEFORE calling newFunction/beginFunction"
    // discipline as `wrapperFor` — both APPEND to `module.functions`,
    // which can reallocate and invalidate a raw `*mir.Function`.
    const target_function = &module.functions.items[@intFromEnum(target)];
    const target_type_store = target_function.type_store orelse fallback_type_store;
    const target_layout = wasm_heap.PtrLayout{
        .ptr_type = target_type_store.builtins.string,
        .idx_type = target_type_store.builtins.boolean,
        .bool_type = target_type_store.builtins.boolean,
    };
    const target_name = try module.arena.allocator().dupe(u8, target_function.name);
    const target_result_type = target_function.result_type;
    const target_param_types = try allocator.alloc(types.TypeId, target_function.parameters.len);
    defer allocator.free(target_param_types);
    for (target_function.parameters, target_param_types) |local, *out| {
        out.* = target_function.locals.items[@intFromEnum(local)].type_id;
    }

    const wrapper_name = try std.fmt.allocPrint(module.arena.allocator(), "@closure_wrap_{s}", .{target_name});
    const wrapper_id = try mir_builder.newFunction(module, allocator, wrapper_name, wasm_heap.dummy_symbol, target_result_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, wrapper_id);

    var params: std.ArrayList(mir.LocalId) = .empty;
    var real_locals: std.ArrayList(mir.LocalId) = .empty;
    defer real_locals.deinit(allocator);
    for (target_param_types) |t| {
        const p = try builder.newLocal(wasm_heap.dummy_symbol, "a", t);
        try params.append(allocator, p);
        try real_locals.append(allocator, p);
    }
    const env_param = try builder.newLocal(wasm_heap.dummy_symbol, "@env", target_layout.idx_type);
    try params.append(allocator, env_param);
    builder.currentFunction().parameters = try params.toOwnedSlice(allocator);
    builder.currentFunction().type_store = target_type_store;

    const arena = module.arena.allocator();
    var args: std.ArrayList(mir.ValueId) = .empty;
    for (real_locals.items) |local| {
        const t = builder.currentFunction().locals.items[@intFromEnum(local)].type_id;
        try args.append(arena, try wasm_heap.loadLocal(&builder, local, t));
    }

    const is_void = target_type_store.eql(target_result_type, target_type_store.builtins.void);
    const dst = if (is_void) null else try builder.newValue(target_result_type);
    try builder.emit(.{ .call = .{ .dst = dst, .callee = target, .args = try args.toOwnedSlice(arena) } });
    builder.terminate(.{ .return_value = .{ .value = dst } });

    try closure_wrapper_of.put(target, wrapper_id);
    return wrapper_id;
}

// Expands `.build_closure{dst, function, captured, already_env_aware}`
// into: an ENVIRONMENT allocation (one 8-byte `frame_store` slot per
// captured value, same plain-struct shape `wasm_objects.zig` already
// uses — heterogeneous i32/f64 captures both fit uniformly, unlike a
// byte-packed layout) — skipped entirely (env_ptr = constant 0) for the
// common zero-capture case (a plain function reference used as a
// value) — then a 2-FIELD BOX, `mem_load`/`mem_store` at byte offsets 0
// and 4 (NOT frame slots — both box fields are always plain i32s, never
// a captured f64 directly, matching `expandCastInterface`'s own
// `{receiver, vtable_ptr}` box shape exactly): `table_index` at +0,
// `env_ptr` at +4. `already_env_aware` decides whether `function` is
// placed in the table directly (a lambda body, already synthesized
// with its own trailing `env_ptr` parameter — `mir_lowering.zig`'s
// `lowerLambda`) or via `closureWrapperFor` (a plain named function,
// needs the ignored-`env_ptr` wrapper).
fn expandBuildClosure(builder: *mir_builder.Builder, allocator: std.mem.Allocator, v: anytype, ctx: ExpandCtx, table: *std.ArrayList(mir.FunctionId), table_index_of: *std.AutoHashMap(mir.FunctionId, u32), closure_wrapper_of: *std.AutoHashMap(mir.FunctionId, mir.FunctionId)) !void {
    const layout = ctx.layout;
    const module = builder.module;
    const alloc_id = wasm_heap.findFunctionByName(module, wasm_heap.alloc_function_name).?;

    // `v.captured` are pre-existing values (produced earlier in the
    // instruction stream by whatever computed each captured expression,
    // IN ARRAY ORDER — `mir_lowering.zig`'s `lowerLambda` emits each
    // one's producer right when it iterates `captures`) — route through
    // Locals IMMEDIATELY, same "buried value" discipline as
    // `expandCastInterface`'s `v.src` (this whole initiative's most
    // load-bearing lesson) — but REVERSE order specifically: with N>1
    // captures, `v.captured[N-1]`'s producer was the LAST one replayed,
    // so it's the value actually sitting on TOP of the real WASM stack
    // at this point — processing `storeLocal` in ARRAY order (index 0
    // first) tried to pop it into the WRONG local. Real bug, found only
    // by running a genuine 2-capture closure under wasmtime/V8 (every
    // earlier fixture this session had exactly one capture, which
    // can't expose an ordering bug at all) — `wasm2wat`/`wasm-objdump`
    // traced it to a `local.set` receiving an f64 where an i32 local
    // was declared, two captures' values swapped.
    const capture_locals = try module.arena.allocator().alloc(mir.LocalId, v.captured.len);
    var capture_index = v.captured.len;
    while (capture_index > 0) {
        capture_index -= 1;
        capture_locals[capture_index] = try wasm_heap.storeLocal(builder, "@capture", builder.currentFunction().valueType(v.captured[capture_index]), v.captured[capture_index]);
    }

    const env_local: mir.LocalId = env_blk: {
        if (v.captured.len == 0) {
            const zero = try wasm_heap.addressConst(builder, layout.ptr_type, 0);
            break :env_blk try wasm_heap.storeLocal(builder, "@env", layout.ptr_type, zero);
        }
        const env_size = try wasm_heap.addressConst(builder, layout.idx_type, @intCast(v.captured.len * 8));
        const env = try builder.newValue(layout.ptr_type);
        try builder.emit(.{ .call = .{ .dst = env, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, env_size) } });
        const local = try wasm_heap.storeLocal(builder, "@env", layout.ptr_type, env);

        // Reverse order — established stack-order convention (see
        // `wasm_objects.zig`'s own plain-struct field-store loop, same
        // reasoning repeated throughout this session's work).
        var i = capture_locals.len;
        while (i > 0) {
            i -= 1;
            const capture_type = builder.currentFunction().locals.items[@intFromEnum(capture_locals[i])].type_id;
            const capture_val = try wasm_heap.loadLocal(builder, capture_locals[i], capture_type);
            const env_for_store = try wasm_heap.loadLocal(builder, local, layout.ptr_type);
            try builder.emit(.{ .frame_store = .{ .frame = env_for_store, .slot = @intCast(i), .src = capture_val } });
        }
        break :env_blk local;
    };

    const callee = if (v.already_env_aware) v.function else try closureWrapperFor(module, allocator, ctx.type_store, closure_wrapper_of, v.function);
    const table_index = try tableIndexFor(table, table_index_of, allocator, callee);

    const box_size = try wasm_heap.addressConst(builder, layout.idx_type, 8);
    const box = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = box, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, box_size) } });
    const box_local = try wasm_heap.storeLocal(builder, "@closure_box", layout.ptr_type, box);

    const table_index_const = try wasm_heap.addressConst(builder, layout.idx_type, table_index);
    const box_for_table = try wasm_heap.loadLocal(builder, box_local, layout.ptr_type);
    try builder.emit(.{ .mem_store = .{ .addr = box_for_table, .src = table_index_const } });

    const env_for_box = try wasm_heap.loadLocal(builder, env_local, layout.ptr_type);
    const four = try wasm_heap.addressConst(builder, layout.idx_type, 4);
    const box_for_env_addr = try wasm_heap.loadLocal(builder, box_local, layout.ptr_type);
    const env_field_addr = try wasm_heap.binOp(builder, layout.idx_type, .add, box_for_env_addr, four);
    try builder.emit(.{ .mem_store = .{ .addr = env_field_addr, .src = env_for_box } });

    try builder.emit(.{ .load_local = .{ .dst = v.dst, .local = box_local } });
}

// Expands a closure-typed `.call_value{callee, args, dst}` (a
// `.build_closure`-produced box, or any local/parameter/field holding
// one) into: unbox (`mem_load` table_index @+0, `mem_load` env_ptr
// @+4), append `env_ptr` as a TRAILING argument, `.call_indirect` —
// mirrors `expandInvokeInterface`'s own unbox-then-`call_indirect`
// shape exactly, same stack-order discipline (`table_index` must be the
// LAST-produced operand, per `call_indirect`'s own WASM semantics).
// STATIC direct calls (`static_callees` — see its own doc comment at
// the call site in `expand`) are left completely untouched —
// `wasm_emit.zig`'s existing `value_to_function` fast path still
// handles them as an ordinary `call`, zero closure overhead.
fn expandCallValue(builder: *mir_builder.Builder, allocator: std.mem.Allocator, v: anytype, ctx: ExpandCtx, static_callees: *const std.AutoHashMap(mir.ValueId, mir.FunctionId)) !void {
    if (static_callees.contains(v.callee)) {
        try builder.emit(.{ .call_value = .{ .dst = v.dst, .callee = v.callee, .args = v.args } });
        return;
    }
    _ = allocator;
    const layout = ctx.layout;
    const module = builder.module;

    const box_local = try wasm_heap.storeLocal(builder, "@call_box", layout.ptr_type, v.callee);
    const arg_locals = try module.arena.allocator().alloc(mir.LocalId, v.args.len);
    for (v.args, arg_locals) |arg, *local| {
        local.* = try wasm_heap.storeLocal(builder, "@call_arg", builder.currentFunction().valueType(arg), arg);
    }

    const box_for_table = try wasm_heap.loadLocal(builder, box_local, layout.ptr_type);
    const table_index_val = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load = .{ .dst = table_index_val, .addr = box_for_table } });
    const table_index_local = try wasm_heap.storeLocal(builder, "@table_index", layout.idx_type, table_index_val);

    const box_for_env = try wasm_heap.loadLocal(builder, box_local, layout.ptr_type);
    const four = try wasm_heap.addressConst(builder, layout.idx_type, 4);
    const env_addr = try wasm_heap.binOp(builder, layout.idx_type, .add, box_for_env, four);
    const env_ptr_val = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .mem_load = .{ .dst = env_ptr_val, .addr = env_addr } });
    const env_ptr_local = try wasm_heap.storeLocal(builder, "@call_env", layout.ptr_type, env_ptr_val);

    const arena = module.arena.allocator();
    var args: std.ArrayList(mir.ValueId) = .empty;
    for (arg_locals) |local| {
        const t = builder.currentFunction().locals.items[@intFromEnum(local)].type_id;
        try args.append(arena, try wasm_heap.loadLocal(builder, local, t));
    }
    try args.append(arena, try wasm_heap.loadLocal(builder, env_ptr_local, layout.ptr_type));

    const table_index_for_call = try wasm_heap.loadLocal(builder, table_index_local, layout.idx_type);
    try builder.emit(.{ .call_indirect = .{ .dst = v.dst, .table_index = table_index_for_call, .args = try args.toOwnedSlice(arena) } });
}

// Also gates first-class function VALUES (`.function_ref` used as
// anything other than `.spawn`'s own statically-resolved callee — see
// `directCallCallees`/`.function_ref`'s rewrite in `expandInstruction`)
// AND closures (`.build_closure`, WASM AOT closure support Stage A —
// `mir_lowering.zig`'s `lowerLambda`/`lowerSymbolValueRef`) — all three
// features share this pass's alloc/table infrastructure, and a program
// using none of them shouldn't pay for any of their setup.
fn usesInterfaces(module: *const mir.Module) bool {
    for (module.functions.items) |function| for (function.blocks.items) |block|
        for (block.instructions.items) |instruction| switch (instruction) {
            .cast_interface, .invoke_interface, .function_ref, .call_value, .build_closure => return true,
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

fn expandBlock(builder: *mir_builder.Builder, allocator: std.mem.Allocator, block_id: mir.BlockId, ctx: ExpandCtx, table: *std.ArrayList(mir.FunctionId), table_index_of: *std.AutoHashMap(mir.FunctionId, u32), wrapper_of: *std.AutoHashMap(mir.FunctionId, mir.FunctionId), closure_wrapper_of: *std.AutoHashMap(mir.FunctionId, mir.FunctionId), direct_call_callees: *const std.AutoHashMap(mir.ValueId, void), static_callees: *std.AutoHashMap(mir.ValueId, mir.FunctionId)) !void {
    const function = builder.currentFunction();
    var original = function.blockConst(block_id).*;
    function.block(block_id).instructions = .empty;
    builder.setCurrentBlock(block_id);
    builder.terminated = false;

    for (original.instructions.items) |instruction| {
        try expandInstruction(builder, allocator, instruction, ctx, table, table_index_of, wrapper_of, closure_wrapper_of, direct_call_callees, static_callees);
    }
    builder.terminate(original.terminator);
    original.instructions.deinit(allocator);
}

fn expandInstruction(builder: *mir_builder.Builder, allocator: std.mem.Allocator, instruction: mir.Instruction, ctx: ExpandCtx, table: *std.ArrayList(mir.FunctionId), table_index_of: *std.AutoHashMap(mir.FunctionId, u32), wrapper_of: *std.AutoHashMap(mir.FunctionId, mir.FunctionId), closure_wrapper_of: *std.AutoHashMap(mir.FunctionId, mir.FunctionId), direct_call_callees: *const std.AutoHashMap(mir.ValueId, void), static_callees: *std.AutoHashMap(mir.ValueId, mir.FunctionId)) !void {
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
                try static_callees.put(v.dst, v.function);
                try builder.emit(instruction);
                return;
            }
            const table_index = try tableIndexFor(table, table_index_of, allocator, v.function);
            try builder.emit(.{ .const_value = .{ .dst = v.dst, .value = .{ .address = table_index } } });
        },
        // WASM AOT closures, Stage A — see `expandBuildClosure`'s own
        // doc comment.
        .build_closure => |v| {
            try expandBuildClosure(builder, allocator, v, ctx, table, table_index_of, closure_wrapper_of);
        },
        // A closure-typed callee (`.function`-typed value, produced by
        // `.build_closure` or an ordinary local/parameter/field holding
        // one) — see `expandCallValue`'s own doc comment. The STATIC
        // direct-call fast path (`static_callees`) is untouched, exactly
        // as `.function_ref`'s own rewrite above.
        .call_value => |v| {
            try expandCallValue(builder, allocator, v, ctx, static_callees);
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
