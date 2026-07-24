#+build !js
package core

import "core:fmt"
import "core:net"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

// Подключается к 127.0.0.1:port с повтором (сервер panos стартует на
// СВОЁМ потоке асинхронно относительно вызова run_code — нет способа
// синхронно узнать "уже слушает", повтор с коротким интервалом надёжнее
// фиксированного sleep).
dial_with_retry :: proc(port: int, attempts := 50) -> (sock: net.TCP_Socket, ok: bool) {
	for _ in 0 ..< attempts {
		s, err := net.dial_tcp_from_hostname_with_port_override("127.0.0.1", port)
		if err == nil {
			return s, true
		}
		time.sleep(10 * time.Millisecond)
	}
	return {}, false
}

// Шлёт МИНИМАЛЬНЫЙ валидный HTTP/1.1-запрос (Content-Length корректен,
// Connection: close — не держим keep-alive, тест читает ровно один ответ
// и закрывает сокет сам) и читает ответ целиком до закрытия соединения
// сервером.
send_http_request :: proc(port: int, method: string, path: string, body: string) -> (response: string, ok: bool) {
	sock, dial_ok := dial_with_retry(port)
	if !dial_ok do return "", false
	defer net.close(sock)

	req := fmt.tprintf(
		"%s %s HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
		method,
		path,
		len(body),
		body,
	)
	_, send_err := net.send_tcp(sock, transmute([]byte)req)
	if send_err != nil do return "", false

	buf: [8192]byte
	total := strings.builder_make()
	for {
		n, recv_err := net.recv_tcp(sock, buf[:])
		if n <= 0 || recv_err != nil do break
		strings.write_bytes(&total, buf[:n])
	}
	return strings.to_string(total), true
}

// Подключается и СРАЗУ обрывает соединение ПОСЛЕ отправки полного запроса
// (не читая ответ) — имитирует клиента, отвалившегося до получения ответа
// (spec.md Edge Case).
send_and_abandon :: proc(port: int, path: string) -> bool {
	sock, dial_ok := dial_with_retry(port)
	if !dial_ok do return false
	req := fmt.tprintf("GET %s HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", path)
	_, send_err := net.send_tcp(sock, transmute([]byte)req)
	net.close(sock) // обрыв сразу — ответ никогда не читаем
	return send_err == nil
}

// Acceptance Scenario 1: реальный внешний клиент (raw TCP, не curl —
// избегаем внешней зависимости в тесте) получает от panos-кода ИМЕННО
// тот ответ, который тот послал через Запрос.ответить(...).
@(test)
test_http_server_basic_request_response :: proc(t: ^testing.T) {
	port := 18180

	source := fmt.tprintf(`
		импорт сеть

		функ старт() -> Строка
			пер слушатель = сеть.http_сервер_слушать(%d).ожидать("не смог слушать")
			пер запрос = слушатель.принять_запрос().ожидать("не смог принять запрос")
			пер путь = запрос.путь()
			запрос.ответить(200, "text/plain", "ответ:" + путь)
			путь
		конец
	`, port)

	client_result: string
	client_ok: bool
	client_thread := thread.create_and_start_with_poly_data3(
		port,
		"/test-path",
		&client_result,
		proc(port: int, path: string, out: ^string) {
			resp, ok := send_http_request(port, "GET", path, "")
			if ok do out^ = resp
		},
	)

	result, ok := run_code(source)
	thread.join(client_thread)
	thread.destroy(client_thread)

	testing.expectf(t, ok, "[http server] пустой стек")
	testing.expectf(t, value_str_eq(result, "/test-path"), "[http server] ожидался путь запроса, получено %v", result)
	testing.expectf(t, strings.contains(client_result, "HTTP/1.1 200"), "[http server] ожидался код 200, получено: %q", client_result)
	testing.expectf(
		t,
		strings.contains(client_result, "ответ:/test-path"),
		"[http server] ожидалось тело ответа с путём, получено: %q",
		client_result,
	)
}

// Acceptance Scenario 2: тело запроса (POST) доступно panos-коду целиком,
// без потокового чтения.
@(test)
test_http_server_request_body :: proc(t: ^testing.T) {
	port := 18181

	source := fmt.tprintf(`
		импорт сеть

		функ старт() -> Строка
			пер слушатель = сеть.http_сервер_слушать(%d).ожидать("не смог слушать")
			пер запрос = слушатель.принять_запрос().ожидать("не смог принять запрос")
			пер тело = запрос.тело()
			запрос.ответить(200, "text/plain", "эхо:" + тело)
			тело
		конец
	`, port)

	client_result: string
	client_thread := thread.create_and_start_with_poly_data3(
		port,
		"тестовое тело",
		&client_result,
		proc(port: int, body: string, out: ^string) {
			resp, ok := send_http_request(port, "POST", "/", body)
			if ok do out^ = resp
		},
	)

	result, ok := run_code(source)
	thread.join(client_thread)
	thread.destroy(client_thread)

	testing.expectf(t, ok, "[http server body] пустой стек")
	testing.expectf(t, value_str_eq(result, "тестовое тело"), "[http server body] panos должен был увидеть тело запроса, получено %v", result)
	testing.expectf(
		t,
		strings.contains(client_result, "эхо:тестовое тело"),
		"[http server body] клиент должен был получить эхо тела, получено: %q",
		client_result,
	)
}

// Edge Case: клиент обрывает соединение ДО того, как panos успел
// ответить — сервер НЕ падает (нет паники), и следующий, независимый
// запрос на ТОМ ЖЕ слушателе всё ещё обрабатывается корректно.
@(test)
test_http_server_client_disconnect_before_respond :: proc(t: ^testing.T) {
	port := 18182

	source := fmt.tprintf(`
		импорт сеть

		функ старт() -> Строка
			пер слушатель = сеть.http_сервер_слушать(%d).ожидать("не смог слушать")

			пер запрос1 = слушатель.принять_запрос().ожидать("не смог принять первый запрос")
			пер рез1 = запрос1.ответить(200, "text/plain", "первый")
			// клиент первого запроса уже отвалился — ответить() не должен
			// паниковать независимо от того, Успех или Неудача он вернул.

			пер запрос2 = слушатель.принять_запрос().ожидать("не смог принять второй запрос")
			запрос2.ответить(200, "text/plain", "второй-ok")
			"выжил"
		конец
	`, port)

	abandon_thread := thread.create_and_start_with_poly_data2(port, "/abandoned", proc(port: int, path: string) {
		send_and_abandon(port, path)
	})

	second_result: string
	second_thread := thread.create_and_start_with_poly_data2(port, &second_result, proc(port: int, out: ^string) {
		// Небольшая задержка, чтобы первый (обрывающийся) запрос гарантированно
		// был принят и обработан раньше второго.
		time.sleep(100 * time.Millisecond)
		resp, ok := send_http_request(port, "GET", "/second", "")
		if ok do out^ = resp
	})

	result, ok := run_code(source)
	thread.join(abandon_thread)
	thread.join(second_thread)
	thread.destroy(abandon_thread)
	thread.destroy(second_thread)

	testing.expectf(t, ok, "[http server disconnect] пустой стек (сервер не должен был упасть)")
	testing.expectf(t, value_str_eq(result, "выжил"), "[http server disconnect] сервер должен был обработать второй запрос после обрыва первого, получено %v", result)
	testing.expectf(
		t,
		strings.contains(second_result, "второй-ok"),
		"[http server disconnect] второй клиент должен был получить корректный ответ, получено: %q",
		second_result,
	)
}

// data-model.md: повторный Запрос.ответить(...) на уже отвеченном запросе
// — Результат.Неудача, не паника (нечего доставлять второй раз).
@(test)
test_http_server_double_respond_is_error :: proc(t: ^testing.T) {
	port := 18183

	source := fmt.tprintf(`
		импорт сеть

		функ старт() -> Булево
			пер слушатель = сеть.http_сервер_слушать(%d).ожидать("не смог слушать")
			пер запрос = слушатель.принять_запрос().ожидать("не смог принять запрос")
			пер рез1 = запрос.ответить(200, "text/plain", "первый")
			пер рез2 = запрос.ответить(200, "text/plain", "второй")
			(не рез1.ошибка()) и рез2.ошибка()
		конец
	`, port)

	client_thread := thread.create_and_start_with_poly_data(port, proc(port: int) {
		send_http_request(port, "GET", "/", "")
	})

	result, ok := run_code(source)
	thread.join(client_thread)
	thread.destroy(client_thread)

	testing.expectf(t, ok, "[http server double respond] пустой стек")
	testing.expectf(
		t,
		result == Value(true),
		"[http server double respond] первый ответить() должен быть Успех, второй — Неудача, получено %v",
		result,
	)
}

// Acceptance Scenario 3/FR-005: несколько panos-процессов на ОДНОМ
// слушателе — оба реальных одновременных клиента получают правильные,
// РАЗЛИЧНЫЕ ответы (доказывает распределение запросов между процессами,
// не только "работает для одного").
@(test)
test_http_server_concurrent_processes :: proc(t: ^testing.T) {
	port := 18184

	source := fmt.tprintf(`
		импорт сеть

		тип Уведомление = перечисление
			Готово
		конец

		функ обработчик(слушатель: Слушатель, родитель: Процесс(Уведомление)) -> Пусто
			пер запрос = слушатель.принять_запрос().ожидать("не смог принять запрос")
			запрос.ответить(200, "text/plain", "обработано:" + запрос.путь())
			отправить(родитель, Уведомление.Готово)
		конец

		функ старт() -> Булево
			пер слушатель = сеть.http_сервер_слушать(%d).ожидать("не смог слушать")
			запусти обработчик(слушатель, себя())
			запусти обработчик(слушатель, себя())
			пер первый = выбор получить()
				Уведомление.Готово -> истина
			конец
			пер второй = выбор получить()
				Уведомление.Готово -> истина
			конец
			первый и второй
		конец
	`, port)

	result_a, result_b: string
	client_a := thread.create_and_start_with_poly_data3(port, "/a", &result_a, proc(port: int, path: string, out: ^string) {
		resp, ok := send_http_request(port, "GET", path, "")
		if ok do out^ = resp
	})
	client_b := thread.create_and_start_with_poly_data3(port, "/b", &result_b, proc(port: int, path: string, out: ^string) {
		resp, ok := send_http_request(port, "GET", path, "")
		if ok do out^ = resp
	})

	_, ok := run_code(source)
	thread.join(client_a)
	thread.join(client_b)
	thread.destroy(client_a)
	thread.destroy(client_b)

	testing.expectf(t, ok, "[http server concurrent] пустой стек")
	testing.expectf(
		t,
		strings.contains(result_a, "обработано:/a") && strings.contains(result_b, "обработано:/b"),
		"[http server concurrent] оба клиента должны получить свои собственные ответы, получено a=%q b=%q",
		result_a,
		result_b,
	)
}

// Edge Case: порт уже занят другим слушателем — Результат.Неудача, не паника.
@(test)
test_http_server_port_already_in_use :: proc(t: ^testing.T) {
	port := 18185

	source := fmt.tprintf(`
		импорт сеть

		функ старт() -> Булево
			пер первый = сеть.http_сервер_слушать(%d)
			пер второй = сеть.http_сервер_слушать(%d)
			(не первый.ошибка()) и второй.ошибка()
		конец
	`, port, port)

	result, ok := run_code(source)
	testing.expectf(t, ok, "[http server port in use] пустой стек")
	testing.expectf(
		t,
		result == Value(true),
		"[http server port in use] первый listen должен быть Успех, второй на том же порту — Неудача, получено %v",
		result,
	)
}
