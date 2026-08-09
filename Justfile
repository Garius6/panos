set shell := ["/bin/bash", "-c"]
set positional-arguments

# T057/T059 (specs/010-zig-migration): Odin has been fully removed
# (core/*.odin, main.odin, lsp/, wasm/, wasm_runtime/*.odin, ols.json,
# odinfmt.json) — Zig (`build.zig` at repo root) is the ONLY toolchain now.
# These recipes are thin wrappers around `zig build ...` that also copy the
# artifact to the path older tooling expects (`./panos`, `./panos-lsp`,
# `demo/panos.wasm`) — editor LSP configs pointed at repo-root
# `./panos-lsp`, `deploy-pages.yml`'s `cp -r demo/.`, etc. all keep working
# unchanged.
build:
	zig build -Doptimize=ReleaseFast
	cp zig-out/bin/panos panos

build-lsp:
	zig build lsp
	cp zig-out/bin/panos-lsp panos-lsp

build-wasm:
	zig build browser
	mkdir -p demo
	cp zig-out/bin/panos-browser.wasm demo/panos.wasm

build-all: build build-lsp build-wasm

test:
	zig build test

# Обновляет версию (zig/core/vm.zig's osVersion), собирает+тестирует,
# коммитит "chore: версия X.Y.Z", тегирует vX.Y.Z, пушит main и тег.
# Версию передавать БЕЗ "v": just bump-and-push 0.2.9
# zig build test падает ненулевым кодом на провале — just останавливает
# рецепт на первой упавшей строке, коммит/тег/push не происходят.
bump-and-push version:
	sed -i '' 's/createString(try self.allocator.dupe(u8, "[^"]*"))/createString(try self.allocator.dupe(u8, "{{version}}"))/' zig/core/vm.zig
	zig build
	zig build test
	git add zig/core/vm.zig
	git commit -m "chore: версия {{version}}"
	git tag v{{version}}
	git push origin main
	git push origin v{{version}}
