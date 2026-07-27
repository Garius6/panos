#+build js
package core

import "core:fmt"

// WASM-заглушка — тот же принцип, что file_value_wasm.odin: SQLite
// открывает файл на диске, WASM-песочница браузера не имеет файловой
// системы. db типизирован rawptr вместо ^sqlite3 (сам sqlite3_bindings.
// odin — #+build !js, недоступен здесь). Структура никогда не
// создаётся на этой платформе, но поля должны совпадать с native-
// стороной (vm_sql_native.odin) — deliver_async_result (vm.odin,
// безусловный) читает in_flight/close_requested напрямую.
Sql_Connection_Value :: struct {
	header:          GC_Header,
	db:              rawptr,
	path:            string,
	is_open:         bool,
	in_flight:       bool,
	close_requested: bool,
}

close_sql_connection :: proc(conn: ^Sql_Connection_Value) {}

call_builtin_sql :: proc(vm: ^VM, name: string, args: []Value) -> (result: Value, ok: bool, handled: bool) {
	switch name {
	case "бд::открыть":
		fmt.panicf("Runtime Panic: '%s' недоступно в браузере (нет файловой системы)", name)
	}
	return
}

invoke_sql_connection_method :: proc(vm: ^VM, receiver: Value, method_name: string, args: []Value) -> (result: Value, ok: bool, handled: bool) {
	if _, is_conn := receiver.(^Sql_Connection_Value); is_conn {
		fmt.panicf("Runtime Panic: методы Соединение_БД недоступны в браузере (нет файловой системы)")
	}
	return {}, false, false
}
