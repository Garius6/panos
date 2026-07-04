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

Decls :: union {
	^Function_Decl,
}

Program :: struct {
	decls: [dynamic]Decls,
}

Type_Node :: union {
	^Type_Ident,
	^Type_Tuple,
	^Type_Function,
}

Type_Function :: struct {
	params:      [dynamic]Type_Node,
	return_type: Type_Node, // Может быть nil, если возвращается Void (ничего)
}

Tuple_Expr :: struct {
	elements: [dynamic]Expr,
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

Binary_Expr :: struct {
	left:  Expr,
	op:    TokenKind,
	right: Expr,
}

Call_Expr :: struct {
	args:   [dynamic]Expr,
	callee: Expr,
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

Expr :: union {
	^Number_Expr,
	^Boolean_Expr,
	^Binary_Expr,
	^Unary_Expr,
	^Ident_Expr,
	^Call_Expr,
	^While_Expr,
	^If_Expr,
	^Tuple_Expr,
}

// Функция для печати всей программы
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
	}
}

// Функция для печати инструкций (Statements)
print_stmt :: proc(stmt: Stmt, prefix: string = "", is_last: bool = true) {
	if stmt == nil do return

	marker := is_last ? "└── " : "├── "
	next_prefix := fmt.tprintf("%s%s", prefix, is_last ? "    " : "│   ")

	switch s in stmt {
	case ^Let_Stmt:
		fmt.printf("%s%sLet(%s)\n", prefix, marker, s.name)
		// У Let_Stmt всегда есть значение (value), оно последнее
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
		for arg in e.args {
			print_ast(arg, next_prefix, false)
		}
	case ^While_Expr:
		fmt.printf("%s%sWhile()\n", prefix, marker)
		print_ast(e.condition)
		for stmt in e.body {
			print_stmt(stmt)
		}

	case ^If_Expr:
		fmt.printf("%s%sIf()\n", prefix, marker)
		print_ast(e.condition, next_prefix, false)

		for stmt in e.then_branch {
			print_stmt(stmt)
		}

		for stmt in e.else_branch {
			print_stmt(stmt)
		}
	case ^Tuple_Expr:
		fmt.printf("%s%sTuple()\n", prefix, marker)
		for el, i in e.elements {
			print_ast(el, next_prefix, i == len(e.elements) - 1)
		}
	}
}

parse_program :: proc(p: ^Parser) -> Program {
	prog := Program {
		decls = make([dynamic]Decls),
	}

	for peek_token(p.stream).kind != .EOF {
		if peek_token(p.stream).kind != .Function {
			fmt.panicf("Ожидалось объявление функции")
		}
		decl := parse_function(p)
		if decl != nil {
			append(&prog.decls, decl)
		}
	}
	return prog
}

parse_function :: proc(p: ^Parser) -> ^Function_Decl {
	expect(p, .Function)

	function := new(Function_Decl)
	function.args = make([dynamic]string)
	function.body = make([dynamic]Stmt)

	tok := next_token(p.stream)
	if tok.kind != .Ident {
		fmt.panicf("Ожидалось имя функции")
	}

	function.name = tok.data

	expect(p, .LParen)

	if tok = peek_token(p.stream); tok.kind == .Ident {
		for tok = next_token(p.stream); tok.kind == .Ident; {
			append(&function.args, tok.data)
		}
	}

	expect(p, .RParen)

	for peek_token(p.stream).kind != .End {
		append(&function.body, parse_stmt(p))
	}

	expect(p, .End)

	return function
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
		// Если это не инструкция языка, значит это выражение.
		// Например: a = 5; или foo();
		return parse_expr_stmt(p)
	}
}

parse_return_stmt :: proc(p: ^Parser) -> Stmt {
	next_token(p.stream) // Поглощаем токен 'return'

	stmt := new(Return_Stmt)

	// Если после return сразу идет точка с запятой, выражение пустое
	tok := peek_token(p.stream)
	if tok.kind == .Semicolon || tok.kind == .End || tok.kind == .EOF {
		stmt.value = nil
	} else {
		stmt.value = parse_expr(p, 0)
	}

	consume_semicolon_or_newline(p)
	return stmt
}

parse_type :: proc(p: ^Parser) -> Type_Node {
	tok := next_token(p.stream)

	if tok.kind == .Ident {
		t := new(Type_Ident)
		t.name = tok.data
		return t
	}

	// Тупл типов, например (Число, Строка)
	if tok.kind == .LParen {
		t := new(Type_Tuple)
		t.elements = make([dynamic]Type_Node)

		if peek_token(p.stream).kind != .RParen {
			for {
				append(&t.elements, parse_type(p))
				if peek_token(p.stream).kind == .Comma {
					next_token(p.stream) // съедаем запятую
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

parse_let_stmt :: proc(p: ^Parser) -> Stmt {
	next_token(p.stream) // Поглощаем 'let'

	stmt := new(Let_Stmt)

	ident_tok := next_token(p.stream)
	if ident_tok.kind != .Ident {
		fmt.panicf(
			"Синтаксическая ошибка: после 'пер' ожидается идентификатор",
		)
	}
	stmt.name = ident_tok.data

	if peek_token(p.stream).kind == .Colon {
		next_token(p.stream) // Съедаем двоеточие
		stmt.type_annotation = parse_type(p)
	}

	expect(p, .Assign) // Ожидаем '='

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

parse_if_expr :: proc(p: ^Parser) -> Expr {
	node := new(If_Expr)

	// 1. Условие
	node.condition = parse_expr(p, 0)

	// 2. Блок 'тогда'
	expect(p, .Then)
	node.then_branch = make([dynamic]Stmt)
	for {
		kind := peek_token(p.stream).kind
		if kind == .Else || kind == .End || kind == .EOF do break
		append(&node.then_branch, parse_stmt(p))
	}

	// 3. Блок 'иначе' (опционально)
	node.else_branch = make([dynamic]Stmt)
	if peek_token(p.stream).kind == .Else {
		next_token(p.stream) // Съедаем 'иначе'
		for {
			kind := peek_token(p.stream).kind
			if kind == .End || kind == .EOF do break
			append(&node.else_branch, parse_stmt(p))
		}
	}

	// 4. Ожидаем 'конец'
	expect(p, .End)
	return node
}

parse_while_expr :: proc(p: ^Parser) -> Expr {
	node := new(While_Expr)

	// 1. Условие
	node.condition = parse_expr(p, 0)

	// 2. Блок 'цикл'
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
			// Вызов функции! `left` (то, что было до скобки) становится нашим callee
			call := new(Call_Expr)
			call.callee = left
			call.args = make([dynamic]Expr)

			// Парсим аргументы до закрывающей скобки
			if peek_token(p.stream).kind != .RParen {
				for {
					append(&call.args, parse_expr(p, 0))
					if peek_token(p.stream).kind == .Comma {
						next_token(p.stream) // Съедаем запятую
					} else {
						break
					}
				}
			}
			expect(p, .RParen) // Съедаем ')'
			left = call // Возвращаем собранный Call_Expr дальше по цепочке
		} else {
			// Обычный бинарный оператор (+, -, *, /)
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

	case .Ident:
		return new_ident(tok)

	case .LParen:
		// 1. Обработка пустого тупла `()`
		if peek_token(p.stream).kind == .RParen {
			next_token(p.stream) // Съедаем ')'
			t := new(Tuple_Expr)
			t.elements = make([dynamic]Expr)
			return t
		}

		// 2. Парсим первое выражение
		e := parse_expr(p, 0)

		// 3. Если дальше запятая, то это тупл `(a, b)`
		if peek_token(p.stream).kind == .Comma {
			t := new(Tuple_Expr)
			t.elements = make([dynamic]Expr)
			append(&t.elements, e)

			for peek_token(p.stream).kind == .Comma {
				next_token(p.stream) // Съедаем запятую

				// Поддержка запятой в конце: `(1,)`
				if peek_token(p.stream).kind == .RParen {
					break
				}
				append(&t.elements, parse_expr(p, 0))
			}
			expect(p, .RParen)
			return t
		}

		// 4. Запятой нет — это обычная группировка `(a + b)`
		expect(p, .RParen)
		return e

	case .Minus:
		rbp := prefix_bp(tok)
		rhs := parse_expr(p, rbp)
		return new_unary(tok, rhs)

	case .If:
		// Токен 'если' мы уже "съели", парсим остальное
		return parse_if_expr(p)

	case .While:
		// Токен 'пока' мы уже "съели"
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
	case .Star, .Slash:
		return 60, 61, true
	case .Plus, .Minus:
		return 50, 51, true
	case .LParen:
		return 80, 0, true
	}
	return 0, 0, false
}

error :: proc(format: string, args: ..any, loc := #caller_location) {
	fmt.panicf(format, args, loc = loc)
}

expect :: proc(p: ^Parser, expected_kind: TokenKind, loc := #caller_location) {
	tok := next_token(p.stream)

	if tok == nil {
		fmt.panicf(
			"Синтаксическая ошибка: ожидалось %v, но обнаружен EOF",
			expected_kind,
			loc = loc,
		)
	}

	if tok.kind != expected_kind {
		fmt.panicf(
			"Синтаксическая ошибка: ожидалось %v, обнаружен %v",
			expected_kind,
			tok.kind,
			loc = loc,
		)
	}
}

consume_semicolon_or_newline :: proc(p: ^Parser) {
	tok := peek_token(p.stream)
	if tok.kind == .Semicolon {
		next_token(p.stream) // Поглощаем явную ';'
	} else if tok.kind == .EOF || tok.kind == .RParen {
		// Здесь можно не поглощать, если мы достигли границы блока
		return
	} else {
		// Если это не ';', но валидный конец выражения — просто игнорируем
		// Либо можно логировать, что мы вставили "виртуальную" точку
	}
}

new_int_lit :: proc(data: ^Token) -> Expr {
	lit := new(Number_Expr)
	value, ok := strconv.parse_f64(data.data)
	if !ok {
		error("Неверный числовой литерал")
	}

	lit.value = value
	return lit
}

new_boolean_lit :: proc(data: ^Token) -> Expr {
	lit := new(Boolean_Expr)
	value := data.data == "истина"

	lit.value = value
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
