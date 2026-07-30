// static-proxy-server.js — минимальный статик-сервер (repo-корень целиком,
// index.html грузит aot-dom-loader.js относительным путём из docs/, тот
// же принцип, что tests/dom/static-server.js — НЕ npm-пакет, избегает
// serve-handler по той же причине, см. её докстринг) + reverse-proxy
// /api/* на panos-бэкенд (demo/todo-app/backend/main.ps, порт 18321).
//
// Прокси нужен ТОЛЬКО потому, что std/сеть/http.ps's ОтветСервера
// (`std/сеть/http.ps:301-305`) не имеет поля для кастомных заголовков —
// panos-бэкенд не может сам выставить Access-Control-Allow-Origin, а
// фронтенд (этот статик-сервер, ДРУГОЙ порт) и бэкенд — разные origin
// с точки зрения браузера. Проксируя /api/* через ТОТ ЖЕ origin, что
// раздаёт статику, CORS не нужен вообще — браузер видит один и тот же
// origin для страницы и для fetch/XHR.
const http = require("http")
const fs = require("fs")
const path = require("path")

const root = path.resolve(__dirname, "../../")
const port = 4174
const backendPort = 18321

const MIME = {
	".html": "text/html",
	".js": "text/javascript",
	".wasm": "application/wasm",
	".ps": "text/plain",
}

http
	.createServer((req, res) => {
		if (req.url.startsWith("/api/")) {
			const proxyReq = http.request(
				{ host: "localhost", port: backendPort, path: req.url, method: req.method, headers: req.headers },
				(proxyRes) => {
					res.writeHead(proxyRes.statusCode, proxyRes.headers)
					proxyRes.pipe(res)
				},
			)
			proxyReq.on("error", () => {
				res.writeHead(502)
				res.end()
			})
			req.pipe(proxyReq)
			return
		}

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
		console.log(`static-proxy-server listening on ${port}, root=${root}, proxying /api/* to :${backendPort}`)
	})
