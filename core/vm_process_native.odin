#+build !js
package core

import "core:fmt"
import "core:os"

// ос::выполнить — вынесено из общего call_builtin (vm.odin) в #+build-split,
// тот же принцип, что vm_io_native.odin/vm_http_native.odin: os.process_exec
// тянет platform-specific process_*.odin (пайпы/fork-exec), недоступные под
// js_wasm32 (см. vm_process_wasm.odin).
//
// Блокирующий синхронный вызов — не в is_async_builtin_name (compiler.odin),
// приемлемо для короткоживущего CLI-инструмента (pan), а не для VM,
// работающей как долгоживущий actor-рантайм (см. research.md фичи
// 003-pan-package-manager, п.8).
call_builtin_process :: proc(vm: ^VM, name: string, args: []Value) -> (result: Value, ok: bool, handled: bool) {
	switch name {
	case "ос::выполнить":
		expect_arg_count(name, len(args), 3)
		program := expect_string_arg(name, args[0])
		args_arr, is_arr := args[1].(^Array_Value)
		if !is_arr {
			fmt.panicf("Runtime Error: ос.выполнить() ожидает массив строк вторым аргументом")
		}
		working_dir := expect_string_arg(name, args[2])

		command := make([dynamic]string, 0, len(args_arr.elements) + 1)
		append(&command, program)
		for elem in args_arr.elements {
			append(&command, expect_string_arg(name, elem))
		}

		desc := os.Process_Desc {
			working_dir = working_dir,
			command     = command[:],
		}
		state, stdout_bytes, stderr_bytes, err := os.process_exec(desc, context.allocator)
		if err != nil {
			return make_error_result(vm, make_error_value(vm, "ос", fmt.tprintf("%v", err))), true, true
		}

		result_tuple := gc_new(vm, Aggregate_Value)
		gc_protect(vm, Value(result_tuple))
		resize(&result_tuple.elements, 3)
		result_tuple.elements[0] = Value(f64(state.exit_code))
		result_tuple.elements[1] = Value(gc_new_string(vm, string(stdout_bytes)))
		result_tuple.elements[2] = Value(gc_new_string(vm, string(stderr_bytes)))
		gc_unprotect(vm, 1)

		return make_ok_result(vm, Value(result_tuple)), true, true

	case "ос::завершить":
		expect_arg_count(name, len(args), 1)
		code, ok_code := args[0].(f64)
		if !ok_code {
			fmt.panicf("Runtime Error: ос.завершить() ожидает число")
		}
		// os.exit -> ! (никогда не возвращается) — терминирует процесс
		// сразу, ровно с этим кодом завершения.
		os.exit(int(code))
	}
	return
}
