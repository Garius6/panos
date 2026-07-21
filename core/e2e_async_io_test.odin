#+build !js
package core

import "core:fmt"
import "core:net"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

// Минимальный локальный HTTP-сервер для теста ниже: слушает на случайном
// свободном порту (port=0 — ОС сама выбирает), принимает ОДНО соединение,
// намеренно ждёт (искусственная задержка — имитирует медленный внешний
// сервис), затем отвечает минимальным валидным HTTP/1.1-ответом. Работает
// на СВОЁМ потоке (core:thread) — не связан с воркер-пулом VM никак, чисто
// тестовая инфраструктура.
run_slow_test_http_server :: proc(listener: net.TCP_Socket) {
	client_sock, _, accept_err := net.accept_tcp(listener)
	if accept_err != nil do return
	defer net.close(client_sock)

	// Осушаем то, что клиент уже успел отправить (запрос) — best-effort,
	// не парсим, просто не оставляем сокет непрочитанным перед ответом.
	buf: [4096]byte
	net.recv_tcp(client_sock, buf[:])

	time.sleep(150 * time.Millisecond)

	response := "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"
	net.send_tcp(client_sock, transmute([]byte)response)
}

// Ключевой тест плана "Неблокирующий I/O для actor model panos": процесс
// #0 (старт()) спавнит дочерний процесс (печатает и сразу завершается),
// затем делает МЕДЛЕННЫЙ сеть.http_запрос(...) (искусственная 150мс
// задержка сервера выше). До этой фичи HTTP-вызов внутри execute()
// блокировал ВЕСЬ планировщик — дочерний процесс физически не мог
// получить свой прогон, пока http_запрос не вернётся, и "child:RAN"
// оказался бы в выводе ТОЛЬКО ПОСЛЕ "http:DONE". С .Call_Builtin_Async/
// .Await_Async submit не блокирует — execute() процесса #0 возвращает
// управление планировщику сразу после отправки задачи в воркер-пул,
// планировщик успевает прогнать дочерний процесс ДО того, как HTTP-ответ
// придёт — "child:RAN" должен оказаться МЕЖДУ "http:START" и "http:DONE".
@(test)
test_async_http_does_not_block_other_processes :: proc(t: ^testing.T) {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	testing.expectf(t, listen_err == nil, "[async http] не удалось запустить тестовый listener: %v", listen_err)
	if listen_err != nil do return
	defer net.close(listener)

	bound, bound_err := net.bound_endpoint(listener)
	testing.expectf(t, bound_err == nil, "[async http] не удалось узнать порт listener'а: %v", bound_err)
	if bound_err != nil do return

	server_thread := thread.create_and_start_with_poly_data(listener, run_slow_test_http_server)
	defer thread.destroy(server_thread)

	url := fmt.tprintf("http://127.0.0.1:%d/", bound.port)

	source := fmt.tprintf(`
		импорт ввод_вывод
		импорт сеть

		функ ребёнок() -> Пусто
			ввод_вывод.печать("child:RAN")
		конец

		функ старт() -> Целое
			запусти ребёнок()
			ввод_вывод.печать("http:START")
			пер р = сеть.http_запрос("GET", "%s", "", соответствие())
			ввод_вывод.печать("http:DONE")
			0
		конец
	`, url)

	result, ok, output := run_code_capture_stdout(source)
	testing.expectf(t, ok, "[async http] стек пуст")
	n, is_num := result.(f64)
	testing.expectf(t, is_num && n == 0, "[async http] ожидалось 0, получено %v", result)

	thread.join(server_thread)

	start_idx := strings.index(output, "http:START")
	child_idx := strings.index(output, "child:RAN")
	done_idx := strings.index(output, "http:DONE")
	testing.expectf(t, start_idx >= 0 && child_idx >= 0 && done_idx >= 0, "[async http] не все три строки найдены в выводе: %q", output)
	testing.expectf(
		t,
		start_idx < child_idx && child_idx < done_idx,
		"[async http] ожидался порядок START < child:RAN < DONE (дочерний процесс должен успеть выполниться, пока планировщик ждёт HTTP-ответ) — получено: %q",
		output,
	)
}

// Фаза 3: фс::прочитать через новый асинхронный путь (Call_Builtin_Async/
// Await_Async, submit_async_io) должен давать ТОТ ЖЕ Результат.Неудача, что
// раньше давал call_builtin_io синхронно, для несуществующего файла —
// доказывает, что File_Read_Result_Data.err корректно долетает через канал
// и deliver_async_result строит правильный Ошибка(...).
@(test)
test_async_file_read_missing_file_is_error :: proc(t: ^testing.T) {
	result, ok := run_code(`
		импорт фс

		функ старт() -> Булево
			пер р = фс.прочитать("/tmp/panos_e2e_async_missing_zzz.txt")
			р.ошибка()
		конец
	`)
	testing.expectf(t, ok, "[async фс.прочитать] пустой стек")
	if !ok do return
	testing.expectf(t, result == Value(true), "[async фс.прочитать] ожидался Ошибка(...) для несуществующего файла, получено %v", result)
}

// Фаза 3: сеть::подключиться через асинхронный путь — единственный новый
// payload-вариант (Tcp_Connect_Result_Data) с платформозависимым полем
// (net.TCP_Socket пересекает канал воркер->главный поток) — проверяет, что
// сокет, установленный НА ВОРКЕРЕ, реально пригоден для .отправить()/
// .получить_строку() на главном потоке после deliver_tcp_connect_result
// (bufio.reader_init/tcp_to_stream, vm_async_io_native.odin).
@(test)
test_async_tcp_connect_then_send_recv :: proc(t: ^testing.T) {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	testing.expectf(t, listen_err == nil, "[async tcp] не удалось запустить тестовый listener: %v", listen_err)
	if listen_err != nil do return
	defer net.close(listener)

	bound, bound_err := net.bound_endpoint(listener)
	testing.expectf(t, bound_err == nil, "[async tcp] не удалось узнать порт listener'а: %v", bound_err)
	if bound_err != nil do return

	server_thread := thread.create_and_start_with_poly_data(listener, run_slow_test_http_server)
	defer thread.destroy(server_thread)

	source := fmt.tprintf(`
		импорт сеть

		функ старт() -> Строка
			пер соединение = сеть.подключиться("127.0.0.1", %d).ожидать("не удалось подключиться")
			соединение.отправить("GET / HTTP/1.1\r\n\r\n")
			соединение.получить_строку().ожидать("нет строки")
		конец
	`, bound.port)

	result, ok := run_code(source)
	thread.join(server_thread)

	testing.expectf(t, ok, "[async tcp] пустой стек")
	if !ok do return
	testing.expectf(
		t,
		value_str_eq(result, "HTTP/1.1 200 OK"),
		"[async tcp] ожидалась первая строка ответа сервера, получено %v",
		result,
	)
}

// Фаза 4: ключевой тест для СТРИМИНГОВОГО чтения — тот же принцип, что
// test_async_http_does_not_block_other_processes, но для .получить_строку()
// на УЖЕ открытом Соединении (а не для одноразового сеть.подключиться из
// Фазы 3). До этой фичи .получить_строку() шёл через invoke_io_method
// синхронно, блокируя ВЕСЬ планировщик на все 150мс серверной задержки.
@(test)
test_async_stream_read_does_not_block_other_processes :: proc(t: ^testing.T) {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	testing.expectf(t, listen_err == nil, "[async stream read] не удалось запустить тестовый listener: %v", listen_err)
	if listen_err != nil do return
	defer net.close(listener)

	bound, bound_err := net.bound_endpoint(listener)
	testing.expectf(t, bound_err == nil, "[async stream read] не удалось узнать порт listener'а: %v", bound_err)
	if bound_err != nil do return

	server_thread := thread.create_and_start_with_poly_data(listener, run_slow_test_http_server)
	defer thread.destroy(server_thread)

	source := fmt.tprintf(`
		импорт ввод_вывод
		импорт сеть

		функ ребёнок() -> Пусто
			ввод_вывод.печать("child:RAN")
		конец

		функ старт() -> Строка
			пер соединение = сеть.подключиться("127.0.0.1", %d).ожидать("не удалось подключиться")
			соединение.отправить("GET / HTTP/1.1\r\n\r\n")
			запусти ребёнок()
			ввод_вывод.печать("read:START")
			пер строка = соединение.получить_строку().ожидать("нет строки")
			ввод_вывод.печать("read:DONE")
			строка
		конец
	`, bound.port)

	result, ok, output := run_code_capture_stdout(source)
	thread.join(server_thread)

	testing.expectf(t, ok, "[async stream read] пустой стек")
	if !ok do return
	testing.expectf(
		t,
		value_str_eq(result, "HTTP/1.1 200 OK"),
		"[async stream read] ожидалась первая строка ответа, получено %v",
		result,
	)

	start_idx := strings.index(output, "read:START")
	child_idx := strings.index(output, "child:RAN")
	done_idx := strings.index(output, "read:DONE")
	testing.expectf(t, start_idx >= 0 && child_idx >= 0 && done_idx >= 0, "[async stream read] не все три строки найдены в выводе: %q", output)
	testing.expectf(
		t,
		start_idx < child_idx && child_idx < done_idx,
		"[async stream read] ожидался порядок START < child:RAN < DONE (дочерний процесс должен успеть выполниться, пока планировщик ждёт ответ сервера) — получено: %q",
		output,
	)
}

// Фаза 4/5: два процесса делят один Socket_Value (передан аргументом при
// запусти — та же ссылка, не копия) и оба пытаются читать одновременно —
// submit_async_io_method выставляет in_flight СИНХРОННО (до того, как
// планировщик вообще может переключиться на другой процесс), так что
// второй читатель детерминированно получает "операция ввода-вывода уже
// выполняется" (общий флаг на чтение И запись, см. submit_async_io_
// method, vm_async_io_native.odin), а не гонку на общем bufio.Reader.
@(test)
test_async_stream_concurrent_read_is_busy_error :: proc(t: ^testing.T) {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	testing.expectf(t, listen_err == nil, "[async stream busy] не удалось запустить тестовый listener: %v", listen_err)
	if listen_err != nil do return
	defer net.close(listener)

	bound, bound_err := net.bound_endpoint(listener)
	testing.expectf(t, bound_err == nil, "[async stream busy] не удалось узнать порт listener'а: %v", bound_err)
	if bound_err != nil do return

	server_thread := thread.create_and_start_with_poly_data(listener, run_slow_test_http_server)
	defer thread.destroy(server_thread)

	source := fmt.tprintf(`
		импорт ввод_вывод
		импорт сеть

		функ второй_читатель(соединение: Соединение) -> Пусто
			пер р = соединение.получить_строку()
			если р.ошибка() тогда
				ввод_вывод.печать("second:" + р.причина().сообщение)
			иначе
				ввод_вывод.печать("second:NO_ERROR")
			конец
		конец

		функ старт() -> Строка
			пер соединение = сеть.подключиться("127.0.0.1", %d).ожидать("не удалось подключиться")
			соединение.отправить("GET / HTTP/1.1\r\n\r\n")
			запусти второй_читатель(соединение)
			соединение.получить_строку().ожидать("нет строки")
		конец
	`, bound.port)

	result, ok, output := run_code_capture_stdout(source)
	thread.join(server_thread)

	testing.expectf(t, ok, "[async stream busy] пустой стек")
	if !ok do return
	testing.expectf(
		t,
		value_str_eq(result, "HTTP/1.1 200 OK"),
		"[async stream busy] первый читатель должен получить настоящий ответ, получено %v",
		result,
	)
	testing.expectf(
		t,
		strings.contains(output, "second:операция ввода-вывода уже выполняется"),
		"[async stream busy] второй читатель должен получить ошибку 'операция ввода-вывода уже выполняется', вывод: %q",
		output,
	)
}

// Фаза 4: .закрыть() вызван, пока другой держатель того же Socket_Value
// ещё читает (in_flight) — закрытие должно вернуться немедленно без
// ошибки (close_requested — реальный close_socket_value откладывается),
// а уже идущее чтение всё равно обязано доставить результат тому, кто его
// начал (submit случился ДО close_requested).
@(test)
test_async_stream_close_while_in_flight_defers_real_close :: proc(t: ^testing.T) {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	testing.expectf(t, listen_err == nil, "[async stream close] не удалось запустить тестовый listener: %v", listen_err)
	if listen_err != nil do return
	defer net.close(listener)

	bound, bound_err := net.bound_endpoint(listener)
	testing.expectf(t, bound_err == nil, "[async stream close] не удалось узнать порт listener'а: %v", bound_err)
	if bound_err != nil do return

	server_thread := thread.create_and_start_with_poly_data(listener, run_slow_test_http_server)
	defer thread.destroy(server_thread)

	source := fmt.tprintf(`
		импорт ввод_вывод
		импорт сеть

		функ закрывающий(соединение: Соединение) -> Пусто
			соединение.закрыть()
			ввод_вывод.печать("closed:NO_ERROR")
		конец

		функ старт() -> Строка
			пер соединение = сеть.подключиться("127.0.0.1", %d).ожидать("не удалось подключиться")
			соединение.отправить("GET / HTTP/1.1\r\n\r\n")
			запусти закрывающий(соединение)
			соединение.получить_строку().ожидать("нет строки")
		конец
	`, bound.port)

	result, ok, output := run_code_capture_stdout(source)
	thread.join(server_thread)

	testing.expectf(t, ok, "[async stream close] пустой стек")
	if !ok do return
	testing.expectf(
		t,
		value_str_eq(result, "HTTP/1.1 200 OK"),
		"[async stream close] чтение, начатое ДО закрытия, должно доставить результат, получено %v",
		result,
	)
	testing.expectf(
		t,
		strings.contains(output, "closed:NO_ERROR"),
		"[async stream close] .закрыть() пока in_flight должен вернуться немедленно без ошибки, вывод: %q",
		output,
	)
}

// Фаза 5: in_flight — ОДИН общий флаг на чтение И запись (не отдельные
// read_in_flight/write_in_flight) — доказывает, что ПОПЫТКА ЗАПИСИ
// (.отправить()) на Socket_Value, где уже идёт чтение (.получить_строку(),
// запущенное другим держателем той же ссылки), тоже получает "операция
// ввода-вывода уже выполняется", а не тихо шлёт байты поверх/во время
// чужого read (что могло бы повредить состояние bufio.Reader/сокета).
@(test)
test_async_stream_write_blocked_by_concurrent_read_is_busy_error :: proc(t: ^testing.T) {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	testing.expectf(t, listen_err == nil, "[async stream write busy] не удалось запустить тестовый listener: %v", listen_err)
	if listen_err != nil do return
	defer net.close(listener)

	bound, bound_err := net.bound_endpoint(listener)
	testing.expectf(t, bound_err == nil, "[async stream write busy] не удалось узнать порт listener'а: %v", bound_err)
	if bound_err != nil do return

	server_thread := thread.create_and_start_with_poly_data(listener, run_slow_test_http_server)
	defer thread.destroy(server_thread)

	source := fmt.tprintf(`
		импорт ввод_вывод
		импорт сеть

		функ писатель(соединение: Соединение) -> Пусто
			пер р = соединение.отправить("лишний запрос")
			если р.ошибка() тогда
				ввод_вывод.печать("writer:" + р.причина().сообщение)
			иначе
				ввод_вывод.печать("writer:NO_ERROR")
			конец
		конец

		функ старт() -> Строка
			пер соединение = сеть.подключиться("127.0.0.1", %d).ожидать("не удалось подключиться")
			соединение.отправить("GET / HTTP/1.1\r\n\r\n")
			запусти писатель(соединение)
			соединение.получить_строку().ожидать("нет строки")
		конец
	`, bound.port)

	result, ok, output := run_code_capture_stdout(source)
	thread.join(server_thread)

	testing.expectf(t, ok, "[async stream write busy] пустой стек")
	if !ok do return
	testing.expectf(
		t,
		value_str_eq(result, "HTTP/1.1 200 OK"),
		"[async stream write busy] читатель должен получить настоящий ответ, получено %v",
		result,
	)
	testing.expectf(
		t,
		strings.contains(output, "writer:операция ввода-вывода уже выполняется"),
		"[async stream write busy] писатель должен получить ошибку 'операция ввода-вывода уже выполняется', вывод: %q",
		output,
	)
}

