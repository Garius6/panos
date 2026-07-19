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

	// Cross-module bounded generic (module.f(...), см. Module_Graph.
	// module_resolvers): f объявлена в ДРУГОМ модуле, со СВОИМ
	// Resolver_Ctx/global_scope — резолвить и типизировать клон нужно ТЕМ
	// ЖЕ резолвером, что и оригинал f, иначе имена, живущие только в её
	// модуле (другие функции/типы, которые f вызывает в своём теле), не
	// найдутся через global_scope ВЫЗЫВАЮЩЕГО модуля. Для same-module
	// вызова module_resolvers[module] == res, подмена — no-op.
	decl_res := res
	if res.module_graph != nil {
		if found, ok := res.module_graph.module_resolvers[module]; ok {
			decl_res = found
		}
		// decl_res мог быть "заморожен" resolve_module ДАВНО (TOML мог
		// резолвиться одним из первых модулей графа) — его .symbol_types
		// с тех пор мог отстать от текущего (Odin-карты не гарантированно
		// аліасятся ПОСЛЕ реаллокации при росте, см. тот же мотив у
		// method_lookup выше и в resolve_module). res.module_graph.
		// symbol_types — единственный ГАРАНТИРОВАННО актуальный источник
		// на момент компиляции (resolve_and_typecheck_all уже завершила
		// ВСЕ модули, дальше карта не растёт).
		decl_res.symbol_types = res.module_graph.symbol_types
	}

	resolve_function_body(decl_res, module, Decls(clone), clone.args[:], clone.body)

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
		// decl_res, НЕ res — node_symbols (Ident_Expr -> Symbol_Id для
		// каждого узла клона) писались resolve_function_body ВЫШЕ ИМЕННО
		// В decl_res.node_symbols (per-Resolver_Ctx карта, см. Module_Graph.
		// module_resolvers) — compile_expr читает через comp.res.
		// node_symbols напрямую, а не через comp.tc.res, так что подмены
		// tc.res=decl_res (выше, для typecheck) недостаточно САМОЙ ПО СЕБЕ:
		// её restore (tc.res = prev_res сразу после check_function_body)
		// произошёл бы ДО того, как comp вообще собран — без этого поля
		// здесь compile_expr искал бы символы клона в res.node_symbols
		// (карта ВЫЗЫВАЮЩЕГО модуля), находил бы INVALID_SYMBOL и падал
		// "символ '' не найден" на первой же ссылке клона на ЧУЖОЕ ДЛЯ
		// вызывающего модуля имя (напр. другую top-level функцию f).
		res              = decl_res,
		locals           = make([dynamic]Local),
	}
	// decl_res, НЕ res — тот же мотив, что у comp.res выше: func_args[key]
	// писала resolve_function_body(decl_res, ...) В decl_res.func_args.
	if args_syms, ok := decl_res.func_args[Decls(clone)]; ok {
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
			_, is_call := call_expr.(^Call_Expr)
			if !is_call do continue
			// tc.res.node_symbols[call.callee] здесь раньше не находило бы
			// callee_sym для cross-module вызова (module.f(...) — callee это
			// ^Property_Expr, не резолвится через node_symbols вообще, см.
			// Type_Ctx.generic_call_callee_sym) — саму инстанциацию тихо
			// пропустили бы, а compiler.odin потом падал бы "инстанциация не
			// найдена". generic_call_callee_sym пишется В ТОМ ЖЕ месте
			// (infer_bounded_generic_call), что и generic_call_instantiations —
			// гарантированно есть запись для любого ключа этой карты.
			callee_sym := tc.generic_call_callee_sym[call_expr]
			// tc.symbol_to_func_decl (per-модульная карта, см. Type_Ctx) не
			// содержала бы cross-module callee_sym (объявлен в ДРУГОМ
			// модуле, со СВОИМ tc_ctx, см. module_loader.odin) — Symbol.decl
			// же выставляется на этапе resolve (единый symbol_store на весь
			// граф), доступен независимо от того, чей это tc.
			fn_decl, has_decl := symbol_at(tc.res.symbol_store, callee_sym).decl.(^Function_Decl)
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
