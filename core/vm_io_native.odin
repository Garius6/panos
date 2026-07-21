#+build !js
package core

import "base:runtime"
import "core:bufio"
import "core:fmt"
import "core:io"
import "core:net"
import "core:os"
import "core:strings"

// Ленивая инициализация общего reader'а над os.stdin. Аллокатор буфера
// закреплён на runtime.heap_allocator(), а не на context.allocator в точке
// вызова (тот же урок, что и с GC-хипом в gc.odin/interner.odin) — VM живёт
// весь процесс, буфер не должен зависеть от арены вызывающего кода.
get_stdin_reader :: proc(vm: ^VM) -> ^bufio.Reader {
	if !vm.stdin_reader_ready {
		context.allocator = runtime.heap_allocator()
		bufio.reader_init(&vm.stdin_reader, os.to_stream(os.stdin))
		vm.stdin_reader_ready = true
	}
	return &vm.stdin_reader
}

read_stdin_line :: proc(vm: ^VM) -> Value {
	return read_line_from_reader(vm, get_stdin_reader(vm))
}

// Куда читать для конкретного File_Value: у обычного файла — его
// собственный buffer, у Файл-обёртки над стдин — единый vm.stdin_reader
// (см. комментарий у поля stdin_reader в VM).
file_reader :: proc(vm: ^VM, file: ^File_Value) -> ^bufio.Reader {
	if file.is_stdin do return get_stdin_reader(vm)
	return &file.reader
}

// Единая точка закрытия File_Value — вызывается и явным .закрыть() из Panos-
// кода, и GC-финализатором в pool_release (см. gc.odin), когда хендл стал
// недостижим, но не был закрыт явно. is_open — гейт идемпотентности: оба
// пути могут сойтись на одном объекте (сначала явный close, потом sweep),
// второй вызов обязан быть no-op.
close_file_value :: proc(file: ^File_Value) {
	if !file.is_open do return
	if !file.is_stdin {
		if file.handle != nil do os.close(file.handle)
		bufio.reader_destroy(&file.reader)
	}
	file.handle = nil
	file.is_open = false
}

// io.Stream поверх net.recv_tcp — только .Read, чего достаточно для
// bufio.Reader (io.read зовёт ровно этот mode, см. core:io/io.odin). Даёт
// Socket_Value переиспользовать read_line_from_reader/read_all_from_reader
// один в один с File_Value, без отдельного пути чтения для сокетов.
tcp_recv_stream_proc :: proc(
	stream_data: rawptr,
	mode: io.Stream_Mode,
	p: []byte,
	offset: i64,
	whence: io.Seek_From,
) -> (
	n: i64,
	err: io.Error,
) {
	#partial switch mode {
	case .Read:
		socket := (^net.TCP_Socket)(stream_data)
		read_n, recv_err := net.recv_tcp(socket^, p)
		if recv_err != nil {
			return i64(read_n), .Unknown
		}
		if read_n == 0 {
			// recv_tcp: 0 байт + nil-ошибка == соединение закрыто с той
			// стороны — это EOF, а не "нечего было прочитать в этот
			// момент" (в отличие от неблокирующих сокетов, наши блокируют).
			return 0, .EOF
		}
		return i64(read_n), nil
	}
	return 0, .Empty
}

tcp_to_stream :: proc(socket: ^net.TCP_Socket) -> io.Stream {
	return io.Stream{procedure = tcp_recv_stream_proc, data = socket}
}

// Симметрично close_file_value — единая точка закрытия для явного
// .закрыть() и GC-финализатора (см. gc.odin::pool_release).
close_socket_value :: proc(sock: ^Socket_Value) {
	if !sock.is_open do return
	bufio.reader_destroy(&sock.reader)
	net.close(sock.socket)
	sock.is_open = false
}

// фс::*/ос::окружение*/ввод_вывод::прочитать_строку/поток/сеть::подключиться
// — вынесены сюда из call_builtin (vm.odin) целиком, т.к. трогают os/net
// напрямую. handled=false для всех остальных имён — вызывающий код
// (call_builtin) продолжает свой обычный switch.
call_builtin_io :: proc(vm: ^VM, name: string, args: []Value) -> (result: Value, ok: bool, handled: bool) {
	switch name {
	case "фс::есть":
		expect_arg_count(name, len(args), 1)
		path := expect_string_arg(name, args[0])
		return Value(os.exists(path)), true, true

	case "фс::прочитать":
		expect_arg_count(name, len(args), 1)
		path := expect_string_arg(name, args[0])
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			return make_error_result(vm, make_error_value(vm, "фс", fmt.tprintf("%v", err))), true, true
		}
		return make_ok_result(vm, Value(gc_new_string(vm, string(data)))), true, true

	case "фс::записать":
		expect_arg_count(name, len(args), 2)
		path := expect_string_arg(name, args[0])
		content := expect_string_arg(name, args[1])
		err := os.write_entire_file(path, content)
		if err != nil {
			return make_error_result(vm, make_error_value(vm, "фс", fmt.tprintf("%v", err))), true, true
		}
		return make_ok_result(vm, Value(f64(len(content)))), true, true

	case "фс::открыть":
		expect_arg_count(name, len(args), 1)
		path := expect_string_arg(name, args[0])
		handle, err := os.open(path, {.Read, .Write, .Create}, os.Permissions_Default_File)
		if err != nil {
			return make_error_result(vm, make_error_value(vm, "фс", fmt.tprintf("%v", err))), true, true
		}
		file := gc_new(vm, File_Value)
		file.handle = handle
		file.is_open = true
		file.is_stdin = false
		context.allocator = runtime.heap_allocator()
		file.path = strings.clone(path)
		bufio.reader_init(&file.reader, os.to_stream(handle))
		return make_ok_result(vm, Value(file)), true, true

	case "ос::окружение":
		expect_arg_count(name, len(args), 1)
		key := expect_string_arg(name, args[0])
		value, found := os.lookup_env(key, context.allocator)
		opt := gc_new(vm, Option_Value)
		gc_protect(vm, Value(opt))
		opt.has_value = found
		if found {
			opt.value = Value(gc_new_string(vm, value))
		} else {
			opt.value = Value(gc_new_string(vm, ""))
		}
		gc_unprotect(vm, 1)
		return Value(opt), true, true

	case "ос::установить_окружение":
		expect_arg_count(name, len(args), 2)
		key := expect_string_arg(name, args[0])
		value := expect_string_arg(name, args[1])
		err := os.set_env(key, value)
		if err != nil {
			return make_error_result(vm, make_error_value(vm, "ос", fmt.tprintf("%v", err))), true, true
		}
		return make_ok_result(vm, Value(f64(0))), true, true

	case "ос::удалить_окружение":
		expect_arg_count(name, len(args), 1)
		key := expect_string_arg(name, args[0])
		return Value(os.unset_env(key)), true, true

	case "ввод_вывод::прочитать_строку":
		expect_arg_count(name, len(args), 0)
		return read_stdin_line(vm), true, true

	case "ввод_вывод::поток":
		expect_arg_count(name, len(args), 0)
		file := gc_new(vm, File_Value)
		file.handle = nil
		file.path = ""
		file.is_open = true
		file.is_stdin = true
		return Value(file), true, true

	case "сеть::подключиться":
		expect_arg_count(name, len(args), 2)
		host := expect_string_arg(name, args[0])
		port_num, ok_port := args[1].(f64)
		if !ok_port {
			fmt.panicf("Runtime Error: сеть.подключиться() ожидает номер порта числом")
		}
		socket, dial_err := net.dial_tcp_from_hostname_with_port_override(host, int(port_num))
		if dial_err != nil {
			return make_error_result(vm, make_error_value(vm, "сеть", fmt.tprintf("%v", dial_err))), true, true
		}
		conn := gc_new(vm, Socket_Value)
		conn.socket = socket
		conn.is_open = true
		context.allocator = runtime.heap_allocator()
		bufio.reader_init(&conn.reader, tcp_to_stream(&conn.socket))
		return make_ok_result(vm, Value(conn)), true, true
	}
	return
}

// Общий guard "receiver уже закрыт" — тело идентично во всех 6 точках
// invoke_io_method ниже (3 File_Value + 3 Socket_Value), отличался только
// модуль/текст ошибки.
io_closed_error :: proc(vm: ^VM, module: string, message: string) -> (Value, bool, bool) {
	return make_error_result(vm, make_error_value(vm, module, message)), true, true
}

// File_Value/Socket_Value методы (.прочитать/.прочитать_строку/.записать/
// .закрыть, .получить/.получить_строку/.отправить/.закрыть) — вынесены из
// invoke_collection_method (vm.odin) целиком, трогают os.write/net.send_tcp.
invoke_io_method :: proc(
	vm: ^VM,
	receiver: Value,
	method_name: string,
	args: []Value,
) -> (
	result: Value,
	ok: bool,
	handled: bool,
) {
	if file, ok_file := receiver.(^File_Value); ok_file {
		handled = true
		switch method_name {
		case "прочитать":
			expect_arg_count(method_name, len(args), 0)
			if !file.is_open {
				return io_closed_error(vm, "фс", "файл уже закрыт")
			}
			content := read_all_from_reader(file_reader(vm, file))
			return make_ok_result(vm, Value(gc_new_string(vm, content))), true, true
		case "прочитать_строку":
			expect_arg_count(method_name, len(args), 0)
			if !file.is_open {
				return io_closed_error(vm, "фс", "файл уже закрыт")
			}
			return read_line_from_reader(vm, file_reader(vm, file)), true, true
		case "записать":
			expect_arg_count(method_name, len(args), 1)
			text := expect_string_arg(method_name, args[0])
			if !file.is_open || file.is_stdin {
				return io_closed_error(vm, "фс", "файл не открыт для записи")
			}
			n, err := os.write(file.handle, transmute([]byte)text)
			if err != nil {
				return make_error_result(vm, make_error_value(vm, "фс", fmt.tprintf("%v", err))), true, true
			}
			return make_ok_result(vm, Value(f64(n))), true, true
		case "закрыть":
			expect_arg_count(method_name, len(args), 0)
			// Фаза 4: если сейчас идёт фоновое стриминговое чтение
			// (in_flight — воркер физически держит &file.reader/handle),
			// настоящий os.close/bufio.reader_destroy отложен до его
			// завершения (deliver_async_result, vm.odin) — иначе гонка
			// с воркером на том же хендле. is_open НЕ трогаем здесь —
			// close_file_value сам его выставит, когда реально сработает;
			// тронуть его сейчас сделало бы отложенный close_file_value
			// молчаливым no-op по его же идемпотентному гейту.
			if file.in_flight {
				file.close_requested = true
				return Value(f64(0)), false, true
			}
			close_file_value(file)
			return Value(f64(0)), false, true
		}
		return
	}

	if sock, ok_sock := receiver.(^Socket_Value); ok_sock {
		handled = true
		switch method_name {
		case "получить":
			expect_arg_count(method_name, len(args), 0)
			if !sock.is_open {
				return io_closed_error(vm, "сеть", "соединение уже закрыто")
			}
			content := read_all_from_reader(&sock.reader)
			return make_ok_result(vm, Value(gc_new_string(vm, content))), true, true
		case "получить_строку":
			expect_arg_count(method_name, len(args), 0)
			if !sock.is_open {
				return io_closed_error(vm, "сеть", "соединение уже закрыто")
			}
			return read_line_from_reader(vm, &sock.reader), true, true
		case "отправить":
			expect_arg_count(method_name, len(args), 1)
			text := expect_string_arg(method_name, args[0])
			if !sock.is_open {
				return io_closed_error(vm, "сеть", "соединение уже закрыто")
			}
			n, err := net.send_tcp(sock.socket, transmute([]byte)text)
			if err != nil {
				return make_error_result(vm, make_error_value(vm, "сеть", fmt.tprintf("%v", err))), true, true
			}
			return make_ok_result(vm, Value(f64(n))), true, true
		case "закрыть":
			expect_arg_count(method_name, len(args), 0)
			// Фаза 4: симметрично File_Value.закрыть выше.
			if sock.in_flight {
				sock.close_requested = true
				return Value(f64(0)), false, true
			}
			close_socket_value(sock)
			return Value(f64(0)), false, true
		}
		return
	}

	return
}
