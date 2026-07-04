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
	func_args:     map[Decls][dynamic]^Symbol,
	lambda_args:   map[Expr][dynamic]^Symbol,
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
		switch d in decl {

		case ^Function_Decl:
			sym := new(Symbol)
			sym.name = d.name

			// Функция всегда регистрируется в глобальном скоупе
			if sym.name in ctx.global_scope.symbols {
				fmt.panicf("Resolve Error: Символ '%s' уже объявлен", sym.name)
			}

			ctx.global_scope.symbols[sym.name] = sym
			ctx.decl_symbols[decl] = sym
		case ^Struct_Decl:
			sym := new(Symbol)
			sym.name = d.name

			if sym.name in ctx.global_scope.symbols {
				fmt.panicf("Resolve Error: Символ '%s' уже объявлен", sym.name)
			}
			ctx.global_scope.symbols[sym.name] = sym
			ctx.decl_symbols[decl] = sym
		case ^Interface_Decl:
			sym := new(Symbol); sym.name = d.name
			ctx.global_scope.symbols[sym.name] = sym
			ctx.decl_symbols[decl] = sym
		case ^Impl_Decl:
			// Методы структур тоже становятся глобальными символами (формат 'Игрок::атаковать')
			for m in d.methods {
				sym := new(Symbol); sym.name = m.name
				ctx.global_scope.symbols[sym.name] = sym
				ctx.decl_symbols[m] = sym
			}
		}

	}

	for decl in prog.decls {
		#partial switch d in decl {
		case ^Impl_Decl:
			for m in d.methods {
				push_scope(ctx)
				args_syms := make([dynamic]^Symbol)
				for arg in m.args {
					sym := new(Symbol); sym.name = arg.name
					ctx.current_scope.symbols[arg.name] = sym
					append(&args_syms, sym)
				}
				ctx.func_args[m] = args_syms
				for stmt in m.body do resolve_stmt(ctx, stmt)
				pop_scope(ctx)
			}

		case ^Function_Decl:
			push_scope(ctx)

			args_syms := make([dynamic]^Symbol)
			for arg in d.args {
				sym := new(Symbol)
				sym.name = arg.name
				ctx.current_scope.symbols[arg.name] = sym
				append(&args_syms, sym)
			}
			ctx.func_args[decl] = args_syms

			for stmt in d.body {
				resolve_stmt(ctx, stmt)
			}

			pop_scope(ctx)
		case ^Struct_Decl:
		// Внутри структуры (пока) нет выражений или локальных переменных,
		// поэтому обходить её тело в Резолвере не нужно.
		}
	}
}

resolve_stmt :: proc(ctx: ^Resolver_Ctx, stmt: Stmt) {
	if stmt == nil do return

	switch s in stmt {
	case ^Let_Stmt:
		resolve_expr(ctx, s.value)

		sym := new(Symbol)
		sym.name = s.name

		if s.name in ctx.current_scope.symbols {
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
	case ^String_Expr:
	case ^Call_Expr:
		resolve_expr(ctx, e.callee)

		for arg in e.args {
			resolve_expr(ctx, arg)
		}
	case ^If_Expr:
		resolve_expr(ctx, e.condition)

		for stmt in e.then_branch {
			resolve_stmt(ctx, stmt)
		}

		for stmt in e.else_branch {
			resolve_stmt(ctx, stmt)
		}

	case ^While_Expr:
		resolve_expr(ctx, e.condition)

		for stmt in e.body {
			resolve_stmt(ctx, stmt)
		}
	case ^Tuple_Expr:
		for el in e.elements {
			resolve_expr(ctx, el)
		}
	case ^Property_Expr:
		resolve_expr(ctx, e.object)
	case ^Lambda_Expr:
		push_scope(ctx)
		args_syms := make([dynamic]^Symbol)
		for arg in e.args {
			sym := new(Symbol); sym.name = arg.name
			ctx.current_scope.symbols[arg.name] = sym
			append(&args_syms, sym)
		}
		ctx.lambda_args[expr] = args_syms
		for stmt in e.body do resolve_stmt(ctx, stmt)
		pop_scope(ctx)
	case ^Array_Expr:
		for el in e.elements {
			resolve_expr(ctx, el)
		}
	case ^Map_Expr:
		for entry in e.entries {
			resolve_expr(ctx, entry.key)
			resolve_expr(ctx, entry.value)
		}
	case ^Index_Expr:
		resolve_expr(ctx, e.object)
		resolve_expr(ctx, e.index)
	}
}

print_resolver_ctx :: proc(ctx: ^Resolver_Ctx) {
	fmt.println("\n================ ТАБЛИЦЫ РЕЗОЛВЕРА ================")

	fmt.println(
		"\n[1] ДЕКЛАРАЦИИ (decl_symbols) - Места создания глобальных символов:",
	)
	if len(ctx.decl_symbols) == 0 do fmt.println("  (пусто)")
	for decl, sym in ctx.decl_symbols {
		switch d in decl {
		case ^Impl_Decl:
			fmt.printf(
				"  [STRUCT] '%s' -> создало Символ по адресу %p\n",
				fmt.tprintf("%s:%s", d.target_type, d.interface_name),
				sym,
			)

		case ^Struct_Decl:
			fmt.printf(
				"  [STRUCT] '%s' -> создало Символ по адресу %p\n",
				d.name,
				sym,
			)
		case ^Interface_Decl:
			fmt.printf(
				"  [INTERFACE] '%s' -> создало Символ по адресу %p\n",
				d.name,
				sym,
			)
		case ^Function_Decl:
			// %p выведет уникальный адрес объекта Symbol (например, 0x14000123450)
			fmt.printf(
				"  [FUNC] '%s' -> создало Символ по адресу %p\n",
				d.name,
				sym,
			)
		}
	}

	fmt.println(
		"\n[2] ЛОКАЛЬНЫЕ ПЕРЕМЕННЫЕ (stmt_symbols) - Места создания локальных символов:",
	)
	if len(ctx.stmt_symbols) == 0 do fmt.println("  (пусто)")
	for stmt, sym in ctx.stmt_symbols {
		#partial switch s in stmt {
		case ^Let_Stmt:
			fmt.printf(
				"  [LET]  '%s' -> создало Символ по адресу %p\n",
				s.name,
				sym,
			)
		}
	}

	fmt.println(
		"\n[3] ИСПОЛЬЗОВАНИЯ (node_symbols) - Куда ссылаются узлы AST:",
	)
	if len(ctx.node_symbols) == 0 do fmt.println("  (пусто)")
	for expr, sym in ctx.node_symbols {
		#partial switch e in expr {
		case ^Ident_Expr:
			fmt.printf(
				"  [EXPR] Идентификатор '%s' -> ссылается на Символ %p\n",
				e.name,
				sym,
			)
		}
	}
	fmt.println("===================================================\n")
}
