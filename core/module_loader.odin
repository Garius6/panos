package core

import "core:fmt"
import "core:os"

read_file_text :: proc(path: string) -> string {
	if !os.exists(path) {
		fmt.panicf("Module Loader Error: файл '%s' не существует", path)
	}

	f, err := os.open(path, {.Read})
	if err != nil {
		fmt.panicf("Module Loader Error: не удалось открыть '%s': %v", path, err)
	}

	data, read_err := os.read_entire_file(f, context.allocator)
	if read_err != nil {
		fmt.panicf(
			"Module Loader Error: не удалось прочесть '%s': %v",
			path,
			read_err,
		)
	}

	return string(data)
}

load_module_recursive :: proc(graph: ^Module_Graph, file_path: string, is_entry: bool) -> ^Module {
	module_key := resolve_import_path(file_path, "")
	if module, found := graph.modules[module_key]; found {
		return module
	}
	if graph.loading[module_key] {
		fmt.panicf(
			"Module Loader Error: обнаружен циклический импорт '%s'",
			file_path,
		)
	}

	graph.loading[module_key] = true
	defer graph.loading[module_key] = false

	module := new(Module)
	module.dir = module_dir_name(module_key)
	if is_entry {
		module.path = ""
	} else {
		module.path = module_key
	}
	module.exports = make(map[Interned]^Symbol)
	module.file_id = u16(len(graph.modules))

	source := read_file_text(module_key)
	module.source = source
	graph.file_paths[module.file_id] = module_key
	graph.file_sources[module.file_id] = source

	tokens := tokenize(source, module.file_id)
	stream := make_stream(tokens)
	defer destroy_stream(&stream)

	parser := Parser {
		stream  = &stream,
		file_id = module.file_id,
	}
	module.ast = parse_program(&parser)

	graph.modules[module_key] = module

	for decl in module.ast.decls {
		if import_decl, ok := decl.(^Import_Decl); ok {
			import_path, exists := resolve_existing_import_path(import_decl.path, module.dir)
			if !exists && is_builtin_module_name(import_decl.path) {
				ensure_builtin_module(graph, import_decl.path)
				continue
			}
			if !exists {
				fmt.panicf(
					"Module Loader Error: модуль '%s' не найден",
					import_decl.path,
				)
			}
			load_module_recursive(graph, import_path, false)
		}
	}

	append(&graph.order, module)
	return module
}

load_module_graph :: proc(entry_path: string) -> Module_Graph {
	graph := new_module_graph()
	load_module_recursive(&graph, entry_path, true)
	return graph
}
