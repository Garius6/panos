#+build js
package core

// Браузер не имеет ФС: файловый `импорт` всегда "не найдено".
resolve_existing_import_path :: proc(import_spec: string, importer_dir: string) -> (string, bool) {
	return resolve_import_path(import_spec, importer_dir), false
}
