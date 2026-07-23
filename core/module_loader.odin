package core

import "core:fmt"

// read_file_text — в module_loader_native.odin/module_loader_wasm.odin
// (#+build split, трогает os.*, а импорт core:os падает compile-time
// panic'ом под js_wasm32). WASM-вариант не имеет ФС и всегда отвечает
// "не найдено" — тот же контракт, что и для отсутствующего файла.

// Ошибки здесь аккумулируются, а не panicf: файл вне панos-репы без
// PANOS_STDLIB/std рядом — обычный live-typing сценарий LSP, а panicf
// уронил бы весь LSP-процесс. module_key просто не попадает в
// graph.modules, и резолвер это переживает (register_top_level_decl::
// Import_Decl проверяет `ok` из map-lookup'а). importer_span — span
// импортирующего `Import_Decl` для diagnostic'а, zero-value для входного
// файла (там винить нечего, см. отдельную проверку entry_module == nil).
load_module_recursive :: proc(
	graph: ^Module_Graph,
	file_path: string,
	is_entry: bool,
	importer_span: Span = {},
) -> ^Module {
	module_key := resolve_import_path(file_path, "")
	if module, found := graph.modules[module_key]; found {
		return module
	}
	if graph.loading[module_key] {
		append(
			&graph.parse_diagnostics,
			Diagnostic {
				severity = .Error,
				span = importer_span,
				message = fmt.tprintf("Module Loader Error: обнаружен циклический импорт '%s'", file_path),
			},
		)
		return nil
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
		text, err_msg, read_ok := read_file_text(module_key)
		if !read_ok {
			append(
				&graph.parse_diagnostics,
				Diagnostic {
					severity = .Error,
					span = importer_span,
					message = fmt.tprintf("Module Loader Error: %s", err_msg),
				},
			)
			return nil
		}
		source = text
	}
	module.source = source
	graph.file_paths[module.file_id] = module_key
	graph.file_sources[module.file_id] = source

	tokens, lex_diags := tokenize(source, module.file_id)
	for d in lex_diags do append(&graph.parse_diagnostics, d)
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
				append(
					&graph.parse_diagnostics,
					Diagnostic {
						severity = .Error,
						span = import_decl.span,
						message = fmt.tprintf("Module Loader Error: модуль '%s' не найден", import_decl.path),
					},
				)
				continue
			}
			load_module_recursive(graph, import_path, false, import_decl.span)
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
// модулей, открытых сейчас как LSP-буферы. Остальные читаются с диска.
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
// порядке". Не гейтит и не прерывается на diagnostics — это решает
// вызывающий код (CLI хочет print+exit до компиляции, LSP хочет копить и
// публиковать per-file, без exit).
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
		// new_type_ctx(&res_ctx) выше указывал на ЛОКАЛЬНУЮ res_ctx; append
		// скопировал её значение в results, но tc_ctx.res всё ещё смотрит на
		// стек, недействительный по выходу из итерации. Перевешиваем на адрес
		// внутри массива.
		last := &results[len(results) - 1]
		last.tc_ctx.res = &last.res_ctx
		// Обновляем graph.symbol_types СРАЗУ, внутри итерации: следующий
		// модуль (зависящий от типов ЭТОГО модуля, напр. перечисление,
		// на которое ссылается через импорт) резолвит свой Type_Ctx ДО того,
		// как графовое присвоение снаружи цикла успело бы произойти. Без этой
		// строки cross-module ADT usage падает с "тип-владелец ещё не построен".
		graph.symbol_types = last.res_ctx.symbol_types
		// Найдено при отладке Стадии 22 (не её баг, см. Module_Graph.
		// symbol_schemes): тот же мотив, но symbol_schemes — НЕ шаренная
		// map (в отличие от symbol_types), а свежая копия на каждый
		// Type_Ctx (new_type_ctx) — накапливаем явно, не переприсваиванием
		// указателя. Без этого экспортированная generic-функция
		// (кол.отфильтровать/отсортировать и т.п.), вызванная из ДРУГОГО
		// модуля, не инстанцировалась бы заново на каждый call site —
		// первый же вызов "цементировал" бы T навсегда (symptom: "попытка
		// получить поле у не-структуры (тип: ?N)" на результате).
		if graph.symbol_schemes == nil {
			graph.symbol_schemes = make(map[Symbol_Id]Type_Scheme)
		}
		for sym, scheme in last.tc_ctx.symbol_schemes {
			graph.symbol_schemes[sym] = scheme
		}
		// Тот же мотив, что symbol_schemes выше — см. Module_Graph.decl_type_params.
		if graph.decl_type_params == nil {
			graph.decl_type_params = make(map[Symbol_Id]map[string]^Type)
		}
		for sym, params in last.tc_ctx.decl_type_params {
			graph.decl_type_params[sym] = params
		}
		// Тот же мотив, что decl_type_params выше — см. Module_Graph.decl_type_param_order.
		if graph.decl_type_param_order == nil {
			graph.decl_type_param_order = make(map[Symbol_Id][dynamic]^Type)
		}
		for sym, ordered in last.tc_ctx.decl_type_param_order {
			graph.decl_type_param_order[sym] = ordered
		}
		// См. Module_Graph.module_resolvers — &last.res_ctx стабилен
		// (preallocated results, см. комментарий выше).
		if graph.module_resolvers == nil {
			graph.module_resolvers = make(map[^Module]^Resolver_Ctx)
		}
		graph.module_resolvers[module] = &last.res_ctx
		// Стадия 45: тот же мотив/паттерн, что symbol_schemes выше — см.
		// Module_Graph.process_message_types.
		if graph.process_message_types == nil {
			graph.process_message_types = make(map[Symbol_Id]^Type)
		}
		for sym, t in last.tc_ctx.process_message_types {
			graph.process_message_types[sym] = t
		}
	}
	return results
}
