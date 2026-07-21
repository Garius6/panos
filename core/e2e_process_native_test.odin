#+build !js
package core

import "core:os"
import "core:testing"

// Регрессия для двух новых builtin'ов фичи 003-pan-package-manager:
// ос::выполнить (спавн процесса с контролем cwd) и directory-ops в фс
// (создать_директорию/список_директории/удалить_директорию) — без них
// пакетный менеджер pan (../panosiki/pan/) не может ни git clone, ни
// раскладывать зависимости в модули/. См. research.md фичи, п.8.

@(test)
test_os_execute_respects_cwd_and_captures_output :: proc(t: ^testing.T) {
	result, ok := run_code(`
		импорт ос
		импорт строки

		функ старт() -> Булево
			пер р = ос.выполнить("/bin/pwd", массив(), "/tmp")
			выбор р
				Результат.Успех(данные) -> данные.0 == 0 и строки.содержит(данные.1, "/tmp")
				Результат.Неудача(ош) -> ложь
			конец
		конец
	`)
	testing.expectf(t, ok, "[ос.выполнить] пустой стек")
	if !ok do return
	testing.expectf(t, result == Value(true), "[ос.выполнить] ожидался код=0 и cwd в stdout, получено %v", result)
}

@(test)
test_os_execute_missing_program_is_error :: proc(t: ^testing.T) {
	result, ok := run_code(`
		импорт ос

		функ старт() -> Булево
			пер р = ос.выполнить("/несуществующая-программа-zzz", массив(), "/tmp")
			р.ошибка()
		конец
	`)
	testing.expectf(t, ok, "[ос.выполнить missing] пустой стек")
	if !ok do return
	testing.expectf(t, result == Value(true), "[ос.выполнить missing] ожидался Ошибка(...) для несуществующей программы, получено %v", result)
}

@(test)
test_fs_directory_ops_create_list_remove :: proc(t: ^testing.T) {
	result, ok := run_code(`
		импорт фс

		функ старт() -> Булево
			пер путь = "/tmp/panos_e2e_dir_test_xyz/вложенная"
			пер р1 = фс.создать_директорию(путь)
			если р1.ошибка() тогда
				возврат ложь
			конец

			пер р2 = фс.список_директории("/tmp/panos_e2e_dir_test_xyz")
			пер содержит_вложенную = ложь
			если р2.успех() тогда
				для имя в р2.значение() цикл
					если имя == "вложенная" тогда
						содержит_вложенную = истина
					конец
				конец
			конец

			пер р3 = фс.удалить_директорию("/tmp/panos_e2e_dir_test_xyz")

			содержит_вложенную и р3.успех() и не фс.есть("/tmp/panos_e2e_dir_test_xyz")
		конец
	`)
	testing.expectf(t, ok, "[фс directory-ops] пустой стек")
	if !ok do return
	testing.expectf(t, result == Value(true), "[фс directory-ops] create/list/remove не сошлись, получено %v", result)
}

// ос::завершить реально терминирует ТЕКУЩИЙ процесс (os.exit -> !) — вызвать
// его в этом же тестовом процессе означало бы убить сам `odin test`.
// Единственный честный способ проверить exit code — спавнить настоящий
// дочерний panos (через `odin run .`, как `just debug-file`) и посмотреть на
// его state.exit_code, а не run_code() в процессе.
@(test)
test_os_terminate_sets_child_process_exit_code :: proc(t: ^testing.T) {
	tmp_script := "/tmp/panos_e2e_os_terminate_test.ps"
	write_err := os.write_entire_file(tmp_script, `
		импорт ос

		функ старт() -> Пусто
			ос.завершить(42)
		конец
	`)
	testing.expectf(t, write_err == nil, "[ос.завершить] не удалось написать временный скрипт: %v", write_err)
	if write_err != nil do return
	defer os.remove(tmp_script)

	desc := os.Process_Desc {
		command = []string{"odin", "run", ".", "--", tmp_script},
	}
	state, _, stderr_bytes, err := os.process_exec(desc, context.allocator)
	testing.expectf(t, err == nil, "[ос.завершить] не удалось запустить дочерний panos: %v (%s)", err, string(stderr_bytes))
	if err != nil do return
	testing.expectf(t, state.exit_code == 42, "[ос.завершить] ожидался exit code 42, получен %d", state.exit_code)
}
