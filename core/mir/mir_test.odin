package mir

import core "../"
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
	result := core.check_source(source)
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
	testing.expectf(t, strings.contains(dump, "= call fn_"), "ожидался call: %s", dump)
	testing.expect_value(t, len(module.functions), 2)
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
