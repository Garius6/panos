#+feature dynamic-literals
package main

import "base:runtime"
import core "../core"
import "core:encoding/json"
import "core:fmt"

// Спайк-демо: JS пишет исходник panos-скрипта в этот статический буфер
// (через WasmMemoryInterface.storeString на адрес из panos_source_ptr()),
// затем зовёт panos_run(len). Простое, но достаточное решение для v1 —
// без динамической аллокации со стороны JS (никакой malloc-обвязки).
SOURCE_BUF_SIZE :: 65536
@(private)
source_buf: [SOURCE_BUF_SIZE]byte

@(export)
panos_source_ptr :: proc "c" () -> ^byte {
	return &source_buf[0]
}

@(export)
panos_source_capacity :: proc "c" () -> int {
	return SOURCE_BUF_SIZE
}

// Запускает panos-скрипт длиной source_len байт из source_buf. Вывод идёт
// через fmt.print*/fmt.eprint* — на js_wasm32 core:fmt сам пишет в
// odin_env.write (см. fmt_js.odin в тулчейне Odin), рантайм-обвязка
// odin.js рендерит это в consoleElement страницы — без единой строчки
// собственного JS-парсинга WASM-памяти под каждый print.
@(export)
panos_run :: proc "c" (source_len: int) {
	context = runtime.default_context()

	// odin.js's writeToConsole копит вывод в закрытый (не доступный извне)
	// массив infoConsoleLines и перерисовывает ВЕСЬ #console из него на
	// каждый print — JS-сторона не может ни очистить, ни узнать про это
	// состояние снаружи (не exposed на window.odin). Раз "очистить между
	// запусками" architecturally недоступно, разделитель печатаем прямо
	// отсюда — то же самое API, тот же поток, без гонки с внутренним
	// состоянием рантайма.
	fmt.println("── запуск ──")

	if source_len < 0 || source_len > SOURCE_BUF_SIZE {
		fmt.eprintln("Ошибка спайка: исходник длиннее буфера демо")
		return
	}
	source := string(source_buf[:source_len])

	result, has_result, diags := core.run_source(source)
	if len(diags) > 0 {
		for d in diags {
			fmt.eprintln(d.message)
		}
		return
	}
	if has_result {
		// ^Panos_String печатается как Odin-структура через голый %v (см.
		// print_vm в vm.odin — тот же unwrap там, для той же причины) —
		// достаём .data явно, иначе результат-строка попадает на страницу
		// как "&Panos_String{header = ..., data = \"текст\"}".
		if ps, ok := result.(^core.Panos_String); ok {
			fmt.println(ps.data)
		} else {
			fmt.println(result)
		}
	}
}

// LSP-lite: несколько прямых экспортов вместо полного LSP-протокола —
// panos-lsp (lsp/lsp_server.odin) целиком про МНОГОФАЙЛОВЫЙ граф импортов
// (Module_Graph, overrides для незаписанных буферов), а браузерное демо
// принципиально single-file (см. заметку у panos_run выше) — вся эта
// инфраструктура тут не нужна. Переиспользует core.check_source (core/
// pipeline.odin) + core.find_expr_in_program (core/position.odin) — те
// же низкоуровневые функции, что использует panos-lsp, просто без
// JSON-RPC обвязки и без графа модулей.
RESULT_BUF_SIZE :: 65536
@(private)
result_buf: [RESULT_BUF_SIZE]byte
@(private)
result_len: int

@(private)
write_result :: proc(data: []byte) {
	n := len(data)
	if n > RESULT_BUF_SIZE do n = RESULT_BUF_SIZE
	copy(result_buf[:n], data[:n])
	result_len = n
}

@(private)
write_result_string :: proc(s: string) {
	write_result(transmute([]byte)s)
}

@(export)
panos_result_ptr :: proc "c" () -> ^byte {
	return &result_buf[0]
}

@(export)
panos_result_len :: proc "c" () -> int {
	return result_len
}

@(private)
source_from_buf :: proc(source_len: int) -> (string, bool) {
	if source_len < 0 || source_len > SOURCE_BUF_SIZE do return "", false
	return string(source_buf[:source_len]), true
}

// Диагностики source_buf'а как JSON-массив {from, to, severity, message} —
// формат напрямую под @codemirror/lint's Diagnostic (from/to — плоский
// UTF-16 offset от начала документа, не line/character, как у LSP).
@(export)
panos_check :: proc "c" (source_len: int) {
	context = runtime.default_context()
	source, ok := source_from_buf(source_len)
	if !ok {
		write_result_string("[]")
		return
	}

	check := core.check_source(source)
	items := make([dynamic]json.Value)
	for d in check.diags {
		append(
			&items,
			json.Value(
				json.Object {
					"from" = json.Integer(i64(core.byte_offset_to_utf16_offset(source, d.span.start))),
					"to" = json.Integer(i64(core.byte_offset_to_utf16_offset(source, d.span.end))),
					"severity" = json.String("error"),
					"message" = json.String(d.message),
				},
			),
		)
	}
	data, _ := json.marshal(json.Array(items), {})
	write_result(data)
}

// Тип выражения под offset (плоский UTF-16, от CodeMirror) — {type, from,
// to} или null. Тот же паттерн, что handle_hover в lsp_server.odin —
// find_expr_in_program + node_types.
@(export)
panos_hover :: proc "c" (source_len: int, offset: int) {
	context = runtime.default_context()
	source, ok := source_from_buf(source_len)
	if !ok {
		write_result_string("null")
		return
	}

	check := core.check_source(source)
	byte_offset := core.utf16_offset_to_byte_offset(source, offset)
	expr := core.find_expr_in_program(check.prog, 0, byte_offset)
	if expr == nil {
		write_result_string("null")
		return
	}
	typ, has_type := check.tc_ctx.node_types[expr]
	if !has_type || typ == nil {
		write_result_string("null")
		return
	}

	sp := core.expr_span(expr)
	obj := json.Object {
		"type" = json.String(core.prune_type(typ).name),
		"from" = json.Integer(i64(core.byte_offset_to_utf16_offset(source, sp.start))),
		"to" = json.Integer(i64(core.byte_offset_to_utf16_offset(source, sp.end))),
	}
	data, _ := json.marshal(json.Value(obj), {})
	write_result(data)
}

// Dot-completion (`receiver.` -> поля/методы/варианты) — JSON-массив
// {label, kind}, kind — CodeMirror-стиль ("field"/"method"/"variant"),
// не LSP CompletionItemKind (тот числовой, тут строковый — проще
// смаппить на стороне JS под @codemirror/autocomplete). Тот же offset-
// арифметика, что handle_completion в lsp_server.odin (offset-2, не
// offset-1 — точка сама вне span'а receiver'а, см. комментарий там).
@(export)
panos_complete :: proc "c" (source_len: int, offset: int) {
	context = runtime.default_context()
	source, ok := source_from_buf(source_len)
	if !ok {
		write_result_string("[]")
		return
	}

	byte_offset := core.utf16_offset_to_byte_offset(source, offset)
	if byte_offset < 2 || source[byte_offset - 1] != '.' {
		write_result_string("[]")
		return
	}

	check := core.check_source(source)
	receiver_expr := core.find_expr_in_program(check.prog, 0, byte_offset - 2)
	if receiver_expr == nil {
		write_result_string("[]")
		return
	}
	typ, has_type := check.tc_ctx.node_types[receiver_expr]
	if !has_type || typ == nil {
		write_result_string("[]")
		return
	}

	members := core.type_completion_members(typ)
	items := make([dynamic]json.Value)
	seen := make(map[string]bool, allocator = context.temp_allocator)
	for m in members {
		if m.name == "" || seen[m.name] do continue
		seen[m.name] = true
		kind_str := "field"
		switch m.kind {
		case .Field:
			kind_str = "field"
		case .Method:
			kind_str = "method"
		case .Variant:
			kind_str = "variant"
		}
		append(&items, json.Value(json.Object{"label" = json.String(m.name), "kind" = json.String(kind_str)}))
	}
	data, _ := json.marshal(json.Array(items), {})
	write_result(data)
}

main :: proc() {}
