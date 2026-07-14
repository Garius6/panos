package main

import "core:bufio"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

LSP_Reader :: struct {
	buf: bufio.Reader,
}

lsp_reader_init :: proc(r: ^LSP_Reader) {
	bufio.reader_init(&r.buf, os.to_stream(os.stdin))
}

// Читает одно сообщение по LSP-фреймингу поверх stdio:
//   Content-Length: N\r\n
//   \r\n
//   <N байт JSON>
// Content-Type — необязательный второй заголовок, игнорируем. Возвращает
// false на EOF (клиент закрыл stdin) или ошибке фрейминга — оба случая
// обрабатываются как "пора выходить" в главном цикле. Тело возвращается
// сырыми байтами — разбор в конкретный Odin-тип делает decode_params()/
// json.unmarshal на envelope (см. lsp_protocol.odin), а не эта функция.
lsp_read_message :: proc(r: ^LSP_Reader, allocator := context.allocator) -> ([]byte, bool) {
	content_length := -1
	for {
		line, err := bufio.reader_read_string(&r.buf, '\n', context.temp_allocator)
		if err != nil {
			if err != .EOF do fmt.eprintln("panos-lsp: ошибка чтения заголовка:", err)
			return nil, false
		}
		line = strings.trim_right(line, "\r\n")
		if line == "" do break // пустая строка — конец заголовков
		if strings.has_prefix(line, "Content-Length:") {
			num_str := strings.trim_space(line[len("Content-Length:"):])
			n, ok := strconv.parse_int(num_str)
			if !ok {
				fmt.eprintln("panos-lsp: не число в Content-Length:", num_str)
				return nil, false
			}
			content_length = n
		}
	}
	if content_length < 0 {
		fmt.eprintln("panos-lsp: заголовки без Content-Length")
		return nil, false
	}

	body := make([]byte, content_length, allocator)
	n_read := 0
	for n_read < content_length {
		n, err := bufio.reader_read(&r.buf, body[n_read:])
		if err != nil && n == 0 {
			if err != .EOF do fmt.eprintln("panos-lsp: ошибка чтения тела сообщения:", err)
			return nil, false
		}
		n_read += n
	}
	return body, true
}

// Пишет JSON-RPC сообщение в stdout с LSP-фреймингом, маршаля v напрямую —
// v обычно RPC_Response(T)/RPC_Notification(T)/RPC_Error_Response
// (см. lsp_protocol.odin), собранные из типизированных proto.*-структур.
// Возвращает false при ошибке marshal — вызывающая сторона (send_response)
// использует это, чтобы гарантировать клиенту хоть какой-то ответ вместо
// зависшего в ожидании запроса (см. commit message).
lsp_write_message :: proc(v: $T) -> bool {
	data, err := json.marshal(v, {})
	if err != nil {
		fmt.eprintln("panos-lsp: не смог замаршалить сообщение:", err, "(тип:", typeid_of(T), ")")
		return false
	}
	defer delete(data)
	fmt.printf("Content-Length: %d\r\n\r\n", len(data))
	os.write(os.stdout, data)
	return true
}
