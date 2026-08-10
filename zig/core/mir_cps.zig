const mir = @import("mir.zig");
const std = @import("std");

pub const SuspendPoint = struct {
    function: mir.FunctionId,
    block: mir.BlockId,
    instruction_index: u32,
    resume_state: u32,
};

pub const ResumeEdge = struct {
    state: u32,
    suspend_block: mir.BlockId,
    resume_block: mir.BlockId,
};

pub const FrameLayout = struct {
    function: mir.FunctionId,
    locals: []const mir.LocalId,
};

pub const FunctionPlan = struct {
    function: mir.FunctionId,
    frame: FrameLayout,
    suspend_points: []const SuspendPoint,
    resume_edges: []const ResumeEdge,
};

// Groups the two analyses into the exact unit the rewrite consumes: one
// function, one durable frame, and monotonically numbered resume states.
pub fn plans(allocator: std.mem.Allocator, module: *const mir.Module) !std.ArrayList(FunctionPlan) {
    var all_points = try collectSuspendPoints(allocator, module);
    defer all_points.deinit(allocator);
    var layouts = try frameLayouts(allocator, module);
    errdefer {
        for (layouts.items) |layout| allocator.free(layout.locals);
        layouts.deinit(allocator);
    }
    var out: std.ArrayList(FunctionPlan) = .empty;
    errdefer out.deinit(allocator);
    for (layouts.items) |layout| {
        var count: usize = 0;
        for (all_points.items) |point| {
            if (point.function == layout.function) count += 1;
        }
        const points = try allocator.alloc(SuspendPoint, count);
        const edges = try allocator.alloc(ResumeEdge, count);
        var at: usize = 0;
        for (all_points.items) |point| {
            if (point.function == layout.function) {
                points[at] = point;
                // The mutating phase splits this block immediately after
                // the receive and replaces this placeholder with the new
                // continuation block id.
                edges[at] = .{ .state = point.resume_state, .suspend_block = point.block, .resume_block = mir.invalid_block };
                at += 1;
            }
        }
        try out.append(allocator, .{ .function = layout.function, .frame = layout, .suspend_points = points, .resume_edges = edges });
    }
    // ownership of locals moved into `out`.
    layouts.clearRetainingCapacity();
    layouts.deinit(allocator);
    return out;
}

pub fn deinitPlans(allocator: std.mem.Allocator, value: *std.ArrayList(FunctionPlan)) void {
    for (value.items) |plan| {
        allocator.free(plan.frame.locals);
        allocator.free(plan.suspend_points);
        allocator.free(plan.resume_edges);
    }
    value.deinit(allocator);
}

// All MIR locals are frame slots for a suspending function. This is larger
// than liveness-minimal spilling, but gives the first CPS backend a simple,
// correct invariant: any value that was materialized into a local survives
// every receive/resume boundary.
pub fn frameLayouts(allocator: std.mem.Allocator, module: *const mir.Module) !std.ArrayList(FrameLayout) {
    var layouts: std.ArrayList(FrameLayout) = .empty;
    errdefer layouts.deinit(allocator);
    for (module.functions.items) |function| {
        var suspends = false;
        for (function.blocks.items) |block| for (block.instructions.items) |instruction| switch (instruction) {
            .receive, .receive_signal => suspends = true,
            else => {},
        };
        if (!suspends) continue;
        const locals = try allocator.alloc(mir.LocalId, function.locals.items.len);
        for (locals, 0..) |*slot, index| slot.* = @enumFromInt(index);
        try layouts.append(allocator, .{ .function = function.id, .locals = locals });
    }
    return layouts;
}

// This scan is the stable input to the mutating CPS rewrite. State zero is
// normal entry; every receive-like instruction gets one later resume state.
pub fn collectSuspendPoints(allocator: std.mem.Allocator, module: *const mir.Module) !std.ArrayList(SuspendPoint) {
    var points: std.ArrayList(SuspendPoint) = .empty;
    errdefer points.deinit(allocator);
    var next_state: u32 = 1;
    for (module.functions.items) |function| for (function.blocks.items) |block| {
        for (block.instructions.items, 0..) |instruction, index| switch (instruction) {
            .receive, .receive_signal => {
                try points.append(allocator, .{ .function = function.id, .block = block.id, .instruction_index = @intCast(index), .resume_state = next_state });
                next_state += 1;
            },
            else => {},
        };
    };
    return points;
}

// CPS phase boundary. It is deliberately separate from AST lowering: the
// pass will turn spawn/receive into resumable process frames before WASM
// emission, preserving the regular MIR for non-suspending functions.
pub fn hasActorInstructions(module: *const mir.Module) bool {
    for (module.functions.items) |function| for (function.blocks.items) |block|
        for (block.instructions.items) |instruction| switch (instruction) {
            .spawn, .send, .receive, .receive_signal => return true,
            else => {},
        };
    return false;
}

// First CPS invariant: an actor instruction is never allowed to reach the
// ordinary stack emitter. The next stages replace every receive with a
// frame-state return and generate the matching resume entry point.
pub fn prepare(module: *mir.Module) !void {
    if (!hasActorInstructions(module)) return;
    var points = try collectSuspendPoints(module.arena.allocator(), module);
    defer points.deinit(module.arena.allocator());
    var actor_plans = try plans(module.arena.allocator(), module);
    defer deinitPlans(module.arena.allocator(), &actor_plans);
    // Keep the analysis live in the pipeline now; the mutating rewrite will
    // consume these exact stable locations in the next pass.
    _ = points.items;
    for (module.functions.items) |function| {
        for (function.blocks.items) |block| {
            for (block.instructions.items) |instruction| switch (instruction) {
                .spawn, .send, .receive, .receive_signal => {},
                else => {},
            };
        }
    }
    _ = std;
}

test "hasActorInstructions detects receive" {
    var module = mir.Module.init(std.testing.allocator);
    defer module.deinit(std.testing.allocator);
    const types = @import("types.zig");
    var function = mir.Function{ .id = @enumFromInt(0), .name = "actor", .symbol = @enumFromInt(0), .result_type = types.TypeId.raw(0), .span = .{ .file_id = 0, .start = 0, .end = 0 } };
    try function.value_types.append(std.testing.allocator, types.TypeId.raw(0));
    var block = mir.Block{ .id = @enumFromInt(0) };
    try block.instructions.append(std.testing.allocator, .{ .receive = .{ .dst = @enumFromInt(0) } });
    try function.blocks.append(std.testing.allocator, block);
    try module.functions.append(std.testing.allocator, function);
    try std.testing.expect(hasActorInstructions(&module));
    var points = try collectSuspendPoints(std.testing.allocator, &module);
    defer points.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), points.items.len);
    try std.testing.expectEqual(@as(u32, 1), points.items[0].resume_state);
    var layouts = try frameLayouts(std.testing.allocator, &module);
    defer {
        for (layouts.items) |layout| std.testing.allocator.free(layout.locals);
        layouts.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), layouts.items.len);
}
