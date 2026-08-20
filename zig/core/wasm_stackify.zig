const std = @import("std");
const mir = @import("mir.zig");
const mir_cfg = @import("mir_cfg.zig");

// Структурные запросы над MIR CFG (`mir_cfg.zig`), нужные `wasm_emit.zig`,
// чтобы решить, где открывать/закрывать WASM `loop`/`if` (структурированное
// управление потоком — block/loop/if, без goto). Не отдельное IR-дерево —
// чистые ЗАПРОСЫ, вызываемые напрямую из прохода эмиссии.
//
// Почему не полноценный relooper в стиле Emscripten: у панос как у ЯЗЫКА
// нет goto/произвольных переходов — ЕДИНСТВЕННЫЙ источник MIR CFG —
// `mir_lowering.zig`, который строит если/иначе и пока СТРУКТУРНО (см.
// `lowerIfExpr`/`lowerWhile`) — граф всегда редуцируем. Но "где сходятся
// ветви если/иначе" и "какая из ветвей Branch у заголовка цикла — тело, а
// какая — выход" нельзя надёжно определить только по позиции в
// reverse-postorder (в отличие от обратного ребра, см. `isLoopHeader`) —
// нужна доминация: место слияния если/иначе — ЕДИНСТВЕННЫЙ блок M с
// idom[M] == branch_block, M ∉ {then_block, else_block} (см. `findMerge`)
// — только у такого M ВСЕ сходящиеся пути проходят исключительно через
// branch_block, что и означает "точка слияния ИМЕННО ЭТОГО если/иначе", в
// отличие от блока, разделяемого с чем-то внешним (например, exit_block
// цикла, куда может попасть и прервать изнутри if/else, и собственная
// ветка-иначе заголовка — без доминации "больше одного предшественника"
// путает "слияние моих двух веток" с "точкой, разделяемой с внешним
// кодом").

pub fn buildRpoIndex(allocator: std.mem.Allocator, info: *const mir_cfg.CfgInfo) !std.AutoHashMap(mir.BlockId, usize) {
    var index: std.AutoHashMap(mir.BlockId, usize) = .init(allocator);
    for (info.reverse_postorder, 0..) |block, i| try index.put(block, i);
    return index;
}

// Истина, если у блока `b` есть предшественник `p` с rpo_index[p] >=
// rpo_index[b] (обратное ребро). Корректно именно потому, что переход к
// заголовку цикла — ЕДИНСТВЕННЫЙ вид обратного ребра, который может
// произвести это понижение (тот же факт, на который уже опирается форма
// CFG в `mir_lowering.zig`: терминатор `branch` всегда указывает вперёд).
pub fn isLoopHeader(info: *const mir_cfg.CfgInfo, rpo_index: *const std.AutoHashMap(mir.BlockId, usize), b: mir.BlockId) bool {
    const b_index = rpo_index.get(b) orelse return false;
    for (info.predecessors[@intFromEnum(b)].items) |p| {
        const p_index = rpo_index.get(p) orelse continue;
        if (p_index >= b_index) return true;
    }
    return false;
}

// Достижимость от `from` до `target` через `successors()` (`mir_cfg.zig`),
// без повторного посещения уже увиденных блоков.
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

// Для `branch(cond, t, e)` заголовка цикла: какой из t/e — ТЕЛО цикла
// (может достичь заголовка обратно), какой — блок ПОСЛЕ цикла. Не
// полагается на порядок аргументов — проверяет структурно.
pub fn identifyLoopBodyAndExit(allocator: std.mem.Allocator, function: *const mir.Function, header: mir.BlockId, then_block: mir.BlockId, else_block: mir.BlockId) !struct { body: mir.BlockId, exit: mir.BlockId } {
    if (try canReach(allocator, function, then_block, header)) return .{ .body = then_block, .exit = else_block };
    return .{ .body = else_block, .exit = then_block };
}

// Непосредственные доминаторы — стандартный итеративный алгоритм
// (Cooper/Harvey/Kennedy, "A Simple, Fast Dominance Algorithm") над
// reverse-postorder + предшественниками, оба уже вычислены в
// `mir_cfg.CfgInfo`.
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

// ЕДИНСТВЕННЫЙ блок M с idom[M] == branch_block, отличный от then_block/
// else_block (см. doc-комментарий этого файла). `null` — обе ветки
// завершают выполнение (return/паника/вечный цикл), слияния нет.
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
    const number_type: types.TypeId = types.TypeId.raw(1);
    const function_id = try mir_builder.newFunction(module, allocator, "тест", @enumFromInt(0), number_type, span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, function_id);
    const cond = try builder.newValue(types.TypeId.raw(0));
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
    const void_type: types.TypeId = types.TypeId.raw(0);
    const function_id = try mir_builder.newFunction(module, allocator, "цикл", @enumFromInt(0), void_type, span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, function_id);
    const header = try builder.newBlock();
    const body = try builder.newBlock();
    const exit = try builder.newBlock();
    builder.terminate(.{ .jump = .{ .target = header } });
    builder.setCurrentBlock(header);
    const cond = try builder.newValue(types.TypeId.raw(0));
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
