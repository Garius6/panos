#+build js
package core

import "core:fmt"

// WASM-заглушка: браузер не может делать реальный ФС/сокеты/блокирующий
// стдин. Все имена, которые native-вариант (vm_io_native.odin) реально бы
// обработал, здесь паникуют понятным сообщением вместо тихого игнора —
// пользователь демо должен видеть, ПОЧЕМУ его скрипт не работает, а не
// "неизвестный встроенный конструктор".
call_builtin_io :: proc(vm: ^VM, name: string, args: []Value) -> (result: Value, ok: bool, handled: bool) {
	switch name {
	case "фс::есть",
	     "фс::прочитать",
	     "фс::записать",
	     "фс::открыть",
	     "ос::окружение",
	     "ос::установить_окружение",
	     "ос::удалить_окружение",
	     "ввод_вывод::прочитать_строку",
	     "ввод_вывод::поток",
	     "сеть::подключиться":
		fmt.panicf("Runtime Panic: '%s' недоступно в браузере (WASM-демо не имеет файловой системы/сети/стдина)", name)
	}
	return
}

// Вызываются из gc.odin's finalizer (pool_release) безусловно, для ЛЮБОГО
// таргета — но раз File_Value/Socket_Value в WASM никогда реально не
// конструируются (см. invoke_io_method ниже), эти вызовы недостижимы на
// практике. no-op вместо реального закрытия — нечего закрывать.
close_file_value :: proc(file: ^File_Value) {}
close_socket_value :: proc(sock: ^Socket_Value) {}

// File_Value/Socket_Value в WASM-варианте никогда реально не
// конструируются (call_builtin_io паникует раньше, чем дошло бы до
// gc_new(File_Value)/gc_new(Socket_Value)) — эта функция теоретически
// недостижима, но должна существовать: invoke_collection_method (vm.odin)
// вызывает её безусловно.
invoke_io_method :: proc(
	vm: ^VM,
	receiver: Value,
	method_name: string,
	args: []Value,
) -> (
	result: Value,
	ok: bool,
	handled: bool,
) {
	return
}
