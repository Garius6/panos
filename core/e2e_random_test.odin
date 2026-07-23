#+build !js
package core

import "core:testing"

// std/математика.ps — файловый std-модуль, а не builtin: run_code
// (module.dir == "") не грузит реальные .ps-зависимости, только
// run_module_file (тот же путь, что CLI/LSP) реально резолвит std/. См.
// комментарий у test_math_stdlib (core/e2e_modules_stdlib_test.odin).
//
// Генератор — stateful обёртка над уже существующими следующее/дробь/
// диапазон (Lehmer/Park-Miller), даёт вызывающему коду автоматический
// seed вместо ручного проброса. Проверки (детерминизм при одинаковом
// seed, продвижение состояния, границы диапазон()/дробь(), оба исхода
// булево(), независимость нескольких экземпляров, новый_генератор()
// вообще работает) объединены в один Булево в
// fixtures/random_fixture_main.ps — тот же паттерн, что test_math_stdlib.
@(test)
test_random_generator :: proc(t: ^testing.T) {
	result, ok := run_module_file("fixtures/random_fixture_main.ps")
	testing.expectf(t, ok, "генератор случайных чисел: стек пуст, нет результата")
	if !ok do return

	testing.expectf(t, result == Value(true), "генератор случайных чисел: ожидалось true, получено %v", result)
}
