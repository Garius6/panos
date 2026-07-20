#+build !js
package core

import "core:testing"

// compute_document_symbols — файловый outline, чисто структурный (без
// резолвера): struct/enum + их дочерние поля/варианты, функции.
@(test)
test_document_symbols_struct_enum_function :: proc(t: ^testing.T) {
	tokens, _ := tokenize(`
		тип Точка = структура
			x: Число
		конец

		тип Цвет = перечисление
			Красный
		конец

		функ квадрат(n: Целое) -> Целое
			n * n
		конец
	`)
	stream := make_stream(tokens)
	parser := Parser{stream = &stream}
	prog := parse_program(&parser)

	symbols := compute_document_symbols(prog)
	defer delete(symbols)

	testing.expectf(t, len(symbols) == 3, "[document symbols] ожидалось 3 top-level символа, получено %d", len(symbols))
	if len(symbols) == 3 {
		testing.expectf(t, symbols[0].kind == .Struct && len(symbols[0].children) == 1 && symbols[0].children[0].kind == .Field, "[document symbols] symbols[0] ожидался Struct с 1 полем")
		testing.expectf(t, symbols[1].kind == .Enum && len(symbols[1].children) == 1 && symbols[1].children[0].kind == .EnumMember, "[document symbols] symbols[1] ожидался Enum с 1 вариантом")
		testing.expectf(t, symbols[2].kind == .Function, "[document symbols] symbols[2] ожидалась Function")
	}
}
