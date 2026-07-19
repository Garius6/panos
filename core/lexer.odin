package core

import "core:fmt"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

Lexer :: struct {
	input:       string,
	pos:         int,
	ch:          rune,
	width:       int,
	file_id:     u16,
	// Accumulate-not-panic, как в Parser/Resolver_Ctx/Type_Ctx: ошибочный
	// символ не должен ронять весь процесс (в т.ч. LSP при live-typing).
	diagnostics: [dynamic]Diagnostic,
	// Строковая интерполяция (`\(...)`, см. TokenKind.InterpString*):
	// стек глубины "(" ОТДЕЛЬНО на каждый активный уровень интерполяции
	// (вложенная интерполяция — `\(f(\(x)))` — толкает свой элемент).
	// top-of-stack == 0 и встретили ')' → это НЕ вложенная скобка
	// выражения, а закрывающая для САМОГО `\(` — возобновляем сканирование
	// строкового фрагмента вместо обычного .RParen. '(' внутри активной
	// интерполяции инкрементирует top, свой же ')' декрементирует —
	// нулевые/несбалансированные "(" не текущего уровня не видит.
	interp_paren_depth: [dynamic]int,
}

new_lexer :: proc(input: string, file_id: u16 = 0) -> Lexer {
	l := Lexer {
		input       = input,
		file_id     = file_id,
		diagnostics = make([dynamic]Diagnostic),
	}
	advance(&l)
	return l
}

// Дедуп по span+message — тот же приём, что report_parse/report_resolve.
report_lex :: proc(l: ^Lexer, span: Span, format: string, args: ..any) {
	msg := fmt.aprintf(format, ..args)
	for d in l.diagnostics {
		if d.span == span && d.message == msg do return
	}
	append(&l.diagnostics, Diagnostic{severity = .Error, span = span, message = msg})
}

// Span текущего (ещё не съеденного) символа — `l.pos - l.width` указывает
// на его начало, `l.pos` на его конец (см. комментарий у next_token_lex).
current_char_span :: proc(l: ^Lexer) -> Span {
	return Span{file_id = l.file_id, start = u32(l.pos - l.width), end = u32(l.pos)}
}

advance :: proc(l: ^Lexer) {
	if l.pos >= len(l.input) {
		l.ch = 0
		l.width = 0
		return
	}
	l.ch, l.width = utf8.decode_rune_in_string(l.input[l.pos:])
	l.pos += l.width
}

peek_char :: proc(l: ^Lexer) -> rune {
	if l.pos >= len(l.input) do return 0
	r, _ := utf8.decode_rune_in_string(l.input[l.pos:])
	return r
}

// Возвращает (saw_newline, doc) — saw_newline: true, если в пропущенном
// whitespace встретился перевод строки (см. Token.nl_before). doc:
// текст ближайшего НЕПРЕРЫВНОГО блока `///`-строк прямо перед следующим
// токеном (docstring), пусто если такого блока не было.
//
// "Непрерывный" — ни одной пустой строки ни ВНУТРИ блока, ни МЕЖДУ его
// последней строкой и следующим токеном; обычный `//`-комментарий или
// пустая строка сбрасывают накопленное (см. newline_run). Разделение с
// плоским счётчиком новых строк вместо стека/состояний — самая простая
// схема, покрывающая нужный случай (docstring вплотную над декларацией),
// без попытки поддержать более сложные разметки.
skip_whitespace_and_comments :: proc(l: ^Lexer) -> (saw_newline: bool, doc: string) {
	doc_lines: [dynamic]string
	newline_run := 0
	for {
		if unicode.is_space(l.ch) {
			if l.ch == '\n' {
				saw_newline = true
				newline_run += 1
				if newline_run >= 2 do clear(&doc_lines)
			}
			advance(l)
		} else if l.ch == '/' && peek_char(l) == '/' {
			advance(l)
			advance(l)
			is_doc := l.ch == '/'
			if is_doc do advance(l)
			start := l.pos - l.width
			for l.ch != '\n' && l.ch != 0 {
				advance(l)
			}
			if is_doc {
				append(&doc_lines, strings.trim_space(l.input[start:l.pos - l.width]))
			} else {
				clear(&doc_lines)
			}
			newline_run = 0
		} else {
			break
		}
	}
	doc = strings.join(doc_lines[:], "\n")
	return
}

read_identifier :: proc(l: ^Lexer) -> string {
	start := l.pos - l.width
	for unicode.is_alpha(l.ch) || unicode.is_digit(l.ch) || l.ch == '_' {
		advance(l)
	}
	return l.input[start:l.pos - l.width]
}

// Число: digits, опционально ".digits". '.' поглощается ТОЛЬКО если сразу
// за ним идёт цифра — иначе это не десятичная точка, а начало ОТДЕЛЬНОГО
// '.'-токена (property/tuple-index доступ). Без этой проверки `t.1.длина()`
// (tuple-индекс 1, затем вызов метода) читался бы как один "числовой"
// токен "1." — '.' перед 'длина' поглощался бы читалкой числа, вместо
// того чтобы остаться отдельным Dot-токеном для парсера.
read_number :: proc(l: ^Lexer) -> string {
	start := l.pos - l.width
	for unicode.is_digit(l.ch) {
		advance(l)
	}
	if l.ch == '.' && unicode.is_digit(peek_char(l)) {
		advance(l)
		for unicode.is_digit(l.ch) {
			advance(l)
		}
	}
	return l.input[start:l.pos - l.width]
}

// Терминатор строкового фрагмента: закрывающая кавычка (конец литерала),
// начало интерполяции `\(` (см. TokenKind.InterpString*), или EOF
// (best-effort восстановление, как раньше).
String_Fragment_End :: enum {
	Quote,
	Interp,
	Eof,
}

// Сканирует текст строкового литерала ДО закрывающей '"', ДО '\(' (начало
// интерполяции), либо до EOF. Не ест открывающую кавычку сама — вызывающий
// код (next_token_lex, и снова после ')', закрывающей '\(...)') решает,
// когда именно начинать фрагмент, поэтому один и тот же сканер переиспользуется
// и для самого первого фрагмента, и для каждого следующего после `\(...)`.
read_string_fragment :: proc(l: ^Lexer) -> (string, String_Fragment_End) {
	builder: strings.Builder
	strings.builder_init(&builder)

	for l.ch != '"' && l.ch != 0 {
		if l.ch == '\\' {
			advance(l)
			switch l.ch {
			case 'n':
				strings.write_byte(&builder, '\n')
			case 't':
				strings.write_byte(&builder, '\t')
			case 'r':
				strings.write_byte(&builder, '\r')
			case '"':
				strings.write_byte(&builder, '"')
			case '\\':
				strings.write_byte(&builder, '\\')
			case '(':
				// Начало интерполяции (Swift-style `\(выражение)`) — сам
				// '(' съедаем здесь (это не литеральный текст и не первый
				// токен встраиваемого выражения), возвращаем накопленный
				// ДО НЕГО фрагмент. next_token_lex продолжит обычной
				// токенизацией выражения (см. interp_paren_depth в Lexer).
				advance(l)
				return strings.to_string(builder), .Interp
			case 0:
				// EOF сразу после '\' — строка обрывается прямо тут, дальше
				// нечего съедать. report_lex + возврат накопленного (best
				// effort), а не panic: следующий next_token_lex увидит
				// l.ch == 0 и естественно закроет поток .EOF-токеном.
				report_lex(l, current_char_span(l), "Лексическая ошибка: незакрытая строка")
				return strings.to_string(builder), .Eof
			case:
				// Неизвестный escape — трактуем как литеральный символ
				// (совпадает с типичным поведением строковых литералов при
				// восстановлении: не роняем оставшуюся часть строки/файла
				// из-за одной опечатки в '\%v').
				report_lex(
					l,
					current_char_span(l),
					"Лексическая ошибка: неизвестная escape-последовательность '\\%v'",
					l.ch,
				)
				strings.write_rune(&builder, l.ch)
			}
		} else {
			strings.write_rune(&builder, l.ch)
		}
		advance(l)
	}

	if l.ch == '"' {
		advance(l) // Съедаем закрывающую кавычку
		return strings.to_string(builder), .Quote
	}
	// l.ch == 0 — дошли до EOF, не встретив закрывающую кавычку.
	// Возвращаем накопленное как best-effort строковый токен вместо
	// падения всего процесса на файле с одной незакрытой кавычкой.
	report_lex(l, current_char_span(l), "Лексическая ошибка: незакрытая строка")
	return strings.to_string(builder), .Eof
}

lookup_ident :: proc(ident: string) -> TokenKind {
	switch ident {
	case "пер":
		return .Let
	case "конст":
		return .Const
	case "истина", "ложь":
		return .Boolean
	case "функ":
		return .Function
	case "возврат":
		return .Return
	case "конец":
		return .End
	case "пока":
		return .While
	case "цикл":
		return .Loop
	case "продолжить":
		return .Continue
	case "прервать":
		return .Break
	case "если":
		return .If
	case "тогда":
		return .Then
	case "иначе":
		return .Else
	case "не":
		return .Negate
	case "и":
		return .And
	case "или":
		return .Or
	case "тип":
		return .TypeDecl
	case "структура":
		return .Struct
	case "реализация":
		return .Impl
	case "интерфейс":
		return .Interface
	case "для":
		return .For
	case "импорт":
		return .Import
	case "экспорт":
		return .Export
	case "перечисление":
		return .Enum
	case "выбор":
		return .Match
	case "как":
		return .As
	case "запусти":
		return .Spawn
	case "в":
		return .In
	case "внешний":
		return .Foreign
	case "ff_структура":
		return .FFStruct
	}
	return .Ident
}

// Имя next_token_lex (а не next_token) во избежание конфликта с token.odin.
// Единственный return внизу ставит span: `l.pos - l.width` всегда указывает
// на начало ещё не съеденного `l.ch`, поэтому start берётся до свитча, end —
// после того, как ветка съела токен целиком.
// for-обёртка нужна для восстановления после "неожиданный символ" (case ниже):
// битый rune съедается и цикл пробует следующий токен, не возвращая никакого
// токена для битого символа. В отличие от Hole-узлов парсера, на уровне
// лексера "дыра" — это просто исчезновение символа из потока.
next_token_lex :: proc(l: ^Lexer, file_id: u16) -> Token {
	for {
	nl_before, doc := skip_whitespace_and_comments(l)

	start_pos := l.pos - l.width
	tok: Token

	if l.ch == 0 {
		tok = Token{kind = .EOF, data = "EOF"}
	} else {
		switch l.ch {
		case '<':
			if peek_char(l) == '>' {
				advance(l)
				advance(l)
				tok = Token {
					kind = .NotEqual,
					data = "<>",
				}
			} else if peek_char(l) == '=' {
				advance(l)
				advance(l)
				tok = Token {
					kind = .LessEqual,
					data = "<=",
				}
			} else {
				tok = Token {
					kind = .Less,
					data = "<",
				}
				advance(l)
			}
		case '>':
			if peek_char(l) == '=' {
				advance(l)
				advance(l)
				tok = Token {
					kind = .GreaterEqual,
					data = ">=",
				}
			} else {
				tok = Token {
					kind = .Greater,
					data = ">",
				}
				advance(l)
			}
		case '=':
			if peek_char(l) == '=' {
				advance(l)
				advance(l)
				tok = Token {
					kind = .Equal,
					data = "==",
				}
			} else {
				tok = Token {
					kind = .Assign,
					data = "=",
				}; advance(l)
			}
		case '+':
			tok = Token {
				kind = .Plus,
				data = "+",
			}; advance(l)
		case '-':
			if peek_char(l) == '>' {
				advance(l)
				advance(l)
				tok = Token {
					kind = .Arrow,
					data = "->",
				}
			} else {
				tok = Token {
					kind = .Minus,
					data = "-",
				}; advance(l)
			}
		case '*':
			tok = Token {
				kind = .Star,
				data = "*",
			}; advance(l)
		case '/':
			tok = Token {
				kind = .Slash,
				data = "/",
			}; advance(l)
		case '%':
			tok = Token {
				kind = .Percent,
				data = "%",
			}; advance(l)
		case '(':
			// Внутри активной интерполяции (Lexer.interp_paren_depth) эта
			// '(' принадлежит встраиваемому выражению — считаем её, чтобы
			// СВОЯ ')' (не закрывающая \(...)) не спуталась со скобкой-
			// терминатором интерполяции ниже.
			if len(l.interp_paren_depth) > 0 {
				l.interp_paren_depth[len(l.interp_paren_depth) - 1] += 1
			}
			tok = Token {
				kind = .LParen,
				data = "(",
			}; advance(l)
		case ')':
			if len(l.interp_paren_depth) > 0 && l.interp_paren_depth[len(l.interp_paren_depth) - 1] == 0 {
				// Глубина 0 на верхушке стека — эта ')' ничему внутри
				// выражения не принадлежит, значит закрывает САМ `\(`.
				// Возобновляем строковый фрагмент вместо .RParen.
				pop(&l.interp_paren_depth)
				advance(l) // съедаем ')'
				text, term := read_string_fragment(l)
				switch term {
				case .Quote, .Eof:
					tok = Token{kind = .InterpStringEnd, data = text}
				case .Interp:
					append(&l.interp_paren_depth, 0)
					tok = Token{kind = .InterpStringMid, data = text}
				}
			} else {
				if len(l.interp_paren_depth) > 0 {
					l.interp_paren_depth[len(l.interp_paren_depth) - 1] -= 1
				}
				tok = Token {
					kind = .RParen,
					data = ")",
				}; advance(l)
			}
		case '[':
			tok = Token {
				kind = .LBracket,
				data = "[",
			}; advance(l)
		case ']':
			tok = Token {
				kind = .RBracket,
				data = "]",
			}; advance(l)
		case ',':
			tok = Token {
				kind = .Comma,
				data = ",",
			}; advance(l)
		case '?':
			tok = Token {
				kind = .Question,
				data = "?",
			}; advance(l)
		case '.':
			tok = Token {
				kind = .Dot,
				data = ".",
			}; advance(l)
		case ':':
			tok = Token {
				kind = .Colon,
				data = ":",
			}; advance(l)
		case ';':
			tok = Token {
				kind = .Semicolon,
				data = ";",
			}; advance(l)
		case '"':
			advance(l) // Съедаем открывающую кавычку
			text, term := read_string_fragment(l)
			switch term {
			case .Quote, .Eof:
				tok = Token{kind = .String, data = text}
			case .Interp:
				append(&l.interp_paren_depth, 0)
				tok = Token{kind = .InterpStringStart, data = text}
			}
		case:
			if unicode.is_alpha(l.ch) || l.ch == '_' {
				ident := read_identifier(l)
				tok = Token{kind = lookup_ident(ident), data = ident}
			} else if unicode.is_digit(l.ch) {
				num := read_number(l)
				tok = Token{kind = .Number, data = num}
			} else {
				report_lex(l, current_char_span(l), "Лексическая ошибка: неожиданный символ '%v'", l.ch)
				advance(l) // символ съеден без токена — форвард-прогресс
				continue // пробуем следующий токен заново
			}
		}
	}

	end_pos := l.pos - l.width
	tok.span = Span{file_id = file_id, start = u32(start_pos), end = u32(end_pos)}
	tok.nl_before = nl_before
	tok.doc = doc
	return tok
	}
}

tokenize :: proc(input: string, file_id: u16 = 0) -> ([dynamic]Token, [dynamic]Diagnostic) {
	l := new_lexer(input, file_id)
	tokens := make([dynamic]Token)

	for {
		tok := next_token_lex(&l, file_id)
		append(&tokens, tok)
		if tok.kind == .EOF do break
	}

	return tokens, l.diagnostics
}
