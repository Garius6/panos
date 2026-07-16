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

// Возвращает true, если в пропущенном whitespace встретился перевод
// строки — используется парсером для различения `Массив(Число)` (генерик)
// от `(...)`, начинающего новый statement на следующей строке (см. Token.nl_before).
skip_whitespace_and_comments :: proc(l: ^Lexer) -> bool {
	saw_newline := false
	for {
		if unicode.is_space(l.ch) {
			if l.ch == '\n' do saw_newline = true
			advance(l)
		} else if l.ch == '/' && peek_char(l) == '/' {
			advance(l)
			advance(l)
			for l.ch != '\n' && l.ch != 0 {
				advance(l)
			}
		} else {
			break
		}
	}
	return saw_newline
}

read_identifier :: proc(l: ^Lexer) -> string {
	start := l.pos - l.width
	for unicode.is_alpha(l.ch) || unicode.is_digit(l.ch) || l.ch == '_' {
		advance(l)
	}
	return l.input[start:l.pos - l.width]
}

read_number :: proc(l: ^Lexer) -> string {
	start := l.pos - l.width
	for unicode.is_digit(l.ch) || l.ch == '.' {
		advance(l)
	}
	return l.input[start:l.pos - l.width]
}

read_string :: proc(l: ^Lexer) -> string {
	advance(l) // Съедаем открывающую кавычку

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
			case 0:
				// EOF сразу после '\' — строка обрывается прямо тут, дальше
				// нечего съедать. report_lex + возврат накопленного (best
				// effort), а не panic: следующий next_token_lex увидит
				// l.ch == 0 и естественно закроет поток .EOF-токеном.
				report_lex(l, current_char_span(l), "Лексическая ошибка: незакрытая строка")
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
	} else {
		// l.ch == 0 — дошли до EOF, не встретив закрывающую кавычку.
		// Возвращаем накопленное как best-effort строковый токен вместо
		// падения всего процесса на файле с одной незакрытой кавычкой.
		report_lex(l, current_char_span(l), "Лексическая ошибка: незакрытая строка")
	}

	return strings.to_string(builder)
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
	nl_before := skip_whitespace_and_comments(l)

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
		case '(':
			tok = Token {
				kind = .LParen,
				data = "(",
			}; advance(l)
		case ')':
			tok = Token {
				kind = .RParen,
				data = ")",
			}; advance(l)
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
			str := read_string(l)
			tok = Token{kind = .String, data = str}
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
