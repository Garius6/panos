package main

import "core:fmt"
import "core:strconv"
import "core:strings"

// --- ТИПЫ ДАННЫХ ---

Type_Kind :: enum {
	Number,
	Bool,
	Void,
	String,
	Function,
	Tuple,
	Struct,
	Interface,
	Array,
	Map,
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
}

Struct_Field :: struct {
	name: string,
	type: ^Type,
}

// Интернированные базовые типы
TY_NUM := &Type{kind = .Number, name = "Число"}
TY_BOOL := &Type{kind = .Bool, name = "Булево"}
TY_VOID := &Type{kind = .Void, name = "Пусто"}
TY_STRING := &Type{kind = .String, name = "Строка"}

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

is_valid_map_key_type :: proc(t: ^Type) -> bool {
	return t.kind == .Number || t.kind == .Bool || t.kind == .String
}

// --- КОНТЕКСТ ---

Type_Ctx :: struct {
	res:              ^Resolver_Ctx,
	node_types:       map[Expr]^Type,
	symbol_types:     map[^Symbol]^Type,
	is_constructor:   map[Expr]bool,
	property_indices: map[Expr]int,
	method_calls:     map[Expr]^Symbol,
	interface_casts:  map[Expr]^Type,
	interface_calls:  map[Expr]string,
	collection_calls: map[Expr]string,
}

new_type_ctx :: proc(res: ^Resolver_Ctx) -> Type_Ctx {
	return Type_Ctx {
		res = res,
		node_types = make(map[Expr]^Type),
		symbol_types = make(map[^Symbol]^Type),
		is_constructor = make(map[Expr]bool),
		property_indices = make(map[Expr]int),
		method_calls = make(map[Expr]^Symbol),
		interface_casts = make(map[Expr]^Type),
		interface_calls = make(map[Expr]string),
		collection_calls = make(map[Expr]string),
	}
}

resolve_param_types :: proc(ctx: ^Type_Ctx, args: [dynamic]Param_Decl) -> [dynamic]^Type {
	params := make([dynamic]^Type)
	for arg in args {
		append(&params, resolve_type_node(ctx, arg.type_annotation))
	}
	return params
}

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

bind_function_args :: proc(ctx: ^Type_Ctx, d: ^Function_Decl, func_type: ^Type) {
	if args_syms, ok := ctx.res.func_args[d]; ok {
		if len(args_syms) != len(func_type.params) {
			fmt.panicf(
				"Type Error: функция '%s' имеет рассинхронизированные аргументы",
				d.name,
			)
		}
		for arg_sym, i in args_syms {
			ctx.symbol_types[arg_sym] = func_type.params[i]
		}
	}
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
			ctx.symbol_types[sym] = struct_type

		case ^Interface_Decl:
			iface_type := new(Type)
			iface_type.kind = .Interface
			iface_type.name = d.name
			iface_type.interface_methods = make(map[string]^Type)
			ctx.symbol_types[ctx.res.decl_symbols[decl]] = iface_type
		}
	}

	// ПРОХОД 2: заполняем структуры, интерфейсы и сигнатуры функций.
	for decl in prog.decls {
		#partial switch d in decl {
		case ^Struct_Decl:
			sym := ctx.res.decl_symbols[decl]
			struct_type := ctx.symbol_types[sym]
			struct_type.fields = make([dynamic]Struct_Field)

			for f in d.fields {
				field_type := resolve_type_node(ctx, f.type_annotation)
				append(&struct_type.fields, Struct_Field{name = f.name, type = field_type})
			}

		case ^Function_Decl:
			sym := ctx.res.decl_symbols[decl]
			ctx.symbol_types[sym] = function_type_from_decl(ctx, d)

		case ^Interface_Decl:
			iface_type := ctx.symbol_types[ctx.res.decl_symbols[decl]]
			iface_type.interface_methods = make(map[string]^Type)
			for m in d.methods {
				iface_type.interface_methods[m.name] = interface_method_type_from_signature(ctx, iface_type, m)
			}
		}
	}

	// ПРОХОД 3: Привязка реализаций (методов и контрактов) к структурам
	for decl in prog.decls {
		#partial switch d in decl {
		case ^Impl_Decl:
			target_sym := ctx.res.global_scope.symbols[d.target_type]
			struct_type := ctx.symbol_types[target_sym]
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
				if len(method_type.params) == 0 || !types_are_equal(method_type.params[0], struct_type) {
					fmt.panicf(
						"Type Error: первый аргумент метода '%s' должен иметь тип '%s'",
						m.name,
						struct_type.name,
					)
				}
				ctx.symbol_types[sym] = method_type
				original_name := m.name[len(d.target_type) + 2:]
				struct_type.methods[original_name] = sym
			}

			// Строгая проверка интерфейсного контракта
			if d.interface_name != "" {
				iface_sym := ctx.res.global_scope.symbols[d.interface_name]
				iface_type := ctx.symbol_types[iface_sym]

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
					actual_method_type := ctx.symbol_types[method_sym]
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
			func_type := ctx.symbol_types[ctx.res.decl_symbols[decl]]
			bind_function_args(ctx, d, func_type)
			check_function_body(ctx, d.body, func_type.return_type)
		case ^Impl_Decl:
			for m in d.methods {
				sym := ctx.res.decl_symbols[m]
				func_type := ctx.symbol_types[sym]
				bind_function_args(ctx, m, func_type)
				check_function_body(ctx, m.body, func_type.return_type)
			}
		}
	}
}

resolve_type_node :: proc(ctx: ^Type_Ctx, node: Type_Node) -> ^Type {
	if node == nil do return TY_VOID

	switch n in node {
	case ^Type_Ident:
		if n.name == "Число" do return TY_NUM
		if n.name == "Булево" do return TY_BOOL
		if n.name == "Строка" do return TY_STRING
		if n.name == "Пусто" do return TY_VOID
		if sym := lookup_symbol(ctx.res.global_scope, n.name); sym != nil {
			if typ, ok := ctx.symbol_types[sym]; ok do return typ
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
	case ^Type_Generic:
		if n.name == "Массив" {
			if len(n.params) != 1 do fmt.panicf("Type Error: Массив ожидает 1 параметр типа")
			return new_array_type(resolve_type_node(ctx, n.params[0]))
		} else if n.name == "Соответствие" {
			if len(n.params) != 2 do fmt.panicf("Type Error: Соответствие ожидает 2 параметра типа")
			key_type := resolve_type_node(ctx, n.params[0])
			if !is_valid_map_key_type(key_type) {
				fmt.panicf("Type Error: тип '%s' нельзя использовать как ключ соответствия", key_type.name)
			}
			return new_map_type(key_type, resolve_type_node(ctx, n.params[1]))
		}
	}
	return TY_VOID
}

types_are_equal :: proc(a: ^Type, b: ^Type) -> bool {
	if a == nil || b == nil do return false
	if a == b do return true

	if b.kind == .Interface && a.kind == .Struct {
		for iface in a.implemented_interfaces {
			if iface == b do return true
		}
		return false
	}

	if a.kind != b.kind do return false

	#partial switch a.kind {
	case .Tuple:
		if len(a.elements) != len(b.elements) do return false
		for i in 0 ..< len(a.elements) {
			if !types_are_equal(a.elements[i], b.elements[i]) do return false
		}
		return true

	case .Function:
		if len(a.params) != len(b.params) do return false
		if !types_are_equal(a.return_type, b.return_type) do return false
		for i in 0 ..< len(a.params) {
			if !types_are_equal(a.params[i], b.params[i]) do return false
		}
		return true

	case .Array:
		return types_are_equal(a.element_type, b.element_type)

	case .Map:
		return types_are_equal(a.key_type, b.key_type) &&
		       types_are_equal(a.value_type, b.value_type)

	case .Struct, .Interface:
		return false
	}
	return true
}

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

// Помощник для вывода типа блока кода (для If и других EOP конструкций)
// Блок возвращает тип своего ПОСЛЕДНЕГО выражения.
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

check_func_decl :: proc(ctx: ^Type_Ctx, d: ^Function_Decl) {
	func_type := ctx.symbol_types[ctx.res.decl_symbols[d]]
	check_function_body(ctx, d.body, func_type.return_type)
}

check_function_body :: proc(ctx: ^Type_Ctx, body: [dynamic]Stmt, expected_return: ^Type) {
	for stmt in body {
		check_stmt(ctx, stmt, expected_return)
	}

	body_type := infer_block_type(ctx, body)
	explicit_return_type := infer_function_body(ctx, body)

	if expected_return == TY_VOID {
		if body_type != TY_VOID {
			fmt.panicf(
				"Type Error: функция объявлена как 'Пусто', но последнее выражение имеет тип '%s'",
				body_type.name,
			)
		}
		return
	}

	if body_type != TY_VOID {
		if !types_are_equal(body_type, expected_return) {
			fmt.panicf(
				"Type Error: функция должна возвращать '%s', но последнее выражение имеет тип '%s'",
				expected_return.name,
				body_type.name,
			)
		}
		return
	}

	if explicit_return_type != nil && explicit_return_type != TY_VOID {
		if !types_are_equal(explicit_return_type, expected_return) {
			fmt.panicf(
				"Type Error: функция должна возвращать '%s', но return имеет тип '%s'",
				expected_return.name,
				explicit_return_type.name,
			)
		}
		return
	}

	fmt.panicf(
		"Type Error: функция должна возвращать '%s', но тело не возвращает значение",
		expected_return.name,
	)
}

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
				fmt.panicf("Type Error: переменная '%s' не может иметь тип 'Пусто'", s.name)
			}
			check_expr(ctx, s.value, expected_type)
			ctx.symbol_types[sym] = expected_type
		} else {
			t := infer_expr(ctx, s.value)
			if t == TY_VOID {
				fmt.panicf("Type Error: переменная '%s' не может иметь тип 'Пусто'", s.name)
			}
			ctx.symbol_types[sym] = t
		}

	case ^Expr_Stmt:
		infer_expr(ctx, s.expr)
	}
	return nil
}

// --- ПРОВЕРКА ВЫРАЖЕНИЙ (EXPRESSIONS) ---

check_expr :: proc(ctx: ^Type_Ctx, expr: Expr, expected: ^Type, loc := #caller_location) {
	if expr == nil do return

	#partial switch e in expr {
	case ^Array_Expr:
		if expected.kind == .Array {
			for el in e.elements {
				check_expr(ctx, el, expected.element_type)
			}
			ctx.node_types[expr] = expected
			return
		}
	case ^Map_Expr:
		if expected.kind == .Map {
			for entry in e.entries {
				check_expr(ctx, entry.key, expected.key_type)
				check_expr(ctx, entry.value, expected.value_type)
			}
			ctx.node_types[expr] = expected
			return
		}
	}

	actual := infer_expr(ctx, expr)

	if expected.kind == .Interface && actual.kind == .Struct {
		if types_are_equal(actual, expected) {
			ctx.interface_casts[expr] = actual
			return
		}
	}

	if !types_are_equal(actual, expected) {
		fmt.panicf(
			"Type Error: ожидался '%s', получен '%s'",
			expected.name,
			actual.name,
			loc = loc,
		)
	}
}

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
		params := resolve_param_types(ctx, e.args)
		if args_syms, ok := ctx.res.lambda_args[expr]; ok {
			if len(args_syms) != len(params) {
				fmt.panicf("Type Error: лямбда имеет рассинхронизированные аргументы")
			}
			for sym, i in args_syms do ctx.symbol_types[sym] = params[i]
		}
		ret_type := resolve_type_node(ctx, e.return_type)
		check_function_body(ctx, e.body, ret_type)
		t = new_function_type(params, ret_type)

	case ^Ident_Expr:
		sym := ctx.res.node_symbols[expr]
		var_type, ok := ctx.symbol_types[sym]
		if !ok do fmt.panicf("Type Error: символ '%s' используется до инициализации", sym.name)
		t = var_type

	case ^Binary_Expr:
		#partial switch e.op {
		case .Plus, .Minus, .Star, .Slash:
			check_expr(ctx, e.left, TY_NUM)
			check_expr(ctx, e.right, TY_NUM)
			t = TY_NUM
		case .Less, .Greater:
			check_expr(ctx, e.left, TY_NUM)
			check_expr(ctx, e.right, TY_NUM)
			t = TY_BOOL
		case .Assign:
			left_t := infer_expr(ctx, e.left)
			right_t := infer_expr(ctx, e.right)
			if !types_are_equal(left_t, right_t) {
				fmt.panicf(
					"Type Error: попытка присвоить значение типа '%s' в место типа '%s'",
					right_t.name,
					left_t.name,
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
		#partial switch prop_expr in e.callee {
		case ^Property_Expr:
			obj_type := infer_expr(ctx, prop_expr.object)

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
					default_type := infer_expr(ctx, e.args[1])
					if !types_are_equal(default_type, obj_type.element_type) {
						fmt.panicf(
							"Type Error: значение по умолчанию имеет тип '%s', ожидался '%s'",
							default_type.name,
							obj_type.element_type.name,
						)
					}
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
					fmt.panicf("Type Error: у массива нет метода '%s'", prop_expr.property)
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
					default_type := infer_expr(ctx, e.args[1])
					if !types_are_equal(default_type, obj_type.value_type) {
						fmt.panicf(
							"Type Error: значение по умолчанию имеет тип '%s', ожидался '%s'",
							default_type.name,
							obj_type.value_type.name,
						)
					}
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
					fmt.panicf("Type Error: у соответствия нет метода '%s'", prop_expr.property)
				}

			} else if obj_type.kind == .Struct {
				if method_sym, is_method := obj_type.methods[prop_expr.property]; is_method {
					method_type := ctx.symbol_types[method_sym]
					if len(e.args) != len(method_type.params) - 1 do fmt.panicf("У метода %s ожидалось %d аргументов", method_sym.name, len(method_type.params) - 1)
					check_expr(ctx, prop_expr.object, method_type.params[0])
					for arg, i in e.args do check_expr(ctx, arg, method_type.params[i + 1])

					ctx.method_calls[expr] = method_sym
					t = method_type.return_type
					ctx.node_types[expr] = t
					return t
				}
			} else if obj_type.kind == .Interface {
				if method_type, exists := obj_type.interface_methods[prop_expr.property]; exists {
					if len(e.args) != len(method_type.params) - 1 do fmt.panicf("Ожидалось %d аргументов", len(method_type.params) - 1)
					for arg, i in e.args do check_expr(ctx, arg, method_type.params[i + 1])

					ctx.interface_calls[expr] = prop_expr.property
					t = method_type.return_type
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

		callee_type := infer_expr(ctx, e.callee)
		if callee_type.kind == .Struct {
			if len(e.args) != len(callee_type.fields) do fmt.panicf("Type Error: структура '%s' имеет %d полей", callee_type.name, len(callee_type.fields))
			for arg, i in e.args do check_expr(ctx, arg, callee_type.fields[i].type)
			ctx.is_constructor[expr] = true
			t = callee_type

		} else if callee_type.kind == .Function {
			if len(e.args) != len(callee_type.params) do fmt.panicf("Type Error: неверное количество аргументов")
			for arg, i in e.args do check_expr(ctx, arg, callee_type.params[i])
			t = callee_type.return_type

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

			if !types_are_equal(then_type, else_type) {
				fmt.panicf(
					"Type Error: ветки 'если' возвращают разные типы. 'тогда' -> '%s', 'иначе' -> '%s'",
					then_type.name,
					else_type.name,
				)
			}
			t = then_type
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
			fmt.panicf("Type Error: для пустого массива нужна аннотация ожидаемого типа")
		}
		element_type := infer_expr(ctx, e.elements[0])
		for el, i in e.elements {
			current_type := infer_expr(ctx, el)
			if i > 0 && !types_are_equal(current_type, element_type) {
				fmt.panicf(
					"Type Error: элементы массива имеют разные типы: '%s' и '%s'",
					element_type.name,
					current_type.name,
				)
			}
		}
		t = new_array_type(element_type)

	case ^Map_Expr:
		if len(e.entries) == 0 {
			fmt.panicf("Type Error: для пустого соответствия нужна аннотация ожидаемого типа")
		}
		key_type := infer_expr(ctx, e.entries[0].key)
		value_type := infer_expr(ctx, e.entries[0].value)
		for entry, i in e.entries {
			current_key_type := infer_expr(ctx, entry.key)
			current_value_type := infer_expr(ctx, entry.value)
			if !is_valid_map_key_type(current_key_type) {
				fmt.panicf("Type Error: тип '%s' нельзя использовать как ключ соответствия", current_key_type.name)
			}
			if i > 0 {
				if !types_are_equal(current_key_type, key_type) {
					fmt.panicf(
						"Type Error: ключи соответствия имеют разные типы: '%s' и '%s'",
						key_type.name,
						current_key_type.name,
					)
				}
				if !types_are_equal(current_value_type, value_type) {
					fmt.panicf(
						"Type Error: значения соответствия имеют разные типы: '%s' и '%s'",
						value_type.name,
						current_value_type.name,
					)
				}
			}
		}
		t = new_map_type(key_type, value_type)

	case ^Index_Expr:
		obj_type := infer_expr(ctx, e.object)
		if obj_type.kind == .Array {
			check_expr(ctx, e.index, TY_NUM)
			t = obj_type.element_type
		} else if obj_type.kind == .Map {
			check_expr(ctx, e.index, obj_type.key_type)
			t = obj_type.value_type
		} else {
			fmt.panicf(
				"Type Error: индексирование поддерживают только массивы и соответствия, получен '%s'",
				obj_type.name,
			)
		}

	case ^Property_Expr:
		obj_type := infer_expr(ctx, e.object)
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
			fmt.panicf("Type Error: метод коллекции '%s' нужно вызвать через ()", e.property)

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

print_type_ctx :: proc(ctx: ^Type_Ctx) {
	for symbol, type in ctx.symbol_types {
		fmt.printf("Символ '%s' имеет тип %s\n", symbol.name, type.name)
	}
}
