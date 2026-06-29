package main

import "core:fmt"

TokenKind :: enum {
	Number,
	Boolean,
	Plus,
	Minus,
	Star,
	Slash,
	Assign,
	LParen,
	RParen,
	Ident,
	Return,
	Let,
	Semicolon,
	EOF,
}

Token :: struct {
	data: string,
	kind: TokenKind,
}

token_to_string :: proc(t: Token) -> string {
	return fmt.aprintf("Token(%v, %q)", t.kind, t.data)
}

TokenStream :: struct {
	tokens:      [dynamic]Token,
	current_idx: int,
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

can_insert_semicolon :: proc(kind: TokenKind) -> bool {
	#partial switch kind {
	case .Ident, .Number, .RParen, .Return:
		return true
	}
	return false
}
