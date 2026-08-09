const std = @import("std");
const ast = @import("ast.zig");
const mir = @import("mir.zig");
const mir_builder = @import("mir_builder.zig");
const resolver = @import("resolver.zig");
const source = @import("source.zig");
const symbols = @import("symbols.zig");
const type_checker = @import("type_checker.zig");
const types = @import("types.zig");

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
            const outcome = try lowerExpr(ctx, return_statement.value);
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
        .ident => blk: {
            const symbol = ctx.resolution.expr_symbols.get(expression) orelse unsupported("неразрешённый идентификатор");
            break :blk continuesWith(try lowerSymbolValueRef(ctx, symbol, expressionSpan(ctx.tree, expression)));
        },
        .unary => |unary| lowerUnary(ctx, expression, unary),
        .binary => |binary| lowerBinary(ctx, expression, binary),
        .call => |call| lowerCall(ctx, expression, call),
        .if_expr => |conditional| lowerIfExpr(ctx, expression, conditional, true),
        .while_expr => |loop| blk: {
            const flow = try lowerWhile(ctx, loop);
            if (flow == .terminates) break :blk terminated;
            break :blk continuesWith(try emitConstNumber(ctx, 0));
        },
        else => unsupported("вид выражения"),
    };
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

// Ported from `core/mir_lowering.odin`'s `lower_assign`/`lower_place`. Phase
// 1a only lowers local-variable places (`Ident_Expr`) — no structs/arrays
// exist in this lowering yet, so `Property_Expr`/`Index_Expr` targets would
// need `unsupported()` regardless of scope. Assignment produces NO value
// (matches Odin's `INVALID_VALUE`/`.Continues` and the bytecode compiler's
// own `y = (x = 1)` restriction) — a well-typed program can never observe
// this, since the type checker requires an if-expression's branches to share
// a common value type before this lowering ever runs.
fn lowerAssign(ctx: *LoweringContext, binary: anytype) anyerror!ExprOutcome {
    const target = switch (ctx.tree.expr(binary.left).*) {
        .ident => blk: {
            const symbol = ctx.resolution.expr_symbols.get(binary.left) orelse unsupported("неразрешённый идентификатор в присваивании");
            break :blk ctx.symbol_to_local.get(symbol) orelse unsupported("присваивание не-локали (Фаза 3+)");
        },
        else => unsupported("цель присваивания (Фаза 3+)"),
    };
    const rhs = try lowerExpr(ctx, binary.right);
    if (rhs.flow == .terminates) return terminated;
    try ctx.builder.emit(.{ .store_local = .{ .local = target, .src = rhs.value } });
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
        }
    }

    if (ctx.tree.expr(call.callee).* == .property) {
        if (try lowerTimeBuiltinCall(ctx, call, result_type)) |outcome| return outcome;
        if (try lowerDomBuiltinCall(ctx, call, result_type)) |outcome| return outcome;
    }

    const callee_outcome = try lowerExpr(ctx, call.callee);
    if (callee_outcome.flow == .terminates) return terminated;
    const args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
    return emitCallValue(ctx, callee_outcome.value, args, result_type);
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

// `DOM.текст`/`.установить_текст`/`.на_клик` — the minimal, numeric-only
// slice `wasm_emit.zig`'s `hostImportNameForBuiltin`/`builtinSignature`
// know how to emit (see those two, `zig/core/wasm_emit.zig`): no
// object-table runtime, no closures — `DOM.текст` returns a `Число`
// (0 if the element is missing or its content doesn't parse as a
// number, matching the host loader's own contract), and `.на_клик`'s
// handler is looked up BY NAME on the host side, called with zero
// arguments (no captured "context" — that would need a real closures
// ABI, out of scope for this slice, same `AGENTS.md` Phase-1a-plus
// framing `время.*` above already uses). Arguments (CSS selectors/
// handler names) are ordinary `Строка` literals — `lowerCallArgs`
// lowers them the same generic way as any other call, relying on
// `lowerExpr`'s existing `.string` case (`const_value{.string=...}`,
// resolved to a data-section byte offset only in `wasm_emit.zig`).
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
        "DOM::на_клик"
    else
        unsupported("DOM.свойство вызов (только текст/установить_текст/на_клик поддержаны)");

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
