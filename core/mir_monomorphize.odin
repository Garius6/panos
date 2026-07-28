package core

// MIR-аналог core/monomorphize.odin — bounded generic-функции клонируются
// под каждую конкретную комбинацию type-параметров, встреченную на call
// site'ах (tc.generic_call_instantiations), клон прогоняется через
// ОБЫЧНЫЙ resolve_function_body/typecheck (тот же путь, что и
// monomorphize_one — ни резолвер, ни тайпчекер не знают о bounded traits
// вообще), а вместо compile_block/emit_opcode тело лоурится в MIR через
// уже существующий lower_function_body — тот принимает res/tc/module/
// fn_id/params/body как параметры, так что клон с ПОДМЕНЁННЫМ decl_res
// (cross-module case, см. monomorphize_one) лоурится тем же кодом, что и
// обычная top-level функция.
//
// Результат регистрируется в module.generic_instantiations[key] (не в
// symbol_to_function — у клона нет собственного стабильного Symbol_Id,
// на call site'ах он ищется по строковому ключу, см. lower_call_expr_
// inner) под тем же build_instantiation_key, что и byte-код путь.

lower_monomorphize_one :: proc(
	res: ^Resolver_Ctx,
	tc: ^Type_Ctx,
	module: ^Mir_Module,
	symbol_to_function: ^map[Symbol_Id]Function_Id,
	fn_decl: ^Function_Decl,
	callee_sym: Symbol_Id,
	concrete_types: [dynamic]^Type,
	key: string,
) {
	clone := clone_function_decl(fn_decl)
	module_of_callee := symbol_at(res.symbol_store, callee_sym).module

	// Cross-module bounded generic (см. monomorphize_one — тот же мотив
	// дословно): резолвить/типизировать клон нужно РЕЗОЛВЕРОМ модуля,
	// где объявлена fn_decl, иначе имена, живущие только в её модуле, не
	// найдутся через global_scope вызывающего модуля.
	decl_res := res
	if res.module_graph != nil {
		if found, ok := res.module_graph.module_resolvers[module_of_callee]; ok {
			decl_res = found
		}
		decl_res.symbol_types = res.module_graph.symbol_types
	}

	resolve_function_body(decl_res, module_of_callee, Decls(clone), clone.args[:], clone.body)

	subst := make(map[string]^Type)
	for name, i in fn_decl.type_params do subst[name] = concrete_types[i]
	prev_params := tc.current_type_params
	prev_res := tc.res
	tc.current_type_params = subst
	tc.res = decl_res

	func_type := function_type_from_decl(tc, clone)
	bind_function_args(tc, clone, func_type)
	check_function_body(tc, clone.span, clone.body, func_type.return_type)

	tc.current_type_params = prev_params
	tc.res = prev_res

	fn_id := new_function(module, key, INVALID_SYMBOL, func_type.return_type, clone.span)
	module.generic_instantiations[key] = fn_id

	// decl_res, НЕ res — resolve_function_body выше писала func_args
	// клона В decl_res.func_args (per-Resolver_Ctx карта), тот же мотив,
	// что у comp.res в monomorphize_one.
	lower_function_body(decl_res, tc, module, fn_id, Decls(clone), clone.args, clone.body, symbol_to_function^)
}

// Fixed-point driver — та же структура, что monomorphize_program
// (снимок необработанных ключей на каждой итерации: typecheck клона
// сам добавляет новые записи в tc.generic_call_instantiations при
// рекурсивном generic-вызове, обход и мутация одной map одновременно
// была бы undefined behavior).
lower_monomorphize_program :: proc(
	res: ^Resolver_Ctx,
	tc: ^Type_Ctx,
	module: ^Mir_Module,
	symbol_to_function: ^map[Symbol_Id]Function_Id,
) {
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
			_, is_call := call_expr.(^Call_Expr)
			if !is_call do continue
			callee_sym := tc.generic_call_callee_sym[call_expr]
			fn_decl, has_decl := symbol_at(tc.res.symbol_store, callee_sym).decl.(^Function_Decl)
			if !has_decl do continue
			key := build_instantiation_key(tc.res.symbol_store, callee_sym, concrete_types)
			if processed[key] do continue
			append(&pending, Pending{fn_decl, callee_sym, concrete_types, key})
		}
		if len(pending) == 0 do break
		for p in pending {
			if processed[p.key] do continue
			lower_monomorphize_one(res, tc, module, symbol_to_function, p.fn_decl, p.callee_sym, p.concrete_types, p.key)
			processed[p.key] = true
		}
	}
}
