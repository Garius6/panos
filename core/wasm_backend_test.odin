package core

import "core:testing"

// wasm_backend_test.odin — структурные тесты WASM AOT-бэкенда (Фаза 1),
// без внешних инструментов (wasmtime/WABT) — часть обычного `odin test
// ./core`/`just test`. Дифференциальные тесты (сравнение с байткод-VM
// через реально запущенный wasmtime) — core/wasm_backend_wasmtime_test.
// odin, за #config(PANOS_WASM_BACKEND_TESTS) — см. `just test-wasm-backend`.

@(private = "file")
lower_wasm_from_source :: proc(t: ^testing.T, source: string) -> []u8 {
	result := check_source(source)
	testing.expectf(t, len(result.diags) == 0, "check_source diagnostics: %v", result.diags)
	module := lower_module(&result.res_ctx, &result.tc_ctx, &result.prog)
	return lower_module_to_wasm(&module)
}

@(test)
test_wasm_module_has_valid_header :: proc(t: ^testing.T) {
	bytes := lower_wasm_from_source(t, `
		функ старт() -> Число
			1 + 2
		конец
	`)
	testing.expectf(t, len(bytes) >= 8, "модуль короче магической шапки+версии: %d байт", len(bytes))
	testing.expect_value(t, bytes[0], u8(0x00))
	testing.expect_value(t, bytes[1], u8(0x61))
	testing.expect_value(t, bytes[2], u8(0x73))
	testing.expect_value(t, bytes[3], u8(0x6D))
	testing.expect_value(t, bytes[4], u8(0x01))
	testing.expect_value(t, bytes[5], u8(0x00))
	testing.expect_value(t, bytes[6], u8(0x00))
	testing.expect_value(t, bytes[7], u8(0x00))
}

@(test)
test_wasm_module_exports_entry_function :: proc(t: ^testing.T) {
	bytes := lower_wasm_from_source(t, `
		функ старт() -> Число
			42
		конец
	`)
	// Export-секция (id=7) содержит имя "старт" как байты UTF-8 —
	// достаточно проверить, что подстрока встречается где-то в модуле
	// (полноценный парсер секций — избыточен для structural smoke-теста,
	// реальная семантика проверяется дифференциальными тестами).
	name := transmute([]u8)string("старт")
	found := false
	if len(bytes) >= len(name) {
		for i := 0; i <= len(bytes) - len(name); i += 1 {
			match := true
			for j in 0 ..< len(name) {
				if bytes[i + j] != name[j] {
					match = false
					break
				}
			}
			if match {
				found = true
				break
			}
		}
	}
	testing.expectf(t, found, "имя функции 'старт' не найдено в байтах модуля")
}

// Намеренно нет теста "паникует на строковом литерале/heap-инструкции вне
// области Фазы 1": Odin's panic() — фатальный abort процесса (нет
// recover/unwind), проверка такого пути уронила бы весь тестовый бинарь
// вместе со всеми остальными тестами. Код, отвечающий за это (emit_mir_instr
// в core/wasm_emit.odin, wasm_val_type в core/wasm_module.odin), прост и
// самоочевиден — понятное сообщение вместо тихого неверного вывода
// достигается самой структурой кода, не отдельным регрессионным тестом.
