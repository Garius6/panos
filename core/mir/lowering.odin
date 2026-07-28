package mir

import core "../"

// AST (после резолва+тайпчека) -> MIR. Работает в ТОЙ ЖЕ точке пайплайна,
// где сегодня работает core/compiler.odin: читает уже посчитанные
// Resolver_Ctx/Type_Ctx side tables (node_symbols/node_types/stmt_symbols/
// func_args/decl_symbols/symbol_types), НИКОГДА их не мутирует и не
// пересчитывает — тот же принцип, что и у сегодняшнего compile_expr/
// compile_stmt. AST не модифицируется.
//
// Область Фазы 1 (см. план): литералы, локали (объявление/чтение/запись),
// бинарные/унарные операторы (включая short-circuit &&/|| через
// lower_condition), если/иначе, пока (с прервать/продолжить), вызовы
// обычных функций, возврат. НЕ покрыто (Фаза 2): выбор/ADT, замыкания,
// интерфейсы, акторы, async I/O, дженерики (bounded — уже отфильтрованы
// на этапе compile_program сегодня тем же способом, см. len(type_param_
// bounds) > 0), sugar операторной перегрузки (Сравниваемое/Арифметика,
// call_infos[expr].kind == .Method_Struct — см. compiler.odin case
// ^Binary_Expr) — lower_expr паникует с понятным сообщением на всём, что
// вне этого списка, а не молча производит некорректный MIR.

Flow_Result :: enum {
	Continues,
	Terminates,
}

Loop_Targets :: struct {
	continue_target: Block_Id,
	break_target:    Block_Id,
}

Lowering_Context :: struct {
	res:                ^core.Resolver_Ctx,
	tc:                 ^core.Type_Ctx,
	module:             ^Mir_Module,
	b:                  Mir_Builder,
	symbol_to_local:    map[core.Symbol_Id]Local_Id,
	symbol_to_function: map[core.Symbol_Id]Function_Id,
	loops:              [dynamic]Loop_Targets,
}

lower_unsupported :: proc(what: string) -> ! {
	panic_msg := "mir lowering (Фаза 1): не поддержано — " // extended below
	fmt_panic(panic_msg, what)
}

@(private = "file")
fmt_panic :: proc(prefix: string, what: string) -> ! {
	// Маленький helper вместо прямого fmt.panicf на каждом call site —
	// единая точка, если формат сообщения понадобится поменять.
	panic(prefix_concat(prefix, what))
}

@(private = "file")
prefix_concat :: proc(a, b: string) -> string {
	buf := make([]u8, len(a) + len(b))
	copy(buf, a)
	copy(buf[len(a):], b)
	return string(buf)
}

// --- Модуль: двухпроходный lowering (проход 1 резервирует все функции —
// forward references/рекурсия; проход 2 лоурит тела) ---

lower_module :: proc(
	res: ^core.Resolver_Ctx,
	tc: ^core.Type_Ctx,
	program: ^core.Program,
) -> Mir_Module {
	module := new_module()
	symbol_to_function := make(map[core.Symbol_Id]Function_Id)

	for decl in program.decls {
		#partial switch d in decl {
		case ^core.Function_Decl:
			if len(d.type_param_bounds) > 0 do continue // дженерики — Фаза 2, тот же фильтр, что compile_program сегодня
			sym := res.decl_symbols[decl]
			result_type := function_return_type(res, sym)
			fn_id := new_function(&module, d.name, sym, result_type, d.span)
			symbol_to_function[sym] = fn_id
		}
	}

	for decl in program.decls {
		#partial switch d in decl {
		case ^core.Function_Decl:
			if len(d.type_param_bounds) > 0 do continue
			sym := res.decl_symbols[decl]
			fn_id := symbol_to_function[sym]
			lower_function_body(res, tc, &module, fn_id, decl, d.args, d.body, symbol_to_function)
		}
	}

	return module
}

@(private = "file")
function_return_type :: proc(res: ^core.Resolver_Ctx, sym: core.Symbol_Id) -> ^core.Type {
	func_type := res.symbol_types[sym]
	if func_type == nil do return core.TY_VOID
	return func_type.return_type
}

@(private = "file")
lower_function_body :: proc(
	res: ^core.Resolver_Ctx,
	tc: ^core.Type_Ctx,
	module: ^Mir_Module,
	fn_id: Function_Id,
	key: core.Decls,
	params: [dynamic]core.Param_Decl,
	body: [dynamic]core.Stmt,
	symbol_to_function: map[core.Symbol_Id]Function_Id,
) {
	ctx := Lowering_Context {
		res                = res,
		tc                 = tc,
		module             = module,
		symbol_to_local    = make(map[core.Symbol_Id]Local_Id),
		symbol_to_function = symbol_to_function,
		loops              = make([dynamic]Loop_Targets),
	}
	ctx.b = begin_function(module, fn_id)

	args_syms, has_args := res.func_args[key]
	param_locals := make([dynamic]Local_Id, 0, len(params))
	if has_args {
		for sym, i in args_syms {
			pt := res.symbol_types[sym]
			name := i < len(params) ? params[i].name : ""
			local := new_local(&ctx.b, sym, name, pt)
			ctx.symbol_to_local[sym] = local
			append(&param_locals, local)
		}
	}
	ctx.b.function.parameters = param_locals[:]

	want_value := prune_type_or_self(ctx.b.function.result_type) != core.TY_VOID
	result, flow := lower_block(&ctx, body, want_value)
	if flow == .Continues {
		if want_value {
			terminate(&ctx.b, new_return_term(result))
		} else {
			terminate(&ctx.b, new_return_term(INVALID_VALUE_AS_NIL))
		}
	}
}

@(private = "file")
prune_type_or_self :: proc(t: ^core.Type) -> ^core.Type {
	if t == nil do return core.TY_VOID
	return core.prune_type(t)
}

INVALID_VALUE_AS_NIL :: INVALID_VALUE

@(private = "file")
new_return_term :: proc(v: Value_Id) -> ^Return_Term {
	term := new(Return_Term)
	if v == INVALID_VALUE {
		term.value = nil
	} else {
		term.value = v
	}
	return term
}

// --- Блок как значение (тот же принцип, что compile_block(..., is_expr)
// сегодня): последний Expr_Stmt в value-контексте отдаёт своё значение
// как результат блока, не Pop'ается; более ранние — только statement-
// эффект. Пустой блок в value-контексте — константный 0.0-заполнитель,
// как и сегодня. ---

lower_block :: proc(
	ctx: ^Lowering_Context,
	stmts: [dynamic]core.Stmt,
	want_value: bool,
) -> (
	result: Value_Id,
	flow: Flow_Result,
) {
	result = INVALID_VALUE
	flow = .Continues

	if len(stmts) == 0 {
		if want_value {
			result = emit_const_number(ctx, 0)
		}
		return
	}

	for i in 0 ..< len(stmts) {
		stmt := stmts[i]
		is_last := i == len(stmts) - 1

		if is_last && want_value {
			if expr_stmt, ok := stmt.(^core.Expr_Stmt); ok {
				result, flow = lower_expr(ctx, expr_stmt.expr)
			} else {
				flow = lower_stmt(ctx, stmt)
				if flow == .Continues {
					result = emit_const_number(ctx, 0)
				}
			}
		} else {
			flow = lower_stmt(ctx, stmt)
		}

		if flow == .Terminates do return
	}
	return
}

@(private = "file")
emit_const_number :: proc(ctx: ^Lowering_Context, n: f64) -> Value_Id {
	v := new_value(&ctx.b, core.TY_NUM)
	emit(&ctx.b, new_const_instr(v, n))
	return v
}

@(private = "file")
new_const_instr :: proc(dst: Value_Id, value: Const_Value) -> ^Const_Instr {
	i := new(Const_Instr)
	i.dst = dst
	i.value = value
	return i
}

// --- Statements ---

lower_stmt :: proc(ctx: ^Lowering_Context, stmt: core.Stmt) -> Flow_Result {
	switch s in stmt {
	case ^core.Let_Stmt:
		if len(s.names) > 0 {
			lower_unsupported("деструктурирующий пер (Фаза 2)")
		}
		v, flow := lower_expr(ctx, s.value)
		if flow == .Terminates do return .Terminates
		sym := ctx.res.stmt_symbols[stmt]
		local_type := ctx.tc.node_types[s.value]
		local := new_local(&ctx.b, sym, s.name, local_type)
		ctx.symbol_to_local[sym] = local
		emit(&ctx.b, new_store_local(local, v))
		return .Continues

	case ^core.Return_Stmt:
		if s.value != nil {
			v, flow := lower_expr(ctx, s.value)
			if flow == .Terminates do return .Terminates
			terminate(&ctx.b, new_return_term(v))
		} else {
			terminate(&ctx.b, new_return_term(INVALID_VALUE))
		}
		return .Terminates

	case ^core.Expr_Stmt:
		_, flow := lower_expr(ctx, s.expr)
		return flow

	case ^core.Continue_Stmt:
		if len(ctx.loops) == 0 {
			lower_unsupported("продолжить вне цикла")
		}
		target := ctx.loops[len(ctx.loops) - 1].continue_target
		terminate(&ctx.b, new_jump_term(target))
		return .Terminates

	case ^core.Break_Stmt:
		if len(ctx.loops) == 0 {
			lower_unsupported("прервать вне цикла")
		}
		target := ctx.loops[len(ctx.loops) - 1].break_target
		terminate(&ctx.b, new_jump_term(target))
		return .Terminates

	case ^core.For_In_Stmt:
		lower_unsupported("для-цикл (Фаза 2)")
	case ^core.Error_Stmt:
		lower_unsupported("Error_Stmt (парсер уже отрапортовал ошибку)")
	}
	lower_unsupported("неизвестный вид statement")
}

@(private = "file")
new_store_local :: proc(local: Local_Id, src: Value_Id) -> ^Store_Local_Instr {
	i := new(Store_Local_Instr)
	i.local = local
	i.src = src
	return i
}

@(private = "file")
new_jump_term :: proc(target: Block_Id) -> ^Jump_Term {
	t := new(Jump_Term)
	t.target = target
	return t
}

// --- Expressions (value context) ---

lower_expr :: proc(
	ctx: ^Lowering_Context,
	expr: core.Expr,
) -> (
	result: Value_Id,
	flow: Flow_Result,
) {
	flow = .Continues

	switch e in expr {
	case ^core.Number_Expr:
		result = emit_const_number(ctx, e.value)
		return

	case ^core.Boolean_Expr:
		v := new_value(&ctx.b, core.TY_BOOL)
		emit(&ctx.b, new_const_instr(v, e.value))
		result = v
		return

	case ^core.String_Expr:
		v := new_value(&ctx.b, core.TY_STRING)
		emit(&ctx.b, new_const_instr(v, e.value))
		result = v
		return

	case ^core.Ident_Expr:
		sym := ctx.res.node_symbols[expr]
		local, ok := ctx.symbol_to_local[sym]
		if !ok {
			lower_unsupported(
				"идентификатор не локаль (builtin/модуль/константа — Фаза 2)",
			)
		}
		v := new_value(&ctx.b, ctx.b.function.locals[int(local)].type)
		emit(&ctx.b, new_load_local(v, local))
		result = v
		return

	case ^core.Unary_Expr:
		return lower_unary_expr(ctx, expr, e)

	case ^core.Binary_Expr:
		return lower_binary_expr(ctx, expr, e)

	case ^core.Call_Expr:
		return lower_call_expr(ctx, expr, e)

	case ^core.If_Expr:
		return lower_if_expr(ctx, expr, e, true)

	case ^core.While_Expr:
		lower_while_expr(ctx, e)
		result = emit_const_number(ctx, 0)
		return

	case ^core.Tuple_Expr,
	     ^core.Property_Expr,
	     ^core.Lambda_Expr,
	     ^core.Array_Expr,
	     ^core.Map_Expr,
	     ^core.Index_Expr,
	     ^core.Try_Expr,
	     ^core.Match_Expr,
	     ^core.Error_Expr,
	     ^core.Spawn_Expr:
		lower_unsupported("вид выражения (Фаза 2)")
	}
	lower_unsupported("неизвестный вид выражения")
}

@(private = "file")
new_load_local :: proc(dst: Value_Id, local: Local_Id) -> ^Load_Local_Instr {
	i := new(Load_Local_Instr)
	i.dst = dst
	i.local = local
	return i
}

@(private = "file")
lower_unary_expr :: proc(
	ctx: ^Lowering_Context,
	expr: core.Expr,
	e: ^core.Unary_Expr,
) -> (
	Value_Id,
	Flow_Result,
) {
	src, flow := lower_expr(ctx, e.right)
	if flow == .Terminates do return INVALID_VALUE, .Terminates

	op: Un_Op
	#partial switch e.op {
	case .Minus:
		// Унарный минус компилируется как -1 * operand в сегодняшнем
		// байткоде (нет отдельного opcode) — на уровне MIR даём ему
		// собственный Un_Op, backend волен реализовать как умножение или
		// напрямую (деталь лоуринга MIR->bytecode, Фаза 2, не MIR).
		op = .Negate_Num
	case .Negate:
		op = .Negate_Bool
	case .Tilde:
		op = .BitNot
	case:
		lower_unsupported("неизвестный унарный оператор")
	}

	dst := new_value(&ctx.b, ctx.tc.node_types[expr])
	i := new(Unary_Instr)
	i.dst = dst
	i.op = op
	i.src = src
	emit(&ctx.b, i)
	return dst, .Continues
}

@(private = "file")
lower_binary_expr :: proc(
	ctx: ^Lowering_Context,
	expr: core.Expr,
	e: ^core.Binary_Expr,
) -> (
	Value_Id,
	Flow_Result,
) {
	if e.op == .Assign {
		lower_unsupported("присваивание = (Фаза 2)")
	}
	if _, has_sugar := ctx.tc.call_infos[expr]; has_sugar {
		lower_unsupported(
			"operator-overload sugar (Сравниваемое/Арифметика, Фаза 2)",
		)
	}

	if e.op == .And || e.op == .Or {
		return lower_short_circuit(ctx, expr, e)
	}

	lhs, lhs_flow := lower_expr(ctx, e.left)
	if lhs_flow == .Terminates do return INVALID_VALUE, .Terminates
	rhs, rhs_flow := lower_expr(ctx, e.right)
	if rhs_flow == .Terminates do return INVALID_VALUE, .Terminates

	result_type := ctx.tc.node_types[expr]

	#partial switch e.op {
	case .Plus:
		return emit_binary(ctx, .Add, lhs, rhs, result_type), .Continues
	case .Minus:
		return emit_binary(ctx, .Subtract, lhs, rhs, result_type), .Continues
	case .Star:
		return emit_binary(ctx, .Multiply, lhs, rhs, result_type), .Continues
	case .Slash:
		// Int_Divide vs Divide — тот же выбор по статическому типу ЛЕВОГО
		// операнда, что и сегодняшний compile_expr (core/compiler.odin,
		// case .Slash), не рантайм-решение.
		if ctx.tc.node_types[e.left] == core.TY_INT {
			return emit_binary(ctx, .Int_Divide, lhs, rhs, result_type), .Continues
		}
		return emit_binary(ctx, .Divide, lhs, rhs, result_type), .Continues
	case .Percent:
		return emit_binary(ctx, .Modulo, lhs, rhs, result_type), .Continues
	case .Ampersand:
		return emit_binary(ctx, .BitAnd, lhs, rhs, result_type), .Continues
	case .Pipe:
		return emit_binary(ctx, .BitOr, lhs, rhs, result_type), .Continues
	case .Caret:
		return emit_binary(ctx, .BitXor, lhs, rhs, result_type), .Continues
	case .LessLess:
		return emit_binary(ctx, .ShiftLeft, lhs, rhs, result_type), .Continues
	case .GreaterGreater:
		return emit_binary(ctx, .ShiftRight, lhs, rhs, result_type), .Continues
	case .Less:
		return emit_compare(ctx, .Less, lhs, rhs), .Continues
	case .Greater:
		return emit_compare(ctx, .Greater, lhs, rhs), .Continues
	case .LessEqual:
		return emit_compare(ctx, .LessEqual, lhs, rhs), .Continues
	case .GreaterEqual:
		return emit_compare(ctx, .GreaterEqual, lhs, rhs), .Continues
	case .Equal:
		return emit_compare(ctx, .Equal, lhs, rhs), .Continues
	case .NotEqual:
		return emit_compare(ctx, .NotEqual, lhs, rhs), .Continues
	}
	lower_unsupported("неизвестный бинарный оператор")
}

@(private = "file")
emit_binary :: proc(
	ctx: ^Lowering_Context,
	op: Bin_Op,
	lhs, rhs: Value_Id,
	result_type: ^core.Type,
) -> Value_Id {
	dst := new_value(&ctx.b, result_type)
	i := new(Binary_Instr)
	i.dst = dst
	i.op = op
	i.lhs = lhs
	i.rhs = rhs
	emit(&ctx.b, i)
	return dst
}

@(private = "file")
emit_compare :: proc(ctx: ^Lowering_Context, op: Cmp_Op, lhs, rhs: Value_Id) -> Value_Id {
	dst := new_value(&ctx.b, core.TY_BOOL)
	i := new(Compare_Instr)
	i.dst = dst
	i.op = op
	i.lhs = lhs
	i.rhs = rhs
	emit(&ctx.b, i)
	return dst
}

// lower_short_circuit — a && b / a || b как CFG-ветвление, НЕ eager
// Binary(And, a, b): условие `a` решает, нужно ли вообще вычислять `b`
// (побочные эффекты `b` не должны выполняться, если `a` уже решил
// исход). Реализовано через lower_condition (см. ниже) + слияние в
// временную locals-ячейку — тот же non-SSA "phi через Store_Local"
// приём, что lower_if_expr использует для результата если/иначе.
@(private = "file")
lower_short_circuit :: proc(
	ctx: ^Lowering_Context,
	expr: core.Expr,
	e: ^core.Binary_Expr,
) -> (
	Value_Id,
	Flow_Result,
) {
	result_local := new_local(&ctx.b, core.INVALID_SYMBOL, "$logic", core.TY_BOOL)

	rhs_block := new_block(&ctx.b)
	short_block := new_block(&ctx.b)
	merge_block := new_block(&ctx.b)

	short_value := e.op == .Or // a || b: коротким выходом (a истинно) кладём true; a && b: коротким (a ложно) кладём false

	if e.op == .And {
		lower_condition(ctx, e.left, rhs_block, short_block)
	} else {
		lower_condition(ctx, e.left, short_block, rhs_block)
	}

	set_current_block(&ctx.b, short_block)
	sv := new_value(&ctx.b, core.TY_BOOL)
	emit(&ctx.b, new_const_instr(sv, short_value))
	emit(&ctx.b, new_store_local(result_local, sv))
	terminate(&ctx.b, new_jump_term(merge_block))

	set_current_block(&ctx.b, rhs_block)
	rv, rflow := lower_expr(ctx, e.right)
	if rflow == .Continues {
		emit(&ctx.b, new_store_local(result_local, rv))
		terminate(&ctx.b, new_jump_term(merge_block))
	}

	set_current_block(&ctx.b, merge_block)
	result := new_value(&ctx.b, core.TY_BOOL)
	emit(&ctx.b, new_load_local(result, result_local))
	return result, .Continues
}

// lower_condition — branch-контекст: строит CFG-рёбра напрямую вместо
// вычисления bool-значения, нужен для short-circuit &&/|| (см. выше) и
// для условий если/пока. a && b лоурится как: lower_condition(a,
// rhs_block, false_target), внутри rhs_block — lower_condition(b,
// true_target, false_target); a || b — симметрично.
lower_condition :: proc(
	ctx: ^Lowering_Context,
	expr: core.Expr,
	true_target, false_target: Block_Id,
) {
	if bin, ok := expr.(^core.Binary_Expr); ok {
		if bin.op == .And {
			rhs_block := new_block(&ctx.b)
			lower_condition(ctx, bin.left, rhs_block, false_target)
			set_current_block(&ctx.b, rhs_block)
			lower_condition(ctx, bin.right, true_target, false_target)
			return
		}
		if bin.op == .Or {
			rhs_block := new_block(&ctx.b)
			lower_condition(ctx, bin.left, true_target, rhs_block)
			set_current_block(&ctx.b, rhs_block)
			lower_condition(ctx, bin.right, true_target, false_target)
			return
		}
	}

	v, flow := lower_expr(ctx, expr)
	if flow == .Terminates do return
	terminate(&ctx.b, new_branch_term(v, true_target, false_target))
}

@(private = "file")
new_branch_term :: proc(cond: Value_Id, then_block, else_block: Block_Id) -> ^Branch_Term {
	t := new(Branch_Term)
	t.cond = cond
	t.then_block = then_block
	t.else_block = else_block
	return t
}

@(private = "file")
lower_call_expr :: proc(
	ctx: ^Lowering_Context,
	expr: core.Expr,
	e: ^core.Call_Expr,
) -> (
	Value_Id,
	Flow_Result,
) {
	callee_ident, ok := e.callee.(^core.Ident_Expr)
	if !ok {
		lower_unsupported(
			"вызов не через простой идентификатор (метод/builtin/конструктор — Фаза 2)",
		)
	}
	callee_sym := ctx.res.node_symbols[e.callee]
	fn_id, ok2 := ctx.symbol_to_function[callee_sym]
	if !ok2 {
		lower_unsupported(
			"вызов не top-level функции (builtin/метод/дженерик-инстанциация — Фаза 2)",
		)
	}

	args := make([dynamic]Value_Id, 0, len(e.args))
	for a in e.args {
		v, flow := lower_expr(ctx, a)
		if flow == .Terminates do return INVALID_VALUE, .Terminates
		append(&args, v)
	}

	result_type := ctx.tc.node_types[expr]
	i := new(Call_Instr)
	i.callee = fn_id
	i.args = args[:]

	if result_type != nil && core.prune_type(result_type) != core.TY_VOID {
		dst := new_value(&ctx.b, result_type)
		i.dst = dst
		emit(&ctx.b, i)
		return dst, .Continues
	}

	emit(&ctx.b, i)
	return INVALID_VALUE, .Continues
}

// lower_if_expr — если/иначе как значение ИЛИ как statement
// (want_value=false из lower_stmt/Expr_Stmt-обёртки на верхнем уровне
// блока). Слияние результата — через синтетическую locals-ячейку
// (Store_Local в каждой ЖИВОЙ (не-terminates) ветке, Load_Local в
// merge-блоке) — тот же non-SSA "temp slot" приём, что
// compile_match_expr использует для subject'а сегодня (core/compiler.
// odin), не phi-узел (MIR Фазы 1 намеренно не SSA, см. план).
@(private = "file")
lower_if_expr :: proc(
	ctx: ^Lowering_Context,
	expr: core.Expr,
	e: ^core.If_Expr,
	want_value: bool,
) -> (
	Value_Id,
	Flow_Result,
) {
	cond_v, cond_flow := lower_expr(ctx, e.condition)
	if cond_flow == .Terminates do return INVALID_VALUE, .Terminates

	then_block := new_block(&ctx.b)
	else_block := new_block(&ctx.b)
	merge_block := new_block(&ctx.b)
	terminate(&ctx.b, new_branch_term(cond_v, then_block, else_block))

	result_type := ctx.tc.node_types[expr]
	result_local := INVALID_LOCAL
	if want_value {
		result_local = new_local(&ctx.b, core.INVALID_SYMBOL, "$if", result_type)
	}

	set_current_block(&ctx.b, then_block)
	then_val, then_flow := lower_block(ctx, e.then_branch, want_value)
	then_continues := then_flow == .Continues
	if then_continues {
		if want_value do emit(&ctx.b, new_store_local(result_local, then_val))
		terminate(&ctx.b, new_jump_term(merge_block))
	}

	set_current_block(&ctx.b, else_block)
	else_val, else_flow := lower_block(ctx, e.else_branch, want_value)
	else_continues := else_flow == .Continues
	if else_continues {
		if want_value do emit(&ctx.b, new_store_local(result_local, else_val))
		terminate(&ctx.b, new_jump_term(merge_block))
	}

	if !then_continues && !else_continues {
		set_current_block(&ctx.b, merge_block)
		terminate(
			&ctx.b,
			new_unreachable_term(
				"обе ветки если завершают выполнение (возврат/прервать/продолжить)",
			),
		)
		return INVALID_VALUE, .Terminates
	}

	set_current_block(&ctx.b, merge_block)
	if want_value {
		result := new_value(&ctx.b, result_type)
		emit(&ctx.b, new_load_local(result, result_local))
		return result, .Continues
	}
	return INVALID_VALUE, .Continues
}

INVALID_LOCAL :: max(Local_Id)

@(private = "file")
new_unreachable_term :: proc(reason: string) -> ^Unreachable_Term {
	t := new(Unreachable_Term)
	t.reason = reason
	return t
}

// lower_while_expr — только как statement (Фаза 1: значение цикла как
// выражения не нужно ни одному сценарию из lower_expr выше — там вызов
// просто кладёт константный 0.0-заполнитель, тем же способом, что
// пустой блок в value-контексте).
@(private = "file")
lower_while_expr :: proc(ctx: ^Lowering_Context, e: ^core.While_Expr) {
	header_block := new_block(&ctx.b)
	body_block := new_block(&ctx.b)
	exit_block := new_block(&ctx.b)

	terminate(&ctx.b, new_jump_term(header_block))
	set_current_block(&ctx.b, header_block)
	cond_v, cond_flow := lower_expr(ctx, e.condition)
	if cond_flow == .Terminates do return
	terminate(&ctx.b, new_branch_term(cond_v, body_block, exit_block))

	set_current_block(&ctx.b, body_block)
	append(&ctx.loops, Loop_Targets{continue_target = header_block, break_target = exit_block})
	_, body_flow := lower_block(ctx, e.body, false)
	pop(&ctx.loops)
	if body_flow == .Continues {
		terminate(&ctx.b, new_jump_term(header_block))
	}

	set_current_block(&ctx.b, exit_block)
}
