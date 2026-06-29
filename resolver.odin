// resolver.odin
package main

import "core:fmt"

// Семантическая сущность (переменная, в будущем - функция)
Symbol :: struct {
	name: string,
}

Resolver_Ctx :: struct {
	scopes:       [dynamic]map[string]^Symbol,

	// Side Tables
	decl_symbols: map[Stmt]^Symbol, // Связывает Let_Stmt с созданным символом
	node_symbols: map[Expr]^Symbol, // Связывает Ident_Expr с символом, на который он указывает
}

new_resolver_ctx :: proc() -> Resolver_Ctx {
	ctx := Resolver_Ctx {
		scopes       = make([dynamic]map[string]^Symbol),
		decl_symbols = make(map[Stmt]^Symbol),
		node_symbols = make(map[Expr]^Symbol),
	}
	// Открываем глобальную область видимости
	append(&ctx.scopes, make(map[string]^Symbol))
	return ctx
}

lookup_symbol :: proc(ctx: ^Resolver_Ctx, name: string) -> ^Symbol {
	#reverse for scope in ctx.scopes {
		if sym, ok := scope[name]; ok {
			return sym
		}
	}
	return nil
}

resolve_program :: proc(ctx: ^Resolver_Ctx, prog: Program) {
	for stmt in prog.statements {
		resolve_stmt(ctx, stmt)
	}
}

resolve_stmt :: proc(ctx: ^Resolver_Ctx, stmt: Stmt) {
	if stmt == nil do return

	switch s in stmt {
	case ^Let_Stmt:
		// 1. Сначала разрешаем правую часть (чтобы запретить `let a = a`)
		resolve_expr(ctx, s.value)

		// 2. Создаем новый символ
		sym := new(Symbol)
		sym.name = s.name

		// 3. Добавляем в текущую область видимости
		current_scope := &ctx.scopes[len(ctx.scopes) - 1]
		if _, exists := current_scope^[s.name]; exists {
			fmt.panicf("Semantic Error: variable '%s' is already declared", s.name)
		}
		current_scope^[s.name] = sym

		// 4. Кэшируем создание в Side Table
		ctx.decl_symbols[stmt] = sym

	case ^Return_Stmt:
		resolve_expr(ctx, s.value)

	case ^Expr_Stmt:
		resolve_expr(ctx, s.expr)
	}
}

resolve_expr :: proc(ctx: ^Resolver_Ctx, expr: Expr) {
	if expr == nil do return

	switch e in expr {
	case ^Ident_Expr:
		sym := lookup_symbol(ctx, e.name)
		if sym == nil {
			fmt.panicf("Resolve Error: undefined variable '%s'", e.name)
		}
		// Кэшируем использование в Side Table
		ctx.node_symbols[expr] = sym

	case ^Binary_Expr:
		resolve_expr(ctx, e.left)
		resolve_expr(ctx, e.right)

	case ^Unary_Expr:
		resolve_expr(ctx, e.right)

	case ^Number_Expr:
	case ^Boolean_Expr:
	}
}

print_resolver_ctx :: proc(resolver_ctx: Resolver_Ctx) {
	for scope in resolver_ctx.scopes {
		fmt.println(scope)
	}

	for decls in resolver_ctx.decl_symbols {
		fmt.println(decls)
	}

	for nodes in resolver_ctx.node_symbols {
		fmt.println(nodes)
	}
}
