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

	server.documents[uri] = doc
	publish_diagnostics(doc)
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

	sym, has_sym := doc.res_ctx.node_symbols[expr]
	// sym.span.file_id != doc.file_id значит символ объявлен в другом
	// модуле/файле — межфайловый go-to-def не входит в MVP (нужен полный
	// граф импортов, а не single-file resolve_program).
	if !has_sym || sym == nil || sym.span.file_id != doc.file_id {
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
