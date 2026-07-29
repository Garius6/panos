package wasm_runtime

import wasi "core:sys/wasm/wasi"

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

// obj_tags — только для variant-объектов (см. pw_build_variant/
// pw_match_tag, Фаза 2.1); для строк/структур/массивов не используется —
// тот же индекс-пространство object-id, отдельная параллельная таблица,
// не встроено в obj_offsets/obj_sizes, чтобы не трогать существующую
// раскладку строк/агрегатов/массивов.
obj_tags: [MAX_OBJECTS]i32

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

// --- Агрегаты (структуры/анонимные туплы) --------------------------------
//
// Тот же объект-в-арене принцип, что строки (obj_offsets/obj_sizes,
// общая таблица) — размер объекта в байтах = field_count*FIELD_SIZE.
// Каждое поле — 8-байтный слот, ЛИБО f64 (Число/Целое), ЛИБО i32 в
// младших 4 байтах (Булево/Строка-handle) — какой из двух, знает
// СТАТИЧЕСКИ сгенерированный код (см. core/wasm_emit.odin — то же
// "статический тип, без рантайм-тега" решение, что для строк). Ручная
// побайтовая упаковка/распаковка (не прямой `(^f64)(&arena[off])^`) —
// `arena` не гарантированно выровнена под f64 на произвольном смещении.

FIELD_SIZE :: 8

@(private)
pack_u64_le :: proc "contextless" (off: i32, bits: u64) {
	for i in i32(0) ..< 8 {
		arena[off + i] = u8(bits >> uint(i * 8))
	}
}

@(private)
unpack_u64_le :: proc "contextless" (off: i32) -> u64 {
	bits: u64
	for i in i32(0) ..< 8 {
		bits |= u64(arena[off + i]) << uint(i * 8)
	}
	return bits
}

// pw_alloc_aggregate — field_count полей по FIELD_SIZE байт, поля
// изначально нулевые. -1 — арена/таблица объектов исчерпана.
@(export)
pw_alloc_aggregate :: proc "contextless" (field_count: i32) -> i32 {
	size := field_count * FIELD_SIZE
	if next_free + size > ARENA_SIZE || obj_count >= MAX_OBJECTS || field_count < 0 {
		return -1
	}
	off := next_free
	for i in i32(0) ..< size {
		arena[off + i] = 0
	}
	next_free += size

	id := obj_count
	obj_offsets[id] = off
	obj_sizes[id] = size
	obj_count += 1
	return id
}

// pw_build_variant — Фаза 2.1 (ADT): та же раскладка, что
// pw_alloc_aggregate (field_count*FIELD_SIZE нулевых байт), плюс тег в
// obj_tags — Build_Variant_Instr's эмиссия (core/wasm_emit.odin)
// заполняет поля ТЕМ ЖЕ pw_set_field_f64/pw_set_field_i32 циклом, что
// New_Aggregate_Instr/New_Array_Instr.
@(export)
pw_build_variant :: proc "contextless" (tag: i32, field_count: i32) -> i32 {
	size := field_count * FIELD_SIZE
	if next_free + size > ARENA_SIZE || obj_count >= MAX_OBJECTS || field_count < 0 {
		return -1
	}
	off := next_free
	for i in i32(0) ..< size {
		arena[off + i] = 0
	}
	next_free += size

	id := obj_count
	obj_offsets[id] = off
	obj_sizes[id] = size
	obj_tags[id] = tag
	obj_count += 1
	return id
}

@(export)
pw_match_tag :: proc "contextless" (handle: i32, tag: i32) -> i32 {
	return obj_tags[handle] == tag ? 1 : 0
}

@(export)
pw_set_field_f64 :: proc "contextless" (handle: i32, index: i32, value: f64) {
	pack_u64_le(obj_offsets[handle] + index * FIELD_SIZE, transmute(u64)value)
}

@(export)
pw_get_field_f64 :: proc "contextless" (handle: i32, index: i32) -> f64 {
	bits := unpack_u64_le(obj_offsets[handle] + index * FIELD_SIZE)
	return transmute(f64)bits
}

@(export)
pw_set_field_i32 :: proc "contextless" (handle: i32, index: i32, value: i32) {
	pack_u64_le(obj_offsets[handle] + index * FIELD_SIZE, u64(u32(value)))
}

@(export)
pw_get_field_i32 :: proc "contextless" (handle: i32, index: i32) -> i32 {
	bits := unpack_u64_le(obj_offsets[handle] + index * FIELD_SIZE)
	return i32(u32(bits))
}

// --- Фаза 2.2: Массив.длина/получить/есть/содержит/срез ----------------
//
// Массив — тот же field_count*FIELD_SIZE арена-объект, что и структуры
// (см. New_Array_Instr в core/wasm_emit.odin, переиспользует
// pw_alloc_aggregate) — obj_sizes[handle]/FIELD_SIZE = число элементов.
// Ветвление (bounds-check, fallback) сделано ЗДЕСЬ, в обычном Odin, а не
// синтезом новых WASM-блоков на месте вызова (core/wasm_stackify.odin
// фиксирует границы блоков ДО того, как core/wasm_emit.odin эмитит
// инструкции внутри блока — вставка нового ветвления посередине блока
// архитектурно не укладывается в эту схему, а здесь branching бесплатен).

@(export)
pw_array_length :: proc "contextless" (handle: i32) -> i32 {
	return obj_sizes[handle] / FIELD_SIZE
}

@(export)
pw_array_in_bounds :: proc "contextless" (handle: i32, index: i32) -> i32 {
	count := obj_sizes[handle] / FIELD_SIZE
	return (index >= 0 && index < count) ? 1 : 0
}

@(export)
pw_array_get_f64 :: proc "contextless" (handle: i32, index: i32, fallback: f64) -> f64 {
	count := obj_sizes[handle] / FIELD_SIZE
	if index < 0 || index >= count do return fallback
	bits := unpack_u64_le(obj_offsets[handle] + index * FIELD_SIZE)
	return transmute(f64)bits
}

@(export)
pw_array_get_i32 :: proc "contextless" (handle: i32, index: i32, fallback: i32) -> i32 {
	count := obj_sizes[handle] / FIELD_SIZE
	if index < 0 || index >= count do return fallback
	bits := unpack_u64_le(obj_offsets[handle] + index * FIELD_SIZE)
	return i32(u32(bits))
}

@(export)
pw_array_contains_f64 :: proc "contextless" (handle: i32, needle: f64) -> i32 {
	count := obj_sizes[handle] / FIELD_SIZE
	needle_bits := transmute(u64)needle
	for i in i32(0) ..< count {
		if unpack_u64_le(obj_offsets[handle] + i * FIELD_SIZE) == needle_bits do return 1
	}
	return 0
}

@(export)
pw_array_contains_i32 :: proc "contextless" (handle: i32, needle: i32) -> i32 {
	count := obj_sizes[handle] / FIELD_SIZE
	needle_bits := u64(u32(needle))
	for i in i32(0) ..< count {
		if unpack_u64_le(obj_offsets[handle] + i * FIELD_SIZE) == needle_bits do return 1
	}
	return 0
}

// pw_array_slice — новый объект, побайтовая (не f64/i32-осведомлённая)
// копия исходных 8-байтных слотов [start, end) — та же логика, что
// pw_concat_strings's byte-copy, срезу не нужно интерпретировать
// содержимое слотов, только переместить его.
@(export)
pw_array_slice :: proc "contextless" (handle: i32, start: i32, end: i32) -> i32 {
	if start < 0 || end < start do return -1
	count := (end - start) * FIELD_SIZE
	if next_free + count > ARENA_SIZE || obj_count >= MAX_OBJECTS {
		return -1
	}
	src_off := obj_offsets[handle] + start * FIELD_SIZE
	off := next_free
	for i in i32(0) ..< count {
		arena[off + i] = arena[src_off + i]
	}
	next_free += count

	id := obj_count
	obj_offsets[id] = off
	obj_sizes[id] = count
	obj_count += 1
	return id
}

// --- Фаза 2.4: Соответствие ---------------------------------------------
//
// Map_Value в байткод-VM — линейный список пар (core/compiler.odin's
// Map_Value.entries), не хеш-таблица (core/vm.odin's map_find_index —
// линейный скан value_equals) — тот же "плоский, arena-дружественный"
// принцип, что Массив уже использует. Запись = 2*FIELD_SIZE байт
// (ключ-слот, значение-слот, в этом порядке) — New_Map_Instr эмитится
// через emit_construct_object (core/wasm_emit.odin), интерливя keys/
// vals в единый список элементов ДО вызова — здесь не нужен отдельный
// allocator, pw_alloc_aggregate уже подходит (field_count = 2*entry_
// count).
//
// Ключ может быть Число (f64) ИЛИ Строка (i32-handle) — сравнение ключа
// поэтому расщеплено на strkey/numkey варианты (байтовое через
// pw_string_equal, числовое напрямую), тем же принципом, что f64/i32-
// расщепление у Массив.получить/содержит. m[k]=v (растущая вставка) —
// вне области (тот же blocker, что Массив.добавить — арена не растит
// объект на месте) — только чтение/удаление (удаление УМЕНЬШАЕТ,
// tractable без роста, см. core/vm.odin's map_remove_at — тот же
// сдвиг-и-уменьшить, портированный на байтовый layout арены).

@(export)
pw_map_length :: proc "contextless" (handle: i32) -> i32 {
	return obj_sizes[handle] / (2 * FIELD_SIZE)
}

@(private)
map_find_strkey :: proc "contextless" (handle: i32, key: i32) -> i32 {
	count := obj_sizes[handle] / (2 * FIELD_SIZE)
	base := obj_offsets[handle]
	for i in i32(0) ..< count {
		key_bits := unpack_u64_le(base + i * 2 * FIELD_SIZE)
		entry_key := i32(u32(key_bits))
		if pw_string_equal(entry_key, key) == 1 do return i
	}
	return -1
}

@(private)
map_find_numkey :: proc "contextless" (handle: i32, key: f64) -> i32 {
	count := obj_sizes[handle] / (2 * FIELD_SIZE)
	base := obj_offsets[handle]
	needle_bits := transmute(u64)key
	for i in i32(0) ..< count {
		key_bits := unpack_u64_le(base + i * 2 * FIELD_SIZE)
		if key_bits == needle_bits do return i
	}
	return -1
}

@(export)
pw_map_has_strkey :: proc "contextless" (handle: i32, key: i32) -> i32 {
	return map_find_strkey(handle, key) >= 0 ? 1 : 0
}

@(export)
pw_map_has_numkey :: proc "contextless" (handle: i32, key: f64) -> i32 {
	return map_find_numkey(handle, key) >= 0 ? 1 : 0
}

@(export)
pw_map_get_strkey_f64 :: proc "contextless" (handle: i32, key: i32, fallback: f64) -> f64 {
	idx := map_find_strkey(handle, key)
	if idx < 0 do return fallback
	bits := unpack_u64_le(obj_offsets[handle] + idx * 2 * FIELD_SIZE + FIELD_SIZE)
	return transmute(f64)bits
}

@(export)
pw_map_get_strkey_i32 :: proc "contextless" (handle: i32, key: i32, fallback: i32) -> i32 {
	idx := map_find_strkey(handle, key)
	if idx < 0 do return fallback
	bits := unpack_u64_le(obj_offsets[handle] + idx * 2 * FIELD_SIZE + FIELD_SIZE)
	return i32(u32(bits))
}

@(export)
pw_map_get_numkey_f64 :: proc "contextless" (handle: i32, key: f64, fallback: f64) -> f64 {
	idx := map_find_numkey(handle, key)
	if idx < 0 do return fallback
	bits := unpack_u64_le(obj_offsets[handle] + idx * 2 * FIELD_SIZE + FIELD_SIZE)
	return transmute(f64)bits
}

@(export)
pw_map_get_numkey_i32 :: proc "contextless" (handle: i32, key: f64, fallback: i32) -> i32 {
	idx := map_find_numkey(handle, key)
	if idx < 0 do return fallback
	bits := unpack_u64_le(obj_offsets[handle] + idx * 2 * FIELD_SIZE + FIELD_SIZE)
	return i32(u32(bits))
}

@(private)
map_delete_at :: proc "contextless" (handle: i32, idx: i32) {
	base := obj_offsets[handle]
	count := obj_sizes[handle] / (2 * FIELD_SIZE)
	entry_size := i32(2 * FIELD_SIZE)
	for i in idx ..< count - 1 {
		for b in i32(0) ..< entry_size {
			arena[base + i * entry_size + b] = arena[base + (i + 1) * entry_size + b]
		}
	}
	obj_sizes[handle] -= entry_size
}

@(export)
pw_map_delete_strkey :: proc "contextless" (handle: i32, key: i32) -> i32 {
	idx := map_find_strkey(handle, key)
	if idx < 0 do return 0
	map_delete_at(handle, idx)
	return 1
}

@(export)
pw_map_delete_numkey :: proc "contextless" (handle: i32, key: f64) -> i32 {
	idx := map_find_numkey(handle, key)
	if idx < 0 do return 0
	map_delete_at(handle, idx)
	return 1
}

// --- Фаза 2.0: ввод_вывод::печать ------------------------------------
//
// Единственный builtin, поддержанный на этом срезе (см. план) — прямой
// WASI-вызов, СВОЙ foreign import (то, что odin's собственная runtime-
// инициализация уже импортирует wasi_snapshot_preview1.fd_write/
// random_get, видно в объектнике этого же пакета, НЕ делает эти функции
// вызываемыми ИЗ нашего кода — нужен собственный site вызова).

// fd_write — Odin's СОБСТВЕННЫЙ base/runtime (os_specific_wasi.odin)
// уже импортирует "wasi_snapshot_preview1"."fd_write" (для _stderr_write,
// #private — не вызвать напрямую) со СВОЕЙ, высокоуровневой Odin-
// сигнатурой (iovs: [][]byte, не сырой WASI ABI) — объявление ТОГО ЖЕ
// имени import'а с ДРУГОЙ сигнатурой в этом же билде — ошибка компиляции
// ("Redeclaration... with different type signatures"), найдено эмпирически
// при первой попытке. Повторяем ТОЧНО ЕЁ сигнатуру — Odin сам маршаллит
// [][]byte в нужный сырой iovec-массив, независимо от того, кто объявил.
foreign import wasi_snapshot "wasi_snapshot_preview1"
@(default_calling_convention = "contextless")
foreign wasi_snapshot {
	fd_write :: proc(fd: i32, iovs: [][]byte, n: ^uint) -> u16 ---
}

@(export)
pw_print_string :: proc "contextless" (handle: i32) {
	off, length := obj_offsets[handle], obj_sizes[handle]
	data := arena[off:][:length]
	n: uint
	fd_write(1, {data}, &n)
}

// --- Фаза 2: строки::содержит/начинается_с/заканчивается_на -----------
// Наивный побайтовый поиск (не Boyer-Moore/KMP) — оправдано размером
// фикстур этого бэкенда, та же логика, что core:strings.contains/
// has_prefix/has_suffix на стороне байткод-VM (core/vm.odin), только без
// доступа к core:strings отсюда (contextless, своя память).

@(export)
pw_string_starts_with :: proc "contextless" (a: i32, prefix: i32) -> i32 {
	a_off, a_len := obj_offsets[a], obj_sizes[a]
	p_off, p_len := obj_offsets[prefix], obj_sizes[prefix]
	if p_len > a_len do return 0
	for i in i32(0) ..< p_len {
		if arena[a_off + i] != arena[p_off + i] do return 0
	}
	return 1
}

@(export)
pw_string_ends_with :: proc "contextless" (a: i32, suffix: i32) -> i32 {
	a_off, a_len := obj_offsets[a], obj_sizes[a]
	s_off, s_len := obj_offsets[suffix], obj_sizes[suffix]
	if s_len > a_len do return 0
	base := a_off + (a_len - s_len)
	for i in i32(0) ..< s_len {
		if arena[base + i] != arena[s_off + i] do return 0
	}
	return 1
}

@(export)
pw_string_contains :: proc "contextless" (a: i32, pattern: i32) -> i32 {
	a_off, a_len := obj_offsets[a], obj_sizes[a]
	p_off, p_len := obj_offsets[pattern], obj_sizes[pattern]
	if p_len == 0 do return 1
	if p_len > a_len do return 0
	for start in i32(0) ..= a_len - p_len {
		match := true
		for i in i32(0) ..< p_len {
			if arena[a_off + start + i] != arena[p_off + i] {
				match = false
				break
			}
		}
		if match do return 1
	}
	return 0
}

// pw_int_to_string — строки::из_целого: десятичное форматирование БЕЗ
// плавающей точки (Целое всегда целое число на этом срезе — никакой
// scientific-notation неоднозначности, в отличие от строки::из_числа,
// сознательно НЕ реализованного здесь — core:fmt-совместимое
// форматирование f64 воспроизводить вручную рискованно, см. память
// проекта про "%v" f64 -> scientific notation выше ~6-7 значащих цифр).
@(export)
pw_int_to_string :: proc "contextless" (value: f64) -> i32 {
	n := i64(value)
	neg := n < 0
	if neg do n = -n

	buf: [24]u8
	pos := len(buf)
	if n == 0 {
		pos -= 1
		buf[pos] = '0'
	} else {
		for n > 0 {
			pos -= 1
			buf[pos] = u8('0' + (n % 10))
			n /= 10
		}
	}
	if neg {
		pos -= 1
		buf[pos] = '-'
	}
	length := i32(len(buf) - pos)

	if next_free + length > ARENA_SIZE || obj_count >= MAX_OBJECTS {
		return -1
	}
	off := next_free
	for i in i32(0) ..< length {
		arena[off + i] = buf[pos + int(i)]
	}
	next_free += length

	id := obj_count
	obj_offsets[id] = off
	obj_sizes[id] = length
	obj_count += 1
	return id
}

// pw_string_compare — трёхзначное лексикографическое БАЙТОВОЕ сравнение,
// -1/0/1 (см. base/runtime's string_cmp/memory_compare, которое
// core:strings.compare — и, транзитивно, core/vm.odin's строки::
// сравнить — использует на стороне байткод-VM: ВСЕГДА ровно -1/0/1, не
// сырая разница байтов, проверено чтением исходника Odin, не
// предположено).
@(export)
pw_string_compare :: proc "contextless" (a: i32, b: i32) -> f64 {
	a_off, a_len := obj_offsets[a], obj_sizes[a]
	b_off, b_len := obj_offsets[b], obj_sizes[b]
	n := min(a_len, b_len)
	for i in i32(0) ..< n {
		if arena[a_off + i] != arena[b_off + i] {
			return arena[a_off + i] < arena[b_off + i] ? -1 : 1
		}
	}
	if a_len != b_len {
		return a_len < b_len ? -1 : 1
	}
	return 0
}

// pw_string_replace_all — строки::заменить: два прохода (посчитать
// непересекающиеся вхождения old, затем построить результат) — то же
// non-overlapping-сканирование, что core:strings.replace_all на стороне
// байткод-VM. Пустой old — 0 вхождений (результат = копия text), не
// пытаемся воспроизвести особый (и редко используемый) случай "вставить
// new между каждым символом", который дал бы core:strings.replace_all
// для old="" — вне тестового скоупа этого среза.
@(export)
pw_string_replace_all :: proc "contextless" (text: i32, old: i32, new: i32) -> i32 {
	t_off, t_len := obj_offsets[text], obj_sizes[text]
	o_off, o_len := obj_offsets[old], obj_sizes[old]
	n_off, n_len := obj_offsets[new], obj_sizes[new]

	matches_at :: proc "contextless" (t_off, i, o_off, o_len: i32) -> bool {
		for j in i32(0) ..< o_len {
			if arena[t_off + i + j] != arena[o_off + j] do return false
		}
		return true
	}

	count: i32 = 0
	if o_len > 0 {
		i := i32(0)
		for i <= t_len - o_len {
			if matches_at(t_off, i, o_off, o_len) {
				count += 1
				i += o_len
			} else {
				i += 1
			}
		}
	}

	result_len := t_len + count * (n_len - o_len)
	if next_free + result_len > ARENA_SIZE || obj_count >= MAX_OBJECTS || result_len < 0 {
		return -1
	}
	off := next_free
	write_pos := off
	i := i32(0)
	for i < t_len {
		if o_len > 0 && i <= t_len - o_len && matches_at(t_off, i, o_off, o_len) {
			for j in i32(0) ..< n_len {
				arena[write_pos] = arena[n_off + j]
				write_pos += 1
			}
			i += o_len
		} else {
			arena[write_pos] = arena[t_off + i]
			write_pos += 1
			i += 1
		}
	}
	next_free += result_len

	id := obj_count
	obj_offsets[id] = off
	obj_sizes[id] = result_len
	obj_count += 1
	return id
}

// --- время::монотонно_мс/сейчас_мс -------------------------------------
//
// core:sys/wasm/wasi (ОТДЕЛЬНЫЙ публичный Odin-пакет, не base/runtime's
// #private os_specific_wasi.odin, см. докстринг про fd_write выше) —
// собственного raw foreign import здесь заводить не нужно, wasi.
// clock_time_get уже proc "contextless" и не требует context.allocator.
//
// ВАЖНО (не для дифф-тестов на точное равенство, см. core/wasm_backend_
// wasmtime_test.odin): байткод-VM's время::монотонно_мс отсчитывает от
// СВОЕГО vm.monotonic_epoch (момент запуска ЭТОГО процесса), а WASI's
// CLOCK_MONOTONIC — от опорной точки хоста (обычно system boot), у
// байткод-VM и скомпилированного .wasm-модуля РАЗНЫЕ процессы — значения
// заведомо не совпадут численно. Проверяется отдельно ("возвращает
// положительное число"), не через wasm_diff_check.
@(export)
pw_monotonic_ms :: proc "contextless" () -> f64 {
	ts, _ := wasi.clock_time_get(wasi.CLOCK_MONOTONIC, 0)
	return f64(ts) / 1e6
}

@(export)
pw_now_ms :: proc "contextless" () -> f64 {
	ts, _ := wasi.clock_time_get(wasi.CLOCK_REALTIME, 0)
	return f64(ts) / 1e6
}
