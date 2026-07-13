#+build !js
package core

import "core:bufio"
import "core:net"
import "core:os"

// Дескриптор открытого файла или потока ввода (стдин). is_stdin файлы не
// владеют ОС-хендлом (нельзя закрыть стдин) — закрытие для них no-op.
File_Value :: struct {
	header:   GC_Header,
	handle:   ^os.File,
	reader:   bufio.Reader,
	path:     string,
	is_open:  bool,
	is_stdin: bool,
}

// TCP-соединение (сеть.подключиться). reader читает через свой io.Stream
// поверх net.recv_tcp (см. tcp_to_stream в vm.odin) — тот же
// read_line_from_reader/read_all_from_reader, что и у File_Value, без
// дублирования логики чтения.
Socket_Value :: struct {
	header:  GC_Header,
	socket:  net.TCP_Socket,
	reader:  bufio.Reader,
	is_open: bool,
}
