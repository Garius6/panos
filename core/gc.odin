package core

import "base:runtime"
import "core:strings"

// Простой non-moving mark-and-sweep — сырых указателей на Value-объекты
// разбросано по всему vm.odin/compiler.odin, moving/copying-коллектор
// потребовал бы fixup всех этих мест при каждом перемещении. Не инкрементальный
// и не параллельный — оверкилл для текущего масштаба (см. ROADMAP §Стадия 1).
GC_Header :: struct {
	marked: bool,
}

// Строковое Value. Compile-time литералы оборачиваются через perm_string()
// (arena/heap-allocated, но НЕ регистрируется в GC — живёт весь процесс,
// освобождать нечего, header.marked для них никогда не читается).
// Runtime-строки (конкатенация, файловый ввод, stdin, срез) — через
// gc_new_string(): полноценно GC-managed, освобождаются при sweep, если
// недостижимы.
Panos_String :: struct {
	header: GC_Header,
	data:   string,
}

GC_State :: struct {
	all_objects:     [dynamic]Value, // всё когда-либо выделенное через gc_new
	// Временная защита значений между pop(vm.stack) и следующей аллокацией:
	// без неё окно "значение снято со стека, но ещё не вложено в новый
	// объект (или объект ещё не вложен обратно в стек)" делает его
	// невидимым для mark, и sweep освобождает то, что нужно микросекунду
	// спустя. Каждый gc_new-вызов, за которым следует ДРУГОЙ gc_new до
	// того, как результат первого окажется на vm.stack, должен обернуть
	// промежуточное значение gc_protect/gc_unprotect.
	protect_stack:   [dynamic]Value,
	bytes_allocated: int,
	next_threshold:  int,
	collections_run: int,
	freed_last_run:  int,

	// Free-list по типу: sweep не зовёт free() на unreachable-объекте, а
	// кладёт его сюда (см. pool_release/pool_take) — при следующем gc_new
	// того же типа объект переиспользуется вместо нового malloc. Без
	// этого RSS растёт под sustained-churn нагрузкой ("миллион аллокаций
	// в цикле") ДАЖЕ при полностью корректном mark/sweep: логический live
	// set остаётся плоским, но free() не гарантирует, что ОС быстро
	// вернёт освобождённые страницы под следующий такой же по размеру
	// new() — этот разрыв между "logically freed" и "OS-visible память
	// переиспользована" эмпирически проверен (см. TASKS.md §Стадия 1).
	free_aggregates: [dynamic]^Aggregate_Value,
	free_arrays:     [dynamic]^Array_Value,
	free_maps:       [dynamic]^Map_Value,
	free_errors:     [dynamic]^Error_Value,
	free_options:    [dynamic]^Option_Value,
	free_results:    [dynamic]^Result_Value,
	free_interfaces: [dynamic]^Interface_Value,
	free_variants:   [dynamic]^Variant_Value,
	free_strings:    [dynamic]^Panos_String,
}

// Не собираем, пока живой хип меньше этого — иначе на маленьких
// программах GC гоняется на каждый чих.
GC_MIN_THRESHOLD :: 1024 * 1024

new_gc_state :: proc() -> GC_State {
	context.allocator = runtime.heap_allocator()
	return GC_State {
		all_objects = make([dynamic]Value),
		protect_stack = make([dynamic]Value),
		next_threshold = GC_MIN_THRESHOLD,
		free_aggregates = make([dynamic]^Aggregate_Value),
		free_arrays = make([dynamic]^Array_Value),
		free_maps = make([dynamic]^Map_Value),
		free_errors = make([dynamic]^Error_Value),
		free_options = make([dynamic]^Option_Value),
		free_results = make([dynamic]^Result_Value),
		free_interfaces = make([dynamic]^Interface_Value),
		free_variants = make([dynamic]^Variant_Value),
		free_strings = make([dynamic]^Panos_String),
	}
}

gc_protect :: proc(vm: ^VM, v: Value) {
	append(&vm.gc.protect_stack, v)
}

gc_unprotect :: proc(vm: ^VM, n: int) {
	resize(&vm.gc.protect_stack, len(vm.gc.protect_stack) - n)
}

pool_take :: proc(pool: ^[dynamic]^$T) -> ^T {
	if len(pool) == 0 do return nil
	obj := pool[len(pool) - 1]
	resize(pool, len(pool) - 1)
	return obj
}

// Аллоцирует T на выделенном GC-хипе (runtime.heap_allocator(), НЕ общая
// arena процесса из main.odin — Dynamic_Arena не поддерживает free()
// отдельных аллокаций; тот же урок, что и с INTERNER в interner.odin).
// Сначала пробует переиспользовать объект из free-list (см. GC_State) —
// только если пул пуст, идёт настоящий new(). Может триггернуть
// collect_garbage() ПЕРЕД аллокацией нового объекта — сам новый объект в
// этот момент ещё не существует, беспокоиться за него не нужно;
// беспокоиться нужно за уже существующие значения, которые в этот момент
// нигде не закреплены — см. gc_protect.
//
// ВАЖНО для .elements/.entries/.fields полей: чтобы пул реально экономил
// malloc, вызывающий код должен использовать resize(&obj.elements, n), а
// НЕ obj.elements = make([dynamic]Value, n) — последнее убивает
// переиспользованный backing-буфер, обнуляя весь смысл пула (см. vm.odin
// Build_Aggregate/Build_Array/Build_Map/Build_Variant).
gc_new :: proc(vm: ^VM, $T: typeid) -> ^T {
	if vm.gc.bytes_allocated > vm.gc.next_threshold {
		collect_garbage(vm)
	}

	obj: ^T
	when T == Aggregate_Value {
		obj = pool_take(&vm.gc.free_aggregates)
	} else when T == Array_Value {
		obj = pool_take(&vm.gc.free_arrays)
	} else when T == Map_Value {
		obj = pool_take(&vm.gc.free_maps)
	} else when T == Error_Value {
		obj = pool_take(&vm.gc.free_errors)
	} else when T == Option_Value {
		obj = pool_take(&vm.gc.free_options)
	} else when T == Result_Value {
		obj = pool_take(&vm.gc.free_results)
	} else when T == Interface_Value {
		obj = pool_take(&vm.gc.free_interfaces)
	} else when T == Variant_Value {
		obj = pool_take(&vm.gc.free_variants)
	} else when T == Panos_String {
		obj = pool_take(&vm.gc.free_strings)
	}

	if obj == nil {
		context.allocator = runtime.heap_allocator()
		obj = new(T)
	} else {
		obj.header.marked = false
	}
	append(&vm.gc.all_objects, Value(obj))
	vm.gc.bytes_allocated += size_of(T)
	return obj
}

// permanent-строка: compile-time литерал, живёт в Compiled_Function.constants
// столько же, сколько сама функция (весь процесс). Не регистрируется в
// GC — sweep её не видит.
perm_string :: proc(s: string) -> ^Panos_String {
	context.allocator = runtime.heap_allocator()
	ps := new(Panos_String)
	ps.data = strings.clone(s)
	return ps
}

// runtime-строка — полноценно GC-managed.
gc_new_string :: proc(vm: ^VM, s: string) -> ^Panos_String {
	ps := gc_new(vm, Panos_String)
	context.allocator = runtime.heap_allocator()
	delete(ps.data) // на случай переиспользования из free_strings — старые байты чужие
	ps.data = strings.clone(s)
	vm.gc.bytes_allocated += len(ps.data)
	return ps
}

// nil для не-GC-managed вариантов (f64/bool/^Compiled_Function — последний
// живёт в глобальном реестре функций всю программу, никогда не
// собирается).
get_header :: proc(v: Value) -> ^GC_Header {
	switch val in v {
	case ^Panos_String:
		return &val.header
	case ^Aggregate_Value:
		return &val.header
	case ^Array_Value:
		return &val.header
	case ^Map_Value:
		return &val.header
	case ^Error_Value:
		return &val.header
	case ^Option_Value:
		return &val.header
	case ^Result_Value:
		return &val.header
	case ^Interface_Value:
		return &val.header
	case ^Variant_Value:
		return &val.header
	case f64, bool, ^Compiled_Function:
		return nil
	}
	return nil
}

// Помечает объект и рекурсивно — его детей. Exhaustive switch (НЕ
// #partial) — добавишь 12-й вариант Value, компилятор заставит обновить
// этот walker раньше, чем он молча пропустит новый тип указателей.
// mark_header сам по себе — cycle guard: уже помеченное не обходится
// повторно, так что циклические структуры (self-referential Aggregate и
// т.п.) не зацикливают mark.
mark_value :: proc(v: Value) {
	h := get_header(v)
	if h == nil do return // f64/bool/^Compiled_Function — не GC-managed
	if h.marked do return // уже размечено — обрыв цикла
	h.marked = true

	switch val in v {
	case f64, bool, ^Compiled_Function, ^Panos_String:
	// листья — нечего обходить дальше
	case ^Aggregate_Value:
		for el in val.elements do mark_value(el)
	case ^Array_Value:
		for el in val.elements do mark_value(el)
	case ^Map_Value:
		for entry in val.entries {
			mark_value(entry.key)
			mark_value(entry.value)
		}
	case ^Error_Value:
		if val.code != nil do mark_value(Value(val.code))
		if val.message != nil do mark_value(Value(val.message))
	case ^Option_Value:
		mark_value(val.value)
	case ^Result_Value:
		mark_value(val.value)
		mark_value(val.error)
	case ^Interface_Value:
		if val.data != nil do mark_value(Value(val.data))
	case ^Variant_Value:
		for f in val.fields do mark_value(f)
	}
}

// vm.stack покрывает и temporaries, и локальные переменные (frame_pointer
// индексирует в тот же стек — у CallFrame нет отдельного Value-хранилища).
// protect_stack — временные защиты (см. gc_protect). registry
// (vm.compiled_functions.constants) — на случай, если когда-нибудь
// появится constant-folding, кладущее живые объекты прямо в константы.
mark_roots :: proc(vm: ^VM) {
	for v in vm.stack do mark_value(v)
	for v in vm.gc.protect_stack do mark_value(v)
	for _, fn in vm.compiled_functions {
		for c in fn.constants do mark_value(c)
	}
}

// Симметрично тому, что gc_new/gc_new_string прибавляют к bytes_allocated —
// нужно sweep'у, чтобы decrement был точной парой к increment'у при
// аллокации, иначе bytes_allocated только растёт, threshold растёт вместе с
// ним, и GC со временем перестаёт триггериться вообще (грубое
// приближение: содержимое [dynamic]-полей типа elements/entries/fields в
// расчёт не идёт, только сам заголовок структуры + байты строки).
value_size :: proc(v: Value) -> int {
	switch val in v {
	case f64, bool, ^Compiled_Function:
		return 0
	case ^Panos_String:
		return size_of(Panos_String) + len(val.data)
	case ^Aggregate_Value:
		return size_of(Aggregate_Value)
	case ^Array_Value:
		return size_of(Array_Value)
	case ^Map_Value:
		return size_of(Map_Value)
	case ^Error_Value:
		return size_of(Error_Value)
	case ^Option_Value:
		return size_of(Option_Value)
	case ^Result_Value:
		return size_of(Result_Value)
	case ^Interface_Value:
		return size_of(Interface_Value)
	case ^Variant_Value:
		return size_of(Variant_Value)
	}
	return 0
}

// Возвращает объект в free-list вместо free(): clear() обнуляет длину
// elements/entries/fields, но СОХРАНЯЕТ capacity backing-буфера — следующий
// gc_new того же типа + resize(&obj.field, n) переиспользует его без
// нового malloc. methods (map) у Interface_Value — редкий, некрупный
// случай, здесь просто delete()'им (не настолько горячий путь).
pool_release :: proc(vm: ^VM, v: Value) {
	context.allocator = runtime.heap_allocator()
	switch val in v {
	case f64, bool, ^Compiled_Function:
	// не GC-managed
	case ^Panos_String:
		append(&vm.gc.free_strings, val)
	case ^Aggregate_Value:
		clear(&val.elements)
		append(&vm.gc.free_aggregates, val)
	case ^Array_Value:
		clear(&val.elements)
		append(&vm.gc.free_arrays, val)
	case ^Map_Value:
		clear(&val.entries)
		append(&vm.gc.free_maps, val)
	case ^Error_Value:
		val.code = nil
		val.message = nil
		append(&vm.gc.free_errors, val)
	case ^Option_Value:
		val.value = nil
		append(&vm.gc.free_options, val)
	case ^Result_Value:
		val.value = nil
		val.error = nil
		append(&vm.gc.free_results, val)
	case ^Interface_Value:
		delete(val.methods)
		val.data = nil
		val.methods = nil
		append(&vm.gc.free_interfaces, val)
	case ^Variant_Value:
		clear(&val.fields)
		append(&vm.gc.free_variants, val)
	}
}

sweep :: proc(vm: ^VM) -> int {
	freed := 0
	write := 0
	for read := 0; read < len(vm.gc.all_objects); read += 1 {
		obj := vm.gc.all_objects[read]
		h := get_header(obj)
		if h == nil || h.marked {
			if h != nil do h.marked = false // сброс для следующего цикла
			vm.gc.all_objects[write] = obj
			write += 1
		} else {
			vm.gc.bytes_allocated -= value_size(obj)
			pool_release(vm, obj)
			freed += 1
		}
	}
	resize(&vm.gc.all_objects, write)
	return freed
}

collect_garbage :: proc(vm: ^VM) {
	mark_roots(vm)
	freed := sweep(vm)
	vm.gc.collections_run += 1
	vm.gc.freed_last_run = freed
	vm.gc.next_threshold = max(vm.gc.bytes_allocated * 2, GC_MIN_THRESHOLD)
}

// Публичный хук для тестов — форсирует сборку вне зависимости от threshold
// (нужно для детерминированных "было N живых объектов, стало M" тестов).
force_gc :: proc(vm: ^VM) {
	collect_garbage(vm)
}

GC_Stats :: struct {
	live_objects:    int,
	bytes_allocated: int,
	collections_run: int,
	freed_last_run:  int,
}

gc_stats :: proc(vm: ^VM) -> GC_Stats {
	return GC_Stats {
		live_objects = len(vm.gc.all_objects),
		bytes_allocated = vm.gc.bytes_allocated,
		collections_run = vm.gc.collections_run,
		freed_last_run = vm.gc.freed_last_run,
	}
}
