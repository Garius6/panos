#+build !js
package core

import "core:testing"

// Собирает VM после полного прогона source, не выполняя его дальше — нужен
// доступ к vm.gc для force_gc/gc_stats, которого run_code() не даёт
// (возвращает только Value результата).
compile_and_run_for_gc :: proc(source: string) -> ^VM {
	tokens, lex_diags := tokenize(source)
	panic_on_diagnostics(lex_diags)
	stream := make_stream(tokens)
	parser := Parser {
		stream = &stream,
	}
	prog := parse_program(&parser)
	panic_on_diagnostics(parser.diagnostics)

	res_ctx := new_resolver_ctx()
	resolve_program(&res_ctx, prog)
	panic_on_diagnostics(res_ctx.diagnostics)

	type_ctx := new_type_ctx(&res_ctx)
	typecheck_program(&type_ctx, prog)
	panic_on_diagnostics(type_ctx.diagnostics)

	registry := make(map[string]^Compiled_Function)
	ensure_prelude_compiled(&res_ctx, &registry)
	compile_program(&res_ctx, &type_ctx, &prog, &registry)
	vm := new_vm(registry)
	run_scheduler(vm)
	return vm
}

// Стадия 1 checkpoint: "программа с миллионом allocation'ов в цикле —
// память не растёт". `пер мусор` внутри тела цикла компилируется в ОДИН
// stack-слот (Set_Local с фиксированным индексом — тело цикла компилируется
// статически один раз, а не по разу на итерацию), так что каждая итерация
// перезаписывает слот предыдущей — предыдущий Array_Value становится
// недостижим сразу же. 100k * ~5 живых-на-момент объектов гарантированно
// пересекает GC_MIN_THRESHOLD не один раз.
@(test)
test_gc_reclaims_garbage_in_loop :: proc(t: ^testing.T) {
	vm := compile_and_run_for_gc(`
		функ старт() -> Число
			пер сч = 0
			пока сч < 100000 цикл
				пер мусор = массив(1, 2, 3, 4, 5)
				сч = сч + 1
			конец
			возврат сч
		конец
	`)

	force_gc(vm)
	stats := gc_stats(vm)
	testing.expectf(
		t,
		stats.collections_run > 0,
		"GC stress: ожидался хотя бы 1 запуск коллектора за 100000 итераций, получено 0",
	)
	testing.expectf(
		t,
		stats.live_objects < 10,
		"GC stress: ожидалось <10 живых объектов после force_gc (мусор из цикла давно недостижим), получено %d",
		stats.live_objects,
	)
}

// Обратная сторона предыдущего теста: GC не должен освобождать то, что
// ДЕЙСТВИТЕЛЬНО достижимо, пока рядом с ним крутится цикл, генерирующий
// мусор — иначе "программа не растёт по памяти" ценой "программа теряет
// живые данные".
@(test)
test_gc_keeps_reachable_data_alive :: proc(t: ^testing.T) {
	vm := compile_and_run_for_gc(`
		функ старт() -> Массив(Число)
			пер живой = массив(1, 2, 3)
			пер сч = 0
			пока сч < 50000 цикл
				пер мусор = массив(9, 9, 9)
				сч = сч + 1
			конец
			возврат живой
		конец
	`)

	force_gc(vm)
	testing.expectf(t, len(vm.stack) > 0, "GC keep-alive: пустой стек")
	if len(vm.stack) == 0 do return

	result := vm.stack[len(vm.stack) - 1]
	arr, ok := result.(^Array_Value)
	testing.expectf(t, ok, "GC keep-alive: результат не массив: %v", result)
	if !ok do return

	testing.expectf(
		t,
		len(arr.elements) == 3 && arr.elements[0] == Value(f64(1)) && arr.elements[2] == Value(f64(3)),
		"GC keep-alive: ожидался [1,2,3] нетронутым после force_gc, получено %v",
		arr.elements,
	)
}

// Объектный API фс: фс.открыть -> Файл-дескриптор с методами .записать/
// .прочитать/.прочитать_строку/.закрыть (см. File_Value в compiler.odin,
// FILE_METHODS в type_cheker.odin).
@(test)
test_file_handle_write_then_read_back :: proc(t: ^testing.T) {
	result, ok := run_code(`
		импорт фс

		функ старт() -> Строка
			пер путь = "/tmp/panos_file_handle_write.txt"
			пер ф = фс.открыть(путь).ожидать("не удалось открыть")
			ф.записать("привет из дескриптора")
			ф.закрыть()
			фс.прочитать(путь).ожидать("не удалось прочитать")
		конец
	`)
	testing.expectf(t, ok, "file handle write: пустой стек")
	if !ok do return
	testing.expectf(
		t,
		value_str_eq(result, "привет из дескриптора"),
		"file handle write: ожидалось 'привет из дескриптора', получено %v",
		result,
	)
}

// .прочитать_строку() и .прочитать() должны делить один и тот же курсор
// чтения (общий bufio.Reader) — вторая строка должна прочитаться СО
// СЛЕДУЮЩЕЙ позиции, а не сначала файла.
@(test)
test_file_handle_read_line_then_read_rest :: proc(t: ^testing.T) {
	result, ok := run_code(`
		импорт фс

		функ старт() -> Строка
			пер путь = "/tmp/panos_file_handle_read.txt"
			фс.записать(путь, "первая\nвторая")
			пер ф = фс.открыть(путь).ожидать("не удалось открыть")
			пер строка1 = ф.прочитать_строку().ожидать("нет строки")
			пер остаток = ф.прочитать().ожидать("нет остатка")
			ф.закрыть()
			строка1 + "|" + остаток
		конец
	`)
	testing.expectf(t, ok, "file handle read: пустой стек")
	if !ok do return
	testing.expectf(
		t,
		value_str_eq(result, "первая|вторая"),
		"file handle read: ожидалось 'первая|вторая', получено %v",
		result,
	)
}

@(test)
test_file_handle_open_missing_dir_is_error :: proc(t: ^testing.T) {
	result, ok := run_code(`
		импорт фс

		функ старт() -> Булево
			пер р = фс.открыть("/tmp/panos_e2e_missing_dir_zzz/file.txt")
			р.ошибка()
		конец
	`)
	testing.expectf(t, ok, "file handle open error: пустой стек")
	if !ok do return
	testing.expectf(t, result == Value(true), "file handle open error: ожидалась ошибка открытия, получено %v", result)
}

// Порт на 127.0.0.1 без слушателя — соединение отклоняется ядром сразу же
// (localhost, не реальная сеть), без риска зависнуть на таймауте.
@(test)
test_socket_connect_refused_is_error :: proc(t: ^testing.T) {
	result, ok := run_code(`
		импорт сеть

		функ старт() -> Булево
			пер р = сеть.подключиться("127.0.0.1", 47)
			р.ошибка()
		конец
	`)
	testing.expectf(t, ok, "socket connect refused: пустой стек")
	if !ok do return
	testing.expectf(t, result == Value(true), "socket connect refused: ожидалась ошибка подключения, получено %v", result)
}

// ввод_вывод.поток() переиспользует File_Value для стдин — здесь только
// структурная проверка (конструктор + .закрыть() как no-op), реального
// чтения не делаем: os.stdin в тестовом процессе не подключён к пайпу и
// блокирующее чтение повесило бы весь test suite.
@(test)
test_stdin_stream_handle_smoke :: proc(t: ^testing.T) {
	result, ok := run_code(`
		импорт ввод_вывод

		функ старт() -> Число
			пер поток = ввод_вывод.поток()
			поток.закрыть()
			42
		конец
	`)
	testing.expectf(t, ok, "stdin stream smoke: пустой стек")
	if !ok do return
	testing.expectf(t, result == Value(f64(42)), "stdin stream smoke: ожидалось 42, получено %v", result)
}

// Стадия 46: время.монотонно_мс() — тики с момента старта VM, растут
// между двумя последовательными вызовами в одном процессе (никогда не
// убывают, даже если оба вызова происходят в одной "тактовой" ячейке
// исполнения — используем >=, а не строгое >, чтобы не флаковать на
// системах с грубой гранулярностью часов).
@(test)
test_time_monotonic_ms_increases :: proc(t: ^testing.T) {
	result, ok := run_code(`
		импорт время

		функ старт() -> Число
			пер a = время.монотонно_мс()
			пер b = время.монотонно_мс()
			b - a
		конец
	`)
	testing.expectf(t, ok, "время.монотонно_мс: пустой стек")
	f, is_num := result.(f64)
	testing.expectf(t, is_num && f >= 0.0, "время.монотонно_мс: разница отрицательна: %v", result)
}

// Стадия 46: время.сейчас_мс() — unix-время в миллисекундах, wall-clock.
// Проверяем правдоподобность (не 0, не отрицательное, в разумных
// пределах современных дат — заведомо больше 2020-01-01, заведомо
// меньше 2100-01-01) вместо точного значения (зависит от момента
// прогона теста).
@(test)
test_time_now_ms_returns_plausible_unix_time :: proc(t: ^testing.T) {
	result, ok := run_code(`
		импорт время

		функ старт() -> Число
			время.сейчас_мс()
		конец
	`)
	testing.expectf(t, ok, "время.сейчас_мс: пустой стек")
	f, is_num := result.(f64)
	// 2020-01-01 = 1577836800000 мс, 2100-01-01 = 4102444800000 мс.
	testing.expectf(
		t,
		is_num && f > 1577836800000.0 && f < 4102444800000.0,
		"время.сейчас_мс: неправдоподобное значение: %v",
		result,
	)
}
