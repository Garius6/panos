#+feature dynamic-literals
package main

import "base:runtime"
import core "../core"
import "core:encoding/json"
import "core:fmt"
import "core:mem"

// Спайк-демо: JS пишет исходник panos-скрипта в этот статический буфер
// (через WasmMemoryInterface.storeString на адрес из panos_source_ptr()),
// затем зовёт panos_run(len). Простое, но достаточное решение для v1 —
// без динамической аллокации со стороны JS (никакой malloc-обвязки).
SOURCE_BUF_SIZE :: 65536
@(private)
source_buf: [SOURCE_BUF_SIZE]byte

// Один переиспользуемый Dynamic_Arena на весь WASM-инстанс (не новый на
// каждый вызов) — попытка "создать арену → dynamic_arena_destroy в конце"
// на каждый вызов (первая версия этого фикса) САМА оказалась источником
// утечки: destroy реально free()'ит backing-блоки арены обратно в
// default_wasm_allocator (порт emmalloc), а следующий init запрашивает
// НОВЫЕ блоки — при неидеальном повторном использовании фрагментами
// это раз за разом дёргает wasm_memory_grow() вместо переиспользования
// уже освобождённого места (эмпирически подтверждено: ~4.7KB/вызов
// panos_check, ~8.5KB/вызов panos_hover утекало ДАЖЕ с аренами). Фикс —
// dynamic_arena_reset() вместо destroy: возвращает блоки в arena's
// unused_blocks (реальный free() НЕ вызывается), следующий вызов их
// переиспользует напрямую — подтверждено нативным прогоном с
// Tracking_Allocator: 2000 повторных check_source стабилизируются на
// одном и том же live-байте после первых ~5 вызовов, без роста дальше.
@(private)
scratch_arena: mem.Dynamic_Arena
@(private)
scratch_arena_ready: bool

// Сбрасывает (или лениво инициализирует) shared-арену и возвращает её
// как allocator — единая точка входа для всех 4 экспортов ниже.
@(private)
reset_scratch_arena :: proc() -> runtime.Allocator {
	if !scratch_arena_ready {
		// out_band_size = block_size — умолчание (10% от block_size, ~6.5KB)
		// отправляло любую аллокацию ≥6.5KB (типичные [dynamic]-массивы
		// AST/диагностик) по отдельному malloc/free-циклу ПРИ КАЖДОМ
		// dynamic_arena_reset (см. блок "outband" в комментарии выше вокруг
		// scratch_arena) — сами блоки переиспользовались (used/unused
		// подтверждено стабильными через panos_debug_arena), а вот out-of-
		// band malloc+free каждый вызов на default_wasm_allocator (emmalloc)
		// не был идеально memory-neutral, что и давало остаточный рост.
		// Подняв порог до размера блока, обычные in-block аллокации (всё,
		// что умещается в один блок) остаются в пуле и переиспользуются
		// как used_blocks/unused_blocks, без единого malloc/free после
		// первого вызова.
		mem.dynamic_arena_init(&scratch_arena, alignment = 64, out_band_size = mem.DYNAMIC_ARENA_BLOCK_SIZE_DEFAULT)
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
// odin_env.write (см. fmt_js.odin в тулчейне Odin), рантайм-обвязка
// odin.js рендерит это в consoleElement страницы — без единой строчки
// собственного JS-парсинга WASM-памяти под каждый print.
// WASM-инстанс живёт ВЕСЬ сеанс страницы (не как нативный CLI, где
// процесс завершается после одного прогона и ОС сама забирает всю
// память) — каждый вызов panos_check/panos_hover/panos_complete/
// panos_run заново гоняет tokenize→parse→resolve→typecheck(→compile→
// execute), и ни один Parser/Resolver_Ctx/Type_Ctx/Compiled_Function
// никогда явно не освобождался, а у Odin нет собственного GC. Живой баг
// (подтверждён замером): ~180KB утекало ЗА ВЫЗОВ panos_check — линтер
// гоняет его на каждое изменение документа, за несколько минут набора
// текста набегали сотни мегабайт, браузер убивал вкладку ("страница
// перезагружена из-за ошибки"). reset_scratch_arena() (см. определение
// выше) даёт каждому вызову чистый scratch-allocator без утечки между
// вызовами. free_all(context.temp_allocator) — отдельный источник:
// context.temp_allocator НЕ совпадает с context.allocator (его арена
// НЕ трогается reset_scratch_arena) — это Odin-глобальный 4MB Arena
// (base:runtime/default_temporary_allocator.odin), который json.marshal
// использует под капотом (сортировка ключей Object) и который по своей
// же документации ("typically called with free_all() once per frame-
// loop") требует ручного сброса — без него первое обращение к нему за
// весь сеанс страницы лениво выделяет и больше никогда не освобождает
// эти 4MB (подтверждено эмпирически: рост ровно ~4.26MB одним скачком
// на несколько сотен вызовов вперёд, а не постепенно).
//
// НЕ покрывает GC'd VM-значения (Aggregate/Array/Map/String и т.п.,
// выделяются во время panos_run's execute) — gc_new/vm_heap_allocator
// (gc.odin) намеренно ИГНОРИРУЮТ ambient context.allocator (pool_release
// полагается на настоящий free() отдельных аллокаций — Dynamic_Arena
// такого не даёт, см. комментарий у vm_heap_allocator в gc.odin). Это
// отдельный, меньший по объёму остаточный лик — полноценный fix для
// panos_run требует менять саму GC-архитектуру под "одноразовый VM"
// (сейчас она рассчитана на один долгоживущий процесс с переиспользуемыми
// пулами), вне scope этого патча.
@(export)
panos_run :: proc "c" (source_len: int) {
	context = runtime.default_context()
	context.allocator = reset_scratch_arena()
	free_all(context.temp_allocator)

	// odin.js's writeToConsole копит вывод в закрытый (не доступный извне)
	// массив infoConsoleLines и перерисовывает ВЕСЬ #console из него на
	// каждый print — JS-сторона не может ни очистить, ни узнать про это
	// состояние снаружи (не exposed на window.odin). Раз "очистить между
	// запусками" architecturally недоступно, разделитель печатаем прямо
	// отсюда — то же самое API, тот же поток, без гонки с внутренним
	// состоянием рантайма.
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
		// ^Panos_String печатается как Odin-структура через голый %v (см.
		// print_vm в vm.odin — тот же unwrap там, для той же причины) —
		// достаём .data явно, иначе результат-строка попадает на страницу
		// как "&Panos_String{header = ..., data = \"текст\"}".
		if ps, ok := result.(^core.Panos_String); ok {
			fmt.println(ps.data)
		} else {
			fmt.println(result)
		}
	}
}

// LSP-lite: несколько прямых экспортов вместо полного LSP-протокола —
// panos-lsp (lsp/lsp_server.odin) целиком про МНОГОФАЙЛОВЫЙ граф импортов
// (Module_Graph, overrides для незаписанных буферов), а браузерное демо
// принципиально single-file (см. заметку у panos_run выше) — вся эта
// инфраструктура тут не нужна. Переиспользует core.check_source (core/
// pipeline.odin) + core.find_expr_in_program (core/position.odin) — те
// же низкоуровневые функции, что использует panos-lsp, просто без
// JSON-RPC обвязки и без графа модулей.
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
