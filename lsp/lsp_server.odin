package main

import core "../core"
import proto "protocol"
import "core:encoding/json"
import "core:fmt"
import "core:slice"
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
		data, ok := lsp_read_message(&reader)
		if !ok do return // stdin закрыт клиентом — выходим тихо

		envelope: RPC_Envelope
		if uerr := json.unmarshal(data, &envelope); uerr != nil {
			fmt.eprintln("panos-lsp: не смог разобрать envelope:", uerr, "raw:", string(data))
			continue
		}
		if envelope.method == "" do continue // это ответ НА НАШ запрос — мы запросов клиенту не шлём

		id_val := envelope.id
		params := envelope.params

		switch envelope.method {
		case "initialize":
			handle_initialize(id_val)
		case "initialized":
		// notification от клиента после инициализации — квитировать нечем
		case "shutdown":
			send_null_response(id_val)
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
		case "textDocument/prepareRename":
			handle_prepare_rename(&server, id_val, params)
		case "textDocument/rename":
			handle_rename(&server, id_val, params)
		case "textDocument/semanticTokens/full":
			handle_semantic_tokens(&server, id_val, params)
		case "textDocument/documentHighlight":
			handle_document_highlight(&server, id_val, params)
		case "textDocument/foldingRange":
			handle_folding_range(&server, id_val, params)
		case "textDocument/documentSymbol":
			handle_document_symbol(&server, id_val, params)
		case "textDocument/signatureHelp":
			handle_signature_help(&server, id_val, params)
		case "workspace/symbol":
			handle_workspace_symbol(&server, id_val, params)
		case "textDocument/codeLens":
			handle_code_lens(&server, id_val, params)
		case "textDocument/selectionRange":
			handle_selection_range(&server, id_val, params)
		case:
			if envelope.id != nil {
				send_error_response(id_val, -32601, "method not found")
			}
		}
	}
}

handle_initialize :: proc(id: json.Value) {
	result := proto.InitializeResult {
		capabilities = proto.ServerCapabilities {
			text_document_sync = proto.TextDocumentSyncKind.Full, // клиент шлёт весь текст, не incremental-дельты
			hover_provider = true,
			definition_provider = true,
			completion_provider = proto.CompletionOptions{},
			references_provider = true,
			rename_provider = proto.RenameOptions{prepare_provider = true},
			document_highlight_provider = true,
			folding_range_provider = true,
			document_symbol_provider = true,
			signature_help_provider = proto.SignatureHelpOptions{trigger_characters = []string{"(", ","}},
			workspace_symbol_provider = true,
			code_lens_provider = proto.CodeLensOptions{},
			selection_range_provider = true,
			semantic_tokens_provider = proto.SemanticTokensOptions {
				legend = proto.SemanticTokensLegend {
					token_types = core.SEMANTIC_TOKEN_TYPE_NAMES[:],
					token_modifiers = []string{},
				},
				full = true,
			},
		},
	}
	send_response(id, result)
}

handle_did_open :: proc(server: ^LSP_Server, params: json.Value) {
	p, ok := decode_params(proto.DidOpenTextDocumentParams, params)
	if !ok do return
	update_document(server, string(p.text_document.uri), p.text_document.text)
}

// Full sync (textDocumentSync = 1): contentChanges — не honest incremental
// TextDocumentContentChangeEvent (union range+text/text-only), а всегда
// последний элемент с полным текстом документа — поэтому не декодируем
// в proto.TextDocumentContentChangeEvent (union из двух вариантов,
// unmarshal в union не умеет выбирать вариант по форме JSON, см. commit
// message), а забираем поле text напрямую: оно есть у обоих вариантов.
Did_Change_Params :: struct {
	text_document:   proto.VersionedTextDocumentIdentifier `json:"textDocument"`,
	content_changes: []struct {
		text: string `json:"text"`,
	} `json:"contentChanges"`,
}

handle_did_change :: proc(server: ^LSP_Server, params: json.Value) {
	p, ok := decode_params(Did_Change_Params, params)
	if !ok || len(p.content_changes) == 0 do return
	text := p.content_changes[len(p.content_changes) - 1].text
	update_document(server, string(p.text_document.uri), text)
}

handle_did_close :: proc(server: ^LSP_Server, params: json.Value) {
	p, ok := decode_params(proto.DidCloseTextDocumentParams, params)
	if !ok do return
	delete_key(&server.documents, string(p.text_document.uri))
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

		diags := make([dynamic]proto.Diagnostic, 0, len(file_diags))
		for d in file_diags {
			append(
				&diags,
				proto.Diagnostic {
					range = lsp_range(source, d.span.start, d.span.end),
					severity = proto.DiagnosticSeverity.Error,
					message = d.message,
				},
			)
		}

		send_notification(
			"textDocument/publishDiagnostics",
			proto.PublishDiagnosticsParams{uri = proto.DocumentUri(file_uri), diagnostics = diags[:]},
		)
	}
}

handle_hover :: proc(server: ^LSP_Server, id: json.Value, params: json.Value) {
	doc, offset, ok := resolve_position(server, params)
	if !ok {
		send_null_response(id)
		return
	}

	expr := core.find_expr_in_program(doc.prog, doc.file_id, offset)
	if expr == nil {
		send_null_response(id)
		return
	}

	typ, has_type := doc.tc_ctx.node_types[expr]
	if !has_type || typ == nil {
		send_null_response(id)
		return
	}

	sym_id, has_sym := doc.res_ctx.node_symbols[expr]
	sym: core.Symbol
	if has_sym && sym_id != core.INVALID_SYMBOL {
		sym = core.symbol_at(doc.res_ctx.symbol_store, sym_id)
	}

	// Type.name у Function-типа — просто константа "Function" (см.
	// new_function_type в type_cheker.odin), бесполезно для hover'а.
	// Собираем читаемую сигнатуру из typ.params/typ.return_type (уже
	// вычислены тайпчекером) + имена параметров через Symbol.decl — тот же
	// приём, что compute_signature_help в signature_help.odin.
	pruned := core.prune_type(typ)
	hover_text: string
	if pruned.kind == .Function {
		param_names: [dynamic]string
		if has_sym {
			if fd, is_fn := sym.decl.(^core.Function_Decl); is_fn {
				for a in fd.args do append(&param_names, a.name)
			}
		}
		parts := make([dynamic]string, 0, len(pruned.params), context.temp_allocator)
		for pt, i in pruned.params {
			name := i < len(param_names) ? param_names[i] : ""
			label := name != "" ? fmt.tprintf("%s: %s", name, core.prune_type(pt).name) : core.prune_type(pt).name
			append(&parts, label)
		}
		hover_text = fmt.tprintf("(%s) -> %s", strings.join(parts[:], ", "), core.prune_type(pruned.return_type).name)
	} else {
		hover_text = pruned.name
	}

	// Докстринг (`///`, см. Function_Decl.doc/decl_doc_comment) — тот же
	// путь к декларации, что handle_definition (node_symbols -> Symbol.decl),
	// добавляется под типом отдельным абзацем, если есть.
	if has_sym {
		if doc_comment := core.decl_doc_comment(sym.decl); doc_comment != "" {
			hover_text = fmt.tprintf("%s\n\n%s", hover_text, doc_comment)
		}
	}

	sp := core.expr_span(expr)
	result := proto.Hover {
		contents = proto.MarkupContent{kind = proto.MarkupKind_PlainText, value = hover_text},
		range = lsp_range(doc.source, sp.start, sp.end),
	}
	send_response(id, result)
}

handle_definition :: proc(server: ^LSP_Server, id: json.Value, params: json.Value) {
	doc, offset, ok := resolve_position(server, params)
	if !ok {
		send_null_response(id)
		return
	}

	expr := core.find_expr_in_program(doc.prog, doc.file_id, offset)
	if expr == nil {
		send_null_response(id)
		return
	}

	sym_id, has_sym := doc.res_ctx.node_symbols[expr]
	if !has_sym || sym_id == core.INVALID_SYMBOL {
		send_null_response(id)
		return
	}
	// symbol_store общий на весь граф импортов (graph.symbol_store) —
	// symbol_at корректно резолвит символ, даже если он объявлен в
	// ДРУГОМ модуле (импортированном), не только в текущем документе.
	sym := core.symbol_at(doc.res_ctx.symbol_store, sym_id)
	if sym.kind == .Builtin {
		// Ошибка/Есть/Нет/Успех/Неудача/длина/паника — span нулевой
		// (install_standard_symbols не задаёт его), некуда прыгать.
		send_null_response(id)
		return
	}

	target_source := doc.source
	target_uri := doc.uri
	if sym.span.file_id != doc.file_id {
		target_source = doc.graph.file_sources[sym.span.file_id]
		target_uri = path_to_uri(doc.graph.file_paths[sym.span.file_id])
	}

	// Function_Decl.name_span — прыгаем точно на имя, не на всю декларацию
	// (сейчас есть только у функций — Struct/Enum/Interface своего
	// name_span не имеют, там по-прежнему весь span).
	jump_span := sym.span
	if fd, is_fn := sym.decl.(^core.Function_Decl); is_fn && fd.name_span.end > fd.name_span.start {
		jump_span = fd.name_span
	}

	result := proto.Location {
		uri   = proto.DocumentUri(target_uri),
		range = lsp_range(target_source, jump_span.start, jump_span.end),
	}
	send_response(id, result)
}

// textDocument/position — форма, общая для hover/definition/completion/
// references/rename (все proto.*Params имеют эту пару полей плюс что-то
// своё); decode_params игнорирует лишние поля, так что достаточно
// декодировать только этот срез, а не полный proto.HoverParams и т.п.
Text_Document_Position_Params :: struct {
	text_document: proto.TextDocumentIdentifier `json:"textDocument"`,
	position:      proto.Position               `json:"position"`,
}

// Общая часть hover/definition/etc: достаёт документ и byte offset курсора.
resolve_position :: proc(server: ^LSP_Server, params: json.Value) -> (^LSP_Document, u32, bool) {
	p, ok := decode_params(Text_Document_Position_Params, params)
	if !ok do return nil, 0, false

	doc, found := server.documents[string(p.text_document.uri)]
	if !found do return nil, 0, false

	offset := core.lsp_position_to_byte_offset(doc.source, int(p.position.line), int(p.position.character))
	return doc, offset, true
}

completion_kind :: proc(kind: core.Symbol_Kind) -> proto.CompletionItemKind {
	switch kind {
	case .Function:
		return .Function
	case .Variable:
		return .Variable
	case .Type:
		return .Class
	case .Module:
		return .Module
	case .Builtin:
		return .Function
	case .Enum_Variant:
		return .EnumMember
	}
	return .Text
}

// LSP CompletionItemKind для core.Completion_Member_Kind (Field/Method/
// EnumMember — та же нумерация, что уже использует completion_kind).
member_completion_kind :: proc(kind: core.Completion_Member_Kind) -> proto.CompletionItemKind {
	switch kind {
	case .Field:
		return .Field
	case .Method:
		return .Method
	case .Variant:
		return .EnumMember
	}
	return .Text
}

// scope-aware enumeration (MVP): глобальные символы модуля (включая алиасы
// импортов как Module-kind символы — сами экспорты импортированного
// модуля не разворачиваются, обращение к ним всегда через `модуль.имя`)
// + параметры и локальные переменные объемлющей функции/метода (без
// точной блочной видимости по позиции — см. collect_local_symbols).
handle_completion :: proc(server: ^LSP_Server, id: json.Value, params: json.Value) {
	doc, offset, ok := resolve_position(server, params)
	if !ok {
		send_response(id, []proto.CompletionItem{})
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
				dot_items := make([dynamic]proto.CompletionItem)
				dot_seen := make(map[string]bool, allocator = context.temp_allocator)
				for m in members {
					if m.name == "" || dot_seen[m.name] do continue
					dot_seen[m.name] = true
					append(&dot_items, proto.CompletionItem{label = m.name, kind = member_completion_kind(m.kind)})
				}
				send_response(id, dot_items[:])
				return
			}
		}
		send_response(id, []proto.CompletionItem{})
		return
	}

	items := make([dynamic]proto.CompletionItem)
	seen := make(map[string]bool, allocator = context.temp_allocator)

	add_item := proc(items: ^[dynamic]proto.CompletionItem, seen: ^map[string]bool, name: string, kind: proto.CompletionItemKind) {
		if name == "" || seen[name] do return
		seen[name] = true
		append(items, proto.CompletionItem{label = name, kind = kind})
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
		items: ^[dynamic]proto.CompletionItem,
		seen: ^map[string]bool,
		add_item: proc(^[dynamic]proto.CompletionItem, ^map[string]bool, string, proto.CompletionItemKind),
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

	send_response(id, items[:])
}

// Собирает Location[] по Symbol_Id: объявление (в этом или другом файле
// графа — symbol_store общий) + все usages ИЗ ЭТОГО документа, ПЛЮС usages
// из других открытых документов, чей граф ЭТУ декларацию не видит "снизу
// вверх" — см. merge_cross_document_usages.
collect_locations :: proc(
	server: ^LSP_Server,
	doc: ^LSP_Document,
	sym_id: core.Symbol_Id,
	include_decl: bool,
) -> [dynamic]proto.Location {
	locations := make([dynamic]proto.Location)
	decl_span := core.symbol_at(doc.res_ctx.symbol_store, sym_id).span
	decl_source := doc.source
	decl_uri := doc.uri
	decl_path := doc.path
	if decl_span.file_id != doc.file_id {
		decl_source = doc.graph.file_sources[decl_span.file_id]
		decl_uri = path_to_uri(doc.graph.file_paths[decl_span.file_id])
		decl_path = doc.graph.file_paths[decl_span.file_id]
	}
	if include_decl {
		append(
			&locations,
			proto.Location{uri = proto.DocumentUri(decl_uri), range = lsp_range(decl_source, decl_span.start, decl_span.end)},
		)
	}
	// Двойной доступ по ключу (len(doc.usages[sym_id]) отдельно от for-range
	// по doc.usages[sym_id]) на ОТСУТСТВУЮЩЕМ ключе — реальный сегфолт (см.
	// codeLens: единственный вызывающий, дающий sym_id БЕЗ единого usage —
	// references/rename всегда резолвят sym_id по клику на существующее
	// использование, там ключ гарантированно есть). Один map-lookup через
	// (value, ok) вместо двух разных обращений — тот же паттерн ниже,
	// merge_cross_document_usages задел не пришлось трогать: там за раз для
	// каждого other_doc максимум одно совпадение по span, накопления с
	// частым отсутствием ключа не было.
	usages_for_sym, has_usages := doc.usages[sym_id]
	for sp in usages_for_sym {
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
			proto.Location{uri = proto.DocumentUri(usage_uri), range = lsp_range(usage_source, sp.start, sp.end)},
		)
	}
	merge_cross_document_usages(server, doc, decl_path, decl_span, &locations)
	return locations
}

// Известное ограничение (частично снятое здесь): doc.graph рождён из
// load_module_graph_with_overrides(doc.path, ...) — ТОЛЬКО прямые импорты
// doc, не "кто импортирует doc" (reverse-dependents). Если декларация лежит
// в файле X и вызывается из файла Y (Y импортирует X), вызов rename/references
// ИЗ Y видит оба места (граф Y включает X), но вызов ИЗ X саму декларацию
// в Y не увидит — граф X не включает Y. Каждый другой открытый документ уже
// посчитал СВОЙ граф независимо (свой Symbol_Store — Symbol_Id НЕ сравним
// между графами напрямую), поэтому матчим декларацию по (путь файла, byte
// span объявления) вместо Symbol_Id: если у другого документа в его графе
// есть файл с тем же путём и в нём символ с тем же span — это та же
// декларация, просто с другим Symbol_Id в другом Symbol_Store. Покрывает
// только СЕЙЧАС ОТКРЫТЫЕ документы — reverse-dependents, которые не открыты
// в редакторе, всё ещё не увидим (нужен был бы project-wide индекс, не MVP).
merge_cross_document_usages :: proc(
	server: ^LSP_Server,
	origin_doc: ^LSP_Document,
	decl_path: string,
	decl_span: core.Span,
	locations: ^[dynamic]proto.Location,
) {
	for _, other_doc in server.documents {
		if other_doc == origin_doc do continue
		matched_sym, found := find_symbol_by_decl_location(other_doc, decl_path, decl_span)
		if !found do continue
		// Прямая индексация map'ы внутри for-range на ОТСУТСТВУЮЩЕМ ключе —
		// сегфолт (см. комментарий в collect_locations выше, где это же
		// нашли живым тестом): matched_sym гарантированно существует как
		// декларация (find_symbol_by_decl_location совпал по span), но НЕ
		// гарантированно имеет хоть один usage В ЭТОМ other_doc.
		matched_usages, _ := other_doc.usages[matched_sym]
		for sp in matched_usages {
			usage_source := other_doc.source
			usage_uri := other_doc.uri
			if sp.file_id != other_doc.file_id {
				usage_source = other_doc.graph.file_sources[sp.file_id]
				usage_uri = path_to_uri(other_doc.graph.file_paths[sp.file_id])
			}
			loc := proto.Location{uri = proto.DocumentUri(usage_uri), range = lsp_range(usage_source, sp.start, sp.end)}
			already_present := false
			for existing in locations {
				if existing == loc {
					already_present = true
					break
				}
			}
			if !already_present do append(locations, loc)
		}
	}
}

// Ищет в графе other_doc файл с путём decl_path, а затем — символ, чей span
// объявления байт-в-байт совпадает с decl_span. Совпадение по (путь, span)
// вместо Symbol_Id, т.к. other_doc резолвился в СВОЁМ отдельном графе со
// своим Symbol_Store (см. merge_cross_document_usages).
find_symbol_by_decl_location :: proc(
	other_doc: ^LSP_Document,
	decl_path: string,
	decl_span: core.Span,
) -> (
	sym_id: core.Symbol_Id,
	found: bool,
) {
	target_file_id: u16
	found_file := false
	for fid, path in other_doc.graph.file_paths {
		if path == decl_path {
			target_file_id = fid
			found_file = true
			break
		}
	}
	if !found_file do return core.INVALID_SYMBOL, false

	store := other_doc.res_ctx.symbol_store
	for i in 1 ..< len(store.symbols) {
		sym := store.symbols[i]
		if sym.span.file_id == target_file_id && sym.span.start == decl_span.start && sym.span.end == decl_span.end {
			return core.Symbol_Id(i), true
		}
	}
	return core.INVALID_SYMBOL, false
}

// Общий первый шаг find-references/rename: позиция курсора -> документ +
// Symbol_Id выражения под курсором. Оба хендлера делали этот же
// 3-шаговый резолв (resolve_position -> find_expr_in_program ->
// node_symbols-lookup) дословно.
resolve_symbol_at_position :: proc(
	server: ^LSP_Server,
	params: json.Value,
) -> (
	doc: ^LSP_Document,
	sym_id: core.Symbol_Id,
	ok: bool,
) {
	found_doc, offset, pos_ok := resolve_position(server, params)
	if !pos_ok {
		return nil, core.INVALID_SYMBOL, false
	}
	expr := core.find_expr_in_program(found_doc.prog, found_doc.file_id, offset)
	if expr == nil {
		return nil, core.INVALID_SYMBOL, false
	}
	found_sym, has_sym := found_doc.res_ctx.node_symbols[expr]
	if !has_sym || found_sym == core.INVALID_SYMBOL {
		return nil, core.INVALID_SYMBOL, false
	}
	return found_doc, found_sym, true
}

// Известное оставшееся ограничение: find-references/rename видят usages по
// всему графу импортов doc + по всем ДРУГИМ ОТКРЫТЫМ документам (см.
// merge_cross_document_usages). Reverse-dependents, которые не открыты в
// редакторе, всё ещё не найдутся — не сканируем весь проект на диске.
handle_references :: proc(server: ^LSP_Server, id: json.Value, params: json.Value) {
	doc, sym_id, ok := resolve_symbol_at_position(server, params)
	if !ok {
		send_null_response(id)
		return
	}

	p, dok := decode_params(proto.ReferenceParams, params)
	if !dok {
		send_null_response(id)
		return
	}
	locations := collect_locations(server, doc, sym_id, p.context_.include_declaration)
	send_response(id, locations[:])
}

// textDocument/prepareRename — подтверждает, что символ под курсором вообще
// переименовываем, и отдаёт точный range+placeholder ДО того, как клиент
// покажет пользователю поле ввода (иначе rename слепой — правит что попало
// под курсором, даже если там не идентификатор). Тот же find_expr_in_program,
// что и hover (handle_hover), не resolve_symbol_at_position — тому не нужен
// span самого выражения, только Symbol_Id.
handle_prepare_rename :: proc(server: ^LSP_Server, id: json.Value, params: json.Value) {
	doc, offset, ok := resolve_position(server, params)
	if !ok {
		send_null_response(id)
		return
	}
	expr := core.find_expr_in_program(doc.prog, doc.file_id, offset)
	if expr == nil {
		send_null_response(id)
		return
	}
	sym_id, has_sym := doc.res_ctx.node_symbols[expr]
	if !has_sym || sym_id == core.INVALID_SYMBOL {
		send_null_response(id)
		return
	}
	sp := core.expr_span(expr)
	result := proto.PrepareRenameResultVariant1 {
		range       = lsp_range(doc.source, sp.start, sp.end),
		placeholder = doc.source[sp.start:sp.end],
	}
	send_response(id, result)
}

handle_rename :: proc(server: ^LSP_Server, id: json.Value, params: json.Value) {
	doc, sym_id, ok := resolve_symbol_at_position(server, params)
	if !ok {
		send_null_response(id)
		return
	}
	p, dok := decode_params(proto.RenameParams, params)
	if !dok {
		send_null_response(id)
		return
	}

	locations := collect_locations(server, doc, sym_id, true)
	// changes сгруппирован по uri — declaration может лежать в ДРУГОМ
	// файле (импортированном модуле), чем usages.
	changes_dyn := make(map[proto.DocumentUri][dynamic]proto.TextEdit, allocator = context.temp_allocator)
	for loc in locations {
		edit := proto.TextEdit{range = loc.range, new_text = p.new_name}
		existing := changes_dyn[loc.uri]
		append(&existing, edit)
		changes_dyn[loc.uri] = existing
	}
	changes := make(map[proto.DocumentUri][]proto.TextEdit)
	for uri, edits in changes_dyn {
		changes[uri] = edits[:]
	}
	result := proto.WorkspaceEdit{changes = changes}
	send_response(id, result)
}

// textDocument/documentHighlight — как references, но только В ТЕКУЩЕМ
// документе (спека этого метода не предполагает межфайловый scope, в
// отличие от rename/references) — фильтруем doc.usages[sym_id] и decl_span
// по file_id, а не отдаём как есть.
handle_document_highlight :: proc(server: ^LSP_Server, id: json.Value, params: json.Value) {
	doc, sym_id, ok := resolve_symbol_at_position(server, params)
	if !ok {
		send_null_response(id)
		return
	}

	highlights := make([dynamic]proto.DocumentHighlight)
	decl_span := core.symbol_at(doc.res_ctx.symbol_store, sym_id).span
	if decl_span.file_id == doc.file_id {
		append(&highlights, proto.DocumentHighlight{range = lsp_range(doc.source, decl_span.start, decl_span.end)})
	}
	// Прямая индексация map'ы в for-range на отсутствующем ключе — сегфолт
	// (см. collect_locations); здесь sym_id всегда приходит через
	// resolve_symbol_at_position (клик на реальное usage), так что ключ
	// гарантированно есть, но паттерн копирует безопасную форму на всякий
	// случай — дешёво, а не разбираться с этим инвариантом при следующей правке.
	usages_for_sym, _ := doc.usages[sym_id]
	for sp in usages_for_sym {
		if sp.file_id != doc.file_id do continue
		append(&highlights, proto.DocumentHighlight{range = lsp_range(doc.source, sp.start, sp.end)})
	}

	send_response(id, highlights[:])
}

// LSP semantic tokens: относительное кодирование (line-delta, char-delta,
// length, token_type, modifiers) — 5 u32 на токен, СТРОГО в порядке
// документа (см. спеку). core.compute_semantic_tokens отдаёт токены из
// node_symbols (map — порядок случайный), поэтому здесь: перевод байтовых
// Span в (line, char) через core.byte_offset_to_lsp_position, сортировка,
// затем относительное кодирование.
// textDocument/foldingRange — чисто синтаксическая: core.compute_folding_ranges
// работает над doc.prog (Program текущего файла), резолвер/граф не нужны.
// Отбрасываем однострочные "блоки" (start_line == end_line) — сворачивать
// там нечего, клиент такие FoldingRange и сам бы проигнорировал (см.
// комментарий в спеке), но не шлём их вовсе, а не полагаемся на клиента.
handle_folding_range :: proc(server: ^LSP_Server, id: json.Value, params: json.Value) {
	p, ok := decode_params(proto.FoldingRangeParams, params)
	if !ok {
		send_null_response(id)
		return
	}
	doc, found := server.documents[string(p.text_document.uri)]
	if !found {
		send_null_response(id)
		return
	}

	raw := core.compute_folding_ranges(doc.prog)
	defer delete(raw)

	ranges := make([dynamic]proto.FoldingRange)
	for fr in raw {
		if fr.span.file_id != doc.file_id do continue
		start_line, _ := core.byte_offset_to_lsp_position(doc.source, fr.span.start)
		end_line, _ := core.byte_offset_to_lsp_position(doc.source, fr.span.end)
		if end_line <= start_line do continue
		append(&ranges, proto.FoldingRange{start_line = u32(start_line), end_line = u32(end_line)})
	}

	send_response(id, ranges[:])
}

// textDocument/documentSymbol — файловый outline, тоже чисто структурный
// (core.compute_document_symbols над doc.prog, без резолвера). doc_symbol_kind_to_proto
// маппит core.Doc_Symbol_Kind в proto.SymbolKind (см. комментарий у Doc_Symbol_Kind).
doc_symbol_kind_to_proto :: proc(k: core.Doc_Symbol_Kind) -> proto.SymbolKind {
	switch k {
	case .Struct:
		return .Struct
	case .Enum:
		return .Enum
	case .Interface:
		return .Interface
	case .Function:
		return .Function
	case .Method:
		return .Method
	case .Field:
		return .Field
	case .EnumMember:
		return .EnumMember
	case .Impl:
		return .Class
	}
	return .Object
}

to_proto_document_symbol :: proc(doc: ^LSP_Document, s: core.Doc_Symbol) -> proto.DocumentSymbol {
	rng := lsp_range(doc.source, s.span.start, s.span.end)
	// name_span (Function_Decl) — точный диапазон одного имени, если он есть
	// (только у функций, см. Doc_Symbol.name_span); иначе selection_range
	// падает обратно на весь span, как раньше.
	selection_rng := rng
	if s.name_span.end > s.name_span.start {
		selection_rng = lsp_range(doc.source, s.name_span.start, s.name_span.end)
	}
	children := make([dynamic]proto.DocumentSymbol, 0, len(s.children))
	for c in s.children {
		append(&children, to_proto_document_symbol(doc, c))
	}
	result := proto.DocumentSymbol {
		name            = s.name,
		kind            = doc_symbol_kind_to_proto(s.kind),
		range           = rng,
		selection_range = selection_rng,
	}
	if len(children) > 0 {
		result.children = children[:]
	}
	return result
}

handle_document_symbol :: proc(server: ^LSP_Server, id: json.Value, params: json.Value) {
	p, ok := decode_params(proto.DocumentSymbolParams, params)
	if !ok {
		send_null_response(id)
		return
	}
	doc, found := server.documents[string(p.text_document.uri)]
	if !found {
		send_null_response(id)
		return
	}

	raw := core.compute_document_symbols(doc.prog)
	defer delete(raw)

	symbols := make([dynamic]proto.DocumentSymbol, 0, len(raw))
	for s in raw {
		append(&symbols, to_proto_document_symbol(doc, s))
	}
	send_response(id, symbols[:])
}

// textDocument/codeLens — "N использований" над каждой функцией, объявленной
// В ЭТОМ файле. Переиспользует collect_locations (тот же счётчик, что
// references/rename) — include_decl=false, считаем только usages, не саму
// декларацию. Command.command оставлен пустым (не resolve-lens, просто
// надпись — клиентам вроде Neovim не из коробки есть куда вести клик по
// произвольной command-строке без своего клиентского маппинга).
handle_code_lens :: proc(server: ^LSP_Server, id: json.Value, params: json.Value) {
	p, ok := decode_params(proto.CodeLensParams, params)
	if !ok {
		send_null_response(id)
		return
	}
	doc, found := server.documents[string(p.text_document.uri)]
	if !found {
		send_null_response(id)
		return
	}

	lenses := make([dynamic]proto.CodeLens)
	store := doc.res_ctx.symbol_store
	for i in 1 ..< len(store.symbols) {
		sym := store.symbols[i]
		if sym.kind != .Function do continue
		if sym.span.file_id != doc.file_id do continue

		sym_id := core.Symbol_Id(i)
		locations := collect_locations(server, doc, sym_id, false)
		count := len(locations)
		delete(locations)

		rng: proto.Range
		if fd, is_fn := sym.decl.(^core.Function_Decl); is_fn {
			rng = lsp_range(doc.source, fd.name_span.start, fd.name_span.end)
		} else {
			line, char := core.byte_offset_to_lsp_position(doc.source, sym.span.start)
			pos := proto.Position{line = u32(line), character = u32(char)}
			rng = proto.Range{start = pos, end = pos}
		}
		append(&lenses, proto.CodeLens{range = rng, command = proto.Command{title = code_lens_title(count), command = ""}})
	}
	send_response(id, lenses[:])
}

// Русское склонение числительного при слове "использование" — 11-14 всегда
// "использований" (искл. из общего mod-10 правила), иначе mod-10: 1 -> ед.
// число, 2-4 -> "использования", остальное -> "использований".
code_lens_title :: proc(count: int) -> string {
	n := count % 100
	form: string
	if n >= 11 && n <= 14 {
		form = "использований"
	} else {
		switch n % 10 {
		case 1:
			form = "использование"
		case 2, 3, 4:
			form = "использования"
		case:
			form = "использований"
		}
	}
	return fmt.tprintf("%d %s", count, form)
}

// textDocument/selectionRange — "Expand/Shrink Selection". Клиент шлёт
// несколько позиций (мультикурсор) — по одной цепочке SelectionRange на
// каждую. core.collect_selection_spans отдаёт span'ы СНАРУЖИ ВНУТРЬ,
// возвращаемая цепочка должна идти ИЗНУТРИ НАРУЖУ (0 = самый глубокий span,
// .parent — на уровень крупнее) — разворачиваем и попутно схлопываем
// соседние идентичные span'ы (Expr_Stmt часто занимает ТОТ ЖЕ диапазон, что
// его единственное выражение — без схлопывания "расширение выделения" на
// этом шаге выглядело бы так, будто ничего не изменилось).
//
// proto.SelectionRange.parent — единственное поле-указатель (^SelectionRange)
// во ВСЁМ автогенерированном protocol-пакете; core:encoding/json.marshal его
// не поддерживает (Unsupported_Type, живой тест это подтвердил) — struct
// целиком тут не годится. Собираем ответ вручную как дерево json.Value
// (Object/Array), в обход marshal-через-struct.
handle_selection_range :: proc(server: ^LSP_Server, id: json.Value, params: json.Value) {
	p, ok := decode_params(proto.SelectionRangeParams, params)
	if !ok {
		send_null_response(id)
		return
	}
	doc, found := server.documents[string(p.text_document.uri)]
	if !found {
		send_null_response(id)
		return
	}

	results := make([dynamic]json.Value, 0, len(p.positions))
	for pos in p.positions {
		offset := core.lsp_position_to_byte_offset(doc.source, int(pos.line), int(pos.character))
		spans := core.collect_selection_spans(doc.prog, doc.file_id, offset)
		defer delete(spans)

		deduped := make([dynamic]core.Span, 0, len(spans), context.temp_allocator)
		for i := len(spans) - 1; i >= 0; i -= 1 {
			sp := spans[i]
			if len(deduped) > 0 {
				last := deduped[len(deduped) - 1]
				if last.start == sp.start && last.end == sp.end do continue
			}
			append(&deduped, sp)
		}

		if len(deduped) == 0 {
			fallback := make(json.Object)
			fallback["range"] = range_to_json_value(proto.Range{start = pos, end = pos})
			append(&results, json.Value(fallback))
		} else {
			append(&results, selection_range_chain_to_json(doc, deduped[:], 0))
		}
	}
	send_response(id, results[:])
}

selection_range_chain_to_json :: proc(doc: ^LSP_Document, deduped: []core.Span, idx: int) -> json.Value {
	sp := deduped[idx]
	obj := make(json.Object)
	obj["range"] = range_to_json_value(lsp_range(doc.source, sp.start, sp.end))
	if idx + 1 < len(deduped) {
		obj["parent"] = selection_range_chain_to_json(doc, deduped, idx + 1)
	}
	return obj
}

range_to_json_value :: proc(r: proto.Range) -> json.Value {
	obj := make(json.Object)
	obj["start"] = position_to_json_value(r.start)
	obj["end"] = position_to_json_value(r.end)
	return obj
}

position_to_json_value :: proc(p: proto.Position) -> json.Value {
	obj := make(json.Object)
	obj["line"] = json.Value(json.Integer(p.line))
	obj["character"] = json.Value(json.Integer(p.character))
	return obj
}

// workspace/symbol — известное ограничение: только по СЕЙЧАС ОТКРЫТЫМ
// документам (переиспользует compute_document_symbols на каждый из них),
// не по всему проекту на диске — тот же MVP-компромисс, что и у
// find-references/rename до project-wide индекса (см. merge_cross_document_
// usages). Пустой query — все символы всех открытых документов.
handle_workspace_symbol :: proc(server: ^LSP_Server, id: json.Value, params: json.Value) {
	p, ok := decode_params(proto.WorkspaceSymbolParams, params)
	if !ok {
		send_null_response(id)
		return
	}

	results := make([dynamic]proto.SymbolInformation)
	for _, doc in server.documents {
		raw := core.compute_document_symbols(doc.prog)
		defer delete(raw)
		for s in raw {
			collect_workspace_symbols(doc, s, "", p.query, &results)
		}
	}
	send_response(id, results[:])
}

collect_workspace_symbols :: proc(
	doc: ^LSP_Document,
	s: core.Doc_Symbol,
	container: string,
	query: string,
	out: ^[dynamic]proto.SymbolInformation,
) {
	if query == "" || strings.contains(s.name, query) {
		info := proto.SymbolInformation {
			name     = s.name,
			kind     = doc_symbol_kind_to_proto(s.kind),
			location = proto.Location{uri = proto.DocumentUri(doc.uri), range = lsp_range(doc.source, s.span.start, s.span.end)},
		}
		if container != "" do info.container_name = container
		append(out, info)
	}
	for c in s.children {
		collect_workspace_symbols(doc, c, s.name, query, out)
	}
}

// textDocument/signatureHelp — подсказка параметров текущего вызова. Как
// hover, использует уже посчитанные тайпчекером типы (doc.tc_ctx.node_types),
// плюс имена параметров через Symbol.decl (core.compute_signature_help).
handle_signature_help :: proc(server: ^LSP_Server, id: json.Value, params: json.Value) {
	doc, offset, ok := resolve_position(server, params)
	if !ok {
		send_null_response(id)
		return
	}

	info, has_info := core.compute_signature_help(&doc.res_ctx, &doc.tc_ctx, doc.prog, doc.file_id, offset)
	if !has_info {
		send_null_response(id)
		return
	}

	proto_params := make([dynamic]proto.ParameterInformation, 0, len(info.params))
	labels := make([dynamic]string, 0, len(info.params))
	for p in info.params {
		label := p.name != "" ? fmt.tprintf("%s: %s", p.name, p.type_name) : p.type_name
		append(&labels, label)
		append(&proto_params, proto.ParameterInformation{label = label})
	}
	label := fmt.tprintf("(%s) -> %s", strings.join(labels[:], ", "), info.return_type)

	sig := proto.SignatureInformation {
		label            = label,
		parameters       = proto_params[:],
		active_parameter = u32(info.active_param),
	}
	result := proto.SignatureHelp {
		signatures        = []proto.SignatureInformation{sig},
		active_signature  = 0,
		active_parameter  = u32(info.active_param),
	}
	send_response(id, result)
}

handle_semantic_tokens :: proc(server: ^LSP_Server, id: json.Value, params: json.Value) {
	p, ok := decode_params(proto.SemanticTokensParams, params)
	if !ok {
		send_null_response(id)
		return
	}
	doc, found := server.documents[string(p.text_document.uri)]
	if !found {
		send_null_response(id)
		return
	}

	raw := core.compute_semantic_tokens(&doc.res_ctx)
	defer delete(raw)

	Positioned_Token :: struct {
		line, char, length, token_type: int,
	}
	items := make([dynamic]Positioned_Token, 0, len(raw), context.temp_allocator)
	for tok in raw {
		line, char := core.byte_offset_to_lsp_position(doc.source, tok.span.start)
		end_line, end_char := core.byte_offset_to_lsp_position(doc.source, tok.span.end)
		if end_line != line || end_char <= char {
			// Идентификаторы в panos однострочные — сюда попасть не должно,
			// но лучше молча пропустить, чем прислать клиенту кадр,
			// нарушающий инвариант спеки (semantic token не может занимать
			// больше одной строки).
			continue
		}
		append(&items, Positioned_Token{line, char, end_char - char, int(tok.token_type)})
	}
	slice.sort_by(items[:], proc(a, b: Positioned_Token) -> bool {
		if a.line != b.line do return a.line < b.line
		return a.char < b.char
	})

	data := make([dynamic]u32, 0, len(items) * 5, context.temp_allocator)
	prev_line := 0
	prev_char := 0
	for it in items {
		delta_line := it.line - prev_line
		delta_char := it.char - prev_char if delta_line == 0 else it.char
		append(&data, u32(delta_line), u32(delta_char), u32(it.length), u32(it.token_type), u32(0))
		prev_line = it.line
		prev_char = it.char
	}

	send_response(id, proto.SemanticTokens{data = data[:]})
}
