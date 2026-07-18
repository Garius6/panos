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
		name == "графика" \
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

// Стадия 4 (FFI-A): raylib's Vector2 :: [2]f32 / Color :: distinct [4]u8
// — на panos-стороне обычные тупы (Число, Число)/(Число, Число, Число,
// Число), БЕЗ нового Type_Kind (тот же приём, что new_tuple_type уже
// используют получить_сигнал()/for-in деструктуризация соответствия).
// Свежий [dynamic]^Type на каждый вызов — new_tuple_type должен владеть
// своим срезом, шарить между сигнатурами нельзя.
raylib_vector2_type :: proc() -> ^Type {
	fields := make([dynamic]^Type)
	append(&fields, TY_NUM)
	append(&fields, TY_NUM)
	return new_tuple_type(fields)
}

raylib_color_type :: proc() -> ^Type {
	fields := make([dynamic]^Type)
	append(&fields, TY_NUM)
	append(&fields, TY_NUM)
	append(&fields, TY_NUM)
	append(&fields, TY_NUM)
	return new_tuple_type(fields)
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
	case "сеть::подключиться":
		return builtin_function_type_2(TY_STRING, TY_NUM, stdlib_result_type(graph, TY_CONNECTION, TY_ERROR))
	case "сеть::кодировать_url":
		return builtin_function_type_1(TY_STRING, TY_STRING)
	case "время::монотонно_мс":
		return new_function_type(make([dynamic]^Type), TY_NUM)
	case "время::сейчас_мс":
		return new_function_type(make([dynamic]^Type), TY_NUM)
	case "графика::инициализировать_окно":
		return builtin_function_type_3(TY_INT, TY_INT, TY_STRING, TY_VOID)
	case "графика::окно_должно_закрыться":
		return new_function_type(make([dynamic]^Type), TY_BOOL)
	case "графика::закрыть_окно":
		return new_function_type(make([dynamic]^Type), TY_VOID)
	case "графика::начать_рисование":
		return new_function_type(make([dynamic]^Type), TY_VOID)
	case "графика::закончить_рисование":
		return new_function_type(make([dynamic]^Type), TY_VOID)
	case "графика::очистить_фон":
		return builtin_function_type_1(raylib_color_type(), TY_VOID)
	case "графика::нарисовать_прямоугольник":
		return builtin_function_type_3(raylib_vector2_type(), raylib_vector2_type(), raylib_color_type(), TY_VOID)
	case "графика::нарисовать_круг":
		return builtin_function_type_3(raylib_vector2_type(), TY_NUM, raylib_color_type(), TY_VOID)
	case "графика::клавиша_нажата":
		return builtin_function_type_1(TY_INT, TY_BOOL)
	case "графика::время_кадра":
		return new_function_type(make([dynamic]^Type), TY_NUM)
	case "графика::задать_fps":
		return builtin_function_type_1(TY_INT, TY_VOID)
	case "графика::клавиша_вверх",
	     "графика::клавиша_вниз",
	     "графика::клавиша_влево",
	     "графика::клавиша_вправо",
	     "графика::клавиша_пробел",
	     "графика::клавиша_escape":
		return new_function_type(make([dynamic]^Type), TY_INT)
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
	} else if name == "графика" {
		add_builtin_export(graph, module, "инициализировать_окно", builtin_export_type(graph, "графика::инициализировать_окно"))
		add_builtin_export(graph, module, "окно_должно_закрыться", builtin_export_type(graph, "графика::окно_должно_закрыться"))
		add_builtin_export(graph, module, "закрыть_окно", builtin_export_type(graph, "графика::закрыть_окно"))
		add_builtin_export(graph, module, "начать_рисование", builtin_export_type(graph, "графика::начать_рисование"))
		add_builtin_export(graph, module, "закончить_рисование", builtin_export_type(graph, "графика::закончить_рисование"))
		add_builtin_export(graph, module, "очистить_фон", builtin_export_type(graph, "графика::очистить_фон"))
		add_builtin_export(graph, module, "нарисовать_прямоугольник", builtin_export_type(graph, "графика::нарисовать_прямоугольник"))
		add_builtin_export(graph, module, "нарисовать_круг", builtin_export_type(graph, "графика::нарисовать_круг"))
		add_builtin_export(graph, module, "клавиша_нажата", builtin_export_type(graph, "графика::клавиша_нажата"))
		add_builtin_export(graph, module, "время_кадра", builtin_export_type(graph, "графика::время_кадра"))
		add_builtin_export(graph, module, "задать_fps", builtin_export_type(graph, "графика::задать_fps"))
		add_builtin_export(graph, module, "клавиша_вверх", builtin_export_type(graph, "графика::клавиша_вверх"))
		add_builtin_export(graph, module, "клавиша_вниз", builtin_export_type(graph, "графика::клавиша_вниз"))
		add_builtin_export(graph, module, "клавиша_влево", builtin_export_type(graph, "графика::клавиша_влево"))
		add_builtin_export(graph, module, "клавиша_вправо", builtin_export_type(graph, "графика::клавиша_вправо"))
		add_builtin_export(graph, module, "клавиша_пробел", builtin_export_type(graph, "графика::клавиша_пробел"))
		add_builtin_export(graph, module, "клавиша_escape", builtin_export_type(graph, "графика::клавиша_escape"))
	}

	return module
}
