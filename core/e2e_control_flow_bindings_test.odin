#+build !js
package core

import "core:testing"

// для-in — чистый parser-level desugar в Let/While/If/Index (см.
// parse_stmt_into/parse_for_stmt_into в parser.odin). Резолвер/type_cheker/
// compiler/vm ничего о нём не знают — эти тесты гоняют desugar сквозь весь
// пайплайн, а не проверяют parser напрямую.
@(test)
test_for_in_sums_array :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ старт() -> Число
			пер числа = массив(10, 20, 30)
			пер сумма = 0
			для х в числа цикл
				сумма = сумма + х
			конец
			сумма
		конец
	`)
	testing.expectf(t, ok, "for-in array: пустой стек")
	if !ok do return
	testing.expectf(t, result == Value(f64(60)), "for-in array: ожидалось 60, получено %v", result)
}

// Шаблон "(к, з)" — деструктуризация тупла из Соответствие.записи()
// (Стадия 16). Map[] сама по себе НЕ индексируется позиционно — for-in
// работает только через .записи().
@(test)
test_for_in_destructures_map_entries :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ старт() -> Число
			пер карта: Соответствие(Строка, Число) = соответствие(
				"a" = 1,
				"b" = 2,
				"c" = 3,
			)
			пер сумма = 0
			для (к, з) в карта.записи() цикл
				сумма = сумма + з
			конец
			сумма
		конец
	`)
	testing.expectf(t, ok, "for-in map entries: пустой стек")
	if !ok do return
	testing.expectf(t, result == Value(f64(6)), "for-in map entries: ожидалось 6, получено %v", result)
}

// Инкремент индекса стоит ПЕРЕД телом (см. комментарий у
// parse_for_stmt_into) именно из-за этого случая: 'продолжить' не должен
// пропускать инкремент, иначе цикл завис бы. 'прервать' проверяется
// отдельно — оба в одном тесте, чтобы покрыть их взаимодействие.
@(test)
test_for_in_continue_and_break :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ старт() -> Число
			пер числа = массив(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)
			пер сумма = 0
			пер посещено = 0
			для х в числа цикл
				посещено = посещено + 1
				если посещено == 8 тогда
					прервать
				конец
				если х == 3 тогда
					продолжить
				конец
				сумма = сумма + х
			конец
			сумма
		конец
	`)
	testing.expectf(t, ok, "for-in continue/break: пустой стек")
	if !ok do return
	// 1+2+4+5+6+7 = 25 (3 пропущен через continue, 8-й элемент не
	// достигнут — break сработал до прибавления к сумме)
	testing.expectf(t, result == Value(f64(25)), "for-in continue/break: ожидалось 25, получено %v", result)
}

@(test)
test_for_in_empty_array_zero_iterations :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ старт() -> Число
			пер пустой: Массив(Число) = массив()
			пер счетчик = 0
			для х в пустой цикл
				счетчик = счетчик + 1
			конец
			счетчик
		конец
	`)
	testing.expectf(t, ok, "for-in empty: пустой стек")
	if !ok do return
	testing.expectf(t, result == Value(f64(0)), "for-in empty: ожидалось 0, получено %v", result)
}

// Ранний возврат внутри для-in тела — синтетическая пока-обёртка не
// должна мешать обычному return-flow (нет отдельной scope-изоляции у
// синтетического While_Expr, ровно как у обычного пока/если — см.
// resolve_stmt::While_Expr).
@(test)
test_for_in_early_return :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ старт() -> Число
			пер числа = массив(1, 3, 5, 4, 7)
			для х в числа цикл
				если х == 4 тогда
					возврат х
				конец
			конец
			-1
		конец
	`)
	testing.expectf(t, ok, "for-in early return: пустой стек")
	if !ok do return
	testing.expectf(t, result == Value(f64(4)), "for-in early return: ожидалось 4, получено %v", result)
}

// Два для-in в одной функции с ОДИНАКОВЫМ именем переменной цикла — до
// scope-фикса (см. resolve_stmt::If_Expr/While_Expr) if/while вообще не
// изолировали scope, `пер` внутри протекал в объемлющую функцию, и второй
// `для х` падал с "Имя х уже объявлено" (не про for-in как таковой — та
// же проблема была у любых двух `пока`/`если` подряд с одноимённым `пер`).
@(test)
test_for_in_multiple_loops_no_name_collision :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ старт() -> Число
			пер а = массив(1, 2)
			пер б = массив(10, 20)
			пер сумма = 0
			для х в а цикл
				сумма = сумма + х
			конец
			для х в б цикл
				сумма = сумма + х
			конец
			сумма
		конец
	`)
	testing.expectf(t, ok, "for-in no collision: пустой стек")
	if !ok do return
	testing.expectf(t, result == Value(f64(33)), "for-in no collision: ожидалось 33, получено %v", result)
}

@(test)
test_for_in_nested_loops :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ старт() -> Число
			пер строки = массив(массив(1, 2), массив(3, 4, 5))
			пер сумма = 0
			для строка в строки цикл
				для х в строка цикл
					сумма = сумма + х
				конец
			конец
			сумма
		конец
	`)
	testing.expectf(t, ok, "for-in nested: пустой стек")
	if !ok do return
	testing.expectf(t, result == Value(f64(15)), "for-in nested: ожидалось 15, получено %v", result)
}

// Регрессия на сам scope-фикс, отдельно от for-in: `пер` внутри если/пока
// объявляет ИМЯ заново в разных, не вложенных, ветках/циклах без
// конфликта, но мутации ВНЕШНИХ переменных (не redeclare, обычное
// присваивание) по-прежнему видны после блока — scope изолирует
// ОБЪЯВЛЕНИЯ, не читает/пишет через границу.
@(test)
test_if_while_scope_isolation :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ старт() -> Число
			пер x = 5
			если истина тогда
				x = x + 1
				пер y = 100
			конец
			если истина тогда
				пер y = 1
				x = x + y
			иначе
				x = 0
			конец
			x
		конец
	`)
	testing.expectf(t, ok, "if/while scope isolation: пустой стек")
	if !ok do return
	// 5 +1 (первый если, y=100 там не видно снаружи) +1 (второй если,
	// свой y=1, не конфликтует с y из первого) = 7
	testing.expectf(t, result == Value(f64(7)), "if/while scope isolation: ожидалось 7, получено %v", result)
}

// Пусто-функция не обязана заканчиваться Пусто-выражением — последний
// statement трактуется как обычный (значение молча отбрасывается), ровно
// как любой НЕ последний statement тела функции. Раньше здесь была
// ошибка "функция объявлена как 'Пусто', но последнее выражение имеет
// тип...", убрана по запросу пользователя.
@(test)
test_void_function_discards_trailing_value :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ побочный_эффект() -> Число
			42
		конец

		функ действие() -> Пусто
			побочный_эффект()
		конец

		функ старт() -> Число
			действие()
			действие()
			99
		конец
	`)
	testing.expectf(t, ok, "void trailing discard: пустой стек")
	if !ok do return
	testing.expectf(t, result == Value(f64(99)), "void trailing discard: ожидалось 99, получено %v", result)
}

// Явный `возврат X` внутри Пусто-функции — ДРУГОЙ путь (check_stmt's
// Return_Stmt, не через infer_block_type) и по-прежнему ошибка: сознательно
// написанный `возврат 5` при заявленном Пусто — это не "последнее
// выражение как значение по умолчанию", а явная ошибка автора.
@(test)
test_void_function_explicit_return_value_still_rejected :: proc(t: ^testing.T) {
	testing.expect_assert(t, "Type Error: ожидался 'Пусто', получен 'Число'")
	run_code(`
		функ старт() -> Пусто
			возврат 5
		конец
	`)
}

// Найдено на внешнем проекте пользователя: `для x в моя_карта цикл` (без
// .записи()) раскрывается в позиционное `[индекс]` (см.
// parse_for_stmt_into), а Соответствие индексируется по ключу — раньше
// это давало неинформативное "ожидался 'Строка', получен 'Число'" без
// намёка на причину. Теперь конкретно для этого паттерна (индекс —
// Число, ключ — нет) — отдельное сообщение с подсказкой про .записи().
@(test)
test_map_positional_index_error_hints_at_записи :: proc(t: ^testing.T) {
	testing.expect_assert(
		t,
		"Type Error: соответствие индексируется по ключу типа 'Строка', получено 'Число' — Соответствие не поддерживает позиционный доступ; для перебора элементов используйте .записи() и 'для (ключ, значение) в ...'",
	)
	run_code(`
		функ старт() -> Число
			пер карта: Соответствие(Строка, Число) = соответствие("a" = 1)
			для x в карта цикл
				x
			конец
			0
		конец
	`)
}

// Регрессия: НЕ-для-in источник того же типа несовпадения (обычная
// индексация с неверным типом ключа) по-прежнему даёт обычное сообщение —
// подсказка про .записи() специфична для "индекс — Число, ключ — нет".
@(test)
test_map_index_wrong_key_type_generic_message_unaffected :: proc(t: ^testing.T) {
	testing.expect_assert(t, "Type Error: ожидался 'Число', получен 'Строка'")
	run_code(`
		функ старт() -> Строка
			пер карта: Соответствие(Число, Строка) = соответствие()
			карта["текст"]
		конец
	`)
}

// value_equals (vm.odin) раньше не имел case для ^Aggregate_Value/
// ^Array_Value/^Map_Value — падал в `return false` безусловно, хотя
// тайпчекер разрешает `==`/`<>` для любых unifiable типов. `стр1 == стр2`
// для двух одинаковых по полям структур молча всегда была `ложь`
// (сравнение по ссылке вместо значения), без единой диагностики.
@(test)
test_struct_array_map_structural_equality :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Точка = структура
			x: Число
			y: Число
		конец

		функ старт() -> Строка
			пер а = Точка(1, 2)
			пер б = Точка(1, 2)
			пер третья = Точка(1, 3)
			пер струкРавны = а == б
			пер струкНеРавны = не (а == третья)

			пер м1 = массив(1, 2, 3)
			пер м2 = массив(1, 2, 3)
			пер м3 = массив(1, 2, 4)
			пер массРавны = м1 == м2
			пер массНеРавны = не (м1 == м3)

			пер к1 = соответствие(1 = "a", 2 = "b")
			пер к2 = соответствие(2 = "b", 1 = "a")
			пер к3 = соответствие(1 = "a", 2 = "c")
			пер картРавны = к1 == к2
			пер картНеРавны = не (к1 == к3)

			если струкРавны и струкНеРавны и массРавны и массНеРавны и картРавны и картНеРавны тогда
				"всё верно"
			иначе
				"провал"
			конец
		конец
	`)
	testing.expectf(t, ok, "[structural equality] стек пуст")
	if ok {
		testing.expectf(t, value_str_eq(result, "всё верно"), "[structural equality] ожидалось 'всё верно', получено %v", result)
	}
}

// Мутация поля (Set_Property) делает self-ссылающийся runtime-граф
// физически возможным (а.следующий = а) — наивная рекурсия в value_equals
// зациклилась бы. visited (пара указателей once-visited = равны без
// рекурсии дальше) — тот же приём, что unify_types уже использует для
// самоссылающихся ТИПОВ (Стадия 7 Phase D). Regression-тест с alarm-
// таймаутом здесь не нужен — testing.T сам падает по общему таймауту
// прогона, если этот тест зависнет.
@(test)
test_struct_equality_self_referential_cycle_safe :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Узел = структура
			значение: Число
			следующий: Опция(Узел)
		конец

		функ старт() -> Булево
			пер а = Узел(1, Опция.Нет())
			а.следующий = Опция.Есть(а)

			пер б = Узел(1, Опция.Нет())
			б.следующий = Опция.Есть(б)

			а == б
		конец
	`)
	testing.expectf(t, ok, "[cycle-safe equality] стек пуст")
	b, is_bool := result.(bool)
	testing.expectf(t, is_bool && b, "[cycle-safe equality] ожидалось true, получено %v", result)
}

// Регрессия: структура БЕЗ реализация Равнозначное — == работает как
// раньше (структурное value_equals), Стадия 22 не required-impl для Eq.
@(test)
test_struct_without_equatable_keeps_structural_equality :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Точка = структура
			x: Число
			y: Число
		конец

		функ старт() -> Булево
			пер а = Точка(1, 2)
			пер б = Точка(1, 2)
			а == б
		конец
	`)
	testing.expectf(t, ok, "[структурное == без Равнозначное] стек пуст")
	b, is_bool := result.(bool)
	testing.expectf(t, is_bool && b, "[структурное == без Равнозначное] ожидалось true, получено %v", result)
}

// Стадия 27: конст-биндинг компилируется/исполняется как обычный пер —
// сама фича не меняет чтение значения, только запрещает переприсвоение.
@(test)
test_const_binding_reads_like_normal_let :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ старт() -> Число
			конст x = 5
			x + 1
		конец
	`)
	testing.expectf(t, ok, "[конст: чтение] стек пуст")
	n, is_num := result.(f64)
	testing.expectf(t, is_num && n == 6, "[конст: чтение] ожидалось 6, получено %v", result)
}

// Негативный кейс: переприсвоение конст даёт diagnostic, не крэш и не
// молчаливый успех.
@(test)
test_const_reassignment_is_error :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		функ старт() -> Число
			конст x = 5
			x = 10
			x
		конец
	`)
	expect_diagnostic(t, diags, "Type Error: попытка переприсвоить константу 'x'")
}

// Стадия 27 (расширение): параметры функций immutable по умолчанию
// (Kotlin/Swift-style) — переприсвоение параметра теперь ошибка, как у
// конст-локалей. Это НАМЕРЕННОЕ изменение поведения относительно
// исходной Стадии 27 (тогда параметры были reassignable — см. Explore
// в ROADMAP) — тест заменяет прежний
// test_function_params_still_reassignable, который проверял старое
// поведение.
@(test)
test_function_params_are_immutable_by_default :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		функ f(x: Число) -> Число
			x = x + 1
			x
		конец

		функ старт() -> Число
			f(5)
		конец
	`)
	expect_diagnostic(t, diags, "Type Error: попытка переприсвоить константу 'x'")
}

// Читать параметр (без переприсвоения) по-прежнему работает как раньше.
@(test)
test_function_params_still_readable :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ f(x: Число) -> Число
			x + 1
		конец

		функ старт() -> Число
			f(5)
		конец
	`)
	testing.expectf(t, ok, "[конст: параметры чтение] стек пуст")
	n, is_num := result.(f64)
	testing.expectf(t, is_num && n == 6, "[конст: параметры чтение] ожидалось 6, получено %v", result)
}

// Regression (Explore-находка): конст во вложенном scope не мешает пер
// с тем же именем во внешнем scope (каждый scope — независимый Symbol).
@(test)
test_const_shadowing_nested_scope_still_works :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ старт() -> Число
			пер x = 5
			если истина тогда
				конст x = 10
				x
			конец
			x
		конец
	`)
	testing.expectf(t, ok, "[конст: shadowing] стек пуст")
	n, is_num := result.(f64)
	testing.expectf(t, is_num && n == 5, "[конст: shadowing] ожидалось 5, получено %v", result)
}

// Деструктуризация в пер/конст: `пер (a, b) = кортеж` (тупл, позиционно)
// и `пер Тип(a, b) = значение` (структура, по порядку объявления полей —
// тот же принцип, что и у обычного позиционного конструктора Тип(1, 2)).
// Компилируется через .Get_Property по числовому индексу — тот же приём,
// что уже применяет for-in для `для (a, b) в ...`.
@(test)
test_let_tuple_destructure :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ старт() -> Число
			пер (a, b, c) = (1, 2, 3)
			a + b + c
		конец
	`)
	testing.expectf(t, ok, "[пер: тупл-деструктуризация] стек пуст")
	n, is_num := result.(f64)
	testing.expectf(t, is_num && n == 6, "[пер: тупл-деструктуризация] ожидалось 6, получено %v", result)
}

// read_number (lexer.odin) раньше поглощал '.' после числа безусловно —
// `t.1.длина()` (tuple-индекс, затем вызов метода на результате) читался
// как ОДИН числовой токен "1." вместо Number("1") + Dot + Ident, парсер
// видел неверный индекс тупла. Фикс: '.' поглощается только если сразу
// за ним цифра (иначе это начало отдельного '.'-токена).
@(test)
test_tuple_index_followed_by_method_call :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ старт() -> Целое
			пер t = (5, массив(1, 2, 3))
			t.1.длина()
		конец
	`)
	testing.expectf(t, ok, "[тупл-индекс + метод] стек пуст")
	n, is_num := result.(f64)
	testing.expectf(t, is_num && n == 3, "[тупл-индекс + метод] ожидалось 3, получено %v", result)
}

// Более глубокая неоднозначность: "1.0" после '.' лексически неотличимо
// от float-литерала И от ДВУХ подряд идущих tuple-индексов (вложенный.1,
// затем .0 от результата) — read_number не может это различить (нет
// контекста). Разрешается в парсере (case .Dot в parse_expr): числовой
// токен сразу после '.' в property-позиции ВСЕГДА индекс(ы) тупла,
// никогда float-значение (нет понятия ".1.5"-поля) — если в тексте
// токена есть '.', парсер расщепляет его на два индекса и десахаривает
// в цепочку Property_Expr, как будто ".1.0" было написано двумя
// токенами явно.
@(test)
test_nested_tuple_index_both_bare_digits :: proc(t: ^testing.T) {
	result, ok := run_code(`
		функ старт() -> Число
			пер вложенный = (1, (2, 3))
			пер тройной = (1, (2, (3, 4)))
			вложенный.1.0 + вложенный.1.1 + тройной.1.1.0 + тройной.1.1.1
		конец
	`)
	testing.expectf(t, ok, "[вложенный tuple-индекс, обе цифры голые] стек пуст")
	n, is_num := result.(f64)
	testing.expectf(
		t,
		is_num && n == 12,
		"[вложенный tuple-индекс, обе цифры голые] ожидалось 12 (2+3+3+4), получено %v",
		result,
	)
}

@(test)
test_let_struct_destructure :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Точка = структура
			x: Число
			y: Число
		конец

		функ старт() -> Число
			пер точка = Точка(3, 4)
			пер Точка(x, y) = точка
			x + y
		конец
	`)
	testing.expectf(t, ok, "[пер: структурная деструктуризация] стек пуст")
	n, is_num := result.(f64)
	testing.expectf(t, is_num && n == 7, "[пер: структурная деструктуризация] ожидалось 7, получено %v", result)
}

// конст-деструктуризация: is_const проброшен на КАЖДОЕ извлечённое имя —
// переприсваивание любого из них должно паниковать так же, как обычный
// конст (Стадия 27).
@(test)
test_const_tuple_destructure_is_immutable :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		функ старт() -> Число
			конст (a, b) = (1, 2)
			a = 99
			a + b
		конец
	`)
	expect_diagnostic(t, diags, "Type Error: попытка переприсвоить константу 'a'")
}

@(test)
test_let_tuple_destructure_arity_mismatch_reports_diagnostic :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		функ старт() -> Число
			пер (a, b, c) = (1, 2)
			a + b + c
		конец
	`)
	expect_diagnostic(t, diags, "Type Error: тупл из 2 элементов не совпадает с шаблоном из 3 имён")
}

@(test)
test_let_struct_destructure_wrong_type_reports_diagnostic :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		тип Точка = структура
			x: Число
			y: Число
		конец
		тип Вектор = структура
			x: Число
			y: Число
		конец

		функ старт() -> Число
			пер точка = Точка(1, 2)
			пер Вектор(x, y) = точка
			x + y
		конец
	`)
	expect_diagnostic(t, diags, "Type Error: шаблон 'пер Вектор(...)' не совпадает со значением типа 'Точка'")
}
