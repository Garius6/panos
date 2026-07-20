#+build js
package core

import "core:fmt"

// WASM: core:thread недоступен (thread.IS_SUPPORTED == false), поэтому
// VM.async_pool/async_completions никогда не инициализируются (new_vm,
// vm.odin, `when thread.IS_SUPPORTED`) — эта функция существует ТОЛЬКО
// чтобы .Call_Builtin_Async компилировался на wasm-цели (компилятор эмитит
// async-опкоды для сеть::http_запрос одинаково на всех платформах, см.
// compiler.odin, case .Builtin). Сохраняет ТОЧНО то же поведение, что
// раньше давал синхронный call_builtin_http (vm_http_wasm.odin) — жёсткий
// panic, а не Результат.Неудача, т.к. это конфигурационная невозможность
// (браузер), а не runtime-ошибка.
submit_async_io :: proc(vm: ^VM, name: string, args: []Value, target_id: int) {
	switch name {
	case "сеть::http_запрос":
		fmt.panicf("Runtime Panic: '%s' недоступно в браузере (WASM-демо не имеет доступа к сети/OpenSSL)", name)
	}
}
