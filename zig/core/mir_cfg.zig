const std = @import("std");
const mir = @import("mir.zig");
const types = @import("types.zig");

// Вычисляется НА ЛЕТУ по терминаторам блоков, никогда не хранится как
// синхронизированный граф в `mir.Function` — терминатор является
// единственным источником истины о потоке управления (см. doc-комментарий
// `mir.zig`); кеширование этого где-либо рискует устареть в момент, когда
// lowering/оптимизация переписывают терминатор.
pub const CfgInfo = struct {
    allocator: std.mem.Allocator,
    predecessors: []std.ArrayList(mir.BlockId),
    reachable: []bool,
    reverse_postorder: []mir.BlockId,

    pub fn deinit(self: *CfgInfo) void {
        for (self.predecessors) |*list| list.deinit(self.allocator);
        self.allocator.free(self.predecessors);
        self.allocator.free(self.reachable);
        self.allocator.free(self.reverse_postorder);
        self.* = undefined;
    }
};

// Куда уходит поток управления из блока согласно ЕГО СОБСТВЕННОМУ
// терминатору. Фиксированный массив из 2 элементов + счётчик (не срез) —
// у терминатора сегодня не может быть больше двух преемников, а возврат
// среза на локальный массив привёл бы к висячей ссылке.
pub const Successors = struct {
    blocks: [2]mir.BlockId = undefined,
    count: u2 = 0,
};

pub fn successors(terminator: mir.Terminator) Successors {
    return switch (terminator) {
        .jump => |jump| .{ .blocks = .{ jump.target, undefined }, .count = 1 },
        .branch => |branch| .{ .blocks = .{ branch.then_block, branch.else_block }, .count = 2 },
        .return_value, .unreachable_term, .none, .suspend_return => .{},
    };
}

// ПРЕДУСЛОВИЕ: каждая цель Jump/Branch в `function` — валидный id блока в
// допустимом диапазоне — `predecessors` индексируется напрямую по сырому
// id без проверки границ (это выполняется на каждой lowered-функции,
// поэтому хеш-таблица здесь была бы реальным оверхедом без пользы на
// доверенном входе). Именно `mir_validate.zig` проверяет это предусловие
// на непроверенном/только что lowered MIR — вызывающий код, который ещё
// не прогнал валидацию, должен сделать это сначала, иначе рискует
// получить панику по выходу за границы массива вместо чистой диагностики.
pub fn computeCfgInfo(allocator: std.mem.Allocator, function: *const mir.Function) !CfgInfo {
    const n = function.blocks.items.len;
    const predecessors = try allocator.alloc(std.ArrayList(mir.BlockId), n);
    for (predecessors) |*list| list.* = .empty;
    const reachable = try allocator.alloc(bool, n);
    @memset(reachable, false);

    if (n == 0 or function.entry == mir.invalid_block) {
        return .{
            .allocator = allocator,
            .predecessors = predecessors,
            .reachable = reachable,
            .reverse_postorder = try allocator.alloc(mir.BlockId, 0),
        };
    }

    // Итеративный post-order DFS (без рекурсии — CFG может уйти глубоко на
    // длинной цепочке если/иначе, а рекурсия рискует переполнить стек Zig
    // на достаточно большой функции).
    var postorder: std.ArrayList(mir.BlockId) = .empty;
    defer postorder.deinit(allocator);
    const visited = try allocator.alloc(bool, n);
    defer allocator.free(visited);
    @memset(visited, false);

    const Frame = struct { block: mir.BlockId, succ_index: u2 };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(allocator);

    visited[@intFromEnum(function.entry)] = true;
    reachable[@intFromEnum(function.entry)] = true;
    try stack.append(allocator, .{ .block = function.entry, .succ_index = 0 });

    while (stack.items.len > 0) {
        const frame = &stack.items[stack.items.len - 1];
        const succs = successors(function.blockConst(frame.block).terminator);

        if (frame.succ_index < succs.count) {
            const next = succs.blocks[frame.succ_index];
            frame.succ_index += 1;
            try predecessors[@intFromEnum(next)].append(allocator, frame.block);
            if (!visited[@intFromEnum(next)]) {
                visited[@intFromEnum(next)] = true;
                reachable[@intFromEnum(next)] = true;
                try stack.append(allocator, .{ .block = next, .succ_index = 0 });
            }
        } else {
            try postorder.append(allocator, frame.block);
            _ = stack.pop();
        }
    }

    const reverse_postorder = try allocator.alloc(mir.BlockId, postorder.items.len);
    for (postorder.items, 0..) |block, index| {
        reverse_postorder[postorder.items.len - 1 - index] = block;
    }

    return .{
        .allocator = allocator,
        .predecessors = predecessors,
        .reachable = reachable,
        .reverse_postorder = reverse_postorder,
    };
}

fn testFunction(allocator: std.mem.Allocator) !mir.Function {
    _ = allocator;
    return .{
        .id = @enumFromInt(0),
        .name = "тест",
        .symbol = @enumFromInt(0),
        .result_type = types.TypeId.raw(0),
        .span = .{ .file_id = 0, .start = 0, .end = 0 },
    };
}

test "computeCfgInfo finds a diamond если/иначе join reachable with two predecessors" {
    const allocator = std.testing.allocator;
    var function = try testFunction(allocator);
    defer function.deinit(allocator);
    // entry -> {then, else} -> join (ромб слияния если/иначе)
    try function.blocks.append(allocator, .{ .id = @enumFromInt(0), .terminator = .{ .branch = .{ .cond = @enumFromInt(0), .then_block = @enumFromInt(1), .else_block = @enumFromInt(2) } } });
    try function.blocks.append(allocator, .{ .id = @enumFromInt(1), .terminator = .{ .jump = .{ .target = @enumFromInt(3) } } });
    try function.blocks.append(allocator, .{ .id = @enumFromInt(2), .terminator = .{ .jump = .{ .target = @enumFromInt(3) } } });
    try function.blocks.append(allocator, .{ .id = @enumFromInt(3), .terminator = .{ .return_value = .{ .value = null } } });
    function.entry = @enumFromInt(0);

    var info = try computeCfgInfo(allocator, &function);
    defer info.deinit();

    try std.testing.expect(info.reachable[0] and info.reachable[1] and info.reachable[2] and info.reachable[3]);
    try std.testing.expectEqual(@as(usize, 2), info.predecessors[3].items.len);
    try std.testing.expectEqual(@as(mir.BlockId, @enumFromInt(0)), info.reverse_postorder[0]);
    try std.testing.expectEqual(@as(mir.BlockId, @enumFromInt(3)), info.reverse_postorder[info.reverse_postorder.len - 1]);
}

test "computeCfgInfo marks an unreachable block (never jumped to) as unreachable" {
    const allocator = std.testing.allocator;
    var function = try testFunction(allocator);
    defer function.deinit(allocator);
    try function.blocks.append(allocator, .{ .id = @enumFromInt(0), .terminator = .{ .return_value = .{ .value = null } } });
    try function.blocks.append(allocator, .{ .id = @enumFromInt(1), .terminator = .{ .return_value = .{ .value = null } } });
    function.entry = @enumFromInt(0);

    var info = try computeCfgInfo(allocator, &function);
    defer info.deinit();

    try std.testing.expect(info.reachable[0]);
    try std.testing.expect(!info.reachable[1]);
}
