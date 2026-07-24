#+build !js
package core

import http "../external/odin-http"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:strings"
import "core:sync/chan"
import "core:thread"

// specs/009-http-server — мост между вендоренным external/odin-http/
// server.odin (свой event loop + пул потоков) и однопоточным panos-VM.
// Три ограничения библиотеки (research.md §1), определяющие всё ниже:
//   1. http.serve/listen_and_serve БЛОКИРУЮТ вызывающий поток НАВСЕГДА —
//      выделенный thread.create_and_start на слушатель, НЕ vm.async_pool
//      (тот исчерпался бы навсегда заблокированными воркерами).
//   2. http.respond() привязан к вызывающему потоку (thread-local assert
//      внутри библиотеки) — Handler ДОЛЖЕН синхронно дождаться ответа на
//      КАНАЛЕ, самостоятельно вызвать respond() и только потом вернуться.
//   3. Тело запроса читается через СОБСТВЕННЫЙ callback odin-http
//      (http.body), не синхронно — вся мостовая логика (канал+блокировка)
//      живёт ВНУТРИ этого callback'а, не в самом Handler_Proc.

// Bridge_Request/Bridge_Response — ПЛОСКИЕ Odin-данные, пересекающие
// границу odin-http-поток -> vm.async_pool-воркер -> главный поток VM.
// Ни одно поле здесь не Value/GC-managed — тот же принцип, что везде в
// неблокирующем I/O (vm_async.odin).
Bridge_Request :: struct {
	method:        string,
	path:          string,
	header_keys:   []string,
	header_values: []string,
	body:          string,
	// cap=1 — ровно один ответ, отправитель (Запрос.ответить) и
	// получатель (odin-http-поток внутри http_on_body_read) по одному
	// с каждой стороны.
	response_chan: chan.Chan(Bridge_Response),
}

Bridge_Response :: struct {
	status:       int,
	content_type: string,
	body:         string,
}

// Полезная нагрузка Async_Result для "запрос принят" (принять_запрос()).
// req == nil при ошибке (текст — в err).
Http_Accept_Result_Data :: struct {
	req: ^Bridge_Request,
	err: Maybe(string),
}

// Разделяемый контекст Handler'а odin-http — ЕДИНСТВЕННОЕ, что нужно
// воркер-потокам odin-http из "внешнего мира": канал, куда класть
// полностью прочитанные запросы. НЕ указатель на Http_Listener_Value
// (GC-managed) — воркеры odin-http вообще не должны знать о GC panos.
Http_Handler_Context :: struct {
	incoming: chan.Chan(rawptr), // rawptr -> ^Bridge_Request (vm_heap_allocator)
}

// Живёт на время ОДНОГО HTTP-запроса — от Handler_Proc до конца
// http_on_body_read (после respond()). Аллоцируется/освобождается на
// context.allocator odin-http-потока (см. run_http_listener_thread —
// явно переставлен на vm_heap_allocator ДО serve(), поэтому и все
// внутренние потоки odin-http, порождённые ВНУТРИ serve(), naследуют
// тот же безопасный аллокатор через стандартный Odin context — не
// разделяемая однопоточная арена main.odin).
Http_Request_Bridge_Ctx :: struct {
	handler_ctx: ^Http_Handler_Context,
	req:         ^http.Request,
	res:         ^http.Response,
}

Http_Listener_Value :: struct {
	header:        GC_Header,
	srv:           ^http.Server,
	handler_ctx:   ^Http_Handler_Context,
	incoming:      chan.Chan(rawptr),
	listen_thread: ^thread.Thread,
	is_open:       bool,
}

Http_Request_Value :: struct {
	header:        GC_Header,
	method:        string,
	path:          string,
	header_keys:   []string,
	header_values: []string,
	body:          string,
	response_chan: chan.Chan(Bridge_Response),
	responded:     bool,
}

// Handler odin-http — вызывается НА ЕГО ПОТОКЕ (не главном потоке VM).
// Только РЕГИСТРИРУЕТ чтение тела (research.md §1.3) — вся мостовая
// логика внутри http_on_body_read, вызываемого odin-http'ем ПОСЛЕ того,
// как тело реально получено (по-прежнему тем же потоком).
http_handler_proc :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	heap := vm_heap_allocator()
	handler_ctx := (^Http_Handler_Context)(h.user_data)
	bridge_ctx := new(Http_Request_Bridge_Ctx, heap)
	bridge_ctx.handler_ctx = handler_ctx
	bridge_ctx.req = req
	bridge_ctx.res = res
	http.body(req, -1, rawptr(bridge_ctx), http_on_body_read)
}

// Явный vm_heap_allocator() ВЕЗДЕ ниже (не ambient context.allocator) —
// та же дисциплина, что и у воркеров vm.async_pool (см. комментарий в
// deliver_async_result, vm.odin): нельзя полагаться, что context.allocator
// на этом (чужом, порождённом odin-http/nbio, не vm.async_pool) потоке —
// именно vm_heap_allocator(), даже если run_http_listener_thread его
// явно выставил перед serve() — обнаружено эмпирически (malloc: pointer
// being freed was not allocated) при первом прогоне e2e-тестов.
http_on_body_read :: proc(user_data: rawptr, body: http.Body, err: http.Body_Error) {
	heap := vm_heap_allocator()
	bridge_ctx := (^Http_Request_Bridge_Ctx)(user_data)
	defer mem.free(bridge_ctx, heap)

	if err != nil {
		http.response_status(bridge_ctx.res, .Bad_Request)
		http.respond(bridge_ctx.res)
		return
	}

	method_str := "GET"
	path_str := "/"
	if rline, has_line := bridge_ctx.req.line.(http.Requestline); has_line {
		method_str = http.method_string(rline.method)
	}
	path_str = bridge_ctx.req.url.path

	header_keys := make([dynamic]string, heap)
	header_values := make([dynamic]string, heap)
	for k, v in bridge_ctx.req.headers._kv {
		append(&header_keys, strings.clone(k, heap))
		append(&header_values, strings.clone(v, heap))
	}

	response_chan, chan_err := chan.create(chan.Chan(Bridge_Response), 1, heap)
	if chan_err != nil {
		http.response_status(bridge_ctx.res, .Internal_Server_Error)
		http.respond(bridge_ctx.res)
		return
	}

	bridge_req := new(Bridge_Request, heap)
	bridge_req.method = strings.clone(method_str, heap)
	bridge_req.path = strings.clone(path_str, heap)
	bridge_req.header_keys = header_keys[:]
	bridge_req.header_values = header_values[:]
	bridge_req.body = strings.clone(string(body), heap)
	bridge_req.response_chan = response_chan

	// Backpressure (research.md §4): если canal полон (потребитель-panos
	// не успевает), send блокирует ИМЕННО этот odin-http-поток, не весь
	// сервер — тот же принцип, что chan.send(vm.async_completions, ...).
	send_ok := chan.send(bridge_ctx.handler_ctx.incoming, rawptr(bridge_req))
	if !send_ok {
		// Канал закрыт — слушатель закрывается/закрыт.
		http.response_status(bridge_ctx.res, .Service_Unavailable)
		http.respond(bridge_ctx.res)
		return
	}

	// Синхронно ждём ответ panos-кода — ИМЕННО здесь, внутри callback'а
	// odin-http (research.md §1.2/§1.3), другого безопасного места нет.
	resp, recv_ok := chan.recv(response_chan)
	if !recv_ok {
		http.response_status(bridge_ctx.res, .Internal_Server_Error)
		http.respond(bridge_ctx.res)
		return
	}

	if resp.content_type != "" {
		http.headers_set_content_type(&bridge_ctx.res.headers, resp.content_type)
	}
	http.body_set(bridge_ctx.res, resp.body)
	http.response_status(bridge_ctx.res, http.Status(resp.status))
	http.respond(bridge_ctx.res)
}

// http.listen() вызывает nbio.acquire_thread_event_loop() — event loop
// ПРИВЯЗАН к ОС-потоку, вызвавшему listen(), а http.serve() (server_date_
// start -> nbio.timeout_poly) читает ИМЕННО этот thread-local event loop
// (иначе EXC_BAD_ACCESS: nil event loop — обнаружено эмпирически через
// lldb-бэктрейс при первом прогоне e2e-тестов). Поэтому listen() и serve()
// ДОЛЖНЫ выполняться на ОДНОМ И ТОМ ЖЕ потоке — нельзя вызвать listen()
// синхронно на главном потоке VM, а serve() на выделенном (как было
// изначально задумано). Вместо этого: и listen(), и serve() — на
// выделенном потоке; результат listen() (успех/ошибка занятого порта)
// возвращается синхронному builtin'у через Http_Listen_Result-канал
// (cap=1) — тот же плоский-канал-мост, что Bridge_Request/Bridge_Response.
Http_Listen_Result :: struct {
	err: Maybe(string),
}

Http_Listen_Thread_Data :: struct {
	srv:         ^http.Server,
	handler:     http.Handler,
	endpoint:    net.Endpoint,
	result_chan: chan.Chan(Http_Listen_Result),
}

// Выделенный поток на ВЕСЬ срок жизни слушателя (research.md §1.1) —
// context.allocator ЯВНО переставлен на vm_heap_allocator ДО listen()/
// serve(): odin-http порождает СВОИ собственные под-потоки (Server_Opts.
// thread_count) через thread.create_and_start_with_poly_data2(...,
// context) — они наследуют ИМЕННО тот context, что был активен здесь, в
// момент вызова serve(). Без этой перестановки они бы унаследовали
// однопоточную mem.Dynamic_Arena главного потока (main.odin) — реальная
// гонка данных между несколькими потоками на одном аллокаторе (тот же
// урок, что уже задокументирован для vm.async_pool-воркеров).
run_http_listener_thread :: proc(data: ^Http_Listen_Thread_Data) {
	context.allocator = vm_heap_allocator()
	heap := vm_heap_allocator()

	srv := data.srv
	handler := data.handler
	endpoint := data.endpoint
	result_chan := data.result_chan
	mem.free(data, heap)

	listen_err := http.listen(srv, endpoint)
	if listen_err != nil {
		chan.send(result_chan, Http_Listen_Result{err = fmt.tprintf("%v", listen_err)})
		return
	}
	chan.send(result_chan, Http_Listen_Result{})

	http.serve(srv, handler)
}

// Финализатор (GC-достижимость, gc.odin) — недостижимый, но не закрытый
// явно слушатель. server_shutdown НЕ блокирует (сам не ждёт потоки) —
// безопасно вызывать из finalizer-контекста sweep().
close_http_listener_value :: proc(val: ^Http_Listener_Value) {
	if !val.is_open do return
	val.is_open = false
	if val.srv != nil {
		http.server_shutdown(val.srv)
	}
}

// Финализатор для НИКОГДА не отвеченного запроса — иначе odin-http-поток,
// заблокированный в http_on_body_read на chan.recv(response_chan), ждал
// бы вечно. chan.try_send — best-effort (получателя уже может не быть,
// если TCP-соединение и так уже разорвано, см. research.md §7) —
// безопасно проигнорировать неудачу.
close_http_request_value :: proc(val: ^Http_Request_Value) {
	if val.responded do return
	val.responded = true
	_ = chan.try_send(val.response_chan, Bridge_Response{status = 500, content_type = "text/plain", body = "запрос не был обработан"})
}

// сеть::http_сервер_слушать — вынесено в #+build-split (external/odin-http
// тянет core:net, недоступен под js_wasm32), тот же принцип, что
// vm_http_native.odin (клиент)/vm_io_native.odin (сокеты).
call_builtin_http_server :: proc(vm: ^VM, name: string, args: []Value) -> (result: Value, ok: bool, handled: bool) {
	switch name {
	case "сеть::http_сервер_слушать":
		expect_arg_count(name, len(args), 1)
		port_num, ok_port := args[0].(f64)
		if !ok_port {
			fmt.panicf("Runtime Error: сеть.http_сервер_слушать() ожидает номер порта числом")
		}
		port := int(port_num)
		heap := vm_heap_allocator()

		srv := new(http.Server, heap)

		incoming_chan, chan_err := chan.create(chan.Chan(rawptr), 64, heap)
		if chan_err != nil {
			mem.free(srv, heap)
			return make_error_result(vm, make_error_value(vm, "сеть", fmt.tprintf("не удалось создать канал: %v", chan_err))), true, true
		}

		result_chan, result_chan_err := chan.create(chan.Chan(Http_Listen_Result), 1, heap)
		if result_chan_err != nil {
			chan.destroy(incoming_chan)
			mem.free(srv, heap)
			return make_error_result(vm, make_error_value(vm, "сеть", fmt.tprintf("не удалось создать канал: %v", result_chan_err))), true, true
		}

		handler_ctx := new(Http_Handler_Context, heap)
		handler_ctx.incoming = incoming_chan

		handler := http.Handler {
			user_data = handler_ctx,
			handle    = http_handler_proc,
		}

		thread_data := new(Http_Listen_Thread_Data, heap)
		thread_data.srv = srv
		thread_data.handler = handler
		thread_data.endpoint = net.Endpoint{address = net.IP4_Any, port = port}
		thread_data.result_chan = result_chan

		listen_thread := thread.create_and_start_with_poly_data(thread_data, run_http_listener_thread)

		// Синхронный, но короткий: listen() — это просто bind()/listen()
		// на сокете, не блокирующий accept-цикл (тот начинается только
		// внутри serve(), уже без ожидания здесь) — research.md §1.1.
		listen_result, recv_ok := chan.recv(result_chan)
		if !recv_ok || listen_result.err != nil {
			thread.join(listen_thread)
			thread.destroy(listen_thread)
			chan.destroy(result_chan)
			chan.destroy(incoming_chan)
			mem.free(handler_ctx, heap)
			mem.free(srv, heap)
			err_msg := "не удалось создать канал результата"
			if msg, has_msg := listen_result.err.(string); has_msg {
				err_msg = fmt.tprintf("не удалось начать слушать порт %d: %s", port, msg)
			}
			return make_error_result(vm, make_error_value(vm, "сеть", err_msg)), true, true
		}
		chan.destroy(result_chan)

		listener := gc_new(vm, Http_Listener_Value)
		listener.srv = srv
		listener.handler_ctx = handler_ctx
		listener.incoming = incoming_chan
		listener.is_open = true
		listener.listen_thread = listen_thread

		return make_ok_result(vm, Value(listener)), true, true
	}
	return {}, false, false
}

// Синхронные методы Слушатель.закрыть()/Запрос.метод()/.путь()/
// .заголовки()/.тело()/.ответить(...) — .принять_запрос() async, см.
// submit_async_io_method ниже (research.md §3).
invoke_http_server_method :: proc(vm: ^VM, receiver: Value, method_name: string, args: []Value) -> (result: Value, ok: bool, handled: bool) {
	if listener, is_listener := receiver.(^Http_Listener_Value); is_listener {
		handled = true
		switch method_name {
		case "закрыть":
			expect_arg_count(method_name, len(args), 0)
			close_http_listener_value(listener)
			return Value(f64(0)), true, true
		}
	}

	if req, is_req := receiver.(^Http_Request_Value); is_req {
		handled = true
		switch method_name {
		case "метод":
			expect_arg_count(method_name, len(args), 0)
			return Value(gc_new_string(vm, req.method)), true, true
		case "путь":
			expect_arg_count(method_name, len(args), 0)
			return Value(gc_new_string(vm, req.path)), true, true
		case "тело":
			expect_arg_count(method_name, len(args), 0)
			return Value(gc_new_string(vm, req.body)), true, true
		case "заголовки":
			expect_arg_count(method_name, len(args), 0)
			m := gc_new(vm, Map_Value)
			gc_protect(vm, Value(m))
			resize(&m.entries, len(req.header_keys))
			for i in 0 ..< len(req.header_keys) {
				m.entries[i] = Map_Entry_Value {
					key   = Value(gc_new_string(vm, req.header_keys[i])),
					value = Value(gc_new_string(vm, req.header_values[i])),
				}
			}
			gc_unprotect(vm, 1)
			return Value(m), true, true
		case "ответить":
			expect_arg_count(method_name, len(args), 3)
			status_num, ok_status := args[0].(f64)
			if !ok_status {
				fmt.panicf("Runtime Error: Запрос.ответить() ожидает статус числом")
			}
			status := int(status_num)
			content_type := expect_string_arg(method_name, args[1])
			body := expect_string_arg(method_name, args[2])

			if req.responded {
				return make_error_result(vm, make_error_value(vm, "сеть", "на этот запрос уже был дан ответ")), true, true
			}
			req.responded = true

			send_ok := chan.try_send(req.response_chan, Bridge_Response{status = status, content_type = content_type, body = body})
			if !send_ok {
				return make_error_result(vm, make_error_value(vm, "сеть", "не удалось доставить ответ (клиент, возможно, уже отключился)")), true, true
			}
			return make_ok_result(vm, Value(f64(0))), true, true
		}
	}

	return {}, false, false
}

// Задача воркера vm.async_pool для Слушатель.принять_запрос() — трогает
// ТОЛЬКО плоское chan.Chan(rawptr) значение (см. submit_async_io_method,
// vm_async_io_native.odin), никогда сам GC-объект Http_Listener_Value —
// gc_pin не нужен (в отличие от File/Socket-стриминга).
Http_Accept_Task_Data :: struct {
	completions: chan.Chan(Async_Result),
	target_id:   int,
	ticket_id:   int,
	incoming:    chan.Chan(rawptr),
}

http_accept_task_proc :: proc(task: thread.Task) {
	heap := vm_heap_allocator()
	data := cast(^Http_Accept_Task_Data)task.data
	defer mem.free(data, heap)

	result := Async_Result{ticket_id = data.ticket_id, target_id = data.target_id}

	raw, recv_ok := chan.recv(data.incoming)
	if !recv_ok {
		// Канал закрыт — слушатель закрыт, пока запрос был в полёте.
		result.payload = Http_Accept_Result_Data{req = nil, err = "слушатель закрыт"}
	} else {
		result.payload = Http_Accept_Result_Data{req = cast(^Bridge_Request)raw, err = nil}
	}

	chan.send(data.completions, result)
}

// Строит Http_Request_Value из уже полученного Bridge_Request — вызывается
// из общего vm.odin (deliver_async_result), см. Tcp_Connect_Result_Data
// прецедент (этот файл, не vm.odin, знает про Bridge_Request/odin-http).
deliver_http_accept_result :: proc(vm: ^VM, target: ^Process_Value, payload: Http_Accept_Result_Data) {
	// Bridge_Request сам по себе (не его string/channel поля — те
	// копируются по значению ниже, backing-память переживает этот free)
	// нужен был только чтобы донести данные до этой точки.
	heap := vm_heap_allocator()
	defer if payload.req != nil do mem.free(payload.req, heap)

	if target == nil || !target.is_alive {
		// Тот же silent-drop, что и везде — но response_chan уже ждёт
		// ответа на другом конце (http_on_body_read), поэтому даём
		// fallback-ответ, чтобы не подвесить клиента навсегда.
		if payload.req != nil {
			_ = chan.try_send(payload.req.response_chan, Bridge_Response{status = 500, content_type = "text/plain", body = "процесс завершился до обработки запроса"})
		}
		return
	}

	value: Value
	if err, has_err := payload.err.(string); has_err {
		value = make_error_result(vm, make_error_value(vm, "сеть", err))
	} else {
		req := gc_new(vm, Http_Request_Value)
		req.method = payload.req.method
		req.path = payload.req.path
		req.header_keys = payload.req.header_keys
		req.header_values = payload.req.header_values
		req.body = payload.req.body
		req.response_chan = payload.req.response_chan
		req.responded = false
		value = make_ok_result(vm, Value(req))
	}
	append(&target.async_results, value)
}
