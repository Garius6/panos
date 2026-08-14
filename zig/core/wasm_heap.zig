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

// `addressConst` above always emits `.address` (i32.const) — wrong for
// an f64-typed (`Число`) value, which needs `.number` (f64.const).
// Found as a real bug (`wasm_strings.zig`'s `@string_replace`, needing
// an f64-typed -1.0 sentinel to compare against `@string_find`'s
// rune-index return) — using `addressConst` there would have produced
// an invalid module (WASM validator: "type mismatch: expected f64
// found i32").
pub fn numberConst(builder: *mir_builder.Builder, number_type: types.TypeId, value: f64) !mir.ValueId {
    const dst = try builder.newValue(number_type);
    try builder.emit(.{ .const_value = .{ .dst = dst, .value = .{ .number = value } } });
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

// 64 KiB — the fixed WASM page size (`memory.size`/`memory.grow` always
// operate in units of this, never bytes directly).
const wasm_page_bytes: u32 = 65536;

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
    const new_ptr_local = try storeLocal(&builder, "new_ptr", layout.idx_type, new_ptr);

    // Real bug found running a synthetic serialize/parse benchmark: this
    // bump pointer never checked against the module's ACTUAL memory size
    // at all — any allocation past the initial page count (fixed at
    // compile time, `wasm_emit.zig`'s `actor_heap_base` computation)
    // trapped with a raw "memory access out of bounds" on the very next
    // read/write through the returned pointer, the first time a program
    // allocated enough (a few thousand small strings — no GC exists here
    // to reclaim any of them either) to walk past it. Grow the memory
    // FIRST, only when actually needed, before ever handing out a
    // pointer past the current boundary.
    // A MIR `compare`/`binary` instruction doesn't re-push its operands —
    // it consumes whatever's already on the WASM stack, in the order
    // those operands were EMITTED (program order), regardless of which
    // one is written as `lhs`/`rhs` in this Zig code. Real bug found
    // running this against a real allocation-heavy program: emitting
    // `current_bytes`'s computation before reloading `new_ptr_for_cmp`
    // put `current_bytes` UNDER `new_ptr` on the stack, so `i32.gt_s`
    // (which pops top-as-c2, next-as-c1) actually computed
    // `current_bytes > new_ptr` — the exact opposite of the intended
    // check — so growth was silently never triggered and the module
    // still trapped at the old boundary. `new_ptr_for_cmp` MUST be
    // loaded first here to land at the bottom of the two-operand stack
    // window matching `cmpOp`'s `lhs` argument.
    const new_ptr_for_cmp = try loadLocal(&builder, new_ptr_local, layout.idx_type);
    const pages = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .memory_size = .{ .dst = pages } });
    const page_bytes_const = try addressConst(&builder, layout.idx_type, wasm_page_bytes);
    const current_bytes = try binOp(&builder, layout.idx_type, .multiply, pages, page_bytes_const);
    const needs_growth = try cmpOp(&builder, layout.bool_type, .greater, new_ptr_for_cmp, current_bytes);

    // Single branch level only — `wasm_stackify.zig`'s merge-point
    // detection (`findMerge`) relies on the CFG staying REDUCIBLE the way
    // `mir_lowering.zig`'s own если/иначе lowering always produces it
    // (each branch's merge is a block dominated ONLY by that branch).
    // A second, nested branch inside `grow_block` sharing the SAME
    // `ok_block` merge as the outer branch breaks that (`ok_block`'s
    // dominator becomes the outer branch, not `grow_block`) — confirmed
    // as a real bug: it compiled but wasmtime rejected the module
    // ("invalid var_i32: integer too large", a corrupted LEB128 from the
    // stackifier misplacing block boundaries). Fixed by not branching a
    // second time on `memory.grow`'s result at all — an actual growth
    // failure (host memory limit hit) just falls through to the same
    // "memory access out of bounds" trap this bug fixes the COMMON case
    // of, on the very next read/write past the boundary; genuinely
    // running out of host memory is not something this allocator can
    // recover from either way.
    const grow_block = try builder.newBlock();
    const ok_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = needs_growth, .then_block = grow_block, .else_block = ok_block } });

    builder.setCurrentBlock(grow_block);
    const new_ptr_for_grow = try loadLocal(&builder, new_ptr_local, layout.idx_type);
    // `pages`/`page_bytes_const` (used above, in the branch condition)
    // are stack values already consumed by that one use — re-derive
    // fresh copies here rather than reusing them (single-use invariant,
    // see the file-level comment on `ValueId`).
    const pages_fresh = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .memory_size = .{ .dst = pages_fresh } });
    const page_bytes_const2 = try addressConst(&builder, layout.idx_type, wasm_page_bytes);
    const current_bytes_for_grow = try binOp(&builder, layout.idx_type, .multiply, pages_fresh, page_bytes_const2);
    const additional_bytes = try binOp(&builder, layout.idx_type, .subtract, new_ptr_for_grow, current_bytes_for_grow);
    const round_up_const = try addressConst(&builder, layout.idx_type, wasm_page_bytes - 1);
    const rounded_bytes = try binOp(&builder, layout.idx_type, .add, additional_bytes, round_up_const);
    const page_bytes_const3 = try addressConst(&builder, layout.idx_type, wasm_page_bytes);
    const additional_pages = try binOp(&builder, layout.idx_type, .int_divide, rounded_bytes, page_bytes_const3);
    const grow_result = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .memory_grow = .{ .dst = grow_result, .pages = additional_pages } });
    builder.terminate(.{ .jump = .{ .target = ok_block } });

    builder.setCurrentBlock(ok_block);
    const new_ptr_for_set = try loadLocal(&builder, new_ptr_local, layout.idx_type);
    try builder.emit(.{ .global_set = .{ .global = 0, .src = new_ptr_for_set } });
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
