package main

import "core:fmt"
import "core:strconv"
import "core:strings"

// --- ТИПЫ ДАННЫХ ---

Type_Kind :: enum {
	Number,
	Bool,
	Void,
	Never,
	String,
	Function,
	Tuple,
	Struct,
	Interface,
	Array,
	Map,
	Error,
	Option,
	Result,
	InferVar,
}

Type :: struct {
	kind:                   Type_Kind,
	name:                   string,
	// Поля ниже используются только если kind == .Function
	params:                 [dynamic]^Type,
	return_type:            ^Type,
	// Для туплов:
	elements:               [dynamic]^Type,
	// Для структур
	fields:                 [dynamic]Struct_Field,
	// Для методов/интерфейсов
	methods:                map[string]^Symbol,
	// Для структур: список интерфейсов, которые они реализовали
	implemented_interfaces: [dynamic]^Type,
	// Для интерфейсов: какие методы они требуют
	interface_methods:      map[string]^Type,
	element_type:           ^Type,
	key_type:               ^Type,
	value_type:             ^Type,
	ok_type:                ^Type,
	error_type:             ^Type,
	infer_id:               int,
	binding:                ^Type,
}

Struct_Field :: struct {
	name: string,
	type: ^Type,
}

// Интернированные базовые типы
TY_NUM := &Type{kind = .Number, name = "Число"}
TY_BOOL := &Type{kind = .Bool, name = "Булево"}
TY_VOID := &Type{kind = .Void, name = "Пусто"}
TY_NEVER := &Type{kind = .Never, name = "Никогда"}
TY_STRING := &Type{kind = .String, name = "Строка"}
TY_ERROR := &Type{kind = .Error, name = "Ошибка"}

// Построение составных типов держим в одном месте, чтобы имена и ссылки
// формировались одинаково во всех ветках type checker'а.
new_function_type :: proc(params: [dynamic]^Type, return_type: ^Type) -> ^Type {
	t := new(Type)
	t.kind = .Function
	t.name = "Function"
	t.params = params
	t.return_type = return_type
	return t
}

new_array_type :: proc(element_type: ^Type) -> ^Type {
	t := new(Type)
	t.kind = .Array
	t.element_type = element_type
	t.name = fmt.tprintf("Массив(%s)", element_type.name)
	return t
}

new_map_type :: proc(key_type: ^Type, value_type: ^Type) -> ^Type {
	t := new(Type)
	t.kind = .Map
	t.key_type = key_type
	t.value_type = value_type
	t.name = fmt.tprintf("Соответствие(%s, %s)", key_type.name, value_type.name)
	return t
}

new_option_type :: proc(element_type: ^Type) -> ^Type {
	t := new(Type)
	t.kind = .Option
	t.element_type = element_type
	t.name = fmt.tprintf("Опция(%s)", element_type.name)
	return t
}

new_result_type :: proc(ok_type: ^Type, error_type: ^Type) -> ^Type {
	t := new(Type)
	t.kind = .Result
	t.ok_type = ok_type
	t.error_type = error_type
	t.name = fmt.tprintf("Результат(%s, %s)", ok_type.name, error_type.name)
	return t
}

is_valid_map_key_type :: proc(t: ^Type) -> bool {
	typ := prune_type(t)
	return typ.kind == .Number || typ.kind == .Bool || typ.kind == .String
}

// --- КОНТЕКСТ ---

Type_Ctx :: struct {
	res:              ^Resolver_Ctx,
	node_types:       map[Expr]^Type,
	is_constructor:   map[Expr]bool,
	property_indices: map[Expr]int,
	method_calls:     map[Expr]^Symbol,
	interface_casts:  map[Expr]^Type,
	interface_calls:  map[Expr]string,
	collection_calls: map[Expr]string,
	builtin_calls:    map[Expr]string,
	current_return:   ^Type,
	next_infer_id:    int,
}

new_type_ctx :: proc(res: ^Resolver_Ctx) -> Type_Ctx {
	return Type_Ctx {
		res = res,
		node_types = make(map[Expr]^Type),
		is_constructor = make(map[Expr]bool),
		property_indices = make(map[Expr]int),
		method_calls = make(map[Expr]^Symbol),
		interface_casts = make(map[Expr]^Type),
		interface_calls = make(map[Expr]string),
		collection_calls = make(map[Expr]string),
		builtin_calls = make(map[Expr]string),
	}
}

// InferVar - внутренний временный тип. Он не равен Any: позже должен
// связаться с конкретным типом или дать ошибку.
new_infer_var :: proc(ctx: ^Type_Ctx) -> ^Type {
	t := new(Type)
	t.kind = .InferVar
	t.infer_id = ctx.next_infer_id
	t.name = fmt.tprintf("?%d", t.infer_id)
	ctx.next_infer_id += 1
	return t
}

// `prune_type` снимает все промежуточные связывания и возвращает фактический тип.
prune_type :: proc(t: ^Type) -> ^Type {
	if t == nil do return nil
	if t.kind == .InferVar && t.binding != nil {
		t.binding = prune_type(t.binding)
		return t.binding
	}
	return t
}

// Нужна для защиты от циклических связываний вида `?T = (... ?T ...)`.
type_contains_infer_var :: proc(t: ^Type, needle: ^Type) -> bool {
	typ := prune_type(t)
	if typ == nil do return false
	if typ == needle do return true

	#partial switch typ.kind {
	case .Function:
		for param in typ.params {
			if type_contains_infer_var(param, needle) do return true
		}
		return type_contains_infer_var(typ.return_type, needle)

	case .Tuple:
		for el in typ.elements {
			if type_contains_infer_var(el, needle) do return true
		}

	case .Array:
		return type_contains_infer_var(typ.element_type, needle)

	case .Map:
		return(
			type_contains_infer_var(typ.key_type, needle) ||
			type_contains_infer_var(typ.value_type, needle) \
		)

	case .Option:
		return type_contains_infer_var(typ.element_type, needle)

	case .Result:
		return(
			type_contains_infer_var(typ.ok_type, needle) ||
			type_contains_infer_var(typ.error_type, needle) \
		)
	}

	return false
}

// Связывает переменную типа с найденным кандидатом, если это не создает цикл.
bind_infer_var :: proc(var_type: ^Type, target: ^Type) -> bool {
	target_type := prune_type(target)
	if target_type == nil do return false
	if target_type == var_type do return true
	if type_contains_infer_var(target_type, var_type) do return false
	var_type.binding = target_type
	return true
}

// Унификация либо подтверждает совместимость типов, либо фиксирует InferVar.
// Это главный механизм вывода типов в лямбдах, аргументах и присваиваниях.
unify_types :: proc(a: ^Type, b: ^Type) -> bool {
	left := prune_type(a)
	right := prune_type(b)
	if left == nil || right == nil do return false
	if left == right do return true
	if left.kind == .Never || right.kind == .Never do return true

	if left.kind == .InferVar do return bind_infer_var(left, right)
	if right.kind == .InferVar do return bind_infer_var(right, left)

	if right.kind == .Interface && left.kind == .Struct {
		for iface in left.implemented_interfaces {
			if iface == right do return true
		}
		return false
	}

	if left.kind != right.kind do return false

	#partial switch left.kind {
	case .Tuple:
		if len(left.elements) != len(right.elements) do return false
		for i in 0 ..< len(left.elements) {
			if !unify_types(left.elements[i], right.elements[i]) do return false
		}
		return true

	case .Function:
		if len(left.params) != len(right.params) do return false
		for i in 0 ..< len(left.params) {
			if !unify_types(left.params[i], right.params[i]) do return false
		}
		return unify_types(left.return_type, right.return_type)

	case .Array:
		return unify_types(left.element_type, right.element_type)

	case .Map:
		return(
			unify_types(left.key_type, right.key_type) &&
			unify_types(left.value_type, right.value_type) \
		)

	case .Option:
		return unify_types(left.element_type, right.element_type)

	case .Result:
		return(
			unify_types(left.ok_type, right.ok_type) &&
			unify_types(left.error_type, right.error_type) \
		)

	case .Struct, .Interface:
		return false
	}
	return true
}

// После вывода типа проверяем, что в нем не осталось неизвестных частей.
has_unresolved_infer_vars :: proc(t: ^Type) -> bool {
	typ := prune_type(t)
	if typ == nil do return false

	#partial switch typ.kind {
	case .InferVar:
		return true

	case .Function:
		for param in typ.params {
			if has_unresolved_infer_vars(param) do return true
		}
		return has_unresolved_infer_vars(typ.return_type)

	case .Tuple:
		for el in typ.elements {
			if has_unresolved_infer_vars(el) do return true
		}

	case .Array:
		return has_unresolved_infer_vars(typ.element_type)

	case .Map:
		return has_unresolved_infer_vars(typ.key_type) || has_unresolved_infer_vars(typ.value_type)

	case .Option:
		return has_unresolved_infer_vars(typ.element_type)

	case .Result:
		return has_unresolved_infer_vars(typ.ok_type) || has_unresolved_infer_vars(typ.error_type)
	}

	return false
}

// Помогает ловить случаи, когда infer дошел не до конца, но код уже
// пытается использовать результат как окончательный тип.
ensure_type_resolved :: proc(t: ^Type, where_text: string) {
	if has_unresolved_infer_vars(t) {
		fmt.panicf("Type Error: не удалось вывести тип %s", where_text)
	}
}

// Для top-level функций типы параметров по-прежнему должны быть явными.
// Это упрощает раннюю регистрацию символов и не смешивает вывод с резолюцией имен.
resolve_param_types :: proc(ctx: ^Type_Ctx, args: [dynamic]Param_Decl) -> [dynamic]^Type {
	params := make([dynamic]^Type)
	for arg in args {
		if arg.type_annotation == nil {
			fmt.panicf(
				"Type Error: у аргумента '%s' нет явной аннотации типа",
				arg.name,
			)
		}
		append(&params, resolve_type_node(ctx, arg.type_annotation))
	}
	return params
}

// Для лямбд параметры можно либо взять из ожидаемого типа, либо вывести
// как отдельные InferVar и потом связать их через тело.
infer_lambda_param_types :: proc(
	ctx: ^Type_Ctx,
	args: [dynamic]Param_Decl,
	expected: ^Type = nil,
) -> [dynamic]^Type {
	params := make([dynamic]^Type)
	expected_type := prune_type(expected)
	if expected_type != nil && expected_type.kind != .Function {
		fmt.panicf(
			"Type Error: лямбду можно проверить только с типом функции",
		)
	}
	if expected_type != nil && len(args) != len(expected_type.params) {
		fmt.panicf(
			"Type Error: лямбда имеет %d аргументов, ожидалось %d",
			len(args),
			len(expected_type.params),
		)
	}

	for arg, i in args {
		if arg.type_annotation != nil {
			arg_type := resolve_type_node(ctx, arg.type_annotation)
			if expected_type != nil && !unify_types(arg_type, expected_type.params[i]) {
				fmt.panicf(
					"Type Error: аргумент лямбды '%s' имеет тип '%s', ожидался '%s'",
					arg.name,
					prune_type(arg_type).name,
					prune_type(expected_type.params[i]).name,
				)
			}
			append(&params, arg_type)
		} else if expected_type != nil {
			append(&params, expected_type.params[i])
		} else {
			append(&params, new_infer_var(ctx))
		}
	}

	return params
}

// Сигнатура обычной функции берется только из явной декларации.
// Для top-level items inference здесь не используется.
function_type_from_decl :: proc(ctx: ^Type_Ctx, d: ^Function_Decl) -> ^Type {
	params := resolve_param_types(ctx, d.args)
	return_type := resolve_type_node(ctx, d.return_type)
	return new_function_type(params, return_type)
}

interface_method_type_from_signature :: proc(
	ctx: ^Type_Ctx,
	iface_type: ^Type,
	m: Method_Signature,
) -> ^Type {
	params := make([dynamic]^Type)
	append(&params, iface_type)
	for arg in m.args {
		append(&params, resolve_type_node(ctx, arg.type_annotation))
	}
	return new_function_type(params, resolve_type_node(ctx, m.return_type))
}

// Привязывает параметры обычной функции к уже вычисленной сигнатуре.
bind_function_args :: proc(ctx: ^Type_Ctx, d: ^Function_Decl, func_type: ^Type) {
	if args_syms, ok := ctx.res.func_args[d]; ok {
		if len(args_syms) != len(func_type.params) {
			fmt.panicf(
				"Type Error: функция '%s' имеет рассинхронизированные аргументы",
				d.name,
			)
		}
		for arg_sym, i in args_syms {
			ctx.res.symbol_types[arg_sym] = func_type.params[i]
		}
	}
}

// То же самое для лямбды: символы аргументов должны получить типы
// тех же позиций, которые были выведены или протолкнуты сверху вниз.
bind_lambda_args :: proc(ctx: ^Type_Ctx, expr: Expr, params: [dynamic]^Type) {
	if args_syms, ok := ctx.res.lambda_args[expr]; ok {
		if len(args_syms) != len(params) {
			fmt.panicf(
				"Type Error: лямбда имеет рассинхронизированные аргументы",
			)
		}
		for sym, i in args_syms do ctx.res.symbol_types[sym] = params[i]
	}
}

// Пытается вывести тип блока callable-выражения: сначала как значение блока,
// а если значения нет, то через явные `return`.
infer_callable_body_type :: proc(ctx: ^Type_Ctx, body: [dynamic]Stmt) -> ^Type {
	body_type := infer_block_type(ctx, body)
	if body_type != TY_VOID do return body_type
	return infer_function_body(ctx, body)
}

// Лямба проверяется bidirectional-стилем:
// если ожидаемый тип известен, он проталкивается вниз; иначе тип выводится из тела.
check_lambda_expr :: proc(
	ctx: ^Type_Ctx,
	expr: Expr,
	lambda: ^Lambda_Expr,
	expected: ^Type = nil,
) -> ^Type {
	expected_type := prune_type(expected)
	params := infer_lambda_param_types(ctx, lambda.args, expected_type)
	bind_lambda_args(ctx, expr, params)

	return_type: ^Type
	if lambda.return_type != nil {
		return_type = resolve_type_node(ctx, lambda.return_type)
		if expected_type != nil && !unify_types(return_type, expected_type.return_type) {
			fmt.panicf(
				"Type Error: лямбда возвращает '%s', ожидался '%s'",
				prune_type(return_type).name,
				prune_type(expected_type.return_type).name,
			)
		}
	} else if expected_type != nil {
		return_type = expected_type.return_type
	} else {
		return_type = new_infer_var(ctx)
	}

	function_type := new_function_type(params, return_type)
	ctx.node_types[expr] = function_type

	if expected_type != nil && !unify_types(function_type, expected_type) {
		fmt.panicf(
			"Type Error: лямбда имеет тип '%s', ожидался '%s'",
			function_type.name,
			expected_type.name,
		)
	}

	if lambda.return_type != nil || expected_type != nil {
		check_function_body(ctx, lambda.body, return_type)
	} else {
		body_type := infer_callable_body_type(ctx, lambda.body)
		if !unify_types(body_type, return_type) {
			fmt.panicf(
				"Type Error: тело лямбды имеет тип '%s', ожидался '%s'",
				prune_type(body_type).name,
				prune_type(return_type).name,
			)
		}
	}

	ensure_type_resolved(function_type, "лямбды")
	return function_type
}

interface_method_types_match :: proc(expected: ^Type, actual: ^Type) -> bool {
	if expected == nil || actual == nil do return false
	if expected.kind != .Function || actual.kind != .Function do return false
	if len(expected.params) != len(actual.params) do return false
	if !types_are_equal(actual.return_type, expected.return_type) do return false

	for i in 1 ..< len(expected.params) {
		if !types_are_equal(actual.params[i], expected.params[i]) do return false
	}
	return true
}

// --- ГЛАВНЫЙ ЦИКЛ ---

// Основной проход type checker'а идет в несколько стадий:
// сначала регистрируем номинальные типы, потом сигнатуры, затем реализации,
// и только после этого проверяем тела.
typecheck_program :: proc(ctx: ^Type_Ctx, prog: Program) {
	// ПРОХОД 1: создаем номинальные типы до разбора полей и сигнатур.
	for decl in prog.decls {
		#partial switch d in decl {
		case ^Struct_Decl:
			struct_type := new(Type)
			struct_type.kind = .Struct
			struct_type.name = d.name
			struct_type.fields = make([dynamic]Struct_Field)
			struct_type.methods = make(map[string]^Symbol)
			struct_type.implemented_interfaces = make([dynamic]^Type)

			sym := ctx.res.decl_symbols[decl]
			ctx.res.symbol_types[sym] = struct_type

		case ^Interface_Decl:
			iface_type := new(Type)
			iface_type.kind = .Interface
			iface_type.name = d.name
			iface_type.interface_methods = make(map[string]^Type)
			ctx.res.symbol_types[ctx.res.decl_symbols[decl]] = iface_type
		}
	}

	// ПРОХОД 2: заполняем структуры, интерфейсы и сигнатуры функций.
	for decl in prog.decls {
		#partial switch d in decl {
		case ^Struct_Decl:
			sym := ctx.res.decl_symbols[decl]
			struct_type := ctx.res.symbol_types[sym]
			struct_type.fields = make([dynamic]Struct_Field)

			for f in d.fields {
				field_type := resolve_type_node(ctx, f.type_annotation)
				append(&struct_type.fields, Struct_Field{name = f.name, type = field_type})
			}

		case ^Function_Decl:
			sym := ctx.res.decl_symbols[decl]
			ctx.res.symbol_types[sym] = function_type_from_decl(ctx, d)

		case ^Interface_Decl:
			iface_type := ctx.res.symbol_types[ctx.res.decl_symbols[decl]]
			iface_type.interface_methods = make(map[string]^Type)
			for m in d.methods {
				iface_type.interface_methods[m.name] = interface_method_type_from_signature(
					ctx,
					iface_type,
					m,
				)
			}
		}
	}

	// ПРОХОД 3: Привязка реализаций (методов и контрактов) к структурам
	for decl in prog.decls {
		#partial switch d in decl {
		case ^Impl_Decl:
			target_sym := ctx.res.global_scope.symbols[d.target_type]
			struct_type := ctx.res.symbol_types[target_sym]
			if struct_type == nil || struct_type.kind != .Struct {
				fmt.panicf(
					"Type Error: неизвестная структура '%s'",
					d.target_type,
				)
			}

			// Регистрируем методы
			for m in d.methods {
				sym := ctx.res.decl_symbols[m]
				method_type := function_type_from_decl(ctx, m)
				if len(method_type.params) == 0 ||
				   !types_are_equal(method_type.params[0], struct_type) {
					fmt.panicf(
						"Type Error: первый аргумент метода '%s' должен иметь тип '%s'",
						m.name,
						struct_type.name,
					)
				}
				ctx.res.symbol_types[sym] = method_type
				original_name := m.name[len(d.target_type) + 2:]
				struct_type.methods[original_name] = sym
			}

			// Строгая проверка интерфейсного контракта
			if d.interface_name != "" {
				iface_sym := ctx.res.global_scope.symbols[d.interface_name]
				iface_type := ctx.res.symbol_types[iface_sym]

				if iface_type == nil || iface_type.kind != .Interface {
					fmt.panicf(
						"Type Error: '%s' не является интерфейсом",
						d.interface_name,
					)
				}

				for req_name in iface_type.interface_methods {
					method_sym, found := struct_type.methods[req_name]
					if !found do fmt.panicf("Type Error: структура '%s' не реализует метод '%s'", d.target_type, req_name)

					expected_method_type := iface_type.interface_methods[req_name]
					actual_method_type := ctx.res.symbol_types[method_sym]
					if !interface_method_types_match(expected_method_type, actual_method_type) {
						fmt.panicf(
							"Type Error: метод '%s' структуры '%s' не совпадает с контрактом интерфейса '%s'",
							req_name,
							d.target_type,
							d.interface_name,
						)
					}
				}
				append(&struct_type.implemented_interfaces, iface_type)
			}
		}
	}

	// ПРОХОД 4: Глубокая проверка тел всех функций и методов
	for decl in prog.decls {
		#partial switch d in decl {
		case ^Function_Decl:
			func_type := ctx.res.symbol_types[ctx.res.decl_symbols[decl]]
			bind_function_args(ctx, d, func_type)
			check_function_body(ctx, d.body, func_type.return_type)
		case ^Impl_Decl:
			for m in d.methods {
				sym := ctx.res.decl_symbols[m]
				func_type := ctx.res.symbol_types[sym]
				bind_function_args(ctx, m, func_type)
				check_function_body(ctx, m.body, func_type.return_type)
			}
		}
	}
}

// Преобразует синтаксический узел типа в внутреннее представление.
// Здесь же проверяются ограничения на generic-конструкторы.
resolve_type_node :: proc(ctx: ^Type_Ctx, node: Type_Node) -> ^Type {
	if node == nil do return TY_VOID

	switch n in node {
	case ^Type_Ident:
		if n.name == "Число" do return TY_NUM
		if n.name == "Булево" do return TY_BOOL
		if n.name == "Строка" do return TY_STRING
		if n.name == "Пусто" do return TY_VOID
		if n.name == "Ошибка" do return TY_ERROR
		if sym := lookup_symbol(ctx.res.global_scope, n.name); sym != nil {
			if sym.kind == .Module {
				fmt.panicf(
					"Type Error: модуль '%s' нельзя использовать как тип",
					n.name,
				)
			}
			if typ, ok := ctx.res.symbol_types[sym]; ok do return typ
		}
		fmt.panicf("Type Error: неизвестный тип '%s'", n.name)

	case ^Type_Tuple:
		elements := make([dynamic]^Type)
		for el_node in n.elements {
			append(&elements, resolve_type_node(ctx, el_node))
		}
		return new_tuple_type(elements)

	case ^Type_Function:
		params := make([dynamic]^Type)
		for p_node in n.params {
			append(&params, resolve_type_node(ctx, p_node))
		}
		return_type := resolve_type_node(ctx, n.return_type)
		return new_function_type(params, return_type)
	case ^Type_Qualified:
		module_sym := lookup_symbol(ctx.res.global_scope, n.module_name)
		if module_sym == nil || module_sym.kind != .Module {
			fmt.panicf("Type Error: неизвестный модуль '%s'", n.module_name)
		}
		imported_module := module_sym.module
		if imported_module == nil {
			fmt.panicf("Type Error: модуль '%s' не загружен", n.module_name)
		}
		if export_sym, found := imported_module.exports[n.name]; found {
			if typ, found_type := ctx.res.symbol_types[export_sym]; found_type {
				return typ
			}
			fmt.panicf(
				"Type Error: тип '%s.%s' еще не доступен",
				n.module_name,
				n.name,
			)
		}
		fmt.panicf(
			"Type Error: модуль '%s' не экспортирует '%s'",
			n.module_name,
			n.name,
		)
	case ^Type_Generic:
		if n.name == "Массив" {
			if len(n.params) != 1 do fmt.panicf("Type Error: Массив ожидает 1 параметр типа")
			return new_array_type(resolve_type_node(ctx, n.params[0]))
		} else if n.name == "Соответствие" {
			if len(n.params) != 2 do fmt.panicf("Type Error: Соответствие ожидает 2 параметра типа")
			key_type := resolve_type_node(ctx, n.params[0])
			if !is_valid_map_key_type(key_type) {
				fmt.panicf(
					"Type Error: тип '%s' нельзя использовать как ключ соответствия",
					key_type.name,
				)
			}
			return new_map_type(key_type, resolve_type_node(ctx, n.params[1]))
		} else if n.name == "Опция" {
			if len(n.params) != 1 do fmt.panicf("Type Error: Опция ожидает 1 параметр типа")
			return new_option_type(resolve_type_node(ctx, n.params[0]))
		} else if n.name == "Результат" {
			if len(n.params) != 2 do fmt.panicf("Type Error: Результат ожидает 2 параметра типа")
			return new_result_type(
				resolve_type_node(ctx, n.params[0]),
				resolve_type_node(ctx, n.params[1]),
			)
		}
	}
	return TY_VOID
}

// Строгое сравнение типов без вывода и без побочных связываний.
types_are_equal :: proc(a: ^Type, b: ^Type) -> bool {
	left := prune_type(a)
	right := prune_type(b)
	if left == nil || right == nil do return false
	if left == right do return true
	if left.kind == .InferVar || right.kind == .InferVar do return false

	if right.kind == .Interface && left.kind == .Struct {
		for iface in left.implemented_interfaces {
			if iface == right do return true
		}
		return false
	}

	if left.kind != right.kind do return false

	#partial switch left.kind {
	case .Tuple:
		if len(left.elements) != len(right.elements) do return false
		for i in 0 ..< len(left.elements) {
			if !types_are_equal(left.elements[i], right.elements[i]) do return false
		}
		return true

	case .Function:
		if len(left.params) != len(right.params) do return false
		if !types_are_equal(left.return_type, right.return_type) do return false
		for i in 0 ..< len(left.params) {
			if !types_are_equal(left.params[i], right.params[i]) do return false
		}
		return true

	case .Array:
		return types_are_equal(left.element_type, right.element_type)

	case .Map:
		return(
			types_are_equal(left.key_type, right.key_type) &&
			types_are_equal(left.value_type, right.value_type) \
		)

	case .Option:
		return types_are_equal(left.element_type, right.element_type)

	case .Result:
		return(
			types_are_equal(left.ok_type, right.ok_type) &&
			types_are_equal(left.error_type, right.error_type) \
		)

	case .Struct, .Interface:
		return false
	}
	return true
}

// Имя тупла строим из имён элементов, чтобы типы было удобно читать в ошибках.
new_tuple_type :: proc(elements: [dynamic]^Type) -> ^Type {
	t := new(Type)
	t.kind = .Tuple
	t.elements = elements

	builder: strings.Builder
	strings.builder_init(&builder)
	strings.write_string(&builder, "(")
	for el, i in elements {
		strings.write_string(&builder, el.name)
		if i < len(elements) - 1 do strings.write_string(&builder, ", ")
	}
	strings.write_string(&builder, ")")
	t.name = strings.to_string(builder)
	return t
}

// --- ПРОВЕРКА БЛОКОВ (Expression-Oriented Programming) ---

// В expression-oriented блоках типом блока считается тип последнего выражения.
infer_block_type :: proc(ctx: ^Type_Ctx, body: [dynamic]Stmt) -> ^Type {
	if len(body) == 0 do return TY_VOID

	// Проверяем все инструкции, кроме последней (они не влияют на возврат блока)
	for i in 0 ..< len(body) - 1 {
		infer_stmt(ctx, body[i])
	}

	// Последняя инструкция решает всё
	last_stmt := body[len(body) - 1]

	#partial switch s in last_stmt {
	case ^Expr_Stmt:
		// Если блок заканчивается выражением, блок принимает его тип
		return infer_expr(ctx, s.expr)
	case:
		// Let_Stmt или Return на конце блока ничего не возвращают (как значение блока)
		infer_stmt(ctx, last_stmt)
		return TY_VOID
	}
	return TY_VOID
}

// Проверка обычной функции против уже известной сигнатуры.
check_func_decl :: proc(ctx: ^Type_Ctx, d: ^Function_Decl) {
	func_type := ctx.res.symbol_types[ctx.res.decl_symbols[d]]
	check_function_body(ctx, d.body, func_type.return_type)
}

// Сначала проверяем инструкции сверху вниз, затем сверяем фактический тип
// блока и явные `return` с ожидаемым возвращаемым типом.
check_function_body :: proc(ctx: ^Type_Ctx, body: [dynamic]Stmt, expected_return: ^Type) {
	expected_return_type := prune_type(expected_return)
	prev_return := ctx.current_return
	ctx.current_return = expected_return_type

	for stmt in body {
		check_stmt(ctx, stmt, expected_return_type)
	}

	body_type := prune_type(infer_block_type(ctx, body))
	explicit_return_type := prune_type(infer_function_body(ctx, body))

	if expected_return_type == TY_VOID {
		if body_type != TY_VOID && !unify_types(body_type, TY_VOID) {
			fmt.panicf(
				"Type Error: функция объявлена как 'Пусто', но последнее выражение имеет тип '%s'",
				prune_type(body_type).name,
			)
		}
		ctx.current_return = prev_return
		return
	}

	if body_type != TY_VOID {
		if !unify_types(body_type, expected_return_type) {
			fmt.panicf(
				"Type Error: функция должна возвращать '%s', но последнее выражение имеет тип '%s'",
				prune_type(expected_return_type).name,
				prune_type(body_type).name,
			)
		}
		ctx.current_return = prev_return
		return
	}

	if explicit_return_type != nil && explicit_return_type != TY_VOID {
		if !unify_types(explicit_return_type, expected_return_type) {
			fmt.panicf(
				"Type Error: функция должна возвращать '%s', но return имеет тип '%s'",
				prune_type(expected_return_type).name,
				prune_type(explicit_return_type).name,
			)
		}
		ctx.current_return = prev_return
		return
	}

	ctx.current_return = prev_return
	fmt.panicf(
		"Type Error: функция должна возвращать '%s', но тело не возвращает значение",
		prune_type(expected_return_type).name,
	)
}

// Ищет первый явный `return` в теле callable-выражения.
infer_function_body :: proc(ctx: ^Type_Ctx, body: [dynamic]Stmt) -> ^Type {
	actual_return := TY_VOID
	for stmt in body {
		ret := infer_stmt(ctx, stmt)
		if ret != nil {
			actual_return = ret
			break
		}
	}
	return actual_return
}

// --- ПРОВЕРКА ИНСТРУКЦИЙ (STATEMENTS) ---

// Statement-level проверка знает ожидаемый тип возврата окружения.
check_stmt :: proc(ctx: ^Type_Ctx, stmt: Stmt, expected_return: ^Type) {
	if stmt == nil do return

	switch s in stmt {
	case ^Return_Stmt:
		if s.value != nil {
			check_expr(ctx, s.value, expected_return)
		} else if expected_return != TY_VOID {
			fmt.panicf(
				"Type Error: ожидался возврат %s, но return пустой",
				expected_return.name,
			)
		}

	case ^Let_Stmt, ^Expr_Stmt:
		infer_stmt(ctx, stmt)
	}
}

// Вывод типа инструкции, если она сама производит значение.
infer_stmt :: proc(ctx: ^Type_Ctx, stmt: Stmt) -> ^Type {
	if stmt == nil do return nil

	switch s in stmt {
	case ^Return_Stmt:
		if s.value != nil {
			return infer_expr(ctx, s.value)
		}
		return TY_VOID

	case ^Let_Stmt:
		sym := ctx.res.stmt_symbols[stmt]
		if s.type_annotation != nil {
			expected_type := resolve_type_node(ctx, s.type_annotation)
			if expected_type == TY_VOID {
				fmt.panicf(
					"Type Error: переменная '%s' не может иметь тип 'Пусто'",
					s.name,
				)
			}
			check_expr(ctx, s.value, expected_type)
			ctx.res.symbol_types[sym] = expected_type
		} else {
			t := infer_expr(ctx, s.value)
			t = prune_type(t)
			if t == TY_VOID {
				fmt.panicf(
					"Type Error: переменная '%s' не может иметь тип 'Пусто'",
					s.name,
				)
			}
			ensure_type_resolved(t, fmt.tprintf("переменной '%s'", s.name))
			ctx.res.symbol_types[sym] = t
		}

	case ^Expr_Stmt:
		infer_expr(ctx, s.expr)
	}
	return nil
}

// --- ПРОВЕРКА ВЫРАЖЕНИЙ (EXPRESSIONS) ---

// Проверяет выражение в контексте ожидаемого типа.
// Для лямбд, коллекций и вызовов это позволяет протолкнуть типы вниз.
check_expr :: proc(ctx: ^Type_Ctx, expr: Expr, expected: ^Type, loc := #caller_location) {
	if expr == nil do return
	expected_type := prune_type(expected)

	#partial switch e in expr {
	case ^Lambda_Expr:
		if expected_type.kind == .Function {
			check_lambda_expr(ctx, expr, e, expected_type)
			return
		}

	case ^Array_Expr:
		if expected_type.kind == .Array {
			for el in e.elements {
				check_expr(ctx, el, expected_type.element_type)
			}
			ctx.node_types[expr] = expected_type
			return
		}
	case ^Map_Expr:
		if expected_type.kind == .Map {
			for entry in e.entries {
				check_expr(ctx, entry.key, expected_type.key_type)
				check_expr(ctx, entry.value, expected_type.value_type)
			}
			ctx.node_types[expr] = expected_type
			return
		}
	}

	actual := infer_expr(ctx, expr)
	actual = prune_type(actual)

	if expected_type.kind == .Interface && actual.kind == .Struct {
		if unify_types(actual, expected_type) {
			ctx.interface_casts[expr] = actual
			return
		}
	}

	if !unify_types(actual, expected_type) {
		fmt.panicf(
			"Type Error: ожидался '%s', получен '%s'",
			prune_type(expected_type).name,
			prune_type(actual).name,
			loc = loc,
		)
	}
}

builtin_constructor_type :: proc(
	ctx: ^Type_Ctx,
	name: string,
	args: [dynamic]Expr,
) -> (
	^Type,
	bool,
) {
	switch name {
	case "Ошибка":
		if len(args) != 2 do fmt.panicf("Type Error: Ошибка() ожидает код и сообщение")
		check_expr(ctx, args[0], TY_STRING)
		check_expr(ctx, args[1], TY_STRING)
		return TY_ERROR, true

	case "Есть":
		if len(args) != 1 do fmt.panicf("Type Error: Есть() ожидает значение")
		return new_option_type(infer_expr(ctx, args[0])), true

	case "Нет":
		if len(args) != 0 do fmt.panicf("Type Error: Нет() не принимает аргументы")
		return new_option_type(new_infer_var(ctx)), true

	case "Успех":
		if len(args) != 1 do fmt.panicf("Type Error: Успех() ожидает значение")
		return new_result_type(infer_expr(ctx, args[0]), new_infer_var(ctx)), true

	case "Неудача":
		if len(args) != 1 do fmt.panicf("Type Error: Неудача() ожидает ошибку")
		return new_result_type(new_infer_var(ctx), infer_expr(ctx, args[0])), true

	case "длина":
		if len(args) != 1 do fmt.panicf("Type Error: длина() ожидает один аргумент")
		arg_type := prune_type(infer_expr(ctx, args[0]))
		if arg_type.kind == .String || arg_type.kind == .Array || arg_type.kind == .Map {
			return TY_NUM, true
		}
		fmt.panicf(
			"Type Error: длина() ожидает строку, массив или соответствие, получен '%s'",
			arg_type.name,
		)

	case "паника":
		if len(args) != 1 do fmt.panicf("Type Error: паника() ожидает сообщение")
		check_expr(ctx, args[0], TY_STRING)
		return TY_NEVER, true
	}

	return nil, false
}

standard_method_type :: proc(
	ctx: ^Type_Ctx,
	call: Expr,
	method_name: string,
	args: [dynamic]Expr,
	receiver_type: ^Type,
) -> (
	^Type,
	bool,
) {
	#partial switch receiver_type.kind {
	case .Option:
		switch method_name {
		case "есть":
			if len(args) != 0 do fmt.panicf("Type Error: Опция.есть() не принимает аргументы")
			ctx.collection_calls[call] = method_name
			return TY_BOOL, true
		case "пусто":
			if len(args) != 0 do fmt.panicf("Type Error: Опция.пусто() не принимает аргументы")
			ctx.collection_calls[call] = method_name
			return TY_BOOL, true
		case "значение":
			if len(args) != 0 do fmt.panicf("Type Error: Опция.значение() не принимает аргументы")
			ctx.collection_calls[call] = method_name
			return prune_type(receiver_type.element_type), true
		case "получить":
			if len(args) != 1 do fmt.panicf("Type Error: Опция.получить() ожидает значение по умолчанию")
			check_expr(ctx, args[0], receiver_type.element_type)
			ctx.collection_calls[call] = method_name
			return prune_type(receiver_type.element_type), true
		case "ожидать":
			if len(args) != 1 do fmt.panicf("Type Error: Опция.ожидать() ожидает сообщение")
			check_expr(ctx, args[0], TY_STRING)
			ctx.collection_calls[call] = method_name
			return prune_type(receiver_type.element_type), true
		case "результат_или":
			if len(args) != 1 do fmt.panicf("Type Error: Опция.результат_или() ожидает ошибку")
			error_type := infer_expr(ctx, args[0])
			ctx.collection_calls[call] = method_name
			return new_result_type(prune_type(receiver_type.element_type), prune_type(error_type)), true
		}

	case .Result:
		switch method_name {
		case "успех":
			if len(args) != 0 do fmt.panicf("Type Error: Результат.успех() не принимает аргументы")
			ctx.collection_calls[call] = method_name
			return TY_BOOL, true
		case "ошибка":
			if len(args) != 0 do fmt.panicf("Type Error: Результат.ошибка() не принимает аргументы")
			ctx.collection_calls[call] = method_name
			return TY_BOOL, true
		case "значение":
			if len(args) != 0 do fmt.panicf("Type Error: Результат.значение() не принимает аргументы")
			ctx.collection_calls[call] = method_name
			return prune_type(receiver_type.ok_type), true
		case "причина":
			if len(args) != 0 do fmt.panicf("Type Error: Результат.причина() не принимает аргументы")
			ctx.collection_calls[call] = method_name
			return prune_type(receiver_type.error_type), true
		case "получить":
			if len(args) != 1 do fmt.panicf("Type Error: Результат.получить() ожидает значение по умолчанию")
			check_expr(ctx, args[0], receiver_type.ok_type)
			ctx.collection_calls[call] = method_name
			return prune_type(receiver_type.ok_type), true
		case "ожидать":
			if len(args) != 1 do fmt.panicf("Type Error: Результат.ожидать() ожидает сообщение")
			check_expr(ctx, args[0], TY_STRING)
			ctx.collection_calls[call] = method_name
			return prune_type(receiver_type.ok_type), true
		case "опция":
			if len(args) != 0 do fmt.panicf("Type Error: Результат.опция() не принимает аргументы")
			ctx.collection_calls[call] = method_name
			return new_option_type(prune_type(receiver_type.ok_type)), true
		case "заменить_значение":
			if len(args) != 1 do fmt.panicf("Type Error: Результат.заменить_значение() ожидает новое значение")
			ok_type := infer_expr(ctx, args[0])
			ctx.collection_calls[call] = method_name
			return new_result_type(prune_type(ok_type), prune_type(receiver_type.error_type)), true
		case "заменить_ошибку":
			if len(args) != 1 do fmt.panicf("Type Error: Результат.заменить_ошибку() ожидает новую ошибку")
			error_type := infer_expr(ctx, args[0])
			ctx.collection_calls[call] = method_name
			return new_result_type(prune_type(receiver_type.ok_type), prune_type(error_type)), true
		}
	}

	return nil, false
}

// Выводит тип выражения без внешнего ожидания.
infer_expr :: proc(ctx: ^Type_Ctx, expr: Expr) -> ^Type {
	if expr == nil do return nil
	if t, ok := ctx.node_types[expr]; ok do return t

	t: ^Type
	switch e in expr {
	case ^Number_Expr:
		t = TY_NUM
	case ^Boolean_Expr:
		t = TY_BOOL
	case ^String_Expr:
		t = TY_STRING

	case ^Lambda_Expr:
		t = check_lambda_expr(ctx, expr, e)

	case ^Ident_Expr:
		sym := ctx.res.node_symbols[expr]
		if sym.kind == .Module {
			fmt.panicf(
				"Type Error: модуль '%s' нельзя использовать как значение",
				sym.name,
			)
		}
		if sym.kind == .Builtin {
			fmt.panicf(
				"Type Error: встроенный конструктор '%s' нужно вызвать через ()",
				sym.name,
			)
		}
		var_type, ok := ctx.res.symbol_types[sym]
		if !ok do fmt.panicf("Type Error: символ '%s' используется до инициализации", sym.name)
		t = prune_type(var_type)

	case ^Binary_Expr:
		#partial switch e.op {
		case .Plus:
			left_t := prune_type(infer_expr(ctx, e.left))
			right_t := prune_type(infer_expr(ctx, e.right))

			if left_t.kind == .InferVar && right_t == TY_STRING {
				unify_types(left_t, TY_STRING)
			} else if right_t.kind == .InferVar && left_t == TY_STRING {
				unify_types(right_t, TY_STRING)
			} else if left_t.kind == .InferVar && right_t == TY_NUM {
				unify_types(left_t, TY_NUM)
			} else if right_t.kind == .InferVar && left_t == TY_NUM {
				unify_types(right_t, TY_NUM)
			}

			left_t = prune_type(left_t)
			right_t = prune_type(right_t)
			if left_t == TY_STRING && right_t == TY_STRING {
				t = TY_STRING
			} else if left_t == TY_NUM && right_t == TY_NUM {
				t = TY_NUM
			} else {
				fmt.panicf(
					"Type Error: оператор '+' ожидает два числа или две строки, получено '%s' и '%s'",
					left_t.name,
					right_t.name,
				)
			}
		case .Minus, .Star, .Slash:
			check_expr(ctx, e.left, TY_NUM)
			check_expr(ctx, e.right, TY_NUM)
			t = TY_NUM
		case .Less, .Greater, .Equal:
			check_expr(ctx, e.left, TY_NUM)
			check_expr(ctx, e.right, TY_NUM)
			t = TY_BOOL

		case .Assign:
			left_t := infer_expr(ctx, e.left)
			check_expr(ctx, e.right, left_t)
			right_t := infer_expr(ctx, e.right)
			if !unify_types(right_t, left_t) {
				fmt.panicf(
					"Type Error: попытка присвоить значение типа '%s' в место типа '%s'",
					prune_type(right_t).name,
					prune_type(left_t).name,
				)
			}
			t = TY_VOID
		case:
			fmt.panicf("Type Error: неподдерживаемый оператор %v", e.op)
		}

	case ^Unary_Expr:
		check_expr(ctx, e.right, TY_NUM)
		t = TY_NUM

	case ^Call_Expr:
		if ident, ok := e.callee.(^Ident_Expr); ok {
			if sym := ctx.res.node_symbols[e.callee]; sym != nil && sym.kind == .Builtin {
				if builtin_type, handled := builtin_constructor_type(ctx, ident.name, e.args);
				   handled {
					t = builtin_type
					ctx.node_types[expr] = t
					return t
				}
			}
		}

		#partial switch prop_expr in e.callee {
		case ^Property_Expr:
			if obj_ident, ok := prop_expr.object.(^Ident_Expr); ok {
				if obj_sym := ctx.res.node_symbols[prop_expr.object];
				   obj_sym != nil && obj_sym.kind == .Module {
					imported_module := obj_sym.module
					if imported_module == nil {
						fmt.panicf(
							"Type Error: модуль '%s' не загружен",
							obj_ident.name,
						)
					}
					export_sym, found := imported_module.exports[prop_expr.property]
					if !found {
						fmt.panicf(
							"Type Error: модуль '%s' не экспортирует '%s'",
							obj_ident.name,
							prop_expr.property,
						)
					}

					export_type, found_type := ctx.res.symbol_types[export_sym]
					if !found_type || export_type == nil {
						if export_sym.kind == .Builtin {
							export_type = builtin_export_type(export_sym.full_name)
							if export_type != nil {
								ctx.res.symbol_types[export_sym] = export_type
							}
						} else if fn_decl, has_fn_decl := export_sym.decl.(^Function_Decl);
						   has_fn_decl {
							export_type = function_type_from_decl(ctx, fn_decl)
						}
						if export_type == nil {
							fmt.panicf(
								"Type Error: символ '%s.%s' еще не типизирован",
								obj_ident.name,
								prop_expr.property,
							)
						}
					}
					export_type = prune_type(export_type)
					#partial switch export_type.kind {
					case .Function:
						if len(e.args) != len(export_type.params) {
							fmt.panicf(
								"Type Error: неверное количество аргументов",
							)
						}
						for arg, i in e.args do check_expr(ctx, arg, export_type.params[i])
						if export_sym.kind == .Builtin {
							ctx.builtin_calls[expr] = export_sym.full_name
						}
						t = prune_type(export_type.return_type)
						ctx.node_types[expr] = t
						return t

					case .Struct:
						if len(e.args) != len(export_type.fields) {
							fmt.panicf(
								"Type Error: структура '%s' имеет %d полей",
								export_type.name,
								len(export_type.fields),
							)
						}
						for arg, i in e.args do check_expr(ctx, arg, export_type.fields[i].type)
						ctx.is_constructor[expr] = true
						t = export_type
						ctx.node_types[expr] = t
						return t

					case:
						fmt.panicf(
							"Type Error: символ '%s.%s' нельзя вызвать",
							obj_ident.name,
							prop_expr.property,
						)
					}
				}
			}

			obj_type := prune_type(infer_expr(ctx, prop_expr.object))

			if method_type, handled := standard_method_type(
				ctx,
				expr,
				prop_expr.property,
				e.args,
				obj_type,
			); handled {
				t = method_type
				ctx.node_types[expr] = t
				return t
			}

			if obj_type.kind == .Array {
				switch prop_expr.property {
				case "длина":
					if len(e.args) != 0 do fmt.panicf("Type Error: массив.длина() не принимает аргументы")
					ctx.collection_calls[expr] = prop_expr.property
					t = TY_NUM
					ctx.node_types[expr] = t
					return t
				case "добавить":
					if len(e.args) != 1 do fmt.panicf("Type Error: массив.добавить() ожидает 1 аргумент")
					check_expr(ctx, e.args[0], obj_type.element_type)
					ctx.collection_calls[expr] = prop_expr.property
					t = TY_VOID
					ctx.node_types[expr] = t
					return t
				case "получить":
					if len(e.args) != 2 do fmt.panicf("Type Error: массив.получить() ожидает индекс и значение по умолчанию")
					check_expr(ctx, e.args[0], TY_NUM)
					check_expr(ctx, e.args[1], obj_type.element_type)
					ctx.collection_calls[expr] = prop_expr.property
					t = obj_type.element_type
					ctx.node_types[expr] = t
					return t
				case "есть":
					if len(e.args) != 1 do fmt.panicf("Type Error: массив.есть() ожидает индекс")
					check_expr(ctx, e.args[0], TY_NUM)
					ctx.collection_calls[expr] = prop_expr.property
					t = TY_BOOL
					ctx.node_types[expr] = t
					return t
				case "содержит":
					if len(e.args) != 1 do fmt.panicf("Type Error: массив.содержит() ожидает значение")
					check_expr(ctx, e.args[0], obj_type.element_type)
					ctx.collection_calls[expr] = prop_expr.property
					t = TY_BOOL
					ctx.node_types[expr] = t
					return t
				case:
					fmt.panicf(
						"Type Error: у массива нет метода '%s'",
						prop_expr.property,
					)
				}

			} else if obj_type.kind == .Map {
				switch prop_expr.property {
				case "длина":
					if len(e.args) != 0 do fmt.panicf("Type Error: соответствие.длина() не принимает аргументы")
					ctx.collection_calls[expr] = prop_expr.property
					t = TY_NUM
					ctx.node_types[expr] = t
					return t
				case "есть":
					if len(e.args) != 1 do fmt.panicf("Type Error: соответствие.есть() ожидает ключ")
					check_expr(ctx, e.args[0], obj_type.key_type)
					ctx.collection_calls[expr] = prop_expr.property
					t = TY_BOOL
					ctx.node_types[expr] = t
					return t
				case "получить":
					if len(e.args) != 2 do fmt.panicf("Type Error: соответствие.получить() ожидает ключ и значение по умолчанию")
					check_expr(ctx, e.args[0], obj_type.key_type)
					check_expr(ctx, e.args[1], obj_type.value_type)
					ctx.collection_calls[expr] = prop_expr.property
					t = obj_type.value_type
					ctx.node_types[expr] = t
					return t
				case "удалить":
					if len(e.args) != 1 do fmt.panicf("Type Error: соответствие.удалить() ожидает ключ")
					check_expr(ctx, e.args[0], obj_type.key_type)
					ctx.collection_calls[expr] = prop_expr.property
					t = TY_BOOL
					ctx.node_types[expr] = t
					return t
				case:
					fmt.panicf(
						"Type Error: у соответствия нет метода '%s'",
						prop_expr.property,
					)
				}

			} else if obj_type.kind == .Struct {
				if method_sym, is_method := obj_type.methods[prop_expr.property]; is_method {
					method_type := ctx.res.symbol_types[method_sym]
					if len(e.args) != len(method_type.params) - 1 do fmt.panicf("У метода %s ожидалось %d аргументов", method_sym.name, len(method_type.params) - 1)
					check_expr(ctx, prop_expr.object, method_type.params[0])
					for arg, i in e.args do check_expr(ctx, arg, method_type.params[i + 1])

					ctx.method_calls[expr] = method_sym
					t = prune_type(method_type.return_type)
					ctx.node_types[expr] = t
					return t
				}
			} else if obj_type.kind == .Interface {
				if method_type, exists := obj_type.interface_methods[prop_expr.property]; exists {
					if len(e.args) != len(method_type.params) - 1 do fmt.panicf("Ожидалось %d аргументов", len(method_type.params) - 1)
					for arg, i in e.args do check_expr(ctx, arg, method_type.params[i + 1])

					ctx.interface_calls[expr] = prop_expr.property
					t = prune_type(method_type.return_type)
					ctx.node_types[expr] = t
					return t
				} else {
					fmt.panicf(
						"Type Error: в интерфейсе '%s' нет метода '%s'",
						obj_type.name,
						prop_expr.property,
					)
				}
			}
		}

		callee_type := prune_type(infer_expr(ctx, e.callee))
		if callee_type.kind == .Struct {
			if len(e.args) != len(callee_type.fields) do fmt.panicf("Type Error: структура '%s' имеет %d полей", callee_type.name, len(callee_type.fields))
			for arg, i in e.args do check_expr(ctx, arg, callee_type.fields[i].type)
			ctx.is_constructor[expr] = true
			t = callee_type

		} else if callee_type.kind == .Function {
			if len(e.args) != len(callee_type.params) do fmt.panicf("Type Error: неверное количество аргументов")
			for arg, i in e.args do check_expr(ctx, arg, callee_type.params[i])
			t = prune_type(callee_type.return_type)

		} else {
			fmt.panicf(
				"Type Error: значение типа '%s' нельзя вызвать",
				callee_type.name,
			)
		}

	case ^If_Expr:
		check_expr(ctx, e.condition, TY_BOOL)

		if len(e.else_branch) == 0 {
			// If без else всегда возвращает Void, так как не имеет значения для ложного условия
			infer_block_type(ctx, e.then_branch)
			t = TY_VOID
		} else {
			then_type := infer_block_type(ctx, e.then_branch)
			else_type := infer_block_type(ctx, e.else_branch)

			if !unify_types(then_type, else_type) {
				fmt.panicf(
					"Type Error: ветки 'если' возвращают разные типы. 'тогда' -> '%s', 'иначе' -> '%s'",
					prune_type(then_type).name,
					prune_type(else_type).name,
				)
			}
			if prune_type(then_type) == TY_NEVER {
				t = prune_type(else_type)
			} else {
				t = prune_type(then_type)
			}
		}

	case ^While_Expr:
		check_expr(ctx, e.condition, TY_BOOL)
		// Обязательно проверяем внутренности цикла (чтобы типизировать локальные переменные внутри)
		infer_block_type(ctx, e.body)
		t = TY_VOID

	case ^Tuple_Expr:
		elements_types := make([dynamic]^Type)
		for el in e.elements {
			append(&elements_types, infer_expr(ctx, el))
		}
		t = new_tuple_type(elements_types)

	case ^Array_Expr:
		if len(e.elements) == 0 {
			fmt.panicf(
				"Type Error: для пустого массива нужна аннотация ожидаемого типа",
			)
		}
		element_type := infer_expr(ctx, e.elements[0])
		for el, i in e.elements {
			current_type := infer_expr(ctx, el)
			if i > 0 && !unify_types(current_type, element_type) {
				fmt.panicf(
					"Type Error: элементы массива имеют разные типы: '%s' и '%s'",
					prune_type(element_type).name,
					prune_type(current_type).name,
				)
			}
		}
		t = new_array_type(prune_type(element_type))

	case ^Map_Expr:
		if len(e.entries) == 0 {
			fmt.panicf(
				"Type Error: для пустого соответствия нужна аннотация ожидаемого типа",
			)
		}
		key_type := infer_expr(ctx, e.entries[0].key)
		value_type := infer_expr(ctx, e.entries[0].value)
		for entry, i in e.entries {
			current_key_type := infer_expr(ctx, entry.key)
			current_value_type := infer_expr(ctx, entry.value)
			if !is_valid_map_key_type(current_key_type) {
				fmt.panicf(
					"Type Error: тип '%s' нельзя использовать как ключ соответствия",
					current_key_type.name,
				)
			}
			if i > 0 {
				if !unify_types(current_key_type, key_type) {
					fmt.panicf(
						"Type Error: ключи соответствия имеют разные типы: '%s' и '%s'",
						prune_type(key_type).name,
						prune_type(current_key_type).name,
					)
				}
				if !unify_types(current_value_type, value_type) {
					fmt.panicf(
						"Type Error: значения соответствия имеют разные типы: '%s' и '%s'",
						prune_type(value_type).name,
						prune_type(current_value_type).name,
					)
				}
			}
		}
		t = new_map_type(prune_type(key_type), prune_type(value_type))

	case ^Index_Expr:
		obj_type := prune_type(infer_expr(ctx, e.object))
		if obj_type.kind == .Array {
			check_expr(ctx, e.index, TY_NUM)
			t = prune_type(obj_type.element_type)
		} else if obj_type.kind == .Map {
			check_expr(ctx, e.index, obj_type.key_type)
			t = prune_type(obj_type.value_type)
		} else if obj_type.kind == .String {
			check_expr(ctx, e.index, TY_NUM)
			t = TY_STRING
		} else {
			fmt.panicf(
				"Type Error: индексирование поддерживают только массивы и соответствия, получен '%s'",
				obj_type.name,
			)
		}

	case ^Try_Expr:
		value_type := prune_type(infer_expr(ctx, e.value))
		if value_type.kind == .Option {
			return_type := prune_type(ctx.current_return)
			if return_type == nil || return_type.kind != .Option {
				fmt.panicf(
					"Type Error: оператор '?' для Опции можно использовать только в функции, возвращающей Опцию",
				)
			}
			t = prune_type(value_type.element_type)
		} else if value_type.kind == .Result {
			return_type := prune_type(ctx.current_return)
			if return_type == nil || return_type.kind != .Result {
				fmt.panicf(
					"Type Error: оператор '?' можно использовать только в функции, возвращающей Результат",
				)
			}
			if !unify_types(value_type.error_type, return_type.error_type) {
				fmt.panicf(
					"Type Error: оператор '?' возвращает ошибку типа '%s', но функция ожидает '%s'",
					prune_type(value_type.error_type).name,
					prune_type(return_type.error_type).name,
				)
			}
			t = prune_type(value_type.ok_type)
		} else {
			fmt.panicf(
				"Type Error: оператор '?' ожидает Опцию или Результат, получен '%s'",
				value_type.name,
			)
		}

	case ^Property_Expr:
		if sym, ok := ctx.res.node_symbols[expr]; ok {
			t = prune_type(ctx.res.symbol_types[sym])
			ctx.node_types[expr] = t
			return t
		}
		if obj_ident, ok := e.object.(^Ident_Expr); ok {
			if obj_sym := ctx.res.node_symbols[e.object];
			   obj_sym != nil && obj_sym.kind == .Module {
				imported_module := obj_sym.module
				if imported_module == nil {
					fmt.panicf(
						"Type Error: модуль '%s' не загружен",
						obj_ident.name,
					)
				}
				if export_sym, found := imported_module.exports[e.property]; found {
					if typ, found_type := ctx.res.symbol_types[export_sym];
					   found_type && typ != nil {
						t = prune_type(typ)
						ctx.node_types[expr] = t
						return t
					}
					if export_sym.kind == .Builtin {
						t = builtin_export_type(export_sym.full_name)
						if t != nil {
							ctx.res.symbol_types[export_sym] = t
							ctx.node_types[expr] = t
							return t
						}
					} else if fn_decl, has_fn_decl := export_sym.decl.(^Function_Decl);
					   has_fn_decl {
						t = function_type_from_decl(ctx, fn_decl)
						ctx.node_types[expr] = t
						return t
					}
					fmt.panicf(
						"Type Error: тип '%s.%s' еще не доступен",
						obj_ident.name,
						e.property,
					)
				}
				fmt.panicf(
					"Type Error: модуль '%s' не экспортирует '%s'",
					obj_ident.name,
					e.property,
				)
			}
		}
		obj_type := prune_type(infer_expr(ctx, e.object))
		if obj_type.kind == .Struct {
			field_idx := -1
			for f, i in obj_type.fields {
				if f.name == e.property {
					field_idx = i
					t = f.type
					break
				}
			}
			if field_idx == -1 do fmt.panicf("Type Error: у структуры '%s' нет поля '%s'", obj_type.name, e.property)
			ctx.property_indices[expr] = field_idx

		} else if obj_type.kind == .Tuple {
			idx, ok := strconv.parse_int(e.property)
			if !ok do fmt.panicf("Type Error: неверный индекс тупла '%s'", e.property)
			if idx < 0 || idx >= len(obj_type.elements) do fmt.panicf("Type Error: индекс %d выходит за границы", idx)
			t = obj_type.elements[idx]
			ctx.property_indices[expr] = idx

		} else if obj_type.kind == .Array || obj_type.kind == .Map {
			fmt.panicf(
				"Type Error: метод коллекции '%s' нужно вызвать через ()",
				e.property,
			)

		} else if obj_type.kind == .Error {
			switch e.property {
			case "код":
				t = TY_STRING
				ctx.property_indices[expr] = 0
			case "сообщение":
				t = TY_STRING
				ctx.property_indices[expr] = 1
			case:
				fmt.panicf("Type Error: у Ошибка нет поля '%s'", e.property)
			}

		} else if obj_type.kind == .Option || obj_type.kind == .Result {
			fmt.panicf(
				"Type Error: метод '%s' нужно вызвать через ()",
				e.property,
			)

		} else {
			fmt.panicf(
				"Type Error: попытка получить поле у не-структуры (тип: %s)",
				obj_type.name,
			)
		}
	}

	ctx.node_types[expr] = t
	return t
}

// Отладочная печать уже вычисленных типов символов.
print_type_ctx :: proc(ctx: ^Type_Ctx) {
	for symbol, type in ctx.res.symbol_types {
		fmt.printf("Символ '%s' имеет тип %s\n", symbol.name, prune_type(type).name)
	}
}
