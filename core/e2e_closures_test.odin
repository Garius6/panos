#+build !js
package core

import "core:testing"

// Стадия 48 (замыкания, value-capture): базовый захват одной внешней
// переменной — лямбда, вызванная ПОСЛЕ создания, всё ещё видит значение,
// которое переменная имела в момент создания лямбды.
@(test)
test_closure_captures_outer_local :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ создать() -> функ() -> Число
			пер n = 5.0
			функ() -> Число
				n
			конец
		конец

		функ старт() -> Число
			пер л = создать()
			л()
		конец
	`)
	testing.expectf(t, ok, "closure: пустой стек")
	f, is_num := result.(f64)
	testing.expectf(t, is_num && f == 5.0, "closure: ожидалось 5.0, получено %v", result)
}

// Snapshot-семантика (НЕ ссылка): мутация внешней переменной ПОСЛЕ
// создания лямбды не видна внутри неё — captured скопирован в момент
// .Build_Closure, не читает текущий слот внешней функции.
@(test)
test_closure_capture_is_snapshot_not_reference :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ старт() -> Число
			пер n = 5.0
			пер л = функ() -> Число
				n
			конец
			n = 999.0
			л()
		конец
	`)
	testing.expectf(t, ok, "closure snapshot: пустой стек")
	f, is_num := result.(f64)
	testing.expectf(t, is_num && f == 5.0, "closure snapshot: ожидалось 5.0 (снапшот), получено %v", result)
}

// Захват НЕСКОЛЬКИХ переменных сразу — проверяет позиционное совпадение
// индексов между .Build_Closure-пушем (внешний контекст) и .Get_Captured
// внутри тела (индексы должны совпадать по порядку lambda_captures).
@(test)
test_closure_captures_multiple_variables :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ старт() -> Число
			пер a = 1.0
			пер b = 2.0
			пер c = 3.0
			пер л = функ() -> Число
				a + b + c
			конец
			л()
		конец
	`)
	testing.expectf(t, ok, "closure multi-capture: пустой стек")
	f, is_num := result.(f64)
	testing.expectf(t, is_num && f == 6.0, "closure multi-capture: ожидалось 6.0, получено %v", result)
}

// Присваивание захваченной переменной ВНУТРИ лямбды — Type Error, не
// тихий no-op (см. type_cheker.odin, case .Assign).
@(test)
test_closure_mutating_captured_variable_is_type_error :: proc(t: ^testing.T) {
	testing.expect_assert(t, "Type Error: захваченная переменная 'n' неизменяема внутри лямбды")
	run_code(`
		функ старт() -> Число
			пер n = 5.0
			пер л = функ() -> Число
				n = 10.0
				n
			конец
			л()
		конец
	`)
}

// Вложенная лямбда-в-лямбде: символ, объявленный СНАРУЖИ ОБЕИХ лямбд,
// транзитивно захватывается на каждом уровне (upvalue-resolution через
// несколько границ, см. lookup_symbol_tracking_captures в resolver.odin).
@(test)
test_closure_nested_lambda_transitive_capture :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ старт() -> Число
			пер a = 1.0
			пер b = 2.0
			пер внешняя_л = функ() -> функ() -> Число
				функ() -> Число
					a + b
				конец
			конец
			пер внутренняя_л = внешняя_л()
			внутренняя_л()
		конец
	`)
	testing.expectf(t, ok, "closure nested: пустой стек")
	f, is_num := result.(f64)
	testing.expectf(t, is_num && f == 3.0, "closure nested: ожидалось 3.0, получено %v", result)
}

// Отправка замыкания другому процессу: message_deep_copy должен глубоко
// скопировать captured (не поделиться heap-объектами между процессами,
// см. case ^Closure_Value в message_deep_copy, vm.odin) — переданный
// closure продолжает работать корректно ПОСЛЕ пересечения границы
// процесса, возвращая исходно захваченное значение.
@(test)
test_closure_sent_to_another_process_survives_deep_copy :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Сообщение = перечисление
			Вызвать(функ() -> Число, Процесс(Число))
		конец

		функ исполнитель() -> Пусто
			выбор получить()
				Сообщение.Вызвать(ф, куда) -> отправить(куда, ф())
			конец
		конец

		функ старт() -> Число
			пер n = 111.0
			пер л = функ() -> Число
				n
			конец
			пер proc: Процесс(Сообщение) = запусти исполнитель()
			отправить(proc, Сообщение.Вызвать(л, себя()))
			получить()
		конец
	`)
	testing.expectf(t, ok, "closure send: пустой стек")
	f, is_num := result.(f64)
	testing.expectf(t, is_num && f == 111.0, "closure send: ожидалось 111.0, получено %v", result)
}
