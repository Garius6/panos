// counter.spec.js — единственный реальный источник проверки для DOM
// target'а (wasmtime не умеет document.*, см. plan). Собирается через
// `just build-wasm-runtime-js` + `odin test ./core -define:PANOS_BUILD_
// DOM_DEMO=true -define:ODIN_TEST_NAMES=core.test_build_dom_counter_
// demo` ДО запуска этого теста — не запускает сборку сама (та требует
// Odin-тулчейн, playwright — только браузер).
const { test, expect } = require("@playwright/test")

test("клик на #btn инкрементирует #count через реальный AOT DOM-вывод", async ({ page }) => {
	await page.goto("/demo/dom/counter.html")

	await expect(page.locator("#count")).toHaveText("0")

	await page.locator("#btn").click()
	await expect(page.locator("#count")).toHaveText("1")

	await page.locator("#btn").click()
	await page.locator("#btn").click()
	await expect(page.locator("#count")).toHaveText("3")
})
