#+build !js
package wasm_runtime

import wasi "core:sys/wasm/wasi"

// runtime_wasi.odin — ввод_вывод::печать/строка и время::монотонно_мс/
// сейчас_мс для wasi_wasm32 (wasmtime и т.п.) — тот же #+build !js/js
// принцип, что core/*_native.odin/core/*_wasm.odin уже применяют для
// native/браузер-специфичного кода в основном package core, только
// здесь развилка wasi/браузер вместо native/браузер (wasm_runtime не
// собирается под native ВООБЩЕ).

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
