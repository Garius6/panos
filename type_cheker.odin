// type_checker.odin
package main

import "core:fmt"

// --- ТИПЫ ДАННЫХ ---

Type_Kind :: enum {
	Number,
	Bool,
	Void,
	Function, // Тип для функций и лямбд
}

Type :: struct {
	kind:        Type_Kind,
	name:        string,
	// Поля ниже используются только если kind == .Function
	params:      [dynamic]^Type,
	return_type: ^Type,
}

// Интернированные базовые типы (одиночки, чтобы можно было сравнивать по указателю)
TY_NUM := &Type{kind = .Number, name = "Number"}
TY_BOOL := &Type{kind = .Bool, name = "Bool"}
TY_VOID := &Type{kind = .Void, name = "Void"}

// Помощник для создания новых типов функций в памяти
new_function_type :: proc(params: [dynamic]^Type, return_type: ^Type) -> ^Type {
	t := new(Type)
	t.kind = .Function
	t.name = "Function"
	t.params = params
	t.return_type = return_type
	return t
}

// --- КОНТЕКСТ ---

Type_Ctx :: struct {
	res:          ^Resolver_Ctx,
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

// --- ГЛАВНЫЙ ЦИКЛ ---

typecheck_program :: proc(ctx: ^Type_Ctx, prog: Program) {

	// ПРОХОД 1: Привязка типов к глобальным символам
	for decl in prog.decls {
		#partial switch d in decl {
		case ^Function_Decl:
			// 1. Создаем тип функции
			// (пока без параметров, позже возьмете их из AST)
			params := make([dynamic]^Type)
			func_type := new_function_type(params, TY_VOID)

			// 2. Берем символ функции из Резолвера (он был создан в Проходе 1 резолвера)
			sym := ctx.res.decl_symbols[decl]

			// 3. ПРИВЯЗЫВАЕМ тип к символу!
			ctx.symbol_types[sym] = func_type
		}
	}

	// ПРОХОД 2: Проверка тел функций
	for decl in prog.decls {
		#partial switch d in decl {
		case ^Function_Decl:
			check_func_decl(ctx, d)
		}
	}
}

// --- ПРОВЕРКА ФУНКЦИЙ ---

check_func_decl :: proc(ctx: ^Type_Ctx, d: ^Function_Decl) {
	// В реальном коде вы возьмете заявленный тип из AST (например, -> Number)
	// Для примера предполагаем, что парсер вернул ожидаемый тип (или TY_VOID)
	expected_return := TY_VOID // Замените на d.declared_return_type, когда добавите в парсер

	// Вызываем проверку сверху-вниз
	check_function_body(ctx, d.body, expected_return)
}

// Режим CHECK (Сверху-вниз): мы ЗНАЕМ, что должна вернуть функция
check_function_body :: proc(ctx: ^Type_Ctx, body: [dynamic]Stmt, expected_return: ^Type) {
	for stmt in body {
		check_stmt(ctx, stmt, expected_return)
	}
}

// Режим INFER (Снизу-вверх): мы НЕ ЗНАЕМ, что вернет функция (например, лямбда)
infer_function_body :: proc(ctx: ^Type_Ctx, body: [dynamic]Stmt) -> ^Type {
	actual_return := TY_VOID

	for stmt in body {
		ret := infer_stmt(ctx, stmt)
		if ret != nil {
			actual_return = ret
			break // Нашли return, прекращаем анализ (Dead Code Analysis)
		}
	}
	return actual_return
}

// --- ПРОВЕРКА ИНСТРУКЦИЙ (STATEMENTS) ---

// Режим CHECK
check_stmt :: proc(ctx: ^Type_Ctx, stmt: Stmt, expected_return: ^Type) {
	if stmt == nil do return

	switch s in stmt {
	case ^Return_Stmt:
		if s.value != nil {
			// Выражение return должно строго соответствовать expected_return
			check_expr(ctx, s.value, expected_return)
		} else if expected_return != TY_VOID {
			fmt.panicf(
				"Type Error: ожидался возврат %s, но return пустой",
				expected_return.name,
			)
		}

	case ^Let_Stmt, ^Expr_Stmt:
		// Для инструкций, которые не делают return, мы просто выводим их внутренние типы
		infer_stmt(ctx, stmt)
	}
}

// Режим INFER: Инструкция "поднимает" тип возврата наверх, если он есть
infer_stmt :: proc(ctx: ^Type_Ctx, stmt: Stmt) -> ^Type {
	if stmt == nil do return nil

	switch s in stmt {
	case ^Return_Stmt:
		if s.value != nil {
			return infer_expr(ctx, s.value)
		}
		return TY_VOID

	case ^Let_Stmt:
		t := infer_expr(ctx, s.value)
		sym := ctx.res.stmt_symbols[stmt]
		ctx.symbol_types[sym] = t

	case ^Expr_Stmt:
		infer_expr(ctx, s.expr)
	}

	return nil // Обычные инструкции ничего не возвращают
}

// --- ПРОВЕРКА ВЫРАЖЕНИЙ (EXPRESSIONS) ---

// Режим CHECK: Убеждается, что выведенный тип совпадает с ожидаемым
check_expr :: proc(ctx: ^Type_Ctx, expr: Expr, expected: ^Type) {
	if expr == nil do return

	actual := infer_expr(ctx, expr)

	// В более сложных языках здесь будет функция unification (сравнение сигнатур),
	// но для базовых типов достаточно проверки указателей.
	if actual != expected {
		fmt.panicf(
			"Type Error: ожидался '%s', получен '%s'",
			expected.name,
			actual.name,
		)
	}
}

// Режим INFER: Вычисляет тип выражения "изнутри"
infer_expr :: proc(ctx: ^Type_Ctx, expr: Expr) -> ^Type {
	if expr == nil do return nil

	// Кэширование
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
			fmt.panicf(
				"Type Error: символ '%s' используется до инициализации",
				sym.name,
			)
		}
		t = var_type

	case ^Binary_Expr:
		#partial switch e.op {
		case .Plus, .Minus, .Star, .Slash:
			// Мы ЗНАЕМ, что математика работает только с числами, поэтому используем CHECK
			check_expr(ctx, e.left, TY_NUM)
			check_expr(ctx, e.right, TY_NUM)
			t = TY_NUM
		case:
			fmt.panicf("Type Error: неподдерживаемый оператор %v", e.op)
		}

	case ^Unary_Expr:
		check_expr(ctx, e.right, TY_NUM)
		t = TY_NUM

	case ^Call_Expr:
		callee_type := infer_expr(ctx, e.callee)

		if callee_type.kind != .Function {
			fmt.panicf(
				"Type Error: попытка вызвать значение типа '%s'. Вызывать можно только функции.",
				callee_type.name,
			)
		}

		if len(e.args) != len(callee_type.params) {
			fmt.panicf(
				"Type Error: неверное количество аргументов. Ожидалось %d, передано %d",
				len(callee_type.params),
				len(e.args),
			)
		}

		// Проверяем, что каждый переданный аргумент совпадает с ожидаемым параметром
		for arg, i in e.args {
			check_expr(ctx, arg, callee_type.params[i])
		}

		t = callee_type.return_type

	// case ^Lambda_Expr:
	// 	// Выводим тип возвращаемого значения из тела лямбды
	// 	actual_return := infer_function_body(ctx, e.body)
	//
	// 	// Собираем типы параметров (временно заглушка, так как параметры лямбды нужно парсить)
	// 	params := make([dynamic]^Type)
	//
	// 	t = new_function_type(params, actual_return)
	}

	ctx.node_types[expr] = t
	return t
}

print_type_ctx :: proc(ctx: ^Type_Ctx) {
	for symbol, type in ctx.symbol_types {
		fmt.printf("Символ '%s' имеет тип %s\n", symbol.name, type.name)
	}
}
