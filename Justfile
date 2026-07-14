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

# Тянет сгенерённые LSP-типы из github.com/Garius6/odin-lsp-protocol
# (pinned на тег, не auto-sync — при апдейте версии поправить тег тут).
sync-lsp-protocol:
	curl -sL https://raw.githubusercontent.com/Garius6/odin-lsp-protocol/v0.1.1/generated/lsp_types.odin \
		| sed 's/^package lsp$/package lsp_protocol/' \
		> lsp/protocol/lsp_types.odin

test:
	odin test ./core
