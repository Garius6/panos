#+feature dynamic-literals
package main

import "core:encoding/json"

// LSP-сообщения глубоко вложены, но нам нужно из них лишь несколько
// листовых значений (uri, line/character, text). Полное описание каждого
// LSP-типа Odin-структурой с json-тегами — оверинжиниринг для MVP с 3
// фичами; вместо этого — точечная навигация по json.Value напрямую.

json_get :: proc(v: json.Value, key: string) -> json.Value {
	if obj, ok := v.(json.Object); ok {
		if val, found := obj[key]; found do return val
	}
	return nil
}

json_str :: proc(v: json.Value, key: string) -> string {
	val := json_get(v, key)
	if s, ok := val.(json.String); ok do return string(s)
	return ""
}

json_int :: proc(v: json.Value, key: string) -> int {
	val := json_get(v, key)
	if n, ok := val.(json.Integer); ok do return int(n)
	if f, ok := val.(json.Float); ok do return int(f) // defensive: клиент прислал число без parse_integers-эффекта
	return 0
}

json_bool :: proc(v: json.Value, key: string) -> bool {
	val := json_get(v, key)
	if b, ok := val.(json.Boolean); ok do return bool(b)
	return false
}

// Собирает LSP Position {line, character} как json.Value.
lsp_position_json :: proc(line: int, character: int) -> json.Value {
	return json.Object {
		"line" = json.Integer(i64(line)),
		"character" = json.Integer(i64(character)),
	}
}

// Собирает LSP Range {start, end} из байтовых offset'ов в source.
lsp_range_json :: proc(source: string, start_offset: u32, end_offset: u32) -> json.Value {
	start_line, start_char := byte_offset_to_lsp_position(source, start_offset)
	end_line, end_char := byte_offset_to_lsp_position(source, end_offset)
	return json.Object {
		"start" = lsp_position_json(start_line, start_char),
		"end" = lsp_position_json(end_line, end_char),
	}
}

send_response :: proc(id: json.Value, result: json.Value) {
	msg := json.Object {
		"jsonrpc" = json.String("2.0"),
		"id"      = id,
		"result"  = result,
	}
	lsp_write_message(msg)
}

send_error_response :: proc(id: json.Value, code: int, message: string) {
	msg := json.Object {
		"jsonrpc" = json.String("2.0"),
		"id"      = id,
		"error"   = json.Object {
			"code" = json.Integer(i64(code)),
			"message" = json.String(message),
		},
	}
	lsp_write_message(msg)
}

send_notification :: proc(method: string, params: json.Value) {
	msg := json.Object {
		"jsonrpc" = json.String("2.0"),
		"method"  = json.String(method),
		"params"  = params,
	}
	lsp_write_message(msg)
}
