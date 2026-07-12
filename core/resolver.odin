// resolver.odin
package core

import "core:fmt"
import "core:os"

Symbol_Kind :: enum {
	Variable,
	Function,
	Type,
	Module,
	Builtin,
	Enum_Variant,
}

// Семантическая сущность: локальная переменная, функция, тип или модуль-алиас.
Symbol :: struct {
	name:              Interned,
	full_name:         Interned,
	kind:              Symbol_Kind,
	module:            ^Module,
	is_exported:       bool,
	decl:              Decls,
	owner_type:        ^Symbol,
	is_pattern_binder: bool,
	// Span объявления — для LSP go-to-definition. Zero-value у builtin'ов
	// (нет исходника, куда прыгать).
	span:              Span,
}

Module :: struct {
	path:    string,
	dir:     string,
	ast:     Program,
	scope:   ^Scope,
	exports: map[Interned]^Symbol,
	file_id: u16,
	source:  string,
}

Module_Graph :: struct {
	modules:      map[string]^Module,
	order:        [dynamic]^Module,
	loading:      map[string]bool,
	symbol_types: map[^Symbol]^Type,
	// file_id → путь/исходник, нужно чтобы превратить Span в line:col при
	// печати diagnostic'а (Span хранит только file_id, не путь).
	file_paths:   map[u16]string,
	file_sources: map[u16]string,
}

Scope :: struct {
	parent:  ^Scope,
	symbols: map[Interned]^Symbol,
}

new_module_graph :: proc() -> Module_Graph {
	return Module_Graph {
		modules = make(map[string]^Module),
		order = make([dynamic]^Module),
		loading = make(map[string]bool),
		symbol_types = make(map[^Symbol]^Type),
		file_paths = make(map[u16]string),
		file_sources = make(map[u16]string),
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

is_bare_import_spec :: proc(import_spec: string) -> bool {
	if is_absolute_path(import_spec) {
		return false
	}

	for ch in import_spec {
		if ch == '/' {
			return false
		}
	}
	return true
}

resolve_existing_import_path :: proc(import_spec: string, importer_dir: string) -> (string, bool) {
	fmt.printf("Резолвим модуль %s %s\n", import_spec, importer_dir)

	local_path := resolve_import_path(import_spec, importer_dir)
	if os.exists(local_path) {
		return local_path, true
	}

	// if is_bare_import_spec(import_spec) {
	modules_path := resolve_import_path(import_spec, "модули")
	if os.exists(modules_path) {
		return modules_path, true
	}

	if env_dir, found := os.lookup_env("PANOS_STDLIB", context.allocator); found {
		stdlib_path := resolve_import_path(import_spec, env_dir)
		if os.exists(stdlib_path) {
			return stdlib_path, true
		}
	}

	stdlib_path := resolve_import_path(import_spec, "std")
	if os.exists(stdlib_path) {
		return stdlib_path, true
	}
	// }

	return local_path, false
}

new_symbol :: proc(
	name: string,
	kind: Symbol_Kind,
	module: ^Module,
	exported: bool = false,
	decl: Decls = nil,
	span: Span = {},
) -> ^Symbol {
	sym := new(Symbol)
	sym.name = intern(name)
	sym.kind = kind
	sym.module = module
	sym.is_exported = exported
	sym.decl = decl
	sym.span = span
	if module != nil && len(module.path) > 0 {
		sym.full_name = intern(fmt.tprintf("%s::%s", module.path, name))
	} else {
		sym.full_name = sym.name
	}
	return sym
}

Resolver_Ctx :: struct {
	current_scope:   ^Scope,
	global_scope:    ^Scope,
	current_module:  ^Module,
	module_graph:    ^Module_Graph,
	symbol_types:    map[^Symbol]^Type,
	pattern_binders: map[^Pattern_Ident]^Symbol,

	// Side Tables
	decl_symbols:    map[Decls]^Symbol,
	stmt_symbols:    map[Stmt]^Symbol,
	node_symbols:    map[Expr]^Symbol,
	func_args:       map[Decls][dynamic]^Symbol,
	lambda_args:     map[Expr][dynamic]^Symbol,
}

push_scope :: proc(resolver: ^Resolver_Ctx) {
	new_scope := new(Scope)
	new_scope.parent = resolver.current_scope
	new_scope.symbols = make(map[Interned]^Symbol)
	resolver.current_scope = new_scope
}

pop_scope :: proc(resolver: ^Resolver_Ctx) {
	if resolver.current_scope.parent != nil {
		resolver.current_scope = resolver.current_scope.parent
	}
}

install_standard_symbols :: proc(ctx: ^Resolver_Ctx) {
	names := [?]string {
		"Ошибка",
		"Есть",
		"Нет",
		"Успех",
		"Неудача",
		"длина",
		"паника",
	}
	for name in names {
		sym := new_symbol(name, .Builtin, nil)
		ctx.current_scope.symbols[sym.name] = sym
	}
}

new_resolver_ctx :: proc() -> Resolver_Ctx {
	ctx := Resolver_Ctx {
		symbol_types    = make(map[^Symbol]^Type),
		stmt_symbols    = make(map[Stmt]^Symbol),
		decl_symbols    = make(map[Decls]^Symbol),
		node_symbols    = make(map[Expr]^Symbol),
		pattern_binders = make(map[^Pattern_Ident]^Symbol),
	}

	push_scope(&ctx)
	ctx.global_scope = ctx.current_scope
	install_standard_symbols(&ctx)

	return ctx
}

new_module_resolver_ctx :: proc(graph: ^Module_Graph, module: ^Module) -> Resolver_Ctx {
	ctx := new_resolver_ctx()
	ctx.module_graph = graph
	ctx.current_module = module
	ctx.symbol_types = graph.symbol_types
	return ctx
}

lookup_symbol :: proc(s: ^Scope, name: Interned) -> ^Symbol {
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
	#partial switch d in decl {
	case ^Import_Decl:
		import_path, exists := resolve_existing_import_path(d.path, module.dir)
		imported_module, ok := ctx.module_graph.modules[import_path]
		if !ok && !exists && is_builtin_module_name(d.path) {
			imported_module = ensure_builtin_module(ctx.module_graph, d.path)
			ok = imported_module != nil
		}
		if !ok {
			fmt.panicf("Resolve Error: модуль '%s' не найден", d.path)
		}

		alias := d.alias
		if alias == "" {
			alias = module_base_name(import_path)
		}
		if intern(alias) in module.scope.symbols {
			fmt.panicf("Resolve Error: символ '%s' уже объявлен", alias)
		}

		sym := new_symbol(alias, .Module, module, span = d.span)
		sym.module = imported_module
		module.scope.symbols[sym.name] = sym

	case ^Function_Decl:
		sym := new_symbol(d.name, .Function, module, d.is_exported, decl, d.span)
		if sym.name in module.scope.symbols {
			fmt.panicf("Resolve Error: символ '%s' уже объявлен", resolve_interned(sym.name))
		}
		module.scope.symbols[sym.name] = sym
		ctx.decl_symbols[decl] = sym
		if d.is_exported {
			module.exports[sym.name] = sym
		}

	case ^Struct_Decl:
		sym := new_symbol(d.name, .Type, module, d.is_exported, decl, d.span)
		if sym.name in module.scope.symbols {
			fmt.panicf("Resolve Error: символ '%s' уже объявлен", resolve_interned(sym.name))
		}
		module.scope.symbols[sym.name] = sym
		ctx.decl_symbols[decl] = sym
		if d.is_exported {
			module.exports[sym.name] = sym
		}

	case ^Interface_Decl:
		sym := new_symbol(d.name, .Type, module, d.is_exported, decl, d.span)
		if sym.name in module.scope.symbols {
			fmt.panicf("Resolve Error: символ '%s' уже объявлен", resolve_interned(sym.name))
		}
		module.scope.symbols[sym.name] = sym
		ctx.decl_symbols[decl] = sym
		if d.is_exported {
			module.exports[sym.name] = sym
		}

	case ^Impl_Decl:
		for m in d.methods {
			sym := new_symbol(m.name, .Function, module, false, m, m.span)
			if sym.name in module.scope.symbols {
				fmt.panicf("Resolve Error: символ '%s' уже объявлен", resolve_interned(sym.name))
			}
			module.scope.symbols[sym.name] = sym
			ctx.decl_symbols[m] = sym
		}

	case ^Enum_Decl:
		type_sym := new_symbol(d.name, .Type, module, d.is_exported, decl, d.span)
		if type_sym.name in module.scope.symbols {
			fmt.panicf("Resolve Error: символ '%s' уже объявлен", resolve_interned(type_sym.name))
		}
		module.scope.symbols[type_sym.name] = type_sym
		ctx.decl_symbols[decl] = type_sym
		if d.is_exported {
			module.exports[type_sym.name] = type_sym
		}

		for variant in d.variants {
			if intern(variant.name) in module.scope.symbols {
				fmt.panicf(
					"Resolve Error: имя варианта '%s' конфликтует с уже объявленным символом в модуле",
					variant.name,
				)
			}
			variant_sym := new_symbol(variant.name, .Enum_Variant, module, d.is_exported, decl, variant.span)
			variant_sym.owner_type = type_sym
			module.scope.symbols[variant_sym.name] = variant_sym
			if d.is_exported {
				module.exports[variant_sym.name] = variant_sym
			}
		}
	}
}

resolve_module :: proc(graph: ^Module_Graph, module: ^Module) -> Resolver_Ctx {
	ctx := new_module_resolver_ctx(graph, module)
	module.scope = ctx.global_scope
	if module.exports == nil {
		module.exports = make(map[Interned]^Symbol)
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
					sym := new_symbol(arg.name, .Variable, module, span = arg.span)
					ctx.current_scope.symbols[sym.name] = sym
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
				sym := new_symbol(arg.name, .Variable, module, span = arg.span)
				ctx.current_scope.symbols[sym.name] = sym
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
		exports = make(map[Interned]^Symbol),
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

resolve_pattern :: proc(ctx: ^Resolver_Ctx, pattern: Pattern) {
	switch p in pattern {
	case ^Pattern_Wildcard:
	// ничего не привязывает
	case ^Pattern_Literal:
		fmt.panicf(
			"Semantic Error: литеральные шаблоны в выборе пока не поддерживаются",
		)
	case ^Pattern_Ident:
		if p.name == "_" {
			// Формально не должно случиться — parse_pattern уже
			// превращает "_" в Pattern_Wildcard.
			return
		}
		if sym := lookup_symbol(ctx.current_scope, intern(p.name)); sym != nil &&
		   sym.kind == .Enum_Variant {
			// Zero-field constructor pattern; захватывать нечего.
			ctx.pattern_binders[p] = sym
		} else {
			// Обычный биндер.
			binder := new_symbol(p.name, .Variable, ctx.current_module, span = p.span)
			binder.is_pattern_binder = true
			ctx.current_scope.symbols[binder.name] = binder
			ctx.pattern_binders[p] = binder
		}
	case ^Pattern_Constructor:
		// Резолвим квалификатор при необходимости и рекурсивно шаблоны
		// аргументов. Само имя варианта разрешит type checker.
		for arg in p.args {
			resolve_pattern(ctx, arg)
		}
	}
}

resolve_stmt :: proc(ctx: ^Resolver_Ctx, stmt: Stmt) {
	if stmt == nil do return

	switch s in stmt {
	case ^Let_Stmt:
		resolve_expr(ctx, s.value)

		sym := new_symbol(s.name, .Variable, ctx.current_module, span = s.span)
		if intern(s.name) in ctx.current_scope.symbols {
			fmt.panicf("Имя %s уже объявлено", s.name)
		}
		ctx.current_scope.symbols[sym.name] = sym

		// 4. Кэшируем создание в Side Table
		ctx.stmt_symbols[stmt] = sym

	case ^Return_Stmt:
		resolve_expr(ctx, s.value)

	case ^Expr_Stmt:
		resolve_expr(ctx, s.expr)

	case ^Continue_Stmt:
	case ^Break_Stmt:
	}
}

resolve_expr :: proc(ctx: ^Resolver_Ctx, expr: Expr) {
	if expr == nil do return

	switch e in expr {
	case ^Ident_Expr:
		sym := lookup_symbol(ctx.current_scope, e.name)
		if sym == nil {
			fmt.panicf("Resolve Error: undefined variable '%s'", resolve_interned(e.name))
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
		obj_sym: ^Symbol
		if obj_ident, ok := e.object.(^Ident_Expr); ok {
			obj_sym = lookup_symbol(ctx.current_scope, obj_ident.name)
		} else {
			obj_sym = ctx.node_symbols[e.object]
		}
		if obj_sym != nil {
			if obj_sym.kind == .Module {
				imported_module := obj_sym.module
				if imported_module == nil {
					fmt.panicf(
						"Resolve Error: модуль '%s' не найден",
						resolve_interned(obj_sym.name),
					)
				}
				if export_sym, found := imported_module.exports[intern(e.property)]; found {
					ctx.node_symbols[expr] = export_sym
					return
				}
				fmt.panicf(
					"Resolve Error: модуль '%s' не экспортирует '%s'",
					resolve_interned(obj_sym.name),
					e.property,
				)
			}
			if obj_sym.kind == .Type {
				if _, is_enum := obj_sym.decl.(^Enum_Decl); is_enum {
					owner_module := obj_sym.module
					if owner_module == nil ||
					   owner_module.scope == nil {
						fmt.panicf(
							"Resolve Error: модуль-владелец типа '%s' недоступен",
							resolve_interned(obj_sym.name),
						)
					}
					variant_sym, found := owner_module.scope.symbols[intern(e.property)]
					if !found ||
					   variant_sym.kind != .Enum_Variant ||
					   variant_sym.owner_type != obj_sym {
						fmt.panicf(
							"Resolve Error: у типа '%s' нет варианта '%s'",
							resolve_interned(obj_sym.name),
							e.property,
						)
					}
					ctx.node_symbols[expr] = variant_sym
					return
				}
			}
		}
	case ^Lambda_Expr:
		push_scope(ctx)
		args_syms := make([dynamic]^Symbol)
		for arg in e.args {
			sym := new_symbol(arg.name, .Variable, ctx.current_module, span = arg.span)
			ctx.current_scope.symbols[sym.name] = sym
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
	case ^Try_Expr:
		resolve_expr(ctx, e.value)

	case ^Match_Expr:
		resolve_expr(ctx, e.subject)
		for arm in e.arms {
			push_scope(ctx)
			resolve_pattern(ctx, arm.pattern)
			for stmt in arm.body do resolve_stmt(ctx, stmt)
			pop_scope(ctx)
		}
	}
}

print_resolver_ctx :: proc(ctx: ^Resolver_Ctx) {
	fmt.println("\n================ ТАБЛИЦЫ РЕЗОЛВЕРА ================")

	fmt.println(
		"\n[1] ДЕКЛАРАЦИИ (decl_symbols) - Места создания глобальных символов:",
	)
	if len(ctx.decl_symbols) == 0 do fmt.println("  (пусто)")
	for decl, sym in ctx.decl_symbols {
		#partial switch d in decl {
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
				resolve_interned(sym.full_name),
				sym,
			)

		case ^Struct_Decl:
			fmt.printf("  [STRUCT] '%s' -> %s (%p)\n", d.name, resolve_interned(sym.full_name), sym)
		case ^Interface_Decl:
			fmt.printf("  [INTERFACE] '%s' -> %s (%p)\n", d.name, resolve_interned(sym.full_name), sym)
		case ^Function_Decl:
			// %p выведет уникальный адрес объекта Symbol (например, 0x14000123450)
			fmt.printf("  [FUNC] '%s' -> %s (%p)\n", d.name, resolve_interned(sym.full_name), sym)
		}
	}

	fmt.println(
		"\n[2] ЛОКАЛЬНЫЕ ПЕРЕМЕННЫЕ (stmt_symbols) - Места создания локальных символов:",
	)
	if len(ctx.stmt_symbols) == 0 do fmt.println("  (пусто)")
	for stmt, sym in ctx.stmt_symbols {
		#partial switch s in stmt {
		case ^Let_Stmt:
			fmt.printf("  [LET]  '%s' -> %s (%p)\n", s.name, resolve_interned(sym.full_name), sym)
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
				resolve_interned(e.name),
				resolve_interned(sym.full_name),
				sym,
			)
		}
	}
	fmt.println("===================================================\n")
}
