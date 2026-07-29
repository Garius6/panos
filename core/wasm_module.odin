package core

import "core:fmt"

// wasm_module.odin — сборка итогового .wasm-модуля (Фаза 1, "walking
// skeleton" WASM AOT-бэкенда). LEB128/секционные помощники + entry point
// lower_module_to_wasm. Инструкции самих функций эмитит wasm_emit.odin
// (через process_from, core/wasm_emit.odin) — этот файл только упаковывает
// готовые байты тел в секции согласно бинарному формату WASM (порядок
// секций СТРОГО по числовому id: Type(1) < Function(3) < Table(4) <
// Export(7) < Element(9) < Code(10), см. спецификацию).
//
// Функция i модуля получает typeidx=i, table-slot=i — тот же индекс во
// ВСЕХ трёх пространствах (простейшее однозначное соответствие, не
// экономит место в typesection на дублирующихся сигнатурах, но не требует
// отдельной de-dup таблицы — оправдано для Фазы 1).

write_uleb128 :: proc(buf: ^[dynamic]u8, value: u64) {
	v := value
	for {
		b := u8(v & 0x7F)
		v >>= 7
		if v != 0 {
			append(buf, b | 0x80)
		} else {
			append(buf, b)
			break
		}
	}
}

write_sleb128 :: proc(buf: ^[dynamic]u8, value: i64) {
	v := value
	more := true
	for more {
		b := u8(v & 0x7F)
		v >>= 7 // арифметический (знаковый) сдвиг у Odin на i64 — то, что нужно SLEB128
		if (v == 0 && (b & 0x40) == 0) || (v == -1 && (b & 0x40) != 0) {
			more = false
		} else {
			b |= 0x80
		}
		append(buf, b)
	}
}

write_f64_le :: proc(buf: ^[dynamic]u8, value: f64) {
	bits := transmute(u64)value
	for i in 0 ..< 8 {
		append(buf, u8(bits >> uint(i * 8)))
	}
}

WASM_I32 :: 0x7F
WASM_F64 :: 0x7C

// wasm_val_type — тип значения в WASM для статического типа panos-Value_Id
// (Фаза 1: Число/Целое -> f64, Булево -> i32; Фаза 1.5: Строка/структура
// ТОЖЕ i32 — handle в wasm_runtime's таблице объектов (см. wasm_runtime/
// runtime.odin), не сырой указатель; Фаза 2.1: Массив/перечисление
// (включая Опция/Результат прелюдии) — та же handle-репрезентация,
// см. obj_tags в wasm_runtime/runtime.odin для перечислений).
wasm_val_type :: proc(t: ^Type) -> u8 {
	if t == nil {
		panic("wasm backend: nil-тип (нерезолвленный generic-параметр?) дошёл до эмиссии — is_wasm_phase1_function должен был это отсечь")
	}
	pt := prune_type(t)
	#partial switch pt.kind {
	case .Number, .Integer:
		return WASM_F64
	case .Bool, .String, .Struct, .Array, .Enum, .Map, .Error, .Tuple:
		return WASM_I32
	case:
		panic(
			fmt.tprintf(
				"wasm backend Фаза 2.1: тип %v не поддержан (нет interface/generics/Соответствие/closures/actors в этой фазе)",
				pt.kind,
			),
		)
	}
}

// is_wasm_phase1_type — как wasm_val_type, но БЕЗ паники (проверка, а не
// конвертация) — Пусто тоже допустим (возврат без значения). nil — тоже
// "не в области" (не паника): найдено реальным крашем — до появления
// .Enum в списке ниже, какая-то прелюдийная локаль с ЕЩЁ nil-типом (не
// зарезолвленным generic-параметром) никогда не достигалась, потому что
// is_wasm_phase1_function рано выходил на .Enum-локали ПЕРЕД ней; теперь
// когда .Enum разрешён, обход доходит и до неё.
@(private = "file")
is_wasm_phase1_type :: proc(t: ^Type) -> bool {
	if t == nil do return false
	#partial switch prune_type(t).kind {
	case .Number, .Integer, .Bool, .Void, .String, .Struct, .Array, .Enum, .Map, .Error, .Tuple:
		return true
	case:
		return false
	}
}

// is_wasm_phase1_function — lower_module лоурит ВСЕ функции программы,
// включая прелюдию (Опция/Результат — @prelude::*, см. core/prelude.odin) —
// они используют Enum/InferVar и вне области Фазы 1 независимо от того,
// использует ли их конкретная тестовая программа. Функция включается в
// wasm-модуль, только если ЕЁ СОБСТВЕННАЯ сигнатура+локали не выходят за
// рамки Фазы 1 — остальные просто не эмитятся (не вызываются фикстурами
// Фазы 1 по построению, см. план).
@(private = "file")
is_wasm_phase1_function :: proc(mfn: ^Mir_Function) -> bool {
	if !is_wasm_phase1_type(mfn.result_type) do return false
	for l in mfn.locals {
		if !is_wasm_phase1_type(l.type) do return false
	}
	return true
}

// wasm_runtime import-контракт (см. wasm_runtime/runtime.odin) — module
// name "env" (совпадает с ключом --preload в тестах, core/wasm_backend_
// wasmtime_test.odin) + фиксированный порядок функций, задающий
// typeidx/funcidx 0..PW_IMPORT_COUNT-1 (импорты ВСЕГДА занимают младшие
// индексы функционального пространства WASM, до любых локально
// определённых функций, см. спецификацию).
PW_IMPORT_MODULE :: "env"

Pw_Import :: struct {
	name:    string,
	params:  []u8,
	results: []u8,
}

PW_SCRATCH_SET :: 0
PW_ALLOC_FROM_SCRATCH :: 1
PW_STRING_LEN :: 2
PW_CONCAT_STRINGS :: 3
PW_STRING_EQUAL :: 4
PW_ALLOC_AGGREGATE :: 5
PW_SET_FIELD_F64 :: 6
PW_GET_FIELD_F64 :: 7
PW_SET_FIELD_I32 :: 8
PW_GET_FIELD_I32 :: 9
PW_PRINT_STRING :: 10
PW_STRING_STARTS_WITH :: 11
PW_STRING_ENDS_WITH :: 12
PW_STRING_CONTAINS :: 13
PW_INT_TO_STRING :: 14
PW_STRING_COMPARE :: 15
PW_STRING_REPLACE_ALL :: 16
PW_MONOTONIC_MS :: 17
PW_NOW_MS :: 18
PW_BUILD_VARIANT :: 19
PW_MATCH_TAG :: 20
PW_ARRAY_LENGTH :: 21
PW_ARRAY_IN_BOUNDS :: 22
PW_ARRAY_GET_F64 :: 23
PW_ARRAY_GET_I32 :: 24
PW_ARRAY_CONTAINS_F64 :: 25
PW_ARRAY_CONTAINS_I32 :: 26
PW_ARRAY_SLICE :: 27
PW_MAP_LENGTH :: 28
PW_MAP_HAS_STRKEY :: 29
PW_MAP_HAS_NUMKEY :: 30
PW_MAP_GET_STRKEY_F64 :: 31
PW_MAP_GET_STRKEY_I32 :: 32
PW_MAP_GET_NUMKEY_F64 :: 33
PW_MAP_GET_NUMKEY_I32 :: 34
PW_MAP_DELETE_STRKEY :: 35
PW_MAP_DELETE_NUMKEY :: 36
PW_ARRAY_PUSH_F64 :: 37
PW_ARRAY_PUSH_I32 :: 38
PW_MAP_SET_STRKEY_F64 :: 39
PW_MAP_SET_STRKEY_I32 :: 40
PW_MAP_SET_NUMKEY_F64 :: 41
PW_MAP_SET_NUMKEY_I32 :: 42
PW_STRING_LENGTH_RUNES :: 43
PW_STRING_SLICE_RUNE :: 44
PW_STRING_FIND_RUNE :: 45
PW_STRING_BYTE_AT :: 46
PW_STRING_SLICE_BYTE :: 47
PW_STRING_FROM_BYTES :: 48
PW_STRING_TO_BYTES :: 49
PW_STRING_CODEPOINT_AT_START :: 50
PW_STRING_TO_RUNES :: 51
PW_STRING_FROM_RUNES :: 52
PW_STRING_CHAR_AT :: 53
PW_STRING_IS_DIGIT :: 54
PW_STRING_IS_ALPHA :: 55
PW_STRING_IS_DIGIT_OR_ALPHA :: 56
PW_STRING_TO_UPPER :: 57
PW_STRING_TO_LOWER :: 58
PW_NUMBER_TO_STRING :: 59
PW_STRING_TO_NUMBER :: 60
PW_STRING_TRIM :: 61
PW_STRING_SPLIT :: 62
PW_STRING_JOIN :: 63
PW_MAP_ENTRIES :: 64
PW_PRINTLN_STRING :: 65
PW_IMPORT_COUNT :: 66

@(private = "file")
pw_imports := [PW_IMPORT_COUNT]Pw_Import {
	{"pw_scratch_set", {WASM_I32, WASM_I32}, {}},
	{"pw_alloc_from_scratch", {WASM_I32}, {WASM_I32}},
	{"pw_string_len", {WASM_I32}, {WASM_I32}},
	{"pw_concat_strings", {WASM_I32, WASM_I32}, {WASM_I32}},
	{"pw_string_equal", {WASM_I32, WASM_I32}, {WASM_I32}},
	{"pw_alloc_aggregate", {WASM_I32}, {WASM_I32}},
	{"pw_set_field_f64", {WASM_I32, WASM_I32, WASM_F64}, {}},
	{"pw_get_field_f64", {WASM_I32, WASM_I32}, {WASM_F64}},
	{"pw_set_field_i32", {WASM_I32, WASM_I32, WASM_I32}, {}},
	{"pw_get_field_i32", {WASM_I32, WASM_I32}, {WASM_I32}},
	{"pw_print_string", {WASM_I32}, {}},
	{"pw_string_starts_with", {WASM_I32, WASM_I32}, {WASM_I32}},
	{"pw_string_ends_with", {WASM_I32, WASM_I32}, {WASM_I32}},
	{"pw_string_contains", {WASM_I32, WASM_I32}, {WASM_I32}},
	{"pw_int_to_string", {WASM_F64}, {WASM_I32}},
	{"pw_string_compare", {WASM_I32, WASM_I32}, {WASM_F64}},
	{"pw_string_replace_all", {WASM_I32, WASM_I32, WASM_I32}, {WASM_I32}},
	{"pw_monotonic_ms", {}, {WASM_F64}},
	{"pw_now_ms", {}, {WASM_F64}},
	{"pw_build_variant", {WASM_I32, WASM_I32}, {WASM_I32}},
	{"pw_match_tag", {WASM_I32, WASM_I32}, {WASM_I32}},
	{"pw_array_length", {WASM_I32}, {WASM_I32}},
	{"pw_array_in_bounds", {WASM_I32, WASM_I32}, {WASM_I32}},
	{"pw_array_get_f64", {WASM_I32, WASM_I32, WASM_F64}, {WASM_F64}},
	{"pw_array_get_i32", {WASM_I32, WASM_I32, WASM_I32}, {WASM_I32}},
	{"pw_array_contains_f64", {WASM_I32, WASM_F64}, {WASM_I32}},
	{"pw_array_contains_i32", {WASM_I32, WASM_I32}, {WASM_I32}},
	{"pw_array_slice", {WASM_I32, WASM_I32, WASM_I32}, {WASM_I32}},
	{"pw_map_length", {WASM_I32}, {WASM_I32}},
	{"pw_map_has_strkey", {WASM_I32, WASM_I32}, {WASM_I32}},
	{"pw_map_has_numkey", {WASM_I32, WASM_F64}, {WASM_I32}},
	{"pw_map_get_strkey_f64", {WASM_I32, WASM_I32, WASM_F64}, {WASM_F64}},
	{"pw_map_get_strkey_i32", {WASM_I32, WASM_I32, WASM_I32}, {WASM_I32}},
	{"pw_map_get_numkey_f64", {WASM_I32, WASM_F64, WASM_F64}, {WASM_F64}},
	{"pw_map_get_numkey_i32", {WASM_I32, WASM_F64, WASM_I32}, {WASM_I32}},
	{"pw_map_delete_strkey", {WASM_I32, WASM_I32}, {WASM_I32}},
	{"pw_map_delete_numkey", {WASM_I32, WASM_F64}, {WASM_I32}},
	{"pw_array_push_f64", {WASM_I32, WASM_F64}, {WASM_I32}},
	{"pw_array_push_i32", {WASM_I32, WASM_I32}, {WASM_I32}},
	{"pw_map_set_strkey_f64", {WASM_I32, WASM_I32, WASM_F64}, {WASM_I32}},
	{"pw_map_set_strkey_i32", {WASM_I32, WASM_I32, WASM_I32}, {WASM_I32}},
	{"pw_map_set_numkey_f64", {WASM_I32, WASM_F64, WASM_F64}, {WASM_I32}},
	{"pw_map_set_numkey_i32", {WASM_I32, WASM_F64, WASM_I32}, {WASM_I32}},
	{"pw_string_length_runes", {WASM_I32}, {WASM_I32}},
	{"pw_string_slice_rune", {WASM_I32, WASM_I32, WASM_I32}, {WASM_I32}},
	{"pw_string_find_rune", {WASM_I32, WASM_I32, WASM_I32}, {WASM_I32}},
	{"pw_string_byte_at", {WASM_I32, WASM_I32}, {WASM_I32}},
	{"pw_string_slice_byte", {WASM_I32, WASM_I32, WASM_I32}, {WASM_I32}},
	{"pw_string_from_bytes", {WASM_I32}, {WASM_I32}},
	{"pw_string_to_bytes", {WASM_I32}, {WASM_I32}},
	{"pw_string_codepoint_at_start", {WASM_I32}, {WASM_I32}},
	{"pw_string_to_runes", {WASM_I32}, {WASM_I32}},
	{"pw_string_from_runes", {WASM_I32}, {WASM_I32}},
	{"pw_string_char_at", {WASM_I32, WASM_I32}, {WASM_I32}},
	{"pw_string_is_digit", {WASM_I32}, {WASM_I32}},
	{"pw_string_is_alpha", {WASM_I32}, {WASM_I32}},
	{"pw_string_is_digit_or_alpha", {WASM_I32}, {WASM_I32}},
	{"pw_string_to_upper", {WASM_I32}, {WASM_I32}},
	{"pw_string_to_lower", {WASM_I32}, {WASM_I32}},
	{"pw_number_to_string", {WASM_F64}, {WASM_I32}},
	{"pw_string_to_number", {WASM_I32}, {WASM_I32}},
	{"pw_string_trim", {WASM_I32}, {WASM_I32}},
	{"pw_string_split", {WASM_I32, WASM_I32}, {WASM_I32}},
	{"pw_string_join", {WASM_I32, WASM_I32}, {WASM_I32}},
	{"pw_map_entries", {WASM_I32}, {WASM_I32}},
	{"pw_println_string", {WASM_I32}, {}},
}

@(private = "file")
write_section :: proc(out: ^[dynamic]u8, id: u8, content: []u8) {
	append(out, id)
	write_uleb128(out, u64(len(content)))
	for b in content do append(out, b)
}

@(private = "file")
write_name :: proc(buf: ^[dynamic]u8, name: string) {
	bytes := transmute([]u8)name
	write_uleb128(buf, u64(len(bytes)))
	for b in bytes do append(buf, b)
}

// lower_module_to_wasm — единственная точка входа (Фаза 1/1.5). Возвращает
// готовые байты WASM MVP-модуля, ИМПОРТИРУЮЩЕГО функции wasm_runtime (см.
// PW_IMPORT_MODULE/pw_imports выше) — сам НЕ владеет памятью и не
// объявляет собственной memory-секции: с Фазы 1.5 память целиком у
// wasm_runtime-модуля (см. его докстринг), сюда попадают только вызовы
// готовых функций. Итоговый модуль запускается композицией с ним (см.
// `wasmtime run --preload env=<runtime>.wasm <это>.wasm`, core/
// wasm_backend_wasmtime_test.odin).
lower_module_to_wasm :: proc(module: ^Mir_Module) -> []u8 {
	// included[k] — исходный индекс (в module.functions) функции, получившей
	// НОВЫЙ (компактный, только среди Фаза-1/1.5-совместимых функций) wasm-
	// индекс PW_IMPORT_COUNT+k — funcidx-пространство начинается с
	// ИМПОРТОВ (см. спецификацию: импортированные функции ВСЕГДА идут
	// раньше локально определённых), локальные функции сдвинуты на
	// PW_IMPORT_COUNT. func_index — обратное отображение (Function_Id
	// исходного module.functions -> итоговый funcidx), для Call_Instr.
	// callee/Function_Ref_Instr.fn (см. wasm_emit.odin) — уже готовое,
	// сдвинутое значение, wasm_emit.odin про сдвиг ничего не знает.
	included := make([dynamic]int)
	defer delete(included)
	func_index := make(map[Function_Id]int)
	defer delete(func_index)
	for &mfn, i in module.functions {
		if is_wasm_phase1_function(&mfn) {
			func_index[Function_Id(i)] = PW_IMPORT_COUNT + len(included)
			append(&included, i)
		}
	}
	n := len(included)

	types_content := make([dynamic]u8)
	defer delete(types_content)
	write_uleb128(&types_content, u64(PW_IMPORT_COUNT + n))
	for imp in pw_imports {
		append(&types_content, 0x60) // functype tag
		write_uleb128(&types_content, u64(len(imp.params)))
		for b in imp.params do append(&types_content, b)
		write_uleb128(&types_content, u64(len(imp.results)))
		for b in imp.results do append(&types_content, b)
	}

	import_content := make([dynamic]u8)
	defer delete(import_content)
	write_uleb128(&import_content, u64(PW_IMPORT_COUNT))
	for imp, i in pw_imports {
		write_name(&import_content, PW_IMPORT_MODULE)
		write_name(&import_content, imp.name)
		append(&import_content, 0x00) // importdesc kind = func
		write_uleb128(&import_content, u64(i)) // typeidx == i (импорты — первые PW_IMPORT_COUNT записей types_content)
	}

	func_content := make([dynamic]u8)
	defer delete(func_content)
	write_uleb128(&func_content, u64(n))

	export_content := make([dynamic]u8)
	defer delete(export_content)
	write_uleb128(&export_content, u64(n))

	for k in 0 ..< n {
		mfn := &module.functions[included[k]]
		param_types := make([dynamic]u8, 0, len(mfn.parameters))
		defer delete(param_types)
		for p in mfn.parameters {
			append(&param_types, wasm_val_type(mfn.locals[int(p)].type))
		}
		returns := prune_type(mfn.result_type) != TY_VOID

		append(&types_content, 0x60) // functype tag
		write_uleb128(&types_content, u64(len(param_types)))
		for b in param_types do append(&types_content, b)
		if returns {
			write_uleb128(&types_content, 1)
			append(&types_content, wasm_val_type(mfn.result_type))
		} else {
			write_uleb128(&types_content, 0)
		}

		wasm_idx := PW_IMPORT_COUNT + k
		write_uleb128(&func_content, u64(wasm_idx)) // typeidx == funcidx == PW_IMPORT_COUNT+k

		write_name(&export_content, mfn.name)
		append(&export_content, 0x00) // exportdesc kind = func
		write_uleb128(&export_content, u64(wasm_idx))
	}

	table_content := make([dynamic]u8)
	defer delete(table_content)
	write_uleb128(&table_content, 1) // 1 таблица
	append(&table_content, 0x70) // funcref
	append(&table_content, 0x00) // limits: только min (без max)
	write_uleb128(&table_content, u64(PW_IMPORT_COUNT + n))

	elem_content := make([dynamic]u8)
	defer delete(elem_content)
	write_uleb128(&elem_content, 1) // 1 активный elem-сегмент
	write_uleb128(&elem_content, 0) // flags=0: active, table 0, expr-offset, funcidx vec
	append(&elem_content, 0x41) // i32.const
	write_sleb128(&elem_content, 0)
	append(&elem_content, 0x0B) // end
	write_uleb128(&elem_content, u64(PW_IMPORT_COUNT + n))
	for i in 0 ..< PW_IMPORT_COUNT + n do write_uleb128(&elem_content, u64(i))

	code_content := make([dynamic]u8)
	defer delete(code_content)
	write_uleb128(&code_content, u64(n))
	for k in 0 ..< n {
		mfn := &module.functions[included[k]]
		body := emit_function_wasm(module, mfn, &func_index)
		write_uleb128(&code_content, u64(len(body)))
		for b in body do append(&code_content, b)
		delete(body)
	}

	out := make([dynamic]u8)
	append(&out, 0x00, 0x61, 0x73, 0x6D) // "\0asm"
	append(&out, 0x01, 0x00, 0x00, 0x00) // version 1
	write_section(&out, 0x01, types_content[:])
	write_section(&out, 0x02, import_content[:])
	write_section(&out, 0x03, func_content[:])
	write_section(&out, 0x04, table_content[:])
	write_section(&out, 0x07, export_content[:])
	write_section(&out, 0x09, elem_content[:])
	write_section(&out, 0x0A, code_content[:])

	return out[:]
}
