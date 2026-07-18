package core

// Inline-pipeline (без файлового I/O — ни module_loader, ни os) для
// программ БЕЗ реальных file-based `импорт`. Общий для WASM-входа
// (wasm/main.odin) и тестовых обёрток run_code в e2e_test.odin, поэтому
// живёт здесь, а не в помеченном `#+build !js_wasm32` e2e_test.odin
// (core:testing не собирается под js).
//
// Возвращает diagnostics явно (как данные), а не паникует первым из них —
// вызывающему коду нужны все диагностики.
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
	run_scheduler(vm)

	if len(vm.stack) > 0 {
		return vm.stack[len(vm.stack) - 1], true, nil
	}
	return 0.0, false, nil
}

Check_Result :: struct {
	prog:    Program,
	res_ctx: Resolver_Ctx,
	tc_ctx:  Type_Ctx,
	diags:   [dynamic]Diagnostic,
}

// Как run_source_with_args, но БЕЗ компиляции/исполнения и БЕЗ early-exit
// по стадиям — копит diagnostics со ВСЕХ стадий разом (тот же паттерн,
// что typecheck_only в e2e_test.odin, но с сохранением prog/res_ctx/
// tc_ctx для последующих позиционных запросов — hover/completion/lint,
// см. wasm/main.odin). Резолвер/тайпчекер accumulate-not-panic с error-
// recovery (Error-node/"hole" паттерн) — прогон всех стадий даже после
// ошибки лексера/парсера обычно даёт полезный частичный AST для позиций
// ДО места ошибки.
check_source :: proc(source: string) -> Check_Result {
	result: Check_Result
	tokens, lex_diags := tokenize(source)
	for d in lex_diags do append(&result.diags, d)

	stream := make_stream(tokens)
	parser := Parser {
		stream = &stream,
	}
	result.prog = parse_program(&parser)
	for d in parser.diagnostics do append(&result.diags, d)

	result.res_ctx = new_resolver_ctx()
	resolve_program(&result.res_ctx, result.prog)
	for d in result.res_ctx.diagnostics do append(&result.diags, d)

	result.tc_ctx = new_type_ctx(&result.res_ctx)
	typecheck_program(&result.tc_ctx, result.prog)
	for d in result.tc_ctx.diagnostics do append(&result.diags, d)

	return result
}
