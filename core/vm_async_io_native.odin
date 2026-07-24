#+build !js
package core

import "core:bufio"
import "core:bytes"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync/chan"
import "core:thread"
import http "../external/odin-http"
import client "../external/odin-http/client"

// Tcp_Connect_Result_Data — единственный payload с платформозависимым полем
// (см. vm_async.odin) — здесь socket настоящий net.TCP_Socket. wasm-пара
// (vm_async_io_wasm.odin) объявляет тот же ИМЯ типа с rawptr-заглушкой (тот
// же приём, что File_Value/Socket_Value, см. file_value_native/wasm.odin).
Tcp_Connect_Result_Data :: struct {
	socket: net.TCP_Socket,
	err:    Maybe(string),
}

// Неблокирующий I/O: submit-сторона для сеть::http_запрос — извлекает
// ПРОСТЫЕ Odin-типы из Value-аргументов (та же логика, что раньше была
// инлайн в call_builtin_http, см. vm_http_native.odin) и КЛОНИРУЕТ их
// (strings.clone) — Panos_String.data указывает на GC-managed память,
// которая может быть собрана сборщиком мусора, пока задача ждёт в очереди
// воркер-пула на ДРУГОМ потоке.
//
// ВСЕ аллокации здесь и в http_task_proc — ЯВНО на vm_heap_allocator()
// (настоящий OS-хип, core/gc.odin), НЕ на ambient context.allocator.
// Причина (живой баг, найден через SIGABRT "pointer being freed was not
// allocated"): main.odin устанавливает context.allocator ПРОГРАММЫ ЦЕЛИКОМ
// на mem.Dynamic_Arena (bump-allocator, НЕ потокобезопасен, не поддерживает
// free() отдельных объектов) — воркер-поток, unwind'ящий Task.allocator
// (thread_pool.odin's pool_do_work делает context.allocator = task.allocator
// на время вызова task.procedure), получил бы ТУ ЖЕ арену, если бы submit_
// async_io передал ambient context.allocator в pool_add_task. free()/
// strings.clone() через общую однопоточную арену с ДРУГОГО потока —
// гонка/порча состояния арены. vm_heap_allocator() — тот же приём, что уже
// использует INTERNER (core/interner.odin) для ровно той же проблемы
// (permanent-хип независимо от ambient context.allocator).
submit_async_io :: proc(vm: ^VM, name: string, args: []Value, target_id: int) {
	switch name {
	case "сеть::http_запрос":
		expect_arg_count(name, len(args), 4)
		method_str := expect_string_arg(name, args[0])
		url := expect_string_arg(name, args[1])
		body_str := expect_string_arg(name, args[2])
		headers_map, is_map := args[3].(^Map_Value)

		heap := vm_heap_allocator()
		headers: [dynamic][2]string
		headers.allocator = heap
		if is_map {
			for entry in headers_map.entries {
				k, k_ok := entry.key.(^Panos_String)
				v, v_ok := entry.value.(^Panos_String)
				if k_ok && v_ok {
					append(&headers, [2]string{strings.clone(k.data, heap), strings.clone(v.data, heap)})
				}
			}
		}

		vm.next_ticket_id += 1
		task_data := new(Http_Task_Data, heap)
		task_data.completions = vm.async_completions
		task_data.target_id = target_id
		task_data.ticket_id = vm.next_ticket_id
		task_data.method_str = strings.clone(method_str, heap)
		task_data.url = strings.clone(url, heap)
		task_data.body_str = strings.clone(body_str, heap)
		task_data.request_headers = headers

		thread.pool_add_task(&vm.async_pool, heap, http_task_proc, task_data)

	case "фс::прочитать":
		expect_arg_count(name, len(args), 1)
		path := expect_string_arg(name, args[0])

		heap := vm_heap_allocator()
		vm.next_ticket_id += 1
		task_data := new(File_Read_Task_Data, heap)
		task_data.completions = vm.async_completions
		task_data.target_id = target_id
		task_data.ticket_id = vm.next_ticket_id
		task_data.path = strings.clone(path, heap)

		thread.pool_add_task(&vm.async_pool, heap, file_read_task_proc, task_data)

	case "фс::записать":
		expect_arg_count(name, len(args), 2)
		path := expect_string_arg(name, args[0])
		content := expect_string_arg(name, args[1])

		heap := vm_heap_allocator()
		vm.next_ticket_id += 1
		task_data := new(File_Write_Task_Data, heap)
		task_data.completions = vm.async_completions
		task_data.target_id = target_id
		task_data.ticket_id = vm.next_ticket_id
		task_data.path = strings.clone(path, heap)
		task_data.content = strings.clone(content, heap)

		thread.pool_add_task(&vm.async_pool, heap, file_write_task_proc, task_data)

	case "сеть::подключиться":
		expect_arg_count(name, len(args), 2)
		host := expect_string_arg(name, args[0])
		port_num, ok_port := args[1].(f64)
		if !ok_port {
			fmt.panicf("Runtime Error: сеть.подключиться() ожидает номер порта числом")
		}

		heap := vm_heap_allocator()
		vm.next_ticket_id += 1
		task_data := new(Tcp_Connect_Task_Data, heap)
		task_data.completions = vm.async_completions
		task_data.target_id = target_id
		task_data.ticket_id = vm.next_ticket_id
		task_data.host = strings.clone(host, heap)
		task_data.port = int(port_num)

		thread.pool_add_task(&vm.async_pool, heap, tcp_connect_task_proc, task_data)
	}
}

File_Read_Task_Data :: struct {
	completions: chan.Chan(Async_Result),
	target_id:   int,
	ticket_id:   int,
	path:        string,
}

file_read_task_proc :: proc(task: thread.Task) {
	heap := vm_heap_allocator()
	data := cast(^File_Read_Task_Data)task.data
	defer {
		delete(data.path, heap)
		mem.free(data, heap)
	}

	result := Async_Result {
		ticket_id = data.ticket_id,
		target_id = data.target_id,
	}

	content, err := os.read_entire_file(data.path, heap)
	if err != nil {
		result.payload = File_Read_Result_Data{err = fmt.aprintf("%v", err, allocator = heap)}
	} else {
		result.payload = File_Read_Result_Data{content = string(content)}
	}
	chan.send(data.completions, result)
}

File_Write_Task_Data :: struct {
	completions: chan.Chan(Async_Result),
	target_id:   int,
	ticket_id:   int,
	path:        string,
	content:     string,
}

file_write_task_proc :: proc(task: thread.Task) {
	heap := vm_heap_allocator()
	data := cast(^File_Write_Task_Data)task.data
	defer {
		delete(data.path, heap)
		delete(data.content, heap)
		mem.free(data, heap)
	}

	result := Async_Result {
		ticket_id = data.ticket_id,
		target_id = data.target_id,
	}

	err := os.write_entire_file(data.path, data.content)
	if err != nil {
		result.payload = File_Write_Result_Data{err = fmt.aprintf("%v", err, allocator = heap)}
	} else {
		result.payload = File_Write_Result_Data{bytes_written = len(data.content)}
	}
	chan.send(data.completions, result)
}

Tcp_Connect_Task_Data :: struct {
	completions: chan.Chan(Async_Result),
	target_id:   int,
	ticket_id:   int,
	host:        string,
	port:        int,
}

tcp_connect_task_proc :: proc(task: thread.Task) {
	heap := vm_heap_allocator()
	data := cast(^Tcp_Connect_Task_Data)task.data
	defer {
		delete(data.host, heap)
		mem.free(data, heap)
	}

	result := Async_Result {
		ticket_id = data.ticket_id,
		target_id = data.target_id,
	}

	socket, dial_err := net.dial_tcp_from_hostname_with_port_override(data.host, data.port)
	if dial_err != nil {
		result.payload = Tcp_Connect_Result_Data{err = fmt.aprintf("%v", dial_err, allocator = heap)}
	} else {
		result.payload = Tcp_Connect_Result_Data{socket = socket}
	}
	chan.send(data.completions, result)
}

// Строит Socket_Value из TCP-соединения, установленного воркером
// (tcp_connect_task_proc выше) — вынесено из deliver_async_result (vm.odin)
// в этот файл, т.к. требует core:net/bufio.reader_init над
// tcp_to_stream (vm_io_native.odin) — vm.odin намеренно не импортирует
// core:net (компилируется на обеих платформах).
deliver_tcp_connect_result :: proc(vm: ^VM, target: ^Process_Value, payload: Tcp_Connect_Result_Data) {
	heap := vm_heap_allocator()
	if err, has_err := payload.err.(string); has_err {
		defer delete(err, heap)
		if target == nil || !target.is_alive do return
		value := make_error_result(vm, make_error_value(vm, "сеть", err))
		append(&target.async_results, value)
		return
	}

	if target == nil || !target.is_alive {
		net.close(payload.socket)
		return
	}

	conn := gc_new(vm, Socket_Value)
	conn.socket = payload.socket
	conn.is_open = true
	context.allocator = heap
	bufio.reader_init(&conn.reader, tcp_to_stream(&conn.socket))
	value := make_ok_result(vm, Value(conn))
	append(&target.async_results, value)
}

// Владение: все поля здесь — обычные Odin-аллокации (context.allocator),
// НИКОГДА не GC-managed. http_task_proc освобождает их сам после того, как
// они больше не нужны (запрос отправлен) — задача пересекает границу
// потоков РОВНО один раз (submit_async_io -> воркер), обратно идёт только
// Async_Result по каналу.
Http_Task_Data :: struct {
	completions:     chan.Chan(Async_Result),
	target_id:       int,
	ticket_id:       int,
	method_str:      string,
	url:             string,
	body_str:        string,
	request_headers: [dynamic][2]string,
}

http_task_proc :: proc(task: thread.Task) {
	// task.allocator == vm_heap_allocator() (см. submit_async_io) —
	// pool_do_work уже установил context.allocator = task.allocator для
	// длительности этого вызова, но явный vm_heap_allocator()+mem.free
	// здесь ОБЯЗАТЕЛЬНЫ, не просто defense-in-depth: голый builtin `free`
	// (без явного аллокатора) вообще не принимает второй аргумент в этой
	// версии Odin (compile error "Too many arguments"), а полагаться на
	// ambient context.allocator для free() живо ловило SIGABRT ("pointer
	// being freed was not allocated") — mem.free(ptr, allocator) из
	// core:mem это единственный проверенный рабочий способ передать
	// аллокатор явно.
	heap := vm_heap_allocator()
	data := cast(^Http_Task_Data)task.data
	defer {
		delete(data.method_str, heap)
		delete(data.url, heap)
		delete(data.body_str, heap)
		for kv in data.request_headers {
			delete(kv[0], heap)
			delete(kv[1], heap)
		}
		delete(data.request_headers)
		mem.free(data, heap)
	}

	result := Async_Result {
		ticket_id = data.ticket_id,
		target_id = data.target_id,
	}

	method, method_ok := http_method_from_string(data.method_str)
	if !method_ok {
		result.payload = Http_Result_Data {
			err = fmt.aprintf("неизвестный HTTP-метод: %s", data.method_str, allocator = heap),
		}
		chan.send(data.completions, result)
		return
	}

	req: client.Request
	client.request_init(&req, method)
	defer client.request_destroy(&req)

	for kv in data.request_headers {
		http.headers_set(&req.headers, kv[0], kv[1])
	}
	if len(data.body_str) > 0 {
		bytes.buffer_write(&req.body, transmute([]u8)data.body_str)
	}

	res, req_err := client.request(&req, data.url)
	if req_err != nil {
		result.payload = Http_Result_Data{err = fmt.aprintf("%v", req_err, allocator = heap)}
		chan.send(data.completions, result)
		return
	}
	defer client.response_destroy(&res)

	body_result, was_alloc, body_err := client.response_body(&res)
	body_text := ""
	if body_err == nil {
		if plain, is_plain := body_result.(client.Body_Plain); is_plain {
			// Клонируем ДО body_destroy ниже — response_body владеет этой
			// памятью, а Async_Result должен пережить текущую функцию
			// (читается позже, на главном потоке, в deliver_async_result).
			body_text = strings.clone(string(plain), heap)
		}
		client.body_destroy(body_result, was_alloc)
	}

	headers_out: [dynamic][2]string
	headers_out.allocator = heap
	for k, v in res.headers._kv {
		append(&headers_out, [2]string{strings.clone(k, heap), strings.clone(v, heap)})
	}

	result.payload = Http_Result_Data {
		status  = int(res.status),
		headers = headers_out,
		body    = body_text,
	}
	chan.send(data.completions, result)
}

// Фаза 4/5 (стриминговый I/O над уже открытым хендлом): submit-сторона для
// File_Value.прочитать/прочитать_строку/записать и Socket_Value.получить/
// получить_строку/отправить — ЕДИНСТВЕННОЕ место, где воркеру передаётся
// сырой указатель на GC-managed объект (а не копия простых данных, как во
// всех остальных submit_* выше): чтение — через reader IN PLACE, чтобы
// курсор сохранялся между последовательными вызовами (см.
// test_file_handle_read_line_then_read_rest, e2e_runtime_gc_test.odin);
// запись — через сам handle/socket. Безопасно ТОЛЬКО благодаря паре gc_pin
// (gc.odin — объект гарантированно ROOT весь полёт, GC не может его
// закрыть/переиспользовать) + in_flight (ОДИН флаг на любую операцию —
// read ИЛИ write, — блокирует ВТОРУЮ конкурентную попытку и откладывает
// .закрыть(), см. invoke_io_method's "закрыть"-ветки). Быстрые отказы
// ("уже закрыт"/"уже выполняется") и is_stdin (см. ниже) обрабатываются
// СИНХРОННО здесь же — Value кладётся в async_results напрямую, никакого
// похода в воркер-пул.
submit_async_io_method :: proc(vm: ^VM, receiver: Value, method_name: string, args: []Value, target_id: int) {
	target := vm.processes[vm.current_process] // submit всегда от имени текущего процесса

	if file, ok_file := receiver.(^File_Value); ok_file {
		is_write := method_name == "записать"

		if is_write && file.is_stdin {
			// Та же проверка, что была в invoke_io_method's "записать"
			// синхронно — стдин никогда не открыт для записи.
			append(&target.async_results, make_error_result(vm, make_error_value(vm, "фс", "файл не открыт для записи")))
			return
		}
		if !file.is_open || file.close_requested {
			append(&target.async_results, make_error_result(vm, make_error_value(vm, "фс", "файл уже закрыт")))
			return
		}
		if file.in_flight {
			append(&target.async_results, make_error_result(vm, make_error_value(vm, "фс", "операция ввода-вывода уже выполняется")))
			return
		}
		if !is_write && file.is_stdin {
			// vm.stdin_reader — общий VM-владеемый (НЕ per-object) ресурс
			// (get_stdin_reader/file_reader выше) — небезопасно передавать
			// воркеру: разные Файл-обёртки над стдин (несколько вызовов
			// ввод_вывод.поток()) делили бы ОДИН реальный reader, а
			// in_flight/gc_pin отслеживаются ПО ОБЪЕКТУ, не по реальному
			// общему ресурсу. Читаем синхронно прямо здесь (главный поток) —
			// тот же класс исключения, что у ввод_вывод.прочитать_строку()
			// (builtin, всегда синхронный).
			value: Value
			if method_name == "прочитать_строку" {
				value = read_line_from_reader(vm, file_reader(vm, file))
			} else {
				content := read_all_from_reader(file_reader(vm, file))
				value = make_ok_result(vm, Value(gc_new_string(vm, content)))
			}
			append(&target.async_results, value)
			return
		}

		file.in_flight = true
		gc_pin(vm, receiver)

		heap := vm_heap_allocator()
		vm.next_ticket_id += 1

		if is_write {
			text := expect_string_arg(method_name, args[0])
			task_data := new(File_Write_Stream_Task_Data, heap)
			task_data.completions = vm.async_completions
			task_data.target_id = target_id
			task_data.ticket_id = vm.next_ticket_id
			task_data.file = file
			task_data.content = strings.clone(text, heap)

			thread.pool_add_task(&vm.async_pool, heap, file_write_stream_task_proc, task_data)
			return
		}

		task_data := new(File_Stream_Task_Data, heap)
		task_data.completions = vm.async_completions
		task_data.target_id = target_id
		task_data.ticket_id = vm.next_ticket_id
		task_data.file = file
		task_data.read_line = method_name == "прочитать_строку"

		thread.pool_add_task(&vm.async_pool, heap, file_stream_task_proc, task_data)
		return
	}

	if sock, ok_sock := receiver.(^Socket_Value); ok_sock {
		is_write := method_name == "отправить"

		if !sock.is_open || sock.close_requested {
			append(&target.async_results, make_error_result(vm, make_error_value(vm, "сеть", "соединение уже закрыто")))
			return
		}
		if sock.in_flight {
			append(&target.async_results, make_error_result(vm, make_error_value(vm, "сеть", "операция ввода-вывода уже выполняется")))
			return
		}

		sock.in_flight = true
		gc_pin(vm, receiver)

		heap := vm_heap_allocator()
		vm.next_ticket_id += 1

		if is_write {
			text := expect_string_arg(method_name, args[0])
			task_data := new(Socket_Write_Stream_Task_Data, heap)
			task_data.completions = vm.async_completions
			task_data.target_id = target_id
			task_data.ticket_id = vm.next_ticket_id
			task_data.sock = sock
			task_data.content = strings.clone(text, heap)

			thread.pool_add_task(&vm.async_pool, heap, socket_write_stream_task_proc, task_data)
			return
		}

		task_data := new(Socket_Stream_Task_Data, heap)
		task_data.completions = vm.async_completions
		task_data.target_id = target_id
		task_data.ticket_id = vm.next_ticket_id
		task_data.sock = sock
		task_data.read_line = method_name == "получить_строку"

		thread.pool_add_task(&vm.async_pool, heap, socket_stream_task_proc, task_data)
		return
	}

	if listener, ok_listener := receiver.(^Http_Listener_Value); ok_listener {
		// Слушатель.принять_запрос() — единственный async-метод здесь
		// (specs/009-http-server, research.md §3). НЕ pin'ится: воркер
		// копирует только chan.Chan(rawptr) — плоское значение, не
		// трогает сам GC-объект Http_Listener_Value (в отличие от File/
		// Socket-стриминга выше, где воркер держит указатель НА объект).
		heap := vm_heap_allocator()
		vm.next_ticket_id += 1

		task_data := new(Http_Accept_Task_Data, heap)
		task_data.completions = vm.async_completions
		task_data.target_id = target_id
		task_data.ticket_id = vm.next_ticket_id
		task_data.incoming = listener.incoming

		thread.pool_add_task(&vm.async_pool, heap, http_accept_task_proc, task_data)
		return
	}
}

File_Stream_Task_Data :: struct {
	completions: chan.Chan(Async_Result),
	target_id:   int,
	ticket_id:   int,
	// Сырой указатель на GC-объект — безопасно ТОЛЬКО пока file.in_flight
	// держит его pinned (см. submit_async_io_method выше) — воркер трогает
	// ИСКЛЮЧИТЕЛЬНО &file.reader (голый bufio-тип), НИКОГДА .header/
	// Value-поля. Читаем через .reader НАПРЯМУЮ (не через file_reader(vm,
	// ...)) — is_stdin уже отфильтрован на submit'е выше, здесь всегда
	// собственный, per-object reader.
	file:        ^File_Value,
	read_line:   bool,
}

file_stream_task_proc :: proc(task: thread.Task) {
	heap := vm_heap_allocator()
	data := cast(^File_Stream_Task_Data)task.data
	defer mem.free(data, heap)

	result := Async_Result{ticket_id = data.ticket_id, target_id = data.target_id}

	content: string
	err: Maybe(string)
	if data.read_line {
		content, err = read_line_raw(&data.file.reader, heap)
	} else {
		content = strings.clone(read_all_from_reader(&data.file.reader), heap)
	}
	result.payload = File_Stream_Read_Result_Data{file = data.file, content = content, err = err}
	chan.send(data.completions, result)
}

Socket_Stream_Task_Data :: struct {
	completions: chan.Chan(Async_Result),
	target_id:   int,
	ticket_id:   int,
	// Симметрично File_Stream_Task_Data выше — Socket_Value.reader ВСЕГДА
	// per-object (в отличие от File_Value, у Socket_Value нет аналога
	// is_stdin/общего reader'а), carve-out не нужен.
	sock:        ^Socket_Value,
	read_line:   bool,
}

socket_stream_task_proc :: proc(task: thread.Task) {
	heap := vm_heap_allocator()
	data := cast(^Socket_Stream_Task_Data)task.data
	defer mem.free(data, heap)

	result := Async_Result{ticket_id = data.ticket_id, target_id = data.target_id}

	content: string
	err: Maybe(string)
	if data.read_line {
		content, err = read_line_raw(&data.sock.reader, heap)
	} else {
		content = strings.clone(read_all_from_reader(&data.sock.reader), heap)
	}
	result.payload = Socket_Stream_Read_Result_Data{sock = data.sock, content = content, err = err}
	chan.send(data.completions, result)
}

// Фаза 5 (стриминговая запись): симметрично File_Stream_Task_Data/
// Socket_Stream_Task_Data выше, но воркер трогает НЕ .reader, а сам
// handle/socket (os.write/net.send_tcp) — content уже склонирован на heap
// в submit_async_io_method (текст-аргумент — GC-managed Panos_String.data,
// не переживёт возврата из execute()).
File_Write_Stream_Task_Data :: struct {
	completions: chan.Chan(Async_Result),
	target_id:   int,
	ticket_id:   int,
	file:        ^File_Value,
	content:     string,
}

file_write_stream_task_proc :: proc(task: thread.Task) {
	heap := vm_heap_allocator()
	data := cast(^File_Write_Stream_Task_Data)task.data
	defer {
		delete(data.content, heap)
		mem.free(data, heap)
	}

	result := Async_Result{ticket_id = data.ticket_id, target_id = data.target_id}

	n, err := os.write(data.file.handle, transmute([]byte)data.content)
	if err != nil {
		result.payload = File_Stream_Write_Result_Data {
			file = data.file,
			err  = fmt.aprintf("%v", err, allocator = heap),
		}
	} else {
		result.payload = File_Stream_Write_Result_Data{file = data.file, bytes_written = n}
	}
	chan.send(data.completions, result)
}

Socket_Write_Stream_Task_Data :: struct {
	completions: chan.Chan(Async_Result),
	target_id:   int,
	ticket_id:   int,
	sock:        ^Socket_Value,
	content:     string,
}

socket_write_stream_task_proc :: proc(task: thread.Task) {
	heap := vm_heap_allocator()
	data := cast(^Socket_Write_Stream_Task_Data)task.data
	defer {
		delete(data.content, heap)
		mem.free(data, heap)
	}

	result := Async_Result{ticket_id = data.ticket_id, target_id = data.target_id}

	n, err := net.send_tcp(data.sock.socket, transmute([]byte)data.content)
	if err != nil {
		result.payload = Socket_Stream_Write_Result_Data {
			sock = data.sock,
			err  = fmt.aprintf("%v", err, allocator = heap),
		}
	} else {
		result.payload = Socket_Stream_Write_Result_Data{sock = data.sock, bytes_written = n}
	}
	chan.send(data.completions, result)
}
