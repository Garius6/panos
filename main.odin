package main

import "back"
import core "core"
import "core:fmt"
import "core:mem"
import "core:os"

main :: proc() {
	default_allocator := context.allocator

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, alignment = 64)
	defer mem.dynamic_arena_destroy(&arena)
	back.register_segfault_handler()

	// Перенаправляем стандартный обработчик паник в библиотеку
	context.assertion_failure_proc = back.assertion_failure_proc
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
	} else if args_len >= 2 {
		run_file(args[1], args[2:])
	}
}

// Печатает diagnostic'и (parser/resolver/typechecker — все три копят в
// []Diagnostic одинаковой формы) как path:line:col: message и выходит,
// если список непуст. Общая точка для всех трёх стадий гейта в run_file.
print_diagnostics_and_exit :: proc(graph: ^core.Module_Graph, diags: [dynamic]core.Diagnostic) {
	if len(diags) == 0 do return
	for d in diags {
		source := graph.file_sources[d.span.file_id]
		path := graph.file_paths[d.span.file_id]
		line, col := core.span_line_col(source, d.span.start)
		fmt.eprintf("%s:%d:%d: %s\n", path, line, col, d.message)
	}
	os.exit(1)
}

run_file :: proc(filename: string, program_args: []string = nil) {
	graph := core.load_module_graph(filename)
	print_diagnostics_and_exit(&graph, graph.parse_diagnostics)

	entry_path := core.resolve_import_path(filename, "")
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
	core.print_program(entry_module.ast)
	fmt.printf("--------------------------\n\n")

	global_registry := make(map[string]^core.Compiled_Function)

	for module in graph.order {
		resolver_ctx := core.resolve_module(&graph, module)
		print_diagnostics_and_exit(&graph, resolver_ctx.diagnostics)
		core.print_resolver_ctx(&resolver_ctx)

		fmt.println("TYPE CHECK")
		fmt.printf("--------------------------\n")
		type_ctx := core.new_type_ctx(&resolver_ctx)
		core.typecheck_program(&type_ctx, module.ast)
		print_diagnostics_and_exit(&graph, type_ctx.diagnostics)
		core.print_type_ctx(&type_ctx)
		fmt.printf("--------------------------\n\n")

		fmt.println("COMPILATION")
		fmt.printf("--------------------------\n")
		module_registry := core.compile_program(&resolver_ctx, &type_ctx, &module.ast, &global_registry)
		core.print_assebler(module_registry)
		fmt.printf("--------------------------\n\n")

		graph.symbol_types = resolver_ctx.symbol_types
	}

	fmt.println("EXECUTION")
	fmt.printf("--------------------------\n")
	vm := core.new_vm(global_registry, program_args)
	core.execute(vm)
	core.print_vm(vm)
	fmt.printf("--------------------------\n\n")
}

repl :: proc() {

}
