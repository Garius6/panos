// todo.spec.js — единственная реальная проверка полного стека todo-демо
// (panos native backend ↔ panos AOT-wasm frontend ↔ настоящий HTTP через
// сеть.http_запрос_sync) — тот же принцип, что tests/dom/counter.spec.js:
// wasmtime не может исполнить XHR/document.*, только реальный браузер.
const { test, expect } = require("@playwright/test")

test("добавление, переключение и удаление задачи через реальный AOT-фронтенд + panos-бэкенд", async ({ page }) => {
	await page.goto("/demo/todo-app/frontend/index.html")

	await expect(page.locator("#список li")).toHaveCount(0)

	await page.locator("#новая-задача").fill("купить хлеб")
	await page.locator("#добавить").click()
	await expect(page.locator("#список li")).toHaveCount(1)
	await expect(page.locator("#список li")).toContainText("купить хлеб")
	await expect(page.locator("#список li")).toContainText("[ ]")

	await page.locator("#список li button", { hasText: "переключить" }).click()
	await expect(page.locator("#список li")).toContainText("[x]")

	await page.locator("#список li button", { hasText: "удалить" }).click()
	await expect(page.locator("#список li")).toHaveCount(0)
})
