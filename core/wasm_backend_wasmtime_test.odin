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
		// рецепта test-wasm-backend в Justfile).
		desc := os.Process_Desc {
			command = []string{"wasmtime", "run", "--preload", "env=wasm_runtime/runtime.wasm", "--invoke", "старт", path},
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
			command = []string{"wasmtime", "run", "--preload", "env=wasm_runtime/runtime.wasm", "--invoke", "старт", path},
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

}
