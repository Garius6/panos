package wasm_runtime

import "base:intrinsics"
import "base:runtime"
import "core:strconv"
import "core:unicode"
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

// obj_capacity — Фаза 2.7 (рост арены): байт РЕЗЕРВИРОВАНО, в отличие
// от obj_sizes (байт ИСПОЛЬЗУЕТСЯ). Каждый существующий allocator
// (pw_alloc_from_scratch/pw_concat_strings/pw_alloc_aggregate/pw_build_
// variant/pw_array_slice/pw_int_to_string/pw_string_replace_all)
// выставляет obj_capacity[id] = размер В МОМЕНТ создания (без запаса —
// массив()+.добавить()-цикл — доминирующий реальный паттерн, первый
// добавить() растёт с нуля в любом случае, простота важнее микро-
// оптимизации на масштабе фикстур этого бэкенда) — см. ensure_capacity
// ниже, единственное место, где capacity РАСХОДИТСЯ с size.
obj_capacity: [MAX_OBJECTS]i32

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
	obj_capacity[id] = obj_sizes[id]
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
	obj_capacity[id] = obj_sizes[id]
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
	obj_capacity[id] = obj_sizes[id]
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
	obj_capacity[id] = obj_sizes[id]
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
	obj_capacity[id] = obj_sizes[id]
	obj_count += 1
	return id
}

// --- Фаза 2.7: рост арены (Массив.добавить, m[k]=v) ---------------------
//
// handle — стабильный ID (индекс в obj_offsets/obj_sizes/obj_capacity),
// НЕ сырой адрес — весь код всегда читает obj_offsets[handle] заново на
// каждый вызов (см. докстринг файла про то, почему сгенерированный код
// никогда не держит сырых адресов) — значит объект МОЖНО релоцировать
// (скопировать байты в новый регион, поменять obj_offsets[handle]) без
// инвалидации чего-либо снаружи, тот же handle продолжает работать. Тем
// самым рост становится классическим growable-vector realloc поверх
// bump-арены — БЕЗ настоящего GC (старые байты остаются мусором,
// никогда не переиспользуются — тот же принцип, что уже принят для
// удалить()'s сжатия и pw_string_replace_all's пересборки).
@(private)
ensure_capacity :: proc "contextless" (handle: i32, extra: i32) -> bool {
	needed := obj_sizes[handle] + extra
	if needed <= obj_capacity[handle] do return true
	new_cap := obj_capacity[handle] * 2
	if new_cap < needed do new_cap = needed
	if next_free + new_cap > ARENA_SIZE || obj_count >= MAX_OBJECTS {
		return false
	}
	off := next_free
	for i in i32(0) ..< obj_sizes[handle] {
		arena[off + i] = arena[obj_offsets[handle] + i]
	}
	next_free += new_cap
	obj_offsets[handle] = off
	obj_capacity[handle] = new_cap
	return true
}

// pw_array_push_f64/i32 — Массив.добавить: растёт на ровно 1 FIELD_SIZE-
// слот (тот же f64/i32-выбор по статическому типу элемента, что весь
// остальной Массив-код, см. core/wasm_emit.odin) и дописывает value в
// хвост. 0 — арена/таблица объектов исчерпана (тот же -1-конвенции для
// других аллокаторов здесь неприменим — эти функции возвращают i32-
// булево "успех", не handle).
@(export)
pw_array_push_f64 :: proc "contextless" (handle: i32, value: f64) -> i32 {
	if !ensure_capacity(handle, FIELD_SIZE) do return 0
	pack_u64_le(obj_offsets[handle] + obj_sizes[handle], transmute(u64)value)
	obj_sizes[handle] += FIELD_SIZE
	return 1
}

@(export)
pw_array_push_i32 :: proc "contextless" (handle: i32, value: i32) -> i32 {
	if !ensure_capacity(handle, FIELD_SIZE) do return 0
	pack_u64_le(obj_offsets[handle] + obj_sizes[handle], u64(u32(value)))
	obj_sizes[handle] += FIELD_SIZE
	return 1
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

// pw_map_set_* — Фаза 2.7: m[k]=v. Совпадает с core/vm.odin's .Set_Index
// UPSERT-семантикой ровно (см. её докстринг): ключ найден — перезаписать
// value-слот НА МЕСТЕ (роста не нужно); не найден — вырастить на 2*
// FIELD_SIZE (ключ+значение) и дописать пару в хвост. Найденный индекс
// умножается на 2*FIELD_SIZE (размер ПАРЫ), а не FIELD_SIZE — та же
// раскладка, что map_find_*/map_delete_at уже используют.
@(export)
pw_map_set_strkey_f64 :: proc "contextless" (handle: i32, key: i32, value: f64) -> i32 {
	if idx := map_find_strkey(handle, key); idx >= 0 {
		pack_u64_le(obj_offsets[handle] + idx * 2 * FIELD_SIZE + FIELD_SIZE, transmute(u64)value)
		return 1
	}
	if !ensure_capacity(handle, 2 * FIELD_SIZE) do return 0
	base := obj_offsets[handle] + obj_sizes[handle]
	pack_u64_le(base, u64(u32(key)))
	pack_u64_le(base + FIELD_SIZE, transmute(u64)value)
	obj_sizes[handle] += 2 * FIELD_SIZE
	return 1
}

@(export)
pw_map_set_strkey_i32 :: proc "contextless" (handle: i32, key: i32, value: i32) -> i32 {
	if idx := map_find_strkey(handle, key); idx >= 0 {
		pack_u64_le(obj_offsets[handle] + idx * 2 * FIELD_SIZE + FIELD_SIZE, u64(u32(value)))
		return 1
	}
	if !ensure_capacity(handle, 2 * FIELD_SIZE) do return 0
	base := obj_offsets[handle] + obj_sizes[handle]
	pack_u64_le(base, u64(u32(key)))
	pack_u64_le(base + FIELD_SIZE, u64(u32(value)))
	obj_sizes[handle] += 2 * FIELD_SIZE
	return 1
}

@(export)
pw_map_set_numkey_f64 :: proc "contextless" (handle: i32, key: f64, value: f64) -> i32 {
	if idx := map_find_numkey(handle, key); idx >= 0 {
		pack_u64_le(obj_offsets[handle] + idx * 2 * FIELD_SIZE + FIELD_SIZE, transmute(u64)value)
		return 1
	}
	if !ensure_capacity(handle, 2 * FIELD_SIZE) do return 0
	base := obj_offsets[handle] + obj_sizes[handle]
	pack_u64_le(base, transmute(u64)key)
	pack_u64_le(base + FIELD_SIZE, transmute(u64)value)
	obj_sizes[handle] += 2 * FIELD_SIZE
	return 1
}

@(export)
pw_map_set_numkey_i32 :: proc "contextless" (handle: i32, key: f64, value: i32) -> i32 {
	if idx := map_find_numkey(handle, key); idx >= 0 {
		pack_u64_le(obj_offsets[handle] + idx * 2 * FIELD_SIZE + FIELD_SIZE, u64(u32(value)))
		return 1
	}
	if !ensure_capacity(handle, 2 * FIELD_SIZE) do return 0
	base := obj_offsets[handle] + obj_sizes[handle]
	pack_u64_le(base, transmute(u64)key)
	pack_u64_le(base + FIELD_SIZE, u64(u32(value)))
	obj_sizes[handle] += 2 * FIELD_SIZE
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

// pw_println_string — ввод_вывод::строка (bytecode: fmt.println, печать
// с завершающим переводом строки, в отличие от pw_print_string выше).
// ДВА отдельных fd_write-вызова, НЕ один с двумя iovec — подтверждено
// спайком ДО вживления: WASI fd_write здесь делает частичную запись
// (writev-семантика, валидно по спецификации) — {data, newline[:]} в
// ОДНОМ вызове реально писал ТОЛЬКО первый iovec (n возвращал len(data),
// второй молча терялся), а не паниковал/ошибался — тихий, а не громкий
// баг, если бы не проверили. Два ОДНО-iovec вызова (та же форма, что
// уже проверенный pw_print_string) надёжно пишут оба куска.
@(export)
pw_println_string :: proc "contextless" (handle: i32) {
	off, length := obj_offsets[handle], obj_sizes[handle]
	data := arena[off:][:length]
	newline := [1]byte{'\n'}
	n: uint
	fd_write(1, {data}, &n)
	fd_write(1, {newline[:]}, &n)
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
	obj_capacity[id] = obj_sizes[id]
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
	obj_capacity[id] = obj_sizes[id]
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

// --- Фаза 2.8: рун-осведомлённые строковые операции ---------------------
//
// panos's собственная строковая модель — рунная (UTF-8 codepoint), не
// байтовая (Cyrillic-heavy фикстуры проекта, см. core/utils.odin's
// get_character_at/string_slice_by_rune/string_find_rune — все считают
// РУНЫ). Ручной UTF-8 декод/энкод (не core:unicode/utf8 — тот же принцип,
// что весь этот пакет: contextless, без зависимостей за пределами
// core:sys/wasm/wasi) — алгоритм по битовому паттерну ведущего байта,
// общеизвестный, не нуждается в стандартной библиотеке.
//
// OOB/невалидный вход — intrinsics.trap() (реальный WASM unreachable,
// подтверждено спайком перед вживлением, та же дисциплина "проверить
// перед тем, как вписать в реальный кодоген", что весь этот бэкенд уже
// применял) — байткод-VM ПАНИКУЕТ на эти случаи (срез/байт/срез_байт/
// из_байтов), не молча отгружает мусор, как принятый ранее (Фаза 2.1/
// 2.4, ДО появления паника()/trap в этом бэкенде вообще) gap для
// Массив/Соответствие OOB — теперь, когда trap-механизм есть, честнее
// повторить byte-код-семантику, а не тихо читать соседнюю память.
// найти() остаётся fallback'ом (-1), не паникой — так же, как
// string_find_rune сама устроена.

@(private)
utf8_decode_at :: proc "contextless" (off: i32) -> (cp: i32, width: i32) {
	b0 := arena[off]
	if b0 & 0x80 == 0 {
		return i32(b0), 1
	}
	if b0 & 0xE0 == 0xC0 {
		b1 := arena[off + 1]
		return (i32(b0 & 0x1F) << 6) | i32(b1 & 0x3F), 2
	}
	if b0 & 0xF0 == 0xE0 {
		b1, b2 := arena[off + 1], arena[off + 2]
		return (i32(b0 & 0x0F) << 12) | (i32(b1 & 0x3F) << 6) | i32(b2 & 0x3F), 3
	}
	// 4-байтный случай (ведущий байт 0xF0-паттерн) — тот же "best effort"
	// допуск для невалидного входа, что был бы у core:unicode/utf8's
	// decode_rune_in_string на этом масштабе фикстур, не полноценный
	// UTF-8-валидатор.
	b1, b2, b3 := arena[off + 1], arena[off + 2], arena[off + 3]
	return (i32(b0 & 0x07) << 18) | (i32(b1 & 0x3F) << 12) | (i32(b2 & 0x3F) << 6) | i32(b3 & 0x3F), 4
}

@(private)
utf8_encode_at :: proc "contextless" (off: i32, cp: i32) -> i32 {
	if cp < 0x80 {
		arena[off] = u8(cp)
		return 1
	}
	if cp < 0x800 {
		arena[off] = u8(0xC0 | (cp >> 6))
		arena[off + 1] = u8(0x80 | (cp & 0x3F))
		return 2
	}
	if cp < 0x10000 {
		arena[off] = u8(0xE0 | (cp >> 12))
		arena[off + 1] = u8(0x80 | ((cp >> 6) & 0x3F))
		arena[off + 2] = u8(0x80 | (cp & 0x3F))
		return 3
	}
	arena[off] = u8(0xF0 | (cp >> 18))
	arena[off + 1] = u8(0x80 | ((cp >> 12) & 0x3F))
	arena[off + 2] = u8(0x80 | ((cp >> 6) & 0x3F))
	arena[off + 3] = u8(0x80 | (cp & 0x3F))
	return 4
}

@(export)
pw_string_length_runes :: proc "contextless" (handle: i32) -> i32 {
	off, length := obj_offsets[handle], obj_sizes[handle]
	count: i32 = 0
	i: i32 = 0
	for i < length {
		_, width := utf8_decode_at(off + i)
		i += width
		count += 1
	}
	return count
}

// pw_string_slice_rune — строки::срез. Тот же обход, что core/utils.
// odin's string_slice_by_rune (проверка idx==start/end ДО декода текущей
// руны, ширина известна только ПОСЛЕ декода).
@(export)
pw_string_slice_rune :: proc "contextless" (handle: i32, start: i32, end: i32) -> i32 {
	if start < 0 || end < start do intrinsics.trap()
	off, length := obj_offsets[handle], obj_sizes[handle]
	start_byte: i32 = -1
	end_byte := length
	idx: i32 = 0
	i: i32 = 0
	for i < length {
		if idx == start do start_byte = i
		if idx == end do end_byte = i
		_, width := utf8_decode_at(off + i)
		i += width
		idx += 1
	}
	if end > idx do intrinsics.trap()
	if start_byte == -1 {
		if start != idx do intrinsics.trap()
		start_byte = length
	}
	slice_len := end_byte - start_byte
	if next_free + slice_len > ARENA_SIZE || obj_count >= MAX_OBJECTS do intrinsics.trap()
	dst_off := next_free
	for j in i32(0) ..< slice_len {
		arena[dst_off + j] = arena[off + start_byte + j]
	}
	next_free += slice_len
	id := obj_count
	obj_offsets[id] = dst_off
	obj_sizes[id] = slice_len
	obj_capacity[id] = slice_len
	obj_count += 1
	return id
}

// pw_string_find_rune — строки::найти. Тот же двухфазный приём, что
// core/utils.odin's string_find_rune: найти байтовую позицию from_rune,
// байтовый линейный поиск оттуда, перевести найденную байтовую позицию
// ОБРАТНО в рунный индекс.
@(export)
pw_string_find_rune :: proc "contextless" (handle: i32, pattern: i32, from_rune: i32) -> i32 {
	off, length := obj_offsets[handle], obj_sizes[handle]
	p_off, p_len := obj_offsets[pattern], obj_sizes[pattern]

	total: i32 = 0
	i: i32 = 0
	for i < length {
		_, width := utf8_decode_at(off + i)
		i += width
		total += 1
	}
	if from_rune < 0 || from_rune > total do return -1

	start_byte := length
	idx: i32 = 0
	i = 0
	for i < length {
		if idx == from_rune {
			start_byte = i
			break
		}
		_, width := utf8_decode_at(off + i)
		i += width
		idx += 1
	}

	match_byte: i32 = -1
	search_i := start_byte
	for search_i <= length - p_len {
		matched := true
		for j in i32(0) ..< p_len {
			if arena[off + search_i + j] != arena[p_off + j] {
				matched = false
				break
			}
		}
		if matched {
			match_byte = search_i
			break
		}
		search_i += 1
	}
	if match_byte == -1 do return -1

	rune_idx: i32 = 0
	i = 0
	for i < length {
		if i == match_byte do return rune_idx
		_, width := utf8_decode_at(off + i)
		i += width
		rune_idx += 1
	}
	return -1
}

@(export)
pw_string_byte_at :: proc "contextless" (handle: i32, idx: i32) -> i32 {
	if idx < 0 || idx >= obj_sizes[handle] do intrinsics.trap()
	return i32(arena[obj_offsets[handle] + idx])
}

@(export)
pw_string_slice_byte :: proc "contextless" (handle: i32, start: i32, end: i32) -> i32 {
	if start < 0 || start > end || end > obj_sizes[handle] do intrinsics.trap()
	length := end - start
	if next_free + length > ARENA_SIZE || obj_count >= MAX_OBJECTS do intrinsics.trap()
	src_off := obj_offsets[handle] + start
	off := next_free
	for i in i32(0) ..< length {
		arena[off + i] = arena[src_off + i]
	}
	next_free += length
	id := obj_count
	obj_offsets[id] = off
	obj_sizes[id] = length
	obj_capacity[id] = length
	obj_count += 1
	return id
}

// pw_string_from_bytes/pw_string_to_bytes — байт-значения хранятся как
// Целое (Массив(Целое), см. core/stdlib.odin), т.е. f64-слоты в этом
// бэкенде (Фаза 1: Число/Целое не различаются рантайм-представлением) —
// НЕ i32-слоты, несмотря на то что байт логически 0-255.
@(export)
pw_string_from_bytes :: proc "contextless" (array_handle: i32) -> i32 {
	count := obj_sizes[array_handle] / FIELD_SIZE
	if next_free + count > ARENA_SIZE || obj_count >= MAX_OBJECTS do intrinsics.trap()
	off := next_free
	src_off := obj_offsets[array_handle]
	for i in i32(0) ..< count {
		bits := unpack_u64_le(src_off + i * FIELD_SIZE)
		v := i32(transmute(f64)bits)
		if v < 0 || v > 255 do intrinsics.trap()
		arena[off + i] = u8(v)
	}
	next_free += count
	id := obj_count
	obj_offsets[id] = off
	obj_sizes[id] = count
	obj_capacity[id] = count
	obj_count += 1
	return id
}

@(export)
pw_string_to_bytes :: proc "contextless" (handle: i32) -> i32 {
	off, length := obj_offsets[handle], obj_sizes[handle]
	size := length * FIELD_SIZE
	if next_free + size > ARENA_SIZE || obj_count >= MAX_OBJECTS do intrinsics.trap()
	dst_off := next_free
	for i in i32(0) ..< length {
		pack_u64_le(dst_off + i * FIELD_SIZE, transmute(u64)f64(arena[off + i]))
	}
	next_free += size
	id := obj_count
	obj_offsets[id] = dst_off
	obj_sizes[id] = size
	obj_capacity[id] = size
	obj_count += 1
	return id
}

@(export)
pw_string_codepoint_at_start :: proc "contextless" (handle: i32) -> i32 {
	if obj_sizes[handle] == 0 do return 0
	cp, _ := utf8_decode_at(obj_offsets[handle])
	return cp
}

@(export)
pw_string_to_runes :: proc "contextless" (handle: i32) -> i32 {
	off, length := obj_offsets[handle], obj_sizes[handle]
	count: i32 = 0
	i: i32 = 0
	for i < length {
		_, width := utf8_decode_at(off + i)
		i += width
		count += 1
	}
	size := count * FIELD_SIZE
	if next_free + size > ARENA_SIZE || obj_count >= MAX_OBJECTS do intrinsics.trap()
	dst_off := next_free
	i = 0
	slot: i32 = 0
	for i < length {
		cp, width := utf8_decode_at(off + i)
		pack_u64_le(dst_off + slot * FIELD_SIZE, transmute(u64)f64(cp))
		i += width
		slot += 1
	}
	next_free += size
	id := obj_count
	obj_offsets[id] = dst_off
	obj_sizes[id] = size
	obj_capacity[id] = size
	obj_count += 1
	return id
}

// pw_string_from_runes — размер результата в байтах неизвестен ДО
// кодирования (1-4 байта на codepoint) — резервируем МАКСИМУМ (4*count),
// используем реально записанное (write_pos) как obj_sizes — obj_capacity
// остаётся БОЛЬШЕ obj_sizes, тот же, уже принятый в Фазе 2.7 принцип
// (capacity >= size, не строго равны), лишний хвост арены просто не
// используется (не мусор в смысле "неверные данные", просто резерв).
@(export)
pw_string_from_runes :: proc "contextless" (array_handle: i32) -> i32 {
	count := obj_sizes[array_handle] / FIELD_SIZE
	src_off := obj_offsets[array_handle]
	max_size := count * 4
	if next_free + max_size > ARENA_SIZE || obj_count >= MAX_OBJECTS do intrinsics.trap()
	off := next_free
	write_pos: i32 = 0
	for i in i32(0) ..< count {
		bits := unpack_u64_le(src_off + i * FIELD_SIZE)
		cp := i32(transmute(f64)bits)
		width := utf8_encode_at(off + write_pos, cp)
		write_pos += width
	}
	next_free += max_size
	id := obj_count
	obj_offsets[id] = off
	obj_sizes[id] = write_pos
	obj_capacity[id] = max_size
	obj_count += 1
	return id
}

// pw_string_char_at — text[i] (Get_Index_Instr на Строка) — одна руна
// как собственная 1-4-байтная подстрока, тот же обход, что core/utils.
// odin's get_character_at.
@(export)
pw_string_char_at :: proc "contextless" (handle: i32, rune_idx: i32) -> i32 {
	if rune_idx < 0 do intrinsics.trap()
	off, length := obj_offsets[handle], obj_sizes[handle]
	idx: i32 = 0
	i: i32 = 0
	for i < length {
		if idx == rune_idx {
			_, width := utf8_decode_at(off + i)
			if next_free + width > ARENA_SIZE || obj_count >= MAX_OBJECTS do intrinsics.trap()
			dst_off := next_free
			for j in i32(0) ..< width {
				arena[dst_off + j] = arena[off + i + j]
			}
			next_free += width
			id := obj_count
			obj_offsets[id] = dst_off
			obj_sizes[id] = width
			obj_capacity[id] = width
			obj_count += 1
			return id
		}
		_, width := utf8_decode_at(off + i)
		i += width
		idx += 1
	}
	intrinsics.trap()
}

// --- Фаза 2.9: Unicode-классификация/регистр -----------------------------
//
// core:unicode's is_digit/is_letter(=is_alpha)/to_upper/to_lower — чистые
// табличные функции (binary_search по статическим сгенерированным
// range-таблицам, core/unicode/letter.odin) — БЕЗ аллокаций/IO, ничего из
// того, что заблокировало переиспользование core/gc.odin в Фазе 1.5
// (core:dynlib/core:terminal). Единственное трение: обычная (не
// "contextless") calling convention Odin всегда протаскивает context
// параметром структурно, даже для функций, ему не пользующихся —
// "contextless"-вызывающему (весь этот пакет) нечего передать без
// явного `context = runtime.default_context()` (ошибка компиляции без
// этой строки, предложенный САМИМ Odin фикс) — проверено СПАЙКОМ ДО
// вживления (реальный wasi_wasm32-билд + wasmtime run, включая
// кириллический to_upper('п')=='П'), не просто "должно скомпилироваться".
// НИКАКИХ собственных Unicode-таблиц не нужно — намного меньший риск,
// чем изначально предполагалось при выборе этого направления.
//
// unicode.is_digit/is_alpha(=is_letter) идут через in_range() по глобалам
// вроде ll_ranges/lu_ranges/nd_ranges (core/unicode/generated.odin) —
// это Range{ranges_16 = ll_ranges16[:], ...}, ЗНАЧЕНИЕ ЧЬИХ ПОЛЕЙ
// вычисляется срезом ДРУГОГО глобала — Odin эмитит это как код в
// компилятором сгенерированном __$startup_runtime (см. base:runtime/
// entry_wasm.odin — обычно вызывается из _start ДО main), а не как
// статические данные. Наш модуль собран с -no-entry-point и вызывается
// напрямую по имени экспорта (без _start) — __$startup_runtime НИКОГДА
// не выполняется, так что эти Range-глобалы остаются нулевыми
// (нил-слайсы) и in_range всегда возвращает false. НЕ баг в
// core:unicode — плата за -no-entry-point/reactor-стиль сборки; сам
// пакет unicode's doc.odin прямо предупреждает об этом ("если не
// используется обычная точка входа, _startup_runtime нужно вызвать
// самостоятельно"). to_upper/to_lower НЕ задеты той же проблемой —
// их range-таблицы (to_upper_ranges/to_lower_ranges) объявлены как
// плоские массивы-литералы и срезаются `[:]` ПРЯМО В МЕСТЕ ВЫЗОВА
// (константные данные линкуются напрямую в data-секцию, без кода
// инициализации) — подтверждено спайком до фикса (to_upper('п') уже
// работал БЕЗ этого вызова, is_alpha('п') — нет, тем же спайком).
@(private)
unicode_runtime_initialized: bool

@(private)
ensure_unicode_runtime :: proc "contextless" () {
	if unicode_runtime_initialized do return
	context = runtime.default_context()
	runtime._startup_runtime()
	unicode_runtime_initialized = true
}

@(export)
pw_string_is_digit :: proc "contextless" (handle: i32) -> i32 {
	ensure_unicode_runtime()
	context = runtime.default_context()
	if obj_sizes[handle] == 0 do return 0
	cp, _ := utf8_decode_at(obj_offsets[handle])
	return unicode.is_digit(rune(cp)) ? 1 : 0
}

@(export)
pw_string_is_alpha :: proc "contextless" (handle: i32) -> i32 {
	ensure_unicode_runtime()
	context = runtime.default_context()
	if obj_sizes[handle] == 0 do return 0
	cp, _ := utf8_decode_at(obj_offsets[handle])
	return unicode.is_alpha(rune(cp)) ? 1 : 0
}

@(export)
pw_string_is_digit_or_alpha :: proc "contextless" (handle: i32) -> i32 {
	ensure_unicode_runtime()
	context = runtime.default_context()
	if obj_sizes[handle] == 0 do return 0
	cp, _ := utf8_decode_at(obj_offsets[handle])
	r := rune(cp)
	return (unicode.is_digit(r) || unicode.is_alpha(r)) ? 1 : 0
}

// pw_string_to_upper/pw_string_to_lower — итоговая длина в байтах не
// известна ДО кодирования (регистр может поменять UTF-8-ширину руны) —
// резервируем МАКСИМУМ (4*rune_count), obj_sizes — реально записанное,
// obj_capacity остаётся БОЛЬШЕ — тот же приём, что pw_string_from_runes
// (Фаза 2.8), не новая техника.
@(export)
pw_string_to_upper :: proc "contextless" (handle: i32) -> i32 {
	context = runtime.default_context()
	off, length := obj_offsets[handle], obj_sizes[handle]
	max_size := length * 4
	if next_free + max_size > ARENA_SIZE || obj_count >= MAX_OBJECTS do intrinsics.trap()
	dst_off := next_free
	write_pos: i32 = 0
	i: i32 = 0
	for i < length {
		cp, width := utf8_decode_at(off + i)
		upper := unicode.to_upper(rune(cp))
		write_pos += utf8_encode_at(dst_off + write_pos, i32(upper))
		i += width
	}
	next_free += max_size
	id := obj_count
	obj_offsets[id] = dst_off
	obj_sizes[id] = write_pos
	obj_capacity[id] = max_size
	obj_count += 1
	return id
}

@(export)
pw_string_to_lower :: proc "contextless" (handle: i32) -> i32 {
	context = runtime.default_context()
	off, length := obj_offsets[handle], obj_sizes[handle]
	max_size := length * 4
	if next_free + max_size > ARENA_SIZE || obj_count >= MAX_OBJECTS do intrinsics.trap()
	dst_off := next_free
	write_pos: i32 = 0
	i: i32 = 0
	for i < length {
		cp, width := utf8_decode_at(off + i)
		lower := unicode.to_lower(rune(cp))
		write_pos += utf8_encode_at(dst_off + write_pos, i32(lower))
		i += width
	}
	next_free += max_size
	id := obj_count
	obj_offsets[id] = dst_off
	obj_sizes[id] = write_pos
	obj_capacity[id] = max_size
	obj_count += 1
	return id
}

// --- Фаза 2.10: строки::в_число / из_числа ------------------------------
//
// core:strconv's generic_ftoa/parse_f64 переиспользуются напрямую, тем же
// приёмом, что core:unicode в Фазе 2.9 (`context = runtime.default_
// context()`, единственное трение) — проверено СПАЙКОМ ДО вживления,
// включая round-trip через реальный wasi_wasm32-билд + wasmtime run.
// В ОТЛИЧИЕ от Фазы 2.9, __$startup_runtime здесь НЕ нужен: единственная
// package-level таблица core:strconv/decimal (_shift_left_offsets) —
// плоский массив-литерал (та же безопасная категория, что to_lower_ranges
// у core:unicode, не Range{ranges_16 = other[:], ...} с вычисляемым
// полем-срезом) — подтверждено спайком, не только чтением исходников.

@(private)
alloc_arena_string :: proc "contextless" (s: string) -> i32 {
	length := i32(len(s))
	if next_free + length > ARENA_SIZE || obj_count >= MAX_OBJECTS do return -1
	off := next_free
	for i in i32(0) ..< length {
		arena[off + i] = s[i]
	}
	next_free += length

	id := obj_count
	obj_offsets[id] = off
	obj_sizes[id] = length
	obj_capacity[id] = length
	obj_count += 1
	return id
}

// pw_number_to_string — зеркалит core/vm.odin's format_number 1:1:
// generic_ftoa(fmt='f', precision=-1) даёт кратчайшее round-trip
// фиксированно-точечное представление БЕЗ экспоненты (обходит живой баг,
// который core/vm.odin:1002 комментирует), затем срезаем ведущий '+'
// (generic_ftoa всегда его печатает для неотрицательных).
@(export)
pw_number_to_string :: proc "contextless" (value: f64) -> i32 {
	context = runtime.default_context()
	buf: [400]byte
	formatted := strconv.generic_ftoa(buf[:], value, 'f', -1, 64)
	text := string(formatted)
	if len(text) > 0 && text[0] == '+' {
		text = text[1:]
	}
	return alloc_arena_string(text)
}

// pw_string_to_number — Результат(Число,Ошибка) строится вручную (тег-
// порядок Успех=0/Неудача=1 зафиксирован в core/prelude.odin:11), тем же
// pw_build_variant/pw_set_field_*, что MIR-видимый Build_Variant_Instr
// использует (core/wasm_emit.odin) — вызываются напрямую как обычные
// Odin-процедуры того же пакета, не через wasm-таблицу импортов (@(export)
// лишь ДОБАВЛЯЕТ экспорт, не мешает прямому вызову изнутри пакета).
// Ошибка{код,сообщение} — не MIR-конструируемый тип (в этой кодовой базе
// НЕТ ни одного вызова конструктора `Ошибка(...)` из panos-исходников,
// он только native-side в core/vm.odin's make_error_value) — собирается
// здесь целиком вручную, без участия wasm_emit.odin.
@(export)
pw_string_to_number :: proc "contextless" (handle: i32) -> i32 {
	context = runtime.default_context()
	off, length := obj_offsets[handle], obj_sizes[handle]
	text := string(arena[off:off + length])
	num, ok := strconv.parse_f64(text)
	if ok {
		result := pw_build_variant(0, 1)
		pw_set_field_f64(result, 0, num)
		return result
	}

	prefix := "'"
	suffix := "' не является числом"
	msg_len := i32(len(prefix)) + length + i32(len(suffix))
	if next_free + msg_len > ARENA_SIZE || obj_count >= MAX_OBJECTS do intrinsics.trap()
	msg_off := next_free
	pos: i32 = 0
	for i in 0 ..< len(prefix) {
		arena[msg_off + pos] = prefix[i]
		pos += 1
	}
	for i in i32(0) ..< length {
		arena[msg_off + pos] = arena[off + i]
		pos += 1
	}
	for i in 0 ..< len(suffix) {
		arena[msg_off + pos] = suffix[i]
		pos += 1
	}
	next_free += msg_len
	msg_id := obj_count
	obj_offsets[msg_id] = msg_off
	obj_sizes[msg_id] = msg_len
	obj_capacity[msg_id] = msg_len
	obj_count += 1

	code_id := alloc_arena_string("строки")
	err := pw_alloc_aggregate(2)
	pw_set_field_i32(err, 0, code_id)
	pw_set_field_i32(err, 1, msg_id)

	result := pw_build_variant(1, 1)
	pw_set_field_i32(result, 0, err)
	return result
}

// --- Фаза 2.11: строки::разбить / соединить / обрезать -------------------

@(private)
alloc_arena_range :: proc "contextless" (src_off: i32, length: i32) -> i32 {
	if next_free + length > ARENA_SIZE || obj_count >= MAX_OBJECTS || length < 0 {
		return -1
	}
	off := next_free
	for i in i32(0) ..< length {
		arena[off + i] = arena[src_off + i]
	}
	next_free += length

	id := obj_count
	obj_offsets[id] = off
	obj_sizes[id] = length
	obj_capacity[id] = length
	obj_count += 1
	return id
}

// pw_string_trim — строки::обрезать (strings.trim_space = unicode.is_space
// с обеих сторон). ОДИН проход вперёд (utf8_decode_at, Фаза 2.8) вместо
// раздельных trim_left/trim_right: start_byte фиксируется на первой не-
// пробельной руне, end_byte двигается на каждой не-пробельной руне —
// после прохода готовы обе границы, обратное UTF-8-декодирование не
// нужно. unicode.is_space's нелатинская ветка идёт через space_ranges[:]
// (core/unicode/tables.odin:469) — плоский массив-литерал, срезаемый
// прямо на месте вызова, та же безопасная категория, что to_lower_ranges
// у core:unicode (Фаза 2.9's диагностика) — __$startup_runtime не нужен.
@(export)
pw_string_trim :: proc "contextless" (handle: i32) -> i32 {
	context = runtime.default_context()
	off, length := obj_offsets[handle], obj_sizes[handle]
	start_byte: i32 = -1
	end_byte: i32 = 0
	i: i32 = 0
	for i < length {
		cp, width := utf8_decode_at(off + i)
		if !unicode.is_space(rune(cp)) {
			if start_byte == -1 do start_byte = i
			end_byte = i + width
		}
		i += width
	}
	if start_byte == -1 do return alloc_arena_range(off, 0)
	return alloc_arena_range(off + start_byte, end_byte - start_byte)
}

// pw_string_split — строки::разбить. Массив строится через
// pw_alloc_aggregate (та же арена-раскладка, что New_Array_Instr, Фаза
// 2.1), слоты — i32-хендлы (Строка на этом бэкенде всегда i32).
// core:strings.split's РАЗВИЛКА (core/strings/strings.odin:822-837,
// проверено чтением исходника, не по памяти): пустой sep разбивает на
// ОТДЕЛЬНЫЕ РУНЫ, непустой — байтовый substring-поиск, count(s,sep)+1
// сегментов. Substring-скан — та же схема, что уже проверенные
// pw_string_contains/pw_string_replace_all (не новый алгоритм).
@(export)
pw_string_split :: proc "contextless" (text: i32, sep: i32) -> i32 {
	context = runtime.default_context()
	t_off, t_len := obj_offsets[text], obj_sizes[text]
	s_off, s_len := obj_offsets[sep], obj_sizes[sep]

	matches_at :: proc "contextless" (t_off, i, s_off, s_len: i32) -> bool {
		for j in i32(0) ..< s_len {
			if arena[t_off + i + j] != arena[s_off + j] do return false
		}
		return true
	}

	if s_len == 0 {
		count: i32 = 0
		i: i32 = 0
		for i < t_len {
			_, width := utf8_decode_at(t_off + i)
			i += width
			count += 1
		}
		arr := pw_alloc_aggregate(count)
		idx: i32 = 0
		i = 0
		for i < t_len {
			_, width := utf8_decode_at(t_off + i)
			seg := alloc_arena_range(t_off + i, width)
			pw_set_field_i32(arr, idx, seg)
			i += width
			idx += 1
		}
		return arr
	}

	match_count: i32 = 0
	i := i32(0)
	for i <= t_len - s_len {
		if matches_at(t_off, i, s_off, s_len) {
			match_count += 1
			i += s_len
		} else {
			i += 1
		}
	}

	arr := pw_alloc_aggregate(match_count + 1)
	idx: i32 = 0
	seg_start := i32(0)
	i = 0
	for i <= t_len - s_len {
		if matches_at(t_off, i, s_off, s_len) {
			seg := alloc_arena_range(t_off + seg_start, i - seg_start)
			pw_set_field_i32(arr, idx, seg)
			idx += 1
			i += s_len
			seg_start = i
		} else {
			i += 1
		}
	}
	last_seg := alloc_arena_range(t_off + seg_start, t_len - seg_start)
	pw_set_field_i32(arr, idx, last_seg)
	return arr
}

// pw_string_join — строки::соединить. Длина результата известна ПОСЛЕ
// первого прохода (сумма длин элементов + разделитель между ними) —
// одна аллокация, второй проход пишет байты напрямую, БЕЗ повторных
// pw_concat_strings-вызовов (та же дисциплина, что построение сообщения
// об ошибке в Фазе 2.10). Массив читается тем же obj_sizes[handle]/
// FIELD_SIZE-соглашением, что любой другой Массив-builtin.
@(export)
pw_string_join :: proc "contextless" (arr: i32, sep: i32) -> i32 {
	context = runtime.default_context()
	count := obj_sizes[arr] / FIELD_SIZE
	s_off, s_len := obj_offsets[sep], obj_sizes[sep]

	total: i32 = 0
	for i in i32(0) ..< count {
		el := pw_get_field_i32(arr, i)
		total += obj_sizes[el]
	}
	if count > 1 do total += s_len * (count - 1)

	if next_free + total > ARENA_SIZE || obj_count >= MAX_OBJECTS {
		return -1
	}
	off := next_free
	write_pos := off
	for i in i32(0) ..< count {
		el := pw_get_field_i32(arr, i)
		el_off, el_len := obj_offsets[el], obj_sizes[el]
		for j in i32(0) ..< el_len {
			arena[write_pos] = arena[el_off + j]
			write_pos += 1
		}
		if i < count - 1 {
			for j in i32(0) ..< s_len {
				arena[write_pos] = arena[s_off + j]
				write_pos += 1
			}
		}
	}
	next_free += total

	id := obj_count
	obj_offsets[id] = off
	obj_sizes[id] = total
	obj_capacity[id] = total
	obj_count += 1
	return id
}

// pw_map_entries — Соответствие.записи() -> Массив((Ключ, Значение)).
// Чистый бит-копи: карта хранит записи как плоские 2*FIELD_SIZE-байтные
// пары (ключ-слот, значение-слот, Фаза 2.4), а 2-элементный тупл — ТОТ ЖЕ
// pw_alloc_aggregate(2)-layout — ключ/значение НЕ нужно интерпретировать
// (в отличие от получить/есть, которым нужно расщепление strkey/numkey и
// i32/f64) — просто переносим 8 сырых байт на слот.
@(export)
pw_map_entries :: proc "contextless" (handle: i32) -> i32 {
	count := obj_sizes[handle] / (2 * FIELD_SIZE)
	base := obj_offsets[handle]
	arr := pw_alloc_aggregate(count)
	for i in i32(0) ..< count {
		pair := pw_alloc_aggregate(2)
		key_bits := unpack_u64_le(base + i * 2 * FIELD_SIZE)
		val_bits := unpack_u64_le(base + i * 2 * FIELD_SIZE + FIELD_SIZE)
		pack_u64_le(obj_offsets[pair], key_bits)
		pack_u64_le(obj_offsets[pair] + FIELD_SIZE, val_bits)
		pw_set_field_i32(arr, i, pair)
	}
	return arr
}
