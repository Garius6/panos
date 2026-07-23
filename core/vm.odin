package core

import "base:runtime"
import "core:bufio"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:sync/chan"
import "core:thread"
import "core:time"
import "core:unicode"
import "core:unicode/utf8"

Main_Function_Name :: "старт"

CallFrame :: struct {
	function:      ^Compiled_Function,
	ip:            int, // Указатель текущей инструкции в ЭТОЙ функции
	frame_pointer: int, // Индекс в vm.stack, где начинаются локальные переменные ЭТОЙ функции
	// Стадия 48 (замыкания): nil для обычного вызова обычной функции.
	// Если callee — ^Closure_Value (не голая ^Compiled_Function), сюда
	// кладётся сам Closure_Value — .Get_Captured читает
	// closure.captured[idx] напрямую отсюда.
	closure:       ^Closure_Value,
}

// Стадия 24 (actor model): что вернул execute() — доработала ли текущая
// функция до конца (frames опустели) или приостановилась на .Receive/
// .Receive_Signal с пустой очередью (ip остался НА инструкции, resume =
// повторный вызов execute() для того же процесса).
// Стадия 38 (monitor): .Crashed — процесс словил catchable runtime-
// ошибку (паника()/деление на ноль/индекс за границей — см. VM.crash_
// message) вместо fmt.panicf, который раньше ронял ВСЮ программу.
// run_scheduler решает, что делать: для "старт()" (i==0) — по-прежнему
// fmt.panicf (фатально, как раньше), для остальных процессов — изоляция
// (см. notify_watchers).
Exec_Result :: enum {
	Completed,
	Suspended,
	Crashed,
}

VM :: struct {
	frames:             [dynamic]CallFrame,
	compiled_functions: map[string]^Compiled_Function,
	stack:              [dynamic]Value,
	program_args:       []string,
	gc:                 GC_State,
	// Единый буферизованный reader над os.stdin — вне зависимости от того,
	// сколько раз вызван ввод_вывод.поток(), реальный поток ОС читается
	// ровно одним bufio.Reader'ом (см. get_stdin_reader). Несколько
	// независимых bufio.Reader поверх одного os.stdin буферизовали бы
	// каждый свой кусок и теряли байты, уже вычитанные другим.
	stdin_reader:       bufio.Reader,
	stdin_reader_ready: bool,
	// Стадия 24 (actor model): все живые процессы (включая старт() —
	// "процесс #0", см. new_vm). .frames/.stack выше — это ТЕКУЩЕГО
	// (сейчас исполняемого) процесса, свопнутые в планировщиком
	// (run_scheduler) перед вызовом execute(); current_process — его
	// индекс в processes, нужен для root-marking'а в GC (mark_roots
	// обходит vm.frames/vm.stack для текущего процесса напрямую, а НЕ
	// через processes[current_process].frames — та копия дескриптора
	// dynamic array может быть устаревшей относительно vm.frames после
	// append/реаллокации, синхронизируется только при swap обратно).
	processes:          [dynamic]^Process_Value,
	current_process:    int,
	next_process_id:    int,
	// Стадия 38 (monitor): выставляется catchable-сайтом ПЕРЕД
	// return .Crashed из execute() — run_scheduler читает его сразу
	// после возврата (см. Exec_Result.Crashed).
	crash_message:      string,
	// Стадия 46 (время.монотонно_мс): момент старта VM — эпоха, от
	// которой отсчитываются монотонные тики. Tick (не Time/wall-clock)
	// — иммунна к переводу системных часов, то же обоснование, что у
	// sliding-window лимита рестартов в std/супервизор.ps.
	monotonic_epoch:    time.Tick,
	// Неблокирующий I/O: воркер-пул + канал завершений. Тип thread.Pool/
	// chan.Chan компилируется на ВСЕХ платформах (core:thread/core:sync/chan
	// без #+build-тегов на сами типы), но core:thread НЕ поддержан на
	// js/wasi/orca (thread.IS_SUPPORTED — compile-time константа) —
	// реальная инициализация/использование этих полей — ТОЛЬКО под
	// `when thread.IS_SUPPORTED` (new_vm) и из #+build !js файлов
	// (vm_async_io_native.odin). Воркер пишет сюда ТОЛЬКО простые Odin-
	// типы (Async_Result — см. vm_async.odin), никогда Value/GC-указатели.
	async_pool:         thread.Pool,
	async_completions:  chan.Chan(Async_Result),
	next_ticket_id:     int,
}

// get_stdin_reader — в vm_io_native.odin/vm_io_wasm.odin (#+build split,
// см. заметку у File_Value в compiler.odin) — трогает os.stdin.

new_vm :: proc(
	compiled_functions: map[string]^Compiled_Function,
	program_args: []string = nil,
) -> ^VM {
	vm := new(VM)
	vm.program_args = program_args
	vm.gc = new_gc_state()
	vm.monotonic_epoch = time.tick_now()

	vm.compiled_functions = compiled_functions

	// Неблокирующий I/O: пул воркеров + канал завершений. thread.IS_SUPPORTED
	// — compile-time константа (false на js/wasi/orca, core/thread/
	// thread_other.odin) — под wasm эта ветка целиком выкидывается на этапе
	// компиляции, поля остаются нулевыми (никогда не читаются — submit_
	// async_io существует только в #+build !js файле, а сеть::http_запрос
	// и так безусловно паникует на wasm, vm_http_wasm.odin).
	when thread.IS_SUPPORTED {
		thread.pool_init(&vm.async_pool, context.allocator, 4)
		thread.pool_start(&vm.async_pool)
		completions, chan_err := chan.create_buffered(chan.Chan(Async_Result), 256, context.allocator)
		if chan_err != nil {
			fmt.panicf("VM Error: не удалось создать канал асинхронного I/O: %v", chan_err)
		}
		vm.async_completions = completions
	}

	main_func, ok := vm.compiled_functions[Main_Function_Name]
	if !ok {
		fmt.panicf("Не определена функция 'старт'")
	}

	// Стадия 24 (actor model): старт() — "процесс #0", та же
	// Process_Value-инфраструктура, что запусти-порождённые процессы
	// (Вопрос 6 грилинга) — без спецкейсов в планировщике дальше.
	// Единственное, что здесь особенное — САМО создание (никто не
	// "запускает" старт(), в отличие от остальных процессов).
	main_process := gc_new(vm, Process_Value)
	main_process.id = vm.next_process_id
	vm.next_process_id += 1
	main_process.is_alive = true
	append(&main_process.frames, CallFrame{function = main_func, ip = 0, frame_pointer = 0})
	for _ in 0 ..< main_func.frame_size {
		append(&main_process.stack, 0.0) // Резервируем слоты локальных под нулями
	}
	append(&vm.processes, main_process)
	vm.current_process = 0

	// Свопаем данные процесса #0 в vm.frames/vm.stack сразу — execute()
	// работает НАД vm.frames/vm.stack напрямую (см. Exec_Result), не
	// над processes[i].frames напрямую.
	vm.frames = main_process.frames
	vm.stack = main_process.stack

	return vm
}

return_from_current_frame :: proc(vm: ^VM, result: Value) {
	frame := &vm.frames[len(vm.frames) - 1]
	callee_index := frame.frame_pointer - 1
	resize_to := callee_index
	if resize_to < 0 do resize_to = 0
	resize(&vm.stack, resize_to)
	if frame.function.returns_value {
		append(&vm.stack, result)
	}
	pop(&vm.frames)
}

variant_tag :: proc(v: Value) -> (int, bool) {
	if variant, ok := v.(^Variant_Value); ok {
		return variant.tag_index, true
	}
	if opt, ok := v.(^Option_Value); ok {
		if opt.has_value do return 1, true
		return 0, true
	}
	if res, ok := v.(^Result_Value); ok {
		if res.is_ok do return 0, true
		return 1, true
	}
	return 0, false
}

variant_field :: proc(v: Value, i: int) -> (Value, bool) {
	if variant, ok := v.(^Variant_Value); ok {
		if i < 0 || i >= len(variant.fields) do return Value{}, false
		return variant.fields[i], true
	}
	if opt, ok := v.(^Option_Value); ok {
		if opt.has_value && i == 0 do return opt.value, true
		return Value{}, false
	}
	if res, ok := v.(^Result_Value); ok {
		if i != 0 do return Value{}, false
		if res.is_ok do return res.value, true
		return res.error, true
	}
	return Value{}, false
}

// Структурное сравнение (не по ссылке): тайпчекер разрешает `==`/`<>` для
// любых unifiable типов, значит две одинаковые по полям структуры обязаны
// быть равны. visited — cycle-safe: мутация полей (Set_Property) допускает
// self-ссылающийся граф (a.следующий = a), пара once-visited указателей
// считается равной без дальнейшей рекурсии.
value_equals :: proc(a: Value, b: Value, visited: ^map[[2]rawptr]bool = nil) -> bool {
	v := visited
	local_v: map[[2]rawptr]bool
	if v == nil {
		local_v = make(map[[2]rawptr]bool, context.temp_allocator)
		v = &local_v
	}

	#partial switch va in a {
	case f64:
		if vb, ok := b.(f64); ok do return va == vb
	case bool:
		if vb, ok := b.(bool); ok do return va == vb
	case ^Panos_String:
		if vb, ok := b.(^Panos_String); ok do return va.data == vb.data
	case ^Variant_Value:
		if vb, ok := b.(^Variant_Value); ok {
			if va.tag_index != vb.tag_index do return false
			if len(va.fields) != len(vb.fields) do return false
			pair := [2]rawptr{va, vb}
			if v[pair] do return true
			v[pair] = true
			for i in 0 ..< len(va.fields) {
				if !value_equals(va.fields[i], vb.fields[i], v) do return false
			}
			return true
		}
	case ^Aggregate_Value:
		if vb, ok := b.(^Aggregate_Value); ok {
			if len(va.elements) != len(vb.elements) do return false
			pair := [2]rawptr{va, vb}
			if v[pair] do return true
			v[pair] = true
			for i in 0 ..< len(va.elements) {
				if !value_equals(va.elements[i], vb.elements[i], v) do return false
			}
			return true
		}
	case ^Array_Value:
		if vb, ok := b.(^Array_Value); ok {
			if len(va.elements) != len(vb.elements) do return false
			pair := [2]rawptr{va, vb}
			if v[pair] do return true
			v[pair] = true
			for i in 0 ..< len(va.elements) {
				if !value_equals(va.elements[i], vb.elements[i], v) do return false
			}
			return true
		}
	case ^Map_Value:
		if vb, ok := b.(^Map_Value); ok {
			if len(va.entries) != len(vb.entries) do return false
			pair := [2]rawptr{va, vb}
			if v[pair] do return true
			v[pair] = true
			// map_find_index сам использует value_equals для ключей — ключи
			// ограничены Number/Bool/String (is_valid_map_key_type,
			// type_cheker.odin), цикл через ключ невозможен, visited не
			// нужен для этого вложенного вызова.
			for entry in va.entries {
				idx := map_find_index(vb, entry.key)
				if idx == -1 do return false
				if !value_equals(entry.value, vb.entries[idx].value, v) do return false
			}
			return true
		}
	}
	return false
}

// Стадия 23 (Печатаемое): дефолтный (structural) путь форматирования —
// зеркалит value_equals по набору покрываемых Value-вариантов, но
// печатает вместо сравнивает. Вызывается ТОЛЬКО когда компилятор НЕ
// вставил Print_Value-путь (реализация Печатаемое для struct'а) — см.
// infer_call_expr (type_cheker.odin) и compiler.odin's .Print_Value.
// Aggregate_Value (struct) не хранит имя типа в рантайме (нет RTTI,
// см. компиляторную заметку у самой структуры) — дамп позиционный,
// "(поле1, поле2)", без имени типа/полей. Variant_Value хранит type_name,
// но НЕ имя конкретного варианта (только tag_index) — тоже позиционный
// дамп после имени типа.
value_to_display_string :: proc(vm: ^VM, value: Value, visited: ^map[rawptr]bool = nil) -> string {
	v := visited
	local_v: map[rawptr]bool
	if v == nil {
		local_v = make(map[rawptr]bool, context.temp_allocator)
		v = &local_v
	}

	#partial switch val in value {
	case f64:
		return fmt.tprintf("%v", val)
	case bool:
		return val ? "истина" : "ложь"
	case ^Panos_String:
		return val.data
	case ^Error_Value:
		return fmt.tprintf("Ошибка(%s, %s)", val.code.data, val.message.data)
	case ^Option_Value:
		if val.has_value do return fmt.tprintf("Есть(%s)", value_to_display_string(vm, val.value, v))
		return "Нет"
	case ^Result_Value:
		if val.is_ok do return fmt.tprintf("Успех(%s)", value_to_display_string(vm, val.value, v))
		return fmt.tprintf("Неудача(%s)", value_to_display_string(vm, val.error, v))
	case ^Interface_Value:
		return value_to_display_string(vm, Value(val.data), v)
	case ^Compiled_Function:
		return fmt.tprintf("<функция %s>", val.name)
	case ^File_Value:
		return "<файл>"
	case ^Socket_Value:
		return "<сокет>"
	case ^Variant_Value:
		if v[val] do return fmt.tprintf("%s(...)", val.type_name)
		v[val] = true
		if len(val.fields) == 0 do return val.type_name
		builder: strings.Builder
		strings.builder_init(&builder, context.temp_allocator)
		fmt.sbprintf(&builder, "%s(", val.type_name)
		for field, i in val.fields {
			if i > 0 do strings.write_string(&builder, ", ")
			strings.write_string(&builder, value_to_display_string(vm, field, v))
		}
		strings.write_string(&builder, ")")
		return strings.to_string(builder)
	case ^Aggregate_Value:
		if v[val] do return "(...)"
		v[val] = true
		builder: strings.Builder
		strings.builder_init(&builder, context.temp_allocator)
		strings.write_string(&builder, "(")
		for el, i in val.elements {
			if i > 0 do strings.write_string(&builder, ", ")
			strings.write_string(&builder, value_to_display_string(vm, el, v))
		}
		strings.write_string(&builder, ")")
		return strings.to_string(builder)
	case ^Array_Value:
		if v[val] do return "[...]"
		v[val] = true
		builder: strings.Builder
		strings.builder_init(&builder, context.temp_allocator)
		strings.write_string(&builder, "[")
		for el, i in val.elements {
			if i > 0 do strings.write_string(&builder, ", ")
			strings.write_string(&builder, value_to_display_string(vm, el, v))
		}
		strings.write_string(&builder, "]")
		return strings.to_string(builder)
	case ^Map_Value:
		if v[val] do return "{...}"
		v[val] = true
		builder: strings.Builder
		strings.builder_init(&builder, context.temp_allocator)
		strings.write_string(&builder, "{")
		for entry, i in val.entries {
			if i > 0 do strings.write_string(&builder, ", ")
			strings.write_string(&builder, value_to_display_string(vm, entry.key, v))
			strings.write_string(&builder, ": ")
			strings.write_string(&builder, value_to_display_string(vm, entry.value, v))
		}
		strings.write_string(&builder, "}")
		return strings.to_string(builder)
	}
	return "?"
}

// Стадия 24 (actor model): copy-on-send reflective deep-copy — адаптация
// value_to_display_string'а walker'а выше, только вместо строки строит
// НЕЗАВИСИМУЮ копию через gc_new. Вызывается ТОЛЬКО когда T сообщения НЕ
// реализует Копируемое (иначе компилятор уже эмитировал явный вызов
// .клонировать() и "отправить_без_копии", см. Call_Kind.Send_Copy,
// type_cheker.odin). Примитивы/строки/функции/File/Socket — иммутабельны
// или намеренно небезопасны для копирования, шарятся по ссылке как есть.
// Процесс(T)-хэндл — тоже по ссылке (сам процесс не "данные").
//
// visited — не просто cycle-guard (как в value_to_display_string), а
// map ОРИГИНАЛ→КОПИЯ: при повторной встрече уже скопированного указателя
// возвращает ТУ ЖЕ копию (не оригинал) — сохраняет топологию графа
// (в т.ч. циклы) в результирующей копии, а не просто обрывает обход.
message_deep_copy :: proc(vm: ^VM, value: Value, visited: ^map[rawptr]Value) -> Value {
	#partial switch val in value {
	case ^Error_Value:
		if existing, ok := visited[val]; ok do return existing
		cp := gc_new(vm, Error_Value)
		visited[val] = Value(cp)
		cp.code = val.code
		cp.message = val.message
		return Value(cp)
	case ^Option_Value:
		if existing, ok := visited[val]; ok do return existing
		cp := gc_new(vm, Option_Value)
		visited[val] = Value(cp)
		// cp ещё не привязан ни к одному корню (visited — обычная map, не
		// GC-root, см. mark_roots) — protect'им перед рекурсией, которая
		// сама может дернуть gc_new и триггернуть collect_garbage, пока
		// cp наполовину заполнен.
		gc_protect(vm, Value(cp))
		cp.has_value = val.has_value
		cp.value = message_deep_copy(vm, val.value, visited)
		gc_unprotect(vm, 1)
		return Value(cp)
	case ^Result_Value:
		if existing, ok := visited[val]; ok do return existing
		cp := gc_new(vm, Result_Value)
		visited[val] = Value(cp)
		gc_protect(vm, Value(cp))
		cp.is_ok = val.is_ok
		cp.value = message_deep_copy(vm, val.value, visited)
		cp.error = message_deep_copy(vm, val.error, visited)
		gc_unprotect(vm, 1)
		return Value(cp)
	case ^Interface_Value:
		if existing, ok := visited[val]; ok do return existing
		cp := gc_new(vm, Interface_Value)
		visited[val] = Value(cp)
		gc_protect(vm, Value(cp))
		cp.methods = val.methods
		cp.data = message_deep_copy(vm, val.data, visited)
		gc_unprotect(vm, 1)
		return Value(cp)
	case ^Variant_Value:
		if existing, ok := visited[val]; ok do return existing
		cp := gc_new(vm, Variant_Value)
		visited[val] = Value(cp)
		gc_protect(vm, Value(cp))
		cp.type_name = val.type_name
		cp.tag_index = val.tag_index
		cp.fields = make([dynamic]Value, len(val.fields))
		for f, i in val.fields do cp.fields[i] = message_deep_copy(vm, f, visited)
		gc_unprotect(vm, 1)
		return Value(cp)
	case ^Aggregate_Value:
		if existing, ok := visited[val]; ok do return existing
		cp := gc_new(vm, Aggregate_Value)
		visited[val] = Value(cp)
		gc_protect(vm, Value(cp))
		cp.elements = make([dynamic]Value, len(val.elements))
		for el, i in val.elements do cp.elements[i] = message_deep_copy(vm, el, visited)
		gc_unprotect(vm, 1)
		return Value(cp)
	case ^Array_Value:
		if existing, ok := visited[val]; ok do return existing
		cp := gc_new(vm, Array_Value)
		visited[val] = Value(cp)
		gc_protect(vm, Value(cp))
		cp.elements = make([dynamic]Value, len(val.elements))
		for el, i in val.elements do cp.elements[i] = message_deep_copy(vm, el, visited)
		gc_unprotect(vm, 1)
		return Value(cp)
	case ^Map_Value:
		if existing, ok := visited[val]; ok do return existing
		cp := gc_new(vm, Map_Value)
		visited[val] = Value(cp)
		gc_protect(vm, Value(cp))
		cp.entries = make([dynamic]Map_Entry_Value, len(val.entries))
		for entry, i in val.entries {
			cp.entries[i] = Map_Entry_Value {
				key   = message_deep_copy(vm, entry.key, visited),
				value = message_deep_copy(vm, entry.value, visited),
			}
		}
		gc_unprotect(vm, 1)
		return Value(cp)
	case ^Closure_Value:
		// Стадия 48 (замыкания): captured сам может содержать heap-
		// объекты (строки, массивы и т.п.) — глубокая копия по тому же
		// принципу, что Array_Value/Map_Value выше, иначе отправка
		// замыкания другому процессу шарила бы мутируемое состояние
		// между процессами (нарушение copy-on-send). fn
		// (^Compiled_Function) НЕ копируется — живёт в глобальном
		// реестре весь процесс, как и голая функция без захвата.
		if existing, ok := visited[val]; ok do return existing
		cp := gc_new(vm, Closure_Value)
		visited[val] = Value(cp)
		gc_protect(vm, Value(cp))
		cp.fn = val.fn
		cp.captured = make([dynamic]Value, len(val.captured))
		for c, i in val.captured do cp.captured[i] = message_deep_copy(vm, c, visited)
		gc_unprotect(vm, 1)
		return Value(cp)
	}
	// f64/bool/^Panos_String/^Compiled_Function/^File_Value/^Socket_Value/
	// ^Process_Value — без копии (иммутабельны либо намеренно небезопасны/
	// бессмысленны для копирования). ^Pointer_Value (Стадия 49) — та же
	// категория, что File/Socket: дублирование wrapper'а вокруг ОДНОГО
	// внешнего адреса с owned=true в ДВУХ независимых Pointer_Value дало
	// бы double-free (каждый GC'nut wrapper звал бы free() независимо) —
	// безопаснее делить ОДИН wrapper, чем гарантированно ломать владение.
	// Стадия 50: это НЕ открытый риск, а безопасный by-construction
	// дизайн — у panos ОДИН общий vm.gc на весь VM (все "процессы" —
	// зелёные нити внутри одного OS-процесса, не независимые адресные
	// пространства), значит расшаренный ^Pointer_Value имеет РОВНО один
	// Odin-объект и освобождается pool_release ровно один раз, когда
	// недостижим из ВСЕХ процессов сразу — см. test_ffi_pointer_owned_
	// sent_to_process_no_double_free (e2e_test.odin).
	return value
}

number_to_index :: proc(value: Value) -> int {
	number, ok := value.(f64)
	if !ok {
		fmt.panicf("Runtime Error: индекс массива должен быть числом")
	}

	idx := int(number)
	if number < 0 || f64(idx) != number {
		fmt.panicf(
			"Runtime Error: индекс массива должен быть неотрицательным целым числом",
		)
	}
	return idx
}

map_find_index :: proc(m: ^Map_Value, key: Value) -> int {
	for entry, i in m.entries {
		if value_equals(entry.key, key) do return i
	}
	return -1
}

map_remove_at :: proc(m: ^Map_Value, idx: int) {
	for i := idx; i < len(m.entries) - 1; i += 1 {
		m.entries[i] = m.entries[i + 1]
	}
	resize(&m.entries, len(m.entries) - 1)
}

expect_arg_count :: proc(method_name: string, actual: int, expected: int) {
	if actual != expected {
		fmt.panicf(
			"Runtime Error: метод '%s' ожидал %d аргументов, получено %d",
			method_name,
			expected,
			actual,
		)
	}
}

expect_string_arg :: proc(function_name: string, value: Value) -> string {
	text, ok := value.(^Panos_String)
	if !ok {
		fmt.panicf(
			"Runtime Error: %s ожидает строковый аргумент",
			function_name,
		)
	}
	return text.data
}

// code/message — компилируемые внутрь VM строки (например "ввод_вывод"),
// а не значения, снятые со стека, поэтому gc_new_string безопасен здесь без
// gc_protect: между gc_new(Error_Value) и присвоением полей других
// gc_new-вызовов, зависящих от уже-непротектнутых локалей, нет.
make_error_value :: proc(vm: ^VM, code: string, message: string) -> Value {
	err := gc_new(vm, Error_Value)
	gc_protect(vm, Value(err))
	err.code = gc_new_string(vm, code)
	err.message = gc_new_string(vm, message)
	gc_unprotect(vm, 1)
	return Value(err)
}

make_ok_result :: proc(vm: ^VM, value: Value) -> Value {
	gc_protect(vm, value)
	res := gc_new(vm, Result_Value)
	res.is_ok = true
	res.value = value
	res.error = f64(0)
	gc_unprotect(vm, 1)
	return Value(res)
}

make_error_result :: proc(vm: ^VM, err: Value) -> Value {
	gc_protect(vm, err)
	res := gc_new(vm, Result_Value)
	res.is_ok = false
	res.value = f64(0)
	res.error = err
	gc_unprotect(vm, 1)
	return Value(res)
}

// Стадия 38 (monitor): рассылает DOWN-сигнал `(Целое, Опция(Строка))`
// всем watchers'ам умершего процесса target_id — crash_reason.?
// отсутствует для штатного завершения (получатель видит (id, Нет)),
// присутствует для краша (получатель видит (id, Есть(причина))).
// Вызывается из run_scheduler в обеих ветках (.Completed и .Crashed при
// i != 0, watchers = process.watchers[:]), а также из call_builtin
// ("наблюдать") для синтетического немедленного сигнала ОДНОМУ
// вотчеру, если цель уже мертва на момент регистрации (watchers —
// одноэлементный слайс, а не поле умершего Process_Value, у которого к
// этому моменту watchers уже мог быть очищен планировщиком).
notify_watchers :: proc(vm: ^VM, target_id: int, watchers: []^Process_Value, crash_reason: Maybe(string)) {
	if len(watchers) == 0 do return
	reason_opt := gc_new(vm, Option_Value)
	gc_protect(vm, Value(reason_opt))
	if reason, crashed := crash_reason.?; crashed {
		reason_opt.has_value = true
		reason_opt.value = Value(gc_new_string(vm, reason))
	} else {
		reason_opt.has_value = false
		reason_opt.value = f64(0)
	}
	payload := gc_new(vm, Aggregate_Value)
	gc_protect(vm, Value(payload))
	append(&payload.elements, Value(f64(target_id)))
	append(&payload.elements, Value(reason_opt))
	for watcher in watchers {
		append(&watcher.signals, Value(payload))
	}
	gc_unprotect(vm, 2)
}

// Стадия 44 (link-примитив): единая точка "процесс окончательно мёртв"
// — переиспользуется run_scheduler'ом (.Completed/.Crashed, i != 0) и
// call_builtin'ом ("убить"), был раньше продублирован в обоих местах.
// Помечает is_alive=false, уведомляет watchers (notify_watchers, Стадия
// 38), КАСКАДНО завершает связанные (links, Стадия 44) процессы — но
// ТОЛЬКО если это НЕНОРМАЛЬНОЕ завершение (reason.? присутствует), тот
// же принцип, что у Erlang: 'normal' exit не убивает linked процессы,
// только краш/убить(). Затем очищает поля и удаляет из vm.processes.
//
// Гарантированно НИКОГДА не вызывается с target.id == 0 ("старт()") —
// у этого процесса особая семантика (завершение = вся программа
// заканчивается), реализованная ТОЛЬКО в run_scheduler для i==0;
// terminate_process не умеет её воспроизвести (нет пути наверх до
// main()), поэтому связать()/убить() отдельно запрещают root как цель
// (и связать() — как инициатора, иначе root мог бы попасть в чей-то
// links и получить каскад). run_scheduler сам никогда не зовёт эту
// функцию для i == 0 (у него отдельная fmt.panicf/return ветка).
terminate_process :: proc(vm: ^VM, target: ^Process_Value, reason: Maybe(string)) {
	if !target.is_alive do return // cycle guard: уже завершён, в т.ч. рекурсивно через links
	target.is_alive = false
	notify_watchers(vm, target.id, target.watchers[:], reason)

	if crash_text, crashed := reason.?; crashed {
		linked_reason := fmt.tprintf("связанный процесс #%d упал: %s", target.id, crash_text)
		for linked in target.links {
			terminate_process(vm, linked, linked_reason)
		}
	}

	for i := 0; i < len(vm.processes); i += 1 {
		if vm.processes[i] == target {
			clear(&target.frames)
			clear(&target.stack)
			clear(&target.mailbox)
			clear(&target.watchers)
			clear(&target.signals)
			clear(&target.links)
			unordered_remove(&vm.processes, i)
			break
		}
	}
}

// Чисто-байтовая часть чтения одной строки — БЕЗ Value/GC (ни
// make_ok_result/make_error_result/gc_new_string) — специально, чтобы
// быть безопасно вызываемой из фонового воркера (Фаза 4, file_stream_
// task_proc/socket_stream_task_proc, vm_async_io_native.odin), который
// никогда не должен трогать vm.gc напрямую (см. gc.odin). read_line_
// from_reader ниже — тонкая GC-оборачивающая обёртка вокруг этого же
// хелпера для синхронного (главный поток) пути.
read_line_raw :: proc(r: ^bufio.Reader, allocator: runtime.Allocator) -> (line: string, err: Maybe(string)) {
	raw_line, read_err := bufio.reader_read_string(r, '\n', allocator)
	if read_err != nil && read_err != .EOF {
		return "", fmt.tprintf("%v", read_err)
	}
	return strings.trim_right(raw_line, "\r\n"), nil
}

// Общая точка чтения одной строки из ЛЮБОГО bufio.Reader — общий путь
// чтения+trim для ввод_вывод::прочитать_строку (общий vm.stdin_reader),
// File_Value.прочитать_строку у файлов (свой reader на дескриптор) и у
// Файл-обёртки над стдин (тот же vm.stdin_reader, см. get_stdin_reader).
read_line_from_reader :: proc(vm: ^VM, r: ^bufio.Reader) -> Value {
	line, err := read_line_raw(r, context.temp_allocator)
	if err_text, has_err := err.(string); has_err {
		return make_error_result(vm, make_error_value(vm, "ввод_вывод", err_text))
	}
	return make_ok_result(vm, Value(gc_new_string(vm, line)))
}

// Вычитывает reader до EOF в temp-буфер (не трогает уже прочитанное — если
// перед .прочитать() были вызовы .прочитать_строку(), получаем ОСТАТОК
// файла, а не его начало заново, ровно как ожидалось бы от одного и того
// же файлового курсора).
read_all_from_reader :: proc(r: ^bufio.Reader) -> string {
	data := make([dynamic]byte, context.temp_allocator)
	buf: [4096]byte
	for {
		n, err := bufio.reader_read(r, buf[:])
		if n > 0 do append(&data, ..buf[:n])
		if err != nil do break
	}
	return string(data[:])
}

// read_stdin_line/file_reader/close_file_value/tcp_to_stream/
// close_socket_value — в vm_io_native.odin/vm_io_wasm.odin (#+build
// split), трогают os.stdin/os.close/net.*.

string_length :: proc(text: string) -> int {
	count := 0
	for _ in text {
		count += 1
	}
	return count
}

// Первая руна строки — строки::это_цифра/это_буква/цифра_или_буква
// принимают однобуквенную Строку (результат индексации text[i], см.
// Get_Index) как замену несуществующему в языке типу Символ.
first_rune :: proc(s: string) -> rune {
	if len(s) == 0 do return 0
	r, _ := utf8.decode_rune_in_string(s)
	return r
}

invoke_collection_method :: proc(
	vm: ^VM,
	receiver: Value,
	method_name: string,
	args: []Value,
) -> (
	Value,
	bool,
) {
	if opt, ok_opt := receiver.(^Option_Value); ok_opt {
		switch method_name {
		case "есть":
			expect_arg_count(method_name, len(args), 0)
			return Value(opt.has_value), true
		case "пусто":
			expect_arg_count(method_name, len(args), 0)
			return Value(!opt.has_value), true
		case "значение":
			expect_arg_count(method_name, len(args), 0)
			if !opt.has_value {
				fmt.panicf(
					"Runtime Error: попытка получить значение из пустой Опции",
				)
			}
			return opt.value, true
		case "получить":
			expect_arg_count(method_name, len(args), 1)
			if opt.has_value do return opt.value, true
			return args[0], true
		case "запас":
			expect_arg_count(method_name, len(args), 1)
			if opt.has_value do return Value(opt), true
			return args[0], true
		case "ожидать":
			expect_arg_count(method_name, len(args), 1)
			message := expect_string_arg(method_name, args[0])
			if !opt.has_value {
				fmt.panicf("Runtime Panic: %s", message)
			}
			return opt.value, true
		case "результат_или":
			expect_arg_count(method_name, len(args), 1)
			if opt.has_value do return make_ok_result(vm, opt.value), true
			return make_error_result(vm, args[0]), true
		case "заменить_значение":
			expect_arg_count(method_name, len(args), 1)
			replaced := gc_new(vm, Option_Value)
			replaced.has_value = opt.has_value
			if opt.has_value {
				replaced.value = args[0]
			} else {
				replaced.value = f64(0)
			}
			return Value(replaced), true
		}
	}

	if res, ok_res := receiver.(^Result_Value); ok_res {
		switch method_name {
		case "успех":
			expect_arg_count(method_name, len(args), 0)
			return Value(res.is_ok), true
		case "ошибка":
			expect_arg_count(method_name, len(args), 0)
			return Value(!res.is_ok), true
		case "значение":
			expect_arg_count(method_name, len(args), 0)
			if !res.is_ok {
				fmt.panicf(
					"Runtime Error: попытка получить значение из ошибочного Результата",
				)
			}
			return res.value, true
		case "причина":
			expect_arg_count(method_name, len(args), 0)
			if res.is_ok {
				fmt.panicf(
					"Runtime Error: попытка получить причину из успешного Результата",
				)
			}
			return res.error, true
		case "получить":
			expect_arg_count(method_name, len(args), 1)
			if res.is_ok do return res.value, true
			return args[0], true
		case "получить_ошибку":
			expect_arg_count(method_name, len(args), 1)
			if res.is_ok do return args[0], true
			return res.error, true
		case "запас":
			expect_arg_count(method_name, len(args), 1)
			if res.is_ok do return make_ok_result(vm, res.value), true
			return args[0], true
		case "ожидать":
			expect_arg_count(method_name, len(args), 1)
			message := expect_string_arg(method_name, args[0])
			if !res.is_ok {
				if err, ok_err := res.error.(^Error_Value); ok_err {
					fmt.panicf("Runtime Panic: %s: %s", message, err.message.data)
				}
				fmt.panicf("Runtime Panic: %s", message)
			}
			return res.value, true
		case "ожидать_ошибку":
			expect_arg_count(method_name, len(args), 1)
			message := expect_string_arg(method_name, args[0])
			if res.is_ok {
				fmt.panicf("Runtime Panic: %s", message)
			}
			return res.error, true
		case "опция":
			expect_arg_count(method_name, len(args), 0)
			opt := gc_new(vm, Option_Value)
			opt.has_value = res.is_ok
			if res.is_ok {
				opt.value = res.value
			} else {
				opt.value = f64(0)
			}
			return Value(opt), true
		case "ошибка_опция":
			expect_arg_count(method_name, len(args), 0)
			opt := gc_new(vm, Option_Value)
			opt.has_value = !res.is_ok
			if res.is_ok {
				opt.value = f64(0)
			} else {
				opt.value = res.error
			}
			return Value(opt), true
		case "заменить_значение":
			expect_arg_count(method_name, len(args), 1)
			if res.is_ok do return make_ok_result(vm, args[0]), true
			return make_error_result(vm, res.error), true
		case "заменить_ошибку":
			expect_arg_count(method_name, len(args), 1)
			if res.is_ok do return make_ok_result(vm, res.value), true
			return make_error_result(vm, args[0]), true
		}
	}

	if arr, ok_arr := receiver.(^Array_Value); ok_arr {
		switch method_name {
		case "длина":
			expect_arg_count(method_name, len(args), 0)
			return Value(f64(len(arr.elements))), true
		case "добавить":
			expect_arg_count(method_name, len(args), 1)
			append(&arr.elements, args[0])
			return Value(f64(0)), false
		case "получить":
			expect_arg_count(method_name, len(args), 2)
			idx := number_to_index(args[0])
			if idx >= len(arr.elements) do return args[1], true
			return arr.elements[idx], true
		case "есть":
			expect_arg_count(method_name, len(args), 1)
			idx := number_to_index(args[0])
			return Value(idx < len(arr.elements)), true
		case "содержит":
			expect_arg_count(method_name, len(args), 1)
			for el in arr.elements {
				if value_equals(el, args[0]) do return Value(true), true
			}
			return Value(false), true
		case "срез":
			// [начало:конец) — та же половинчато-открытая конвенция, что
			// строки::срез, для единообразия между Строка/Массив.
			expect_arg_count(method_name, len(args), 2)
			start := number_to_index(args[0])
			end := number_to_index(args[1])
			if start < 0 || end < start || end > len(arr.elements) {
				fmt.panicf(
					"Runtime Error: срез [%d:%d] выходит за границы массива длиной %d",
					start,
					end,
					len(arr.elements),
				)
			}
			// arr (receiver) уже снят с vm.stack к этому моменту (см.
			// Invoke_Collection) — протектим явно, тот же мотив, что у
			// "записи" (Map) выше: аллокация ниже иначе может собрать arr
			// как мусор посреди чтения arr.elements.
			gc_protect(vm, Value(arr))
			result := gc_new(vm, Array_Value)
			gc_protect(vm, Value(result))
			for i := start; i < end; i += 1 {
				append(&result.elements, arr.elements[i])
			}
			gc_unprotect(vm, 2)
			return Value(result), true
		}
	}

	if p, ok_process := receiver.(^Process_Value); ok_process {
		switch method_name {
		case "номер":
			expect_arg_count(method_name, len(args), 0)
			return Value(f64(p.id)), true
		}
	}

	if m, ok_map := receiver.(^Map_Value); ok_map {
		switch method_name {
		case "длина":
			expect_arg_count(method_name, len(args), 0)
			return Value(f64(len(m.entries))), true
		case "есть":
			expect_arg_count(method_name, len(args), 1)
			return Value(map_find_index(m, args[0]) != -1), true
		case "получить":
			expect_arg_count(method_name, len(args), 2)
			idx := map_find_index(m, args[0])
			if idx == -1 do return args[1], true
			return m.entries[idx].value, true
		case "удалить":
			expect_arg_count(method_name, len(args), 1)
			idx := map_find_index(m, args[0])
			if idx == -1 do return Value(false), true
			map_remove_at(m, idx)
			return Value(true), true
		case "записи":
			// Массив((Ключ, Значение)) — единственный способ пройтись по
			// произвольному Соответствию без for-in. `m` (receiver) уже
			// снят с vm.stack к этому моменту (см. Invoke_Collection) —
			// протектим явно, иначе аллокация ниже может собрать его как
			// мусор посреди чтения m.entries.
			expect_arg_count(method_name, len(args), 0)
			gc_protect(vm, Value(m))
			arr := gc_new(vm, Array_Value)
			gc_protect(vm, Value(arr))
			for entry in m.entries {
				pair := gc_new(vm, Aggregate_Value)
				resize(&pair.elements, 2)
				pair.elements[0] = entry.key
				pair.elements[1] = entry.value
				append(&arr.elements, Value(pair))
			}
			gc_unprotect(vm, 2)
			return Value(arr), true
		}
	}

	// File_Value/Socket_Value методы (.прочитать/.записать/.закрыть и
	// сетевые аналоги) — в vm_io_native.odin/vm_io_wasm.odin (#+build
	// split, трогают os.write/net.send_tcp).
	if result, ok, handled := invoke_io_method(vm, receiver, method_name, args); handled {
		return result, ok
	}

	fmt.panicf(
		"Runtime Error: метод '%s' не найден у коллекции",
		method_name,
	)
}

call_builtin :: proc(vm: ^VM, name: string, args: []Value) -> (Value, bool) {
	// фс::*/ос::окружение*/ввод_вывод::прочитать_строку/поток/сеть::подключиться
	// — в vm_io_native.odin/vm_io_wasm.odin (#+build split, трогают
	// os.exists/os.open/os.lookup_env/net.dial_tcp...). Остальные builtin'ы
	// (в т.ч. ос::аргументы, ввод_вывод::печать/строка, сеть::кодировать_url
	// — уже os/net-агностичны) остаются в общем switch ниже без изменений.
	if result, ok, handled := call_builtin_io(vm, name, args); handled {
		return result, ok
	}
	// сжатие::* — в vm_compress_native.odin/vm_compress_wasm.odin (#+build
	// split, native тянет core:compress/gzip, который транзитивно импортирует
	// core:os — падает compile-time panic'ом под js_wasm32, тот же урок,
	// что и с фс/сеть выше).
	if result, ok, handled := call_builtin_compress(vm, name, args); handled {
		return result, ok
	}
	// сеть::http_запрос — в vm_http_native.odin/vm_http_wasm.odin (#+build
	// split, native тянет core:net + external/odin-http's openssl-биндинг,
	// оба недоступны под js_wasm32).
	if result, ok, handled := call_builtin_http(vm, name, args); handled {
		return result, ok
	}
	// ос::выполнить — в vm_process_native.odin/vm_process_wasm.odin (#+build
	// split, native тянет platform-specific process_*.odin из core:os,
	// недоступные под js_wasm32).
	if result, ok, handled := call_builtin_process(vm, name, args); handled {
		return result, ok
	}
	// синтаксис::* — в vm_syntax_native.odin/vm_syntax_wasm.odin (#+build
	// split, native тянет read_file_text/tokenize/parse_program для ЧУЖОГО
	// .ps файла — codegen-инструменты на panos, не связано с рантаймом
	// текущей программы).
	if result, ok, handled := call_builtin_syntax(vm, name, args); handled {
		return result, ok
	}
	switch name {
	case "Ошибка":
		expect_arg_count(name, len(args), 2)
		code, ok_code := args[0].(^Panos_String)
		message, ok_message := args[1].(^Panos_String)
		if !ok_code || !ok_message {
			fmt.panicf("Runtime Error: Ошибка() ожидает две строки")
		}
		// code/message уже на vm.stack через args (слайс в живой стек) —
		// протектить не нужно, они рутятся сами до возврата из этого вызова.
		err := gc_new(vm, Error_Value)
		err.code = code
		err.message = message
		return Value(err), true

	case "Есть":
		expect_arg_count(name, len(args), 1)
		opt := gc_new(vm, Option_Value)
		opt.has_value = true
		opt.value = args[0]
		return Value(opt), true

	case "Нет":
		expect_arg_count(name, len(args), 0)
		opt := gc_new(vm, Option_Value)
		opt.has_value = false
		opt.value = f64(0)
		return Value(opt), true

	case "Успех":
		expect_arg_count(name, len(args), 1)
		res := gc_new(vm, Result_Value)
		res.is_ok = true
		res.value = args[0]
		res.error = f64(0)
		return Value(res), true

	case "Неудача":
		expect_arg_count(name, len(args), 1)
		return make_error_result(vm, args[0]), true

	case "длина":
		expect_arg_count(name, len(args), 1)
		if text, ok := args[0].(^Panos_String); ok {
			return Value(f64(string_length(text.data))), true
		}
		if arr, ok := args[0].(^Array_Value); ok {
			return Value(f64(len(arr.elements))), true
		}
		if m, ok := args[0].(^Map_Value); ok {
			return Value(f64(len(m.entries))), true
		}
		fmt.panicf(
			"Runtime Error: длина() ожидает строку, массив или соответствие",
		)

	case "встроку":
		// Строковая интерполяция (`"...\(x)..."`, десахарена парсером в
		// вызовы встроку(x), см. parser.odin) + прямой вызов встроку(x) —
		// та же логика конверсии, что использует ввод_вывод.печать/.строка
		// (value_to_display_string, Печатаемое-диспатч уже сделан
		// компилятором ДО этого builtin'а, см. Call_Info.Print_Value в
		// type_cheker.odin), только результат ВОЗВРАЩАЕТСЯ как Строка,
		// а не печатается.
		expect_arg_count(name, len(args), 1)
		return Value(gc_new_string(vm, value_to_display_string(vm, args[0]))), true

	case "паника":
		// Стадия 38 (monitor): не fmt.panicf (ронял бы ВСЮ программу) —
		// crash_message читается сразу после call_builtin() (.Call_Builtin
		// в execute()), которая превращает его в Exec_Result.Crashed.
		// Единственная реальная точка user-triggered краша (см. ROADMAP
		// §Стадия 38): .значение()/.ожидать() и т.п. у Опции/Результата —
		// panos-функции из PRELUDE_SOURCE (prelude.odin), зовущие паника().
		expect_arg_count(name, len(args), 1)
		message := expect_string_arg(name, args[0])
		vm.crash_message = fmt.tprintf("Runtime Panic: %s", message)
		return Value(f64(0)), false

	case "Целое":
		// Целое и Число на рантайме — один и тот же f64 (см. type_cheker.
		// odin: "На РАНТАЙМЕ представлен ТЕМ ЖЕ f64"), так что приведение —
		// это усечение к нулю значения, а не смена представления.
		expect_arg_count(name, len(args), 1)
		n, ok := args[0].(f64)
		if !ok {
			fmt.panicf("Runtime Error: Целое() ожидает число")
		}
		return Value(math.trunc(n)), true

	case "Число":
		// Целое->Число: то же f64-значение как есть, не-op.
		expect_arg_count(name, len(args), 1)
		n, ok := args[0].(f64)
		if !ok {
			fmt.panicf("Runtime Error: Число() ожидает число")
		}
		return Value(n), true

	case "себя":
		expect_arg_count(name, len(args), 0)
		return Value(vm.processes[vm.current_process]), true

	case "отправить":
		expect_arg_count(name, len(args), 2)
		process, ok := args[0].(^Process_Value)
		if !ok {
			fmt.panicf("Runtime Error: отправить() ожидает Процесс(T) первым аргументом")
		}
		if !process.is_alive {
			// Erlang-поведение: тихий no-op на мёртвый процесс (ROADMAP
			// Стадия 24, п.8) — синхронная проверка живости всё равно
			// гонка, Результат создал бы ложное чувство надёжности.
			return Value(f64(0)), false
		}
		// T сообщения НЕ реализует Копируемое (иначе компилятор эмитил
		// бы "отправить_без_копии", см. Call_Kind.Send_Copy) — рантайм
		// сам делает reflective deep-copy.
		visited := make(map[rawptr]Value, 0, context.temp_allocator)
		append(&process.mailbox, message_deep_copy(vm, args[1], &visited))
		return Value(f64(0)), false

	case "отправить_без_копии":
		// Стадия 24: внутреннее имя, эмитится ТОЛЬКО компилятором
		// (Call_Kind.Send_Copy) — сообщение уже прошло .клонировать(),
		// повторный reflective copy исказил бы намеренно НЕ
		// скопированные пользователем поля.
		expect_arg_count(name, len(args), 2)
		process, ok := args[0].(^Process_Value)
		if !ok {
			fmt.panicf("Runtime Error: отправить() ожидает Процесс(T) первым аргументом")
		}
		if !process.is_alive {
			return Value(f64(0)), false
		}
		append(&process.mailbox, args[1])
		return Value(f64(0)), false

	case "наблюдать":
		// Стадия 38 (monitor): регистрирует ТЕКУЩИЙ процесс наблюдателем
		// цели. Если цель уже мертва — синтетический немедленный сигнал
		// (симметрично тому, что отправить() на мёртвый процесс уже
		// тихий no-op — здесь вместо тишины сигнал, иначе получить_
		// сигнал() вызывающего зависнет навечно, никто его не разбудит).
		expect_arg_count(name, len(args), 1)
		target, ok := args[0].(^Process_Value)
		if !ok {
			fmt.panicf("Runtime Error: наблюдать() ожидает Процесс(T) первым аргументом")
		}
		watcher := vm.processes[vm.current_process]
		if !target.is_alive {
			notify_watchers(vm, target.id, []^Process_Value{watcher}, "процесс уже не существует")
		} else {
			append(&target.watchers, watcher)
		}
		return Value(f64(0)), false

	case "убить":
		// Стадия 42 (kill-примитив): принудительно останавливает ЧУЖОЙ
		// процесс — единственный способ прервать выполнение процесса
		// извне (до этого — только естественное завершение/краш).
		// terminate_process (Стадия 44 — вынесена в общую функцию, была
		// продублирована здесь и в run_scheduler) переиспользует тот же
		// путь очистки, что и .Completed/.Crashed, плюс (новое) каскадно
		// завершает связанные через связать() процессы.
		//
		// Самоубийство и убийство "старт()" (процесс #0) запрещены явно:
		// для самоубийства понадобился бы способ немедленно прервать
		// ТЕКУЩИЙ execute() (этот builtin — обычный синхронный вызов
		// внутри него, простой return отсюда НЕ останавливает
		// оставшиеся инструкции тела процесса); а старт() — корневой
		// процесс, крашing/завершение которого и так уже имеет особую
		// семантику (вся программа завершается) — убийство его извне
		// потребовало бы прокидывать этот сигнал обратно в run_scheduler
		// из глубины call_builtin, что не стоит сложности ради узкого
		// кейса ("зачем убивать процесс, за которым и так некому
		// наблюдать").
		expect_arg_count(name, len(args), 1)
		target, ok := args[0].(^Process_Value)
		if !ok {
			fmt.panicf("Runtime Error: убить() ожидает Процесс(T) первым аргументом")
		}
		current := vm.processes[vm.current_process]
		if target == current {
			fmt.panicf("Runtime Error: убить() нельзя применить к самому себе")
		}
		if target.id == 0 {
			fmt.panicf("Runtime Error: убить() нельзя применить к главному процессу")
		}
		terminate_process(vm, target, "процесс принудительно остановлен (убить())")
		return Value(f64(0)), false

	case "связать":
		// Стадия 44 (link-примитив): двусторонняя связь — крах ЛЮБОЙ
		// стороны (Есть(причина), не Нет — см. terminate_process)
		// каскадно завершает и другую. "Просто уведомить, не убивать"
		// уже даёт наблюдать()/получить_сигнал() (Стадия 38) — связать()
		// не нуждается в Erlang-style trap_exit opt-out, раз оба
		// поведения уже доступны как два разных builtin'а.
		//
		// Самолинковка разрешена (как у наблюдать() — безвредна, cycle
		// guard в terminate_process её же обезвреживает). "Старт()"
		// (процесс #0) запрещён и как цель, И как инициатор — если бы
		// root попал в чей-то links, каскад попытался бы завершить его
		// через terminate_process, у которой нет способа воспроизвести
		// особую семантику root'а (программа заканчивается) — только
		// run_scheduler это умеет, для i == 0 отдельной веткой.
		expect_arg_count(name, len(args), 1)
		target, ok := args[0].(^Process_Value)
		if !ok {
			fmt.panicf("Runtime Error: связать() ожидает Процесс(T) первым аргументом")
		}
		current := vm.processes[vm.current_process]
		if current.id == 0 {
			fmt.panicf("Runtime Error: связать() нельзя вызвать из главного процесса")
		}
		if target.id == 0 {
			fmt.panicf("Runtime Error: связать() нельзя применить к главному процессу")
		}
		if !target.is_alive {
			return Value(f64(0)), false
		}
		append(&current.links, target)
		append(&target.links, current)
		return Value(f64(0)), false

	case "ос::аргументы":
		expect_arg_count(name, len(args), 0)
		arr := gc_new(vm, Array_Value)
		gc_protect(vm, Value(arr))
		arr.elements = make([dynamic]Value)
		for arg in vm.program_args {
			append(&arr.elements, Value(gc_new_string(vm, arg)))
		}
		gc_unprotect(vm, 1)
		return Value(arr), true

	case "время::монотонно_мс":
		// Стадия 46: тики с момента старта VM (vm.monotonic_epoch,
		// выставляется один раз в new_vm) — иммунно к переводу системных
		// часов, для sliding-window лимита рестартов супервизора нужно
		// именно это, не время::сейчас_мс.
		expect_arg_count(name, len(args), 0)
		return Value(time.duration_milliseconds(time.tick_since(vm.monotonic_epoch))), true

	case "время::сейчас_мс":
		// Стадия 46: wall-clock, unix-время в миллисекундах — для логов/
		// отображения, НЕ для измерения интервалов (перевод часов ломает
		// монотонность).
		expect_arg_count(name, len(args), 0)
		return Value(f64(time.to_unix_nanoseconds(time.now())) / 1e6), true

	case "ввод_вывод::печать":
		// Стадия 23 (Печатаемое): аргумент — ЛЮБОЙ Value, не только Строка.
		// Если он реализует Печатаемое, компилятор уже подменил его на
		// результат .вСтроку() (см. .Print_Value в compiler.odin) — сюда
		// приходит готовая Panos_String. Иначе — structural dump.
		expect_arg_count(name, len(args), 1)
		fmt.print(value_to_display_string(vm, args[0]))
		return Value(f64(0)), false

	case "ввод_вывод::строка":
		expect_arg_count(name, len(args), 1)
		fmt.println(value_to_display_string(vm, args[0]))
		return Value(f64(0)), false

	case "сеть::кодировать_url":
		// percent-encoding по байтам, не рунам — RFC 3986 unreserved
		// (A-Z a-z 0-9 - _ . ~) как есть, всё остальное как %XX (в т.ч.
		// каждый байт многобайтовой UTF-8 руны отдельно). Нет способа
		// сделать это в самом Panos — нет доступа к байтам строки.
		expect_arg_count(name, len(args), 1)
		text := expect_string_arg(name, args[0])
		builder: strings.Builder
		strings.builder_init(&builder, context.temp_allocator)
		for b in transmute([]byte)text {
			is_unreserved :=
				(b >= 'A' && b <= 'Z') ||
				(b >= 'a' && b <= 'z') ||
				(b >= '0' && b <= '9') ||
				b == '-' ||
				b == '_' ||
				b == '.' ||
				b == '~'
			if is_unreserved {
				strings.write_byte(&builder, b)
			} else {
				fmt.sbprintf(&builder, "%%%02X", b)
			}
		}
		return Value(gc_new_string(vm, strings.to_string(builder))), true

	case "строки::срез":
		expect_arg_count(name, len(args), 3)
		text := expect_string_arg(name, args[0])
		start := number_to_index(args[1])
		end := number_to_index(args[2])
		slice, ok := string_slice_by_rune(text, start, end)
		if !ok {
			fmt.panicf(
				"Runtime Error: срез [%d:%d] выходит за границы строки длиной %d",
				start,
				end,
				string_length(text),
			)
		}
		return Value(gc_new_string(vm, slice)), true

	case "строки::это_цифра":
		expect_arg_count(name, len(args), 1)
		text := expect_string_arg(name, args[0])
		return Value(unicode.is_digit(first_rune(text))), true

	case "строки::это_буква":
		expect_arg_count(name, len(args), 1)
		text := expect_string_arg(name, args[0])
		return Value(unicode.is_alpha(first_rune(text))), true

	case "строки::цифра_или_буква":
		expect_arg_count(name, len(args), 1)
		text := expect_string_arg(name, args[0])
		r := first_rune(text)
		return Value(unicode.is_digit(r) || unicode.is_alpha(r)), true

	case "строки::в_число":
		expect_arg_count(name, len(args), 1)
		text := expect_string_arg(name, args[0])
		num, ok := strconv.parse_f64(text)
		if !ok {
			return make_error_result(
				vm,
				make_error_value(vm, "строки", fmt.tprintf("'%s' не является числом", text)),
			), true
		}
		return make_ok_result(vm, Value(num)), true

	case "строки::из_числа":
		expect_arg_count(name, len(args), 1)
		num, ok_num := args[0].(f64)
		if !ok_num {
			fmt.panicf("Runtime Error: строки.из_числа() ожидает число")
		}
		return Value(gc_new_string(vm, fmt.tprintf("%v", num))), true

	case "строки::из_целого":
		expect_arg_count(name, len(args), 1)
		num, ok_num := args[0].(f64)
		if !ok_num {
			fmt.panicf("Runtime Error: строки.из_целого() ожидает целое")
		}
		return Value(gc_new_string(vm, fmt.tprintf("%d", i64(num)))), true

	case "строки::найти":
		expect_arg_count(name, len(args), 3)
		text := expect_string_arg(name, args[0])
		pattern := expect_string_arg(name, args[1])
		from_idx := number_to_index(args[2])
		return Value(f64(string_find_rune(text, pattern, from_idx))), true

	case "строки::содержит":
		expect_arg_count(name, len(args), 2)
		text := expect_string_arg(name, args[0])
		pattern := expect_string_arg(name, args[1])
		return Value(strings.contains(text, pattern)), true

	case "строки::заменить":
		expect_arg_count(name, len(args), 3)
		text := expect_string_arg(name, args[0])
		old_part := expect_string_arg(name, args[1])
		new_part := expect_string_arg(name, args[2])
		replaced, _ := strings.replace_all(text, old_part, new_part, context.temp_allocator)
		return Value(gc_new_string(vm, replaced)), true

	case "строки::разбить":
		expect_arg_count(name, len(args), 2)
		text := expect_string_arg(name, args[0])
		sep := expect_string_arg(name, args[1])
		parts, _ := strings.split(text, sep, context.temp_allocator)
		arr := gc_new(vm, Array_Value)
		gc_protect(vm, Value(arr))
		for part in parts {
			append(&arr.elements, Value(gc_new_string(vm, part)))
		}
		gc_unprotect(vm, 1)
		return Value(arr), true

	case "строки::соединить":
		expect_arg_count(name, len(args), 2)
		arr, ok_arr := args[0].(^Array_Value)
		if !ok_arr {
			fmt.panicf("Runtime Error: строки.соединить() ожидает массив строк")
		}
		sep := expect_string_arg(name, args[1])
		parts := make([dynamic]string, 0, len(arr.elements), context.temp_allocator)
		for el in arr.elements {
			append(&parts, expect_string_arg(name, el))
		}
		joined, _ := strings.join(parts[:], sep, context.temp_allocator)
		return Value(gc_new_string(vm, joined)), true

	case "строки::обрезать":
		expect_arg_count(name, len(args), 1)
		text := expect_string_arg(name, args[0])
		return Value(gc_new_string(vm, strings.trim_space(text))), true

	case "строки::начинается_с":
		expect_arg_count(name, len(args), 2)
		text := expect_string_arg(name, args[0])
		prefix := expect_string_arg(name, args[1])
		return Value(strings.has_prefix(text, prefix)), true

	case "строки::заканчивается_на":
		expect_arg_count(name, len(args), 2)
		text := expect_string_arg(name, args[0])
		suffix := expect_string_arg(name, args[1])
		return Value(strings.has_suffix(text, suffix)), true

	case "строки::верхний_регистр":
		expect_arg_count(name, len(args), 1)
		text := expect_string_arg(name, args[0])
		upper, _ := strings.to_upper(text, context.temp_allocator)
		return Value(gc_new_string(vm, upper)), true

	case "строки::нижний_регистр":
		expect_arg_count(name, len(args), 1)
		text := expect_string_arg(name, args[0])
		lower, _ := strings.to_lower(text, context.temp_allocator)
		return Value(gc_new_string(vm, lower)), true

	case "строки::сравнить":
		expect_arg_count(name, len(args), 2)
		a := expect_string_arg(name, args[0])
		b := expect_string_arg(name, args[1])
		return Value(f64(strings.compare(a, b))), true

	case "строки::байт":
		// Побайтовый (не рунный, в отличие от строки::срез/длина/индексации,
		// см. core/utils.odin) доступ — нужен для бинарных форматов (tar и
		// т.п.), где содержимое не обязано быть валидным UTF-8.
		expect_arg_count(name, len(args), 2)
		text := expect_string_arg(name, args[0])
		idx := number_to_index(args[1])
		if idx >= len(text) {
			fmt.panicf(
				"Runtime Error: байт[%d] выходит за границы строки длиной %d байт",
				idx,
				len(text),
			)
		}
		return Value(f64(text[idx])), true

	case "строки::длина_байт":
		expect_arg_count(name, len(args), 1)
		text := expect_string_arg(name, args[0])
		return Value(f64(len(text))), true

	case "строки::срез_байт":
		expect_arg_count(name, len(args), 3)
		text := expect_string_arg(name, args[0])
		start := number_to_index(args[1])
		end := number_to_index(args[2])
		if start > end || end > len(text) {
			fmt.panicf(
				"Runtime Error: срез_байт[%d:%d] выходит за границы строки длиной %d байт",
				start,
				end,
				len(text),
			)
		}
		return Value(gc_new_string(vm, text[start:end])), true

	case "строки::из_байтов":
		expect_arg_count(name, len(args), 1)
		arr, is_arr := args[0].(^Array_Value)
		if !is_arr {
			fmt.panicf("Runtime Error: из_байтов ожидает Массив(Целое)")
		}
		buf := make([]u8, len(arr.elements), context.temp_allocator)
		for el, i in arr.elements {
			n, is_num := el.(f64)
			if !is_num || n < 0 || n > 255 || f64(int(n)) != n {
				fmt.panicf("Runtime Error: из_байтов ожидает значения 0-255, получено %v", el)
			}
			buf[i] = u8(n)
		}
		return Value(gc_new_string(vm, string(buf))), true

	case "строки::в_байты":
		// Обратное к из_байтов — все байты строки одним вызовом (Go
		// `[]byte(s)`), а не по одному через строки.байт(s, i) в цикле.
		expect_arg_count(name, len(args), 1)
		text := expect_string_arg(name, args[0])
		arr := gc_new(vm, Array_Value)
		gc_protect(vm, Value(arr))
		arr.elements = make([dynamic]Value, 0, len(text))
		for i := 0; i < len(text); i += 1 {
			append(&arr.elements, Value(f64(text[i])))
		}
		gc_unprotect(vm, 1)
		return Value(arr), true

	case "строки::кодовая_точка":
		// Codepoint-значение ПЕРВОЙ руны строки (Go: `rune(s[0])` при
		// range по строке) — принимает как однорунные срезы (типичный
		// вход: text[i]), так и многорунные (просто игнорирует остаток,
		// как first_rune везде в этом файле).
		expect_arg_count(name, len(args), 1)
		text := expect_string_arg(name, args[0])
		return Value(f64(first_rune(text))), true

	case "строки::в_руны":
		// Строка -> Массив(Целое) codepoint-значений (Go `[]rune(s)`).
		expect_arg_count(name, len(args), 1)
		text := expect_string_arg(name, args[0])
		arr := gc_new(vm, Array_Value)
		gc_protect(vm, Value(arr))
		arr.elements = make([dynamic]Value)
		for i := 0; i < len(text); {
			r, width := utf8.decode_rune_in_string(text[i:])
			append(&arr.elements, Value(f64(r)))
			i += width
		}
		gc_unprotect(vm, 1)
		return Value(arr), true

	case "строки::из_рун":
		// Обратное к в_руны — Массив(Целое) codepoint'ов -> Строка (Go
		// `string([]rune{...})`). Тот же UTF-8-энкодинг, что panos-код
		// был вынужден писать руками (см. std/кодирование/toml.ps
		// \u-эскейпы) — здесь через core:unicode/utf8 напрямую.
		expect_arg_count(name, len(args), 1)
		arr, is_arr := args[0].(^Array_Value)
		if !is_arr {
			fmt.panicf("Runtime Error: из_рун ожидает Массив(Целое)")
		}
		buf := strings.builder_make(context.temp_allocator)
		for el in arr.elements {
			n, is_num := el.(f64)
			if !is_num || f64(i32(n)) != n {
				fmt.panicf("Runtime Error: из_рун ожидает codepoint-значения (Целое), получено %v", el)
			}
			strings.write_rune(&buf, rune(i32(n)))
		}
		return Value(gc_new_string(vm, strings.to_string(buf))), true
	}

	fmt.panicf(
		"Runtime Error: неизвестный встроенный конструктор '%s'",
		name,
	)
}

// Стадия 24 (actor model): работает над vm.frames/vm.stack — планировщик
// (run_scheduler) отвечает за то, чтобы они отражали ТЕКУЩИЙ процесс
// перед вызовом. Возвращает .Suspended, если наткнулась на .Receive с
// пустым mailbox (ip остаётся на самом .Receive — resume перепроверит),
// .Completed, если верхнеуровневая функция процесса действительно
// вернулась (frames опустели).
execute :: proc(vm: ^VM) -> Exec_Result {

	for len(vm.frames) > 0 {

		// Берем ТЕКУЩИЙ фрейм по указателю, чтобы мы могли менять его ip
		frame := &vm.frames[len(vm.frames) - 1]
		instructions := frame.function.instructions

		if frame.ip >= len(instructions) {
			// Если мы дошли до конца инструкций без явного RETURN,
			// просто удаляем фрейм (возвращаемся)
			pop(&vm.frames)
			continue
		}

		opcode := Opcode(instructions[frame.ip])

		#partial switch opcode {
		case .Constant:
			frame.ip += 1
			const_index := instructions[frame.ip]
			append(&vm.stack, frame.function.constants[const_index])

		case .Set_Local:
			frame.ip += 1
			slot_index := int(instructions[frame.ip])

			// 1. Берем верхнее значение (результат вычислений)
			value := pop(&vm.stack)
			// 2. Кладем его глубоко в стек, туда, где зарезервировано место переменной
			vm.stack[frame.frame_pointer + slot_index] = value

		case .Get_Local:
			frame.ip += 1
			slot_index := int(instructions[frame.ip])

			// 1. Читаем значение из глубин стека (относительно начала фрейма)
			value := vm.stack[frame.frame_pointer + slot_index]
			// 2. Копируем его на самую вершину стека для вычислений
			append(&vm.stack, value)

		case .Pop:
			pop(&vm.stack)

		case .Add:
			val_b := pop(&vm.stack)
			val_a := pop(&vm.stack)

			if a, ok_a := val_a.(f64); ok_a {
				if b, ok_b := val_b.(f64); ok_b {
					append(&vm.stack, Value(a + b))
					break
				}
			}

			if a, ok_a := val_a.(^Panos_String); ok_a {
				if b, ok_b := val_b.(^Panos_String); ok_b {
					// a/b уже сняты со стека, но fmt.tprintf читает их байты
					// СРАЗУ (temp_allocator), до вызова gc_new_string — им
					// не нужно переживать сам вызов, только предоставить
					// данные для конкатенации.
					append(&vm.stack, Value(gc_new_string(vm, fmt.tprintf("%s%s", a.data, b.data))))
					break
				}
			}

			fmt.panicf(
				"Runtime Error: оператор '+' ожидает два числа или две строки (было %v и %v)",
				val_a,
				val_b,
			)
		case .Subtract:
			r := pop(&vm.stack).(f64); l := pop(&vm.stack).(f64)
			append(&vm.stack, l - r)

		case .Multiply:
			r := pop(&vm.stack).(f64); l := pop(&vm.stack).(f64)
			append(&vm.stack, l * r)
		case .Divide:
			r := pop(&vm.stack).(f64); l := pop(&vm.stack).(f64)
			append(&vm.stack, l / r)

		case .Int_Divide:
			// Целое/Целое: усечение к нулю (как в C/Rust/Go — НЕ floor
			// как в Python, см. согласование в ROADMAP/чате). Рантайм
			// по-прежнему f64 (Целое не имеет отдельного Value-варианта,
			// см. Type_Kind.Integer) — только выбор опкода статический.
			r := pop(&vm.stack).(f64); l := pop(&vm.stack).(f64)
			if r == 0 {
				// Стадия 38: catchable — см. Exec_Result.Crashed.
				vm.crash_message = "Runtime Error: деление на ноль"
				return .Crashed
			}
			append(&vm.stack, math.trunc(l / r))

		case .Modulo:
			// Остаток при усечении к нулю — знак следует делимому (та же
			// семантика, что math.mod/C-шный fmod, согласовано с .Int_Divide).
			r := pop(&vm.stack).(f64); l := pop(&vm.stack).(f64)
			if r == 0 {
				vm.crash_message = "Runtime Error: деление на ноль (остаток)"
				return .Crashed
			}
			append(&vm.stack, math.mod(l, r))

		case .BitAnd:
			// Целое на рантайме — f64 (см. .Int_Divide выше) — конвертируем
			// в i64, делаем битовую операцию, конвертируем назад. typechecker
			// уже гарантировал Целое с обеих сторон (infer_binary_expr).
			r := pop(&vm.stack).(f64); l := pop(&vm.stack).(f64)
			append(&vm.stack, f64(i64(l) & i64(r)))

		case .BitOr:
			r := pop(&vm.stack).(f64); l := pop(&vm.stack).(f64)
			append(&vm.stack, f64(i64(l) | i64(r)))

		case .BitXor:
			r := pop(&vm.stack).(f64); l := pop(&vm.stack).(f64)
			append(&vm.stack, f64(i64(l) ~ i64(r)))

		case .BitNot:
			v := pop(&vm.stack).(f64)
			append(&vm.stack, f64(~i64(v)))

		case .ShiftLeft:
			r := pop(&vm.stack).(f64); l := pop(&vm.stack).(f64)
			append(&vm.stack, f64(i64(l) << uint(i64(r))))

		case .ShiftRight:
			r := pop(&vm.stack).(f64); l := pop(&vm.stack).(f64)
			append(&vm.stack, f64(i64(l) >> uint(i64(r))))

		case .Less:
			r := pop(&vm.stack).(f64); l := pop(&vm.stack).(f64)
			append(&vm.stack, l < r)

		case .Greater:
			r := pop(&vm.stack).(f64); l := pop(&vm.stack).(f64)
			append(&vm.stack, l > r)

		case .Negate:
			e := pop(&vm.stack).(bool)
			append(&vm.stack, !e)

		case .Equal:
			r := pop(&vm.stack)
			l := pop(&vm.stack)
			append(&vm.stack, value_equals(l, r))

		case .Call:
			frame.ip += 1
			arg_count := int(instructions[frame.ip])

			// Функция лежит на стеке ПОД всеми аргументами
			callee_index := len(vm.stack) - 1 - arg_count
			callee_val := vm.stack[callee_index]

			// Стадия 48 (замыкания): callee — либо голая ^Compiled_Function
			// (обычная функция/некапчурящая лямбда), либо ^Closure_Value
			// (захватывающая лямбда, см. .Build_Closure) — в обоих
			// случаях исполняется одна и та же ^Compiled_Function,
			// разница только в том, доступен ли .Get_Captured.
			func_ptr: ^Compiled_Function
			closure: ^Closure_Value
			#partial switch v in callee_val {
			case ^Compiled_Function:
				func_ptr = v
			case ^Closure_Value:
				func_ptr = v.fn
				closure = v
			case:
				fmt.panicf(
					"Runtime Error: попытка вызвать не функцию (получено: %v)",
					callee_val,
				)
			}

			new_frame := CallFrame {
				function      = func_ptr,
				ip            = 0,
				frame_pointer = callee_index + 1, // локальные начинаются прямо с аргументов
				closure       = closure,
			}

			// Дорезервируем слоты под остальные локальные (нулями)
			locals_to_allocate := func_ptr.frame_size - arg_count
			for _ in 0 ..< locals_to_allocate {
				append(&vm.stack, Value(f64(0)))
			}

			// Точка возврата в вызывающий фрейм
			vm.frames[len(vm.frames) - 1].ip = frame.ip + 1

			append(&vm.frames, new_frame)
			continue // пропускаем frame.ip += 1 в конце цикла

		case .Call_Builtin:
			frame.ip += 1
			name_index := instructions[frame.ip]
			frame.ip += 1
			arg_count := int(instructions[frame.ip])

			name := frame.function.constants[name_index].(^Panos_String).data
			args_start := len(vm.stack) - arg_count
			args := vm.stack[args_start:]
			// Стадия 38: сброс ПЕРЕД вызовом — только "паника" может
			// выставить его внутри call_builtin, читаем сразу после.
			vm.crash_message = ""
			result, has_result := call_builtin(vm, name, args)
			if vm.crash_message != "" {
				return .Crashed
			}
			resize(&vm.stack, args_start)
			if has_result {
				append(&vm.stack, result)
			}

		case .Call_Builtin_Async:
			// Неблокирующий I/O: та же операнд-форма/извлечение args, что
			// .Call_Builtin выше, но вместо синхронного call_builtin —
			// submit_async_io (vm_async_io_native.odin/_wasm.odin, #+build
			// split — как vm_http_native.odin) кладёт задачу в воркер-пул
			// и возвращается СРАЗУ (submit не блокирует). ip продолжает
			// как обычно на следующую инструкцию — компилятор ВСЕГДА
			// эмитит .Await_Async сразу после (см. compiler.odin, case
			// .Builtin), которая и делает настоящий suspend/resume.
			frame.ip += 1
			name_index := instructions[frame.ip]
			frame.ip += 1
			arg_count := int(instructions[frame.ip])

			name := frame.function.constants[name_index].(^Panos_String).data
			args_start := len(vm.stack) - arg_count
			args := vm.stack[args_start:]
			target_id := vm.processes[vm.current_process].id
			submit_async_io(vm, name, args, target_id)
			resize(&vm.stack, args_start)

		case .Await_Async:
			// Неблокирующий I/O: тот же suspend/resume паттерн, что
			// .Receive_Signal, но над process.async_results — ОТДЕЛЬНАЯ от
			// mailbox очередь (см. Process_Value.async_results,
			// compiler.odin) специально чтобы результат async-вызова не
			// перепутался с обычным пользовательским сообщением,
			// пришедшим, пока процесс ждал.
			process := vm.processes[vm.current_process]
			if len(process.async_results) == 0 {
				return .Suspended
			}
			result := process.async_results[0]
			ordered_remove(&process.async_results, 0)
			append(&vm.stack, result)

		case .Call_Foreign:
			frame.ip += 1
			ff_index := instructions[frame.ip]
			frame.ip += 1
			arg_count := int(instructions[frame.ip])

			ff := frame.function.constants[ff_index].(^Foreign_Function)
			args_start := len(vm.stack) - arg_count
			args := vm.stack[args_start:]
			result := call_foreign(vm, ff, args)
			resize(&vm.stack, args_start)
			append(&vm.stack, result)

		case .Build_Closure:
			frame.ip += 1
			fn_index := instructions[frame.ip]
			frame.ip += 1
			capture_count := int(instructions[frame.ip])

			fn := frame.function.constants[fn_index].(^Compiled_Function)
			captured_start := len(vm.stack) - capture_count
			closure := gc_new(vm, Closure_Value)
			closure.fn = fn
			resize(&closure.captured, capture_count)
			copy(closure.captured[:], vm.stack[captured_start:])
			resize(&vm.stack, captured_start)
			append(&vm.stack, Value(closure))

		case .Get_Captured:
			frame.ip += 1
			idx := instructions[frame.ip]
			append(&vm.stack, frame.closure.captured[idx])

		case .Return:
			result: Value = f64(0) // по умолчанию, если функция ничего не вернула

			base_frame_size := frame.frame_pointer + frame.function.frame_size

			// Всё, что выше слотов локальных, — возвращаемое значение
			if len(vm.stack) > base_frame_size {
				result = pop(&vm.stack)
			}

			return_from_current_frame(vm, result)
			continue

		case .Try_Unwrap:
			// Опция/Результат — обычные Variant_Value (как любой user-enum),
			// построенные через Build_Variant. Тег-порядок (Нет=0/Есть=1,
			// Успех=0/Неудача=1) зафиксирован в prelude.odin.
			value := pop(&vm.stack)
			if variant, ok := value.(^Variant_Value); ok {
				switch variant.type_name {
				case "Опция":
					if variant.tag_index == 1 { 	// Есть
						append(&vm.stack, variant.fields[0])
					} else { 	// Нет
						return_from_current_frame(vm, value)
						continue
					}
				case "Результат":
					if variant.tag_index == 0 { 	// Успех
						append(&vm.stack, variant.fields[0])
					} else { 	// Неудача
						return_from_current_frame(vm, value)
						continue
					}
				case:
					fmt.panicf(
						"Runtime Error: оператор '?' ожидал Опцию или Результат",
					)
				}
			} else {
				fmt.panicf(
					"Runtime Error: оператор '?' ожидал Опцию или Результат",
				)
			}

		case .Jump_If_False:
			// 2-байтовое смещение (big-endian), всегда вперёд
			frame.ip += 1
			high := u16(instructions[frame.ip])
			frame.ip += 1
			low := u16(instructions[frame.ip])

			offset := (high << 8) | low

			condition_val := pop(&vm.stack)

			// Без ok-проверки: тайпчекер гарантирует строго bool на стеке
			condition := condition_val.(bool)

			if !condition {
				frame.ip += int(offset)
			}

		case .Jump:
			frame.ip += 1
			high := u16(instructions[frame.ip])
			frame.ip += 1
			low := u16(instructions[frame.ip])

			offset := (high << 8) | low

			// Безусловный прыжок. offset знаковый (i16): While прыгает назад.
			frame.ip += int(i16(offset))
		case .Build_Aggregate:
			frame.ip += 1
			count := int(instructions[frame.ip])

			agg := gc_new(vm, Aggregate_Value)
			resize(&agg.elements, count)

			// Снимаем со стека в обратном порядке: последний аргумент сверху
			for i := count - 1; i >= 0; i -= 1 {
				agg.elements[i] = pop(&vm.stack)
			}

			append(&vm.stack, Value(agg))

		case .Build_Variant:
			frame.ip += 1
			name_index := int(instructions[frame.ip])
			frame.ip += 1
			tag := int(instructions[frame.ip])
			frame.ip += 1
			arity := int(instructions[frame.ip])

			type_name := frame.function.constants[name_index].(^Panos_String).data

			variant := gc_new(vm, Variant_Value)
			variant.type_name = type_name
			variant.tag_index = tag
			resize(&variant.fields, arity)
			for i := arity - 1; i >= 0; i -= 1 {
				variant.fields[i] = pop(&vm.stack)
			}
			append(&vm.stack, Value(variant))

		case .Match_Tag:
			frame.ip += 1
			tag_const_idx := int(instructions[frame.ip])
			expected_tag := int(frame.function.constants[tag_const_idx].(f64))
			subject := vm.stack[len(vm.stack) - 1]
			actual_tag, ok := variant_tag(subject)
			if !ok {
				fmt.panicf(
					"Runtime Error: выбор ожидал значение перечисления, но получил %v",
					subject,
				)
			}
			append(&vm.stack, Value(actual_tag == expected_tag))

		case .Get_Variant_Field:
			frame.ip += 1
			field_idx := int(instructions[frame.ip])
			subject := pop(&vm.stack)
			field_val, ok := variant_field(subject, field_idx)
			if !ok {
				fmt.panicf(
					"Runtime Error: попытка прочитать поле #%d у неподходящего варианта",
					field_idx,
				)
			}
			append(&vm.stack, field_val)

		case .Match_Fail:
			subject := vm.stack[len(vm.stack) - 1]
			variant_name := "?"
			if v, is_variant := subject.(^Variant_Value); is_variant {
				variant_name = v.type_name
			}
			fmt.panicf(
				"Runtime Error: значение варианта '%s' не покрыто ни одной веткой выбора",
				variant_name,
			)

		case .Build_Array:
			frame.ip += 1
			count := int(instructions[frame.ip])

			arr := gc_new(vm, Array_Value)
			resize(&arr.elements, count)

			for i := count - 1; i >= 0; i -= 1 {
				arr.elements[i] = pop(&vm.stack)
			}

			append(&vm.stack, Value(arr))

		case .Build_Map:
			frame.ip += 1
			count := int(instructions[frame.ip])

			m := gc_new(vm, Map_Value)
			resize(&m.entries, count)

			for i := count - 1; i >= 0; i -= 1 {
				value := pop(&vm.stack)
				key := pop(&vm.stack)
				m.entries[i] = Map_Entry_Value {
					key   = key,
					value = value,
				}
			}

			append(&vm.stack, Value(m))

		case .Get_Property:
			frame.ip += 1
			idx := int(instructions[frame.ip])

			val := pop(&vm.stack)
			if agg, ok_agg := val.(^Aggregate_Value); ok_agg {
				append(&vm.stack, agg.elements[idx])
			} else if err, ok_err := val.(^Error_Value); ok_err {
				switch idx {
				case 0:
					append(&vm.stack, Value(err.code))
				case 1:
					append(&vm.stack, Value(err.message))
				case:
					fmt.panicf(
						"Runtime Error: у Ошибка нет поля с индексом %d",
						idx,
					)
				}
			} else {
				fmt.panicf(
					"Runtime Error: попытка прочитать поле у примитивного типа",
				)
			}

		case .Set_Property:
			frame.ip += 1
			idx := int(instructions[frame.ip])

			value := pop(&vm.stack)
			target := pop(&vm.stack)

			if agg, ok_agg := target.(^Aggregate_Value); ok_agg {
				agg.elements[idx] = value
			} else if iface, ok_iface := target.(^Interface_Value); ok_iface {
				// Стадия 25: iface.data теперь Value (было ^Aggregate_Value
				// напрямую) — перечисления тоже могут стоять за интерфейсом,
				// но у Variant_Value нет settable-полей (не Aggregate_Value),
				// присваивание через интерфейс им не смысленно.
				agg, ok_agg := iface.data.(^Aggregate_Value)
				if !ok_agg {
					fmt.panicf(
						"Runtime Error: присваивание полю через интерфейс поддержано только для структур",
					)
				}
				agg.elements[idx] = value
			} else if err, ok_err := target.(^Error_Value); ok_err {
				text, ok_text := value.(^Panos_String)
				if !ok_text {
					fmt.panicf(
						"Runtime Error: поля Ошибка принимают только строки",
					)
				}
				switch idx {
				case 0:
					err.code = text
				case 1:
					err.message = text
				case:
					fmt.panicf(
						"Runtime Error: у Ошибка нет поля с индексом %d",
						idx,
					)
				}
			} else {
				fmt.panicf(
					"Runtime Error: попытка записать поле у примитивного типа",
				)
			}

		case .Get_Index:
			index := pop(&vm.stack)
			receiver := pop(&vm.stack)

			if arr, ok_arr := receiver.(^Array_Value); ok_arr {
				idx := number_to_index(index)
				if idx >= len(arr.elements) {
					// Стадия 38: catchable — см. Exec_Result.Crashed.
					vm.crash_message = fmt.tprintf(
						"Runtime Error: индекс %d выходит за границы массива",
						idx,
					)
					return .Crashed
				}
				append(&vm.stack, arr.elements[idx])
			} else if m, ok_map := receiver.(^Map_Value); ok_map {
				idx := map_find_index(m, index)
				if idx == -1 {
					vm.crash_message = "Runtime Error: ключ не найден в соответствии"
					return .Crashed
				}
				append(&vm.stack, m.entries[idx].value)
			} else if m, ok_string := receiver.(^Panos_String); ok_string {
				idx := number_to_index(index)

				if char_str, ok := get_character_at(m.data, idx); ok {
					new_string := Value(gc_new_string(vm, char_str))
					append(&vm.stack, new_string)
				} else {
					vm.crash_message = fmt.tprintf(
						"Runtime Error: индекс %d выходит за границы массива",
						idx,
					)
					return .Crashed
				}
			} else {
				fmt.panicf(
					"Runtime Error: индексирование поддерживают только массивы и соответствия",
				)
			}

		case .Set_Index:
			value := pop(&vm.stack)
			index := pop(&vm.stack)
			receiver := pop(&vm.stack)

			if arr, ok_arr := receiver.(^Array_Value); ok_arr {
				idx := number_to_index(index)
				if idx >= len(arr.elements) {
					vm.crash_message = fmt.tprintf(
						"Runtime Error: индекс %d выходит за границы массива",
						idx,
					)
					return .Crashed
				}
				arr.elements[idx] = value
			} else if m, ok_map := receiver.(^Map_Value); ok_map {
				idx := map_find_index(m, index)
				if idx == -1 {
					append(&m.entries, Map_Entry_Value{key = index, value = value})
				} else {
					m.entries[idx].value = value
				}
			} else {
				fmt.panicf(
					"Runtime Error: индексная запись поддерживает только массивы и соответствия",
				)
			}

		case .Cast_Interface:
			frame.ip += 1
			struct_name_index := instructions[frame.ip]
			struct_name := frame.function.constants[struct_name_index].(^Panos_String).data

			val := pop(&vm.stack)
			// Стадия 25: структура ИЛИ перечисление — vtable-механизм ниже
			// ищет методы по имени "ИмяТипа::метод" среди vm.compiled_
			// functions, ему всё равно, Aggregate_Value это или
			// Variant_Value (то же самое, что уже верно для обычного
			// вызова метода на структуре/enum — см. infer_property_expr).
			_, is_agg := val.(^Aggregate_Value)
			_, is_variant := val.(^Variant_Value)
			if !is_agg && !is_variant {
				fmt.panicf(
					"Runtime Error: в интерфейс можно привести только структуру или перечисление",
				)
			}
			// val только что снят со стека — до gc_new(Interface_Value) он
			// нигде не закреплён, protect'им явно (см. gc_protect в gc.odin).
			gc_protect(vm, val)

			iface := gc_new(vm, Interface_Value)
			iface.data = val
			iface.methods = make(map[string]^Compiled_Function)

			prefix := fmt.tprintf("%s::", struct_name)
			for name, fn in vm.compiled_functions {
				if len(name) > len(prefix) && name[:len(prefix)] == prefix {
					iface.methods[name[len(prefix):]] = fn
				}
			}

			gc_unprotect(vm, 1)
			append(&vm.stack, Value(iface))

		case .Invoke_Interface:
			frame.ip += 1
			method_name_index := instructions[frame.ip]
			frame.ip += 1
			arg_count := int(instructions[frame.ip])

			method_name := frame.function.constants[method_name_index].(^Panos_String).data
			callee_index := len(vm.stack) - 1 - arg_count
			iface_val := vm.stack[callee_index]

			iface, ok := iface_val.(^Interface_Value)
			if !ok {
				fmt.panicf(
					"Runtime Error: попытка вызвать интерфейсный метод у не-интерфейса",
				)
			}

			func_ptr, found := iface.methods[method_name]
			if !found {
				fmt.panicf(
					"Runtime Error: метод '%s' не найден в vtable интерфейса",
					method_name,
				)
			}

			vm.stack[callee_index] = Value(func_ptr)
			append(&vm.stack, Value(f64(0)))
			for i := len(vm.stack) - 1; i > callee_index + 1; i -= 1 {
				vm.stack[i] = vm.stack[i - 1]
			}
			vm.stack[callee_index + 1] = Value(iface.data)

			total_arg_count := arg_count + 1
			new_frame := CallFrame {
				function      = func_ptr,
				ip            = 0,
				frame_pointer = callee_index + 1,
			}

			locals_to_allocate := func_ptr.frame_size - total_arg_count
			for _ in 0 ..< locals_to_allocate {
				append(&vm.stack, Value(f64(0)))
			}

			vm.frames[len(vm.frames) - 1].ip = frame.ip + 1
			append(&vm.frames, new_frame)
			continue

		case .Invoke_Collection:
			frame.ip += 1
			method_name_index := instructions[frame.ip]
			frame.ip += 1
			arg_count := int(instructions[frame.ip])

			method_name := frame.function.constants[method_name_index].(^Panos_String).data
			receiver_index := len(vm.stack) - 1 - arg_count
			receiver := vm.stack[receiver_index]
			args := vm.stack[receiver_index + 1:]

			result, has_result := invoke_collection_method(vm, receiver, method_name, args)
			resize(&vm.stack, receiver_index)
			if has_result {
				append(&vm.stack, result)
			}

		case .Invoke_Collection_Async:
			// Фаза 4/5: та же операнд-форма, что .Invoke_Collection выше, но
			// submit вместо синхронного invoke_collection_method —
			// submit_async_io_method (vm_async_io_native.odin/_wasm.odin)
			// либо кладёт задачу в воркер-пул (реальный стриминговый
			// read/write), либо (файл уже закрыт/занят) сразу синхронно
			// кладёт готовый Value в process.async_results — оба случая
			// .Await_Async сразу после видит одинаково. args нужны только
			// записи/отправить (1 строка) — read-методы (0 аргументов)
			// получат пустой срез, submit_async_io_method их игнорирует.
			frame.ip += 1
			method_name_index := instructions[frame.ip]
			frame.ip += 1
			arg_count := int(instructions[frame.ip])

			method_name := frame.function.constants[method_name_index].(^Panos_String).data
			receiver_index := len(vm.stack) - 1 - arg_count
			receiver := vm.stack[receiver_index]
			args := vm.stack[receiver_index + 1:]
			target_id := vm.processes[vm.current_process].id
			submit_async_io_method(vm, receiver, method_name, args, target_id)
			resize(&vm.stack, receiver_index)

		case .Spawn:
			frame.ip += 1
			arg_count := int(instructions[frame.ip])

			// Функция и аргументы лежат на ТЕКУЩЕМ стеке — как перед .Call —
			// но мы НЕ выполняем callee здесь, а копируем аргументы в СВЕЖИЙ
			// стек нового процесса (own frames/stack, см. Process_Value).
			callee_index := len(vm.stack) - 1 - arg_count
			callee_val := vm.stack[callee_index]

			func_ptr, ok := callee_val.(^Compiled_Function)
			if !ok {
				fmt.panicf(
					"Runtime Error: попытка запустить (запусти) не функцию (получено: %v)",
					callee_val,
				)
			}

			new_process := gc_new(vm, Process_Value)
			new_process.id = vm.next_process_id
			vm.next_process_id += 1
			new_process.is_alive = true

			append(
				&new_process.frames,
				CallFrame{function = func_ptr, ip = 0, frame_pointer = 0},
			)
			for i := 0; i < arg_count; i += 1 {
				append(&new_process.stack, vm.stack[callee_index + 1 + i])
			}
			locals_to_allocate := func_ptr.frame_size - arg_count
			for _ in 0 ..< locals_to_allocate {
				append(&new_process.stack, Value(f64(0)))
			}

			append(&vm.processes, new_process)

			// Снимаем fn+аргументы с текущего стека, кладём handle процесса
			resize(&vm.stack, callee_index)
			append(&vm.stack, Value(new_process))

		case .Receive:
			process := vm.processes[vm.current_process]
			if len(process.mailbox) == 0 {
				// Чистый ранний выход: ip НЕ двигаем (даже байт операнда —
				// у .Receive его нет), при resume execute() снова начнёт
				// именно с этой же инструкции .Receive и перепроверит mailbox.
				return .Suspended
			}
			msg := process.mailbox[0]
			ordered_remove(&process.mailbox, 0)
			append(&vm.stack, msg)

		case .Receive_Signal:
			// Стадия 38: тот же suspend/resume паттерн, что .Receive, но
			// своя очередь (process.signals) — сигнал уже готовый тупл
			// (Целое, Опция(Строка)), построенный notify_watchers'ом,
			// просто снимается с FIFO и кладётся на стек.
			process := vm.processes[vm.current_process]
			if len(process.signals) == 0 {
				return .Suspended
			}
			sig := process.signals[0]
			ordered_remove(&process.signals, 0)
			append(&vm.stack, sig)
		}

		// Двигаем IP текущего фрейма вперед
		frame.ip += 1
	}

	return .Completed
}

// Неблокирующий I/O: превращает плоские данные Async_Result (см.
// vm_async.odin) в настоящий Результат-Value — ЕДИНСТВЕННОЕ место, где эта
// граница пересекается, и делает это ТОЛЬКО главный поток (вызывается из
// run_scheduler, никогда из воркера — см. core/gc.odin, gc_new/gc_new_string
// не потокобезопасны). Молча дропает результат, если процесс-получатель
// больше не жив — тот же прецедент, что у отправить() на мёртвый процесс.
deliver_async_result :: proc(vm: ^VM, comp: Async_Result) {
	target: ^Process_Value
	for p in vm.processes {
		if p.id == comp.target_id {
			target = p
			break
		}
	}

	// payload — обычная Odin-память (strings.clone/context.allocator в
	// воркере, НЕ GC-managed) — должна быть освобождена ЗДЕСЬ независимо от
	// того, жив ли ещё процесс-получатель (мёртвый процесс — тот же
	// silent-drop, что у отправить(), но утечка памяти это не оправдывает).
	switch payload in comp.payload {
	case Http_Result_Data:
		// Явный vm_heap_allocator() — main.odin делает ambient context.
		// allocator этой функции mem.Dynamic_Arena (не потокобезопасна,
		// НЕ та память, на которой воркер (vm_async_io_native.odin)
		// реально аллоцировал payload через vm_heap_allocator()) — delete()
		// без явного allocator'а тут был бы delete через ЧУЖОЙ аллокатор.
		heap := vm_heap_allocator()
		defer {
			for kv in payload.headers {
				delete(kv[0], heap)
				delete(kv[1], heap)
			}
			delete(payload.headers)
			delete(payload.body, heap)
			if err, has_err := payload.err.(string); has_err do delete(err, heap)
		}

		if target == nil || !target.is_alive do return

		value: Value
		if err, has_err := payload.err.(string); has_err {
			value = make_error_result(vm, make_error_value(vm, "сеть", err))
		} else {
			header_pairs := gc_new(vm, Array_Value)
			gc_protect(vm, Value(header_pairs))
			for kv in payload.headers {
				pair := gc_new(vm, Aggregate_Value)
				resize(&pair.elements, 2)
				pair.elements[0] = Value(gc_new_string(vm, kv[0]))
				pair.elements[1] = Value(gc_new_string(vm, kv[1]))
				append(&header_pairs.elements, Value(pair))
			}
			result_tuple := gc_new(vm, Aggregate_Value)
			resize(&result_tuple.elements, 3)
			result_tuple.elements[0] = Value(f64(payload.status))
			result_tuple.elements[1] = Value(header_pairs)
			result_tuple.elements[2] = Value(gc_new_string(vm, payload.body))
			gc_unprotect(vm, 1)
			value = make_ok_result(vm, Value(result_tuple))
		}
		append(&target.async_results, value)

	case File_Read_Result_Data:
		heap := vm_heap_allocator()
		defer if err, has_err := payload.err.(string); has_err do delete(err, heap)
		defer delete(payload.content, heap)

		if target == nil || !target.is_alive do return

		value: Value
		if err, has_err := payload.err.(string); has_err {
			value = make_error_result(vm, make_error_value(vm, "фс", err))
		} else {
			value = make_ok_result(vm, Value(gc_new_string(vm, payload.content)))
		}
		append(&target.async_results, value)

	case File_Write_Result_Data:
		heap := vm_heap_allocator()
		defer if err, has_err := payload.err.(string); has_err do delete(err, heap)

		if target == nil || !target.is_alive do return

		value: Value
		if err, has_err := payload.err.(string); has_err {
			value = make_error_result(vm, make_error_value(vm, "фс", err))
		} else {
			value = make_ok_result(vm, Value(f64(payload.bytes_written)))
		}
		append(&target.async_results, value)

	case Tcp_Connect_Result_Data:
		// Единственный payload с платформозависимым полем (net.TCP_Socket
		// на native, rawptr-заглушка на wasm — см. vm_async.odin) — само
		// построение Value (Socket_Value/bufio.reader_init) вынесено в
		// deliver_tcp_connect_result (vm_async_io_native.odin/_wasm.odin),
		// т.к. этот файл (vm.odin) намеренно не импортирует core:net.
		deliver_tcp_connect_result(vm, target, payload)

	case File_Stream_Read_Result_Data:
		// Фаза 4: unpin/deferred-close — ДО проверки живости получателя
		// (мёртвый процесс не должен блокировать реальное освобождение
		// ресурса — тот же прецедент, что net.close на мёртвой ветке
		// deliver_tcp_connect_result). close_file_value безусловно вызываем
		// из этого файла и раньше (pool_release, gc.odin) — не новый
		// прецедент, несмотря на #+build-раздельную реализацию.
		file := payload.file
		file.in_flight = false
		gc_unpin(vm, Value(file))
		if file.close_requested {
			close_file_value(file)
		}

		heap := vm_heap_allocator()
		defer delete(payload.content, heap)
		defer if err, has_err := payload.err.(string); has_err do delete(err, heap)

		if target == nil || !target.is_alive do return

		value: Value
		if err, has_err := payload.err.(string); has_err {
			value = make_error_result(vm, make_error_value(vm, "фс", err))
		} else {
			value = make_ok_result(vm, Value(gc_new_string(vm, payload.content)))
		}
		append(&target.async_results, value)

	case Socket_Stream_Read_Result_Data:
		// Симметрично File_Stream_Read_Result_Data выше, close_socket_value/
		// модуль "сеть".
		sock := payload.sock
		sock.in_flight = false
		gc_unpin(vm, Value(sock))
		if sock.close_requested {
			close_socket_value(sock)
		}

		heap := vm_heap_allocator()
		defer delete(payload.content, heap)
		defer if err, has_err := payload.err.(string); has_err do delete(err, heap)

		if target == nil || !target.is_alive do return

		value: Value
		if err, has_err := payload.err.(string); has_err {
			value = make_error_result(vm, make_error_value(vm, "сеть", err))
		} else {
			value = make_ok_result(vm, Value(gc_new_string(vm, payload.content)))
		}
		append(&target.async_results, value)

	case File_Stream_Write_Result_Data:
		// Фаза 5: симметрично File_Stream_Read_Result_Data — unpin/
		// deferred-close ДО проверки живости получателя, но здесь
		// результат — Результат(Число, Ошибка) (байт записано), не строка.
		file := payload.file
		file.in_flight = false
		gc_unpin(vm, Value(file))
		if file.close_requested {
			close_file_value(file)
		}

		heap := vm_heap_allocator()
		defer if err, has_err := payload.err.(string); has_err do delete(err, heap)

		if target == nil || !target.is_alive do return

		value: Value
		if err, has_err := payload.err.(string); has_err {
			value = make_error_result(vm, make_error_value(vm, "фс", err))
		} else {
			value = make_ok_result(vm, Value(f64(payload.bytes_written)))
		}
		append(&target.async_results, value)

	case Socket_Stream_Write_Result_Data:
		// Симметрично File_Stream_Write_Result_Data выше, close_socket_value/
		// модуль "сеть".
		sock := payload.sock
		sock.in_flight = false
		gc_unpin(vm, Value(sock))
		if sock.close_requested {
			close_socket_value(sock)
		}

		heap := vm_heap_allocator()
		defer if err, has_err := payload.err.(string); has_err do delete(err, heap)

		if target == nil || !target.is_alive do return

		value: Value
		if err, has_err := payload.err.(string); has_err {
			value = make_error_result(vm, make_error_value(vm, "сеть", err))
		} else {
			value = make_ok_result(vm, Value(f64(payload.bytes_written)))
		}
		append(&target.async_results, value)
	}
}

// Неблокирующий I/O: неблокирующий дренаж всего, что успело накопиться в
// канале завершений — вызывается оппортунистически из run_scheduler между
// проходами по процессам (не только в idle-ветке дедлок-guard'а).
drain_async_completions :: proc(vm: ^VM) {
	when thread.IS_SUPPORTED {
		for {
			comp, ok := chan.try_recv(vm.async_completions)
			if !ok do break
			deliver_async_result(vm, comp)
		}
	}
}

// Стадия 24 (actor model): единственная точка входа для запуска VM —
// раньше был один вызов execute(vm) (Value 1 старт()), теперь execute()
// нужно вызывать МНОГО раз (по одному на процесс за тик), round-robin
// (Вопрос 2 грилинга — простой вариант, без runnable/waiting очередей).
// Возвращает управление, когда старт() ("процесс #0") завершается —
// программа выходит СРАЗУ, не дожидаясь осиротевших процессов (Вопрос 6).
// vm.frames/vm.stack по возврату — финальное состояние процесса #0, тот
// же контракт, что раньше давал одиночный execute(vm) (vm.stack[len-1] —
// результат старт()).
run_scheduler :: proc(vm: ^VM) {
	for {
		any_ran := false

		i := 0
		for i < len(vm.processes) {
			process := vm.processes[i]

			// Пустые mailbox И signals И async_results у УЖЕ хоть раз
			// запущенного процесса — нечего делать, пропускаем без входа в
			// execute() (deadlock-guard: если так для ВСЕХ процессов
			// подряд — некому никого разбудить, см. ниже). Свежеспавненный
			// (has_run=false) обязан получить хотя бы один прогон, даже с
			// пустыми всеми тремя очередями — тело процесса не обязано
			// начинаться с получить()/получить_сигнал(). Стадия 38:
			// signals — та же логика, что mailbox, иначе процесс,
			// приостановленный на получить_сигнал(), никогда не получит
			// второй шанс исполниться после прихода сигнала (deadlock-guard
			// ложно сработал бы первым). Неблокирующий I/O: async_results —
			// та же логика — процесс на .Await_Async не должен считаться
			// "нечего делать" только пока ждёт результат.
			if process.has_run && len(process.mailbox) == 0 && len(process.signals) == 0 && len(process.async_results) == 0 {
				i += 1
				continue
			}

			any_ran = true
			process.has_run = true

			vm.frames = process.frames
			vm.stack = process.stack
			vm.current_process = i

			result := execute(vm)

			process.frames = vm.frames
			process.stack = vm.stack

			if result == .Completed {
				if i == 0 {
					// старт() завершился — программа выходит немедленно,
					// vm.frames/vm.stack уже отражают его финальное
					// состояние (ничего дополнительно свопать не нужно).
					// Неблокирующий I/O: воркер-потоки пула ЖИВЫ (ждут на
					// семафоре) до явного pool_join — без него процесс
					// падает с SIGABRT при выходе (незавершённые потоки на
					// момент завершения main). pool_join сам безопасен на
					// никогда не стартовавшем пуле (пустой pool.threads).
					when thread.IS_SUPPORTED {
						thread.pool_join(&vm.async_pool)
					}
					return
				}
				// Стадия 38: штатное завершение — наблюдатели видят
				// (id, Нет), links (Стадия 44) НЕ каскадируют (нормальное
				// завершение не убивает связанных — см. terminate_process).
				terminate_process(vm, process, nil)
				continue // swap-remove передвинул последний элемент на место i — не увеличиваем i
			}

			if result == .Crashed {
				if i == 0 {
					// Стадия 38: краш "старт()" — по-прежнему фатален для
					// всей программы, тот же текст, что раньше шёл в
					// fmt.panicf на самом catchable-сайте (см. Exec_
					// Result.Crashed) — регрессии в существующих тестах
					// на паника()/Опция/Результат нет.
					fmt.panicf("%s", vm.crash_message)
				}
				// Изоляция: наблюдатели видят (id, Есть(причина)), ВСЯ
				// остальная программа продолжает работать — раньше любой
				// краш здесь ронял всё через fmt.panicf. Стадия 44:
				// связанные (links) процессы каскадно завершаются тоже.
				terminate_process(vm, process, vm.crash_message)
				continue
			}

			i += 1
		}

		drain_async_completions(vm)

		if !any_ran {
			// Неблокирующий I/O: "никто не выполнялся" больше не
			// автоматически значит дедлок — если есть I/O в полёте
			// (воркер-пул ещё не закончил, ИЛИ результат уже лежит в
			// канале, но drain выше не успел его забрать в ту же
			// итерацию), это настоящий idle-wait, а не тупик: блокируемся
			// на канале (НЕ busy-spin), затем дренируем и пересканируем.
			// pool_num_outstanding — атомарный счётчик пула
			// (waiting+in_processing), не дублируем отдельным полем — он
			// НЕ может ложно показать 0, пока воркер ещё не отправил
			// результат в канал: pool_do_work (thread_pool.odin) снимает
			// счётчик СТРОГО ПОСЛЕ возврата task-процедуры, а наши задачи
			// (http_task_proc) делают chan.send ПОСЛЕДНИМ действием перед
			// возвратом — порядок "send, потом декремент" гарантирован
			// библиотекой, не только соглашением здесь.
			has_pending_io := false
			when thread.IS_SUPPORTED {
				has_pending_io = thread.pool_num_outstanding(&vm.async_pool) > 0 || chan.len(vm.async_completions) > 0
			}
			if has_pending_io {
				when thread.IS_SUPPORTED {
					comp, ok := chan.recv(vm.async_completions)
					if ok do deliver_async_result(vm, comp)
					drain_async_completions(vm)
				}
				continue
			}
			// Ни один процесс не выполнялся за целый круг, и никакого I/O
			// в полёте нет — никто не сможет никого разбудить (отправить()
			// вызывается ТОЛЬКО из исполняющегося кода). Настоящий дедлок,
			// не приближение.
			fmt.panicf(
				"Runtime Error: все процессы заблокированы в ожидании сообщений (дедлок)",
			)
		}
	}
}

print_vm :: proc(vm: ^VM) {
	for s in vm.stack {
		if ps, ok := s.(^Panos_String); ok {
			fmt.println(ps.data)
		} else {
			fmt.println(s)
		}
	}
}
