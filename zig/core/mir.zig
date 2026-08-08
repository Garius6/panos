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
};

pub const ConstValue = union(enum) {
    number: f64,
    boolean: bool,
    string: []const u8,
};

pub const InterfaceMethodBinding = struct {
    method_name: []const u8,
    function: FunctionId,
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
    invoke_interface: struct { dst: ?ValueId, receiver: ValueId, method_name: []const u8, args: []const ValueId },
    build_variant: struct { dst: ValueId, type_name: []const u8, variant_name: []const u8, tag: u32, fields: []const ValueId },
    match_tag: struct { dst: ValueId, subject: ValueId, tag: u32 },
    get_variant_field: struct { dst: ValueId, subject: ValueId, field_index: u32 },
    build_closure: struct { dst: ValueId, function: FunctionId, captured: []const ValueId },
    function_ref: struct { dst: ValueId, function: FunctionId },
    spawn: struct { dst: ValueId, callee: ValueId, args: []const ValueId },
    send: struct { process: ValueId, message: ValueId },
    receive: struct { dst: ValueId },
    receive_signal: struct { dst: ValueId },
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
        .result_type = @enumFromInt(0),
        .span = .{ .file_id = 0, .start = 0, .end = 0 },
    };
    defer function.deinit(allocator);
    try function.blocks.append(allocator, .{ .id = @enumFromInt(0), .span = .{ .file_id = 0, .start = 0, .end = 0 } });
    try function.value_types.append(allocator, @enumFromInt(7));
    try std.testing.expectEqual(@as(BlockId, @enumFromInt(0)), function.block(@enumFromInt(0)).id);
    try std.testing.expectEqual(@as(types.TypeId, @enumFromInt(7)), function.valueType(@enumFromInt(0)));
}

test "mir Module tracks generic instantiations by name" {
    const allocator = std.testing.allocator;
    var module = Module.init(allocator);
    defer module.deinit(allocator);
    try module.generic_instantiations.put("идентичность$Число", @enumFromInt(3));
    try std.testing.expectEqual(@as(?FunctionId, @enumFromInt(3)), module.generic_instantiations.get("идентичность$Число"));
}
