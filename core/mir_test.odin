#+build !js
package core

import "core:strings"
import "core:testing"

// Фаза 1 верификация (см. план): печатное представление MIR для батареи
// AST-фрагментов + validate_function без ошибок. check_source (core/
// pipeline.odin) — обычный (не _test.odin) пайплайн лексер→парсер→
// резолвер→тайпчекер, тот же, что использует wasm/main.odin и LSP —
// доступен отсюда через cross-package импорт "../", в отличие от
// run_code (core/e2e_test.odin, компилируется только под `odin test
// ./core`, не виден при обычной сборке пакета core, которую делает
// `odin test ./core/mir`).

@(private = "file")
lower_source :: proc(t: ^testing.T, source: string) -> (Mir_Module, ^Mir_Function) {
	result := check_source(source)
	testing.expectf(t, len(result.diags) == 0, "check_source diagnostics: %v", result.diags)

	module := lower_module(&result.res_ctx, &result.tc_ctx, &result.prog)
	for &fn in module.functions {
		if fn.name == "старт" {
			return module, &fn
		}
	}
	testing.fail_now(t, "функция 'старт' не найдена после lowering")
}

@(private = "file")
expect_valid :: proc(t: ^testing.T, module: ^Mir_Module, fn: ^Mir_Function) {
	issues := validate_function(module, fn)
	defer delete(issues)
	for issue in issues {
		testing.expectf(t, !issue.is_error, "validate_function: %s", issue.message)
	}
}

@(test)
test_mir_integer_literal :: proc(t: ^testing.T) {
	module, fn := lower_source(t, `
		функ старт() -> Число
			42
		конец
	`)
	expect_valid(t, &module, fn)
	dump := print_function(fn)
	testing.expectf(
		t,
		strings.contains(dump, "= const 42"),
		"ожидался 'const 42' в дампе: %s",
		dump,
	)
	testing.expectf(
		t,
		strings.contains(dump, "return v"),
		"ожидался 'return v...' в дампе: %s",
		dump,
	)
}

@(test)
test_mir_local_decl_and_read :: proc(t: ^testing.T) {
	module, fn := lower_source(
		t,
		`
		функ старт() -> Число
			пер x = 10
			x
		конец
	`,
	)
	expect_valid(t, &module, fn)
	dump := print_function(fn)
	testing.expectf(
		t,
		strings.contains(dump, "store_local local_0"),
		"ожидался store_local: %s",
		dump,
	)
	testing.expectf(
		t,
		strings.contains(dump, "load_local local_0"),
		"ожидался load_local: %s",
		dump,
	)
}

@(test)
test_mir_binary_expr :: proc(t: ^testing.T) {
	module, fn := lower_source(
		t,
		`
		функ старт() -> Число
			1 + 2 * 3
		конец
	`,
	)
	expect_valid(t, &module, fn)
	dump := print_function(fn)
	testing.expectf(
		t,
		strings.contains(dump, "binary Multiply"),
		"ожидался Multiply: %s",
		dump,
	)
	testing.expectf(t, strings.contains(dump, "binary Add"), "ожидался Add: %s", dump)
}

@(test)
test_mir_function_call :: proc(t: ^testing.T) {
	module, fn := lower_source(
		t,
		`
		функ помощник(x: Число) -> Число
			x + 1
		конец

		функ старт() -> Число
			помощник(41)
		конец
	`,
	)
	expect_valid(t, &module, fn)
	dump := print_function(fn)
	testing.expectf(t, strings.contains(dump, "fn_ref fn_"), "ожидался fn_ref: %s", dump)
	testing.expectf(t, strings.contains(dump, "call_value"), "ожидался call_value: %s", dump)
	found_helper := false
	for &f in module.functions do if f.name == "помощник" do found_helper = true
	testing.expectf(t, found_helper, "ожидалась функция 'помощник' в модуле")
}

@(test)
test_mir_return :: proc(t: ^testing.T) {
	module, fn := lower_source(
		t,
		`
		функ старт() -> Число
			возврат 5
		конец
	`,
	)
	expect_valid(t, &module, fn)
	dump := print_function(fn)
	testing.expectf(
		t,
		strings.contains(dump, "return v"),
		"ожидался return v...: %s",
		dump,
	)
	// Один явный возврат в единственном блоке — ровно 1 блок.
	testing.expect_value(t, len(fn.blocks), 1)
}

@(test)
test_mir_if_without_else_value :: proc(t: ^testing.T) {
	module, fn := lower_source(
		t,
		`
		функ старт() -> Число
			если истина тогда
				1
			конец
			0
		конец
	`,
	)
	expect_valid(t, &module, fn)
	// entry + then + else(пустой) + merge — минимум 4 блока.
	testing.expectf(
		t,
		len(fn.blocks) >= 4,
		"ожидалось >= 4 блока, получено %d",
		len(fn.blocks),
	)
}

@(test)
test_mir_if_with_else :: proc(t: ^testing.T) {
	module, fn := lower_source(
		t,
		`
		функ старт() -> Число
			если истина тогда
				1
			иначе
				2
			конец
		конец
	`,
	)
	expect_valid(t, &module, fn)
	dump := print_function(fn)
	testing.expectf(t, strings.contains(dump, "branch v"), "ожидался branch: %s", dump)
}

@(test)
test_mir_while_with_break_and_continue :: proc(t: ^testing.T) {
	module, fn := lower_source(
		t,
		`
		функ старт() -> Число
			пока истина цикл
				если истина тогда
					прервать
				конец
				продолжить
			конец
			0
		конец
	`,
	)
	expect_valid(t, &module, fn)
	dump := print_function(fn)
	testing.expectf(
		t,
		strings.contains(dump, "jump"),
		"ожидался jump (break/continue): %s",
		dump,
	)
}

@(test)
test_mir_short_circuit_and :: proc(t: ^testing.T) {
	module, fn := lower_source(
		t,
		`
		функ старт() -> Булево
			истина и ложь
		конец
	`,
	)
	expect_valid(t, &module, fn)
	dump := print_function(fn)
	testing.expectf(
		t,
		strings.contains(dump, "load_local"),
		"ожидался load_local ($logic-слияние): %s",
		dump,
	)
}

@(test)
test_mir_short_circuit_or :: proc(t: ^testing.T) {
	module, fn := lower_source(
		t,
		`
		функ старт() -> Булево
			ложь или истина
		конец
	`,
	)
	expect_valid(t, &module, fn)
}

@(test)
test_mir_nested_control_flow :: proc(t: ^testing.T) {
	module, fn := lower_source(
		t,
		`
		функ старт() -> Число
			если истина тогда
				если ложь тогда
					1
				иначе
					2
				конец
			иначе
				3
			конец
		конец
	`,
	)
	expect_valid(t, &module, fn)
}

@(test)
test_mir_assign_local :: proc(t: ^testing.T) {
	module, fn := lower_source(
		t,
		`
		функ старт() -> Число
			пер x = 0
			x = x + 1
			x
		конец
	`,
	)
	expect_valid(t, &module, fn)
	dump := print_function(fn)
	testing.expectf(t, strings.contains(dump, "store_local local_0"), "ожидался store_local: %s", dump)
}

@(test)
test_mir_assign_while_counter :: proc(t: ^testing.T) {
	module, fn := lower_source(
		t,
		`
		функ старт() -> Число
			пер i = 0
			пока i < 3 цикл
				i = i + 1
			конец
			i
		конец
	`,
	)
	expect_valid(t, &module, fn)
}

@(test)
test_mir_destructure_tuple :: proc(t: ^testing.T) {
	module, fn := lower_source(
		t,
		`
		функ старт() -> Число
			пер (a, b) = (1, 2)
			a + b
		конец
	`,
	)
	expect_valid(t, &module, fn)
	dump := print_function(fn)
	testing.expectf(t, strings.contains(dump, "get_property"), "ожидался get_property: %s", dump)
}

@(test)
test_mir_array_literal_and_get_index :: proc(t: ^testing.T) {
	module, fn := lower_source(
		t,
		`
		функ старт() -> Число
			пер значения = массив(1, 2, 3)
			значения[0]
		конец
	`,
	)
	expect_valid(t, &module, fn)
	dump := print_function(fn)
	testing.expectf(t, strings.contains(dump, "new_array"), "ожидался new_array: %s", dump)
	testing.expectf(t, strings.contains(dump, "get_index"), "ожидался get_index: %s", dump)
}

@(test)
test_mir_map_literal :: proc(t: ^testing.T) {
	module, fn := lower_source(
		t,
		`
		функ старт() -> Соответствие(Строка, Число)
			соответствие("а" = 1, "б" = 2)
		конец
	`,
	)
	expect_valid(t, &module, fn)
	dump := print_function(fn)
	testing.expectf(t, strings.contains(dump, "new_map"), "ожидался new_map: %s", dump)
}

@(test)
test_mir_for_in_fast_array :: proc(t: ^testing.T) {
	module, fn := lower_source(
		t,
		`
		функ старт() -> Число
			пер значения = массив(1, 2, 3)
			пер сумма = 0
			для x в значения цикл
				сумма = сумма + x
			конец
			сумма
		конец
	`,
	)
	expect_valid(t, &module, fn)
	dump := print_function(fn)
	testing.expectf(t, strings.contains(dump, ".длина()"), "ожидался вызов длина: %s", dump)
}

@(test)
test_mir_struct_construct_and_method_call :: proc(t: ^testing.T) {
	module, fn := lower_source(
		t,
		`
		тип Точка = структура
			x: Число
			y: Число
		конец

		реализация Точка
			функ сумма(это: Точка) -> Число
				это.x + это.y
			конец
		конец

		функ старт() -> Число
			пер p = Точка(1, 2)
			p.сумма()
		конец
	`,
	)
	expect_valid(t, &module, fn)
	dump := print_function(fn)
	testing.expectf(t, strings.contains(dump, "new_aggregate"), "ожидался new_aggregate: %s", dump)
	testing.expectf(t, strings.contains(dump, "call_value"), "ожидался call_value: %s", dump)
	found_method := false
	for &f in module.functions do if f.name == "Точка::сумма" do found_method = true
	testing.expectf(t, found_method, "ожидался метод 'Точка::сумма' в модуле")
}

@(test)
test_mir_property_read :: proc(t: ^testing.T) {
	module, fn := lower_source(
		t,
		`
		тип Точка = структура
			x: Число
			y: Число
		конец

		функ старт() -> Число
			пер p = Точка(1, 2)
			p.x
		конец
	`,
	)
	expect_valid(t, &module, fn)
	dump := print_function(fn)
	testing.expectf(t, strings.contains(dump, "get_property"), "ожидался get_property: %s", dump)
}

@(test)
test_mir_builtin_call :: proc(t: ^testing.T) {
	module, fn := lower_source(
		t,
		`
		импорт строки

		функ старт() -> Число
			строки.в_число("42").получить(0)
		конец
	`,
	)
	expect_valid(t, &module, fn)
	dump := print_function(fn)
	testing.expectf(t, strings.contains(dump, "call_builtin"), "ожидался call_builtin: %s", dump)
}

@(test)
test_mir_match_enum_adt :: proc(t: ^testing.T) {
	module, fn := lower_source(
		t,
		`
		тип Фигура = перечисление
			Круг(Число)
			Квадрат(Число)
		конец

		функ старт() -> Число
			пер ф = Фигура.Круг(5)
			выбор ф
				Фигура.Круг(r) -> r
				Фигура.Квадрат(s) -> s
			конец
		конец
	`,
	)
	expect_valid(t, &module, fn)
	dump := print_function(fn)
	testing.expectf(t, strings.contains(dump, "match_tag"), "ожидался match_tag: %s", dump)
	testing.expectf(t, strings.contains(dump, "get_variant_field"), "ожидался get_variant_field: %s", dump)
}

@(test)
test_mir_option_prelude_methods :: proc(t: ^testing.T) {
	module, fn := lower_source(
		t,
		`
		функ старт() -> Число
			пер o = Опция.Есть(42)
			o.получить(0)
		конец
	`,
	)
	expect_valid(t, &module, fn)
}

@(test)
test_mir_try_operator :: proc(t: ^testing.T) {
	module, fn := lower_source(
		t,
		`
		функ помощник() -> Результат(Число, Ошибка)
			Результат.Успех(5)
		конец

		функ старт() -> Результат(Число, Ошибка)
			пер x = помощник()?
			Результат.Успех(x + 1)
		конец
	`,
	)
	expect_valid(t, &module, fn)
	dump := print_function(fn)
	testing.expectf(t, strings.contains(dump, "try_unwrap"), "ожидался try_unwrap: %s", dump)
}

@(test)
test_mir_spawn_and_receive :: proc(t: ^testing.T) {
	module, fn := lower_source(
		t,
		`
		функ рабочий() -> Пусто
			пер отправитель: Процесс(Число) = получить()
			отправить(отправитель, 1)
		конец

		функ старт() -> Число
			пер _ = запусти рабочий()
			5
		конец
	`,
	)
	expect_valid(t, &module, fn)
	dump := print_function(fn)
	testing.expectf(t, strings.contains(dump, "= spawn v"), "ожидался spawn: %s", dump)

	found_worker := false
	for &f in module.functions {
		if f.name == "рабочий" {
			found_worker = true
			issues := validate_function(&module, &f)
			defer delete(issues)
			for issue in issues do testing.expectf(t, !issue.is_error, "рабочий: %s", issue.message)
			worker_dump := print_function(&f)
			testing.expectf(t, strings.contains(worker_dump, "= receive"), "ожидался receive: %s", worker_dump)
		}
	}
	testing.expectf(t, found_worker, "ожидалась функция 'рабочий' в модуле")
}

@(test)
test_mir_lambda_no_capture :: proc(t: ^testing.T) {
	module, fn := lower_source(
		t,
		`
		функ старт() -> Число
			пер f = функ(x: Число) -> Число
				x + 1
			конец
			f(41)
		конец
	`,
	)
	expect_valid(t, &module, fn)
	dump := print_function(fn)
	testing.expectf(t, strings.contains(dump, "fn_ref"), "ожидался fn_ref: %s", dump)
}

@(test)
test_mir_lambda_with_capture :: proc(t: ^testing.T) {
	module, fn := lower_source(
		t,
		`
		функ старт() -> Число
			пер base = 10
			пер f = функ(x: Число) -> Число
				x + base
			конец
			f(5)
		конец
	`,
	)
	expect_valid(t, &module, fn)
	dump := print_function(fn)
	testing.expectf(t, strings.contains(dump, "build_closure"), "ожидался build_closure: %s", dump)

	found_lambda := false
	for &f in module.functions {
		if strings.contains(f.name, "lambda_") {
			found_lambda = true
			issues := validate_function(&module, &f)
			defer delete(issues)
			for issue in issues do testing.expectf(t, !issue.is_error, "лямбда: %s", issue.message)
			lambda_dump := print_function(&f)
			testing.expectf(t, strings.contains(lambda_dump, "load_captured"), "ожидался load_captured: %s", lambda_dump)
		}
	}
	testing.expectf(t, found_lambda, "ожидалась функция-лямбда в модуле")
}

@(test)
test_mir_interface_cast_and_invoke :: proc(t: ^testing.T) {
	module, fn := lower_source(
		t,
		`
		тип Печатаемый = интерфейс
			функ вСтроку() -> Строка
		конец

		тип Точка = структура
			x: Число
		конец

		реализация Печатаемый для Точка
			функ вСтроку(это: Точка) -> Строка
				"точка"
			конец
		конец

		функ показать(п: Печатаемый) -> Строка
			п.вСтроку()
		конец

		функ старт() -> Строка
			показать(Точка(1))
		конец
	`,
	)
	expect_valid(t, &module, fn)
	dump := print_function(fn)
	testing.expectf(t, strings.contains(dump, "cast_interface"), "ожидался cast_interface: %s", dump)

	found_show := false
	for &f in module.functions {
		if f.name == "показать" {
			found_show = true
			issues := validate_function(&module, &f)
			defer delete(issues)
			for issue in issues do testing.expectf(t, !issue.is_error, "показать: %s", issue.message)
			show_dump := print_function(&f)
			testing.expectf(t, strings.contains(show_dump, ".вСтроку()"), "ожидался invoke_interface: %s", show_dump)
		}
	}
	testing.expectf(t, found_show, "ожидалась функция 'показать' в модуле")
}

@(test)
test_mir_for_in_iterator_protocol :: proc(t: ^testing.T) {
	module, fn := lower_source(
		t,
		`
		тип СчётчикДо = структура
			текущее: Число
			предел: Число
		конец

		реализация Итерируемое для СчётчикДо
			функ следующий(это: СчётчикДо) -> Опция(Число)
				если это.текущее >= это.предел тогда
					Опция.Нет()
				иначе
					это.текущее = это.текущее + 1
					Опция.Есть(это.текущее)
				конец
			конец
		конец

		функ старт() -> Число
			пер сч = СчётчикДо(0, 5)
			пер сумма = 0
			для x в сч цикл
				сумма = сумма + x
			конец
			сумма
		конец
	`,
	)
	expect_valid(t, &module, fn)
	dump := print_function(fn)
	testing.expectf(t, strings.contains(dump, "match_tag"), "ожидался match_tag: %s", dump)
	testing.expectf(t, strings.contains(dump, "get_variant_field"), "ожидался get_variant_field: %s", dump)
}

@(test)
test_mir_foreign_call :: proc(t: ^testing.T) {
	module, fn := lower_source(
		t,
		`
		внешний "libc" функ getpid() -> Целое(32)

		функ старт() -> Целое
			getpid()
		конец
	`,
	)
	expect_valid(t, &module, fn)
	dump := print_function(fn)
	testing.expectf(t, strings.contains(dump, "call_foreign"), "ожидался call_foreign: %s", dump)
}

// Bounded generics (`функ f[T: Интерфейс](...)`) НИКОГДА не лоурятся
// напрямую — тот же фильтр (len(type_param_bounds) > 0), что compile_
// program применяет сегодня (core/compiler.odin). Полная поддержка
// ВЫЗОВОВ bounded generic-функций требует MIR-аналога monomorphize_
// program (клонирование+резолв+тайпчек+lowering под конкретные типы,
// core/monomorphize.odin) — не реализовано в этой фазе, см. план
// (2.3k: "нет новой lowering-логики, только порядок"). Этот тест
// фиксирует ТЕКУЩЕЕ поведение: bounded generic-декларация в программе
// не ломает lowering остального модуля (просто пропускается), но её
// ВЫЗОВ пока не поддержан.
@(test)
test_mir_bounded_generic_decl_is_skipped :: proc(t: ^testing.T) {
	module, fn := lower_source(
		t,
		`
		функ макс[T: Сравниваемое](a: T, b: T) -> T
			если a.сравнить(b) > 0 тогда
				a
			иначе
				b
			конец
		конец

		функ старт() -> Число
			42
		конец
	`,
	)
	expect_valid(t, &module, fn)
	found_generic := false
	for &f in module.functions do if f.name == "макс" do found_generic = true
	testing.expectf(t, !found_generic, "bounded generic-функция НЕ должна лоуриться напрямую (шаблон)")
}

// --- Стадия 2.4: end-to-end через РЕАЛЬНЫЙ VM (не только print+validate)
// --- lower_module -> lower_module_to_bytecode -> new_vm -> 
// run_scheduler -> читаем vm.stack — тот же пайплайн, что core/pipeline.
// odin's run_source_with_args, только вместо compile_program используется
// MIR-based backend.

@(private = "file")
run_via_mir :: proc(t: ^testing.T, source: string) -> (Value, bool) {
	result := check_source(source)
	testing.expectf(t, len(result.diags) == 0, "check_source diagnostics: %v", result.diags)
	module := lower_module(&result.res_ctx, &result.tc_ctx, &result.prog)
	registry := lower_module_to_bytecode(&module)
	vm := new_vm(registry)
	run_scheduler(vm)
	if len(vm.stack) > 0 {
		return vm.stack[len(vm.stack) - 1], true
	}
	return nil, false
}

@(test)
test_bytecode_arithmetic :: proc(t: ^testing.T) {
	v, ok := run_via_mir(t, `
		функ старт() -> Число
			1 + 2 * 3
		конец
	`)
	testing.expectf(t, ok, "стек пуст")
	testing.expect_value(t, v, Value(f64(7)))
}

@(test)
test_bytecode_if_else :: proc(t: ^testing.T) {
	v, ok := run_via_mir(t, `
		функ старт() -> Число
			если 5 > 3 тогда
				1
			иначе
				2
			конец
		конец
	`)
	testing.expectf(t, ok, "стек пуст")
	testing.expect_value(t, v, Value(f64(1)))
}

@(test)
test_bytecode_while_loop :: proc(t: ^testing.T) {
	v, ok := run_via_mir(t, `
		функ старт() -> Число
			пер i = 0
			пер сумма = 0
			пока i < 10 цикл
				сумма = сумма + i
				i = i + 1
			конец
			сумма
		конец
	`)
	testing.expectf(t, ok, "стек пуст")
	testing.expect_value(t, v, Value(f64(45)))
}

@(test)
test_bytecode_function_call :: proc(t: ^testing.T) {
	v, ok := run_via_mir(t, `
		функ квадрат(x: Число) -> Число
			x * x
		конец

		функ старт() -> Число
			квадрат(7)
		конец
	`)
	testing.expectf(t, ok, "стек пуст")
	testing.expect_value(t, v, Value(f64(49)))
}

@(test)
test_bytecode_match_adt :: proc(t: ^testing.T) {
	v, ok := run_via_mir(t, `
		тип Фигура = перечисление
			Круг(Число)
			Квадрат(Число)
		конец

		функ старт() -> Число
			пер ф = Фигура.Квадрат(9)
			выбор ф
				Фигура.Круг(r) -> r
				Фигура.Квадрат(s) -> s
			конец
		конец
	`)
	testing.expectf(t, ok, "стек пуст")
	testing.expect_value(t, v, Value(f64(9)))
}

@(test)
test_bytecode_match_adt_hot_loop :: proc(t: ^testing.T) {
	// Регрессия: Match_Tag peek-без-снятия (core/vm.odin) не должен
	// накапливать мусор на стеке между попытками армов — см. докстринг
	// в начале core/mir/bytecode.odin. Много итераций, худший случай
	// (последний арм из трёх, т.е. 2 неудачные попытки на итерацию).
	v, ok := run_via_mir(t, `
		тип Фигура = перечисление
			Круг(Число)
			Квадрат(Число)
			Треугольник(Число)
		конец

		функ классифицировать(ф: Фигура) -> Число
			выбор ф
				Фигура.Круг(r) -> r
				Фигура.Квадрат(s) -> s
				Фигура.Треугольник(t) -> t
			конец
		конец

		функ старт() -> Число
			пер сумма = 0
			пер i = 0
			пока i < 50000 цикл
				сумма = сумма + классифицировать(Фигура.Треугольник(1))
				i = i + 1
			конец
			сумма
		конец
	`)
	testing.expectf(t, ok, "стек пуст")
	testing.expect_value(t, v, Value(f64(50000)))
}

@(test)
test_bytecode_closure_with_capture :: proc(t: ^testing.T) {
	v, ok := run_via_mir(t, `
		функ старт() -> Число
			пер base = 10
			пер f = функ(x: Число) -> Число
				x + base
			конец
			f(5)
		конец
	`)
	testing.expectf(t, ok, "стек пуст")
	testing.expect_value(t, v, Value(f64(15)))
}

@(test)
test_bytecode_interface_dispatch :: proc(t: ^testing.T) {
	v, ok := run_via_mir(t, `
		тип Печатаемый = интерфейс
			функ вСтроку() -> Строка
		конец

		тип Точка = структура
			x: Число
		конец

		реализация Печатаемый для Точка
			функ вСтроку(это: Точка) -> Строка
				"точка"
			конец
		конец

		функ показать(п: Печатаемый) -> Строка
			п.вСтроку()
		конец

		функ старт() -> Строка
			показать(Точка(1))
		конец
	`)
	testing.expectf(t, ok, "стек пуст")
	str, is_str := v.(^Panos_String)
	testing.expectf(t, is_str, "ожидалась строка, получено %v", v)
	if is_str do testing.expect_value(t, str.data, "точка")
}

@(test)
test_bytecode_for_in_array :: proc(t: ^testing.T) {
	v, ok := run_via_mir(t, `
		функ старт() -> Число
			пер значения = массив(1, 2, 3, 4, 5)
			пер сумма = 0
			для x в значения цикл
				сумма = сумма + x
			конец
			сумма
		конец
	`)
	testing.expectf(t, ok, "стек пуст")
	testing.expect_value(t, v, Value(f64(15)))
}

@(test)
test_bytecode_option_prelude_methods :: proc(t: ^testing.T) {
	v, ok := run_via_mir(t, `
		функ старт() -> Число
			пер o = Опция.Есть(42)
			o.получить(0)
		конец
	`)
	testing.expectf(t, ok, "стек пуст")
	testing.expect_value(t, v, Value(f64(42)))
}

// Bounded generics (lower_monomorphize_program, mir_monomorphize.odin) —
// зеркало test_bounded_generic_max_works_with_primitive_and_struct
// (core/e2e_types_interfaces_test.odin), но через MIR-бэкенд: ОДНО и то
// же generic-тело вызывается с Число (нативный `>` хардкод) И со
// структурой (Сравниваемое.сравнить sugar) — должны лоуриться в ДВЕ
// разные Mir_Function под разными ключами и давать корректный результат
// независимо.
@(test)
test_bytecode_bounded_generic_max :: proc(t: ^testing.T) {
	v, ok := run_via_mir(t, `
		тип Точка = структура
			x: Число
		конец

		реализация Сравниваемое для Точка
			функ сравнить(это: Точка, другое: Точка) -> Число
				это.x - другое.x
			конец
		конец

		функ max[T: Сравниваемое](a: T, b: T) -> T
			если a > b тогда a иначе b конец
		конец

		функ старт() -> Булево
			пер число_результат = max(3.0, 7.0)
			пер п1 = Точка(1)
			пер п2 = Точка(2)
			пер структ_результат = max(п1, п2)
			число_результат == 7.0 и структ_результат.x == 2
		конец
	`)
	testing.expectf(t, ok, "стек пуст")
	b, is_bool := v.(bool)
	testing.expectf(t, is_bool && b, "ожидалось true, получено %v", v)
}
