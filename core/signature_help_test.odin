#+build !js
package core

import "core:strings"
import "core:testing"

// compute_signature_help: находит охватывающий Call_Expr, достаёт имена
// параметров (Symbol.decl -> Function_Decl.args) и активный параметр по
// позиции курсора среди уже переданных аргументов.
@(test)
test_signature_help_active_parameter :: proc(t: ^testing.T) {
	source := `
		функ сложить(а: Целое, б: Целое) -> Целое
			а + б
		конец

		функ старт() -> Целое
			сложить(1, 2)
		конец
	`
	tokens, _ := tokenize(source)
	stream := make_stream(tokens)
	parser := Parser{stream = &stream}
	prog := parse_program(&parser)

	res_ctx := new_resolver_ctx()
	resolve_program(&res_ctx, prog)
	type_ctx := new_type_ctx(&res_ctx)
	typecheck_program(&type_ctx, prog)

	// Позиция сразу после "сложить(" в ТЕЛЕ вызова (не в списке параметров
	// декларации выше — та тоже начинается с "сложить(", strings.index
	// нашёл бы её первой).
	open_paren_offset := u32(strings.index(source, "сложить(1, 2)") + len("сложить("))
	info, ok := compute_signature_help(&res_ctx, &type_ctx, prog, 0, open_paren_offset)
	testing.expect(t, ok, "[signature help] ожидался найденный Call_Expr сразу после '('")
	if ok {
		testing.expectf(t, info.active_param == 0, "[signature help] ожидался active_param == 0 сразу после '(', получено %d", info.active_param)
		testing.expectf(t, len(info.params) == 2, "[signature help] ожидалось 2 параметра, получено %d", len(info.params))
	}

	// Позиция сразу после запятой второго аргумента (", " перед "2").
	second_arg_offset := u32(strings.index(source, ", 2") + len(", "))
	info2, ok2 := compute_signature_help(&res_ctx, &type_ctx, prog, 0, second_arg_offset)
	testing.expect(t, ok2, "[signature help] ожидался найденный Call_Expr перед вторым аргументом")
	if ok2 {
		testing.expectf(t, info2.active_param == 1, "[signature help] ожидался active_param == 1 перед вторым аргументом, получено %d", info2.active_param)
	}
}
