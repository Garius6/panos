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

