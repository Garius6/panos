package main

import "core:fmt"
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
	start := l.pos - l.width

	for l.ch != '"' && l.ch != 0 {
		advance(l)
	}

	str := l.input[start:l.pos - l.width]

	if l.ch == '"' {
		advance(l) // Съедаем закрывающую кавычку
	} else {
		fmt.panicf("Лексическая ошибка: незакрытая строка")
	}

	return str
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
	case "если":
		return .If
	case "тогда":
		return .Then
	case "иначе":
		return .Else
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
	case "как":
		return .As
	}
	return .Ident
}

// ВАЖНО: Переименовано в next_token_lex, чтобы не конфликтовать с token.odin!
next_token_lex :: proc(l: ^Lexer) -> Token {
	skip_whitespace_and_comments(l)

	if l.ch == 0 {
		return Token{kind = .EOF, data = "EOF"}
	}

	tok: Token

	switch l.ch {
	case '<':
		tok = Token {
			kind = .Less,
			data = "<",
		}; advance(l)
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
		return Token{kind = .String, data = str}
	case:
		if unicode.is_alpha(l.ch) || l.ch == '_' {
			ident := read_identifier(l)
			return Token{kind = lookup_ident(ident), data = ident}
		} else if unicode.is_digit(l.ch) {
			num := read_number(l)
			return Token{kind = .Number, data = num}
		} else {
			fmt.panicf(
				"Лексическая ошибка: неожиданный символ '%v'",
				l.ch,
			)
		}
	}

	return tok
}

// ВАЖНО: Сигнатура не изменена, возвращает [dynamic]Token как раньше.
tokenize :: proc(input: string) -> [dynamic]Token {
	l := new_lexer(input)
	tokens := make([dynamic]Token)

	for {
		tok := next_token_lex(&l)
		append(&tokens, tok)
		if tok.kind == .EOF do break
	}

	return tokens
}
