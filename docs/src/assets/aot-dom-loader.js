// aot-dom-loader.js — браузерный загрузчик AOT-скомпилированных panos-
// программ (core/wasm_module.odin, DOM target) — НЕ то же самое, что
// interactive.js (тот грузит панос-ИНТЕРПРЕТАТОР целиком, этот грузит
// ОДНУ конкретную скомпилированную .ps-программу). Собственная минимальная
// обвязка (тот же принцип, что interactive.js — НЕ odin.js/odin_dom, см.
// её докстринг), но ДВУХСТАДИЙНАЯ композиция вместо одностадийной:
//
//   1) runtime_js.wasm (wasm_runtime, -target:js_wasm32, см. Justfile's
//      build-wasm-runtime-js) — ЭТОТ модуль владеет памятью/арену (тот же
//      принцип, что wasmtime-путь: --preload env=<runtime>.wasm, core/
//      wasm_backend_wasmtime_test.odin). Компилируется реальным Odin-
//      кодом (wasm_runtime/runtime_js.odin, #+build js) — значит САМ
//      нуждается в odin_env (write/rand_bytes — тот же контракт, что
//      interactive.js уже реализует для интерпретатора, СКОПИРОВАН сюда
//      буквально, не переиспользован модульно — держать эти два загрузчика
//      независимыми проще, чем городить общий JS-модуль ради 20 строк) —
//      ПЛЮС свой собственный js_runtime (write/now_ms/monotonic_ms, см.
//      wasm_runtime/runtime_js.odin).
//   2) программа.wasm (сама AOT-скомпилированная panos-программа) —
//      получает imports.env = экспорты runtime_js.wasm (все pw_*-функции)
//      И imports.dom = ЭТИ DOM-функции (dom_get_text и т.п., core/
//      wasm_module.odin's PW_DOM_MODULE) — единственное место, где
//      document.* реально вызывается, программа.wasm сама НИКОГДА не
//      видит DOM напрямую.
//
// Строки между JS и WASM — ВСЕГДА через хендлы (opaque i32 в объект-
// таблице wasm_runtime), НЕ напрямую: pw_scratch_set/pw_alloc_from_scratch
// строит новую Строку из JS-байт (тот же протокол, что Const_Instr(string)
// кодогенерация уже использует), pw_string_ptr+pw_string_len+TextDecoder
// читает существующую. Опция(Строка) результаты (DOM.текст/DOM.атрибут)
// ЭТА сторона строит САМА через pw_build_variant/pw_set_field_i32 —
// экспортированные функции runtime, вызываемые НАПРЯМУЮ из JS как любые
// другие (никакого нового Odin-кода для этого направления не нужно).

const TAG_NONE = 0
const TAG_SOME = 1

export async function loadAotDomProgram(programWasmUrl, runtimeWasmUrl) {
	const decoder = new TextDecoder()
	const encoder = new TextEncoder()
	let memory

	// odin_env — ТОТ ЖЕ контракт, что interactive.js реализует для панос-
	// интерпретатора (см. её докстринг) — wasm_runtime, скомпилированный
	// реальным Odin-тулчейном под js_wasm32, нуждается в НЁМ, а не в
	// каком-то своём отдельном контракте (Odin's base/runtime всегда
	// ожидает odin_env на этой платформе, независимо от того, что за
	// package компилируется).
	const odinEnv = {
		write: (fd, ptr, len) => {
			process_stderr_or_stdout(fd, decoder.decode(new Uint8Array(memory.buffer, ptr, len)))
		},
		trap: () => {
			throw new Error("wasm_runtime panic")
		},
		alert: () => {},
		abort: () => {
			throw new Error("wasm_runtime abort")
		},
		evaluate: () => {},
		open: () => {},
		time_now: () => BigInt(Date.now()),
		tick_now: () => performance.now(),
		time_sleep: () => {},
		sqrt: Math.sqrt,
		sin: Math.sin,
		cos: Math.cos,
		pow: Math.pow,
		fmuladd: (x, y, z) => x * y + z,
		ln: Math.log,
		exp: Math.exp,
		ldexp: (x, e) => x * Math.pow(2, e),
		rand_bytes: (ptr, len) => {
			crypto.getRandomValues(new Uint8Array(memory.buffer, ptr, len))
		},
	}

	function process_stderr_or_stdout(fd, text) {
		if (fd === 2) {
			console.error(text)
		} else {
			console.log(text)
		}
	}

	// js_runtime — wasm_runtime/runtime_js.odin's СОБСТВЕННЫЙ контракт
	// (ввод_вывод::печать/строка, время::монотонно_мс/сейчас_мс) —
	// ОТДЕЛЬНЫЙ от odin_env, wasm_runtime никогда не идёт через Odin-
	// собственную runtime-инициализацию (см. её докстринг), значит
	// odin_env — это ТОЛЬКО то, что base/runtime само требует, а печать
	// panos-строк — свой, явно объявленный контракт.
	const jsRuntime = {
		write: (ptr, len) => {
			process_stderr_or_stdout(1, decoder.decode(new Uint8Array(memory.buffer, ptr, len)))
		},
		now_ms: () => Date.now(),
		monotonic_ms: () => performance.now(),
	}

	const runtimeResp = await fetch(runtimeWasmUrl)
	const runtimeBytes = await runtimeResp.arrayBuffer()
	const runtimeResult = await WebAssembly.instantiate(runtimeBytes, {
		odin_env: odinEnv,
		js_runtime: jsRuntime,
	})
	const runtime = runtimeResult.instance
	memory = runtime.exports.memory

	// pw_scratch_set/pw_alloc_from_scratch — тот же побайтовый протокол,
	// что Const_Instr(string) кодогенерация использует (Фаза 1.5) — JS
	// пишет байты по одному, затем "закрывает" в постоянный объект.
	function allocString(text) {
		const bytes = encoder.encode(text)
		for (let i = 0; i < bytes.length; i++) {
			runtime.exports.pw_scratch_set(i, bytes[i])
		}
		return runtime.exports.pw_alloc_from_scratch(bytes.length)
	}

	function readString(handle) {
		const ptr = runtime.exports.pw_string_ptr(handle)
		const len = runtime.exports.pw_string_len(handle)
		return decoder.decode(new Uint8Array(memory.buffer, ptr, len))
	}

	// buildOption — Есть(x)/Нет() — тег-порядок ЗАФИКСИРОВАН (core/
	// prelude.odin:11, Нет=0/Есть=1), pw_build_variant/pw_set_field_i32 —
	// ТЕ ЖЕ экспортированные функции, что кодогенерация wasm-стороны сама
	// использует для Build_Variant_Instr — вызываются здесь НАПРЯМУЮ как
	// обычные exports, без какого-либо нового Odin-кода.
	function buildTextOption(text) {
		if (text === null || text === undefined) {
			return runtime.exports.pw_build_variant(TAG_NONE, 0)
		}
		const strHandle = allocString(text)
		const id = runtime.exports.pw_build_variant(TAG_SOME, 1)
		runtime.exports.pw_set_field_i32(id, 0, strHandle)
		return id
	}

	let program // заполняется ниже, обработчикам нужен ДОСТУП к своим же exports

	// dom — единственное место, где document.* реально вызывается (см.
	// докстринг файла). Каждая функция получает СТРОКОВЫЕ ХЕНДЛЫ (i32,
	// объект-таблица wasm_runtime), не значения напрямую.
	const dom = {
		dom_get_text: (selHandle) => {
			const el = document.querySelector(readString(selHandle))
			return buildTextOption(el ? el.textContent : null)
		},
		dom_set_text: (selHandle, textHandle) => {
			const el = document.querySelector(readString(selHandle))
			if (!el) return 0
			el.textContent = readString(textHandle)
			return 1
		},
		dom_get_attribute: (selHandle, nameHandle) => {
			const el = document.querySelector(readString(selHandle))
			if (!el) return buildTextOption(null)
			return buildTextOption(el.getAttribute(readString(nameHandle)))
		},
		dom_set_attribute: (selHandle, nameHandle, valueHandle) => {
			const el = document.querySelector(readString(selHandle))
			if (!el) return 0
			el.setAttribute(readString(nameHandle), readString(valueHandle))
			return 1
		},
		dom_remove_attribute: (selHandle, nameHandle) => {
			const el = document.querySelector(readString(selHandle))
			if (!el) return 0
			el.removeAttribute(readString(nameHandle))
			return 1
		},
		dom_create_and_append: (parentSelHandle, tagHandle, idHandle) => {
			const parent = document.querySelector(readString(parentSelHandle))
			if (!parent) return 0
			const el = document.createElement(readString(tagHandle))
			el.id = readString(idHandle)
			parent.appendChild(el)
			return 1
		},
		dom_remove: (selHandle) => {
			const el = document.querySelector(readString(selHandle))
			if (!el) return 0
			el.remove()
			return 1
		},
		dom_on_click: (selHandle, handlerNameHandle) => {
			return registerHandler(selHandle, handlerNameHandle, "click")
		},
		dom_on_input: (selHandle, handlerNameHandle) => {
			return registerHandler(selHandle, handlerNameHandle, "input")
		},
	}

	// registerHandler — имя_обработчика ДОЛЖНО совпадать с ИМЕНЕМ
	// экспортированной panos-функции (core/wasm_module.odin's export-
	// секция экспортирует КАЖДУЮ функцию по её имени безусловно) —
	// программа обязана объявить `функ имя() -> Пусто` В ГЛАВНОМ файле
	// (не в импортированном модуле — там имя несёт префикс "модуль::",
	// см. resolver.odin's full_name, за пределами v1). Несуществующее
	// имя — ложь СРАЗУ (не тихий no-op), не ждёт первого клика.
	function registerHandler(selHandle, handlerNameHandle, eventName) {
		const el = document.querySelector(readString(selHandle))
		const handlerName = readString(handlerNameHandle)
		const handlerFn = program.exports[handlerName]
		if (!el || typeof handlerFn !== "function") return 0
		// __env — closure-хендл (см. план closures, core/wasm_module.odin):
		// КАЖДАЯ panos-функция теперь принимает этот трейлинг i32-параметр
		// единообразно, обработчик — обычная неcaptured функция и его не
		// читает, но арность WASM-сигнатуры требует передать хоть что-то.
		el.addEventListener(eventName, () => handlerFn(0))
		return 1
	}

	const programResp = await fetch(programWasmUrl)
	const programBytes = await programResp.arrayBuffer()
	const programResult = await WebAssembly.instantiate(programBytes, {
		env: runtime.exports,
		dom: dom,
	})
	program = programResult.instance

	// программа.wasm — РУЧНАЯ WASM-кодогенерация (core/wasm_module.odin),
	// не настоящая Odin-сборка — нет _start/своей инициализации вообще,
	// только объявленные panos-функции. "старт" — ФИКСИРОВАННОЕ имя
	// точки входа во всём проекте (тот же вызов, что `panos run`/
	// wasmtime-путь этого бэкенда, `--invoke старт`, делают). Трейлинг 0
	// — __env (см. план closures) — старт его не читает, см. registerHandler.
	program.exports["старт"](0)

	return program
}
