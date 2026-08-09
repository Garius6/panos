// aot-dom-loader.js — browser loader for a panos AOT-compiled `.wasm`
// program that uses the `DOM` builtin module (`panos build --target=wasm`,
// see `zig/core/mir_lowering.zig`'s `lowerDomBuiltinCall` / `zig/core/
// wasm_emit.zig`'s `hostImportNameForBuiltin`/`builtinSignature`).
//
// Deliberately minimal, matching what that backend actually emits today —
// NO object-table runtime, NO closures, NO separate runtime.wasm to
// instantiate first (unlike this file's earlier Odin-era shape): a
// `Строка` argument to `DOM.*` (a CSS selector or a click-handler's
// exported panos function name) is always a COMPILE-TIME constant, encoded
// by the compiler as a null-terminated UTF-8 run inside the program's own
// `memory` export at a fixed byte offset — `readCString` below is the only
// piece of string handling this loader needs. `DOM.текст`/`.установить_текст`
// work on a NUMBER (the element's `textContent` parsed as/formatted from a
// panos `Число`), not a real string — this backend has no runtime string
// object at all, so a genuinely textual DOM binding is out of scope until
// it does.
//
// NOTE: `demo/todo-app/frontend/index.html` still calls
// `loadAotDomProgram(programUrl, runtimeUrl)` with the OLD two-argument,
// object-table-runtime-based signature — that program was built against
// the now-deleted Odin AOT backend and is already tracked as non-
// functional (`ISSUES.md`'s "Odin-era" banner); it is not compatible with
// this loader and isn't something this rewrite attempts to fix.
export async function loadAotDomProgram(programWasmUrl) {
	const decoder = new TextDecoder()
	let instance

	function readCString(offset) {
		const bytes = new Uint8Array(instance.exports.memory.buffer)
		let end = offset
		while (bytes[end] !== 0) end++
		return decoder.decode(bytes.subarray(offset, end))
	}

	const dom = {
		dom_get_text_num: (selOffset) => {
			const el = document.querySelector(readCString(selOffset))
			if (!el) return 0
			const n = parseFloat(el.textContent)
			return Number.isFinite(n) ? n : 0
		},
		dom_set_text_num: (selOffset, value) => {
			const el = document.querySelector(readCString(selOffset))
			if (el) el.textContent = String(value)
		},
		// Handler name MUST match an exported panos function taking zero
		// arguments (`функ имя() -> Пусто`) — no captured "context" value,
		// unlike the old Odin-era loader's `(context, __env)` convention
		// (that needed a real closures ABI this backend doesn't have yet).
		dom_on_click_num: (selOffset, handlerNameOffset) => {
			const el = document.querySelector(readCString(selOffset))
			const handlerName = readCString(handlerNameOffset)
			const handler = instance.exports[handlerName]
			if (el && typeof handler === "function") {
				el.addEventListener("click", () => handler())
			}
		},
	}

	const response = await fetch(programWasmUrl)
	const bytes = await response.arrayBuffer()
	const module = new WebAssembly.Module(bytes)
	instance = await WebAssembly.instantiate(module, { env: dom })

	// "старт" — the fixed entry-point name every panos target uses
	// (`panos run`'s `функ старт()`, same convention, no arguments here
	// since the AOT backend never lowers argv).
	instance.exports["старт"]()

	return instance
}
