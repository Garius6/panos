#+build !js
package core

import "core:testing"

// Стадия 47 (FFI-B, первый срез): VM исполняется В ТОМ ЖЕ ОС-процессе,
// что и сам тест — getpid(), вызванный ИЗ панос-программы через
// .Call_Foreign, обязан вернуть ТОТ ЖЕ PID, что и getpid(), вызванный
// напрямую из Odin-кода теста (foreign import ниже, независимый от
// core/ffi_bindings.odin/libffi путь) — строгая проверка, а не просто
// "положительное число".
foreign import ffi_test_libc "system:c"

foreign ffi_test_libc {
	getpid :: proc() -> i32 ---
}

@(test)
test_ffi_getpid_matches_real_process_pid :: proc(t: ^testing.T) {
	result, ok := run_code(`
		внешний "libc" функ getpid() -> Целое(32)

		функ старт() -> Целое
			getpid()
		конец
	`)
	testing.expectf(t, ok, "getpid: пустой стек")
	f, is_num := result.(f64)
	expected := f64(getpid())
	testing.expectf(t, is_num && f == expected, "getpid: ожидался реальный PID %v, получено %v", expected, result)
}

// Доказывает маршаллинг АРГУМЕНТА (не только возврата) — abs() из libc,
// и отрицательный, и уже-положительный вход.
@(test)
test_ffi_abs_marshals_argument_both_signs :: proc(t: ^testing.T) {
	result, ok := run_code(`
		внешний "libc" функ abs(x: Целое(32)) -> Целое(32)

		функ старт() -> Целое
			abs(0 - 12345) + abs(777)
		конец
	`)
	testing.expectf(t, ok, "abs: пустой стек")
	f, is_num := result.(f64)
	testing.expectf(t, is_num && f == 13122.0, "abs: неверный результат: %v", result)
}

@(test)
test_ffi_unknown_library_reports_resolve_error :: proc(t: ^testing.T) {
	testing.expect_assert(t, "Resolve Error: библиотека 'libдефинитивнонесуществует123' не найдена (libдефинитивнонесуществует123.dylib)")
	run_code(`
		внешний "libдефинитивнонесуществует123" функ несуществующая() -> Целое(32)

		функ старт() -> Целое
			несуществующая()
		конец
	`)
}

@(test)
test_ffi_unknown_symbol_reports_resolve_error :: proc(t: ^testing.T) {
	testing.expect_assert(t, "Resolve Error: библиотека 'libc' не экспортирует символ 'definitely_not_a_real_libc_symbol_xyz'")
	run_code(`
		внешний "libc" функ definitely_not_a_real_libc_symbol_xyz() -> Целое(32)

		функ старт() -> Целое
			definitely_not_a_real_libc_symbol_xyz()
		конец
	`)
}

// Стадия 49 (FFI): КСтрока как ПАРАМЕТР — panos Строка маршаллится в
// null-terminated C-буфер (borrowed, на время вызова), strlen() из libc
// считает реальную длину C-строки.
@(test)
test_ffi_cstring_param_strlen :: proc(t: ^testing.T) {
	result, ok := run_code(`
		внешний "libc" функ strlen(s: КСтрока) -> Целое(64)

		функ старт() -> Целое
			strlen("hello world")
		конец
	`)
	testing.expectf(t, ok, "cstring param: пустой стек")
	f, is_num := result.(f64)
	testing.expectf(t, is_num && f == 11.0, "cstring param: ожидалось 11, получено %v", result)
}

// КСтрока как ВОЗВРАТ — libc strdup() возвращает malloc'нутый char*,
// panos копирует его в новую Panos_String (никогда не заимствует чужую
// C-память для строк, см. call_foreign, vm_ffi_native.odin) — round-trip
// через UTF-8 (кириллица) тоже должен пройти без искажений.
@(test)
test_ffi_cstring_return_strdup_round_trip :: proc(t: ^testing.T) {
	result, ok := run_code(`
		внешний "libc" функ strdup(s: КСтрока) -> КСтрока

		функ старт() -> Строка
			strdup("привет мир")
		конец
	`)
	testing.expectf(t, ok, "cstring return: пустой стек")
	s, is_str := result.(^Panos_String)
	testing.expectf(t, is_str && s.data == "привет мир", "cstring return: ожидалось 'привет мир', получено %v", result)
}

// Указатель(T) с постфиксом свой: malloc() возвращает опаковый handle,
// хранится в переменной — не должно падать ни при построении
// Pointer_Value, ни при GC-сборке (pool_release освобождает через libc
// free(), т.к. свой стоит явно). Несколько malloc подряд —
// проверяет, что пул/повторное использование объекта не портит новый
// указатель.
@(test)
test_ffi_pointer_owned_malloc_does_not_crash :: proc(t: ^testing.T) {
	result, ok := run_code(`
		внешний "libc" функ malloc(размер: Целое(64)) -> Указатель(Целое) свой

		функ старт() -> Целое
			пер a = malloc(16)
			пер b = malloc(32)
			пер c = malloc(64)
			777
		конец
	`)
	testing.expectf(t, ok, "pointer malloc: пустой стек")
	f, is_num := result.(f64)
	testing.expectf(t, is_num && f == 777.0, "pointer malloc: ожидалось 777, получено %v", result)
}

// Указатель(T) БЕЗ аннотации владения — default чужой, pool_release
// НЕ должен пытаться free() чужую память (getenv() возвращает указатель
// в область памяти окружения процесса, которую libc сама не ожидает
// освобождённой вручную) — программа обязана завершиться штатно, а не
// упасть на попытке освободить не-panos-выделенную память.
@(test)
test_ffi_pointer_default_borrowed_does_not_free :: proc(t: ^testing.T) {
	result, ok := run_code(`
		внешний "libc" функ getenv(имя: КСтрока) -> Указатель(Целое)

		функ старт() -> Целое
			пер p = getenv("PATH")
			42
		конец
	`)
	testing.expectf(t, ok, "pointer borrowed: пустой стек")
	f, is_num := result.(f64)
	testing.expectf(t, is_num && f == 42.0, "pointer borrowed: ожидалось 42, получено %v", result)
}

// Стадия 50: отправка `свой`-указателя другому процессу НЕ дублирует
// Pointer_Value (message_deep_copy не копирует его — та же категория,
// что File_Value/Socket_Value) — оба процесса делят ОДИН Odin-объект.
// Это безопасно, а не риск double-free: у panos ОДИН общий GC-хип на
// весь VM (все "процессы" — зелёные нити внутри одного vm.gc, не
// отдельные ОС-процессы с независимой памятью, см. VM.gc в vm.odin) —
// pool_release вызывается РОВНО ОДИН РАЗ, когда объект недостижим ИЗ
// ВСЕХ процессов сразу. force_gc ПОСЛЕ того, как оба процесса
// закончились (указатель больше нигде не держится), должен освободить
// его ровно один раз — реальный double-free уронил бы весь тестовый
// бинарник (heap corruption abort), не просто провалил бы assertion.
@(test)
test_ffi_pointer_owned_sent_to_process_no_double_free :: proc(t: ^testing.T) {
	vm := compile_and_run_for_gc(`
		внешний "libc" функ malloc(размер: Целое(64)) -> Указатель(Целое) свой

		тип Сообщение = перечисление
			Данные(Указатель(Целое))
		конец

		функ получатель() -> Число
			выбор получить()
				Сообщение.Данные(p) -> 0
			конец
		конец

		функ старт() -> Число
			пер p = malloc(64)
			пер proc = запусти получатель()
			отправить(proc, Сообщение.Данные(p))
			777
		конец
	`)

	force_gc(vm)
	stats := gc_stats(vm)
	testing.expectf(
		t,
		stats.freed_last_run > 0,
		"pointer send: ожидался хотя бы 1 освобождённый объект (Pointer_Value недостижим из обоих процессов), получено %d",
		stats.freed_last_run,
	)

	// Второй force_gc — если бы pool_release как-то вызвался повторно на
	// уже освобождённом объекте (double-free), это обычно проявляется
	// именно на СЛЕДУЮЩЕМ цикле аллокации/сборки (heap corruption не
	// всегда падает мгновенно) — доп. страховка, не строгая необходимость.
	force_gc(vm)
}

// Стадия 51 (FFI: Число(N) + ff_структура): raylib уже требуется этой
// сборкой (Стадия 4 — vendor:raylib, brew install raylib) — те же 3
// теста ниже используют раylib через РЕАЛЬНЫЙ внешний-путь (dynlib +
// libffi), не vendor-биндинги, доказывая struct-by-value/float-
// маршаллинг живым вызовом. `Vector2Add`/`Fade` — чистые утилитные
// функции raylib, НЕ требуют открытого окна (в отличие от отрисовки) —
// детерминированно, без визуальной проверки.
@(test)
test_ffi_float_struct_vector2add :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Vector2 = ff_структура
			x: Число(32)
			y: Число(32)
		конец

		внешний "/opt/homebrew/opt/raylib/lib/libraylib.dylib" функ Vector2Add(a: Vector2, b: Vector2) -> Vector2

		функ старт() -> Число
			пер r = Vector2Add(Vector2(1.0, 2.0), Vector2(3.0, 4.0))
			r.x + r.y
		конец
	`)
	testing.expectf(t, ok, "Vector2Add: пустой стек")
	f, is_num := result.(f64)
	testing.expectf(t, is_num && f == 10.0, "Vector2Add: ожидалось 10.0 ((1+3)+(2+4)), получено %v", result)
}

// Целое(8) — ОБЯЗАН быть беззнаковым (u8, не i8): raylib's Color-каналы
// unsigned char 0-255. Fade(color, 0.5) умножает alpha-канал на 0.5,
// RGB не трогает — Fade(Color(255,0,0,255), 0.5) = Color(255,0,0,127)
// (255*0.5=127.5, усечение вниз).
@(test)
test_ffi_int8_struct_color_fade :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Color = ff_структура
			r: Целое(8)
			g: Целое(8)
			b: Целое(8)
			a: Целое(8)
		конец

		внешний "/opt/homebrew/opt/raylib/lib/libraylib.dylib" функ Fade(color: Color, alpha: Число(32)) -> Color

		функ старт() -> Целое
			пер c = Fade(Color(255, 0, 0, 255), 0.5)
			c.r + c.g + c.b + c.a
		конец
	`)
	testing.expectf(t, ok, "Fade: пустой стек")
	f, is_num := result.(f64)
	testing.expectf(t, is_num && f == 382.0, "Fade: ожидалось 382 (255+0+0+127), получено %v", result)
}

// Пусто (void) как возврат внешний-функции — SetTargetFPS ничего не
// возвращает, не требует окна, безопасна для headless CI-прогона.
@(test)
test_ffi_void_return_does_not_crash :: proc(t: ^testing.T) {
	result, ok := run_code(`
		внешний "/opt/homebrew/opt/raylib/lib/libraylib.dylib" функ SetTargetFPS(fps: Целое(32)) -> Пусто

		функ старт() -> Целое
			SetTargetFPS(60)
			42
		конец
	`)
	testing.expectf(t, ok, "void return: пустой стек")
	f, is_num := result.(f64)
	testing.expectf(t, is_num && f == 42.0, "void return: ожидалось 42, получено %v", result)
}
