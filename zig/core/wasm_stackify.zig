const std = @import("std");
const mir = @import("mir.zig");
const mir_cfg = @import("mir_cfg.zig");

// Ported from `core/wasm_stackify.odin` — structural queries over the MIR
// CFG (`mir_cfg.zig`) that `wasm_emit.zig` needs to decide where to open/
// close WASM `loop`/`if` (structured control flow — block/loop/if, no
// goto). Not a separate IR tree — pure QUERIES, called directly from the
// emit pass.
//
// Why not a full Emscripten-style relooper: panos as a LANGUAGE has no
// goto/arbitrary jumps — the ONLY source of a MIR CFG is `mir_lowering.zig`,
// which builds если/иначе and пока STRUCTURALLY (see `lowerIfExpr`/
// `lowerWhile`) — the graph is always reducible. But "where do если/иначе
// branches merge" and "which Branch arm of a loop header is the body vs.
// the exit" can't be reliably determined from reverse-postorder position
// alone (unlike a back-edge, see `isLoopHeader`) — dominance is needed:
// an если/иначе merge is the UNIQUE block M with idom[M] == branch_block,
// M ∉ {then_block, else_block} (see `findMerge`) — only such an M has
// EVERY converging path pass exclusively through branch_block, which is
// what "merge point of THIS если/иначе" actually means, as opposed to a
// block shared with something external (e.g. a loop's exit_block, which
// both прервать from inside if/else AND the header's own else-branch can
// reach — without dominance, "more than one predecessor" alone confuses
// "merge of my two branches" with "a point shared with outside code").

pub fn buildRpoIndex(allocator: std.mem.Allocator, info: *const mir_cfg.CfgInfo) !std.AutoHashMap(mir.BlockId, usize) {
    var index: std.AutoHashMap(mir.BlockId, usize) = .init(allocator);
    for (info.reverse_postorder, 0..) |block, i| try index.put(block, i);
    return index;
}

// True if block `b` has a predecessor `p` with rpo_index[p] >= rpo_index[b]
// (a back-edge). Correct precisely because a jump-to-loop-header is the
// ONLY kind of backward edge this lowering can ever produce (the same
// fact `mir_lowering.zig`'s CFG shape already relies on: a `branch`
// terminator always points forward).
pub fn isLoopHeader(info: *const mir_cfg.CfgInfo, rpo_index: *const std.AutoHashMap(mir.BlockId, usize), b: mir.BlockId) bool {
    const b_index = rpo_index.get(b) orelse return false;
    for (info.predecessors[@intFromEnum(b)].items) |p| {
        const p_index = rpo_index.get(p) orelse continue;
        if (p_index >= b_index) return true;
    }
    return false;
}

// Reachable from `from` to `target` via `successors()` (`mir_cfg.zig`),
// without revisiting an already-seen block.
pub fn canReach(allocator: std.mem.Allocator, function: *const mir.Function, from: mir.BlockId, target: mir.BlockId) !bool {
    var visited: std.AutoHashMap(mir.BlockId, void) = .init(allocator);
    defer visited.deinit();
    var stack: std.ArrayList(mir.BlockId) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, from);
    while (stack.pop()) |b| {
        if (b == target) return true;
        if (visited.contains(b)) continue;
        try visited.put(b, {});
        const succs = mir_cfg.successors(function.blockConst(b).terminator);
        var i: u2 = 0;
        while (i < succs.count) : (i += 1) {
            if (!visited.contains(succs.blocks[i])) try stack.append(allocator, succs.blocks[i]);
        }
    }
    return false;
}

// A loop header's `branch(cond, t, e)`: which of t/e is the loop BODY (can
// reach back to header), which is the block AFTER the loop. Does not rely
// on argument order — checks structurally.
pub fn identifyLoopBodyAndExit(allocator: std.mem.Allocator, function: *const mir.Function, header: mir.BlockId, then_block: mir.BlockId, else_block: mir.BlockId) !struct { body: mir.BlockId, exit: mir.BlockId } {
    if (try canReach(allocator, function, then_block, header)) return .{ .body = then_block, .exit = else_block };
    return .{ .body = else_block, .exit = then_block };
}

// Immediate dominators — standard iterative algorithm (Cooper/Harvey/
// Kennedy, "A Simple, Fast Dominance Algorithm") over reverse-postorder +
// predecessors, both already computed by `mir_cfg.CfgInfo`.
pub fn computeIdom(allocator: std.mem.Allocator, function: *const mir.Function, info: *const mir_cfg.CfgInfo, rpo_index: *const std.AutoHashMap(mir.BlockId, usize)) !std.AutoHashMap(mir.BlockId, mir.BlockId) {
    var idom: std.AutoHashMap(mir.BlockId, mir.BlockId) = .init(allocator);
    const entry = function.entry;
    try idom.put(entry, entry);

    var changed = true;
    while (changed) {
        changed = false;
        for (info.reverse_postorder) |b| {
            if (b == entry) continue;
            var new_idom: mir.BlockId = mir.invalid_block;
            for (info.predecessors[@intFromEnum(b)].items) |p| {
                if (!idom.contains(p)) continue;
                if (new_idom == mir.invalid_block) {
                    new_idom = p;
                } else {
                    new_idom = intersectDoms(&idom, rpo_index, new_idom, p);
                }
            }
            if (new_idom != mir.invalid_block) {
                const old = idom.get(b);
                if (old == null or old.? != new_idom) {
                    try idom.put(b, new_idom);
                    changed = true;
                }
            }
        }
    }
    return idom;
}

fn intersectDoms(idom: *const std.AutoHashMap(mir.BlockId, mir.BlockId), rpo_index: *const std.AutoHashMap(mir.BlockId, usize), a: mir.BlockId, b: mir.BlockId) mir.BlockId {
    var x = a;
    var y = b;
    while (x != y) {
        while (rpo_index.get(x).? > rpo_index.get(y).?) x = idom.get(x).?;
        while (rpo_index.get(y).? > rpo_index.get(x).?) y = idom.get(y).?;
    }
    return x;
}

// The UNIQUE block M with idom[M] == branch_block, other than then_block/
// else_block themselves (see this file's doc comment). `null` — both
// branches terminate execution (return/panic/loop forever), there is no
// merge.
pub fn findMerge(function: *const mir.Function, idom: *const std.AutoHashMap(mir.BlockId, mir.BlockId), branch_block: mir.BlockId, then_block: mir.BlockId, else_block: mir.BlockId) ?mir.BlockId {
    for (0..function.blocks.items.len) |i| {
        const b: mir.BlockId = @enumFromInt(i);
        if (b == then_block or b == else_block or b == branch_block) continue;
        const dominator = idom.get(b) orelse continue;
        if (dominator == branch_block) return b;
    }
    return null;
}

const mir_builder = @import("mir_builder.zig");
const symbols = @import("symbols.zig");
const source = @import("source.zig");
const types = @import("types.zig");

fn buildDiamondFunction(allocator: std.mem.Allocator, module: *mir.Module) !mir.FunctionId {
    const span: source.Span = .{ .file_id = 0, .start = 0, .end = 0 };
    const number_type: types.TypeId = @enumFromInt(1);
    const function_id = try mir_builder.newFunction(module, allocator, "тест", @enumFromInt(0), number_type, span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, function_id);
    const cond = try builder.newValue(@enumFromInt(0));
    try builder.emit(.{ .const_value = .{ .dst = cond, .value = .{ .boolean = true } } });
    const then_block = try builder.newBlock();
    const else_block = try builder.newBlock();
    const merge_block = try builder.newBlock();
    builder.terminate(.{ .branch = .{ .cond = cond, .then_block = then_block, .else_block = else_block } });
    builder.setCurrentBlock(then_block);
    builder.terminate(.{ .jump = .{ .target = merge_block } });
    builder.setCurrentBlock(else_block);
    builder.terminate(.{ .jump = .{ .target = merge_block } });
    builder.setCurrentBlock(merge_block);
    builder.terminate(.{ .return_value = .{ .value = null } });
    return function_id;
}

test "findMerge identifies the join block of a diamond если/иначе" {
    const allocator = std.testing.allocator;
    var module = mir.Module.init(allocator);
    defer module.deinit(allocator);
    const function_id = try buildDiamondFunction(allocator, &module);
    const function = &module.functions.items[@intFromEnum(function_id)];

    var cfg = try mir_cfg.computeCfgInfo(allocator, function);
    defer cfg.deinit();
    var rpo_index = try buildRpoIndex(allocator, &cfg);
    defer rpo_index.deinit();
    var idom = try computeIdom(allocator, function, &cfg, &rpo_index);
    defer idom.deinit();

    const merge = findMerge(function, &idom, @enumFromInt(0), @enumFromInt(1), @enumFromInt(2));
    try std.testing.expectEqual(@as(?mir.BlockId, @enumFromInt(3)), merge);
}

fn buildLoopFunction(allocator: std.mem.Allocator, module: *mir.Module) !mir.FunctionId {
    const span: source.Span = .{ .file_id = 0, .start = 0, .end = 0 };
    const void_type: types.TypeId = @enumFromInt(0);
    const function_id = try mir_builder.newFunction(module, allocator, "цикл", @enumFromInt(0), void_type, span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, function_id);
    const header = try builder.newBlock();
    const body = try builder.newBlock();
    const exit = try builder.newBlock();
    builder.terminate(.{ .jump = .{ .target = header } });
    builder.setCurrentBlock(header);
    const cond = try builder.newValue(@enumFromInt(0));
    try builder.emit(.{ .const_value = .{ .dst = cond, .value = .{ .boolean = true } } });
    builder.terminate(.{ .branch = .{ .cond = cond, .then_block = body, .else_block = exit } });
    builder.setCurrentBlock(body);
    builder.terminate(.{ .jump = .{ .target = header } });
    builder.setCurrentBlock(exit);
    builder.terminate(.{ .return_value = .{ .value = null } });
    return function_id;
}

test "isLoopHeader detects the header via its own back-edge from the body" {
    const allocator = std.testing.allocator;
    var module = mir.Module.init(allocator);
    defer module.deinit(allocator);
    const function_id = try buildLoopFunction(allocator, &module);
    const function = &module.functions.items[@intFromEnum(function_id)];

    var cfg = try mir_cfg.computeCfgInfo(allocator, function);
    defer cfg.deinit();
    var rpo_index = try buildRpoIndex(allocator, &cfg);
    defer rpo_index.deinit();

    const header: mir.BlockId = @enumFromInt(1);
    const body: mir.BlockId = @enumFromInt(2);
    try std.testing.expect(isLoopHeader(&cfg, &rpo_index, header));
    try std.testing.expect(!isLoopHeader(&cfg, &rpo_index, body));

    const identified = try identifyLoopBodyAndExit(allocator, function, header, body, @enumFromInt(3));
    try std.testing.expectEqual(body, identified.body);
    try std.testing.expectEqual(@as(mir.BlockId, @enumFromInt(3)), identified.exit);
}
