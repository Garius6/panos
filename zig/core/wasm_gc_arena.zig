const std = @import("std");
const mir = @import("mir.zig");
const mir_builder = @import("mir_builder.zig");
const mir_cps = @import("mir_cps.zig");
const types = @import("types.zig");
const wasm_heap = @import("wasm_heap.zig");
const wasm_emit = @import("wasm_emit.zig");

// Phase 1 GC for WASM AOT — see `project_panos_wasm_aot_memory_growth_fix`/
// `project_panos_elm_architecture_dom_storage_design` for the full design
// discussion. WASM AOT has no tracing collector (a real one needs type-
// layout descriptors + spilling every local to linear memory, deferred as
// Phase 2) — this pass gets a cheap, correct-by-construction fraction of
// the value instead: reset the bump-allocator arena (`global 0`,
// `wasm_heap.zig`'s `@runtime_alloc`) to a checkpoint at the START of
// every JS-invoked ENTRY-POINT call, restoring it when that call returns.
// Reclaims everything allocated (and necessarily dead, since nothing
// outside the call can still reference it once it returns) across
// REPEATED calls — the exact shape of the Elm-architecture DOM-as-storage
// pattern (`старт`, then many independent `DOM.на_клик`/`после_кадра`
// callbacks) that motivated this work. Does NOT reclaim garbage
// generated WITHIN one long single call (a big loop) — that still relies
// on `memory.grow` alone (`project_panos_wasm_aot_memory_growth_fix`).
//
// Runs LAST in the AOT expand pipeline (after `wasm_objects`/
// `wasm_strings`/`wasm_interfaces`/`wasm_actors`), reusing
// `wasm_actors.zig`'s `buildScheduler` rename-and-wrap precedent: rename
// the original entry-point function to an internal name, build a NEW
// function under the ORIGINAL export name that does
// `checkpoint = arena; call original; arena = checkpoint; return result`.
//
// Which functions get wrapped is deliberately NOT "every WASM export" —
// `wasm_emit.zig` exports every compiled top-level function under its
// own name, not just the ones JS actually invokes directly; wrapping an
// incidentally-exported internal helper would reset arena state in the
// MIDDLE of whatever top-level call happens to invoke it, corrupting
// live intra-call data. The exact set: `старт` plus
// `module.dom_handler_names` (collected during `mir_lowering.zig`'s
// tree-shaking reachability walk — the same "handler registered by
// string-literal name" detection already built for that pass, reused
// here for an unrelated purpose).

fn uniqueInternalName(module: *mir.Module, original_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(module.arena.allocator(), "@arena_impl_{s}", .{original_name});
}

fn wrapEntryPoint(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, original_id: mir.FunctionId) !void {
    const original_name = try module.arena.allocator().dupe(u8, module.functions.items[@intFromEnum(original_id)].name);
    const internal_name = try uniqueInternalName(module, original_name);

    const original = &module.functions.items[@intFromEnum(original_id)];
    const result_type = original.result_type;
    const original_params = original.parameters;

    var param_types: std.ArrayList(types.TypeId) = .empty;
    defer param_types.deinit(allocator);
    var param_names: std.ArrayList([]const u8) = .empty;
    defer param_names.deinit(allocator);
    for (original_params) |local_id| {
        const local = original.locals.items[@intFromEnum(local_id)];
        try param_types.append(allocator, local.type_id);
        try param_names.append(allocator, local.name);
    }

    const new_id = try mir_builder.newFunction(module, allocator, original_name, wasm_heap.dummy_symbol, result_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, new_id);
    builder.currentFunction().type_store = type_store;

    var new_params: std.ArrayList(mir.LocalId) = .empty;
    for (param_types.items, param_names.items) |type_id, name| {
        const local = try builder.newLocal(wasm_heap.dummy_symbol, name, type_id);
        try new_params.append(allocator, local);
    }
    builder.currentFunction().parameters = try new_params.toOwnedSlice(allocator);

    // Checkpoint the arena bump pointer BEFORE running the wrapped body.
    const checkpoint = try builder.newValue(type_store.builtins.boolean);
    try builder.emit(.{ .global_get = .{ .dst = checkpoint, .global = wasm_emit.actor_heap_global_index } });
    const checkpoint_local = try wasm_heap.storeLocal(&builder, "@gc_checkpoint", type_store.builtins.boolean, checkpoint);

    // `module.arena`, not `allocator` — this slice is stored permanently
    // inside the `.call` instruction below, which `Block.deinit` never
    // frees on its own (only the instruction LIST itself, not variable-
    // length fields inside individual instructions — see
    // `mir.Module.arena`'s own doc comment). Confirmed as a real leak via
    // `DebugAllocator` before this fix (same class of bug `lowerCallArgs`
    // in `mir_lowering.zig` already avoids for the same reason).
    const arena = module.arena.allocator();
    var call_args: std.ArrayList(mir.ValueId) = .empty;
    for (builder.currentFunction().parameters, param_types.items) |local_id, type_id| {
        const value = try wasm_heap.loadLocal(&builder, local_id, type_id);
        try call_args.append(arena, value);
    }
    const args_slice = try call_args.toOwnedSlice(arena);

    const is_void = type_store.eql(result_type, type_store.builtins.void);
    if (is_void) {
        try builder.emit(.{ .call = .{ .dst = null, .callee = original_id, .args = args_slice } });
        const checkpoint_for_restore = try wasm_heap.loadLocal(&builder, checkpoint_local, type_store.builtins.boolean);
        try builder.emit(.{ .global_set = .{ .global = wasm_emit.actor_heap_global_index, .src = checkpoint_for_restore } });
        builder.terminate(.{ .return_value = .{ .value = null } });
    } else {
        const result = try builder.newValue(result_type);
        try builder.emit(.{ .call = .{ .dst = result, .callee = original_id, .args = args_slice } });
        const result_local = try wasm_heap.storeLocal(&builder, "@gc_result", result_type, result);
        const checkpoint_for_restore = try wasm_heap.loadLocal(&builder, checkpoint_local, type_store.builtins.boolean);
        try builder.emit(.{ .global_set = .{ .global = wasm_emit.actor_heap_global_index, .src = checkpoint_for_restore } });
        const result_for_return = try wasm_heap.loadLocal(&builder, result_local, result_type);
        builder.terminate(.{ .return_value = .{ .value = result_for_return } });
    }

    // Old entry point is no longer externally reachable under its
    // original export name (the new wrapper above owns that now) —
    // renamed so `wasm_emit.zig`'s "export every function by name"
    // doesn't produce a colliding second export.
    module.functions.items[@intFromEnum(original_id)].name = internal_name;
}

pub fn expand(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore) !void {
    // No heap used at all (no `@runtime_alloc`/global 0 in the final
    // module, `wasm_emit.zig`'s own `has_actors` gate) — nothing to
    // reset, and generating a wrapper that references a nonexistent
    // global would produce an invalid module.
    if (!mir_cps.usesActorMemory(module)) return;

    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    var entry_names: std.ArrayList([]const u8) = .empty;
    defer entry_names.deinit(allocator);
    if (!seen.contains("старт")) {
        try seen.put("старт", {});
        try entry_names.append(allocator, "старт");
    }
    for (module.dom_handler_names) |name| {
        if (seen.contains(name)) continue;
        try seen.put(name, {});
        try entry_names.append(allocator, name);
    }

    for (entry_names.items) |name| {
        const id = wasm_heap.findFunctionByName(module, name) orelse continue;
        try wrapEntryPoint(allocator, module, type_store, id);
    }
}
