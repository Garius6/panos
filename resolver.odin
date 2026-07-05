// resolver.odin
package main

import "core:fmt"

Symbol_Kind :: enum {
	Variable,
	Function,
	Type,
	Module,
}

// Семантическая сущность: локальная переменная, функция, тип или модуль-алиас.
Symbol :: struct {
	name:        string,
	full_name:   string,
	kind:        Symbol_Kind,
	module:      ^Module,
	is_exported: bool,
	decl:        Decls,
}

Module :: struct {
	path:    string,
	dir:     string,
	ast:     Program,
	scope:   ^Scope,
	exports: map[string]^Symbol,
}

Module_Graph :: struct {
	modules:      map[string]^Module,
	order:        [dynamic]^Module,
	loading:      map[string]bool,
	symbol_types: map[^Symbol]^Type,
}

Scope :: struct {
	parent:  ^Scope,
	symbols: map[string]^Symbol,
}

new_module_graph :: proc() -> Module_Graph {
	return Module_Graph {
		modules = make(map[string]^Module),
		order = make([dynamic]^Module),
		loading = make(map[string]bool),
		symbol_types = make(map[^Symbol]^Type),
	}
}

module_dir_name :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' {
			return path[:i]
		}
	}
	return ""
}

module_base_name :: proc(path: string) -> string {
	start := 0
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' {
			start = i + 1
			break
		}
	}

	name := path[start:]
	if len(name) >= 3 && name[len(name) - 3:] == ".ps" {
		return name[:len(name) - 3]
	}
	return name
}

path_has_ps_suffix :: proc(path: string) -> bool {
	return len(path) >= 3 && path[len(path) - 3:] == ".ps"
}

is_absolute_path :: proc(path: string) -> bool {
	return len(path) > 0 && path[0] == '/'
}

normalize_path :: proc(path: string) -> string {
	absolute := is_absolute_path(path)
	parts := make([dynamic]string)

	start := 0
	for i := 0; i <= len(path); i += 1 {
		if i == len(path) || path[i] == '/' {
			part := path[start:i]
			start = i + 1

			if part == "" || part == "." {
				continue
			}

			if part == ".." {
				if len(parts) > 0 && parts[len(parts) - 1] != ".." {
					pop(&parts)
				} else if !absolute {
					append(&parts, part)
				}
				continue
			}

			append(&parts, part)
		}
	}

	result := ""
	if absolute {
		result = "/"
	}
	for part, i in parts {
		if absolute && i == 0 {
			result = fmt.tprintf("/%s", part)
		} else if i > 0 {
			result = fmt.tprintf("%s/%s", result, part)
		} else {
			result = part
		}
	}

	if result == "" {
		return "."
	}
	return result
}

resolve_import_path :: proc(import_spec: string, importer_dir: string) -> string {
	spec := import_spec
	if !path_has_ps_suffix(spec) {
		spec = fmt.tprintf("%s.ps", spec)
	}
	if !is_absolute_path(spec) && len(importer_dir) > 0 {
		spec = fmt.tprintf("%s/%s", importer_dir, spec)
	}
	return normalize_path(spec)
}

new_symbol :: proc(
	name: string,
	kind: Symbol_Kind,
	module: ^Module,
	exported: bool = false,
	decl: Decls = nil,
) -> ^Symbol {
	sym := new(Symbol)
	sym.name = name
	sym.kind = kind
	sym.module = module
	sym.is_exported = exported
	sym.decl = decl
	if module != nil && len(module.path) > 0 {
		sym.full_name = fmt.tprintf("%s::%s", module.path, name)
	} else {
		sym.full_name = name
	}
	return sym
}

Resolver_Ctx :: struct {
	current_scope:  ^Scope,
	global_scope:   ^Scope,
	current_module: ^Module,
	module_graph:   ^Module_Graph,
	symbol_types:   map[^Symbol]^Type,

	// Side Tables
	decl_symbols:   map[Decls]^Symbol,
	stmt_symbols:   map[Stmt]^Symbol,
	node_symbols:   map[Expr]^Symbol,
	func_args:      map[Decls][dynamic]^Symbol,
	lambda_args:    map[Expr][dynamic]^Symbol,
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
		symbol_types = make(map[^Symbol]^Type),
		stmt_symbols = make(map[Stmt]^Symbol),
		decl_symbols = make(map[Decls]^Symbol),
		node_symbols = make(map[Expr]^Symbol),
	}

	push_scope(&ctx)
	ctx.global_scope = ctx.current_scope

	return ctx
}

new_module_resolver_ctx :: proc(graph: ^Module_Graph, module: ^Module) -> Resolver_Ctx {
	ctx := new_resolver_ctx()
	ctx.module_graph = graph
	ctx.current_module = module
	ctx.symbol_types = graph.symbol_types
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

register_top_level_decl :: proc(ctx: ^Resolver_Ctx, module: ^Module, decl: Decls) {
	switch d in decl {
	case ^Import_Decl:
		import_path := resolve_import_path(d.path, module.dir)
		imported_module, ok := ctx.module_graph.modules[import_path]
		if !ok {
			fmt.panicf("Resolve Error: модуль '%s' не найден", d.path)
		}

		alias := d.alias
		if alias == "" {
			alias = module_base_name(import_path)
		}
		if alias in module.scope.symbols {
			fmt.panicf("Resolve Error: символ '%s' уже объявлен", alias)
		}

		sym := new_symbol(alias, .Module, module)
		sym.module = imported_module
		module.scope.symbols[alias] = sym

	case ^Function_Decl:
		sym := new_symbol(d.name, .Function, module, d.is_exported, decl)
		if sym.name in module.scope.symbols {
			fmt.panicf("Resolve Error: символ '%s' уже объявлен", sym.name)
		}
		module.scope.symbols[sym.name] = sym
		ctx.decl_symbols[decl] = sym
		if d.is_exported {
			module.exports[sym.name] = sym
		}

	case ^Struct_Decl:
		sym := new_symbol(d.name, .Type, module, d.is_exported, decl)
		if sym.name in module.scope.symbols {
			fmt.panicf("Resolve Error: символ '%s' уже объявлен", sym.name)
		}
		module.scope.symbols[sym.name] = sym
		ctx.decl_symbols[decl] = sym
		if d.is_exported {
			module.exports[sym.name] = sym
		}

	case ^Interface_Decl:
		sym := new_symbol(d.name, .Type, module, d.is_exported, decl)
		if sym.name in module.scope.symbols {
			fmt.panicf("Resolve Error: символ '%s' уже объявлен", sym.name)
		}
		module.scope.symbols[sym.name] = sym
		ctx.decl_symbols[decl] = sym
		if d.is_exported {
			module.exports[sym.name] = sym
		}

	case ^Impl_Decl:
		for m in d.methods {
			sym := new_symbol(m.name, .Function, module, false, m)
			if sym.name in module.scope.symbols {
				fmt.panicf("Resolve Error: символ '%s' уже объявлен", sym.name)
			}
			module.scope.symbols[sym.name] = sym
			ctx.decl_symbols[m] = sym
		}
	}
}

resolve_module :: proc(graph: ^Module_Graph, module: ^Module) -> Resolver_Ctx {
	ctx := new_module_resolver_ctx(graph, module)
	module.scope = ctx.global_scope
	if module.exports == nil {
		module.exports = make(map[string]^Symbol)
	}

	for decl in module.ast.decls {
		register_top_level_decl(&ctx, module, decl)
	}

	for decl in module.ast.decls {
		#partial switch d in decl {
		case ^Import_Decl:
		// Импорты уже зарегистрированы в первом проходе.
		case ^Impl_Decl:
			for m in d.methods {
				push_scope(&ctx)
				args_syms := make([dynamic]^Symbol)
				for arg in m.args {
					sym := new_symbol(arg.name, .Variable, module)
					ctx.current_scope.symbols[arg.name] = sym
					append(&args_syms, sym)
				}
				ctx.func_args[m] = args_syms
				for stmt in m.body do resolve_stmt(&ctx, stmt)
				pop_scope(&ctx)
			}

		case ^Function_Decl:
			push_scope(&ctx)

			args_syms := make([dynamic]^Symbol)
			for arg in d.args {
				sym := new_symbol(arg.name, .Variable, module)
				ctx.current_scope.symbols[arg.name] = sym
				append(&args_syms, sym)
			}
			ctx.func_args[decl] = args_syms

			for stmt in d.body {
				resolve_stmt(&ctx, stmt)
			}

			pop_scope(&ctx)
		case ^Struct_Decl:
		case ^Interface_Decl:
		}
	}

	return ctx
}

resolve_program :: proc(ctx: ^Resolver_Ctx, prog: Program) {
	module := Module {
		path    = "",
		dir     = "",
		ast     = prog,
		scope   = nil,
		exports = make(map[string]^Symbol),
	}
	if ctx.global_scope == nil {
		push_scope(ctx)
		ctx.global_scope = ctx.current_scope
	}
	module.scope = ctx.global_scope
	graph := new_module_graph()
	resolved := resolve_module(&graph, &module)
	resolved.module_graph = nil
	resolved.current_module = nil
	ctx^ = resolved
}

resolve_stmt :: proc(ctx: ^Resolver_Ctx, stmt: Stmt) {
	if stmt == nil do return

	switch s in stmt {
	case ^Let_Stmt:
		resolve_expr(ctx, s.value)

		sym := new_symbol(s.name, .Variable, ctx.current_module)
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
		if obj_ident, ok := e.object.(^Ident_Expr); ok {
			if obj_sym := lookup_symbol(ctx.current_scope, obj_ident.name);
			   obj_sym != nil && obj_sym.kind == .Module {
				imported_module := obj_sym.module
				if imported_module == nil {
					fmt.panicf(
						"Resolve Error: модуль '%s' не найден",
						obj_ident.name,
					)
				}
				if export_sym, found := imported_module.exports[e.property]; found {
					ctx.node_symbols[expr] = export_sym
					return
				}
				fmt.panicf(
					"Resolve Error: модуль '%s' не экспортирует '%s'",
					obj_ident.name,
					e.property,
				)
			}
		}
	case ^Lambda_Expr:
		push_scope(ctx)
		args_syms := make([dynamic]^Symbol)
		for arg in e.args {
			sym := new_symbol(arg.name, .Variable, ctx.current_module)
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
		case ^Import_Decl:
			fmt.printf(
				"  [IMPORT] '%s'%s\n",
				d.path,
				d.alias != "" ? fmt.tprintf(" as %s", d.alias) : "",
			)
		case ^Impl_Decl:
			fmt.printf(
				"  [STRUCT] '%s' -> %s (%p)\n",
				fmt.tprintf("%s:%s", d.target_type, d.interface_name),
				sym.full_name,
				sym,
			)

		case ^Struct_Decl:
			fmt.printf("  [STRUCT] '%s' -> %s (%p)\n", d.name, sym.full_name, sym)
		case ^Interface_Decl:
			fmt.printf("  [INTERFACE] '%s' -> %s (%p)\n", d.name, sym.full_name, sym)
		case ^Function_Decl:
			// %p выведет уникальный адрес объекта Symbol (например, 0x14000123450)
			fmt.printf("  [FUNC] '%s' -> %s (%p)\n", d.name, sym.full_name, sym)
		}
	}

	fmt.println(
		"\n[2] ЛОКАЛЬНЫЕ ПЕРЕМЕННЫЕ (stmt_symbols) - Места создания локальных символов:",
	)
	if len(ctx.stmt_symbols) == 0 do fmt.println("  (пусто)")
	for stmt, sym in ctx.stmt_symbols {
		#partial switch s in stmt {
		case ^Let_Stmt:
			fmt.printf("  [LET]  '%s' -> %s (%p)\n", s.name, sym.full_name, sym)
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
				"  [EXPR] Идентификатор '%s' -> %s (%p)\n",
				e.name,
				sym.full_name,
				sym,
			)
		}
	}
	fmt.println("===================================================\n")
}
