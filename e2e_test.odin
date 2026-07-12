package main

import "core:testing"

// typecheck_program больше не panic'ует на первой ошибке — копит в
// ctx.diagnostics (см. report() в type_cheker.odin). run_file в main.odin
// печатает их все и выходит до компиляции; здесь — тот же гейт, но вместо
// печати panic'уем с текстом ПЕРВОГО diagnostic'а. Это сохраняет поведение
// старых `testing.expect_assert(t, "Type Error: ...")` тестов без
// переписывания: они по-прежнему ловят ровно один panic с тем же
// сообщением, что было бы у fmt.panicf раньше. Тесты, которые хотят
// проверить накопление НЕСКОЛЬКИХ ошибок разом, используют expect_diagnostic
// ниже вместо этого моста.
panic_on_diagnostics :: proc(ctx: ^Type_Ctx) {
	if len(ctx.diagnostics) > 0 {
		panic(ctx.diagnostics[0].message)
	}
}

// Вспомогательная функция, которая прогоняет весь пайплайн и возвращает результат
run_code_with_args :: proc(source: string, program_args: []string = nil) -> (Value, bool) {
	// 1. Лексика и Парсинг
	tokens := tokenize(source) // Ваша функция лексера
	stream := make_stream(tokens)
	parser := Parser {
		stream = &stream,
	}
	prog := parse_program(&parser)

	// 2. Резолв и Типизация
	res_ctx := new_resolver_ctx()
	resolve_program(&res_ctx, prog)

	type_ctx := new_type_ctx(&res_ctx)
	typecheck_program(&type_ctx, prog)
	panic_on_diagnostics(&type_ctx)

	// 3. Компиляция
	registry := compile_program(&res_ctx, &type_ctx, &prog)

	// 4. Выполнение (VM)
	vm := new_vm(registry, program_args)
	execute(vm)

	// Возвращаем результат (то, что осталось на вершине стека)
	if len(vm.stack) > 0 {
		return vm.stack[len(vm.stack) - 1], true
	}
	return 0.0, false
}

run_code :: proc(source: string) -> (Value, bool) {
	return run_code_with_args(source)
}

run_module_file :: proc(filename: string) -> (Value, bool) {
	graph := load_module_graph(filename)
	registry := make(map[string]^Compiled_Function)

	for module in graph.order {
		res_ctx := resolve_module(&graph, module)
		type_ctx := new_type_ctx(&res_ctx)
		typecheck_program(&type_ctx, module.ast)
		panic_on_diagnostics(&type_ctx)
		compile_program(&res_ctx, &type_ctx, &module.ast, &registry)
		graph.symbol_types = res_ctx.symbol_types
	}

	vm := new_vm(registry)
	execute(vm)

	if len(vm.stack) > 0 {
		return vm.stack[len(vm.stack) - 1], true
	}
	return 0.0, false
}

// Прогоняет только парсинг+резолв+типизацию (без компиляции/исполнения) и
// возвращает накопленные diagnostic'и — для тестов, которые хотят увидеть
// ВСЕ ошибки разом, а не только первую (в отличие от run_code, который
// через panic_on_diagnostics останавливается на первой).
typecheck_only :: proc(source: string) -> [dynamic]Diagnostic {
	tokens := tokenize(source)
	stream := make_stream(tokens)
	parser := Parser {
		stream = &stream,
	}
	prog := parse_program(&parser)

	res_ctx := new_resolver_ctx()
	resolve_program(&res_ctx, prog)

	type_ctx := new_type_ctx(&res_ctx)
	typecheck_program(&type_ctx, prog)
	return type_ctx.diagnostics
}

// expect_diagnostic проверяет, что среди накопленных ошибок есть хотя бы
// одна с точным текстом expected — в отличие от testing.expect_assert
// (которая ловит panic), здесь программа НЕ падает, поэтому можно
// проверить сразу несколько независимых ошибок в одном source.
expect_diagnostic :: proc(t: ^testing.T, diagnostics: [dynamic]Diagnostic, expected: string, loc := #caller_location) {
	for d in diagnostics {
		if d.message == expected do return
	}
	testing.expectf(t, false, "diagnostic not found: %q (got %d diagnostics)", expected, len(diagnostics), loc = loc)
}

@(test)
test_explicit_panic :: proc(t: ^testing.T) {
	testing.expect_assert(t, "Runtime Panic: критичный сбой")
	run_code(`
		функ старт() -> Число
			паника("критичный сбой")
		конец
	`)
}

@(test)
test_option_expect_panics_on_empty :: proc(t: ^testing.T) {
	testing.expect_assert(t, "Runtime Panic: нет значения")
	run_code(`
		функ старт() -> Число
			пер о: Опция(Число) = Нет()
			о.ожидать("нет значения")
		конец
	`)
}

@(test)
test_result_expect_panics_on_error :: proc(t: ^testing.T) {
	testing.expect_assert(t, "Runtime Panic: не удалось: нет файла")
	run_code(`
		функ старт() -> Число
			пер р: Результат(Число, Ошибка) = Неудача(Ошибка("фс", "нет файла"))
			р.ожидать("не удалось")
		конец
	`)
}

@(test)
test_result_expect_error_panics_on_success :: proc(t: ^testing.T) {
	testing.expect_assert(t, "Runtime Panic: ожидалась ошибка")
	run_code(`
		функ старт() -> Ошибка
			пер р: Результат(Число, Ошибка) = Успех(42)
			р.ожидать_ошибку("ожидалась ошибка")
		конец
	`)
}

@(test)
test_strict_index_panics_out_of_bounds :: proc(t: ^testing.T) {
	testing.expect_assert(t, "Runtime Error: индекс 1 выходит за границы массива")
	run_code(`
		функ старт() -> Число
			пер числа = массив(10)
			числа[1]
		конец
	`)
}

@(test)
test_continue_outside_loop_is_type_error :: proc(t: ^testing.T) {
	testing.expect_assert(t, "Type Error: 'продолжить' можно использовать только внутри цикла")
	run_code(`
		функ старт() -> Число
			продолжить
			1
		конец
	`)
}

@(test)
test_break_outside_loop_is_type_error :: proc(t: ^testing.T) {
	testing.expect_assert(t, "Type Error: 'прервать' можно использовать только внутри цикла")
	run_code(`
		функ старт() -> Число
			прервать
			1
		конец
	`)
}

@(test)
test_math_and_logic :: proc(t: ^testing.T) {
	TestCase :: struct {
		name:     string,
		source:   string,
		expected: Value,
	}

	tests := []TestCase {
		{
			"Простая математика",
			"функ старт() -> Число  10 + 20 конец",
			f64(30.0),
		},
		{
			"Унарный минус",
			"функ старт() -> Число  -5 конец",
			f64(-5.0),
		},
		{"Логика", "функ старт() -> Булево истина конец", true},
		{
			"Сложный if",
			`
			функ старт() -> Число
				пер х = если истина тогда 10 иначе 20 конец
				х + 5
		    конец
		`,
			f64(15.0),
		},
		{
			"Вызов функции",
			`
			функ удвоить(х: Число) -> Число  х * 2 конец
			функ старт() -> Число  удвоить(10) конец
		`,
			f64(20.0),
		},
		{
			"Конкатенация строк",
			`
			функ старт() -> Строка
				пер имя = "pan"
				имя + "os" + "!"
			конец
		`,
			"panos!",
		},
		{
			"Строки: escape-последовательности",
			`
			функ старт() -> Строка
				"a\n\tb\rc\"d\\e"
			конец
		`,
			"a\n\tb\rc\"d\\e",
		},
		{
			"Длина строк и коллекций",
			`
			функ старт() -> Число
				пер числа = массив(1, 2, 3)
				пер цены = соответствие("яблоко" = 10, "груша" = 20)
				длина("привет") + длина(числа) + длина(цены)
			конец
		`,
			f64(11.0),
		},
		{
			"Массивы: индекс, запись и методы",
			`
			функ старт() -> Число
				пер числа: Массив(Число) = массив()
				числа.добавить(1)
				числа.добавить(2)
				числа[1] = 10
				числа[0] + числа[1] + числа.длина() + числа.получить(5, 7)
			конец
		`,
			f64(20.0),
		},
		{
			"Массивы: проверки наличия",
			`
			функ старт() -> Булево
				пер числа = массив(3, 4)
				числа.есть(1)
			конец
		`,
			true,
		},
		{
			"Цикл: продолжить",
			`
			функ старт() -> Число
				пер i = 0
				пер сумма = 0
				пока i < 5 цикл
					i = i + 1
					если i == 3 тогда
						продолжить
					конец
					сумма = сумма + i
				конец
				сумма
			конец
		`,
			f64(12.0),
		},
		{
			"Цикл: прервать",
			`
			функ старт() -> Число
				пер i = 0
				пер сумма = 0
				пока i < 10 цикл
					i = i + 1
					если i > 3 тогда
						прервать
					конец
					сумма = сумма + i
				конец
				сумма
			конец
		`,
			f64(6.0),
		},
		{
			"Соответствие: литерал, индекс и методы",
			`
			функ старт() -> Число
				пер цены = соответствие(
					"яблоко" = 10,
					"груша" = 20,
				)
				цены["банан"] = 5
				если цены.есть("банан") тогда
					цены["яблоко"] + цены.получить("банан", 0) + цены.длина()
				иначе
					0
				конец
			конец
		`,
			f64(18.0),
		},
		{
			"Соответствие: удаление",
			`
			функ старт() -> Число
				пер цены = соответствие("яблоко" = 10, "груша" = 20)
				пер удалено = цены.удалить("груша")
				если удалено тогда цены.длина() иначе 0 конец
			конец
		`,
			f64(1.0),
		},
		{
			"Лямбда: вывод параметров и возврата из тела",
			`
			функ старт() -> Число
				пер удвоить = функ(х)
					х * 2
				конец
				удвоить(7)
			конец
		`,
			f64(14.0),
		},
		{
			"Лямбда: вывод из аннотации переменной",
			`
			функ старт() -> Число
				пер длина: функ(Строка) -> Число = функ(текст)
					42
				конец
				длина("panos")
			конец
		`,
			f64(42.0),
		},
		{
			"Лямбда: вывод из типа параметра функции",
			`
			функ применить(ф: функ(Число) -> Число, значение: Число) -> Число
				ф(значение)
			конец

			функ старт() -> Число
				применить(функ(х)
					х + 3
				конец, 9)
			конец
		`,
			f64(12.0),
		},
		{
			"Результат: успех",
			`
			функ старт() -> Число
				пер р: Результат(Число, Ошибка) = Успех(41)
				если р.успех() тогда р.значение() + 1 иначе 0 конец
			конец
		`,
			f64(42.0),
		},
		{
			"Результат: ошибка и причина",
			`
			функ старт() -> Строка
				пер р: Результат(Число, Ошибка) = Неудача(Ошибка("фс", "нет файла"))
				если р.ошибка() тогда р.причина().сообщение иначе "" конец
			конец
		`,
			"нет файла",
		},
		{
			"Результат: оператор ? разворачивает успех",
			`
			функ добавить_один() -> Результат(Число, Ошибка)
				пер р: Результат(Число, Ошибка) = Успех(41)
				Успех(р? + 1)
			конец

			функ старт() -> Число
				добавить_один().получить(0)
			конец
		`,
			f64(42.0),
		},
		{
			"Результат: оператор ? возвращает ошибку",
			`
			функ получить() -> Результат(Число, Ошибка)
				Неудача(Ошибка("фс", "нет файла"))
			конец

			функ пробросить() -> Результат(Число, Ошибка)
				Успех(получить()? + 1)
			конец

			функ старт() -> Строка
				пер р = пробросить()
				если р.ошибка() тогда р.причина().сообщение иначе "" конец
			конец
		`,
			"нет файла",
		},
		{
			"Результат: получить ошибку из успеха возвращает умолчание",
			`
			функ старт() -> Строка
				пер р: Результат(Число, Ошибка) = Успех(42)
				р.получить_ошибку(Ошибка("нет", "нет ошибки")).сообщение
			конец
		`,
			"нет ошибки",
		},
		{
			"Результат: получить ошибку из неудачи",
			`
			функ старт() -> Строка
				пер р: Результат(Число, Ошибка) = Неудача(Ошибка("фс", "нет файла"))
				р.получить_ошибку(Ошибка("нет", "нет ошибки")).сообщение
			конец
		`,
			"нет файла",
		},
		{
			"Результат: ожидать возвращает успех",
			`
			функ старт() -> Число
				пер р: Результат(Число, Ошибка) = Успех(42)
				р.ожидать("должен быть успех")
			конец
		`,
			f64(42.0),
		},
		{
			"Результат: ожидать ошибку возвращает причину",
			`
			функ старт() -> Строка
				пер р: Результат(Число, Ошибка) = Неудача(Ошибка("фс", "нет файла"))
				р.ожидать_ошибку("должна быть ошибка").сообщение
			конец
		`,
			"нет файла",
		},
		{
			"Результат: успех в опцию",
			`
			функ старт() -> Число
				пер р: Результат(Число, Ошибка) = Успех(42)
				р.опция().получить(0)
			конец
		`,
			f64(42.0),
		},
		{
			"Результат: ошибка в пустую опцию",
			`
			функ старт() -> Число
				пер р: Результат(Число, Ошибка) = Неудача(Ошибка("фс", "нет файла"))
				р.опция().получить(42)
			конец
		`,
			f64(42.0),
		},
		{
			"Результат: успех в пустую опцию ошибки",
			`
			функ старт() -> Строка
				пер р: Результат(Число, Ошибка) = Успех(42)
				р.ошибка_опция().получить(Ошибка("нет", "нет ошибки")).сообщение
			конец
		`,
			"нет ошибки",
		},
		{
			"Результат: ошибка в опцию ошибки",
			`
			функ старт() -> Строка
				пер р: Результат(Число, Ошибка) = Неудача(Ошибка("фс", "нет файла"))
				р.ошибка_опция().получить(Ошибка("нет", "нет ошибки")).сообщение
			конец
		`,
			"нет файла",
		},
		{
			"Результат: заменить ошибку сохраняет успех",
			`
			функ старт() -> Число
				пер р: Результат(Число, Ошибка) = Успех(42)
				р.заменить_ошибку(Ошибка("новая", "не важно")).получить(0)
			конец
		`,
			f64(42.0),
		},
		{
			"Результат: заменить ошибку меняет причину",
			`
			функ старт() -> Строка
				пер р: Результат(Число, Ошибка) = Неудача(Ошибка("старая", "старое"))
				пер новый = р.заменить_ошибку(Ошибка("новая", "новое"))
				если новый.ошибка() тогда новый.причина().сообщение иначе "" конец
			конец
		`,
			"новое",
		},
		{
			"Результат: заменить значение меняет успех",
			`
			функ старт() -> Строка
				пер р: Результат(Число, Ошибка) = Успех(42)
				р.заменить_значение("готово").получить("нет")
			конец
		`,
			"готово",
		},
		{
			"Результат: заменить значение сохраняет ошибку",
			`
			функ старт() -> Строка
				пер р: Результат(Число, Ошибка) = Неудача(Ошибка("старая", "старое"))
				пер новый = р.заменить_значение("готово")
				если новый.ошибка() тогда новый.причина().сообщение иначе "" конец
			конец
		`,
			"старое",
		},
		{
			"Результат: запас сохраняет успех",
			`
			функ старт() -> Число
				пер р: Результат(Число, Ошибка) = Успех(42)
				р.запас(Успех(7)).получить(0)
			конец
		`,
			f64(42.0),
		},
		{
			"Результат: запас возвращает запасной результат",
			`
			функ старт() -> Число
				пер р: Результат(Число, Ошибка) = Неудача(Ошибка("нет", "нет значения"))
				р.запас(Успех(42)).получить(0)
			конец
		`,
			f64(42.0),
		},
		{
			"Опция: значение по умолчанию",
			`
			функ старт() -> Число
				пер о: Опция(Число) = Нет()
				о.получить(42)
			конец
		`,
			f64(42.0),
		},
		{
			"Паника: ветка имеет тип Никогда",
			`
			функ старт() -> Число
				если истина тогда 42 иначе паника("невозможно") конец
			конец
		`,
			f64(42.0),
		},
		{
			"Опция: есть значение",
			`
			функ старт() -> Число
				пер о = Есть(10)
				если о.есть() тогда о.значение() иначе 0 конец
			конец
		`,
			f64(10.0),
		},
		{
			"Опция: оператор ? разворачивает значение",
			`
			функ добавить_один() -> Опция(Число)
				пер о: Опция(Число) = Есть(41)
				Есть(о? + 1)
			конец

			функ старт() -> Число
				добавить_один().получить(0)
			конец
		`,
			f64(42.0),
		},
		{
			"Опция: оператор ? возвращает Нет",
			`
			функ получить() -> Опция(Число)
				Нет()
			конец

			функ пробросить() -> Опция(Число)
				Есть(получить()? + 1)
			конец

			функ старт() -> Число
				пробросить().получить(42)
			конец
		`,
			f64(42.0),
		},
		{
			"Опция: ожидать возвращает значение",
			`
			функ старт() -> Число
				пер о: Опция(Число) = Есть(42)
				о.ожидать("должно быть значение")
			конец
		`,
			f64(42.0),
		},
		{
			"Опция: заменить значение меняет значение",
			`
			функ старт() -> Строка
				пер о: Опция(Число) = Есть(42)
				о.заменить_значение("готово").получить("нет")
			конец
		`,
			"готово",
		},
		{
			"Опция: заменить значение сохраняет пусто",
			`
			функ старт() -> Строка
				пер о: Опция(Число) = Нет()
				о.заменить_значение("готово").получить("нет")
			конец
		`,
			"нет",
		},
		{
			"Опция: запас сохраняет значение",
			`
			функ старт() -> Число
				пер о: Опция(Число) = Есть(42)
				о.запас(Есть(7)).получить(0)
			конец
		`,
			f64(42.0),
		},
		{
			"Опция: запас возвращает запасную опцию",
			`
			функ старт() -> Число
				пер о: Опция(Число) = Нет()
				о.запас(Есть(42)).получить(0)
			конец
		`,
			f64(42.0),
		},
		{
			"Опция: значение в результат",
			`
			функ старт() -> Число
				пер о: Опция(Число) = Есть(42)
				о.результат_или(Ошибка("опция", "пусто")).получить(0)
			конец
		`,
			f64(42.0),
		},
		{
			"Опция: пусто в ошибочный результат",
			`
			функ старт() -> Строка
				пер о: Опция(Число) = Нет()
				пер р = о.результат_или(Ошибка("опция", "пусто"))
				если р.ошибка() тогда р.причина().сообщение иначе "" конец
			конец
		`,
			"пусто",
		},
		{
			"Стандартная библиотека: файловая система",
			`
			импорт фс

			функ старт() -> Строка
				пер путь = "/tmp/panos_stdlib_e2e.txt"
				пер запись = фс.записать(путь, "panos")
				если запись.успех() тогда
					если фс.есть(путь) тогда
						фс.прочитать(путь).получить("ошибка")
					иначе
						"нет файла"
					конец
				иначе
					запись.причина().сообщение
				конец
			конец
		`,
			"panos",
		},
		{
			"Стандартная библиотека: вывод",
			`
			импорт ввод_вывод

			функ старт() -> Число
				ввод_вывод.печать("panos")
				ввод_вывод.строка("")
				42
			конец
		`,
			f64(42.0),
		},
	}

	for tc in tests {
		result, ok := run_code(tc.source)
		testing.expectf(
			t,
			ok,
			"[%s] ПРОВАЛ: Стек пуст, нет результата",
			tc.name,
		)

		if !ok do continue

		testing.expectf(
			t,
			result == tc.expected,
			"[%s] ПРОВАЛ: Ожидалось %v, получено %v",
			tc.name,
			tc.expected,
			result,
		)
	}

	args_result, args_ok := run_code_with_args(
		`
		импорт ос

		функ старт() -> Строка
			пер аргументы = ос.аргументы()
			аргументы[1]
		конец
	`,
		[]string{"альфа", "бета"},
	)
	testing.expectf(
		t,
		args_ok,
		"[Стандартная библиотека: аргументы] стек пуст",
	)
	if args_ok {
		testing.expectf(
			t,
			args_result == "бета",
			"[Стандартная библиотека: аргументы] ожидалось бета, получено %v",
			args_result,
		)
	}

	env_result, env_ok := run_code(
		`
		импорт ос

		функ старт() -> Строка
			пер запись = ос.установить_окружение("PANOS_E2E_ENV", "значение")
			если запись.успех() тогда
				ос.окружение("PANOS_E2E_ENV").получить("нет")
			иначе
				запись.причина().сообщение
			конец
		конец
	`,
	)
	testing.expectf(
		t,
		env_ok,
		"[Стандартная библиотека: окружение] стек пуст",
	)
	if env_ok {
		testing.expectf(
			t,
			env_result == "значение",
			"[Стандартная библиотека: окружение] ожидалось значение, получено %v",
			env_result,
		)
	}
}

@(test)
test_modules :: proc(t: ^testing.T) {
	result, ok := run_module_file("module_fixture_main.ps")
	testing.expectf(t, ok, "Модули: стек пуст, нет результата")
	if !ok do return

	testing.expectf(
		t,
		result == f64(42.0),
		"Модули: ожидалось 42, получено %v",
		result,
	)

	stdlib_result, stdlib_ok := run_module_file("stdlib_fixture_main.ps")
	testing.expectf(
		t,
		stdlib_ok,
		"Файловая stdlib: стек пуст, нет результата",
	)
	if !stdlib_ok do return

	testing.expectf(
		t,
		stdlib_result == f64(42.0),
		"Файловая stdlib: ожидалось 42, получено %v",
		stdlib_result,
	)
}

@(test)
test_adt_cross_module_qualified_use :: proc(t: ^testing.T) {
	result, ok := run_module_file("adt_fixture_main.ps")
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
	result, ok := run_module_file("adt_fixture_short.ps")
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
	run_module_file("adt_fixture_private_use.ps")
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
				Прямоугольник(ш, в) -> ш * в
			конец
		конец
		функ старт() -> Число
			возврат площадь(Точка)
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
				Прямоугольник(ш, в) -> ш * в
			конец
		конец
		функ старт() -> Число
			возврат площадь(Прямоугольник(4, 5))
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
			пер зн: Ф = Б(7)
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
			пер ф: Фигура = Круг(3)
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
			пер д: Дерево = Узел(5)
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
			пер с: Событие = А
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
			пер зн: Ф = А
			возврат выбор зн
				_ -> 42
				Б -> 1
			конец
		конец
	`)
}

has_latin_word :: proc(msg: string) -> bool {
	// Разрешённые английские префиксы диагностики (соглашение проекта).
	body := msg
	prefixes := [?]string {
		"Type Error:",
		"Runtime Error:",
		"Runtime Panic:",
		"Semantic Error:",
		"Syntactic Error:",
		"Compiler Error:",
		"Resolve Error:",
		"Синтаксическая ошибка:",
	}
	for prefix in prefixes {
		if len(body) >= len(prefix) && body[:len(prefix)] == prefix {
			body = body[len(prefix):]
			break
		}
	}
	// Ищем последовательность из ≥3 ASCII-латинских букв в теле сообщения.
	streak := 0
	for r in body {
		is_latin := (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z')
		if is_latin {
			streak += 1
			if streak >= 3 do return true
		} else {
			streak = 0
		}
	}
	return false
}

@(test)
test_diagnostics_have_no_latin_words :: proc(t: ^testing.T) {
	messages := [?]string {
		"Type Error: у варианта 'Фигура.Круг' поле #0 ожидает 'Число', получено 'Строка'",
		"Синтаксическая ошибка: вариант 'Круг' объявлен дважды в 'Фигура'",
		"Resolve Error: у типа 'Фигура' нет варианта 'Ромб'",
		"Resolve Error: имя варианта 'Точка' конфликтует с уже объявленным символом в модуле",
		"Resolve Error: модуль 'ф' не экспортирует 'Круг'",
		"Type Error: выбор не покрывает варианты: Точка",
		"Type Error: выбор не покрывает варианты: Лист",
		"Type Error: выбор не покрывает варианты: Г",
		"Type Error: '_' в выборе должен быть только последней веткой",
		"Type Error: вариант 'Ф.А' покрыт повторно в ветке #2",
		"Type Error: выбор не покрывает варианты: Нет",
	}
	for msg, i in messages {
		testing.expectf(
			t,
			!has_latin_word(msg),
			"сообщение #%d содержит латинское слово: %s",
			i,
			msg,
		)
	}
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
			возврат индекс(V13)
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
			пер зн: Ф = Б
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
				Успех(Круг(рад)) -> рад
				_ -> 0
			конец
		конец
		функ старт() -> Число
			возврат разбор(Успех(Круг(7)))
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
				Успех(Круг(рад)) -> рад
				_ -> 99
			конец
		конец
		функ старт() -> Число
			возврат разбор(Успех(Точка))
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
			пер о: Опция(Число) = Есть(41)
			возврат выбор о
				Есть(х) -> х + 1
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
			пер о: Опция(Число) = Нет()
			возврат выбор о
				Есть(х) -> х + 1
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
			пер р: Результат(Строка, Ошибка) = Успех("ок")
			возврат выбор р
				Успех(з) -> з
				Неудача(о) -> "плохо"
			конец
		конец
	`)
	testing.expectf(t, ok, "res match: пустой стек")
	if !ok do return
	s, is_str := result.(string)
	testing.expectf(t, is_str && s == "ок", "res match: %v != ок", result)
}

@(test)
test_match_option_non_exhaustive_rejected :: proc(t: ^testing.T) {
	testing.expect_assert(t, "Type Error: выбор не покрывает варианты: Нет")
	run_code(`
		функ старт() -> Число
			пер о: Опция(Число) = Есть(5)
			возврат выбор о
				Есть(х) -> х
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
			пер зн: Ф = А
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
			пер зн: Ф = Б(7)
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
		    возврат Точка
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
		    возврат Круг(3)
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
		    возврат Прямоугольник(4, 5)
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
		    возврат Круг("три")
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
