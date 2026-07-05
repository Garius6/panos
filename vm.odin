package main

import "core:fmt"
import "core:os"

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
	program_args:       []string,
}

new_vm :: proc(
	compiled_functions: map[string]^Compiled_Function,
	program_args: []string = nil,
) -> ^VM {
	vm := new(VM)
	vm.frames = make([dynamic]CallFrame)
	vm.program_args = program_args

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

return_from_current_frame :: proc(vm: ^VM, result: Value) {
	frame := &vm.frames[len(vm.frames) - 1]
	callee_index := frame.frame_pointer - 1
	resize_to := callee_index
	if resize_to < 0 do resize_to = 0
	resize(&vm.stack, resize_to)
	if frame.function.returns_value {
		append(&vm.stack, result)
	}
	pop(&vm.frames)
}

value_equals :: proc(a: Value, b: Value) -> bool {
	#partial switch va in a {
	case f64:
		if vb, ok := b.(f64); ok do return va == vb
	case bool:
		if vb, ok := b.(bool); ok do return va == vb
	case string:
		if vb, ok := b.(string); ok do return va == vb
	}
	return false
}

number_to_index :: proc(value: Value) -> int {
	number, ok := value.(f64)
	if !ok {
		fmt.panicf("Runtime Error: индекс массива должен быть числом")
	}

	idx := int(number)
	if number < 0 || f64(idx) != number {
		fmt.panicf(
			"Runtime Error: индекс массива должен быть неотрицательным целым числом",
		)
	}
	return idx
}

map_find_index :: proc(m: ^Map_Value, key: Value) -> int {
	for entry, i in m.entries {
		if value_equals(entry.key, key) do return i
	}
	return -1
}

map_remove_at :: proc(m: ^Map_Value, idx: int) {
	for i := idx; i < len(m.entries) - 1; i += 1 {
		m.entries[i] = m.entries[i + 1]
	}
	resize(&m.entries, len(m.entries) - 1)
}

expect_arg_count :: proc(method_name: string, actual: int, expected: int) {
	if actual != expected {
		fmt.panicf(
			"Runtime Error: метод '%s' ожидал %d аргументов, получено %d",
			method_name,
			expected,
			actual,
		)
	}
}

expect_string_arg :: proc(function_name: string, value: Value) -> string {
	text, ok := value.(string)
	if !ok {
		fmt.panicf(
			"Runtime Error: %s ожидает строковый аргумент",
			function_name,
		)
	}
	return text
}

make_error_value :: proc(code: string, message: string) -> Value {
	err := new(Error_Value)
	err.code = code
	err.message = message
	return Value(err)
}

make_ok_result :: proc(value: Value) -> Value {
	res := new(Result_Value)
	res.is_ok = true
	res.value = value
	res.error = f64(0)
	return Value(res)
}

make_error_result :: proc(err: Value) -> Value {
	res := new(Result_Value)
	res.is_ok = false
	res.value = f64(0)
	res.error = err
	return Value(res)
}

read_stdin_line :: proc() -> Value {
	line := make([dynamic]byte)
	buffer: [256]byte

	for {
		n, err := os.read(os.stdin, buffer[:])
		if n > 0 {
			for b in buffer[:n] {
				if b == '\n' {
					return make_ok_result(Value(string(line[:])))
				}
				if b != '\r' {
					append(&line, b)
				}
			}
		}

		if err != nil {
			if len(line) > 0 {
				return make_ok_result(Value(string(line[:])))
			}
			return make_error_result(
				make_error_value("ввод_вывод", fmt.tprintf("%v", err)),
			)
		}

		if n == 0 {
			return make_ok_result(Value(string(line[:])))
		}
	}
}

string_length :: proc(text: string) -> int {
	count := 0
	for _ in text {
		count += 1
	}
	return count
}

invoke_collection_method :: proc(
	receiver: Value,
	method_name: string,
	args: []Value,
) -> (
	Value,
	bool,
) {
	if opt, ok_opt := receiver.(^Option_Value); ok_opt {
		switch method_name {
		case "есть":
			expect_arg_count(method_name, len(args), 0)
			return Value(opt.has_value), true
		case "пусто":
			expect_arg_count(method_name, len(args), 0)
			return Value(!opt.has_value), true
		case "значение":
			expect_arg_count(method_name, len(args), 0)
			if !opt.has_value {
				fmt.panicf(
					"Runtime Error: попытка получить значение из пустой Опции",
				)
			}
			return opt.value, true
		case "получить":
			expect_arg_count(method_name, len(args), 1)
			if opt.has_value do return opt.value, true
			return args[0], true
		}
	}

	if res, ok_res := receiver.(^Result_Value); ok_res {
		switch method_name {
		case "успех":
			expect_arg_count(method_name, len(args), 0)
			return Value(res.is_ok), true
		case "ошибка":
			expect_arg_count(method_name, len(args), 0)
			return Value(!res.is_ok), true
		case "значение":
			expect_arg_count(method_name, len(args), 0)
			if !res.is_ok {
				fmt.panicf(
					"Runtime Error: попытка получить значение из ошибочного Результата",
				)
			}
			return res.value, true
		case "причина":
			expect_arg_count(method_name, len(args), 0)
			if res.is_ok {
				fmt.panicf(
					"Runtime Error: попытка получить причину из успешного Результата",
				)
			}
			return res.error, true
		case "получить":
			expect_arg_count(method_name, len(args), 1)
			if res.is_ok do return res.value, true
			return args[0], true
		}
	}

	if arr, ok_arr := receiver.(^Array_Value); ok_arr {
		switch method_name {
		case "длина":
			expect_arg_count(method_name, len(args), 0)
			return Value(f64(len(arr.elements))), true
		case "добавить":
			expect_arg_count(method_name, len(args), 1)
			append(&arr.elements, args[0])
			return Value(f64(0)), false
		case "получить":
			expect_arg_count(method_name, len(args), 2)
			idx := number_to_index(args[0])
			if idx >= len(arr.elements) do return args[1], true
			return arr.elements[idx], true
		case "есть":
			expect_arg_count(method_name, len(args), 1)
			idx := number_to_index(args[0])
			return Value(idx < len(arr.elements)), true
		case "содержит":
			expect_arg_count(method_name, len(args), 1)
			for el in arr.elements {
				if value_equals(el, args[0]) do return Value(true), true
			}
			return Value(false), true
		}
	}

	if m, ok_map := receiver.(^Map_Value); ok_map {
		switch method_name {
		case "длина":
			expect_arg_count(method_name, len(args), 0)
			return Value(f64(len(m.entries))), true
		case "есть":
			expect_arg_count(method_name, len(args), 1)
			return Value(map_find_index(m, args[0]) != -1), true
		case "получить":
			expect_arg_count(method_name, len(args), 2)
			idx := map_find_index(m, args[0])
			if idx == -1 do return args[1], true
			return m.entries[idx].value, true
		case "удалить":
			expect_arg_count(method_name, len(args), 1)
			idx := map_find_index(m, args[0])
			if idx == -1 do return Value(false), true
			map_remove_at(m, idx)
			return Value(true), true
		}
	}

	fmt.panicf(
		"Runtime Error: метод '%s' не найден у коллекции",
		method_name,
	)
}

call_builtin :: proc(vm: ^VM, name: string, args: []Value) -> (Value, bool) {
	switch name {
	case "Ошибка":
		expect_arg_count(name, len(args), 2)
		code, ok_code := args[0].(string)
		message, ok_message := args[1].(string)
		if !ok_code || !ok_message {
			fmt.panicf("Runtime Error: Ошибка() ожидает две строки")
		}
		err := new(Error_Value)
		err.code = code
		err.message = message
		return Value(err), true

	case "Есть":
		expect_arg_count(name, len(args), 1)
		opt := new(Option_Value)
		opt.has_value = true
		opt.value = args[0]
		return Value(opt), true

	case "Нет":
		expect_arg_count(name, len(args), 0)
		opt := new(Option_Value)
		opt.has_value = false
		opt.value = f64(0)
		return Value(opt), true

	case "Успех":
		expect_arg_count(name, len(args), 1)
		res := new(Result_Value)
		res.is_ok = true
		res.value = args[0]
		res.error = f64(0)
		return Value(res), true

	case "Неудача":
		expect_arg_count(name, len(args), 1)
		return make_error_result(args[0]), true

	case "длина":
		expect_arg_count(name, len(args), 1)
		if text, ok := args[0].(string); ok {
			return Value(f64(string_length(text))), true
		}
		if arr, ok := args[0].(^Array_Value); ok {
			return Value(f64(len(arr.elements))), true
		}
		if m, ok := args[0].(^Map_Value); ok {
			return Value(f64(len(m.entries))), true
		}
		fmt.panicf(
			"Runtime Error: длина() ожидает строку, массив или соответствие",
		)

	case "паника":
		expect_arg_count(name, len(args), 1)
		message := expect_string_arg(name, args[0])
		fmt.panicf("Runtime Panic: %s", message)

	case "фс::есть":
		expect_arg_count(name, len(args), 1)
		path := expect_string_arg(name, args[0])
		return Value(os.exists(path)), true

	case "фс::прочитать":
		expect_arg_count(name, len(args), 1)
		path := expect_string_arg(name, args[0])
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			return make_error_result(make_error_value("фс", fmt.tprintf("%v", err))), true
		}
		return make_ok_result(Value(string(data))), true

	case "фс::записать":
		expect_arg_count(name, len(args), 2)
		path := expect_string_arg(name, args[0])
		content := expect_string_arg(name, args[1])
		err := os.write_entire_file(path, content)
		if err != nil {
			return make_error_result(make_error_value("фс", fmt.tprintf("%v", err))), true
		}
		return make_ok_result(Value(f64(len(content)))), true

	case "ос::аргументы":
		expect_arg_count(name, len(args), 0)
		arr := new(Array_Value)
		arr.elements = make([dynamic]Value)
		for arg in vm.program_args {
			append(&arr.elements, Value(arg))
		}
		return Value(arr), true

	case "ос::окружение":
		expect_arg_count(name, len(args), 1)
		key := expect_string_arg(name, args[0])
		value, found := os.lookup_env(key, context.allocator)
		opt := new(Option_Value)
		opt.has_value = found
		if found {
			opt.value = Value(value)
		} else {
			opt.value = Value("")
		}
		return Value(opt), true

	case "ос::установить_окружение":
		expect_arg_count(name, len(args), 2)
		key := expect_string_arg(name, args[0])
		value := expect_string_arg(name, args[1])
		err := os.set_env(key, value)
		if err != nil {
			return make_error_result(make_error_value("ос", fmt.tprintf("%v", err))), true
		}
		return make_ok_result(Value(f64(0))), true

	case "ос::удалить_окружение":
		expect_arg_count(name, len(args), 1)
		key := expect_string_arg(name, args[0])
		return Value(os.unset_env(key)), true

	case "ввод_вывод::печать":
		expect_arg_count(name, len(args), 1)
		text := expect_string_arg(name, args[0])
		fmt.print(text)
		return Value(f64(0)), false

	case "ввод_вывод::строка":
		expect_arg_count(name, len(args), 1)
		text := expect_string_arg(name, args[0])
		fmt.println(text)
		return Value(f64(0)), false

	case "ввод_вывод::прочитать_строку":
		expect_arg_count(name, len(args), 0)
		return read_stdin_line(), true
	}

	fmt.panicf(
		"Runtime Error: неизвестный встроенный конструктор '%s'",
		name,
	)
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

			if a, ok_a := val_a.(f64); ok_a {
				if b, ok_b := val_b.(f64); ok_b {
					append(&vm.stack, Value(a + b))
					break
				}
			}

			if a, ok_a := val_a.(string); ok_a {
				if b, ok_b := val_b.(string); ok_b {
					append(&vm.stack, Value(fmt.tprintf("%s%s", a, b)))
					break
				}
			}

			fmt.panicf(
				"Runtime Error: оператор '+' ожидает два числа или две строки (было %v и %v)",
				val_a,
				val_b,
			)
		case .Subtract:
			r := pop(&vm.stack).(f64); l := pop(&vm.stack).(f64) // <-- ДОБАВЛЕНО
			append(&vm.stack, l - r) // <-- ДОБАВЛЕНО

		case .Multiply:
			r := pop(&vm.stack).(f64); l := pop(&vm.stack).(f64) // <-- ДОБАВЛЕНО
			append(&vm.stack, l * r) // <-- ДОБАВЛЕНО
		case .Divide:
			r := pop(&vm.stack).(f64); l := pop(&vm.stack).(f64) // <-- ДОБАВЛЕНО
			append(&vm.stack, l / r) // <-- ДОБАВЛЕНО

		case .Less:
			r := pop(&vm.stack).(f64); l := pop(&vm.stack).(f64) // <-- ДОБАВЛЕНО
			append(&vm.stack, l < r)

		case .Greater:
			r := pop(&vm.stack).(f64); l := pop(&vm.stack).(f64)
			append(&vm.stack, l > r)

		case .Equal:
			r := pop(&vm.stack); l := pop(&vm.stack)
			append(&vm.stack, l == r)

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

		case .Call_Builtin:
			frame.ip += 1
			name_index := instructions[frame.ip]
			frame.ip += 1
			arg_count := int(instructions[frame.ip])

			name := frame.function.constants[name_index].(string)
			args_start := len(vm.stack) - arg_count
			args := vm.stack[args_start:]
			result, has_result := call_builtin(vm, name, args)
			resize(&vm.stack, args_start)
			if has_result {
				append(&vm.stack, result)
			}

		case .Return:
			result: Value = f64(0) // Значение по умолчанию (если функция ничего не вернула)

			// Вычисляем, где заканчиваются локальные переменные
			base_frame_size := frame.frame_pointer + frame.function.frame_size

			// Если на стеке есть что-то ВЫШЕ локальных переменных — это наш результат!
			if len(vm.stack) > base_frame_size {
				result = pop(&vm.stack)
			}

			return_from_current_frame(vm, result)
			continue

		case .Try_Unwrap:
			value := pop(&vm.stack)
			res, ok := value.(^Result_Value)
			if !ok {
				fmt.panicf("Runtime Error: оператор '?' ожидал Результат")
			}
			if res.is_ok {
				append(&vm.stack, res.value)
			} else {
				return_from_current_frame(vm, value)
				continue
			}

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
		case .Build_Aggregate:
			frame.ip += 1
			count := int(instructions[frame.ip])

			agg := new(Aggregate_Value)
			agg.elements = make([dynamic]Value, count)

			// ВАЖНО: Снимаем значения со стека в ОБРАТНОМ порядке!
			// Если было Игрок(10, 20), то 20 лежит на самом верху стека (индекс 1).
			for i := count - 1; i >= 0; i -= 1 {
				agg.elements[i] = pop(&vm.stack)
			}

			// Кладем готовую структуру на стек
			append(&vm.stack, Value(agg))

		case .Build_Array:
			frame.ip += 1
			count := int(instructions[frame.ip])

			arr := new(Array_Value)
			arr.elements = make([dynamic]Value, count)

			for i := count - 1; i >= 0; i -= 1 {
				arr.elements[i] = pop(&vm.stack)
			}

			append(&vm.stack, Value(arr))

		case .Build_Map:
			frame.ip += 1
			count := int(instructions[frame.ip])

			m := new(Map_Value)
			m.entries = make([dynamic]Map_Entry_Value, count)

			for i := count - 1; i >= 0; i -= 1 {
				value := pop(&vm.stack)
				key := pop(&vm.stack)
				m.entries[i] = Map_Entry_Value {
					key   = key,
					value = value,
				}
			}

			append(&vm.stack, Value(m))

		case .Get_Property:
			frame.ip += 1
			idx := int(instructions[frame.ip])

			val := pop(&vm.stack)
			if agg, ok_agg := val.(^Aggregate_Value); ok_agg {
				append(&vm.stack, agg.elements[idx])
			} else if err, ok_err := val.(^Error_Value); ok_err {
				switch idx {
				case 0:
					append(&vm.stack, Value(err.code))
				case 1:
					append(&vm.stack, Value(err.message))
				case:
					fmt.panicf(
						"Runtime Error: у Ошибка нет поля с индексом %d",
						idx,
					)
				}
			} else {
				fmt.panicf(
					"Runtime Error: попытка прочитать поле у примитивного типа",
				)
			}

		case .Set_Property:
			frame.ip += 1
			idx := int(instructions[frame.ip])

			value := pop(&vm.stack)
			target := pop(&vm.stack)

			if agg, ok_agg := target.(^Aggregate_Value); ok_agg {
				agg.elements[idx] = value
			} else if iface, ok_iface := target.(^Interface_Value); ok_iface {
				iface.data.elements[idx] = value
			} else if err, ok_err := target.(^Error_Value); ok_err {
				text, ok_text := value.(string)
				if !ok_text {
					fmt.panicf(
						"Runtime Error: поля Ошибка принимают только строки",
					)
				}
				switch idx {
				case 0:
					err.code = text
				case 1:
					err.message = text
				case:
					fmt.panicf(
						"Runtime Error: у Ошибка нет поля с индексом %d",
						idx,
					)
				}
			} else {
				fmt.panicf(
					"Runtime Error: попытка записать поле у примитивного типа",
				)
			}

		case .Get_Index:
			index := pop(&vm.stack)
			receiver := pop(&vm.stack)

			if arr, ok_arr := receiver.(^Array_Value); ok_arr {
				idx := number_to_index(index)
				if idx >= len(arr.elements) {
					fmt.panicf(
						"Runtime Error: индекс %d выходит за границы массива",
						idx,
					)
				}
				append(&vm.stack, arr.elements[idx])
			} else if m, ok_map := receiver.(^Map_Value); ok_map {
				idx := map_find_index(m, index)
				if idx == -1 {
					fmt.panicf(
						"Runtime Error: ключ не найден в соответствии",
					)
				}
				append(&vm.stack, m.entries[idx].value)
			} else if m, ok_string := receiver.(string); ok_string {
				idx := number_to_index(index)

				if char_str, ok := get_character_at(m, idx); ok {
					new_string := Value(char_str)
					append(&vm.stack, new_string)
				} else {
					fmt.panicf(
						"Runtime Error: индекс %d выходит за границы массива",
						idx,
					)
				}
			} else {
				fmt.panicf(
					"Runtime Error: индексирование поддерживают только массивы и соответствия",
				)
			}

		case .Set_Index:
			value := pop(&vm.stack)
			index := pop(&vm.stack)
			receiver := pop(&vm.stack)

			if arr, ok_arr := receiver.(^Array_Value); ok_arr {
				idx := number_to_index(index)
				if idx >= len(arr.elements) {
					fmt.panicf(
						"Runtime Error: индекс %d выходит за границы массива",
						idx,
					)
				}
				arr.elements[idx] = value
			} else if m, ok_map := receiver.(^Map_Value); ok_map {
				idx := map_find_index(m, index)
				if idx == -1 {
					append(&m.entries, Map_Entry_Value{key = index, value = value})
				} else {
					m.entries[idx].value = value
				}
			} else {
				fmt.panicf(
					"Runtime Error: индексная запись поддерживает только массивы и соответствия",
				)
			}

		case .Cast_Interface:
			frame.ip += 1
			struct_name_index := instructions[frame.ip]
			struct_name := frame.function.constants[struct_name_index].(string)

			val := pop(&vm.stack)
			agg, ok := val.(^Aggregate_Value)
			if !ok {
				fmt.panicf(
					"Runtime Error: в интерфейс можно привести только структуру",
				)
			}

			iface := new(Interface_Value)
			iface.data = agg
			iface.methods = make(map[string]^Compiled_Function)

			prefix := fmt.tprintf("%s::", struct_name)
			for name, fn in vm.compiled_functions {
				if len(name) > len(prefix) && name[:len(prefix)] == prefix {
					iface.methods[name[len(prefix):]] = fn
				}
			}

			append(&vm.stack, Value(iface))

		case .Invoke_Interface:
			frame.ip += 1
			method_name_index := instructions[frame.ip]
			frame.ip += 1
			arg_count := int(instructions[frame.ip])

			method_name := frame.function.constants[method_name_index].(string)
			callee_index := len(vm.stack) - 1 - arg_count
			iface_val := vm.stack[callee_index]

			iface, ok := iface_val.(^Interface_Value)
			if !ok {
				fmt.panicf(
					"Runtime Error: попытка вызвать интерфейсный метод у не-интерфейса",
				)
			}

			func_ptr, found := iface.methods[method_name]
			if !found {
				fmt.panicf(
					"Runtime Error: метод '%s' не найден в vtable интерфейса",
					method_name,
				)
			}

			vm.stack[callee_index] = Value(func_ptr)
			append(&vm.stack, Value(f64(0)))
			for i := len(vm.stack) - 1; i > callee_index + 1; i -= 1 {
				vm.stack[i] = vm.stack[i - 1]
			}
			vm.stack[callee_index + 1] = Value(iface.data)

			total_arg_count := arg_count + 1
			new_frame := CallFrame {
				function      = func_ptr,
				ip            = 0,
				frame_pointer = callee_index + 1,
			}

			locals_to_allocate := func_ptr.frame_size - total_arg_count
			for _ in 0 ..< locals_to_allocate {
				append(&vm.stack, Value(f64(0)))
			}

			vm.frames[len(vm.frames) - 1].ip = frame.ip + 1
			append(&vm.frames, new_frame)
			continue

		case .Invoke_Collection:
			frame.ip += 1
			method_name_index := instructions[frame.ip]
			frame.ip += 1
			arg_count := int(instructions[frame.ip])

			method_name := frame.function.constants[method_name_index].(string)
			receiver_index := len(vm.stack) - 1 - arg_count
			receiver := vm.stack[receiver_index]
			args := vm.stack[receiver_index + 1:]

			result, has_result := invoke_collection_method(receiver, method_name, args)
			resize(&vm.stack, receiver_index)
			if has_result {
				append(&vm.stack, result)
			}
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
