#+build js
package core

import "core:fmt"

// WASM-заглушка — тот же принцип, что vm_http_wasm.odin/vm_io_wasm.odin:
// external/odin-http/server тянет core:net и свой собственный поток-пул
// (core:thread), ни то ни другое не собирается для js_wasm32 (FR-007).
// Структуры существуют (типы Слушатель/Запрос видны тайпчекеру на обеих
// платформах — core/type_cheker.odin не разделён по #+build), но НИКОГДА
// не создаются на этой платформе — реальные поля не нужны, только
// header для GC-совместимости (gc.odin ссылается на эти типы обобщённо).
Http_Listener_Value :: struct {
	header: GC_Header,
}

Http_Request_Value :: struct {
	header: GC_Header,
}

// Никогда не создаётся на этой платформе — только чтобы имя типа
// существовало для общего vm_async.odin (Async_Result.payload union),
// тот же приём, что Tcp_Connect_Result_Data (vm_async_io_wasm.odin).
Http_Accept_Result_Data :: struct {
	req: rawptr,
	err: Maybe(string),
}

close_http_listener_value :: proc(val: ^Http_Listener_Value) {}
close_http_request_value :: proc(val: ^Http_Request_Value) {}

// Никогда фактически не вызывается — Http_Listener_Value.принять_запрос()
// недостижим на этой платформе (invoke_http_server_method паникует раньше,
// submit_async_io/deliver_async_result её вообще не видят под js_wasm32,
// т.к. vm_async_io_wasm.odin не регистрирует Http_Listener_Value-ветку).
// Определена только чтобы имя существовало для общего vm.odin.
deliver_http_accept_result :: proc(vm: ^VM, target: ^Process_Value, payload: Http_Accept_Result_Data) {}

call_builtin_http_server :: proc(vm: ^VM, name: string, args: []Value) -> (result: Value, ok: bool, handled: bool) {
	switch name {
	case "сеть::http_сервер_слушать":
		fmt.panicf("Runtime Panic: '%s' недоступно в браузере (WASM-демо не имеет доступа к сети/потокам ОС)", name)
	}
	return
}

invoke_http_server_method :: proc(vm: ^VM, receiver: Value, method_name: string, args: []Value) -> (result: Value, ok: bool, handled: bool) {
	if _, is_listener := receiver.(^Http_Listener_Value); is_listener {
		fmt.panicf("Runtime Panic: методы Слушателя недоступны в браузере (WASM-демо не имеет доступа к сети/потокам ОС)")
	}
	if _, is_req := receiver.(^Http_Request_Value); is_req {
		fmt.panicf("Runtime Panic: методы Запроса недоступны в браузере (WASM-демо не имеет доступа к сети/потокам ОС)")
	}
	return {}, false, false
}
