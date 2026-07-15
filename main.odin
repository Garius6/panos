package main

import "external/back"
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

	// Перенаправляем обработчик паник в back-библиотеку (backtrace на assert)
	context.assertion_failure_proc = back.assertion_failure_proc
	context.allocator = mem.dynamic_arena_allocator(&arena)
	when ODIN_DEBUG {
		tracker: mem.Tracking_Allocator
		mem.tracking_allocator_init(&tracker, context.allocator, default_allocator)

		defer mem.tracking_allocator_destroy(&tracker)

		context.allocator = mem.tracking_allocator(&tracker)
	}

	args := os.args
	idx := 1
	verbose := false
	// -v/--verbose должен стоять ПЕРЕД именем файла: panos -v file.ps arg1
	// arg2 — всё, что после файла, идёт в сам скрипт как program_args
	// (ос.аргументы()), флаг интерпретатора туда попасть не должен.
	if len(args) > idx && (args[idx] == "-v" || args[idx] == "--verbose") {
		verbose = true
		idx += 1
	}

	if len(args) <= idx {
		repl()
	} else {
		run_file(args[idx], args[idx + 1:], verbose)
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

run_file :: proc(filename: string, program_args: []string = nil, verbose: bool = false) {
	graph := core.load_module_graph(filename)

	entry_path := core.resolve_import_path(filename, "")
	entry_module := graph.modules[entry_path]
	if entry_module == nil {
		fmt.eprintf(
			"Не удалось загрузить входной модуль %s\n",
			filename,
		)
		return
	}

	if verbose {
		fmt.println("AST")
		fmt.printf("--------------------------\n")
		core.print_program(entry_module.ast)
		fmt.printf("--------------------------\n\n")
	}

	results := core.resolve_and_typecheck_all(&graph)

	// Гейт до компиляции: копим diagnostics со всех модулей и фаз разом (не
	// только первую упавшую) — тот же accumulate-not-panic принцип, что и
	// внутри каждой фазы, только теперь ещё и поперёк графа импортов.
	all_diags := make([dynamic]core.Diagnostic)
	for d in graph.parse_diagnostics do append(&all_diags, d)
	for r in results {
		for d in r.res_ctx.diagnostics do append(&all_diags, d)
		for d in r.tc_ctx.diagnostics do append(&all_diags, d)
	}
	print_diagnostics_and_exit(&graph, all_diags)

	global_registry := make(map[string]^core.Compiled_Function)
	if len(results) > 0 {
		core.ensure_prelude_compiled(&results[0].res_ctx, &global_registry)
	}

	for i in 0 ..< len(results) {
		r := &results[i]
		module_registry := core.compile_program(&r.res_ctx, &r.tc_ctx, &r.module.ast, &global_registry)
		if verbose {
			core.print_resolver_ctx(&r.res_ctx)

			fmt.println("TYPE CHECK")
			fmt.printf("--------------------------\n")
			core.print_type_ctx(&r.tc_ctx)
			fmt.printf("--------------------------\n\n")

			fmt.println("COMPILATION")
			fmt.printf("--------------------------\n")
			core.print_assebler(module_registry)
			fmt.printf("--------------------------\n\n")
		}
	}

	if verbose {
		fmt.println("EXECUTION")
		fmt.printf("--------------------------\n")
	}
	vm := core.new_vm(global_registry, program_args)
	core.execute(vm)
	// Не гейтим за verbose — это фактический результат прогона (значение,
	// оставшееся на стеке после старт()), а не внутренняя отладочная
	// информация компилятора.
	core.print_vm(vm)
	if verbose {
		fmt.printf("--------------------------\n\n")
	}
}

repl :: proc() {

}
