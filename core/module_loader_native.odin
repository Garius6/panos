#+build !js
package core

import "core:fmt"
import "core:os"

// ok=false — ошибка описана в err_msg (без "Module Loader Error:" префикса,
// его добавляет вызывающий вместе с уместным span'ом — read_file_text сам
// не знает, откуда его вызвали, чтобы указать на импорт).
read_file_text :: proc(path: string) -> (data: string, err_msg: string, ok: bool) {
	if !os.exists(path) {
		return "", fmt.tprintf("файл '%s' не существует", path), false
	}

	f, err := os.open(path, {.Read})
	if err != nil {
		return "", fmt.tprintf("не удалось открыть '%s': %v", path, err), false
	}

	content, read_err := os.read_entire_file(f, context.allocator)
	if read_err != nil {
		return "", fmt.tprintf("не удалось прочесть '%s': %v", path, read_err), false
	}

	return string(content), "", true
}
