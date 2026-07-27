#+build !js
package core

import "base:runtime"
import "core:fmt"
import "core:strings"

// Соединение с SQLite-базой (бд.открыть). in_flight/close_requested — тот
// же приём неблокирующего стримингового I/O, что у File_Value/Socket_Value
// (file_value_native.odin): выполнить()/запрос() пинят объект через
// gc_pin на время работы воркер-потока (submit_async_io_method,
// vm_async_io_native.odin), закрыть() во время in_flight откладывает
// реальный sqlite3_close_v2 до завершения воркера (deliver_async_result,
// vm.odin) — иначе гонка с воркером на том же ^sqlite3.
Sql_Connection_Value :: struct {
	header:          GC_Header,
	db:              ^sqlite3,
	path:            string,
	is_open:         bool,
	in_flight:       bool,
	close_requested: bool,
}

// Единая точка закрытия — явный .закрыть() из Panos-кода И GC-финализатор
// в pool_release (gc.odin), когда хендл стал недостижим, но не закрыт
// явно. is_open — гейт идемпотентности, симметрично close_file_value.
close_sql_connection :: proc(conn: ^Sql_Connection_Value) {
	if !conn.is_open do return
	sqlite3_close_v2(conn.db)
	conn.db = nil
	conn.is_open = false
}

// sqlite3_errmsg возвращает указатель на буфер САМОГО соединения,
// невалидный после следующего вызова sqlite3-функции на том же db или
// после close — копируем строку СРАЗУ (context.allocator в точке вызова:
// это либо основной VM-поток при бд.открыть, либо воркер с явно
// подставленным vm_heap_allocator() при выполнить/запрос, см.
// vm_async_io_native.odin — оба безопасны для gc_new_string/strings.clone
// ниже по стеку).
sql_error_message :: proc(db: ^sqlite3) -> string {
	return string(sqlite3_errmsg(db))
}

// бд::открыть — вынесено из общего call_builtin (vm.odin) в #+build-split,
// тот же принцип, что vm_io_native.odin/vm_http_server_native.odin.
// Синхронный (не в is_async_builtin_name, compiler.odin) — открытие файла
// БД такой же быстрый локальный syscall, как фс.открыть, не сетевой
// round-trip вроде сеть.подключиться.
call_builtin_sql :: proc(vm: ^VM, name: string, args: []Value) -> (result: Value, ok: bool, handled: bool) {
	switch name {
	case "бд::открыть":
		expect_arg_count(name, len(args), 1)
		path := expect_string_arg(name, args[0])

		context.allocator = vm_heap_allocator()
		path_cstr := strings.clone_to_cstring(path)
		defer delete(path_cstr)

		db: ^sqlite3
		rc := sqlite3_open_v2(path_cstr, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
		if rc != SQLITE_OK {
			msg := sql_error_message(db)
			err := make_error_value(vm, "бд", msg)
			sqlite3_close_v2(db) // sqlite3_open_v2 может частично выделить db даже при ошибке
			return make_error_result(vm, err), true, true
		}

		conn := gc_new(vm, Sql_Connection_Value)
		conn.db = db
		conn.is_open = true
		conn.path = strings.clone(path)
		return make_ok_result(vm, Value(conn)), true, true
	}
	return
}

// Соединение_БД.закрыть() — единственный синхронный метод (выполнить/
// запрос идут через submit_async_io_method, vm_async_io_native.odin).
invoke_sql_connection_method :: proc(
	vm: ^VM,
	receiver: Value,
	method_name: string,
	args: []Value,
) -> (
	result: Value,
	ok: bool,
	handled: bool,
) {
	conn, is_conn := receiver.(^Sql_Connection_Value)
	if !is_conn do return

	handled = true
	switch method_name {
	case "закрыть":
		expect_arg_count(method_name, len(args), 0)
		// Симметрично File_Value.закрыть() (vm_io_native.odin) — если
		// воркер сейчас физически держит conn.db, реальный close
		// откладывается до его завершения.
		if conn.in_flight {
			conn.close_requested = true
			return Value(f64(0)), false, true
		}
		close_sql_connection(conn)
		return Value(f64(0)), false, true
	}
	handled = false
	return
}

// Биндит параметры (позиционно, ?-плейсхолдеры, 1-based индексы SQLite) —
// используется и call_builtin_sql (нет, только async-путь: выполнить/
// запрос) и sql_exec_task_proc/sql_query_task_proc (vm_async_io_native.
// odin). Аллокатор ДОЛЖЕН быть уже переключён вызывающим на
// vm_heap_allocator() при вызове с воркер-потока (см. предупреждение в
// vm_async_io_native.odin) — здесь используется context.temp_allocator
// НЕ применяется намеренно, только явный clone_to_cstring на текущем
// context.allocator + defer delete.
sql_bind_params :: proc(stmt: ^sqlite3_stmt, params: []string) -> (ok: bool, rc: i32) {
	for p, i in params {
		idx := i32(i + 1)
		cstr := strings.clone_to_cstring(p)
		defer delete(cstr)
		bind_rc := sqlite3_bind_text(stmt, idx, cstr, -1, SQLITE_TRANSIENT)
		if bind_rc != SQLITE_OK do return false, bind_rc
	}
	return true, SQLITE_OK
}

// Читает ИМЕНА колонок текущего prepared statement (после успешного
// sqlite3_prepare_v2, до первого sqlite3_step — имена не меняются между
// шагами одного и того же statement).
sql_column_names :: proc(stmt: ^sqlite3_stmt) -> [dynamic]string {
	count := sqlite3_column_count(stmt)
	names := make([dynamic]string, 0, count)
	for i in 0 ..< count {
		append(&names, strings.clone(string(sqlite3_column_name(stmt, i))))
	}
	return names
}

// Читает ОДНУ строку результата (после sqlite3_step вернул SQLITE_ROW) в
// плоский []Maybe(string) — nil означает NULL-колонку (пропускается при
// сборке итоговой Соответствие(Строка, Строка) в deliver_async_result,
// vm.odin — единый способ представить NULL без отдельного типа). BLOB-
// колонка — не читается вообще, вызывающий обязан проверить
// sqlite3_column_type на BLOB ДО вызова этой функции и вернуть ошибку
// (см. sql_query_task_proc) — молчаливая text-коэрсия бинарных байт была
// бы потерей данных, а не удобством.
sql_read_row :: proc(stmt: ^sqlite3_stmt) -> [dynamic]Maybe(string) {
	count := sqlite3_column_count(stmt)
	row := make([dynamic]Maybe(string), 0, count)
	for i in 0 ..< count {
		if sqlite3_column_type(stmt, i) == SQLITE_NULL {
			append(&row, Maybe(string)(nil))
			continue
		}
		n := sqlite3_column_bytes(stmt, i)
		text: string
		if n > 0 {
			text_ptr := sqlite3_column_text(stmt, i)
			text = strings.clone(strings.string_from_ptr((^byte)(text_ptr), int(n)))
		}
		append(&row, Maybe(string)(text))
	}
	return row
}
