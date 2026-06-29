// resolver.odin
package main

import "core:fmt"

// Семантическая сущность (переменная, в будущем - функция)
Symbol :: struct {
	name: string,
}

Scope :: struct {
	parent:  ^Scope,
	symbols: map[string]^Symbol,
}

Resolver_Ctx :: struct {
	current_scope: ^Scope,
	global_scope:  ^Scope,

	// Side Tables
	decl_symbols:  map[Decls]^Symbol,
	stmt_symbols:  map[Stmt]^Symbol,
	node_symbols:  map[Expr]^Symbol,
}

push_scope :: proc(resolver: ^Resolver_Ctx) {
	new_scope := new(Scope)
	new_scope.parent = resolver.current_scope
	new_scope.symbols = make(map[string]^Symbol)
	resolver.current_scope = new_scope
}

pop_scope :: proc(resolver: ^Resolver_Ctx) {
	if resolver.current_scope.parent != nil {
		resolver.current_scope = resolver.current_scope.parent
	}
}

new_resolver_ctx :: proc() -> Resolver_Ctx {
	ctx := Resolver_Ctx {
		stmt_symbols = make(map[Stmt]^Symbol),
		decl_symbols = make(map[Decls]^Symbol),
		node_symbols = make(map[Expr]^Symbol),
	}

	push_scope(&ctx)
	ctx.global_scope = ctx.current_scope

	return ctx
}

lookup_symbol :: proc(s: ^Scope, name: string) -> ^Symbol {
	sym, found := s.symbols[name]
	if found {
		return sym
	}

	if s.parent != nil {
		return lookup_symbol(s.parent, name)
	}

	return nil
}

resolve_program :: proc(ctx: ^Resolver_Ctx, prog: Program) {
	for decl in prog.decls {
		resolve_decl(ctx, decl)
	}
}

resolve_decl :: proc(ctx: ^Resolver_Ctx, decl: Decls) {
	switch d in decl {
	case ^Function_Decl:
		sym := new(Symbol)
		sym.name = d.name

		if lookup_symbol(ctx.current_scope, sym.name) != nil {
			fmt.panicf("Символ %s уже объявлен", sym.name)
		}

		ctx.decl_symbols[decl] = sym

		push_scope(ctx)
		for stmt in d.body {
			resolve_stmt(ctx, stmt)
		}
		pop_scope(ctx)
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
		if lookup_symbol(ctx.current_scope, s.name) != nil {
			fmt.panicf("Имя %s уже объявлено", s.name)
		}
		ctx.current_scope.symbols[s.name] = sym

		// 4. Кэшируем создание в Side Table
		ctx.stmt_symbols[stmt] = sym

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
		sym := lookup_symbol(ctx.current_scope, e.name)
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

	// for scopes in resolver_ctx.scopes {
	// 	for key, value in scopes {
	// 		fmt.printf("Область %s, символ: %s\n", key, value.name)
	// 	}
	// }

	for decls in resolver_ctx.decl_symbols {
		fmt.println(decls)
	}

	for nodes in resolver_ctx.node_symbols {
		fmt.println(nodes)
	}
}
