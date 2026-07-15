#+feature dynamic-literals
#+build js
package core

// В браузере нет ФС — реальный std/ (native-CLI читает его с диска,
// см. resolver_import_native.odin/module_loader_native.odin) недоступен.
// Вшиваем содержимое std/*.ps в бинарь через #load — ключи карты СОВПАДАЮТ
// с тем, что resolve_import_path(spec, "std") реально возвращает для
// bare-импорта (напр. `импорт "коллекции"` -> "std/коллекции.ps"), так что
// resolve_existing_import_path/read_file_text (см. resolver_import_wasm.odin/
// module_loader_wasm.odin) могут обращаться к ней напрямую по резолвленному
// пути, без отдельного маппинга имён.
wasm_std_files := map[string]string {
	"std/тест.ps"               = #load("../std/тест.ps", string),
	"std/флаги.ps"               = #load("../std/флаги.ps", string),
	"std/математика.ps"          = #load("../std/математика.ps", string),
	"std/коллекции.ps"           = #load("../std/коллекции.ps", string),
	"std/сеть/http.ps"           = #load("../std/сеть/http.ps", string),
	"std/кодирование/json.ps"    = #load("../std/кодирование/json.ps", string),
	"std/кодирование/toml.ps"    = #load("../std/кодирование/toml.ps", string),
}
