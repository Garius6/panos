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
	graph := load_module_graph(filename)
	entry_path := resolve_import_path(filename, "")
	entry_module := graph.modules[entry_path]
	if entry_module == nil {
		fmt.eprintf(
			"Не удалось загрузить входной модуль %s\n",
			filename,
		)
		return
	}

	fmt.println("AST")
	fmt.printf("--------------------------\n")
	print_program(entry_module.ast)
	fmt.printf("--------------------------\n\n")

	global_registry := make(map[string]^Compiled_Function)

	for module in graph.order {
		resolver_ctx := resolve_module(&graph, module)
		print_resolver_ctx(&resolver_ctx)

		fmt.println("TYPE CHECK")
		fmt.printf("--------------------------\n")
		type_ctx := new_type_ctx(&resolver_ctx)
		typecheck_program(&type_ctx, module.ast)
		print_type_ctx(&type_ctx)
		fmt.printf("--------------------------\n\n")

		fmt.println("COMPILATION")
		fmt.printf("--------------------------\n")
		module_registry := compile_program(&resolver_ctx, &type_ctx, &module.ast, &global_registry)
		print_assebler(module_registry)
		fmt.printf("--------------------------\n\n")
	}

	fmt.println("EXECUTION")
	fmt.printf("--------------------------\n")
	vm := new_vm(global_registry)
	execute(vm)
	print_vm(vm)
	fmt.printf("--------------------------\n\n")
}

repl :: proc() {

}
