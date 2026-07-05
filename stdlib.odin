package main

import "core:fmt"

is_builtin_module_name :: proc(name: string) -> bool {
	return name == "фс"
}

add_builtin_export :: proc(graph: ^Module_Graph, module: ^Module, name: string, typ: ^Type) {
	sym := new_symbol(name, .Builtin, module, true)
	module.exports[name] = sym
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

builtin_export_type :: proc(full_name: string) -> ^Type {
	switch full_name {
	case "фс::есть":
		return builtin_function_type_1(TY_STRING, TY_BOOL)
	case "фс::прочитать":
		return builtin_function_type_1(TY_STRING, new_result_type(TY_STRING, TY_ERROR))
	case "фс::записать":
		return builtin_function_type_2(TY_STRING, TY_STRING, new_result_type(TY_NUM, TY_ERROR))
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

	module := new(Module)
	module.path = name
	module.dir = ""
	module.exports = make(map[string]^Symbol)
	graph.modules[name] = module

	if name == "фс" {
		add_builtin_export(graph, module, "есть", builtin_function_type_1(TY_STRING, TY_BOOL))
		add_builtin_export(
			graph,
			module,
			"прочитать",
			builtin_function_type_1(TY_STRING, new_result_type(TY_STRING, TY_ERROR)),
		)
		add_builtin_export(
			graph,
			module,
			"записать",
			builtin_function_type_2(TY_STRING, TY_STRING, new_result_type(TY_NUM, TY_ERROR)),
		)
	}

	return module
}
