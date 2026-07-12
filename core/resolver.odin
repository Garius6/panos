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
	owner_type:        Symbol_Id,
	is_pattern_binder: bool,
	// Span объявления — для LSP go-to-definition. Zero-value у builtin'ов
	// (нет исходника, куда прыгать).
	span:              Span,
}

// Стабильный хэндл на Symbol вместо ^Symbol — индекс в Symbol_Store. Даёт
// дешёвые cross-reference таблицы (Symbol_Id -> [dynamic]Usage_Site для LSP
// find-references/rename), не завязанные на адрес объекта в памяти.
Symbol_Id :: distinct u32

// Индекс 0 зарезервирован под sentinel (как Interned(0) под ""): нет символа.
INVALID_SYMBOL :: Symbol_Id(0)

Symbol_Store :: struct {
	symbols: [dynamic]Symbol,
}

// ^Symbol_Store всегда живёт в куче (см. new_symbol_store) — это позволяет
// свободно копировать содержащие его структуры (Resolver_Ctx, Module_Graph)
// по значению, не боясь расхождения backing-массива.
new_symbol_store :: proc() -> ^Symbol_Store {
	store := new(Symbol_Store)
	store.symbols = make([dynamic]Symbol)
	append(&store.symbols, Symbol{}) // индекс 0 = INVALID_SYMBOL sentinel
	return store
}

// Возвращает копию Symbol по значению — Symbol не хранит крупных встроенных
// массивов, копия дешева и безопасна (не зависит от того, реаллоцировался ли
// backing-массив store между созданием символа и чтением).
symbol_at :: proc(store: ^Symbol_Store, id: Symbol_Id) -> Symbol {
	return store.symbols[id]
}

Module :: struct {
	path:     string,
	dir:      string,
	ast:      Program,
	scope:    ^Scope,
	exports:  map[Interned]Symbol_Id,
	file_id:  u16,
	source:   string,
	// Варианты перечислений НЕ живут в scope.symbols (см. register_top_level_decl
	// Enum_Decl) — иначе два разных `тип X = перечисление` с одноимённым
	// вариантом (напр. оба "Точка") конфликтовали бы как "уже объявлено",
	// хотя логически не пересекаются. Ключ первого уровня — Symbol_Id
	// типа-владельца, чтобы Тип1.Вариант и Тип2.Вариант с одинаковым
	// именем не перетирали друг друга в одной плоской map. Доступ к
	// варианту теперь ТОЛЬКО квалифицированный (Тип.Вариант) — bare
	// `Вариант(...)` как конструктор-выражение больше не резолвится
	// (см. Property_Expr в resolve_expr). Шаблоны в `выбор` (Pattern_Ident/
	// Pattern_Constructor) это не затрагивает — они резолвят имя варианта
	// по expected_type в type_cheker.odin, никогда не ходили через scope.
	variants: map[Symbol_Id]map[Interned]Symbol_Id,
}

Module_Graph :: struct {
	modules:          map[string]^Module,
	order:            [dynamic]^Module,
	loading:          map[string]bool,
	symbol_types:     map[Symbol_Id]^Type,
	symbol_store:     ^Symbol_Store,
	// file_id → путь/исходник, нужно чтобы превратить Span в line:col при
	// печати diagnostic'а (Span хранит только file_id, не путь).
	file_paths:       map[u16]string,
	file_sources:     map[u16]string,
	// Parser.diagnostics каждого загруженного модуля — Parser живёт только
	// внутри load_module_recursive, поэтому собираем сюда, иначе они
	// терялись бы вместе с локальным Parser'ом.
	parse_diagnostics: [dynamic]Diagnostic,
	// LSP: module_key (нормализованный путь) -> текст из редактора, для
	// модулей, которые сейчас открыты как буферы. Пусто вне LSP — CLI
	// (main.odin) всегда читает с диска.
	source_overrides:  map[string]string,
}

Scope :: struct {
	parent:  ^Scope,
	symbols: map[Interned]Symbol_Id,
}

new_module_graph :: proc() -> Module_Graph {
	return Module_Graph {
		modules = make(map[string]^Module),
		order = make([dynamic]^Module),
		loading = make(map[string]bool),
		symbol_types = make(map[Symbol_Id]^Type),
		symbol_store = new_symbol_store(),
		file_paths = make(map[u16]string),
		file_sources = make(map[u16]string),
		parse_diagnostics = make([dynamic]Diagnostic),
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
	store: ^Symbol_Store,
	name: string,
	kind: Symbol_Kind,
	module: ^Module,
	exported: bool = false,
	decl: Decls = nil,
	span: Span = {},
	owner_type: Symbol_Id = INVALID_SYMBOL,
	is_pattern_binder: bool = false,
	// Для kind == .Module: символ должен указывать на импортированный модуль,
	// а не на модуль-импортёр (тот нужен только для вычисления full_name).
	module_override: ^Module = nil,
) -> Symbol_Id {
	sym := Symbol {
		name              = intern(name),
		kind              = kind,
		module            = module,
		is_exported       = exported,
		decl              = decl,
		span              = span,
		owner_type        = owner_type,
		is_pattern_binder = is_pattern_binder,
	}
	if module != nil && len(module.path) > 0 {
		sym.full_name = intern(fmt.tprintf("%s::%s", module.path, name))
	} else {
		sym.full_name = sym.name
	}
	if module_override != nil {
		sym.module = module_override
	}
	id := Symbol_Id(len(store.symbols))
	append(&store.symbols, sym)
	return id
}

Resolver_Ctx :: struct {
	current_scope:   ^Scope,
	global_scope:    ^Scope,
	current_module:  ^Module,
	module_graph:    ^Module_Graph,
	symbol_store:    ^Symbol_Store,
	symbol_types:    map[Symbol_Id]^Type,
	pattern_binders: map[^Pattern_Ident]Symbol_Id,
	// Diagnostic/Severity из type_cheker.odin — тот же package, тот же
	// accumulate-not-panic паттерн, что и в парсере/тайпчекере.
	diagnostics:     [dynamic]Diagnostic,

	// Side Tables
	decl_symbols:    map[Decls]Symbol_Id,
	stmt_symbols:    map[Stmt]Symbol_Id,
	node_symbols:    map[Expr]Symbol_Id,
	func_args:       map[Decls][dynamic]Symbol_Id,
	lambda_args:     map[Expr][dynamic]Symbol_Id,
}

report_resolve :: proc(ctx: ^Resolver_Ctx, span: Span, format: string, args: ..any) {
	msg := fmt.aprintf(format, ..args)
	for d in ctx.diagnostics {
		if d.span == span && d.message == msg do return
	}
	append(&ctx.diagnostics, Diagnostic{severity = .Error, span = span, message = msg})
}

push_scope :: proc(resolver: ^Resolver_Ctx) {
	new_scope := new(Scope)
	new_scope.parent = resolver.current_scope
	new_scope.symbols = make(map[Interned]Symbol_Id)
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
		sym := new_symbol(ctx.symbol_store, name, .Builtin, nil)
		ctx.current_scope.symbols[intern(name)] = sym
	}
}

new_resolver_ctx :: proc() -> Resolver_Ctx {
	ctx := Resolver_Ctx {
		symbol_store    = new_symbol_store(),
		symbol_types    = make(map[Symbol_Id]^Type),
		stmt_symbols    = make(map[Stmt]Symbol_Id),
		decl_symbols    = make(map[Decls]Symbol_Id),
		node_symbols    = make(map[Expr]Symbol_Id),
		pattern_binders = make(map[^Pattern_Ident]Symbol_Id),
		diagnostics     = make([dynamic]Diagnostic),
	}

	push_scope(&ctx)
	ctx.global_scope = ctx.current_scope
	install_standard_symbols(&ctx)

	return ctx
}

new_module_resolver_ctx :: proc(graph: ^Module_Graph, module: ^Module) -> Resolver_Ctx {
	// Не через new_resolver_ctx(): она ставит собственный свежий
	// symbol_store и сразу устанавливает в него builtin'ы — если потом
	// подменить symbol_store на graph.symbol_store, Symbol_Id builtin'ов
	// (уже записанные в scope) будут указывать в чужой, отброшенный store
	// (id's коллизия — напр. "Есть" получало тот же #2, что и первая
	// пользовательская переменная модуля). Строим ctx сразу на
	// graph.symbol_store, чтобы install_standard_symbols писала builtin'ы
	// в тот же store, что будет использоваться дальше.
	ctx := Resolver_Ctx {
		symbol_store    = graph.symbol_store,
		symbol_types    = graph.symbol_types,
		stmt_symbols    = make(map[Stmt]Symbol_Id),
		decl_symbols    = make(map[Decls]Symbol_Id),
		node_symbols    = make(map[Expr]Symbol_Id),
		pattern_binders = make(map[^Pattern_Ident]Symbol_Id),
		diagnostics     = make([dynamic]Diagnostic),
	}
	push_scope(&ctx)
	ctx.global_scope = ctx.current_scope
	install_standard_symbols(&ctx)
	ctx.module_graph = graph
	ctx.current_module = module
	return ctx
}

lookup_symbol :: proc(s: ^Scope, name: Interned) -> Symbol_Id {
	sym, found := s.symbols[name]
	if found {
		return sym
	}

	if s.parent != nil {
		return lookup_symbol(s.parent, name)
	}

	return INVALID_SYMBOL
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
			report_resolve(ctx, d.span, "Resolve Error: модуль '%s' не найден", d.path)
			return
		}

		alias := d.alias
		if alias == "" {
			alias = module_base_name(import_path)
		}
		alias_id := intern(alias)
		if alias_id in module.scope.symbols {
			report_resolve(ctx, d.span, "Resolve Error: символ '%s' уже объявлен", alias)
			return
		}

		sym := new_symbol(ctx.symbol_store, alias, .Module, module, span = d.span, module_override = imported_module)
		module.scope.symbols[alias_id] = sym

	case ^Function_Decl:
		sym := new_symbol(ctx.symbol_store, d.name, .Function, module, d.is_exported, decl, d.span)
		name_id := intern(d.name)
		ctx.decl_symbols[decl] = sym
		if name_id in module.scope.symbols {
			report_resolve(ctx, d.span, "Resolve Error: символ '%s' уже объявлен", d.name)
		} else {
			module.scope.symbols[name_id] = sym
			if d.is_exported {
				module.exports[name_id] = sym
			}
		}

	case ^Struct_Decl:
		sym := new_symbol(ctx.symbol_store, d.name, .Type, module, d.is_exported, decl, d.span)
		name_id := intern(d.name)
		ctx.decl_symbols[decl] = sym
		if name_id in module.scope.symbols {
			report_resolve(ctx, d.span, "Resolve Error: символ '%s' уже объявлен", d.name)
		} else {
			module.scope.symbols[name_id] = sym
			if d.is_exported {
				module.exports[name_id] = sym
			}
		}

	case ^Interface_Decl:
		sym := new_symbol(ctx.symbol_store, d.name, .Type, module, d.is_exported, decl, d.span)
		name_id := intern(d.name)
		ctx.decl_symbols[decl] = sym
		if name_id in module.scope.symbols {
			report_resolve(ctx, d.span, "Resolve Error: символ '%s' уже объявлен", d.name)
		} else {
			module.scope.symbols[name_id] = sym
			if d.is_exported {
				module.exports[name_id] = sym
			}
		}

	case ^Impl_Decl:
		for m in d.methods {
			sym := new_symbol(ctx.symbol_store, m.name, .Function, module, false, m, m.span)
			name_id := intern(m.name)
			ctx.decl_symbols[m] = sym
			if name_id in module.scope.symbols {
				report_resolve(ctx, m.span, "Resolve Error: символ '%s' уже объявлен", m.name)
			} else {
				module.scope.symbols[name_id] = sym
			}
		}

	case ^Enum_Decl:
		type_name_id := intern(d.name)
		type_sym := new_symbol(ctx.symbol_store, d.name, .Type, module, d.is_exported, decl, d.span)
		ctx.decl_symbols[decl] = type_sym
		if type_name_id in module.scope.symbols {
			report_resolve(ctx, d.span, "Resolve Error: символ '%s' уже объявлен", d.name)
		} else {
			module.scope.symbols[type_name_id] = type_sym
			if d.is_exported {
				module.exports[type_name_id] = type_sym
			}
		}

		for variant in d.variants {
			variant_name_id := intern(variant.name)
			variant_sym := new_symbol(
				ctx.symbol_store,
				variant.name,
				.Enum_Variant,
				module,
				d.is_exported,
				decl,
				variant.span,
				owner_type = type_sym,
			)
			// Дубликат ИМЕНИ ВНУТРИ одного и того же перечисления ловит
			// парсер ("вариант 'X' объявлен дважды в 'Y'") — сюда попадают
			// уже различные (enum, variant_name) пары, коллизий между
			// РАЗНЫМИ типами больше не бывает по конструкции map'ы.
			if module.variants == nil {
				module.variants = make(map[Symbol_Id]map[Interned]Symbol_Id)
			}
			inner_variants, has_inner := module.variants[type_sym]
			if !has_inner {
				inner_variants = make(map[Interned]Symbol_Id)
			}
			inner_variants[variant_name_id] = variant_sym
			module.variants[type_sym] = inner_variants
			if d.is_exported {
				module.exports[variant_name_id] = variant_sym
			}
		}
	}
}

resolve_module :: proc(graph: ^Module_Graph, module: ^Module) -> Resolver_Ctx {
	ctx := new_module_resolver_ctx(graph, module)
	module.scope = ctx.global_scope
	if module.exports == nil {
		module.exports = make(map[Interned]Symbol_Id)
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
				args_syms := make([dynamic]Symbol_Id)
				for arg in m.args {
					sym := new_symbol(ctx.symbol_store, arg.name, .Variable, module, span = arg.span)
					ctx.current_scope.symbols[intern(arg.name)] = sym
					append(&args_syms, sym)
				}
				ctx.func_args[m] = args_syms
				for stmt in m.body do resolve_stmt(&ctx, stmt)
				pop_scope(&ctx)
			}

		case ^Function_Decl:
			push_scope(&ctx)

			args_syms := make([dynamic]Symbol_Id)
			for arg in d.args {
				sym := new_symbol(ctx.symbol_store, arg.name, .Variable, module, span = arg.span)
				ctx.current_scope.symbols[intern(arg.name)] = sym
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
		exports = make(map[Interned]Symbol_Id),
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
		report_resolve(ctx, p.span, "Semantic Error: литеральные шаблоны в выборе пока не поддерживаются")
	case ^Pattern_Ident:
		if p.name == "_" {
			// Формально не должно случиться — parse_pattern уже
			// превращает "_" в Pattern_Wildcard.
			return
		}
		sym := lookup_symbol(ctx.current_scope, intern(p.name))
		if sym != INVALID_SYMBOL && symbol_at(ctx.symbol_store, sym).kind == .Enum_Variant {
			// Zero-field constructor pattern; захватывать нечего.
			ctx.pattern_binders[p] = sym
		} else {
			// Обычный биндер.
			binder := new_symbol(
				ctx.symbol_store,
				p.name,
				.Variable,
				ctx.current_module,
				span = p.span,
				is_pattern_binder = true,
			)
			ctx.current_scope.symbols[intern(p.name)] = binder
			ctx.pattern_binders[p] = binder
		}
	case ^Pattern_Constructor:
		// Резолвим квалификатор при необходимости и рекурсивно шаблоны
		// аргументов. Само имя варианта разрешит type checker.
		for arg in p.args {
			resolve_pattern(ctx, arg)
		}
	case ^Error_Pattern:
	// Уже отрапортовано парсером — нечего резолвить.
	}
}

resolve_stmt :: proc(ctx: ^Resolver_Ctx, stmt: Stmt) {
	if stmt == nil do return

	switch s in stmt {
	case ^Let_Stmt:
		resolve_expr(ctx, s.value)

		sym := new_symbol(ctx.symbol_store, s.name, .Variable, ctx.current_module, span = s.span)
		name_id := intern(s.name)
		if name_id in ctx.current_scope.symbols {
			report_resolve(ctx, s.span, "Имя %s уже объявлено", s.name)
		}
		ctx.current_scope.symbols[name_id] = sym

		// 4. Кэшируем создание в Side Table
		ctx.stmt_symbols[stmt] = sym

	case ^Return_Stmt:
		resolve_expr(ctx, s.value)

	case ^Expr_Stmt:
		resolve_expr(ctx, s.expr)

	case ^Continue_Stmt:
	case ^Break_Stmt:
	case ^Error_Stmt:
	}
}

resolve_expr :: proc(ctx: ^Resolver_Ctx, expr: Expr) {
	if expr == nil do return

	switch e in expr {
	case ^Ident_Expr:
		sym := lookup_symbol(ctx.current_scope, e.name)
		if sym == INVALID_SYMBOL {
			report_resolve(ctx, e.span, "Resolve Error: undefined variable '%s'", resolve_interned(e.name))
		}
		// Кэшируем использование в Side Table (INVALID_SYMBOL если undefined —
		// typechecker трактует это как poison, не каскадирует вторичный
		// diagnostic, см. infer_ident_expr).
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

		// Своя scope на ветку (тот же паттерн, что у Match_Expr/Lambda_Expr
		// ниже) — без неё `пер x` в then И `пер x` в else двух РАЗНЫХ if
		// в одной функции конфликтовали бы как "уже объявлено", хотя
		// логически никогда не видят друг друга. Раньше её не было вообще
		// (см. TASKS.md — всплыло на для-in с переиспользованным именем
		// переменной в соседних, не вложенных, циклах).
		push_scope(ctx)
		for stmt in e.then_branch {
			resolve_stmt(ctx, stmt)
		}
		pop_scope(ctx)

		push_scope(ctx)
		for stmt in e.else_branch {
			resolve_stmt(ctx, stmt)
		}
		pop_scope(ctx)

	case ^While_Expr:
		resolve_expr(ctx, e.condition)

		push_scope(ctx)
		for stmt in e.body {
			resolve_stmt(ctx, stmt)
		}
		pop_scope(ctx)
	case ^Tuple_Expr:
		for el in e.elements {
			resolve_expr(ctx, el)
		}
	case ^Property_Expr:
		resolve_expr(ctx, e.object)
		obj_sym: Symbol_Id
		if obj_ident, ok := e.object.(^Ident_Expr); ok {
			obj_sym = lookup_symbol(ctx.current_scope, obj_ident.name)
		} else {
			obj_sym = ctx.node_symbols[e.object]
		}
		if obj_sym != INVALID_SYMBOL {
			obj := symbol_at(ctx.symbol_store, obj_sym)
			if obj.kind == .Module {
				imported_module := obj.module
				if imported_module == nil {
					report_resolve(ctx, e.span, "Resolve Error: модуль '%s' не найден", resolve_interned(obj.name))
					return
				}
				if export_sym, found := imported_module.exports[intern(e.property)]; found {
					ctx.node_symbols[expr] = export_sym
					return
				}
				report_resolve(
					ctx,
					e.span,
					"Resolve Error: модуль '%s' не экспортирует '%s'",
					resolve_interned(obj.name),
					e.property,
				)
				return
			}
			if obj.kind == .Type {
				if _, is_enum := obj.decl.(^Enum_Decl); is_enum {
					owner_module := obj.module
					if owner_module == nil {
						report_resolve(
							ctx,
							e.span,
							"Resolve Error: модуль-владелец типа '%s' недоступен",
							resolve_interned(obj.name),
						)
						return
					}
					// Ключ первого уровня — Symbol_Id САМОГО типа (obj_sym) —
					// см. Module.variants. found==false покрывает и "модуль
					// ещё не зарегистрировал вариантов для этого типа"
					// (nil map, safe read), и "такого варианта нет".
					variant_id, found := owner_module.variants[obj_sym][intern(e.property)]
					if !found {
						report_resolve(
							ctx,
							e.span,
							"Resolve Error: у типа '%s' нет варианта '%s'",
							resolve_interned(obj.name),
							e.property,
						)
						return
					}
					ctx.node_symbols[expr] = variant_id
					return
				}
			}
		}
	case ^Lambda_Expr:
		push_scope(ctx)
		args_syms := make([dynamic]Symbol_Id)
		for arg in e.args {
			sym := new_symbol(ctx.symbol_store, arg.name, .Variable, ctx.current_module, span = arg.span)
			ctx.current_scope.symbols[intern(arg.name)] = sym
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
	case ^Error_Expr:
	// Уже отрапортовано парсером — нечего резолвить, node_symbols не
	// заполняется (typecheck сработает через INVALID_SYMBOL).
	}
}

print_resolver_ctx :: proc(ctx: ^Resolver_Ctx) {
	fmt.println("\n================ ТАБЛИЦЫ РЕЗОЛВЕРА ================")

	fmt.println(
		"\n[1] ДЕКЛАРАЦИИ (decl_symbols) - Места создания глобальных символов:",
	)
	if len(ctx.decl_symbols) == 0 do fmt.println("  (пусто)")
	for decl, sym_id in ctx.decl_symbols {
		sym := symbol_at(ctx.symbol_store, sym_id)
		#partial switch d in decl {
		case ^Import_Decl:
			fmt.printf(
				"  [IMPORT] '%s'%s\n",
				d.path,
				d.alias != "" ? fmt.tprintf(" as %s", d.alias) : "",
			)
		case ^Impl_Decl:
			fmt.printf(
				"  [STRUCT] '%s' -> %s (#%d)\n",
				fmt.tprintf("%s:%s", d.target_type, d.interface_name),
				resolve_interned(sym.full_name),
				sym_id,
			)

		case ^Struct_Decl:
			fmt.printf("  [STRUCT] '%s' -> %s (#%d)\n", d.name, resolve_interned(sym.full_name), sym_id)
		case ^Interface_Decl:
			fmt.printf("  [INTERFACE] '%s' -> %s (#%d)\n", d.name, resolve_interned(sym.full_name), sym_id)
		case ^Function_Decl:
			fmt.printf("  [FUNC] '%s' -> %s (#%d)\n", d.name, resolve_interned(sym.full_name), sym_id)
		}
	}

	fmt.println(
		"\n[2] ЛОКАЛЬНЫЕ ПЕРЕМЕННЫЕ (stmt_symbols) - Места создания локальных символов:",
	)
	if len(ctx.stmt_symbols) == 0 do fmt.println("  (пусто)")
	for stmt, sym_id in ctx.stmt_symbols {
		sym := symbol_at(ctx.symbol_store, sym_id)
		#partial switch s in stmt {
		case ^Let_Stmt:
			fmt.printf("  [LET]  '%s' -> %s (#%d)\n", s.name, resolve_interned(sym.full_name), sym_id)
		}
	}

	fmt.println(
		"\n[3] ИСПОЛЬЗОВАНИЯ (node_symbols) - Куда ссылаются узлы AST:",
	)
	if len(ctx.node_symbols) == 0 do fmt.println("  (пусто)")
	for expr, sym_id in ctx.node_symbols {
		sym := symbol_at(ctx.symbol_store, sym_id)
		#partial switch e in expr {
		case ^Ident_Expr:
			fmt.printf(
				"  [EXPR] Идентификатор '%s' -> %s (#%d)\n",
				resolve_interned(e.name),
				resolve_interned(sym.full_name),
				sym_id,
			)
		}
	}
	fmt.println("===================================================\n")
}
