package main

import "core:fmt"

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

new_vm :: proc(main_func: ^Compiled_Function) -> ^VM {

	vm := new(VM)
	vm.frames = make([dynamic]CallFrame)
	vm.compiled_functions = make(map[string]^Compiled_Function)

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
