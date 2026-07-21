#+build !js
package core

import "core:testing"

// `&Имя` — компилятор просто прикрепляет её к декларации, не вычисляет и не
// проверяет (см. parser.odin::parse_annotations). Один positional-кейс без
// аргументов на структуре.
@(test)
test_annotation_attaches_to_struct :: proc(t: ^testing.T) {
	tokens, _ := tokenize(`
		&Json
		тип Точка = структура
			x: Число
		конец
	`)
	stream := make_stream(tokens)
	parser := Parser{stream = &stream}
	prog := parse_program(&parser)

	testing.expectf(t, len(parser.diagnostics) == 0, "[annotation: struct] неожиданные diagnostics: %v", parser.diagnostics)
	testing.expectf(t, len(prog.decls) == 1, "[annotation: struct] ожидалась 1 декларация, получено %d", len(prog.decls))
	if len(prog.decls) != 1 do return

	s, ok := prog.decls[0].(^Struct_Decl)
	testing.expectf(t, ok, "[annotation: struct] ожидалась Struct_Decl")
	if !ok do return
	testing.expectf(t, len(s.annotations) == 1, "[annotation: struct] ожидалась 1 аннотация, получено %d", len(s.annotations))
	if len(s.annotations) != 1 do return
	testing.expectf(t, s.annotations[0].name == "Json", "[annotation: struct] получено имя %q", s.annotations[0].name)
	testing.expectf(t, len(s.annotations[0].args) == 0, "[annotation: struct] ожидалось 0 аргументов")
}

// Позиционные и именованные аргументы в одной аннотации на функции.
@(test)
test_annotation_positional_and_named_args :: proc(t: ^testing.T) {
	tokens, _ := tokenize(`
		&Route("/users", метод = "GET", включено = истина)
		функ обработчик() -> Целое
			1
		конец
	`)
	stream := make_stream(tokens)
	parser := Parser{stream = &stream}
	prog := parse_program(&parser)

	testing.expectf(t, len(parser.diagnostics) == 0, "[annotation: args] неожиданные diagnostics: %v", parser.diagnostics)
	testing.expectf(t, len(prog.decls) == 1, "[annotation: args] ожидалась 1 декларация")
	if len(prog.decls) != 1 do return

	fn, ok := prog.decls[0].(^Function_Decl)
	testing.expectf(t, ok, "[annotation: args] ожидалась Function_Decl")
	if !ok do return
	testing.expectf(t, len(fn.annotations) == 1, "[annotation: args] ожидалась 1 аннотация")
	if len(fn.annotations) != 1 do return

	ann := fn.annotations[0]
	testing.expectf(t, ann.name == "Route", "[annotation: args] получено имя %q", ann.name)
	testing.expectf(t, len(ann.args) == 3, "[annotation: args] ожидалось 3 аргумента, получено %d", len(ann.args))
	if len(ann.args) != 3 do return

	testing.expectf(t, ann.args[0].name == "" && ann.args[0].value.kind == .String && ann.args[0].value.text == "/users",
		"[annotation: args] позиционный аргумент: %v", ann.args[0])
	testing.expectf(t, ann.args[1].name == "метод" && ann.args[1].value.kind == .String && ann.args[1].value.text == "GET",
		"[annotation: args] именованный строковый аргумент: %v", ann.args[1])
	testing.expectf(t, ann.args[2].name == "включено" && ann.args[2].value.kind == .Boolean,
		"[annotation: args] именованный булев аргумент: %v", ann.args[2])
}

// Несколько аннотаций подряд, каждая на своей строке — накапливаются по
// порядку в одном срезе.
@(test)
test_annotation_stacking :: proc(t: ^testing.T) {
	tokens, _ := tokenize(`
		&Json
		&Устарело("используйте Новый")
		тип Старый = структура
			x: Число
		конец
	`)
	stream := make_stream(tokens)
	parser := Parser{stream = &stream}
	prog := parse_program(&parser)

	testing.expectf(t, len(parser.diagnostics) == 0, "[annotation: stacking] неожиданные diagnostics: %v", parser.diagnostics)
	if len(prog.decls) != 1 do return
	s, ok := prog.decls[0].(^Struct_Decl)
	testing.expectf(t, ok && len(s.annotations) == 2, "[annotation: stacking] ожидалось 2 аннотации, получено %d", ok ? len(s.annotations) : -1)
	if !ok || len(s.annotations) != 2 do return
	testing.expectf(t, s.annotations[0].name == "Json", "[annotation: stacking] #0 получено %q", s.annotations[0].name)
	testing.expectf(t, s.annotations[1].name == "Устарело", "[annotation: stacking] #1 получено %q", s.annotations[1].name)
}

// Аннотация на отдельном поле структуры, не на всей декларации.
@(test)
test_annotation_attaches_to_field :: proc(t: ^testing.T) {
	tokens, _ := tokenize(`
		тип Точка = структура
			&Json("id")
			x: Число
			y: Число
		конец
	`)
	stream := make_stream(tokens)
	parser := Parser{stream = &stream}
	prog := parse_program(&parser)

	testing.expectf(t, len(parser.diagnostics) == 0, "[annotation: field] неожиданные diagnostics: %v", parser.diagnostics)
	if len(prog.decls) != 1 do return
	s, ok := prog.decls[0].(^Struct_Decl)
	testing.expectf(t, ok && len(s.fields) == 2, "[annotation: field] ожидалось 2 поля")
	if !ok || len(s.fields) != 2 do return

	testing.expectf(t, len(s.fields[0].annotations) == 1 && s.fields[0].annotations[0].name == "Json",
		"[annotation: field] поле 'x' получено %v", s.fields[0].annotations)
	testing.expectf(t, len(s.fields[1].annotations) == 0, "[annotation: field] поле 'y' не должно иметь аннотаций")
}

// Битовое И (`&`, .Ampersand) в теле функции по-прежнему разбирается как
// оператор, а не как начало аннотации — эти два разбора живут в
// непересекающихся позициях (см. parse_annotations докstring).
@(test)
test_ampersand_still_works_as_bitwise_and :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ старт() -> Целое
			пер a: Целое = 12
			пер b: Целое = 10
			a & b
		конец
	`)
	testing.expectf(t, ok, "[annotation: & disambiguation] стек пуст")
	if ok {
		n, is_num := result.(f64)
		testing.expectf(t, is_num && n == 8, "[annotation: & disambiguation] ожидалось 8, получено %v", result)
	}
}

// Негатив: '&' без имени следом — не годится, диагностика.
@(test)
test_annotation_missing_name_is_error :: proc(t: ^testing.T) {
	tokens, _ := tokenize(`
		&(1)
		функ f() -> Целое
			1
		конец
	`)
	stream := make_stream(tokens)
	parser := Parser{stream = &stream}
	_ = parse_program(&parser)
	expect_diagnostic(t, parser.diagnostics, "Синтаксическая ошибка: после '&' ожидается имя аннотации, получено: LParen")
}

// Негатив: аннотации не допускаются перед `импорт`.
@(test)
test_annotation_on_import_is_error :: proc(t: ^testing.T) {
	tokens, _ := tokenize(`
		&Json
		импорт строки
	`)
	stream := make_stream(tokens)
	parser := Parser{stream = &stream}
	_ = parse_program(&parser)
	expect_diagnostic(t, parser.diagnostics, "Синтаксическая ошибка: аннотации недопустимы для импорта")
}
