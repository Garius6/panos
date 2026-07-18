// Превращает каждый ```panos блок кода в редактируемый + запускаемый
// виджет (как у Go Tour) — один общий WASM-инстанс на страницу, у
// каждого блока своя (не растущая, в отличие от demo/index.html)
// область вывода: перед каждым запуском просто чистим её и пишем заново,
// никакого общего #console на всех блоков не нужно, значит и обходной
// путь odin.js с накоплением текста тут не нужен — пишем свой минимальный
// набор WASM-импортов напрямую (тот же контракт, что panos.wasm ожидает
// от odin.js, см. wasm/main.odin).
(function () {
	"use strict";

	const SOURCE_BUF_SIZE = 65536;

	let memory = null;
	let instance = null;
	let initPromise = null;
	// Синхронный WASM-вызов — реентерабельности нет, значит один общий
	// указатель "куда сейчас пишем" безопасен между запусками разных
	// виджетов на одной странице.
	let activeOutput = null;

	function wasmUrl() {
		// panos.wasm копируется дженериком "любой не-md файл из src/"
		// (в assets/panos.wasm от корня книги, БЕЗ src/-префикса — в
		// отличие от additional-js/additional-css, которые уходят в
		// src/assets/<hash>.{js,css}: два разных механизма копирования
		// mdBook с разными путями, свой путь руками не выведешь надёжно).
		// path_to_root — готовая переменная mdBook, компенсирует глубину
		// вложенности текущей страницы (задаётся инлайн-<script> в <head>
		// каждой страницы). Объявлена там через const/let — НЕ становится
		// свойством window (в отличие от var), но видна как голый
		// идентификатор всем classic <script>-тегам страницы, раз они
		// делят один top-level lexical scope — этот скрипт тоже classic
		// (не type="module"), достаём её напрямую, не через window.
		return path_to_root + "assets/panos.wasm";
	}

	function initWasm() {
		if (initPromise) return initPromise;
		initPromise = (async () => {
			const decoder = new TextDecoder();
			const imports = {
				env: {},
				odin_env: {
					write: (fd, ptr, len) => {
						if (activeOutput) {
							activeOutput.text += decoder.decode(new Uint8Array(memory.buffer, ptr, len));
						}
					},
					trap: () => { throw new Error("panos panic"); },
					alert: () => {},
					abort: () => { throw new Error("panos abort"); },
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
						crypto.getRandomValues(new Uint8Array(memory.buffer, ptr, len));
					},
				},
			};
			const resp = await fetch(wasmUrl());
			const bytes = await resp.arrayBuffer();
			const result = await WebAssembly.instantiate(bytes, imports);
			instance = result.instance;
			memory = instance.exports.memory;
			instance.exports._start();
		})();
		return initPromise;
	}

	function runSource(source) {
		const encoder = new TextEncoder();
		const bytes = encoder.encode(source);
		if (bytes.length > SOURCE_BUF_SIZE) {
			return { ok: false, text: "Ошибка: исходник длиннее буфера (64KB)" };
		}
		const ptr = instance.exports.panos_source_ptr();
		new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);

		const output = { text: "" };
		activeOutput = output;
		let crashed = false;
		try {
			instance.exports.panos_run(bytes.length);
		} catch (e) {
			crashed = true;
		}
		activeOutput = null;
		// panos_run сам печатает "── запуск ──" перед стартом — нужно
		// demo/index.html (там #console общий и растущий, разделитель
		// помогает отличить прогоны друг от друга). У наших виджетов
		// область вывода своя и чистится перед каждым запуском — разделитель
		// тут чистый шум, срезаем.
		const text = output.text.replace(/^── запуск ──\n\n?/, "");
		return { ok: !crashed, text };
	}

	function buildWidget(codeEl) {
		const pre = codeEl.parentElement;
		const source = codeEl.textContent.replace(/\n$/, "");

		const widget = document.createElement("div");
		widget.className = "panos-widget";

		const textarea = document.createElement("textarea");
		textarea.value = source;
		textarea.spellcheck = false;
		textarea.rows = Math.max(3, source.split("\n").length);

		const toolbar = document.createElement("div");
		toolbar.className = "panos-toolbar";

		const button = document.createElement("button");
		button.textContent = "▶ Запустить";

		const status = document.createElement("span");
		status.className = "panos-status";

		toolbar.appendChild(button);
		toolbar.appendChild(status);

		const output = document.createElement("pre");
		output.className = "panos-output";

		widget.appendChild(textarea);
		widget.appendChild(toolbar);
		widget.appendChild(output);

		button.addEventListener("click", async () => {
			button.disabled = true;
			status.textContent = "Загрузка...";
			status.classList.remove("panos-crashed");
			try {
				await initWasm();
			} catch (e) {
				status.textContent = "Не удалось загрузить WASM-модуль";
				button.disabled = false;
				return;
			}
			const result = runSource(textarea.value);
			output.textContent = result.text;
			if (!result.ok) {
				status.textContent = "⚠ выполнение прервано (паника)";
				status.classList.add("panos-crashed");
			} else {
				status.textContent = "";
			}
			button.disabled = false;
		});

		pre.replaceWith(widget);
	}

	document.addEventListener("DOMContentLoaded", () => {
		document.querySelectorAll("pre > code.language-panos").forEach(buildWidget);
	});
})();
