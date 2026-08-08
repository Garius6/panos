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

	if len(args) > idx && args[idx] == "build" {
		run_build(args[idx + 1:])
		return
	}

	if len(args) <= idx {
		repl()
	} else {
		run_file(args[idx], args[idx + 1:], verbose)
	}
}

// run_build реализует `panos build --target=wasm <файл> [-o выход.wasm]` —
// использует файловый module graph, поэтому поддерживает обычные
// `импорт`ы. Inline check_source остаётся отдельным no-FS путём для LSP
// и браузерных сценариев.
run_build :: proc(args: []string) {
	target := ""
	input := ""
	output := ""

	i := 0
	for i < len(args) {
		arg := args[i]
		switch {
		case arg == "--target" && i + 1 < len(args):
			target = args[i + 1]
			i += 2
		case len(arg) > len("--target=") && arg[:len("--target=")] == "--target=":
			target = arg[len("--target="):]
			i += 1
		case arg == "-o" && i + 1 < len(args):
			output = args[i + 1]
			i += 2
		case:
			input = arg
			i += 1
		}
	}

	if target != "wasm" {
		fmt.eprintf("panos build: поддерживается только --target=wasm (получено: %q)\n", target)
		os.exit(1)
	}
	if input == "" {
		fmt.eprintf("panos build --target=wasm <файл.ps> [-o выход.wasm]\n")
		os.exit(1)
	}
	if output == "" {
		base := input
		if len(input) > 3 && input[len(input) - 3:] == ".ps" {
			base = input[:len(input) - 3]
		}
		output = fmt.tprintf("%s.wasm", base)
	}

	graph := core.load_module_graph(input)
	entry_path := core.resolve_import_path(input, "")
	if graph.modules[entry_path] == nil {
		fmt.eprintf("panos build: не удалось загрузить входной модуль %s\n", input)
		os.exit(1)
	}

	results := core.resolve_and_typecheck_all(&graph, true)
	all_diags := make([dynamic]core.Diagnostic)
	for d in graph.parse_diagnostics do append(&all_diags, d)
	for r in results {
		for d in r.res_ctx.diagnostics do append(&all_diags, d)
		for d in r.tc_ctx.diagnostics do append(&all_diags, d)
	}
	print_diagnostics_and_exit(&graph, all_diags)

	module := core.lower_program_graph(results)
	bytes := core.lower_module_to_wasm(&module)

	write_err := os.write_entire_file(output, bytes)
	if write_err != nil {
		fmt.eprintf("panos build: не удалось записать %s: %v\n", output, write_err)
		os.exit(1)
	}
	fmt.printf("panos build: записан %s\n", output)
}

// Печатает diagnostic'и (parser/resolver/typechecker — все три копят в
// []Diagnostic одинаковой формы) как path:line:col: message. Выходит
// ТОЛЬКО если среди них есть хотя бы одна .Error — Severity.Warning
// (напр. недостижимый код) печатается для информации, но не мешает
// запуску (см. diagnostics_have_error, core/type_cheker.odin).
print_diagnostics_and_exit :: proc(graph: ^core.Module_Graph, diags: [dynamic]core.Diagnostic) {
	if len(diags) == 0 do return
	for d in diags {
		source := graph.file_sources[d.span.file_id]
		path := graph.file_paths[d.span.file_id]
		line, col := core.span_line_col(source, d.span.start)
		prefix := d.severity == .Error ? "" : "warning: "
		fmt.eprintf("%s:%d:%d: %s%s\n", path, line, col, prefix, d.message)
	}
	if core.diagnostics_have_error(diags[:]) do os.exit(1)
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

	module := core.lower_program_graph(results)
	core.optimize_module(&module)
	global_registry := core.lower_module_to_bytecode(&module)
	if verbose {
		for i in 0 ..< len(results) {
			core.print_resolver_ctx(&results[i].res_ctx)
			fmt.println("TYPE CHECK")
			fmt.printf("--------------------------\n")
			core.print_type_ctx(&results[i].tc_ctx)
			fmt.printf("--------------------------\n\n")
		}
		fmt.println("MIR")
		fmt.printf("--------------------------\n")
		fmt.println(core.print_module(&module))
		fmt.printf("--------------------------\n\n")
	}

	if verbose {
		fmt.println("EXECUTION")
		fmt.printf("--------------------------\n")
	}
	vm := core.new_vm(global_registry, program_args)
	core.run_scheduler(vm)
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
