const std = @import("std");
const mir = @import("mir.zig");
const mir_builder = @import("mir_builder.zig");
const types = @import("types.zig");
const wasm_heap = @import("wasm_heap.zig");
const wasm_module = @import("wasm_module.zig");

// Eliminates struct/array/variant JS-host object-table imports
// (`@runtime::struct_*`/`array_*`/`variant_*`) — replaces `.new_aggregate`/
// `.get_property`/`.set_property`/`.build_variant`/`.match_tag`/
// `.get_variant_field`/`.new_array`/`.get_index`/`.set_index` with real
// in-module linear-memory code, reusing `wasm_heap.zig`'s bump allocator
// (shared with `wasm_actors.zig` — both cooperate on the same global-0
// heap). Runs BEFORE `mir_cps.prepare` (data-structure lowering before
// control-flow-transform lowering — `mir_cps.zig`'s rewrite treats
// whatever it doesn't recognize as an ordinary pass-through instruction,
// so the order is safe either way, but this is the cleaner sequencing).
//
// Struct/variant representation: N contiguous 8-byte slots (same shape
// as an actor frame), bump-allocated. A struct's `field_index` (already
// a compile-time `u32`) maps DIRECTLY onto `frame_load`/`frame_store`'s
// existing `slot: u32` — no new instructions needed. A variant is the
// same shape with slot 0 reserved for the tag. This removes two real,
// existing limitations: the old host-import naming scheme
// (`struct_new_iff`-style) hard-capped structs at 3 fields and variants
// at 2 — the generic alloc+store sequence has no such cap.
//
// Array representation needs real dynamic growth, unlike structs/
// variants (fixed field count known at construction): a 3-slot header
// (`length`, `capacity`, `data_ptr`, all internally `idx_type`/i32) plus
// a SEPARATELY bump-allocated data buffer. `@array_ensure_capacity` is
// the one place needing a genuine (non-unrolled) WASM `loop` — but it's
// an ordinary single-header/single-exit shape (no CPS/suspend
// involved), so it hits `wasm_stackify.zig`'s existing fast path
// unchanged. The copy loop moves 8 raw bytes per element via `f64.load`/
// `f64.store` REGARDLESS of the array's real element type — reinterking
// an i32 handle's bit pattern as f64 for a pure load+store round-trip
// doesn't corrupt anything (no arithmetic touches the value), and it
// avoids needing two copy-loop variants.
//
// User-facing array indices are `Число` (f64); real memory addressing
// needs i32 — `mir.UnOp.to_i32`/`from_i32` (added alongside this file)
// convert at the boundary, once, inside the generic array functions.

fn unsupported(comptime what: []const u8) error{ObjectExpandUnsupported} {
    std.debug.print("panos build: AOT (wasm) объекты — " ++ what ++ "\n", .{});
    return error.ObjectExpandUnsupported;
}

const length_slot: u32 = 0;
const capacity_slot: u32 = 1;
const data_ptr_slot: u32 = 2;
const array_header_slots: u32 = 3;

pub const ArrayRuntime = struct {
    new: mir.FunctionId,
    ensure_capacity: mir.FunctionId,
    append_i32: mir.FunctionId,
    append_f64: mir.FunctionId,
    get_i32: mir.FunctionId,
    get_f64: mir.FunctionId,
    get_or_i32: mir.FunctionId,
    get_or_f64: mir.FunctionId,
    set_i32: mir.FunctionId,
    set_f64: mir.FunctionId,
    length: mir.FunctionId,
};

const ExpandCtx = struct {
    layout: wasm_heap.PtrLayout,
    type_store: *const types.TypeStore,
    array_runtime: ?ArrayRuntime,
};

pub fn expand(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore) !void {
    if (!usesObjects(module)) return;

    const layout = wasm_heap.PtrLayout{
        .ptr_type = type_store.builtins.string,
        .idx_type = type_store.builtins.boolean,
        .bool_type = type_store.builtins.boolean,
    };

    // `buildAllocInto` (structs/variants) needs `@runtime_alloc` too, not
    // just arrays — build it unconditionally whenever ANY object kind is
    // present (idempotent: a no-op if arrays already built it). Found via
    // a real crash: a struct/variant-only module (no arrays) never called
    // `buildArrayRuntime`, so `findFunctionByName(..., alloc_function_name)`
    // returned null and `buildAllocInto`'s `.?` unwrap panicked.
    _ = try wasm_heap.findOrBuildAlloc(allocator, module, type_store, layout);

    var array_runtime: ?ArrayRuntime = null;
    if (usesArrays(module)) array_runtime = try buildArrayRuntime(allocator, module, type_store, layout);

    // Snapshot the function id LIST before mutating — `buildArrayRuntime`
    // above already appended new functions to `module.functions`; those
    // new functions' own bodies never contain struct/array/variant
    // instructions THEMSELVES (hand-built, not user code), so it's safe
    // to just re-scan `module.functions.items` fresh each time below
    // rather than needing a frozen snapshot (unlike `mir_cps.zig`'s
    // block-splitting, nothing here appends MORE functions mid-walk).
    var index: usize = 0;
    while (index < module.functions.items.len) : (index += 1) {
        const function_id: mir.FunctionId = @enumFromInt(index);
        // Each function may belong to a DIFFERENT source module, hence a
        // DIFFERENT `types.TypeStore` instance (`TypeId.owner` is
        // deliberately store-specific — see `types.zig`'s own "makes
        // accidental cross-store use fail" doc comment). New locals
        // created below (`dst_local` etc.) must be typed against THIS
        // function's own store, not the caller-supplied top-level
        // `type_store` (only the ENTRY module's) — same cross-module bug
        // already found and fixed in `wasm_interfaces.zig`'s own
        // per-function derivation, found there while getting a prelude
        // default method (`Итерируемое::отобразить`, non-entry module)
        // to construct a struct for the first time ever — a silently
        // mistyped local (declared f64, holding a real i32 alloc
        // pointer) that only `wasmtime`'s own validator ever caught.
        // `array_runtime`'s OWN functions stay on the global entry store
        // — they're compiler-synthesized helpers, self-consistent
        // internally, and every CALLER already types their own `dst`
        // independently (same reasoning already established for
        // `@runtime_alloc`).
        const function_store = module.functions.items[index].type_store orelse type_store;
        const function_layout = wasm_heap.PtrLayout{
            .ptr_type = function_store.builtins.string,
            .idx_type = function_store.builtins.boolean,
            .bool_type = function_store.builtins.boolean,
        };
        const function_ctx = ExpandCtx{ .layout = function_layout, .type_store = function_store, .array_runtime = array_runtime };
        const block_count = module.functions.items[index].blocks.items.len;
        var block_index: usize = 0;
        while (block_index < block_count) : (block_index += 1) {
            var builder = mir_builder.Builder{ .module = module, .allocator = allocator, .function_id = function_id };
            try expandBlock(&builder, allocator, @enumFromInt(block_index), function_ctx);
        }
    }
}

fn usesObjects(module: *const mir.Module) bool {
    for (module.functions.items) |function| for (function.blocks.items) |block|
        for (block.instructions.items) |instruction| switch (instruction) {
            .new_aggregate, .get_property, .set_property, .build_variant, .match_tag, .get_variant_field, .new_array, .get_index, .set_index => return true,
            .call_builtin => |v| if (isArrayBuiltinCall(v.name)) return true,
            else => {},
        };
    return false;
}

fn usesArrays(module: *const mir.Module) bool {
    for (module.functions.items) |function| for (function.blocks.items) |block|
        for (block.instructions.items) |instruction| switch (instruction) {
            .new_array, .get_index, .set_index => return true,
            .call_builtin => |v| if (isArrayBuiltinCall(v.name)) return true,
            else => {},
        };
    return false;
}

// `.длина()`/`.добавить(x)`/`.получить(i, запасное)` array METHOD calls
// lower (`mir_lowering.zig`'s `lowerArrayMethodCall`) to a generic
// `.call_builtin{name="@runtime::array_*"}`, NOT `.new_array`/
// `.get_index`/`.set_index` (those three only cover array-LITERAL
// construction and `[]` subscripting) — found by actually running the
// smoke test and hitting `unknown import: env::array_append_f64`, not
// by reading alone. These names must be rewritten to real `.call`s
// against `ArrayRuntime`'s functions here, same as the instruction-kind
// forms above.
fn isArrayBuiltinCall(name: []const u8) bool {
    return std.mem.eql(u8, name, "@runtime::array_length") or
        std.mem.eql(u8, name, "@runtime::array_append_i32") or
        std.mem.eql(u8, name, "@runtime::array_append_f64") or
        std.mem.eql(u8, name, "@runtime::array_get_or_i32") or
        std.mem.eql(u8, name, "@runtime::array_get_or_f64");
}

// Rewrites `block_id`'s instructions in place, straight-line (struct/
// array/variant expansion never needs to split a block or touch its
// terminator — every instruction here becomes a short SEQUENCE at the
// SAME position, not new control flow; only the shared array runtime
// functions built once in `buildArrayRuntime` contain a real branch/
// loop).
fn expandBlock(builder: *mir_builder.Builder, allocator: std.mem.Allocator, block_id: mir.BlockId, ctx: ExpandCtx) !void {
    const function = builder.currentFunction();
    var original = function.blockConst(block_id).*;
    function.block(block_id).instructions = .empty;
    builder.setCurrentBlock(block_id);
    builder.terminated = false;

    for (original.instructions.items) |instruction| {
        try expandInstruction(builder, allocator, instruction, ctx);
    }
    builder.terminate(original.terminator);
    original.instructions.deinit(allocator);
}

fn expandInstruction(builder: *mir_builder.Builder, allocator: std.mem.Allocator, instruction: mir.Instruction, ctx: ExpandCtx) !void {
    const layout = ctx.layout;
    switch (instruction) {
        .new_aggregate => |v| {
            const dst_local = try buildAllocInto(builder, allocator, layout, @as(u32, @intCast(v.elements.len)) * 8);
            // Iterate elements in REVERSE. `v.elements` are all
            // PRE-EXISTING values (each field expression is evaluated
            // adjacent to the ORIGINAL, unexpanded `.new_aggregate`
            // instruction, in order) — meaning by the time this expansion
            // runs, they're ALL already sitting on the real WASM stack in
            // production order, with the LAST element topmost. Storing
            // element 0 FIRST (ascending) grabbed the wrong (topmost,
            // last-produced) value as `src` for `frame_store` — confirmed
            // via wasmtime as a genuine stack-corruption bug (a LATER,
            // unrelated instruction ended up consuming a stray leftover
            // value with the wrong type). Storing in reverse consumes
            // each element exactly when it's actually topmost; `slot`
            // still equals the element's own index, independent of
            // consumption order.
            var i = v.elements.len;
            while (i > 0) {
                i -= 1;
                const frame = try wasm_heap.loadLocal(builder, dst_local, layout.ptr_type);
                try builder.emit(.{ .frame_store = .{ .frame = frame, .slot = @intCast(i), .src = v.elements[i] } });
            }
            try builder.emit(.{ .load_local = .{ .dst = v.dst, .local = dst_local } });
        },
        .get_property => |v| {
            try builder.emit(.{ .frame_load = .{ .dst = v.dst, .frame = v.object, .slot = v.field_index } });
        },
        .set_property => |v| {
            try emitReorderedStore(builder, layout, v.object, v.value, v.field_index);
        },
        .build_variant => |v| {
            const dst_local = try buildAllocInto(builder, allocator, layout, (1 + @as(u32, @intCast(v.fields.len))) * 8);
            // `src` (`tag_const`) must be produced BEFORE `frame` (`tag_frame`)
            // — `frame_store` needs stack `[src, frame]` with `frame`
            // topmost/freshest (see `wasm_emit.zig`'s
            // `EmitContext.frame_store_scratch_frame` doc comment). The field
            // loop below already gets this right (its own `frame` reload sits
            // right before each `frame_store`, after the pre-existing
            // `field` value) — this tag-store had the two swapped, which
            // corrupted the real WASM stack (confirmed via wasmtime: caused
            // an unrelated later local to receive the wrong value/type,
            // "type mismatch: expected f64, found i32").
            // `v.fields` are pre-existing values too — same reverse-order
            // requirement as `.new_aggregate` above (stored AFTER the tag,
            // since the tag write happens first and is unaffected: `tag_const`
            // is produced fresh, right here, not a pre-existing value).
            var i = v.fields.len;
            while (i > 0) {
                i -= 1;
                const frame = try wasm_heap.loadLocal(builder, dst_local, layout.ptr_type);
                try builder.emit(.{ .frame_store = .{ .frame = frame, .slot = @intCast(1 + i), .src = v.fields[i] } });
            }
            const tag_const = try wasm_heap.addressConst(builder, layout.idx_type, v.tag);
            const tag_frame = try wasm_heap.loadLocal(builder, dst_local, layout.ptr_type);
            try builder.emit(.{ .frame_store = .{ .frame = tag_frame, .slot = 0, .src = tag_const } });
            try builder.emit(.{ .load_local = .{ .dst = v.dst, .local = dst_local } });
        },
        .match_tag => |v| {
            const tag_value = try builder.newValue(layout.idx_type);
            try builder.emit(.{ .frame_load = .{ .dst = tag_value, .frame = v.subject, .slot = 0 } });
            const tag_const = try wasm_heap.addressConst(builder, layout.idx_type, v.tag);
            try builder.emit(.{ .compare = .{ .dst = v.dst, .op = .equal, .lhs = tag_value, .rhs = tag_const } });
        },
        .get_variant_field => |v| {
            try builder.emit(.{ .frame_load = .{ .dst = v.dst, .frame = v.subject, .slot = 1 + v.field_index } });
        },
        .new_array => |v| {
            // `.copy` has NO codegen support in `wasm_emit.zig` at all
            // (Phase 2, per that file's own scope note) — found by
            // actually running this and hitting "вид MIR-инструкции при
            // подсчёте использований", not by reading alone. An earlier
            // fix routed around `.copy` by reusing `v.dst` directly as
            // the `@array_new` call's own result — but that then reused
            // `v.dst` a SECOND time internally (for the append-loop's
            // own reloads), double-consuming the SAME ValueId the
            // ORIGINAL instruction stream already has exactly one
            // consumer lined up for (e.g. `пер числа = ...`'s own
            // `store_local`) — a single-use violation
            // (`mir_validate.zig`: "v0 используется 2 раз(а)"), found
            // the same way. Fixed like `.new_aggregate`/`.build_variant`:
            // allocate into a FRESH internal value, do all internal work
            // through a local, and only produce `v.dst` at the very end
            // via one fresh `load_local`.
            const rt = ctx.array_runtime.?;
            const handle = try builder.newValue(layout.ptr_type);
            try builder.emit(.{ .call = .{ .dst = handle, .callee = rt.new, .args = &.{} } });
            const dst_local = try wasm_heap.storeLocal(builder, "@arr", layout.ptr_type, handle);
            for (v.elements) |element| {
                const is_i32 = wasm_module.wasmValTypeForStore(ctx.type_store, builder.currentFunction().valueType(element)) == wasm_module.wasm_i32;
                const append_fn = if (is_i32) rt.append_i32 else rt.append_f64;
                const arr = try wasm_heap.loadLocal(builder, dst_local, layout.ptr_type);
                try builder.emit(.{ .call = .{ .dst = null, .callee = append_fn, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ arr, element }) } });
            }
            try builder.emit(.{ .load_local = .{ .dst = v.dst, .local = dst_local } });
        },
        .get_index => |v| {
            const rt = ctx.array_runtime.?;
            const is_i32 = wasm_module.wasmValTypeForStore(ctx.type_store, builder.currentFunction().valueType(v.dst)) == wasm_module.wasm_i32;
            const get_fn = if (is_i32) rt.get_i32 else rt.get_f64;
            try builder.emit(.{ .call = .{ .dst = v.dst, .callee = get_fn, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ v.object, v.index }) } });
        },
        .set_index => |v| {
            const rt = ctx.array_runtime.?;
            const is_i32 = wasm_module.wasmValTypeForStore(ctx.type_store, builder.currentFunction().valueType(v.value)) == wasm_module.wasm_i32;
            const set_fn = if (is_i32) rt.set_i32 else rt.set_f64;
            // `object`/`index`/`value` are all pre-existing operands
            // (produced by their own earlier instructions, unmovable) —
            // no reordering issue here since `.call`'s `args` are
            // replayed in the EXACT order they're listed, matching
            // how they were ALREADY pushed by the original (unmodified)
            // instruction stream — unlike `frame_store`/`mem_store`,
            // `.call` doesn't impose a fixed field-vs-freshness
            // convention.
            try builder.emit(.{ .call = .{ .dst = null, .callee = set_fn, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ v.object, v.index, v.value }) } });
        },
        .call_builtin => |v| if (isArrayBuiltinCall(v.name)) {
            const rt = ctx.array_runtime.?;
            // `args`/`dst` are all pre-existing operands (already produced
            // by the original instruction stream, in the ORIGINAL order) —
            // `.call`'s args replay in exactly the order listed, same as
            // `.get_index`/`.set_index` above, so no reordering needed.
            const callee = if (std.mem.eql(u8, v.name, "@runtime::array_length"))
                rt.length
            else if (std.mem.eql(u8, v.name, "@runtime::array_append_i32"))
                rt.append_i32
            else if (std.mem.eql(u8, v.name, "@runtime::array_append_f64"))
                rt.append_f64
            else if (std.mem.eql(u8, v.name, "@runtime::array_get_or_i32"))
                rt.get_or_i32
            else
                rt.get_or_f64;
            try builder.emit(.{ .call = .{ .dst = v.dst, .callee = callee, .args = v.args } });
        } else {
            try builder.emit(instruction);
        },
        else => try builder.emit(instruction),
    }
}

// `.new_aggregate`/`.build_variant`: `dst` is a BRAND NEW value (the
// alloc call's own result) — reused multiple times below (once per
// field store), so it needs the same store-once/reload-fresh treatment
// as everywhere else in this codebase's hand-built MIR (single-use
// invariant). Returns the local holding it.
// Real bug found running actual code, not just reading: the ORIGINAL
// version of this function used the CALLER-supplied `dst` ValueId
// directly as the alloc call's own result, then ALSO consumed it once
// more internally (`storeLocal`) for repeated field-store reloads —
// but `dst` is the SAME ValueId the ORIGINAL (pre-expansion) instruction
// stream already has EXACTLY ONE consumer lined up for (e.g. `пер задача
// = Задача(...)`'s own `store_local`), immediately after where
// `.new_aggregate`/`.build_variant` used to sit. Consuming it a SECOND
// time here violated the single-use invariant
// (`mir_validate.zig`: "v0 используется 2 раз(а)"). Fixed: allocate into
// a FRESH internal value instead, do all internal work through a local
// holding THAT, and only at the very end — via the returned `LocalId`
// — the caller must emit `load_local{dst, local}` to make the
// caller-supplied `dst` valid, freshly, exactly once, at the position
// the original instruction occupied.
fn buildAllocInto(builder: *mir_builder.Builder, allocator: std.mem.Allocator, layout: wasm_heap.PtrLayout, size: u32) !mir.LocalId {
    _ = allocator;
    const size_const = try wasm_heap.addressConst(builder, layout.idx_type, size);
    const alloc_id = wasm_heap.findFunctionByName(builder.module, wasm_heap.alloc_function_name).?;
    const handle = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = handle, .callee = alloc_id, .args = try wasm_heap.dupeOne(builder.module, size_const) } });
    return wasm_heap.storeLocal(builder, "@obj", layout.ptr_type, handle);
}

// `set_property`'s `object`/`value` are BOTH pre-existing operands
// (produced by their own earlier instructions, in the ORIGINAL order
// `object` then `value` — matching the old host-import codegen's own
// documented `(handle, value, field)` call convention). `frame_store`
// codegen needs the OPPOSITE: `frame` (here, `object`) must be the
// MORE-RECENTLY-pushed of the two. Since neither operand's producer can
// be moved, swap them via two temp locals — pop `value` (currently on
// top) into a local, pop `object` (now exposed) into another, then push
// `value` first and `object` second, giving `frame_store` exactly the
// `[src, frame]` order it needs. Found by tracing through the SAME
// operand-order reasoning that `wasm_emit.zig`'s `EmitContext.
// frame_store_scratch_frame` doc comment already documents for
// `mir_cps.zig`'s own frame_store construction — this is the one place
// in THIS file where the "fresh value is always last" shortcut used
// everywhere else doesn't apply, because BOTH operands are pre-existing.
fn emitReorderedStore(builder: *mir_builder.Builder, layout: wasm_heap.PtrLayout, object: mir.ValueId, value: mir.ValueId, field_index: u32) !void {
    const value_type = builder.currentFunction().valueType(value);
    const value_local = try wasm_heap.storeLocal(builder, "@val", value_type, value);
    const object_local = try wasm_heap.storeLocal(builder, "@obj", layout.ptr_type, object);
    const value_reload = try wasm_heap.loadLocal(builder, value_local, value_type);
    const object_reload = try wasm_heap.loadLocal(builder, object_local, layout.ptr_type);
    try builder.emit(.{ .frame_store = .{ .frame = object_reload, .slot = field_index, .src = value_reload } });
}

// --- Array runtime -------------------------------------------------------

// Public + idempotent (unlike `wasm_heap.findOrBuildAlloc`'s own
// no-caching rationale, an `ArrayRuntime` has 11 functions to re-find by
// name — worth a real name-lookup short-circuit instead of re-deriving
// each field individually): callable from `wasm_strings.zig` too
// (`разбить` returns `Массив(Строка)`, needs `@array_new`/
// `@array_append_i32`), for a module that has NO other array usage of
// its own — `wasm_objects.expand`'s own `usesArrays` gate only scans
// for `.new_array`/`.get_index`/`.set_index`/`@runtime::array_*`, which
// a still-unexpanded `строки::разбить` call doesn't match yet (it only
// becomes an array-returning call AFTER `wasm_strings.expand` rewrites
// it) — so `wasm_objects.expand` may have skipped building the array
// runtime entirely by the time `wasm_strings.expand` runs.
pub fn findOrBuildArrayRuntime(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout) !ArrayRuntime {
    if (wasm_heap.findFunctionByName(module, "@array_new")) |new_id| {
        return .{
            .new = new_id,
            .ensure_capacity = wasm_heap.findFunctionByName(module, "@array_ensure_capacity").?,
            .append_i32 = wasm_heap.findFunctionByName(module, "@array_append_i32").?,
            .append_f64 = wasm_heap.findFunctionByName(module, "@array_append_f64").?,
            .get_i32 = wasm_heap.findFunctionByName(module, "@array_get_i32").?,
            .get_f64 = wasm_heap.findFunctionByName(module, "@array_get_f64").?,
            .get_or_i32 = wasm_heap.findFunctionByName(module, "@array_get_or_i32").?,
            .get_or_f64 = wasm_heap.findFunctionByName(module, "@array_get_or_f64").?,
            .set_i32 = wasm_heap.findFunctionByName(module, "@array_set_i32").?,
            .set_f64 = wasm_heap.findFunctionByName(module, "@array_set_f64").?,
            .length = wasm_heap.findFunctionByName(module, "@array_length").?,
        };
    }
    return buildArrayRuntime(allocator, module, type_store, layout);
}

fn buildArrayRuntime(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout) !ArrayRuntime {
    _ = try wasm_heap.findOrBuildAlloc(allocator, module, type_store, layout);
    const new_fn = try buildArrayNew(allocator, module, type_store, layout);
    const ensure = try buildEnsureCapacity(allocator, module, type_store, layout);
    const append_i32 = try buildAppend(allocator, module, type_store, layout, "@array_append_i32", layout.ptr_type, ensure);
    const append_f64 = try buildAppend(allocator, module, type_store, layout, "@array_append_f64", type_store.builtins.number, ensure);
    const get_i32 = try buildGet(allocator, module, type_store, layout, "@array_get_i32", layout.ptr_type);
    const get_f64 = try buildGet(allocator, module, type_store, layout, "@array_get_f64", type_store.builtins.number);
    const get_or_i32 = try buildGetOr(allocator, module, type_store, layout, "@array_get_or_i32", layout.ptr_type);
    const get_or_f64 = try buildGetOr(allocator, module, type_store, layout, "@array_get_or_f64", type_store.builtins.number);
    const set_i32 = try buildSet(allocator, module, type_store, layout, "@array_set_i32", layout.ptr_type);
    const set_f64 = try buildSet(allocator, module, type_store, layout, "@array_set_f64", type_store.builtins.number);
    const length_fn = try buildLength(allocator, module, type_store, layout);
    return .{
        .new = new_fn,
        .ensure_capacity = ensure,
        .append_i32 = append_i32,
        .append_f64 = append_f64,
        .get_i32 = get_i32,
        .get_f64 = get_f64,
        .get_or_i32 = get_or_i32,
        .get_or_f64 = get_or_f64,
        .set_i32 = set_i32,
        .set_f64 = set_f64,
        .length = length_fn,
    };
}

fn buildArrayNew(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@array_new", wasm_heap.dummy_symbol, layout.ptr_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    builder.currentFunction().parameters = &.{};
    builder.currentFunction().type_store = type_store;

    const size_const = try wasm_heap.addressConst(&builder, layout.idx_type, array_header_slots * 8);
    const alloc_id = wasm_heap.findFunctionByName(module, wasm_heap.alloc_function_name).?;
    const handle = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = handle, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, size_const) } });
    const handle_local = try wasm_heap.storeLocal(&builder, "@h", layout.ptr_type, handle);

    inline for (.{ length_slot, capacity_slot, data_ptr_slot }) |slot| {
        const zero = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
        const frame = try wasm_heap.loadLocal(&builder, handle_local, layout.ptr_type);
        try builder.emit(.{ .frame_store = .{ .frame = frame, .slot = slot, .src = zero } });
    }
    const result = try wasm_heap.loadLocal(&builder, handle_local, layout.ptr_type);
    builder.terminate(.{ .return_value = .{ .value = result } });
    return id;
}

// The one place needing a genuine (non-unrolled) WASM `loop` — element
// count is only known at runtime. Ordinary single-header/single-exit
// shape (no suspend/CPS involved), matching `mir_lowering.zig`'s own
// `lowerWhile` output exactly (jump into header, header branches to
// body/exit, body ends with a jump back to header) — hits `wasm_stackify
// .zig`'s existing fast path (`identifyLoopBodyAndExit`) unchanged.
fn buildEnsureCapacity(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@array_ensure_capacity", wasm_heap.dummy_symbol, type_store.builtins.void, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const handle_local = try builder.newLocal(wasm_heap.dummy_symbol, "handle", layout.ptr_type);
    const needed_local = try builder.newLocal(wasm_heap.dummy_symbol, "needed", layout.idx_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{ handle_local, needed_local });
    builder.currentFunction().type_store = type_store;

    const alloc_id = wasm_heap.findFunctionByName(module, wasm_heap.alloc_function_name).?;

    const frame1 = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    const capacity = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .frame_load = .{ .dst = capacity, .frame = frame1, .slot = capacity_slot } });
    const needed = try wasm_heap.loadLocal(&builder, needed_local, layout.idx_type);
    const enough = try wasm_heap.cmpOp(&builder, layout.bool_type, .greater_equal, capacity, needed);

    const grow_block = try builder.newBlock();
    const skip_block = try builder.newBlock();
    const after_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = enough, .then_block = skip_block, .else_block = grow_block } });

    builder.setCurrentBlock(skip_block);
    builder.terminate(.{ .jump = .{ .target = after_block } });

    builder.setCurrentBlock(grow_block);
    // Simplified on purpose: `new_capacity = needed`, no amortized
    // doubling. O(n^2) for repeated single-element appends in the worst
    // case, but correct and MUCH smaller branch surface than a max(needed,
    // capacity*2, 4) computation — given how much of this session's real
    // bugs came from exactly this kind of hand-authored branch/reorder
    // logic, favoring simplicity here. Revisit only if this turns out to
    // matter in practice.
    const new_cap_bytes_src = try wasm_heap.loadLocal(&builder, needed_local, layout.idx_type);
    const eight = try wasm_heap.addressConst(&builder, layout.idx_type, 8);
    const new_cap_bytes = try wasm_heap.binOp(&builder, layout.idx_type, .multiply, new_cap_bytes_src, eight);
    const new_data = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = new_data, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, new_cap_bytes) } });
    const new_data_local = try wasm_heap.storeLocal(&builder, "@newdata", layout.ptr_type, new_data);

    // Copy loop: i = 0; while i < length { new_data[i] = old_data[i]; i += 1; }
    const length_for_loop = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    const length = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .frame_load = .{ .dst = length, .frame = length_for_loop, .slot = length_slot } });
    const length_local = try wasm_heap.storeLocal(&builder, "@len", layout.idx_type, length);
    const old_data_for_loop = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    const old_data = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .frame_load = .{ .dst = old_data, .frame = old_data_for_loop, .slot = data_ptr_slot } });
    const old_data_local = try wasm_heap.storeLocal(&builder, "@olddata", layout.ptr_type, old_data);
    const i_local = try builder.newLocal(wasm_heap.dummy_symbol, "@i", layout.idx_type);
    const zero_i = try wasm_heap.addressConst(&builder, layout.idx_type, 0);
    try builder.emit(.{ .store_local = .{ .local = i_local, .src = zero_i } });

    const loop_header = try builder.newBlock();
    builder.terminate(.{ .jump = .{ .target = loop_header } });

    builder.setCurrentBlock(loop_header);
    const i_for_cmp = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const length_for_cmp = try wasm_heap.loadLocal(&builder, length_local, layout.idx_type);
    const keep_going = try wasm_heap.cmpOp(&builder, layout.bool_type, .less, i_for_cmp, length_for_cmp);
    const loop_body = try builder.newBlock();
    const loop_exit = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = keep_going, .then_block = loop_body, .else_block = loop_exit } });

    builder.setCurrentBlock(loop_body);
    // 8-byte raw copy via f64 load/store REGARDLESS of real element type
    // — reinterpreting an i32 handle's bit pattern as f64 for a pure
    // round-trip (no arithmetic) doesn't corrupt anything, and avoids
    // needing two copy-loop variants (see file doc comment).
    const i_for_addr1 = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const eight_a = try wasm_heap.addressConst(&builder, layout.idx_type, 8);
    const i_bytes_old = try wasm_heap.binOp(&builder, layout.idx_type, .multiply, i_for_addr1, eight_a);
    const old_data_for_addr = try wasm_heap.loadLocal(&builder, old_data_local, layout.ptr_type);
    const old_addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, old_data_for_addr, i_bytes_old);
    const elem = try builder.newValue(type_store.builtins.number);
    try builder.emit(.{ .mem_load = .{ .dst = elem, .addr = old_addr } });
    // `elem` (src) reloaded BEFORE `new_addr` is computed — `mem_store`
    // needs stack order `[src, addr]` (addr topmost, freshest — see
    // `EmitContext.frame_store_scratch_frame`'s doc comment in
    // `wasm_emit.zig`, the same convention `mem_store` shares).
    const elem_local = try wasm_heap.storeLocal(&builder, "@elem", type_store.builtins.number, elem);
    const elem_reload = try wasm_heap.loadLocal(&builder, elem_local, type_store.builtins.number);

    const i_for_addr2 = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const eight_b = try wasm_heap.addressConst(&builder, layout.idx_type, 8);
    const i_bytes_new = try wasm_heap.binOp(&builder, layout.idx_type, .multiply, i_for_addr2, eight_b);
    const new_data_for_addr = try wasm_heap.loadLocal(&builder, new_data_local, layout.ptr_type);
    const new_addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, new_data_for_addr, i_bytes_new);
    try builder.emit(.{ .mem_store = .{ .addr = new_addr, .src = elem_reload } });

    const i_next = try wasm_heap.loadLocal(&builder, i_local, layout.idx_type);
    const one = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const i_incremented = try wasm_heap.binOp(&builder, layout.idx_type, .add, i_next, one);
    try builder.emit(.{ .store_local = .{ .local = i_local, .src = i_incremented } });
    builder.terminate(.{ .jump = .{ .target = loop_header } });

    builder.setCurrentBlock(loop_exit);
    const new_cap_for_store = try wasm_heap.loadLocal(&builder, needed_local, layout.idx_type);
    const handle_for_cap = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    try builder.emit(.{ .frame_store = .{ .frame = handle_for_cap, .slot = capacity_slot, .src = new_cap_for_store } });
    const new_data_for_store = try wasm_heap.loadLocal(&builder, new_data_local, layout.ptr_type);
    const handle_for_data = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    try builder.emit(.{ .frame_store = .{ .frame = handle_for_data, .slot = data_ptr_slot, .src = new_data_for_store } });
    builder.terminate(.{ .jump = .{ .target = after_block } });

    builder.setCurrentBlock(after_block);
    builder.terminate(.{ .return_value = .{ .value = null } });
    return id;
}

fn buildAppend(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout, name: []const u8, payload_type: types.TypeId, ensure_capacity: mir.FunctionId) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, name, wasm_heap.dummy_symbol, type_store.builtins.void, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const handle_local = try builder.newLocal(wasm_heap.dummy_symbol, "handle", layout.ptr_type);
    const value_local = try builder.newLocal(wasm_heap.dummy_symbol, "value", payload_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{ handle_local, value_local });
    builder.currentFunction().type_store = type_store;

    const frame_for_length = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    const length = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .frame_load = .{ .dst = length, .frame = frame_for_length, .slot = length_slot } });
    const length_local = try wasm_heap.storeLocal(&builder, "@len", layout.idx_type, length);

    // `.call`'s own operands must be PRODUCED in parameter order (each
    // arg's producing instruction pushes it — `.call`'s codegen does
    // nothing itself, see `wasm_emit.zig`'s own comment: "already on
    // the stack, same convention as `.call_value`") — `handle` first,
    // `needed` second, matching `@array_ensure_capacity(handle, needed)`.
    const handle_for_ensure = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    const length_for_needed = try wasm_heap.loadLocal(&builder, length_local, layout.idx_type);
    const one = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const needed = try wasm_heap.binOp(&builder, layout.idx_type, .add, length_for_needed, one);
    try builder.emit(.{ .call = .{ .dst = null, .callee = ensure_capacity, .args = try builder.module.arena.allocator().dupe(mir.ValueId, &.{ handle_for_ensure, needed }) } });

    // `value` reloaded BEFORE `addr` is computed — `mem_store` needs
    // `[src, addr]` (addr topmost/freshest).
    const value_reload = try wasm_heap.loadLocal(&builder, value_local, payload_type);
    const length_for_addr = try wasm_heap.loadLocal(&builder, length_local, layout.idx_type);
    const eight = try wasm_heap.addressConst(&builder, layout.idx_type, 8);
    const byte_offset = try wasm_heap.binOp(&builder, layout.idx_type, .multiply, length_for_addr, eight);
    const frame_for_data = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    const data_ptr = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .frame_load = .{ .dst = data_ptr, .frame = frame_for_data, .slot = data_ptr_slot } });
    const addr = try wasm_heap.binOp(&builder, layout.idx_type, .add, data_ptr, byte_offset);
    try builder.emit(.{ .mem_store = .{ .addr = addr, .src = value_reload } });

    const length_for_inc = try wasm_heap.loadLocal(&builder, length_local, layout.idx_type);
    const one_again = try wasm_heap.addressConst(&builder, layout.idx_type, 1);
    const length_new = try wasm_heap.binOp(&builder, layout.idx_type, .add, length_for_inc, one_again);
    const frame_for_store = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    try builder.emit(.{ .frame_store = .{ .frame = frame_for_store, .slot = length_slot, .src = length_new } });
    builder.terminate(.{ .return_value = .{ .value = null } });
    return id;
}

// Bounds-check helper shared by get/get_or/set: `index` (Число, f64,
// user-supplied) converted to i32 once, compared against `length`.
// Returns the i32 index as a LOCAL (not a bare `ValueId`) — `fits` is
// consumed immediately by the caller's branch terminator, but the index
// is only needed LATER, inside the branch's true-arm (`elementAddr`),
// crossing a block boundary. A `ValueId` produced here and consumed
// after a block boundary is invalid under the stack-replay convention
// (confirmed via wasmtime: caused "type mismatch"/"nothing on stack"
// errors) — callers must reload fresh via `wasm_heap.loadLocal` at their
// own use site instead.
fn boundsCheck(builder: *mir_builder.Builder, layout: wasm_heap.PtrLayout, handle_local: mir.LocalId, index_local: mir.LocalId) !struct { index_local: mir.LocalId, fits: mir.ValueId } {
    const index_f64 = try wasm_heap.loadLocal(builder, index_local, builder.currentFunction().type_store.?.builtins.number);
    const index_i32 = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .unary = .{ .dst = index_i32, .op = .to_i32, .src = index_f64 } });
    const index_local2 = try wasm_heap.storeLocal(builder, "@idx", layout.idx_type, index_i32);
    const index_for_cmp = try wasm_heap.loadLocal(builder, index_local2, layout.idx_type);
    const in_bounds_low = try wasm_heap.addressConst(builder, layout.idx_type, 0);
    const not_negative = try wasm_heap.cmpOp(builder, layout.bool_type, .greater_equal, index_for_cmp, in_bounds_low);
    // `length` computed and used immediately adjacent to `less_than_length`
    // below (no other value produced/consumed in between) — earlier this
    // was computed BEFORE `not_negative`'s operands, which buried it under
    // them on the real WASM stack (single-use SSA values are genuine stack
    // values, not registers; confirmed corrupting the stack via wasmtime).
    const index_for_cmp2 = try wasm_heap.loadLocal(builder, index_local2, layout.idx_type);
    const frame_for_length = try wasm_heap.frameValue(builder, handle_local, layout.ptr_type);
    const length = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .frame_load = .{ .dst = length, .frame = frame_for_length, .slot = length_slot } });
    const less_than_length = try wasm_heap.cmpOp(builder, layout.bool_type, .less, index_for_cmp2, length);
    const fits = try wasm_heap.binOp(builder, layout.bool_type, .bit_and, not_negative, less_than_length);
    return .{ .index_local = index_local2, .fits = fits };
}

fn elementAddr(builder: *mir_builder.Builder, layout: wasm_heap.PtrLayout, handle_local: mir.LocalId, index_i32: mir.ValueId) !mir.ValueId {
    const eight = try wasm_heap.addressConst(builder, layout.idx_type, 8);
    const byte_offset = try wasm_heap.binOp(builder, layout.idx_type, .multiply, index_i32, eight);
    const frame_for_data = try wasm_heap.frameValue(builder, handle_local, layout.ptr_type);
    const data_ptr = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .frame_load = .{ .dst = data_ptr, .frame = frame_for_data, .slot = data_ptr_slot } });
    return wasm_heap.binOp(builder, layout.idx_type, .add, data_ptr, byte_offset);
}

// Out-of-bounds traps (matches the old JS host's `RangeError` throw for
// plain getters — see this file's own doc comment on `wasm_objects.zig`'s
// design: a real, accepted Phase-1 gap, same class as `to_i32`'s own
// trap-on-overflow).
fn buildGet(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout, name: []const u8, payload_type: types.TypeId) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, name, wasm_heap.dummy_symbol, payload_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const handle_local = try builder.newLocal(wasm_heap.dummy_symbol, "handle", layout.ptr_type);
    const index_local = try builder.newLocal(wasm_heap.dummy_symbol, "index", type_store.builtins.number);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{ handle_local, index_local });
    builder.currentFunction().type_store = type_store;

    const bounds = try boundsCheck(&builder, layout, handle_local, index_local);
    const ok_block = try builder.newBlock();
    const trap_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = bounds.fits, .then_block = ok_block, .else_block = trap_block } });

    builder.setCurrentBlock(trap_block);
    builder.terminate(.{ .unreachable_term = .{ .reason = "массив: индекс вне диапазона" } });

    builder.setCurrentBlock(ok_block);
    const index_reload = try wasm_heap.loadLocal(&builder, bounds.index_local, layout.idx_type);
    const addr = try elementAddr(&builder, layout, handle_local, index_reload);
    const value = try builder.newValue(payload_type);
    try builder.emit(.{ .mem_load = .{ .dst = value, .addr = addr } });
    builder.terminate(.{ .return_value = .{ .value = value } });
    return id;
}

fn buildGetOr(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout, name: []const u8, payload_type: types.TypeId) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, name, wasm_heap.dummy_symbol, payload_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const handle_local = try builder.newLocal(wasm_heap.dummy_symbol, "handle", layout.ptr_type);
    const index_local = try builder.newLocal(wasm_heap.dummy_symbol, "index", type_store.builtins.number);
    const fallback_local = try builder.newLocal(wasm_heap.dummy_symbol, "fallback", payload_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{ handle_local, index_local, fallback_local });
    builder.currentFunction().type_store = type_store;

    const bounds = try boundsCheck(&builder, layout, handle_local, index_local);
    const ok_block = try builder.newBlock();
    const fallback_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = bounds.fits, .then_block = ok_block, .else_block = fallback_block } });

    builder.setCurrentBlock(ok_block);
    const index_reload = try wasm_heap.loadLocal(&builder, bounds.index_local, layout.idx_type);
    const addr = try elementAddr(&builder, layout, handle_local, index_reload);
    const value = try builder.newValue(payload_type);
    try builder.emit(.{ .mem_load = .{ .dst = value, .addr = addr } });
    builder.terminate(.{ .return_value = .{ .value = value } });

    builder.setCurrentBlock(fallback_block);
    const fallback = try wasm_heap.loadLocal(&builder, fallback_local, payload_type);
    builder.terminate(.{ .return_value = .{ .value = fallback } });
    return id;
}

fn buildSet(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout, name: []const u8, payload_type: types.TypeId) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, name, wasm_heap.dummy_symbol, type_store.builtins.void, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const handle_local = try builder.newLocal(wasm_heap.dummy_symbol, "handle", layout.ptr_type);
    const index_local = try builder.newLocal(wasm_heap.dummy_symbol, "index", type_store.builtins.number);
    const value_local = try builder.newLocal(wasm_heap.dummy_symbol, "value", payload_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{ handle_local, index_local, value_local });
    builder.currentFunction().type_store = type_store;

    const bounds = try boundsCheck(&builder, layout, handle_local, index_local);
    const ok_block = try builder.newBlock();
    const trap_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = bounds.fits, .then_block = ok_block, .else_block = trap_block } });

    builder.setCurrentBlock(trap_block);
    builder.terminate(.{ .unreachable_term = .{ .reason = "массив: индекс вне диапазона" } });

    builder.setCurrentBlock(ok_block);
    // `value` reloaded BEFORE `addr` is computed — `mem_store` needs
    // `[src, addr]` (addr topmost/freshest).
    const value_reload = try wasm_heap.loadLocal(&builder, value_local, payload_type);
    const index_reload = try wasm_heap.loadLocal(&builder, bounds.index_local, layout.idx_type);
    const addr = try elementAddr(&builder, layout, handle_local, index_reload);
    try builder.emit(.{ .mem_store = .{ .addr = addr, .src = value_reload } });
    builder.terminate(.{ .return_value = .{ .value = null } });
    return id;
}

fn buildLength(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout) !mir.FunctionId {
    const id = try mir_builder.newFunction(module, allocator, "@array_length", wasm_heap.dummy_symbol, type_store.builtins.number, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const handle_local = try builder.newLocal(wasm_heap.dummy_symbol, "handle", layout.ptr_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{handle_local});
    builder.currentFunction().type_store = type_store;

    const frame = try wasm_heap.frameValue(&builder, handle_local, layout.ptr_type);
    const length_i32 = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .frame_load = .{ .dst = length_i32, .frame = frame, .slot = length_slot } });
    const length_f64 = try builder.newValue(type_store.builtins.number);
    try builder.emit(.{ .unary = .{ .dst = length_f64, .op = .from_i32, .src = length_i32 } });
    builder.terminate(.{ .return_value = .{ .value = length_f64 } });
    return id;
}
