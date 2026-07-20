#+build !js
package core

import "core:bytes"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync/chan"
import "core:thread"
import http "../external/odin-http"
import client "../external/odin-http/client"

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
	}
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
