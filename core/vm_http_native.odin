#+build !js
package core

import "core:bytes"
import "core:fmt"
import http "../external/odin-http"
import client "../external/odin-http/client"

// сеть::http_запрос — вынесено из общего call_builtin (vm.odin) в
// #+build-split, тот же принцип, что vm_io_native.odin/vm_compress_native.odin:
// external/odin-http/client тянет core:net (недоступен под js_wasm32) и
// собственный openssl-биндинг (system:ssl.3/system:crypto.3 на macOS/
// Linux — системная зависимость, принятая сознательно, см. ROADMAP.md).
//
// Настоящий HTTP(S)-клиент вместо ручного сокет-парсинга в
// std/сеть/http.ps — корректно обрабатывает Content-Length/chunked
// encoding (vs старый "читать до EOF" в http.ps) и умеет https.
call_builtin_http :: proc(vm: ^VM, name: string, args: []Value) -> (result: Value, ok: bool, handled: bool) {
	switch name {
	case "сеть::http_запрос":
		expect_arg_count(name, len(args), 4)
		method_str := expect_string_arg(name, args[0])
		url := expect_string_arg(name, args[1])
		body_str := expect_string_arg(name, args[2])
		headers_map, is_map := args[3].(^Map_Value)

		method, method_ok := http_method_from_string(method_str)
		if !method_ok {
			return make_error_result(
				vm,
				make_error_value(vm, "сеть", fmt.tprintf("неизвестный HTTP-метод: %s", method_str)),
			), true, true
		}

		req: client.Request
		client.request_init(&req, method)
		defer client.request_destroy(&req)

		if is_map {
			for entry in headers_map.entries {
				k, k_ok := entry.key.(^Panos_String)
				v, v_ok := entry.value.(^Panos_String)
				if k_ok && v_ok {
					http.headers_set(&req.headers, k.data, v.data)
				}
			}
		}
		if len(body_str) > 0 {
			bytes.buffer_write(&req.body, transmute([]u8)body_str)
		}

		res, req_err := client.request(&req, url)
		if req_err != nil {
			return make_error_result(vm, make_error_value(vm, "сеть", fmt.tprintf("%v", req_err))), true, true
		}
		defer client.response_destroy(&res)

		body_result, was_alloc, body_err := client.response_body(&res)
		defer if body_err == nil {
			client.body_destroy(body_result, was_alloc)
		}
		body_text := ""
		if body_err == nil {
			if plain, is_plain := body_result.(client.Body_Plain); is_plain {
				body_text = string(plain)
			}
		}

		// Порядок: header_pairs протектим ДО заполнения (append ниже может
		// триггернуть collect_garbage), НЕ убираем протект, пока сам
		// header_pairs не сохранён как поле уже протекченного result_tuple
		// (тот же паттерн, что message_deep_copy/Соответствие.записи).
		header_pairs := gc_new(vm, Array_Value)
		gc_protect(vm, Value(header_pairs))
		for k, v in res.headers._kv {
			pair := gc_new(vm, Aggregate_Value)
			resize(&pair.elements, 2)
			pair.elements[0] = Value(gc_new_string(vm, k))
			pair.elements[1] = Value(gc_new_string(vm, v))
			append(&header_pairs.elements, Value(pair))
		}

		result_tuple := gc_new(vm, Aggregate_Value)
		resize(&result_tuple.elements, 3)
		result_tuple.elements[0] = Value(f64(int(res.status)))
		result_tuple.elements[1] = Value(header_pairs)
		result_tuple.elements[2] = Value(gc_new_string(vm, body_text))
		gc_unprotect(vm, 1)

		return make_ok_result(vm, Value(result_tuple)), true, true
	}
	return
}

http_method_from_string :: proc(s: string) -> (http.Method, bool) {
	switch s {
	case "GET":
		return .Get, true
	case "POST":
		return .Post, true
	case "PUT":
		return .Put, true
	case "DELETE":
		return .Delete, true
	case "PATCH":
		return .Patch, true
	case "HEAD":
		return .Head, true
	case "OPTIONS":
		return .Options, true
	}
	return .Get, false
}
