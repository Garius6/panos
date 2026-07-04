package main

import "core:fmt"
import "core:strings"

Value :: union {
	f64,
	bool,
	^Compiled_Function,
}

Compiled_Function :: struct {
	name:         string,
	instructions: [dynamic]u8,
	constants:    [dynamic]Value,
	frame_size:   int,
}

Local :: struct {
	symbol: ^Symbol, // Берем из Resolver_Ctx
	depth:  int,
}

Compiler :: struct {
	registry:         ^map[string]^Compiled_Function, // Указатель на глобальный реестр
	current_function: ^Compiled_Function,
	res:              ^Resolver_Ctx,
	locals:           [dynamic]Local,
	scope_depth:      int,
}

new_compiler :: proc(res: ^Resolver_Ctx, name: string) -> Compiler {

	c := Compiler {
		res         = res,
		locals      = make([dynamic]Local),
		scope_depth = 0,
	}
	return c
}

Opcode :: enum u8 {
	Constant, // Операнд: 1 байт (индекс в пуле констант)
	Add, // Без операндов
	Subtract,
	Multiply,
	Divide,
	Get_Local, // Операнд: 1 байт (индекс слота во фрейме)
	Set_Local, // Операнд: 1 байт (индекс слота во фрейме)
	Jump_If_False, // Операнд: 2 байта (смещение прыжка)
	Jump, // Операнд: 2 байта (смещение прыжка)
	Pop, // Удалить вершину стека
	Return, // Возврат из функции
	Call,
}

// Записать 1 байт в массив инструкций
emit_byte :: proc(c: ^Compiler, byte: u8) {
	append(&c.current_function.instructions, byte)
}

// Записать опкод
emit_opcode :: proc(c: ^Compiler, op: Opcode) {
	emit_byte(c, u8(op))
}

// Сохранить константу и сгенерировать инструкцию для ее загрузки
emit_constant :: proc(c: ^Compiler, value: Value) {
	append(&c.current_function.constants, value)
	idx := len(c.current_function.constants) - 1

	if idx > 255 {
		fmt.panicf("Too many constants in one function!") // Для простоты используем 1 байт
	}

	emit_opcode(c, .Constant)
	emit_byte(c, u8(idx))
}

// Генерирует опкод прыжка и 2 пустых байта для адреса.
// Возвращает индекс, куда потом нужно будет вписать правильный адрес.
emit_jump :: proc(c: ^Compiler, op: Opcode) -> int {
	emit_opcode(c, op)
	emit_byte(c, 0xff) // Фиктивный старший байт
	emit_byte(c, 0xff) // Фиктивный младший байт
	return len(c.current_function.instructions) - 2
}

// Вызывается после того, как тело блока скомпилировано.
// Вычисляет длину прыжка и "зашивает" ее поверх 0xFFFF.
patch_jump :: proc(c: ^Compiler, offset: int) {
	// Насколько далеко нужно прыгнуть (текущая длина минус адрес прыжка минус 2 байта операнда)
	jump_length := len(c.current_function.instructions) - offset - 2

	if jump_length > 65535 {
		fmt.panicf("Too much code to jump over!")
	}

	c.current_function.instructions[offset] = u8((jump_length >> 8) & 0xff) // Старший байт
	c.current_function.instructions[offset + 1] = u8(jump_length & 0xff) // Младший байт
}

compile_program :: proc(res: ^Resolver_Ctx, program: ^Program) -> map[string]^Compiled_Function {
	registry := make(map[string]^Compiled_Function)

	// ПРОХОД 1: Выделяем память под функции (Hoisting)
	// Это позволит функции 'старт' вызывать функцию 'а', даже если 'а' объявлена ниже.
	for decl in program.decls {
		#partial switch d in decl {
		case ^Function_Decl:
			fn := new(Compiled_Function)
			fn.name = d.name
			// Инициализируем массивы функции
			fn.instructions = make([dynamic]u8)
			fn.constants = make([dynamic]Value)
			registry[d.name] = fn
		}
	}

	// ПРОХОД 2: Компиляция тел функций
	for decl in program.decls {
		#partial switch d in decl {
		case ^Function_Decl:
			// СОЗДАЕМ ЧИСТЫЙ КОНТЕКСТ ДЛЯ ЭТОЙ ФУНКЦИИ!
			// Массив locals пуст, scope_depth = 0. Никаких утечек переменных.
			ctx := Compiler {
				registry         = &registry,
				current_function = registry[d.name],
				res              = res,
				locals           = make([dynamic]Local),
				scope_depth      = 0,
			}

			// Компилируем тело
			for stmt in d.body {
				compile_statement(&ctx, stmt)
			}

			// Защита: если программист забыл написать return, компилятор добавит его сам
			emit_opcode(&ctx, .Return)
		}
	}

	return registry // Возвращаем только готовые функции!}
}

compile_decl :: proc(c: ^Compiler, decl: Decls) {
	switch d in decl {
	case ^Function_Decl:
		function := new(Compiled_Function)
		function.name = d.name

		c.current_function = function

		for stmt in d.body {
			compile_statement(c, stmt)
		}

		c.registry[function.name] = function
	}
}

compile_statement :: proc(ctx: ^Compiler, statement: Stmt) {
	switch stmt in statement {
	case ^Let_Stmt:
		compile_expr(ctx, stmt.value)

		sym := ctx.res.stmt_symbols[stmt]
		append(&ctx.locals, Local{symbol = sym, depth = ctx.scope_depth})
		slot_index := len(ctx.locals) - 1

		ctx.current_function.frame_size = max(ctx.current_function.frame_size, len(ctx.locals))

		emit_opcode(ctx, .Set_Local)
		emit_byte(ctx, u8(slot_index))

	case ^Return_Stmt:
		if stmt.value != nil {
			compile_expr(ctx, stmt.value)
		}
		emit_opcode(ctx, .Return)

	case ^Expr_Stmt:
		compile_expr(ctx, stmt.expr)
		emit_opcode(ctx, .Pop)
	}
}

compile_expr :: proc(ctx: ^Compiler, expr: Expr) {

	switch e in expr {
	case ^Number_Expr:
		emit_constant(ctx, e.value)
	case ^Boolean_Expr:
		emit_constant(ctx, e.value)
	case ^Unary_Expr:
		compile_expr(ctx, e.right)
		#partial switch e.op {
		case .Minus:
			emit_constant(ctx, -1.0)
			emit_opcode(ctx, .Multiply)
		}

	case ^Ident_Expr:
		sym := ctx.res.node_symbols[expr]

		slot_index := -1
		#reverse for loc, i in ctx.locals {
			if loc.symbol == sym {
				slot_index = i
				break
			}
		}

		if slot_index != -1 {
			// Это локальная переменная
			emit_opcode(ctx, .Get_Local)
			emit_byte(ctx, u8(slot_index))
		} else {
			// 2. Если не локальная, ищем в глобальном реестре функций!
			if fn_ptr, ok := ctx.registry^[sym.name]; ok {
				// Кладем саму функцию на стек как константу!
				emit_constant(ctx, Value(fn_ptr))
			} else {
				fmt.panicf("Compiler Error: символ '%s' не найден", sym.name)
			}
		}

	case ^Binary_Expr:
		compile_expr(ctx, e.left)
		compile_expr(ctx, e.right)

		#partial switch e.op {
		case .Plus:
			emit_opcode(ctx, .Add)
		}

	case ^Call_Expr:
		// 1. Кладем функцию на стек (выполнится код из Ident_Expr выше)
		compile_expr(ctx, e.callee)

		// 2. Кладем аргументы (если они есть)
		// for arg in e.args do compile_expr(ctx, arg)

		// 3. Вызываем!
		emit_opcode(ctx, .Call)
		emit_byte(ctx, 0) // Количество аргументов (пока 0)

	case ^If_Expr:
		// 1. Вычисляем условие (на стеке окажется bool)
		compile_expr(ctx, e.condition)

		// 2. Прыгаем в ветку 'иначе', если условие ЛОЖНО
		else_jump := emit_jump(ctx, .Jump_If_False)

		// 3. Компилируем ветку 'тогда'
		for stmt in e.then_branch {
			compile_statement(ctx, stmt)
		}

		// 4. После выполнения 'тогда' мы должны ПЕРЕПРЫГНУТЬ ветку 'иначе'!
		end_jump := emit_jump(ctx, .Jump)

		// 5. Теперь мы знаем адрес начала 'иначе'. Зашиваем его в первый прыжок!
		patch_jump(ctx, else_jump)

		// 6. Компилируем ветку 'иначе' (если она есть)
		if len(e.else_branch) > 0 {
			for stmt in e.else_branch {
				compile_statement(ctx, stmt)
			}
		}

		// 7. Зашиваем адрес конца всего 'if' во второй прыжок
		patch_jump(ctx, end_jump)

	case ^While_Expr:
		// 1. Запоминаем адрес начала цикла, чтобы возвращаться сюда
		loop_start := len(ctx.current_function.instructions)

		// 2. Условие
		compile_expr(ctx, e.condition)

		// 3. Если условие ложно, выпрыгиваем из цикла
		exit_jump := emit_jump(ctx, .Jump_If_False)

		// 4. Тело цикла
		for stmt in e.body {
			compile_statement(ctx, stmt)
		}

		// 5. Прыгаем обратно в начало (эмулируем Jump_Back)
		// У нас нет отдельного опкода для прыжка назад, но мы можем использовать патч:
		loop_jump := emit_jump(ctx, .Jump)

		// Хак для прыжка назад: считаем смещение вручную как отрицательное число
		// Либо, для простоты, сделайте опкод .Loop, который прыгает назад.
		// Пока оставим прямой патч (вычисляет вперед, но нам нужно назад):
		jump_length := loop_start - len(ctx.current_function.instructions)
		ctx.current_function.instructions[loop_jump] = u8((jump_length >> 8) & 0xff)
		ctx.current_function.instructions[loop_jump + 1] = u8(jump_length & 0xff)

		// 6. Зашиваем адрес выхода из цикла
		patch_jump(ctx, exit_jump)
	case ^Tuple_Expr:
		fmt.panicf("Компиляция туплов еще не реализована в VM!")
	}
}

print_assebler :: proc(registry: map[string]^Compiled_Function) {

	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	prefix := "\t"

	for name, f in registry {

		function_name := fmt.tprintf("FUNCTION %s\n", name)
		strings.write_string(&builder, function_name)

		instructions := f.instructions
		for idx := 0; idx < len(instructions); idx += 1 {
			current_opcode := Opcode(instructions[idx])
			switch current_opcode {
			case .Constant:
				idx += 1
				command := fmt.tprintf("%sCONSTANT: %d\n", prefix, instructions[idx])
				strings.write_string(&builder, command)

			case .Add:
				command := fmt.tprintf("%sADD\n", prefix)
				strings.write_string(&builder, command)

			case .Subtract:
				command := fmt.tprintf("%sSUBSTACT\n", prefix)
				strings.write_string(&builder, command)

			case .Multiply:
				command := fmt.tprintf("%sMULTIPLY\n", prefix)
				strings.write_string(&builder, command)

			case .Divide:
				command := fmt.tprintf("%sCONSTANT\n", prefix)
				strings.write_string(&builder, command)

			case .Get_Local:
				idx += 1
				command := fmt.tprintf("%sGET_LOCAL: %d\n", prefix, instructions[idx])
				strings.write_string(&builder, command)

			case .Set_Local:
				idx += 1
				command := fmt.tprintf("%sSET_LOCAL: %d\n", prefix, instructions[idx])
				strings.write_string(&builder, command)

			case .Jump_If_False:
				idx += 2
				command := fmt.tprintf("%sJUMP_IF_FALSE\n", prefix)
				strings.write_string(&builder, command)

			case .Jump:
				idx += 2
				command := fmt.tprintf("%sJUMP\n", prefix)
				strings.write_string(&builder, command)

			case .Pop:
				command := fmt.tprintf("%sPOP\n", prefix)
				strings.write_string(&builder, command)

			case .Return:
				command := fmt.tprintf("%sRETURN\n", prefix)
				strings.write_string(&builder, command)

			case .Call:
				idx += 1
				command := fmt.tprintf("%sCALL\n", prefix)
				strings.write_string(&builder, command)

			}
		}
	}
	res := strings.to_string(builder)

	fmt.println(res)

}
