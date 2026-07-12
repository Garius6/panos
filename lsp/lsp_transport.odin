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
// false на EOF (клиент закрыл stdin) или ошибке фрейминга/парсинга —
// оба случая обрабатываются как "пора выходить" в главном цикле.
lsp_read_message :: proc(r: ^LSP_Reader, allocator := context.allocator) -> (json.Value, bool) {
	content_length := -1
	for {
		line, err := bufio.reader_read_string(&r.buf, '\n', context.temp_allocator)
		if err != nil do return nil, false
		line = strings.trim_right(line, "\r\n")
		if line == "" do break // пустая строка — конец заголовков
		if strings.has_prefix(line, "Content-Length:") {
			num_str := strings.trim_space(line[len("Content-Length:"):])
			n, ok := strconv.parse_int(num_str)
			if !ok do return nil, false
			content_length = n
		}
	}
	if content_length < 0 do return nil, false

	body := make([]byte, content_length, allocator)
	n_read := 0
	for n_read < content_length {
		n, err := bufio.reader_read(&r.buf, body[n_read:])
		if err != nil && n == 0 do return nil, false
		n_read += n
	}

	// parse_integers=true: по умолчанию Odin парсит все JSON-числа как
	// Float. LSP шлёт line/character/id как целые — без этого json_int()
	// (проверяет только .Integer variant) видел бы одни нули.
	value, jerr := json.parse(body, parse_integers = true, allocator = allocator)
	if jerr != nil do return nil, false
	return value, true
}

// Пишет JSON-RPC сообщение в stdout с LSP-фреймингом. v — обычно
// json.Object, собранный вручную (см. lsp_server.odin) — под LSP-протокол
// проще строить json.Value напрямую, чем описывать каждый message как
// Odin-структуру с json-тегами (слишком много вариативных полей).
lsp_write_message :: proc(v: json.Value) {
	data, err := json.marshal(v, {})
	if err != nil do return
	defer delete(data)
	fmt.printf("Content-Length: %d\r\n\r\n", len(data))
	os.write(os.stdout, data)
}
