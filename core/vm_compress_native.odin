#+build !js
package core

import "core:bytes"
import "core:compress/gzip"
import "core:fmt"

// сжатие::* — вынесено из общего call_builtin (vm.odin) в #+build-split,
// тот же принцип, что vm_io_native.odin/vm_io_wasm.odin: core:compress/gzip
// импортирует core:os (для load_from_file, которым мы даже не пользуемся)
// транзитивно — простой импорт пакета падает compile-time panic'ом под
// js_wasm32, поэтому реальная реализация живёт только в native-варианте.
call_builtin_compress :: proc(vm: ^VM, name: string, args: []Value) -> (result: Value, ok: bool, handled: bool) {
	switch name {
	case "сжатие::разжать_gzip":
		expect_arg_count(name, len(args), 1)
		data := expect_string_arg(name, args[0])
		buf: bytes.Buffer
		err := gzip.load_from_bytes(transmute([]u8)data, &buf)
		if err != nil {
			bytes.buffer_destroy(&buf)
			return make_error_result(vm, make_error_value(vm, "сжатие", fmt.tprintf("%v", err))), true, true
		}
		decompressed := string(bytes.buffer_to_bytes(&buf))
		result_str := gc_new_string(vm, decompressed)
		bytes.buffer_destroy(&buf)
		return make_ok_result(vm, Value(result_str)), true, true
	}
	return
}
