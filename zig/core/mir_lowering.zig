const std = @import("std");
const ast = @import("ast.zig");
const mir = @import("mir.zig");
const mir_builder = @import("mir_builder.zig");
const resolver = @import("resolver.zig");
const source = @import("source.zig");
const symbols = @import("symbols.zig");
const type_checker = @import("type_checker.zig");
const types = @import("types.zig");
const wasm_module = @import("wasm_module.zig");

// AST (post resolve+typecheck) → MIR. Ported from `core/mir_lowering.odin`
// (~2000 lines there) — works at the SAME pipeline point `compiler.zig`
// already does: reads the already-computed resolver/type-checker side
// tables (`resolution.expr_symbols`/`decl_symbols`/`function_parameters`,
// `checked.expression_types`/`symbol_types`/`types`), NEVER mutates or
// recomputes them, never modifies the AST.
//
// SCOPE — deliberately narrower than even Odin's own "Phase 1" (see that
// file's own doc comment): number/boolean/string literals, locals
// (declare/read via `пер`/parameters), unary/binary operators (including
// short-circuit `и`/`или`), `если`/`иначе`, `пока` (+ `прервать`/
// `продолжить`), plain function calls (by identifier OR by an arbitrary
// value — the generic `Call_Value_Instr` fallback), `возврат`. NOT covered
// (reported via `unsupported`, matching Odin's `lower_unsupported` —
// panics with a clear message rather than silently producing incorrect
// MIR, since this pipeline isn't reachable from normal compilation yet):
// `выбор`/ADTs, closures, interfaces, actors, async I/O, generics,
// operator-overload sugar (Сравниваемое/Арифметика), `для`/`для..in`,
// destructuring, builtins, methods, `внешний`. Each of these is a REAL
// Phase-2-equivalent addition, not an oversight — same split Odin made.

pub const FlowResult = enum { continues, terminates };

const ExprOutcome = struct {
    value: mir.ValueId,
    flow: FlowResult,
};

fn continuesWith(value: mir.ValueId) ExprOutcome {
    return .{ .value = value, .flow = .continues };
}

const terminated: ExprOutcome = .{ .value = mir.invalid_value, .flow = .terminates };

const LoopTargets = struct {
    continue_target: mir.BlockId,
    break_target: mir.BlockId,
};

const LoweringContext = struct {
    allocator: std.mem.Allocator,
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    checked: *const type_checker.CheckResult,
    builder: mir_builder.Builder,
    symbol_to_local: std.AutoHashMap(symbols.SymbolId, mir.LocalId),
    symbol_to_function: *const std.AutoHashMap(symbols.SymbolId, mir.FunctionId),
    loops: std.ArrayList(LoopTargets) = .empty,

    fn deinit(self: *LoweringContext) void {
        self.loops.deinit(self.allocator);
        self.symbol_to_local.deinit();
        self.* = undefined;
    }
};

fn unsupported(comptime what: []const u8) noreturn {
    @panic("mir lowering (Фаза 1): не поддержано — " ++ what);
}

fn expressionSpan(tree: *const ast.Ast, expression: ast.ExprId) source.Span {
    return switch (tree.expr(expression).*) {
        .error_node => |span| span,
        inline else => |value| value.span,
    };
}

fn functionReturnType(checked: *const type_checker.CheckResult, symbol: symbols.SymbolId) types.TypeId {
    const signature_id = checked.symbol_types.get(symbol) orelse return checked.types.builtins.void;
    const entry = checked.types.get(signature_id) orelse return checked.types.builtins.void;
    return switch (entry.*) {
        .function => |value| value.return_type,
        else => checked.types.builtins.void,
    };
}

pub fn lowerModule(
    allocator: std.mem.Allocator,
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    checked: *const type_checker.CheckResult,
) !mir.Module {
    var module = mir.Module.init(allocator);
    errdefer module.deinit(allocator);

    var symbol_to_function: std.AutoHashMap(symbols.SymbolId, mir.FunctionId) = .init(allocator);
    defer symbol_to_function.deinit();

    const program = tree.program orelse return module;

    // Two-pass — pass 1 reserves every function (forward references and
    // recursion both need the callee's FunctionId to exist before any
    // body is lowered); pass 2 lowers bodies.
    for (program.declarations) |decl_id| {
        const function = switch (tree.decl(decl_id).*) {
            .function => |value| value,
            else => continue,
        };
        if (function.type_parameters.len > 0) continue; // generics — Phase 2
        const symbol = resolution.decl_symbols.get(decl_id) orelse continue;
        const result_type = functionReturnType(checked, symbol);
        const function_id = try mir_builder.newFunction(&module, allocator, function.name, symbol, result_type, function.span);
        module.functions.items[@intFromEnum(function_id)].type_store = &checked.types;
        try symbol_to_function.put(symbol, function_id);
    }

    for (program.declarations) |decl_id| {
        const function = switch (tree.decl(decl_id).*) {
            .function => |value| value,
            else => continue,
        };
        if (function.type_parameters.len > 0) continue;
        const symbol = resolution.decl_symbols.get(decl_id) orelse continue;
        const function_id = symbol_to_function.get(symbol) orelse continue;
        try lowerFunctionBody(allocator, tree, resolution, checked, &module, function_id, decl_id, function.body, &symbol_to_function);
    }

    return module;
}

// Link the already resolved/type-checked module graph into one AOT MIR
// module. The bytecode compiler has its own linker; this deliberately keeps
// an AOT-specific, small equivalent so WASM does not inherit bytecode VM
// assumptions. The initial slice supports plain non-generic functions and
// direct local-file imports — exactly the Phase-1 MIR surface.
pub fn lowerGraph(
    allocator: std.mem.Allocator,
    graph: anytype,
    compiled: anytype,
) !mir.Module {
    var module = mir.Module.init(allocator);
    errdefer module.deinit(allocator);

    var function_maps: std.ArrayList(std.AutoHashMap(symbols.SymbolId, mir.FunctionId)) = .empty;
    defer {
        for (function_maps.items) |*map| map.deinit();
        function_maps.deinit(allocator);
    }
    try function_maps.ensureTotalCapacity(allocator, graph.modules.items.len);
    for (0..graph.modules.items.len) |_| try function_maps.append(allocator, .init(allocator));

    // Reserve every local function before lowering any body. This gives
    // forward references, recursion and cross-module direct calls stable
    // global FunctionIds in the resulting WASM module.
    for (graph.order.items) |module_index| {
        const resolution = if (compiled.modules[module_index].resolution) |*value| value else continue;
        const checked = if (compiled.modules[module_index].checked) |*value| value else continue;
        const tree = &graph.modules.items[module_index].tree;
        const program = tree.program orelse continue;
        for (program.declarations) |decl_id| {
            const function = switch (tree.decl(decl_id).*) {
                .function => |value| value,
                else => continue,
            };
            if (function.type_parameters.len != 0) continue;
            const symbol = resolution.decl_symbols.get(decl_id) orelse continue;
            const result_type = functionReturnType(checked, symbol);
            const function_id = try mir_builder.newFunction(&module, allocator, function.name, symbol, result_type, function.span);
            module.functions.items[@intFromEnum(function_id)].type_store = &checked.types;
            try function_maps.items[module_index].put(symbol, function_id);
        }
    }

    // Imported symbols are freshly minted in the importing Resolution. Map
    // each one back to the reserved FunctionId of its exporting declaration.
    for (graph.order.items) |module_index| {
        const resolution = if (compiled.modules[module_index].resolution) |*value| value else continue;
        var imports = resolution.imported_symbols.iterator();
        while (imports.next()) |entry| {
            const origin = entry.value_ptr.*;
            const target_resolution = if (compiled.modules[origin.module].resolution) |*value| value else continue;
            const target_symbol = target_resolution.decl_symbols.get(origin.declaration) orelse continue;
            const target_function = function_maps.items[origin.module].get(target_symbol) orelse continue;
            try function_maps.items[module_index].put(entry.key_ptr.*, target_function);
        }
    }

    for (graph.order.items) |module_index| {
        const resolution = if (compiled.modules[module_index].resolution) |*value| value else continue;
        const checked = if (compiled.modules[module_index].checked) |*value| value else continue;
        const tree = &graph.modules.items[module_index].tree;
        const program = tree.program orelse continue;
        for (program.declarations) |decl_id| {
            const function = switch (tree.decl(decl_id).*) {
                .function => |value| value,
                else => continue,
            };
            if (function.type_parameters.len != 0) continue;
            const symbol = resolution.decl_symbols.get(decl_id) orelse continue;
            const function_id = function_maps.items[module_index].get(symbol) orelse continue;
            try lowerFunctionBody(allocator, tree, resolution, checked, &module, function_id, decl_id, function.body, &function_maps.items[module_index]);
        }
    }

    return module;
}

fn lowerFunctionBody(
    allocator: std.mem.Allocator,
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    checked: *const type_checker.CheckResult,
    module: *mir.Module,
    function_id: mir.FunctionId,
    decl_id: ast.DeclId,
    body: []const ast.StmtId,
    symbol_to_function: *const std.AutoHashMap(symbols.SymbolId, mir.FunctionId),
) !void {
    var ctx = LoweringContext{
        .allocator = allocator,
        .tree = tree,
        .resolution = resolution,
        .checked = checked,
        .builder = try mir_builder.Builder.beginFunction(module, allocator, function_id),
        .symbol_to_local = .init(allocator),
        .symbol_to_function = symbol_to_function,
    };
    defer ctx.deinit();

    const parameter_symbols = resolution.function_parameters.get(decl_id) orelse &.{};
    var param_locals: std.ArrayList(mir.LocalId) = .empty;
    for (parameter_symbols) |symbol| {
        const type_id = checked.symbol_types.get(symbol) orelse checked.types.builtins.void;
        const local = try ctx.builder.newLocal(symbol, "", type_id);
        try ctx.symbol_to_local.put(symbol, local);
        try param_locals.append(allocator, local);
    }
    ctx.builder.currentFunction().parameters = try param_locals.toOwnedSlice(allocator);

    const result_type = ctx.builder.currentFunction().result_type;
    const want_value = !checked.types.eql(result_type, checked.types.builtins.void);
    const outcome = try lowerBlock(&ctx, body, want_value);
    if (outcome.flow == .continues) {
        ctx.builder.terminate(.{ .return_value = .{ .value = if (want_value) outcome.value else null } });
    }
}

// Block as a value (same principle as `compileBlockValue` today): the last
// expression-statement, in value context, yields its value as the block's
// result instead of being discarded; earlier statements are effect-only.
// An empty block, in value context, is a 0.0 placeholder — same as today.
fn lowerBlock(ctx: *LoweringContext, statements: []const ast.StmtId, want_value: bool) anyerror!ExprOutcome {
    if (statements.len == 0) {
        if (!want_value) return continuesWith(mir.invalid_value);
        return continuesWith(try emitConstNumber(ctx, 0));
    }
    for (statements, 0..) |statement, index| {
        const is_last = index == statements.len - 1;
        if (is_last and want_value) {
            const expression = switch (ctx.tree.stmt(statement).*) {
                .expr => |expr_stmt| expr_stmt.value,
                else => {
                    const flow = try lowerStmt(ctx, statement);
                    if (flow == .terminates) return terminated;
                    return continuesWith(try emitConstNumber(ctx, 0));
                },
            };
            return lowerExpr(ctx, expression);
        }
        const flow = try lowerStmt(ctx, statement);
        if (flow == .terminates) return terminated;
    }
    // Only reachable when `want_value == false` — the last statement, in a
    // value-requesting context, always returns from within the loop above
    // (either via the extracted-expression path or the early-return for a
    // non-expression last statement).
    return continuesWith(mir.invalid_value);
}

fn emitConstNumber(ctx: *LoweringContext, value: f64) !mir.ValueId {
    const dst = try ctx.builder.newValue(ctx.checked.types.builtins.number);
    try ctx.builder.emit(.{ .const_value = .{ .dst = dst, .value = .{ .number = value } } });
    return dst;
}

fn lowerStmt(ctx: *LoweringContext, statement: ast.StmtId) anyerror!FlowResult {
    switch (ctx.tree.stmt(statement).*) {
        .let => |let| {
            if (let.destructure_type != null) unsupported("деструктурирующее объявление");
            const outcome = try lowerExpr(ctx, let.value);
            if (outcome.flow == .terminates) return .terminates;
            const bindings = ctx.resolution.stmt_bindings.get(statement) orelse &.{};
            if (bindings.len != 1) unsupported("деструктурирующее объявление");
            const symbol = bindings[0];
            const local_type = ctx.checked.expression_types.get(let.value) orelse ctx.checked.types.builtins.void;
            const local = try ctx.builder.newLocal(symbol, let.name orelse "", local_type);
            try ctx.symbol_to_local.put(symbol, local);
            try ctx.builder.emit(.{ .store_local = .{ .local = local, .src = outcome.value } });
            return .continues;
        },
        .return_stmt => |return_statement| {
            const return_value = return_statement.value orelse {
                ctx.builder.terminate(.{ .return_value = .{ .value = null } });
                return .terminates;
            };
            const outcome = try lowerExpr(ctx, return_value);
            if (outcome.flow == .terminates) return .terminates;
            ctx.builder.terminate(.{ .return_value = .{ .value = outcome.value } });
            return .terminates;
        },
        .expr => |expr_statement| {
            // `если` as a bare statement: lowerIfExpr always lowers with
            // want_value=true when called from expression context (needed
            // for если-as-value), but here (Expr_Stmt — value is ALWAYS
            // discarded) that would create a synthetic merge slot and try
            // to Store_Local an invalid value in any branch with no real
            // value (e.g. `если ... тогда сумма = сумма + i конец` — an
            // assignment produces no value). Real bug Odin's own
            // differential testing caught this exact way — lower with
            // want_value=false explicitly here instead of going through
            // lowerExpr's hardcoded true.
            if (ctx.tree.expr(expr_statement.value).* == .if_expr) {
                const if_expr = ctx.tree.expr(expr_statement.value).if_expr;
                const outcome = try lowerIfExpr(ctx, expr_statement.value, if_expr, false);
                return outcome.flow;
            }
            const outcome = try lowerExpr(ctx, expr_statement.value);
            return outcome.flow;
        },
        .for_range => |range| return lowerForRange(ctx, statement, range),
        .continue_stmt => {
            if (ctx.loops.items.len == 0) unsupported("продолжить вне цикла");
            const target = ctx.loops.items[ctx.loops.items.len - 1].continue_target;
            ctx.builder.terminate(.{ .jump = .{ .target = target } });
            return .terminates;
        },
        .break_stmt => {
            if (ctx.loops.items.len == 0) unsupported("прервать вне цикла");
            const target = ctx.loops.items[ctx.loops.items.len - 1].break_target;
            ctx.builder.terminate(.{ .jump = .{ .target = target } });
            return .terminates;
        },
        else => unsupported("вид statement"),
    }
}

fn lowerForRange(ctx: *LoweringContext, statement: ast.StmtId, range: anytype) anyerror!FlowResult {
    const start = try lowerExpr(ctx, range.start);
    if (start.flow == .terminates) return .terminates;
    const end = try lowerExpr(ctx, range.end);
    if (end.flow == .terminates) return .terminates;
    const bindings = ctx.resolution.stmt_bindings.get(statement) orelse unsupported("для без символа переменной");
    if (bindings.len != 1) unsupported("для с несколькими переменными");
    const index_type = ctx.checked.expression_types.get(range.start) orelse ctx.checked.types.builtins.number;
    const index_local = try ctx.builder.newLocal(bindings[0], range.name, index_type);
    try ctx.symbol_to_local.put(bindings[0], index_local);
    const end_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$for_end", index_type);
    try ctx.builder.emit(.{ .store_local = .{ .local = end_local, .src = end.value } });
    try ctx.builder.emit(.{ .store_local = .{ .local = index_local, .src = start.value } });
    const header = try ctx.builder.newBlock();
    const body = try ctx.builder.newBlock();
    const step = try ctx.builder.newBlock();
    const exit = try ctx.builder.newBlock();
    ctx.builder.terminate(.{ .jump = .{ .target = header } });
    ctx.builder.setCurrentBlock(header);
    const index_value = try ctx.builder.newValue(index_type);
    const end_value = try ctx.builder.newValue(index_type);
    try ctx.builder.emit(.{ .load_local = .{ .dst = index_value, .local = index_local } });
    try ctx.builder.emit(.{ .load_local = .{ .dst = end_value, .local = end_local } });
    const cond = try emitCompare(ctx, .less_equal, index_value, end_value);
    ctx.builder.terminate(.{ .branch = .{ .cond = cond, .then_block = body, .else_block = exit } });
    ctx.builder.setCurrentBlock(body);
    try ctx.loops.append(ctx.allocator, .{ .continue_target = step, .break_target = exit });
    const body_outcome = try lowerBlock(ctx, range.body, false);
    _ = ctx.loops.pop();
    if (body_outcome.flow == .continues) ctx.builder.terminate(.{ .jump = .{ .target = step } });
    ctx.builder.setCurrentBlock(step);
    const current = try ctx.builder.newValue(index_type);
    try ctx.builder.emit(.{ .load_local = .{ .dst = current, .local = index_local } });
    const one = try emitConstNumber(ctx, 1);
    const next = try ctx.builder.newValue(index_type);
    try ctx.builder.emit(.{ .binary = .{ .dst = next, .op = .add, .lhs = current, .rhs = one } });
    try ctx.builder.emit(.{ .store_local = .{ .local = index_local, .src = next } });
    ctx.builder.terminate(.{ .jump = .{ .target = header } });
    ctx.builder.setCurrentBlock(exit);
    return .continues;
}

fn lowerExpr(ctx: *LoweringContext, expression: ast.ExprId) anyerror!ExprOutcome {
    return switch (ctx.tree.expr(expression).*) {
        .number => |number| continuesWith(try emitConstNumber(ctx, number.value)),
        .boolean => |boolean| blk: {
            const dst = try ctx.builder.newValue(ctx.checked.types.builtins.boolean);
            try ctx.builder.emit(.{ .const_value = .{ .dst = dst, .value = .{ .boolean = boolean.value } } });
            break :blk continuesWith(dst);
        },
        .string => |string| blk: {
            const dst = try ctx.builder.newValue(ctx.checked.types.builtins.string);
            try ctx.builder.emit(.{ .const_value = .{ .dst = dst, .value = .{ .string = string.value } } });
            break :blk continuesWith(dst);
        },
        .array => |array| lowerArrayLiteral(ctx, expression, array),
        .spawn => |spawn| lowerSpawn(ctx, expression, spawn),
        .index => |index| lowerIndex(ctx, expression, index),
        .ident => blk: {
            const symbol = ctx.resolution.expr_symbols.get(expression) orelse unsupported("неразрешённый идентификатор");
            break :blk continuesWith(try lowerSymbolValueRef(ctx, symbol, expressionSpan(ctx.tree, expression)));
        },
        .unary => |unary| lowerUnary(ctx, expression, unary),
        .binary => |binary| lowerBinary(ctx, expression, binary),
        .call => |call| lowerCall(ctx, expression, call),
        .property => |property| lowerProperty(ctx, expression, property),
        .if_expr => |conditional| lowerIfExpr(ctx, expression, conditional, true),
        .match_expr => |match| lowerMatchExpr(ctx, expression, match),
        .while_expr => |loop| blk: {
            const flow = try lowerWhile(ctx, loop);
            if (flow == .terminates) break :blk terminated;
            break :blk continuesWith(try emitConstNumber(ctx, 0));
        },
        else => unsupported("вид выражения"),
    };
}

// Keep actor creation explicit in MIR. CPS lowering consumes this before the
// WASM emitter; representing it as an ordinary call would lose the child
// frame and make a later `получить()` impossible to resume correctly.
fn lowerSpawn(ctx: *LoweringContext, expression: ast.ExprId, spawn: anytype) anyerror!ExprOutcome {
    const call = switch (ctx.tree.expr(spawn.call).*) {
        .call => |value| value,
        else => unsupported("запусти не-вызов"),
    };
    const symbol = ctx.resolution.expr_symbols.get(call.callee) orelse unsupported("запусти неразрешённую функцию");
    const function_id = ctx.symbol_to_function.get(symbol) orelse unsupported("запусти не-статическую функцию");
    const callee = try emitFunctionRef(ctx, function_id);
    const args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
    const result_type = ctx.checked.expression_types.get(expression) orelse unsupported("запусти без типа");
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .spawn = .{ .dst = dst, .callee = callee, .args = args } });
    return continuesWith(dst);
}

fn lowerMatchExpr(ctx: *LoweringContext, expression: ast.ExprId, match: anytype) anyerror!ExprOutcome {
    const subject = try lowerExpr(ctx, match.subject);
    if (subject.flow == .terminates) return terminated;
    const subject_type = ctx.checked.expression_types.get(match.subject) orelse unsupported("выбор без типа subject");
    const subject_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$match", subject_type);
    try ctx.builder.emit(.{ .store_local = .{ .local = subject_local, .src = subject.value } });
    const result_type = ctx.checked.expression_types.get(expression) orelse ctx.checked.types.builtins.void;
    const has_result = !ctx.checked.types.eql(result_type, ctx.checked.types.builtins.void);
    const result_local: ?mir.LocalId = if (has_result) try ctx.builder.newLocal(symbols.invalid_symbol, "$match_result", result_type) else null;
    const merge = try ctx.builder.newBlock();

    for (match.arms, 0..) |arm, arm_index| {
        const next = if (arm_index + 1 < match.arms.len) try ctx.builder.newBlock() else mir.invalid_block;
        const variant = ctx.checked.pattern_variants.get(arm.pattern);
        if (variant) |variant_symbol| {
            const definition = ctx.checked.enum_definitions.get((ctx.resolution.symbols.get(variant_symbol) orelse unreachable).owner_type) orelse unsupported("вариант без enum definition");
            var tag: u32 = 0;
            for (definition.variants, 0..) |candidate, index| if (candidate.symbol == variant_symbol) {
                tag = @intCast(index);
                break;
            };
            const condition = try ctx.builder.newValue(ctx.checked.types.builtins.boolean);
            const loaded_subject = try ctx.builder.newValue(subject_type);
            try ctx.builder.emit(.{ .load_local = .{ .dst = loaded_subject, .local = subject_local } });
            try ctx.builder.emit(.{ .match_tag = .{ .dst = condition, .subject = loaded_subject, .tag = tag } });
            const body = try ctx.builder.newBlock();
            if (next == mir.invalid_block) {
                const impossible = try ctx.builder.newBlock();
                ctx.builder.terminate(.{ .branch = .{ .cond = condition, .then_block = body, .else_block = impossible } });
                ctx.builder.setCurrentBlock(impossible);
                ctx.builder.terminate(.{ .unreachable_term = .{ .reason = "неисчерпывающий выбор" } });
            } else ctx.builder.terminate(.{ .branch = .{ .cond = condition, .then_block = body, .else_block = next } });
            ctx.builder.setCurrentBlock(body);
            try bindVariantPattern(ctx, arm.pattern, subject_local, subject_type);
        } else {
            try bindCatchAllPattern(ctx, arm.pattern, subject_local, subject_type);
        }
        const outcome = try lowerBlock(ctx, arm.body, has_result);
        if (outcome.flow == .continues) {
            if (result_local) |local| try ctx.builder.emit(.{ .store_local = .{ .local = local, .src = outcome.value } });
            ctx.builder.terminate(.{ .jump = .{ .target = merge } });
        }
        if (next != mir.invalid_block) ctx.builder.setCurrentBlock(next);
    }
    ctx.builder.setCurrentBlock(merge);
    if (!has_result) return continuesWith(mir.invalid_value);
    const result = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .load_local = .{ .dst = result, .local = result_local.? } });
    return continuesWith(result);
}

fn bindCatchAllPattern(ctx: *LoweringContext, pattern: ast.PatternId, subject_local: mir.LocalId, subject_type: types.TypeId) !void {
    const binding = ctx.resolution.pattern_symbols.get(pattern) orelse return;
    const local = try ctx.builder.newLocal(binding, "$pattern", subject_type);
    try ctx.symbol_to_local.put(binding, local);
    const value = try ctx.builder.newValue(subject_type);
    try ctx.builder.emit(.{ .load_local = .{ .dst = value, .local = subject_local } });
    try ctx.builder.emit(.{ .store_local = .{ .local = local, .src = value } });
}

fn bindVariantPattern(ctx: *LoweringContext, pattern: ast.PatternId, subject_local: mir.LocalId, subject_type: types.TypeId) !void {
    const constructor = switch (ctx.tree.pattern(pattern).*) {
        .constructor => |value| value,
        else => return,
    };
    for (constructor.arguments, 0..) |argument, index| {
        const binding = ctx.resolution.pattern_symbols.get(argument) orelse continue;
        const field_type = ctx.checked.pattern_types.get(argument) orelse blk: {
            // `получить()` deliberately has poison as its static subject
            // type. The checker still resolved the constructor variant, so
            // recover its positional field type from that enum definition.
            const variant_symbol = ctx.checked.pattern_variants.get(pattern) orelse unsupported("payload pattern без типа");
            const entry = ctx.resolution.symbols.get(variant_symbol) orelse unsupported("payload variant без symbol");
            const definition = ctx.checked.enum_definitions.get(entry.owner_type) orelse unsupported("payload variant без enum definition");
            for (definition.variants) |variant| {
                if (variant.symbol != variant_symbol) continue;
                if (index >= variant.fields.len) unsupported("payload pattern вне variant fields");
                break :blk variant.fields[index];
            }
            unsupported("payload variant не найден");
        };
        const local = try ctx.builder.newLocal(binding, "$payload", field_type);
        try ctx.symbol_to_local.put(binding, local);
        const loaded_subject = try ctx.builder.newValue(subject_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = loaded_subject, .local = subject_local } });
        const field = try ctx.builder.newValue(field_type);
        try ctx.builder.emit(.{ .get_variant_field = .{ .dst = field, .subject = loaded_subject, .field_index = @intCast(index) } });
        try ctx.builder.emit(.{ .store_local = .{ .local = local, .src = field } });
    }
}

fn valuesInArena(ctx: *LoweringContext, values: []const mir.ValueId) ![]const mir.ValueId {
    const out = try ctx.builder.module.arena.allocator().alloc(mir.ValueId, values.len);
    @memcpy(out, values);
    return out;
}

fn lowerArrayLiteral(ctx: *LoweringContext, expression: ast.ExprId, array: anytype) anyerror!ExprOutcome {
    const array_type = ctx.checked.expression_types.get(expression) orelse unsupported("массив без типа");
    const entry = ctx.checked.types.get(array_type) orelse unsupported("массив с неизвестным типом");
    const element_type = switch (entry.*) {
        .array => |value| value,
        else => unsupported("литерал не-массива"),
    };
    const array_value = try ctx.builder.newValue(array_type);
    try ctx.builder.emit(.{ .new_array = .{ .dst = array_value, .elements = &.{} } });
    const local = try ctx.builder.newLocal(symbols.invalid_symbol, "$array", array_type);
    try ctx.builder.emit(.{ .store_local = .{ .local = local, .src = array_value } });
    const append_name = if (wasm_module.wasmValTypeForStore(&ctx.checked.types, element_type) == wasm_module.wasm_i32) "@runtime::array_append_i32" else "@runtime::array_append_f64";
    for (array.elements) |element| {
        const receiver = try ctx.builder.newValue(array_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = receiver, .local = local } });
        const value = try lowerExpr(ctx, element);
        if (value.flow == .terminates) return terminated;
        try ctx.builder.emit(.{ .call_builtin = .{ .dst = null, .name = append_name, .args = try valuesInArena(ctx, &.{ receiver, value.value }) } });
    }
    const result = try ctx.builder.newValue(array_type);
    try ctx.builder.emit(.{ .load_local = .{ .dst = result, .local = local } });
    return continuesWith(result);
}

fn lowerIndex(ctx: *LoweringContext, expression: ast.ExprId, index: anytype) anyerror!ExprOutcome {
    const object = try lowerExpr(ctx, index.object);
    if (object.flow == .terminates) return terminated;
    const subscript = try lowerExpr(ctx, index.index);
    if (subscript.flow == .terminates) return terminated;
    const result_type = ctx.checked.expression_types.get(expression) orelse unsupported("индексирование без типа результата");
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .get_index = .{ .dst = dst, .object = object.value, .index = subscript.value } });
    return continuesWith(dst);
}

fn lowerProperty(ctx: *LoweringContext, expression: ast.ExprId, property: anytype) anyerror!ExprOutcome {
    // Module members and enum variants are resolved symbols and are handled
    // by their callers. A remaining property expression is a struct field.
    if (ctx.resolution.expr_symbols.contains(expression)) unsupported("свойство-модуль или вариант перечисления вне вызова");
    const object = try lowerExpr(ctx, property.object);
    if (object.flow == .terminates) return terminated;
    const object_type = ctx.checked.expression_types.get(property.object) orelse unsupported("свойство без типа объекта");
    const type_entry = ctx.checked.types.get(object_type) orelse unsupported("свойство с неизвестным типом объекта");
    const nominal = switch (type_entry.*) {
        .nominal => |value| value,
        else => unsupported("свойство не-структуры"),
    };
    const fields = ctx.checked.nominal_fields.get(nominal.symbol) orelse unsupported("поле generic-структуры");
    for (fields, 0..) |field, index| {
        if (!std.mem.eql(u8, field.name, property.property)) continue;
        const result_type = ctx.checked.expression_types.get(expression) orelse field.typ;
        const dst = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .get_property = .{ .dst = dst, .object = object.value, .field_index = @intCast(index) } });
        return continuesWith(dst);
    }
    unsupported("неизвестное поле структуры");
}

fn lowerSymbolValueRef(ctx: *LoweringContext, symbol: symbols.SymbolId, span: source.Span) !mir.ValueId {
    if (ctx.symbol_to_local.get(symbol)) |local| {
        const dst = try ctx.builder.newValue(ctx.builder.currentFunction().locals.items[@intFromEnum(local)].type_id);
        try ctx.builder.emit(.{ .load_local = .{ .dst = dst, .local = local } });
        return dst;
    }
    if (ctx.symbol_to_function.get(symbol)) |function_id| {
        return emitFunctionRef(ctx, function_id);
    }
    _ = span;
    unsupported("символ не является локалью или функцией");
}

fn emitFunctionRef(ctx: *LoweringContext, function_id: mir.FunctionId) !mir.ValueId {
    const dst = try ctx.builder.newValue(ctx.checked.types.builtins.void);
    try ctx.builder.emit(.{ .function_ref = .{ .dst = dst, .function = function_id } });
    return dst;
}

fn lowerUnary(ctx: *LoweringContext, expression: ast.ExprId, unary: anytype) anyerror!ExprOutcome {
    const src = try lowerExpr(ctx, unary.operand);
    if (src.flow == .terminates) return terminated;
    const op: mir.UnOp = switch (unary.operator) {
        .minus => .negate_number,
        .negate => .negate_bool,
        .tilde => .bit_not,
        else => unsupported("унарный оператор"),
    };
    const result_type = ctx.checked.expression_types.get(expression) orelse ctx.checked.types.builtins.void;
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .unary = .{ .dst = dst, .op = op, .src = src.value } });
    return continuesWith(dst);
}

fn lowerBinary(ctx: *LoweringContext, expression: ast.ExprId, binary: anytype) anyerror!ExprOutcome {
    if (binary.operator == .assign) return lowerAssign(ctx, binary);
    if (binary.operator == .and_expr or binary.operator == .or_expr) return lowerShortCircuit(ctx, binary);

    const lhs = try lowerExpr(ctx, binary.left);
    if (lhs.flow == .terminates) return terminated;
    const rhs = try lowerExpr(ctx, binary.right);
    if (rhs.flow == .terminates) return terminated;

    const result_type = ctx.checked.expression_types.get(expression) orelse ctx.checked.types.builtins.void;
    const bin_op: mir.BinOp = switch (binary.operator) {
        .plus => .add,
        .minus => .subtract,
        .star => .multiply,
        .slash => if (ctx.checked.types.eql(ctx.checked.expression_types.get(binary.left) orelse ctx.checked.types.builtins.void, ctx.checked.types.builtins.integer)) mir.BinOp.int_divide else mir.BinOp.divide,
        .percent => .modulo,
        .ampersand => .bit_and,
        .pipe => .bit_or,
        .caret => .bit_xor,
        .less_less => .shift_left,
        .greater_greater => .shift_right,
        .less, .less_equal, .greater, .greater_equal, .equal, .not_equal => return continuesWith(try emitCompare(ctx, binary.operator, lhs.value, rhs.value)),
        else => unsupported("бинарный оператор"),
    };
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .binary = .{ .dst = dst, .op = bin_op, .lhs = lhs.value, .rhs = rhs.value } });
    return continuesWith(dst);
}

// Assignment produces NO value
// (matches Odin's `INVALID_VALUE`/`.Continues` and the bytecode compiler's
// own `y = (x = 1)` restriction) — a well-typed program can never observe
// this, since the type checker requires an if-expression's branches to share
// a common value type before this lowering ever runs.
fn lowerAssign(ctx: *LoweringContext, binary: anytype) anyerror!ExprOutcome {
    switch (ctx.tree.expr(binary.left).*) {
        .ident => {
            const symbol = ctx.resolution.expr_symbols.get(binary.left) orelse unsupported("неразрешённый идентификатор в присваивании");
            const target = ctx.symbol_to_local.get(symbol) orelse unsupported("присваивание не-локали (Фаза 3+)");
            const rhs = try lowerExpr(ctx, binary.right);
            if (rhs.flow == .terminates) return terminated;
            try ctx.builder.emit(.{ .store_local = .{ .local = target, .src = rhs.value } });
        },
        .property => |property| {
            const object = try lowerExpr(ctx, property.object);
            if (object.flow == .terminates) return terminated;
            const object_type = ctx.checked.expression_types.get(property.object) orelse unsupported("присваивание свойства без типа");
            const entry = ctx.checked.types.get(object_type) orelse unsupported("присваивание свойства с неизвестным типом");
            const nominal = switch (entry.*) {
                .nominal => |value| value,
                else => unsupported("присваивание свойства не-структуры"),
            };
            const fields = ctx.checked.nominal_fields.get(nominal.symbol) orelse unsupported("присваивание поля generic-структуры");
            var field_index: ?u32 = null;
            for (fields, 0..) |field, index| {
                if (std.mem.eql(u8, field.name, property.property)) {
                    field_index = @intCast(index);
                    break;
                }
            }
            const index = field_index orelse unsupported("присваивание неизвестному полю структуры");
            const rhs = try lowerExpr(ctx, binary.right);
            if (rhs.flow == .terminates) return terminated;
            try ctx.builder.emit(.{ .set_property = .{ .object = object.value, .field_index = index, .value = rhs.value } });
        },
        .index => |index| {
            const object = try lowerExpr(ctx, index.object);
            if (object.flow == .terminates) return terminated;
            const subscript = try lowerExpr(ctx, index.index);
            if (subscript.flow == .terminates) return terminated;
            const rhs = try lowerExpr(ctx, binary.right);
            if (rhs.flow == .terminates) return terminated;
            try ctx.builder.emit(.{ .set_index = .{ .object = object.value, .index = subscript.value, .value = rhs.value } });
        },
        else => unsupported("цель присваивания (Фаза 3+)"),
    }
    return continuesWith(mir.invalid_value);
}

fn emitCompare(ctx: *LoweringContext, operator: anytype, lhs: mir.ValueId, rhs: mir.ValueId) !mir.ValueId {
    const cmp_op: mir.CmpOp = switch (operator) {
        .less => .less,
        .less_equal => .less_equal,
        .greater => .greater,
        .greater_equal => .greater_equal,
        .equal => .equal,
        .not_equal => .not_equal,
        else => unreachable,
    };
    const dst = try ctx.builder.newValue(ctx.checked.types.builtins.boolean);
    try ctx.builder.emit(.{ .compare = .{ .dst = dst, .op = cmp_op, .lhs = lhs, .rhs = rhs } });
    return dst;
}

// `и`/`или` — same non-SSA "merge through a temp local" trick `lowerIfExpr`
// uses for a branch's result value, via `lowerCondition` building real CFG
// edges instead of computing a bool eagerly.
fn lowerShortCircuit(ctx: *LoweringContext, binary: anytype) anyerror!ExprOutcome {
    const result_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$logic", ctx.checked.types.builtins.boolean);
    const rhs_block = try ctx.builder.newBlock();
    const short_block = try ctx.builder.newBlock();
    const merge_block = try ctx.builder.newBlock();
    const short_value = binary.operator == .or_expr;

    if (binary.operator == .and_expr) {
        try lowerCondition(ctx, binary.left, rhs_block, short_block);
    } else {
        try lowerCondition(ctx, binary.left, short_block, rhs_block);
    }

    ctx.builder.setCurrentBlock(short_block);
    const short_dst = try ctx.builder.newValue(ctx.checked.types.builtins.boolean);
    try ctx.builder.emit(.{ .const_value = .{ .dst = short_dst, .value = .{ .boolean = short_value } } });
    try ctx.builder.emit(.{ .store_local = .{ .local = result_local, .src = short_dst } });
    ctx.builder.terminate(.{ .jump = .{ .target = merge_block } });

    ctx.builder.setCurrentBlock(rhs_block);
    const rhs_outcome = try lowerExpr(ctx, binary.right);
    if (rhs_outcome.flow == .continues) {
        try ctx.builder.emit(.{ .store_local = .{ .local = result_local, .src = rhs_outcome.value } });
        ctx.builder.terminate(.{ .jump = .{ .target = merge_block } });
    }

    ctx.builder.setCurrentBlock(merge_block);
    const result = try ctx.builder.newValue(ctx.checked.types.builtins.boolean);
    try ctx.builder.emit(.{ .load_local = .{ .dst = result, .local = result_local } });
    return continuesWith(result);
}

// Branch-context lowering — builds CFG edges directly instead of computing
// a bool value, needed for short-circuit `и`/`или` (above) and for
// `если`/`пока` conditions. `a и b` lowers as: lowerCondition(a, rhs_block,
// false_target), inside rhs_block — lowerCondition(b, true_target,
// false_target); `a или b` is symmetric.
fn lowerCondition(ctx: *LoweringContext, expression: ast.ExprId, true_target: mir.BlockId, false_target: mir.BlockId) anyerror!void {
    if (ctx.tree.expr(expression).* == .binary) {
        const binary = ctx.tree.expr(expression).binary;
        if (binary.operator == .and_expr) {
            const rhs_block = try ctx.builder.newBlock();
            try lowerCondition(ctx, binary.left, rhs_block, false_target);
            ctx.builder.setCurrentBlock(rhs_block);
            try lowerCondition(ctx, binary.right, true_target, false_target);
            return;
        }
        if (binary.operator == .or_expr) {
            const rhs_block = try ctx.builder.newBlock();
            try lowerCondition(ctx, binary.left, true_target, rhs_block);
            ctx.builder.setCurrentBlock(rhs_block);
            try lowerCondition(ctx, binary.right, true_target, false_target);
            return;
        }
    }
    const outcome = try lowerExpr(ctx, expression);
    if (outcome.flow == .terminates) return;
    ctx.builder.terminate(.{ .branch = .{ .cond = outcome.value, .then_block = true_target, .else_block = false_target } });
}

// Non-SSA "temp slot" merge (Store_Local in each LIVE — non-terminating —
// branch, Load_Local in the merge block), not a phi node — MIR Phase 1 is
// deliberately not SSA.
fn lowerIfExpr(ctx: *LoweringContext, expression: ast.ExprId, conditional: anytype, want_value: bool) anyerror!ExprOutcome {
    const cond = try lowerExpr(ctx, conditional.condition);
    if (cond.flow == .terminates) return terminated;

    const then_block = try ctx.builder.newBlock();
    const else_block = try ctx.builder.newBlock();
    const merge_block = try ctx.builder.newBlock();
    ctx.builder.terminate(.{ .branch = .{ .cond = cond.value, .then_block = then_block, .else_block = else_block } });

    const result_type = ctx.checked.expression_types.get(expression) orelse ctx.checked.types.builtins.void;
    var result_local: mir.LocalId = undefined;
    if (want_value) result_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$if", result_type);

    ctx.builder.setCurrentBlock(then_block);
    const then_outcome = try lowerBlock(ctx, conditional.then_branch, want_value);
    const then_continues = then_outcome.flow == .continues;
    if (then_continues) {
        if (want_value) try ctx.builder.emit(.{ .store_local = .{ .local = result_local, .src = then_outcome.value } });
        ctx.builder.terminate(.{ .jump = .{ .target = merge_block } });
    }

    ctx.builder.setCurrentBlock(else_block);
    const else_outcome = try lowerBlock(ctx, conditional.else_branch, want_value);
    const else_continues = else_outcome.flow == .continues;
    if (else_continues) {
        if (want_value) try ctx.builder.emit(.{ .store_local = .{ .local = result_local, .src = else_outcome.value } });
        ctx.builder.terminate(.{ .jump = .{ .target = merge_block } });
    }

    if (!then_continues and !else_continues) {
        ctx.builder.setCurrentBlock(merge_block);
        ctx.builder.terminate(.{ .unreachable_term = .{ .reason = "обе ветки если завершают выполнение (возврат/прервать/продолжить)" } });
        return terminated;
    }

    ctx.builder.setCurrentBlock(merge_block);
    if (want_value) {
        const result = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = result, .local = result_local } });
        return continuesWith(result);
    }
    return continuesWith(mir.invalid_value);
}

// Only ever lowered as a statement (Phase 1: no scenario needs a пока-as-
// value — the one caller in `lowerExpr` above just supplies a constant 0
// placeholder, same treatment as an empty block in value context).
fn lowerWhile(ctx: *LoweringContext, loop: anytype) anyerror!FlowResult {
    const header_block = try ctx.builder.newBlock();
    const body_block = try ctx.builder.newBlock();
    const exit_block = try ctx.builder.newBlock();

    ctx.builder.terminate(.{ .jump = .{ .target = header_block } });
    ctx.builder.setCurrentBlock(header_block);
    const cond = try lowerExpr(ctx, loop.condition);
    if (cond.flow == .terminates) return .terminates;
    ctx.builder.terminate(.{ .branch = .{ .cond = cond.value, .then_block = body_block, .else_block = exit_block } });

    ctx.builder.setCurrentBlock(body_block);
    try ctx.loops.append(ctx.allocator, .{ .continue_target = header_block, .break_target = exit_block });
    const body_outcome = try lowerBlock(ctx, loop.body, false);
    _ = ctx.loops.pop();
    if (body_outcome.flow == .continues) {
        ctx.builder.terminate(.{ .jump = .{ .target = header_block } });
    }

    ctx.builder.setCurrentBlock(exit_block);
    return .continues;
}

// Scope note: only two shapes are lowered — a statically-known top-level
// function called by bare identifier (the fast path — Odin's own
// equivalent), and the fully generic fallback (callee lowered as an
// ORDINARY expression, called through `Call_Value_Instr` — covers a
// closure/higher-order-function value, resolved by the backend, not
// lowering). Builtins, methods, constructors, `внешний`, `получить`/
// `получить_сигнал`, generics — all explicitly `unsupported` here (Phase
// 2 in the Odin original too).
fn lowerCall(ctx: *LoweringContext, expression: ast.ExprId, call: anytype) anyerror!ExprOutcome {
    const result_type = ctx.checked.expression_types.get(expression) orelse ctx.checked.types.builtins.void;

    if (ctx.tree.expr(call.callee).* == .ident) {
        const callee_symbol = ctx.resolution.expr_symbols.get(call.callee) orelse null;
        if (callee_symbol) |symbol| {
            if (ctx.symbol_to_function.get(symbol)) |function_id| {
                const function_ref = try emitFunctionRef(ctx, function_id);
                const args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
                return emitCallValue(ctx, function_ref, args, result_type);
            }
            if (try lowerEnumConstructor(ctx, symbol, call, result_type)) |outcome| return outcome;
            if (try lowerStructConstructor(ctx, expression, symbol, call, result_type)) |outcome| return outcome;
            if (try lowerNumericCastCall(ctx, symbol, call)) |outcome| return outcome;
            if (try lowerLengthBuiltinCall(ctx, symbol, call, result_type)) |outcome| return outcome;
            if (try lowerProcessBuiltinCall(ctx, symbol, call, result_type)) |outcome| return outcome;
        }
    }

    if (ctx.tree.expr(call.callee).* == .property) {
        // A function imported from a local file is represented in the AST
        // as `модуль.функция`, not as a bare identifier. Resolution has
        // already associated that property expression with the importer-side
        // symbol; lowerGraph rebinds that symbol to the exporter's global
        // MIR FunctionId.
        if (ctx.resolution.expr_symbols.get(call.callee)) |symbol| {
            if (ctx.symbol_to_function.get(symbol)) |function_id| {
                const function_ref = try emitFunctionRef(ctx, function_id);
                const args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
                return emitCallValue(ctx, function_ref, args, result_type);
            }
            if (try lowerEnumConstructor(ctx, symbol, call, result_type)) |outcome| return outcome;
        }
        if (try lowerTimeBuiltinCall(ctx, call, result_type)) |outcome| return outcome;
        if (try lowerNetworkBuiltinCall(ctx, call, result_type)) |outcome| return outcome;
        if (try lowerStringBuiltinCall(ctx, call, result_type)) |outcome| return outcome;
        if (try lowerDomBuiltinCall(ctx, call, result_type)) |outcome| return outcome;
        if (try lowerArrayMethodCall(ctx, call, result_type)) |outcome| return outcome;
        if (try lowerOptionMethodCall(ctx, call, result_type)) |outcome| return outcome;
    }

    const callee_outcome = try lowerExpr(ctx, call.callee);
    if (callee_outcome.flow == .terminates) return terminated;
    const args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
    return emitCallValue(ctx, callee_outcome.value, args, result_type);
}

fn lowerEnumConstructor(ctx: *LoweringContext, symbol: symbols.SymbolId, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const entry = ctx.resolution.symbols.get(symbol) orelse return null;
    if (entry.kind != .enum_variant) return null;
    const definition = ctx.checked.enum_definitions.get(entry.owner_type) orelse return null;
    var tag: ?u32 = null;
    for (definition.variants, 0..) |variant, index| {
        if (variant.symbol == symbol) {
            tag = @intCast(index);
            break;
        }
    }
    const variant_tag = tag orelse return null;
    if (call.arguments.len > 3) unsupported("вариант с более чем 3 полями");
    const fields = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .build_variant = .{ .dst = dst, .type_name = "", .variant_name = entry.name, .tag = variant_tag, .fields = fields } });
    return continuesWith(dst);
}

fn lowerArrayMethodCall(ctx: *LoweringContext, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const property = ctx.tree.expr(call.callee).property;
    const object_type = ctx.checked.expression_types.get(property.object) orelse return null;
    const entry = ctx.checked.types.get(object_type) orelse return null;
    const element_type = switch (entry.*) {
        .array => |value| value,
        else => return null,
    };
    const is_i32 = wasm_module.wasmValTypeForStore(&ctx.checked.types, element_type) == wasm_module.wasm_i32;
    const name = if (std.mem.eql(u8, property.property, "длина") and call.arguments.len == 0)
        "@runtime::array_length"
    else if (std.mem.eql(u8, property.property, "добавить") and call.arguments.len == 1)
        if (is_i32) "@runtime::array_append_i32" else "@runtime::array_append_f64"
    else if (std.mem.eql(u8, property.property, "получить") and call.arguments.len == 2)
        if (is_i32) "@runtime::array_get_or_i32" else "@runtime::array_get_or_f64"
    else
        return null;

    const receiver = try lowerExpr(ctx, property.object);
    if (receiver.flow == .terminates) return terminated;
    var values: std.ArrayList(mir.ValueId) = .empty;
    defer values.deinit(ctx.allocator);
    try values.append(ctx.allocator, receiver.value);
    for (call.arguments) |argument| {
        const value = try lowerExpr(ctx, argument);
        if (value.flow == .terminates) return terminated;
        try values.append(ctx.allocator, value.value);
    }
    const is_void = ctx.checked.types.eql(result_type, ctx.checked.types.builtins.void);
    const dst = if (is_void) null else try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .call_builtin = .{ .dst = dst, .name = name, .args = try valuesInArena(ctx, values.items) } });
    return continuesWith(dst orelse mir.invalid_value);
}

// `Опция` is a two-tag ADT from the prelude (`Нет = 0`, `Есть = 1`). These
// two accessors are sufficient for the conventional guarded pattern in the
// todo AOT demo and reuse the same variant ABI as explicit `выбор`.
fn lowerOptionMethodCall(ctx: *LoweringContext, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const property = ctx.tree.expr(call.callee).property;
    const object_type = ctx.checked.expression_types.get(property.object) orelse return null;
    const type_entry = ctx.checked.types.get(object_type) orelse return null;
    const nominal = switch (type_entry.*) {
        .nominal => |value| value,
        else => return null,
    };
    const owner = ctx.resolution.symbols.get(nominal.symbol) orelse return null;
    if (!std.mem.eql(u8, owner.name, "Опция")) return null;

    const receiver = try lowerExpr(ctx, property.object);
    if (receiver.flow == .terminates) return terminated;
    if (std.mem.eql(u8, property.property, "есть") and call.arguments.len == 0) {
        const dst = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .match_tag = .{ .dst = dst, .subject = receiver.value, .tag = 1 } });
        return continuesWith(dst);
    }
    if (std.mem.eql(u8, property.property, "получить") and call.arguments.len == 1) {
        // Both receiver and fallback are evaluated before selecting the
        // result, exactly as for an ordinary Panos method call.
        const option_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$option", object_type);
        try ctx.builder.emit(.{ .store_local = .{ .local = option_local, .src = receiver.value } });
        const fallback = try lowerExpr(ctx, call.arguments[0]);
        if (fallback.flow == .terminates) return terminated;
        const fallback_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$option_fallback", result_type);
        try ctx.builder.emit(.{ .store_local = .{ .local = fallback_local, .src = fallback.value } });
        const result_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$option_result", result_type);
        const condition = try ctx.builder.newValue(ctx.checked.types.builtins.boolean);
        const loaded_option = try ctx.builder.newValue(object_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = loaded_option, .local = option_local } });
        try ctx.builder.emit(.{ .match_tag = .{ .dst = condition, .subject = loaded_option, .tag = 1 } });
        const has_value = try ctx.builder.newBlock();
        const no_value = try ctx.builder.newBlock();
        const merge = try ctx.builder.newBlock();
        ctx.builder.terminate(.{ .branch = .{ .cond = condition, .then_block = has_value, .else_block = no_value } });

        ctx.builder.setCurrentBlock(has_value);
        const value_option = try ctx.builder.newValue(object_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = value_option, .local = option_local } });
        const value = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .get_variant_field = .{ .dst = value, .subject = value_option, .field_index = 0 } });
        try ctx.builder.emit(.{ .store_local = .{ .local = result_local, .src = value } });
        ctx.builder.terminate(.{ .jump = .{ .target = merge } });

        ctx.builder.setCurrentBlock(no_value);
        const default_value = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = default_value, .local = fallback_local } });
        try ctx.builder.emit(.{ .store_local = .{ .local = result_local, .src = default_value } });
        ctx.builder.terminate(.{ .jump = .{ .target = merge } });

        ctx.builder.setCurrentBlock(merge);
        const result = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = result, .local = result_local } });
        return continuesWith(result);
    }
    return null;
}

fn lowerStructConstructor(ctx: *LoweringContext, expression: ast.ExprId, symbol: symbols.SymbolId, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const entry = ctx.resolution.symbols.get(symbol) orelse return null;
    if (entry.kind != .type) return null;
    const type_entry = ctx.checked.types.get(result_type) orelse return null;
    const nominal = switch (type_entry.*) {
        .nominal => |value| value,
        else => return null,
    };
    if (nominal.symbol != symbol) return null;
    const fields = ctx.checked.nominal_fields.get(symbol) orelse return null;
    if (fields.len > 3) unsupported("структура с более чем 3 полями");
    const arguments = ctx.checked.call_arguments.get(expression) orelse call.arguments;
    const args = try lowerCallArgs(ctx, arguments) orelse return terminated;
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .new_aggregate = .{ .dst = dst, .type_name = entry.name, .elements = args } });
    return continuesWith(dst);
}

// `Целое(x)`/`Число(x)` — bare (non-module) builtin cast calls, same real
// gap as `zig/core/compiler.zig`'s `compileNumericCastBuiltin` (see its
// doc comment) — `mir_lowering.zig` needed the SAME fix independently
// since it never routes through `compiler.zig` at all. `Число(x)` is a
// pure no-op (identity — both share one f64 MIR/WASM representation),
// `Целое(x)` truncates toward zero via `UnOp.int_trunc`.
fn lowerNumericCastCall(ctx: *LoweringContext, symbol: symbols.SymbolId, call: anytype) anyerror!?ExprOutcome {
    const entry = ctx.resolution.symbols.get(symbol) orelse return null;
    if (entry.kind != .builtin or entry.module_path != null) return null;
    const is_integer = std.mem.eql(u8, entry.name, "Целое");
    if (!is_integer and !std.mem.eql(u8, entry.name, "Число")) return null;
    if (call.arguments.len != 1) unsupported("приведение типа с числом аргументов != 1");

    const argument_outcome = try lowerExpr(ctx, call.arguments[0]);
    if (argument_outcome.flow == .terminates) return terminated;
    if (!is_integer) return continuesWith(argument_outcome.value);

    const dst = try ctx.builder.newValue(ctx.checked.types.builtins.integer);
    try ctx.builder.emit(.{ .unary = .{ .dst = dst, .op = .int_trunc, .src = argument_outcome.value } });
    return continuesWith(dst);
}

fn lowerLengthBuiltinCall(ctx: *LoweringContext, symbol: symbols.SymbolId, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const entry = ctx.resolution.symbols.get(symbol) orelse return null;
    if (entry.kind != .builtin or entry.module_path != null or !std.mem.eql(u8, entry.name, "длина")) return null;
    if (call.arguments.len != 1) unsupported("длина с числом аргументов != 1");

    const argument_type = ctx.checked.expression_types.get(call.arguments[0]) orelse return null;
    const type_entry = ctx.checked.types.get(argument_type) orelse return null;
    if (type_entry.* != .primitive or type_entry.primitive != .string) return null;

    const args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .call_builtin = .{ .dst = dst, .name = "строки::длина", .args = args } });
    return continuesWith(dst);
}

fn lowerProcessBuiltinCall(ctx: *LoweringContext, symbol: symbols.SymbolId, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const entry = ctx.resolution.symbols.get(symbol) orelse return null;
    if (entry.kind != .builtin or entry.module_path != null) return null;
    if (std.mem.eql(u8, entry.name, "отправить") and call.arguments.len == 2) {
        const args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
        try ctx.builder.emit(.{ .send = .{ .process = args[0], .message = args[1] } });
        return continuesWith(mir.invalid_value);
    }
    if (std.mem.eql(u8, entry.name, "получить") and call.arguments.len == 0) {
        const dst = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .receive = .{ .dst = dst } });
        return continuesWith(dst);
    }
    if (std.mem.eql(u8, entry.name, "себя") and call.arguments.len == 0) {
        const dst = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .call_builtin = .{ .dst = dst, .name = "@runtime::current_process", .args = &.{} } });
        return continuesWith(dst);
    }
    return null;
}

// The JS string runtime owns the actual UTF-16 storage; Panos string values
// remain opaque i32 handles in WASM. `строки.срез`/`.найти` deliberately use
// Unicode scalar indices, matching the VM contract, rather than JS UTF-16
// offsets. `в_число` constructs the standard Результат handle in that same
// host runtime, so ordinary Panos `выбор` handles both outcomes unchanged.
fn lowerStringBuiltinCall(ctx: *LoweringContext, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const symbol = ctx.resolution.expr_symbols.get(call.callee) orelse return null;
    const entry = ctx.resolution.symbols.get(symbol) orelse return null;
    if (entry.kind != .builtin or entry.module_path == null or !std.mem.eql(u8, entry.module_path.?, "строки")) return null;

    const property = ctx.tree.expr(call.callee).property;
    const name = if (std.mem.eql(u8, property.property, "длина_байт"))
        "строки::длина_байт"
    else if (std.mem.eql(u8, property.property, "срез"))
        "строки::срез"
    else if (std.mem.eql(u8, property.property, "найти"))
        "строки::найти"
    else if (std.mem.eql(u8, property.property, "начинается_с"))
        "строки::начинается_с"
    else if (std.mem.eql(u8, property.property, "заменить"))
        "строки::заменить"
    else if (std.mem.eql(u8, property.property, "разбить"))
        "строки::разбить"
    else if (std.mem.eql(u8, property.property, "из_числа"))
        "строки::из_числа"
    else if (std.mem.eql(u8, property.property, "в_число"))
        "строки::в_число"
    else
        unsupported("строки.свойство вызов (неподдерживаемая строковая операция в AOT WASM)");

    const args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .call_builtin = .{ .dst = dst, .name = name, .args = args } });
    return continuesWith(dst);
}

// AOT's deliberately narrow browser-network bridge. The host performs a
// same-origin synchronous XHR because the current WASM ABI has no suspension
// or continuation support; success is `Опция.Есть(тело)`, any failed request
// is `Опция.Нет()`.
fn lowerNetworkBuiltinCall(ctx: *LoweringContext, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const symbol = ctx.resolution.expr_symbols.get(call.callee) orelse return null;
    const entry = ctx.resolution.symbols.get(symbol) orelse return null;
    if (entry.kind != .builtin or entry.module_path == null or !std.mem.eql(u8, entry.module_path.?, "сеть")) return null;

    const property = ctx.tree.expr(call.callee).property;
    if (!std.mem.eql(u8, property.property, "http_запрос_sync")) {
        unsupported("сеть.свойство вызов (неподдерживаемая сетевая операция в AOT WASM)");
    }
    const args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .call_builtin = .{ .dst = dst, .name = "сеть::http_запрос_sync", .args = args } });
    return continuesWith(dst);
}

// `время.сейчас_мс`/`.монотонно_мс` — the only builtin-module calls this
// Phase-1a-plus slice lowers, matching exactly what `zig/wasm_runtime/
// runtime_wasi.zig`'s own doc comment already anticipated ("Phase-1a never
// lowers a string at all... no clock reads reachable from any lowered
// program yet EITHER" — this is that "either" becoming true). Emitted as
// `call_builtin` with the SAME "модуль::имя" name convention `target.zig`
// already uses for runtime availability checks, not a new naming scheme.
// `время.спать_мс` deliberately has no case here — it's native-only
// (`target.zig`'s `builtinAvailability`), and stays an `unsupported()`
// panic in AOT WASM, same failure mode every other native-only feature
// already gets in this file.
fn lowerTimeBuiltinCall(ctx: *LoweringContext, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const property = ctx.tree.expr(call.callee).property;
    const symbol = ctx.resolution.expr_symbols.get(call.callee) orelse return null;
    const entry = ctx.resolution.symbols.get(symbol) orelse return null;
    if (entry.kind != .builtin or entry.module_path == null or !std.mem.eql(u8, entry.module_path.?, "время")) return null;

    if (std.mem.eql(u8, property.property, "спать_мс")) unsupported("время.спать_мс (native-only builtin, недоступен в AOT WASM)");

    const name = if (std.mem.eql(u8, property.property, "сейчас_мс"))
        "время::сейчас_мс"
    else if (std.mem.eql(u8, property.property, "монотонно_мс"))
        "время::монотонно_мс"
    else
        unsupported("модуль.свойство вызов (только время.сейчас_мс/монотонно_мс поддержаны в AOT WASM)");

    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .call_builtin = .{ .dst = dst, .name = name, .args = &.{} } });
    return continuesWith(dst);
}

// DOM supports the compatible numeric methods plus textual content/input
// methods. The browser emitter transports every Panos `Строка` as an
// opaque JS-runtime handle; click callbacks are still named, zero-argument
// exports and cannot capture a Panos context yet.
fn lowerDomBuiltinCall(ctx: *LoweringContext, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const symbol = ctx.resolution.expr_symbols.get(call.callee) orelse return null;
    const entry = ctx.resolution.symbols.get(symbol) orelse return null;
    if (entry.kind != .builtin or entry.module_path == null or !std.mem.eql(u8, entry.module_path.?, "DOM")) return null;

    const property = ctx.tree.expr(call.callee).property;
    const name = if (std.mem.eql(u8, property.property, "текст"))
        "DOM::текст"
    else if (std.mem.eql(u8, property.property, "установить_текст"))
        "DOM::установить_текст"
    else if (std.mem.eql(u8, property.property, "на_клик"))
        if (call.arguments.len == 3) "DOM::на_клик_контекст" else "DOM::на_клик"
    else if (std.mem.eql(u8, property.property, "текст_строка"))
        "DOM::текст_строка"
    else if (std.mem.eql(u8, property.property, "установить_текст_строка"))
        "DOM::установить_текст_строка"
    else if (std.mem.eql(u8, property.property, "значение_поля"))
        "DOM::значение_поля"
    else if (std.mem.eql(u8, property.property, "установить_значение_поля"))
        "DOM::установить_значение_поля"
    else if (std.mem.eql(u8, property.property, "создать_и_добавить"))
        "DOM::создать_и_добавить"
    else if (std.mem.eql(u8, property.property, "после_кадра"))
        "DOM::после_кадра"
    else
        unsupported("DOM.свойство вызов (неподдерживаемый DOM-метод)");

    const args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
    const is_void = ctx.checked.types.eql(result_type, ctx.checked.types.builtins.void);
    if (is_void) {
        try ctx.builder.emit(.{ .call_builtin = .{ .dst = null, .name = name, .args = args } });
        return continuesWith(mir.invalid_value);
    }
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .call_builtin = .{ .dst = dst, .name = name, .args = args } });
    return continuesWith(dst);
}

fn lowerCallArgs(ctx: *LoweringContext, expressions: []const ast.ExprId) anyerror!?[]const mir.ValueId {
    // Arena-backed (see `mir.Module.arena`'s doc comment) — this slice is
    // stored permanently inside a `call_value` instruction, unlike
    // `ctx.allocator`-backed temporaries that get freed within this call.
    const arena = ctx.builder.module.arena.allocator();
    var args: std.ArrayList(mir.ValueId) = .empty;
    for (expressions) |expression| {
        const outcome = try lowerExpr(ctx, expression);
        if (outcome.flow == .terminates) return null;
        try args.append(arena, outcome.value);
    }
    return try args.toOwnedSlice(arena);
}

fn emitCallValue(ctx: *LoweringContext, callee: mir.ValueId, args: []const mir.ValueId, result_type: types.TypeId) anyerror!ExprOutcome {
    if (!ctx.checked.types.eql(result_type, ctx.checked.types.builtins.void)) {
        const dst = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .call_value = .{ .dst = dst, .callee = callee, .args = args } });
        return continuesWith(dst);
    }
    try ctx.builder.emit(.{ .call_value = .{ .dst = null, .callee = callee, .args = args } });
    return continuesWith(mir.invalid_value);
}

test "lowerModule lowers a recursive arithmetic function to a valid CFG" {
    const allocator = std.testing.allocator;
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const type_checker_mod = @import("type_checker.zig");
    const source_text =
        \\функ факториал(n: Число) -> Число
        \\    если n < 2 тогда
        \\        1
        \\    иначе
        \\        n * факториал(n - 1)
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

    var module = try lowerModule(allocator, &parsed.ast, &resolved, &checked);
    defer module.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), module.functions.items.len);
    const function = &module.functions.items[0];
    try std.testing.expectEqualStrings("факториал", function.name);
    // entry (condition) + then + else + merge — the if-expression's own
    // 4-block shape, nothing more (this function's body IS the if-expr).
    try std.testing.expectEqual(@as(usize, 4), function.blocks.items.len);

    var cfg = try @import("mir_cfg.zig").computeCfgInfo(allocator, function);
    defer cfg.deinit();
    for (cfg.reachable) |reachable| try std.testing.expect(reachable);
}

test "lowerModule lowers пока into header/body/exit blocks, no back-edge when the body always returns" {
    const allocator = std.testing.allocator;
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const type_checker_mod = @import("type_checker.zig");
    // Deliberately avoids assignment here to isolate header/body/exit block
    // wiring and a body that TERMINATES (return), which must suppress the
    // loop's back-edge jump — see the accumulator test below for the
    // assignment-driven back-edge case.
    const source_text =
        \\функ цикл_тест(n: Число) -> Число
        \\    пока n > 0 цикл
        \\        возврат n
        \\    конец
        \\    0
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

    var module = try lowerModule(allocator, &parsed.ast, &resolved, &checked);
    defer module.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), module.functions.items.len);
    const function = &module.functions.items[0];
    // entry (jump to header) + header (condition) + body (returns) + exit
    // (falls through to the trailing `0`).
    try std.testing.expectEqual(@as(usize, 4), function.blocks.items.len);

    const header = function.blockConst(@enumFromInt(1));
    try std.testing.expect(header.terminator == .branch);
    const body = function.blockConst(@enumFromInt(2));
    try std.testing.expect(body.terminator == .return_value);
    const exit = function.blockConst(@enumFromInt(3));
    try std.testing.expect(exit.terminator == .return_value);
}

test "lowerModule lowers an accumulator пока loop with assignment, back-edge present" {
    const allocator = std.testing.allocator;
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const type_checker_mod = @import("type_checker.zig");
    const source_text =
        \\функ сумма_до(предел: Число) -> Число
        \\    пер итог: Число = 0
        \\    пер i: Число = 1
        \\    пока i < предел цикл
        \\        итог = итог + i
        \\        i = i + 1
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

    var module = try lowerModule(allocator, &parsed.ast, &resolved, &checked);
    defer module.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), module.functions.items.len);
    const function = &module.functions.items[0];
    // entry (jump to header) + header (condition) + body (falls off the end,
    // must jump BACK to header) + exit (falls through to trailing `итог`).
    try std.testing.expectEqual(@as(usize, 4), function.blocks.items.len);

    const body = function.blockConst(@enumFromInt(2));
    try std.testing.expect(body.terminator == .jump);
    try std.testing.expectEqual(@as(mir.BlockId, @enumFromInt(1)), body.terminator.jump.target);
}
