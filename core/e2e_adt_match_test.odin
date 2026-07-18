#+build !js
package core

import "core:testing"

@(test)
test_adt_cross_module_qualified_use :: proc(t: ^testing.T) {
	result, ok := run_module_file("fixtures/adt_fixture_main.ps")
	testing.expectf(t, ok, "cross-module: пустой стек")
	if !ok do return
	v, is_variant := result.(^Variant_Value)
	testing.expectf(t, is_variant, "cross-module: ожидался ^Variant_Value")
	if !is_variant do return
	testing.expectf(
		t,
		v.type_name == "Фигура" && v.tag_index == 1 && len(v.fields) == 1,
		"cross-module: форма не совпадает",
	)
	f0, is_num := v.fields[0].(f64)
	testing.expectf(t, is_num && f0 == 9.0, "cross-module: поле != 9")
}

@(test)
test_adt_cross_module_short_form :: proc(t: ^testing.T) {
	result, ok := run_module_file("fixtures/adt_fixture_short.ps")
	testing.expectf(t, ok, "cross-module short: пустой стек")
	if !ok do return
	v, is_variant := result.(^Variant_Value)
	testing.expectf(t, is_variant, "cross-module short: ожидался ^Variant_Value")
	if !is_variant do return
	f0, _ := v.fields[0].(f64)
	testing.expectf(
		t,
		v.tag_index == 1 && f0 == 11.0,
		"cross-module short: неверная форма",
	)
}

@(test)
test_adt_non_exported_use_rejected :: proc(t: ^testing.T) {
	testing.expect_assert(t, "Resolve Error: модуль 'ф' не экспортирует 'Круг'")
	run_module_file("fixtures/adt_fixture_private_use.ps")
}

@(test)
test_match_returns_per_variant_value :: proc(t: ^testing.T) {
	sources := [?]string {
		`тип Ф = перечисление
			Точка
			Круг(Число)
			Прямоугольник(Число, Число)
		конец
		функ площадь(ф: Ф) -> Число
			возврат выбор ф
				Точка -> 0
				Круг(р) -> р * р * 314 / 100
				Прямоугольник(ш, выс) -> ш * выс
			конец
		конец
		функ старт() -> Число
			возврат площадь(Ф.Точка)
		конец`,
		`тип Ф = перечисление
			Точка
			Круг(Число)
			Прямоугольник(Число, Число)
		конец
		функ площадь(ф: Ф) -> Число
			возврат выбор ф
				Точка -> 0
				Круг(р) -> р * р * 314 / 100
				Прямоугольник(ш, выс) -> ш * выс
			конец
		конец
		функ старт() -> Число
			возврат площадь(Ф.Прямоугольник(4, 5))
		конец`,
	}
	expected := [?]f64{0, 20}
	for src, i in sources {
		result, ok := run_code(src)
		testing.expectf(t, ok, "match #%d: пустой стек", i)
		if !ok do continue
		f, is_num := result.(f64)
		testing.expectf(t, is_num && f == expected[i], "match #%d: %v != %v", i, result, expected[i])
	}
}

@(test)
test_match_wildcard_arm_executes :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Ф = перечисление
			А
			Б(Число)
		конец
		функ старт() -> Число
			пер зн: Ф = Ф.Б(7)
			возврат выбор зн
				А -> 0
				_ -> 42
			конец
		конец
	`)
	testing.expectf(t, ok, "wildcard: пустой стек")
	if !ok do return
	f, is_num := result.(f64)
	testing.expectf(t, is_num && f == 42.0, "wildcard: %v != 42", result)
}

@(test)
test_match_missing_variant_фигура :: proc(t: ^testing.T) {
	testing.expect_assert(t, "Type Error: выбор не покрывает варианты: Точка")
	run_code(`
		тип Фигура = перечисление
			Точка
			Круг(Число)
		конец
		функ старт() -> Число
			пер ф: Фигура = Фигура.Круг(3)
			возврат выбор ф
				Круг(р) -> р
			конец
		конец
	`)
}

@(test)
test_match_missing_variant_дерево :: proc(t: ^testing.T) {
	testing.expect_assert(t, "Type Error: выбор не покрывает варианты: Лист")
	run_code(`
		тип Дерево = перечисление
			Лист
			Узел(Число)
		конец
		функ старт() -> Число
			пер д: Дерево = Дерево.Узел(5)
			возврат выбор д
				Узел(х) -> х
			конец
		конец
	`)
}

@(test)
test_match_missing_variant_multi :: proc(t: ^testing.T) {
	testing.expect_assert(t, "Type Error: выбор не покрывает варианты: Г")
	run_code(`
		тип Событие = перечисление
			А
			Б
			В(Число)
			Г
		конец
		функ старт() -> Число
			пер с: Событие = Событие.А
			возврат выбор с
				А -> 0
				Б -> 1
				В(х) -> х
			конец
		конец
	`)
}

@(test)
test_match_unreachable_after_wildcard_rejected :: proc(t: ^testing.T) {
	testing.expect_assert(
		t,
		"Type Error: '_' в выборе должен быть только последней веткой",
	)
	run_code(`
		тип Ф = перечисление
			А
			Б
		конец
		функ старт() -> Число
			пер зн: Ф = Ф.А
			возврат выбор зн
				_ -> 42
				Б -> 1
			конец
		конец
	`)
}

@(test)
test_match_scales_20_variants :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип К = перечисление
			V0; V1; V2; V3; V4; V5; V6; V7; V8; V9
			V10; V11; V12; V13; V14; V15; V16; V17; V18; V19
		конец
		функ индекс(к: К) -> Число
			возврат выбор к
				V0 -> 0; V1 -> 1; V2 -> 2; V3 -> 3; V4 -> 4
				V5 -> 5; V6 -> 6; V7 -> 7; V8 -> 8; V9 -> 9
				V10 -> 10; V11 -> 11; V12 -> 12; V13 -> 13; V14 -> 14
				V15 -> 15; V16 -> 16; V17 -> 17; V18 -> 18; V19 -> 19
			конец
		конец
		функ старт() -> Число
			возврат индекс(К.V13)
		конец
	`)
	testing.expectf(t, ok, "20-variants: пустой стек")
	if !ok do return
	f, is_num := result.(f64)
	testing.expectf(t, is_num && f == 13.0, "20-variants: %v != 13", result)
}

@(test)
test_match_arm_panics_never_ignored_in_result_type :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Ф = перечисление
			А
			Б
		конец
		функ старт() -> Число
			пер зн: Ф = Ф.Б
			возврат выбор зн
				А -> паника("не должно")
				Б -> 5
			конец
		конец
	`)
	testing.expectf(t, ok, "panic-arm: пустой стек")
	if !ok do return
	f, is_num := result.(f64)
	testing.expectf(t, is_num && f == 5.0, "panic-arm: %v != 5", result)
}

@(test)
test_match_nested_constructor_binds_inner :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Ф = перечисление
			Круг(Число)
		конец
		функ разбор(р: Результат(Ф, Ошибка)) -> Число
			возврат выбор р
				Результат.Успех(Круг(рад)) -> рад
				_ -> 0
			конец
		конец
		функ старт() -> Число
			возврат разбор(Результат.Успех(Ф.Круг(7)))
		конец
	`)
	testing.expectf(t, ok, "nested: пустой стек")
	if !ok do return
	f, is_num := result.(f64)
	testing.expectf(t, is_num && f == 7.0, "nested: %v != 7", result)
}

@(test)
test_match_nested_constructor_falls_to_wildcard :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Ф = перечисление
			Круг(Число)
			Точка
		конец
		функ разбор(р: Результат(Ф, Ошибка)) -> Число
			возврат выбор р
				Результат.Успех(Круг(рад)) -> рад
				_ -> 99
			конец
		конец
		функ старт() -> Число
			возврат разбор(Результат.Успех(Ф.Точка))
		конец
	`)
	testing.expectf(t, ok, "nested fall: пустой стек")
	if !ok do return
	f, is_num := result.(f64)
	testing.expectf(t, is_num && f == 99.0, "nested fall: %v != 99", result)
}

@(test)
test_match_option_binds_and_branches :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ старт() -> Число
			пер о: Опция(Число) = Опция.Есть(41)
			возврат выбор о
				Опция.Есть(х) -> х + 1
				Нет -> 0
			конец
		конец
	`)
	testing.expectf(t, ok, "opt match: пустой стек")
	if !ok do return
	f, is_num := result.(f64)
	testing.expectf(t, is_num && f == 42.0, "opt match: %v != 42", result)
}

@(test)
test_match_option_none_branch :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ старт() -> Число
			пер о: Опция(Число) = Опция.Нет()
			возврат выбор о
				Опция.Есть(х) -> х + 1
				Нет -> 99
			конец
		конец
	`)
	testing.expectf(t, ok, "opt none: пустой стек")
	if !ok do return
	f, is_num := result.(f64)
	testing.expectf(t, is_num && f == 99.0, "opt none: %v != 99", result)
}

@(test)
test_match_result_binds_success_and_error :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ старт() -> Строка
			пер р: Результат(Строка, Ошибка) = Результат.Успех("ок")
			возврат выбор р
				Результат.Успех(з) -> з
				Результат.Неудача(о) -> "плохо"
			конец
		конец
	`)
	testing.expectf(t, ok, "res match: пустой стек")
	if !ok do return
	s, is_str := result.(^Panos_String)
	testing.expectf(t, is_str && s.data == "ок", "res match: %v != ок", result)
}

@(test)
test_match_option_non_exhaustive_rejected :: proc(t: ^testing.T) {
	testing.expect_assert(t, "Type Error: выбор не покрывает варианты: Нет")
	run_code(`
		функ старт() -> Число
			пер о: Опция(Число) = Опция.Есть(5)
			возврат выбор о
				Опция.Есть(х) -> х
			конец
		конец
	`)
}

@(test)
test_match_duplicate_variant_arm_rejected :: proc(t: ^testing.T) {
	testing.expect_assert(
		t,
		"Type Error: вариант 'Ф.А' покрыт повторно в ветке #2",
	)
	run_code(`
		тип Ф = перечисление
			А
			Б
		конец
		функ старт() -> Число
			пер зн: Ф = Ф.А
			возврат выбор зн
				А -> 0
				А -> 1
			конец
		конец
	`)
}

@(test)
test_match_binder_pattern :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Ф = перечисление
			А
			Б(Число)
		конец
		функ старт() -> Число
			пер зн: Ф = Ф.Б(7)
			возврат выбор зн
				любой -> 5
			конец
		конец
	`)
	testing.expectf(t, ok, "binder: пустой стек")
	if !ok do return
	f, is_num := result.(f64)
	testing.expectf(t, is_num && f == 5.0, "binder: %v != 5", result)
}

@(test)
test_adt_declare_and_construct_zero_field :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Фигура = перечисление
		    Точка
		    Круг(Число)
		    Прямоугольник(Число, Число)
		конец

		функ старт() -> Фигура
		    возврат Фигура.Точка
		конец
	`)
	testing.expectf(t, ok, "US1 zero-field: пустой стек")
	if !ok do return
	v, is_variant := result.(^Variant_Value)
	testing.expectf(t, is_variant, "US1 zero-field: ожидался ^Variant_Value, получено %v", result)
	if !is_variant do return
	testing.expectf(
		t,
		v.type_name == "Фигура",
		"US1 zero-field: type_name '%s' != 'Фигура'",
		v.type_name,
	)
	testing.expectf(t, v.tag_index == 0, "US1 zero-field: tag_index %d != 0", v.tag_index)
	testing.expectf(t, len(v.fields) == 0, "US1 zero-field: fields не пустые (%d)", len(v.fields))
}

@(test)
test_adt_declare_and_construct_single_field :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Фигура = перечисление
		    Точка
		    Круг(Число)
		    Прямоугольник(Число, Число)
		конец

		функ старт() -> Фигура
		    возврат Фигура.Круг(3)
		конец
	`)
	testing.expectf(t, ok, "US1 single-field: пустой стек")
	if !ok do return
	v, is_variant := result.(^Variant_Value)
	testing.expectf(
		t,
		is_variant,
		"US1 single-field: ожидался ^Variant_Value, получено %v",
		result,
	)
	if !is_variant do return
	testing.expectf(t, v.tag_index == 1, "US1 single-field: tag_index %d != 1", v.tag_index)
	testing.expectf(
		t,
		len(v.fields) == 1,
		"US1 single-field: ожидалось 1 поле, получено %d",
		len(v.fields),
	)
	f, is_num := v.fields[0].(f64)
	testing.expectf(t, is_num && f == 3.0, "US1 single-field: поле != 3 (%v)", v.fields[0])
}

@(test)
test_adt_declare_and_construct_multi_field :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Фигура = перечисление
		    Точка
		    Круг(Число)
		    Прямоугольник(Число, Число)
		конец

		функ старт() -> Фигура
		    возврат Фигура.Прямоугольник(4, 5)
		конец
	`)
	testing.expectf(t, ok, "US1 multi-field: пустой стек")
	if !ok do return
	v, is_variant := result.(^Variant_Value)
	testing.expectf(t, is_variant, "US1 multi-field: ожидался ^Variant_Value")
	if !is_variant do return
	testing.expectf(t, v.tag_index == 2, "US1 multi-field: tag_index %d != 2", v.tag_index)
	testing.expectf(
		t,
		len(v.fields) == 2,
		"US1 multi-field: ожидалось 2 поля, получено %d",
		len(v.fields),
	)
	f0, ok0 := v.fields[0].(f64)
	f1, ok1 := v.fields[1].(f64)
	testing.expectf(
		t,
		ok0 && ok1 && f0 == 4.0 && f1 == 5.0,
		"US1 multi-field: поля != (4, 5) (%v, %v)",
		v.fields[0],
		v.fields[1],
	)
}

@(test)
test_adt_arg_type_mismatch_rejected :: proc(t: ^testing.T) {
	testing.expect_assert(
		t,
		"Type Error: у варианта 'Фигура.Круг' поле #0 ожидает 'Число', получено 'Строка'",
	)
	run_code(`
		тип Фигура = перечисление
		    Круг(Число)
		конец

		функ старт() -> Фигура
		    возврат Фигура.Круг("три")
		конец
	`)
}

@(test)
test_adt_qualified_variant_call :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Фигура = перечисление
		    Точка
		    Круг(Число)
		конец

		функ старт() -> Фигура
		    возврат Фигура.Круг(7)
		конец
	`)
	testing.expectf(t, ok, "US1 qualified: пустой стек")
	if !ok do return
	v, is_variant := result.(^Variant_Value)
	testing.expectf(t, is_variant, "US1 qualified: ожидался ^Variant_Value")
	if !is_variant do return
	testing.expectf(
		t,
		v.type_name == "Фигура" && v.tag_index == 1 && len(v.fields) == 1,
		"US1 qualified: неверная форма (%v, tag=%d, len=%d)",
		v.type_name,
		v.tag_index,
		len(v.fields),
	)
}

@(test)
test_adt_qualified_zero_field_variant :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Фигура = перечисление
		    Точка
		    Круг(Число)
		конец

		функ старт() -> Фигура
		    возврат Фигура.Точка
		конец
	`)
	testing.expectf(t, ok, "US1 qualified zero: пустой стек")
	if !ok do return
	v, is_variant := result.(^Variant_Value)
	testing.expectf(t, is_variant, "US1 qualified zero: ожидался ^Variant_Value")
	if !is_variant do return
	testing.expectf(
		t,
		v.type_name == "Фигура" && v.tag_index == 0 && len(v.fields) == 0,
		"US1 qualified zero: неверная форма",
	)
}

@(test)
test_adt_unknown_qualified_variant_rejected :: proc(t: ^testing.T) {
	testing.expect_assert(t, "Resolve Error: у типа 'Фигура' нет варианта 'Ромб'")
	run_code(`
		тип Фигура = перечисление
		    Точка
		    Круг(Число)
		конец

		функ старт() -> Фигура
		    возврат Фигура.Ромб
		конец
	`)
}

@(test)
test_adt_variant_collides_with_struct_rejected :: proc(t: ^testing.T) {
	testing.expect_assert(
		t,
		"Resolve Error: имя варианта 'Точка' конфликтует с уже объявленным символом в модуле",
	)
	run_code(`
		тип Точка = структура
		    x: Число
		    y: Число
		конец

		тип Фигура = перечисление
		    Точка
		    Круг(Число)
		конец

		функ старт() -> Число
		    возврат 0
		конец
	`)
}

@(test)
test_adt_duplicate_variant_rejected :: proc(t: ^testing.T) {
	testing.expect_assert(
		t,
		"Синтаксическая ошибка: вариант 'Круг' объявлен дважды в 'Фигура'",
	)
	run_code(`
		тип Фигура = перечисление
		    Круг(Число)
		    Круг(Число, Число)
		конец

		функ старт() -> Фигура
		    возврат Круг(1)
		конец
	`)
}

// `реализация <перечисление>` раньше не была поддержана: ПРОХОД 3
// type_cheker.odin пропускал регистрацию методов для любого target,
// который не .Struct (репортил диагностику и `continue`), но ПРОХОД 4 всё
// равно пытался проверить тела методов через symbol_types[sym], который
// для пропущенных методов оставался nil — bind_function_args(ctx, m, nil)
// сегфолтил на func_type.params. Всплыло при написании toml.ps (Значение —
// рекурсивный ADT с методами). Теперь Enum поддержан наравне со Struct
// (кроме реализации интерфейсов — это осталось только для Struct).
@(test)
test_enum_impl_block_method_call :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Фигура = перечисление
			Точка
			Круг(Число)
		конец

		реализация Фигура
			функ имя(это: Фигура) -> Строка
				выбор это
					Точка -> "точка"
					Круг(_) -> "круг"
				конец
			конец
		конец

		функ старт() -> Строка
			пер ф = Фигура.Круг(5)
			ф.имя()
		конец
	`)
	testing.expectf(t, ok, "enum impl: пустой стек")
	if !ok do return
	testing.expectf(t, value_str_eq(result, "круг"), "enum impl: ожидалось 'круг', получено %v", result)
}

// Стадия 25: перечисления МОГУТ реализовывать интерфейсы (раньше давало
// diagnostic — см. историю коммитов). Вызов через интерфейсный тип
// параметра — реальная проверка рантайма: Interface_Value.data теперь
// Value (было ^Aggregate_Value), Cast_Interface/Invoke_Interface должны
// корректно работать и с Variant_Value receiver'ом, не только Aggregate_Value.
@(test)
test_enum_can_implement_interface :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Атакующий = интерфейс
			функ атаковать(урон: Число) -> Число
		конец

		тип Фигура = перечисление
			Точка
			Линия
		конец

		реализация Атакующий для Фигура
			функ атаковать(это: Фигура, урон: Число) -> Число
				выбор это
					Точка -> урон
					Линия -> урон * 2
				конец
			конец
		конец

		функ бой(а: Атакующий) -> Число
			а.атаковать(10)
		конец

		функ старт() -> Число
			бой(Фигура.Линия)
		конец
	`)
	testing.expectf(t, ok, "[Стадия 25: enum implements interface] стек пуст")
	n, is_num := result.(f64)
	testing.expectf(t, is_num && n == 20, "[Стадия 25: enum implements interface] ожидалось 20, получено %v", result)
}

// Варианты перечислений больше не живут в плоском module-scope (см.
// Module.variants в resolver.odin) — два РАЗНЫХ перечисления в одном
// модуле теперь МОГУТ переиспользовать одно и то же имя варианта, если
// доступ всегда квалифицирован Тип.Вариант. Раньше это падало "имя
// варианта конфликтует с уже объявленным символом в модуле".
@(test)
test_enum_variant_name_reuse_across_types :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Фигура = перечисление
			Точка
			Круг(Число)
		конец

		тип Статус = перечисление
			Точка
			Активен
		конец

		функ старт() -> Число
			пер ф: Фигура = Фигура.Точка
			пер с: Статус = Статус.Точка
			выбор ф
				Точка -> выбор с
					Точка -> 1
					Активен -> 0
				конец
				Круг(_) -> 0
			конец
		конец
	`)
	testing.expectf(t, ok, "enum variant reuse: пустой стек")
	if !ok do return
	testing.expectf(t, result == Value(f64(1)), "enum variant reuse: ожидалось 1, получено %v", result)
}

// Обратная сторона фикса: bare-конструктор (без квалификации типом)
// больше не резолвится вообще — единственный путь построить вариант
// теперь Тип.Вариант. Паттерны в `выбор` это НЕ затрагивает (резолвятся
// по expected_type в type_cheker, не через scope) — см. соседний тест.
@(test)
test_enum_bare_constructor_rejected :: proc(t: ^testing.T) {
	testing.expect_assert(t, "Resolve Error: undefined variable 'Круг'")
	run_code(`
		тип Фигура = перечисление
			Точка
			Круг(Число)
		конец

		функ старт() -> Фигура
			возврат Круг(5)
		конец
	`)
}

// Стадия 25: реализация интерфейса на перечислении с ПАЙЛОАД-ВАРИАНТОМ,
// переданным туда, где ожидается интерфейсный тип параметра —
// Cast_Interface (vm.odin) теперь принимает и Variant_Value, не только
// Aggregate_Value.
@(test)
test_enum_payload_variant_as_interface_arg :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Атакующий = интерфейс
			функ атаковать(урон: Число) -> Число
		конец

		тип Существо = перечисление
			Гоблин(Число)
			Дракон(Число)
		конец

		реализация Атакующий для Существо
			функ атаковать(это: Существо, урон: Число) -> Число
				выбор это
					Гоблин(защита) -> урон - защита
					Дракон(защита) -> урон - защита * 2
				конец
			конец
		конец

		функ бой(а: Атакующий) -> Число
			а.атаковать(20)
		конец

		функ старт() -> Число
			бой(Существо.Дракон(3))
		конец
	`)
	testing.expectf(t, ok, "[Стадия 25: enum payload-вариант как интерфейс-арг] стек пуст")
	n, is_num := result.(f64)
	testing.expectf(t, is_num && n == 14, "[Стадия 25: enum payload-вариант как интерфейс-арг] ожидалось 14, получено %v", result)
}

// Стадия 25: Копируемое на перечислении — обычный прямой вызов метода,
// подтверждает, что generic interface-dispatch (уже бесплатный для
// структур, Стадия 23) так же бесплатен для enum receiver'ов.
@(test)
test_enum_implements_copyable :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Событие = перечисление
			А(Число)
			Б
		конец

		реализация Копируемое для Событие
			функ клонировать(это: Событие) -> Событие
				выбор это
					А(x) -> Событие.А(x)
					Б -> Событие.Б
				конец
			конец
		конец

		функ старт() -> Число
			пер e = Событие.А(5)
			пер e2 = e.клонировать()
			выбор e2
				А(x) -> x
				Б -> -1
			конец
		конец
	`)
	testing.expectf(t, ok, "[Стадия 25: enum implements Копируемое] стек пуст")
	n, is_num := result.(f64)
	testing.expectf(t, is_num && n == 5, "[Стадия 25: enum implements Копируемое] ожидалось 5, получено %v", result)
}

// `выбор` на литералах: выбор больше не ограничен .Enum-subject'ами —
// Число/Строка/Булево дают Match_Arm_Kind.Literal-ветки, компилирующиеся
// в обычное .Equal (та же структурная семантика, что у оператора ==).
@(test)
test_match_number_literal_pattern :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ описать(x: Число) -> Строка
			выбор x
				1 -> "один"
				2 -> "два"
				_ -> "другое"
			конец
		конец

		функ старт() -> Строка
			описать(1) + " " + описать(2) + " " + описать(99)
		конец
	`)
	testing.expectf(t, ok, "[выбор: Число] стек пуст")
	s, is_str := result.(^Panos_String)
	testing.expectf(t, is_str && s.data == "один два другое", "[выбор: Число] ожидалось 'один два другое', получено %v", result)
}

@(test)
test_match_string_literal_pattern_with_binder_catchall :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ разобрать(s: Строка) -> Число
			выбор s
				"да" -> 1
				"нет" -> 0
				остальное -> -1
			конец
		конец

		функ старт() -> Число
			разобрать("да") + разобрать("нет") + разобрать("???")
		конец
	`)
	testing.expectf(t, ok, "[выбор: Строка] стек пуст")
	n, is_num := result.(f64)
	testing.expectf(t, is_num && n == 0, "[выбор: Строка] ожидалось 0 (1+0-1), получено %v", result)
}

// Булево — единственный литеральный тип с конечным доменом (2 значения):
// выбор по обеим веткам истина/ложь исчерпывающий БЕЗ обязательного `_`,
// в отличие от Число/Строка (см. следующий негативный тест).
@(test)
test_match_boolean_exhaustive_without_wildcard :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ старт() -> Строка
			выбор истина
				истина -> "да"
				ложь -> "нет"
			конец
		конец
	`)
	testing.expectf(t, ok, "[выбор: Булево exhaustive] стек пуст")
	s, is_str := result.(^Panos_String)
	testing.expectf(t, is_str && s.data == "да", "[выбор: Булево exhaustive] ожидалось 'да', получено %v", result)
}

// Литеральные шаблоны работают и как под-шаблоны внутри конструктора
// варианта (Событие.Клик(1, y)) — classify_pattern рекурсивен по
// expected_fields, литеральная ветка не требует отдельного кода для
// этого случая.
@(test)
test_match_literal_inside_constructor_subpattern :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Событие = перечисление
			Клик(Число, Число)
		конец

		функ старт() -> Строка
			пер e = Событие.Клик(1, 2)
			выбор e
				Событие.Клик(1, y) -> "клик по x=1"
				Событие.Клик(x, y) -> "обычный клик"
			конец
		конец
	`)
	testing.expectf(t, ok, "[выбор: литерал в конструкторе] стек пуст")
	s, is_str := result.(^Panos_String)
	testing.expectf(t, is_str && s.data == "клик по x=1", "[выбор: литерал в конструкторе] ожидалось 'клик по x=1', получено %v", result)
}

// Число/Строка — неперечислимый домен, без завершающей `_`/биндер-ветки
// выбор не может считаться исчерпывающим (в отличие от Булево выше).
@(test)
test_match_number_literal_requires_catchall :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		функ старт() -> Строка
			выбор 1
				1 -> "один"
				2 -> "два"
			конец
		конец
	`)
	expect_diagnostic(t, diags, "Type Error: выбор по 'Число' должен заканчиваться веткой '_' или биндером — набор литеральных веток не может быть исчерпывающим")
}

@(test)
test_match_boolean_missing_value_reports_diagnostic :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		функ старт() -> Строка
			выбор истина
				истина -> "да"
			конец
		конец
	`)
	expect_diagnostic(t, diags, "Type Error: выбор не покрывает значения: ложь")
}

@(test)
test_match_literal_type_mismatch_reports_diagnostic :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		функ старт() -> Строка
			выбор 5
				"пять" -> "текст"
				_ -> "другое"
			конец
		конец
	`)
	expect_diagnostic(t, diags, "Type Error: ожидался 'Число', получен 'Строка'")
}

// `выбор` на структурах: Точка(1, x) разбирает поля по порядку объявления
// с полноценными под-шаблонами (литерал/`_`/биндер), Точка(_, _) — все
// поля wildcard, выступает как catch-all (та же exhaustiveness-семантика,
// что и голый `_`/биндер).
@(test)
test_match_struct_constructor_pattern :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Точка = структура
			x: Число
			y: Число
		конец

		функ описать(п: Точка) -> Строка
			выбор п
				Точка(1, x) -> "первая"
				Точка(2, x) -> "вторая"
				Точка(_, _) -> "другая"
			конец
		конец

		функ старт() -> Строка
			описать(Точка(1, 99)) + " " + описать(Точка(2, 99)) + " " + описать(Точка(5, 99))
		конец
	`)
	testing.expectf(t, ok, "[выбор: структурный конструктор] стек пуст")
	s, is_str := result.(^Panos_String)
	testing.expectf(t, is_str && s.data == "первая вторая другая", "[выбор: структурный конструктор] ожидалось 'первая вторая другая', получено %v", result)
}

@(test)
test_match_struct_missing_catchall_reports_diagnostic :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		тип Точка = структура
			x: Число
			y: Число
		конец

		функ старт() -> Строка
			пер п = Точка(1, 2)
			выбор п
				Точка(1, x) -> "один"
			конец
		конец
	`)
	expect_diagnostic(t, diags, "Type Error: выбор по 'Точка' должен заканчиваться веткой '_', биндером или конструктором, покрывающим все поля (например 'Точка(_, _)')")
}

@(test)
test_match_struct_wrong_type_name_reports_diagnostic :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		тип Точка = структура
			x: Число
			y: Число
		конец
		тип Вектор = структура
			x: Число
			y: Число
		конец

		функ старт() -> Строка
			пер п = Точка(1, 2)
			выбор п
				Вектор(x, y) -> "вектор"
				_ -> "другое"
			конец
		конец
	`)
	expect_diagnostic(t, diags, "Type Error: шаблон-конструктор 'Вектор' не совпадает со структурой 'Точка'")
}

@(test)
test_match_struct_fully_covering_arm_must_be_last :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		тип Точка = структура
			x: Число
			y: Число
		конец

		функ старт() -> Строка
			пер п = Точка(1, 2)
			выбор п
				Точка(x, y) -> "любая"
				Точка(1, y) -> "недостижимо"
			конец
		конец
	`)
	expect_diagnostic(t, diags, "Type Error: ветка-конструктор структуры, покрывающая все поля, должна быть только последней — она покрывает все случаи")
}

// Рекурсивная exhaustiveness: вложенный Struct_Constructor под-шаблон
// (Точка(_, _)) сам исчерпывающий для своего типа — родительская ветка
// (Событие.Клик(...)) теперь ЗАЧИТЫВАЕТ это (pi.fields_fully_covered
// в classify_pattern рекурсивен через is_exhaustive под-шаблонов), не
// требует лишней catch-all ветки. Раньше (Стадия 25/29/31) любой
// вложенный Constructor/Struct_Constructor давал "не покрывает" ВСЕГДА,
// независимо от собственной исчерпываемости.
@(test)
test_match_nested_struct_constructor_recursively_exhaustive :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Точка = структура
			x: Число
			y: Число
		конец

		тип Событие = перечисление
			Клик(Точка)
			Скролл(Число)
		конец

		функ старт() -> Строка
			пер е: Событие = Событие.Клик(Точка(1, 2))
			выбор е
				Событие.Клик(Точка(_, _)) -> "клик"
				Событие.Скролл(_) -> "скролл"
			конец
		конец
	`)
	testing.expectf(t, ok, "[рекурсивная exhaustiveness] стек пуст")
	s, is_str := result.(^Panos_String)
	testing.expectf(t, is_str && s.data == "клик", "[рекурсивная exhaustiveness] ожидалось 'клик', получено %v", result)
}

// Негативный кейс: вложенный под-шаблон ЧАСТИЧНО сужен литералом
// (Точка(1, _), не Точка(_, _)) — НЕ исчерпывающий для Точка, значит и
// родительская ветка НЕ покрывает Клик целиком — catch-all по-прежнему
// обязателен.
@(test)
test_match_nested_struct_constructor_partial_still_requires_catchall :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		тип Точка = структура
			x: Число
			y: Число
		конец

		тип Событие = перечисление
			Клик(Точка)
			Скролл(Число)
		конец

		функ старт() -> Строка
			пер е: Событие = Событие.Клик(Точка(1, 2))
			выбор е
				Событие.Клик(Точка(1, _)) -> "клик на x=1"
				Событие.Скролл(_) -> "скролл"
			конец
		конец
	`)
	expect_diagnostic(t, diags, "Type Error: выбор не покрывает варианты: Клик")
}

// Именованные поля в структурных шаблонах (`Точка(x: 1, y: _)`) — только
// у структур (нет тегов, но есть ИМЕНА полей, в отличие от enum-
// вариантов). Частичные: неупомянутые поля трактуются как неявный `_`,
// не сужают exhaustiveness этой ветки.
@(test)
test_match_named_field_pattern_partial :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Точка = структура
			x: Число
			y: Число
		конец

		функ старт() -> Строка
			пер п = Точка(0, 5)
			выбор п
				Точка(x: 0, y: 0) -> "начало координат"
				Точка(y: 0) -> "на оси X"
				Точка(x: 0) -> "на оси Y"
				Точка(_, _) -> "где-то ещё"
			конец
		конец
	`)
	testing.expectf(t, ok, "[именованные поля: частичное] стек пуст")
	s, is_str := result.(^Panos_String)
	testing.expectf(t, is_str && s.data == "на оси Y", "[именованные поля: частичное] ожидалось 'на оси Y', получено %v", result)
}

// Точка(x: _, y: _) — все поля явно (именованно) wildcard — эквивалентно
// голому Точка(_, _), полностью покрывает структуру, catch-all не нужен.
@(test)
test_match_named_field_pattern_all_wildcards_is_catchall :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		тип Точка = структура
			x: Число
			y: Число
		конец

		функ старт() -> Строка
			пер п = Точка(3, 4)
			выбор п
				Точка(x: 0, y: 0) -> "начало"
				Точка(x: _, y: _) -> "другое"
			конец
		конец
	`)
	testing.expectf(t, len(diags) == 0, "[именованные поля: все wildcard] неожиданные diagnostics: %v", diags)
}

// Негатив: неизвестное имя поля — понятная diagnostic, не крэш.
@(test)
test_match_named_field_pattern_unknown_field_is_error :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		тип Точка = структура
			x: Число
			y: Число
		конец

		функ старт() -> Строка
			пер п = Точка(3, 4)
			выбор п
				Точка(z: 0) -> "?"
				_ -> "другое"
			конец
		конец
	`)
	expect_diagnostic(t, diags, "Type Error: у структуры 'Точка' нет поля 'z'")
}

// Негатив: смешивать позиционную и именованную форму в одном шаблоне
// нельзя.
@(test)
test_match_mixed_positional_and_named_fields_is_error :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		тип Точка = структура
			x: Число
			y: Число
		конец

		функ старт() -> Строка
			пер п = Точка(3, 4)
			выбор п
				Точка(1, y: 2) -> "?"
				_ -> "другое"
			конец
		конец
	`)
	expect_diagnostic(t, diags, "Синтаксическая ошибка: нельзя смешивать позиционные и именованные поля в одном шаблоне")
}

// Негатив: у enum-вариантов нет имён полей (Variant_Decl хранит только
// типы, не имена) — именованная форма для них бессмысленна.
@(test)
test_match_named_field_pattern_on_enum_variant_is_error :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		тип Событие = перечисление
			Клик(Число, Число)
		конец

		функ старт() -> Строка
			пер e = Событие.Клик(1, 2)
			выбор e
				Событие.Клик(x: 1, y: 2) -> "?"
				_ -> "другое"
			конец
		конец
	`)
	expect_diagnostic(t, diags, "Type Error: вариант перечисления 'Клик' не имеет именованных полей — только позиционные")
}
