// aot-dom-loader.js — browser loader for a panos AOT-compiled `.wasm`
// program that uses the `DOM` builtin module (`panos build --target=wasm`,
// see `zig/core/mir_lowering.zig`'s `lowerDomBuiltinCall` / `zig/core/
// wasm_emit.zig`'s `hostImportNameForBuiltin`/`builtinSignature`).
//
// String values are opaque i32 handles held by this host. The compiler
// turns each literal's static UTF-8 offset into a handle through
// `pw_string_literal`; dynamic DOM values and string `+` use the same
// table. Allocation and collection therefore stay outside the WASM core.
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
	const strings = [""]
	const stringHandles = new Map([["", 0]])
	const aggregates = [null]
	const arrays = [null]
	const variants = [null]
	function newAggregate(fields) {
		aggregates.push(fields)
		return aggregates.length - 1
	}
	function arrayAt(handle) {
		return arrays[handle]
	}
	function newVariant(fields, tag) {
		variants.push({ fields, tag })
		return variants.length - 1
	}
	function internString(value) {
		const text = String(value)
		const existing = stringHandles.get(text)
		if (existing !== undefined) return existing
		const handle = strings.length
		strings.push(text)
		stringHandles.set(text, handle)
		return handle
	}
	function stringValue(handle) {
		return strings[handle] ?? ""
	}
	function runes(handle) {
		return Array.from(stringValue(handle))
	}
	function asRuneIndex(value) {
		return Math.trunc(value)
	}

	function readCString(offset) {
		const bytes = new Uint8Array(instance.exports.memory.buffer)
		let end = offset
		while (bytes[end] !== 0) end++
		return decoder.decode(bytes.subarray(offset, end))
	}

	const dom = {
		struct_new_: () => newAggregate([]),
		struct_new_f: (a) => newAggregate([a]),
		struct_new_i: (a) => newAggregate([a]),
		struct_new_ff: (a, b) => newAggregate([a, b]),
		struct_new_if: (a, b) => newAggregate([a, b]),
		struct_new_fi: (a, b) => newAggregate([a, b]),
		struct_new_ii: (a, b) => newAggregate([a, b]),
		struct_new_fff: (a, b, c) => newAggregate([a, b, c]),
		struct_new_iff: (a, b, c) => newAggregate([a, b, c]),
		struct_new_fif: (a, b, c) => newAggregate([a, b, c]),
		struct_new_iif: (a, b, c) => newAggregate([a, b, c]),
		struct_new_ffi: (a, b, c) => newAggregate([a, b, c]),
		struct_new_ifi: (a, b, c) => newAggregate([a, b, c]),
		struct_new_fii: (a, b, c) => newAggregate([a, b, c]),
		struct_new_iii: (a, b, c) => newAggregate([a, b, c]),
		struct_get_i32: (handle, field) => aggregates[handle]?.[field] ?? 0,
		struct_get_f64: (handle, field) => aggregates[handle]?.[field] ?? 0,
		struct_set_i32: (handle, value, field) => {
			if (aggregates[handle]) aggregates[handle][field] = value
		},
		struct_set_f64: (handle, value, field) => {
			if (aggregates[handle]) aggregates[handle][field] = value
		},
		array_new: () => {
			arrays.push([])
			return arrays.length - 1
		},
		array_length: (handle) => arrayAt(handle)?.length ?? 0,
		array_append_i32: (handle, value) => {
			arrayAt(handle)?.push(value)
		},
		array_append_f64: (handle, value) => {
			arrayAt(handle)?.push(value)
		},
		array_set_i32: (handle, index, value) => {
			const array = arrayAt(handle)
			if (!array || !Number.isInteger(index) || index < 0 || index >= array.length) throw new RangeError("индекс массива вне границ")
			array[index] = value
		},
		array_set_f64: (handle, index, value) => {
			const array = arrayAt(handle)
			if (!array || !Number.isInteger(index) || index < 0 || index >= array.length) throw new RangeError("индекс массива вне границ")
			array[index] = value
		},
		array_get_i32: (handle, index) => {
			const array = arrayAt(handle)
			if (!array || !Number.isInteger(index) || index < 0 || index >= array.length) throw new RangeError("индекс массива вне границ")
			return array[index]
		},
		array_get_f64: (handle, index) => {
			const array = arrayAt(handle)
			if (!array || !Number.isInteger(index) || index < 0 || index >= array.length) throw new RangeError("индекс массива вне границ")
			return array[index]
		},
		array_get_or_i32: (handle, index, fallback) => {
			const array = arrayAt(handle)
			return array && Number.isInteger(index) && index >= 0 && index < array.length ? array[index] : fallback
		},
		array_get_or_f64: (handle, index, fallback) => {
			const array = arrayAt(handle)
			return array && Number.isInteger(index) && index >= 0 && index < array.length ? array[index] : fallback
		},
		variant_new_: (tag) => newVariant([], tag),
		variant_new_i: (a, tag) => newVariant([a], tag),
		variant_new_f: (a, tag) => newVariant([a], tag),
		variant_new_ii: (a, b, tag) => newVariant([a, b], tag),
		variant_new_if: (a, b, tag) => newVariant([a, b], tag),
		variant_new_fi: (a, b, tag) => newVariant([a, b], tag),
		variant_new_ff: (a, b, tag) => newVariant([a, b], tag),
		variant_match: (handle, tag) => variants[handle]?.tag === tag ? 1 : 0,
		variant_get_i32: (handle, field) => variants[handle]?.fields[field] ?? 0,
		variant_get_f64: (handle, field) => variants[handle]?.fields[field] ?? 0,
		pw_string_literal: (offset) => internString(readCString(offset)),
		pw_string_concat: (left, right) => internString(stringValue(left) + stringValue(right)),
		pw_string_length: (value) => runes(value).length,
		pw_string_byte_length: (value) => new TextEncoder().encode(stringValue(value)).length,
		pw_string_slice: (value, start, end) => internString(runes(value).slice(asRuneIndex(start), asRuneIndex(end)).join("")),
		pw_string_find: (value, needle, start) => {
			const subject = runes(value)
			const target = runes(needle)
			const from = Math.max(0, asRuneIndex(start))
			if (target.length === 0) return Math.min(from, subject.length)
			for (let index = from; index + target.length <= subject.length; index++) {
				let matches = true
				for (let offset = 0; offset < target.length; offset++) {
					if (subject[index + offset] !== target[offset]) {
						matches = false
						break
					}
				}
				if (matches) return index
			}
			return -1
		},
		pw_string_starts_with: (value, prefix) => stringValue(value).startsWith(stringValue(prefix)) ? 1 : 0,
		pw_string_replace: (value, from, to) => internString(stringValue(value).replaceAll(stringValue(from), stringValue(to))),
		pw_string_split: (value, separator) => {
			arrays.push(stringValue(value).split(stringValue(separator)).map(internString))
			return arrays.length - 1
		},
		pw_string_from_number: (value) => internString(String(value)),
		pw_string_to_number: (value) => {
			const text = stringValue(value).trim()
			const number = Number(text)
			if (text !== "" && Number.isFinite(number)) return newVariant([number], 0)
			return newVariant([newAggregate([internString("строки"), internString("некорректное число")])], 1)
		},
		// The AOT ABI cannot suspend a Panos frame, so this intentionally uses
		// synchronous same-origin XHR. HTTP 2xx returns Опция.Есть(body);
		// every non-2xx or transport failure is Опция.Нет().
		pw_http_request_sync: (method, url, body) => {
			try {
				const request = new XMLHttpRequest()
				request.open(stringValue(method), stringValue(url), false)
				request.setRequestHeader("Content-Type", "application/json")
				request.send(stringValue(body))
				if (request.status >= 200 && request.status < 300) return newVariant([internString(request.responseText)], 1)
			} catch (_) {
				// Network failures are represented by Опция.Нет().
			}
			return newVariant([], 0)
		},
		dom_get_text_num: (selector) => {
			const el = document.querySelector(stringValue(selector))
			if (!el) return 0
			const n = parseFloat(el.textContent)
			return Number.isFinite(n) ? n : 0
		},
		dom_set_text_num: (selector, value) => {
			const el = document.querySelector(stringValue(selector))
			if (el) el.textContent = String(value)
		},
		// Handler name MUST match an exported panos function taking zero
		// arguments (`функ имя() -> Пусто`) — no captured "context" value,
		// unlike the old Odin-era loader's `(context, __env)` convention
		// (that needed a real closures ABI this backend doesn't have yet).
		dom_on_click_num: (selector, handlerName) => {
			const el = document.querySelector(stringValue(selector))
			const name = stringValue(handlerName)
			const handler = instance.exports[name]
			if (el && typeof handler === "function") {
				el.addEventListener("click", () => handler())
			}
		},
		// The three-argument form `DOM.на_клик(selector, name, context)`
		// is intentionally not a general closure ABI: `name` remains a
		// static exported function and context is one explicit string value.
		dom_on_click_context: (selector, handlerName, context) => {
			const el = document.querySelector(stringValue(selector))
			const handler = instance.exports[stringValue(handlerName)]
			if (el && typeof handler === "function") {
				el.addEventListener("click", () => handler(context))
			}
		},
		dom_get_text_string: (selector) => {
			const el = document.querySelector(stringValue(selector))
			return internString(el?.textContent ?? "")
		},
		dom_set_text_string: (selector, value) => {
			const el = document.querySelector(stringValue(selector))
			if (el) el.textContent = stringValue(value)
		},
		dom_get_input_value: (selector) => {
			const el = document.querySelector(stringValue(selector))
			return internString(el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement ? el.value : "")
		},
		dom_set_input_value: (selector, value) => {
			const el = document.querySelector(stringValue(selector))
			if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) el.value = stringValue(value)
		},
		dom_create_append: (parentSelector, tagName, id) => {
			const parent = document.querySelector(stringValue(parentSelector))
			if (!parent) return
			const child = document.createElement(stringValue(tagName))
			child.id = stringValue(id)
			parent.appendChild(child)
		},
		// Schedules a fresh exported Panos call. It deliberately does not
		// suspend or resume the current Panos frame, so it is safe without a
		// CPS transform or a general actor/closure runtime.
		dom_after_frame: (handlerName, context) => {
			const handler = instance.exports[stringValue(handlerName)]
			if (typeof handler === "function") {
				requestAnimationFrame(() => handler(context))
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
