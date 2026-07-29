#+build !js
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

@(test)
test_wasm_module_has_import_section_for_runtime :: proc(t: ^testing.T) {
	// Фаза 1.5: КАЖДЫЙ модуль импортирует wasm_runtime (см.
	// core/wasm_module.odin's pw_imports), даже если фикстура строк не
	// использует — funcidx-пространство начинается с них безусловно.
	bytes := lower_wasm_from_source(t, `
		функ старт() -> Число
			1 + 2
		конец
	`)
	name := transmute([]u8)string("pw_alloc_from_scratch")
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
	testing.expectf(t, found, "имя импорта 'pw_alloc_from_scratch' не найдено в байтах модуля")
}

@(test)
test_wasm_module_lowers_string_const_without_panic :: proc(t: ^testing.T) {
	// Фаза 1.5: строковый литерал (и `+`/`==` на Строка) больше не
	// паникует, см. core/wasm_emit.odin's emit_string_const/
	// PW_CONCAT_STRINGS/PW_STRING_EQUAL — семантика проверяется
	// дифференциальными тестами (core/wasm_backend_wasmtime_test.odin),
	// здесь только структурная гарантия "лоуринг не падает".
	bytes := lower_wasm_from_source(t, `
		функ старт() -> Булево
			("при" + "вет") == "привет"
		конец
	`)
	testing.expectf(t, len(bytes) > 8, "модуль пуст")
}

@(test)
test_wasm_module_lowers_print_call_without_panic :: proc(t: ^testing.T) {
	// Фаза 2.0: ввод_вывод::печать больше не паникует (единственный
	// поддержанный builtin, см. core/wasm_emit.odin's Call_Builtin_Instr
	// case) — семантика (реальный stdout) проверяется дифференциальными
	// тестами.
	bytes := lower_wasm_from_source(t, `
		импорт ввод_вывод
		функ старт() -> Пусто
			ввод_вывод.печать("привет")
		конец
	`)
	name := transmute([]u8)string("pw_print_string")
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
	testing.expectf(t, found, "имя импорта 'pw_print_string' не найдено в байтах модуля")
}

@(test)
test_wasm_module_lowers_array_without_panic :: proc(t: ^testing.T) {
	// Фаза 2.1: Массив (New_Array_Instr/Get_Index_Instr/Set_Index_Instr)
	// больше не паникует — семантика проверяется дифференциальными
	// тестами.
	bytes := lower_wasm_from_source(t, `
		функ старт() -> Число
			пер значения = массив(1, 2, 3)
			значения[0]
		конец
	`)
	testing.expectf(t, len(bytes) > 8, "модуль пуст")
}

@(test)
test_wasm_module_lowers_enum_match_without_panic :: proc(t: ^testing.T) {
	// Фаза 2.1: Build_Variant_Instr/Match_Tag_Instr/Get_Variant_Field_
	// Instr (через `выбор`) больше не паникуют — семантика проверяется
	// дифференциальными тестами.
	bytes := lower_wasm_from_source(t, `
		тип Ф = перечисление
			Точка
			Круг(Число)
		конец
		функ старт() -> Число
			возврат выбор Ф.Круг(5)
				Точка -> 0
				Круг(р) -> р
			конец
		конец
	`)
	testing.expectf(t, len(bytes) > 8, "модуль пуст")
}

@(test)
test_wasm_module_lowers_array_method_call_without_panic :: proc(t: ^testing.T) {
	bytes := lower_wasm_from_source(t, `
		функ старт() -> Число
			пер значения = массив(1, 2, 3)
			пер часть = значения.срез(0, 1)
			если значения.есть(0) и значения.содержит(2) и часть.длина() == 1 тогда
				возврат значения.получить(0, -1)
			конец
			0
		конец
	`)
	testing.expectf(t, len(bytes) > 8, "модуль пуст")
}

@(test)
test_wasm_module_lowers_map_without_panic :: proc(t: ^testing.T) {
	bytes := lower_wasm_from_source(t, `
		функ старт() -> Целое
			пер цены = соответствие("яблоко" = 10, "груша" = 20)
			цены.удалить("яблоко")
			если цены.есть("груша") тогда
				пер прочитано = цены["груша"]
				пер запасное = цены.получить("груша", -1)
				если прочитано + запасное > 0 тогда
					цены.удалить("груша")
				конец
			конец
			цены.длина()
		конец
	`)
	testing.expectf(t, len(bytes) > 8, "модуль пуст")
}

@(test)
test_wasm_module_lowers_array_push_and_map_set_index_without_panic :: proc(t: ^testing.T) {
	bytes := lower_wasm_from_source(t, `
		функ старт() -> Целое
			пер a: Массив(Целое) = массив()
			a.добавить(1)
			a.добавить(2)
			пер m = соответствие("а" = 1)
			m["б"] = 2
			m["а"] = 99
			a.длина() + m.длина()
		конец
	`)
	testing.expectf(t, len(bytes) > 8, "модуль пуст")
}

// Намеренно нет теста "паникует на interface/closures/actors вне
// области": Odin's panic() — фатальный abort процесса (нет
// recover/unwind), проверка такого пути уронила бы весь тестовый бинарь
// вместе со всеми остальными тестами. Код, отвечающий за это
// (emit_mir_instr в core/wasm_emit.odin, wasm_val_type в core/wasm_
// module.odin), прост и самоочевиден — понятное сообщение вместо тихого
// неверного вывода достигается самой структурой кода, не отдельным
// регрессионным тестом.
