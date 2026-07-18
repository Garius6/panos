#+build js
package core

import "core:fmt"

// WASM-заглушка — тот же принцип, что vm_io_wasm.odin: core:compress/gzip
// в native-варианте транзитивно тянет core:os, который падает
// compile-time panic'ом под js_wasm32 при простом импорте пакета.
call_builtin_compress :: proc(vm: ^VM, name: string, args: []Value) -> (result: Value, ok: bool, handled: bool) {
	switch name {
	case "сжатие::разжать_gzip":
		fmt.panicf("Runtime Panic: '%s' недоступно в браузере (WASM-демо не имеет доступа к core:compress/gzip)", name)
	}
	return
}
