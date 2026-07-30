#+build !js
package core

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"

// wasm_backend_wasmtime_test.odin — дифференциальные тесты WASM AOT-
// бэкенда (Фаза 1): один и тот же исходник исполняется (а) существующей
// байткод-VM, (б) реально скомпилированным .wasm-модулем под wasmtime —
// результаты должны совпасть. Тот же принцип, что core/mir_optimize_test.
// odin's opt_diff_check (страховка, поймавшая 2 реальных бага за эту
// сессию) — здесь применён к НОВОМУ бэкенду вместо оптимизации.
//
// За #config(PANOS_WASM_BACKEND_TESTS, false) — требует установленный
// `wasmtime` в PATH, НЕ входит в обычный `odin test ./core`/`just test`
// (см. `just test-wasm-backend`, Justfile) — согласовано с пользователем
// явно (отдельный рецепт вместо runtime-skip, чтобы контрибьюторы без
// wasmtime вообще не собирали эти тесты, а не просто видели их "прошли
// тривиально").

when #config(PANOS_WASM_BACKEND_TESTS, false) {

	@(private = "file")
	wasm_diff_temp_file_counter: i64

	@(private = "file")
	Diff_Result :: struct {
		ok:      bool,
		is_bool: bool,
		num:     f64,
		bl:      bool,
	}

	@(private = "file")
	run_bytecode_diff :: proc(source: string) -> Diff_Result {
		result := check_source(source)
		if len(result.diags) > 0 do return Diff_Result{ok = false}
		module := lower_module(&result.res_ctx, &result.tc_ctx, &result.prog)
		registry := lower_module_to_bytecode(&module)
		vm := new_vm(registry)
		run_scheduler(vm)
		if len(vm.stack) == 0 do return Diff_Result{ok = false}
		top := vm.stack[len(vm.stack) - 1]
		if b, is_b := top.(bool); is_b {
			return Diff_Result{ok = true, is_bool = true, bl = b}
		}
		if n, is_n := top.(f64); is_n {
			return Diff_Result{ok = true, is_bool = false, num = n}
		}
		return Diff_Result{ok = false}
	}

	@(private = "file")
	run_wasm_diff :: proc(source: string) -> Diff_Result {
		result := check_source(source)
		if len(result.diags) > 0 do return Diff_Result{ok = false}
		module := lower_module(&result.res_ctx, &result.tc_ctx, &result.prog)

		entry_is_bool := false
		found_entry := false
		for &mfn in module.functions {
			if mfn.name == "старт" {
				entry_is_bool = prune_type(mfn.result_type).kind == .Bool
				found_entry = true
				break
			}
		}
		if !found_entry do return Diff_Result{ok = false}

		bytes := lower_module_to_wasm(&module)

		id := sync.atomic_add(&wasm_diff_temp_file_counter, 1)
		dir, dir_err := os.temp_dir(context.allocator)
		if dir_err != nil do return Diff_Result{ok = false}
		path := fmt.tprintf("%s/panos_wasm_diff_%d.wasm", dir, id)
		if os.write_entire_file(path, bytes) != nil do return Diff_Result{ok = false}
		defer os.remove(path)

		// Каждый Фаза-1/1.5-модуль импортирует wasm_runtime (см.
		// core/wasm_module.odin's pw_imports) НЕЗАВИСИМО от того,
		// использует ли КОНКРЕТНАЯ фикстура строки — --preload обязателен
		// всегда, не только для строковых тестов (см. `just build-wasm-
		// runtime`, запускается перед этим тестом через зависимость
		// рецепта test-wasm-backend в Justfile). Трейлинг "0" — __env
		// (см. план closures): КАЖДАЯ функция, включая старт, теперь
		// имеет этот параметр единообразно, старт его просто не читает —
		// wasmtime's --invoke передаёт трейлинг CLI-аргументы как
		// аргументы вызываемой функции.
		desc := os.Process_Desc {
			command = []string{"wasmtime", "run", "--preload", "env=wasm_runtime/runtime.wasm", "--invoke", "старт", path, "0"},
		}
		state, stdout_bytes, _, err := os.process_exec(desc, context.allocator)
		if err != nil || !state.success do return Diff_Result{ok = false}

		out := strings.trim_space(string(stdout_bytes))
		if entry_is_bool {
			n, parsed := strconv.parse_int(out)
			if !parsed do return Diff_Result{ok = false}
			return Diff_Result{ok = true, is_bool = true, bl = n != 0}
		}
		n, parsed := strconv.parse_f64(out)
		if !parsed do return Diff_Result{ok = false}
		return Diff_Result{ok = true, is_bool = false, num = n}
	}

	// run_wasm_stdout — Фаза 2.0 (ввод_вывод::печать): в отличие от
	// run_wasm_diff, не парсит возврат старт() как число/булево (печать
	// возвращает Пусто) — вместо этого возвращает СЫРОЙ stdout, реально
	// написанный через pw_print_string (см. wasm_runtime/runtime.odin) —
	// первый случай в этом бэкенде, где результат наблюдается напрямую, а
	// не через Compare_Instr-обходной путь (см. строковые тесты Фазы 1.5).
	@(private = "file")
	run_wasm_stdout :: proc(source: string) -> (stdout: string, ok: bool) {
		result := check_source(source)
		if len(result.diags) > 0 do return "", false
		module := lower_module(&result.res_ctx, &result.tc_ctx, &result.prog)
		bytes := lower_module_to_wasm(&module)

		id := sync.atomic_add(&wasm_diff_temp_file_counter, 1)
		dir, dir_err := os.temp_dir(context.allocator)
		if dir_err != nil do return "", false
		path := fmt.tprintf("%s/panos_wasm_stdout_%d.wasm", dir, id)
		if os.write_entire_file(path, bytes) != nil do return "", false
		defer os.remove(path)

		desc := os.Process_Desc {
			command = []string{"wasmtime", "run", "--preload", "env=wasm_runtime/runtime.wasm", "--invoke", "старт", path, "0"},
		}
		state, stdout_bytes, _, err := os.process_exec(desc, context.allocator)
		if err != nil || !state.success do return "", false
		return string(stdout_bytes), true
	}

	@(private = "file")
	wasm_diff_check :: proc(t: ^testing.T, source: string) {
		bc := run_bytecode_diff(source)
		wa := run_wasm_diff(source)
		testing.expectf(t, bc.ok, "байткод-путь не вернул значение для:\n%s", source)
		testing.expectf(t, wa.ok, "wasm-путь (wasmtime) не вернул значение для:\n%s", source)
		if bc.ok && wa.ok {
			testing.expectf(
				t,
				bc.is_bool == wa.is_bool,
				"РАСХОЖДЕНИЕ ТИПА: байткод is_bool=%v, wasm is_bool=%v, источник:\n%s",
				bc.is_bool,
				wa.is_bool,
				source,
			)
			if bc.is_bool {
				testing.expectf(
					t,
					bc.bl == wa.bl,
					"РАСХОЖДЕНИЕ: байткод=%v, wasm=%v, источник:\n%s",
					bc.bl,
					wa.bl,
					source,
				)
			} else {
				testing.expectf(
					t,
					bc.num == wa.num,
					"РАСХОЖДЕНИЕ: байткод=%v, wasm=%v, источник:\n%s",
					bc.num,
					wa.num,
					source,
				)
			}
		}
	}

	@(test)
	test_wasm_diff_arithmetic :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Число
				(1 + 2 * 3 - 4) / 2
			конец
		`)
	}

	@(test)
	test_wasm_diff_bitwise_and_integer_division :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Целое
				пер a: Целое = 13
				пер b: Целое = 5
				a / b + a % b + (a & b) + (a | b) + (a ^ b) + (~a) + (a << 1) + (a >> 1)
			конец
		`)
	}

	@(test)
	test_wasm_diff_comparisons :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Булево
				пер a = 3
				пер b = 5
				(a < b) и (b > a) и (a <= 3) и (b >= 5) и (a <> b) и не (a == b)
			конец
		`)
	}

	@(test)
	test_wasm_diff_if_else_both_branches_as_value :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Число
				пер x = 7
				если x > 5 тогда
					100
				иначе
					200
				конец
			конец
		`)
		wasm_diff_check(t, `
			функ старт() -> Число
				пер x = 2
				если x > 5 тогда
					100
				иначе
					200
				конец
			конец
		`)
	}

	@(test)
	test_wasm_diff_if_else_as_statement :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Число
				пер x = 7
				пер результат = 0.0
				если x > 5 тогда
					результат = 1
				иначе
					результат = 2
				конец
				результат
			конец
		`)
	}

	@(test)
	test_wasm_diff_while_break_continue :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Целое
				пер i: Целое = 0
				пер сумма: Целое = 0
				пока i < 10 цикл
					i = i + 1
					если i % 2 == 0 тогда
						продолжить
					конец
					если i > 7 тогда
						прервать
					конец
					сумма = сумма + i
				конец
				сумма
			конец
		`)
	}

	@(test)
	test_wasm_diff_function_call_with_args :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ сложить(a: Число, b: Число) -> Число
				a + b
			конец
			функ старт() -> Число
				сложить(3, 4) + сложить(10, 20)
			конец
		`)
	}

	@(test)
	test_wasm_diff_recursion :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ факториал(n: Целое) -> Целое
				если n <= 1 тогда
					1
				иначе
					n * факториал(n - 1)
				конец
			конец
			функ старт() -> Целое
				факториал(6)
			конец
		`)
	}

	// Фаза 1.5: строки. Наблюдаемый результат — ТОЛЬКО через Compare_Instr
	// (Equal/NotEqual, см. core/wasm_emit.odin's emit_compare_op) — нет ни
	// длины, ни чтения байт обратно (Call_Builtin_Instr вне области Фазы
	// 1.5, см. план), поэтому фикстуры возвращают Булево, переиспользуя
	// уже существующий bool-путь дифф-харнесса.

	@(test)
	test_wasm_diff_string_const_equal :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Булево
				"привет" == "привет"
			конец
		`)
		wasm_diff_check(t, `
			функ старт() -> Булево
				"привет" == "пока"
			конец
		`)
	}

	@(test)
	test_wasm_diff_string_concat :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Булево
				("при" + "вет") == "привет"
			конец
		`)
		wasm_diff_check(t, `
			функ старт() -> Булево
				("а" + "б" + "в") <> "абв"
			конец
		`)
	}

	@(test)
	test_wasm_diff_string_variable :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Булево
				пер a = "hello"
				пер b = "world"
				(a + " " + b) == "hello world"
			конец
		`)
	}

	// Фаза 1.5: агрегаты (New_Aggregate_Instr/Get_Property_Instr/
	// Set_Property_Instr) — только через прямой доступ к полям (.x/.y),
	// без методов (Call_Method_Instr вне области Фазы 1.5).

	@(test)
	test_wasm_diff_struct_construct_and_read_fields :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			тип Точка = структура
				x: Число
				y: Число
			конец
			функ старт() -> Число
				пер p = Точка(3, 4)
				p.x + p.y
			конец
		`)
	}

	@(test)
	test_wasm_diff_struct_set_field :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			тип Точка = структура
				x: Число
				y: Число
			конец
			функ старт() -> Число
				пер p = Точка(1, 1)
				p.x = 10
				p.y = 20
				p.x + p.y
			конец
		`)
	}

	@(test)
	test_wasm_diff_struct_mixed_field_types :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			тип Запись = структура
				имя: Строка
				активен: Булево
				счёт: Число
			конец
			функ старт() -> Булево
				пер r = Запись("тест", истина, 42)
				(r.имя == "тест") и (r.активен == истина) и (r.счёт == 42)
			конец
		`)
	}

	// Фаза 2.0: первый Call_Builtin_Instr (ввод_вывод::печать) — реальный,
	// напрямую наблюдаемый stdout через pw_print_string (wasm_runtime/
	// runtime.odin's WASI fd_write), не Compare_Instr-обходной путь.

	@(test)
	test_wasm_print_writes_real_stdout :: proc(t: ^testing.T) {
		out, ok := run_wasm_stdout(`
			импорт ввод_вывод
			функ старт() -> Пусто
				ввод_вывод.печать("hello wasm")
			конец
		`)
		testing.expectf(t, ok, "wasm-путь не выполнился")
		testing.expectf(t, out == "hello wasm", "ожидался stdout 'hello wasm', получено %q", out)
	}

	@(test)
	test_wasm_print_concatenated_string :: proc(t: ^testing.T) {
		out, ok := run_wasm_stdout(`
			импорт ввод_вывод
			функ старт() -> Пусто
				пер a = "при"
				пер b = "вет"
				ввод_вывод.печать(a + b)
			конец
		`)
		testing.expectf(t, ok, "wasm-путь не выполнился")
		testing.expectf(t, out == "привет", "ожидался stdout 'привет', получено %q", out)
	}

	@(test)
	test_wasm_println_writes_trailing_newline :: proc(t: ^testing.T) {
		out, ok := run_wasm_stdout(`
			импорт ввод_вывод
			функ старт() -> Пусто
				ввод_вывод.строка("привет")
			конец
		`)
		testing.expectf(t, ok, "wasm-путь не выполнился")
		testing.expectf(t, out == "привет\n", "ожидался stdout 'привет\\n', получено %q", out)
	}

	@(test)
	test_wasm_print_struct_field :: proc(t: ^testing.T) {
		out, ok := run_wasm_stdout(`
			импорт ввод_вывод
			тип Запись = структура
				имя: Строка
			конец
			функ старт() -> Пусто
				пер r = Запись("панос")
				ввод_вывод.печать(r.имя)
			конец
		`)
		testing.expectf(t, ok, "wasm-путь не выполнился")
		testing.expectf(t, out == "панос", "ожидался stdout 'панос', получено %q", out)
	}

	@(test)
	test_wasm_diff_string_length :: proc(t: ^testing.T) {
		// строки::длина_байт — второй builtin (после ввод_вывод::печать) —
		// впервые в этом бэкенде даёт настоящий числовой readback строки
		// (не только Compare_Instr, как строковые тесты Фазы 1.5) —
		// проходит через уже существующий числовой путь wasm_diff_check.
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Целое
				строки.длина_байт("привет")
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Целое
				пер a = "при"
				пер b = "вет"
				строки.длина_байт(a + b)
			конец
		`)
	}

	@(test)
	test_wasm_diff_string_search_builtins :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.начинается_с("привет мир", "привет")
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.начинается_с("привет", "мир")
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.заканчивается_на("привет мир", "мир")
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.заканчивается_на("привет мир", "привет")
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.содержит("привет мир", "ет м")
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.содержит("привет мир", "xyz")
			конец
		`)
	}

	@(test)
	test_wasm_diff_int_to_string :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.из_целого(42) == "42"
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.из_целого(-17) == "-17"
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.из_целого(0) == "0"
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				пер n: Целое = 100
				строки.из_целого(n * n) == "10000"
			конец
		`)
	}

	@(test)
	test_wasm_diff_string_compare :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Число
				строки.сравнить("абв", "абг")
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Число
				строки.сравнить("абг", "абв")
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Число
				строки.сравнить("привет", "привет")
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Число
				строки.сравнить("аб", "абв")
			конец
		`)
	}

	@(test)
	test_wasm_diff_string_replace :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.заменить("привет мир мир", "мир", "земля") == "привет земля земля"
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.заменить("привет", "xyz", "abc") == "привет"
			конец
		`)
	}

	@(test)
	test_wasm_diff_panos_version :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			импорт ос
			импорт строки
			функ старт() -> Булево
				строки.длина_байт(ос.версия_паноса()) > 0.0
			конец
		`)
	}

	@(test)
	test_wasm_diff_time_builtins_sanity :: proc(t: ^testing.T) {
		// время::монотонно_мс/сейчас_мс отсчитываются от РАЗНЫХ эпох в
		// байткод-VM (vm.monotonic_epoch — момент старта процесса) и в
		// wasm-модуле (WASI CLOCK_MONOTONIC/CLOCK_REALTIME — от опорной
		// точки хоста) — два РАЗНЫХ процесса, точное числовое совпадение
		// в принципе невозможно, см. докстринг pw_monotonic_ms/pw_now_ms
		// в wasm_runtime/runtime.odin. Проверяем через существующий
		// bool-путь wasm_diff_check переиспользованием санити-условия
		// (">= 0.0"), которое ОБА пути дают одинаково истинным независимо
		// от конкретного числа — не отдельный новый харнесс.
		wasm_diff_check(t, `
			импорт время
			функ старт() -> Булево
				время.монотонно_мс() >= 0.0
			конец
		`)
		wasm_diff_check(t, `
			импорт время
			функ старт() -> Булево
				время.сейчас_мс() >= 0.0
			конец
		`)
	}

	// Фаза 2.1: Массив (New_Array_Instr/Get_Index_Instr/Set_Index_Instr) и
	// ADT construction+pattern matching (Build_Variant_Instr/Match_Tag_
	// Instr/Get_Variant_Field_Instr через `выбор`, не через методы —
	// Call_Method_Instr вне области, см. план).

	@(test)
	test_wasm_diff_array_construct_and_index :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Число
				пер значения = массив(10, 20, 30)
				значения[0] + значения[1] + значения[2]
			конец
		`)
		wasm_diff_check(t, `
			функ старт() -> Число
				пер i: Целое = 1
				пер значения = массив(10, 20, 30)
				значения[i]
			конец
		`)
	}

	@(test)
	test_wasm_diff_array_set_index :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Число
				пер значения = массив(1, 2, 3)
				значения[1] = 99
				значения[0] + значения[1] + значения[2]
			конец
		`)
	}

	@(test)
	test_wasm_diff_enum_match_user_declared :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			тип Ф = перечисление
				Точка
				Круг(Число)
				Прямоугольник(Число, Число)
			конец
			функ площадь(ф: Ф) -> Число
				возврат выбор ф
					Точка -> 0
					Круг(р) -> р * р
					Прямоугольник(ш, выс) -> ш * выс
				конец
			конец
			функ старт() -> Число
				площадь(Ф.Точка) + площадь(Ф.Круг(3)) + площадь(Ф.Прямоугольник(4, 5))
			конец
		`)
	}

	@(test)
	test_wasm_diff_opciya_match :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Число
				пер p: Опция(Число) = Опция.Есть(42)
				возврат выбор p
					Опция.Есть(x) -> x
					Нет -> 0
				конец
			конец
		`)
		wasm_diff_check(t, `
			функ старт() -> Число
				пер p: Опция(Число) = Опция.Нет()
				возврат выбор p
					Опция.Есть(x) -> x
					Нет -> -1
				конец
			конец
		`)
	}

	@(test)
	test_wasm_diff_rezultat_match :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Число
				пер r: Результат(Число, Строка) = Результат.Успех(7)
				возврат выбор r
					Результат.Успех(x) -> x
					Неудача(_) -> -1
				конец
			конец
		`)
	}

	// Фаза 2.2, Шаг 0: обычный .метод()-синтаксис (не голый `выбор`) для
	// НЕ-generic структуры — типизируется как Method_Struct (call_infos
	// kind == .Method_Struct, см. type_cheker.odin ~5721), лоурится в
	// Function_Ref_Instr+Call_Value_Instr (Фаза 1) — уже работает без
	// изменений в wasm_emit.odin/wasm_module.odin/wasm_runtime.

	@(test)
	test_wasm_diff_struct_method_call :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
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
				пер p = Точка(3, 4)
				p.сумма()
			конец
		`)
	}

	// Фаза 2.3: Опция/Результат-методы через Method_Struct — ИСПРАВЛЕНО
	// (было: resolve_func_index паникует "вне области Фазы 1", т.к.
	// symbol_to_function[info.symbol_ref] указывал на немономорфизиро-
	// ванный шаблон с абстрактным T). Теперь mir_lowering.odin's
	// .Method_Struct case резолвит через mir_monomorphize.odin's
	// lower_monomorphize_program (единый fixed-point для bounded-generic
	// функций И методов generic-типов) — см. project-память про 4 реальных
	// слоя багов, найденных и исправленных/задокументированных при этом.
	//
	// Фаза 2.5: методы с РЕАЛЬНЫМ биндером в `выбор это` (значение/
	// получить/причина — "Есть(x) -> x", не только wildcard "Есть(_)")
	// ТОЖЕ теперь работают — "это: Опция" (голая, без явных type-
	// аргументов) больше НЕ резолвится в общий немономорфизированный
	// шаблон: resolve_type_node's Type_Ident case реинстанцирует его
	// через instantiate_type (тот же механизм, что уже даёт "Опция(
	// Число)" для явных type-аргументов), используя current_receiver_
	// subst (построен в mir_monomorphize.odin's monomorphize_register_
	// method_one). Ниже — получить()/получить_ошибку() (arity с
	// fallback, реальный биндер, БЕЗ паника() на альтернативной ветке —
	// значение()/причина()/ожидать() падают на ОТДЕЛЬНОМ, несвязанном
	// гэпе: паника()-builtin вообще не реализован в этом бэкенде, вне
	// области). Опция(Процесс(T)) как T-аргумент типизируется и лоурится
	// корректно на байткод-пути (record_generic_method_instantiation не
	// исключает .Process — см. resynced в mir_monomorphize.odin: decl_
	// res.symbol_types резинхронизируется из res.module_graph.symbol_
	// types только на первое использование данного decl_res за фиксед-
	// пойнт раунд, не на каждый клон). Через WASM непроверяемо end-to-
	// end конкретно из-за actor'ов (Spawn_Instr в панике-листе этого
	// бэкенда, отдельный, не связанный гэп) — только байткод-путь
	// (его supervisor-фикстуры используют) подтверждает поведение.

	@(test)
	test_wasm_diff_opciya_method_calls :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Булево
				пер p: Опция(Число) = Опция.Есть(42)
				p.есть()
			конец
		`)
		wasm_diff_check(t, `
			функ старт() -> Булево
				пер p: Опция(Число) = Опция.Нет()
				p.пусто()
			конец
		`)
		wasm_diff_check(t, `
			функ старт() -> Число
				пер p: Опция(Число) = Опция.Есть(42)
				p.получить(0)
			конец
		`)
		wasm_diff_check(t, `
			функ старт() -> Число
				пер p: Опция(Число) = Опция.Нет()
				p.получить(-1)
			конец
		`)
	}

	@(test)
	test_wasm_diff_rezultat_method_calls :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Булево
				пер r: Результат(Число, Строка) = Результат.Успех(7)
				r.успех()
			конец
		`)
		wasm_diff_check(t, `
			функ старт() -> Булево
				пер r: Результат(Число, Строка) = Результат.Неудача("ой")
				r.ошибка()
			конец
		`)
		wasm_diff_check(t, `
			функ старт() -> Число
				пер r: Результат(Число, Строка) = Результат.Успех(7)
				r.получить(-1)
			конец
		`)
		wasm_diff_check(t, `
			функ старт() -> Булево
				пер r: Результат(Число, Строка) = Результат.Неудача("ой")
				r.получить_ошибку("нет") == "ой"
			конец
		`)
	}

	// Фаза 2.2: настоящий Call_Method_Instr — Массив.длина/получить/есть/
	// содержит/срез (Method_Collection, type_cheker.odin:5594-5626).
	// добавить намеренно не покрыт (мутирующий рост — вне области, см.
	// план). f64- и Булево-элементные фикстуры оба — упражняют
	// PW_ARRAY_GET_F64/PW_ARRAY_CONTAINS_F64 и их _I32-пары (см.
	// wasm_field_is_i32 в wasm_emit.odin).

	@(test)
	test_wasm_diff_array_length :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Целое
				массив(10, 20, 30).длина()
			конец
		`)
	}

	@(test)
	test_wasm_diff_array_get_with_fallback :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Число
				пер значения = массив(10, 20, 30)
				значения.получить(1, -1)
			конец
		`)
		wasm_diff_check(t, `
			функ старт() -> Число
				пер значения = массив(10, 20, 30)
				значения.получить(5, -1)
			конец
		`)
	}

	@(test)
	test_wasm_diff_array_get_bool_elements :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Булево
				пер флаги = массив(истина, ложь, истина)
				флаги.получить(1, истина)
			конец
		`)
		wasm_diff_check(t, `
			функ старт() -> Булево
				пер флаги = массив(истина, ложь, истина)
				флаги.получить(9, ложь)
			конец
		`)
	}

	@(test)
	test_wasm_diff_array_has_index :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Булево
				массив(1, 2, 3).есть(1)
			конец
		`)
		wasm_diff_check(t, `
			функ старт() -> Булево
				массив(1, 2, 3).есть(9)
			конец
		`)
	}

	@(test)
	test_wasm_diff_array_contains :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Булево
				массив(1, 2, 3).содержит(2)
			конец
		`)
		wasm_diff_check(t, `
			функ старт() -> Булево
				массив(1, 2, 3).содержит(9)
			конец
		`)
		wasm_diff_check(t, `
			функ старт() -> Булево
				массив(истина, ложь).содержит(ложь)
			конец
		`)
	}

	@(test)
	test_wasm_diff_array_slice :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Целое
				пер значения = массив(10, 20, 30, 40)
				пер часть = значения.срез(1, 3)
				часть.длина()
			конец
		`)
		wasm_diff_check(t, `
			функ старт() -> Число
				пер значения = массив(10, 20, 30, 40)
				пер часть = значения.срез(1, 3)
				часть[0] + часть[1]
			конец
		`)
	}

	// Фаза 2.4: Соответствие — New_Map_Instr (конструктор) + Get_Index_Instr
	// (m[k], читает через тот же путь, что получить(), нулевой fallback на
	// отсутствующий ключ — тот же принятый gap, что у Массив OOB, Фаза 2.1)
	// + Call_Method_Instr (длина/есть/получить/удалить). m[k]=v (Set_Index)
	// намеренно НЕ покрыт (арена не растит объект на месте для вставки
	// нового ключа, см. план — та же причина, что Массив.добавить).
	// Строковые ключи (доминирующий реальный случай, json/toml) и числовые
	// ключи — оба пути (pw_map_*_strkey/numkey).

	@(test)
	test_wasm_diff_map_construct_and_get_strkey :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Число
				пер цены = соответствие("яблоко" = 10, "груша" = 20)
				цены["яблоко"]
			конец
		`)
	}

	@(test)
	test_wasm_diff_map_get_numkey :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Целое
				пер м: Соответствие(Целое, Целое) = соответствие(1 = 100, 2 = 200)
				пер ключ: Целое = 2
				м[ключ]
			конец
		`)
	}

	@(test)
	test_wasm_diff_map_length :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Целое
				соответствие("а" = 1, "б" = 2, "в" = 3).длина()
			конец
		`)
	}

	@(test)
	test_wasm_diff_map_has :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Булево
				соответствие("яблоко" = 10).есть("яблоко")
			конец
		`)
		wasm_diff_check(t, `
			функ старт() -> Булево
				соответствие("яблоко" = 10).есть("банан")
			конец
		`)
	}

	@(test)
	test_wasm_diff_map_get_with_fallback :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Число
				пер цены = соответствие("яблоко" = 10, "груша" = 20)
				цены.получить("груша", -1)
			конец
		`)
		wasm_diff_check(t, `
			функ старт() -> Число
				пер цены = соответствие("яблоко" = 10, "груша" = 20)
				цены.получить("банан", -1)
			конец
		`)
	}

	@(test)
	test_wasm_diff_map_delete :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Булево
				пер цены = соответствие("яблоко" = 10, "груша" = 20)
				цены.удалить("яблоко")
			конец
		`)
		wasm_diff_check(t, `
			функ старт() -> Булево
				пер цены = соответствие("яблоко" = 10, "груша" = 20)
				цены.удалить("банан")
			конец
		`)
		wasm_diff_check(t, `
			функ старт() -> Целое
				пер цены = соответствие("яблоко" = 10, "груша" = 20)
				цены.удалить("яблоко")
				цены.длина()
			конец
		`)
	}

	// Фаза 2.13: записи() — pw_map_entries чистый бит-копи (запись карты
	// и 2-элементный тупл — один и тот же 2*FIELD_SIZE-layout, см.
	// wasm_runtime/runtime.odin), покрыты строковые И числовые ключи.

	@(test)
	test_wasm_diff_map_entries_strkey :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Булево
				пер цены = соответствие("яблоко" = 10)
				пер зап = цены.записи()
				зап.длина() == 1 и зап[0].0 == "яблоко" и зап[0].1 == 10
			конец
		`)
	}

	@(test)
	test_wasm_diff_map_entries_numkey :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Целое
				пер м: Соответствие(Целое, Целое) = соответствие(1 = 100, 2 = 200)
				пер зап = м.записи()
				зап[0].0 + зап[1].0 + зап[0].1 + зап[1].1
			конец
		`)
	}

	// Фаза 2.14 (продолжение): сеть::кодировать_url — RFC 3986 percent-
	// encoding побайтово, cеть.модуль native-agnostic (нет фс/сокета —
	// чистое строковое преобразование). Cyrillic-кейс покрыт (многобайтовые
	// UTF-8-руны кодируются байт за байтом), точный литерал сверен
	// заранее через urllib.parse.quote (та же кодировка/регистр hex).

	@(test)
	test_wasm_diff_url_encode :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			импорт сеть
			функ старт() -> Булево
				сеть.кодировать_url("abc-DEF_123.~") == "abc-DEF_123.~"
			конец
		`)
		wasm_diff_check(t, `
			импорт сеть
			функ старт() -> Булево
				сеть.кодировать_url("hello world!") == "hello%20world%21"
			конец
		`)
		wasm_diff_check(t, `
			импорт сеть
			функ старт() -> Булево
				сеть.кодировать_url("привет") == "%D0%BF%D1%80%D0%B8%D0%B2%D0%B5%D1%82"
			конец
		`)
	}

	// Фаза 2.6: паника(сообщение) — теперь эмитится (pw_print_string +
	// WASM unreachable-трап), больше не паникует КОМПИЛЯТОР при попытке
	// сгенерировать код. Разблокирует .причина()/.ожидать() на УСПЕШНОМ
	// пути (паника() никогда реально не вызывается — Опция/Результат
	// содержат значение, "не тот" арм с паника() внутри просто не
	// исполняется, но ДОЛЖЕН быть валидно эмиттируем регардлесс —
	// is_wasm_phase1_function/резолюция функций не смотрит на runtime-
	// достижимость, только на компайл-тайм совместимость сигнатуры).
	// Прямая проверка самого трапа — отдельный тест ниже (единственный
	// в этом файле, ожидающий !success от wasmtime, а не запись через
	// wasm_diff_check).

	@(test)
	test_wasm_diff_rezultat_ozhidat_and_prichina_success_path :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Число
				пер r: Результат(Число, Строка) = Результат.Успех(7)
				r.ожидать("не должно случиться")
			конец
		`)
	}

	@(test)
	test_wasm_panic_traps_and_prints_message :: proc(t: ^testing.T) {
		src := `
			функ старт() -> Пусто
				паника("бум-сообщение")
			конец
		`
		result := check_source(src)
		testing.expectf(t, len(result.diags) == 0, "check_source diagnostics: %v", result.diags)
		module := lower_module(&result.res_ctx, &result.tc_ctx, &result.prog)
		bytes := lower_module_to_wasm(&module)

		id := sync.atomic_add(&wasm_diff_temp_file_counter, 1)
		dir, dir_err := os.temp_dir(context.allocator)
		testing.expectf(t, dir_err == nil, "нет temp dir")
		path := fmt.tprintf("%s/panos_wasm_panic_%d.wasm", dir, id)
		testing.expectf(t, os.write_entire_file(path, bytes) == nil, "не удалось записать модуль")
		defer os.remove(path)

		desc := os.Process_Desc {
			command = []string{"wasmtime", "run", "--preload", "env=wasm_runtime/runtime.wasm", "--invoke", "старт", path, "0"},
		}
		state, stdout_bytes, _, err := os.process_exec(desc, context.allocator)
		testing.expectf(t, err == nil, "process_exec ошибка: %v", err)
		testing.expectf(t, !state.success, "паника() должна трапнуть wasm-модуль (ненулевой выход), получен успех")
		testing.expectf(
			t,
			strings.contains(string(stdout_bytes), "бум-сообщение"),
			"ожидалось сообщение паники в stdout, получено: %q",
			string(stdout_bytes),
		)
	}

	// Фаза 2.7: рост арены — Массив.добавить и m[k]=v на Соответствие,
	// оба ранее исключены (арена не растила объект на месте). 6 push'ей
	// с нуля пересекают НЕСКОЛЬКО удвоений capacity (0->8->16->32->64
	// байт, см. wasm_runtime/runtime.odin's ensure_capacity) — не только
	// первый рост-с-нуля.

	@(test)
	test_wasm_diff_array_push_length :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Целое
				пер a: Массив(Целое) = массив()
				a.добавить(10)
				a.добавить(20)
				a.добавить(30)
				a.добавить(40)
				a.добавить(50)
				a.добавить(60)
				a.длина()
			конец
		`)
	}

	@(test)
	test_wasm_diff_array_push_values_survive_growth :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Число
				пер a: Массив(Число) = массив()
				a.добавить(1)
				a.добавить(2)
				a.добавить(3)
				a.добавить(4)
				a.добавить(5)
				a[0] + a[4]
			конец
		`)
	}

	@(test)
	test_wasm_diff_map_set_index_existing_key :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Число
				пер m = соответствие("а" = 1, "б" = 2)
				m["а"] = 99
				m["а"]
			конец
		`)
	}

	@(test)
	test_wasm_diff_map_set_index_new_key_grows :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Целое
				пер m = соответствие("а" = 1)
				m["б"] = 2
				m["в"] = 3
				m.длина()
			конец
		`)
		wasm_diff_check(t, `
			функ старт() -> Число
				пер m = соответствие("а" = 1)
				m["б"] = 2
				m["б"]
			конец
		`)
	}

	// Фаза 2.8: рун-осведомлённые строковые операции — panos's собственная
	// строковая модель рунная (Cyrillic-heavy фикстуры), не байтовая — все
	// тесты ниже нарочно используют кириллицу, а не ASCII (ASCII-заглушка
	// тихо разошлась бы с реальным поведением, не покрыла бы 2-байтные
	// UTF-8-руны).

	@(private = "file")
	run_wasm_expect_trap :: proc(t: ^testing.T, source: string) {
		result := check_source(source)
		testing.expectf(t, len(result.diags) == 0, "check_source diagnostics: %v", result.diags)
		module := lower_module(&result.res_ctx, &result.tc_ctx, &result.prog)
		bytes := lower_module_to_wasm(&module)

		id := sync.atomic_add(&wasm_diff_temp_file_counter, 1)
		dir, dir_err := os.temp_dir(context.allocator)
		testing.expectf(t, dir_err == nil, "нет temp dir")
		path := fmt.tprintf("%s/panos_wasm_trap_%d.wasm", dir, id)
		testing.expectf(t, os.write_entire_file(path, bytes) == nil, "не удалось записать модуль")
		defer os.remove(path)

		desc := os.Process_Desc {
			command = []string{"wasmtime", "run", "--preload", "env=wasm_runtime/runtime.wasm", "--invoke", "старт", path, "0"},
		}
		state, _, _, err := os.process_exec(desc, context.allocator)
		testing.expectf(t, err == nil, "process_exec ошибка: %v", err)
		testing.expectf(t, !state.success, "ожидался trap (ненулевой выход), получен успех")
	}

	@(test)
	test_wasm_diff_string_length_runes :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Целое
				длина("привет")
			конец
		`)
	}

	@(test)
	test_wasm_diff_string_length_polymorphic :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Целое
				массив(1, 2, 3).длина()
			конец
		`)
		wasm_diff_check(t, `
			функ старт() -> Целое
				соответствие("а" = 1, "б" = 2).длина()
			конец
		`)
	}

	@(test)
	test_wasm_diff_string_index :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Булево
				пер text = "привет"
				text[0] == "п"
			конец
		`)
		wasm_diff_check(t, `
			функ старт() -> Булево
				пер text = "привет"
				text[5] == "т"
			конец
		`)
	}

	@(test)
	test_wasm_diff_string_slice_rune :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.срез("привет", 0, 3) == "при"
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.срез("привет", 3, 6) == "вет"
			конец
		`)
	}

	@(test)
	test_wasm_diff_string_find_rune :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Целое
				строки.найти("привет мир", "мир", 0)
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Целое
				строки.найти("привет", "банан", 0)
			конец
		`)
	}

	@(test)
	test_wasm_diff_string_byte_at :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Целое
				строки.байт("привет", 0)
			конец
		`)
	}

	@(test)
	test_wasm_diff_string_slice_byte :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.срез_байт("привет", 0, 2) == "п"
			конец
		`)
	}

	@(test)
	test_wasm_diff_string_bytes_roundtrip :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				пер text = "привет"
				строки.из_байтов(строки.в_байты(text)) == text
			конец
		`)
	}

	@(test)
	test_wasm_diff_string_codepoint :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.кодовая_точка("п") == строки.кодовая_точка("привет")
			конец
		`)
	}

	@(test)
	test_wasm_diff_string_runes_roundtrip :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				пер text = "привет мир"
				строки.из_рун(строки.в_руны(text)) == text
			конец
		`)
	}

	@(test)
	test_wasm_panic_string_slice_rune_oob_traps :: proc(t: ^testing.T) {
		run_wasm_expect_trap(t, `
			импорт строки
			функ старт() -> Пусто
				строки.срез("привет", 0, 99)
			конец
		`)
	}

	@(test)
	test_wasm_panic_string_byte_oob_traps :: proc(t: ^testing.T) {
		run_wasm_expect_trap(t, `
			импорт строки
			функ старт() -> Пусто
				строки.байт("привет", 99)
			конец
		`)
	}

	// Фаза 2.9: Unicode-классификация/регистр — core:unicode's табличные
	// функции напрямую (см. wasm_runtime/runtime.odin, контекст-фикс
	// проверен спайком) — Cyrillic-фикстуры обязательны (не только ASCII,
	// см. её докстринг про то, почему ASCII-заглушка не покрыла бы
	// реальное поведение).

	@(test)
	test_wasm_diff_string_is_digit :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.это_цифра("5")
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.это_цифра("привет")
			конец
		`)
	}

	@(test)
	test_wasm_diff_string_is_alpha :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.это_буква("п")
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.это_буква("5")
			конец
		`)
	}

	@(test)
	test_wasm_diff_string_digit_or_alpha :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.цифра_или_буква("ю")
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.цифра_или_буква(" ")
			конец
		`)
	}

	@(test)
	test_wasm_diff_string_upper_lower_case :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.верхний_регистр("привет mir") == "ПРИВЕТ MIR"
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.нижний_регистр("ПРИВЕТ MIR") == "привет mir"
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				пер text = "Привет Мир"
				строки.нижний_регистр(строки.верхний_регистр(text)) == строки.нижний_регистр(text)
			конец
		`)
	}

	// Фаза 2.10: строки::из_числа/в_число — core:strconv напрямую (см.
	// wasm_runtime/runtime.odin, спайком проверено ДО вживления). Кейс
	// 1234567.0 — та же величина, что core/vm.odin:1002-1016
	// документирует как исторический баг (scientific notation вместо
	// фиксированно-точечного формата).

	@(test)
	test_wasm_diff_number_to_string :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.из_числа(42.0) == "42"
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.из_числа(3.14) == "3.14"
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.из_числа(-7.5) == "-7.5"
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.из_числа(1234567.0) == "1234567"
			конец
		`)
	}

	@(test)
	test_wasm_diff_string_to_number :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.в_число("42").значение() == 42.0
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.в_число("3.14").значение() == 3.14
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.в_число("abc").успех() == ложь и строки.в_число("abc").ошибка() == истина
			конец
		`)
	}

	// Фаза 2.11: строки::разбить/соединить/обрезать — core:strings.split
	// имеет реальную развилку (непустой sep = байтовый substring-поиск,
	// пустой sep = разбивка на руны, core/strings/strings.odin:822-837) —
	// оба пути покрыты. соединить и обрезать проверены и на кириллице,
	// не только ASCII (это проекта собственная дисциплина, см. Фазу 2.8).

	@(test)
	test_wasm_diff_string_split_join :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				пер части = строки.разбить("a,b,c", ",")
				части.длина() == 3 и строки.соединить(части, ",") == "a,b,c"
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				пер части = строки.разбить("привет", "-")
				части.длина() == 1 и строки.соединить(части, "-") == "привет"
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				пер руны = строки.разбить("привет", "")
				руны.длина() == 6 и строки.соединить(руны, "") == "привет"
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.соединить(массив("a", "b", "c"), ", ") == "a, b, c"
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.соединить(массив("одиночный"), ", ") == "одиночный"
			конец
		`)
	}

	@(test)
	test_wasm_diff_string_trim :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.обрезать("  привет мир  ") == "привет мир"
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.обрезать("\t\n   \t") == ""
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.обрезать("привет") == "привет"
			конец
		`)
	}

	// Фаза 2.12: .код/.сообщение на Ошибка — .Error добавлен в wasm_val_
	// type/is_wasm_phase1_type (core/wasm_module.odin), разблокировав
	// УЖЕ СУЩЕСТВУЮЩУЮ generic-method/Get_Property_Instr машинерию (Фазы
	// 2.3/2.5) без нового кода в mir_lowering.odin/wasm_emit.odin.

	@(test)
	test_wasm_diff_error_code_message_fields :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.в_число("abc").причина().код == "строки"
			конец
		`)
		wasm_diff_check(t, `
			импорт строки
			функ старт() -> Булево
				строки.в_число("abc").причина().сообщение == "'abc' не является числом"
			конец
		`)
	}

	// Try_Unwrap_Instr (`?`-оператор) — ранее панике-листовалась вместе с
	// closures/interfaces/actors, реально не связана ни с одним из них
	// (single-function рантайм-развилка, см. её докстринг в core/mir.odin
	// и core/wasm_emit.odin's emit_try_unwrap). Успешный путь распаковывает
	// payload и продолжает; путь-неудача возвращает Опцию/Результат ЦЕЛИКОМ
	// (тот же, полученный от src) — оба покрыты ниже отдельно для Опции и
	// Результата.

	@(test)
	test_wasm_diff_try_unwrap_option_success :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ шаг1() -> Опция(Число)
				Опция.Есть(7)
			конец
			функ шаг2() -> Опция(Число)
				пер x = шаг1()?
				Опция.Есть(x * 2)
			конец
			функ старт() -> Число
				шаг2().получить(-1)
			конец
		`)
	}

	@(test)
	test_wasm_diff_try_unwrap_option_none_short_circuits :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ шаг1() -> Опция(Число)
				Опция.Нет()
			конец
			функ шаг2() -> Опция(Число)
				пер x = шаг1()?
				Опция.Есть(x * 2)
			конец
			функ старт() -> Число
				шаг2().получить(-1)
			конец
		`)
	}

	@(test)
	test_wasm_diff_try_unwrap_result_success :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ шаг1() -> Результат(Число, Строка)
				Результат.Успех(10)
			конец
			функ шаг2() -> Результат(Число, Строка)
				пер x = шаг1()?
				Результат.Успех(x + 5)
			конец
			функ старт() -> Число
				шаг2().получить(-1)
			конец
		`)
	}

	@(test)
	test_wasm_diff_try_unwrap_result_failure_short_circuits :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ шаг1() -> Результат(Число, Строка)
				Результат.Неудача("ой")
			конец
			функ шаг2() -> Результат(Число, Строка)
				пер x = шаг1()?
				Результат.Успех(x + 5)
			конец
			функ старт() -> Число
				шаг2().получить(-1)
			конец
		`)
	}

	@(test)
	test_wasm_diff_try_unwrap_result_failure_preserves_error_value :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ шаг1() -> Результат(Число, Строка)
				Результат.Неудача("исходная")
			конец
			функ шаг2() -> Результат(Число, Строка)
				пер x = шаг1()?
				Результат.Успех(x + 5)
			конец
			функ старт() -> Булево
				шаг2().получить_ошибку("нет") == "исходная"
			конец
		`)
	}

	// Closures (Build_Closure_Instr/Load_Captured_Instr, план closures) —
	// каждое компилируемое функциональное значение (захватывающее или
	// нет) теперь единообразный [fn_index, captured...] arena-хендл;
	// КАЖДАЯ WASM-функция получила трейлинг __env-параметр (см.
	// core/wasm_module.odin). Call_Value_Instr's callee почти ВСЕГДА
	// проходит через ОБЩИЙ (структурный скан, find_call_value_typeidx)
	// путь — "быстрый" O(1)-путь (value_to_closure_local) покрывает
	// только вызов ПО ИМЕНИ напрямую (без прохода через локаль), т.е.
	// РОВНО то, что уже работало ДО closures — сам `пер f = ...; f()`
	// паттерн (нормальный способ хранить/передавать функцию) ВСЕГДА идёт
	// через фоллбэк, что и проверяют тесты ниже.

	@(test)
	test_wasm_diff_closure_non_capturing_stored_then_called :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ ответ() -> Число
				42.0
			конец
			функ старт() -> Число
				пер f = ответ
				f()
			конец
		`)
	}

	@(test)
	test_wasm_diff_closure_capturing_called_immediately :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Число
				пер y = 10.0
				пер f = функ(x: Число) -> Число
					x + y
				конец
				f(5.0)
			конец
		`)
	}

	@(test)
	test_wasm_diff_closure_capturing_stored_then_called_twice :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Число
				пер y = 100.0
				пер f = функ(x: Число) -> Число
					x + y
				конец
				пер a = f(1.0)
				пер b = f(2.0)
				a + b
			конец
		`)
	}

	@(test)
	test_wasm_diff_closure_passed_as_argument_and_called_inside :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ применить(ф: функ(Число) -> Число, значение: Число) -> Число
				ф(значение)
			конец
			функ старт() -> Число
				пер y = 7.0
				пер f = функ(x: Число) -> Число
					x + y
				конец
				применить(f, 3.0)
			конец
		`)
	}

	@(test)
	test_wasm_diff_closure_nested_captures_another_closure :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			функ старт() -> Число
				пер прибавить_один = функ(x: Число) -> Число
					x + 1.0
				конец
				пер обёртка = функ(x: Число) -> Число
					прибавить_один(x) * 2.0
				конец
				обёртка(3.0)
			конец
		`)
	}

	// Interfaces (Cast_Interface_Instr/Invoke_Interface_Instr, план
	// interfaces) — вызов интерфейсного метода теперь диспетчится
	// СТРОКОВЫМ сравнением имени метода в рантайме (см. emit_invoke_
	// interface), не позиционно — struct_type.methods итерируется как
	// map, порядок между разными кастами НЕ детерминирован.

	@(test)
	test_wasm_diff_interface_single_impl_via_argument :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			тип Числимое = интерфейс
				функ значение() -> Число
			конец
			тип Точка = структура
				x: Число
			конец
			реализация Числимое для Точка
				функ значение(это: Точка) -> Число
					это.x
				конец
			конец
			функ показать(p: Числимое) -> Число
				p.значение()
			конец
			функ старт() -> Число
				показать(Точка(42))
			конец
		`)
	}

	@(test)
	test_wasm_diff_interface_two_structs_shared_call_site :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			тип Числимое = интерфейс
				функ значение() -> Число
			конец
			тип ТочкаA = структура
				x: Число
			конец
			тип ТочкаB = структура
				y: Число
				z: Число
			конец
			реализация Числимое для ТочкаA
				функ значение(это: ТочкаA) -> Число
					это.x
				конец
			конец
			реализация Числимое для ТочкаB
				функ значение(это: ТочкаB) -> Число
					это.y + это.z
				конец
			конец
			функ показать(p: Числимое) -> Число
				p.значение()
			конец
			функ старт() -> Число
				пер a = показать(ТочкаA(10))
				пер b = показать(ТочкаB(3, 4))
				a + b
			конец
		`)
	}

	@(test)
	test_wasm_diff_interface_stored_then_invoked_later :: proc(t: ^testing.T) {
		wasm_diff_check(t, `
			тип Числимое = интерфейс
				функ значение() -> Число
			конец
			тип Точка = структура
				x: Число
			конец
			реализация Числимое для Точка
				функ значение(это: Точка) -> Число
					это.x
				конец
			конец
			функ старт() -> Число
				пер p: Числимое = Точка(7)
				пер a = 1.0
				пер b = 2.0
				p.значение() + a + b
			конец
		`)
	}

}
