#+build !js
package core

import "core:os"
import "core:testing"

// wasm_dom_demo_build_test.odin — НЕ настоящий тест, инструмент сборки
// демо-фикстуры для Playwright (docs/src/assets/aot-dom-loader.js's
// сквозной прогон, tests/dom/) — за ОТДЕЛЬНЫМ #config (не PANOS_WASM_
// BACKEND_TESTS, той пометке нужен wasmtime/wasm-ld, здесь — только
// сама AOT-кодогенерация, которую core/wasm_backend_test.odin УЖЕ
// проверяет структурно на КАЖДОМ `just test`) — компилирует demo/dom/
// counter.ps в реальный .wasm-файл, единственный способ получить его
// (сейчас нет отдельной CLI-команды "скомпилировать .ps в AOT WASM",
// только internal Odin-функции check_source/lower_module/lower_module_
// to_wasm, которыми уже пользуются остальные wasm-тесты этого файла).
when #config(PANOS_BUILD_DOM_DEMO, false) {

	@(test)
	test_build_dom_counter_demo :: proc(t: ^testing.T) {
		source_bytes, read_err := os.read_entire_file_from_path("demo/dom/counter.ps", context.allocator)
		testing.expectf(t, read_err == nil, "demo/dom/counter.ps не прочитан: %v", read_err)
		if read_err != nil do return

		result := check_source(string(source_bytes))
		testing.expectf(t, len(result.diags) == 0, "demo/dom/counter.ps diagnostics: %v", result.diags)
		if len(result.diags) > 0 do return

		module := lower_module(&result.res_ctx, &result.tc_ctx, &result.prog)
		bytes := lower_module_to_wasm(&module)

		write_err := os.write_entire_file("demo/dom/counter.wasm", bytes)
		testing.expectf(t, write_err == nil, "demo/dom/counter.wasm не записан: %v", write_err)
	}

}
