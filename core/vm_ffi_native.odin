#+build !js
package core

import "core:fmt"
import "core:strings"

// Стадия 49 (FFI): libc free() — НЕ часть vendored libffi (external/
// libffi/), обычная платформенная libc-функция (тот же принцип, что
// "system:c" в core/e2e_test.odin's getpid-тесте) — не нарушает
// "вендорить всё": libc — платформенный C-рантайм, на который уже
// неявно опирается сам Odin, не третьесторонняя библиотека. Вызывается
// ТОЛЬКО из gc.odin's pool_release, ТОЛЬКО когда Pointer_Value.owned ==
// true (см. Foreign_Decl.return_owned/`свой`, parser.odin).
foreign import libc_free "system:c"
foreign libc_free {
	free :: proc(ptr: rawptr) ---
}

pointer_free :: proc(ptr: rawptr) {
	free(ptr)
}

// Стадия 47/49/51: вызывается из execute()'s .Call_Foreign (vm.odin) с
// уже снятыми со стека arg_count значениями (args). arg_storage —
// 8-байтные ячейки под КАЖДЫЙ СКАЛЯРНЫЙ аргумент (i8/i32/i64/f32/f64
// влезают напрямую; для КСтрока/Указатель(T) в ячейку кладётся САМ
// rawptr — размер совпадает на 64-битных платформах, единственных пока
// поддержанных, см. external/libffi/README.md) — avalue содержит АДРЕСА
// этих ячеек (libffi-контракт: массив указателей на аргументы, не
// значения напрямую). .Struct — ОСОБЫЙ случай: avalue[i] указывает
// НАПРЯМУЮ на сырой байтовый буфер (сам буфер И ЕСТЬ значение аргумента
// для struct-by-value, не адрес-на-адрес, как у остальных), см. pack_
// ffi_struct.
call_foreign :: proc(vm: ^VM, ff: ^Foreign_Function, args: []Value) -> Value {
	if !ff.cif_ready {
		prepare_foreign_cif(ff)
	}
	cif := (^Ffi_Cif)(ff.cif)

	nargs := len(ff.param_kinds)
	arg_storage := make([]i64, nargs, context.temp_allocator)
	avalue := make([]rawptr, nargs, context.temp_allocator)
	for i in 0 ..< nargs {
		#partial switch ff.param_kinds[i] {
		case .Int8:
			// u8, НЕ i8: C ABI-тип — ffi_type_uint8 (см. ffi_bindings.odin),
			// Целое(8) в этом срезе всегда БЕЗЗНАКОВЫЙ байт (raylib's
			// Color-каналы 0-255, отрицательных значений не бывает) —
			// signed i8(255.0) даёт неопределённое/неверное поведение при
			// конвертации из float вне [-128,127], в отличие от u8.
			(^u8)(&arg_storage[i])^ = u8(args[i].(f64))
			avalue[i] = &arg_storage[i]
		case .Int32:
			(^i32)(&arg_storage[i])^ = i32(args[i].(f64))
			avalue[i] = &arg_storage[i]
		case .Int64:
			(^i64)(&arg_storage[i])^ = i64(args[i].(f64))
			avalue[i] = &arg_storage[i]
		case .Float32:
			(^f32)(&arg_storage[i])^ = f32(args[i].(f64))
			avalue[i] = &arg_storage[i]
		case .Float64:
			(^f64)(&arg_storage[i])^ = args[i].(f64)
			avalue[i] = &arg_storage[i]
		case .CString:
			// Строка живёт ТОЛЬКО на время этого вызова (borrowed
			// convention — см. docs/src/language/ffi.md) — если
			// C-функция сохраняет указатель дольше своего вызова, это
			// вне гарантий этого среза.
			s := args[i].(^Panos_String)
			cstr, _ := strings.clone_to_cstring(s.data, context.temp_allocator)
			(^cstring)(&arg_storage[i])^ = cstr
			avalue[i] = &arg_storage[i]
		case .Pointer:
			p := args[i].(^Pointer_Value)
			(^rawptr)(&arg_storage[i])^ = p.ptr
			avalue[i] = &arg_storage[i]
		case .Struct:
			agg := args[i].(^Aggregate_Value)
			buf := pack_ffi_struct(ff.param_struct_types[i], agg)
			avalue[i] = raw_data(buf)
		}
	}

	// Стадия 51: .Struct-возврат нуждается в буфере ТОЧНОГО размера
	// составного типа (может быть больше 8 байт arg_storage-эквивалента,
	// хотя у Vector2/Color сейчас — нет) — отдельная ветка вместо
	// переиспользования ret_storage.
	ret_storage: i64
	rvalue: rawptr = &ret_storage
	ret_struct_buf: []u8
	if ff.return_kind == .Struct {
		composite := (^Ffi_Type)(ff.return_struct_type.ffi_composite)
		ret_struct_buf = make([]u8, composite.size, context.temp_allocator)
		rvalue = raw_data(ret_struct_buf)
	}

	ffi_call(cif, ff.fn_ptr, rvalue, nargs > 0 ? raw_data(avalue) : nil)

	switch ff.return_kind {
	case .Void:
		return f64(0)
	case .Int8:
		return Value(f64((^u8)(&ret_storage)^))
	case .Int32:
		return Value(f64((^i32)(&ret_storage)^))
	case .Int64:
		return Value(f64(ret_storage))
	case .Float32:
		return Value(f64((^f32)(&ret_storage)^))
	case .Float64:
		return Value(f64((^f64)(&ret_storage)^))
	case .CString:
		// panos ВСЕГДА копирует возвращённую C-строку в новую
		// Panos_String (gc_new_string клонирует байты) — никогда не
		// заимствует чужую C-память, независимо от того, кто ей
		// реально владеет на C-стороне.
		raw_cstr := (^cstring)(&ret_storage)^
		return Value(gc_new_string(vm, string(raw_cstr)))
	case .Pointer:
		ptr_val := gc_new(vm, Pointer_Value)
		ptr_val.ptr = (^rawptr)(&ret_storage)^
		ptr_val.owned = ff.return_owned
		return Value(ptr_val)
	case .Struct:
		return Value(unpack_ffi_struct(vm, ff.return_struct_type, ret_struct_buf))
	}
	return f64(0)
}

// Стадия 51: пакует ^Aggregate_Value (ff_структура-значение, как обычная
// panos-структура — Стадия 35's именованный конструктор) в сырой C-
// layout буфер по offset'ам struct_type.ffi_offsets. Каждое поле — f64
// на panos-стороне (как везде), записывается по своей C-ширине
// (Foreign_Marshal_Kind, struct_type.ffi_field_kinds[i]).
pack_ffi_struct :: proc(struct_type: ^Type, agg: ^Aggregate_Value) -> []u8 {
	ensure_struct_prepared(struct_type)
	composite := (^Ffi_Type)(struct_type.ffi_composite)
	buf := make([]u8, composite.size, context.temp_allocator)
	for kind, i in struct_type.ffi_field_kinds {
		off := struct_type.ffi_offsets[i]
		val := agg.elements[i].(f64)
		field_ptr := &buf[off]
		#partial switch kind {
		case .Int8:
			(^u8)(field_ptr)^ = u8(val)
		case .Int32:
			(^i32)(field_ptr)^ = i32(val)
		case .Int64:
			(^i64)(field_ptr)^ = i64(val)
		case .Float32:
			(^f32)(field_ptr)^ = f32(val)
		case .Float64:
			(^f64)(field_ptr)^ = val
		}
	}
	return buf
}

// Обратная операция: сырой C-буфер (возврат ff_структура-функции) ->
// новый ^Aggregate_Value (та же рантайм-форма, что обычные panos-
// структуры — .x/.y-доступ, именованный конструктор работают бесплатно).
unpack_ffi_struct :: proc(vm: ^VM, struct_type: ^Type, buf: []u8) -> ^Aggregate_Value {
	agg := gc_new(vm, Aggregate_Value)
	resize(&agg.elements, len(struct_type.ffi_field_kinds))
	for kind, i in struct_type.ffi_field_kinds {
		off := struct_type.ffi_offsets[i]
		field_ptr := &buf[off]
		val: f64
		#partial switch kind {
		case .Int8:
			val = f64((^u8)(field_ptr)^)
		case .Int32:
			val = f64((^i32)(field_ptr)^)
		case .Int64:
			val = f64((^i64)(field_ptr)^)
		case .Float32:
			val = f64((^f32)(field_ptr)^)
		case .Float64:
			val = (^f64)(field_ptr)^
		}
		agg.elements[i] = val
	}
	return agg
}

// Стадия 51: строит (лениво, ОДИН РАЗ, кэш на struct_type.ffi_composite/
// ffi_offsets — тот же паттерн, что Foreign_Decl.compiled_fn/Foreign_
// Function.cif) составной FFI_TYPE_STRUCT для ff_структура-типа. size/
// alignment составного типа считает САМА libffi (см. libffi-
// исследование) — но ТОЛЬКО как побочный эффект ffi_prep_cif, в котором
// этот составной тип реально участвует (см. prepare_foreign_cif) —
// поэтому вызывается ИЗНУТРИ prepare_foreign_cif, не отдельно.
ensure_struct_composite :: proc(struct_type: ^Type) -> ^Ffi_Type {
	if struct_type.ffi_composite != nil {
		return (^Ffi_Type)(struct_type.ffi_composite)
	}
	context.allocator = vm_heap_allocator()

	n := len(struct_type.ffi_field_kinds)
	// null-terminated массив ^Ffi_Type (libffi-контракт для elements).
	elements := make([]^Ffi_Type, n + 1)
	for kind, i in struct_type.ffi_field_kinds {
		elements[i] = ffi_type_for_marshal(kind)
	}
	elements[n] = nil

	composite := new(Ffi_Type)
	composite.type = FFI_TYPE_STRUCT
	composite.elements = raw_data(elements)
	struct_type.ffi_composite = rawptr(composite)
	return composite
}

// Заполняет struct_type.ffi_offsets ПОСЛЕ того, как составной тип уже
// поучаствовал хотя бы в одном ffi_prep_cif (size/alignment реально
// посчитаны) — вызывается из prepare_foreign_cif сразу после успешного
// ffi_prep_cif внешней функции.
ensure_struct_offsets :: proc(struct_type: ^Type) {
	if struct_type.ffi_offsets != nil {
		return
	}
	context.allocator = vm_heap_allocator()
	composite := (^Ffi_Type)(struct_type.ffi_composite)
	offsets := make([]uint, len(struct_type.ffi_field_kinds))
	status := ffi_get_struct_offsets(FFI_DEFAULT_ABI, composite, raw_data(offsets))
	if status != FFI_OK {
		fmt.panicf("Runtime Error: ffi_get_struct_offsets не удался для '%s' (status=%d)", struct_type.name, status)
	}
	struct_type.ffi_offsets = offsets
}

// Вызывается лениво из call_foreign/pack_ffi_struct для типов, которые
// почему-то ещё не прошли через prepare_foreign_cif (не должно случаться
// в нормальном потоке — cif_ready гарантирует это на уровне Foreign_
// Function — но защищаемся от прямого вызова pack_ffi_struct в отрыве).
ensure_struct_prepared :: proc(struct_type: ^Type) {
	if struct_type.ffi_offsets == nil {
		fmt.panicf("Compiler Error: ff_структура '%s' используется до prepare_foreign_cif", struct_type.name)
	}
}

// Готовит Ffi_Cif ОДИН РАЗ на ^Foreign_Function (кэш через cif_ready) —
// ffi_prep_cif не бесплатен и результат не меняется между вызовами одной
// и той же decl. atypes должен пережить эту функцию (cif хранит указатель
// на него, ffi_call читает его при КАЖДОМ вызове) — permanent-хип
// (vm_heap_allocator, gc.odin), не temp_allocator.
prepare_foreign_cif :: proc(ff: ^Foreign_Function) {
	context.allocator = vm_heap_allocator()

	cif := new(Ffi_Cif)
	nargs := len(ff.param_kinds)
	atypes := make([]^Ffi_Type, nargs)
	for kind, i in ff.param_kinds {
		if kind == .Struct {
			atypes[i] = ensure_struct_composite(ff.param_struct_types[i])
		} else {
			atypes[i] = ffi_type_for_marshal(kind)
		}
	}
	rtype: ^Ffi_Type
	if ff.return_kind == .Struct {
		rtype = ensure_struct_composite(ff.return_struct_type)
	} else {
		rtype = ffi_type_for_marshal(ff.return_kind)
	}
	status := ffi_prep_cif(cif, FFI_DEFAULT_ABI, u32(nargs), rtype, nargs > 0 ? raw_data(atypes) : nil)
	if status != FFI_OK {
		fmt.panicf("Runtime Error: ffi_prep_cif не удался для '%s' (status=%d)", ff.name, status)
	}
	ff.cif = rawptr(cif)
	ff.cif_ready = true

	// Стадия 51: offset'ы полей ТОЛЬКО ПОСЛЕ успешного ffi_prep_cif —
	// size/alignment составных типов уже посчитаны libffi.
	for kind, i in ff.param_kinds {
		if kind == .Struct {
			ensure_struct_offsets(ff.param_struct_types[i])
		}
	}
	if ff.return_kind == .Struct {
		ensure_struct_offsets(ff.return_struct_type)
	}
}
