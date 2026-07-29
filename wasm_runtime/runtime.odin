package wasm_runtime

// wasm_runtime — Фаза 1.5 WASM AOT-бэкенда: минимальный, ОТДЕЛЬНЫЙ от
// core/gc.odin аллокатор для heap-значений (пока только строки) в
// скомпилированных panos-программах. НЕ переиспользует core/gc.odin —
// см. решение в плане (реальный GC завязан на структуру VM, а компиляция
// ВСЕГО package core под -target:wasi_wasm32 упирается в непортированные
// на wasi core:dynlib/core:terminal самого Odin). Этот пакет НЕ
// импортирует ничего из core/ — чистая арифметика над фиксированными
// буферами, proc "contextless" (без context.allocator/make/append, как
// рекомендует сам Odin для wasm-целей).
//
// Владение памятью: ЭТОТ модуль — единственный, кто владеет/экспортирует
// линейную память (см. Шаг 0-спайк Фазы 1: `wasmtime run --preload`
// инстанцирует preload-модуль ПЕРВЫМ, значит ТОЛЬКО preload-модуль может
// быть стороной-экспортёром для того, что грузится позже — экспортировать
// память из ПОЗЖЕ загружаемого сгенерированного кода сюда технически
// невозможно при этом порядке). Сгенерированный код (core/wasm_module.
// odin) поэтому НИКОГДА не работает с сырыми адресами в этой памяти —
// строковые константы передаются побайтово через pw_scratch_set (без
// этого сгенерированному и рантайм-модулю пришлось бы согласовывать
// раскладку памяти между двумя НЕЗАВИСИМО слинкованными wasm-модулями,
// у каждого из которых своя, невидимая снаружи, компоновка — реальная
// ловушка, найденная и отклонённая при проектировании, не гипотетическая).
//
// Bump-аллокатор без сборки мусора (Фаза 1.5: фикстуры маленькие,
// коллекция — отдельная, более поздняя задача).

ARENA_SIZE :: 1 << 20 // 1 MiB — с запасом для Фазы 1.5 фикстур
MAX_OBJECTS :: 4096
SCRATCH_SIZE :: 1 << 16 // 64 KiB — с запасом на одну строковую константу разом

arena:      [ARENA_SIZE]u8
next_free:  i32
scratch:    [SCRATCH_SIZE]u8

obj_offsets: [MAX_OBJECTS]i32
obj_sizes:   [MAX_OBJECTS]i32
obj_count:   i32

// pw_scratch_set — записывает ОДИН байт строковой константы в scratch-
// буфер (сгенерированный код зовёт это в цикле, по байту на константу,
// ПЕРЕД pw_alloc_from_scratch) — см. докстринг файла про то, почему не
// сырой адрес.
@(export)
pw_scratch_set :: proc "contextless" (index: i32, byte_value: i32) {
	if index < 0 || index >= SCRATCH_SIZE do return
	scratch[index] = u8(byte_value)
}

// pw_alloc_from_scratch — переносит первые length байт scratch-буфера в
// постоянный объект арены, возвращает handle. -1 — арена/таблица
// объектов исчерпана (Фаза 1.5 не делает collect+retry).
@(export)
pw_alloc_from_scratch :: proc "contextless" (length: i32) -> i32 {
	if next_free + length > ARENA_SIZE || obj_count >= MAX_OBJECTS || length < 0 {
		return -1
	}
	off := next_free
	for i in i32(0) ..< length {
		arena[off + i] = scratch[i]
	}
	next_free += length

	id := obj_count
	obj_offsets[id] = off
	obj_sizes[id] = length
	obj_count += 1
	return id
}

@(export)
pw_string_len :: proc "contextless" (handle: i32) -> i32 {
	return obj_sizes[handle]
}

// pw_concat_strings — новый объект = байты a + байты b (panos's `+` на
// двух Строка, см. core/vm.odin's .Add — та же семантика, конкатенация).
@(export)
pw_concat_strings :: proc "contextless" (a: i32, b: i32) -> i32 {
	a_off, a_len := obj_offsets[a], obj_sizes[a]
	b_off, b_len := obj_offsets[b], obj_sizes[b]
	total := a_len + b_len
	if next_free + total > ARENA_SIZE || obj_count >= MAX_OBJECTS {
		return -1
	}
	off := next_free
	for i in i32(0) ..< a_len {
		arena[off + i] = arena[a_off + i]
	}
	for i in i32(0) ..< b_len {
		arena[off + a_len + i] = arena[b_off + i]
	}
	next_free += total

	id := obj_count
	obj_offsets[id] = off
	obj_sizes[id] = total
	obj_count += 1
	return id
}

// pw_string_equal — байтовое сравнение (panos's Строка `==`/`!=`,
// core/vm.odin's value_equals для ^Panos_String — тоже байтовое).
// Возвращает i32 0/1 (WASM-булево, см. core/wasm_emit.odin).
@(export)
pw_string_equal :: proc "contextless" (a: i32, b: i32) -> i32 {
	a_off, a_len := obj_offsets[a], obj_sizes[a]
	b_off, b_len := obj_offsets[b], obj_sizes[b]
	if a_len != b_len do return 0
	for i in i32(0) ..< a_len {
		if arena[a_off + i] != arena[b_off + i] do return 0
	}
	return 1
}
