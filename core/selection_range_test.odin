#+build !js
package core

import "core:strings"
import "core:testing"

// collect_selection_spans — цепочка span'ов СНАРУЖИ ВНУТРЬ (декларация ->
// ... -> самый глубокий узел, содержащий offset).
@(test)
test_selection_range_nested_chain :: proc(t: ^testing.T) {
	source := `
		функ квадрат(n: Целое) -> Целое
			n * n
		конец
	`
	tokens, _ := tokenize(source)
	stream := make_stream(tokens)
	parser := Parser{stream = &stream}
	prog := parse_program(&parser)

	// Offset на первом "n" внутри "n * n".
	offset := u32(strings.index(source, "n * n"))
	spans := collect_selection_spans(prog, 0, offset)
	defer delete(spans)

	testing.expectf(t, len(spans) >= 2, "[selection range] ожидалось минимум 2 уровня (декларация + выражение), получено %d", len(spans))
	if len(spans) >= 2 {
		outer := spans[0]
		inner := spans[len(spans) - 1]
		testing.expectf(
			t,
			outer.start <= inner.start && outer.end >= inner.end,
			"[selection range] внешний span должен содержать внутренний: outer=%v inner=%v",
			outer,
			inner,
		)
	}
}
