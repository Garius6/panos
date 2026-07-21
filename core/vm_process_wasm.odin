#+build js
package core

import "core:fmt"

// WASM-заглушка — тот же принцип, что vm_io_wasm.odin/vm_compress_wasm.odin:
// os.process_exec в native-варианте тянет platform-specific process_*.odin,
// недоступные под js_wasm32 (браузер не может спавнить процессы).
call_builtin_process :: proc(vm: ^VM, name: string, args: []Value) -> (result: Value, ok: bool, handled: bool) {
	switch name {
	case "ос::выполнить", "ос::завершить":
		fmt.panicf("Runtime Panic: '%s' недоступно в браузере (WASM-демо не может управлять процессом)", name)
	}
	return
}
