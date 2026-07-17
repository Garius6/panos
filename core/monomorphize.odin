package core

import "core:strings"

// Bounded traits: тело bounded generic-функции (`type_param_bounds`
// непусто) типизируется абстрактно ОДИН раз (см. type_cheker.odin —
// как и любой другой generic), но НИКОГДА не компилируется напрямую —
// оно клонируется под каждую конкретную комбинацию type-параметров,
// встреченную на call site'ах (ctx.generic_call_instantiations,
// заполняется infer_bounded_generic_call), и каждый клон проходит
// ПОЛНОСТЬЮ обычный resolve→typecheck→compile (см. monomorphize_one) —
// ни один из этих трёх пайплайнов не знает о bounded traits вообще,
// клон с T, зарезолвленным в конкретный тип, неотличим от обычной
// non-generic функции.

// "имя_функции$Тип1,Тип2" — человекочитаемый registry-ключ (в отличие
// от generic_instance_cache, который канонизирует ^Type ПОИНТЕРЫ, не
// нужен человекочитаемым — этот ключ реальный ключ ctx.registry, читает
// его и compiler.odin на call site).
build_instantiation_key :: proc(store: ^Symbol_Store, sym: Symbol_Id, concrete_types: [dynamic]^Type) -> string {
	b := strings.builder_make()
	strings.write_string(&b, symbol_registry_key(store, sym))
	for t, i in concrete_types {
		strings.write_string(&b, i == 0 ? "$" : ",")
		strings.write_string(&b, prune_type(t).name)
	}
	return strings.to_string(b)
}

// Клонирует тело fn_decl, резолвит клон в scope ТОГО ЖЕ модуля, что и
// оригинал, типизирует с T, подставленным в concrete_types НАПРЯМУЮ
// (ctx.current_type_params = subst — resolve_type_node's Type_Ident-кейс
// проверяет current_type_params ПЕРВЫМ, до глобальных типов — T
// резолвится в конкретный тип без единого нового InferVar), компилирует
// и кладёт под key в registry. Typecheck клона может обнаружить НОВЫЕ
// записи в ctx.generic_call_instantiations (рекурсивный generic-вызов
// внутри тела) — их подбирает monomorphize_program на следующей
// итерации fixed-point цикла.
monomorphize_one :: proc(
	res: ^Resolver_Ctx,
	tc: ^Type_Ctx,
	registry: ^map[string]^Compiled_Function,
	fn_decl: ^Function_Decl,
	callee_sym: Symbol_Id,
	concrete_types: [dynamic]^Type,
	key: string,
) {
	clone := clone_function_decl(fn_decl)
	module := symbol_at(res.symbol_store, callee_sym).module

	resolve_function_body(res, module, Decls(clone), clone.args[:], clone.body)

	subst := make(map[string]^Type)
	for name, i in fn_decl.type_params do subst[name] = concrete_types[i]
	prev := tc.current_type_params
	tc.current_type_params = subst

	func_type := function_type_from_decl(tc, clone)
	bind_function_args(tc, clone, func_type)
	check_function_body(tc, clone.span, clone.body, func_type.return_type)

	tc.current_type_params = prev

	fn := new(Compiled_Function)
	fn.name = key
	fn.returns_value = prune_type(func_type.return_type) != TY_VOID
	fn.instructions = make([dynamic]u8)
	fn.constants = make([dynamic]Value)
	registry^[key] = fn

	comp := Compiler {
		registry         = registry,
		current_function = fn,
		tc               = tc,
		res              = res,
		locals           = make([dynamic]Local),
	}
	if args_syms, ok := res.func_args[Decls(clone)]; ok {
		for s in args_syms do append(&comp.locals, Local{symbol = s, depth = 0})
	}
	comp.current_function.frame_size = len(comp.locals)
	compile_block(&comp, clone.body, true)
	emit_opcode(&comp, .Return)
}

// Fixed-point driver — вызывается ПЕРЕД обычными pass 1/2 compile_program
// (registry должен УЖЕ содержать все нужные инстанциации к моменту, когда
// обычная компиляция дойдёт до call site'ов bounded generic-функций,
// см. compiler.odin). Снимает СНИМОК необработанных ключей на каждой
// итерации вместо мутации map'а во время обхода — typecheck клона
// (monomorphize_one) сам добавляет НОВЫЕ записи в tc.generic_call_
// instantiations (рекурсия), обход и мутация одной и той же map
// одновременно была бы undefined behavior.
monomorphize_program :: proc(res: ^Resolver_Ctx, tc: ^Type_Ctx, registry: ^map[string]^Compiled_Function) {
	Pending :: struct {
		fn_decl:        ^Function_Decl,
		callee_sym:     Symbol_Id,
		concrete_types: [dynamic]^Type,
		key:            string,
	}

	processed := make(map[string]bool)
	for {
		pending := make([dynamic]Pending)
		for call_expr, concrete_types in tc.generic_call_instantiations {
			call, is_call := call_expr.(^Call_Expr)
			if !is_call do continue
			callee_sym := tc.res.node_symbols[call.callee]
			fn_decl, has_decl := tc.symbol_to_func_decl[callee_sym]
			if !has_decl do continue
			key := build_instantiation_key(tc.res.symbol_store, callee_sym, concrete_types)
			if processed[key] do continue
			append(&pending, Pending{fn_decl, callee_sym, concrete_types, key})
		}
		if len(pending) == 0 do break
		for p in pending {
			if processed[p.key] do continue // могли обработать раньше в этом же батче (несколько call site'ов, одна инстанциация)
			monomorphize_one(res, tc, registry, p.fn_decl, p.callee_sym, p.concrete_types, p.key)
			processed[p.key] = true
		}
	}
}
