package main

import "core:fmt"
import "core:unicode"
import "core:unicode/utf8"

// Структура для хранения состояния
Lexer :: struct {
	input:      string,
	pos:        int,
	nest_level: int,
}

tokenize :: proc(input: string) -> [dynamic]Token {
	l := Lexer {
		input      = input,
		pos        = 0,
		nest_level = 0,
	}
	tokens: [dynamic]Token

	for l.pos < len(l.input) {
		ch, width := utf8.decode_rune_in_string(l.input[l.pos:])

		switch {
		case unicode.is_space(ch):
			l.pos += width
		case ch == ';':
			append(&tokens, Token{kind = .Semicolon, data = ";"})
			l.pos += width

		case unicode.is_alpha(ch) || ch == '_':
			start := l.pos
			for l.pos < len(l.input) {
				c, w := utf8.decode_rune_in_string(l.input[l.pos:])
				if unicode.is_alpha(c) || unicode.is_digit(c) || c == '_' {
					l.pos += w
				} else {
					break
				}
			}

			word := l.input[start:l.pos]
			keywords := keywords()

			if word in keywords {
				append(&tokens, Token{kind = keywords[word], data = word})
			} else {
				append(&tokens, Token{kind = .Ident, data = word})
			}

		case unicode.is_digit(ch):
			start := l.pos
			for l.pos < len(l.input) {
				c, w := utf8.decode_rune_in_string(l.input[l.pos:])
				if unicode.is_digit(c) {
					l.pos += w
				} else {
					break
				}
			}
			append(&tokens, Token{kind = .Number, data = l.input[start:l.pos]})

		case ch == '+':
			append(&tokens, Token{kind = .Plus, data = "+"})
			l.pos += width
		case ch == '-':
			append(&tokens, Token{kind = .Minus, data = "-"})
			l.pos += width
		case ch == '*':
			append(&tokens, Token{kind = .Star, data = "*"})
			l.pos += width
		case ch == '/':
			append(&tokens, Token{kind = .Slash, data = "/"})
			l.pos += width
		case ch == '(':
			l.nest_level += 1
			append(&tokens, Token{kind = .LParen, data = "("})
			l.pos += width
		case ch == ')':
			if l.nest_level > 0 do l.nest_level -= 1
			append(&tokens, Token{kind = .RParen, data = ")"})
			l.pos += width
		case ch == '=':
			if l.nest_level > 0 do l.nest_level -= 1
			append(&tokens, Token{kind = .Assign, data = "="})
			l.pos += width
		case ch == ',':
			if l.nest_level > 0 do l.nest_level -= 1
			append(&tokens, Token{kind = .Comma, data = ","})
			l.pos += width
		case ch == ':':
			if l.nest_level > 0 do l.nest_level -= 1
			append(&tokens, Token{kind = .Colon, data = ":"})
			l.pos += width

		case:
			fmt.panicf(
				"Синтаксическая ошибка: неожиданный символ '%v' на позиции %d",
				ch,
				l.pos,
			)
		}
	}

	append(&tokens, Token{kind = .EOF, data = "EOF"})

	return tokens
}

keywords :: proc() -> map[string]TokenKind {
	keywords := make(map[string]TokenKind, context.allocator)
	keywords["пер"] = .Let
	keywords["истина"] = .Boolean
	keywords["ложь"] = .Boolean
	keywords["функ"] = .Function
	keywords["конец"] = .End
	keywords["пока"] = .While
	keywords["цикл"] = .Loop
	keywords["если"] = .If
	keywords["тогда"] = .Then
	keywords["иначе"] = .Else

	return keywords
}
