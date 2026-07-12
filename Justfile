set positional-arguments
debug-file file:
	odin run . -debug -vet -strict-style -vet-tabs  -warnings-as-errors -- $1

build:
	odin build . -out:panos

build-lsp:
	odin build ./lsp -out:panos-lsp

build-all: build build-lsp

test:
	odin test ./core
