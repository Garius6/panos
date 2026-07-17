// resolver.odin
package core

import "core:fmt"

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
	// Стадия 27: конст-биндинг — запрещает переприсвоение через `=`
	// (type_cheker.odin's infer_binary_expr, case .Assign). НЕ deep
	// immutability — поля/элементы (Property_Expr/Index_Expr) не
	// проверяются, только сам биндинг (Ident_Expr).
	is_const:          bool,
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
	// варианту ТОЛЬКО квалифицированный (Тип.Вариант) — bare
	// `Вариант(...)` как конструктор-выражение не резолвится
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
	// Найдено при отладке Стадии 22 (не её баг): cross-module вызов
	// экспортированной generic-функции (алиас.функция(...)) НЕ инстанцировал
	// схему заново — infer_call_expr's Property_Expr-ветка использовала
	// export_type напрямую (шаблонный тип с общими InferVar), в отличие от
	// infer_ident_expr (same-file вызов), которая уже давно инстанцирует
	// через symbol_schemes. Symbol_Id generic-функции узнаётся ("реально
	// generic") только ПОСЛЕ typecheck_program той декларации
	// (try_generalize) — значит, в отличие от symbol_types (растёт во
	// время resolve, доступен как единая шаренная map с самого начала),
	// схемы нужно копить ПОСЛЕ каждого модуля и раздавать СЛЕДУЮЩИМ —
	// см. resolve_and_typecheck_all (module_loader.odin) и new_type_ctx
	// (type_cheker.odin), тот же паттерн, что prelude_symbol_schemes.
	symbol_schemes:   map[Symbol_Id]Type_Scheme,
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
	// decl_type_param_order прелюдийных generic-типов
	// (Опция/Результат) — обычно живёт только внутри Type_Ctx ОДНОГО
	// typecheck_program-прохода (см. Type_Ctx.decl_type_param_order), но
	// прелюдия резолвится/типизируется РОВНО ОДИН РАЗ в СВОЁМ tc_ctx
	// (ensure_prelude), а каждый пользовательский модуль получает СВОЙ
	// СВЕЖИЙ Type_Ctx — без этого поля ссылка Опция(Число) в любом
	// пользовательском модуле теряла бы ordered type-параметры и падала
	// с "не является generic-типом". new_type_ctx копирует это в
	// decl_type_param_order каждого нового ctx.
	prelude_generic_order: map[Symbol_Id][dynamic]^Type,
	// symbol_schemes методов Опции/Результата (generalize(), напр.
	// "ожидать" — T выводится структурно из
	// "это: Опция") — та же история, что и prelude_generic_order: живёт
	// только в prelude_tc_ctx (СВОЙ typecheck-проход), пользовательский
	// Type_Ctx никогда не видит прелюдийные Impl_Decl напрямую. Без копии
	// вызов Результат.ожидать(...) получал бы НЕ-инстанцированный T,
	// зацементированный на первом же вызове (или вовсе неразрешённый).
	prelude_symbol_schemes: map[Symbol_Id]Type_Scheme,
	// Symbol_Id Опции/Результата — нужны stdlib.odin (ensure_builtin_module
	// работает ДО того, как для конкретного модуля есть Type_Ctx или даже
	// Resolver_Ctx.prelude_option_sym, только graph под рукой).
	prelude_option_sym:    Symbol_Id,
	prelude_result_sym:    Symbol_Id,
	// Symbol_Id Сравниваемое/Равнозначное (Стадия 22) — тот же мотив, что у
	// prelude_option_sym: typechecker'у нужно по ^Type конкретной структуры
	// проверить "реализует ли она ИМЕННО Сравниваемое" (указательное
	// сравнение с implemented_interfaces), не просто "есть ли метод с
	// именем сравнить" — типизация номинальная, не структурная.
	prelude_comparable_sym: Symbol_Id,
	prelude_equatable_sym:  Symbol_Id,
	// Symbol_Id 4 интерфейсов Арифметики (Стадия 23) — тот же мотив.
	prelude_addable_sym:    Symbol_Id,
	prelude_subtractable_sym: Symbol_Id,
	prelude_multipliable_sym: Symbol_Id,
	prelude_divisible_sym:    Symbol_Id,
	// Symbol_Id Печатаемое (Стадия 23) — тот же мотив.
	prelude_printable_sym:    Symbol_Id,
	// Symbol_Id Копируемое (Стадия 23) — не используется typecheck/
	// compiler-кодом самого Копируемое (обычный прямой вызов метода, без
	// sugar), но заведён для консистентности с остальными 5 интерфейсами
	// И для будущей Стадии 24 (copy-on-send: нужно будет отличить "есть
	// ли у типа кастомный .клонировать()" от дефолтного reflective-копи-
	// рования при отправке сообщения в mailbox).
	prelude_copyable_sym:     Symbol_Id,
	// Symbol_Id Итерируемое (Стадия 23, generic-интерфейс — Стадия 28) —
	// нужен for-in'у (type_cheker.odin, case ^For_In_Stmt) для нominal-
	// проверки "implements Итерируемое" тем же способом, что и остальные.
	prelude_iterable_sym:     Symbol_Id,
	// Хип-аллоцированные resolve/typecheck-контексты прелюдии — нужны
	// ensure_prelude_compiled (compiler.odin-этап, см. там) ПОСЛЕ того,
	// как ensure_prelude уже вернулась (её собственные локальные res_ctx/
	// tc_ctx к тому моменту были бы недействительны на стеке).
	prelude_res_ctx:       ^Resolver_Ctx,
	prelude_tc_ctx:        ^Type_Ctx,
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

// resolve_existing_import_path — в resolver_import_native.odin/
// resolver_import_wasm.odin (#+build split, трогает os.exists/
// os.lookup_env — сам импорт core:os падает под js_wasm32). WASM-спайк v1
// не поддерживает файловый `импорт` — см. read_file_text в
// module_loader_wasm.odin.

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
	is_const: bool = false,
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
		is_const          = is_const,
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
	// Стадия 23 (Итерируемое): For_In_Stmt.names — 1+ имён (одиночное
	// или tuple-деструктуризация `для (к, з) в ...`), позиционно
	// параллельно names. Та же форма, что func_args/lambda_args.
	for_in_names_syms: map[Stmt][dynamic]Symbol_Id,
	// Деструктуризация в пер/конст (Let_Stmt.names непусто) — та же форма,
	// что for_in_names_syms, позиционно параллельно Let_Stmt.names.
	let_destructure_syms: map[Stmt][dynamic]Symbol_Id,

	// Symbol_Id типов Опция/Результат из прелюдии —
	// нужны type_cheker.odin (infer_try_expr, оператор `?`), чтобы отличить
	// "это именно Опция/Результат" от произвольного пользовательского
	// 2-вариантного enum (.kind == .Enum само по себе не различает).
	// Выставляются в resolve_module после слияния экспортов прелюдии.
	prelude_option_sym: Symbol_Id,
	prelude_result_sym: Symbol_Id,
	// Symbol_Id Сравниваемое/Равнозначное (Стадия 22) — см. одноимённые
	// поля на Module_Graph, тот же мотив.
	prelude_comparable_sym: Symbol_Id,
	prelude_equatable_sym:  Symbol_Id,
	// Symbol_Id 4 интерфейсов Арифметики (Стадия 23) — тот же мотив.
	prelude_addable_sym:    Symbol_Id,
	prelude_subtractable_sym: Symbol_Id,
	prelude_multipliable_sym: Symbol_Id,
	prelude_divisible_sym:    Symbol_Id,
	// Symbol_Id Печатаемое (Стадия 23) — тот же мотив.
	prelude_printable_sym:    Symbol_Id,
	// Symbol_Id Копируемое (Стадия 23) — тот же мотив.
	prelude_copyable_sym:     Symbol_Id,
	// Symbol_Id Итерируемое (Стадия 23) — тот же мотив.
	prelude_iterable_sym:     Symbol_Id,
	// Копия graph.prelude_generic_order (см. там) — Resolver_Ctx (в
	// отличие от module_graph, который resolve_program обнуляет после
	// однократного резолва, см. resolve_program) переживает весь
	// typecheck_program. new_type_ctx копирует это в decl_type_param_order
	// каждого нового Type_Ctx.
	prelude_generic_order: map[Symbol_Id][dynamic]^Type,
	// Копия graph.prelude_symbol_schemes (см. там) — new_type_ctx копирует
	// это в symbol_schemes каждого нового Type_Ctx.
	prelude_symbol_schemes: map[Symbol_Id]Type_Scheme,
	// Копии graph.prelude_res_ctx/prelude_tc_ctx — нужны ensure_prelude_
	// compiled (compiler.odin-этап), тем же способом: module_graph
	// resolve_program обнуляет, эти поля на Resolver_Ctx — нет.
	prelude_res_ctx:       ^Resolver_Ctx,
	prelude_tc_ctx:        ^Type_Ctx,
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

// Reserved-имена builtin-функций (второй тир зарезервированной лексики,
// см. docs/src/language/basic-types.md "Зарезервированные слова" — первый
// тир — жёсткие keyword'ы лексера типа "пер"/"тип"/"функ"/"в", которые
// вообще не могут стать .Ident-токеном). Единая hard-reserved политика:
// НИ ОДНО из этих имён нельзя объявить заново — ни как top-level функцию/
// тип (register_named_symbol проверяет коллизию с module.scope.symbols
// без исключения для .Builtin), ни как локальную переменную/параметр/
// pattern-биндер (check_not_reserved, вызывается во всех местах, где
// заводится .Variable-символ). "в" (for-in) в этот список НЕ входит — она
// теперь настоящий Token_Kind.In лексера (см. lexer.odin/parser.odin),
// другой механизм той же политики.
RESERVED_BUILTIN_NAMES := [?]string {
	"Ошибка",
	"длина",
	"паника",
	"получить",
	"отправить",
	"себя",
	"наблюдать",
	"получить_сигнал",
	"убить",
}

install_standard_symbols :: proc(ctx: ^Resolver_Ctx) {
	// Есть/Нет/Успех/Неудача сюда НЕ входят — это Enum_Variant варианты
	// Опции/Результата из прелюдии, доступные через слияние её exports
	// в resolve_module (см. ниже).
	for name in RESERVED_BUILTIN_NAMES {
		sym := new_symbol(ctx.symbol_store, name, .Builtin, nil)
		ctx.current_scope.symbols[intern(name)] = sym
	}
}

// Проверяет, что name НЕ входит в RESERVED_BUILTIN_NAMES — вызывается
// перед КАЖДОЙ регистрацией НОВОГО локального .Variable-символа (пер/
// конст/деструктуризация/for-in/параметры функций и лямбд/pattern-
// биндеры в выборе), т.к. эти места НЕ идут через register_named_symbol
// (module-scope-only коллизия) и по умолчанию разрешают затенение любого
// внешнего имени (обычная вложенная область видимости) — без этой явной
// проверки reserved-имя было бы затеняемым локально, что нарушило бы
// единую hard-reserved политику. Возвращает true (и репортит diagnostic),
// если имя зарезервировано — вызывающий код продолжает регистрацию
// символа как обычно (poison-паттерн резолвера — не блокировать остальной
// проход из-за одной ошибки).
check_not_reserved :: proc(ctx: ^Resolver_Ctx, name: string, span: Span) -> bool {
	for reserved in RESERVED_BUILTIN_NAMES {
		if name == reserved {
			report_resolve(ctx, span, "Resolve Error: '%s' — зарезервированное имя, нельзя использовать", name)
			return true
		}
	}
	return false
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

// Общий паттерн для Function_Decl/Struct_Decl/Interface_Decl/Enum_Decl (сам
// тип, без вариантов) и методов Impl_Decl: интернировать имя, проверить
// коллизию в module.scope.symbols, при отсутствии — записать в scope и (если
// экспортируется) в module.exports. Возвращает символ ВСЕГДА (даже при
// коллизии) — вызывающий пишет его в ctx.decl_symbols безусловно, тот же
// poison-паттерн, что и везде в резолвере (не каскадировать вторичные
// ошибки на отсутствующем symbol_id).
register_named_symbol :: proc(
	ctx: ^Resolver_Ctx,
	module: ^Module,
	name: string,
	kind: Symbol_Kind,
	decl: Decls,
	span: Span,
	is_exported: bool,
) -> Symbol_Id {
	sym := new_symbol(ctx.symbol_store, name, kind, module, is_exported, decl, span)
	name_id := intern(name)
	// Единая hard-reserved политика (см. RESERVED_BUILTIN_NAMES выше):
	// install_standard_symbols заранее кладёт builtin'ы ("получить" и
	// т.п.) в module.scope.symbols — коллизия с ними теперь ТА ЖЕ ошибка,
	// что коллизия с обычным пользовательским объявлением, без исключения
	// для .Builtin (раньше — Стадия 24 — было наоборот, затенение
	// разрешалось; см. ROADMAP §Стадия 39).
	if _, taken := module.scope.symbols[name_id]; taken {
		report_resolve(ctx, span, "Resolve Error: символ '%s' уже объявлен", name)
	} else {
		module.scope.symbols[name_id] = sym
		if is_exported {
			module.exports[name_id] = sym
		}
	}
	return sym
}

// Резолвит тело функции/метода: своя scope на аргументы (регистрирует их
// как .Variable-символы), обход тела через resolve_stmt, запись args_syms в
// ctx.func_args под ключом `key` (для Function_Decl — сам decl, для метода
// Impl_Decl — узел метода). Общий паттерн для Function_Decl и методов
// Impl_Decl.
resolve_function_body :: proc(
	ctx: ^Resolver_Ctx,
	module: ^Module,
	key: Decls,
	args: []Param_Decl,
	body: [dynamic]Stmt,
) {
	push_scope(ctx)
	args_syms := make([dynamic]Symbol_Id)
	for arg in args {
		// Стадия 27 (расширение): параметры immutable по умолчанию
		// (Kotlin/Swift-style, не opt-in как обычный `конст` для локалей) —
		// нет способа сделать параметр мутируемым, нужна копия в `пер`
		// внутри тела, если требуется.
		check_not_reserved(ctx, arg.name, arg.span)
		sym := new_symbol(ctx.symbol_store, arg.name, .Variable, module, span = arg.span, is_const = true)
		ctx.current_scope.symbols[intern(arg.name)] = sym
		append(&args_syms, sym)
	}
	ctx.func_args[key] = args_syms
	for stmt in body do resolve_stmt(ctx, stmt)
	pop_scope(ctx)
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
		ctx.decl_symbols[decl] = register_named_symbol(ctx, module, d.name, .Function, decl, d.span, d.is_exported)

	case ^Struct_Decl:
		ctx.decl_symbols[decl] = register_named_symbol(ctx, module, d.name, .Type, decl, d.span, d.is_exported)

	case ^Interface_Decl:
		ctx.decl_symbols[decl] = register_named_symbol(ctx, module, d.name, .Type, decl, d.span, d.is_exported)

	case ^Impl_Decl:
		for m in d.methods {
			ctx.decl_symbols[m] = register_named_symbol(ctx, module, m.name, .Function, m, m.span, false)
		}

	case ^Enum_Decl:
		type_sym := register_named_symbol(ctx, module, d.name, .Type, decl, d.span, d.is_exported)
		ctx.decl_symbols[decl] = type_sym

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

	// Опция/Результат доступны в КАЖДОМ модуле без
	// "импорт" — module.path проверяем, чтобы резолв самой прелюдии не
	// пытался слить себя же в собственный scope (ensure_prelude уже
	// зарегистрировал module в graph.modules ДО вызова resolve_module,
	// так что prelude != nil сработал бы неверно и без этой проверки —
	// но path-проверка явнее и не завязана на порядок регистрации).
	if module.path != PRELUDE_MODULE_KEY {
		prelude := ensure_prelude(graph)
		merge_prelude_exports(&ctx, graph, module, prelude)
		// ensure_prelude типизирует прелюдию В СВОЁМ, ОТДЕЛЬНОМ вызове
		// resolve_module — graph.symbol_types растёт с нуля, а ctx.
		// symbol_types (скопирован ДО этого роста, в new_module_resolver_
		// ctx выше) остаётся указывать на СТАРУЮ, всё ещё пустую копию —
		// без пересинхронизации типы Опции/Результата/фс/сеть и т.п.
		// невидимы для typecheck_program этого модуля.
		ctx.symbol_types = graph.symbol_types
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
				resolve_function_body(&ctx, module, m, m.args[:], m.body)
			}

		case ^Function_Decl:
			resolve_function_body(&ctx, module, decl, d.args[:], d.body)
		case ^Struct_Decl:
		case ^Interface_Decl:
		}
	}

	// См. комментарий у резинхронизации после ensure_prelude выше —
	// register_top_level_decl (ensure_builtin_module/add_builtin_export)
	// тоже пишет напрямую в graph.symbol_types, тот же риск расхождения.
	ctx.symbol_types = graph.symbol_types
	return ctx
}

resolve_program :: proc(ctx: ^Resolver_Ctx, prog: Program) {
	// new(Module), не стековый композитный литерал — каждый созданный здесь
	// Symbol хранит указатель НА ЭТОТ Module (Symbol.module) и переживает
	// саму resolve_program (читается вплоть до compile_program/
	// monomorphize_program, см. core/monomorphize.odin). Стековая версия
	// (была здесь раньше) давала dangling pointer, как только resolve_program
	// возвращалась — молча не всплывало годами, пока bounded traits'
	// monomorphize_one не стал первым кодом, читающим Symbol.module ТАК
	// поздно (на этапе компиляции, стек уже многократно переиспользован) —
	// тот же класс бага, что stack-escape в parse_for_range_stmt_into
	// (Стадия 32, Целое).
	module := new(Module)
	module.path = ""
	module.dir = ""
	module.ast = prog
	module.exports = make(map[Interned]Symbol_Id)
	if ctx.global_scope == nil {
		push_scope(ctx)
		ctx.global_scope = ctx.current_scope
	}
	module.scope = ctx.global_scope
	graph := new_module_graph()
	resolved := resolve_module(&graph, module)
	resolved.module_graph = nil
	resolved.current_module = nil
	ctx^ = resolved
}

resolve_pattern :: proc(ctx: ^Resolver_Ctx, pattern: Pattern) {
	switch p in pattern {
	case ^Pattern_Wildcard:
	// ничего не привязывает
	case ^Pattern_Literal:
		resolve_expr(ctx, p.value)
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
			check_not_reserved(ctx, p.name, p.span)
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

		if len(s.names) > 0 {
			// Деструктуризация (тупл или структура) — символ на КАЖДОЕ имя,
			// та же форма, что For_In_Stmt.names/for_in_names_syms.
			syms := make([dynamic]Symbol_Id)
			for name in s.names {
				check_not_reserved(ctx, name, s.span)
				sym := new_symbol(ctx.symbol_store, name, .Variable, ctx.current_module, span = s.span, is_const = s.is_const)
				name_id := intern(name)
				if name_id in ctx.current_scope.symbols {
					report_resolve(ctx, s.span, "Имя %s уже объявлено", name)
				}
				ctx.current_scope.symbols[name_id] = sym
				append(&syms, sym)
			}
			ctx.let_destructure_syms[stmt] = syms
		} else {
			check_not_reserved(ctx, s.name, s.span)
			sym := new_symbol(ctx.symbol_store, s.name, .Variable, ctx.current_module, span = s.span, is_const = s.is_const)
			name_id := intern(s.name)
			if name_id in ctx.current_scope.symbols {
				report_resolve(ctx, s.span, "Имя %s уже объявлено", s.name)
			}
			ctx.current_scope.symbols[name_id] = sym

			ctx.stmt_symbols[stmt] = sym
		}

	case ^Return_Stmt:
		resolve_expr(ctx, s.value)

	case ^Expr_Stmt:
		resolve_expr(ctx, s.expr)

	case ^Continue_Stmt:
	case ^Break_Stmt:
	case ^Error_Stmt:

	case ^For_In_Stmt:
		resolve_expr(ctx, s.iterable)

		push_scope(ctx)
		names_syms := make([dynamic]Symbol_Id)
		for name in s.names {
			// is_const НЕ выставляем (в отличие от параметров функций,
			// Стадия 27) — старое parse-time десахаривание использовало
			// mk_let (обычный `пер`, reassignable); сохраняем то же
			// поведение, не меняем его этим рефакторингом попутно.
			check_not_reserved(ctx, name, s.span)
			sym := new_symbol(ctx.symbol_store, name, .Variable, ctx.current_module, span = s.span)
			name_id := intern(name)
			if name_id in ctx.current_scope.symbols {
				report_resolve(ctx, s.span, "Имя %s уже объявлено", name)
			}
			ctx.current_scope.symbols[name_id] = sym
			append(&names_syms, sym)
		}
		ctx.for_in_names_syms[stmt] = names_syms

		for body_stmt in s.body do resolve_stmt(ctx, body_stmt)
		pop_scope(ctx)
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
	case ^Spawn_Expr:
		// `запусти <вызов>` резолвится ТОЧНО как обычный Call_Expr — сам
		// Spawn_Expr лишь маркер для typecheck/compile, резолверу нечего
		// делать по-другому (callee + аргументы резолвятся как всегда).
		resolve_expr(ctx, e.call)
	case ^If_Expr:
		resolve_expr(ctx, e.condition)

		// Своя scope на ветку (тот же паттерн, что у Match_Expr/Lambda_Expr
		// ниже) — без неё `пер x` в then И `пер x` в else двух РАЗНЫХ if
		// в одной функции конфликтовали бы как "уже объявлено", хотя
		// логически никогда не видят друг друга.
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
			// Стадия 27 (расширение) — та же immutable-by-default политика,
			// что у обычных функций (resolve_function_body).
			check_not_reserved(ctx, arg.name, arg.span)
			sym := new_symbol(ctx.symbol_store, arg.name, .Variable, ctx.current_module, span = arg.span, is_const = true)
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
