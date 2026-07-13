package core

import "core:fmt"

is_builtin_module_name :: proc(name: string) -> bool {
	return(
		name == "фс" ||
		name == "ос" ||
		name == "ввод_вывод" ||
		name == "строки" ||
		name == "сеть" \
	)
}

add_builtin_export :: proc(graph: ^Module_Graph, module: ^Module, name: string, typ: ^Type) {
	sym := new_symbol(graph.symbol_store, name, .Builtin, module, true)
	module.exports[intern(name)] = sym
	graph.symbol_types[sym] = typ
}

builtin_function_type_1 :: proc(param: ^Type, return_type: ^Type) -> ^Type {
	fn_params := make([dynamic]^Type)
	append(&fn_params, param)
	return new_function_type(fn_params, return_type)
}

builtin_function_type_2 :: proc(param_1: ^Type, param_2: ^Type, return_type: ^Type) -> ^Type {
	fn_params := make([dynamic]^Type)
	append(&fn_params, param_1)
	append(&fn_params, param_2)
	return new_function_type(fn_params, return_type)
}

builtin_function_type_3 :: proc(param_1: ^Type, param_2: ^Type, param_3: ^Type, return_type: ^Type) -> ^Type {
	fn_params := make([dynamic]^Type)
	append(&fn_params, param_1)
	append(&fn_params, param_2)
	append(&fn_params, param_3)
	return new_function_type(fn_params, return_type)
}

// Стадия 7 Phase F: Опция/Результат больше не Type_Kind, а обычные generic-
// enum'ы прелюдии — эти два хелпера строят их напрямую через graph
// (Module_Graph), а НЕ через ctx-based new_option_type/new_result_type
// (type_cheker.odin): ensure_builtin_module выполняется во время резолва
// импорта, ДО того как для этого модуля существует Type_Ctx — только graph
// (уже содержащий типизированную прелюдию, см. resolve_module) под рукой.
stdlib_option_type :: proc(graph: ^Module_Graph, element_type: ^Type) -> ^Type {
	sym := graph.prelude_option_sym
	return instantiate_generic_raw(graph.symbol_types[sym], graph.prelude_generic_order[sym], []^Type{element_type})
}

stdlib_result_type :: proc(graph: ^Module_Graph, ok_type: ^Type, error_type: ^Type) -> ^Type {
	sym := graph.prelude_result_sym
	return instantiate_generic_raw(
		graph.symbol_types[sym],
		graph.prelude_generic_order[sym],
		[]^Type{ok_type, error_type},
	)
}

builtin_export_type :: proc(graph: ^Module_Graph, full_name: string) -> ^Type {
	switch full_name {
	case "фс::есть":
		return builtin_function_type_1(TY_STRING, TY_BOOL)
	case "фс::прочитать":
		return builtin_function_type_1(TY_STRING, stdlib_result_type(graph, TY_STRING, TY_ERROR))
	case "фс::записать":
		return builtin_function_type_2(TY_STRING, TY_STRING, stdlib_result_type(graph, TY_NUM, TY_ERROR))
	case "фс::открыть":
		return builtin_function_type_1(TY_STRING, stdlib_result_type(graph, TY_FILE, TY_ERROR))
	case "ос::аргументы":
		return new_function_type(make([dynamic]^Type), new_array_type(TY_STRING))
	case "ос::окружение":
		return builtin_function_type_1(TY_STRING, stdlib_option_type(graph, TY_STRING))
	case "ос::установить_окружение":
		return builtin_function_type_2(TY_STRING, TY_STRING, stdlib_result_type(graph, TY_NUM, TY_ERROR))
	case "ос::удалить_окружение":
		return builtin_function_type_1(TY_STRING, TY_BOOL)
	case "ввод_вывод::печать":
		return builtin_function_type_1(TY_STRING, TY_VOID)
	case "ввод_вывод::строка":
		return builtin_function_type_1(TY_STRING, TY_VOID)
	case "ввод_вывод::прочитать_строку":
		return new_function_type(make([dynamic]^Type), stdlib_result_type(graph, TY_STRING, TY_ERROR))
	case "ввод_вывод::поток":
		return new_function_type(make([dynamic]^Type), TY_FILE)
	case "строки::срез":
		return builtin_function_type_3(TY_STRING, TY_NUM, TY_NUM, TY_STRING)
	case "строки::это_цифра":
		return builtin_function_type_1(TY_STRING, TY_BOOL)
	case "строки::это_буква":
		return builtin_function_type_1(TY_STRING, TY_BOOL)
	case "строки::цифра_или_буква":
		return builtin_function_type_1(TY_STRING, TY_BOOL)
	case "строки::в_число":
		return builtin_function_type_1(TY_STRING, stdlib_result_type(graph, TY_NUM, TY_ERROR))
	case "строки::из_числа":
		return builtin_function_type_1(TY_NUM, TY_STRING)
	case "сеть::подключиться":
		return builtin_function_type_2(TY_STRING, TY_NUM, stdlib_result_type(graph, TY_CONNECTION, TY_ERROR))
	case "сеть::кодировать_url":
		return builtin_function_type_1(TY_STRING, TY_STRING)
	}
	return nil
}

ensure_builtin_module :: proc(graph: ^Module_Graph, name: string) -> ^Module {
	if module, found := graph.modules[name]; found {
		return module
	}
	if !is_builtin_module_name(name) {
		fmt.panicf(
			"Stdlib Error: неизвестный встроенный модуль '%s'",
			name,
		)
	}
	// Стадия 7 Phase F: фс::прочитать/открыть/... возвращают Результат(...)
	// (stdlib_result_type ниже), которому нужны graph.prelude_result_sym/
	// symbol_types[...]/prelude_generic_order — обычно выставляет
	// resolve_module ДО своего register_top_level_decl. Но load_module_
	// recursive (module_loader.odin) зовёт ensure_builtin_module ЕЩЁ РАНЬШЕ,
	// на этапе сканирования импортов, до единого resolve_module для этого
	// графа — без явного вызова здесь прелюдия ещё не существует, и
	// ensure_builtin_module (self-мемоизация выше) закэшировал бы "фс" с
	// nil-типами НАВСЕГДА. ensure_prelude сама мемоизирована — повторный
	// вызов из resolve_module ниже по стеку — no-op.
	ensure_prelude(graph)

	module := new(Module)
	module.path = name
	module.dir = ""
	module.exports = make(map[Interned]Symbol_Id)
	graph.modules[name] = module

	if name == "фс" {
		add_builtin_export(graph, module, "есть", builtin_function_type_1(TY_STRING, TY_BOOL))
		add_builtin_export(
			graph,
			module,
			"прочитать",
			builtin_function_type_1(TY_STRING, stdlib_result_type(graph, TY_STRING, TY_ERROR)),
		)
		add_builtin_export(
			graph,
			module,
			"записать",
			builtin_function_type_2(TY_STRING, TY_STRING, stdlib_result_type(graph, TY_NUM, TY_ERROR)),
		)
		add_builtin_export(
			graph,
			module,
			"открыть",
			builtin_function_type_1(TY_STRING, stdlib_result_type(graph, TY_FILE, TY_ERROR)),
		)
	} else if name == "ос" {
		add_builtin_export(
			graph,
			module,
			"аргументы",
			builtin_export_type(graph, "ос::аргументы"),
		)
		add_builtin_export(
			graph,
			module,
			"окружение",
			builtin_export_type(graph, "ос::окружение"),
		)
		add_builtin_export(
			graph,
			module,
			"установить_окружение",
			builtin_export_type(graph, "ос::установить_окружение"),
		)
		add_builtin_export(
			graph,
			module,
			"удалить_окружение",
			builtin_export_type(graph, "ос::удалить_окружение"),
		)
	} else if name == "ввод_вывод" {
		add_builtin_export(
			graph,
			module,
			"печать",
			builtin_export_type(graph, "ввод_вывод::печать"),
		)
		add_builtin_export(
			graph,
			module,
			"строка",
			builtin_export_type(graph, "ввод_вывод::строка"),
		)
		add_builtin_export(
			graph,
			module,
			"прочитать_строку",
			builtin_export_type(graph, "ввод_вывод::прочитать_строку"),
		)
		add_builtin_export(
			graph,
			module,
			"поток",
			builtin_export_type(graph, "ввод_вывод::поток"),
		)
	} else if name == "строки" {
		add_builtin_export(graph, module, "срез", builtin_export_type(graph, "строки::срез"))
		add_builtin_export(graph, module, "это_цифра", builtin_export_type(graph, "строки::это_цифра"))
		add_builtin_export(graph, module, "это_буква", builtin_export_type(graph, "строки::это_буква"))
		add_builtin_export(
			graph,
			module,
			"цифра_или_буква",
			builtin_export_type(graph, "строки::цифра_или_буква"),
		)
		add_builtin_export(graph, module, "в_число", builtin_export_type(graph, "строки::в_число"))
		add_builtin_export(graph, module, "из_числа", builtin_export_type(graph, "строки::из_числа"))
	} else if name == "сеть" {
		add_builtin_export(
			graph,
			module,
			"подключиться",
			builtin_export_type(graph, "сеть::подключиться"),
		)
		add_builtin_export(
			graph,
			module,
			"кодировать_url",
			builtin_export_type(graph, "сеть::кодировать_url"),
		)
	}

	return module
}
