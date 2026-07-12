package core

import "base:runtime"
import "core:bufio"
import "core:fmt"
import "core:io"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

Main_Function_Name :: "старт"

CallFrame :: struct {
	function:      ^Compiled_Function,
	ip:            int, // Указатель текущей инструкции в ЭТОЙ функции
	frame_pointer: int, // Индекс в vm.stack, где начинаются локальные переменные ЭТОЙ функции
}

VM :: struct {
	frames:             [dynamic]CallFrame,
	compiled_functions: map[string]^Compiled_Function,
	stack:              [dynamic]Value,
	program_args:       []string,
	gc:                 GC_State,
	// Единый буферизованный reader над os.stdin — вне зависимости от того,
	// сколько раз вызван ввод_вывод.поток(), реальный поток ОС читается
	// ровно одним bufio.Reader'ом (см. get_stdin_reader). Несколько
	// независимых bufio.Reader поверх одного os.stdin буферизовали бы
	// каждый свой кусок и теряли байты, уже вычитанные другим.
	stdin_reader:       bufio.Reader,
	stdin_reader_ready: bool,
}

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

new_vm :: proc(
	compiled_functions: map[string]^Compiled_Function,
	program_args: []string = nil,
) -> ^VM {
	vm := new(VM)
	vm.frames = make([dynamic]CallFrame)
	vm.program_args = program_args
	vm.gc = new_gc_state()

	// Берем переданный словарь напрямую
	vm.compiled_functions = compiled_functions

	main_func, ok := vm.compiled_functions[Main_Function_Name]
	if !ok {
		fmt.panicf("Не определена функция 'старт'")
	}

	main_frame := CallFrame {
		function      = main_func,
		ip            = 0,
		frame_pointer = 0,
	}
	append(&vm.frames, main_frame)

	for _ in 0 ..< main_func.frame_size {
		append(&vm.stack, 0.0) // Забиваем нулями/nil
	}
	return vm
}

return_from_current_frame :: proc(vm: ^VM, result: Value) {
	frame := &vm.frames[len(vm.frames) - 1]
	callee_index := frame.frame_pointer - 1
	resize_to := callee_index
	if resize_to < 0 do resize_to = 0
	resize(&vm.stack, resize_to)
	if frame.function.returns_value {
		append(&vm.stack, result)
	}
	pop(&vm.frames)
}

variant_tag :: proc(v: Value) -> (int, bool) {
	if variant, ok := v.(^Variant_Value); ok {
		return variant.tag_index, true
	}
	if opt, ok := v.(^Option_Value); ok {
		if opt.has_value do return 1, true
		return 0, true
	}
	if res, ok := v.(^Result_Value); ok {
		if res.is_ok do return 0, true
		return 1, true
	}
	return 0, false
}

variant_field :: proc(v: Value, i: int) -> (Value, bool) {
	if variant, ok := v.(^Variant_Value); ok {
		if i < 0 || i >= len(variant.fields) do return Value{}, false
		return variant.fields[i], true
	}
	if opt, ok := v.(^Option_Value); ok {
		if opt.has_value && i == 0 do return opt.value, true
		return Value{}, false
	}
	if res, ok := v.(^Result_Value); ok {
		if i != 0 do return Value{}, false
		if res.is_ok do return res.value, true
		return res.error, true
	}
	return Value{}, false
}

value_equals :: proc(a: Value, b: Value) -> bool {
	#partial switch va in a {
	case f64:
		if vb, ok := b.(f64); ok do return va == vb
	case bool:
		if vb, ok := b.(bool); ok do return va == vb
	case ^Panos_String:
		if vb, ok := b.(^Panos_String); ok do return va.data == vb.data
	}
	return false
}

number_to_index :: proc(value: Value) -> int {
	number, ok := value.(f64)
	if !ok {
		fmt.panicf("Runtime Error: индекс массива должен быть числом")
	}

	idx := int(number)
	if number < 0 || f64(idx) != number {
		fmt.panicf(
			"Runtime Error: индекс массива должен быть неотрицательным целым числом",
		)
	}
	return idx
}

map_find_index :: proc(m: ^Map_Value, key: Value) -> int {
	for entry, i in m.entries {
		if value_equals(entry.key, key) do return i
	}
	return -1
}

map_remove_at :: proc(m: ^Map_Value, idx: int) {
	for i := idx; i < len(m.entries) - 1; i += 1 {
		m.entries[i] = m.entries[i + 1]
	}
	resize(&m.entries, len(m.entries) - 1)
}

expect_arg_count :: proc(method_name: string, actual: int, expected: int) {
	if actual != expected {
		fmt.panicf(
			"Runtime Error: метод '%s' ожидал %d аргументов, получено %d",
			method_name,
			expected,
			actual,
		)
	}
}

expect_string_arg :: proc(function_name: string, value: Value) -> string {
	text, ok := value.(^Panos_String)
	if !ok {
		fmt.panicf(
			"Runtime Error: %s ожидает строковый аргумент",
			function_name,
		)
	}
	return text.data
}

// code/message — компилируемые внутрь VM строки (например "ввод_вывод"),
// а не значения, снятые со стека, поэтому gc_new_string безопасен здесь без
// gc_protect: между gc_new(Error_Value) и присвоением полей других
// gc_new-вызовов, зависящих от уже-непротектнутых локалей, нет.
make_error_value :: proc(vm: ^VM, code: string, message: string) -> Value {
	err := gc_new(vm, Error_Value)
	gc_protect(vm, Value(err))
	err.code = gc_new_string(vm, code)
	err.message = gc_new_string(vm, message)
	gc_unprotect(vm, 1)
	return Value(err)
}

make_ok_result :: proc(vm: ^VM, value: Value) -> Value {
	gc_protect(vm, value)
	res := gc_new(vm, Result_Value)
	res.is_ok = true
	res.value = value
	res.error = f64(0)
	gc_unprotect(vm, 1)
	return Value(res)
}

make_error_result :: proc(vm: ^VM, err: Value) -> Value {
	gc_protect(vm, err)
	res := gc_new(vm, Result_Value)
	res.is_ok = false
	res.value = f64(0)
	res.error = err
	gc_unprotect(vm, 1)
	return Value(res)
}

// Общая точка чтения одной строки из ЛЮБОГО bufio.Reader — используется и
// для ввод_вывод::прочитать_строку (общий vm.stdin_reader), и для
// File_Value.прочитать_строку у обычных файлов (свой reader на дескриптор),
// и у Файл-обёртки над стдин (тот же vm.stdin_reader, см. get_stdin_reader).
// Один и тот же путь чтения+trim для всех трёх случаев — то самое
// "разделяет общий механизм", о котором просили.
read_line_from_reader :: proc(vm: ^VM, r: ^bufio.Reader) -> Value {
	line, err := bufio.reader_read_string(r, '\n', context.temp_allocator)
	if err != nil && err != .EOF {
		return make_error_result(vm, make_error_value(vm, "ввод_вывод", fmt.tprintf("%v", err)))
	}
	trimmed := strings.trim_right(line, "\r\n")
	return make_ok_result(vm, Value(gc_new_string(vm, trimmed)))
}

read_stdin_line :: proc(vm: ^VM) -> Value {
	return read_line_from_reader(vm, get_stdin_reader(vm))
}

// Вычитывает reader до EOF в temp-буфер (не трогает уже прочитанное — если
// перед .прочитать() были вызовы .прочитать_строку(), получаем ОСТАТОК
// файла, а не его начало заново, ровно как ожидалось бы от одного и того
// же файлового курсора).
read_all_from_reader :: proc(r: ^bufio.Reader) -> string {
	data := make([dynamic]byte, context.temp_allocator)
	buf: [4096]byte
	for {
		n, err := bufio.reader_read(r, buf[:])
		if n > 0 do append(&data, ..buf[:n])
		if err != nil do break
	}
	return string(data[:])
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

string_length :: proc(text: string) -> int {
	count := 0
	for _ in text {
		count += 1
	}
	return count
}

// Первая руна строки — строки::это_цифра/это_буква/цифра_или_буква
// принимают однобуквенную Строку (результат индексации text[i], см.
// Get_Index) как замену несуществующему в языке типу Символ.
first_rune :: proc(s: string) -> rune {
	if len(s) == 0 do return 0
	r, _ := utf8.decode_rune_in_string(s)
	return r
}

invoke_collection_method :: proc(
	vm: ^VM,
	receiver: Value,
	method_name: string,
	args: []Value,
) -> (
	Value,
	bool,
) {
	if opt, ok_opt := receiver.(^Option_Value); ok_opt {
		switch method_name {
		case "есть":
			expect_arg_count(method_name, len(args), 0)
			return Value(opt.has_value), true
		case "пусто":
			expect_arg_count(method_name, len(args), 0)
			return Value(!opt.has_value), true
		case "значение":
			expect_arg_count(method_name, len(args), 0)
			if !opt.has_value {
				fmt.panicf(
					"Runtime Error: попытка получить значение из пустой Опции",
				)
			}
			return opt.value, true
		case "получить":
			expect_arg_count(method_name, len(args), 1)
			if opt.has_value do return opt.value, true
			return args[0], true
		case "запас":
			expect_arg_count(method_name, len(args), 1)
			if opt.has_value do return Value(opt), true
			return args[0], true
		case "ожидать":
			expect_arg_count(method_name, len(args), 1)
			message := expect_string_arg(method_name, args[0])
			if !opt.has_value {
				fmt.panicf("Runtime Panic: %s", message)
			}
			return opt.value, true
		case "результат_или":
			expect_arg_count(method_name, len(args), 1)
			if opt.has_value do return make_ok_result(vm, opt.value), true
			return make_error_result(vm, args[0]), true
		case "заменить_значение":
			expect_arg_count(method_name, len(args), 1)
			replaced := gc_new(vm, Option_Value)
			replaced.has_value = opt.has_value
			if opt.has_value {
				replaced.value = args[0]
			} else {
				replaced.value = f64(0)
			}
			return Value(replaced), true
		}
	}

	if res, ok_res := receiver.(^Result_Value); ok_res {
		switch method_name {
		case "успех":
			expect_arg_count(method_name, len(args), 0)
			return Value(res.is_ok), true
		case "ошибка":
			expect_arg_count(method_name, len(args), 0)
			return Value(!res.is_ok), true
		case "значение":
			expect_arg_count(method_name, len(args), 0)
			if !res.is_ok {
				fmt.panicf(
					"Runtime Error: попытка получить значение из ошибочного Результата",
				)
			}
			return res.value, true
		case "причина":
			expect_arg_count(method_name, len(args), 0)
			if res.is_ok {
				fmt.panicf(
					"Runtime Error: попытка получить причину из успешного Результата",
				)
			}
			return res.error, true
		case "получить":
			expect_arg_count(method_name, len(args), 1)
			if res.is_ok do return res.value, true
			return args[0], true
		case "получить_ошибку":
			expect_arg_count(method_name, len(args), 1)
			if res.is_ok do return args[0], true
			return res.error, true
		case "запас":
			expect_arg_count(method_name, len(args), 1)
			if res.is_ok do return make_ok_result(vm, res.value), true
			return args[0], true
		case "ожидать":
			expect_arg_count(method_name, len(args), 1)
			message := expect_string_arg(method_name, args[0])
			if !res.is_ok {
				if err, ok_err := res.error.(^Error_Value); ok_err {
					fmt.panicf("Runtime Panic: %s: %s", message, err.message.data)
				}
				fmt.panicf("Runtime Panic: %s", message)
			}
			return res.value, true
		case "ожидать_ошибку":
			expect_arg_count(method_name, len(args), 1)
			message := expect_string_arg(method_name, args[0])
			if res.is_ok {
				fmt.panicf("Runtime Panic: %s", message)
			}
			return res.error, true
		case "опция":
			expect_arg_count(method_name, len(args), 0)
			opt := gc_new(vm, Option_Value)
			opt.has_value = res.is_ok
			if res.is_ok {
				opt.value = res.value
			} else {
				opt.value = f64(0)
			}
			return Value(opt), true
		case "ошибка_опция":
			expect_arg_count(method_name, len(args), 0)
			opt := gc_new(vm, Option_Value)
			opt.has_value = !res.is_ok
			if res.is_ok {
				opt.value = f64(0)
			} else {
				opt.value = res.error
			}
			return Value(opt), true
		case "заменить_значение":
			expect_arg_count(method_name, len(args), 1)
			if res.is_ok do return make_ok_result(vm, args[0]), true
			return make_error_result(vm, res.error), true
		case "заменить_ошибку":
			expect_arg_count(method_name, len(args), 1)
			if res.is_ok do return make_ok_result(vm, res.value), true
			return make_error_result(vm, args[0]), true
		}
	}

	if arr, ok_arr := receiver.(^Array_Value); ok_arr {
		switch method_name {
		case "длина":
			expect_arg_count(method_name, len(args), 0)
			return Value(f64(len(arr.elements))), true
		case "добавить":
			expect_arg_count(method_name, len(args), 1)
			append(&arr.elements, args[0])
			return Value(f64(0)), false
		case "получить":
			expect_arg_count(method_name, len(args), 2)
			idx := number_to_index(args[0])
			if idx >= len(arr.elements) do return args[1], true
			return arr.elements[idx], true
		case "есть":
			expect_arg_count(method_name, len(args), 1)
			idx := number_to_index(args[0])
			return Value(idx < len(arr.elements)), true
		case "содержит":
			expect_arg_count(method_name, len(args), 1)
			for el in arr.elements {
				if value_equals(el, args[0]) do return Value(true), true
			}
			return Value(false), true
		}
	}

	if m, ok_map := receiver.(^Map_Value); ok_map {
		switch method_name {
		case "длина":
			expect_arg_count(method_name, len(args), 0)
			return Value(f64(len(m.entries))), true
		case "есть":
			expect_arg_count(method_name, len(args), 1)
			return Value(map_find_index(m, args[0]) != -1), true
		case "получить":
			expect_arg_count(method_name, len(args), 2)
			idx := map_find_index(m, args[0])
			if idx == -1 do return args[1], true
			return m.entries[idx].value, true
		case "удалить":
			expect_arg_count(method_name, len(args), 1)
			idx := map_find_index(m, args[0])
			if idx == -1 do return Value(false), true
			map_remove_at(m, idx)
			return Value(true), true
		case "записи":
			// Массив((Ключ, Значение)) — единственный способ пройтись по
			// произвольному Соответствию без for-in. `m` (receiver) уже
			// снят с vm.stack к этому моменту (см. Invoke_Collection) —
			// протектим явно, иначе аллокация ниже может собрать его как
			// мусор посреди чтения m.entries.
			expect_arg_count(method_name, len(args), 0)
			gc_protect(vm, Value(m))
			arr := gc_new(vm, Array_Value)
			gc_protect(vm, Value(arr))
			for entry in m.entries {
				pair := gc_new(vm, Aggregate_Value)
				resize(&pair.elements, 2)
				pair.elements[0] = entry.key
				pair.elements[1] = entry.value
				append(&arr.elements, Value(pair))
			}
			gc_unprotect(vm, 2)
			return Value(arr), true
		}
	}

	if file, ok_file := receiver.(^File_Value); ok_file {
		switch method_name {
		case "прочитать":
			expect_arg_count(method_name, len(args), 0)
			if !file.is_open {
				return make_error_result(vm, make_error_value(vm, "фс", "файл уже закрыт")), true
			}
			content := read_all_from_reader(file_reader(vm, file))
			return make_ok_result(vm, Value(gc_new_string(vm, content))), true
		case "прочитать_строку":
			expect_arg_count(method_name, len(args), 0)
			if !file.is_open {
				return make_error_result(vm, make_error_value(vm, "фс", "файл уже закрыт")), true
			}
			return read_line_from_reader(vm, file_reader(vm, file)), true
		case "записать":
			expect_arg_count(method_name, len(args), 1)
			text := expect_string_arg(method_name, args[0])
			if !file.is_open || file.is_stdin {
				return make_error_result(vm, make_error_value(vm, "фс", "файл не открыт для записи")), true
			}
			n, err := os.write(file.handle, transmute([]byte)text)
			if err != nil {
				return make_error_result(vm, make_error_value(vm, "фс", fmt.tprintf("%v", err))), true
			}
			return make_ok_result(vm, Value(f64(n))), true
		case "закрыть":
			expect_arg_count(method_name, len(args), 0)
			close_file_value(file)
			return Value(f64(0)), false
		}
	}

	if sock, ok_sock := receiver.(^Socket_Value); ok_sock {
		switch method_name {
		case "получить":
			expect_arg_count(method_name, len(args), 0)
			if !sock.is_open {
				return make_error_result(vm, make_error_value(vm, "сеть", "соединение уже закрыто")), true
			}
			content := read_all_from_reader(&sock.reader)
			return make_ok_result(vm, Value(gc_new_string(vm, content))), true
		case "получить_строку":
			expect_arg_count(method_name, len(args), 0)
			if !sock.is_open {
				return make_error_result(vm, make_error_value(vm, "сеть", "соединение уже закрыто")), true
			}
			return read_line_from_reader(vm, &sock.reader), true
		case "отправить":
			expect_arg_count(method_name, len(args), 1)
			text := expect_string_arg(method_name, args[0])
			if !sock.is_open {
				return make_error_result(vm, make_error_value(vm, "сеть", "соединение уже закрыто")), true
			}
			n, err := net.send_tcp(sock.socket, transmute([]byte)text)
			if err != nil {
				return make_error_result(vm, make_error_value(vm, "сеть", fmt.tprintf("%v", err))), true
			}
			return make_ok_result(vm, Value(f64(n))), true
		case "закрыть":
			expect_arg_count(method_name, len(args), 0)
			close_socket_value(sock)
			return Value(f64(0)), false
		}
	}

	fmt.panicf(
		"Runtime Error: метод '%s' не найден у коллекции",
		method_name,
	)
}

call_builtin :: proc(vm: ^VM, name: string, args: []Value) -> (Value, bool) {
	switch name {
	case "Ошибка":
		expect_arg_count(name, len(args), 2)
		code, ok_code := args[0].(^Panos_String)
		message, ok_message := args[1].(^Panos_String)
		if !ok_code || !ok_message {
			fmt.panicf("Runtime Error: Ошибка() ожидает две строки")
		}
		// code/message уже на vm.stack через args (слайс в живой стек) —
		// протектить не нужно, они рутятся сами до возврата из этого вызова.
		err := gc_new(vm, Error_Value)
		err.code = code
		err.message = message
		return Value(err), true

	case "Есть":
		expect_arg_count(name, len(args), 1)
		opt := gc_new(vm, Option_Value)
		opt.has_value = true
		opt.value = args[0]
		return Value(opt), true

	case "Нет":
		expect_arg_count(name, len(args), 0)
		opt := gc_new(vm, Option_Value)
		opt.has_value = false
		opt.value = f64(0)
		return Value(opt), true

	case "Успех":
		expect_arg_count(name, len(args), 1)
		res := gc_new(vm, Result_Value)
		res.is_ok = true
		res.value = args[0]
		res.error = f64(0)
		return Value(res), true

	case "Неудача":
		expect_arg_count(name, len(args), 1)
		return make_error_result(vm, args[0]), true

	case "длина":
		expect_arg_count(name, len(args), 1)
		if text, ok := args[0].(^Panos_String); ok {
			return Value(f64(string_length(text.data))), true
		}
		if arr, ok := args[0].(^Array_Value); ok {
			return Value(f64(len(arr.elements))), true
		}
		if m, ok := args[0].(^Map_Value); ok {
			return Value(f64(len(m.entries))), true
		}
		fmt.panicf(
			"Runtime Error: длина() ожидает строку, массив или соответствие",
		)

	case "паника":
		expect_arg_count(name, len(args), 1)
		message := expect_string_arg(name, args[0])
		fmt.panicf("Runtime Panic: %s", message)

	case "фс::есть":
		expect_arg_count(name, len(args), 1)
		path := expect_string_arg(name, args[0])
		return Value(os.exists(path)), true

	case "фс::прочитать":
		expect_arg_count(name, len(args), 1)
		path := expect_string_arg(name, args[0])
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			return make_error_result(vm, make_error_value(vm, "фс", fmt.tprintf("%v", err))), true
		}
		return make_ok_result(vm, Value(gc_new_string(vm, string(data)))), true

	case "фс::записать":
		expect_arg_count(name, len(args), 2)
		path := expect_string_arg(name, args[0])
		content := expect_string_arg(name, args[1])
		err := os.write_entire_file(path, content)
		if err != nil {
			return make_error_result(vm, make_error_value(vm, "фс", fmt.tprintf("%v", err))), true
		}
		return make_ok_result(vm, Value(f64(len(content)))), true

	case "фс::открыть":
		expect_arg_count(name, len(args), 1)
		path := expect_string_arg(name, args[0])
		handle, err := os.open(path, {.Read, .Write, .Create}, os.Permissions_Default_File)
		if err != nil {
			return make_error_result(vm, make_error_value(vm, "фс", fmt.tprintf("%v", err))), true
		}
		file := gc_new(vm, File_Value)
		file.handle = handle
		file.is_open = true
		file.is_stdin = false
		context.allocator = runtime.heap_allocator()
		file.path = strings.clone(path)
		bufio.reader_init(&file.reader, os.to_stream(handle))
		return make_ok_result(vm, Value(file)), true

	case "ос::аргументы":
		expect_arg_count(name, len(args), 0)
		arr := gc_new(vm, Array_Value)
		gc_protect(vm, Value(arr))
		arr.elements = make([dynamic]Value)
		for arg in vm.program_args {
			append(&arr.elements, Value(gc_new_string(vm, arg)))
		}
		gc_unprotect(vm, 1)
		return Value(arr), true

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
		return Value(opt), true

	case "ос::установить_окружение":
		expect_arg_count(name, len(args), 2)
		key := expect_string_arg(name, args[0])
		value := expect_string_arg(name, args[1])
		err := os.set_env(key, value)
		if err != nil {
			return make_error_result(vm, make_error_value(vm, "ос", fmt.tprintf("%v", err))), true
		}
		return make_ok_result(vm, Value(f64(0))), true

	case "ос::удалить_окружение":
		expect_arg_count(name, len(args), 1)
		key := expect_string_arg(name, args[0])
		return Value(os.unset_env(key)), true

	case "ввод_вывод::печать":
		expect_arg_count(name, len(args), 1)
		text := expect_string_arg(name, args[0])
		fmt.print(text)
		return Value(f64(0)), false

	case "ввод_вывод::строка":
		expect_arg_count(name, len(args), 1)
		text := expect_string_arg(name, args[0])
		fmt.println(text)
		return Value(f64(0)), false

	case "ввод_вывод::прочитать_строку":
		expect_arg_count(name, len(args), 0)
		return read_stdin_line(vm), true

	case "ввод_вывод::поток":
		expect_arg_count(name, len(args), 0)
		file := gc_new(vm, File_Value)
		file.handle = nil
		file.path = ""
		file.is_open = true
		file.is_stdin = true
		return Value(file), true

	case "сеть::подключиться":
		expect_arg_count(name, len(args), 2)
		host := expect_string_arg(name, args[0])
		port_num, ok_port := args[1].(f64)
		if !ok_port {
			fmt.panicf("Runtime Error: сеть.подключиться() ожидает номер порта числом")
		}
		socket, dial_err := net.dial_tcp_from_hostname_with_port_override(host, int(port_num))
		if dial_err != nil {
			return make_error_result(vm, make_error_value(vm, "сеть", fmt.tprintf("%v", dial_err))), true
		}
		conn := gc_new(vm, Socket_Value)
		conn.socket = socket
		conn.is_open = true
		context.allocator = runtime.heap_allocator()
		bufio.reader_init(&conn.reader, tcp_to_stream(&conn.socket))
		return make_ok_result(vm, Value(conn)), true

	case "сеть::кодировать_url":
		// percent-encoding по байтам, не рунам — RFC 3986 unreserved
		// (A-Z a-z 0-9 - _ . ~) как есть, всё остальное как %XX (в т.ч.
		// каждый байт многобайтовой UTF-8 руны отдельно). Нет способа
		// сделать это в самом Panos — нет доступа к байтам строки.
		expect_arg_count(name, len(args), 1)
		text := expect_string_arg(name, args[0])
		builder: strings.Builder
		strings.builder_init(&builder, context.temp_allocator)
		for b in transmute([]byte)text {
			is_unreserved :=
				(b >= 'A' && b <= 'Z') ||
				(b >= 'a' && b <= 'z') ||
				(b >= '0' && b <= '9') ||
				b == '-' ||
				b == '_' ||
				b == '.' ||
				b == '~'
			if is_unreserved {
				strings.write_byte(&builder, b)
			} else {
				fmt.sbprintf(&builder, "%%%02X", b)
			}
		}
		return Value(gc_new_string(vm, strings.to_string(builder))), true

	case "строки::срез":
		expect_arg_count(name, len(args), 3)
		text := expect_string_arg(name, args[0])
		start := number_to_index(args[1])
		end := number_to_index(args[2])
		slice, ok := string_slice_by_rune(text, start, end)
		if !ok {
			fmt.panicf(
				"Runtime Error: срез [%d:%d] выходит за границы строки длиной %d",
				start,
				end,
				string_length(text),
			)
		}
		return Value(gc_new_string(vm, slice)), true

	case "строки::это_цифра":
		expect_arg_count(name, len(args), 1)
		text := expect_string_arg(name, args[0])
		return Value(unicode.is_digit(first_rune(text))), true

	case "строки::это_буква":
		expect_arg_count(name, len(args), 1)
		text := expect_string_arg(name, args[0])
		return Value(unicode.is_alpha(first_rune(text))), true

	case "строки::цифра_или_буква":
		expect_arg_count(name, len(args), 1)
		text := expect_string_arg(name, args[0])
		r := first_rune(text)
		return Value(unicode.is_digit(r) || unicode.is_alpha(r)), true

	case "строки::в_число":
		expect_arg_count(name, len(args), 1)
		text := expect_string_arg(name, args[0])
		num, ok := strconv.parse_f64(text)
		if !ok {
			return make_error_result(
				vm,
				make_error_value(vm, "строки", fmt.tprintf("'%s' не является числом", text)),
			), true
		}
		return make_ok_result(vm, Value(num)), true

	case "строки::из_числа":
		expect_arg_count(name, len(args), 1)
		num, ok_num := args[0].(f64)
		if !ok_num {
			fmt.panicf("Runtime Error: строки.из_числа() ожидает число")
		}
		return Value(gc_new_string(vm, fmt.tprintf("%v", num))), true
	}

	fmt.panicf(
		"Runtime Error: неизвестный встроенный конструктор '%s'",
		name,
	)
}

execute :: proc(vm: ^VM) {

	for len(vm.frames) > 0 {

		// Берем ТЕКУЩИЙ фрейм по указателю, чтобы мы могли менять его ip
		frame := &vm.frames[len(vm.frames) - 1]
		instructions := frame.function.instructions

		if frame.ip >= len(instructions) {
			// Если мы дошли до конца инструкций без явного RETURN,
			// просто удаляем фрейм (возвращаемся)
			pop(&vm.frames)
			continue
		}

		opcode := Opcode(instructions[frame.ip])

		#partial switch opcode {
		case .Constant:
			frame.ip += 1
			const_index := instructions[frame.ip]
			append(&vm.stack, frame.function.constants[const_index])

		case .Set_Local:
			frame.ip += 1
			slot_index := int(instructions[frame.ip])

			// 1. Берем верхнее значение (результат вычислений)
			value := pop(&vm.stack)
			// 2. Кладем его глубоко в стек, туда, где зарезервировано место переменной
			vm.stack[frame.frame_pointer + slot_index] = value

		case .Get_Local:
			frame.ip += 1
			slot_index := int(instructions[frame.ip])

			// 1. Читаем значение из глубин стека (относительно начала фрейма)
			value := vm.stack[frame.frame_pointer + slot_index]
			// 2. Копируем его на самую вершину стека для вычислений
			append(&vm.stack, value)

		case .Pop:
			pop(&vm.stack)

		case .Add:
			val_b := pop(&vm.stack)
			val_a := pop(&vm.stack)

			if a, ok_a := val_a.(f64); ok_a {
				if b, ok_b := val_b.(f64); ok_b {
					append(&vm.stack, Value(a + b))
					break
				}
			}

			if a, ok_a := val_a.(^Panos_String); ok_a {
				if b, ok_b := val_b.(^Panos_String); ok_b {
					// a/b уже сняты со стека, но fmt.tprintf читает их байты
					// СРАЗУ (temp_allocator), до вызова gc_new_string — им
					// не нужно переживать сам вызов, только предоставить
					// данные для конкатенации.
					append(&vm.stack, Value(gc_new_string(vm, fmt.tprintf("%s%s", a.data, b.data))))
					break
				}
			}

			fmt.panicf(
				"Runtime Error: оператор '+' ожидает два числа или две строки (было %v и %v)",
				val_a,
				val_b,
			)
		case .Subtract:
			r := pop(&vm.stack).(f64); l := pop(&vm.stack).(f64) // <-- ДОБАВЛЕНО
			append(&vm.stack, l - r) // <-- ДОБАВЛЕНО

		case .Multiply:
			r := pop(&vm.stack).(f64); l := pop(&vm.stack).(f64) // <-- ДОБАВЛЕНО
			append(&vm.stack, l * r) // <-- ДОБАВЛЕНО
		case .Divide:
			r := pop(&vm.stack).(f64); l := pop(&vm.stack).(f64) // <-- ДОБАВЛЕНО
			append(&vm.stack, l / r) // <-- ДОБАВЛЕНО

		case .Less:
			r := pop(&vm.stack).(f64); l := pop(&vm.stack).(f64) // <-- ДОБАВЛЕНО
			append(&vm.stack, l < r)

		case .Greater:
			r := pop(&vm.stack).(f64); l := pop(&vm.stack).(f64)
			append(&vm.stack, l > r)

		case .Negate:
			e := pop(&vm.stack).(bool)
			append(&vm.stack, !e)

		case .Equal:
			r := pop(&vm.stack)
			l := pop(&vm.stack)
			append(&vm.stack, value_equals(l, r))

		case .Call:
			frame.ip += 1
			arg_count := int(instructions[frame.ip])

			// 1. Ищем функцию на стеке. Она лежит под всеми аргументами!
			callee_index := len(vm.stack) - 1 - arg_count
			callee_val := vm.stack[callee_index]

			func_ptr, ok := callee_val.(^Compiled_Function)
			if !ok {
				fmt.panicf(
					"Runtime Error: попытка вызвать не функцию (получено: %v)",
					callee_val,
				)
			}

			// 2. Создаем новый фрейм
			new_frame := CallFrame {
				function      = func_ptr,
				ip            = 0,
				frame_pointer = callee_index + 1, // Переменные начинаются прямо с аргументов
			}

			// 3. Выделяем место под локальные переменные (нули)
			locals_to_allocate := func_ptr.frame_size - arg_count
			for _ in 0 ..< locals_to_allocate {
				append(&vm.stack, Value(f64(0)))
			}

			// 4. Запоминаем точку возврата для текущ��й функции
			vm.frames[len(vm.frames) - 1].ip = frame.ip + 1

			// 5. Переключаем контекст!
			append(&vm.frames, new_frame)
			continue // ВАЖНО: Начинаем новый цикл, пропуская frame.ip += 1 в конце

		case .Call_Builtin:
			frame.ip += 1
			name_index := instructions[frame.ip]
			frame.ip += 1
			arg_count := int(instructions[frame.ip])

			name := frame.function.constants[name_index].(^Panos_String).data
			args_start := len(vm.stack) - arg_count
			args := vm.stack[args_start:]
			result, has_result := call_builtin(vm, name, args)
			resize(&vm.stack, args_start)
			if has_result {
				append(&vm.stack, result)
			}

		case .Return:
			result: Value = f64(0) // Значение по умолчанию (если функция ничего не вернула)

			// Вычисляем, где заканчиваются локальные переменные
			base_frame_size := frame.frame_pointer + frame.function.frame_size

			// Если на стеке есть что-то ВЫШЕ локальных переменных — это наш результат!
			if len(vm.stack) > base_frame_size {
				result = pop(&vm.stack)
			}

			return_from_current_frame(vm, result)
			continue

		case .Try_Unwrap:
			value := pop(&vm.stack)
			if opt, ok_opt := value.(^Option_Value); ok_opt {
				if opt.has_value {
					append(&vm.stack, opt.value)
				} else {
					return_from_current_frame(vm, value)
					continue
				}
			} else if res, ok_res := value.(^Result_Value); ok_res {
				if res.is_ok {
					append(&vm.stack, res.value)
				} else {
					return_from_current_frame(vm, value)
					continue
				}
			} else {
				fmt.panicf(
					"Runtime Error: оператор '?' ожидал Опцию или Результат",
				)
			}

		case .Jump_If_False:
			// Читаем 2 байта смещения
			frame.ip += 1
			high := u16(instructions[frame.ip])
			frame.ip += 1
			low := u16(instructions[frame.ip])

			offset := (high << 8) | low

			// Снимаем условие со стека
			condition_val := pop(&vm.stack)

			// Мы не делаем ok-проверку, потому что Type Checker
			// УЖЕ гарантировал, что на стеке лежит строго bool!
			condition := condition_val.(bool)

			if !condition {
				frame.ip += int(offset) // Прыгаем вперед!
			}

		case .Jump:
			frame.ip += 1
			high := u16(instructions[frame.ip])
			frame.ip += 1
			low := u16(instructions[frame.ip])

			offset := (high << 8) | low

			// Безусловный прыжок (например, в конец if после выполнения then)
			// Если offset отрицательный (в случае While), int() сохранит знак.
			frame.ip += int(i16(offset))
		case .Build_Aggregate:
			frame.ip += 1
			count := int(instructions[frame.ip])

			agg := gc_new(vm, Aggregate_Value)
			resize(&agg.elements, count)

			// ВАЖНО: Снимаем значения со стека в ОБРАТНОМ порядке!
			// Если было Игрок(10, 20), то 20 лежит на самом верху стека (индекс 1).
			for i := count - 1; i >= 0; i -= 1 {
				agg.elements[i] = pop(&vm.stack)
			}

			// Кладем готовую структуру на стек
			append(&vm.stack, Value(agg))

		case .Build_Variant:
			frame.ip += 1
			name_index := int(instructions[frame.ip])
			frame.ip += 1
			tag := int(instructions[frame.ip])
			frame.ip += 1
			arity := int(instructions[frame.ip])

			type_name := frame.function.constants[name_index].(^Panos_String).data

			variant := gc_new(vm, Variant_Value)
			variant.type_name = type_name
			variant.tag_index = tag
			resize(&variant.fields, arity)
			for i := arity - 1; i >= 0; i -= 1 {
				variant.fields[i] = pop(&vm.stack)
			}
			append(&vm.stack, Value(variant))

		case .Match_Tag:
			frame.ip += 1
			tag_const_idx := int(instructions[frame.ip])
			expected_tag := int(frame.function.constants[tag_const_idx].(f64))
			subject := vm.stack[len(vm.stack) - 1]
			actual_tag, ok := variant_tag(subject)
			if !ok {
				fmt.panicf(
					"Runtime Error: выбор ожидал значение перечисления, но получил %v",
					subject,
				)
			}
			append(&vm.stack, Value(actual_tag == expected_tag))

		case .Get_Variant_Field:
			frame.ip += 1
			field_idx := int(instructions[frame.ip])
			subject := pop(&vm.stack)
			field_val, ok := variant_field(subject, field_idx)
			if !ok {
				fmt.panicf(
					"Runtime Error: попытка прочитать поле #%d у неподходящего варианта",
					field_idx,
				)
			}
			append(&vm.stack, field_val)

		case .Match_Fail:
			subject := vm.stack[len(vm.stack) - 1]
			variant_name := "?"
			if v, is_variant := subject.(^Variant_Value); is_variant {
				variant_name = v.type_name
			}
			fmt.panicf(
				"Runtime Error: значение варианта '%s' не покрыто ни одной веткой выбора",
				variant_name,
			)

		case .Build_Array:
			frame.ip += 1
			count := int(instructions[frame.ip])

			arr := gc_new(vm, Array_Value)
			resize(&arr.elements, count)

			for i := count - 1; i >= 0; i -= 1 {
				arr.elements[i] = pop(&vm.stack)
			}

			append(&vm.stack, Value(arr))

		case .Build_Map:
			frame.ip += 1
			count := int(instructions[frame.ip])

			m := gc_new(vm, Map_Value)
			resize(&m.entries, count)

			for i := count - 1; i >= 0; i -= 1 {
				value := pop(&vm.stack)
				key := pop(&vm.stack)
				m.entries[i] = Map_Entry_Value {
					key   = key,
					value = value,
				}
			}

			append(&vm.stack, Value(m))

		case .Get_Property:
			frame.ip += 1
			idx := int(instructions[frame.ip])

			val := pop(&vm.stack)
			if agg, ok_agg := val.(^Aggregate_Value); ok_agg {
				append(&vm.stack, agg.elements[idx])
			} else if err, ok_err := val.(^Error_Value); ok_err {
				switch idx {
				case 0:
					append(&vm.stack, Value(err.code))
				case 1:
					append(&vm.stack, Value(err.message))
				case:
					fmt.panicf(
						"Runtime Error: у Ошибка нет поля с индексом %d",
						idx,
					)
				}
			} else {
				fmt.panicf(
					"Runtime Error: попытка прочитать поле у примитивного типа",
				)
			}

		case .Set_Property:
			frame.ip += 1
			idx := int(instructions[frame.ip])

			value := pop(&vm.stack)
			target := pop(&vm.stack)

			if agg, ok_agg := target.(^Aggregate_Value); ok_agg {
				agg.elements[idx] = value
			} else if iface, ok_iface := target.(^Interface_Value); ok_iface {
				iface.data.elements[idx] = value
			} else if err, ok_err := target.(^Error_Value); ok_err {
				text, ok_text := value.(^Panos_String)
				if !ok_text {
					fmt.panicf(
						"Runtime Error: поля Ошибка принимают только строки",
					)
				}
				switch idx {
				case 0:
					err.code = text
				case 1:
					err.message = text
				case:
					fmt.panicf(
						"Runtime Error: у Ошибка нет поля с индексом %d",
						idx,
					)
				}
			} else {
				fmt.panicf(
					"Runtime Error: попытка записать поле у примитивного типа",
				)
			}

		case .Get_Index:
			index := pop(&vm.stack)
			receiver := pop(&vm.stack)

			if arr, ok_arr := receiver.(^Array_Value); ok_arr {
				idx := number_to_index(index)
				if idx >= len(arr.elements) {
					fmt.panicf(
						"Runtime Error: индекс %d выходит за границы массива",
						idx,
					)
				}
				append(&vm.stack, arr.elements[idx])
			} else if m, ok_map := receiver.(^Map_Value); ok_map {
				idx := map_find_index(m, index)
				if idx == -1 {
					fmt.panicf(
						"Runtime Error: ключ не найден в соответствии",
					)
				}
				append(&vm.stack, m.entries[idx].value)
			} else if m, ok_string := receiver.(^Panos_String); ok_string {
				idx := number_to_index(index)

				if char_str, ok := get_character_at(m.data, idx); ok {
					new_string := Value(gc_new_string(vm, char_str))
					append(&vm.stack, new_string)
				} else {
					fmt.panicf(
						"Runtime Error: индекс %d выходит за границы массива",
						idx,
					)
				}
			} else {
				fmt.panicf(
					"Runtime Error: индексирование поддерживают только массивы и соответствия",
				)
			}

		case .Set_Index:
			value := pop(&vm.stack)
			index := pop(&vm.stack)
			receiver := pop(&vm.stack)

			if arr, ok_arr := receiver.(^Array_Value); ok_arr {
				idx := number_to_index(index)
				if idx >= len(arr.elements) {
					fmt.panicf(
						"Runtime Error: индекс %d выходит за границы массива",
						idx,
					)
				}
				arr.elements[idx] = value
			} else if m, ok_map := receiver.(^Map_Value); ok_map {
				idx := map_find_index(m, index)
				if idx == -1 {
					append(&m.entries, Map_Entry_Value{key = index, value = value})
				} else {
					m.entries[idx].value = value
				}
			} else {
				fmt.panicf(
					"Runtime Error: индексная запись поддерживает только массивы и соответствия",
				)
			}

		case .Cast_Interface:
			frame.ip += 1
			struct_name_index := instructions[frame.ip]
			struct_name := frame.function.constants[struct_name_index].(^Panos_String).data

			val := pop(&vm.stack)
			agg, ok := val.(^Aggregate_Value)
			if !ok {
				fmt.panicf(
					"Runtime Error: в интерфейс можно привести только структуру",
				)
			}
			// agg только что снят со стека — до gc_new(Interface_Value) он
			// нигде не закреплён, protect'им явно (см. gc_protect в gc.odin).
			gc_protect(vm, val)

			iface := gc_new(vm, Interface_Value)
			iface.data = agg
			iface.methods = make(map[string]^Compiled_Function)

			prefix := fmt.tprintf("%s::", struct_name)
			for name, fn in vm.compiled_functions {
				if len(name) > len(prefix) && name[:len(prefix)] == prefix {
					iface.methods[name[len(prefix):]] = fn
				}
			}

			gc_unprotect(vm, 1)
			append(&vm.stack, Value(iface))

		case .Invoke_Interface:
			frame.ip += 1
			method_name_index := instructions[frame.ip]
			frame.ip += 1
			arg_count := int(instructions[frame.ip])

			method_name := frame.function.constants[method_name_index].(^Panos_String).data
			callee_index := len(vm.stack) - 1 - arg_count
			iface_val := vm.stack[callee_index]

			iface, ok := iface_val.(^Interface_Value)
			if !ok {
				fmt.panicf(
					"Runtime Error: попытка вызвать интерфейсный метод у не-интерфейса",
				)
			}

			func_ptr, found := iface.methods[method_name]
			if !found {
				fmt.panicf(
					"Runtime Error: метод '%s' не найден в vtable интерфейса",
					method_name,
				)
			}

			vm.stack[callee_index] = Value(func_ptr)
			append(&vm.stack, Value(f64(0)))
			for i := len(vm.stack) - 1; i > callee_index + 1; i -= 1 {
				vm.stack[i] = vm.stack[i - 1]
			}
			vm.stack[callee_index + 1] = Value(iface.data)

			total_arg_count := arg_count + 1
			new_frame := CallFrame {
				function      = func_ptr,
				ip            = 0,
				frame_pointer = callee_index + 1,
			}

			locals_to_allocate := func_ptr.frame_size - total_arg_count
			for _ in 0 ..< locals_to_allocate {
				append(&vm.stack, Value(f64(0)))
			}

			vm.frames[len(vm.frames) - 1].ip = frame.ip + 1
			append(&vm.frames, new_frame)
			continue

		case .Invoke_Collection:
			frame.ip += 1
			method_name_index := instructions[frame.ip]
			frame.ip += 1
			arg_count := int(instructions[frame.ip])

			method_name := frame.function.constants[method_name_index].(^Panos_String).data
			receiver_index := len(vm.stack) - 1 - arg_count
			receiver := vm.stack[receiver_index]
			args := vm.stack[receiver_index + 1:]

			result, has_result := invoke_collection_method(vm, receiver, method_name, args)
			resize(&vm.stack, receiver_index)
			if has_result {
				append(&vm.stack, result)
			}
		}

		// Двигаем IP текущего фрейма вперед
		frame.ip += 1
	}

}

print_vm :: proc(vm: ^VM) {
	for s in vm.stack {
		if ps, ok := s.(^Panos_String); ok {
			fmt.println(ps.data)
		} else {
			fmt.println(s)
		}
	}
}
