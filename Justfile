set shell := ["/bin/bash", "-c"]
set positional-arguments
debug-file file:
	odin run . -debug -vet -strict-style -vet-tabs  -warnings-as-errors -- $1

build:
	odin build . -out:panos

build-lsp:
	odin build ./lsp -out:panos-lsp

# DWARF-символы + без оптимизаций — для lldb-dap (см. nvim DAP-конфиг).
# Не заменяет build-lsp: релизная сборка не должна тащить -debug/-o:none.
build-lsp-debug:
	odin build ./lsp -out:panos-lsp -debug -o:none

# -o:size обязателен: дефолтный -o:minimal даёт модуль, на котором падает
# JIT-компилятор Safari/WebKit (см. wasm/main.odin).
build-wasm:
	odin build wasm -target:js_wasm32 -o:size -out:demo/panos.wasm

build-all: build build-lsp build-wasm

sync-lsp-protocol:
	curl -sL https://raw.githubusercontent.com/Garius6/odin-lsp-protocol/v0.1.1/generated/lsp_types.odin \
		| sed 's/^package lsp$/package lsp_protocol/' \
		> lsp/protocol/lsp_types.odin

# track-memory=false: компилятор (parser/resolver/type_cheker/compiler)
# нигде не освобождает свои AST/Type-графы — тем же образом, что и
# рантайм-бинарь panos, рассчитанный на однократный процесс, память
# которого забирает ОС при выходе. Без этого флага тест-раннер репортит
# КАЖДЫЙ такой alloc как "+++ leak" (не баг, не влияет на память
# реального бинаря) — только шум в выводе `just test`.
test:
	odin test ./core -define:ODIN_TEST_TRACK_MEMORY=false

# Обновляет PANOS_VERSION (core/vm.odin), собирает+тестирует, коммитит
# "chore: версия X.Y.Z", тегирует vX.Y.Z, пушит main и тег — тот же
# ручной semver, что описан в комментарии у PANOS_VERSION. Версию
# передавать БЕЗ "v": just bump-and-push 0.2.9
# odin test ./core падает ненулевым кодом на провале — just останавливает
# рецепт на первой упавшей строке, коммит/тег/push не происходят.
bump-and-push version:
	sed -i '' 's/PANOS_VERSION :: "[^"]*"/PANOS_VERSION :: "{{version}}"/' core/vm.odin
	odin build . -out:panos
	odin test ./core
	git add core/vm.odin
	git commit -m "chore: версия {{version}}"
	git tag v{{version}}
	git push origin main
	git push origin v{{version}}
