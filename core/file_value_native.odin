#+build !js
package core

import "core:bufio"
import "core:net"
import "core:os"

// Дескриптор открытого файла или потока ввода (стдин). is_stdin файлы не
// владеют ОС-хендлом (нельзя закрыть стдин) — закрытие для них no-op.
//
// in_flight/close_requested (неблокирующий стриминговый I/O, Фаза 4):
// in_flight — true пока фоновый воркер физически держит &reader/handle
// (submit_async_io_method пин'ит объект через gc_pin на это время — см.
// gc.odin — GC не может закрыть/переиспользовать его, пока pinned).
// close_requested — .закрыть() был вызван, пока in_flight — настоящий
// close_file_value откладывается до завершения воркера (deliver_async_
// result, vm.odin), иначе гонка на os.close/bufio.reader_destroy с ещё
// читающим воркером.
File_Value :: struct {
	header:          GC_Header,
	handle:          ^os.File,
	reader:          bufio.Reader,
	path:            string,
	is_open:         bool,
	is_stdin:        bool,
	in_flight:       bool,
	close_requested: bool,
}

// TCP-соединение (сеть.подключиться). reader читает через свой io.Stream
// поверх net.recv_tcp (см. tcp_to_stream в vm.odin) — тот же
// read_line_from_reader/read_all_from_reader, что и у File_Value, без
// дублирования логики чтения. in_flight/close_requested — см. File_Value.
Socket_Value :: struct {
	header:          GC_Header,
	socket:          net.TCP_Socket,
	reader:          bufio.Reader,
	is_open:         bool,
	in_flight:       bool,
	close_requested: bool,
}
