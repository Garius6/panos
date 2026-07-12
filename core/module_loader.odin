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
	module.exports = make(map[Interned]Symbol_Id)
	module.file_id = u16(len(graph.modules))

	source: string
	if override, has_override := graph.source_overrides[module_key]; has_override {
		// LSP: буфер редактируется в памяти и может ещё не быть сохранён
		// на диск (или отличаться от диска) — используем текст из
		// редактора вместо read_file_text для этого конкретного модуля.
		source = override
	} else {
		source = read_file_text(module_key)
	}
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
	for d in parser.diagnostics do append(&graph.parse_diagnostics, d)

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

// Как load_module_graph, но с картой module_key -> текст-из-редактора для
// модулей, открытых сейчас как LSP-буферы (см. source_overrides в
// Module_Graph). Остальные модули читаются с диска как обычно.
load_module_graph_with_overrides :: proc(
	entry_path: string,
	overrides: map[string]string,
) -> Module_Graph {
	graph := new_module_graph()
	graph.source_overrides = overrides
	load_module_recursive(&graph, entry_path, true)
	return graph
}

Module_Result :: struct {
	module:  ^Module,
	res_ctx: Resolver_Ctx,
	tc_ctx:  Type_Ctx,
}

// Общий цикл "resolve+typecheck каждый модуль в графе, в топологическом
// порядке" — раньше дублировался в main.odin::run_file и
// lsp/lsp_server.odin::revalidate_document один-в-один. Не гейтит и не
// прерывается на diagnostics сама — это решает вызывающий код (CLI хочет
// print+exit до компиляции, LSP хочет копить и публиковать per-file, без
// exit).
resolve_and_typecheck_all :: proc(graph: ^Module_Graph) -> [dynamic]Module_Result {
	// Ёмкость выставлена сразу под len(graph.order) — append() ниже не
	// реаллоцирует backing-массив, что важно: Type_Ctx.res указывает на
	// Resolver_Ctx, ВСТРОЕННЫЙ В ТОТ ЖЕ элемент results, и это
	// самоссылающееся поле правится ПОСЛЕ append (см. ниже) на адрес
	// внутри массива — реаллокация где-то в середине цикла превратила бы
	// уже подправленные res-поля более ранних элементов в висячие
	// указатели.
	results := make([dynamic]Module_Result, 0, len(graph.order))
	for module in graph.order {
		res_ctx := resolve_module(graph, module)
		tc_ctx := new_type_ctx(&res_ctx)
		typecheck_program(&tc_ctx, module.ast)
		append(&results, Module_Result{module = module, res_ctx = res_ctx, tc_ctx = tc_ctx})
		// new_type_ctx(&res_ctx) выше указывал на ЛОКАЛЬНУЮ переменную
		// res_ctx — append скопировал её значение в results, но
		// tc_ctx.res всё ещё смотрит на уже недействительный (по выходу
		// из этой итерации) стек. Перевешиваем на адрес внутри массива.
		last := &results[len(results) - 1]
		last.tc_ctx.res = &last.res_ctx
		// ВАЖНО: обновляем graph.symbol_types СРАЗУ, внутри этой же
		// итерации — следующий модуль (зависящий от типов, построенных
		// ЭТИМ модулем, напр. перечисление, на которое ссылается через
		// импорт) резолвит свой Type_Ctx ДО того, как графовое присвоение
		// снаружи цикла успело бы произойти. Без этой строки здесь
		// cross-module ADT usage падает с "тип-владелец ещё не построен" —
		// эмпирически проверено, не переименовывать в "no-op" без теста.
		graph.symbol_types = last.res_ctx.symbol_types
	}
	return results
}
