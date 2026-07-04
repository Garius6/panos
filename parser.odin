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
	name: string,
	args: [dynamic]string,
	body: [dynamic]Stmt,
}

Method_Signature :: struct {
	name: string,
	args: [dynamic]string,
}

Interface_Decl :: struct {
	name:    string,
	methods: [dynamic]Method_Signature,
}

Field_Decl :: struct {
	name:            string,
	type_annotation: Type_Node,
}

Struct_Decl :: struct {
	name:   string,
	fields: [dynamic]Field_Decl,
}

Impl_Decl :: struct {
	interface_name: string,
	target_type:    string,
	methods:        [dynamic]^Function_Decl,
}

Decls :: union {
	^Function_Decl,
	^Struct_Decl,
	^Impl_Decl,
	^Interface_Decl,
}

Program :: struct {
	decls: [dynamic]Decls,
}

// НОВОЕ: Универсальный тип для дженериков (Массив(Число), Соответствие(Число, Строка))
Type_Generic :: struct {
	name:   string,
	params: [dynamic]Type_Node,
}

Type_Node :: union {
	^Type_Ident,
	^Type_Tuple,
	^Type_Function,
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
	args: [dynamic]string,
	body: [dynamic]Stmt,
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
}

// --- ПЕЧАТЬ AST ---

print_program :: proc(prog: Program) {
	fmt.println("Program")
	for decl in prog.decls {
		print_decl(decl)
	}
}

print_decl :: proc(decl: Decls) {
	switch d in decl {
	case ^Function_Decl:
		fmt.printf("Function (%s)\n", d.name)
		for stmt, i in d.body {
			is_last := i == len(d.body) - 1
			print_stmt(stmt, "", is_last)
		}
	case ^Struct_Decl:
		fmt.printf("Struct (%s)\n", d.name)
		for field, i in d.fields {
			is_last := i == len(d.fields) - 1
			print_field(field, "", is_last)
		}
	case ^Impl_Decl:
		fmt.printf("Impl (%s)\n", d.target_type)
	case ^Interface_Decl:
		fmt.printf("Interface (%s)\n", d.name)
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
	}
}

print_ast :: proc(expr: Expr, prefix: string = "", is_last: bool = true) {
	if expr == nil do return

	marker := is_last ? "└── " : "├── "
	next_prefix_base := is_last ? "    " : "│   "
	next_prefix := fmt.tprintf("%s%s", prefix, next_prefix_base)

	switch e in expr {
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
	}
}

// --- ПАРСИНГ ВЕРХНЕГО УРОВНЯ ---

parse_program :: proc(p: ^Parser) -> Program {
	prog := Program {
		decls = make([dynamic]Decls),
	}

	for peek_token(p.stream).kind != .EOF {
		tok_kind := peek_token(p.stream).kind
		if tok_kind == .Function {
			decl := parse_function(p)
			append(&prog.decls, decl)
		} else if tok_kind == .TypeDecl {
			if p.stream.tokens[p.stream.current_idx + 3].kind == .Struct {
				decl := parse_struct_decl(p)
				append(&prog.decls, decl)
			} else {
				decl := parse_interface_decl(p)
				append(&prog.decls, decl)
			}
		} else if tok_kind == .Impl {
			decl := parse_impl_decl(p)
			append(&prog.decls, decl)
		} else {
			fmt.panicf(
				"Ожидалось объявление функции или типа, получено: %v",
				tok_kind,
			)
		}
	}
	return prog
}

parse_interface_decl :: proc(p: ^Parser) -> ^Interface_Decl {
	expect(p, .TypeDecl)
	decl := new(Interface_Decl)
	decl.methods = make([dynamic]Method_Signature)

	name_tok := next_token(p.stream)
	decl.name = name_tok.data

	expect(p, .Assign)
	expect(p, .Interface)

	for peek_token(p.stream).kind != .End && peek_token(p.stream).kind != .EOF {
		expect(p, .Function)
		method_name := next_token(p.stream)
		signature := Method_Signature {
			name = method_name.data,
			args = make([dynamic]string),
		}

		expect(p, .LParen)
		if peek_token(p.stream).kind == .Ident {
			append(&signature.args, next_token(p.stream).data)
			for peek_token(p.stream).kind == .Comma {
				next_token(p.stream)
				arg_tok := next_token(p.stream)
				if arg_tok.kind != .Ident do fmt.panicf("Ожидалось имя аргумента")
				append(&signature.args, arg_tok.data)
			}
		}
		expect(p, .RParen)
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

		method := parse_function(p)
		if len(method.args) == 0 || method.args[0] != "это" {
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

parse_function :: proc(p: ^Parser) -> ^Function_Decl {
	expect(p, .Function)
	function := new(Function_Decl)
	function.args = make([dynamic]string)
	function.body = make([dynamic]Stmt)

	tok := next_token(p.stream)
	if tok.kind != .Ident do fmt.panicf("Ожидалось имя функции")
	function.name = tok.data

	expect(p, .LParen)
	if peek_token(p.stream).kind == .Ident {
		append(&function.args, next_token(p.stream).data)
		for peek_token(p.stream).kind == .Comma {
			next_token(p.stream) // Съедаем запятую
			tok_arg := next_token(p.stream)
			if tok_arg.kind != .Ident do fmt.panicf("Ожидалось имя аргумента")
			append(&function.args, tok_arg.data)
		}
	}
	expect(p, .RParen)

	for peek_token(p.stream).kind != .End && peek_token(p.stream).kind != .EOF {
		append(&function.body, parse_stmt(p))
	}
	expect(p, .End)

	return function
}

parse_struct_decl :: proc(p: ^Parser) -> ^Struct_Decl {
	expect(p, .TypeDecl)

	decl := new(Struct_Decl)
	decl.fields = make([dynamic]Field_Decl)

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

	if tok.kind == .Ident {
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
	case:
		return parse_expr_stmt(p)
	}
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
		lam.args = make([dynamic]string)
		lam.body = make([dynamic]Stmt)

		expect(p, .LParen)
		if peek_token(p.stream).kind == .Ident {
			tok_arg := next_token(p.stream)
			append(&lam.args, tok_arg.data)
			for peek_token(p.stream).kind == .Comma {
				next_token(p.stream)
				t_arg := next_token(p.stream)
				append(&lam.args, t_arg.data)
			}
		}
		expect(p, .RParen)

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

	case .If:
		return parse_if_expr(p)

	case .While:
		return parse_while_expr(p)

	case:
		error("unexpected token %s in nud position", tok.data)
	}
	return nil
}

prefix_bp :: proc(token: ^Token) -> int {
	#partial switch token.kind {
	case .Minus:
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
	case .Assign:
		return 10, 9, true
	case .LParen:
		return 80, 0, true
	case .LBracket:
		return 80, 0, true
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
