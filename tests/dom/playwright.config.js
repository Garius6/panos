// playwright.config.js — сквозной прогон DOM target'а (демо/dom/
// counter.html + docs/src/assets/aot-dom-loader.js) в реальном headless
// Chromium — wasmtime не умеет document.*, только браузер может это
// проверить, см. план (`../../.claude/plans/generic-questing-stream.md`
// на момент планирования — не гарантированно живой путь потом).
const { defineConfig } = require("@playwright/test")

module.exports = defineConfig({
	testDir: ".",
	webServer: {
		// static-server.js — свой минимальный сервер (см. её докстринг про
		// то, почему не serve-handler), корень репозитория целиком —
		// counter.html грузит aot-dom-loader.js относительным путём
		// ../../docs/src/assets/, статик-сервер должен видеть ОБА дерева
		// (demo/ и docs/) из общего корня.
		command: "node static-server.js",
		port: 4173,
		reuseExistingServer: !process.env.CI,
	},
	use: {
		baseURL: "http://localhost:4173",
	},
})
