const std = @import("std");
const ast = @import("ast.zig");
const bytecode = @import("bytecode.zig");
const source = @import("source.zig");
const symbols = @import("symbols.zig");
const types = @import("types.zig");

// MIR (mid-level IR) — the AOT `panos build --target=wasm` pipeline's
// bytecode→WASM lowering stage, ported from Odin's `core/mir*.odin` +
// `core/wasm_*.odin` (~9000 lines total there). Same phased scope as the
// Odin original: the full instruction/terminator set is declared
// EXHAUSTIVELY here from the start (so validation/printing/emission
// switches never need new cases bolted on later), but the LOWERING pass
// (bytecode → MIR, a separate file) only ever PRODUCES the "Phase 1"
// subset — literals, locals, binary/unary/compare operators (including
// short-circuit `и`/`или` lowered to real branches), calls, and control
// flow (`если`/`пока`/`для`, via Jump/Branch terminators). Interfaces,
// closures, actors (спавн/отправить/получить), `внешний`, ADTs and
// collections are declared but not yet lowered — same "Phase 2" split
// Odin made, not an oversight.
//
// `Symbol_Id`/`Type`/`Span` in the Odin original are reused directly from
// the resolver/type-checker (MIR never recomputes semantic info, only
// reads it) — the same is true here: `symbols.SymbolId`, `types.TypeId`,
// `source.Span`.

pub const ValueId = enum(u32) { _ };
pub const LocalId = enum(u32) { _ };
pub const BlockId = enum(u32) { _ };
pub const FunctionId = enum(u32) { _ };

pub const invalid_block: BlockId = @enumFromInt(std.math.maxInt(u32));
pub const invalid_value: ValueId = @enumFromInt(std.math.maxInt(u32));

pub const BinOp = enum {
    add,
    subtract,
    multiply,
    divide,
    int_divide,
    modulo,
    bit_and,
    bit_or,
    bit_xor,
    shift_left,
    shift_right,
};

pub const CmpOp = enum {
    less,
    greater,
    equal,
    less_equal,
    greater_equal,
    not_equal,
};

pub const UnOp = enum {
    negate_number,
    negate_bool,
    bit_not,
    int_trunc,
    // `wasm_objects.zig` — array indices arrive from user code as `Число`
    // (f64), but real linear-memory addressing needs i32. Distinct from
    // `int_trunc` (which stays in f64 space, `Число` truncation, not a
    // WASM-level representation change). `to_i32` traps
    // (`i32.trunc_f64_s`) on a negative-after-truncation or out-of-i32-
    // range input — a bad array index crashes the module rather than
    // surfacing a clean panos-level error; a known, accepted Phase-1 gap
    // (see `wasm_objects.zig`'s own doc comment).
    to_i32,
    from_i32,
};

pub const ConstValue = union(enum) {
    number: f64,
    boolean: bool,
    string: []const u8,
    // Raw i32 literal (`i32.const`, unlike `.number`'s always-f64
    // `Целое`/`Число` representation) — `mir_cps.zig`/`wasm_actors.zig`
    // need genuine i32 constants for frame/heap pointer arithmetic and
    // resume-state tags, which must round-trip through i32 ops exactly
    // (`.number`'s f64->i64->i32 conversion dance, used elsewhere for
    // `%`/bitwise ops, is unnecessary overhead for values that are never
    // meant to be a user-visible `Число` in the first place).
    address: u32,
};

pub const InterfaceMethodBinding = struct {
    method_name: []const u8,
    function: FunctionId,
    // True when `function` is the interface's OWN default-method body
    // (`тип X = интерфейс \n функ м(это: X, ...) -> ... \n <тело> \n
    // конец`), not a concrete type's `реализация` override. A default
    // method's `это` parameter is the ABSTRACT interface value itself
    // (so it can keep dispatching polymorphically via `это.
    // другой_метод()`), not the raw underlying concrete value an
    // ordinary override expects — `wasm_interfaces.zig` needs this to
    // decide which shape of `это` a given vtable slot's callee wants.
    // Mirrors `bytecode.Function.is_default_interface_method`'s exact
    // rationale on the native backend (`vm.zig`'s `callInterface`).
    is_default: bool = false,
};

// Three-address, one simple operation per instruction — mirrors
// `bytecode.Instruction`'s union(enum) shape, but every MIR value is named
// (`dst: ValueId`) rather than living on an implicit stack, since MIR is
// consumed by a structural (block/CFG) lowering, not a stack machine.
pub const Instruction = union(enum) {
    const_value: struct { dst: ValueId, value: ConstValue },
    copy: struct { dst: ValueId, src: ValueId },
    load_local: struct { dst: ValueId, local: LocalId },
    store_local: struct { local: LocalId, src: ValueId },
    load_captured: struct { dst: ValueId, index: u32 },
    binary: struct { dst: ValueId, op: BinOp, lhs: ValueId, rhs: ValueId },
    compare: struct { dst: ValueId, op: CmpOp, lhs: ValueId, rhs: ValueId },
    unary: struct { dst: ValueId, op: UnOp, src: ValueId },
    call: struct { dst: ?ValueId, callee: FunctionId, args: []const ValueId },
    call_value: struct { dst: ?ValueId, callee: ValueId, args: []const ValueId },
    call_builtin: struct { dst: ?ValueId, name: []const u8, args: []const ValueId },
    call_method: struct { dst: ?ValueId, receiver: ValueId, name: []const u8, args: []const ValueId },
    // Sync/async is a BACKEND decision (same `is_async_builtin_name`-style
    // check, just applied at MIR→bytecode time instead of AST→bytecode) —
    // one instruction shape covers both, matching the Odin design note.
    call_async: struct { dst: ?ValueId, receiver: ?ValueId, name: []const u8, args: []const ValueId },
    call_foreign: struct { dst: ?ValueId, foreign: bytecode.ForeignFunctionConstant, args: []const ValueId },
    new_aggregate: struct { dst: ValueId, type_name: []const u8, elements: []const ValueId },
    get_property: struct { dst: ValueId, object: ValueId, field_index: u32 },
    set_property: struct { object: ValueId, field_index: u32, value: ValueId },
    new_array: struct { dst: ValueId, elements: []const ValueId },
    new_map: struct { dst: ValueId, keys: []const ValueId, values: []const ValueId },
    get_index: struct { dst: ValueId, object: ValueId, index: ValueId },
    set_index: struct { object: ValueId, index: ValueId, value: ValueId },
    cast_interface: struct { dst: ValueId, src: ValueId, vtable: []const InterfaceMethodBinding },
    invoke_interface: struct { dst: ?ValueId, receiver: ValueId, method_name: []const u8, method_index: u16 = 0, args: []const ValueId },
    // WASM-only (`wasm_interfaces.zig`'s own expansion of `.invoke_interface`
    // — never produced by `mir_lowering.zig`, never seen by the native
    // bytecode compiler). `table_index` is a RUNTIME value (loaded from an
    // interface box's vtable at the call site — which concrete function it
    // resolves to is only known once the program runs), unlike `.call`'s
    // compile-time-fixed `callee: FunctionId`. `wasm_emit.zig` derives the
    // `call_indirect` type check purely from `args`/`dst`'s own MIR types
    // (same as `.call`), and separately ensures (function-section building)
    // that every function ever placed in the WASM function table shares one
    // deduplicated type entry per distinct signature shape — `call_indirect`
    // traps on ANY literal type-index mismatch, even for structurally
    // identical signatures under two separate type-section entries.
    call_indirect: struct { dst: ?ValueId, table_index: ValueId, args: []const ValueId },
    build_variant: struct { dst: ValueId, type_name: []const u8, variant_name: []const u8, tag: u32, fields: []const ValueId },
    match_tag: struct { dst: ValueId, subject: ValueId, tag: u32 },
    get_variant_field: struct { dst: ValueId, subject: ValueId, field_index: u32 },
    // WASM AOT closure support (Stage A) — `function` is EITHER a lambda
    // body already synthesized with its own trailing `env_ptr` parameter
    // (`already_env_aware = true`, `mir_lowering.zig`'s `lowerLambda`) OR
    // a pre-existing named function used as a first-class VALUE
    // (`already_env_aware = false`, `lowerSymbolValueRef`'s `.function`
    // fallback) — the latter needs a thin trailing-`env_ptr`-ignoring
    // WRAPPER synthesized at expansion time (`wasm_interfaces.zig`,
    // reusing its established `wrapperFor`-shaped pattern) since the
    // ORIGINAL function's signature/direct-call sites must stay
    // untouched. `captured` empty is the common "plain function value,
    // zero captures" case. Expanded by `wasm_interfaces.zig` (same pass
    // that already rewrites `.function_ref`/`.cast_interface`) into a
    // real env allocation (one slot per captured value) + a 2-slot
    // `{table_index, env_ptr}` box — see that file's own doc comment.
    build_closure: struct { dst: ValueId, function: FunctionId, captured: []const ValueId, already_env_aware: bool },
    function_ref: struct { dst: ValueId, function: FunctionId },
    spawn: struct { dst: ValueId, callee: ValueId, args: []const ValueId },
    send: struct { process: ValueId, message: ValueId },
    receive: struct { dst: ValueId },
    receive_signal: struct { dst: ValueId },
    // CPS rewrite output (`mir_cps.zig`) — a suspend-capable function's
    // locals are NOT ordinary WASM locals (those reset to zero on every
    // fresh call into the function; a resumed actor step needs its state
    // to survive ACROSS separate WASM calls). `frame` is the function's
    // own frame pointer (an opaque linear-memory address, passed in as
    // the step function's one real parameter — see `wasm_actors.zig`),
    // `slot` a compiler-assigned offset within it. Only ever appear in a
    // function `mir_cps.zig` has already rewritten — a function that
    // never suspends keeps plain `load_local`/`store_local` untouched.
    frame_load: struct { dst: ValueId, frame: ValueId, slot: u32 },
    frame_store: struct { frame: ValueId, slot: u32, src: ValueId },
    // `wasm_actors.zig`'s bump-allocator heap pointer — the ONE piece of
    // process-wide mutable state that can't live in any single function's
    // frame (every process's allocation shares it). A real WASM Global
    // (mutable i32), index `global` into the module's (currently
    // single-entry) global section — never emitted at all for a module
    // with no actor instructions.
    global_get: struct { dst: ValueId, global: u32 },
    global_set: struct { global: u32, src: ValueId },
    // WASM `memory.size`/`memory.grow` (opcodes 0x3F/0x40, both followed
    // by a fixed `0x00` memory-index byte — this backend only ever has
    // one memory) — WASM-only, produced exclusively by `wasm_heap.zig`'s
    // `buildAlloc` to grow linear memory before the bump pointer would
    // walk past the end of it. `memory.size` returns the current size in
    // 64 KiB PAGES (not bytes); `memory.grow` takes a page DELTA and
    // returns the previous page count, or `-1` on failure (host memory
    // limit reached). Real bug found running a synthetic serialize/parse
    // benchmark: `buildAlloc`'s bump pointer never checked against the
    // actual memory size at all — any allocation past the module's
    // initial page count (computed once at compile time from string
    // constants + the actor heap, `wasm_emit.zig`'s `actor_heap_base`)
    // trapped with a raw "memory access out of bounds", not a clean
    // diagnostic, the first time a program allocated enough (a few
    // thousand small strings) to walk past it.
    memory_size: struct { dst: ValueId },
    memory_grow: struct { dst: ValueId, pages: ValueId },
    // Like `frame_load`/`frame_store` but the address is a fully computed
    // RUNTIME i32 value, not `frame + compile-time slot*8` — needed for
    // `wasm_actors.zig`'s mailbox ring buffer (message index only known
    // at runtime, e.g. `frame + ring_base_bytes + head*8`). `frame_load`/
    // `frame_store` can't express this at all (`slot: u32` is a Zig
    // struct field, never a `ValueId`) — kept separate rather than
    // generalizing them, since every OTHER caller (the CPS rewrite
    // itself) only ever needs compile-time-constant slots and benefits
    // from that being visible in the instruction shape.
    mem_load: struct { dst: ValueId, addr: ValueId },
    mem_store: struct { addr: ValueId, src: ValueId },
    // Byte-granular siblings of `mem_load`/`mem_store` above — those are
    // always word-granular (4 or 8 bytes, picked from `dst`/`src`'s own
    // type). String work (`wasm_strings.zig`) needs single-byte access:
    // UTF-8 byte inspection, byte-by-byte copy loops, digit-string
    // construction. `dst`/`src` are always `idx_type` (i32) here — a
    // byte value zero-extended into i32 on load, only the low byte
    // stored on store (`i32.load8_u`/`i32.store8`).
    mem_load8: struct { dst: ValueId, addr: ValueId },
    mem_store8: struct { addr: ValueId, src: ValueId },
    // `?`-operator — an ordinary instruction, not a terminator: early
    // return on failure is runtime semantics INSIDE one opcode already
    // today (unpacks Опция/Результат/any 2-variant ADT, panics or returns
    // early) — invisible to MIR/CFG, same principle already applied to
    // Receive/Await_Async (see the comment in Odin's mir.odin this is
    // ported from).
    try_unwrap: struct { dst: ValueId, src: ValueId },
};

// Assignment target (`lower_place` in the Odin original) — not an
// instruction itself, used by lowering to decide which Store_Local/
// Set_Property/Set_Index to emit for `место = выражение`.
pub const Place = union(enum) {
    local: LocalId,
    property: struct { object: ValueId, field_index: u32 },
    index: struct { object: ValueId, index: ValueId },
};

// Exactly one per block — the CFG's source of truth (no separate graph is
// stored; see `mir_cfg.zig`).
pub const Terminator = union(enum) {
    none, // block not yet closed — only valid transiently during building
    jump: struct { target: BlockId },
    branch: struct { cond: ValueId, then_block: BlockId, else_block: BlockId },
    return_value: struct { value: ?ValueId },
    unreachable_term: struct { reason: []const u8 },
    // CPS rewrite output (`mir_cps.zig`) — a suspend-capable function's
    // step-block hits this instead of `return_value` when its mailbox/
    // signal check comes up empty: the frame's `state` slot has already
    // been set to the matching `ResumeEdge.state` via `frame_store`
    // (see `Instruction.frame_store`), and this terminator just needs
    // `wasm_actors.zig`'s scheduler to see "not done yet" distinctly
    // from an ordinary completion value — including a genuine `Пусто`
    // completion (`return_value{.value = null}`), which must NOT be
    // confused with "still running".
    suspend_return,
};

pub const Local = struct {
    id: LocalId,
    symbol: symbols.SymbolId,
    name: []const u8,
    type_id: types.TypeId,
};

pub const Block = struct {
    id: BlockId,
    instructions: std.ArrayList(Instruction) = .empty,
    terminator: Terminator = .none,
    span: source.Span = .{ .file_id = 0, .start = 0, .end = 0 },

    pub fn deinit(self: *Block, allocator: std.mem.Allocator) void {
        self.instructions.deinit(allocator);
        self.* = undefined;
    }
};

pub const Function = struct {
    id: FunctionId,
    name: []const u8,
    symbol: symbols.SymbolId,
    parameters: []const LocalId = &.{},
    locals: std.ArrayList(Local) = .empty,
    // value_types.items[i] is ValueId(i)'s static type — ValueId/LocalId/
    // BlockId are all plain indices into these arrays (not pointers into a
    // growable array, which could be invalidated across an `append` — same
    // discipline `vm.zig`'s process/frame model already uses).
    value_types: std.ArrayList(types.TypeId) = .empty,
    blocks: std.ArrayList(Block) = .empty,
    entry: BlockId = invalid_block,
    result_type: types.TypeId,
    // A linked AOT module may contain functions lowered from several Panos
    // source modules. Their TypeIds are scoped to different TypeStores, so
    // the WASM emitter must classify a function's values through the store
    // that created them, not through one arbitrary entry-module checker.
    type_store: ?*const types.TypeStore = null,
    span: source.Span,

    pub fn deinit(self: *Function, allocator: std.mem.Allocator) void {
        for (self.blocks.items) |*b| b.deinit(allocator);
        self.blocks.deinit(allocator);
        self.locals.deinit(allocator);
        self.value_types.deinit(allocator);
        allocator.free(self.parameters);
        self.* = undefined;
    }

    pub fn block(self: *Function, id: BlockId) *Block {
        return &self.blocks.items[@intFromEnum(id)];
    }

    pub fn blockConst(self: *const Function, id: BlockId) *const Block {
        return &self.blocks.items[@intFromEnum(id)];
    }

    pub fn valueType(self: *const Function, id: ValueId) types.TypeId {
        return self.value_types.items[@intFromEnum(id)];
    }
};

pub const Module = struct {
    functions: std.ArrayList(Function) = .empty,
    // Key is the same human-readable "имя$Тип1,Тип2" instantiation key the
    // bytecode compiler already uses for generic monomorphization — a
    // generic clone has no single stable SymbolId shared across
    // instantiations, so it can't live in an ordinary symbol→function map.
    generic_instantiations: std.StringHashMap(FunctionId),
    // Backs every variable-length slice field INSIDE an instruction (call
    // args, aggregate elements, vtables, ...) — there are too many such
    // fields across the instruction set to track and free individually
    // (unlike `Function`'s own `blocks`/`locals`/`value_types`, which ARE
    // real `ArrayList`s with a normal `deinit`). One arena per module,
    // torn down as a single unit in `deinit`, same "bump-allocate for the
    // whole pass, free it all at once" shape `compiler.zig`'s
    // `CompileResult.arena` already uses for the bytecode side.
    arena: std.heap.ArenaAllocator,
    // Every top-level function name registered as a `DOM.на_клик`/
    // `.на_клик_контекст`/`.после_кадра` handler (by string-literal
    // argument), collected once during `mir_lowering.zig`'s tree-shaking
    // reachability walk (`addDomHandlerRoots`) — reused by
    // `wasm_gc_arena.zig` to know exactly which functions are genuine
    // JS-invoked entry points (alongside `старт`) that need a bump-
    // pointer checkpoint/restore wrapper. Allocated in `arena` above,
    // so no separate lifetime to manage.
    dom_handler_names: [][]const u8 = &.{},

    pub fn init(allocator: std.mem.Allocator) Module {
        return .{
            .generic_instantiations = .init(allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Module, allocator: std.mem.Allocator) void {
        for (self.functions.items) |*function| function.deinit(allocator);
        self.functions.deinit(allocator);
        self.generic_instantiations.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

test "mir Function.block/valueType index correctly by id" {
    const allocator = std.testing.allocator;
    var function = Function{
        .id = @enumFromInt(0),
        .name = "тест",
        .symbol = @enumFromInt(0),
        .result_type = types.TypeId.raw(0),
        .span = .{ .file_id = 0, .start = 0, .end = 0 },
    };
    defer function.deinit(allocator);
    try function.blocks.append(allocator, .{ .id = @enumFromInt(0), .span = .{ .file_id = 0, .start = 0, .end = 0 } });
    try function.value_types.append(allocator, types.TypeId.raw(7));
    try std.testing.expectEqual(@as(BlockId, @enumFromInt(0)), function.block(@enumFromInt(0)).id);
    try std.testing.expectEqual(types.TypeId.raw(7), function.valueType(@enumFromInt(0)));
}

test "mir Module tracks generic instantiations by name" {
    const allocator = std.testing.allocator;
    var module = Module.init(allocator);
    defer module.deinit(allocator);
    try module.generic_instantiations.put("идентичность$Число", @enumFromInt(3));
    try std.testing.expectEqual(@as(?FunctionId, @enumFromInt(3)), module.generic_instantiations.get("идентичность$Число"));
}
