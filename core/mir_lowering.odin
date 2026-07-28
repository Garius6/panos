package core

import "core:fmt"

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
	res:                ^Resolver_Ctx,
	tc:                 ^Type_Ctx,
	module:             ^Mir_Module,
	b:                  Mir_Builder,
	symbol_to_local:    map[Symbol_Id]Local_Id,
	symbol_to_function: map[Symbol_Id]Function_Id,
	// Непусто ТОЛЬКО при лоуринге ТЕЛА лямбды — индекс символа в
	// Closure_Value.captured (порядок = ctx.res.lambda_captures[expr],
	// тот же, что Get_Captured сегодня). Проверяется ПОСЛЕ symbol_to_local
	// в Ident_Expr — тот же порядок приоритета, что compile_symbol_value_
	// ref сегодня (locals, потом captures, потом global function).
	symbol_to_capture:  map[Symbol_Id]int,
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

// lower_module — как ensure_prelude_compiled + compile_program сегодня
// (core/pipeline.odin): прелюдия (Опция/Результат и их методы — .получить/
// .значение/.причина/т.п., СВОИ res/tc через res.prelude_res_ctx/
// prelude_tc_ctx, СВОЙ AST через prelude_res_ctx.current_module.ast)
// хостится/лоурится В ТОТ ЖЕ module/symbol_to_function ПЕРЕД пользова-
// тельской программой — иначе любой вызов .получить(запасное) и т.п. не
// резолвился бы (прелюдийные декларации не входят в program.decls).
lower_module :: proc(
	res: ^Resolver_Ctx,
	tc: ^Type_Ctx,
	program: ^Program,
) -> Mir_Module {
	module := new_module()
	symbol_to_function := make(map[Symbol_Id]Function_Id)

	if res.prelude_res_ctx != nil && res.prelude_tc_ctx != nil {
		hoist_decls(res.prelude_res_ctx, &module, &symbol_to_function, res.prelude_res_ctx.current_module.ast.decls)
		lower_decls(res.prelude_res_ctx, res.prelude_tc_ctx, &module, &symbol_to_function, res.prelude_res_ctx.current_module.ast.decls)
	}

	hoist_decls(res, &module, &symbol_to_function, program.decls)

	// Bounded traits: ПОСЛЕ hoisting (клоны могут ссылаться на Function_Id
	// обычных функций/методов — skeleton уже существует, тело ещё нет),
	// но ДО lower_decls — иначе call site'ы bounded generic-функций (см.
	// lower_call_expr_inner) не найдут свою инстанциацию в module.
	// generic_instantiations. Один вызов покрывает и прелюдию, и
	// пользовательскую программу — tc.generic_call_instantiations общая
	// на весь тайпчек, symbol_at(...).decl не зависит от того, в каком
	// hoist_decls-проходе была зарегистрирована исходная generic-функция.
	lower_monomorphize_program(res, tc, &module, &symbol_to_function)

	lower_decls(res, tc, &module, &symbol_to_function, program.decls)

	return module
}

@(private = "file")
hoist_decls :: proc(
	res: ^Resolver_Ctx,
	module: ^Mir_Module,
	symbol_to_function: ^map[Symbol_Id]Function_Id,
	decls: [dynamic]Decls,
) {
	for decl in decls {
		#partial switch d in decl {
		case ^Function_Decl:
			if len(d.type_param_bounds) > 0 do continue // дженерики — Фаза 2, тот же фильтр, что compile_program сегодня
			sym := res.decl_symbols[decl]
			result_type := function_return_type(res, sym)
			fn_id := new_function(module, d.name, sym, result_type, d.span)
			symbol_to_function[sym] = fn_id
		case ^Impl_Decl:
			// Методы структур/интерфейсов — та же двухпроходная логика,
			// что compile_program's Impl_Decl case (hoist ВСЕХ методов ДО
			// лоуринга любого тела, forward references/рекурсия между
			// методами работают так же, как между top-level функциями).
			for m in d.methods {
				sym := res.decl_symbols[m]
				result_type := function_return_type(res, sym)
				fn_id := new_function(module, m.name, sym, result_type, m.span)
				symbol_to_function[sym] = fn_id
			}
		}
	}
}

@(private = "file")
lower_decls :: proc(
	res: ^Resolver_Ctx,
	tc: ^Type_Ctx,
	module: ^Mir_Module,
	symbol_to_function: ^map[Symbol_Id]Function_Id,
	decls: [dynamic]Decls,
) {
	for decl in decls {
		#partial switch d in decl {
		case ^Function_Decl:
			if len(d.type_param_bounds) > 0 do continue
			sym := res.decl_symbols[decl]
			fn_id := symbol_to_function[sym]
			lower_function_body(res, tc, module, fn_id, decl, d.args, d.body, symbol_to_function^)
		case ^Impl_Decl:
			for m in d.methods {
				sym := res.decl_symbols[m]
				fn_id := symbol_to_function[sym]
				lower_function_body(res, tc, module, fn_id, m, m.args, m.body, symbol_to_function^)
			}
		}
	}
}

@(private = "file")
function_return_type :: proc(res: ^Resolver_Ctx, sym: Symbol_Id) -> ^Type {
	func_type := res.symbol_types[sym]
	if func_type == nil do return TY_VOID
	return func_type.return_type
}

// НЕ private = "file" — lower_monomorphize_one (mir_monomorphize.odin)
// переиспользует эту же функцию для тел мономорфизированных клонов
// (тот же приём, что lower_module делает для обычных top-level функций,
// клон неотличим от обычной функции к этому моменту).
lower_function_body :: proc(
	res: ^Resolver_Ctx,
	tc: ^Type_Ctx,
	module: ^Mir_Module,
	fn_id: Function_Id,
	key: Decls,
	params: [dynamic]Param_Decl,
	body: [dynamic]Stmt,
	symbol_to_function: map[Symbol_Id]Function_Id,
) {
	ctx := Lowering_Context {
		res                = res,
		tc                 = tc,
		module             = module,
		symbol_to_local    = make(map[Symbol_Id]Local_Id),
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
	current_function(&ctx.b).parameters = param_locals[:]

	want_value := prune_type_or_self(current_function(&ctx.b).result_type) != TY_VOID
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
prune_type_or_self :: proc(t: ^Type) -> ^Type {
	if t == nil do return TY_VOID
	return prune_type(t)
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
	stmts: [dynamic]Stmt,
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
			if expr_stmt, ok := stmt.(^Expr_Stmt); ok {
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
	v := new_value(&ctx.b, TY_NUM)
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

lower_stmt :: proc(ctx: ^Lowering_Context, stmt: Stmt) -> Flow_Result {
	switch s in stmt {
	case ^Let_Stmt:
		if len(s.names) > 0 {
			// Деструктуризация (тупл или структура — оба Aggregate_Value,
			// Get_Property по числовому индексу работает одинаково для
			// обоих) — тот же приём, что core/compiler.odin: значение
			// материализуется в СИНТЕТИЧЕСКИЙ Mir_Local (читается по разу
			// на каждое имя — обязано идти через Local, не bare Value_Id,
			// см. single-use инвариант), затем Get_Property+Store_Local
			// на каждое имя.
			v, flow := lower_expr(ctx, s.value)
			if flow == .Terminates do return .Terminates
			value_local := new_local(&ctx.b, INVALID_SYMBOL, "$destructure", ctx.tc.node_types[s.value])
			emit(&ctx.b, new_store_local(value_local, v))

			syms := ctx.res.let_destructure_syms[stmt]
			field_indices := ctx.tc.let_destructure_field_indices[stmt]
			for sym, i in syms {
				// Тип поля не протаскиваем (nil) — ни backend (Фаза 4,
				// см. план), ни текущий validate.odin не читают value_
				// types[i] для чего-то, кроме длины/подсчёта; уточнение
				// типа per-field — не блокер для корректной структуры
				// инструкций/CFG.
				loaded := new_value(&ctx.b, nil)
				emit(&ctx.b, new_load_local(loaded, value_local))
				field_v := new_value(&ctx.b, nil)
				gp := new(Get_Property_Instr)
				gp.dst = field_v
				gp.object = loaded
				gp.field_index = field_indices[i]
				emit(&ctx.b, gp)
				binder_local := new_local(&ctx.b, sym, s.names[i], nil)
				ctx.symbol_to_local[sym] = binder_local
				emit(&ctx.b, new_store_local(binder_local, field_v))
			}
			return .Continues
		}
		v, flow := lower_expr(ctx, s.value)
		if flow == .Terminates do return .Terminates
		sym := ctx.res.stmt_symbols[stmt]
		local_type := ctx.tc.node_types[s.value]
		local := new_local(&ctx.b, sym, s.name, local_type)
		ctx.symbol_to_local[sym] = local
		emit(&ctx.b, new_store_local(local, v))
		return .Continues

	case ^Return_Stmt:
		if s.value != nil {
			v, flow := lower_expr(ctx, s.value)
			if flow == .Terminates do return .Terminates
			terminate(&ctx.b, new_return_term(v))
		} else {
			terminate(&ctx.b, new_return_term(INVALID_VALUE))
		}
		return .Terminates

	case ^Expr_Stmt:
		// If_Expr — особый случай: lower_expr's If_Expr-ветка всегда
		// лоурит с want_value=true (нужно для if-как-значения в value-
		// контексте), но здесь (Expr_Stmt — значение ВСЕГДА отбрасывается)
		// это создавало бы синтетическую merge-ячейку и пыталось Store_
		// Local в неё INVALID_VALUE для веток без реального значения
		// (напр. `если ... тогда сумма = сумма + i конец` — присваивание
		// не производит значения) — реальный баг, найденный дифференциальным
		// тестированием (Фаза 2.5): падение "Index out of range" в VM —
		// Store_Local с несуществующим src портил стек. Явно лоурим с
		// want_value=false, минуя lower_expr's жёстко закодированный true.
		if if_expr, is_if := s.expr.(^If_Expr); is_if {
			_, flow := lower_if_expr(ctx, s.expr, if_expr, false)
			return flow
		}
		_, flow := lower_expr(ctx, s.expr)
		return flow

	case ^Continue_Stmt:
		if len(ctx.loops) == 0 {
			lower_unsupported("продолжить вне цикла")
		}
		target := ctx.loops[len(ctx.loops) - 1].continue_target
		terminate(&ctx.b, new_jump_term(target))
		return .Terminates

	case ^Break_Stmt:
		if len(ctx.loops) == 0 {
			lower_unsupported("прервать вне цикла")
		}
		target := ctx.loops[len(ctx.loops) - 1].break_target
		terminate(&ctx.b, new_jump_term(target))
		return .Terminates

	case ^For_In_Stmt:
		return lower_for_in_stmt(ctx, stmt, s)
	case ^Error_Stmt:
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
	expr: Expr,
) -> (
	result: Value_Id,
	flow: Flow_Result,
) {
	flow = .Continues

	switch e in expr {
	case ^Number_Expr:
		result = emit_const_number(ctx, e.value)
		return

	case ^Boolean_Expr:
		v := new_value(&ctx.b, TY_BOOL)
		emit(&ctx.b, new_const_instr(v, e.value))
		result = v
		return

	case ^String_Expr:
		v := new_value(&ctx.b, TY_STRING)
		emit(&ctx.b, new_const_instr(v, e.value))
		result = v
		return

	case ^Ident_Expr:
		sym := ctx.res.node_symbols[expr]
		result = lower_symbol_value_ref(ctx, sym, ctx.tc.node_types[expr])
		return

	case ^Unary_Expr:
		return lower_unary_expr(ctx, expr, e)

	case ^Binary_Expr:
		return lower_binary_expr(ctx, expr, e)

	case ^Call_Expr:
		return lower_call_expr(ctx, expr, e)

	case ^If_Expr:
		return lower_if_expr(ctx, expr, e, true)

	case ^While_Expr:
		lower_while_expr(ctx, e)
		result = emit_const_number(ctx, 0)
		return

	case ^Tuple_Expr:
		elements := make([dynamic]Value_Id, 0, len(e.elements))
		for el in e.elements {
			v, eflow := lower_expr(ctx, el)
			if eflow == .Terminates do return INVALID_VALUE, .Terminates
			append(&elements, v)
		}
		dst := new_value(&ctx.b, ctx.tc.node_types[expr])
		i := new(New_Aggregate_Instr)
		i.dst = dst
		i.type_name = "" // анонимный тупл — та же конвенция, что Aggregate_Value.type_name сегодня
		i.elements = elements[:]
		emit(&ctx.b, i)
		return dst, .Continues

	case ^Array_Expr:
		elements := make([dynamic]Value_Id, 0, len(e.elements))
		for el in e.elements {
			v, eflow := lower_expr(ctx, el)
			if eflow == .Terminates do return INVALID_VALUE, .Terminates
			append(&elements, v)
		}
		dst := new_value(&ctx.b, ctx.tc.node_types[expr])
		i := new(New_Array_Instr)
		i.dst = dst
		i.elements = elements[:]
		emit(&ctx.b, i)
		return dst, .Continues

	case ^Map_Expr:
		keys := make([dynamic]Value_Id, 0, len(e.entries))
		vals := make([dynamic]Value_Id, 0, len(e.entries))
		for entry in e.entries {
			kv, kflow := lower_expr(ctx, entry.key)
			if kflow == .Terminates do return INVALID_VALUE, .Terminates
			vv, vflow := lower_expr(ctx, entry.value)
			if vflow == .Terminates do return INVALID_VALUE, .Terminates
			append(&keys, kv)
			append(&vals, vv)
		}
		dst := new_value(&ctx.b, ctx.tc.node_types[expr])
		i := new(New_Map_Instr)
		i.dst = dst
		i.keys = keys[:]
		i.vals = vals[:]
		emit(&ctx.b, i)
		return dst, .Continues

	case ^Index_Expr:
		obj, oflow := lower_expr(ctx, e.object)
		if oflow == .Terminates do return INVALID_VALUE, .Terminates
		idx, iflow := lower_expr(ctx, e.index)
		if iflow == .Terminates do return INVALID_VALUE, .Terminates
		dst := new_value(&ctx.b, ctx.tc.node_types[expr])
		i := new(Get_Index_Instr)
		i.dst = dst
		i.object = obj
		i.index = idx
		emit(&ctx.b, i)
		return dst, .Continues

	case ^Property_Expr:
		// Constructor_Variant через голое свойство (0-арный enum-вариант
		// без ()) — та же спец-ветка, что core/compiler.odin's case
		// ^Property_Expr (call_infos[expr].kind == .Constructor_Variant),
		// не обычное чтение поля.
		if info, ok := ctx.tc.call_infos[expr]; ok && info.kind == Call_Kind.Constructor_Variant {
			dst := new_value(&ctx.b, ctx.tc.node_types[expr])
			bv := new(Build_Variant_Instr)
			bv.dst = dst
			bv.type_name = info.variant.owner_type.name
			bv.variant_name = info.variant.owner_type.variants[info.variant.tag_index].name
			bv.tag = info.variant.tag_index
			bv.fields = nil
			emit(&ctx.b, bv)
			return maybe_wrap_interface_cast(ctx, expr, dst), .Continues
		}

		obj, oflow := lower_expr(ctx, e.object)
		if oflow == .Terminates do return INVALID_VALUE, .Terminates
		dst := new_value(&ctx.b, ctx.tc.node_types[expr])
		i := new(Get_Property_Instr)
		i.dst = dst
		i.object = obj
		i.field_index = ctx.tc.property_indices[expr]
		emit(&ctx.b, i)
		return dst, .Continues

	case ^Try_Expr:
		src, sflow := lower_expr(ctx, e.value)
		if sflow == .Terminates do return INVALID_VALUE, .Terminates
		dst := new_value(&ctx.b, ctx.tc.node_types[expr])
		i := new(Try_Unwrap_Instr)
		i.dst = dst
		i.src = src
		emit(&ctx.b, i)
		return dst, .Continues

	case ^Match_Expr:
		return lower_match_expr(ctx, expr, e)

	case ^Error_Expr:
		// Компилятор запускается только после typecheck_program с нулём
		// diagnostics — Error_Expr сюда дойти не должен (см. core/
		// compiler.odin's тот же комментарий на этом кейсе).
		lower_unsupported("Error_Expr дошёл до lowering — типизация должна была отклонить программу раньше")

	case ^Spawn_Expr:
		return lower_spawn_expr(ctx, expr, e)

	case ^Lambda_Expr:
		return lower_lambda_expr(ctx, expr, e)
	}
	lower_unsupported("неизвестный вид выражения")
}

// lower_spawn_expr — `запусти f(args...)`. Покрывает только callee-
// идентификатор В ТОМ ЖЕ модуле (см. core/compiler.odin's case
// ^Spawn_Expr) — `запусти Модуль.функция(...)` требует cross-module
// резолва экспортов, которого lower_module целиком (single-программный
// вход, как и compile_program) сегодня не делает ни для чего (не
// специфично для Spawn) — известное ограничение, не блокер для этой фазы.
@(private = "file")
lower_spawn_expr :: proc(ctx: ^Lowering_Context, expr: Expr, e: ^Spawn_Expr) -> (Value_Id, Flow_Result) {
	if _, is_prop := e.call.callee.(^Property_Expr); is_prop {
		lower_unsupported("запусти через cross-module callee (Модуль.функция) — Фаза 3+")
	}
	callee_sym := ctx.res.node_symbols[e.call.callee]
	fn_id, found := ctx.symbol_to_function[callee_sym]
	if !found {
		lower_unsupported("запусти: функция не найдена в symbol_to_function")
	}
	fn_ref := emit_fn_ref(ctx, fn_id, nil)
	args, aflow := lower_call_args(ctx, e.call.args)
	if aflow == .Terminates do return INVALID_VALUE, .Terminates
	dst := new_value(&ctx.b, ctx.tc.node_types[expr])
	i := new(Spawn_Instr)
	i.dst = dst
	i.callee = fn_ref
	i.args = args
	emit(&ctx.b, i)
	return dst, .Continues
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
	expr: Expr,
	e: ^Unary_Expr,
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
	expr: Expr,
	e: ^Binary_Expr,
) -> (
	Value_Id,
	Flow_Result,
) {
	if e.op == .Assign {
		return lower_assign(ctx, e)
	}
	if info, has_sugar := ctx.tc.call_infos[expr]; has_sugar && info.kind == Call_Kind.Method_Struct {
		// Сравниваемое/Арифметика sugar — реюз Method_Struct-кодогена
		// (сравнить()/сложить()/... возвращают либо Число (3-way compare,
		// нормализуется ниже до Булево через сравнение с 0), либо Self
		// напрямую для +/-/*//.
		return lower_operator_sugar(ctx, expr, e, info)
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
		if ctx.tc.node_types[e.left] == TY_INT {
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
lower_operator_sugar :: proc(
	ctx: ^Lowering_Context,
	expr: Expr,
	e: ^Binary_Expr,
	info: Call_Info,
) -> (
	Value_Id,
	Flow_Result,
) {
	fn_id, found := ctx.symbol_to_function[info.symbol_ref]
	if !found {
		lower_unsupported("метод сравнить/сложить/... не найден в symbol_to_function")
	}
	fn_ref := emit_fn_ref(ctx, fn_id, nil)
	lhs, lflow := lower_expr(ctx, e.left)
	if lflow == .Terminates do return INVALID_VALUE, .Terminates
	rhs, rflow := lower_expr(ctx, e.right)
	if rflow == .Terminates do return INVALID_VALUE, .Terminates

	raw := emit_call_value(ctx, fn_ref, value_slice(lhs, rhs), ctx.tc.node_types[expr])

	#partial switch e.op {
	case .Less:
		zero := emit_const_number(ctx, 0)
		return emit_compare(ctx, .Less, raw, zero), .Continues
	case .Greater:
		zero := emit_const_number(ctx, 0)
		return emit_compare(ctx, .Greater, raw, zero), .Continues
	case .LessEqual:
		zero := emit_const_number(ctx, 0)
		gt := emit_compare(ctx, .Greater, raw, zero)
		return emit_unary(ctx, .Negate_Bool, gt, TY_BOOL), .Continues
	case .GreaterEqual:
		zero := emit_const_number(ctx, 0)
		lt := emit_compare(ctx, .Less, raw, zero)
		return emit_unary(ctx, .Negate_Bool, lt, TY_BOOL), .Continues
	case .NotEqual:
		return emit_unary(ctx, .Negate_Bool, raw, TY_BOOL), .Continues
	case .Equal, .Plus, .Minus, .Star, .Slash:
		// равно() уже Булево; сложить/вычесть/умножить/разделить уже Self —
		// raw и есть ответ, без пост-обработки.
		return raw, .Continues
	}
	lower_unsupported("неизвестный оператор operator-overload sugar")
}

@(private = "file")
emit_unary :: proc(ctx: ^Lowering_Context, op: Un_Op, src: Value_Id, result_type: ^Type) -> Value_Id {
	dst := new_value(&ctx.b, result_type)
	i := new(Unary_Instr)
	i.dst = dst
	i.op = op
	i.src = src
	emit(&ctx.b, i)
	return dst
}

// lower_place — куда писать значение присваивания (см. Place, core/mir/
// mir.odin). Не читает текущее значение цели — только вычисляет АДРЕС
// (для Property_Place/Index_Place это значит лоурить object/index как
// ОБЫЧНЫЕ выражения, они читаются, а не пишутся).
@(private = "file")
lower_place :: proc(ctx: ^Lowering_Context, expr: Expr) -> (Place, Flow_Result) {
	#partial switch e in expr {
	case ^Ident_Expr:
		sym := ctx.res.node_symbols[expr]
		local, ok := ctx.symbol_to_local[sym]
		if !ok {
			lower_unsupported("присваивание не-локали (Фаза 3+)")
		}
		p := new(Local_Place)
		p.local = local
		return p, .Continues

	case ^Property_Expr:
		obj, flow := lower_expr(ctx, e.object)
		if flow == .Terminates do return nil, .Terminates
		p := new(Property_Place)
		p.object = obj
		p.field_index = ctx.tc.property_indices[expr]
		return p, .Continues

	case ^Index_Expr:
		obj, flow := lower_expr(ctx, e.object)
		if flow == .Terminates do return nil, .Terminates
		idx, idx_flow := lower_expr(ctx, e.index)
		if idx_flow == .Terminates do return nil, .Terminates
		p := new(Index_Place)
		p.object = obj
		p.index = idx
		return p, .Continues
	}
	lower_unsupported("недопустимая цель присваивания")
}

// lower_assign — Binary_Expr{op=.Assign}. ПОРЯДОК ВЫЧИСЛЕНИЯ ВАЖЕН и
// ОТЛИЧАЕТСЯ от наивного "RHS потом место": core/compiler.odin's Assign-
// ветка для Property/Index вычисляет МЕСТО (object[, index]) ПЕРВЫМ, RHS
// ПОСЛЕДНИМ — потому что core/vm.odin's .Set_Property/.Set_Index
// ожидают строго [..., object[, index], value] на стеке (снимают value
// первым, object/index — глубже). lower_place emit'ит инструкции
// ТОЛЬКО для Property/Index (Local — чистый lookup без побочных
// инструкций, порядок для него не важен), поэтому безусловный
// "место, потом RHS" корректен для ВСЕХ трёх случаев разом. Значения
// присваивание НЕ производит (Set_Local/Set_Property/Set_Index сегодня
// НЕ оставляют значение на стеке — см. core/vm.odin case .Set_Local: pop,
// не peek) — `y = (x = 1)` не поддержано ни сегодняшним компилятором, ни
// этим, сохраняем то же поведение.
@(private = "file")
lower_assign :: proc(ctx: ^Lowering_Context, e: ^Binary_Expr) -> (Value_Id, Flow_Result) {
	place, place_flow := lower_place(ctx, e.left)
	if place_flow == .Terminates do return INVALID_VALUE, .Terminates

	rhs, rhs_flow := lower_expr(ctx, e.right)
	if rhs_flow == .Terminates do return INVALID_VALUE, .Terminates

	switch p in place {
	case ^Local_Place:
		emit(&ctx.b, new_store_local(p.local, rhs))
	case ^Property_Place:
		i := new(Set_Property_Instr)
		i.object = p.object
		i.field_index = p.field_index
		i.value = rhs
		emit(&ctx.b, i)
	case ^Index_Place:
		i := new(Set_Index_Instr)
		i.object = p.object
		i.index = p.index
		i.value = rhs
		emit(&ctx.b, i)
	}
	return INVALID_VALUE, .Continues
}

@(private = "file")
emit_binary :: proc(
	ctx: ^Lowering_Context,
	op: Bin_Op,
	lhs, rhs: Value_Id,
	result_type: ^Type,
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
	dst := new_value(&ctx.b, TY_BOOL)
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
	expr: Expr,
	e: ^Binary_Expr,
) -> (
	Value_Id,
	Flow_Result,
) {
	result_local := new_local(&ctx.b, INVALID_SYMBOL, "$logic", TY_BOOL)

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
	sv := new_value(&ctx.b, TY_BOOL)
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
	result := new_value(&ctx.b, TY_BOOL)
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
	expr: Expr,
	true_target, false_target: Block_Id,
) {
	if bin, ok := expr.(^Binary_Expr); ok {
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

// maybe_wrap_interface_cast — see maybe_emit_interface_cast, core/
// compiler.odin: если ctx.tc.interface_casts[expr] задан (struct_type,
// апкаст к интерфейсу нужен в этой позиции — join-точки если/выбор УЖЕ
// зарегистрировали его в тайпчекере для обеих ветвей, см. CLAUDE.md
// cross-module-interface-vtable-fix), строим vtable (метод-имя,
// Function_Id) через struct_type.methods + ctx.symbol_to_function — ТОТ
// ЖЕ Symbol_Id-based механизм, что compile-time vtable в сегодняшнем
// байткоде (не рантайм-скан). Вызывается на КАЖДОМ месте, где сегодняшний
// компилятор зовёт maybe_emit_interface_cast — все они внутри Call_Expr
// (Build_Variant/все call_infos.kind-ветки/foreign/актор-примитивы/
// финальный fallback) плюс голый Property_Expr-конструктор варианта.
@(private = "file")
maybe_wrap_interface_cast :: proc(ctx: ^Lowering_Context, expr: Expr, value: Value_Id) -> Value_Id {
	struct_type, needs_cast := ctx.tc.interface_casts[expr]
	if !needs_cast do return value

	bindings := make([dynamic]Interface_Method_Binding, 0, len(struct_type.methods))
	for method_name, method_sym in struct_type.methods {
		fn_id, found := ctx.symbol_to_function[method_sym]
		if !found {
			lower_unsupported("метод не найден в symbol_to_function при построении vtable интерфейса")
		}
		append(&bindings, Interface_Method_Binding{method_name = method_name, fn = fn_id})
	}

	dst := new_value(&ctx.b, nil)
	i := new(Cast_Interface_Instr)
	i.dst = dst
	i.src = value
	i.vtable = bindings[:]
	emit(&ctx.b, i)
	return dst
}

// lower_call_expr — тонкая обёртка над lower_call_expr_inner, применяющая
// maybe_wrap_interface_cast к результату РОВНО ОДИН РАЗ (вместо
// дублирования на каждом из ~15 return сегодняшнего case ^Call_Expr, см.
// список call site'ов maybe_emit_interface_cast в core/compiler.odin) —
// эквивалентно (interface_casts ключуется по САМОМУ Call_Expr-узлу,
// одному на все внутренние ветки).
lower_call_expr :: proc(ctx: ^Lowering_Context, expr: Expr, e: ^Call_Expr) -> (Value_Id, Flow_Result) {
	v, flow := lower_call_expr_inner(ctx, expr, e)
	if flow == .Terminates do return v, flow
	return maybe_wrap_interface_cast(ctx, expr, v), flow
}

@(private = "file")
lower_call_expr_inner :: proc(
	ctx: ^Lowering_Context,
	expr: Expr,
	e: ^Call_Expr,
) -> (
	Value_Id,
	Flow_Result,
) {
	result_type := ctx.tc.node_types[expr]

	// Дженерик-инстанциация (bounded traits) — ключ инстанциации уже
	// гарантированно зарегистрирован lower_monomorphize_program/lower_module
	// ДО этой точки (см. 2.3k). generic_call_callee_sym, НЕ node_symbols
	// [e.callee] — тот же мотив, что у monomorphize_program
	// (core/monomorphize.odin): cross-module вызов (module.f(...)) имеет
	// ^Property_Expr callee, не резолвящийся через node_symbols вообще.
	if concrete_types, ok := ctx.tc.generic_call_instantiations[expr]; ok {
		callee_sym := ctx.tc.generic_call_callee_sym[expr]
		key := build_instantiation_key(ctx.res.symbol_store, callee_sym, concrete_types)
		fn_id, found := ctx.module.generic_instantiations[key]
		if !found {
			lower_unsupported("инстанциация generic-функции не найдена")
		}
		fn_ref := emit_fn_ref(ctx, fn_id, nil)
		args, aflow := lower_call_args(ctx, e.args)
		if aflow == .Terminates do return INVALID_VALUE, .Terminates
		return emit_call_value(ctx, fn_ref, args, result_type), .Continues
	}

	if info, ok := ctx.tc.call_infos[expr]; ok {
		switch info.kind {
		case .Constructor_Variant:
			args, aflow := lower_call_args(ctx, e.args)
			if aflow == .Terminates do return INVALID_VALUE, .Terminates
			dst := new_value(&ctx.b, result_type)
			i := new(Build_Variant_Instr)
			i.dst = dst
			i.type_name = info.variant.owner_type.name
			i.variant_name = info.variant.owner_type.variants[info.variant.tag_index].name
			i.tag = info.variant.tag_index
			i.fields = args
			emit(&ctx.b, i)
			return dst, .Continues

		case .Builtin:
			args, aflow := lower_call_args(ctx, e.args)
			if aflow == .Terminates do return INVALID_VALUE, .Terminates
			if is_async_builtin_name(info.text_name) {
				return emit_call_builtin_async(ctx, info.text_name, args, result_type), .Continues
			}
			return emit_call_builtin(ctx, info.text_name, args, result_type), .Continues

		case .Method_Collection:
			prop_expr := e.callee.(^Property_Expr)
			obj, oflow := lower_expr(ctx, prop_expr.object)
			if oflow == .Terminates do return INVALID_VALUE, .Terminates
			args, aflow := lower_call_args(ctx, e.args)
			if aflow == .Terminates do return INVALID_VALUE, .Terminates
			receiver_type := ctx.tc.node_types[prop_expr.object]
			if is_async_stream_method(receiver_type, info.text_name) {
				dst := new_value(&ctx.b, result_type)
				i := new(Call_Async_Instr)
				i.dst = dst
				i.receiver = obj
				i.name = info.text_name
				i.args = args
				emit(&ctx.b, i)
				return dst, .Continues
			}
			return emit_call_method(ctx, obj, info.text_name, args, result_type), .Continues

		case .Method_Interface:
			prop_expr := e.callee.(^Property_Expr)
			obj, oflow := lower_expr(ctx, prop_expr.object)
			if oflow == .Terminates do return INVALID_VALUE, .Terminates
			args, aflow := lower_call_args(ctx, e.args)
			if aflow == .Terminates do return INVALID_VALUE, .Terminates
			dst := new_value(&ctx.b, result_type)
			i := new(Invoke_Interface_Instr)
			i.dst = dst
			i.receiver = obj
			i.method_name = info.text_name
			i.args = args
			emit(&ctx.b, i)
			return dst, .Continues

		case .Method_Struct:
			fn_id, found := ctx.symbol_to_function[info.symbol_ref]
			if !found {
				lower_unsupported("метод не найден в symbol_to_function")
			}
			fn_ref := emit_fn_ref(ctx, fn_id, nil)
			prop_expr := e.callee.(^Property_Expr)
			obj, oflow := lower_expr(ctx, prop_expr.object)
			if oflow == .Terminates do return INVALID_VALUE, .Terminates
			args, aflow := lower_call_args(ctx, e.args)
			if aflow == .Terminates do return INVALID_VALUE, .Terminates
			full_args := make([dynamic]Value_Id, 0, len(args) + 1)
			append(&full_args, obj)
			for a in args do append(&full_args, a)
			return emit_call_value(ctx, fn_ref, full_args[:], result_type), .Continues

		case .Constructor_Struct:
			args, aflow := lower_call_args(ctx, e.args)
			if aflow == .Terminates do return INVALID_VALUE, .Terminates
			dst := new_value(&ctx.b, result_type)
			i := new(New_Aggregate_Instr)
			i.dst = dst
			i.type_name = result_type.name
			i.elements = args
			emit(&ctx.b, i)
			return dst, .Continues

		case .Print_Value:
			fn_id, found := ctx.symbol_to_function[info.symbol_ref]
			if !found {
				lower_unsupported("метод вСтроку не найден в symbol_to_function")
			}
			fn_ref := emit_fn_ref(ctx, fn_id, nil)
			arg0, aflow := lower_expr(ctx, e.args[0])
			if aflow == .Terminates do return INVALID_VALUE, .Terminates
			str_v := emit_call_value(ctx, fn_ref, value_slice(arg0), TY_STRING)
			return emit_call_builtin(ctx, info.text_name, value_slice(str_v), result_type), .Continues

		case .Send_Copy:
			proc_v, pflow := lower_expr(ctx, e.args[0])
			if pflow == .Terminates do return INVALID_VALUE, .Terminates
			fn_id, found := ctx.symbol_to_function[info.symbol_ref]
			if !found {
				lower_unsupported("метод клонировать не найден в symbol_to_function")
			}
			fn_ref := emit_fn_ref(ctx, fn_id, nil)
			msg_v, mflow := lower_expr(ctx, e.args[1])
			if mflow == .Terminates do return INVALID_VALUE, .Terminates
			cloned_v := emit_call_value(ctx, fn_ref, value_slice(msg_v), ctx.tc.node_types[e.args[1]])
			return emit_call_builtin(ctx, "отправить_без_копии", value_slice(proc_v, cloned_v), result_type), .Continues
		}
	}

	if ident, ok := e.callee.(^Ident_Expr); ok {
		sym_id := ctx.res.node_symbols[e.callee]
		if sym_id != INVALID_SYMBOL {
			if foreign_decl, is_foreign := symbol_at(ctx.res.symbol_store, sym_id).decl.(^Foreign_Decl); is_foreign {
				ff := get_or_build_foreign_function(foreign_decl)
				args, aflow := lower_call_args(ctx, e.args)
				if aflow == .Terminates do return INVALID_VALUE, .Terminates
				dst := new_value(&ctx.b, result_type)
				i := new(Call_Foreign_Instr)
				i.dst = dst
				i.fn = ff
				i.args = args
				emit(&ctx.b, i)
				return dst, .Continues
			}
		}
		if sym_id != INVALID_SYMBOL && symbol_at(ctx.res.symbol_store, sym_id).kind == .Builtin {
			name := resolve_interned(ident.name)
			if name == "получить" {
				dst := new_value(&ctx.b, result_type)
				ri := new(Receive_Instr)
				ri.dst = dst
				emit(&ctx.b, ri)
				return dst, .Continues
			}
			if name == "получить_сигнал" {
				dst := new_value(&ctx.b, result_type)
				rsi := new(Receive_Signal_Instr)
				rsi.dst = dst
				emit(&ctx.b, rsi)
				return dst, .Continues
			}
			args, aflow := lower_call_args(ctx, e.args)
			if aflow == .Terminates do return INVALID_VALUE, .Terminates
			if is_async_builtin_name(name) {
				return emit_call_builtin_async(ctx, name, args, result_type), .Continues
			}
			return emit_call_builtin(ctx, name, args, result_type), .Continues
		}
	}

	// Статически известная top-level функция по голому идентификатору —
	// быстрый путь (Function_Id известен на этапе лоуринга, callee всё
	// равно эмитится ЗНАЧЕНИЕМ через emit_fn_ref — см. её докстринг).
	if callee_ident, ok := e.callee.(^Ident_Expr); ok {
		callee_sym := ctx.res.node_symbols[callee_ident]
		if fn_id, found := ctx.symbol_to_function[callee_sym]; found {
			fn_ref := emit_fn_ref(ctx, fn_id, nil)
			args, aflow := lower_call_args(ctx, e.args)
			if aflow == .Terminates do return INVALID_VALUE, .Terminates
			return emit_call_value(ctx, fn_ref, args, result_type), .Continues
		}
	}

	// Общий путь — callee лоурится как ОБЫЧНОЕ выражение (локаль,
	// содержащая замыкание/^Compiled_Function, результат другого вызова
	// и т.п.), вызывается через значение (Call_Value_Instr). Тот же
	// финальный fallback, что core/compiler.odin's case ^Call_Expr:
	// compile_expr(ctx, e.callee) + обычный .Call — рантайм-диспетчинг
	// ^Compiled_Function vs ^Closure_Value решает backend (Фаза 2.4), не
	// lowering.
	callee_v, cflow := lower_expr(ctx, e.callee)
	if cflow == .Terminates do return INVALID_VALUE, .Terminates
	args, aflow := lower_call_args(ctx, e.args)
	if aflow == .Terminates do return INVALID_VALUE, .Terminates
	i := new(Call_Value_Instr)
	i.callee = callee_v
	i.args = args
	if result_type != nil && prune_type(result_type) != TY_VOID {
		dst := new_value(&ctx.b, result_type)
		i.dst = dst
		emit(&ctx.b, i)
		return dst, .Continues
	}
	emit(&ctx.b, i)
	return INVALID_VALUE, .Continues
}

// value_slice — heap-аллоцированный []Value_Id из 1-2 значений. НЕ
// заменять на инлайн []Value_Id{...} compound-литерал: такой литерал
// использует память СТЕКА текущего кадра (тот же класс бага, что &Type{
// ...} для указателя — см. историю этого файла, Receive_Instr) — если
// результат сохраняется в поле инструкции, переживающей возврат из
// текущей функции (i.args = ...), сырой стековый слайс станет мусором
// уже к моменту, когда backend/print/validate его прочитают. Найдено
// эмпирически (test_mir_for_in_iterator_protocol — call fn_N(v0) вместо
// call fn_N(v5), классический stack-reuse симптом).
@(private = "file")
value_slice :: proc(vs: ..Value_Id) -> []Value_Id {
	out := make([]Value_Id, len(vs))
	copy(out, vs)
	return out
}

@(private = "file")
lower_call_args :: proc(ctx: ^Lowering_Context, exprs: [dynamic]Expr) -> ([]Value_Id, Flow_Result) {
	args := make([dynamic]Value_Id, 0, len(exprs))
	for a in exprs {
		v, flow := lower_expr(ctx, a)
		if flow == .Terminates do return nil, .Terminates
		append(&args, v)
	}
	return args[:], .Continues
}

// emit_fn_ref — Function_Ref_Instr для статически известного Function_Id.
// ВАЖНО: должен эмититься ДО лоуринга receiver/аргументов вызова, НЕ
// после — core/vm.odin's .Call/.Spawn читают callee СО СТЕКА строго ПОД
// всеми аргументами (`callee_index := len(vm.stack) - 1 - arg_count`,
// см. case .Call), а backend (2.4) реплеит инструкции блока в их
// естественном MIR-порядке без реордеринга — если бы Function_Ref шёл
// ПОСЛЕ аргументов, callee оказался бы НАД ними на стеке, а не под.
// Тот же порядок, что core/compiler.odin уже соблюдает сегодня
// (emit_constant(fn_ptr) ПЕРЕД compile_expr(receiver)/args).
@(private = "file")
emit_fn_ref :: proc(ctx: ^Lowering_Context, fn_id: Function_Id, fn_type: ^Type) -> Value_Id {
	v := new_value(&ctx.b, fn_type)
	i := new(Function_Ref_Instr)
	i.dst = v
	i.fn = fn_id
	emit(&ctx.b, i)
	return v
}

// emit_call_value — Call_Value_Instr через УЖЕ вычисленный callee
// (обычно свежий Function_Ref_Instr, эмитированный emit_fn_ref ДО
// аргументов — см. её докстринг).
@(private = "file")
emit_call_value :: proc(ctx: ^Lowering_Context, callee: Value_Id, args: []Value_Id, result_type: ^Type) -> Value_Id {
	i := new(Call_Value_Instr)
	i.callee = callee
	i.args = args
	if result_type != nil && prune_type(result_type) != TY_VOID {
		dst := new_value(&ctx.b, result_type)
		i.dst = dst
		emit(&ctx.b, i)
		return dst
	}
	emit(&ctx.b, i)
	return INVALID_VALUE
}

@(private = "file")
emit_call_builtin :: proc(ctx: ^Lowering_Context, name: string, args: []Value_Id, result_type: ^Type) -> Value_Id {
	i := new(Call_Builtin_Instr)
	i.name = name
	i.args = args
	if result_type != nil && prune_type(result_type) != TY_VOID {
		dst := new_value(&ctx.b, result_type)
		i.dst = dst
		emit(&ctx.b, i)
		return dst
	}
	emit(&ctx.b, i)
	return INVALID_VALUE
}

@(private = "file")
emit_call_builtin_async :: proc(ctx: ^Lowering_Context, name: string, args: []Value_Id, result_type: ^Type) -> Value_Id {
	i := new(Call_Async_Instr)
	i.receiver = nil
	i.name = name
	i.args = args
	if result_type != nil && prune_type(result_type) != TY_VOID {
		dst := new_value(&ctx.b, result_type)
		i.dst = dst
		emit(&ctx.b, i)
		return dst
	}
	emit(&ctx.b, i)
	return INVALID_VALUE
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
	expr: Expr,
	e: ^If_Expr,
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
		result_local = new_local(&ctx.b, INVALID_SYMBOL, "$if", result_type)
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
lower_while_expr :: proc(ctx: ^Lowering_Context, e: ^While_Expr) {
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

// lower_for_in_stmt — две формы по ctx.tc.for_in_infos (см. core/
// compiler.odin's compile_for_in_stmt, тот же приём, что здесь: For_In_
// Stmt не десахарен парсером, форма решается типизатором один раз).
//
// Fast_Array реализована полностью. Iterator_Protocol нуждается в
// разрешении Symbol_Id метода следующий() в Function_Id ЧЕРЕЗ ТОТ ЖЕ
// механизм, что обычные методы структур (2.3e/2.3h ещё не реализованы на
// момент написания этой функции) — временная панике-заглушка, дозаписать
// сразу после 2.3h.
@(private = "file")
lower_for_in_stmt :: proc(ctx: ^Lowering_Context, stmt: Stmt, s: ^For_In_Stmt) -> Flow_Result {
	info, has_info := ctx.tc.for_in_infos[stmt]
	if !has_info {
		lower_unsupported("for_in_infos отсутствует для for-in")
	}

	names_syms := ctx.res.for_in_names_syms[stmt]

	iterable_v, iflow := lower_expr(ctx, s.iterable)
	if iflow == .Terminates do return .Terminates
	iter_local := new_local(&ctx.b, INVALID_SYMBOL, "$for_iter", ctx.tc.node_types[s.iterable])
	emit(&ctx.b, new_store_local(iter_local, iterable_v))

	#partial switch info.kind {
	case .Fast_Array:
		idx_local := new_local(&ctx.b, INVALID_SYMBOL, "$for_idx", TY_NUM)
		neg1 := emit_const_number(ctx, -1)
		emit(&ctx.b, new_store_local(idx_local, neg1))

		header_block := new_block(&ctx.b)
		body_block := new_block(&ctx.b)
		exit_block := new_block(&ctx.b)
		terminate(&ctx.b, new_jump_term(header_block))

		set_current_block(&ctx.b, header_block)
		idx_v := new_value(&ctx.b, TY_NUM)
		emit(&ctx.b, new_load_local(idx_v, idx_local))
		one_v := emit_const_number(ctx, 1)
		next_idx_v := emit_binary(ctx, .Add, idx_v, one_v, TY_NUM)
		emit(&ctx.b, new_store_local(idx_local, next_idx_v))

		idx_v2 := new_value(&ctx.b, TY_NUM)
		emit(&ctx.b, new_load_local(idx_v2, idx_local))
		iter_v_len := new_value(&ctx.b, ctx.tc.node_types[s.iterable])
		emit(&ctx.b, new_load_local(iter_v_len, iter_local))
		len_v := emit_call_method(ctx, iter_v_len, "длина", nil, TY_NUM)
		cont_v := emit_compare(ctx, .NotEqual, idx_v2, len_v)
		terminate(&ctx.b, new_branch_term(cont_v, body_block, exit_block))

		set_current_block(&ctx.b, body_block)
		iter_v_idx := new_value(&ctx.b, ctx.tc.node_types[s.iterable])
		emit(&ctx.b, new_load_local(iter_v_idx, iter_local))
		idx_v3 := new_value(&ctx.b, TY_NUM)
		emit(&ctx.b, new_load_local(idx_v3, idx_local))
		elem_v := new_value(&ctx.b, nil)
		gi := new(Get_Index_Instr)
		gi.dst = elem_v
		gi.object = iter_v_idx
		gi.index = idx_v3
		emit(&ctx.b, gi)
		lower_for_in_bind_names(ctx, names_syms, elem_v)

		append(&ctx.loops, Loop_Targets{continue_target = header_block, break_target = exit_block})
		_, body_flow := lower_block(ctx, s.body, false)
		pop(&ctx.loops)
		if body_flow == .Continues {
			terminate(&ctx.b, new_jump_term(header_block))
		}

		set_current_block(&ctx.b, exit_block)
		return .Continues

	case .Iterator_Protocol:
		// `для x в итерируемое цикл ... конец` — .следующий() резолвится
		// СТАТИЧЕСКИ через info.next_method_sym (тот же Symbol_Id-путь, что
		// Method_Struct, НЕ Call_Method_Instr с именем — см. core/compiler.
		// odin's compile_for_in_stmt, Iterator_Protocol-ветка).
		next_fn_id, found := ctx.symbol_to_function[info.next_method_sym]
		if !found {
			lower_unsupported("метод следующий не найден в symbol_to_function")
		}

		header_block := new_block(&ctx.b)
		body_block := new_block(&ctx.b)
		exit_block := new_block(&ctx.b)
		terminate(&ctx.b, new_jump_term(header_block))

		set_current_block(&ctx.b, header_block)
		next_result_type := ctx.module.functions[int(next_fn_id)].result_type
		fn_ref := emit_fn_ref(ctx, next_fn_id, nil)
		iter_v := new_value(&ctx.b, ctx.tc.node_types[s.iterable])
		emit(&ctx.b, new_load_local(iter_v, iter_local))
		opt_v := emit_call_value(ctx, fn_ref, value_slice(iter_v), next_result_type)
		subject_local := new_local(&ctx.b, INVALID_SYMBOL, "$for_subject", nil)
		emit(&ctx.b, new_store_local(subject_local, opt_v))

		tag_subj := new_value(&ctx.b, nil)
		emit(&ctx.b, new_load_local(tag_subj, subject_local))
		tag_ok := new_value(&ctx.b, TY_BOOL)
		mt := new(Match_Tag_Instr)
		mt.dst = tag_ok
		mt.subject = tag_subj
		mt.tag = 1 // Есть — см. prelude.odin, тот же тег, что compile_for_in_stmt использует напрямую
		emit(&ctx.b, mt)
		terminate(&ctx.b, new_branch_term(tag_ok, body_block, exit_block))

		set_current_block(&ctx.b, body_block)
		field_subj := new_value(&ctx.b, nil)
		emit(&ctx.b, new_load_local(field_subj, subject_local))
		elem_v := new_value(&ctx.b, nil)
		gvf := new(Get_Variant_Field_Instr)
		gvf.dst = elem_v
		gvf.subject = field_subj
		gvf.field_index = 0
		emit(&ctx.b, gvf)
		lower_for_in_bind_names(ctx, names_syms, elem_v)

		append(&ctx.loops, Loop_Targets{continue_target = header_block, break_target = exit_block})
		_, body_flow := lower_block(ctx, s.body, false)
		pop(&ctx.loops)
		if body_flow == .Continues {
			terminate(&ctx.b, new_jump_term(header_block))
		}

		set_current_block(&ctx.b, exit_block)
		return .Continues
	}
	lower_unsupported("неизвестная форма for-in")
}

// lower_for_in_bind_names — деструктуризация элемента цикла в 1+ имён
// (для (a, b) в ...) — тот же приём, что 2.3b (пер (a, b) = ...): при
// >1 имени элемент материализуется в Mir_Local (читается многократно —
// обязано идти через Local, single-use инвариант), Get_Property по
// позиции на каждое имя.
@(private = "file")
lower_for_in_bind_names :: proc(ctx: ^Lowering_Context, names_syms: [dynamic]Symbol_Id, elem_v: Value_Id) {
	if len(names_syms) == 1 {
		binder := new_local(&ctx.b, names_syms[0], "", nil)
		ctx.symbol_to_local[names_syms[0]] = binder
		emit(&ctx.b, new_store_local(binder, elem_v))
		return
	}
	elem_local := new_local(&ctx.b, INVALID_SYMBOL, "$for_elem", nil)
	emit(&ctx.b, new_store_local(elem_local, elem_v))
	for sym, i in names_syms {
		loaded := new_value(&ctx.b, nil)
		emit(&ctx.b, new_load_local(loaded, elem_local))
		field_v := new_value(&ctx.b, nil)
		gp := new(Get_Property_Instr)
		gp.dst = field_v
		gp.object = loaded
		gp.field_index = i
		emit(&ctx.b, gp)
		binder := new_local(&ctx.b, sym, "", nil)
		ctx.symbol_to_local[sym] = binder
		emit(&ctx.b, new_store_local(binder, field_v))
	}
}

// emit_call_method — Call_Method_Instr (динамический вызов по имени,
// как Invoke_Collection в сегодняшнем байткоде — "длина"/"получить"/
// т.п. на Массив/Соответствие/Строка) с ноль-или-более аргументами.
@(private = "file")
emit_call_method :: proc(ctx: ^Lowering_Context, receiver: Value_Id, name: string, args: []Value_Id, result_type: ^Type) -> Value_Id {
	dst := new_value(&ctx.b, result_type)
	i := new(Call_Method_Instr)
	i.dst = dst
	i.receiver = receiver
	i.name = name
	i.args = args
	emit(&ctx.b, i)
	return dst
}

// lower_match_expr — выбор/ADT (см. core/compiler.odin's compile_match_
// expr/compile_pattern, полностью перечитаны для этой реализации).
// Subject лоурится ОДИН раз в синтетический Mir_Local (читается многократно
// — по разу на арм/под-шаблон, обязано идти через Local, single-use
// инвариант). Армы образуют цепочку fail-блоков (арм N+1 — это fail-блок
// арма N, тот же приём, что сегодняшний fail_jumps-список), последний
// fail-блок — Unreachable_Term (Match_Fail).
@(private = "file")
lower_match_expr :: proc(ctx: ^Lowering_Context, expr: Expr, m: ^Match_Expr) -> (Value_Id, Flow_Result) {
	arm_infos, has_infos := ctx.tc.match_arm_infos[m]
	if !has_infos {
		lower_unsupported("match_arm_infos отсутствует для выбора")
	}
	want_value := prune_type(ctx.tc.node_types[expr]) != TY_VOID

	subject_v, sflow := lower_expr(ctx, m.subject)
	if sflow == .Terminates do return INVALID_VALUE, .Terminates
	subject_local := new_local(&ctx.b, INVALID_SYMBOL, "$match_subject", ctx.tc.node_types[m.subject])
	emit(&ctx.b, new_store_local(subject_local, subject_v))

	result_type := ctx.tc.node_types[expr]
	result_local := INVALID_LOCAL
	if want_value {
		result_local = new_local(&ctx.b, INVALID_SYMBOL, "$match_result", result_type)
	}

	merge_block := new_block(&ctx.b)
	any_arm_continues := false

	for arm, arm_idx in m.arms {
		pi := arm_infos[arm_idx]
		fail_block := new_block(&ctx.b)

		lower_pattern(ctx, &pi, subject_local, fail_block)

		arm_val, arm_flow := lower_block(ctx, arm.body, want_value)
		if arm_flow == .Continues {
			any_arm_continues = true
			if want_value do emit(&ctx.b, new_store_local(result_local, arm_val))
			terminate(&ctx.b, new_jump_term(merge_block))
		}

		set_current_block(&ctx.b, fail_block)
	}

	// Последний fail-блок = ни один арм не подошёл — Match_Fail сегодня
	// (runtime-паника при "недостижимом" промахе выбора).
	terminate(&ctx.b, new_unreachable_term("выбор: ни один арм не подошёл (Match_Fail)"))

	if !any_arm_continues {
		set_current_block(&ctx.b, merge_block)
		terminate(&ctx.b, new_unreachable_term("выбор: ни один арм не завершается нормально"))
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

// lower_pattern — один Pattern_Info (уже резолвен тайпчекером — kind/tag_
// index/binder_sym/sub_patterns готовы, AST Pattern-узел сюда не нужен).
// value_local — locals-ячейка с проверяемым значением (subject ИЛИ поле
// родительского конструктора — при .Constructor/.Struct_Constructor
// рекурсия материализует КАЖДОЕ под-поле в СВОЙ Mir_Local перед
// рекурсивным вызовом, single-use инвариант). fail_block — куда прыгать
// при несовпадении.
@(private = "file")
lower_pattern :: proc(ctx: ^Lowering_Context, pi: ^Pattern_Info, value_local: Local_Id, fail_block: Block_Id) {
	switch pi.kind {
	case .Wildcard:
	// без условия — совпадает всегда

	case .Literal:
		v := new_value(&ctx.b, nil)
		emit(&ctx.b, new_load_local(v, value_local))
		lit_v, lflow := lower_expr(ctx, pi.literal_expr)
		if lflow == .Terminates do return
		eq := emit_compare(ctx, .Equal, v, lit_v)
		next_block := new_block(&ctx.b)
		terminate(&ctx.b, new_branch_term(eq, next_block, fail_block))
		set_current_block(&ctx.b, next_block)

	case .Binder:
		v := new_value(&ctx.b, nil)
		emit(&ctx.b, new_load_local(v, value_local))
		binder_local := new_local(&ctx.b, pi.binder_sym, "", nil)
		ctx.symbol_to_local[pi.binder_sym] = binder_local
		emit(&ctx.b, new_store_local(binder_local, v))

	case .Constructor:
		v := new_value(&ctx.b, nil)
		emit(&ctx.b, new_load_local(v, value_local))
		tag_ok := new_value(&ctx.b, TY_BOOL)
		mt := new(Match_Tag_Instr)
		mt.dst = tag_ok
		mt.subject = v
		mt.tag = pi.tag_index
		emit(&ctx.b, mt)
		next_block := new_block(&ctx.b)
		terminate(&ctx.b, new_branch_term(tag_ok, next_block, fail_block))
		set_current_block(&ctx.b, next_block)

		for &sub, field_idx in pi.sub_patterns {
			if sub.kind == .Wildcard do continue
			subj_v := new_value(&ctx.b, nil)
			emit(&ctx.b, new_load_local(subj_v, value_local))
			field_v := new_value(&ctx.b, nil)
			gvf := new(Get_Variant_Field_Instr)
			gvf.dst = field_v
			gvf.subject = subj_v
			gvf.field_index = field_idx
			emit(&ctx.b, gvf)
			field_local := new_local(&ctx.b, INVALID_SYMBOL, "$match_field", nil)
			emit(&ctx.b, new_store_local(field_local, field_v))
			// Тот же СКВОЗНОЙ fail_block верхнего уровня передаётся КАЖДОМУ
			// под-паттерну — на несовпадение любого поля арм проваливается
			// в тот же fail-блок (следующий арм), тот же принцип, что
			// сегодняшний общий fail_jumps-список в compile_pattern.
			lower_pattern(ctx, &sub, field_local, fail_block)
		}

	case .Struct_Constructor:
		for &sub, field_idx in pi.sub_patterns {
			if sub.kind == .Wildcard do continue
			obj_v := new_value(&ctx.b, nil)
			emit(&ctx.b, new_load_local(obj_v, value_local))
			field_v := new_value(&ctx.b, nil)
			gp := new(Get_Property_Instr)
			gp.dst = field_v
			gp.object = obj_v
			gp.field_index = field_idx
			emit(&ctx.b, gp)
			field_local := new_local(&ctx.b, INVALID_SYMBOL, "$match_field", nil)
			emit(&ctx.b, new_store_local(field_local, field_v))
			lower_pattern(ctx, &sub, field_local, fail_block)
		}
	}
}

// lower_symbol_value_ref — читает ТЕКУЩЕЕ значение символа: локаль,
// захват (если лоурится тело лямбды) или ссылка на функцию по имени —
// тот же порядок приоритета, что compile_symbol_value_ref сегодня
// (core/compiler.odin). Используется и для голых Ident_Expr, и для
// снимка захватываемых значений ПЕРЕД Build_Closure (2.3g).
@(private = "file")
lower_symbol_value_ref :: proc(ctx: ^Lowering_Context, sym: Symbol_Id, type: ^Type) -> Value_Id {
	if local, ok := ctx.symbol_to_local[sym]; ok {
		v := new_value(&ctx.b, current_function(&ctx.b).locals[int(local)].type)
		emit(&ctx.b, new_load_local(v, local))
		return v
	}
	if idx, ok := ctx.symbol_to_capture[sym]; ok {
		v := new_value(&ctx.b, type)
		lc := new(Load_Captured_Instr)
		lc.dst = v
		lc.index = idx
		emit(&ctx.b, lc)
		return v
	}
	if fn_id, ok := ctx.symbol_to_function[sym]; ok {
		v := new_value(&ctx.b, type)
		fr := new(Function_Ref_Instr)
		fr.dst = v
		fr.fn = fn_id
		emit(&ctx.b, fr)
		return v
	}
	lower_unsupported("идентификатор не резолвится (builtin/модуль/константа — Фаза 3+)")
}

// lower_lambda_expr — see core/compiler.odin's case ^Lambda_Expr. Имя
// строится тем же способом (module_prefix::lambda_N или lambda_N),
// Mir_Function регистрируется ЛЕНИВО (безопасно благодаря 2.1 — Mir_
// Builder больше не держит сырой ^Mir_Function через границу append).
// Захваты — снимок ЗНАЧЕНИЙ на момент построения (не ячейки), читаются
// во ВНЕШНЕМ контексте через lower_symbol_value_ref ДО создания тела
// лямбды. Тело лоурится ОТДЕЛЬНЫМ Lowering_Context с своим symbol_to_
// capture (индекс = позиция в ctx.res.lambda_captures[expr]).
@(private = "file")
lower_lambda_expr :: proc(ctx: ^Lowering_Context, expr: Expr, e: ^Lambda_Expr) -> (Value_Id, Flow_Result) {
	lambda_type := ctx.tc.node_types[expr]
	result_type := lambda_type.return_type

	name: string
	if ctx.res.current_module != nil && len(ctx.res.current_module.path) > 0 {
		name = fmt.tprintf("%s::lambda_%d", ctx.res.current_module.path, len(ctx.module.functions))
	} else {
		name = fmt.tprintf("lambda_%d", len(ctx.module.functions))
	}
	fn_id := new_function(ctx.module, name, INVALID_SYMBOL, result_type, e.span)

	captures := ctx.res.lambda_captures[expr]
	captured_values := make([dynamic]Value_Id, 0, len(captures))
	for sym in captures {
		v := lower_symbol_value_ref(ctx, sym, ctx.res.symbol_types[sym])
		append(&captured_values, v)
	}

	dst := new_value(&ctx.b, lambda_type)
	if len(captures) == 0 {
		fr := new(Function_Ref_Instr)
		fr.dst = dst
		fr.fn = fn_id
		emit(&ctx.b, fr)
	} else {
		bc := new(Build_Closure_Instr)
		bc.dst = dst
		bc.fn = fn_id
		bc.captured = captured_values[:]
		emit(&ctx.b, bc)
	}

	lower_lambda_body(ctx.res, ctx.tc, ctx.module, fn_id, expr, e, captures, ctx.symbol_to_function)

	return dst, .Continues
}

@(private = "file")
lower_lambda_body :: proc(
	res: ^Resolver_Ctx,
	tc: ^Type_Ctx,
	module: ^Mir_Module,
	fn_id: Function_Id,
	expr: Expr,
	e: ^Lambda_Expr,
	captures: [dynamic]Symbol_Id,
	symbol_to_function: map[Symbol_Id]Function_Id,
) {
	inner := Lowering_Context {
		res                = res,
		tc                 = tc,
		module             = module,
		symbol_to_local    = make(map[Symbol_Id]Local_Id),
		symbol_to_function = symbol_to_function,
		symbol_to_capture  = make(map[Symbol_Id]int),
		loops              = make([dynamic]Loop_Targets),
	}
	inner.b = begin_function(module, fn_id)

	for sym, i in captures {
		inner.symbol_to_capture[sym] = i
	}

	args_syms, has_args := res.lambda_args[expr]
	param_locals := make([dynamic]Local_Id, 0, len(e.args))
	if has_args {
		for sym, i in args_syms {
			pt := res.symbol_types[sym]
			name := i < len(e.args) ? e.args[i].name : ""
			local := new_local(&inner.b, sym, name, pt)
			inner.symbol_to_local[sym] = local
			append(&param_locals, local)
		}
	}
	current_function(&inner.b).parameters = param_locals[:]

	want_value := prune_type_or_self(current_function(&inner.b).result_type) != TY_VOID
	result, flow := lower_block(&inner, e.body, want_value)
	if flow == .Continues {
		if want_value {
			terminate(&inner.b, new_return_term(result))
		} else {
			terminate(&inner.b, new_return_term(INVALID_VALUE))
		}
	}
}
