package core

import "core:fmt"

is_builtin_module_name :: proc(name: string) -> bool {
	return(
		name == "фс" ||
		name == "ос" ||
		name == "ввод_вывод" ||
		name == "строки" ||
		name == "сеть" ||
		name == "время" ||
		name == "сжатие" \
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

builtin_function_type_4 :: proc(param_1: ^Type, param_2: ^Type, param_3: ^Type, param_4: ^Type, return_type: ^Type) -> ^Type {
	fn_params := make([dynamic]^Type)
	append(&fn_params, param_1)
	append(&fn_params, param_2)
	append(&fn_params, param_3)
	append(&fn_params, param_4)
	return new_function_type(fn_params, return_type)
}

// Опция/Результат — обычные generic-enum'ы прелюдии, а не Type_Kind. Эти
// два хелпера строят их напрямую через graph, а НЕ через ctx-based
// new_option_type/new_result_type (type_cheker.odin): ensure_builtin_module
// выполняется во время резолва импорта, ДО того как для этого модуля
// существует Type_Ctx — только graph (уже содержащий типизированную
// прелюдию) под рукой.
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
		return builtin_function_type_3(TY_STRING, TY_INT, TY_INT, TY_STRING)
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
	case "строки::из_целого":
		return builtin_function_type_1(TY_INT, TY_STRING)
	case "строки::найти":
		return builtin_function_type_3(TY_STRING, TY_STRING, TY_INT, TY_INT)
	case "строки::содержит":
		return builtin_function_type_2(TY_STRING, TY_STRING, TY_BOOL)
	case "строки::заменить":
		return builtin_function_type_3(TY_STRING, TY_STRING, TY_STRING, TY_STRING)
	case "строки::разбить":
		return builtin_function_type_2(TY_STRING, TY_STRING, new_array_type(TY_STRING))
	case "строки::соединить":
		return builtin_function_type_2(new_array_type(TY_STRING), TY_STRING, TY_STRING)
	case "строки::обрезать":
		return builtin_function_type_1(TY_STRING, TY_STRING)
	case "строки::начинается_с":
		return builtin_function_type_2(TY_STRING, TY_STRING, TY_BOOL)
	case "строки::заканчивается_на":
		return builtin_function_type_2(TY_STRING, TY_STRING, TY_BOOL)
	case "строки::верхний_регистр":
		return builtin_function_type_1(TY_STRING, TY_STRING)
	case "строки::нижний_регистр":
		return builtin_function_type_1(TY_STRING, TY_STRING)
	case "строки::сравнить":
		return builtin_function_type_2(TY_STRING, TY_STRING, TY_NUM)
	case "строки::байт":
		return builtin_function_type_2(TY_STRING, TY_INT, TY_INT)
	case "строки::длина_байт":
		return builtin_function_type_1(TY_STRING, TY_INT)
	case "строки::срез_байт":
		return builtin_function_type_3(TY_STRING, TY_INT, TY_INT, TY_STRING)
	case "строки::из_байтов":
		return builtin_function_type_1(new_array_type(TY_INT), TY_STRING)
	case "сжатие::разжать_gzip":
		return builtin_function_type_1(TY_STRING, stdlib_result_type(graph, TY_STRING, TY_ERROR))
	case "сеть::подключиться":
		return builtin_function_type_2(TY_STRING, TY_NUM, stdlib_result_type(graph, TY_CONNECTION, TY_ERROR))
	case "сеть::кодировать_url":
		return builtin_function_type_1(TY_STRING, TY_STRING)
	case "сеть::http_запрос":
		// Настоящий HTTP(S)-клиент (external/odin-http, OpenSSL для https)
		// вместо ручного сокет-парсинга в std/сеть/http.ps — корректно
		// обрабатывает Content-Length/chunked encoding, поддерживает https.
		// Результат: (статус, пары-заголовков, тело).
		pair_fields := make([dynamic]^Type)
		append(&pair_fields, TY_STRING, TY_STRING)
		pair_type := new_tuple_type(pair_fields)
		success_fields := make([dynamic]^Type)
		append(&success_fields, TY_INT, new_array_type(pair_type), TY_STRING)
		success_type := new_tuple_type(success_fields)
		return builtin_function_type_4(
			TY_STRING,
			TY_STRING,
			TY_STRING,
			new_map_type(TY_STRING, TY_STRING),
			stdlib_result_type(graph, success_type, TY_ERROR),
		)
	case "время::монотонно_мс":
		return new_function_type(make([dynamic]^Type), TY_NUM)
	case "время::сейчас_мс":
		return new_function_type(make([dynamic]^Type), TY_NUM)
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
	// фс::прочитать/открыть/... возвращают Результат(...) (stdlib_result_type
	// ниже), которому нужны graph.prelude_result_sym/symbol_types/
	// prelude_generic_order — обычно выставляет resolve_module. Но
	// load_module_recursive зовёт ensure_builtin_module ЕЩЁ РАНЬШЕ, на этапе
	// сканирования импортов, до единого resolve_module для графа — без явного
	// вызова здесь прелюдия ещё не существует, и self-мемоизация выше
	// закэшировала бы "фс" с nil-типами НАВСЕГДА. ensure_prelude сама
	// мемоизирована — повторный вызов ниже по стеку — no-op.
	ensure_prelude(graph)

	module := new(Module)
	module.path = name
	module.dir = ""
	module.exports = make(map[Interned]Symbol_Id)
	graph.modules[name] = module

	if name == "фс" {
		add_builtin_export(graph, module, "есть", builtin_export_type(graph, "фс::есть"))
		add_builtin_export(graph, module, "прочитать", builtin_export_type(graph, "фс::прочитать"))
		add_builtin_export(graph, module, "записать", builtin_export_type(graph, "фс::записать"))
		add_builtin_export(graph, module, "открыть", builtin_export_type(graph, "фс::открыть"))
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
		add_builtin_export(graph, module, "из_целого", builtin_export_type(graph, "строки::из_целого"))
		add_builtin_export(graph, module, "найти", builtin_export_type(graph, "строки::найти"))
		add_builtin_export(graph, module, "содержит", builtin_export_type(graph, "строки::содержит"))
		add_builtin_export(graph, module, "заменить", builtin_export_type(graph, "строки::заменить"))
		add_builtin_export(graph, module, "разбить", builtin_export_type(graph, "строки::разбить"))
		add_builtin_export(graph, module, "соединить", builtin_export_type(graph, "строки::соединить"))
		add_builtin_export(graph, module, "обрезать", builtin_export_type(graph, "строки::обрезать"))
		add_builtin_export(
			graph,
			module,
			"начинается_с",
			builtin_export_type(graph, "строки::начинается_с"),
		)
		add_builtin_export(
			graph,
			module,
			"заканчивается_на",
			builtin_export_type(graph, "строки::заканчивается_на"),
		)
		add_builtin_export(
			graph,
			module,
			"верхний_регистр",
			builtin_export_type(graph, "строки::верхний_регистр"),
		)
		add_builtin_export(
			graph,
			module,
			"нижний_регистр",
			builtin_export_type(graph, "строки::нижний_регистр"),
		)
		add_builtin_export(graph, module, "сравнить", builtin_export_type(graph, "строки::сравнить"))
		add_builtin_export(graph, module, "байт", builtin_export_type(graph, "строки::байт"))
		add_builtin_export(graph, module, "длина_байт", builtin_export_type(graph, "строки::длина_байт"))
		add_builtin_export(graph, module, "срез_байт", builtin_export_type(graph, "строки::срез_байт"))
		add_builtin_export(graph, module, "из_байтов", builtin_export_type(graph, "строки::из_байтов"))
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
		add_builtin_export(
			graph,
			module,
			"http_запрос",
			builtin_export_type(graph, "сеть::http_запрос"),
		)
	} else if name == "время" {
		add_builtin_export(
			graph,
			module,
			"монотонно_мс",
			builtin_export_type(graph, "время::монотонно_мс"),
		)
		add_builtin_export(
			graph,
			module,
			"сейчас_мс",
			builtin_export_type(graph, "время::сейчас_мс"),
		)
	} else if name == "сжатие" {
		add_builtin_export(
			graph,
			module,
			"разжать_gzip",
			builtin_export_type(graph, "сжатие::разжать_gzip"),
		)
	}

	return module
}
