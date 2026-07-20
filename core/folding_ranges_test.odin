#+build !js
package core

import "core:testing"

// compute_folding_ranges — чисто синтаксическая (парсер, без резолвера):
// struct/enum/interface/impl декларации + вложенные if/while/match/lambda
// блоки, растянутые больше чем на одну строку.
@(test)
test_folding_ranges_covers_decls_and_nested_blocks :: proc(t: ^testing.T) {
	tokens, _ := tokenize(`
		тип Точка = структура
			x: Число
		конец

		функ квадрат(n: Целое) -> Целое
			если n > 0
				n * n
			иначе
				0
			конец
		конец
	`)
	stream := make_stream(tokens)
	parser := Parser{stream = &stream}
	prog := parse_program(&parser)

	ranges := compute_folding_ranges(prog)
	defer delete(ranges)

	testing.expectf(t, len(ranges) == 3, "[folding ranges] ожидалось 3 диапазона (структура, функция, if), получено %d", len(ranges))
}
