#+build js
package core

import "core:fmt"

// WASM-заглушка — тот же принцип, что vm_process_wasm.odin: read_file_text
// (native-вариант) тянет os.open/os.read_entire_file, недоступные под
// js_wasm32 (браузер не может читать произвольные пути с диска).
call_builtin_syntax :: proc(vm: ^VM, name: string, args: []Value) -> (result: Value, ok: bool, handled: bool) {
	switch name {
	case "синтаксис::структуры",
	     "синтаксис::поля",
	     "синтаксис::аннотации",
	     "синтаксис::аргумент_аннотации",
	     "синтаксис::аннотации_поля",
	     "синтаксис::аргумент_аннотации_поля":
		fmt.panicf("Runtime Panic: '%s' недоступно в браузере (WASM-демо не читает файлы с диска)", name)
	}
	return
}
