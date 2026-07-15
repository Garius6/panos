#+build js
package core

// Браузер не имеет реальной ФС, но std/ вшита в бинарь (см.
// wasm_stdlib.odin) — тот же фоллбэк-порядок, что и в
// resolver_import_native.odin (local -> "std"), минус "модули"/
// PANOS_STDLIB (нет смысла без реальной ФС — некуда положить файл).
resolve_existing_import_path :: proc(import_spec: string, importer_dir: string) -> (string, bool) {
	local_path := resolve_import_path(import_spec, importer_dir)
	if local_path in wasm_std_files {
		return local_path, true
	}

	stdlib_path := resolve_import_path(import_spec, "std")
	if stdlib_path in wasm_std_files {
		return stdlib_path, true
	}

	return local_path, false
}
