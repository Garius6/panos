#+build !js
package core

import "core:testing"

@(test)
test_modules :: proc(t: ^testing.T) {
	result, ok := run_module_file("fixtures/module_fixture_main.ps")
	testing.expectf(t, ok, "Модули: стек пуст, нет результата")
	if !ok do return

	testing.expectf(
		t,
		result == f64(42.0),
		"Модули: ожидалось 42, получено %v",
		result,
	)

	stdlib_result, stdlib_ok := run_module_file("fixtures/stdlib_fixture_main.ps")
	testing.expectf(
		t,
		stdlib_ok,
		"Файловая stdlib: стек пуст, нет результата",
	)
	if !stdlib_ok do return

	testing.expectf(
		t,
		stdlib_result == f64(42.0),
		"Файловая stdlib: ожидалось 42, получено %v",
		stdlib_result,
	)
}

// Импорт по пути с '/' во вложенный каталог (не только соседний файл) —
// resolve_import_path/normalize_path это уже поддерживали, но regression-
// покрытия не было. См. также std/кодирование/toml.ps.
@(test)
test_nested_module_import :: proc(t: ^testing.T) {
	result, ok := run_module_file("fixtures/module_fixture_nested_main.ps")
	testing.expectf(t, ok, "Вложенный модуль: стек пуст, нет результата")
	if !ok do return

	testing.expectf(
		t,
		result == f64(42.0),
		"Вложенный модуль: ожидалось 42, получено %v",
		result,
	)
}

// Чистая логика std/сеть/http.ps (разбор URL) без реального сокета —
// сеть на CI/в тестовом окружении может быть недоступна или дать таймаут,
// а разобрать_адрес не требует соединения вообще (только строки.срез/
// строки.в_число). Реальный HTTP GET/POST проверен вручную (см.
// TASKS.md §Стадия 15) — Python HTTP-сервер на loopback.
@(test)
test_http_url_parsing :: proc(t: ^testing.T) {
	result, ok := run_module_file("fixtures/http_url_fixture_main.ps")
	testing.expectf(t, ok, "http url parsing: стек пуст, нет результата")
	if !ok do return

	testing.expectf(t, result == Value(true), "http url parsing: ожидалось true, получено %v", result)
}

// Чистая логика роутера (сопоставить_путь/скомпилировать_путь) — тоже без
// сокета, Маршрутизатор.обработать() требует реальный Запрос (нативный
// opaque-тип, конструируется только через реальный accept-loop) — та
// часть покрыта отдельным сокет-тестом ниже (test_http_router_dispatch).
@(test)
test_http_router_path_matching :: proc(t: ^testing.T) {
	result, ok := run_module_file("fixtures/http_router_fixture_main.ps")
	testing.expectf(t, ok, "http router path matching: стек пуст, нет результата")
	if !ok do return

	testing.expectf(t, result == Value(true), "http router path matching: ожидалось true, получено %v", result)
}

// std/математика.ps — файловый std-модуль, а не builtin: run_code (inline-
// исходник, module.dir == "") никогда не грузит реальные .ps-зависимости
// через load_module_recursive, только builtin-модули (см. resolver.odin:
// register_top_level_decl — imported_module ищется в ctx.module_graph.
// modules, куда inline-путь ничего не кладёт). run_module_file — тот же
// путь, что CLI/LSP (load_module_graph), поэтому std/ реально резолвится.
@(test)
test_math_stdlib :: proc(t: ^testing.T) {
	result, ok := run_module_file("fixtures/math_fixture_main.ps")
	testing.expectf(t, ok, "математика: стек пуст, нет результата")
	if !ok do return

	testing.expectf(t, result == Value(true), "математика: ожидалось true, получено %v", result)
}

// std/слог.ps — тот же файловый std-модуль, что math_fixture_main.ps выше:
// импорт без builtin-регистрации, резолвится только через load_module_graph
// (run_module_file), не run_code.
@(test)
test_слог_stdlib :: proc(t: ^testing.T) {
	result, ok := run_module_file("fixtures/слог_fixture_main.ps")
	testing.expectf(t, ok, "слог: стек пуст, нет результата")
	if !ok do return

	testing.expectf(t, result == Value(true), "слог: ожидалось true, получено %v", result)
}

// Логгер (фильтрация по уровню/тег/структурные поля/несколько приёмников)
// — проверяется через файловый приёмник + фс.прочитать обратно, не через
// перехват stdout (тот же принцип, что остальные fixture-тесты этого
// файла: сравниваем возвращённое panos-значение, не побочный вывод).
@(test)
test_логгер_stdlib :: proc(t: ^testing.T) {
	result, ok := run_module_file("fixtures/логгер_fixture_main.ps")
	testing.expectf(t, ok, "логгер: стек пуст, нет результата")
	if !ok do return

	testing.expectf(t, result == Value(true), "логгер: ожидалось true, получено %v", result)
}

@(test)
test_collections_stdlib :: proc(t: ^testing.T) {
	result, ok := run_module_file("fixtures/collections_fixture_main.ps")
	testing.expectf(t, ok, "коллекции: стек пуст, нет результата")
	if !ok do return

	testing.expectf(t, result == Value(true), "коллекции: ожидалось true, получено %v", result)
}

@(test)
test_json_stdlib :: proc(t: ^testing.T) {
	result, ok := run_module_file("fixtures/json_fixture_main.ps")
	testing.expectf(t, ok, "json: стек пуст, нет результата")
	if !ok do return

	testing.expectf(t, result == Value(true), "json: ожидалось true, получено %v", result)
}

@(test)
test_toml_stdlib :: proc(t: ^testing.T) {
	result, ok := run_module_file("fixtures/toml_fixture_main.ps")
	testing.expectf(t, ok, "toml: стек пуст, нет результата")
	if !ok do return

	testing.expectf(t, result == Value(true), "toml: ожидалось true, получено %v", result)
}

@(test)
test_test_stdlib :: proc(t: ^testing.T) {
	result, ok := run_module_file("fixtures/test_fixture_main.ps")
	testing.expectf(t, ok, "тест: стек пуст, нет результата")
	if !ok do return

	testing.expectf(t, result == Value(f64(0.0)), "тест: ожидалось 0 (все проверки прошли), получено %v", result)
}

@(test)
test_flags_stdlib :: proc(t: ^testing.T) {
	result, ok := run_module_file("fixtures/flags_fixture_main.ps")
	testing.expectf(t, ok, "флаги: стек пуст, нет результата")
	if !ok do return

	testing.expectf(t, result == Value(true), "флаги: ожидалось true, получено %v", result)
}

// std/архив.ps — чистый panos поверх строки::байт/длина_байт/срез_байт/
// из_байтов (core builtin) — round-trip собрать→разобрать. Кросс-
// совместимость с реальным tar (bsdtar на macOS с AppleDouble/PAX-
// заголовками) и сжатие::разжать_gzip (core:compress/gzip) проверены
// вручную — здесь только логика самого panos-кода, без внешних
// тестовых бинарников в CI.
@(test)
test_archive_stdlib :: proc(t: ^testing.T) {
	result, ok := run_module_file("fixtures/archive_fixture_main.ps")
	testing.expectf(t, ok, "архив: стек пуст, нет результата")
	if !ok do return

	testing.expectf(t, result == Value(true), "архив: ожидалось true, получено %v", result)
}

// Регрессия: строки.из_числа (vm.odin, теперь format_number) звало
// fmt.tprintf("%v", f64) — Go/Odin default float formatting переключается
// на scientific notation выше ~6-7 значащих цифр: из_числа(1234567.0)
// давало "1.234567e+06" вместо "1234567". Раньше обходили ЛОКАЛЬНО в
// каждом вызывающем месте (std/дата.ps и т.д., см. CLAUDE.md), не
// исправляя на источнике. Найдено при аудите техдолга 2026-07-27, теперь
// строки.из_числа сама даёт фиксированно-точечный формат для любой
// величины (strconv.generic_ftoa, fmt='f', precision=-1 — shortest
// round-trip). Отдельно проверяет, что value_to_display_string (встроку/
// печать/строка/интерполяция) тоже больше не бьётся — там был ТОТ ЖЕ
// fmt.tprintf("%v", ...) паттерн, независимо исправленный тем же
// приёмом.
@(test)
test_string_from_number_avoids_scientific_notation :: proc(t: ^testing.T) {
	result, ok := run_code(`
		импорт строки

		функ старт() -> Строка
			пер a = строки.из_числа(1234567.0)
			пер b = строки.из_числа(1000000000000.0)
			пер c = встроку(9999999)
			"\(a) \(b) \(c)"
		конец
	`)
	testing.expectf(t, ok, "[из_числа: scientific notation] стек пуст")
	if ok {
		testing.expectf(
			t,
			value_str_eq(result, "1234567 1000000000000 9999999"),
			"[из_числа: scientific notation] ожидалось '1234567 1000000000000 9999999', получено %v",
			result,
		)
	}
}

// Раньше module_loader.odin panicf'ал на "модуль не найден" — единственный
// оставшийся panicking путь пайплайна (см. TASKS.md §Стадия 10 П6). Роняло
// не только CLI (терпимо — main.odin гейтит и выходит), но и ВЕСЬ LSP-
// процесс на одном битом импорте, что обнаружилось на реальном внешнем
// проекте пользователя. Мигрировано на тот же accumulate-not-panic — граф
// просто не получает эту вершину, diagnostic копится как обычно.
@(test)
test_module_loader_missing_import_does_not_panic :: proc(t: ^testing.T) {
	graph := load_module_graph("fixtures/module_fixture_missing_import_main.ps")
	found := false
	for d in graph.parse_diagnostics {
		if d.message == "Module Loader Error: модуль 'не_существует_вообще_никогда' не найден" {
			found = true
		}
	}
	testing.expectf(
		t,
		found,
		"missing import: ожидался diagnostic про отсутствующий модуль, получено %v",
		graph.parse_diagnostics,
	)
}
