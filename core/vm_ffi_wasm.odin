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
