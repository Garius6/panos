package main

import "core:fmt"
import "core:mem"
import "core:os"

main :: proc() {
	default_allocator := context.allocator

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, alignment = 64)
	defer mem.dynamic_arena_destroy(&arena)

	context.allocator = mem.dynamic_arena_allocator(&arena)

	when ODIN_DEBUG {
		tracker: mem.Tracking_Allocator
		mem.tracking_allocator_init(&tracker, context.allocator, default_allocator)

		defer mem.tracking_allocator_destroy(&tracker)

		context.allocator = mem.tracking_allocator(&tracker)
	}

	args := os.args
	args_len := len(args)
	if args_len == 1 {
		repl()
	} else if args_len == 2 {
		run_file(args[1])
	}
}

run_file :: proc(filename: string) {
	if !os.exists(filename) {
		fmt.eprintf("Файл %s не существует\n", filename)
		return
	}

	f, file_open_error := os.open(filename, {.Read})
	if file_open_error != nil {
		fmt.eprintf(
			"Не удалось открыть файл по причине: %v\n",
			file_open_error,
		)
		return
	}

	data, file_reading_error := os.read_entire_file(f, context.allocator)
	if file_reading_error != nil {
		fmt.eprintf(
			"Не удалось прочесть файл по причине: %v\n",
			file_open_error,
		)
		return
	}

	tokens := tokenize(string(data))
	stream := make_stream(tokens)
	defer destroy_stream(&stream)

	fmt.println("TOKENS")
	fmt.printf("--------------------------\n")
	for tok := next_token(&stream); tok != nil; tok = next_token(&stream) {
		fmt.println(token_to_string(tok^))
	}
	stream.current_idx = 0
	fmt.printf("--------------------------\n\n")

	fmt.println("AST")
	fmt.printf("--------------------------\n")
	parser := Parser {
		stream = &stream,
	}
	program := parse_program(&parser)
	print_program(program)
	fmt.printf("--------------------------\n\n")

	resolver_ctx := new_resolver_ctx()
	resolve_program(&resolver_ctx, program)
	print_resolver_ctx(&resolver_ctx)

	fmt.println("TYPE CHECK")
	fmt.printf("--------------------------\n")
	type_ctx := new_type_ctx(&resolver_ctx)
	typecheck_program(&type_ctx, program)
	print_type_ctx(&type_ctx)
	fmt.printf("--------------------------\n\n")

	fmt.println("COMPILATION")
	fmt.printf("--------------------------\n")
	registry := compile_program(&resolver_ctx, &program)
	print_assebler(registry)
	fmt.printf("--------------------------\n\n")

	fmt.println("EXECUTION")
	fmt.printf("--------------------------\n")
	vm := new_vm(registry)
	execute(vm)
	print_vm(vm)
	fmt.printf("--------------------------\n\n")
}

repl :: proc() {

}
