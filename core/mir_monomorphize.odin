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
//
// ДВЕ ФАЗЫ, НЕ ОДНА (реальный баг, найденный эмпирически — не по чтению
// кода — при добавлении методов, Фаза 2.3, см. lower_monomorphize_program
// ниже): typecheck клона (check_function_body) может ОБНАРУЖИТЬ НОВУЮ,
// ещё не смонофирмизированную инстанциацию (напр. bounded-generic функция
// `разобрать_в[T](это: T, ...) ... рез.причина() ...` — check_function_
// body клона разобрать_в[Сервер] типизирует rez.причина() и ВПЕРВЫЕ
// корректно записывает причина$Значение,Ошибка — при АБСТРАКТНОМ проходе
// исходного тела эта запись пропускалась ctx.in_abstract_generic_body,
// см. record_generic_method_instantiation). Если сразу после typecheck
// клона (внутри ТОЙ ЖЕ функции) вызвать lower_function_body — она дойдёт
// до rez.причина() и попытается найти УЖЕ ГОТОВЫЙ Function_Id для
// причина$Значение,Ошибка в module.generic_instantiations — но та
// инстанциация ТОЛЬКО ЧТО обнаружена, ещё не обработана (обработка
// произошла бы на СЛЕДУЮЩЕЙ итерации fixed-point'а — СЛИШКОМ ПОЗДНО,
// lower_function_body клона разобрать_в[Сервер] УЖЕ выполняется прямо
// сейчас) — паника "инстанциация ... не найдена". Поэтому: сначала
// ПОЛНЫЙ fixed-point ТОЛЬКО typecheck+регистрация Function_Id (без
// lower_function_body) для ВСЕХ клонов, рекурсивно обнаруженных, ЛЮБОЙ
// глубины — и ТОЛЬКО ПОСЛЕ ЭТОГО, когда каждый Function_Id уже в module.
// generic_instantiations, второй проход лоурит ТЕЛА всех собранных
// клонов. Так гарантируется, что lower_function_body НИКОГДА не видит
// ключ, которого ещё нет в таблице.

@(private = "file")
Clone_To_Lower :: struct {
	decl_res: ^Resolver_Ctx,
	fn_id:    Function_Id,
	clone:    ^Function_Decl,
}

// monomorphize_register_one — typecheck+регистрация Function_Id для ОДНОЙ
// инстанциации bounded-generic ФУНКЦИИ (T — fn_decl.type_params). НЕ
// лоурит тело — см. докстринг файла про то, почему это отдельная фаза.
@(private = "file")
monomorphize_register_one :: proc(
	res: ^Resolver_Ctx,
	tc: ^Type_Ctx,
	module: ^Mir_Module,
	fn_decl: ^Function_Decl,
	callee_sym: Symbol_Id,
	concrete_types: [dynamic]^Type,
	key: string,
) -> Clone_To_Lower {
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

	return Clone_To_Lower{decl_res, fn_id, clone}
}

// monomorphize_register_method_one — Фаза 2.3 (WASM AOT-бэкенд): та же
// idea, что monomorphize_register_one, но клонирует тело МЕТОДА
// generic-типа (Опция(T)'s есть/получить и т.п., core/prelude.odin) под
// КОНКРЕТНУЮ инстанциацию владеющего типа (Опция(Число)) —
// ПАРАЛЛЕЛЬНЫЙ механизм, не расширение monomorphize_register_one: тот
// клонирует под fn_decl.type_params (T ФУНКЦИИ), здесь же у метода
// СОБСТВЕННОГО [T] нет вообще — T достаётся от владеющей структуры/
// перечисления (см. type_cheker.odin's record_generic_method_
// instantiation). subst поэтому строится из owner_sym's decl.type_params
// (Struct_Decl/Enum_Decl — те же строковые имена, в том же порядке, что
// ctx.decl_type_param_order[owner_sym], см. make_decl_type_params), НЕ из
// method's fn_decl.type_params (тот пуст здесь).
@(private = "file")
monomorphize_register_method_one :: proc(
	res: ^Resolver_Ctx,
	tc: ^Type_Ctx,
	module: ^Mir_Module,
	method_sym: Symbol_Id,
	owner_sym: Symbol_Id,
	concrete_types: [dynamic]^Type,
	key: string,
) -> (
	Clone_To_Lower,
	bool,
) {
	fn_decl, has_decl := symbol_at(res.symbol_store, method_sym).decl.(^Function_Decl)
	if !has_decl do return {}, false

	clone := clone_function_decl(fn_decl)
	module_of_callee := symbol_at(res.symbol_store, method_sym).module

	decl_res := res
	if res.module_graph != nil {
		if found, ok := res.module_graph.module_resolvers[module_of_callee]; ok {
			decl_res = found
		}
		decl_res.symbol_types = res.module_graph.symbol_types
	}

	resolve_function_body(decl_res, module_of_callee, Decls(clone), clone.args[:], clone.body)

	owner_type_params: [dynamic]string
	#partial switch owner_decl in symbol_at(res.symbol_store, owner_sym).decl {
	case ^Struct_Decl:
		owner_type_params = owner_decl.type_params
	case ^Enum_Decl:
		owner_type_params = owner_decl.type_params
	}
	subst := make(map[string]^Type)
	for name, i in owner_type_params {
		if i >= len(concrete_types) do break
		subst[name] = concrete_types[i]
	}

	// Фаза 2.5: голая ссылка "это: Опция" (без явных type-аргументов)
	// внутри клона резолвится через resolve_type_node's Type_Ident case
	// в отдельную (не эту, string-keyed) infer_id-keyed карту — см. её
	// докстринг про то, почему НЕ через ctx.decl_type_params[owner_sym]
	// (per-Type_Ctx, у прелюдийных Опция/Результат живёт в ЧУЖОМ
	// tc_ctx, найдено эмпирически). Placeholder'ы (T-InferVar'ы) берём
	// СТРУКТУРНЫМ обходом СЫРОГО (неинстанцированного) шаблона —
	// collect_instance_args уже так же используется в record_generic_
	// method_instantiation на РЕАЛЬНОМ instance'е (собирает конкретные
	// типы); здесь тот же обход на АБСТРАКТНОМ шаблоне просто вернёт
	// сырые InferVar'ы вместо конкретных типов — тот же порядковый
	// walk, та же уже принятая позиционная оговорка (см. её докстринг).
	receiver_placeholders := make([dynamic]^Type)
	collect_instance_args(res.symbol_types[owner_sym], &receiver_placeholders)
	receiver_subst := make(map[int]^Type)
	for placeholder, i in receiver_placeholders {
		if i >= len(concrete_types) do break
		if pruned := prune_type(placeholder); pruned.kind == .InferVar {
			receiver_subst[pruned.infer_id] = concrete_types[i]
		}
	}

	prev_params := tc.current_type_params
	prev_res := tc.res
	prev_owner_sym := tc.current_receiver_owner_sym
	prev_receiver_subst := tc.current_receiver_subst
	tc.current_type_params = subst
	tc.res = decl_res
	tc.current_receiver_owner_sym = owner_sym
	tc.current_receiver_subst = receiver_subst

	func_type := function_type_from_decl(tc, clone)
	bind_function_args(tc, clone, func_type)
	check_function_body(tc, clone.span, clone.body, func_type.return_type)

	tc.current_type_params = prev_params
	tc.res = prev_res
	tc.current_receiver_owner_sym = prev_owner_sym
	tc.current_receiver_subst = prev_receiver_subst

	fn_id := new_function(module, key, INVALID_SYMBOL, func_type.return_type, clone.span)
	module.generic_instantiations[key] = fn_id

	return Clone_To_Lower{decl_res, fn_id, clone}, true
}

// lower_monomorphize_program — комбинированный driver для ОБЕИХ
// монофирмизаций: bounded generic-функций (tc.generic_call_
// instantiations) И методов generic-типов (tc.generic_method_
// instantiations, Фаза 2.3). ОБЩИЙ processed-набор, ОБЩАЯ fixed-point
// итерация, и (см. докстринг файла) СТРОГО отдельная фаза лоуринга
// ПОСЛЕ того, как fixed point полностью сошёлся — ни одна инстанциация,
// обнаруженная НА ЛЮБОЙ итерации (включая обнаруженные ДРУГ ДРУГОМ —
// функция обнаруживает метод, метод обнаруживает функцию, любая
// глубина), не лоурится, пока не сойдётся ВЕСЬ граф.
lower_monomorphize_program :: proc(
	res: ^Resolver_Ctx,
	tc: ^Type_Ctx,
	module: ^Mir_Module,
	symbol_to_function: ^map[Symbol_Id]Function_Id,
) {
	Pending_Fn :: struct {
		fn_decl:        ^Function_Decl,
		callee_sym:     Symbol_Id,
		concrete_types: [dynamic]^Type,
		key:            string,
	}
	Pending_Method :: struct {
		method_sym:     Symbol_Id,
		owner_sym:      Symbol_Id,
		concrete_types: [dynamic]^Type,
		key:            string,
	}

	to_lower := make([dynamic]Clone_To_Lower)
	processed := make(map[string]bool)
	for {
		pending_fns := make([dynamic]Pending_Fn)
		for call_expr, concrete_types in tc.generic_call_instantiations {
			_, is_call := call_expr.(^Call_Expr)
			if !is_call do continue
			callee_sym := tc.generic_call_callee_sym[call_expr]
			fn_decl, has_decl := symbol_at(tc.res.symbol_store, callee_sym).decl.(^Function_Decl)
			if !has_decl do continue
			key := build_instantiation_key(tc.res.symbol_store, callee_sym, concrete_types)
			if processed[key] do continue
			append(&pending_fns, Pending_Fn{fn_decl, callee_sym, concrete_types, key})
		}

		pending_methods := make([dynamic]Pending_Method)
		for call_expr, concrete_types in tc.generic_method_instantiations {
			info, has_info := tc.call_infos[call_expr]
			if !has_info do continue
			method_sym := info.symbol_ref
			owner_sym := tc.generic_method_owner_sym[call_expr]
			if owner_sym == INVALID_SYMBOL do continue
			key := build_instantiation_key(tc.res.symbol_store, method_sym, concrete_types)
			if processed[key] do continue
			append(&pending_methods, Pending_Method{method_sym, owner_sym, concrete_types, key})
		}

		if len(pending_fns) == 0 && len(pending_methods) == 0 do break

		for p in pending_fns {
			if processed[p.key] do continue
			append(&to_lower, monomorphize_register_one(res, tc, module, p.fn_decl, p.callee_sym, p.concrete_types, p.key))
			processed[p.key] = true
		}
		for p in pending_methods {
			if processed[p.key] do continue
			c, ok := monomorphize_register_method_one(res, tc, module, p.method_sym, p.owner_sym, p.concrete_types, p.key)
			if ok do append(&to_lower, c)
			processed[p.key] = true
		}
	}

	// Fixed point сошёлся — КАЖДАЯ инстанциация (обнаруженная на любой
	// итерации, любым из двух механизмов) уже в module.generic_
	// instantiations. Теперь безопасно лоурить тела — ни один вызов
	// внутри них не сошлётся на ещё не зарегистрированный ключ.
	for c in to_lower {
		// decl_res, НЕ res — resolve_function_body писала func_args
		// клона В decl_res.func_args (per-Resolver_Ctx карта), тот же
		// мотив, что у comp.res в monomorphize_one.
		lower_function_body(c.decl_res, tc, module, c.fn_id, Decls(c.clone), c.clone.args, c.clone.body, symbol_to_function^)
	}
}
