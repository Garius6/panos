#+build !js
package core

import "core:fmt"

// синтаксис::* — compile-time АСТ-интроспекция ДРУГОГО .ps файла (не текущей
// программы) для codegen-инструментов, написанных на panos (см. specs/004
// обсуждение аннотаций). Принципиально НЕ рантайм-рефлексия: не трогает
// представление значений VM, не даёт доступ по имени к полям живого
// объекта — просто гоняет уже существующий core.tokenize/parse_program по
// тексту файла, как это уже делает LSP (lsp/lsp_server.odin), только теперь
// доступно и panos-скрипту, не только Odin-коду.
//
// Без персистентного хендла (в отличие от Файл/Соединение) — каждый вызов
// заново читает и парсит путь. Для build-time инструмента, гоняемого по
// одному небольшому .ps файлу за раз, это не hot path — цена повторного
// парсинга принята ради того, чтобы не заводить новый Type_Kind/Value-
// вариант/GC-трассировку/method-dispatch только под этот один сценарий
// (см. ос::выполнить — тот же принцип "плоские данные вместо именованной
// структуры" в stdlib.odin).

// ok=false — либо файл не прочитать (err_msg от read_file_text), либо в нём
// синтаксическая ошибка (err_msg — первая diagnostic, лексер или парсер).
parse_syntax_file :: proc(path: string) -> (prog: Program, err_msg: string, ok: bool) {
	content, read_err, read_ok := read_file_text(path)
	if !read_ok {
		return Program{}, read_err, false
	}
	tokens, lex_diags := tokenize(content)
	stream := make_stream(tokens)
	parser := Parser{stream = &stream}
	prog = parse_program(&parser)
	if len(lex_diags) > 0 {
		return Program{}, lex_diags[0].message, false
	}
	if len(parser.diagnostics) > 0 {
		return Program{}, parser.diagnostics[0].message, false
	}
	return prog, "", true
}

find_struct_decl :: proc(prog: Program, name: string) -> ^Struct_Decl {
	for decl in prog.decls {
		if s, is_struct := decl.(^Struct_Decl); is_struct && s.name == name do return s
	}
	return nil
}

find_field_decl :: proc(s: ^Struct_Decl, name: string) -> ^Field_Decl {
	for i := 0; i < len(s.fields); i += 1 {
		if s.fields[i].name == name do return &s.fields[i]
	}
	return nil
}

// Общая голова у всех шести синтаксис::* вызовов: распарсить путь, найти
// структуру по имени, обернуть обе возможные неудачи в один и тот же
// Результат(_, Ошибка) — дальше каждый case решает, что делать со `s`.
resolve_syntax_struct :: proc(vm: ^VM, path: string, struct_name: string) -> (s: ^Struct_Decl, err_result: Value, failed: bool) {
	prog, err_msg, parse_ok := parse_syntax_file(path)
	if !parse_ok {
		return nil, make_error_result(vm, make_error_value(vm, "синтаксис", err_msg)), true
	}
	found := find_struct_decl(prog, struct_name)
	if found == nil {
		return nil, make_error_result(
			vm,
			make_error_value(vm, "синтаксис", fmt.tprintf("структура '%s' не найдена в '%s'", struct_name, path)),
		), true
	}
	return found, nil, false
}

annotation_names_array :: proc(vm: ^VM, annotations: [dynamic]Annotation) -> Value {
	arr := gc_new(vm, Array_Value)
	gc_protect(vm, Value(arr))
	for ann in annotations {
		append(&arr.elements, Value(gc_new_string(vm, ann.name)))
	}
	gc_unprotect(vm, 1)
	return Value(arr)
}

annotation_arg_option :: proc(vm: ^VM, annotations: [dynamic]Annotation, ann_name: string) -> Value {
	opt := gc_new(vm, Option_Value)
	gc_protect(vm, Value(opt))
	if arg_text, has_arg := annotation_string_arg(find_annotation(annotations, ann_name)); has_arg {
		opt.has_value = true
		opt.value = Value(gc_new_string(vm, arg_text))
	} else {
		opt.has_value = false
		opt.value = f64(0)
	}
	gc_unprotect(vm, 1)
	return Value(opt)
}

call_builtin_syntax :: proc(vm: ^VM, name: string, args: []Value) -> (result: Value, ok: bool, handled: bool) {
	switch name {
	case "синтаксис::структуры":
		expect_arg_count(name, len(args), 1)
		path := expect_string_arg(name, args[0])
		prog, err_msg, parse_ok := parse_syntax_file(path)
		if !parse_ok {
			return make_error_result(vm, make_error_value(vm, "синтаксис", err_msg)), true, true
		}
		arr := gc_new(vm, Array_Value)
		gc_protect(vm, Value(arr))
		for decl in prog.decls {
			if s, is_struct := decl.(^Struct_Decl); is_struct {
				append(&arr.elements, Value(gc_new_string(vm, s.name)))
			}
		}
		gc_unprotect(vm, 1)
		return make_ok_result(vm, Value(arr)), true, true

	case "синтаксис::поля":
		expect_arg_count(name, len(args), 2)
		path := expect_string_arg(name, args[0])
		struct_name := expect_string_arg(name, args[1])
		s, err_result, failed := resolve_syntax_struct(vm, path, struct_name)
		if failed do return err_result, true, true

		arr := gc_new(vm, Array_Value)
		gc_protect(vm, Value(arr))
		for field in s.fields {
			pair := gc_new(vm, Aggregate_Value)
			resize(&pair.elements, 2)
			pair.elements[0] = Value(gc_new_string(vm, field.name))
			pair.elements[1] = Value(gc_new_string(vm, type_node_to_string(field.type_annotation)))
			append(&arr.elements, Value(pair))
		}
		gc_unprotect(vm, 1)
		return make_ok_result(vm, Value(arr)), true, true

	case "синтаксис::аннотации":
		expect_arg_count(name, len(args), 2)
		path := expect_string_arg(name, args[0])
		struct_name := expect_string_arg(name, args[1])
		s, err_result, failed := resolve_syntax_struct(vm, path, struct_name)
		if failed do return err_result, true, true
		return make_ok_result(vm, annotation_names_array(vm, s.annotations)), true, true

	case "синтаксис::аргумент_аннотации":
		expect_arg_count(name, len(args), 3)
		path := expect_string_arg(name, args[0])
		struct_name := expect_string_arg(name, args[1])
		ann_name := expect_string_arg(name, args[2])
		s, err_result, failed := resolve_syntax_struct(vm, path, struct_name)
		if failed do return err_result, true, true
		return make_ok_result(vm, annotation_arg_option(vm, s.annotations, ann_name)), true, true

	case "синтаксис::аннотации_поля":
		expect_arg_count(name, len(args), 3)
		path := expect_string_arg(name, args[0])
		struct_name := expect_string_arg(name, args[1])
		field_name := expect_string_arg(name, args[2])
		s, err_result, failed := resolve_syntax_struct(vm, path, struct_name)
		if failed do return err_result, true, true
		field := find_field_decl(s, field_name)
		if field == nil {
			return make_error_result(
				vm,
				make_error_value(vm, "синтаксис", fmt.tprintf("поле '%s' не найдено у структуры '%s'", field_name, struct_name)),
			), true, true
		}
		return make_ok_result(vm, annotation_names_array(vm, field.annotations)), true, true

	case "синтаксис::аргумент_аннотации_поля":
		expect_arg_count(name, len(args), 4)
		path := expect_string_arg(name, args[0])
		struct_name := expect_string_arg(name, args[1])
		field_name := expect_string_arg(name, args[2])
		ann_name := expect_string_arg(name, args[3])
		s, err_result, failed := resolve_syntax_struct(vm, path, struct_name)
		if failed do return err_result, true, true
		field := find_field_decl(s, field_name)
		if field == nil {
			return make_error_result(
				vm,
				make_error_value(vm, "синтаксис", fmt.tprintf("поле '%s' не найдено у структуры '%s'", field_name, struct_name)),
			), true, true
		}
		return make_ok_result(vm, annotation_arg_option(vm, field.annotations, ann_name)), true, true
	}
	return
}
