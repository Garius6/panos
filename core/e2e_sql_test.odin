#+build !js
package core

import "core:fmt"
import "core:os"
import "core:testing"

// bd.открыть/.выполнить/.запрос/.закрыть — end-to-end через реальный
// временный SQLite-файл (не in-memory: sqlite3_open_v2 в vm_sql_native.
// odin всегда открывает путь на диске, ":memory:" не проверялся отдельно
// — тот же прод-путь, что настоящая программа). Один temp-файл на тест,
// удаляется в defer независимо от исхода.
sql_temp_db_path :: proc(tag: string) -> string {
	return fmt.tprintf("%s/panos_e2e_sql_%s.db", os.temp_dir(context.temp_allocator), tag)
}

@(test)
test_sql_open_create_insert_query_close :: proc(t: ^testing.T) {
	path := sql_temp_db_path("basic")
	os.remove(path)
	defer os.remove(path)

	result, ok := run_code(fmt.tprintf(`
		импорт бд

		функ старт() -> Строка
			пер соед = бд.открыть("%s").ожидать("не смог открыть")
			соед.выполнить("CREATE TABLE т (id INTEGER, имя TEXT)", массив()).ожидать("create failed")
			соед.выполнить("INSERT INTO т VALUES (?, ?)", массив("1", "Алиса")).ожидать("insert failed")
			соед.выполнить("INSERT INTO т VALUES (?, ?)", массив("2", "Борис")).ожидать("insert failed")

			пер строки = соед.запрос("SELECT id, имя FROM т ORDER BY id", массив()).ожидать("query failed")
			соед.закрыть()

			если строки.длина() <> 2 тогда
				возврат "неверное число строк"
			конец
			пер первая = строки.получить(0, соответствие())
			первая.получить("имя", "?")
		конец
	`, path))
	testing.expectf(t, ok, "[бд: базовый цикл] стек пуст")
	if ok {
		testing.expectf(t, value_str_eq(result, "Алиса"), "[бд: базовый цикл] ожидалось 'Алиса', получено %v", result)
	}
}

@(test)
test_sql_query_omits_null_columns :: proc(t: ^testing.T) {
	path := sql_temp_db_path("null")
	os.remove(path)
	defer os.remove(path)

	result, ok := run_code(fmt.tprintf(`
		импорт бд

		функ старт() -> Строка
			пер соед = бд.открыть("%s").ожидать("не смог открыть")
			соед.выполнить("CREATE TABLE т (id INTEGER, имя TEXT)", массив()).ожидать("create failed")
			соед.выполнить("INSERT INTO т VALUES (?, NULL)", массив("1")).ожидать("insert failed")

			пер строки = соед.запрос("SELECT id, имя FROM т", массив()).ожидать("query failed")
			соед.закрыть()

			пер строка = строки.получить(0, соответствие())
			// NULL-колонка отсутствует в Соответствие вовсе — .есть()
			// отличает её от пустой строки без отдельного типа (см. план
			// фичи). "1"/"0" вместо Булево — вСтроку(Булево) не нужен тут.
			если строка.есть("имя") тогда
				возврат "имя присутствует, ожидалось отсутствие (NULL)"
			конец
			если не строка.есть("id") тогда
				возврат "id отсутствует, ожидалось присутствие"
			конец
			"ok"
		конец
	`, path))
	testing.expectf(t, ok, "[бд: NULL] стек пуст")
	if ok {
		testing.expectf(t, value_str_eq(result, "ok"), "[бд: NULL] ожидалось 'ok', получено %v", result)
	}
}

@(test)
test_sql_query_rejects_blob_columns :: proc(t: ^testing.T) {
	path := sql_temp_db_path("blob")
	os.remove(path)
	defer os.remove(path)

	result, ok := run_code(fmt.tprintf(`
		импорт бд

		функ старт() -> Строка
			пер соед = бд.открыть("%s").ожидать("не смог открыть")
			соед.выполнить("CREATE TABLE т (данные BLOB)", массив()).ожидать("create failed")
			соед.выполнить("INSERT INTO т VALUES (x'0102')", массив()).ожидать("insert failed")

			выбор соед.запрос("SELECT данные FROM т", массив())
				Результат.Успех(_) -> "неожиданно успех"
				Результат.Неудача(ош) -> ош.сообщение
			конец
		конец
	`, path))
	testing.expectf(t, ok, "[бд: BLOB] стек пуст")
	if ok {
		testing.expectf(
			t,
			value_str_eq(result, "BLOB-колонки не поддержаны в этой версии"),
			"[бд: BLOB] ожидалась ошибка про BLOB, получено %v",
			result,
		)
	}
}

@(test)
test_sql_exec_bad_syntax_returns_error :: proc(t: ^testing.T) {
	path := sql_temp_db_path("badsyntax")
	os.remove(path)
	defer os.remove(path)

	result, ok := run_code(fmt.tprintf(`
		импорт бд

		функ старт() -> Булево
			пер соед = бд.открыть("%s").ожидать("не смог открыть")
			пер плохой = соед.выполнить("НЕ ВАЛИДНЫЙ SQL", массив())
			соед.закрыть()
			плохой.ошибка()
		конец
	`, path))
	testing.expectf(t, ok, "[бд: плохой SQL] стек пуст")
	if ok {
		testing.expectf(t, result == Value(true), "[бд: плохой SQL] ожидалась ошибка, получено %v", result)
	}
}

// submit_async_io_method's "уже закрыто" fast-fail — тот же код-путь,
// что предотвращает гонку двух одновременных операций на одном
// соединении (in_flight), но детерминированно проверяемый: два
// перекрывающихся async-вызова с точным таймингом воркер-потока — flaky
// тест (готовность результата зависит от скорости диска), закрытое
// соединение — нет.
@(test)
test_sql_operation_on_closed_connection_returns_error :: proc(t: ^testing.T) {
	path := sql_temp_db_path("closed")
	os.remove(path)
	defer os.remove(path)

	result, ok := run_code(fmt.tprintf(`
		импорт бд

		функ старт() -> Булево
			пер соед = бд.открыть("%s").ожидать("не смог открыть")
			соед.закрыть()
			пер попытка = соед.выполнить("CREATE TABLE т (id INTEGER)", массив())
			попытка.ошибка()
		конец
	`, path))
	testing.expectf(t, ok, "[бд: закрытое соединение] стек пуст")
	if ok {
		testing.expectf(t, result == Value(true), "[бд: закрытое соединение] ожидалась ошибка, получено %v", result)
	}
}

@(test)
test_sql_open_invalid_path_returns_error :: proc(t: ^testing.T) {
	result, ok := run_code(`
		импорт бд

		функ старт() -> Булево
			пер соед = бд.открыть("/несуществующая/директория/файл.db")
			соед.ошибка()
		конец
	`)
	testing.expectf(t, ok, "[бд: неверный путь] стек пуст")
	if ok {
		testing.expectf(t, result == Value(true), "[бд: неверный путь] ожидалась ошибка, получено %v", result)
	}
}

// Sql_Connection_Value использует ТОТ ЖЕ gc_pin/in_flight механизм, что
// File_Value/Socket_Value (см. submit_async_io_method,
// vm_async_io_native.odin) — GC-безопасность во время async-операции
// уже доказана для этого механизма отдельными тестами на File_Value в
// e2e_runtime_gc_test.odin (тот же код-путь, не переоткрываем).
