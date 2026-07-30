#+build !js
package core

import "core:os"
import "core:testing"

// wasm_todo_demo_build_test.odin — НЕ настоящий тест, инструмент сборки
// demo/todo-app/frontend/main.ps в реальный .wasm-файл — тот же паттерн,
// что core/wasm_dom_demo_build_test.odin (см. её докстринг про то, почему
// это единственный сегодня способ получить .wasm без отдельной CLI-
// команды).
when #config(PANOS_BUILD_TODO_DEMO, false) {

	@(test)
	test_build_todo_frontend_demo :: proc(t: ^testing.T) {
		source_bytes, read_err := os.read_entire_file_from_path("demo/todo-app/frontend/main.ps", context.allocator)
		testing.expectf(t, read_err == nil, "demo/todo-app/frontend/main.ps не прочитан: %v", read_err)
		if read_err != nil do return

		result := check_source(string(source_bytes))
		testing.expectf(t, len(result.diags) == 0, "demo/todo-app/frontend/main.ps diagnostics: %v", result.diags)
		if len(result.diags) > 0 do return

		module := lower_module(&result.res_ctx, &result.tc_ctx, &result.prog)
		bytes := lower_module_to_wasm(&module)

		write_err := os.write_entire_file("demo/todo-app/frontend/main.wasm", bytes)
		testing.expectf(t, write_err == nil, "demo/todo-app/frontend/main.wasm не записан: %v", write_err)
	}

}
