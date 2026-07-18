#+build !js
package core

import "core:os"
import "core:sync"
import "core:testing"

// Парсер, резолвер и тайпчекер больше не panic'уют на первой ошибке — все
// три копят diagnostic'и в собственный []Diagnostic (Parser.diagnostics,
// Resolver_Ctx.diagnostics, Type_Ctx.diagnostics — общий accumulate-not-panic
// паттерн, см. report()/report_parse()/report_resolve()). run_file в
// main.odin печатает их все и выходит до компиляции; здесь — тот же гейт,
// но вместо печати panic'уем с текстом ПЕРВОГО diagnostic'а (в порядке
// pipeline: parse → resolve → typecheck, как раньше первый panic случался
// на самой ранней стадии). Это сохраняет поведение старых
// `testing.expect_assert(t, "...")` тестов без переписывания. Тесты,
// которые хотят проверить накопление НЕСКОЛЬКИХ ошибок разом, используют
// expect_diagnostic ниже вместо этого моста.
panic_on_diagnostics :: proc(diags: [dynamic]Diagnostic) {
	if len(diags) > 0 {
		panic(diags[0].message)
	}
}

// Тонкая panic-обёртка поверх run_source_with_args (core/pipeline.odin) —
// сам пайплайн переехал туда, т.к. нужен и WASM-входу, которому этот файл
// (тянет core:testing, не собирается под js_wasm32) недоступен. Панику на
// первом diagnostic'е сохраняем ради ~200 существующих `run_code(...)` по
// тестам этого файла — не переписываем их все на explicit-diagnostics API.
run_code_with_args :: proc(source: string, program_args: []string = nil) -> (Value, bool) {
	result, has_result, diags := run_source_with_args(source, program_args)
	panic_on_diagnostics(diags)
	return result, has_result
}

run_code :: proc(source: string) -> (Value, bool) {
	return run_code_with_args(source)
}

// odin test гоняет тесты в НЕСКОЛЬКО потоков одновременно (по умолчанию,
// см. -define:ODIN_TEST_THREADS) — os.stdout ниже ГЛОБАЛЬНОЕ состояние
// процесса, не per-thread, так что без сериализации два теста, зовущие
// run_code_capture_stdout параллельно, гонятся за одним и тем же
// редиректом: один поток видит чужой вывод примешанным в свой (флейк,
// разный "случайный" тест падает от прогона к прогону). Мьютекс делает
// подмену os.stdout атомарной операцией на всю функцию, а не только на
// сам своп.
capture_stdout_mutex: sync.Mutex

// Стадия 23 (Печатаемое): ввод_вывод::печать/строка пишут через
// fmt.print/fmt.println в os.stdout (fmt перечитывает os.stdout при
// КАЖДОМ вызове, не кэширует writer) — подменяем глобал на временный
// файл на время run_code, чтобы e2e-тесты могли проверить РЕАЛЬНЫЙ
// печатаемый текст (structural-дамп/вызов вСтроку()), а не только
// "выполнилось без паники".
run_code_capture_stdout :: proc(source: string) -> (Value, bool, string) {
	sync.mutex_lock(&capture_stdout_mutex)
	defer sync.mutex_unlock(&capture_stdout_mutex)

	tmp_path := "/tmp/panos_e2e_stdout_capture.txt"
	file, create_err := os.create(tmp_path)
	if create_err != nil {
		panic("не удалось создать временный файл для захвата stdout")
	}
	old_stdout := os.stdout
	os.stdout = file
	// Найдено при Стадии 25: run_code паникует на diagnostic'ах
	// (panic_on_diagnostics) — без defer тут os.stdout НИКОГДА не
	// восстанавливался бы при панике, оставляя редирект висеть на
	// СЛЕДУЮЩИЙ тест, использующий эту же функцию (интерференция через
	// общий os.stdout, не сам файл — path переиспользуется намеренно,
	// но stdout — глобальное состояние процесса).
	defer {
		os.stdout = old_stdout
		os.close(file)
		os.remove(tmp_path)
	}
	result, ok := run_code(source)
	data, _ := os.read_entire_file(tmp_path, context.temp_allocator)
	return result, ok, string(data)
}

run_module_file :: proc(filename: string) -> (Value, bool) {
	graph := load_module_graph(filename)
	registry := make(map[string]^Compiled_Function)

	// resolve_and_typecheck_all — общий с main.odin::run_file и
	// lsp/lsp_server.odin::revalidate_document путь. Раньше этот тест
	// гонял СВОЙ отдельный цикл, из-за чего регрессия в общем коде
	// (dangling Type_Ctx.res после копирования Module_Result в массив)
	// проходила мимо всего test suite — теперь тот же путь, что и CLI.
	results := resolve_and_typecheck_all(&graph)
	for r in results {
		panic_on_diagnostics(r.res_ctx.diagnostics)
		panic_on_diagnostics(r.tc_ctx.diagnostics)
	}
	if len(results) > 0 {
		ensure_prelude_compiled(&results[0].res_ctx, &registry)
	}
	for i in 0 ..< len(results) {
		r := &results[i]
		compile_program(&r.res_ctx, &r.tc_ctx, &r.module.ast, &registry)
	}

	vm := new_vm(registry)
	run_scheduler(vm)

	if len(vm.stack) > 0 {
		return vm.stack[len(vm.stack) - 1], true
	}
	return 0.0, false
}

// Стадия 45: как run_module_file, но останавливается ПОСЛЕ resolve+
// typecheck (не компилирует/не исполняет) и возвращает накопленные
// diagnostic'и со всех модулей графа разом — для негативных тестов на
// `запусти Модуль.функция(...)` (модуль/функция не существуют), где
// нужен РЕАЛЬНЫЙ импорт (в отличие от typecheck_only, у которого
// Resolver_Ctx.module_graph == nil — однофайловый путь, см. её пометку).
typecheck_only_module_file :: proc(filename: string) -> [dynamic]Diagnostic {
	graph := load_module_graph(filename)
	results := resolve_and_typecheck_all(&graph)
	all := make([dynamic]Diagnostic)
	for d in graph.parse_diagnostics do append(&all, d)
	for r in results {
		for d in r.res_ctx.diagnostics do append(&all, d)
		for d in r.tc_ctx.diagnostics do append(&all, d)
	}
	return all
}

// Прогоняет только парсинг+резолв+типизацию (без компиляции/исполнения) и
// возвращает накопленные diagnostic'и СО ВСЕХ трёх стадий разом — для
// тестов, которые хотят увидеть ВСЕ ошибки, а не только первую (в отличие
// от run_code, который через panic_on_diagnostics останавливается на первой).
typecheck_only :: proc(source: string) -> [dynamic]Diagnostic {
	tokens, lex_diags := tokenize(source)
	stream := make_stream(tokens)
	parser := Parser {
		stream = &stream,
	}
	prog := parse_program(&parser)

	res_ctx := new_resolver_ctx()
	resolve_program(&res_ctx, prog)

	type_ctx := new_type_ctx(&res_ctx)
	typecheck_program(&type_ctx, prog)

	all := make([dynamic]Diagnostic)
	for d in lex_diags do append(&all, d)
	for d in parser.diagnostics do append(&all, d)
	for d in res_ctx.diagnostics do append(&all, d)
	for d in type_ctx.diagnostics do append(&all, d)
	return all
}

// Value.string теперь ^Panos_String (см. gc.odin) — прямое `value == "лит"`
// больше не компилируется (нет неявной конвертации), а `value == Value(...)`
// сравнивало бы указатели, а не содержимое. Тестам, которые раньше писали
// `result == "литерал"`, нужен явный, content-based хелпер.
value_str_eq :: proc(v: Value, expected: string) -> bool {
	s, ok := v.(^Panos_String)
	return ok && s.data == expected
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
