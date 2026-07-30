// static-server.js — минимальный статик-сервер для playwright.config.js's
// webServer (repo-корень целиком, counter.html грузит aot-dom-loader.js
// относительным путём из docs/). НЕ npm-пакет — избегает serve-handler
// (транзитивная high-severity DoS-уязвимость в brace-expansion/minimatch,
// найдено через npm audit; риск на практике нулевой — сервер только на
// localhost, только для headless Chromium в тесте — но раз можно
// избежать зависимости вовсе парой строк Node stdlib, так проще).
const http = require("http")
const fs = require("fs")
const path = require("path")

const root = path.resolve(__dirname, "../../")
const port = 4173

const MIME = {
	".html": "text/html",
	".js": "text/javascript",
	".wasm": "application/wasm",
	".ps": "text/plain",
}

http
	.createServer((req, res) => {
		const urlPath = decodeURIComponent(req.url.split("?")[0])
		const filePath = path.join(root, urlPath)
		if (!filePath.startsWith(root)) {
			res.writeHead(403)
			res.end()
			return
		}
		fs.readFile(filePath, (err, data) => {
			if (err) {
				res.writeHead(404)
				res.end()
				return
			}
			const ext = path.extname(filePath)
			res.writeHead(200, { "Content-Type": MIME[ext] || "application/octet-stream" })
			res.end(data)
		})
	})
	.listen(port, () => {
		console.log(`static-server listening on ${port}, root=${root}`)
	})
