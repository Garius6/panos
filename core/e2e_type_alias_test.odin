#+build !js
package core

import "core:testing"

// `тип Имя = <тип-выражение>` (Go-style `type X = Y`) — Имя резолвится в
// САМ aliased_type (resolve_symbol_type, type_cheker.odin), не номинальный
// тип. Главный мотив — читаемые сигнатуры функциональных типов (Обработчик
// вместо инлайн функ(...)->...), но выражение справа может быть любым
// Type_Node (base-тип, структура, кортеж и т.п.), кроме generic-параметров
// самого алиаса (см. test_type_alias_generic_params_rejected).

@(test)
test_type_alias_function_type_basic :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Обработчик = функ(Число) -> Число

		функ применить(ф: Обработчик, x: Число) -> Число
			ф(x)
		конец

		функ удвоить(x: Число) -> Число
			x + x
		конец

		функ старт() -> Число
			применить(удвоить, 21)
		конец
	`)
	testing.expectf(t, ok, "[type alias] пустой стек")
	n, is_num := result.(f64)
	testing.expectf(t, is_num && n == 42.0, "[type alias] ожидалось 42, получено %v", result)
}

@(test)
test_type_alias_cross_module :: proc(t: ^testing.T) {
	result, ok := run_module_file("fixtures/type_alias_fixture_main.ps")
	testing.expectf(t, ok, "[type alias cross-module] пустой стек")
	if !ok do return
	n, is_num := result.(f64)
	testing.expectf(t, is_num && n == 30.0, "[type alias cross-module] ожидалось 30, получено %v", result)
}

// Non-generic alias к обычному base-типу — должен быть ВЗАИМОЗАМЕНЯЕМ с
// прямым использованием Число (тот же ^Type-объект, не отдельный
// номинальный тип, см. resolve_symbol_type).
@(test)
test_type_alias_to_base_type_is_interchangeable :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип МоёЧисло = Число

		функ принимает_число(x: Число) -> Число
			x
		конец

		функ старт() -> МоёЧисло
			принимает_число(5)
		конец
	`)
	testing.expectf(t, ok, "[type alias base] пустой стек")
	n, is_num := result.(f64)
	testing.expectf(t, is_num && n == 5.0, "[type alias base] ожидалось 5, получено %v", result)
}

// Алиас, объявленный ДО структуры, которую он аглиасит (forward reference
// внутри одного файла) — resolve_symbol_type резолвит лениво, по факту
// первого использования, а не по позиции в файле.
@(test)
test_type_alias_forward_reference_to_struct :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Точка2 = Точка

		тип Точка = структура
			x: Число
			y: Число
		конец

		функ старт() -> Число
			пер п: Точка2 = Точка(1, 2)
			п.x + п.y
		конец
	`)
	testing.expectf(t, ok, "[type alias forward] пустой стек")
	n, is_num := result.(f64)
	testing.expectf(t, is_num && n == 3.0, "[type alias forward] ожидалось 3, получено %v", result)
}

@(test)
test_type_alias_cyclic_is_type_error :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		тип A = B
		тип B = A

		функ старт() -> Число
			0
		конец
	`)
	expect_diagnostic(t, diags, "Type Error: циклический алиас типа 'A'")
}

@(test)
test_type_alias_generic_params_rejected :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		тип Компаратор[Т] = функ(Т, Т) -> Число

		функ старт() -> Число
			0
		конец
	`)
	expect_diagnostic(t, diags, "Синтаксическая ошибка: алиас типа 'Компаратор' не может иметь свои type-параметры")
}
