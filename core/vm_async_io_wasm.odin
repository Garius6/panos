#+build js
package core

import "core:fmt"

// Tcp_Connect_Result_Data — та же rawptr-заглушка, что File_Value.handle/
// Socket_Value.socket на wasm (см. file_value_wasm.odin) — реальный
// net.TCP_Socket недоступен под js_wasm32 (сам импорт core:net падает).
// Недостижимо на практике: submit_async_io ниже паникует раньше, чем этот
// вариант payload'а мог бы быть сконструирован.
Tcp_Connect_Result_Data :: struct {
	socket: rawptr,
	err:    Maybe(string),
}

// WASM: core:thread недоступен (thread.IS_SUPPORTED == false), поэтому
// VM.async_pool/async_completions никогда не инициализируются (new_vm,
// vm.odin, `when thread.IS_SUPPORTED`) — эта функция существует ТОЛЬКО
// чтобы .Call_Builtin_Async компилировался на wasm-цели (компилятор эмитит
// async-опкоды одинаково на всех платформах, см. compiler.odin,
// is_async_builtin_name/case .Builtin). Сохраняет ТОЧНО то же поведение,
// что раньше давал синхронный call_builtin_io/call_builtin_http (vm_io_wasm.
// odin/vm_http_wasm.odin) — жёсткий panic, а не Результат.Неудача, т.к. это
// конфигурационная невозможность (браузер), а не runtime-ошибка.
submit_async_io :: proc(vm: ^VM, name: string, args: []Value, target_id: int) {
	switch name {
	case "сеть::http_запрос":
		fmt.panicf("Runtime Panic: '%s' недоступно в браузере (WASM-демо не имеет доступа к сети/OpenSSL)", name)
	case "фс::прочитать", "фс::записать", "сеть::подключиться":
		fmt.panicf("Runtime Panic: '%s' недоступно в браузере (WASM-демо не имеет файловой системы/сети)", name)
	}
}

// Недостижимо (см. Tcp_Connect_Result_Data выше) — существует только чтобы
// deliver_async_result (vm.odin) компилировался на wasm-цели.
deliver_tcp_connect_result :: proc(vm: ^VM, target: ^Process_Value, payload: Tcp_Connect_Result_Data) {}

// Фаза 4: File_Value/Socket_Value никогда реально не конструируются на
// wasm (call_builtin_io паникует раньше — vm_io_wasm.odin), поэтому
// .прочитать_строку()/.получить() и т.п. недостижимы на практике — эта
// функция существует только чтобы .Invoke_Collection_Async компилировался
// на wasm-цели (компилятор эмитит его одинаково на всех платформах, см.
// compiler.odin, is_async_stream_method/case .Method_Collection). Тот же
// panic-паттерн, что submit_async_io выше.
submit_async_io_method :: proc(vm: ^VM, receiver: Value, method_name: string, target_id: int) {
	fmt.panicf("Runtime Panic: '%s' недоступно в браузере (WASM-демо не имеет файловой системы/сети)", method_name)
}
