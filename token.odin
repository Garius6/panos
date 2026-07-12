package main

import "core:fmt"

TokenKind :: enum {
	Number,
	Boolean,
	Plus,
	Minus,
	Star,
	String,
	Slash,
	Assign,
	LParen,
	RParen,
	LBracket,
	RBracket,
	Less,
	Greater,
	Equal,
	Negate,
	NotEqual,
	Ident,
	Function,
	Colon,
	If,
	Then,
	Else,
	And,
	Or,
	While,
	Loop,
	Continue,
	Break,
	Arrow,
	End,
	TypeDecl,
	Struct,
	Dot,
	Impl,
	Interface,
	For,
	Return,
	Let,
	Import,
	Export,
	Enum,
	Match,
	As,
	Semicolon,
	Comma,
	Question,
	EOF,
}

// Позиция куска исходника в байтах. file_id различает модули в графе
// импортов — нужен уже сейчас (не только для будущего LSP), т.к. один
// прогон типизирует несколько файлов сразу.
Span :: struct {
	file_id: u16,
	start:   u32,
	end:     u32,
}

Token :: struct {
	data: string,
	kind: TokenKind,
	span: Span,
}

token_to_string :: proc(t: Token) -> string {
	return fmt.aprintf("Token(%v, %s)", t.kind, t.data)
}

TokenStream :: struct {
	tokens:      [dynamic]Token,
	current_idx: int,
}

// Span последнего съеденного токена (current_idx - 1). Парсер использует
// это, чтобы проставить end-позицию AST-узла после того, как дочитал
// конструкцию до конца.
last_token_span :: proc(s: ^TokenStream) -> Span {
	if s.current_idx == 0 do return Span{}
	return s.tokens[s.current_idx - 1].span
}

// Байтовый offset → line:col (1-based) для печати diagnostic'ов. Счёт
// побайтовый, не rune-aware — для кириллицы col будет не совсем "визуальная
// колонка" (multi-byte UTF-8), но line всегда точная, а этого достаточно
// для перехода к строке в редакторе. Точный rune-aware col — по нужде,
// когда появится LSP (Стадия 3) с реальными position-запросами.
span_line_col :: proc(source: string, offset: u32) -> (line: int, col: int) {
	line = 1
	col = 1
	limit := int(offset)
	if limit > len(source) do limit = len(source)
	for i := 0; i < limit; i += 1 {
		if source[i] == '\n' {
			line += 1
			col = 1
		} else {
			col += 1
		}
	}
	return
}

make_stream :: proc(tokens: [dynamic]Token) -> TokenStream {
	return TokenStream{tokens = tokens}
}

destroy_stream :: proc(s: ^TokenStream) {
	delete(s.tokens)
}

next_token :: proc(s: ^TokenStream) -> ^Token {
	if s.current_idx >= len(s.tokens) {
		return nil
	}
	idx := s.current_idx
	s.current_idx += 1
	return &s.tokens[idx]
}

peek_token :: proc(s: ^TokenStream) -> ^Token {
	if s.current_idx >= len(s.tokens) {
		return nil
	}
	return &s.tokens[s.current_idx]
}
