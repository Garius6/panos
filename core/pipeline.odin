package core

// Inline-pipeline (без файлового I/O — ни module_loader, ни os) для
// программ БЕЗ реальных file-based `импорт`. Вынесено из e2e_test.odin
// (было test-only run_code/run_code_with_args) в постоянный файл по двум
// причинам: (1) core/e2e_test.odin помечен `#+build !js_wasm32` (тянет
// core:testing, которая не собирается под js в этом Odin-тулчейне) — сам
// пайплайн нужен и WASM-входу (wasm/main.odin), которому core:testing не
// нужен вообще; (2) не дублировать одну и ту же 30-строчную цепочку
// tokenize→parse→resolve→typecheck→compile→execute в двух местах.
//
// В отличие от старого run_code_with_args (паниковал текстом первого
// diagnostic'а — удобно для тестов, но непригодно для вызывающего кода,
// которому нужны ВСЕ diagnostic'и как данные, не как panic), run_source_
// with_args возвращает diagnostics явно. e2e_test.odin's run_code/
// run_code_with_args остаются (в e2e_test.odin) тонкими panic-обёртками
// поверх этой функции — существующие ~200 вызовов run_code(...) по тестам
// не переписываются.
run_source_with_args :: proc(
	source: string,
	program_args: []string = nil,
) -> (
	result: Value,
	has_result: bool,
	diags: [dynamic]Diagnostic,
) {
	// 1. Лексика и Парсинг
	tokens, lex_diags := tokenize(source)
	if len(lex_diags) > 0 do return 0.0, false, lex_diags
	stream := make_stream(tokens)
	parser := Parser {
		stream = &stream,
	}
	prog := parse_program(&parser)
	if len(parser.diagnostics) > 0 do return 0.0, false, parser.diagnostics

	// 2. Резолв и Типизация
	res_ctx := new_resolver_ctx()
	resolve_program(&res_ctx, prog)
	if len(res_ctx.diagnostics) > 0 do return 0.0, false, res_ctx.diagnostics

	type_ctx := new_type_ctx(&res_ctx)
	typecheck_program(&type_ctx, prog)
	if len(type_ctx.diagnostics) > 0 do return 0.0, false, type_ctx.diagnostics

	// 3. Компиляция
	registry := make(map[string]^Compiled_Function)
	ensure_prelude_compiled(&res_ctx, &registry)
	compile_program(&res_ctx, &type_ctx, &prog, &registry)

	// 4. Выполнение (VM)
	vm := new_vm(registry, program_args)
	execute(vm)

	if len(vm.stack) > 0 {
		return vm.stack[len(vm.stack) - 1], true, nil
	}
	return 0.0, false, nil
}

run_source :: proc(source: string) -> (result: Value, has_result: bool, diags: [dynamic]Diagnostic) {
	return run_source_with_args(source)
}
