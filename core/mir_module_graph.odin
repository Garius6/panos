package core

// Многомодульный вход в MIR-лоуринг — аналог main.odin's run_file
// компиляционного цикла (resolve_and_typecheck_all -> ensure_prelude_
// compiled -> compile_program в graph.order на ОБЩИЙ registry), но
// строящий ОДИН общий Mir_Module вместо ОБЩЕГО map[string]^Compiled_
// Function. lower_module (mir_lowering.odin) лоурит ровно ОДИН Program
// (+ его прелюдию) — файловые `импорт`ы (module_loader.odin's Module_
// Graph) лоурить не умеет вообще (см. историю lower_spawn_expr's cross-
// module ограничения). Здесь то же двухпроходное hoist/lower, что
// lower_module делает для одного файла, применяется МОДУЛЬ ЗА МОДУЛЕМ —
// граф гарантированно ациклический и topologically ordered (graph.order,
// dependency-before-dependent, см. load_module_recursive), а Symbol_Id
// общий на ВЕСЬ граф (единый Symbol_Store, см. graph.symbol_store) —
// значит forward-ссылка из модуля-зависимости на модуль-зависимый
// невозможна (импорт цикла запрещён загрузчиком), и hoist_decls/lower_
// decls модуля N видят Function_Id ВСЕХ модулей 0..N-1 через ОБЩИЙ
// symbol_to_function, ровно как compile_program's per-module hoist/
// compile-body пары видят ОБЩИЙ registry сегодня.
lower_program_graph :: proc(results: [dynamic]Module_Result) -> Mir_Module {
	module := new_module()
	symbol_to_function := make(map[Symbol_Id]Function_Id)

	if len(results) == 0 do return module

	// Odin-карты копируются ПО ЗНАЧЕНИЮ (заголовок: указатель+len+cap) —
	// каждый resolve_module в resolve_and_typecheck_all резинхронизирует
	// СВОЙ res_ctx.symbol_types на graph.symbol_types В КОНЦЕ СВОЕГО
	// вызова (см. resolver.odin, "тот же мотив" — уже задокументировано
	// как риск расхождения ТАМ ЖЕ), но НИЧЕГО не возвращается назад и не
	// обновляет УЖЕ СОХРАНЁННЫЕ копии заголовка в results[j].res_ctx для
	// j < i, если модуль i растит карту ДАЛЬШЕ (рост = realloc + free
	// старого backing-массива, core:runtime — не GC, освобождение
	// немедленное). К моменту, когда lower_program_graph вызывается,
	// resolve_and_typecheck_all УЖЕ полностью прошла ВЕСЬ граф — карта
	// больше НЕ растёт, и results[len-1].res_ctx.symbol_types (последний
	// модуль синхронизировался последним) — ГАРАНТИРОВАННО свежий
	// источник (тот же принцип, что monomorphize_one использует через
	// res.module_graph.symbol_types). Без этой ресинхронизации
	// prelude_res_ctx.symbol_types (захвачен ДАВНО, ещё во время
	// load_module_graph's ensure_prelude, до регистрации остальных
	// builtin-модулей graph'а) — гарантированно висячий указатель:
	// найдено эмпирически (AddressSanitizer heap-use-after-free,
	// fixtures/supervisor_dynamic_add_fixture_main.ps — array
	// realloc/free от add_builtin_export("строки"/"ввод_вывод"/...)
	// уже ПОСЛЕ того, как прелюдия типизировалась).
	freshest_symbol_types := results[len(results) - 1].res_ctx.symbol_types
	for i in 0 ..< len(results) {
		results[i].res_ctx.symbol_types = freshest_symbol_types
	}
	if results[0].res_ctx.prelude_res_ctx != nil {
		results[0].res_ctx.prelude_res_ctx.symbol_types = freshest_symbol_types
	}

	lower_prelude_into(&results[0].res_ctx, &module, &symbol_to_function)

	for i in 0 ..< len(results) {
		r := &results[i]
		hoist_decls(&r.res_ctx, &module, &symbol_to_function, r.module.ast.decls)
		// Bounded traits: тот же порядок (hoist -> monomorphize -> lower),
		// что lower_module для одного файла — см. её комментарий. Здесь
		// вызывается ОТДЕЛЬНО на КАЖДЫЙ модуль (не один раз на весь граф):
		// tc.generic_call_instantiations — per-Type_Ctx карта (у каждого
		// модуля свой r.tc_ctx, см. resolve_and_typecheck_all), инстанции,
		// найденные при тайпчеке модуля N, читаются ИЗ r.tc_ctx модуля N —
		// тот же принцип, что compile_program's собственный monomorphize_
		// program-вызов внутри per-module цикла main.odin.
		lower_monomorphize_program(&r.res_ctx, &r.tc_ctx, &module, &symbol_to_function)
		lower_decls(&r.res_ctx, &r.tc_ctx, &module, &symbol_to_function, r.module.ast.decls)
	}

	return module
}
