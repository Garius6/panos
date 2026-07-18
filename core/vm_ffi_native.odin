#+build !js
package core

import "core:fmt"

// Стадия 47 (FFI-B, первый срез): вызывается из execute()'s .Call_Foreign
// (vm.odin) с уже снятыми со стека arg_count значениями (args). Панос-
// значения — всегда f64 (Целое рантайм-представления не имеет отдельного
// от Число, см. Int_Divide/Modulo в compiler.odin) — маршаллинг только
// меняет C ABI ширину (i32/i64), не панос-тип.
call_foreign :: proc(vm: ^VM, ff: ^Foreign_Function, args: []Value) -> Value {
	if !ff.cif_ready {
		prepare_foreign_cif(ff)
	}
	cif := (^Ffi_Cif)(ff.cif)

	nargs := len(ff.param_widths)
	// avalue — массив УКАЗАТЕЛЕЙ на аргументы (libffi-контракт, не значения
	// напрямую) — arg_storage даёт стабильную (не temp, не GC) память под
	// каждый аргумент на время ЭТОГО вызова.
	arg_storage := make([]i64, nargs, context.temp_allocator)
	avalue := make([]rawptr, nargs, context.temp_allocator)
	for i in 0 ..< nargs {
		val := args[i].(f64)
		if ff.param_widths[i] == 32 {
			(^i32)(&arg_storage[i])^ = i32(val)
		} else {
			(^i64)(&arg_storage[i])^ = i64(val)
		}
		avalue[i] = &arg_storage[i]
	}

	ret_storage: i64
	ffi_call(cif, ff.fn_ptr, &ret_storage, nargs > 0 ? raw_data(avalue) : nil)

	if ff.return_width == 32 {
		return Value(f64((^i32)(&ret_storage)^))
	}
	return Value(f64(ret_storage))
}

// Готовит Ffi_Cif ОДИН РАЗ на ^Foreign_Function (кэш через cif_ready) —
// ffi_prep_cif не бесплатен и результат не меняется между вызовами одной
// и той же decl. atypes должен пережить эту функцию (cif хранит указатель
// на него, ffi_call читает его при КАЖДОМ вызове) — permanent-хип
// (vm_heap_allocator, gc.odin), не temp_allocator.
prepare_foreign_cif :: proc(ff: ^Foreign_Function) {
	context.allocator = vm_heap_allocator()

	cif := new(Ffi_Cif)
	nargs := len(ff.param_widths)
	atypes := make([]^Ffi_Type, nargs)
	for w, i in ff.param_widths {
		atypes[i] = ffi_type_for_width(w)
	}
	rtype := ffi_type_for_width(ff.return_width)
	status := ffi_prep_cif(cif, FFI_DEFAULT_ABI, u32(nargs), rtype, nargs > 0 ? raw_data(atypes) : nil)
	if status != FFI_OK {
		fmt.panicf("Runtime Error: ffi_prep_cif не удался для '%s' (status=%d)", ff.name, status)
	}
	ff.cif = rawptr(cif)
	ff.cif_ready = true
}
