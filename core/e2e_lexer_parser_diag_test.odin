#+build !js
package core

import "core:testing"

has_latin_word :: proc(msg: string) -> bool {
	// Разрешённые английские префиксы диагностики (соглашение проекта).
	body := msg
	prefixes := [?]string {
		"Type Error:",
		"Runtime Error:",
		"Runtime Panic:",
		"Semantic Error:",
		"Syntactic Error:",
		"Compiler Error:",
		"Resolve Error:",
		"Синтаксическая ошибка:",
	}
	for prefix in prefixes {
		if len(body) >= len(prefix) && body[:len(prefix)] == prefix {
			body = body[len(prefix):]
			break
		}
	}
	// Ищем последовательность из ≥3 ASCII-латинских букв в теле сообщения.
	streak := 0
	for r in body {
		is_latin := (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z')
		if is_latin {
			streak += 1
			if streak >= 3 do return true
		} else {
			streak = 0
		}
	}
	return false
}

@(test)
test_diagnostics_have_no_latin_words :: proc(t: ^testing.T) {
	messages := [?]string {
		"Type Error: у варианта 'Фигура.Круг' поле #0 ожидает 'Число', получено 'Строка'",
		"Синтаксическая ошибка: вариант 'Круг' объявлен дважды в 'Фигура'",
		"Resolve Error: у типа 'Фигура' нет варианта 'Ромб'",
		"Resolve Error: имя варианта 'Точка' конфликтует с уже объявленным символом в модуле",
		"Resolve Error: модуль 'ф' не экспортирует 'Круг'",
		"Type Error: выбор не покрывает варианты: Точка",
		"Type Error: выбор не покрывает варианты: Лист",
		"Type Error: выбор не покрывает варианты: Г",
		"Type Error: '_' в выборе должен быть только последней веткой",
		"Type Error: вариант 'Ф.А' покрыт повторно в ветке #2",
		"Type Error: выбор не покрывает варианты: Нет",
	}
	for msg, i in messages {
		testing.expectf(
			t,
			!has_latin_word(msg),
			"сообщение #%d содержит латинское слово: %s",
			i,
			msg,
		)
	}
}

// Лексер больше не panic'ует (см. lexer.odin::report_lex) — последний из
// panic'ующих проходов пайплайна (Стадия 10 П6 намеренно это отложила).
// Неожиданный символ молча исчезает из потока токенов (report_lex +
// advance, БЕЗ токена для него) — парсер о нём вообще не узнаёт, поэтому
// остаток программы разбирается нормально.
@(test)
test_lexer_reports_unexpected_char_and_continues :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		функ старт() -> Число
			$
			42
		конец
	`)
	expect_diagnostic(t, diags, "Лексическая ошибка: неожиданный символ '$'")
}

@(test)
test_lexer_reports_unterminated_string :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		функ старт() -> Строка
			"не закрыта
	`)
	expect_diagnostic(t, diags, "Лексическая ошибка: незакрытая строка")
}

// Неизвестная escape-последовательность восстанавливается как литеральный
// символ ПОСЛЕ '\' (не сама '\') — строка не обрывается из-за одной
// опечатки в экранировании.
@(test)
test_lexer_unknown_escape_recovers_as_literal :: proc(t: ^testing.T) {
	tokens, diags := tokenize(`"плохой \q escape"`)
	expect_diagnostic(t, diags, "Лексическая ошибка: неизвестная escape-последовательность '\\q'")
	testing.expectf(t, len(tokens) >= 1, "unknown escape recovery: пустой поток токенов")
	if len(tokens) == 0 do return
	str_tok := tokens[0]
	testing.expectf(t, str_tok.kind == .String, "unknown escape recovery: ожидался String токен, получен %v", str_tok.kind)
	testing.expectf(
		t,
		str_tok.data == "плохой q escape",
		"unknown escape recovery: ожидалось 'плохой q escape', получено %q",
		str_tok.data,
	)
}

// Именованные аргументы (`f(x = 1, y = 2)`) — везде, где есть позиционные
// параметры/поля: функции, конструкторы структур, методы. Порядок в
// вызове может отличаться от объявления — сверяется по именам.
@(test)
test_named_call_args_function_struct_and_method :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Точка = структура
			x: Число
			y: Число
		конец

		реализация Точка
			функ сумма(это: Точка, множитель: Число, сдвиг: Число) -> Число
				(это.x + это.y) * множитель + сдвиг
			конец
		конец

		функ вычесть(a: Число, b: Число) -> Число
			a - b
		конец

		функ старт() -> Число
			пер п = Точка(x = 1, y = 2)
			пер р1 = вычесть(a = 10, b = 3)
			пер р2 = вычесть(b = 3, a = 10)
			пер р3 = п.сумма(сдвиг = 1, множитель = 2)
			р1 + р2 + р3
		конец
	`)
	testing.expectf(t, ok, "[именованные аргументы] стек пуст")
	if ok {
		n, is_num := result.(f64)
		testing.expectf(t, is_num && n == 21, "[именованные аргументы] ожидалось 21, получено %v", result)
	}
}

// Негатив: смешивать позиционные и именованные аргументы в одном вызове
// нельзя.
@(test)
test_named_call_args_mixing_positional_is_error :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		функ f(a: Число, b: Число) -> Число
			a + b
		конец
		функ старт() -> Число
			f(1, b = 2)
		конец
	`)
	expect_diagnostic(t, diags, "Синтаксическая ошибка: нельзя смешивать позиционные и именованные аргументы в одном вызове")
}

// Негатив: неизвестное имя аргумента.
@(test)
test_named_call_args_unknown_name_is_error :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		функ f(a: Число, b: Число) -> Число
			a + b
		конец
		функ старт() -> Число
			f(a = 1, c = 2)
		конец
	`)
	expect_diagnostic(t, diags, "Type Error: неизвестный именованный аргумент 'c'")
}

// Негатив: повторный именованный аргумент.
@(test)
test_named_call_args_duplicate_name_is_error :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		функ f(a: Число, b: Число) -> Число
			a + b
		конец
		функ старт() -> Число
			f(a = 1, a = 2)
		конец
	`)
	expect_diagnostic(t, diags, "Type Error: именованный аргумент 'a' указан повторно")
}

// Именованная деструктуризация (`пер Тип(x: a, y: b) = значение`) —
// закрывает последнее позиционное место из language-fails (конструктор
// и match-шаблоны уже получили именованную альтернативу, Стадии 35/36).
// Порядок в шаблоне может отличаться от объявления структуры.
@(test)
test_named_destructure_reordered :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Точка = структура
			x: Число
			y: Число
			z: Число
		конец

		функ старт() -> Число
			пер точка = Точка(1, 2, 3)
			пер Точка(y: b, x: a) = точка
			a * 100 + b
		конец
	`)
	testing.expectf(t, ok, "[именованная деструктуризация] стек пуст")
	if ok {
		n, is_num := result.(f64)
		testing.expectf(t, is_num && n == 102, "[именованная деструктуризация] ожидалось 102, получено %v", result)
	}
}

// Частичная — в отличие от именованных аргументов вызова (Стадия 36),
// деструктуризация допускает НЕ упоминать все поля (не все значения
// обязательно извлекать).
@(test)
test_named_destructure_partial :: proc(t: ^testing.T) {
	result, ok := run_code(`
		тип Точка = структура
			x: Число
			y: Число
			z: Число
		конец

		функ старт() -> Число
			пер точка = Точка(1, 2, 3)
			пер Точка(z: c) = точка
			c
		конец
	`)
	testing.expectf(t, ok, "[частичная деструктуризация] стек пуст")
	if ok {
		n, is_num := result.(f64)
		testing.expectf(t, is_num && n == 3, "[частичная деструктуризация] ожидалось 3, получено %v", result)
	}
}

// Негатив: неизвестное имя поля.
@(test)
test_named_destructure_unknown_field_is_error :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		тип Точка = структура
			x: Число
			y: Число
		конец
		функ старт() -> Число
			пер точка = Точка(1, 2)
			пер Точка(w: a) = точка
			a
		конец
	`)
	expect_diagnostic(t, diags, "Type Error: у структуры 'Точка' нет поля 'w'")
}

// Негатив: повторное имя поля в шаблоне.
@(test)
test_named_destructure_duplicate_field_is_error :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		тип Точка = структура
			x: Число
			y: Число
		конец
		функ старт() -> Число
			пер точка = Точка(1, 2)
			пер Точка(x: a, x: b) = точка
			a + b
		конец
	`)
	expect_diagnostic(t, diags, "Type Error: поле 'x' указано в деструктуризации повторно")
}

// Негатив: смешивать позиционную и именованную форму в одной
// деструктуризации нельзя.
@(test)
test_named_destructure_mixing_is_error :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		тип Точка = структура
			x: Число
			y: Число
		конец
		функ старт() -> Число
			пер точка = Точка(1, 2)
			пер Точка(a, y: b) = точка
			a + b
		конец
	`)
	expect_diagnostic(t, diags, "Синтаксическая ошибка: нельзя смешивать позиционную и именованную деструктуризацию в одном выражении")
}

// Негатив: тупл-деструктуризация не имеет имён полей — именованная форма
// бессмысленна (та же причина, что enum-варианты в match-шаблонах).
@(test)
test_named_destructure_tuple_form_rejects_named_syntax :: proc(t: ^testing.T) {
	diags := typecheck_only(`
		функ старт() -> Число
			пер тупл = (1, 2)
			пер (x: a, y: b) = тупл
			a + b
		конец
	`)
	testing.expectf(t, len(diags) > 0, "[тупл против именованной формы] ожидались diagnostics")
}
