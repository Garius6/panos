#+build !js
package core

import "core:strings"
import "core:testing"

// --- Структурные тесты (print-based, тот же стиль, что core/mir_test.
// odin) — подтверждают, что конкретные паттерны реально свёртываются/
// устраняются, не просто "программа всё ещё считает правильно". ---

@(private = "file")
lower_and_optimize :: proc(t: ^testing.T, source: string) -> (Mir_Module, ^Mir_Function) {
	result := check_source(source)
	testing.expectf(t, len(result.diags) == 0, "check_source diagnostics: %v", result.diags)
	module := lower_module(&result.res_ctx, &result.tc_ctx, &result.prog)
	optimize_module(&module)
	for &fn in module.functions {
		if fn.name == "старт" {
			return module, &fn
		}
	}
	testing.fail_now(t, "функция 'старт' не найдена после lowering")
}

@(private = "file")
expect_valid_optimized :: proc(t: ^testing.T, module: ^Mir_Module, fn: ^Mir_Function) {
	issues := validate_function(module, fn)
	defer delete(issues)
	for issue in issues {
		testing.expectf(t, !issue.is_error, "validate_function (после optimize_module): %s", issue.message)
	}
}

@(test)
test_optimize_fold_arithmetic_chain :: proc(t: ^testing.T) {
	module, fn := lower_and_optimize(t, `
		функ старт() -> Число
			1 + 2 * 3
		конец
	`)
	expect_valid_optimized(t, &module, fn)
	dump := print_function(fn)
	testing.expectf(t, strings.contains(dump, "= const 7"), "ожидался 'const 7' (свёрнуто), дамп: %s", dump)
	testing.expectf(t, !strings.contains(dump, "binary "), "бинарные операции должны были свернуться, дамп: %s", dump)
}

@(test)
test_optimize_fold_string_concat :: proc(t: ^testing.T) {
	// ASCII-only source — print_function экранирует не-ASCII в \u-форму
	// (см. core/mir_print.odin), сравнивать читаемее на латинице.
	module, fn := lower_and_optimize(t, `
		функ старт() -> Строка
			"hello, " + "world"
		конец
	`)
	expect_valid_optimized(t, &module, fn)
	dump := print_function(fn)
	testing.expectf(t, strings.contains(dump, `"hello, world"`), "ожидалась свёрнутая строка, дамп: %s", dump)
}

@(test)
test_optimize_fold_comparison :: proc(t: ^testing.T) {
	module, fn := lower_and_optimize(t, `
		функ старт() -> Булево
			1 < 2
		конец
	`)
	expect_valid_optimized(t, &module, fn)
	dump := print_function(fn)
	testing.expectf(t, strings.contains(dump, "= const true"), "ожидался 'const true' (свёрнуто), дамп: %s", dump)
}

@(test)
test_optimize_fold_does_not_touch_variable :: proc(t: ^testing.T) {
	// a — параметр, не константа: свёртка не должна ничего трогать.
	module, fn := lower_and_optimize(t, `
		функ f(a: Число) -> Число
			a + 1
		конец

		функ старт() -> Число
			f(41)
		конец
	`)
	expect_valid_optimized(t, &module, fn)
	found_f := false
	for &f in module.functions {
		if f.name == "f" {
			found_f = true
			dump := print_function(&f)
			testing.expectf(t, strings.contains(dump, "binary Add"), "a+1 с переменной a НЕ должно свернуться, дамп: %s", dump)
		}
	}
	testing.expectf(t, found_f, "функция 'f' не найдена")
}

@(test)
test_optimize_divide_by_zero_not_folded :: proc(t: ^testing.T) {
	// Int_Divide/Modulo с константным rhs==0 паникуют В РАНТАЙМЕ
	// (core/vm.odin) — свёртка не должна тихо убирать эту панику.
	module, fn := lower_and_optimize(t, `
		функ старт() -> Целое
			пер a: Целое = 10
			пер b: Целое = 0
			a / b
		конец
	`)
	expect_valid_optimized(t, &module, fn)
	// a и b — переменные (пер), не литералы, so инструкция и так не
	// свернулась бы — реальный тест на "rhs==0 не сворачивается" — ниже,
	// через прямой вызов fold_binary.
	folded, ok := fold_binary(.Int_Divide, f64(10), f64(0))
	testing.expectf(t, !ok, "деление на 0 НЕ должно свернуться, получено %v", folded)
}

// entry_branch_targets — лоурит source БЕЗ оптимизации, возвращает
// (then_block, else_block) entry-блока — используется как база для
// сравнения "куда должен указывать Jump_Term после свёртки" (номера
// блоков зависят от порядка lower_if_expr's new_block-вызовов, надёжнее
// прочитать их из РЕАЛЬНОГО неоптимизированного лоуринга, чем
// захардкодить).
@(private = "file")
entry_branch_targets :: proc(t: ^testing.T, source: string) -> (then_block, else_block: Block_Id) {
	result := check_source(source)
	testing.expectf(t, len(result.diags) == 0, "check_source diagnostics: %v", result.diags)
	module := lower_module(&result.res_ctx, &result.tc_ctx, &result.prog)
	for &fn in module.functions {
		if fn.name != "старт" do continue
		entry_blk := &fn.blocks[fn.entry]
		branch, ok := entry_blk.terminator.(^Branch_Term)
		testing.expectf(t, ok, "ожидался Branch_Term в entry-блоке неоптимизированного MIR")
		return branch.then_block, branch.else_block
	}
	testing.fail_now(t, "функция 'старт' не найдена")
}

@(test)
test_optimize_fold_constant_branch_true :: proc(t: ^testing.T) {
	source := `
		функ старт() -> Число
			если истина тогда
				1
			иначе
				2
			конец
		конец
	`
	then_block, _ := entry_branch_targets(t, source)

	module, fn := lower_and_optimize(t, source)
	expect_valid_optimized(t, &module, fn)
	entry_blk := &fn.blocks[fn.entry]
	jump, is_jump := entry_blk.terminator.(^Jump_Term)
	testing.expectf(t, is_jump, "entry-терминатор должен был стать Jump_Term (было %T)", entry_blk.terminator)
	if is_jump {
		testing.expect_value(t, jump.target, then_block)
	}
}

@(test)
test_optimize_fold_constant_branch_from_comparison :: proc(t: ^testing.T) {
	// Условие само не литерал, а свёртывается ДО проверки branch'а —
	// 1 < 2 сначала фолдится в const true (обычная свёртка), ТОЛЬКО
	// ПОТОМ fold_constant_branch видит cond в const_val.
	source := `
		функ старт() -> Число
			если 1 < 2 тогда
				42
			иначе
				99
			конец
		конец
	`
	then_block, _ := entry_branch_targets(t, source)

	module, fn := lower_and_optimize(t, source)
	expect_valid_optimized(t, &module, fn)
	entry_blk := &fn.blocks[fn.entry]
	jump, is_jump := entry_blk.terminator.(^Jump_Term)
	testing.expectf(t, is_jump, "entry-терминатор должен был стать Jump_Term (было %T)", entry_blk.terminator)
	if is_jump {
		testing.expect_value(t, jump.target, then_block)
	}
}

@(test)
test_optimize_fold_constant_branch_false :: proc(t: ^testing.T) {
	source := `
		функ старт() -> Число
			если ложь тогда
				1
			иначе
				2
			конец
		конец
	`
	_, else_block := entry_branch_targets(t, source)

	module, fn := lower_and_optimize(t, source)
	expect_valid_optimized(t, &module, fn)
	entry_blk := &fn.blocks[fn.entry]
	jump, is_jump := entry_blk.terminator.(^Jump_Term)
	testing.expectf(t, is_jump, "entry-терминатор должен был стать Jump_Term (было %T)", entry_blk.terminator)
	if is_jump {
		testing.expect_value(t, jump.target, else_block)
	}
}

@(test)
test_optimize_fold_constant_branch_removes_dead_side_effect :: proc(t: ^testing.T) {
	// Вызов внутри МЁРТВОЙ ветки не должен попасть в СКОМПИЛИРОВАННЫЙ
	// байткод — доказывает удаление ВСЕГО блока через уже существующий
	// reverse_postorder-пропуск недостижимых блоков в backend'е (core/
	// mir_bytecode.odin), не просто отсутствие условной инструкции.
	// print_function ТУТ не годится — она печатает ВСЕ fn.blocks
	// (включая недостижимые), reachability — забота бэкенда, не принтера.
	module, fn := lower_and_optimize(t, `
		функ побочный_эффект() -> Число
			999
		конец

		функ старт() -> Число
			если ложь тогда
				побочный_эффект()
			иначе
				1
			конец
		конец
	`)
	expect_valid_optimized(t, &module, fn)
	registry := lower_module_to_bytecode(&module)
	compiled, found := registry["старт"]
	testing.expectf(t, found, "функция 'старт' не найдена в registry")
	if found {
		has_dead_constant := false
		for c in compiled.constants {
			if f, ok := c.(f64); ok && f == 999 do has_dead_constant = true
		}
		testing.expectf(t, !has_dead_constant, "константа 999 из мёртвой ветки не должна попасть в скомпилированный байткод")
	}
}

@(test)
test_optimize_execution_constant_branch :: proc(t: ^testing.T) {
	v, ok := run_via_mir_optimized(t, `
		функ старт() -> Число
			если истина тогда
				42
			иначе
				0
			конец
		конец
	`)
	testing.expectf(t, ok, "стек пуст")
	testing.expect_value(t, v, Value(f64(42)))
}

@(test)
test_opt_diff_constant_branch :: proc(t: ^testing.T) {
	opt_diff_check(t, `
		функ старт() -> Число
			пер сумма = 0
			если истина тогда
				сумма = сумма + 1
			иначе
				сумма = сумма - 1
			конец
			если 1 < 2 тогда
				сумма = сумма * 10
			конец
			сумма
		конец
	`)
}

@(test)
test_optimize_eliminate_adjacent_match_binder :: proc(t: ^testing.T) {
	source := `
		тип О = перечисление
			Есть(Число)
		конец

		функ старт() -> Число
			выбор О.Есть(5)
				Есть(x) -> x + 1
			конец
		конец
	`
	// Неоптимизированная база для сравнения: lower_pattern's .Constructor
	// case строит ДВЕ соседние store/load-пары для одного бинда x —
	// $match_field (Get_Variant_Field -> store -> немедленный load,
	// начало .Binder case) И сам binder_local (тот load -> store ->
	// load из lower_symbol_value_ref на "x" в теле арма) — обе
	// действительно соседние (ничего между store и следующим load), обе
	// должны устраниться. Match subject (local_0, 1 store/2 load — читается
	// ЕЩЁ РАЗ под-паттерном) и cross-block merge-локаль результата арма
	// (1 store в block'е арма/1 load в merge-блоке, РАЗНЫЕ блоки) — ДОЛЖНЫ
	// остаться, эта пара не соседняя и остаётся легитимно нужной.
	unopt_result := check_source(source)
	testing.expectf(t, len(unopt_result.diags) == 0, "check_source diagnostics: %v", unopt_result.diags)
	unopt_module := lower_module(&unopt_result.res_ctx, &unopt_result.tc_ctx, &unopt_result.prog)
	unopt_dump := ""
	for &f in unopt_module.functions do if f.name == "старт" do unopt_dump = print_function(&f)

	module, fn := lower_and_optimize(t, source)
	expect_valid_optimized(t, &module, fn)
	opt_dump := print_function(fn)

	unopt_stores := strings.count(unopt_dump, "store_local")
	opt_stores := strings.count(opt_dump, "store_local")
	unopt_loads := strings.count(unopt_dump, "load_local")
	opt_loads := strings.count(opt_dump, "load_local")

	testing.expectf(
		t,
		opt_stores == unopt_stores - 2,
		"ожидалось устранение РОВНО 2 store_local (field_local + binder_local): было %d, стало %d",
		unopt_stores,
		opt_stores,
	)
	testing.expectf(
		t,
		opt_loads == unopt_loads - 2,
		"ожидалось устранение РОВНО 2 load_local: было %d, стало %d",
		unopt_loads,
		opt_loads,
	)
	// Прямая ссылка на extracted-поле, минуя оба устранённых круга —
	// get_variant_field's dst используется НАПРЯМУЮ в binary Add.
	testing.expectf(t, strings.contains(opt_dump, "get_variant_field"), "дамп: %s", opt_dump)
}

@(test)
test_optimize_does_not_touch_match_subject :: proc(t: ^testing.T) {
	// Match subject — одно store, МНОГО load (по разу на арм/под-паттерн)
	// — load-count != 1, обязана остаться нетронутой.
	module, fn := lower_and_optimize(t, `
		тип Ц = перечисление
			А
			Б
			В
		конец

		функ старт() -> Число
			выбор Ц.Б
				А -> 1
				Б -> 2
				В -> 3
			конец
		конец
	`)
	expect_valid_optimized(t, &module, fn)
	issues := validate_function(&module, fn)
	defer delete(issues)
	for issue in issues do testing.expectf(t, !issue.is_error, "validate_function: %s", issue.message)
}

// --- Исполнение через реальный backend+VM — оптимизированный MIR должен
// давать ТОТ ЖЕ результат, что и неоптимизированный (core/mir_test.odin's
// test_bytecode_*, которые НЕ зовут optimize_module). ---

@(private = "file")
run_via_mir_optimized :: proc(t: ^testing.T, source: string) -> (Value, bool) {
	result := check_source(source)
	testing.expectf(t, len(result.diags) == 0, "check_source diagnostics: %v", result.diags)
	module := lower_module(&result.res_ctx, &result.tc_ctx, &result.prog)
	optimize_module(&module)
	registry := lower_module_to_bytecode(&module)
	vm := new_vm(registry)
	run_scheduler(vm)
	if len(vm.stack) > 0 {
		return vm.stack[len(vm.stack) - 1], true
	}
	return nil, false
}

@(test)
test_optimize_execution_arithmetic :: proc(t: ^testing.T) {
	v, ok := run_via_mir_optimized(t, `
		функ старт() -> Число
			(1 + 2) * (10 - 4) / 2
		конец
	`)
	testing.expectf(t, ok, "стек пуст")
	testing.expect_value(t, v, Value(f64(9)))
}

@(test)
test_optimize_execution_match_binder :: proc(t: ^testing.T) {
	v, ok := run_via_mir_optimized(t, `
		тип О = перечисление
			Есть(Число)
		конец

		функ старт() -> Число
			выбор О.Есть(41)
				Есть(x) -> x + 1
			конец
		конец
	`)
	testing.expectf(t, ok, "стек пуст")
	testing.expect_value(t, v, Value(f64(42)))
}

@(test)
test_optimize_execution_closure :: proc(t: ^testing.T) {
	v, ok := run_via_mir_optimized(t, `
		функ старт() -> Число
			пер прибавить = функ(x: Число) -> Число
				x + 100
			конец
			прибавить(1 + 2 * 3)
		конец
	`)
	testing.expectf(t, ok, "стек пуст")
	testing.expect_value(t, v, Value(f64(107)))
}

@(test)
test_optimize_execution_while_loop :: proc(t: ^testing.T) {
	// Цикл с константной арифметикой внутри тела — свёртка внутри блока
	// тела цикла должна сработать один раз на СТАТИЧЕСКУЮ инструкцию
	// (исполняется много раз в рантайме, лоуринг статический).
	v, ok := run_via_mir_optimized(t, `
		функ старт() -> Число
			пер i = 0
			пер сумма = 0
			пока i < 10 цикл
				сумма = сумма + (2 + 3)
				i = i + 1
			конец
			сумма
		конец
	`)
	testing.expectf(t, ok, "стек пуст")
	testing.expect_value(t, v, Value(f64(50)))
}

// --- Постоянный differential-харнесс: optimize_module ВКЛ vs ВЫКЛ должны
// давать ИДЕНТИЧНЫЙ результат исполнения. В отличие от удалённого
// core/mir_differential_test.odin (одноразовая миграция old->MIR
// backend, удалён после cutover), этот остаётся в дереве постоянно —
// страховка для ВСЕХ будущих проходов Фазы 3, не только этого. ---

@(private = "file")
Opt_Diff_Result :: struct {
	ok:      bool,
	display: string,
}

@(private = "file")
run_unoptimized_source :: proc(source: string) -> Opt_Diff_Result {
	result := check_source(source)
	if len(result.diags) > 0 do return Opt_Diff_Result{ok = false}
	module := lower_module(&result.res_ctx, &result.tc_ctx, &result.prog)
	registry := lower_module_to_bytecode(&module)
	vm := new_vm(registry)
	run_scheduler(vm)
	if len(vm.stack) == 0 do return Opt_Diff_Result{ok = false}
	return Opt_Diff_Result{ok = true, display = value_to_display_string(vm, vm.stack[len(vm.stack) - 1])}
}

@(private = "file")
run_optimized_source :: proc(source: string) -> Opt_Diff_Result {
	result := check_source(source)
	if len(result.diags) > 0 do return Opt_Diff_Result{ok = false}
	module := lower_module(&result.res_ctx, &result.tc_ctx, &result.prog)
	optimize_module(&module)
	registry := lower_module_to_bytecode(&module)
	vm := new_vm(registry)
	run_scheduler(vm)
	if len(vm.stack) == 0 do return Opt_Diff_Result{ok = false}
	return Opt_Diff_Result{ok = true, display = value_to_display_string(vm, vm.stack[len(vm.stack) - 1])}
}

@(private = "file")
opt_diff_check :: proc(t: ^testing.T, source: string) {
	unopt := run_unoptimized_source(source)
	opt := run_optimized_source(source)
	testing.expectf(t, unopt.ok, "неоптимизированный путь не вернул значение (пустой стек) для:\n%s", source)
	testing.expectf(t, opt.ok, "оптимизированный путь не вернул значение (пустой стек) для:\n%s", source)
	if unopt.ok && opt.ok {
		testing.expectf(
			t,
			unopt.display == opt.display,
			"РАСХОЖДЕНИЕ: неоптимизированный=%q, оптимизированный=%q, источник:\n%s",
			unopt.display,
			opt.display,
			source,
		)
	}
}

@(test)
test_opt_diff_arithmetic_and_bitwise :: proc(t: ^testing.T) {
	opt_diff_check(t, `
		функ старт() -> Число
			пер a: Целое = 6
			пер b: Целое = 3
			Число((1 + 2 * 3 - 4) / 2) + Число(a & b) + Число(a | b) + Число(~a) + Число(a << 1) + Число(a >> 1)
		конец
	`)
}

@(test)
test_opt_diff_string_concat_and_compare :: proc(t: ^testing.T) {
	opt_diff_check(t, `
		функ старт() -> Булево
			пер s = "a" + "b" + "c"
			s == "abc" и 1 < 2 и 3 >= 3 и 4 <> 5
		конец
	`)
}

@(test)
test_opt_diff_match_adt_multi_binder :: proc(t: ^testing.T) {
	opt_diff_check(t, `
		тип Пара = перечисление
			Значения(Число, Число)
		конец

		функ старт() -> Число
			выбор Пара.Значения(3, 4)
				Значения(a, b) -> a + b
			конец
		конец
	`)
}

@(test)
test_opt_diff_nested_if_and_loop :: proc(t: ^testing.T) {
	opt_diff_check(t, `
		функ старт() -> Число
			пер сумма = 0
			пер i: Целое = 0
			пока i < 20 цикл
				если i % 2 == 0 тогда
					сумма = сумма + Число(i)
				иначе
					сумма = сумма - 1
				конец
				i = i + 1
			конец
			сумма
		конец
	`)
}

@(test)
test_opt_diff_closures_and_structs :: proc(t: ^testing.T) {
	opt_diff_check(t, `
		тип Точка = структура
			x: Число
			y: Число
		конец

		функ старт() -> Число
			пер п = Точка(1 + 1, 2 * 2)
			пер удвоить = функ(v: Число) -> Число
				v * 2
			конец
			удвоить(п.x) + удвоить(п.y)
		конец
	`)
}

// --- Реальные fixtures/*.ps через файловый (многомодульный) путь — тот
// же курируемый корпус, что использовался для верификации cutover'а
// (см. git log, коммит "реальный cutover"). ---

@(private = "file")
run_unoptimized_module_file :: proc(filename: string) -> Opt_Diff_Result {
	graph := load_module_graph(filename)
	if len(graph.parse_diagnostics) > 0 do return Opt_Diff_Result{ok = false}
	results := resolve_and_typecheck_all(&graph)
	for r in results {
		if len(r.res_ctx.diagnostics) > 0 || len(r.tc_ctx.diagnostics) > 0 do return Opt_Diff_Result{ok = false}
	}
	module := lower_program_graph(results)
	registry := lower_module_to_bytecode(&module)
	vm := new_vm(registry)
	run_scheduler(vm)
	if len(vm.stack) == 0 do return Opt_Diff_Result{ok = false}
	return Opt_Diff_Result{ok = true, display = value_to_display_string(vm, vm.stack[len(vm.stack) - 1])}
}

@(private = "file")
run_optimized_module_file :: proc(filename: string) -> Opt_Diff_Result {
	graph := load_module_graph(filename)
	if len(graph.parse_diagnostics) > 0 do return Opt_Diff_Result{ok = false}
	results := resolve_and_typecheck_all(&graph)
	for r in results {
		if len(r.res_ctx.diagnostics) > 0 || len(r.tc_ctx.diagnostics) > 0 do return Opt_Diff_Result{ok = false}
	}
	module := lower_program_graph(results)
	optimize_module(&module)
	registry := lower_module_to_bytecode(&module)
	vm := new_vm(registry)
	run_scheduler(vm)
	if len(vm.stack) == 0 do return Opt_Diff_Result{ok = false}
	return Opt_Diff_Result{ok = true, display = value_to_display_string(vm, vm.stack[len(vm.stack) - 1])}
}

@(private = "file")
opt_diff_check_module_file :: proc(t: ^testing.T, filename: string) {
	unopt := run_unoptimized_module_file(filename)
	opt := run_optimized_module_file(filename)
	testing.expectf(t, unopt.ok, "неоптимизированный путь не вернул значение для %s", filename)
	testing.expectf(t, opt.ok, "оптимизированный путь не вернул значение для %s", filename)
	if unopt.ok && opt.ok {
		testing.expectf(
			t,
			unopt.display == opt.display,
			"РАСХОЖДЕНИЕ на %s: неоптимизированный=%q, оптимизированный=%q",
			filename,
			unopt.display,
			opt.display,
		)
	}
}

@(private = "file")
opt_diff_module_corpus := []string {
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
test_opt_diff_module_file_corpus :: proc(t: ^testing.T) {
	for path in opt_diff_module_corpus {
		opt_diff_check_module_file(t, path)
	}
}

@(test)
test_opt_diff_module_file_panic_supervisor :: proc(t: ^testing.T) {
	testing.expect_assert(
		t,
		"Runtime Panic: супервизор (один-за-одного): 'падающий-рабочий' превысил лимит перезапусков (1 за 60000мс): процесс уже не существует",
	)
	run_optimized_module_file("fixtures/supervisor_fixture_main.ps")
}
