// playwright.config.js — сквозной прогон todo-демо (backend + wasm-
// фронтенд), тот же принцип, что tests/dom/playwright.config.js —
// отдельная npm-установка (Node не резолвит node_modules сестринской
// директории через require без symlink-трюков), но браузерный бинарник
// Chromium кэшируется ГЛОБАЛЬНО (~/.cache/ms-playwright), повторная
// установка не тянет его заново.
const { defineConfig } = require("@playwright/test")

module.exports = defineConfig({
	testDir: __dirname,
	webServer: [
		{
			command: "../../panos ../../demo/todo-app/backend/main.ps",
			cwd: __dirname,
			port: 18321,
			reuseExistingServer: !process.env.CI,
		},
		{
			command: "node static-proxy-server.js",
			cwd: __dirname,
			port: 4174,
			reuseExistingServer: !process.env.CI,
		},
	],
	use: { baseURL: "http://localhost:4174" },
})
