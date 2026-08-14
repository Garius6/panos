// aot-dom-loader.js — browser loader for a panos AOT-compiled `.wasm`
// program that uses the `DOM` builtin module (`panos build --target=wasm`,
// see `zig/core/mir_lowering.zig`'s `lowerDomBuiltinCall` / `zig/core/
// wasm_emit.zig`'s `hostImportNameForBuiltin`/`builtinSignature`).
//
// Строка/Опция(Строка) values are REAL addresses into the program's own
// WASM linear memory now, not host-table handles — `zig/core/wasm_strings.
// zig` (string builtins host-imports elimination) and `zig/core/
// wasm_objects.zig` (struct/array/variant expansion) both replaced the
// original DOM-object-table scheme with real in-memory representations
// some time ago; this loader was never updated to match and silently
// stayed correct only because nothing ever exercised a Строка/Опция(Строка)
// value crossing the host boundary until `сеть.http_запрос_sync` was
// actually run end-to-end for the first time (`panos build --target=wasm`
// itself only started succeeding for real programs once WASM AOT interface
// dispatch + first-class function values landed — see the WASM-AOT
// initiative's own commit history). Confirmed via `wasm-objdump`: the
// compiled module imports ZERO `pw_string_*`/`struct_new_*`/`variant_new_*`
// functions any more — every one of those host imports below was already
// dead code, never actually requested by the module.
//
// Layouts read/written directly here, matching the compiler's own codegen
// exactly (not guessed):
//   Строка:  `[u32 byte_length][raw UTF-8 bytes...]` — `wasm_strings.zig`'s
//            own "LENGTH-PREFIXED UTF-8 byte buffer" doc comment.
//   Опция(T): two 8-byte slots — `[i32 tag][padding][i32-or-f64 field0]...`
//            (`wasm_objects.zig`'s `.build_variant`/`.match_tag` codegen —
//            each slot is 8 bytes regardless of the value's own width, a
//            narrow i32 write only touches the slot's low 4 bytes). Опция's
//            own tag order is fixed by `prelude.zig`: `Нет = 0`, `Есть(T)
//            = 1`.
// Both are allocated via the module's own exported bump allocator,
// `@runtime_alloc(size) -> ptr` (exported unconditionally like every other
// function, `wasm_emit.zig`'s export section has no allow-list) — this
// loader never needs its own memory management, just the same allocator
// the WASM code itself uses.
//
// NOTE: `demo/todo-app/frontend/index.html` still calls
// `loadAotDomProgram(programUrl, runtimeUrl)` with the OLD two-argument,
// object-table-runtime-based signature — that program was built against
// the now-deleted Odin AOT backend and is already tracked as non-
// functional (`ISSUES.md`'s "Odin-era" banner); it is not compatible with
// this loader and isn't something this rewrite attempts to fix.
export async function loadAotDomProgram(programWasmUrl) {
	const decoder = new TextDecoder()
	const encoder = new TextEncoder()
	let instance
	// Elm-architecture Model, held here (not in the DOM) across separate
	// `state_read`/`.записать` round-trips — see the `состояние.*` host
	// functions below. Per-instance (one `loadAotDomProgram` call =
	// one running program), never global.
	let heldModel = ""

	// Never cache a `DataView`/`Uint8Array` across calls — WASM memory can
	// grow (`memory.grow`), which detaches any previously constructed view
	// of the old backing `ArrayBuffer`.
	function memoryView() {
		return new DataView(instance.exports.memory.buffer)
	}
	function memoryBytes() {
		return new Uint8Array(instance.exports.memory.buffer)
	}

	// `ptr === 0` is NOT a null/missing-string sentinel here — the static
	// string-literal data section is placed at the very START of linear
	// memory (`wasm_emit.zig`'s own `actor_heap_base` computation adds
	// the actor allocator's sentinel-avoidance AFTER `strings.data.len`,
	// confirming the data section itself starts at absolute address 0),
	// so a short/common literal (e.g. the very FIRST string constant
	// emitted) can legitimately have a real address of exactly 0. Real
	// bug found via a `DOM.создать_и_добавить("body", ...)` call reading
	// back as an empty selector — silently broke `querySelector("")`
	// instead of `querySelector("body")` — confirmed via `strings
	// program.wasm` showing "body" genuinely present in the data section
	// while every OTHER string literal in the same tiny test program
	// happened to read back correctly (they didn't land at offset 0).
	function readString(ptr) {
		const byteLength = memoryView().getUint32(ptr, true)
		return decoder.decode(memoryBytes().subarray(ptr + 4, ptr + 4 + byteLength))
	}

	function writeString(text) {
		const bytes = encoder.encode(text)
		const ptr = instance.exports["@runtime_alloc"](4 + bytes.length)
		memoryView().setUint32(ptr, bytes.length, true)
		memoryBytes().set(bytes, ptr + 4)
		return ptr
	}

	// Опция(Строка) — the only Опция(T) shape this host boundary ever
	// needs to build or read (DOM.значение_поля's result, `сеть.
	// http_запрос_sync`'s result). `null`/`undefined` builds `Нет`.
	function buildStringOption(text) {
		if (text === null || text === undefined) {
			const ptr = instance.exports["@runtime_alloc"](8)
			memoryView().setInt32(ptr, 0, true) // tag = Нет
			return ptr
		}
		const strHandle = writeString(text)
		const ptr = instance.exports["@runtime_alloc"](16)
		memoryView().setInt32(ptr, 1, true) // tag = Есть
		memoryView().setInt32(ptr + 8, strHandle, true) // field 0, slot 1
		return ptr
	}

	// `на_клик`/`.на_клик_контекст` re-registering on the SAME element
	// across repeated calls (e.g. a re-render loop re-running the same
	// `DOM.на_клик(...)` call every frame/update) used to just keep
	// STACKING listeners forever — every click fired every past
	// registration, including ones captured with now-stale context
	// pointers (memory-safe since Phase 1 GC's promotion fix, but still
	// semantically wrong: a click would re-run OLD handlers with OLD
	// data). `WeakMap<Element, listener>` — keyed by the actual element
	// (not the selector string), so a genuinely RECREATED element for
	// the same selector (`DOM.создать_и_добавить` rebuilding a subtree)
	// gets its own fresh entry with no explicit cleanup needed (the old,
	// now-detached element and its map entry become unreachable
	// together); re-registering on the SAME still-attached element
	// replaces the listener instead of adding a second one.
	const clickListeners = new WeakMap()
	function registerClick(el, listener) {
		const previous = clickListeners.get(el)
		if (previous) el.removeEventListener("click", previous)
		el.addEventListener("click", listener)
		clickListeners.set(el, listener)
	}

	const dom = {
		dom_get_text_num: (selectorPtr) => {
			const el = document.querySelector(readString(selectorPtr))
			if (!el) return 0
			const n = parseFloat(el.textContent)
			return Number.isFinite(n) ? n : 0
		},
		dom_set_text_num: (selectorPtr, value) => {
			const el = document.querySelector(readString(selectorPtr))
			if (el) el.textContent = String(value)
		},
		// Handler name MUST match an exported panos function taking zero
		// arguments (`функ имя() -> Пусто`) — no captured "context" value,
		// unlike the old Odin-era loader's `(context, __env)` convention
		// (that needed a real closures ABI this backend doesn't have yet).
		dom_on_click_num: (selectorPtr, handlerNamePtr) => {
			const el = document.querySelector(readString(selectorPtr))
			const handler = instance.exports[readString(handlerNamePtr)]
			if (el && typeof handler === "function") {
				registerClick(el, () => handler())
			}
		},
		// The three-argument form `DOM.на_клик(selector, name, context)`
		// is intentionally not a general closure ABI: `name` remains a
		// static exported function and `context` is one explicit Строка
		// value — `contextPtr` is already a real Строка handle from the
		// WASM side, forwarded to the handler UNCHANGED (never decoded
		// here; only WASM code ever needs to read it).
		dom_on_click_context: (selectorPtr, handlerNamePtr, contextPtr) => {
			const el = document.querySelector(readString(selectorPtr))
			const handler = instance.exports[readString(handlerNamePtr)]
			if (el && typeof handler === "function") {
				registerClick(el, () => handler(contextPtr))
			}
		},
		dom_get_text_string: (selectorPtr) => {
			const el = document.querySelector(readString(selectorPtr))
			return writeString(el?.textContent ?? "")
		},
		dom_set_text_string: (selectorPtr, valuePtr) => {
			const el = document.querySelector(readString(selectorPtr))
			if (el) el.textContent = readString(valuePtr)
		},
		dom_get_input_value: (selectorPtr) => {
			const el = document.querySelector(readString(selectorPtr))
			return writeString(el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement ? el.value : "")
		},
		dom_set_input_value: (selectorPtr, valuePtr) => {
			const el = document.querySelector(readString(selectorPtr))
			if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) el.value = readString(valuePtr)
		},
		// `DOM.атрибут`/`.установить_атрибут` — the general escape hatch
		// for anything not covered by a dedicated call (CSS via
		// `style`, CSS classes via `class`, ARIA attributes, etc.).
		// Returns/accepts a plain Строка, no Опция wrapping (matches
		// `dom_get_text_string`'s own "" fallback, not `сеть.
		// http_запрос_sync`'s Опция convention — an attribute simply
		// being absent is not an error case worth a match/`.получить()`
		// at every call site).
		dom_get_attribute: (selectorPtr, nameAttrPtr) => {
			const el = document.querySelector(readString(selectorPtr))
			return writeString(el?.getAttribute(readString(nameAttrPtr)) ?? "")
		},
		dom_set_attribute: (selectorPtr, nameAttrPtr, valuePtr) => {
			const el = document.querySelector(readString(selectorPtr))
			if (el) el.setAttribute(readString(nameAttrPtr), readString(valuePtr))
		},
		// `состояние.прочитать`/`.записать` — an Elm-architecture Model
		// held as a plain JS variable in THIS closure (`heldModel`,
		// declared below), not a DOM attribute — see
		// `project_panos_elm_architecture_dom_storage_design`. Always a
		// full byte copy in both directions (`writeString`/`readString`),
		// same as every other Строка crossing this boundary — no raw
		// pointer is ever held onto here, so it needs no special handling
		// under the WASM side's per-call arena reset.
		state_read: () => writeString(heldModel),
		state_write: (valuePtr) => {
			heldModel = readString(valuePtr)
		},
		dom_create_append: (parentSelectorPtr, tagNamePtr, idPtr) => {
			const parent = document.querySelector(readString(parentSelectorPtr))
			if (!parent) return
			const child = document.createElement(readString(tagNamePtr))
			child.id = readString(idPtr)
			parent.appendChild(child)
		},
		// Schedules a fresh exported Panos call. It deliberately does not
		// suspend or resume the current Panos frame, so it is safe without a
		// CPS transform or a general actor/closure runtime.
		dom_after_frame: (handlerNamePtr, contextPtr) => {
			const handler = instance.exports[readString(handlerNamePtr)]
			if (typeof handler === "function") {
				requestAnimationFrame(() => handler(contextPtr))
			}
		},
		// The AOT ABI cannot suspend a Panos frame, so this intentionally uses
		// synchronous same-origin XHR. HTTP 2xx returns Опция.Есть(body);
		// every non-2xx or transport failure is Опция.Нет() — both built as
		// REAL Опция(Строка) values in WASM memory via `buildStringOption`,
		// not a host-table handle (see this file's own header comment for
		// why the old scheme silently traps `match_tag`/`get_variant_field`
		// with "unreachable" — confirmed via `wasmtime`, not guessed).
		pw_http_request_sync: (methodPtr, urlPtr, bodyPtr) => {
			try {
				const request = new XMLHttpRequest()
				request.open(readString(methodPtr), readString(urlPtr), false)
				request.setRequestHeader("Content-Type", "application/json")
				request.send(readString(bodyPtr))
				if (request.status >= 200 && request.status < 300) return buildStringOption(request.responseText)
			} catch (_) {
				// Network failures are represented by Опция.Нет().
			}
			return buildStringOption(null)
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
