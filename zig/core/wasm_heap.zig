const std = @import("std");
const mir = @import("mir.zig");
const mir_builder = @import("mir_builder.zig");
const types = @import("types.zig");
const source = @import("source.zig");
const symbols = @import("symbols.zig");

// Shared MIR-construction helpers + the one bump allocator, used by BOTH
// `wasm_actors.zig` and `wasm_objects.zig` — extracted so the two passes
// cooperate on the SAME heap (global 0) safely: whichever pass runs
// first creates the one `@runtime_alloc` function, the other reuses it
// by name lookup (`findOrBuildAlloc`). Either pass's `alloc` calls read/
// write the same global, so interleaved allocations from both passes
// are safe by construction — nothing here needs to know which OTHER
// pass, if any, also uses the heap.

pub const dummy_span: source.Span = .{ .file_id = 0, .start = 0, .end = 0 };
pub const dummy_symbol: symbols.SymbolId = @enumFromInt(0);

// Types wide enough to be a real WASM i32 (`wasm_module.wasmValTypeForStore`)
// without inventing a new panos-level type — `ptr_type` (reused `Строка`)
// for addresses/handles, `idx_type` (reused `Булево`) for plain integer
// arithmetic (ring/array indices, counters) that must never collide with
// `.binary`'s string-concat special case (which checks equality against
// `builtins.string` specifically — `idx_type` deliberately avoids that).
pub const PtrLayout = struct {
    ptr_type: types.TypeId,
    idx_type: types.TypeId,
    bool_type: types.TypeId,
};

pub fn findFunctionByName(module: *const mir.Module, name: []const u8) ?mir.FunctionId {
    for (module.functions.items) |function| {
        if (std.mem.eql(u8, function.name, name)) return function.id;
    }
    return null;
}

pub fn frameValue(builder: *mir_builder.Builder, frame_local: mir.LocalId, ptr_type: types.TypeId) !mir.ValueId {
    const dst = try builder.newValue(ptr_type);
    try builder.emit(.{ .load_local = .{ .dst = dst, .local = frame_local } });
    return dst;
}

pub fn addressConst(builder: *mir_builder.Builder, ptr_type: types.TypeId, value: u32) !mir.ValueId {
    const dst = try builder.newValue(ptr_type);
    try builder.emit(.{ .const_value = .{ .dst = dst, .value = .{ .address = value } } });
    return dst;
}

pub fn boolConst(builder: *mir_builder.Builder, bool_type: types.TypeId, value: bool) !mir.ValueId {
    const dst = try builder.newValue(bool_type);
    try builder.emit(.{ .const_value = .{ .dst = dst, .value = .{ .boolean = value } } });
    return dst;
}

pub fn binOp(builder: *mir_builder.Builder, result_type: types.TypeId, op: mir.BinOp, lhs: mir.ValueId, rhs: mir.ValueId) !mir.ValueId {
    const dst = try builder.newValue(result_type);
    try builder.emit(.{ .binary = .{ .dst = dst, .op = op, .lhs = lhs, .rhs = rhs } });
    return dst;
}

pub fn cmpOp(builder: *mir_builder.Builder, bool_type: types.TypeId, op: mir.CmpOp, lhs: mir.ValueId, rhs: mir.ValueId) !mir.ValueId {
    const dst = try builder.newValue(bool_type);
    try builder.emit(.{ .compare = .{ .dst = dst, .op = op, .lhs = lhs, .rhs = rhs } });
    return dst;
}

pub fn notOp(builder: *mir_builder.Builder, bool_type: types.TypeId, value: mir.ValueId) !mir.ValueId {
    const dst = try builder.newValue(bool_type);
    try builder.emit(.{ .unary = .{ .dst = dst, .op = .negate_bool, .src = value } });
    return dst;
}

// This whole file's #1 rule (inherited by every caller): a `ValueId` is a
// STACK VALUE, consumed by its single use the moment `wasm_emit.zig`
// replays it — reusing one across two or more later instructions
// (`mir_validate.zig`'s "single-use инвариант") is invalid MIR, not just
// a style question. Any value needed more than once MUST go through a
// real `Local` (store once, reload fresh at each use) — exactly what
// `frameValue` already does for a frame pointer; `storeLocal`/
// `loadLocal` generalize that to every other repeated value (found by
// actually running `mir_validate.zig` over hand-built output, not by
// reading alone, while building `wasm_actors.zig`).
pub fn storeLocal(builder: *mir_builder.Builder, name: []const u8, type_id: types.TypeId, value: mir.ValueId) !mir.LocalId {
    const local = try builder.newLocal(dummy_symbol, name, type_id);
    try builder.emit(.{ .store_local = .{ .local = local, .src = value } });
    return local;
}

pub fn loadLocal(builder: *mir_builder.Builder, local: mir.LocalId, type_id: types.TypeId) !mir.ValueId {
    const dst = try builder.newValue(type_id);
    try builder.emit(.{ .load_local = .{ .dst = dst, .local = local } });
    return dst;
}

pub fn dupeOne(module: *mir.Module, value: mir.ValueId) ![]const mir.ValueId {
    return module.arena.allocator().dupe(mir.ValueId, &.{value});
}

pub const alloc_function_name = "@runtime_alloc";

fn buildAlloc(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: PtrLayout) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, alloc_function_name, dummy_symbol, layout.ptr_type, dummy_span);
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
    // Result typed `idx_type`, not `ptr_type` (`builtins.string`) —
    // `.binary`'s codegen special-cases ANY result typed `builtins.string`
    // as string concatenation (`wasm_emit.zig`), which silently
    // miscompiled this bump-pointer arithmetic into a call to a host
    // string-concat import that then had to be declared but was never
    // actually reachable at runtime (confirmed via wasmtime: "unknown
    // import: env::pw_string_concat" even though no code path called it).
    // `global_set` only cares about the underlying WASM primitive (i32,
    // same for both `idx_type`/`ptr_type` here), so no conversion needed.
    const new_ptr = try binOp(&builder, layout.idx_type, .add, ptr_for_add, size);
    try builder.emit(.{ .global_set = .{ .global = 0, .src = new_ptr } });
    const ptr_for_return = try loadLocal(&builder, ptr_local, layout.ptr_type);
    builder.terminate(.{ .return_value = .{ .value = ptr_for_return } });
    return id;
}

// Real bug found while extracting this from `wasm_actors.zig`: the
// original had a process-global `var g_alloc_id: ?mir.FunctionId = null`
// cache — stale across separate compilations within the same process
// (e.g. this codebase's own multi-case `zig test` runs), since a
// `FunctionId` is only valid for the ONE `mir.Module` it was allocated
// in. Fixed by dropping the cache entirely — `findFunctionByName` is a
// cheap linear scan, called at most a handful of times per compile, no
// need to cache across compiles at all.
pub fn findOrBuildAlloc(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: PtrLayout) !mir.FunctionId {
    if (findFunctionByName(module, alloc_function_name)) |id| return id;
    return buildAlloc(allocator, module, type_store, layout);
}
