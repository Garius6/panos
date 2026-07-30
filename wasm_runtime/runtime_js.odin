#+build js
package wasm_runtime

// runtime_js.odin — ввод_вывод::печать/строка и время::монотонно_мс/
// сейчас_мс для js_wasm32 (браузер) — зеркало runtime_wasi.odin (#+build
// !js), тот же набор экспортируемых имён/сигнатур, другая реализация.
// wasm_runtime никогда не проходит через Odin-собственную runtime-
// инициализацию (нет _start, см. Фазу 2.9 — __$startup_runtime), значит
// автоматический core:fmt->odin_env-роутинг сюда НЕ относится — свой
// foreign import, под ОТДЕЛЬНЫМ именем модуля "js_runtime" (не
// "odin_env" — это НЕ тот контракт, которого core:fmt ожидал бы, если
// бы шёл через обычную Odin-инициализацию; здесь его нет вообще,
// значит и переиспользовать нечего) — контракт закрывает docs/src/
// assets/aot-dom-loader.js (браузерный загрузчик AOT-программ).
foreign import js_rt "js_runtime"
@(default_calling_convention = "contextless")
foreign js_rt {
	write :: proc(ptr: i32, len: i32) ---
	now_ms :: proc() -> f64 ---
	monotonic_ms :: proc() -> f64 ---
}

@(private)
newline_byte: [1]u8 = {'\n'}

// write(ptr,len) читает НАПРЯМУЮ из линейной памяти ЭТОГО инстанса по
// АБСОЛЮТНОМУ адресу (то, что JS видит как exports.memory.buffer) — тот
// же "абсолютный, не arena-относительный" нюанс, что pw_string_ptr в
// runtime.odin документирует подробно; abs_addr — общий помощник для
// ЛЮБОГО package-level байта, не только arena[off] (newline_byte —
// отдельный package-level массив, но линейно в ТОЙ ЖЕ памяти инстанса).
@(private)
abs_addr :: proc "contextless" (p: ^u8) -> i32 {
	return i32(uintptr(p))
}

@(export)
pw_print_string :: proc "contextless" (handle: i32) {
	length := obj_sizes[handle]
	write(pw_string_ptr(handle), length)
}

// pw_println_string — ДВА отдельных write-вызова (текст, затем '\n' из
// СВОЕГО статического однобайтового буфера) — тот же принцип, что
// runtime_wasi.odin's двух-fd_write-вызовная версия.
@(export)
pw_println_string :: proc "contextless" (handle: i32) {
	length := obj_sizes[handle]
	write(pw_string_ptr(handle), length)
	write(abs_addr(&newline_byte[0]), 1)
}

@(export)
pw_monotonic_ms :: proc "contextless" () -> f64 {
	return monotonic_ms()
}

@(export)
pw_now_ms :: proc "contextless" () -> f64 {
	return now_ms()
}
