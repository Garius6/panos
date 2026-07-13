#+build js
package core

import "core:fmt"

// WASM-спайк v1: файловый `импорт` не поддержан (браузер не имеет ФС) —
// всегда "не найдено", тот же контракт, что и у native-варианта для
// отсутствующего файла (см. module_loader_native.odin).
read_file_text :: proc(path: string) -> (data: string, err_msg: string, ok: bool) {
	return "", fmt.tprintf("файловый импорт недоступен в браузере ('%s')", path), false
}
