#+build !js
package core

import "core:testing"

// ============================================================================
// US1 — квалифицированный generic-тип (модуль.Тип(Аргумент)) как аннотация
// типа. Фикстуры: fixtures/qualified_generic_fixture_lib.ps (экспортирует
// Коробка[T]/Пара[A,B], плюс НЕэкспортированный НеЭкспортированная[T]) +
// fixtures/qualified_generic_fixture_main*.ps.
// ============================================================================

@(test)
test_qualified_generic_type_as_return_and_param_annotation :: proc(t: ^testing.T) {
	result, ok := run_module_file("fixtures/qualified_generic_fixture_main.ps")
	testing.expectf(t, ok, "[квалифицированный generic-тип] стек пуст")
	b, is_bool := result.(bool)
	testing.expectf(t, is_bool && b, "[квалифицированный generic-тип] ожидалось true, получено %v", result)
}

@(test)
test_qualified_generic_type_not_exported_reports_error :: proc(t: ^testing.T) {
	diags := typecheck_only_module_file("fixtures/qualified_generic_fixture_main_not_exported.ps")
	expect_diagnostic(t, diags, "Type Error: модуль 'либ' не экспортирует 'НеЭкспортированная'")
}

@(test)
test_qualified_generic_type_wrong_arity_reports_error :: proc(t: ^testing.T) {
	diags := typecheck_only_module_file("fixtures/qualified_generic_fixture_main_wrong_arity.ps")
	expect_diagnostic(t, diags, "Type Error: 'Коробка' ожидает 1 параметров типа, получено 2")
}

// ============================================================================
// US2 — многострочное тело ветки `выбор`/`если` (`Шаблон тогда ... конец`).
// ============================================================================

@(test)
test_match_arm_then_block_runs_side_effect_and_yields_tail_value :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ старт() -> Булево
			пер журнал: Массив(Число) = массив()
			пер значение: Опция(Число) = Опция.Есть(41)
			пер результат = выбор значение
				Опция.Есть(x) тогда
					журнал.добавить(x)
					x + 1
				конец
				Опция.Нет -> 0
			конец

			результат == 42 и длина(журнал) == 1 и журнал[0] == 41
		конец
	`)
	testing.expectf(t, ok, "[многострочная ветка выбор] стек пуст")
	b, is_bool := result.(bool)
	testing.expectf(t, is_bool && b, "[многострочная ветка выбор] ожидалось true, получено %v", result)
}

@(test)
test_match_mixes_single_line_and_block_arms_with_matching_tail_types :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ старт() -> Число
			пер значение: Опция(Число) = Опция.Есть(10)
			выбор значение
				Опция.Есть(x) тогда
					пер удвоенное = x * 2
					удвоенное
				конец
				Опция.Нет -> 0
			конец
		конец
	`)
	testing.expectf(t, ok, "[смешанные формы веток] стек пуст")
	n, is_num := result.(f64)
	testing.expectf(t, is_num && n == 20.0, "[смешанные формы веток] ожидалось 20, получено %v", result)
}

@(test)
test_match_block_arms_still_enforce_tail_type_unification :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		функ f() -> Пусто
			пер значение: Опция(Число) = Опция.Есть(1)
			выбор значение
				Опция.Есть(x) тогда
					x
				конец
				Опция.Нет тогда
					"строка"
				конец
			конец
		конец
	`)
	testing.expectf(t, len(diags) > 0, "[несовпадение типов хвостовых веток] ожидалась хотя бы одна ошибка типов")
}

@(test)
test_match_block_arm_ending_in_return_needs_no_further_tail_expr :: proc(t: ^testing.T) {
	result_pos, ok_pos := run_code(`
		// Хвост после выбор — "пер запасной = 100 \n запасной", НЕ голый
		// "-999": statement-граница не чувствительна к переводу строки
		// перед бинарным оператором (не баг этой фичи — "x\n-999" вне match
		// тоже читается как "x - 999"), голый литерал после выбор слился бы
		// в "(выбор ...) - 999" вместо двух отдельных statement'ов.
		функ проверить(x: Число) -> Число
			выбор x > 0
				истина тогда
					пер y = x * 2
					возврат y
				конец
				ложь тогда
					возврат 0
				конец
			конец
			пер запасной: Число = 100
			запасной
		конец

		функ старт() -> Число
			проверить(5)
		конец
	`)
	testing.expectf(t, ok_pos, "[возврат посреди многострочной ветки, положительная] стек пуст")
	n_pos, is_num_pos := result_pos.(f64)
	testing.expectf(t, is_num_pos && n_pos == 10.0, "[возврат посреди многострочной ветки, положительная] ожидалось 10, получено %v", result_pos)

	result_neg, ok_neg := run_code(`
		// Хвост после выбор — "пер запасной = 100 \n запасной", НЕ голый
		// "-999": statement-граница не чувствительна к переводу строки
		// перед бинарным оператором (не баг этой фичи — "x\n-999" вне match
		// тоже читается как "x - 999"), голый литерал после выбор слился бы
		// в "(выбор ...) - 999" вместо двух отдельных statement'ов.
		функ проверить(x: Число) -> Число
			выбор x > 0
				истина тогда
					пер y = x * 2
					возврат y
				конец
				ложь тогда
					возврат 0
				конец
			конец
			пер запасной: Число = 100
			запасной
		конец

		функ старт() -> Число
			проверить(-3)
		конец
	`)
	testing.expectf(t, ok_neg, "[возврат посреди многострочной ветки, отрицательная] стек пуст")
	n_neg, is_num_neg := result_neg.(f64)
	testing.expectf(t, is_num_neg && n_neg == 0.0, "[возврат посреди многострочной ветки, отрицательная] ожидалось 0, получено %v", result_neg)
}

@(test)
test_if_multiline_branches_still_unify_by_tail_expression :: proc(t: ^testing.T) {
	// если...тогда...иначе...конец уже поддерживал многострочные блоки ДО
	// этой фичи — тест фиксирует отсутствие регрессии (Acceptance Scenario 2
	// в spec.md явно распространяет FR-005 и на если, не только выбор).
	result, ok := run_code(`
		функ старт() -> Число
			пер x = 5
			если x > 0 тогда
				пер y = x * 2
				y
			иначе
				пер y = 0 - x
				y
			конец
		конец
	`)
	testing.expectf(t, ok, "[если многострочные ветки] стек пуст")
	n, is_num := result.(f64)
	testing.expectf(t, is_num && n == 10.0, "[если многострочные ветки] ожидалось 10, получено %v", result)
}

// ============================================================================
// US3 — завершающая запятая в списках через запятую.
// ============================================================================

@(test)
test_trailing_comma_in_call_args :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ сложить(а: Число, б: Число) -> Число
			а + б
		конец

		функ старт() -> Число
			сложить(
				1,
				2,
			)
		конец
	`)
	testing.expectf(t, ok, "[завершающая запятая: аргументы вызова] стек пуст")
	n, is_num := result.(f64)
	testing.expectf(t, is_num && n == 3.0, "[завершающая запятая: аргументы вызова] ожидалось 3, получено %v", result)
}

@(test)
test_trailing_comma_in_enum_variant_types :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Пара = перечисление
			Значения(Число, Строка,)
		конец

		функ старт() -> Число
			пер п = Пара.Значения(5, "х")
			выбор п
				Пара.Значения(n, _) -> n
			конец
		конец
	`)
	testing.expectf(t, ok, "[завершающая запятая: типы варианта перечисления] стек пуст")
	n, is_num := result.(f64)
	testing.expectf(t, is_num && n == 5.0, "[завершающая запятая: типы варианта перечисления] ожидалось 5, получено %v", result)
}

@(test)
test_trailing_comma_in_pattern_constructor_args :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Пара = перечисление
			Значения(Число, Строка)
		конец

		функ старт() -> Число
			пер п = Пара.Значения(7, "х")
			выбор п
				Пара.Значения(n, _,) -> n
			конец
		конец
	`)
	testing.expectf(t, ok, "[завершающая запятая: аргументы шаблона-конструктора] стек пуст")
	n, is_num := result.(f64)
	testing.expectf(t, is_num && n == 7.0, "[завершающая запятая: аргументы шаблона-конструктора] ожидалось 7, получено %v", result)
}

@(test)
test_trailing_comma_in_generic_type_args :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ старт() -> Число
			пер м: Соответствие(Строка, Число,) = соответствие()
			м["x"] = 5
			м["x"]
		конец
	`)
	testing.expectf(t, ok, "[завершающая запятая: type-аргументы generic-типа] стек пуст")
	n, is_num := result.(f64)
	testing.expectf(t, is_num && n == 5.0, "[завершающая запятая: type-аргументы generic-типа] ожидалось 5, получено %v", result)
}

@(test)
test_trailing_comma_in_tuple_type_elements :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ пара() -> (Число, Строка,)
			(1, "x")
		конец

		функ старт() -> Число
			пер (n, s) = пара()
			n
		конец
	`)
	testing.expectf(t, ok, "[завершающая запятая: элементы tuple-типа] стек пуст")
	n, is_num := result.(f64)
	testing.expectf(t, is_num && n == 1.0, "[завершающая запятая: элементы tuple-типа] ожидалось 1, получено %v", result)
}

@(test)
test_trailing_comma_without_preceding_arg_is_still_an_error :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		функ без_аргументов() -> Число
			0
		конец

		функ старт() -> Число
			без_аргументов(,)
		конец
	`)
	testing.expectf(t, len(diags) > 0, "[запятая без аргумента] ожидалась хотя бы одна ошибка")
}
