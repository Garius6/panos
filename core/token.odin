package core

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
	LessEqual,
	GreaterEqual,
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
	Const,
	Import,
	Export,
	Enum,
	Match,
	As,
	Semicolon,
	Comma,
	Question,
	Spawn,
	Percent,
	EOF,
}

// Позиция куска исходника в байтах. file_id различает модули в графе
// импортов — один прогон типизирует несколько файлов сразу.
Span :: struct {
	file_id: u16,
	start:   u32,
	end:     u32,
}

Token :: struct {
	data:      string,
	kind:      TokenKind,
	span:      Span,
	// true, если между предыдущим токеном и этим был перевод строки — см.
	// использование в parser.odin (parse_type): различает `Массив(Число)`
	// (генерик, '(' на той же строке) от `-> Число\n(выражение)` (тело
	// функции, начинающееся со скобки на СЛЕДУЮЩЕЙ строке — не генерик-аргс).
	nl_before: bool,
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
// побайтовый, не rune-aware — для кириллицы col не совпадает с визуальной
// колонкой (multi-byte UTF-8), но line всегда точная, а этого достаточно
// для перехода к строке в редакторе.
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

// Ни next_token, ни peek_token НИКОГДА не возвращают nil — tokenize()
// гарантирует хотя бы один .EOF-токен последним элементом s.tokens, и обе
// функции клэмпят current_idx на нём вместо ухода за границу массива.
// "Конец потока" — устойчивое состояние: сколько раз ни спроси, снова .EOF.
// Вызывающий код может безопасно читать .kind без nil-проверки.
next_token :: proc(s: ^TokenStream) -> ^Token {
	if s.current_idx >= len(s.tokens) - 1 {
		s.current_idx = len(s.tokens) - 1
		return &s.tokens[s.current_idx]
	}
	idx := s.current_idx
	s.current_idx += 1
	return &s.tokens[idx]
}

peek_token :: proc(s: ^TokenStream) -> ^Token {
	if s.current_idx >= len(s.tokens) {
		return &s.tokens[len(s.tokens) - 1]
	}
	return &s.tokens[s.current_idx]
}
