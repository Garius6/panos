package core

import "core:fmt"
import "core:strings"

Builtin_Target_Availability :: enum {
	Both,
	Native_Only,
	Wasm_Aot_Only,
}

// builtin_target_availability — единственный источник правды о доступности
// platform-specific builtin'ов. Методы opaque native-объектов проверяются
// отдельными runtime guards, потому что не являются Call_Builtin.
builtin_target_availability :: proc(name: string) -> Builtin_Target_Availability {
	if strings.has_prefix(name, "DOM::") || name == "сеть::http_запрос_sync" {
		return .Wasm_Aot_Only
	}
	if strings.has_prefix(name, "фс::") ||
	   strings.has_prefix(name, "сжатие::") ||
	   strings.has_prefix(name, "синтаксис::") ||
	   strings.has_prefix(name, "бд::") {
		return .Native_Only
	}
	switch name {
	case "время::спать_мс",
	     "ос::окружение",
	     "ос::установить_окружение",
	     "ос::удалить_окружение",
	     "ос::выполнить",
	     "ос::завершить",
	     "ввод_вывод::прочитать_строку",
	     "ввод_вывод::поток",
	     "сеть::подключиться",
	     "сеть::http_запрос",
	     "сеть::http_сервер_слушать":
		return .Native_Only
	}
	return .Both
}

builtin_available_for_target :: proc(name: string, wasm_target: bool) -> bool {
	availability := builtin_target_availability(name)
	if wasm_target do return availability != .Native_Only
	return availability != .Wasm_Aot_Only
}

builtin_unavailable_type_message :: proc(name: string, wasm_target: bool) -> string {
	if wasm_target {
		return fmt.tprintf("Type Error: builtin '%s' недоступен для WASM-таргета", name)
	}
	return fmt.tprintf("Type Error: builtin '%s' доступен только для AOT WASM-таргета", name)
}

// Bytecode VM не исполняет AOT WASM builtin'ы даже при сборке самого VM под
// js_wasm32: DOM/XHR вызывает внешний JS-загрузчик, а не VM dispatch.
builtin_available_in_bytecode_vm :: proc(name: string) -> bool {
	availability := builtin_target_availability(name)
	if availability == .Wasm_Aot_Only do return false
	when ODIN_ARCH == .wasm32 {
		return availability != .Native_Only
	}
	return true
}

ensure_builtin_available_in_bytecode_vm :: proc(name: string) {
	if builtin_available_in_bytecode_vm(name) do return
	availability := builtin_target_availability(name)
	if availability == .Wasm_Aot_Only {
		fmt.panicf("Runtime Panic: '%s' доступно только в AOT WASM-выводе, не в байткод-VM", name)
	}
	fmt.panicf("Runtime Panic: '%s' недоступно в этом runtime-таргете", name)
}
