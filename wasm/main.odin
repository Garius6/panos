#+feature dynamic-literals
package main

// Сборка этого пакета ОБЯЗАНА идти с -o:size (см. Justfile build-wasm /
// .github/workflows/deploy-pages.yml): дефолтный -o:minimal даёт модуль,
// на JIT-компиляции которого падает JavaScriptCore (Safari/WebKit) —
// у него отдельный, куда более скромный бюджет памяти под компилятор,
// чем у V8/Chrome.

import "base:runtime"
import core "../core"
import "core:encoding/json"
import "core:fmt"
import "core:mem"

// JS пишет исходник panos-скрипта в этот статический буфер (через
// WasmMemoryInterface.storeString на адрес из panos_source_ptr()), затем
// зовёт panos_run(len). Статический буфер вместо динамической аллокации со
// стороны JS — не нужна malloc-обвязка.
SOURCE_BUF_SIZE :: 65536
@(private)
source_buf: [SOURCE_BUF_SIZE]byte

// Один переиспользуемый Dynamic_Arena на весь WASM-инстанс, не новый на каждый
// вызов. Схема "создать арену → dynamic_arena_destroy в конце" на каждый вызов
// сама течёт: destroy free()'ит backing-блоки арены обратно в
// default_wasm_allocator (порт emmalloc), а следующий init запрашивает новые
// блоки — при фрагментированном повторном использовании это дёргает
// wasm_memory_grow() вместо переиспользования уже освобождённого места.
// Поэтому dynamic_arena_reset() вместо destroy: возвращает блоки в
// arena.unused_blocks (без реального free()), следующий вызов переиспользует
// их напрямую — стабилизируется на постоянном live-байте после первых
// нескольких вызовов, дальше не растёт.
@(private)
scratch_arena: mem.Dynamic_Arena
@(private)
scratch_arena_ready: bool

// Сбрасывает (или лениво инициализирует) shared-арену и возвращает её
// как allocator — единая точка входа для всех 4 экспортов ниже.
@(private)
reset_scratch_arena :: proc() -> runtime.Allocator {
	if !scratch_arena_ready {
		// Поднимать out_band_size до block_size (чтобы крупные
		// [dynamic]-массивы AST/диагностик не гоняли malloc/free на каждый
		// dynamic_arena_reset) НЕ стоит: на файле побольше это ловит WASM-трап
		// "memory access out of bounds" внутри
		// dynamic_arena_resize_bytes_non_zeroed — похоже на баг в core:mem при
		// in-block resize около границы block_size. Дефолтный out_band_size
		// безопасен, ценой малого остаточного роста.
		mem.dynamic_arena_init(&scratch_arena, alignment = 64)
		scratch_arena_ready = true
	} else {
		mem.dynamic_arena_reset(&scratch_arena)
	}
	return mem.dynamic_arena_allocator(&scratch_arena)
}

@(export)
panos_source_ptr :: proc "c" () -> ^byte {
	return &source_buf[0]
}

@(export)
panos_source_capacity :: proc "c" () -> int {
	return SOURCE_BUF_SIZE
}

// Синтетический путь "входного файла" плейграунда — реального файла нет
// (JS пишет исходник в source_buf), но graph-based pipeline (та же, что у
// LSP — см. lsp/lsp_server.odin::revalidate_document) требует путь-ключ
// для source_overrides. `импорт` внутри плейграунда резолвится либо через
// него (относительные импорты — всегда "не найдено", в браузере кроме
// самого плейграунда ничего нет), либо через std/, вшитую в бинарь
// (core/wasm_stdlib.odin) — см. resolver_import_wasm.odin/
// module_loader_wasm.odin.
WASM_ENTRY_PATH :: "плейграунд.ps"

// Строит Module_Graph из ОДНОГО исходника плейграунда + всех модулей,
// импортированных им (транзитивно) — только std/, реальной ФС нет.
// Раньше (single-file core.run_source/check_source) `импорт` в браузере
// не работал вообще: resolve_existing_import_path/read_file_text под
// #+build js всегда возвращали "не найдено", а run_source_with_args в
// принципе не строил граф. Теперь используется тот же
// load_module_graph_with_overrides + resolve_and_typecheck_all, что и LSP.
@(private)
wasm_load_graph :: proc(source: string) -> (graph: core.Module_Graph, results: [dynamic]core.Module_Result) {
	overrides := make(map[string]string)
	overrides[WASM_ENTRY_PATH] = source
	graph = core.load_module_graph_with_overrides(WASM_ENTRY_PATH, overrides)
	results = core.resolve_and_typecheck_all(&graph)
	return
}

// graph.order (и, следовательно, results) — топологический порядок
// зависимостей: импортируемые модули идут ПЕРЕД импортирующим
// (module_loader.odin аппендит модуль в graph.order только после того, как
// обработаны все его импорты) — значит entry обычно НЕ results[0], его надо
// искать явно по указателю на Module (graph.modules[WASM_ENTRY_PATH]), тот
// же паттерн, что revalidate_document в lsp_server.odin.
@(private)
wasm_find_entry :: proc(graph: ^core.Module_Graph, results: ^[dynamic]core.Module_Result) -> ^core.Module_Result {
	entry_module := graph.modules[WASM_ENTRY_PATH]
	if entry_module == nil do return nil
	for i in 0 ..< len(results) {
		if results[i].module == entry_module do return &results[i]
	}
	return nil
}

// Запускает panos-скрипт длиной source_len байт из source_buf. Вывод идёт
// через fmt.print*/fmt.eprint* — на js_wasm32 core:fmt сам пишет в
// odin_env.write (см. fmt_js.odin в тулчейне Odin), обвязка odin.js рендерит
// это в consoleElement страницы — без собственного JS-парсинга WASM-памяти.
//
// WASM-инстанс живёт весь сеанс страницы (в отличие от нативного CLI, где
// процесс завершается и ОС забирает память). Каждый вызов
// panos_check/panos_hover/panos_complete/panos_run заново гоняет
// tokenize→parse→resolve→typecheck(→compile→execute), и ни один
// Parser/Resolver_Ctx/Type_Ctx/Compiled_Function не освобождался явно, а у
// Odin нет GC — за сеанс набегали сотни мегабайт, браузер убивал вкладку.
// reset_scratch_arena() (см. выше) даёт каждому вызову чистый
// scratch-allocator без утечки между вызовами.
//
// free_all(context.temp_allocator) — отдельный источник: temp_allocator НЕ
// совпадает с context.allocator (его арена не трогается reset_scratch_arena) —
// это Odin-глобальный 4MB Arena (base:runtime/default_temporary_allocator.odin),
// который json.marshal использует под капотом (сортировка ключей Object) и
// который по своей документации требует ручного free_all() раз за цикл — без
// него он лениво выделяет 4MB за сеанс и никогда не освобождает.
//
// НЕ покрывает GC'd VM-значения (Aggregate/Array/Map/String и т.п., выделяются
// во время execute) — gc_new/vm_heap_allocator (gc.odin) намеренно игнорируют
// ambient context.allocator (pool_release полагается на настоящий free()
// отдельных аллокаций — Dynamic_Arena такого не даёт, см. комментарий у
// vm_heap_allocator в gc.odin). Это отдельный, меньший остаточный лик —
// полноценный fix требует менять GC-архитектуру под одноразовый VM (сейчас она
// рассчитана на долгоживущий процесс с переиспользуемыми пулами), вне scope.
@(export)
panos_run :: proc "c" (source_len: int) {
	context = runtime.default_context()
	context.allocator = reset_scratch_arena()
	free_all(context.temp_allocator)

	// odin.js writeToConsole копит вывод в закрытый массив infoConsoleLines
	// и перерисовывает весь #console из него — JS-сторона не может очистить
	// это состояние (не exposed на window.odin). Раз "очистить между
	// запусками" недоступно, разделитель печатаем отсюда — то же API, тот же
	// поток, без гонки с внутренним состоянием рантайма.
	fmt.println("── запуск ──")

	if source_len < 0 || source_len > SOURCE_BUF_SIZE {
		fmt.eprintln("Ошибка спайка: исходник длиннее буфера демо")
		return
	}
	source := string(source_buf[:source_len])

	graph, results := wasm_load_graph(source)

	// Тот же accumulate-not-panic гейт, что run_file в main.odin (native
	// CLI) — diagnostics со всех стадий и всех модулей графа разом, не
	// только первая упавшая.
	all_diags := make([dynamic]core.Diagnostic)
	for d in graph.parse_diagnostics do append(&all_diags, d)
	for r in results {
		for d in r.res_ctx.diagnostics do append(&all_diags, d)
		for d in r.tc_ctx.diagnostics do append(&all_diags, d)
	}
	if len(all_diags) > 0 {
		for d in all_diags {
			fmt.eprintln(d.message)
		}
		return
	}

	global_registry := make(map[string]^core.Compiled_Function)
	if len(results) > 0 {
		core.ensure_prelude_compiled(&results[0].res_ctx, &global_registry)
	}
	for i in 0 ..< len(results) {
		r := &results[i]
		core.compile_program(&r.res_ctx, &r.tc_ctx, &r.module.ast, &global_registry)
	}

	vm := core.new_vm(global_registry, nil)
	core.run_scheduler(vm)

	if len(vm.stack) > 0 {
		result := vm.stack[len(vm.stack) - 1]
		// ^Panos_String через голый %v печатается как Odin-структура (см.
		// print_vm в vm.odin — тот же unwrap для той же причины) — достаём
		// .data явно, иначе строка попадёт на страницу как
		// "&Panos_String{header = ..., data = \"текст\"}".
		if ps, ok := result.(^core.Panos_String); ok {
			fmt.println(ps.data)
		} else {
			fmt.println(result)
		}
	}
}

// LSP-lite: прямые экспорты вместо полного LSP-протокола — браузерное
// демо принципиально single-buffer (одно текстовое поле, без набора
// открытых файлов), так что полноценный JSON-RPC/LSP_Document (lsp/
// lsp_server.odin) тут не нужен. Но `импорт` теперь резолвится через тот
// же graph-based pipeline (wasm_load_graph/wasm_find_entry выше), что и
// panos_run — иначе hover/diagnostics/completion не видели бы типы из
// std/, импортированной в плейграунде.
RESULT_BUF_SIZE :: 65536
@(private)
result_buf: [RESULT_BUF_SIZE]byte
@(private)
result_len: int

@(private)
write_result :: proc(data: []byte) {
	n := len(data)
	if n > RESULT_BUF_SIZE do n = RESULT_BUF_SIZE
	copy(result_buf[:n], data[:n])
	result_len = n
}

@(private)
write_result_string :: proc(s: string) {
	write_result(transmute([]byte)s)
}

@(export)
panos_result_ptr :: proc "c" () -> ^byte {
	return &result_buf[0]
}

@(export)
panos_result_len :: proc "c" () -> int {
	return result_len
}

@(private)
source_from_buf :: proc(source_len: int) -> (string, bool) {
	if source_len < 0 || source_len > SOURCE_BUF_SIZE do return "", false
	return string(source_buf[:source_len]), true
}

@(private)
add_diag_if_own_file :: proc(items: ^[dynamic]json.Value, source: string, file_id: u16, d: core.Diagnostic) {
	// parse_diagnostics — плоский список по ВСЕМ модулям графа (включая
	// std/, если бы там была ошибка); diagnostics плейграунда (единственный
	// видимый пользователю буфер) — только с его file_id, иначе from/to
	// считались бы как UTF-16 offset в ЧУЖОМ source.
	if d.span.file_id != file_id do return
	append(
		items,
		json.Value(
			json.Object {
				"from" = json.Integer(i64(core.byte_offset_to_utf16_offset(source, d.span.start))),
				"to" = json.Integer(i64(core.byte_offset_to_utf16_offset(source, d.span.end))),
				"severity" = json.String("error"),
				"message" = json.String(d.message),
			},
		),
	)
}

// Диагностики source_buf'а как JSON-массив {from, to, severity, message} —
// формат напрямую под @codemirror/lint's Diagnostic (from/to — плоский
// UTF-16 offset от начала документа, не line/character, как у LSP).
// Арена — см. развёрнутый комментарий у panos_run выше. Компиляция/
// исполнение не трогаются (только tokenize/parse/resolve/typecheck по
// всему графу) — покрытие аренами полное, без остаточного лика.
@(export)
panos_check :: proc "c" (source_len: int) {
	context = runtime.default_context()
	context.allocator = reset_scratch_arena()
	free_all(context.temp_allocator)

	source, ok := source_from_buf(source_len)
	if !ok {
		write_result_string("[]")
		return
	}

	graph, results := wasm_load_graph(source)
	entry := wasm_find_entry(&graph, &results)
	if entry == nil {
		write_result_string("[]")
		return
	}

	items := make([dynamic]json.Value)
	for d in graph.parse_diagnostics do add_diag_if_own_file(&items, source, entry.module.file_id, d)
	for d in entry.res_ctx.diagnostics do add_diag_if_own_file(&items, source, entry.module.file_id, d)
	for d in entry.tc_ctx.diagnostics do add_diag_if_own_file(&items, source, entry.module.file_id, d)

	data, _ := json.marshal(json.Array(items), {})
	write_result(data)
}

// Тип выражения под offset (плоский UTF-16, от CodeMirror) — {type, from,
// to} или null. Тот же паттерн, что handle_hover в lsp_server.odin —
// find_expr_in_program + node_types.
// Арена — см. комментарий у panos_run/panos_check выше. Полное покрытие,
// как у panos_check (тоже без compile/execute).
@(export)
panos_hover :: proc "c" (source_len: int, offset: int) {
	context = runtime.default_context()
	context.allocator = reset_scratch_arena()
	free_all(context.temp_allocator)

	source, ok := source_from_buf(source_len)
	if !ok {
		write_result_string("null")
		return
	}

	graph, results := wasm_load_graph(source)
	entry := wasm_find_entry(&graph, &results)
	if entry == nil {
		write_result_string("null")
		return
	}

	byte_offset := core.utf16_offset_to_byte_offset(source, offset)
	expr := core.find_expr_in_program(entry.module.ast, entry.module.file_id, byte_offset)
	if expr == nil {
		write_result_string("null")
		return
	}
	typ, has_type := entry.tc_ctx.node_types[expr]
	if !has_type || typ == nil {
		write_result_string("null")
		return
	}

	sp := core.expr_span(expr)
	obj := json.Object {
		"type" = json.String(core.prune_type(typ).name),
		"from" = json.Integer(i64(core.byte_offset_to_utf16_offset(source, sp.start))),
		"to" = json.Integer(i64(core.byte_offset_to_utf16_offset(source, sp.end))),
	}
	data, _ := json.marshal(json.Value(obj), {})
	write_result(data)
}

// Dot-completion (`receiver.` -> поля/методы/варианты) — JSON-массив
// {label, kind}, kind — CodeMirror-стиль ("field"/"method"/"variant"),
// не LSP CompletionItemKind (тот числовой, тут строковый — проще
// смаппить на стороне JS под @codemirror/autocomplete). Тот же offset-
// арифметика, что handle_completion в lsp_server.odin (offset-2, не
// offset-1 — точка сама вне span'а receiver'а, см. комментарий там).
// Арена — см. комментарий у panos_run/panos_check выше. Полное покрытие,
// как у panos_check (тоже без compile/execute).
@(export)
panos_complete :: proc "c" (source_len: int, offset: int) {
	context = runtime.default_context()
	context.allocator = reset_scratch_arena()
	free_all(context.temp_allocator)

	source, ok := source_from_buf(source_len)
	if !ok {
		write_result_string("[]")
		return
	}

	byte_offset := core.utf16_offset_to_byte_offset(source, offset)
	if byte_offset < 2 || source[byte_offset - 1] != '.' {
		write_result_string("[]")
		return
	}

	graph, results := wasm_load_graph(source)
	entry := wasm_find_entry(&graph, &results)
	if entry == nil {
		write_result_string("[]")
		return
	}

	receiver_expr := core.find_expr_in_program(entry.module.ast, entry.module.file_id, byte_offset - 2)
	if receiver_expr == nil {
		write_result_string("[]")
		return
	}
	typ, has_type := entry.tc_ctx.node_types[receiver_expr]
	if !has_type || typ == nil {
		write_result_string("[]")
		return
	}

	members := core.type_completion_members(typ)
	items := make([dynamic]json.Value)
	seen := make(map[string]bool, allocator = context.temp_allocator)
	for m in members {
		if m.name == "" || seen[m.name] do continue
		seen[m.name] = true
		kind_str := "field"
		switch m.kind {
		case .Field:
			kind_str = "field"
		case .Method:
			kind_str = "method"
		case .Variant:
			kind_str = "variant"
		}
		append(&items, json.Value(json.Object{"label" = json.String(m.name), "kind" = json.String(kind_str)}))
	}
	data, _ := json.marshal(json.Array(items), {})
	write_result(data)
}

main :: proc() {}
