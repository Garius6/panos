package main

import "core:fmt"
import "core:strconv"

Parser :: struct {
	stream: ^TokenStream,
}

Parser_Error :: enum {
	Cannot,
}

Program :: struct {
	statements: [dynamic]Stmt,
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
	name:  string,
	value: Expr,
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

Expr :: union {
	^Number_Expr,
	^Boolean_Expr,
	^Binary_Expr,
	^Unary_Expr,
	^Ident_Expr,
}

// Функция для печати всей программы
print_program :: proc(prog: Program) {
	fmt.println("Program")
	for stmt, i in prog.statements {
		is_last := i == len(prog.statements) - 1
		print_stmt(stmt, "", is_last)
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
	}
}

parse_program :: proc(p: ^Parser) -> Program {
	prog := Program {
		statements = make([dynamic]Stmt, context.allocator), // Использует динамическую арену
	}

	for peek_token(p.stream).kind != .EOF {
		stmt := parse_stmt(p)
		if stmt != nil {
			append(&prog.statements, stmt)
		}
	}
	return prog
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
	if peek_token(p.stream).kind == .Semicolon {
		stmt.value = nil
	} else {
		stmt.value = parse_expr(p, 0)
	}

	expect(p, .Semicolon) // Поглощаем ';'
	return stmt
}

parse_let_stmt :: proc(p: ^Parser) -> Stmt {
	next_token(p.stream) // Поглощаем 'let'

	stmt := new(Let_Stmt)

	// Ожидаем идентификатор
	ident_tok := next_token(p.stream)
	if ident_tok.kind != .Ident {
		fmt.panicf(
			"Синтаксическая ошибка: после 'пер' ожидается идентификатор",
		)
	}
	stmt.name = ident_tok.data

	expect(p, .Assign) // Ожидаем '='

	stmt.value = parse_expr(p, 0)

	expect(p, .Semicolon)
	return stmt
}

parse_expr_stmt :: proc(p: ^Parser) -> Stmt {
	stmt := new(Expr_Stmt)
	stmt.expr = parse_expr(p, 0)

	// Поглощаем опциональную или обязательную точку с запятой
	if peek_token(p.stream).kind == .Semicolon {
		next_token(p.stream)
	}

	return stmt
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
		right := parse_expr(p, rbp)
		left = new_bin_op(op.kind, left, right)
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
		e := parse_expr(p, 0)
		expect(p, .RParen)
		return e
	case .Minus:
		rbp := prefix_bp(tok)
		rhs := parse_expr(p, rbp)
		return new_unary(tok, rhs)
	case:
		error("unexpected token in nud position")
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
	}
	return 0, 0, false
}

error :: proc(message: string) {
	fmt.panicf(message)
}

expect :: proc(p: ^Parser, expected_kind: TokenKind) {
	tok := next_token(p.stream)

	if tok == nil {
		fmt.panicf(
			"Синтаксическая ошибка: ожидалось %v, но обнаружен EOF",
			expected_kind,
		)
	}

	if tok.kind != expected_kind {
		fmt.panicf(
			"Синтаксическая ошибка: ожидалось %v, обнаружен %v",
			expected_kind,
			tok.kind,
		)
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
