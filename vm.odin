package main

import "core:fmt"

Main_Function_Name :: "старт"

CallFrame :: struct {
	function:      ^Compiled_Function,
	ip:            int, // Указатель текущей инструкции в ЭТОЙ функции
	frame_pointer: int, // Индекс в vm.stack, где начинаются локальные переменные ЭТОЙ функции
}

VM :: struct {
	frames:             [dynamic]CallFrame,
	compiled_functions: map[string]^Compiled_Function,
	stack:              [dynamic]Value,
}

new_vm :: proc(compiled_functions: map[string]^Compiled_Function) -> ^VM {
	vm := new(VM)
	vm.frames = make([dynamic]CallFrame)

	// Берем переданный словарь напрямую
	vm.compiled_functions = compiled_functions

	main_func, ok := vm.compiled_functions[Main_Function_Name]
	if !ok {
		fmt.panicf("Не определена функция 'старт'")
	}

	main_frame := CallFrame {
		function      = main_func,
		ip            = 0,
		frame_pointer = 0,
	}
	append(&vm.frames, main_frame)

	for _ in 0 ..< main_func.frame_size {
		append(&vm.stack, 0.0) // Забиваем нулями/nil
	}
	return vm
}

execute :: proc(vm: ^VM) {

	for len(vm.frames) > 0 {

		// Берем ТЕКУЩИЙ фрейм по указателю, чтобы мы могли менять его ip
		frame := &vm.frames[len(vm.frames) - 1]
		instructions := frame.function.instructions

		if frame.ip >= len(instructions) {
			// Если мы дошли до конца инструкций без явного RETURN,
			// просто удаляем фрейм (возвращаемся)
			pop(&vm.frames)
			continue
		}

		opcode := Opcode(instructions[frame.ip])

		#partial switch opcode {
		case .Constant:
			frame.ip += 1
			const_index := instructions[frame.ip]
			append(&vm.stack, frame.function.constants[const_index])

		case .Set_Local:
			frame.ip += 1
			slot_index := int(instructions[frame.ip])

			// 1. Берем верхнее значение (результат вычислений)
			value := pop(&vm.stack)
			// 2. Кладем его глубоко в стек, туда, где зарезервировано место переменной
			vm.stack[frame.frame_pointer + slot_index] = value

		case .Get_Local:
			frame.ip += 1
			slot_index := int(instructions[frame.ip])

			// 1. Читаем значение из глубин стека (относительно начала фрейма)
			value := vm.stack[frame.frame_pointer + slot_index]
			// 2. Копируем его на самую вершину стека для вычислений
			append(&vm.stack, value)

		case .Pop:
			pop(&vm.stack)

		case .Add:
			val_b := pop(&vm.stack)
			val_a := pop(&vm.stack)

			// 2. Распаковываем (извлекаем f64)
			// В Odin это делается через паттерн-матчинг (switch)
			a, ok_a := val_a.(f64)
			b, ok_b := val_b.(f64)

			// 3. Проверка типов перед операцией
			if !ok_a || !ok_b {
				fmt.panicf(
					"Runtime Error: нельзя сложить не-числа (было %v и %v)",
					val_a,
					val_b,
				)
			}

			// 4. Складываем и снова упаковываем в union
			append(&vm.stack, Value(a + b))
		case .Subtract, .Multiply, .Divide:
		case .Call:
			frame.ip += 1
			arg_count := int(instructions[frame.ip])

			// 1. Ищем функцию на стеке. Она лежит под всеми аргументами!
			callee_index := len(vm.stack) - 1 - arg_count
			callee_val := vm.stack[callee_index]

			func_ptr, ok := callee_val.(^Compiled_Function)
			if !ok {
				fmt.panicf(
					"Runtime Error: попытка вызвать не функцию (получено: %v)",
					callee_val,
				)
			}

			// 2. Создаем новый фрейм
			new_frame := CallFrame {
				function      = func_ptr,
				ip            = 0,
				frame_pointer = callee_index + 1, // Переменные начинаются прямо с аргументов
			}

			// 3. Выделяем место под локальные переменные (нули)
			locals_to_allocate := func_ptr.frame_size - arg_count
			for _ in 0 ..< locals_to_allocate {
				append(&vm.stack, Value(f64(0)))
			}

			// 4. Запоминаем точку возврата для текущ��й функции
			vm.frames[len(vm.frames) - 1].ip = frame.ip + 1

			// 5. Переключаем контекст!
			append(&vm.frames, new_frame)
			continue // ВАЖНО: Начинаем новый цикл, пропуская frame.ip += 1 в конце

		case .Return:
			result: Value = f64(0) // Значение по умолчанию (если функция ничего не вернула)

			// Вычисляем, где заканчиваются локальные переменные
			base_frame_size := frame.frame_pointer + frame.function.frame_size

			// Если на стеке есть что-то ВЫШЕ локальных переменных — это наш результат!
			if len(vm.stack) > base_frame_size {
				result = pop(&vm.stack)
			}

			// Очищаем весь кадр (локальные переменные, аргументы и саму вызванную функцию)
			// Функция-callee лежит прямо перед frame_pointer
			callee_index := frame.frame_pointer - 1

			// В Odin функция resize мгновенно отсекает хвост массива (очищает стек)
			resize(&vm.stack, callee_index)

			// Кладем результат обратно на стек для той функции, которая нас вызывала
			append(&vm.stack, result)

			// Удаляем текущий фрейм
			pop(&vm.frames)

			// Если мы вышли из функции 'старт', программа сама завершится
			continue

		case .Jump_If_False:
			// Читаем 2 байта смещения
			frame.ip += 1
			high := u16(instructions[frame.ip])
			frame.ip += 1
			low := u16(instructions[frame.ip])

			offset := (high << 8) | low

			// Снимаем условие со стека
			condition_val := pop(&vm.stack)

			// Мы не делаем ok-проверку, потому что Type Checker
			// УЖЕ гарантировал, что на стеке лежит строго bool!
			condition := condition_val.(bool)

			if !condition {
				frame.ip += int(offset) // Прыгаем вперед!
			}

		case .Jump:
			frame.ip += 1
			high := u16(instructions[frame.ip])
			frame.ip += 1
			low := u16(instructions[frame.ip])

			offset := (high << 8) | low

			// Безусловный прыжок (например, в конец if после выполнения then)
			// Если offset отрицательный (в случае While), int() сохранит знак.
			frame.ip += int(i16(offset))
		}

		// Двигаем IP текущего фрейма вперед
		frame.ip += 1
	}

}

print_vm :: proc(vm: ^VM) {
	for s in vm.stack {
		fmt.println(s)
	}
}
