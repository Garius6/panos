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

build-all: build build-lsp

test:
	odin test ./core
