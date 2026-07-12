#+feature dynamic-literals
package main

import core "../core"
import "core:encoding/json"
import "core:strings"

// Каждый открытый в редакторе документ — свой независимый прогон
// tokenize→parse→resolve→typecheck (single-file resolve_program, БЕЗ
// графа импортов — как e2e_test.odin::run_code). file_id свой на сервер
// (не пересекается с CLI-режимом main.odin), инкрементируется на каждое
// изменение — старые Type_Ctx/Resolver_Ctx от предыдущей версии документа
// просто перестают быть достижимы и никуда не используются повторно.
LSP_Document :: struct {
	uri:     string,
	source:  string,
	file_id: u16,
	prog:    core.Program,
	res_ctx: core.Resolver_Ctx,
	tc_ctx:  core.Type_Ctx,
	// Symbol_Id -> все места использования (для find-references/rename).
	// Не включает span объявления — тот берётся напрямую из symbol_at(...).span.
	usages:  map[core.Symbol_Id][dynamic]core.Span,
}

LSP_Server :: struct {
	documents:    map[string]^LSP_Document,
	next_file_id: u16,
}

// ВАЖНО (известное ограничение MVP): parse_program/resolve_program по-прежнему
// используют fmt.panicf на синтаксических/resolve-ошибках (только
// type_cheker.odin мигрирован на diagnostic accumulation в Стадии 2).
// Значит синтаксическая ошибка в редактируемом файле уронит весь LSP-процесс.
// vscode-languageclient по умолчанию перезапускает упавший сервер, так что
// это не фатально для MVP, но требует отдельной доработки (аналогичная
// миграция panicf→report для parser.odin/resolver.odin), если понадобится
// не терять diagnostics/hover-состояние при каждой опечатке.
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
			"textDocumentSync" = json.Integer(1), // Full — TASKS.md явно просит full-reparse, не incremental
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

update_document :: proc(server: ^LSP_Server, uri: string, text: string) {
	doc := new(LSP_Document)
	doc.uri = uri
	doc.source = strings.clone(text)
	doc.file_id = server.next_file_id
	server.next_file_id += 1

	tokens := core.tokenize(doc.source, doc.file_id)
	stream := core.make_stream(tokens)
	parser := core.Parser {
		stream  = &stream,
		file_id = doc.file_id,
	}
	doc.prog = core.parse_program(&parser)

	doc.res_ctx = core.new_resolver_ctx()
	core.resolve_program(&doc.res_ctx, doc.prog)

	doc.tc_ctx = core.new_type_ctx(&doc.res_ctx)
	core.typecheck_program(&doc.tc_ctx, doc.prog)

	build_usages(doc)

	server.documents[uri] = doc
	publish_diagnostics(doc)
}

// Symbol_Id -> [span использования, ...] — единственный проход по
// node_symbols (Expr -> Symbol_Id), заполненному резолвером. Объявление
// само по себе не входит (доступно через symbol_at(...).span отдельно) —
// в node_symbols попадают только Ident/Property-узлы, ссылающиеся НА
// символ, а не место его создания (Let_Stmt.name — строка, не Expr-узел).
build_usages :: proc(doc: ^LSP_Document) {
	doc.usages = make(map[core.Symbol_Id][dynamic]core.Span)
	for expr, sym_id in doc.res_ctx.node_symbols {
		sp := core.expr_span(expr)
		list := doc.usages[sym_id]
		append(&list, sp)
		doc.usages[sym_id] = list
	}
}

publish_diagnostics :: proc(doc: ^LSP_Document) {
	diags := make([dynamic]json.Value, 0, len(doc.tc_ctx.diagnostics))
	for d in doc.tc_ctx.diagnostics {
		append(
			&diags,
			json.Value(
				json.Object {
					"range" = lsp_range_json(doc.source, d.span.start, d.span.end),
					"severity" = json.Integer(1), // Error
					"message" = json.String(d.message),
				},
			),
		)
	}

	send_notification(
		"textDocument/publishDiagnostics",
		json.Object{"uri" = json.String(doc.uri), "diagnostics" = json.Array(diags)},
	)
}

handle_hover :: proc(server: ^LSP_Server, id: json.Value, params: json.Value) {
	doc, offset, ok := resolve_position(server, params)
	if !ok {
		send_response(id, nil)
		return
	}

	expr := find_expr_in_program(doc.prog, doc.file_id, offset)
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

	expr := find_expr_in_program(doc.prog, doc.file_id, offset)
	if expr == nil {
		send_response(id, nil)
		return
	}

	sym_id, has_sym := doc.res_ctx.node_symbols[expr]
	// sym.span.file_id != doc.file_id значит символ объявлен в другом
	// модуле/файле — межфайловый go-to-def не входит в MVP (нужен полный
	// граф импортов, а не single-file resolve_program).
	if !has_sym || sym_id == core.INVALID_SYMBOL {
		send_response(id, nil)
		return
	}
	sym := core.symbol_at(doc.res_ctx.symbol_store, sym_id)
	if sym.span.file_id != doc.file_id {
		send_response(id, nil)
		return
	}

	result := json.Object {
		"uri" = json.String(doc.uri),
		"range" = lsp_range_json(doc.source, sym.span.start, sym.span.end),
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

	offset := lsp_position_to_byte_offset(doc.source, line, character)
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

// scope-aware enumeration (MVP): глобальные символы модуля + параметры и
// локальные переменные объемлющей функции/метода (без точной блочной
// видимости по позиции — см. collect_local_symbols).
handle_completion :: proc(server: ^LSP_Server, id: json.Value, params: json.Value) {
	doc, offset, ok := resolve_position(server, params)
	if !ok {
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

	decl := find_enclosing_decl(doc.prog, doc.file_id, offset)
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
		collect_local_symbols(res, body, &locals)
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
				if span_contains(m.span, doc.file_id, offset) {
					body_and_args(&doc.res_ctx, m, m.body, &items, &seen, add_item)
				}
			}
		}
	}

	send_response(id, json.Array(items))
}

// Собирает Location[] по Symbol_Id: объявление (если includeDeclaration и
// оно в этом же файле) + все usages из doc.usages.
collect_locations :: proc(doc: ^LSP_Document, sym_id: core.Symbol_Id, include_decl: bool) -> [dynamic]json.Value {
	locations := make([dynamic]json.Value)
	if include_decl {
		decl_span := core.symbol_at(doc.res_ctx.symbol_store, sym_id).span
		if decl_span.file_id == doc.file_id {
			append(
				&locations,
				json.Value(
					json.Object {
						"uri" = json.String(doc.uri),
						"range" = lsp_range_json(doc.source, decl_span.start, decl_span.end),
					},
				),
			)
		}
	}
	for sp in doc.usages[sym_id] {
		append(
			&locations,
			json.Value(
				json.Object{"uri" = json.String(doc.uri), "range" = lsp_range_json(doc.source, sp.start, sp.end)},
			),
		)
	}
	return locations
}

// Межфайловый find-references/rename не входит в MVP — как и go-to-def,
// работает только в пределах открытого документа (single-file
// resolve_program, без графа импортов).
handle_references :: proc(server: ^LSP_Server, id: json.Value, params: json.Value) {
	doc, offset, ok := resolve_position(server, params)
	if !ok {
		send_response(id, nil)
		return
	}
	expr := find_expr_in_program(doc.prog, doc.file_id, offset)
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
	expr := find_expr_in_program(doc.prog, doc.file_id, offset)
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
	edits := make([dynamic]json.Value)
	for loc in locations {
		obj := loc.(json.Object)
		append(&edits, json.Value(json.Object{"range" = obj["range"], "newText" = json.String(new_name)}))
	}

	changes := make(json.Object)
	changes[doc.uri] = json.Array(edits)
	result := json.Object{"changes" = json.Value(changes)}
	send_response(id, result)
}
