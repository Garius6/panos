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

	result, has_result, diags := core.run_source(source)
	if len(diags) > 0 {
		for d in diags {
			fmt.eprintln(d.message)
		}
		return
	}
	if has_result {
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

// LSP-lite: прямые экспорты вместо полного LSP-протокола — panos-lsp
// (lsp/lsp_server.odin) весь про многофайловый граф импортов (Module_Graph,
// overrides для незаписанных буферов), а браузерное демо принципиально
// single-file, вся эта инфраструктура тут не нужна. Переиспользует
// core.check_source (core/pipeline.odin) + core.find_expr_in_program
// (core/position.odin) — те же функции, что и panos-lsp, но без JSON-RPC
// обвязки и без графа модулей.
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

// Диагностики source_buf'а как JSON-массив {from, to, severity, message} —
// формат напрямую под @codemirror/lint's Diagnostic (from/to — плоский
// UTF-16 offset от начала документа, не line/character, как у LSP).
// Арена — см. развёрнутый комментарий у panos_run выше. check_source
// (в отличие от panos_run) не трогает vm_heap_allocator вообще — не
// компилирует и не исполняет, только tokenize/parse/resolve/typecheck —
// значит покрытие аренами здесь ПОЛНОЕ, без остаточного лика.
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

	check := core.check_source(source)
	items := make([dynamic]json.Value)
	for d in check.diags {
		append(
			&items,
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
	data, _ := json.marshal(json.Array(items), {})
	write_result(data)
}

// Тип выражения под offset (плоский UTF-16, от CodeMirror) — {type, from,
// to} или null. Тот же паттерн, что handle_hover в lsp_server.odin —
// find_expr_in_program + node_types.
// Арена — см. комментарий у panos_run/panos_check выше. Полное покрытие,
// как у panos_check (тоже только check_source, без compile/execute).
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

	check := core.check_source(source)
	byte_offset := core.utf16_offset_to_byte_offset(source, offset)
	expr := core.find_expr_in_program(check.prog, 0, byte_offset)
	if expr == nil {
		write_result_string("null")
		return
	}
	typ, has_type := check.tc_ctx.node_types[expr]
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
// как у panos_check (тоже только check_source, без compile/execute).
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

	check := core.check_source(source)
	receiver_expr := core.find_expr_in_program(check.prog, 0, byte_offset - 2)
	if receiver_expr == nil {
		write_result_string("[]")
		return
	}
	typ, has_type := check.tc_ctx.node_types[receiver_expr]
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
