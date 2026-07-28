#+build !js
package core

// Стадия 2.5 (план): дифференциальное тестирование — гоняем ОДИН И ТОТ
// ЖЕ исходник через СТАРЫЙ путь (compile_program, прямой обход
// AST) и НОВЫЙ путь (lower_module + lower_module_to_bytecode), сравниваем
// финальный результат через value_to_display_string (core/vm.odin —
// сравнение по СТРОКОВОМУ представлению, не по указателю: два независимых
// прогона строят СВОИ heap-объекты, поэтому raw pointer-equality всегда
// ложно различалась бы). НЕ пытается сравнивать байткод байт-в-байт —
// план явно этого не требует ("поведение должно совпадать, кодирование —
// не обязательно").
//
// MIR раньше жило в отдельном Odin-пакете (core/mir, package mir,
// однонаправленно импортировавшем core) — слито в package core, чтобы
// compile_program мог со временем звать lower_module/
// lower_module_to_bytecode напрямую (циклический импорт между core и
// mir делал это невозможным). Реальное переключение default-бэкенда —
// всё ещё отдельная, не начатая задача.

import "core:strings"
import "core:testing"

@(private = "file")
Diff_Result :: struct {
	ok:      bool,
	display: string,
}

@(private = "file")
run_old_path :: proc(source: string) -> Diff_Result {
	result := check_source(source)
	if len(result.diags) > 0 do return Diff_Result{ok = false}

	registry := make(map[string]^Compiled_Function)
	ensure_prelude_compiled(&result.res_ctx, &registry)
	compile_program(&result.res_ctx, &result.tc_ctx, &result.prog, &registry)

	vm := new_vm(registry)
	run_scheduler(vm)
	if len(vm.stack) == 0 do return Diff_Result{ok = false}
	return Diff_Result{ok = true, display = value_to_display_string(vm, vm.stack[len(vm.stack) - 1])}
}

@(private = "file")
run_new_path :: proc(source: string) -> Diff_Result {
	result := check_source(source)
	if len(result.diags) > 0 do return Diff_Result{ok = false}

	module := lower_module(&result.res_ctx, &result.tc_ctx, &result.prog)
	registry := lower_module_to_bytecode(&module)

	vm := new_vm(registry)
	run_scheduler(vm)
	if len(vm.stack) == 0 do return Diff_Result{ok = false}
	return Diff_Result{ok = true, display = value_to_display_string(vm, vm.stack[len(vm.stack) - 1])}
}

// diff_check — прогоняет source через оба пути, требует, чтобы оба
// успешно вернули значение И строковые представления совпали.
@(private = "file")
diff_check :: proc(t: ^testing.T, source: string) {
	old := run_old_path(source)
	new := run_new_path(source)
	testing.expectf(t, old.ok, "СТАРЫЙ путь не вернул значение (пустой стек) для:\n%s", source)
	testing.expectf(t, new.ok, "НОВЫЙ (MIR) путь не вернул значение (пустой стек) для:\n%s", source)
	if old.ok && new.ok {
		testing.expectf(
			t,
			old.display == new.display,
			"РАСХОЖДЕНИЕ: старый=%q, новый(MIR)=%q, источник:\n%s",
			old.display,
			new.display,
			source,
		)
	}
}

// --- Многомодульный корпус (реальные fixtures/*.ps, файловые `импорт`ы,
// module_loader.odin's Module_Graph) — та же пара путей, что выше, но
// через load_module_graph+resolve_and_typecheck_all вместо check_source,
// и lower_program_graph (mir_module_graph.odin) вместо lower_module.
// Зеркалит run_module_file (core/e2e_test.odin) для старого пути.

@(private = "file")
run_old_path_module_file :: proc(filename: string) -> Diff_Result {
	graph := load_module_graph(filename)
	if len(graph.parse_diagnostics) > 0 do return Diff_Result{ok = false}
	results := resolve_and_typecheck_all(&graph)
	for r in results {
		if len(r.res_ctx.diagnostics) > 0 || len(r.tc_ctx.diagnostics) > 0 do return Diff_Result{ok = false}
	}

	registry := make(map[string]^Compiled_Function)
	if len(results) > 0 {
		ensure_prelude_compiled(&results[0].res_ctx, &registry)
	}
	for i in 0 ..< len(results) {
		r := &results[i]
		compile_program(&r.res_ctx, &r.tc_ctx, &r.module.ast, &registry)
	}

	vm := new_vm(registry)
	run_scheduler(vm)
	if len(vm.stack) == 0 do return Diff_Result{ok = false}
	return Diff_Result{ok = true, display = value_to_display_string(vm, vm.stack[len(vm.stack) - 1])}
}

@(private = "file")
run_new_path_module_file :: proc(filename: string) -> Diff_Result {
	graph := load_module_graph(filename)
	if len(graph.parse_diagnostics) > 0 do return Diff_Result{ok = false}
	results := resolve_and_typecheck_all(&graph)
	for r in results {
		if len(r.res_ctx.diagnostics) > 0 || len(r.tc_ctx.diagnostics) > 0 do return Diff_Result{ok = false}
	}

	module := lower_program_graph(results)
	registry := lower_module_to_bytecode(&module)

	vm := new_vm(registry)
	run_scheduler(vm)
	if len(vm.stack) == 0 do return Diff_Result{ok = false}
	return Diff_Result{ok = true, display = value_to_display_string(vm, vm.stack[len(vm.stack) - 1])}
}

@(private = "file")
diff_check_module_file :: proc(t: ^testing.T, filename: string) {
	old := run_old_path_module_file(filename)
	new := run_new_path_module_file(filename)
	testing.expectf(t, old.ok, "СТАРЫЙ путь не вернул значение (пустой стек) для %s", filename)
	testing.expectf(t, new.ok, "НОВЫЙ (MIR) путь не вернул значение (пустой стек) для %s", filename)
	if old.ok && new.ok {
		testing.expectf(
			t,
			old.display == new.display,
			"РАСХОЖДЕНИЕ на %s: старый=%q, новый(MIR)=%q",
			filename,
			old.display,
			new.display,
		)
	}
}

// Курируемое подмножество fixtures/*.ps (не весь каталог — см. ниже) —
// реальные многофайловые программы, гоняемые через ОБА пути. Исключены:
// (1) fixtures БЕЗ функ старт() (библиотеки, импортируются, не
// запускаются напрямую); (2) заведомо-негативные fixtures (typecheck/
// resolve diagnostics — qualified_generic_fixture_main_{not_exported,
// wrong_arity}, module_fixture_missing_import_main, spawn_qualified_
// bad_{module,type}_fixture_main, spawn_qualified_not_function_fixture_
// main, adt_fixture_private_use, const_fixture_main_private) — они
// тестируют diagnostics ДО бэкенда, обоим путям тут нечего сравнивать;
// (3) random_fixture_main (время.сейчас_мс()-seed — недетерминированно
// МЕЖДУ двумя прогонами, ложное расхождение, не баг бэкенда);
// (4) http_router_serve_fixture_main/http_serve_sugar_fixture_main
// (реальные сокеты — оба прогона подряд на одном порту); (5) supervisor_*
// и spawn_qualified_fixture_main — намеренно ЗАВЕРШАЮТСЯ паникой (см.
// core/e2e_actors_test.odin's testing.expect_assert на этих же fixtures)
// — diff_check_module_file ожидает успешное значение с ОБЕИХ сторон, не
// подходит; см. отдельные test_diff_module_file_panic_* ниже.
@(private = "file")
mir_module_diff_corpus := []string {
	"fixtures/adt_fixture_main.ps",
	"fixtures/adt_fixture_private_main.ps",
	"fixtures/adt_fixture_short.ps",
	"fixtures/archive_fixture_main.ps",
	"fixtures/bounded_generic_iface_fixture_main.ps",
	"fixtures/collections_fixture_main.ps",
	"fixtures/const_fixture_main.ps",
	"fixtures/flags_fixture_main.ps",
	"fixtures/generic_cross_module_fixture_main.ps",
	"fixtures/http_router_fixture_main.ps",
	"fixtures/http_url_fixture_main.ps",
	"fixtures/impl_qualified_target_main.ps",
	"fixtures/interface_cross_module_main.ps",
	"fixtures/json_fixture_main.ps",
	"fixtures/math_fixture_main.ps",
	"fixtures/module_fixture_main.ps",
	"fixtures/module_fixture_nested_main.ps",
	"fixtures/qualified_generic_fixture_main.ps",
	"fixtures/stdlib_fixture_main.ps",
	"fixtures/test_fixture_main.ps",
	"fixtures/toml_fixture_main.ps",
	"fixtures/type_alias_fixture_main.ps",
	"fixtures/логгер_fixture_main.ps",
	"fixtures/слог_fixture_main.ps",
}

@(test)
test_diff_module_file_corpus :: proc(t: ^testing.T) {
	for path in mir_module_diff_corpus {
		diff_check_module_file(t, path)
	}
}

// Cross-module `запусти Модуль.функция(...)` + супервизор-сценарии —
// намеренно панкуют (см. одноимённые тесты в core/e2e_actors_test.odin,
// та же testing.expect_assert-точная-строка), проверяем только НОВЫЙ
// (MIR) путь даёт ТУ ЖЕ панику — старый путь уже покрыт e2e_actors_test.
@(test)
test_diff_module_file_panic_spawn_qualified :: proc(t: ^testing.T) {
	testing.expect_assert(t, "Runtime Panic: Runtime Panic: эхо получило: привет")
	run_new_path_module_file("fixtures/spawn_qualified_fixture_main.ps")
}

@(test)
test_diff_module_file_panic_supervisor :: proc(t: ^testing.T) {
	testing.expect_assert(
		t,
		"Runtime Panic: супервизор (один-за-одного): 'падающий-рабочий' превысил лимит перезапусков (1 за 60000мс): процесс уже не существует",
	)
	run_new_path_module_file("fixtures/supervisor_fixture_main.ps")
}

@(test)
test_diff_module_file_panic_supervisor_dynamic_add :: proc(t: ^testing.T) {
	testing.expect_assert(
		t,
		"Runtime Panic: Runtime Panic: супервизор (один-за-одного): 'динамический-рабочий' превысил лимит перезапусков (1 за 60000мс): процесс уже не существует",
	)
	run_new_path_module_file("fixtures/supervisor_dynamic_add_fixture_main.ps")
}

@(test)
test_diff_module_file_panic_supervisor_dynamic_remove :: proc(t: ^testing.T) {
	testing.expect_assert(
		t,
		"Runtime Panic: Runtime Panic: супервизор (один-за-одного): 'падающая-после-удаления' превысил лимит перезапусков (1 за 60000мс): процесс уже не существует",
	)
	run_new_path_module_file("fixtures/supervisor_dynamic_remove_fixture_main.ps")
}

@(test)
test_diff_module_file_panic_supervisor_narrow_window :: proc(t: ^testing.T) {
	testing.expect_assert(t, "Runtime Error: все процессы заблокированы в ожидании сообщений (дедлок)")
	run_new_path_module_file("fixtures/supervisor_narrow_window_fixture_main.ps")
}

@(test)
test_diff_module_file_panic_supervisor_one_for_all :: proc(t: ^testing.T) {
	testing.expect_assert(
		t,
		"Runtime Panic: супервизор (групповой рестарт): краш 'падающая' исчерпал лимит групповых перезапусков (1 за 60000мс): Runtime Panic: бум",
	)
	run_new_path_module_file("fixtures/supervisor_one_for_all_fixture_main.ps")
}

@(test)
test_diff_module_file_panic_supervisor_rest_for_one :: proc(t: ^testing.T) {
	testing.expect_assert(
		t,
		"Runtime Panic: супервизор (групповой рестарт): краш 'падающая' исчерпал лимит групповых перезапусков (1 за 60000мс): Runtime Panic: бум",
	)
	run_new_path_module_file("fixtures/supervisor_rest_for_one_fixture_main.ps")
}

// --- Корпус: та же батарея фич, что уже покрыта unit-тестами Фазы 2
// (2.3a-2.3k) + 2.4, теперь сравниваемая напрямую со старым компилятором
// вместо изолированной проверки print+validate/VM-запуска. ---

@(test)
test_diff_arithmetic :: proc(t: ^testing.T) {
	diff_check(t, `
		функ старт() -> Число
			(1 + 2 * 3 - 4 / 2)
		конец
	`)
}

@(test)
test_diff_int_divide :: proc(t: ^testing.T) {
	diff_check(t, `
		функ старт() -> Число
			пер a: Целое = 7
			пер b: Целое = 2
			Число(a / b % b)
		конец
	`)
}

@(test)
test_diff_bitwise :: proc(t: ^testing.T) {
	diff_check(t, `
		функ старт() -> Число
			пер a: Целое = 6
			пер b: Целое = 3
			пер c: Целое = 1
			пер d: Целое = 4
			Число((a & b) | (c << d))
		конец
	`)
}

@(test)
test_diff_if_else :: proc(t: ^testing.T) {
	diff_check(t, `
		функ старт() -> Строка
			если 3 > 5 тогда
				"а"
			иначе
				если 3 == 3 тогда
					"б"
				иначе
					"в"
				конец
			конец
		конец
	`)
}

@(test)
test_diff_while_and_assign :: proc(t: ^testing.T) {
	diff_check(t, `
		функ старт() -> Число
			пер i: Целое = 0
			пер сумма: Целое = 0
			пока i < 20 цикл
				если i % 2 == 0 тогда
					сумма = сумма + i
				конец
				i = i + 1
			конец
			Число(сумма)
		конец
	`)
}

@(test)
test_diff_break_continue :: proc(t: ^testing.T) {
	diff_check(t, `
		функ старт() -> Число
			пер сумма: Целое = 0
			пер i: Целое = 0
			пока истина цикл
				i = i + 1
				если i > 100 тогда
					прервать
				конец
				если i % 3 == 0 тогда
					продолжить
				конец
				сумма = сумма + i
			конец
			Число(сумма)
		конец
	`)
}

@(test)
test_diff_short_circuit :: proc(t: ^testing.T) {
	diff_check(t, `
		функ побочный(x: Булево) -> Булево
			x
		конец

		функ старт() -> Булево
			(побочный(ложь) и побочный(истина)) или побочный(истина)
		конец
	`)
}

@(test)
test_diff_function_calls_and_recursion :: proc(t: ^testing.T) {
	diff_check(t, `
		функ факториал(n: Число) -> Число
			если n <= 1 тогда
				1
			иначе
				n * факториал(n - 1)
			конец
		конец

		функ старт() -> Число
			факториал(10)
		конец
	`)
}

@(test)
test_diff_struct_and_methods :: proc(t: ^testing.T) {
	diff_check(t, `
		тип Точка = структура
			x: Число
			y: Число
		конец

		реализация Точка
			функ длина_квадрат(это: Точка) -> Число
				это.x * это.x + это.y * это.y
			конец
		конец

		функ старт() -> Число
			пер p = Точка(3, 4)
			p.длина_квадрат()
		конец
	`)
}

@(test)
test_diff_property_assign :: proc(t: ^testing.T) {
	diff_check(t, `
		тип Счётчик = структура
			значение: Число
		конец

		функ старт() -> Число
			пер c = Счётчик(0)
			c.значение = c.значение + 1
			c.значение = c.значение + 1
			c.значение
		конец
	`)
}

@(test)
test_diff_array_and_index_assign :: proc(t: ^testing.T) {
	diff_check(t, `
		функ старт() -> Число
			пер значения = массив(1, 2, 3)
			значения[1] = 99
			значения[0] + значения[1] + значения[2]
		конец
	`)
}

@(test)
test_diff_map_literal :: proc(t: ^testing.T) {
	diff_check(t, `
		функ старт() -> Число
			пер m = соответствие("а" = 1, "б" = 2, "в" = 3)
			m.получить("б", 0)
		конец
	`)
}

@(test)
test_diff_tuple_destructure :: proc(t: ^testing.T) {
	diff_check(t, `
		функ старт() -> Число
			пер (a, b, c) = (10, 20, 30)
			a + b + c
		конец
	`)
}

@(test)
test_diff_for_in_fast_array :: proc(t: ^testing.T) {
	diff_check(t, `
		функ старт() -> Число
			пер значения = массив(5, 10, 15, 20)
			пер сумма = 0
			для x в значения цикл
				сумма = сумма + x
			конец
			сумма
		конец
	`)
}

@(test)
test_diff_for_in_iterator_protocol :: proc(t: ^testing.T) {
	diff_check(t, `
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
			пер сч = СчётчикДо(0, 8)
			пер сумма = 0
			для x в сч цикл
				сумма = сумма + x
			конец
			сумма
		конец
	`)
}

@(test)
test_diff_match_adt :: proc(t: ^testing.T) {
	diff_check(t, `
		тип Фигура = перечисление
			Круг(Число)
			Прямоугольник(Число, Число)
		конец

		функ площадь(ф: Фигура) -> Число
			выбор ф
				Фигура.Круг(r) -> r * r * 314 / 100
				Фигура.Прямоугольник(a, b) -> a * b
			конец
		конец

		функ старт() -> Число
			площадь(Фигура.Прямоугольник(3, 7))
		конец
	`)
}

@(test)
test_diff_option_result_prelude :: proc(t: ^testing.T) {
	diff_check(t, `
		функ безопасное_деление(a: Число, b: Число) -> Результат(Число, Ошибка)
			если b == 0 тогда
				Результат.Неудача(Ошибка("матем", "деление на ноль"))
			иначе
				Результат.Успех(a / b)
			конец
		конец

		функ старт() -> Число
			пер r = безопасное_деление(10, 2)
			выбор r
				Результат.Успех(v) -> v
				Результат.Неудача(_) -> -1
			конец
		конец
	`)
}

@(test)
test_diff_try_operator :: proc(t: ^testing.T) {
	diff_check(t, `
		функ шаг1() -> Результат(Число, Ошибка)
			Результат.Успех(5)
		конец

		функ шаг2(x: Число) -> Результат(Число, Ошибка)
			Результат.Успех(x * 2)
		конец

		функ старт() -> Результат(Число, Ошибка)
			пер a = шаг1()?
			пер b = шаг2(a)?
			Результат.Успех(a + b)
		конец
	`)
}

@(test)
test_diff_closure_capture :: proc(t: ^testing.T) {
	diff_check(t, `
		функ старт() -> Число
			пер множитель = 3
			пер утроить = функ(x: Число) -> Число
				x * множитель
			конец
			утроить(7) + утроить(2)
		конец
	`)
}

@(test)
test_diff_interface_dispatch :: proc(t: ^testing.T) {
	diff_check(t, `
		тип Звук = интерфейс
			функ издать() -> Строка
		конец

		тип Кошка = структура
			имя: Строка
		конец

		тип Собака = структура
			имя: Строка
		конец

		реализация Звук для Кошка
			функ издать(это: Кошка) -> Строка
				"мяу"
			конец
		конец

		реализация Звук для Собака
			функ издать(это: Собака) -> Строка
				"гав"
			конец
		конец

		функ озвучить(з: Звук) -> Строка
			з.издать()
		конец

		функ старт() -> Строка
			озвучить(Кошка("Мурка")) + озвучить(Собака("Рекс"))
		конец
	`)
}

@(test)
test_diff_operator_overload_sugar :: proc(t: ^testing.T) {
	diff_check(t, `
		тип Вектор = структура
			x: Число
			y: Число
		конец

		реализация Складываемое для Вектор
			функ сложить(это: Вектор, другое: Вектор) -> Вектор
				Вектор(это.x + другое.x, это.y + другое.y)
			конец
		конец

		реализация Сравниваемое для Вектор
			функ сравнить(это: Вектор, другое: Вектор) -> Число
				(это.x * это.x + это.y * это.y) - (другое.x * другое.x + другое.y * другое.y)
			конец
		конец

		функ старт() -> Булево
			пер a = Вектор(1, 2) + Вектор(3, 4)
			пер b = Вектор(5, 5)
			a.x == b.x и a.y == b.y и a > Вектор(0, 0)
		конец
	`)
}

@(test)
test_diff_string_builtin_calls :: proc(t: ^testing.T) {
	diff_check(t, `
		импорт строки

		функ старт() -> Строка
			строки.верхний_регистр(строки.обрезать("  привет  "))
		конец
	`)
}

@(test)
test_diff_spawn_send_receive :: proc(t: ^testing.T) {
	diff_check(t, `
		функ рабочий() -> Пусто
			пер сообщение: Число = получить()
			42
		конец

		функ старт() -> Число
			пер proc = запусти рабочий()
			отправить(proc, 21 * 2)
			42
		конец
	`)
}

@(test)
test_diff_nested_match_and_if :: proc(t: ^testing.T) {
	diff_check(t, `
		тип Дерево = перечисление
			Лист(Число)
			Узел(Дерево, Дерево)
		конец

		функ сумма_дерева(д: Дерево) -> Число
			выбор д
				Дерево.Лист(v) -> v
				Дерево.Узел(l, r) -> сумма_дерева(l) + сумма_дерева(r)
			конец
		конец

		функ старт() -> Число
			пер t = Дерево.Узел(
				Дерево.Узел(Дерево.Лист(1), Дерево.Лист(2)),
				Дерево.Лист(3),
			)
			если сумма_дерева(t) > 5 тогда
				сумма_дерева(t) * 10
			иначе
				0
			конец
		конец
	`)
}

@(test)
test_diff_discarded_call_result :: proc(t: ^testing.T) {
	diff_check(t, `
		функ побочный_эффект() -> Число
			42
		конец

		функ старт() -> Число
			побочный_эффект()
			побочный_эффект()
			побочный_эффект()
			99
		конец
	`)
}

@(test)
test_diff_bounded_generic_max :: proc(t: ^testing.T) {
	diff_check(t, `
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
}
