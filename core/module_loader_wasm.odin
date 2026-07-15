#+build js
package core

import "core:fmt"

// Браузер не имеет реальной ФС — но std/ вшита в бинарь (wasm_stdlib.odin),
// и resolve_existing_import_path (resolver_import_wasm.odin) уже
// гарантирует, что сюда попадёт только путь, реально присутствующий в
// wasm_std_files. Всё остальное (локальные/относительные импорты
// несуществующих в браузере файлов) по-прежнему "недоступно".
read_file_text :: proc(path: string) -> (data: string, err_msg: string, ok: bool) {
	if content, found := wasm_std_files[path]; found {
		return content, "", true
	}
	return "", fmt.tprintf("файловый импорт недоступен в браузере ('%s')", path), false
}
