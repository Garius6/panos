package main

import "core:fmt"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

Lexer :: struct {
	input: string,
	pos:   int,
	ch:    rune,
	width: int,
}

new_lexer :: proc(input: string) -> Lexer {
	l := Lexer {
		input = input,
	}
	advance(&l)
	return l
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

skip_whitespace_and_comments :: proc(l: ^Lexer) {
	for {
		if unicode.is_space(l.ch) {
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
				fmt.panicf(
					"Лексическая ошибка: незакрытая строка",
				)
			case:
				fmt.panicf(
					"Лексическая ошибка: неизвестная escape-последовательность '\\%v'",
					l.ch,
				)
			}
		} else {
			strings.write_rune(&builder, l.ch)
		}
		advance(l)
	}

	if l.ch == '"' {
		advance(l) // Съедаем закрывающую кавычку
	} else {
		fmt.panicf("Лексическая ошибка: незакрытая строка")
	}

	return strings.to_string(builder)
}

lookup_ident :: proc(ident: string) -> TokenKind {
	switch ident {
	case "пер":
		return .Let
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
	}
	return .Ident
}

// ВАЖНО: Переименовано в next_token_lex, чтобы не конфликтовать с token.odin!
// Один return point внизу — там же ставится span. `l.pos - l.width` в
// любой момент указывает на начало ещё не съеденного `l.ch` (см.
// read_identifier/read_number — тот же приём), поэтому start берётся до
// свитча, а end — после того, как соответствующая ветка съела токен целиком.
next_token_lex :: proc(l: ^Lexer, file_id: u16) -> Token {
	skip_whitespace_and_comments(l)

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
			} else {
				tok = Token {
					kind = .Less,
					data = "<",
				}
				advance(l)
			}
		case '>':
			tok = Token {
				kind = .Greater,
				data = ">",
			}; advance(l)
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
				fmt.panicf(
					"Лексическая ошибка: неожиданный символ '%v'",
					l.ch,
				)
			}
		}
	}

	end_pos := l.pos - l.width
	tok.span = Span{file_id = file_id, start = u32(start_pos), end = u32(end_pos)}
	return tok
}

tokenize :: proc(input: string, file_id: u16 = 0) -> [dynamic]Token {
	l := new_lexer(input)
	tokens := make([dynamic]Token)

	for {
		tok := next_token_lex(&l, file_id)
		append(&tokens, tok)
		if tok.kind == .EOF do break
	}

	return tokens
}
