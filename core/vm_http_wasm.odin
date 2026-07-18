#+build js
package core

import "core:fmt"

// WASM-заглушка — тот же принцип, что vm_io_wasm.odin/vm_compress_wasm.odin:
// external/odin-http/client тянет core:net (недоступен под js_wasm32) и
// собственный openssl-биндинг, ни то ни другое не собирается для браузера.
call_builtin_http :: proc(vm: ^VM, name: string, args: []Value) -> (result: Value, ok: bool, handled: bool) {
	switch name {
	case "сеть::http_запрос":
		fmt.panicf("Runtime Panic: '%s' недоступно в браузере (WASM-демо не имеет доступа к сети/OpenSSL)", name)
	}
	return
}
