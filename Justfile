set positional-arguments
debug-file file:
	odin run . -debug -vet -strict-style -vet-tabs  -warnings-as-errors -- $1
