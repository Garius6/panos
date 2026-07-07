package main

import "core:fmt"
import "core:strconv"

Parser :: struct {
	stream: ^TokenStream,
}

Parser_Error :: enum {
	Cannot,
}

Function_Decl :: struct {
	name:        string,
	args:        [dynamic]Param_Decl,
	return_type: Type_Node,
	body:        [dynamic]Stmt,
	is_exported: bool,
}

Param_Decl :: struct {
	name:            string,
	type_annotation: Type_Node,
}

Method_Signature :: struct {
	name:        string,
	args:        [dynamic]Param_Decl,
	return_type: Type_Node,
}

Interface_Decl :: struct {
	name:        string,
	methods:     [dynamic]Method_Signature,
	is_exported: bool,
}

Field_Decl :: struct {
	name:            string,
	type_annotation: Type_Node,
}

Struct_Decl :: struct {
	name:        string,
	fields:      [dynamic]Field_Decl,
	is_exported: bool,
}

Import_Decl :: struct {
	path:  string,
	alias: string,
}

Variant_Decl :: struct {
	name:  string,
	types: [dynamic]Type_Node,
}

Enum_Decl :: struct {
	name:        string,
	variants:    [dynamic]Variant_Decl,
	is_exported: bool,
}

Impl_Decl :: struct {
	interface_name: string,
	target_type:    string,
	methods:        [dynamic]^Function_Decl,
}

Decls :: union {
	^Import_Decl,
	^Function_Decl,
	^Struct_Decl,
	^Impl_Decl,
	^Interface_Decl,
	^Enum_Decl,
}

Program :: struct {
	decls: [dynamic]Decls,
}

Type_Generic :: struct {
	name:   string,
	params: [dynamic]Type_Node,
}

Type_Qualified :: struct {
	module_name: string,
	name:        string,
}

Type_Node :: union {
	^Type_Ident,
	^Type_Tuple,
	^Type_Function,
	^Type_Qualified,
	^Type_Generic, // Заменяет Type_Array и Type_Map
}

Type_Function :: struct {
	params:      [dynamic]Type_Node,
	return_type: Type_Node,
}

Type_Ident :: struct {
	name: string,
}

Type_Tuple :: struct {
	elements: [dynamic]Type_Node,
}

Stmt :: union {
	^Return_Stmt,
	^Let_Stmt,
	^Expr_Stmt,
	^Continue_Stmt,
	^Break_Stmt,
}

Return_Stmt :: struct {
	value: Expr,
}

Let_Stmt :: struct {
	name:            string,
	value:           Expr,
	type_annotation: Type_Node,
}

Expr_Stmt :: struct {
	expr: Expr,
}

Continue_Stmt :: struct {}

Break_Stmt :: struct {}

Pattern_Wildcard :: struct {}
Pattern_Literal :: struct {
	value: Expr,
}
Pattern_Ident :: struct {
	name: string,
}
Pattern_Constructor :: struct {
	module_name: string,
	name:        string,
	args:        [dynamic]Pattern,
}

Pattern :: union {
	^Pattern_Wildcard,
	^Pattern_Literal,
	^Pattern_Ident,
	^Pattern_Constructor,
}

Match_Arm :: struct {
	pattern: Pattern,
	body:    [dynamic]Stmt,
}

Match_Expr :: struct {
	subject: Expr,
	arms:    [dynamic]Match_Arm,
}

Ident_Expr :: struct {
	name: string,
}

Unary_Expr :: struct {
	op:    TokenKind,
	right: Expr,
}

Number_Expr :: struct {
	value: f64,
}

Boolean_Expr :: struct {
	value: bool,
}

String_Expr :: struct {
	value: string,
}

Binary_Expr :: struct {
	left:  Expr,
	op:    TokenKind, // Теперь может быть .Assign (=)
	right: Expr,
}

Call_Expr :: struct {
	args:   [dynamic]Expr,
	callee: Expr,
}

Property_Expr :: struct {
	object:   Expr,
	property: string,
}

If_Expr :: struct {
	condition:   Expr,
	then_branch: [dynamic]Stmt,
	else_branch: [dynamic]Stmt,
}

While_Expr :: struct {
	condition: Expr,
	body:      [dynamic]Stmt,
}

Tuple_Expr :: struct {
	elements: [dynamic]Expr,
}

Lambda_Expr :: struct {
	args:        [dynamic]Param_Decl,
	return_type: Type_Node,
	body:        [dynamic]Stmt,
}

Array_Expr :: struct {
	elements: [dynamic]Expr,
}

Map_Entry_Expr :: struct {
	key:   Expr,
	value: Expr,
}

Map_Expr :: struct {
	entries: [dynamic]Map_Entry_Expr,
}

Index_Expr :: struct {
	object: Expr,
	index:  Expr,
}

Try_Expr :: struct {
	value: Expr,
}

Expr :: union {
	^Number_Expr,
	^Boolean_Expr,
	^String_Expr,
	^Binary_Expr,
	^Unary_Expr,
	^Ident_Expr,
	^Call_Expr,
	^While_Expr,
	^If_Expr,
	^Tuple_Expr,
	^Property_Expr,
	^Lambda_Expr,
	^Array_Expr,
	^Map_Expr,
	^Index_Expr,
	^Try_Expr,
	^Match_Expr,
}

// --- ПЕЧАТЬ AST ---

print_program :: proc(prog: Program) {
	fmt.println("Program")
	for decl in prog.decls {
		print_decl(decl)
	}
}

print_decl :: proc(decl: Decls) {
	#partial switch d in decl {
	case ^Import_Decl:
		if d.alias != "" {
			fmt.printf("Import (%s as %s)\n", d.path, d.alias)
		} else {
			fmt.printf("Import (%s)\n", d.path)
		}
	case ^Function_Decl:
		fmt.printf("%sFunction (%s)\n", d.is_exported ? "Export " : "", d.name)
		for stmt, i in d.body {
			is_last := i == len(d.body) - 1
			print_stmt(stmt, "", is_last)
		}
	case ^Struct_Decl:
		fmt.printf("%sStruct (%s)\n", d.is_exported ? "Export " : "", d.name)
		for field, i in d.fields {
			is_last := i == len(d.fields) - 1
			print_field(field, "", is_last)
		}
	case ^Impl_Decl:
		fmt.printf("Impl (%s)\n", d.target_type)
	case ^Interface_Decl:
		fmt.printf("%sInterface (%s)\n", d.is_exported ? "Export " : "", d.name)
	}
}

print_field :: proc(field: Field_Decl, prefix: string = "", is_last: bool = true) {
	marker := is_last ? "└── " : "├── "
	fmt.printf("%s%sField(%s)\n", prefix, marker, field.name)
}

print_stmt :: proc(stmt: Stmt, prefix: string = "", is_last: bool = true) {
	if stmt == nil do return

	marker := is_last ? "└── " : "├── "
	next_prefix := fmt.tprintf("%s%s", prefix, is_last ? "    " : "│   ")

	switch s in stmt {
	case ^Let_Stmt:
		fmt.printf("%s%sLet(%s)\n", prefix, marker, s.name)
		print_ast(s.value, next_prefix, true)

	case ^Return_Stmt:
		fmt.printf("%s%sReturn\n", prefix, marker)
		if s.value != nil {
			print_ast(s.value, next_prefix, true)
		}

	case ^Expr_Stmt:
		fmt.printf("%s%sExpr_Stmt\n", prefix, marker)
		print_ast(s.expr, next_prefix, true)

	case ^Continue_Stmt:
		fmt.printf("%s%sContinue\n", prefix, marker)

	case ^Break_Stmt:
		fmt.printf("%s%sBreak\n", prefix, marker)
	}
}

print_ast :: proc(expr: Expr, prefix: string = "", is_last: bool = true) {
	if expr == nil do return

	marker := is_last ? "└── " : "├── "
	next_prefix_base := is_last ? "    " : "│   "
	next_prefix := fmt.tprintf("%s%s", prefix, next_prefix_base)

	#partial switch e in expr {
	case ^Number_Expr:
		fmt.printf("%s%sNumber(%v)\n", prefix, marker, e.value)
	case ^Boolean_Expr:
		fmt.printf("%s%sBoolean(%v)\n", prefix, marker, e.value)
	case ^String_Expr:
		fmt.printf("%s%sString(\"%s\")\n", prefix, marker, e.value)
	case ^Unary_Expr:
		fmt.printf("%s%sUnary(%v)\n", prefix, marker, e.op)
		print_ast(e.right, next_prefix, true)
	case ^Binary_Expr:
		fmt.printf("%s%sBinary(%v)\n", prefix, marker, e.op)
		print_ast(e.left, next_prefix, false)
		print_ast(e.right, next_prefix, true)
	case ^Ident_Expr:
		fmt.printf("%s%sIdent(%v)\n", prefix, marker, e.name)
	case ^Call_Expr:
		fmt.printf("%s%sCall()\n", prefix, marker)
		print_ast(e.callee, next_prefix, false)
		for arg, i in e.args {
			print_ast(arg, next_prefix, i == len(e.args) - 1)
		}
	case ^While_Expr:
		fmt.printf("%s%sWhile()\n", prefix, marker)
		print_ast(e.condition, next_prefix, false)
		for stmt, i in e.body {
			print_stmt(stmt, next_prefix, i == len(e.body) - 1)
		}
	case ^If_Expr:
		fmt.printf("%s%sIf()\n", prefix, marker)
		print_ast(e.condition, next_prefix, false)
		for stmt in e.then_branch {
			print_stmt(stmt, next_prefix, false)
		}
		for stmt, i in e.else_branch {
			print_stmt(stmt, next_prefix, i == len(e.else_branch) - 1)
		}
	case ^Tuple_Expr:
		fmt.printf("%s%sTuple()\n", prefix, marker)
		for el, i in e.elements {
			print_ast(el, next_prefix, i == len(e.elements) - 1)
		}
	case ^Property_Expr:
		fmt.printf("%s%sProperty(%s)\n", prefix, marker, e.property)
		print_ast(e.object, next_prefix, true)
	case ^Lambda_Expr:
		fmt.printf("%s%sLambda()\n", prefix, marker)
		for stmt, i in e.body {
			print_stmt(stmt, next_prefix, i == len(e.body) - 1)
		}
	case ^Array_Expr:
		fmt.printf("%s%sArray()\n", prefix, marker)
		for el, i in e.elements {
			print_ast(el, next_prefix, i == len(e.elements) - 1)
		}
	case ^Map_Expr:
		fmt.printf("%s%sMap()\n", prefix, marker)
		for entry, i in e.entries {
			entry_marker := i == len(e.entries) - 1 ? "└── " : "├── "
			entry_prefix := fmt.tprintf(
				"%s%s",
				next_prefix,
				i == len(e.entries) - 1 ? "    " : "│   ",
			)
			fmt.printf("%s%sEntry\n", next_prefix, entry_marker)
			print_ast(entry.key, entry_prefix, false)
			print_ast(entry.value, entry_prefix, true)
		}
	case ^Index_Expr:
		fmt.printf("%s%sIndex()\n", prefix, marker)
		print_ast(e.object, next_prefix, false)
		print_ast(e.index, next_prefix, true)
	case ^Try_Expr:
		fmt.printf("%s%sTry(?)\n", prefix, marker)
		print_ast(e.value, next_prefix, true)
	}
}

// --- ПАРСИНГ ВЕРХНЕГО УРОВНЯ ---

parse_program :: proc(p: ^Parser) -> Program {
	prog := Program {
		decls = make([dynamic]Decls),
	}

	for peek_token(p.stream).kind != .EOF {
		is_exported := false
		if peek_token(p.stream).kind == .Export {
			next_token(p.stream)
			is_exported = true
		}

		tok_kind := peek_token(p.stream).kind
		if tok_kind == .Import {
			if is_exported {
				fmt.panicf(
					"Синтаксическая ошибка: нельзя экспортировать импорт",
				)
			}
			decl := parse_import_decl(p)
			append(&prog.decls, decl)
		} else if tok_kind == .Function {
			decl := parse_function(p, is_exported)
			append(&prog.decls, decl)
		} else if tok_kind == .TypeDecl {
			third_kind := p.stream.tokens[p.stream.current_idx + 3].kind
			if third_kind == .Struct {
				decl := parse_struct_decl(p, is_exported)
				append(&prog.decls, decl)
			} else if third_kind == .Enum {
				decl := parse_enum_decl(p, is_exported)
				append(&prog.decls, decl)
			} else if third_kind == .Interface {
				decl := parse_interface_decl(p, is_exported)
				append(&prog.decls, decl)
			} else {
				fmt.panicf(
					"Синтаксическая ошибка: после 'тип X =' ожидалось 'структура', 'интерфейс' или 'перечисление', получено: %v",
					third_kind,
				)
			}
		} else if tok_kind == .Impl {
			if is_exported {
				fmt.panicf(
					"Синтаксическая ошибка: реализация не может быть экспортирована",
				)
			}
			decl := parse_impl_decl(p)
			append(&prog.decls, decl)
		} else {
			fmt.panicf(
				"Ожидалось объявление, импорт или экспорт, получено: %v",
				tok_kind,
			)
		}
	}
	return prog
}

parse_import_decl :: proc(p: ^Parser) -> ^Import_Decl {
	expect(p, .Import)
	decl := new(Import_Decl)

	path_tok := next_token(p.stream)
	if path_tok.kind != .Ident && path_tok.kind != .String {
		fmt.panicf(
			"Синтаксическая ошибка: после 'импорт' ожидается имя модуля или строка пути",
		)
	}
	decl.path = path_tok.data

	if peek_token(p.stream).kind == .As {
		next_token(p.stream)
		alias_tok := next_token(p.stream)
		if alias_tok.kind != .Ident {
			fmt.panicf(
				"Синтаксическая ошибка: после 'как' ожидается имя псевдонима",
			)
		}
		decl.alias = alias_tok.data
	}

	consume_semicolon_or_newline(p)
	return decl
}

parse_enum_decl :: proc(p: ^Parser, is_exported: bool) -> ^Enum_Decl {
	expect(p, .TypeDecl)

	name_tok := next_token(p.stream)
	if name_tok.kind != .Ident {
		fmt.panicf(
			"Синтаксическая ошибка: после 'тип' ожидалось имя перечисления, получено: %v",
			name_tok.kind,
		)
	}

	decl := new(Enum_Decl)
	decl.name = name_tok.data
	decl.is_exported = is_exported
	decl.variants = make([dynamic]Variant_Decl)

	expect(p, .Assign)
	expect(p, .Enum)

	seen := make(map[string]bool)
	defer delete(seen)

	for peek_token(p.stream).kind != .End && peek_token(p.stream).kind != .EOF {
		variant_tok := next_token(p.stream)
		if variant_tok.kind != .Ident {
			fmt.panicf(
				"Синтаксическая ошибка: в перечислении '%s' ожидалось имя варианта, получено: %v",
				decl.name,
				variant_tok.kind,
			)
		}
		if seen[variant_tok.data] {
			fmt.panicf(
				"Синтаксическая ошибка: вариант '%s' объявлен дважды в '%s'",
				variant_tok.data,
				decl.name,
			)
		}
		seen[variant_tok.data] = true

		variant := Variant_Decl {
			name  = variant_tok.data,
			types = make([dynamic]Type_Node),
		}

		if peek_token(p.stream).kind == .LParen {
			next_token(p.stream) // (
			if peek_token(p.stream).kind == .RParen {
				fmt.panicf(
					"Синтаксическая ошибка: у варианта '%s.%s' должны быть либо параметры в скобках, либо скобки должны отсутствовать",
					decl.name,
					variant_tok.data,
				)
			}
			for {
				append(&variant.types, parse_type(p))
				if peek_token(p.stream).kind == .Comma {
					next_token(p.stream)
					continue
				}
				break
			}
			expect(p, .RParen)
		}

		append(&decl.variants, variant)
		consume_semicolon_or_newline(p)
	}

	expect(p, .End)

	if len(decl.variants) == 0 {
		fmt.panicf(
			"Синтаксическая ошибка: перечисление '%s' должно объявлять хотя бы один вариант",
			decl.name,
		)
	}

	return decl
}

parse_interface_decl :: proc(p: ^Parser, is_exported: bool) -> ^Interface_Decl {
	expect(p, .TypeDecl)
	decl := new(Interface_Decl)
	decl.methods = make([dynamic]Method_Signature)
	decl.is_exported = is_exported

	name_tok := next_token(p.stream)
	decl.name = name_tok.data

	expect(p, .Assign)
	expect(p, .Interface)

	for peek_token(p.stream).kind != .End && peek_token(p.stream).kind != .EOF {
		expect(p, .Function)
		method_name := next_token(p.stream)
		signature := Method_Signature {
			name = method_name.data,
		}
		signature.args = parse_param_list(p, true)
		signature.return_type = parse_required_return_type(p, "метода интерфейса")
		append(&decl.methods, signature)
		consume_semicolon_or_newline(p)
	}

	expect(p, .End)
	return decl
}

parse_impl_decl :: proc(p: ^Parser) -> ^Impl_Decl {
	expect(p, .Impl)

	decl := new(Impl_Decl)
	decl.methods = make([dynamic]^Function_Decl)

	first_ident := next_token(p.stream)
	if first_ident.kind != .Ident do error("Ожидалось имя типа или интерфейса")

	if peek_token(p.stream).kind == .For {
		expect(p, .For)

		target_tok := next_token(p.stream)
		if target_tok.kind != .Ident do error("Ожидалось имя целевой структуры")

		decl.interface_name = first_ident.data
		decl.target_type = target_tok.data
	} else {
		decl.target_type = first_ident.data
	}

	for peek_token(p.stream).kind != .End && peek_token(p.stream).kind != .EOF {
		if peek_token(p.stream).kind != .Function {
			error(
				"Внутри блока реализации могут быть только функции",
			)
		}

		method := parse_function(p, false)
		if len(method.args) == 0 || method.args[0].name != "это" {
			fmt.panicf(
				"Синтаксическая ошибка: первый аргумент метода '%s' структуры '%s' должен называться 'это'",
				method.name,
				decl.target_type,
			)
		}

		method.name = fmt.tprintf("%s::%s", decl.target_type, method.name)
		append(&decl.methods, method)
	}

	expect(p, .End)
	return decl
}

parse_function :: proc(p: ^Parser, is_exported: bool) -> ^Function_Decl {
	expect(p, .Function)
	function := new(Function_Decl)
	function.body = make([dynamic]Stmt)
	function.is_exported = is_exported

	tok := next_token(p.stream)
	if tok.kind != .Ident do fmt.panicf("Ожидалось имя функции")
	function.name = tok.data

	function.args = parse_param_list(p, true)
	function.return_type = parse_required_return_type(p, "функции")

	for peek_token(p.stream).kind != .End && peek_token(p.stream).kind != .EOF {
		append(&function.body, parse_stmt(p))
	}
	expect(p, .End)

	return function
}

parse_param_list :: proc(p: ^Parser, require_types: bool) -> [dynamic]Param_Decl {
	params := make([dynamic]Param_Decl)
	expect(p, .LParen)

	if peek_token(p.stream).kind != .RParen {
		for {
			param_tok := next_token(p.stream)
			if param_tok.kind != .Ident do fmt.panicf("Ожидалось имя аргумента")

			param := Param_Decl {
				name = param_tok.data,
			}

			if peek_token(p.stream).kind == .Colon {
				next_token(p.stream)
				param.type_annotation = parse_type(p)
			} else if require_types {
				fmt.panicf(
					"Синтаксическая ошибка: после аргумента '%s' ожидается ': Тип'",
					param.name,
				)
			}
			append(&params, param)

			if peek_token(p.stream).kind == .Comma {
				next_token(p.stream)
				if peek_token(p.stream).kind == .RParen {
					break
				}
			} else {
				break
			}
		}
	}

	expect(p, .RParen)
	return params
}

parse_required_return_type :: proc(p: ^Parser, owner: string) -> Type_Node {
	if peek_token(p.stream).kind != .Arrow {
		fmt.panicf(
			"Синтаксическая ошибка: после объявления %s ожидается '-> Тип'",
			owner,
		)
	}
	next_token(p.stream)
	return parse_type(p)
}

parse_optional_return_type :: proc(p: ^Parser) -> Type_Node {
	if peek_token(p.stream).kind != .Arrow do return nil
	next_token(p.stream)
	return parse_type(p)
}

parse_struct_decl :: proc(p: ^Parser, is_exported: bool) -> ^Struct_Decl {
	expect(p, .TypeDecl)

	decl := new(Struct_Decl)
	decl.fields = make([dynamic]Field_Decl)
	decl.is_exported = is_exported

	name_tok := next_token(p.stream)
	if name_tok.kind != .Ident do error("Ожидалось имя типа")
	decl.name = name_tok.data

	expect(p, .Assign)
	expect(p, .Struct)

	for peek_token(p.stream).kind != .End && peek_token(p.stream).kind != .EOF {
		field := Field_Decl{}

		field_tok := next_token(p.stream)
		if field_tok.kind != .Ident do error("Ожидалось имя поля структуры")
		field.name = field_tok.data

		expect(p, .Colon)

		field.type_annotation = parse_type(p)
		append(&decl.fields, field)

		consume_semicolon_or_newline(p)
	}

	expect(p, .End)
	return decl
}

// --- ПАРСИНГ ТИПОВ И ИНСТРУКЦИЙ ---

parse_type :: proc(p: ^Parser) -> Type_Node {
	tok := next_token(p.stream)

	if tok.kind == .Function {
		t := new(Type_Function)
		t.params = make([dynamic]Type_Node)

		expect(p, .LParen)
		if peek_token(p.stream).kind != .RParen {
			for {
				append(&t.params, parse_type(p))
				if peek_token(p.stream).kind == .Comma {
					next_token(p.stream)
					if peek_token(p.stream).kind == .RParen {
						break
					}
				} else {
					break
				}
			}
		}
		expect(p, .RParen)
		expect(p, .Arrow)
		t.return_type = parse_type(p)
		return t
	}

	if tok.kind == .Ident {
		if peek_token(p.stream).kind == .Dot {
			next_token(p.stream)
			member_tok := next_token(p.stream)
			if member_tok.kind != .Ident {
				fmt.panicf(
					"Синтаксическая ошибка: после '.' ожидается имя типа",
				)
			}
			t := new(Type_Qualified)
			t.module_name = tok.data
			t.name = member_tok.data
			return t
		}

		// НОВОЕ: Универсальный парсинг дженерик-типов: Массив(Число), Соответствие(Число, Строка)
		if peek_token(p.stream).kind == .LParen {
			next_token(p.stream) // съедаем (
			t := new(Type_Generic)
			t.name = tok.data
			t.params = make([dynamic]Type_Node)

			if peek_token(p.stream).kind != .RParen {
				for {
					append(&t.params, parse_type(p))
					if peek_token(p.stream).kind == .Comma {
						next_token(p.stream)
					} else {
						break
					}
				}
			}
			expect(p, .RParen)
			return t
		}

		// Иначе это обычный тип-идентификатор (Число, Строка)
		t := new(Type_Ident)
		t.name = tok.data
		return t
	}

	if tok.kind == .LParen {
		t := new(Type_Tuple)
		t.elements = make([dynamic]Type_Node)

		if peek_token(p.stream).kind != .RParen {
			for {
				append(&t.elements, parse_type(p))
				if peek_token(p.stream).kind == .Comma {
					next_token(p.stream)
				} else {
					break
				}
			}
		}
		expect(p, .RParen)
		return t
	}

	error("Ожидалось имя типа или тупл")
	return nil
}

parse_stmt :: proc(p: ^Parser) -> Stmt {
	tok := peek_token(p.stream)
	if tok == nil do return nil

	#partial switch tok.kind {
	case .Return:
		return parse_return_stmt(p)
	case .Let:
		return parse_let_stmt(p)
	case .Continue:
		return parse_continue_stmt(p)
	case .Break:
		return parse_break_stmt(p)
	case:
		return parse_expr_stmt(p)
	}
}

parse_continue_stmt :: proc(p: ^Parser) -> Stmt {
	next_token(p.stream)
	stmt := new(Continue_Stmt)
	consume_semicolon_or_newline(p)
	return stmt
}

parse_break_stmt :: proc(p: ^Parser) -> Stmt {
	next_token(p.stream)
	stmt := new(Break_Stmt)
	consume_semicolon_or_newline(p)
	return stmt
}

parse_return_stmt :: proc(p: ^Parser) -> Stmt {
	next_token(p.stream)
	stmt := new(Return_Stmt)

	tok := peek_token(p.stream)
	if tok.kind == .Semicolon || tok.kind == .End || tok.kind == .EOF {
		stmt.value = nil
	} else {
		stmt.value = parse_expr(p, 0)
	}

	consume_semicolon_or_newline(p)
	return stmt
}

parse_let_stmt :: proc(p: ^Parser) -> Stmt {
	next_token(p.stream)
	stmt := new(Let_Stmt)

	ident_tok := next_token(p.stream)
	if ident_tok.kind != .Ident do fmt.panicf("Синтаксическая ошибка: после 'пер' ожидается идентификатор")
	stmt.name = ident_tok.data

	if peek_token(p.stream).kind == .Colon {
		next_token(p.stream)
		stmt.type_annotation = parse_type(p)
	}

	expect(p, .Assign)
	stmt.value = parse_expr(p, 0)
	consume_semicolon_or_newline(p)
	return stmt
}

parse_expr_stmt :: proc(p: ^Parser) -> Stmt {
	stmt := new(Expr_Stmt)
	stmt.expr = parse_expr(p, 0)
	consume_semicolon_or_newline(p)
	return stmt
}

// --- ПАРСИНГ ВЫРАЖЕНИЙ (PRATT PARSER) ---

parse_if_expr :: proc(p: ^Parser) -> Expr {
	node := new(If_Expr)
	node.condition = parse_expr(p, 0)

	expect(p, .Then)
	node.then_branch = make([dynamic]Stmt)
	for {
		kind := peek_token(p.stream).kind
		if kind == .Else || kind == .End || kind == .EOF do break
		append(&node.then_branch, parse_stmt(p))
	}

	node.else_branch = make([dynamic]Stmt)
	if peek_token(p.stream).kind == .Else {
		next_token(p.stream)
		for {
			kind := peek_token(p.stream).kind
			if kind == .End || kind == .EOF do break
			append(&node.else_branch, parse_stmt(p))
		}
	}

	expect(p, .End)
	return node
}

parse_while_expr :: proc(p: ^Parser) -> Expr {
	node := new(While_Expr)
	node.condition = parse_expr(p, 0)

	expect(p, .Loop)
	node.body = make([dynamic]Stmt)
	for {
		kind := peek_token(p.stream).kind
		if kind == .End || kind == .EOF do break
		append(&node.body, parse_stmt(p))
	}

	expect(p, .End)
	return node
}

parse_array_literal_after_lparen :: proc(p: ^Parser) -> Expr {
	node := new(Array_Expr)
	node.elements = make([dynamic]Expr)

	if peek_token(p.stream).kind != .RParen {
		for {
			append(&node.elements, parse_expr(p, 0))
			if peek_token(p.stream).kind == .Comma {
				next_token(p.stream)
				if peek_token(p.stream).kind == .RParen {
					break
				}
			} else {
				break
			}
		}
	}

	expect(p, .RParen)
	return node
}

parse_map_literal_after_lparen :: proc(p: ^Parser) -> Expr {
	node := new(Map_Expr)
	node.entries = make([dynamic]Map_Entry_Expr)

	if peek_token(p.stream).kind != .RParen {
		for {
			entry := Map_Entry_Expr{}
			entry.key = parse_expr(p, 11)
			expect(p, .Assign)
			entry.value = parse_expr(p, 0)
			append(&node.entries, entry)

			if peek_token(p.stream).kind == .Comma {
				next_token(p.stream)
				if peek_token(p.stream).kind == .RParen {
					break
				}
			} else {
				break
			}
		}
	}

	expect(p, .RParen)
	return node
}

parse_expr :: proc(p: ^Parser, min_bp: int) -> Expr {
	tok := next_token(p.stream)
	if tok == nil {
		error("Unexpected end of file")
		return nil
	}

	left := nud(p, tok)

	for {
		op := peek_token(p.stream)
		if op == nil || op.kind == .EOF do break

		lbp, rbp, is_infix := infix_bp(op)
		if !is_infix || lbp < min_bp do break

		next_token(p.stream)

		if op.kind == .LParen {
			if ident, ok := left.(^Ident_Expr); ok {
				if ident.name == "массив" {
					left = parse_array_literal_after_lparen(p)
					continue
				}
				if ident.name == "соответствие" {
					left = parse_map_literal_after_lparen(p)
					continue
				}
			}

			// Вызов функции (в том числе массив() и соответствие()!)
			call := new(Call_Expr)
			call.callee = left
			call.args = make([dynamic]Expr)

			if peek_token(p.stream).kind != .RParen {
				for {
					append(&call.args, parse_expr(p, 0))
					if peek_token(p.stream).kind == .Comma {
						next_token(p.stream)
					} else {
						break
					}
				}
			}
			expect(p, .RParen)
			left = call

		} else if op.kind == .Dot {
			prop_tok := next_token(p.stream)
			if prop_tok.kind != .Ident && prop_tok.kind != .Number {
				error("Ожидалось имя поля или индекс после '.'")
			}
			prop := new(Property_Expr)
			prop.object = left
			prop.property = prop_tok.data
			left = prop

		} else if op.kind == .LBracket {
			index := new(Index_Expr)
			index.object = left
			index.index = parse_expr(p, 0)
			expect(p, .RBracket)
			left = index

		} else if op.kind == .Question {
			try_expr := new(Try_Expr)
			try_expr.value = left
			left = try_expr

		} else {
			// Обычный бинарный оператор (включая `=`)
			right := parse_expr(p, rbp)
			left = new_bin_op(op.kind, left, right)
		}
	}
	return left
}

nud :: proc(p: ^Parser, tok: ^Token) -> Expr {
	#partial switch tok.kind {
	case .Number:
		return new_int_lit(tok)

	case .Boolean:
		return new_boolean_lit(tok)

	case .String:
		s := new(String_Expr)
		s.value = tok.data
		return s

	case .Ident:
		return new_ident(tok)

	case .Function:
		// Лямбда-функции: функ(х) х + 1 конец
		lam := new(Lambda_Expr)
		lam.body = make([dynamic]Stmt)

		lam.args = parse_param_list(p, false)
		lam.return_type = parse_optional_return_type(p)

		for peek_token(p.stream).kind != .End && peek_token(p.stream).kind != .EOF {
			append(&lam.body, parse_stmt(p))
		}
		expect(p, .End)
		return lam

	case .LParen:
		if peek_token(p.stream).kind == .RParen {
			next_token(p.stream)
			t := new(Tuple_Expr)
			t.elements = make([dynamic]Expr)
			return t
		}

		e := parse_expr(p, 0)

		if peek_token(p.stream).kind == .Comma {
			t := new(Tuple_Expr)
			t.elements = make([dynamic]Expr)
			append(&t.elements, e)

			for peek_token(p.stream).kind == .Comma {
				next_token(p.stream)
				if peek_token(p.stream).kind == .RParen {
					break
				}
				append(&t.elements, parse_expr(p, 0))
			}
			expect(p, .RParen)
			return t
		}

		expect(p, .RParen)
		return e

	case .Minus:
		rbp := prefix_bp(tok)
		rhs := parse_expr(p, rbp)
		return new_unary(tok, rhs)

	case .Negate:
		rbp := prefix_bp(tok)
		rhs := parse_expr(p, rbp)
		return new_unary(tok, rhs)

	case .If:
		return parse_if_expr(p)

	case .While:
		return parse_while_expr(p)

	case .Match:
		return parse_match_expr(p)

	case:
		error("unexpected token %s in nud position", tok.data)
	}
	return nil
}

parse_pattern :: proc(p: ^Parser) -> Pattern {
	tok := next_token(p.stream)
	if tok.kind == .Ident {
		if tok.data == "_" {
			return new(Pattern_Wildcard)
		}
		module_name := ""
		type_name := ""
		name := tok.data
		// Optional qualification: Ident.Ident (Type.Variant) or
		// Ident.Ident.Ident (module.Type.Variant).
		for peek_token(p.stream).kind == .Dot {
			next_token(p.stream)
			next_tok := next_token(p.stream)
			if next_tok.kind != .Ident {
				fmt.panicf(
					"Синтаксическая ошибка: после '.' в шаблоне ожидался идентификатор",
				)
			}
			if module_name == "" {
				module_name = name
				name = next_tok.data
			} else {
				type_name = name
				name = next_tok.data
			}
		}
		// If only one dot was used, we don't know yet whether it was
		// Type.Variant or module.Variant — resolver decides. Store as
		// (module_name=first, name=second, type_name=""). For two dots,
		// (module_name=first, type_name=second, name=third).
		if type_name != "" {
			// Encode module.Type.Variant into Pattern_Constructor by
			// prefixing module_name with the type qualifier separator "|".
			// Simpler: store type as "module_name". We track second-level
			// via type_name concatenated. For now flatten to module.
			module_name = fmt.aprintf("%s.%s", module_name, type_name)
		}
		if peek_token(p.stream).kind == .LParen {
			next_token(p.stream)
			pat := new(Pattern_Constructor)
			pat.module_name = module_name
			pat.name = name
			pat.args = make([dynamic]Pattern)
			if peek_token(p.stream).kind == .RParen {
				fmt.panicf(
					"Синтаксическая ошибка: у шаблона-конструктора '%s' пустые скобки",
					name,
				)
			}
			for {
				append(&pat.args, parse_pattern(p))
				if peek_token(p.stream).kind == .Comma {
					next_token(p.stream)
					continue
				}
				break
			}
			expect(p, .RParen)
			return pat
		}
		if module_name != "" {
			pat := new(Pattern_Constructor)
			pat.module_name = module_name
			pat.name = name
			pat.args = make([dynamic]Pattern)
			return pat
		}
		pat := new(Pattern_Ident)
		pat.name = name
		return pat
	}
	fmt.panicf(
		"Синтаксическая ошибка: такой шаблон в выборе пока не поддерживается: %v",
		tok.kind,
	)
}

parse_match_expr :: proc(p: ^Parser) -> ^Match_Expr {
	m := new(Match_Expr)
	m.arms = make([dynamic]Match_Arm)
	m.subject = parse_expr(p, 0)

	consume_semicolon_or_newline(p)

	for peek_token(p.stream).kind != .End && peek_token(p.stream).kind != .EOF {
		arm := Match_Arm {
			body = make([dynamic]Stmt),
		}
		arm.pattern = parse_pattern(p)
		expect(p, .Arrow)
		// Тело ветки: один или несколько statement до разделителя ветки.
		// Разделителем считается перевод строки или `;`; следующая ветка
		// начинается со следующего Pattern (Ident/`_`).
		for {
			append(&arm.body, parse_stmt(p))
			if peek_token(p.stream).kind == .Semicolon {
				next_token(p.stream)
			}
			nxt := peek_token(p.stream).kind
			if nxt == .End || nxt == .EOF do break
			// Если следующий токен — идентификатор ИЛИ `_` (Ident), это
			// начало следующей ветки. Наивно: если после текущего stmt
			// стоит Ident в позиции начала выражения, считаем это новой
			// веткой. Для простоты сейчас поддерживаем ветки в одну
			// строку — далее берём следующую ветку сразу.
			break
		}
		append(&m.arms, arm)
	}
	expect(p, .End)

	if len(m.arms) == 0 {
		fmt.panicf("Синтаксическая ошибка: выбор должен содержать хотя бы одну ветку")
	}
	return m
}

prefix_bp :: proc(token: ^Token) -> int {
	#partial switch token.kind {
	case .Minus, .Negate:
		return 100
	}
	return 0
}

infix_bp :: proc(tok: ^Token) -> (lbp, rbp: int, ok: bool) {
	#partial switch tok.kind {
	case .Dot:
		return 90, 91, true
	case .Star, .Slash:
		return 60, 61, true
	case .Plus, .Minus:
		return 50, 51, true
	case .Less, .Greater:
		return 40, 41, true
	case .Equal, .NotEqual:
		return 30, 31, true
	case .And:
		return 28, 29, true
	case .Or:
		return 26, 27, true
	case .Assign:
		return 10, 9, true
	case .LParen:
		return 80, 0, true
	case .LBracket:
		return 80, 0, true
	case .Question:
		return 90, 91, true
	}
	return 0, 0, false
}

// --- УТИЛИТЫ ---

error :: proc(format: string, args: ..any, loc := #caller_location) {
	fmt.panicf(format, args, loc = loc)
}

expect :: proc(p: ^Parser, expected_kind: TokenKind, loc := #caller_location) {
	tok := next_token(p.stream)
	if tok == nil do fmt.panicf("Синтаксическая ошибка: ожидалось %v, но обнаружен EOF", expected_kind, loc = loc)
	if tok.kind != expected_kind do fmt.panicf("Синтаксическая ошибка: ожидалось %v, обнаружен %v", expected_kind, tok.kind, loc = loc)
}

consume_semicolon_or_newline :: proc(p: ^Parser) {
	tok := peek_token(p.stream)
	if tok.kind == .Semicolon {
		next_token(p.stream)
	} else if tok.kind == .EOF || tok.kind == .RParen {
		return
	}
}

new_int_lit :: proc(data: ^Token) -> Expr {
	lit := new(Number_Expr)
	value, ok := strconv.parse_f64(data.data)
	if !ok do error("Неверный числовой литерал")
	lit.value = value
	return lit
}

new_boolean_lit :: proc(data: ^Token) -> Expr {
	lit := new(Boolean_Expr)
	lit.value = data.data == "истина"
	return lit
}

new_bin_op :: proc(kind: TokenKind, left: Expr, right: Expr) -> Expr {
	b := new(Binary_Expr)
	b.left = left
	b.op = kind
	b.right = right
	return b
}

new_unary :: proc(token: ^Token, rhs: Expr) -> Expr {
	lit := new(Unary_Expr)
	lit.op = token.kind
	lit.right = rhs
	return lit
}

new_ident :: proc(tok: ^Token) -> Expr {
	node := new(Ident_Expr)
	node.name = tok.data
	return node
}
