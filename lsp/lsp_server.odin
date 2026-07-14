#+feature dynamic-literals
package main

import core "../core"
import "core:encoding/json"
import "core:strings"

// Каждый открытый в редакторе документ разбирается вместе со своим графом
// импортов (core.Module_Graph). Открытые документы подставляются в граф как
// in-memory overrides (см. core.load_module_graph_with_overrides): их текст
// мог измениться в редакторе и ещё не быть сохранён на диск. Остальные модули
// графа читаются с диска. file_id — id ENTRY-модуля внутри его собственного
// графа; graph хранится целиком, чтобы go-to-definition мог указать на символ
// в другом файле (граф даёт file_id -> путь через graph.file_paths).
LSP_Document :: struct {
	uri:     string,
	path:    string, // абсолютный путь на диске, извлечённый из uri
	source:  string,
	file_id: u16,
	graph:   core.Module_Graph,
	prog:    core.Program,
	res_ctx: core.Resolver_Ctx,
	tc_ctx:  core.Type_Ctx,
	// resolve/typecheck diagnostics со всех модулей графа (не только entry):
	// ошибка в импортированной зависимости тоже должна попасть в diagnostics,
	// а не потеряться вместе с отброшенным Resolver_Ctx/Type_Ctx.
	all_diagnostics: [dynamic]core.Diagnostic,
	// Module_Result по каждому модулю графа — нужен build_usages, чтобы
	// find-references/rename видели использования символа во всех файлах графа.
	// Symbol_Id сравним между модулями — Symbol_Store общий на весь граф
	// (resolver.odin, graph.symbol_store).
	results: [dynamic]core.Module_Result,
	// Symbol_Id -> все места использования во всём графе (для
	// find-references/rename). Не включает span объявления — тот берётся
	// напрямую из symbol_at(...).span. Span несёт свой file_id —
	// межмодульность бесплатна, отдельной группировки по файлам не нужно.
	usages:  map[core.Symbol_Id][dynamic]core.Span,
}

LSP_Server :: struct {
	documents: map[string]^LSP_Document,
}

run_lsp_server :: proc() {
	server: LSP_Server
	server.documents = make(map[string]^LSP_Document)

	reader: LSP_Reader
	lsp_reader_init(&reader)

	for {
		msg, ok := lsp_read_message(&reader)
		if !ok do return // stdin закрыт клиентом — выходим тихо

		obj, is_obj := msg.(json.Object)
		if !is_obj do continue
		method := json_str(msg, "method")
		if method == "" do continue // это ответ НА НАШ запрос — мы запросов клиенту не шлём

		params := json_get(msg, "params")
		id_val, has_id := obj["id"]

		switch method {
		case "initialize":
			handle_initialize(id_val)
		case "initialized":
		// notification от клиента после инициализации — квитировать нечем
		case "shutdown":
			send_response(id_val, nil)
		case "exit":
			return
		case "textDocument/didOpen":
			handle_did_open(&server, params)
		case "textDocument/didChange":
			handle_did_change(&server, params)
		case "textDocument/didClose":
			handle_did_close(&server, params)
		case "textDocument/hover":
			handle_hover(&server, id_val, params)
		case "textDocument/definition":
			handle_definition(&server, id_val, params)
		case "textDocument/completion":
			handle_completion(&server, id_val, params)
		case "textDocument/references":
			handle_references(&server, id_val, params)
		case "textDocument/rename":
			handle_rename(&server, id_val, params)
		case:
			if has_id {
				send_error_response(id_val, -32601, "method not found")
			}
		}
	}
}

handle_initialize :: proc(id: json.Value) {
	result := json.Object {
		"capabilities" = json.Object {
			"textDocumentSync" = json.Integer(1), // Full sync: клиент шлёт весь текст, не incremental-дельты
			"hoverProvider" = json.Boolean(true),
			"definitionProvider" = json.Boolean(true),
			"completionProvider" = json.Object{},
			"referencesProvider" = json.Boolean(true),
			"renameProvider" = json.Boolean(true),
		},
	}
	send_response(id, result)
}

handle_did_open :: proc(server: ^LSP_Server, params: json.Value) {
	text_document := json_get(params, "textDocument")
	uri := json_str(text_document, "uri")
	text := json_str(text_document, "text")
	update_document(server, uri, text)
}

handle_did_change :: proc(server: ^LSP_Server, params: json.Value) {
	text_document := json_get(params, "textDocument")
	uri := json_str(text_document, "uri")
	changes := json_get(params, "contentChanges")
	arr, ok := changes.(json.Array)
	if !ok || len(arr) == 0 do return
	// Full sync (textDocumentSync = 1): последний change содержит весь текст.
	text := json_str(arr[len(arr) - 1], "text")
	update_document(server, uri, text)
}

handle_did_close :: proc(server: ^LSP_Server, params: json.Value) {
	text_document := json_get(params, "textDocument")
	uri := json_str(text_document, "uri")
	delete_key(&server.documents, uri)
}

// file:///abs/path -> /abs/path. Не декодирует %XX-escape'ы — для
// локальных путей без пробелов/юникода в самом пути этого достаточно
// (MVP, как и остальные LSP-хелперы здесь).
uri_to_path :: proc(uri: string) -> string {
	prefix :: "file://"
	if strings.has_prefix(uri, prefix) {
		return uri[len(prefix):]
	}
	return uri
}

path_to_uri :: proc(path: string) -> string {
	return strings.concatenate({"file://", path})
}

update_document :: proc(server: ^LSP_Server, uri: string, text: string) {
	doc, existed := server.documents[uri]
	if !existed {
		doc = new(LSP_Document)
		doc.uri = uri
		doc.path = uri_to_path(uri)
		server.documents[uri] = doc
	}
	doc.source = strings.clone(text)

	// Изменившийся документ может быть чьей-то зависимостью: если util.ps
	// редактируется (ещё не сохранён), импортирующий его main.ps должен
	// пересчитаться тоже, иначе его diagnostics устареют до следующей правки
	// main.ps. Пересчитываем все открытые документы, не только изменившийся —
	// для типичного числа открытых файлов это дёшево, в отличие от честного
	// dependency-tracking.
	for _, other_doc in server.documents {
		revalidate_document(server, other_doc)
	}
}

revalidate_document :: proc(server: ^LSP_Server, doc: ^LSP_Document) {
	// Открытые документы подставляются вместо чтения с диска — включая
	// сам doc (его .source уже актуален на момент вызова).
	overrides := make(map[string]string)
	for _, other_doc in server.documents {
		key := core.resolve_import_path(other_doc.path, "")
		overrides[key] = other_doc.source
	}

	graph := core.load_module_graph_with_overrides(doc.path, overrides)
	entry_key := core.resolve_import_path(doc.path, "")
	entry_module := graph.modules[entry_key]
	if entry_module == nil {
		// Не должно случиться (entry всегда грузится первым в
		// load_module_recursive), но на всякий случай не падаем молча.
		return
	}

	doc.graph = graph
	doc.prog = entry_module.ast
	doc.file_id = entry_module.file_id

	results := core.resolve_and_typecheck_all(&graph)
	all_diagnostics := make([dynamic]core.Diagnostic)
	for i in 0 ..< len(results) {
		r := &results[i]
		for d in r.res_ctx.diagnostics do append(&all_diagnostics, d)
		for d in r.tc_ctx.diagnostics do append(&all_diagnostics, d)
		if r.module == entry_module {
			doc.res_ctx = r.res_ctx
			doc.tc_ctx = r.tc_ctx
		}
	}
	doc.all_diagnostics = all_diagnostics
	doc.results = results

	build_usages(doc)

	publish_diagnostics(server, doc)
}

// Symbol_Id -> [span использования, ...] — проход по node_symbols
// (Expr -> Symbol_Id) всех модулей графа. Symbol_Id сравним между ними
// (общий Symbol_Store на граф, см. LSP_Document.results). Объявление не
// входит (доступно через symbol_at(...).span отдельно) — в node_symbols
// попадают только Ident/Property-узлы, ссылающиеся на символ, а не место его
// создания (Let_Stmt.name — строка, не Expr-узел). Span несёт свой file_id —
// межмодульность бесплатна.
build_usages :: proc(doc: ^LSP_Document) {
	doc.usages = make(map[core.Symbol_Id][dynamic]core.Span)
	for i in 0 ..< len(doc.results) {
		r := &doc.results[i]
		for expr, sym_id in r.res_ctx.node_symbols {
			sp := core.expr_span(expr)
			list := doc.usages[sym_id]
			append(&list, sp)
			doc.usages[sym_id] = list
		}
	}
}

// Публикует diagnostics для всех модулей графа: ошибка в импортированном
// модуле тоже должна куда-то попасть, а не молча проглатываться. Группирует
// по file_id, шлёт одно уведомление на файл (даже если тот сейчас не открыт в
// редакторе — publishDiagnostics это не требует).
publish_diagnostics :: proc(server: ^LSP_Server, doc: ^LSP_Document) {
	by_file := make(map[u16][dynamic]core.Diagnostic, allocator = context.temp_allocator)

	collect :: proc(by_file: ^map[u16][dynamic]core.Diagnostic, list: [dynamic]core.Diagnostic) {
		for d in list {
			bucket := by_file[d.span.file_id]
			append(&bucket, d)
			by_file[d.span.file_id] = bucket
		}
	}
	collect(&by_file, doc.graph.parse_diagnostics)
	collect(&by_file, doc.all_diagnostics)

	// Файлы графа без единой diagnostic'и тоже должны получить пустой
	// список — иначе старые diagnostics для файла, который только что
	// починили, останутся висеть в редакторе.
	for _, module in doc.graph.modules {
		if module.file_id not_in by_file {
			by_file[module.file_id] = nil
		}
	}

	for file_id, file_diags in by_file {
		source := doc.graph.file_sources[file_id]
		path := doc.graph.file_paths[file_id]
		file_uri := path_to_uri(path)

		diags := make([dynamic]json.Value, 0, len(file_diags))
		for d in file_diags {
			append(
				&diags,
				json.Value(
					json.Object {
						"range" = lsp_range_json(source, d.span.start, d.span.end),
						"severity" = json.Integer(1), // Error
						"message" = json.String(d.message),
					},
				),
			)
		}

		send_notification(
			"textDocument/publishDiagnostics",
			json.Object{"uri" = json.String(file_uri), "diagnostics" = json.Array(diags)},
		)
	}
}

handle_hover :: proc(server: ^LSP_Server, id: json.Value, params: json.Value) {
	doc, offset, ok := resolve_position(server, params)
	if !ok {
		send_response(id, nil)
		return
	}

	expr := core.find_expr_in_program(doc.prog, doc.file_id, offset)
	if expr == nil {
		send_response(id, nil)
		return
	}

	typ, has_type := doc.tc_ctx.node_types[expr]
	if !has_type || typ == nil {
		send_response(id, nil)
		return
	}

	sp := core.expr_span(expr)
	result := json.Object {
		"contents" = json.Object {
			"kind" = json.String("plaintext"),
			"value" = json.String(core.prune_type(typ).name),
		},
		"range" = lsp_range_json(doc.source, sp.start, sp.end),
	}
	send_response(id, result)
}

handle_definition :: proc(server: ^LSP_Server, id: json.Value, params: json.Value) {
	doc, offset, ok := resolve_position(server, params)
	if !ok {
		send_response(id, nil)
		return
	}

	expr := core.find_expr_in_program(doc.prog, doc.file_id, offset)
	if expr == nil {
		send_response(id, nil)
		return
	}

	sym_id, has_sym := doc.res_ctx.node_symbols[expr]
	if !has_sym || sym_id == core.INVALID_SYMBOL {
		send_response(id, nil)
		return
	}
	// symbol_store общий на весь граф импортов (graph.symbol_store) —
	// symbol_at корректно резолвит символ, даже если он объявлен в
	// ДРУГОМ модуле (импортированном), не только в текущем документе.
	sym := core.symbol_at(doc.res_ctx.symbol_store, sym_id)
	if sym.kind == .Builtin {
		// Ошибка/Есть/Нет/Успех/Неудача/длина/паника — span нулевой
		// (install_standard_symbols не задаёт его), некуда прыгать.
		send_response(id, nil)
		return
	}

	target_source := doc.source
	target_uri := doc.uri
	if sym.span.file_id != doc.file_id {
		target_source = doc.graph.file_sources[sym.span.file_id]
		target_uri = path_to_uri(doc.graph.file_paths[sym.span.file_id])
	}

	result := json.Object {
		"uri" = json.String(target_uri),
		"range" = lsp_range_json(target_source, sym.span.start, sym.span.end),
	}
	send_response(id, result)
}

// Общая часть hover/definition: достаёт документ и byte offset курсора.
resolve_position :: proc(server: ^LSP_Server, params: json.Value) -> (^LSP_Document, u32, bool) {
	text_document := json_get(params, "textDocument")
	uri := json_str(text_document, "uri")
	position := json_get(params, "position")
	line := json_int(position, "line")
	character := json_int(position, "character")

	doc, found := server.documents[uri]
	if !found do return nil, 0, false

	offset := core.lsp_position_to_byte_offset(doc.source, line, character)
	return doc, offset, true
}

completion_kind :: proc(kind: core.Symbol_Kind) -> int {
	// LSP CompletionItemKind: Function=3, Variable=6, Class=7, Module=9,
	// EnumMember=20.
	switch kind {
	case .Function:
		return 3
	case .Variable:
		return 6
	case .Type:
		return 7
	case .Module:
		return 9
	case .Builtin:
		return 3
	case .Enum_Variant:
		return 20
	}
	return 1
}

// LSP CompletionItemKind для core.Completion_Member_Kind (Field=5, Method=2,
// EnumMember=20 — та же нумерация, что уже использует completion_kind).
member_completion_kind :: proc(kind: core.Completion_Member_Kind) -> int {
	switch kind {
	case .Field:
		return 5
	case .Method:
		return 2
	case .Variant:
		return 20
	}
	return 1
}

// scope-aware enumeration (MVP): глобальные символы модуля (включая алиасы
// импортов как Module-kind символы — сами экспорты импортированного
// модуля не разворачиваются, обращение к ним всегда через `модуль.имя`)
// + параметры и локальные переменные объемлющей функции/метода (без
// точной блочной видимости по позиции — см. collect_local_symbols).
handle_completion :: proc(server: ^LSP_Server, id: json.Value, params: json.Value) {
	doc, offset, ok := resolve_position(server, params)
	if !ok {
		send_response(id, json.Array{})
		return
	}

	// Dot-режим: курсор сразу после `receiver.` — вместо плоского scope-дампа
	// показываем поля/методы/варианты резолвленного типа receiver'а. Ищем на
	// offset-2, а не offset-1: span_contains использует [start,end) с
	// исключённым концом, точка лежит вне span'а receiver'а — нужен последний
	// байт receiver'а перед точкой (напр. "p." — точка на byte 2, "p" занимает
	// [1,2), ищем на 1). node_types даёт тип найденного узла (см.
	// core.type_completion_members, core/completion.odin).
	if offset > 1 && offset <= u32(len(doc.source)) && doc.source[offset - 1] == '.' {
		receiver_expr := core.find_expr_in_program(doc.prog, doc.file_id, offset - 2)
		if receiver_expr != nil {
			if typ, has_type := doc.tc_ctx.node_types[receiver_expr]; has_type && typ != nil {
				members := core.type_completion_members(typ)
				dot_items := make([dynamic]json.Value)
				dot_seen := make(map[string]bool, allocator = context.temp_allocator)
				for m in members {
					if m.name == "" || dot_seen[m.name] do continue
					dot_seen[m.name] = true
					append(
						&dot_items,
						json.Value(
							json.Object{"label" = json.String(m.name), "kind" = json.Integer(i64(member_completion_kind(m.kind)))},
						),
					)
				}
				send_response(id, json.Array(dot_items))
				return
			}
		}
		send_response(id, json.Array{})
		return
	}

	items := make([dynamic]json.Value)
	seen := make(map[string]bool, allocator = context.temp_allocator)

	add_item := proc(items: ^[dynamic]json.Value, seen: ^map[string]bool, name: string, kind: int) {
		if name == "" || seen[name] do return
		seen[name] = true
		append(items, json.Value(json.Object{"label" = json.String(name), "kind" = json.Integer(i64(kind))}))
	}

	for name_id, sym_id in doc.res_ctx.global_scope.symbols {
		sym := core.symbol_at(doc.res_ctx.symbol_store, sym_id)
		add_item(&items, &seen, core.resolve_interned(name_id), completion_kind(sym.kind))
	}

	decl := core.find_enclosing_decl(doc.prog, doc.file_id, offset)
	body_and_args :: proc(
		res: ^core.Resolver_Ctx,
		decl: core.Decls,
		body: [dynamic]core.Stmt,
		items: ^[dynamic]json.Value,
		seen: ^map[string]bool,
		add_item: proc(^[dynamic]json.Value, ^map[string]bool, string, int),
	) {
		if args, ok := res.func_args[decl]; ok {
			for a in args {
				sym := core.symbol_at(res.symbol_store, a)
				add_item(items, seen, core.resolve_interned(sym.name), completion_kind(sym.kind))
			}
		}
		locals := make([dynamic]core.Symbol_Id, context.temp_allocator)
		core.collect_local_symbols(res, body, &locals)
		for l in locals {
			sym := core.symbol_at(res.symbol_store, l)
			add_item(items, seen, core.resolve_interned(sym.name), completion_kind(sym.kind))
		}
	}
	if decl != nil {
		#partial switch d in decl {
		case ^core.Function_Decl:
			body_and_args(&doc.res_ctx, decl, d.body, &items, &seen, add_item)
		case ^core.Impl_Decl:
			for m in d.methods {
				if core.span_contains(m.span, doc.file_id, offset) {
					body_and_args(&doc.res_ctx, m, m.body, &items, &seen, add_item)
				}
			}
		}
	}

	send_response(id, json.Array(items))
}

// Собирает Location[] по Symbol_Id: объявление (в этом или другом файле
// графа — symbol_store общий) + все usages ИЗ ЭТОГО документа (doc.usages
// не сканирует другие открытые файлы — см. ограничение в
// handle_references).
collect_locations :: proc(doc: ^LSP_Document, sym_id: core.Symbol_Id, include_decl: bool) -> [dynamic]json.Value {
	locations := make([dynamic]json.Value)
	if include_decl {
		decl_span := core.symbol_at(doc.res_ctx.symbol_store, sym_id).span
		decl_source := doc.source
		decl_uri := doc.uri
		if decl_span.file_id != doc.file_id {
			decl_source = doc.graph.file_sources[decl_span.file_id]
			decl_uri = path_to_uri(doc.graph.file_paths[decl_span.file_id])
		}
		append(
			&locations,
			json.Value(
				json.Object {
					"uri" = json.String(decl_uri),
					"range" = lsp_range_json(decl_source, decl_span.start, decl_span.end),
				},
			),
		)
	}
	for sp in doc.usages[sym_id] {
		// sp может лежать в ЛЮБОМ модуле графа (build_usages теперь
		// сканирует все) — тот же file_id-aware выбор источника/uri, что
		// уже используется для decl_span выше, а не всегда doc.uri/doc.source.
		usage_source := doc.source
		usage_uri := doc.uri
		if sp.file_id != doc.file_id {
			usage_source = doc.graph.file_sources[sp.file_id]
			usage_uri = path_to_uri(doc.graph.file_paths[sp.file_id])
		}
		append(
			&locations,
			json.Value(
				json.Object{"uri" = json.String(usage_uri), "range" = lsp_range_json(usage_source, sp.start, sp.end)},
			),
		)
	}
	return locations
}

// Известное ограничение MVP: find-references/rename сканируют usages
// ТОЛЬКО в текущем открытом документе, не по всему графу импортов/
// проекту — символ, объявленный в текущем файле и используемый в другом
// открытом файле, найдётся не полностью. Определение символа (в т.ч. в
// другом файле) резолвится корректно через общий symbol_store.
handle_references :: proc(server: ^LSP_Server, id: json.Value, params: json.Value) {
	doc, offset, ok := resolve_position(server, params)
	if !ok {
		send_response(id, nil)
		return
	}
	expr := core.find_expr_in_program(doc.prog, doc.file_id, offset)
	if expr == nil {
		send_response(id, nil)
		return
	}
	sym_id, has_sym := doc.res_ctx.node_symbols[expr]
	if !has_sym || sym_id == core.INVALID_SYMBOL {
		send_response(id, nil)
		return
	}

	include_decl := json_bool(json_get(params, "context"), "includeDeclaration")
	locations := collect_locations(doc, sym_id, include_decl)
	send_response(id, json.Array(locations))
}

handle_rename :: proc(server: ^LSP_Server, id: json.Value, params: json.Value) {
	doc, offset, ok := resolve_position(server, params)
	if !ok {
		send_response(id, nil)
		return
	}
	new_name := json_str(params, "newName")
	expr := core.find_expr_in_program(doc.prog, doc.file_id, offset)
	if expr == nil {
		send_response(id, nil)
		return
	}
	sym_id, has_sym := doc.res_ctx.node_symbols[expr]
	if !has_sym || sym_id == core.INVALID_SYMBOL {
		send_response(id, nil)
		return
	}

	locations := collect_locations(doc, sym_id, true)
	// changes сгруппирован по uri — declaration может лежать в ДРУГОМ
	// файле (импортированном модуле), чем usages.
	changes := make(json.Object)
	for loc in locations {
		obj := loc.(json.Object)
		uri := string(obj["uri"].(json.String))
		edit := json.Value(json.Object{"range" = obj["range"], "newText" = json.String(new_name)})
		if existing, found := changes[uri]; found {
			arr := existing.(json.Array)
			append(&arr, edit)
			changes[uri] = json.Value(arr)
		} else {
			changes[uri] = json.Value(json.Array{edit})
		}
	}
	result := json.Object{"changes" = json.Value(changes)}
	send_response(id, result)
}
