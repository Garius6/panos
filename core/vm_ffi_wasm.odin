#+build js
package core

import "core:fmt"

// WASM-заглушка: libffi (ffi_bindings.odin) — #+build !js, недоступен
// здесь по построению. `внешний`-декларация физически не может успешно
// зарезолвиться в браузере (dynlib.load_library всегда did_load=false на
// js, см. resolver.odin) — Resolve Error ловит это раньше, чем дело
// дойдёт до реального вызова, так что эта функция теоретически
// недостижима в собранной программе. Существует, потому что execute()
// (vm.odin) вызывает call_foreign безусловно для ЛЮБОГО таргета.
call_foreign :: proc(vm: ^VM, ff: ^Foreign_Function, args: []Value) -> Value {
	fmt.panicf("Runtime Panic: 'внешний'-функции недоступны в браузере (WASM-сборка не может грузить нативные библиотеки)")
}

// Стадия 49: Pointer_Value.owned == true не может возникнуть на wasm —
// единственный источник (возврат из `внешний`-вызова) недостижим (см.
// call_foreign выше). Существует, потому что gc.odin's pool_release
// вызывает pointer_free безусловно для ЛЮБОГО таргета.
pointer_free :: proc(ptr: rawptr) {
	fmt.panicf("Runtime Panic: указатели недоступны в браузере (WASM-сборка не может грузить нативные библиотеки)")
}
