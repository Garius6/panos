// checker.odin
package main

import "core:fmt"

Type_Kind :: enum {
	Number,
	Bool,
}

Type :: struct {
	kind: Type_Kind,
	name: string,
}

// Интернированные базовые типы
TY_NUM := &Type{kind = .Number, name = "Number"}
TY_BOOL := &Type{kind = .Bool, name = "Bool"}

Type_Ctx :: struct {
	res:          ^Resolver_Ctx, // Доступ к данным резолвера

	// Side Tables тайп-чекера
	node_types:   map[Expr]^Type, // Вычисленные типы выражений
	symbol_types: map[^Symbol]^Type, // Назначенные типы символов
}

new_type_ctx :: proc(res: ^Resolver_Ctx) -> Type_Ctx {
	return Type_Ctx {
		res = res,
		node_types = make(map[Expr]^Type),
		symbol_types = make(map[^Symbol]^Type),
	}
}

typecheck_program :: proc(ctx: ^Type_Ctx, prog: Program) {
	for stmt in prog.statements {
		check_stmt(ctx, stmt)
	}
}

check_stmt :: proc(ctx: ^Type_Ctx, stmt: Stmt) {
	if stmt == nil do return

	switch s in stmt {
	case ^Let_Stmt:
		// 1. Выводим тип правой части
		t := infer_expr(ctx, s.value)

		// 2. Берем символ из таблицы резолвера и привязываем к нему тип
		sym := ctx.res.decl_symbols[stmt]
		ctx.symbol_types[sym] = t

	case ^Return_Stmt:
		if s.value != nil {
			infer_expr(ctx, s.value)
		}

	case ^Expr_Stmt:
		infer_expr(ctx, s.expr)
	}
}

infer_expr :: proc(ctx: ^Type_Ctx, expr: Expr) -> ^Type {
	if expr == nil do return nil

	// Кэширование: если тип уже вычислен, возвращаем его
	if t, ok := ctx.node_types[expr]; ok {
		return t
	}

	t: ^Type
	switch e in expr {
	case ^Number_Expr:
		t = TY_NUM
	case ^Boolean_Expr:
		t = TY_BOOL

	case ^Ident_Expr:
		sym := ctx.res.node_symbols[expr]
		var_type, ok := ctx.symbol_types[sym]
		if !ok {
			fmt.panicf("Type Error: symbol '%s' has no assigned type yet", sym.name)
		}
		t = var_type

	case ^Binary_Expr:
		#partial switch e.op {
		case .Plus, .Minus, .Star, .Slash:
			check_expr(ctx, e.left, TY_NUM)
			check_expr(ctx, e.right, TY_NUM)
			t = TY_NUM
		case:
			fmt.panicf("Type Error: unsupported operator %v", e.op)
		}

	case ^Unary_Expr:
		check_expr(ctx, e.right, TY_NUM)
		t = TY_NUM
	}

	ctx.node_types[expr] = t
	return t
}

check_expr :: proc(ctx: ^Type_Ctx, expr: Expr, expected: ^Type) {
	if expr == nil do return

	actual := infer_expr(ctx, expr)
	if actual != expected {
		fmt.panicf("Type Error: expected '%s', got '%s'", expected.name, actual.name)
	}
}

print_type_ctx :: proc(ctx: ^Type_Ctx) {
	for symbol, type in ctx.symbol_types {
		fmt.printf("Символ '%s' имеет тип %s\n", symbol.name, type.name)
	}
}
