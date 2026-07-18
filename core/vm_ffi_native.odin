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

// Стадия 47/49: вызывается из execute()'s .Call_Foreign (vm.odin) с уже
// снятыми со стека arg_count значениями (args). arg_storage — 8-байтные
// ячейки под КАЖДЫЙ аргумент (i32/i64 влезают напрямую; для КСтрока/
// Указатель(T) в ячейку кладётся САМ rawptr — размер совпадает на
// 64-битных платформах, единственных пока поддержанных, см. external/
// libffi/README.md) — avalue содержит АДРЕСА этих ячеек (libffi-
// контракт: массив указателей на аргументы, не значения напрямую).
call_foreign :: proc(vm: ^VM, ff: ^Foreign_Function, args: []Value) -> Value {
	if !ff.cif_ready {
		prepare_foreign_cif(ff)
	}
	cif := (^Ffi_Cif)(ff.cif)

	nargs := len(ff.param_kinds)
	arg_storage := make([]i64, nargs, context.temp_allocator)
	avalue := make([]rawptr, nargs, context.temp_allocator)
	for i in 0 ..< nargs {
		switch ff.param_kinds[i] {
		case .Int32:
			(^i32)(&arg_storage[i])^ = i32(args[i].(f64))
		case .Int64:
			(^i64)(&arg_storage[i])^ = i64(args[i].(f64))
		case .CString:
			// Строка живёт ТОЛЬКО на время этого вызова (borrowed
			// convention — см. docs/src/language/ffi.md) — если
			// C-функция сохраняет указатель дольше своего вызова, это
			// вне гарантий этого среза.
			s := args[i].(^Panos_String)
			cstr, _ := strings.clone_to_cstring(s.data, context.temp_allocator)
			(^cstring)(&arg_storage[i])^ = cstr
		case .Pointer:
			p := args[i].(^Pointer_Value)
			(^rawptr)(&arg_storage[i])^ = p.ptr
		}
		avalue[i] = &arg_storage[i]
	}

	ret_storage: i64
	ffi_call(cif, ff.fn_ptr, &ret_storage, nargs > 0 ? raw_data(avalue) : nil)

	switch ff.return_kind {
	case .Int32:
		return Value(f64((^i32)(&ret_storage)^))
	case .Int64:
		return Value(f64(ret_storage))
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
	}
	return f64(0)
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
		atypes[i] = ffi_type_for_marshal(kind)
	}
	rtype := ffi_type_for_marshal(ff.return_kind)
	status := ffi_prep_cif(cif, FFI_DEFAULT_ABI, u32(nargs), rtype, nargs > 0 ? raw_data(atypes) : nil)
	if status != FFI_OK {
		fmt.panicf("Runtime Error: ffi_prep_cif не удался для '%s' (status=%d)", ff.name, status)
	}
	ff.cif = rawptr(cif)
	ff.cif_ready = true
}
