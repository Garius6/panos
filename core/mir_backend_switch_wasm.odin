#+build js
package core

// core:os недоступен под js/wasm (compile-time panic) — переключателя
// тут не бывает, wasm-сборка всегда идёт старым путём.
use_mir_backend :: proc() -> bool {
	return false
}
