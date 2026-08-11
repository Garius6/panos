const std = @import("std");
const mir = @import("mir.zig");
const mir_cfg = @import("mir_cfg.zig");
const mir_validate = @import("mir_validate.zig");
const type_checker = @import("type_checker.zig");
const types = @import("types.zig");
const wasm_module = @import("wasm_module.zig");
const wasm_stackify = @import("wasm_stackify.zig");

// Ported from `core/wasm_emit.odin` (~1922 lines there) — scoped to
// EXACTLY what `mir_lowering.zig` can produce (see that file's own scope
// note): number/boolean constants, locals, arithmetic/comparison/unary
// operators, `если`/`пока`, direct function calls, `возврат`. No
// aggregates/arrays/maps/interfaces/closures/`?`-operator/strings —
// those need an object-table runtime (`pw_alloc_aggregate` etc. in the
// Odin original) that doesn't exist on this side yet. Anything MIR
// contains outside this set is a lowering bug, not an emission gap — MIR
// can't contain it in the first place (`mir_lowering.zig`'s `unsupported`
// panics before such an instruction is ever built).

const ScopeKind = enum { loop, if_scope };
const Scope = struct { kind: ScopeKind, header: mir.BlockId = mir.invalid_block };

const EmitContext = struct {
    allocator: std.mem.Allocator,
    checked: *const type_checker.CheckResult,
    type_store: *const types.TypeStore,
    function: *const mir.Function,
    func_index: *const std.AutoHashMap(mir.FunctionId, u32),
    cfg: mir_cfg.CfgInfo,
    rpo_index: std.AutoHashMap(mir.BlockId, usize),
    idom: std.AutoHashMap(mir.BlockId, mir.BlockId),
    visited: std.AutoHashMap(mir.BlockId, void),
    scope_stack: std.ArrayList(Scope) = .empty,
    code: std.ArrayList(u8) = .empty,
    // `Function_Ref_Instr` has no WASM-level stack representation on its
    // own (no closure/table support yet) — it only ever feeds a
    // STATICALLY known `call_value` immediately after (that's the only
    // shape `mir_lowering.zig`'s `lowerCall` ever produces). Recorded here
    // instead of pushed onto the WASM stack; `call_value` looks the
    // callee up here and emits a direct `call`.
    value_to_function: std.AutoHashMap(mir.ValueId, mir.FunctionId),
    use_count: std.AutoHashMap(mir.ValueId, u32),
    // `call_builtin`'s "модуль::имя" (`time_now`/`time_monotonic`
    // строки) → WASM import function index — empty for any module that
    // never calls a builtin (the common case; see `collectBuiltinNames`).
    builtin_index: *const std.StringHashMap(u32),
    // Every string CONSTANT literal in the module → its byte offset into
    // the module's own static data section (see `collectStringConstants`)
    // — empty for any module with no string literals at all.
    string_offsets: *const std.StringHashMap(u32),
    // Lazily reserved the first time a function needs `%`/bitwise ops
    // (see `.binary`'s `.modulo`/`.bit_*`/`.shift_*` cases) — WASM's f64
    // has no modulo/bitwise instructions at all, only i32/i64 do, and
    // Phase-1a numbers are uniformly f64 (see `.binary`'s own comment on
    // that convention). Converting BOTH operands to i32 needs a scratch
    // local: they're already both live on the WASM value stack by the
    // time this instruction runs (stack machine — no way to reach the
    // BOTTOM one, `lhs`, without first popping the top one, `rhs`,
    // somewhere). One local suffices for a whole function — each use is
    // fully consumed (stored then immediately reloaded) before the next,
    // never overlapping. Declared in the function's local section by
    // `emitFunctionWasm` only if `scratch_i32_local != null` after the
    // body's been fully emitted (its index is fixed the moment it's
    // first reserved: `function.locals.items.len`, i.e. right past every
    // real MIR local).
    scratch_i32_local: ?u32 = null,

    fn reserveScratchLocal(self: *EmitContext) u32 {
        if (self.scratch_i32_local) |index| return index;
        const index: u32 = @intCast(self.function.locals.items.len);
        self.scratch_i32_local = index;
        return index;
    }

    fn init(allocator: std.mem.Allocator, checked: *const type_checker.CheckResult, function: *const mir.Function, func_index: *const std.AutoHashMap(mir.FunctionId, u32), builtin_index: *const std.StringHashMap(u32), string_offsets: *const std.StringHashMap(u32)) !EmitContext {
        var cfg = try mir_cfg.computeCfgInfo(allocator, function);
        errdefer cfg.deinit();
        var rpo_index = try wasm_stackify.buildRpoIndex(allocator, &cfg);
        errdefer rpo_index.deinit();
        var idom = try wasm_stackify.computeIdom(allocator, function, &cfg, &rpo_index);
        errdefer idom.deinit();
        const use_count = try computeUseCount(allocator, function);
        return .{
            .allocator = allocator,
            .checked = checked,
            .type_store = function.type_store orelse &checked.types,
            .function = function,
            .func_index = func_index,
            .cfg = cfg,
            .rpo_index = rpo_index,
            .idom = idom,
            .visited = .init(allocator),
            .value_to_function = .init(allocator),
            .use_count = use_count,
            .builtin_index = builtin_index,
            .string_offsets = string_offsets,
        };
    }

    fn deinit(self: *EmitContext) void {
        self.use_count.deinit();
        self.value_to_function.deinit();
        self.code.deinit(self.allocator);
        self.scope_stack.deinit(self.allocator);
        self.visited.deinit();
        self.idom.deinit();
        self.rpo_index.deinit();
        self.cfg.deinit();
        self.* = undefined;
    }
};

// Same treatment as `mir_lowering.zig`'s `unsupported()` (see that
// file's doc comment) — was `@panic`, crashed the whole `panos build
// --target=wasm` process with a Zig stack trace on any Phase-1a
// codegen gap (found running the actual motivating case for the
// struct-methods feature: `std/математика.pns`'s `Генератор.
// следующее()` PRNG uses `%`/bitwise ops, which this backend's
// arithmetic emission doesn't cover yet — a genuinely separate,
// pre-existing gap from method dispatch itself). `cli/main.zig`
// already wraps `emitModule(...)` in a `catch |err| { print; exit(1);
// }` (needed for its OTHER failure modes already) — no caller-side
// change needed here, just stop crashing.
fn unsupported(comptime what: []const u8) error{WasmEmitUnsupported} {
    std.debug.print("panos build: AOT (wasm) кодогенерация не поддерживает — " ++ what ++ "\n", .{});
    return error.WasmEmitUnsupported;
}

fn countUse(counts: *std.AutoHashMap(mir.ValueId, u32), value: mir.ValueId) !void {
    const entry = try counts.getOrPutValue(value, 0);
    entry.value_ptr.* += 1;
}

// Only the operand shapes Phase-1a MIR can contain — see this file's own
// doc comment for why an exhaustive `mir.Instruction`/`mir.Terminator`
// switch isn't needed (lowering never produces anything else).
fn computeUseCount(allocator: std.mem.Allocator, function: *const mir.Function) !std.AutoHashMap(mir.ValueId, u32) {
    var counts: std.AutoHashMap(mir.ValueId, u32) = .init(allocator);
    for (function.blocks.items) |block| {
        for (block.instructions.items) |instruction| {
            switch (instruction) {
                .store_local => |store| try countUse(&counts, store.src),
                .binary => |binary| {
                    try countUse(&counts, binary.lhs);
                    try countUse(&counts, binary.rhs);
                },
                .compare => |compare| {
                    try countUse(&counts, compare.lhs);
                    try countUse(&counts, compare.rhs);
                },
                .unary => |unary| try countUse(&counts, unary.src),
                .call_value => |call| {
                    try countUse(&counts, call.callee);
                    for (call.args) |arg| try countUse(&counts, arg);
                },
                .call_builtin => |call| for (call.args) |arg| try countUse(&counts, arg),
                .new_aggregate => |aggregate| for (aggregate.elements) |element| try countUse(&counts, element),
                .get_property => |property| try countUse(&counts, property.object),
                .set_property => |property| {
                    try countUse(&counts, property.object);
                    try countUse(&counts, property.value);
                },
                .new_array => |array| for (array.elements) |element| try countUse(&counts, element),
                .get_index => |index| {
                    try countUse(&counts, index.object);
                    try countUse(&counts, index.index);
                },
                .set_index => |index| {
                    try countUse(&counts, index.object);
                    try countUse(&counts, index.index);
                    try countUse(&counts, index.value);
                },
                .build_variant => |variant| for (variant.fields) |field| try countUse(&counts, field),
                .match_tag => |match| try countUse(&counts, match.subject),
                .get_variant_field => |field| try countUse(&counts, field.subject),
                .const_value, .load_local, .function_ref => {},
                else => return unsupported("вид MIR-инструкции при подсчёте использований"),
            }
        }
        switch (block.terminator) {
            .branch => |branch| try countUse(&counts, branch.cond),
            .return_value => |return_term| if (return_term.value) |value| try countUse(&counts, value),
            .jump, .unreachable_term, .none => {},
        }
    }
    return counts;
}

fn findBrDepth(ctx: *EmitContext, target: mir.BlockId) !usize {
    var i = ctx.scope_stack.items.len;
    while (i > 0) {
        i -= 1;
        const scope = ctx.scope_stack.items[i];
        if (scope.kind == .loop and scope.header == target) return (ctx.scope_stack.items.len - 1) - i;
    }
    return unsupported("br-цель не найдена среди открытых scope (нарушен структурный инвариант)");
}

const ProcessOutcome = struct { fallthrough: mir.BlockId, ok: bool };

// Emits block `start` and everything structurally belonging to its
// region, until `stop_at` (a boundary already known to the caller) or a
// Return/Unreachable/back-edge. Returns `{stop_at, true}` if the region
// normally falls through to `stop_at` (caller continues from there),
// otherwise `{_, false}` — every path in the region either returned/
// panicked, or went to a loop via `br`.
fn processFrom(ctx: *EmitContext, start: mir.BlockId, stop_at: mir.BlockId) !ProcessOutcome {
    var b = start;
    while (true) {
        if (b == stop_at) return .{ .fallthrough = b, .ok = true };

        if (wasm_stackify.isLoopHeader(&ctx.cfg, &ctx.rpo_index, b) and !ctx.visited.contains(b)) {
            try ctx.visited.put(b, {});
            const block = ctx.function.blockConst(b);
            const branch = switch (block.terminator) {
                .branch => |value| value,
                else => return unsupported("loop header без branch-terminator'а"),
            };
            const identified = try wasm_stackify.identifyLoopBodyAndExit(ctx.allocator, ctx.function, b, branch.then_block, branch.else_block);

            try ctx.code.appendSlice(ctx.allocator, &.{ 0x03, 0x40 }); // loop (empty blocktype)
            try ctx.scope_stack.append(ctx.allocator, .{ .kind = .loop, .header = b });
            // The header's OWN instructions (computing cond) go INSIDE the
            // loop, not before it — cond is part of the loop body (`пока
            // cond цикл`), it must be recomputed every iteration via `br 0`
            // back to the loop's start, not once before the first entry.
            try emitBlockInstructions(ctx, block);
            try ctx.code.appendSlice(ctx.allocator, &.{ 0x04, 0x40 }); // if (empty blocktype)
            try ctx.scope_stack.append(ctx.allocator, .{ .kind = .if_scope });
            // The return of processFrom(body, ...) is intentionally
            // ignored: the body ALWAYS either reaches stop_at=exit (e.g.
            // via прервать, possibly from a nested если/иначе) or ends via
            // back-edge-br/return/unreachable — either way the body is
            // fully emitted by this point; what exactly happened doesn't
            // matter here, exit_block follows regardless.
            _ = try processFrom(ctx, identified.body, identified.exit);
            _ = ctx.scope_stack.pop(); // if
            try ctx.code.append(ctx.allocator, 0x05); // else — empty
            try ctx.code.append(ctx.allocator, 0x0B); // end if
            _ = ctx.scope_stack.pop(); // loop
            try ctx.code.append(ctx.allocator, 0x0B); // end loop

            b = identified.exit;
            continue;
        }

        try ctx.visited.put(b, {});
        const block = ctx.function.blockConst(b);
        try emitBlockInstructions(ctx, block);

        switch (block.terminator) {
            .jump => |jump| {
                if (ctx.visited.contains(jump.target) and wasm_stackify.isLoopHeader(&ctx.cfg, &ctx.rpo_index, jump.target)) {
                    const depth = try findBrDepth(ctx, jump.target);
                    try ctx.code.append(ctx.allocator, 0x0C); // br
                    try wasm_module.writeUleb128(&ctx.code, ctx.allocator, depth);
                    return .{ .fallthrough = mir.invalid_block, .ok = false };
                }
                b = jump.target;
                continue;
            },
            .branch => |branch| {
                const merge = wasm_stackify.findMerge(ctx.function, &ctx.idom, b, branch.then_block, branch.else_block);
                const sub_stop = merge orelse stop_at;

                // cond is already on the stack.
                try ctx.code.appendSlice(ctx.allocator, &.{ 0x04, 0x40 }); // if (empty blocktype)
                try ctx.scope_stack.append(ctx.allocator, .{ .kind = .if_scope });
                const then_outcome = try processFrom(ctx, branch.then_block, sub_stop);
                try ctx.code.append(ctx.allocator, 0x05); // else
                const else_outcome = try processFrom(ctx, branch.else_block, sub_stop);
                try ctx.code.append(ctx.allocator, 0x0B); // end if
                _ = ctx.scope_stack.pop();

                if (merge != null) {
                    b = merge.?;
                    continue;
                }
                if (then_outcome.ok) {
                    b = then_outcome.fallthrough;
                    continue;
                }
                if (else_outcome.ok) {
                    b = else_outcome.fallthrough;
                    continue;
                }
                // Real bug found running actual code, not just reading
                // it: this `if`/`else` was emitted with an empty
                // (void) blocktype (see the `0x04, 0x40` above) — valid
                // ONLY if code reachable from AT LEAST ONE branch could
                // fall through to the `if`'s own `end` leaving the
                // stack unchanged. Here NEITHER branch does (both
                // diverged — `возврат`, `прервать`/`продолжить`, or
                // panic — `then_outcome.ok`/`else_outcome.ok` both
                // false) — every real `и`+`else` diverging shape (most
                // commonly `если x тогда возврат Y конец` with no
                // `иначе`, i.e. ANY early-return) hit this. Semantically
                // the code point right after `end` is unreachable, but
                // real WASM validators (confirmed against both
                // `wat2wasm` and `wasmtime`, independent of any panos
                // codegen) do NOT infer that automatically from "both
                // branches diverged" — they need an EXPLICIT
                // `unreachable` marker here, or they reject the whole
                // module as invalid (not a runtime failure — it never
                // even LOADS). One byte fixes it.
                try ctx.code.append(ctx.allocator, 0x00); // unreachable
                return .{ .fallthrough = mir.invalid_block, .ok = false };
            },
            .return_value => {
                try ctx.code.append(ctx.allocator, 0x0F); // return
                return .{ .fallthrough = mir.invalid_block, .ok = false };
            },
            .unreachable_term => {
                try ctx.code.append(ctx.allocator, 0x00); // unreachable
                return .{ .fallthrough = mir.invalid_block, .ok = false };
            },
            .none => return unsupported("блок без terminator'а"),
        }
    }
}

// `mir_bytecode.odin`'s replay model doesn't care whether an instruction's
// dst gets used (an unused value is just "garbage" living on `vm.stack`
// until Return, which discards the whole frame's stack) — WASM's
// structural validator can't tolerate that: every block/if/loop/function
// must have a STATICALLY balanced stack height at its boundaries. So: a
// zero-use value (see `computeUseCount` above) is `drop`ped immediately.
fn emitBlockInstructions(ctx: *EmitContext, block: *const mir.Block) !void {
    for (block.instructions.items) |instruction| {
        const dst = try emitMirInstr(ctx, instruction);
        if (dst) |value| {
            if ((ctx.use_count.get(value) orelse 0) == 0) try ctx.code.append(ctx.allocator, 0x1A); // drop
        }
    }
}

fn wasmType(ctx: *EmitContext, value: mir.ValueId) u8 {
    return wasm_module.wasmValTypeForStore(ctx.type_store, ctx.function.valueType(value));
}

// Returns the instruction's `dst`, if any (for the caller's drop-if-unused
// check) — `function_ref` has a `dst` in MIR terms but pushes nothing onto
// the real WASM stack (see `EmitContext.value_to_function`'s doc comment),
// so it returns `null` here despite having a MIR-level dst.
fn emitMirInstr(ctx: *EmitContext, instruction: mir.Instruction) !?mir.ValueId {
    const code = &ctx.code;
    const allocator = ctx.allocator;
    switch (instruction) {
        .const_value => |c| {
            switch (c.value) {
                .number => |n| {
                    try code.append(allocator, 0x44); // f64.const
                    try wasm_module.writeF64Le(code, allocator, n);
                },
                .boolean => |b| {
                    try code.append(allocator, 0x41); // i32.const
                    try wasm_module.writeSleb128(code, allocator, if (b) 1 else 0);
                },
                .string => |s| {
                    const offset = ctx.string_offsets.get(s) orelse return unsupported("строковая константа без выделенного смещения (баг сборки data-секции)");
                    try code.append(allocator, 0x41); // i32.const
                    try wasm_module.writeSleb128(code, allocator, @intCast(offset));
                    const import_index = ctx.builtin_index.get("@runtime::строка_литерал") orelse return unsupported("строковая константа без runtime-импорта");
                    try code.append(allocator, 0x10); // call
                    try wasm_module.writeUleb128(code, allocator, import_index);
                },
            }
            return c.dst;
        },
        .load_local => |load| {
            try code.append(allocator, 0x20); // local.get
            try wasm_module.writeUleb128(code, allocator, @intFromEnum(load.local));
            return load.dst;
        },
        .store_local => |store| {
            try code.append(allocator, 0x21); // local.set
            try wasm_module.writeUleb128(code, allocator, @intFromEnum(store.local));
            return null;
        },
        .binary => |binary| {
            if (ctx.type_store.eql(ctx.function.valueType(binary.dst), ctx.type_store.builtins.string)) {
                if (binary.op != .add) return unsupported("строки поддерживают только оператор +");
                const import_index = ctx.builtin_index.get("@runtime::строка_сложить") orelse return unsupported("конкатенация строк без runtime-импорта");
                try code.append(allocator, 0x10); // call
                try wasm_module.writeUleb128(code, allocator, import_index);
                return binary.dst;
            }
            const is_int = wasmType(ctx, binary.dst) == wasm_module.wasm_i32;
            _ = is_int; // Phase-1a binary ops are all f64 — Целое shares f64 representation (same convention as the bytecode VM).
            switch (binary.op) {
                .modulo, .bit_and, .bit_or, .bit_xor, .shift_left, .shift_right => {
                    // Stack on entry: [lhs_f64, rhs_f64] (both already
                    // pushed by earlier instructions — see
                    // `scratch_i32_local`'s doc comment for why a scratch
                    // local is unavoidable here). Shuffle rhs through the
                    // scratch local so both operands can be converted in
                    // the right order, do the integer op, convert the
                    // result back to f64 (matching every other Phase-1a
                    // numeric op's f64 representation).
                    //
                    // i64, NOT i32 — real bug found running actual code:
                    // `std/математика.pns`'s own PRNG seeds itself from
                    // `время.сейчас_мс()` (unix-ms, ~1.8e12 — WAY past
                    // i32's ~2.1e9 ceiling) precisely THROUGH a `%`
                    // (`Целое(мс) % Целое(2147483647)`, deliberately
                    // brings a huge timestamp down into range) — i32.
                    // trunc_f64_s on that входной value traps
                    // ("float unrepresentable in integer range") before
                    // the modulo ever runs, defeating the exact use case
                    // that motivated needing % in WASM at all. `Целое`
                    // is documented (see математика.pns) to be exact up
                    // to 2^53 in its f64 representation — i64 covers
                    // that with enormous headroom, i32 doesn't come
                    // close.
                    const scratch = ctx.reserveScratchLocal();
                    try code.append(allocator, 0x21); // local.set scratch  (pops rhs_f64)
                    try wasm_module.writeUleb128(code, allocator, scratch);
                    try code.append(allocator, 0xB0); // i64.trunc_f64_s   (lhs_f64 -> lhs_i64)
                    try code.append(allocator, 0x20); // local.get scratch (push rhs_f64 back)
                    try wasm_module.writeUleb128(code, allocator, scratch);
                    try code.append(allocator, 0xB0); // i64.trunc_f64_s   (rhs_f64 -> rhs_i64)
                    const int_opcode: u8 = switch (binary.op) {
                        .modulo => 0x81, // i64.rem_s
                        .bit_and => 0x83, // i64.and
                        .bit_or => 0x84, // i64.or
                        .bit_xor => 0x85, // i64.xor
                        .shift_left => 0x86, // i64.shl
                        .shift_right => 0x87, // i64.shr_s
                        else => unreachable,
                    };
                    try code.append(allocator, int_opcode);
                    try code.append(allocator, 0xB9); // f64.convert_i64_s
                    return binary.dst;
                },
                else => {},
            }
            const opcode: u8 = switch (binary.op) {
                .add => 0xA0, // f64.add
                .subtract => 0xA1, // f64.sub
                .multiply => 0xA2, // f64.mul
                .divide => 0xA3, // f64.div
                .int_divide => 0xA3, // f64.div, truncated below
                .modulo, .bit_and, .bit_or, .bit_xor, .shift_left, .shift_right => unreachable, // handled above
            };
            try code.append(allocator, opcode);
            if (binary.op == .int_divide) try code.append(allocator, 0x9C); // f64.trunc — toward zero, matches Целое/Целое semantics
            return binary.dst;
        },
        .compare => |compare| {
            // Numbers (including Panos `Целое`) use f64; strings, booleans,
            // variants and aggregates are opaque i32 handles. Equality of
            // the latter must use the i32 family — emitting f64.eq for a
            // string comparison makes a formally invalid WASM module.
            const opcode: u8 = if (wasmType(ctx, compare.lhs) == wasm_module.wasm_i32) switch (compare.op) {
                .less => 0x48, // i32.lt_s
                .greater => 0x4A, // i32.gt_s
                .equal => 0x46, // i32.eq
                .less_equal => 0x4C, // i32.le_s
                .greater_equal => 0x4E, // i32.ge_s
                .not_equal => 0x47, // i32.ne
            } else switch (compare.op) {
                .less => 0x63, // f64.lt
                .greater => 0x64, // f64.gt
                .equal => 0x61, // f64.eq
                .less_equal => 0x65, // f64.le
                .greater_equal => 0x66, // f64.ge
                .not_equal => 0x62, // f64.ne
            };
            try code.append(allocator, opcode);
            return compare.dst;
        },
        .unary => |unary| {
            switch (unary.op) {
                .negate_number => try code.append(allocator, 0x9A), // f64.neg
                .negate_bool => try code.append(allocator, 0x45), // i32.eqz
                .int_trunc => try code.append(allocator, 0x9C), // f64.trunc
                .bit_not => return unsupported("побитовое НЕ (вне Phase 1a)"),
            }
            return unary.dst;
        },
        .function_ref => |function_ref| {
            try ctx.value_to_function.put(function_ref.dst, function_ref.function);
            return null;
        },
        .call_value => |call| {
            for (call.args) |_| {} // args are already on the stack — replayed earlier, in order, by their own instructions.
            const function_id = ctx.value_to_function.get(call.callee) orelse return unsupported("вызов через динамическое значение (нет call_indirect/таблицы функций в Phase 1a)");
            const function_index = ctx.func_index.get(function_id) orelse return unsupported("функция не найдена в индексе модуля");
            try code.append(allocator, 0x10); // call
            try wasm_module.writeUleb128(code, allocator, function_index);
            return call.dst;
        },
        .call_builtin => |call| {
            for (call.args) |_| {} // время.сейчас_мс/монотонно_мс take no args — nothing to replay yet.
            const import_index = ctx.builtin_index.get(call.name) orelse return unsupported("call_builtin без соответствующего host-импорта");
            try code.append(allocator, 0x10); // call
            try wasm_module.writeUleb128(code, allocator, import_index);
            return call.dst;
        },
        .new_aggregate => |aggregate| {
            const import_index = ctx.builtin_index.get(try structNewBuiltinName(ctx.function, aggregate.elements)) orelse return unsupported("конструктор структуры без runtime-импорта");
            try code.append(allocator, 0x10); // call
            try wasm_module.writeUleb128(code, allocator, import_index);
            return aggregate.dst;
        },
        .get_property => |property| {
            try code.append(allocator, 0x41); // i32.const field index
            try wasm_module.writeSleb128(code, allocator, @intCast(property.field_index));
            const getter_name = if (wasmType(ctx, property.dst) == wasm_module.wasm_i32) "@runtime::struct_get_i32" else "@runtime::struct_get_f64";
            const import_index = ctx.builtin_index.get(getter_name) orelse return unsupported("чтение поля структуры без runtime-импорта");
            try code.append(allocator, 0x10); // call
            try wasm_module.writeUleb128(code, allocator, import_index);
            return property.dst;
        },
        .set_property => |property| {
            try code.append(allocator, 0x41); // i32.const field index
            try wasm_module.writeSleb128(code, allocator, @intCast(property.field_index));
            const setter_name = if (wasmType(ctx, property.value) == wasm_module.wasm_i32) "@runtime::struct_set_i32" else "@runtime::struct_set_f64";
            const import_index = ctx.builtin_index.get(setter_name) orelse return unsupported("запись поля структуры без runtime-импорта");
            try code.append(allocator, 0x10); // call(handle, value, field)
            try wasm_module.writeUleb128(code, allocator, import_index);
            return null;
        },
        .new_array => |array| {
            if (array.elements.len != 0) return unsupported("new_array с inline-элементами");
            const import_index = ctx.builtin_index.get("@runtime::array_new") orelse return unsupported("массив без runtime-импорта");
            try code.append(allocator, 0x10); // call
            try wasm_module.writeUleb128(code, allocator, import_index);
            return array.dst;
        },
        .get_index => |index| {
            const getter_name = if (wasmType(ctx, index.dst) == wasm_module.wasm_i32) "@runtime::array_get_i32" else "@runtime::array_get_f64";
            const import_index = ctx.builtin_index.get(getter_name) orelse return unsupported("индексирование массива без runtime-импорта");
            try code.append(allocator, 0x10); // call(handle, index)
            try wasm_module.writeUleb128(code, allocator, import_index);
            return index.dst;
        },
        .set_index => |index| {
            const setter_name = if (wasmType(ctx, index.value) == wasm_module.wasm_i32) "@runtime::array_set_i32" else "@runtime::array_set_f64";
            const import_index = ctx.builtin_index.get(setter_name) orelse return unsupported("запись массива без runtime-импорта");
            try code.append(allocator, 0x10); // call(handle, index, value)
            try wasm_module.writeUleb128(code, allocator, import_index);
            return null;
        },
        .build_variant => |variant| {
            try code.append(allocator, 0x41); // i32.const tag follows fields
            try wasm_module.writeSleb128(code, allocator, @intCast(variant.tag));
            const import_index = ctx.builtin_index.get(try variantNewBuiltinName(ctx.function, variant.fields)) orelse return unsupported("вариант без runtime-импорта");
            try code.append(allocator, 0x10);
            try wasm_module.writeUleb128(code, allocator, import_index);
            return variant.dst;
        },
        .match_tag => |match| {
            try code.append(allocator, 0x41);
            try wasm_module.writeSleb128(code, allocator, @intCast(match.tag));
            const import_index = ctx.builtin_index.get("@runtime::variant_match") orelse return unsupported("проверка variant без runtime-импорта");
            try code.append(allocator, 0x10);
            try wasm_module.writeUleb128(code, allocator, import_index);
            return match.dst;
        },
        .get_variant_field => |field| {
            try code.append(allocator, 0x41);
            try wasm_module.writeSleb128(code, allocator, @intCast(field.field_index));
            const name = if (wasmType(ctx, field.dst) == wasm_module.wasm_i32) "@runtime::variant_get_i32" else "@runtime::variant_get_f64";
            const import_index = ctx.builtin_index.get(name) orelse return unsupported("чтение поля variant без runtime-импорта");
            try code.append(allocator, 0x10);
            try wasm_module.writeUleb128(code, allocator, import_index);
            return field.dst;
        },
        else => return unsupported("вид MIR-инструкции"),
    }
}

pub fn emitFunctionWasm(
    allocator: std.mem.Allocator,
    checked: *const type_checker.CheckResult,
    function: *const mir.Function,
    func_index: *const std.AutoHashMap(mir.FunctionId, u32),
    builtin_index: *const std.StringHashMap(u32),
    string_offsets: *const std.StringHashMap(u32),
) ![]u8 {
    var ctx = try EmitContext.init(allocator, checked, function, func_index, builtin_index, string_offsets);
    defer ctx.deinit();

    _ = try processFrom(&ctx, function.entry, mir.invalid_block);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const has_scratch = ctx.scratch_i32_local != null;
    const n_body_locals = function.locals.items.len - function.parameters.len + @as(usize, if (has_scratch) 1 else 0);
    try wasm_module.writeUleb128(&out, allocator, n_body_locals);
    for (function.parameters.len..function.locals.items.len) |i| {
        try wasm_module.writeUleb128(&out, allocator, 1);
        const store = function.type_store orelse &checked.types;
        try out.append(allocator, wasm_module.wasmValTypeForStore(store, function.locals.items[i].type_id));
    }
    if (has_scratch) {
        try wasm_module.writeUleb128(&out, allocator, 1);
        try out.append(allocator, wasm_module.wasm_f64);
    }
    try out.appendSlice(allocator, ctx.code.items);
    try out.append(allocator, 0x0B); // end функции
    return try out.toOwnedSlice(allocator);
}

// `call_builtin`'s "модуль::имя" name → the host runtime export it needs
// (`zig/wasm_runtime/runtime_wasi.zig`/`runtime_js.zig`'s `pw_now_ms`/
// `pw_monotonic_ms` — built for exactly this, previously never called by
// anything). `время.спать_мс` never reaches this function at all —
// `mir_lowering.zig`'s `lowerTimeBuiltinCall` panics before producing a
// `call_builtin` for it (native-only builtin, not an AOT WASM host call).
fn hostImportNameForBuiltin(name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, name, "время::сейчас_мс")) return "pw_now_ms";
    if (std.mem.eql(u8, name, "время::монотонно_мс")) return "pw_monotonic_ms";
    if (std.mem.eql(u8, name, "сеть::http_запрос_sync")) return "pw_http_request_sync";
    // `DOM::*` string arguments are opaque i32 handles maintained by the
    // JS host. `@runtime::строка_литерал` converts data-section offsets to
    // those handles and `@runtime::строка_сложить` creates dynamic values.
    if (std.mem.eql(u8, name, "DOM::текст")) return "dom_get_text_num";
    if (std.mem.eql(u8, name, "DOM::установить_текст")) return "dom_set_text_num";
    if (std.mem.eql(u8, name, "DOM::на_клик")) return "dom_on_click_num";
    if (std.mem.eql(u8, name, "DOM::на_клик_контекст")) return "dom_on_click_context";
    if (std.mem.eql(u8, name, "DOM::текст_строка")) return "dom_get_text_string";
    if (std.mem.eql(u8, name, "DOM::установить_текст_строка")) return "dom_set_text_string";
    if (std.mem.eql(u8, name, "DOM::значение_поля")) return "dom_get_input_value";
    if (std.mem.eql(u8, name, "DOM::установить_значение_поля")) return "dom_set_input_value";
    if (std.mem.eql(u8, name, "DOM::создать_и_добавить")) return "dom_create_append";
    if (std.mem.eql(u8, name, "DOM::после_кадра")) return "dom_after_frame";
    if (std.mem.eql(u8, name, "строки::длина")) return "pw_string_length";
    if (std.mem.eql(u8, name, "строки::длина_байт")) return "pw_string_byte_length";
    if (std.mem.eql(u8, name, "строки::срез")) return "pw_string_slice";
    if (std.mem.eql(u8, name, "строки::найти")) return "pw_string_find";
    if (std.mem.eql(u8, name, "строки::начинается_с")) return "pw_string_starts_with";
    if (std.mem.eql(u8, name, "строки::заменить")) return "pw_string_replace";
    if (std.mem.eql(u8, name, "строки::разбить")) return "pw_string_split";
    if (std.mem.eql(u8, name, "строки::из_числа")) return "pw_string_from_number";
    if (std.mem.eql(u8, name, "строки::в_число")) return "pw_string_to_number";
    if (std.mem.eql(u8, name, "@runtime::строка_литерал")) return "pw_string_literal";
    if (std.mem.eql(u8, name, "@runtime::строка_сложить")) return "pw_string_concat";
    if (std.mem.startsWith(u8, name, "@runtime::struct_")) return name["@runtime::".len..];
    if (std.mem.startsWith(u8, name, "@runtime::variant_")) return name["@runtime::".len..];
    if (std.mem.startsWith(u8, name, "@runtime::array_")) return name["@runtime::".len..];
    return unsupported("call_builtin с именем без известного host-импорта");
}

const BuiltinSignature = struct { params: []const u8, result: ?u8 };

fn builtinSignature(name: []const u8) !BuiltinSignature {
    if (std.mem.eql(u8, name, "время::сейчас_мс") or std.mem.eql(u8, name, "время::монотонно_мс"))
        return .{ .params = &.{}, .result = wasm_module.wasm_f64 };
    if (std.mem.eql(u8, name, "сеть::http_запрос_sync"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "DOM::текст"))
        return .{ .params = &.{wasm_module.wasm_i32}, .result = wasm_module.wasm_f64 };
    if (std.mem.eql(u8, name, "DOM::установить_текст"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_f64 }, .result = null };
    if (std.mem.eql(u8, name, "DOM::на_клик"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = null };
    if (std.mem.eql(u8, name, "DOM::на_клик_контекст"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = null };
    if (std.mem.eql(u8, name, "DOM::текст_строка") or std.mem.eql(u8, name, "DOM::значение_поля"))
        return .{ .params = &.{wasm_module.wasm_i32}, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "DOM::установить_текст_строка") or std.mem.eql(u8, name, "DOM::установить_значение_поля"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = null };
    if (std.mem.eql(u8, name, "DOM::создать_и_добавить"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = null };
    if (std.mem.eql(u8, name, "DOM::после_кадра"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = null };
    if (std.mem.eql(u8, name, "@runtime::строка_литерал"))
        return .{ .params = &.{wasm_module.wasm_i32}, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "@runtime::строка_сложить"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "строки::длина") or std.mem.eql(u8, name, "строки::длина_байт"))
        return .{ .params = &.{wasm_module.wasm_i32}, .result = wasm_module.wasm_f64 };
    if (std.mem.eql(u8, name, "строки::срез"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_f64, wasm_module.wasm_f64 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "строки::найти"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32, wasm_module.wasm_f64 }, .result = wasm_module.wasm_f64 };
    if (std.mem.eql(u8, name, "строки::начинается_с"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "строки::заменить"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "строки::разбить"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "строки::из_числа"))
        return .{ .params = &.{wasm_module.wasm_f64}, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "строки::в_число"))
        return .{ .params = &.{wasm_module.wasm_i32}, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "@runtime::struct_get_i32"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "@runtime::struct_get_f64"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = wasm_module.wasm_f64 };
    if (std.mem.eql(u8, name, "@runtime::struct_set_i32"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = null };
    if (std.mem.eql(u8, name, "@runtime::struct_set_f64"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_f64, wasm_module.wasm_i32 }, .result = null };
    if (std.mem.startsWith(u8, name, "@runtime::struct_new_")) return try structNewSignature(name["@runtime::struct_new_".len..]);
    if (std.mem.eql(u8, name, "@runtime::variant_new_f")) return .{ .params = &.{ wasm_module.wasm_f64, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "@runtime::variant_new_i")) return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "@runtime::variant_new_ff")) return .{ .params = &.{ wasm_module.wasm_f64, wasm_module.wasm_f64, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "@runtime::variant_new_fi")) return .{ .params = &.{ wasm_module.wasm_f64, wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "@runtime::variant_new_if")) return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_f64, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "@runtime::variant_new_ii")) return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "@runtime::variant_new_")) return .{ .params = &.{wasm_module.wasm_i32}, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "@runtime::array_new"))
        return .{ .params = &.{}, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "@runtime::array_length"))
        return .{ .params = &.{wasm_module.wasm_i32}, .result = wasm_module.wasm_f64 };
    if (std.mem.eql(u8, name, "@runtime::array_append_i32"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = null };
    if (std.mem.eql(u8, name, "@runtime::array_append_f64"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_f64 }, .result = null };
    if (std.mem.eql(u8, name, "@runtime::array_set_i32"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_f64, wasm_module.wasm_i32 }, .result = null };
    if (std.mem.eql(u8, name, "@runtime::array_set_f64"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_f64, wasm_module.wasm_f64 }, .result = null };
    if (std.mem.eql(u8, name, "@runtime::array_get_i32"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_f64 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "@runtime::array_get_f64"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_f64 }, .result = wasm_module.wasm_f64 };
    if (std.mem.eql(u8, name, "@runtime::array_get_or_i32"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_f64, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "@runtime::array_get_or_f64"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_f64, wasm_module.wasm_f64 }, .result = wasm_module.wasm_f64 };
    if (std.mem.eql(u8, name, "@runtime::variant_match"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "@runtime::variant_get_i32"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = wasm_module.wasm_i32 };
    if (std.mem.eql(u8, name, "@runtime::variant_get_f64"))
        return .{ .params = &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 }, .result = wasm_module.wasm_f64 };
    return unsupported("call_builtin с именем без известной сигнатуры импорта");
}

// Every DISTINCT string literal any function in `module` uses, concatenated
// null-terminated into one blob — `pw_string_literal` reads the literal
// from this data section and converts its offset into a JS string handle.
// Empty for a module with no string literals at all.
fn collectStringConstants(allocator: std.mem.Allocator, module: *const mir.Module) !struct {
    data: []u8,
    offsets: std.StringHashMap(u32),
} {
    var offsets: std.StringHashMap(u32) = .init(allocator);
    errdefer offsets.deinit();
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(allocator);
    for (module.functions.items) |function| {
        for (function.blocks.items) |block| {
            for (block.instructions.items) |instruction| {
                switch (instruction) {
                    .const_value => |c| switch (c.value) {
                        .string => |s| {
                            if (!offsets.contains(s)) {
                                try offsets.put(s, @intCast(data.items.len));
                                try data.appendSlice(allocator, s);
                                try data.append(allocator, 0); // null terminator
                            }
                        },
                        else => {},
                    },
                    else => {},
                }
            }
        }
    }
    return .{ .data = try data.toOwnedSlice(allocator), .offsets = offsets };
}

// Every DISTINCT builtin name any function in `module` calls, in first-seen
// order — the common case (no builtin calls anywhere) returns an empty
// list, so a program that never touches `время.*` gets a WASM module with
// NO import section at all, same as before this feature existed (no host
// needs to supply anything to run it).
fn collectBuiltinNames(allocator: std.mem.Allocator, module: *const mir.Module) !std.ArrayList([]const u8) {
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(allocator);
    for (module.functions.items) |function| {
        for (function.blocks.items) |block| {
            for (block.instructions.items) |instruction| {
                switch (instruction) {
                    .call_builtin => |call| {
                        try appendBuiltinName(allocator, &seen, &names, call.name);
                    },
                    .const_value => |constant| switch (constant.value) {
                        .string => try appendBuiltinName(allocator, &seen, &names, "@runtime::строка_литерал"),
                        else => {},
                    },
                    .binary => |binary| {
                        const store = function.type_store orelse continue;
                        if (store.eql(function.valueType(binary.dst), store.builtins.string)) {
                            try appendBuiltinName(allocator, &seen, &names, "@runtime::строка_сложить");
                        }
                    },
                    .new_aggregate => |aggregate| {
                        try appendBuiltinName(allocator, &seen, &names, try structNewBuiltinName(&function, aggregate.elements));
                    },
                    .get_property => {
                        const getter_name = if (wasm_module.wasmValTypeForStore(function.type_store orelse continue, function.valueType(instruction.get_property.dst)) == wasm_module.wasm_i32) "@runtime::struct_get_i32" else "@runtime::struct_get_f64";
                        try appendBuiltinName(allocator, &seen, &names, getter_name);
                    },
                    .set_property => |property| {
                        const setter_name = if (wasm_module.wasmValTypeForStore(function.type_store orelse continue, function.valueType(property.value)) == wasm_module.wasm_i32) "@runtime::struct_set_i32" else "@runtime::struct_set_f64";
                        try appendBuiltinName(allocator, &seen, &names, setter_name);
                    },
                    .new_array => try appendBuiltinName(allocator, &seen, &names, "@runtime::array_new"),
                    .get_index => |index| {
                        const getter_name = if (wasm_module.wasmValTypeForStore(function.type_store orelse continue, function.valueType(index.dst)) == wasm_module.wasm_i32) "@runtime::array_get_i32" else "@runtime::array_get_f64";
                        try appendBuiltinName(allocator, &seen, &names, getter_name);
                    },
                    .set_index => |index| {
                        const setter_name = if (wasm_module.wasmValTypeForStore(function.type_store orelse continue, function.valueType(index.value)) == wasm_module.wasm_i32) "@runtime::array_set_i32" else "@runtime::array_set_f64";
                        try appendBuiltinName(allocator, &seen, &names, setter_name);
                    },
                    .build_variant => |variant| try appendBuiltinName(allocator, &seen, &names, try variantNewBuiltinName(&function, variant.fields)),
                    .match_tag => try appendBuiltinName(allocator, &seen, &names, "@runtime::variant_match"),
                    .get_variant_field => |field| {
                        const name = if (wasm_module.wasmValTypeForStore(function.type_store orelse continue, function.valueType(field.dst)) == wasm_module.wasm_i32) "@runtime::variant_get_i32" else "@runtime::variant_get_f64";
                        try appendBuiltinName(allocator, &seen, &names, name);
                    },
                    else => {},
                }
            }
        }
    }
    return names;
}

fn structNewBuiltinName(function: *const mir.Function, elements: []const mir.ValueId) ![]const u8 {
    if (elements.len > 3) return unsupported("структура с более чем 3 полями");
    const store = function.type_store orelse return unsupported("структура без TypeStore");
    var mask: u3 = 0;
    for (elements, 0..) |element, index| {
        if (wasm_module.wasmValTypeForStore(store, function.valueType(element)) == wasm_module.wasm_i32) {
            mask |= @as(u3, 1) << @intCast(index);
        }
    }
    return switch (elements.len) {
        0 => "@runtime::struct_new_",
        1 => if (mask == 0) "@runtime::struct_new_f" else "@runtime::struct_new_i",
        2 => switch (mask) {
            0 => "@runtime::struct_new_ff",
            1 => "@runtime::struct_new_if",
            2 => "@runtime::struct_new_fi",
            3 => "@runtime::struct_new_ii",
            else => unreachable,
        },
        3 => switch (mask) {
            0 => "@runtime::struct_new_fff",
            1 => "@runtime::struct_new_iff",
            2 => "@runtime::struct_new_fif",
            3 => "@runtime::struct_new_iif",
            4 => "@runtime::struct_new_ffi",
            5 => "@runtime::struct_new_ifi",
            6 => "@runtime::struct_new_fii",
            7 => "@runtime::struct_new_iii",
        },
        else => unreachable,
    };
}

fn structNewSignature(pattern: []const u8) !BuiltinSignature {
    const params: []const u8 = switch (pattern.len) {
        0 => &.{},
        1 => if (pattern[0] == 'i') &.{wasm_module.wasm_i32} else &.{wasm_module.wasm_f64},
        2 => if (std.mem.eql(u8, pattern, "ii")) &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 } else if (std.mem.eql(u8, pattern, "if")) &.{ wasm_module.wasm_i32, wasm_module.wasm_f64 } else if (std.mem.eql(u8, pattern, "fi")) &.{ wasm_module.wasm_f64, wasm_module.wasm_i32 } else &.{ wasm_module.wasm_f64, wasm_module.wasm_f64 },
        3 => if (std.mem.eql(u8, pattern, "iii")) &.{ wasm_module.wasm_i32, wasm_module.wasm_i32, wasm_module.wasm_i32 } else if (std.mem.eql(u8, pattern, "iif")) &.{ wasm_module.wasm_i32, wasm_module.wasm_i32, wasm_module.wasm_f64 } else if (std.mem.eql(u8, pattern, "ifi")) &.{ wasm_module.wasm_i32, wasm_module.wasm_f64, wasm_module.wasm_i32 } else if (std.mem.eql(u8, pattern, "iff")) &.{ wasm_module.wasm_i32, wasm_module.wasm_f64, wasm_module.wasm_f64 } else if (std.mem.eql(u8, pattern, "fii")) &.{ wasm_module.wasm_f64, wasm_module.wasm_i32, wasm_module.wasm_i32 } else if (std.mem.eql(u8, pattern, "fif")) &.{ wasm_module.wasm_f64, wasm_module.wasm_i32, wasm_module.wasm_f64 } else if (std.mem.eql(u8, pattern, "ffi")) &.{ wasm_module.wasm_f64, wasm_module.wasm_f64, wasm_module.wasm_i32 } else &.{ wasm_module.wasm_f64, wasm_module.wasm_f64, wasm_module.wasm_f64 },
        else => return unsupported("сигнатура структуры с более чем 3 полями"),
    };
    return .{ .params = params, .result = wasm_module.wasm_i32 };
}

fn variantNewBuiltinName(function: *const mir.Function, fields: []const mir.ValueId) ![]const u8 {
    const struct_name = try structNewBuiltinName(function, fields);
    const pattern = struct_name["@runtime::struct_new_".len..];
    if (pattern.len > 2) return unsupported("variant с более чем 2 полями");
    if (pattern.len == 0) return "@runtime::variant_new_";
    if (std.mem.eql(u8, pattern, "i")) return "@runtime::variant_new_i";
    if (std.mem.eql(u8, pattern, "f")) return "@runtime::variant_new_f";
    if (std.mem.eql(u8, pattern, "ii")) return "@runtime::variant_new_ii";
    if (std.mem.eql(u8, pattern, "if")) return "@runtime::variant_new_if";
    if (std.mem.eql(u8, pattern, "fi")) return "@runtime::variant_new_fi";
    return "@runtime::variant_new_ff";
}

fn variantNewSignature(pattern: []const u8) !BuiltinSignature {
    const base = try structNewSignature(pattern);
    const params = switch (pattern.len) {
        0 => &.{wasm_module.wasm_i32},
        1 => if (pattern[0] == 'i') &.{ wasm_module.wasm_i32, wasm_module.wasm_i32 } else &.{ wasm_module.wasm_f64, wasm_module.wasm_i32 },
        2 => if (std.mem.eql(u8, pattern, "ii")) &.{ wasm_module.wasm_i32, wasm_module.wasm_i32, wasm_module.wasm_i32 } else if (std.mem.eql(u8, pattern, "if")) &.{ wasm_module.wasm_i32, wasm_module.wasm_f64, wasm_module.wasm_i32 } else if (std.mem.eql(u8, pattern, "fi")) &.{ wasm_module.wasm_f64, wasm_module.wasm_i32, wasm_module.wasm_i32 } else &.{ wasm_module.wasm_f64, wasm_module.wasm_f64, wasm_module.wasm_i32 },
        else => return unsupported("variant с более чем 2 полями"),
    };
    return .{ .params = params, .result = base.result };
}

fn appendBuiltinName(
    allocator: std.mem.Allocator,
    seen: *std.StringHashMap(void),
    names: *std.ArrayList([]const u8),
    name: []const u8,
) !void {
    if (!seen.contains(name)) {
        try seen.put(name, {});
        try names.append(allocator, name);
    }
}

// Assembles a complete, standalone `.wasm` binary — Type/Import/Function/
// Export/Code sections, one function type per MIR function (no
// deduplication — wasteful but valid, matching the Odin original's own
// choice not to bother sharing signatures), every function exported under
// its MIR name. WASM's function index space is imports-first: every
// `call_builtin` name used anywhere in `module` becomes ONE import (module
// "env", field = `hostImportNameForBuiltin`'s host export name) at the
// FRONT of the index space, so every module-defined function's real index
// is `builtin_count + declaration_order` — `func_index`/`function_section`/
// `export_section` all apply that same offset consistently.
// `mir_validate.zig`'s own construction-time invariants already guarantee
// `mir_lowering.zig`'s OWN output is well-formed — but running this here
// unconditionally is what turns a FUTURE lowering bug into a clean error
// message ("v3 используется 2 раза") instead of an out-of-bounds panic or
// silently-wrong WASM bytes deep inside `processFrom`'s stack-machine
// replay. Warnings (unreachable blocks) are logged, not fatal — same
// severity split `mir_validate.zig` itself documents.
fn validateOrFail(allocator: std.mem.Allocator, checked: *const type_checker.CheckResult, module: *const mir.Module) !void {
    for (module.functions.items) |*function| {
        const store = function.type_store orelse &checked.types;
        const issues = try mir_validate.validateFunction(allocator, module, function, store.builtins.void);
        defer mir_validate.freeIssues(allocator, issues);
        for (issues) |issue| {
            if (issue.is_error) {
                return error.InvalidMir;
            }
        }
    }
}

pub fn emitModule(allocator: std.mem.Allocator, checked: *const type_checker.CheckResult, module: *const mir.Module) ![]u8 {
    try validateOrFail(allocator, checked, module);

    var builtin_names = try collectBuiltinNames(allocator, module);
    defer builtin_names.deinit(allocator);
    const builtin_count: u32 = @intCast(builtin_names.items.len);

    var builtin_index: std.StringHashMap(u32) = .init(allocator);
    defer builtin_index.deinit();
    for (builtin_names.items, 0..) |name, i| try builtin_index.put(name, @intCast(i));

    var strings = try collectStringConstants(allocator, module);
    defer allocator.free(strings.data);
    defer strings.offsets.deinit();
    const needs_memory = strings.data.len != 0;

    var func_index: std.AutoHashMap(mir.FunctionId, u32) = .init(allocator);
    defer func_index.deinit();
    for (module.functions.items, 0..) |function, i| try func_index.put(function.id, builtin_count + @as(u32, @intCast(i)));

    // Import types come FIRST in the type section — import type index `i`
    // is simply `i` for `i < builtin_count`, per each builtin's own
    // `builtinSignature` (NOT uniformly `() -> f64` any more — `DOM.*`
    // needs real params/void results too).
    var type_section: std.ArrayList(u8) = .empty;
    defer type_section.deinit(allocator);
    try wasm_module.writeUleb128(&type_section, allocator, builtin_count + module.functions.items.len);
    for (builtin_names.items) |name| {
        const signature = try builtinSignature(name);
        try type_section.append(allocator, 0x60); // functype
        try wasm_module.writeUleb128(&type_section, allocator, signature.params.len);
        for (signature.params) |param_type| try type_section.append(allocator, param_type);
        try wasm_module.writeUleb128(&type_section, allocator, if (signature.result != null) 1 else 0);
        if (signature.result) |result_type| try type_section.append(allocator, result_type);
    }
    for (module.functions.items) |function| {
        const store = function.type_store orelse &checked.types;
        try type_section.append(allocator, 0x60); // functype
        try wasm_module.writeUleb128(&type_section, allocator, function.parameters.len);
        for (function.parameters) |local| {
            const local_type = function.locals.items[@intFromEnum(local)].type_id;
            try type_section.append(allocator, wasm_module.wasmValTypeForStore(store, local_type));
        }
        const is_void = store.eql(function.result_type, store.builtins.void);
        try wasm_module.writeUleb128(&type_section, allocator, if (is_void) 0 else 1);
        if (!is_void) try type_section.append(allocator, wasm_module.wasmValTypeForStore(store, function.result_type));
    }

    var import_section: std.ArrayList(u8) = .empty;
    defer import_section.deinit(allocator);
    if (builtin_count != 0) {
        try wasm_module.writeUleb128(&import_section, allocator, builtin_count);
        for (builtin_names.items, 0..) |name, i| {
            const host_name = try hostImportNameForBuiltin(name);
            try wasm_module.writeUleb128(&import_section, allocator, "env".len);
            try import_section.appendSlice(allocator, "env");
            try wasm_module.writeUleb128(&import_section, allocator, host_name.len);
            try import_section.appendSlice(allocator, host_name);
            try import_section.append(allocator, 0x00); // func import kind
            try wasm_module.writeUleb128(&import_section, allocator, i); // typeidx
        }
    }

    var function_section: std.ArrayList(u8) = .empty;
    defer function_section.deinit(allocator);
    try wasm_module.writeUleb128(&function_section, allocator, module.functions.items.len);
    for (0..module.functions.items.len) |i| try wasm_module.writeUleb128(&function_section, allocator, builtin_count + i);

    // Linear memory holds only the flat blob of literal strings. Dynamic
    // strings are host handles; this deliberately avoids a WASM GC/heap in
    // the first browser runtime ABI.
    var memory_section: std.ArrayList(u8) = .empty;
    defer memory_section.deinit(allocator);
    var data_section: std.ArrayList(u8) = .empty;
    defer data_section.deinit(allocator);
    if (needs_memory) {
        const pages: u32 = @intCast((strings.data.len + 65535) / 65536);
        try wasm_module.writeUleb128(&memory_section, allocator, 1); // 1 memory
        try memory_section.append(allocator, 0x00); // limits: min only, no max
        try wasm_module.writeUleb128(&memory_section, allocator, @max(pages, 1));

        try wasm_module.writeUleb128(&data_section, allocator, 1); // 1 active segment
        try data_section.append(allocator, 0x00); // flags: active, memory 0
        try data_section.append(allocator, 0x41); // i32.const
        try wasm_module.writeSleb128(&data_section, allocator, 0); // offset 0
        try data_section.append(allocator, 0x0B); // end
        try wasm_module.writeUleb128(&data_section, allocator, strings.data.len);
        try data_section.appendSlice(allocator, strings.data);
    }

    var export_section: std.ArrayList(u8) = .empty;
    defer export_section.deinit(allocator);
    try wasm_module.writeUleb128(&export_section, allocator, module.functions.items.len + @as(usize, if (needs_memory) 1 else 0));
    for (module.functions.items, 0..) |function, i| {
        try wasm_module.writeUleb128(&export_section, allocator, function.name.len);
        try export_section.appendSlice(allocator, function.name);
        try export_section.append(allocator, 0x00); // func export kind
        try wasm_module.writeUleb128(&export_section, allocator, builtin_count + i);
    }
    if (needs_memory) {
        try wasm_module.writeUleb128(&export_section, allocator, "memory".len);
        try export_section.appendSlice(allocator, "memory");
        try export_section.append(allocator, 0x02); // memory export kind
        try wasm_module.writeUleb128(&export_section, allocator, 0); // memidx 0
    }

    var code_section: std.ArrayList(u8) = .empty;
    defer code_section.deinit(allocator);
    try wasm_module.writeUleb128(&code_section, allocator, module.functions.items.len);
    for (module.functions.items) |function| {
        const body = try emitFunctionWasm(allocator, checked, &function, &func_index, &builtin_index, &strings.offsets);
        defer allocator.free(body);
        try wasm_module.writeUleb128(&code_section, allocator, body.len);
        try code_section.appendSlice(allocator, body);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &wasm_module.magic_and_version);
    try wasm_module.writeSection(&out, allocator, 1, type_section.items);
    if (builtin_count != 0) try wasm_module.writeSection(&out, allocator, 2, import_section.items);
    try wasm_module.writeSection(&out, allocator, 3, function_section.items);
    if (needs_memory) try wasm_module.writeSection(&out, allocator, 5, memory_section.items);
    try wasm_module.writeSection(&out, allocator, 7, export_section.items);
    try wasm_module.writeSection(&out, allocator, 10, code_section.items);
    if (needs_memory) try wasm_module.writeSection(&out, allocator, 11, data_section.items);
    return try out.toOwnedSlice(allocator);
}

test "emitModule produces a valid, executable .wasm for a recursive MIR function" {
    const allocator = std.testing.allocator;
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker_mod = @import("type_checker.zig");
    const mir_lowering = @import("mir_lowering.zig");

    const source_text =
        \\функ факториал(n: Число) -> Число
        \\    если n < 2.0 тогда
        \\        1.0
        \\    иначе
        \\        n * факториал(n - 1.0)
        \\    конец
        \\конец
    ;
    var lexed = try lexer.tokenize(allocator, source_text, 0);
    defer lexed.deinit();
    var parsed = try parser.parse(allocator, lexed.tokens.items);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    var resolved = try resolver.resolve(allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker_mod.check(allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);

    var module = try mir_lowering.lowerModule(allocator, &parsed.ast, &resolved, &checked);
    defer module.deinit(allocator);

    const wasm_bytes = try emitModule(allocator, &checked, &module);
    defer allocator.free(wasm_bytes);
    try std.testing.expect(std.mem.eql(u8, wasm_bytes[0..4], &.{ 0x00, 0x61, 0x73, 0x6D }));

    // `Io.Threaded.Options.environ` defaults to EMPTY (by design — spawning
    // a child with the real environment must be opt-in) — `expand_arg0 =
    // .expand`'s own `$PATH` search reads THIS field, not the real OS
    // environment, so without passing `std.testing.environ` (populated by
    // the standard test runner from the real process env) it silently
    // falls back to a tiny hardcoded default (`/usr/local/bin:/bin/:/usr/
    // bin`) and reports `FileNotFound` even when `wasmtime` is genuinely on
    // `$PATH` (confirmed empirically — an earlier version of this test
    // hardcoded `/opt/homebrew/bin/wasmtime` to work around exactly this,
    // which broke on any machine/CI runner using a different install path).
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();
    const path = "zzz_wasm_emit_test.wasm";
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = path, .data = wasm_bytes });
    defer std.Io.Dir.cwd().deleteFile(io.io(), path) catch {};

    const result = std.process.run(allocator, io.io(), .{
        .argv = &.{ "wasmtime", "run", "--invoke", "факториал", path, "5" },
        .expand_arg0 = .expand,
    }) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exited_zero = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!exited_zero) {
        std.debug.print("wasmtime failed: {s}\n", .{result.stderr});
        return error.WasmtimeFailed;
    }
    // 5! == 120
    try std.testing.expectEqualStrings("120\n", result.stdout);
}

test "emitModule produces a valid, executable .wasm for a real iterating пока loop with assignment" {
    const allocator = std.testing.allocator;
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker_mod = @import("type_checker.zig");
    const mir_lowering = @import("mir_lowering.zig");

    const source_text =
        \\функ сумма_до(предел: Число) -> Число
        \\    пер итог: Число = 0.0
        \\    пер i: Число = 1.0
        \\    пока i < предел цикл
        \\        итог = итог + i
        \\        i = i + 1.0
        \\    конец
        \\    итог
        \\конец
    ;
    var lexed = try lexer.tokenize(allocator, source_text, 0);
    defer lexed.deinit();
    var parsed = try parser.parse(allocator, lexed.tokens.items);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    var resolved = try resolver.resolve(allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker_mod.check(allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);

    var module = try mir_lowering.lowerModule(allocator, &parsed.ast, &resolved, &checked);
    defer module.deinit(allocator);

    const wasm_bytes = try emitModule(allocator, &checked, &module);
    defer allocator.free(wasm_bytes);

    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();
    const path = "zzz_wasm_emit_loop_test.wasm";
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = path, .data = wasm_bytes });
    defer std.Io.Dir.cwd().deleteFile(io.io(), path) catch {};

    const result = std.process.run(allocator, io.io(), .{
        .argv = &.{ "wasmtime", "run", "--invoke", "сумма_до", path, "10" },
        .expand_arg0 = .expand,
    }) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exited_zero = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!exited_zero) {
        std.debug.print("wasmtime failed: {s}\n", .{result.stderr});
        return error.WasmtimeFailed;
    }
    // 1+2+...+9 == 45 (i < 10, not <=)
    try std.testing.expectEqualStrings("45\n", result.stdout);
}

test "emitModule fails cleanly on a malformed MIR module instead of crashing" {
    const allocator = std.testing.allocator;
    const mir_builder = @import("mir_builder.zig");

    var checked = try type_checker.CheckResult.init(allocator);
    defer checked.deinit();

    var module = mir.Module.init(allocator);
    defer module.deinit(allocator);
    const function_id = try mir_builder.newFunction(&module, allocator, "сломано", @enumFromInt(0), checked.types.builtins.void, .{ .file_id = 0, .start = 0, .end = 0 });
    var builder = try mir_builder.Builder.beginFunction(&module, allocator, function_id);
    // Jump to a block that doesn't exist — exactly the invariant
    // `mir_validate.zig` exists to catch before it reaches `processFrom`'s
    // stack-machine replay (which would otherwise index out of bounds).
    builder.terminate(.{ .jump = .{ .target = @enumFromInt(99) } });

    try std.testing.expectError(error.InvalidMir, emitModule(allocator, &checked, &module));
}
