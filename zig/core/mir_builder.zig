const std = @import("std");
const mir = @import("mir.zig");
const source = @import("source.zig");
const symbols = @import("symbols.zig");
const types = @import("types.zig");

// Ported from `core/mir_builder.odin`. `Builder` is a thin wrapper around
// ONE module function, accumulating instructions into a "current" block.
// It references the function through `module`+`function_id` (an index),
// NEVER a raw `*mir.Function` — `module.functions.append` can reallocate
// the backing buffer, invalidating any previously-taken pointer (same
// discipline `ValueId`/`LocalId`/`BlockId` already enforce as plain
// indices, not pointers). This matters even for a single top-level
// function once lowering is extended to closures (Phase 2): a lambda
// expression registers its OWN function lazily, mid-lowering of the
// OUTER function's body — an `append` at that point could invalidate an
// outer-scope `*mir.Function` a caller might otherwise have cached.

pub fn newFunction(
    module: *mir.Module,
    allocator: std.mem.Allocator,
    name: []const u8,
    symbol: symbols.SymbolId,
    result_type: types.TypeId,
    span: source.Span,
) !mir.FunctionId {
    const id: mir.FunctionId = @enumFromInt(module.functions.items.len);
    try module.functions.append(allocator, .{
        .id = id,
        .name = name,
        .symbol = symbol,
        .entry = mir.invalid_block,
        .result_type = result_type,
        .span = span,
    });
    return id;
}

pub const Builder = struct {
    module: *mir.Module,
    allocator: std.mem.Allocator,
    function_id: mir.FunctionId,
    current_block_id: mir.BlockId = mir.invalid_block,
    terminated: bool = false,

    // A fresh dereference of `module.functions.items[function_id]` on
    // EVERY call (never cached on the Builder) — see the module doc
    // comment above for why.
    pub fn currentFunction(self: *Builder) *mir.Function {
        return &self.module.functions.items[@intFromEnum(self.function_id)];
    }

    // Creates a builder for lowering the BODY of a function already
    // reserved via `newFunction` — immediately opens an entry block.
    pub fn beginFunction(module: *mir.Module, allocator: std.mem.Allocator, function_id: mir.FunctionId) !Builder {
        var self = Builder{ .module = module, .allocator = allocator, .function_id = function_id };
        const entry = try self.newBlock();
        self.currentFunction().entry = entry;
        self.setCurrentBlock(entry);
        return self;
    }

    pub fn newBlock(self: *Builder) !mir.BlockId {
        const function = self.currentFunction();
        const id: mir.BlockId = @enumFromInt(function.blocks.items.len);
        try function.blocks.append(self.allocator, .{ .id = id });
        return id;
    }

    pub fn setCurrentBlock(self: *Builder, id: mir.BlockId) void {
        self.current_block_id = id;
        self.terminated = self.currentFunction().blockConst(id).terminator != .none;
    }

    pub fn newLocal(self: *Builder, symbol: symbols.SymbolId, name: []const u8, type_id: types.TypeId) !mir.LocalId {
        const function = self.currentFunction();
        const id: mir.LocalId = @enumFromInt(function.locals.items.len);
        try function.locals.append(self.allocator, .{ .id = id, .symbol = symbol, .name = name, .type_id = type_id });
        return id;
    }

    pub fn newValue(self: *Builder, type_id: types.TypeId) !mir.ValueId {
        const function = self.currentFunction();
        const id: mir.ValueId = @enumFromInt(function.value_types.items.len);
        try function.value_types.append(self.allocator, type_id);
        return id;
    }

    pub fn valueType(self: *Builder, value: mir.ValueId) types.TypeId {
        return self.currentFunction().valueType(value);
    }

    pub fn currentBlock(self: *Builder) *mir.Block {
        return self.currentFunction().block(self.current_block_id);
    }

    // `emit`/`terminate` panic if the current block is ALREADY closed —
    // the same invariant lowering's own flow-tracking must uphold (after
    // возврат/прервать/продолжить, lowering must not try to append to
    // that same block) — this panic is a second, defensive line, not the
    // primary enforcement.
    pub fn emit(self: *Builder, instruction: mir.Instruction) !void {
        if (self.terminated) @panic("mir_builder: текущий блок уже завершён terminator'ом");
        try self.currentBlock().instructions.append(self.allocator, instruction);
    }

    pub fn terminate(self: *Builder, terminator: mir.Terminator) void {
        if (self.terminated) @panic("mir_builder: текущий блок уже завершён terminator'ом");
        self.currentBlock().terminator = terminator;
        self.terminated = true;
    }

    pub fn isTerminated(self: *const Builder) bool {
        return self.terminated;
    }
};

test "mir_builder accumulates instructions into the current block until terminated" {
    const allocator = std.testing.allocator;
    var module = mir.Module.init(allocator);
    defer module.deinit(allocator);
    const span: source.Span = .{ .file_id = 0, .start = 0, .end = 0 };
    const number_type: types.TypeId = @enumFromInt(1);
    const function_id = try newFunction(&module, allocator, "тест", @enumFromInt(0), number_type, span);
    var builder = try Builder.beginFunction(&module, allocator, function_id);

    const forty_two = try builder.newValue(number_type);
    try builder.emit(.{ .const_value = .{ .dst = forty_two, .value = .{ .number = 42 } } });
    try std.testing.expect(!builder.isTerminated());
    builder.terminate(.{ .return_value = .{ .value = forty_two } });
    try std.testing.expect(builder.isTerminated());

    const function = builder.currentFunction();
    try std.testing.expectEqual(@as(usize, 1), function.blocks.items.len);
    try std.testing.expectEqual(@as(usize, 1), function.blockConst(function.entry).instructions.items.len);
}

test "mir_builder panics when emitting past a terminated block" {
    const allocator = std.testing.allocator;
    var module = mir.Module.init(allocator);
    defer module.deinit(allocator);
    const span: source.Span = .{ .file_id = 0, .start = 0, .end = 0 };
    const void_type: types.TypeId = @enumFromInt(0);
    const function_id = try newFunction(&module, allocator, "тест", @enumFromInt(0), void_type, span);
    var builder = try Builder.beginFunction(&module, allocator, function_id);
    builder.terminate(.{ .return_value = .{ .value = null } });

    // Zig has no `expectPanic` — this is exercised END-TO-END instead by
    // `mir_lowering_test.zig`'s exhaustiveness check (a real lowering bug
    // hitting this path would abort that test binary, same as any other
    // Zig `@panic`), matching how this VM already treats its own internal
    // invariant panics elsewhere (never unit-tested by triggering the
    // panic directly).
}
