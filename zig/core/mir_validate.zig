const std = @import("std");
const mir = @import("mir.zig");
const mir_cfg = @import("mir_cfg.zig");
const types = @import("types.zig");

// Ported from `core/mir_validate.odin`. Runs AFTER lowering a function —
// never mutates MIR, only reads it. Not currently a hard blocker for
// `mir_lowering.zig` itself (its own construction already guarantees the
// invariants checked here), but a real robustness net against FUTURE
// lowering bugs the way `mir_lowering.odin`'s own differential testing
// found several (see `mir_lowering.zig`'s doc comments) — a malformed MIR
// value/block reference should fail loudly here, not silently corrupt
// `wasm_emit.zig`'s stack-machine replay or crash with an unrelated panic
// deep inside emission.

pub const ValidationIssue = struct {
    message: []const u8,
    // true = structural error (MIR is broken, nothing downstream can be
    // trusted); false = a warning (e.g. an unreachable block — may be
    // legitimate, doesn't necessarily reject the function).
    is_error: bool,
};

fn validBlock(id: mir.BlockId, n: usize) bool {
    return @intFromEnum(id) < n and id != mir.invalid_block;
}

fn validLocal(id: mir.LocalId, n: usize) bool {
    return @intFromEnum(id) < n;
}

fn validValue(id: mir.ValueId, n: usize) bool {
    return @intFromEnum(id) < n and id != mir.invalid_value;
}

// (dst, operands) of a single instruction — EXHAUSTIVE switch (not
// `#partial`/`else`) so a new `Instruction` variant fails to compile here
// until it's given a case, same principle as `core/gc.odin`'s
// get_header/mark_value (see docs/src/architecture/memory-and-gc.md).
// `operands` is allocator-owned, caller frees.
fn instrRefs(allocator: std.mem.Allocator, instruction: mir.Instruction) !struct { dst: ?mir.ValueId, operands: []mir.ValueId } {
    var operands: std.ArrayList(mir.ValueId) = .empty;
    var dst: ?mir.ValueId = null;
    switch (instruction) {
        .const_value => |v| dst = v.dst,
        .copy => |v| {
            dst = v.dst;
            try operands.append(allocator, v.src);
        },
        .load_local => |v| dst = v.dst,
        .store_local => |v| try operands.append(allocator, v.src),
        .load_captured => |v| dst = v.dst,
        .binary => |v| {
            dst = v.dst;
            try operands.appendSlice(allocator, &.{ v.lhs, v.rhs });
        },
        .compare => |v| {
            dst = v.dst;
            try operands.appendSlice(allocator, &.{ v.lhs, v.rhs });
        },
        .unary => |v| {
            dst = v.dst;
            try operands.append(allocator, v.src);
        },
        .call => |v| {
            dst = v.dst;
            try operands.appendSlice(allocator, v.args);
        },
        .call_value => |v| {
            dst = v.dst;
            try operands.append(allocator, v.callee);
            try operands.appendSlice(allocator, v.args);
        },
        .call_builtin => |v| {
            dst = v.dst;
            try operands.appendSlice(allocator, v.args);
        },
        .call_method => |v| {
            dst = v.dst;
            try operands.append(allocator, v.receiver);
            try operands.appendSlice(allocator, v.args);
        },
        .call_async => |v| {
            dst = v.dst;
            if (v.receiver) |r| try operands.append(allocator, r);
            try operands.appendSlice(allocator, v.args);
        },
        .call_foreign => |v| {
            dst = v.dst;
            try operands.appendSlice(allocator, v.args);
        },
        .new_aggregate => |v| {
            dst = v.dst;
            try operands.appendSlice(allocator, v.elements);
        },
        .get_property => |v| {
            dst = v.dst;
            try operands.append(allocator, v.object);
        },
        .set_property => |v| try operands.appendSlice(allocator, &.{ v.object, v.value }),
        .new_array => |v| {
            dst = v.dst;
            try operands.appendSlice(allocator, v.elements);
        },
        .new_map => |v| {
            dst = v.dst;
            try operands.appendSlice(allocator, v.keys);
            try operands.appendSlice(allocator, v.values);
        },
        .get_index => |v| {
            dst = v.dst;
            try operands.appendSlice(allocator, &.{ v.object, v.index });
        },
        .set_index => |v| try operands.appendSlice(allocator, &.{ v.object, v.index, v.value }),
        .cast_interface => |v| {
            dst = v.dst;
            try operands.append(allocator, v.src);
        },
        .invoke_interface => |v| {
            dst = v.dst;
            try operands.append(allocator, v.receiver);
            try operands.appendSlice(allocator, v.args);
        },
        .build_variant => |v| {
            dst = v.dst;
            try operands.appendSlice(allocator, v.fields);
        },
        .match_tag => |v| {
            dst = v.dst;
            try operands.append(allocator, v.subject);
        },
        .get_variant_field => |v| {
            dst = v.dst;
            try operands.append(allocator, v.subject);
        },
        .build_closure => |v| {
            dst = v.dst;
            try operands.appendSlice(allocator, v.captured);
        },
        .function_ref => |v| dst = v.dst,
        .spawn => |v| {
            dst = v.dst;
            try operands.append(allocator, v.callee);
            try operands.appendSlice(allocator, v.args);
        },
        .send => |v| try operands.appendSlice(allocator, &.{ v.process, v.message }),
        .receive => |v| dst = v.dst,
        .receive_signal => |v| dst = v.dst,
        .try_unwrap => |v| {
            dst = v.dst;
            try operands.append(allocator, v.src);
        },
        .frame_load => |v| {
            dst = v.dst;
            try operands.append(allocator, v.frame);
        },
        .frame_store => |v| try operands.appendSlice(allocator, &.{ v.frame, v.src }),
        .global_get => |v| dst = v.dst,
        .global_set => |v| try operands.append(allocator, v.src),
        .mem_load => |v| {
            dst = v.dst;
            try operands.append(allocator, v.addr);
        },
        .mem_store => |v| try operands.appendSlice(allocator, &.{ v.addr, v.src }),
    }
    return .{ .dst = dst, .operands = try operands.toOwnedSlice(allocator) };
}

// `void_type` — the checker's own `Builtins.void` TypeId, needed to decide
// whether a bare `Return` (no value) is legal for this function. Passed in
// rather than hardcoded: `mir.Module`/`mir.Function` never carry a
// reference to the live `types.TypeStore` they were built against (MIR only
// stores the already-resolved `TypeId`s themselves), and re-deriving "which
// TypeId means void" any other way here would silently assume a specific
// `TypeStore.init` allocation order that belongs to `types.zig`, not this
// file.
pub fn validateFunction(allocator: std.mem.Allocator, module: *const mir.Module, function: *const mir.Function, void_type: types.TypeId) ![]ValidationIssue {
    var issues: std.ArrayList(ValidationIssue) = .empty;

    const n_blocks = function.blocks.items.len;
    const n_locals = function.locals.items.len;
    const n_values = function.value_types.items.len;

    if (!validBlock(function.entry, n_blocks)) {
        try issues.append(allocator, .{
            .message = try std.fmt.allocPrint(allocator, "функция '{s}': entry-блок не задан или вне диапазона", .{function.name}),
            .is_error = true,
        });
        return issues.toOwnedSlice(allocator);
    }

    // Invariant `mir_lowering.zig` relies on for EVERY value it produces
    // (see that file's doc comment): a ValueId is used as an operand AT
    // MOST once across the whole function — this is what lets
    // `wasm_emit.zig` replay instructions as a pure stack machine (a
    // producing instruction's result stays on the machine stack until its
    // single consumer, no register allocator needed).
    var use_count: std.AutoHashMap(mir.ValueId, u32) = .init(allocator);
    defer use_count.deinit();
    const countUse = struct {
        fn call(uc: *std.AutoHashMap(mir.ValueId, u32), v: mir.ValueId) !void {
            if (v == mir.invalid_value) return;
            const entry = try uc.getOrPutValue(v, 0);
            entry.value_ptr.* += 1;
        }
    }.call;

    // Set on any terminator that references an out-of-range block —
    // `mir_cfg.computeCfgInfo` indexes its predecessor arrays directly by
    // raw block id (no bounds check, a deliberate perf choice for code that
    // otherwise only ever runs on already-validated MIR), so running it
    // over a malformed Jump/Branch target would crash instead of reporting
    // a clean issue. Skip the reachability pass below in that case — the
    // structural error is already reported, and "don't trust the rest"
    // already applies once ANY structural error is found (see this file's
    // own doc comment).
    var has_bad_block_ref = false;

    for (function.blocks.items) |*blk| {
        switch (blk.terminator) {
            .none => {
                try issues.append(allocator, .{
                    .message = try std.fmt.allocPrint(allocator, "функция '{s}', блок {d}: нет terminator'а", .{ function.name, @intFromEnum(blk.id) }),
                    .is_error = true,
                });
                continue;
            },
            .jump => |j| {
                if (!validBlock(j.target, n_blocks)) {
                    has_bad_block_ref = true;
                    try issues.append(allocator, .{
                        .message = try std.fmt.allocPrint(allocator, "функция '{s}', блок {d}: Jump на несуществующий блок {d}", .{ function.name, @intFromEnum(blk.id), @intFromEnum(j.target) }),
                        .is_error = true,
                    });
                }
            },
            .branch => |b| {
                try countUse(&use_count, b.cond);
                if (!validValue(b.cond, n_values)) {
                    try issues.append(allocator, .{
                        .message = try std.fmt.allocPrint(allocator, "функция '{s}', блок {d}: Branch с неопределённым условием", .{ function.name, @intFromEnum(blk.id) }),
                        .is_error = true,
                    });
                }
                if (!validBlock(b.then_block, n_blocks)) {
                    has_bad_block_ref = true;
                    try issues.append(allocator, .{
                        .message = try std.fmt.allocPrint(allocator, "функция '{s}', блок {d}: Branch.then на несуществующий блок {d}", .{ function.name, @intFromEnum(blk.id), @intFromEnum(b.then_block) }),
                        .is_error = true,
                    });
                }
                if (!validBlock(b.else_block, n_blocks)) {
                    has_bad_block_ref = true;
                    try issues.append(allocator, .{
                        .message = try std.fmt.allocPrint(allocator, "функция '{s}', блок {d}: Branch.else на несуществующий блок {d}", .{ function.name, @intFromEnum(blk.id), @intFromEnum(b.else_block) }),
                        .is_error = true,
                    });
                }
            },
            .return_value => |r| {
                const returns_value = !function.result_type.eql(void_type);
                const has_value = r.value != null;
                if (returns_value and !has_value) {
                    try issues.append(allocator, .{
                        .message = try std.fmt.allocPrint(allocator, "функция '{s}', блок {d}: Return без значения у функции с непустым типом результата", .{ function.name, @intFromEnum(blk.id) }),
                        .is_error = true,
                    });
                }
                if (!returns_value and has_value) {
                    try issues.append(allocator, .{
                        .message = try std.fmt.allocPrint(allocator, "функция '{s}', блок {d}: Return со значением у функции с типом результата Пусто", .{ function.name, @intFromEnum(blk.id) }),
                        .is_error = true,
                    });
                }
                if (r.value) |v| {
                    try countUse(&use_count, v);
                    if (!validValue(v, n_values)) {
                        try issues.append(allocator, .{
                            .message = try std.fmt.allocPrint(allocator, "функция '{s}', блок {d}: Return с неопределённым значением", .{ function.name, @intFromEnum(blk.id) }),
                            .is_error = true,
                        });
                    }
                }
            },
            .unreachable_term => {},
            .suspend_return => {},
        }

        for (blk.instructions.items) |instruction| {
            const refs = try instrRefs(allocator, instruction);
            defer allocator.free(refs.operands);
            if (refs.dst) |d| {
                if (!validValue(d, n_values)) {
                    try issues.append(allocator, .{
                        .message = try std.fmt.allocPrint(allocator, "функция '{s}', блок {d}: инструкция пишет в неопределённый Value_Id", .{ function.name, @intFromEnum(blk.id) }),
                        .is_error = true,
                    });
                }
            }
            for (refs.operands) |op| {
                try countUse(&use_count, op);
                if (!validValue(op, n_values)) {
                    try issues.append(allocator, .{
                        .message = try std.fmt.allocPrint(allocator, "функция '{s}', блок {d}: инструкция читает неопределённый Value_Id", .{ function.name, @intFromEnum(blk.id) }),
                        .is_error = true,
                    });
                }
            }

            switch (instruction) {
                .load_local => |v| {
                    if (!validLocal(v.local, n_locals)) {
                        try issues.append(allocator, .{
                            .message = try std.fmt.allocPrint(allocator, "функция '{s}', блок {d}: Load_Local вне диапазона locals", .{ function.name, @intFromEnum(blk.id) }),
                            .is_error = true,
                        });
                    }
                },
                .store_local => |v| {
                    if (!validLocal(v.local, n_locals)) {
                        try issues.append(allocator, .{
                            .message = try std.fmt.allocPrint(allocator, "функция '{s}', блок {d}: Store_Local вне диапазона locals", .{ function.name, @intFromEnum(blk.id) }),
                            .is_error = true,
                        });
                    }
                },
                .call => |v| {
                    if (@intFromEnum(v.callee) >= module.functions.items.len) {
                        try issues.append(allocator, .{
                            .message = try std.fmt.allocPrint(allocator, "функция '{s}', блок {d}: Call на несуществующую функцию", .{ function.name, @intFromEnum(blk.id) }),
                            .is_error = true,
                        });
                    } else {
                        const callee = &module.functions.items[@intFromEnum(v.callee)];
                        if (v.args.len != callee.parameters.len) {
                            try issues.append(allocator, .{
                                .message = try std.fmt.allocPrint(allocator, "функция '{s}', блок {d}: Call в '{s}' с {d} аргументами, ожидалось {d}", .{ function.name, @intFromEnum(blk.id), callee.name, v.args.len, callee.parameters.len }),
                                .is_error = true,
                            });
                        }
                    }
                },
                else => {},
            }
        }
    }

    var it = use_count.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* > 1) {
            try issues.append(allocator, .{
                .message = try std.fmt.allocPrint(allocator, "функция '{s}': v{d} используется {d} раз(а) — нарушен single-use инвариант, значения с >1 использования обязаны идти через Local", .{ function.name, @intFromEnum(entry.key_ptr.*), entry.value_ptr.* }),
                .is_error = true,
            });
        }
    }

    if (!has_bad_block_ref) {
        var cfg = try mir_cfg.computeCfgInfo(allocator, function);
        defer cfg.deinit();
        for (cfg.reachable, 0..) |reachable, i| {
            if (!reachable) {
                try issues.append(allocator, .{
                    .message = try std.fmt.allocPrint(allocator, "функция '{s}': блок {d} недостижим из entry", .{ function.name, i }),
                    .is_error = false,
                });
            }
        }
    }

    return issues.toOwnedSlice(allocator);
}

pub fn validateModule(allocator: std.mem.Allocator, module: *const mir.Module, void_type: types.TypeId) ![]ValidationIssue {
    var all: std.ArrayList(ValidationIssue) = .empty;
    for (module.functions.items) |*function| {
        const issues = try validateFunction(allocator, module, function, void_type);
        defer allocator.free(issues);
        try all.appendSlice(allocator, issues);
    }
    return all.toOwnedSlice(allocator);
}

pub fn freeIssues(allocator: std.mem.Allocator, issues: []const ValidationIssue) void {
    for (issues) |issue| allocator.free(issue.message);
    allocator.free(issues);
}

const mir_builder = @import("mir_builder.zig");
const symbols = @import("symbols.zig");
const source = @import("source.zig");

test "validateFunction reports a Jump to a nonexistent block" {
    const allocator = std.testing.allocator;
    var module = mir.Module.init(allocator);
    defer module.deinit(allocator);
    const void_type: types.TypeId = types.TypeId.raw(0);
    const function_id = try mir_builder.newFunction(&module, allocator, "тест", @enumFromInt(0), void_type, .{ .file_id = 0, .start = 0, .end = 0 });
    var builder = try mir_builder.Builder.beginFunction(&module, allocator, function_id);
    builder.terminate(.{ .jump = .{ .target = @enumFromInt(99) } });

    const function = &module.functions.items[@intFromEnum(function_id)];
    const issues = try validateFunction(allocator, &module, function, void_type);
    defer freeIssues(allocator, issues);

    var found = false;
    for (issues) |issue| {
        if (issue.is_error and std.mem.indexOf(u8, issue.message, "Jump на несуществующий блок") != null) found = true;
    }
    try std.testing.expect(found);
}

test "validateFunction reports a value used more than once (single-use invariant)" {
    const allocator = std.testing.allocator;
    var module = mir.Module.init(allocator);
    defer module.deinit(allocator);
    const void_type: types.TypeId = types.TypeId.raw(0);
    const number_type: types.TypeId = types.TypeId.raw(1);
    const function_id = try mir_builder.newFunction(&module, allocator, "тест", @enumFromInt(0), number_type, .{ .file_id = 0, .start = 0, .end = 0 });
    var builder = try mir_builder.Builder.beginFunction(&module, allocator, function_id);
    const v = try builder.newValue(number_type);
    try builder.emit(.{ .const_value = .{ .dst = v, .value = .{ .number = 1.0 } } });
    const dst = try builder.newValue(number_type);
    // Reuses `v` as BOTH operands — violates the single-use invariant every
    // lowering function in `mir_lowering.zig` is written to preserve.
    try builder.emit(.{ .binary = .{ .dst = dst, .op = .add, .lhs = v, .rhs = v } });
    builder.terminate(.{ .return_value = .{ .value = dst } });

    const function = &module.functions.items[@intFromEnum(function_id)];
    const issues = try validateFunction(allocator, &module, function, void_type);
    defer freeIssues(allocator, issues);

    var found = false;
    for (issues) |issue| {
        if (issue.is_error and std.mem.indexOf(u8, issue.message, "нарушен single-use инвариант") != null) found = true;
    }
    try std.testing.expect(found);
}

test "validateFunction warns (not errors) on an unreachable block" {
    const allocator = std.testing.allocator;
    var module = mir.Module.init(allocator);
    defer module.deinit(allocator);
    const void_type: types.TypeId = types.TypeId.raw(0);
    const function_id = try mir_builder.newFunction(&module, allocator, "тест", @enumFromInt(0), void_type, .{ .file_id = 0, .start = 0, .end = 0 });
    var builder = try mir_builder.Builder.beginFunction(&module, allocator, function_id);
    builder.terminate(.{ .return_value = .{ .value = null } });
    _ = try builder.newBlock(); // never targeted by any Jump/Branch

    const function = &module.functions.items[@intFromEnum(function_id)];
    const issues = try validateFunction(allocator, &module, function, void_type);
    defer freeIssues(allocator, issues);

    var found_warning = false;
    for (issues) |issue| {
        if (!issue.is_error and std.mem.indexOf(u8, issue.message, "недостижим из entry") != null) found_warning = true;
    }
    try std.testing.expect(found_warning);
}
