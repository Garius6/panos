#+build js
package core

import "core:bufio"

// WASM-заглушки File_Value/Socket_Value — см. file_value_native.odin.
// handle/socket типизированы rawptr вместо ^os.File/net.TCP_Socket (сам
// ИМПОРТ core:os/core:net падает под js_wasm32) — но фс::открыть/
// сеть::подключиться (vm_io_wasm.odin) паникуют раньше, чем эти поля
// реально понадобились бы, так что тип-заглушка достаточен.
File_Value :: struct {
	header:   GC_Header,
	handle:   rawptr,
	reader:   bufio.Reader,
	path:     string,
	is_open:  bool,
	is_stdin: bool,
}

Socket_Value :: struct {
	header:  GC_Header,
	socket:  rawptr,
	reader:  bufio.Reader,
	is_open: bool,
}
