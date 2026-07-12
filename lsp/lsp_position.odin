package main

import core "../core"
import "core:unicode/utf8"

// LSP использует UTF-16 code unit'ы для character-offset'а внутри строки
// (унаследовано от JS/VS Code). Исходники Panos — UTF-8. Эти две функции —
// единственное место конвертации; всё остальное в LSP-коде работает либо
// с байтовыми Span (внутренний AST), либо с (line, utf16_character)
// (протокол).

// Байтовый offset в source -> (line, utf16_character), оба 0-based (LSP).
byte_offset_to_lsp_position :: proc(source: string, offset: u32) -> (line: int, character: int) {
	limit := int(offset)
	if limit > len(source) do limit = len(source)

	line_start := 0
	for i := 0; i < limit; i += 1 {
		if source[i] == '\n' {
			line += 1
			line_start = i + 1
		}
	}
	character = utf16_len(source[line_start:limit])
	return
}

// (line, utf16_character) из LSP -> байтовый offset в source.
lsp_position_to_byte_offset :: proc(source: string, line: int, character: int) -> u32 {
	i := 0
	cur_line := 0
	for cur_line < line && i < len(source) {
		if source[i] == '\n' do cur_line += 1
		i += 1
	}
	units := 0
	for units < character && i < len(source) && source[i] != '\n' {
		r, w := utf8.decode_rune_in_string(source[i:])
		i += w
		units += r > 0xFFFF ? 2 : 1
	}
	return u32(i)
}

// Длина строки в UTF-16 code unit'ах: символы вне BMP (>0xFFFF) кодируются
// суррогатной парой = 2 unit'а, всё остальное — 1. Кириллица целиком в
// BMP, так что для панос-исходников это почти всегда len(s в рунах), но
// считаем честно на случай эмодзи/т.п. в строковых литералах или комментах.
utf16_len :: proc(s: string) -> int {
	n := 0
	for r in s {
		n += r > 0xFFFF ? 2 : 1
	}
	return n
}

// --- ПОИСК AST-УЗЛА ПО ПОЗИЦИИ ---

decl_span :: proc(d: core.Decls) -> core.Span {
	if d == nil do return core.Span{}
	switch v in d {
	case ^core.Import_Decl:
		return v.span
	case ^core.Function_Decl:
		return v.span
	case ^core.Struct_Decl:
		return v.span
	case ^core.Impl_Decl:
		return v.span
	case ^core.Interface_Decl:
		return v.span
	case ^core.Enum_Decl:
		return v.span
	}
	return core.Span{}
}

span_contains :: proc(sp: core.Span, file_id: u16, offset: u32) -> bool {
	return sp.file_id == file_id && offset >= sp.start && offset < sp.end
}

// Находит самый глубокий Expr, чей span содержит offset. Спускается в
// дочерние узлы; если ни один потомок не содержит offset (напр. курсор на
// операторе/скобке), возвращает сам e — этого достаточно для hover
// ("тип этого под-выражения").
find_expr_at :: proc(e: core.Expr, file_id: u16, offset: u32) -> core.Expr {
	if e == nil do return nil
	if !span_contains(core.expr_span(e), file_id, offset) do return nil

	#partial switch v in e {
	case ^core.Binary_Expr:
		if r := find_expr_at(v.left, file_id, offset); r != nil do return r
		if r := find_expr_at(v.right, file_id, offset); r != nil do return r
	case ^core.Unary_Expr:
		if r := find_expr_at(v.right, file_id, offset); r != nil do return r
	case ^core.Call_Expr:
		if r := find_expr_at(v.callee, file_id, offset); r != nil do return r
		for arg in v.args {
			if r := find_expr_at(arg, file_id, offset); r != nil do return r
		}
	case ^core.While_Expr:
		if r := find_expr_at(v.condition, file_id, offset); r != nil do return r
		if r := find_in_body(v.body, file_id, offset); r != nil do return r
	case ^core.If_Expr:
		if r := find_expr_at(v.condition, file_id, offset); r != nil do return r
		if r := find_in_body(v.then_branch, file_id, offset); r != nil do return r
		if r := find_in_body(v.else_branch, file_id, offset); r != nil do return r
	case ^core.Tuple_Expr:
		for el in v.elements {
			if r := find_expr_at(el, file_id, offset); r != nil do return r
		}
	case ^core.Property_Expr:
		if r := find_expr_at(v.object, file_id, offset); r != nil do return r
	case ^core.Lambda_Expr:
		if r := find_in_body(v.body, file_id, offset); r != nil do return r
	case ^core.Array_Expr:
		for el in v.elements {
			if r := find_expr_at(el, file_id, offset); r != nil do return r
		}
	case ^core.Map_Expr:
		for entry in v.entries {
			if r := find_expr_at(entry.key, file_id, offset); r != nil do return r
			if r := find_expr_at(entry.value, file_id, offset); r != nil do return r
		}
	case ^core.Index_Expr:
		if r := find_expr_at(v.object, file_id, offset); r != nil do return r
		if r := find_expr_at(v.index, file_id, offset); r != nil do return r
	case ^core.Try_Expr:
		if r := find_expr_at(v.value, file_id, offset); r != nil do return r
	case ^core.Match_Expr:
		if r := find_expr_at(v.subject, file_id, offset); r != nil do return r
		for arm in v.arms {
			if r := find_in_body(arm.body, file_id, offset); r != nil do return r
		}
	}
	return e
}

find_in_body :: proc(body: [dynamic]core.Stmt, file_id: u16, offset: u32) -> core.Expr {
	for stmt in body {
		if r := find_in_stmt(stmt, file_id, offset); r != nil do return r
	}
	return nil
}

find_in_stmt :: proc(stmt: core.Stmt, file_id: u16, offset: u32) -> core.Expr {
	if stmt == nil do return nil
	#partial switch s in stmt {
	case ^core.Return_Stmt:
		return find_expr_at(s.value, file_id, offset)
	case ^core.Let_Stmt:
		return find_expr_at(s.value, file_id, offset)
	case ^core.Expr_Stmt:
		return find_expr_at(s.expr, file_id, offset)
	}
	return nil
}

// Верхнеуровневая точка входа: находит Expr в программе по byte offset.
// Сперва находит объемлющий Decl (функцию/метод), затем спускается внутрь.
find_expr_in_program :: proc(prog: core.Program, file_id: u16, offset: u32) -> core.Expr {
	for decl in prog.decls {
		if !span_contains(decl_span(decl), file_id, offset) do continue
		#partial switch d in decl {
		case ^core.Function_Decl:
			return find_in_body(d.body, file_id, offset)
		case ^core.Impl_Decl:
			for m in d.methods {
				if span_contains(m.span, file_id, offset) {
					return find_in_body(m.body, file_id, offset)
				}
			}
		}
		return nil
	}
	return nil
}
