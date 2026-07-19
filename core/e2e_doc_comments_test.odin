#+build !js
package core

import "core:testing"

// `///` docstring, вплотную над декларацией — попадает в Function_Decl.doc
// (Token.doc, см. skip_whitespace_and_comments в lexer.odin). Обычный `//`
// в языке никогда не порождал токена для своего текста — `///` первый
// случай, когда содержимое комментария переживает лексер.
@(test)
test_doc_comment_attaches_to_function :: proc(t: ^testing.T) {
	tokens, _ := tokenize(`
		/// Складывает два числа.
		/// Возвращает их сумму.
		функ сложить(a: Число, b: Число) -> Число
			a + b
		конец
	`)
	stream := make_stream(tokens)
	parser := Parser{stream = &stream}
	prog := parse_program(&parser)

	testing.expectf(t, len(prog.decls) == 1, "[doc: функция] ожидалась 1 декларация, получено %d", len(prog.decls))
	if len(prog.decls) != 1 do return
	fn, ok := prog.decls[0].(^Function_Decl)
	testing.expectf(t, ok, "[doc: функция] ожидалась Function_Decl")
	if ok {
		testing.expectf(
			t,
			fn.doc == "Складывает два числа.\nВозвращает их сумму.",
			"[doc: функция] получено %q",
			fn.doc,
		)
	}
}

// Докстринг над `экспорт функ` — висит на токене `экспорт` (первом токене
// всей декларации), не на `функ» — parse_program обязан забрать его ДО
// того, как съест .Export (см. её комментарий).
@(test)
test_doc_comment_attaches_across_export :: proc(t: ^testing.T) {
	tokens, _ := tokenize(`
		/// Публичная функция.
		экспорт функ f() -> Целое
			1
		конец
	`)
	stream := make_stream(tokens)
	parser := Parser{stream = &stream}
	prog := parse_program(&parser)

	testing.expectf(t, len(prog.decls) == 1, "[doc: export] ожидалась 1 декларация")
	if len(prog.decls) != 1 do return
	fn, ok := prog.decls[0].(^Function_Decl)
	testing.expectf(t, ok && fn.is_exported, "[doc: export] ожидалась экспортированная Function_Decl")
	if ok {
		testing.expectf(t, fn.doc == "Публичная функция.", "[doc: export] получено %q", fn.doc)
	}
}

// Пустая строка МЕЖДУ докстрингом и декларацией рвёт привязку — это
// сознательно обычный, "висящий в воздухе" комментарий, а не докстринг.
@(test)
test_doc_comment_blank_line_breaks_attachment :: proc(t: ^testing.T) {
	tokens, _ := tokenize(`
		/// Этот комментарий отделён пустой строкой.

		функ f() -> Целое
			1
		конец
	`)
	stream := make_stream(tokens)
	parser := Parser{stream = &stream}
	prog := parse_program(&parser)

	testing.expectf(t, len(prog.decls) == 1, "[doc: blank line] ожидалась 1 декларация")
	if len(prog.decls) != 1 do return
	fn, ok := prog.decls[0].(^Function_Decl)
	testing.expectf(t, ok, "[doc: blank line] ожидалась Function_Decl")
	if ok {
		testing.expectf(t, fn.doc == "", "[doc: blank line] ожидалось пусто, получено %q", fn.doc)
	}
}

// Обычный `//` (не `///`) — рвёт цепочку докстринга, как и раньше не
// порождая никакого текста.
@(test)
test_plain_comment_does_not_attach :: proc(t: ^testing.T) {
	tokens, _ := tokenize(`
		// обычный комментарий
		функ f() -> Целое
			1
		конец
	`)
	stream := make_stream(tokens)
	parser := Parser{stream = &stream}
	prog := parse_program(&parser)

	testing.expectf(t, len(prog.decls) == 1, "[doc: plain //] ожидалась 1 декларация")
	if len(prog.decls) != 1 do return
	fn, ok := prog.decls[0].(^Function_Decl)
	testing.expectf(t, ok, "[doc: plain //] ожидалась Function_Decl")
	if ok {
		testing.expectf(t, fn.doc == "", "[doc: plain //] ожидалось пусто, получено %q", fn.doc)
	}
}

// Докстринг над структурой/интерфейсом/перечислением — та же side-table
// схема, что у функций (Struct_Decl.doc/Interface_Decl.doc/Enum_Decl.doc).
@(test)
test_doc_comment_attaches_to_struct_interface_enum :: proc(t: ^testing.T) {
	tokens, _ := tokenize(`
		/// Точка на плоскости.
		тип Точка = структура
			x: Число
		конец

		/// Умеет сравнивать себя.
		тип Упорядоченное = интерфейс
			функ меньше(другое: Упорядоченное) -> Булево
		конец

		/// Результат операции.
		тип Исход = перечисление
			Успех
			Провал
		конец
	`)
	stream := make_stream(tokens)
	parser := Parser{stream = &stream}
	prog := parse_program(&parser)

	testing.expectf(t, len(prog.decls) == 3, "[doc: struct/iface/enum] ожидалось 3 декларации, получено %d", len(prog.decls))
	if len(prog.decls) != 3 do return

	s, s_ok := prog.decls[0].(^Struct_Decl)
	testing.expectf(t, s_ok && s.doc == "Точка на плоскости.", "[doc: struct] получено %q", s_ok ? s.doc : "<not struct>")

	i, i_ok := prog.decls[1].(^Interface_Decl)
	testing.expectf(t, i_ok && i.doc == "Умеет сравнивать себя.", "[doc: interface] получено %q", i_ok ? i.doc : "<not interface>")

	e, e_ok := prog.decls[2].(^Enum_Decl)
	testing.expectf(t, e_ok && e.doc == "Результат операции.", "[doc: enum] получено %q", e_ok ? e.doc : "<not enum>")
}
