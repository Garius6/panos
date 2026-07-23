#+build !js
package core

import "core:testing"

// ============================================================================
// Top-level "[экспорт] конст ИМЯ = <литерал>" — компилируется подстановкой
// литерала на месте использования (см. compile_symbol_value_ref/Property_Expr
// в compiler.odin), значение MUST быть Число/Строка/Булево литералом (либо
// унарный минус перед числом).
// ============================================================================

@(test)
test_const_number_used_in_same_file :: proc(t: ^testing.T) {
	result, ok := run_code(`
		конст НОМЕР_ВЕРСИИ = 11

		функ старт() -> Число
			НОМЕР_ВЕРСИИ
		конец
	`)
	testing.expectf(t, ok, "[конст число] стек пуст")
	n, is_num := result.(f64)
	testing.expectf(t, is_num && n == 11.0, "[конст число] ожидалось 11, получено %v", result)
}

@(test)
test_const_negative_number_string_bool_same_file :: proc(t: ^testing.T) {
	result, ok := run_code(`
		конст МИНИМУМ = -5
		конст ИМЯ = "панос"
		конст ОТЛАДКА = истина

		функ старт() -> Булево
			МИНИМУМ == -5 и ИМЯ == "панос" и ОТЛАДКА
		конец
	`)
	testing.expectf(t, ok, "[конст отрицательное/строка/булево] стек пуст")
	b, is_bool := result.(bool)
	testing.expectf(t, is_bool && b, "[конст отрицательное/строка/булево] ожидалось true, получено %v", result)
}

@(test)
test_const_reassignment_is_a_type_error :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		конст X = 5

		функ старт() -> Пусто
			X = 10
		конец
	`)
	expect_diagnostic(t, diags, "Type Error: попытка переприсвоить константу 'X'")
}

@(test)
test_const_value_must_be_a_literal :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		функ вычислить() -> Число
			5
		конец

		конст X = вычислить()

		функ старт() -> Пусто
		конец
	`)
	expect_diagnostic(t, diags, "Синтаксическая ошибка: значение 'конст' должно быть числовым/строковым/булевым литералом")
}

@(test)
test_const_duplicate_name_is_a_resolve_error :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		конст X = 1
		конст X = 2

		функ старт() -> Пусто
		конец
	`)
	expect_diagnostic(t, diags, "Resolve Error: символ 'X' уже объявлен")
}

@(test)
test_exported_const_used_across_module_boundary :: proc(t: ^testing.T) {
	result, ok := run_module_file("fixtures/const_fixture_main.ps")
	testing.expectf(t, ok, "[конст через границу модуля] стек пуст")
	b, is_bool := result.(bool)
	testing.expectf(t, is_bool && b, "[конст через границу модуля] ожидалось true, получено %v", result)
}

@(test)
test_non_exported_const_not_visible_across_module_boundary :: proc(t: ^testing.T) {
	diags := typecheck_only_module_file("fixtures/const_fixture_main_private.ps")
	expect_diagnostic(t, diags, "Resolve Error: модуль 'либ' не экспортирует 'ПРИВАТНАЯ'")
}
