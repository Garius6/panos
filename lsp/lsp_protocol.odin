package main

import core "../core"
import proto "protocol"
import "core:encoding/json"

// JSON-RPC-конверт сообщения от клиента. method/params неизвестны заранее —
// метод определяет, в какой конкретный proto.*Params разобрать params (см.
// decode_params). id/params остаются json.Value: id может быть числом/
// строкой/null (JSON-RPC), а params — заведомо неизвестной заранее формы.
RPC_Envelope :: struct {
	jsonrpc: string     `json:"jsonrpc"`,
	id:      json.Value `json:"id"`,
	method:  string     `json:"method"`,
	params:  json.Value `json:"params"`,
}

// Раскодирует params (уже распарсенное поддерево) в конкретный
// LSP-параметр-тип через промежуточный marshal → unmarshal: params уже
// json.Value, а не сырые байты, так что второй проход дешёвый — не по
// всему сообщению, а по одному вложенному объекту.
decode_params :: proc($T: typeid, params: json.Value) -> (T, bool) {
	data, merr := json.marshal(params, {})
	if merr != nil do return {}, false
	defer delete(data)
	result: T
	uerr := json.unmarshal(data, &result)
	return result, uerr == nil
}

lsp_position :: proc(line: int, character: int) -> proto.Position {
	return proto.Position{line = u32(line), character = u32(character)}
}

lsp_range :: proc(source: string, start_offset: u32, end_offset: u32) -> proto.Range {
	start_line, start_char := core.byte_offset_to_lsp_position(source, start_offset)
	end_line, end_char := core.byte_offset_to_lsp_position(source, end_offset)
	return proto.Range{start = lsp_position(start_line, start_char), end = lsp_position(end_line, end_char)}
}

RPC_Response :: struct($R: typeid) {
	jsonrpc: string     `json:"jsonrpc"`,
	id:      json.Value `json:"id"`,
	result:  R          `json:"result"`,
}

send_response :: proc(id: json.Value, result: $T) {
	lsp_write_message(RPC_Response(T){jsonrpc = "2.0", id = id, result = result})
}

// result: null — общий случай "нет ответа" (hover/definition/references
// не нашли ничего под курсором и т.п.).
send_null_response :: proc(id: json.Value) {
	send_response(id, json.Value(nil))
}

RPC_Error_Response :: struct {
	jsonrpc: string     `json:"jsonrpc"`,
	id:      json.Value `json:"id"`,
	error:   struct {
		code:    int    `json:"code"`,
		message: string `json:"message"`,
	} `json:"error"`,
}

send_error_response :: proc(id: json.Value, code: int, message: string) {
	lsp_write_message(RPC_Error_Response{jsonrpc = "2.0", id = id, error = {code = code, message = message}})
}

RPC_Notification :: struct($P: typeid) {
	jsonrpc: string `json:"jsonrpc"`,
	method:  string `json:"method"`,
	params:  P      `json:"params"`,
}

send_notification :: proc(method: string, params: $T) {
	lsp_write_message(RPC_Notification(T){jsonrpc = "2.0", method = method, params = params})
}
