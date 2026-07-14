package core

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

// Байтовый offset -> плоский UTF-16 offset от начала ВСЕГО source (не
// line-relative, в отличие от byte_offset_to_lsp_position выше) — формат,
// который ждёт CodeMirror (число, а не {line, character}), см. wasm/main.odin.
byte_offset_to_utf16_offset :: proc(source: string, byte_offset: u32) -> int {
	limit := int(byte_offset)
	if limit > len(source) do limit = len(source)
	return utf16_len(source[:limit])
}

// Обратное: плоский UTF-16 offset (от CodeMirror) -> байтовый offset.
utf16_offset_to_byte_offset :: proc(source: string, utf16_offset: int) -> u32 {
	i := 0
	units := 0
	for units < utf16_offset && i < len(source) {
		r, w := utf8.decode_rune_in_string(source[i:])
		i += w
		units += r > 0xFFFF ? 2 : 1
	}
	return u32(i)
}

// --- ПОИСК AST-УЗЛА ПО ПОЗИЦИИ ---

decl_span :: proc(d: Decls) -> Span {
	if d == nil do return Span{}
	switch v in d {
	case ^Import_Decl:
		return v.span
	case ^Function_Decl:
		return v.span
	case ^Struct_Decl:
		return v.span
	case ^Impl_Decl:
		return v.span
	case ^Interface_Decl:
		return v.span
	case ^Enum_Decl:
		return v.span
	case ^Error_Decl:
		return v.span
	}
	return Span{}
}

span_contains :: proc(sp: Span, file_id: u16, offset: u32) -> bool {
	return sp.file_id == file_id && offset >= sp.start && offset < sp.end
}

// Находит самый глубокий Expr, чей span содержит offset. Спускается в
// дочерние узлы; если ни один потомок не содержит offset (напр. курсор на
// операторе/скобке), возвращает сам e — этого достаточно для hover
// ("тип этого под-выражения").
find_expr_at :: proc(e: Expr, file_id: u16, offset: u32) -> Expr {
	if e == nil do return nil
	if !span_contains(expr_span(e), file_id, offset) do return nil

	#partial switch v in e {
	case ^Binary_Expr:
		if r := find_expr_at(v.left, file_id, offset); r != nil do return r
		if r := find_expr_at(v.right, file_id, offset); r != nil do return r
	case ^Unary_Expr:
		if r := find_expr_at(v.right, file_id, offset); r != nil do return r
	case ^Call_Expr:
		if r := find_expr_at(v.callee, file_id, offset); r != nil do return r
		for arg in v.args {
			if r := find_expr_at(arg, file_id, offset); r != nil do return r
		}
	case ^While_Expr:
		if r := find_expr_at(v.condition, file_id, offset); r != nil do return r
		if r := find_in_body(v.body, file_id, offset); r != nil do return r
	case ^If_Expr:
		if r := find_expr_at(v.condition, file_id, offset); r != nil do return r
		if r := find_in_body(v.then_branch, file_id, offset); r != nil do return r
		if r := find_in_body(v.else_branch, file_id, offset); r != nil do return r
	case ^Tuple_Expr:
		for el in v.elements {
			if r := find_expr_at(el, file_id, offset); r != nil do return r
		}
	case ^Property_Expr:
		if r := find_expr_at(v.object, file_id, offset); r != nil do return r
	case ^Lambda_Expr:
		if r := find_in_body(v.body, file_id, offset); r != nil do return r
	case ^Array_Expr:
		for el in v.elements {
			if r := find_expr_at(el, file_id, offset); r != nil do return r
		}
	case ^Map_Expr:
		for entry in v.entries {
			if r := find_expr_at(entry.key, file_id, offset); r != nil do return r
			if r := find_expr_at(entry.value, file_id, offset); r != nil do return r
		}
	case ^Index_Expr:
		if r := find_expr_at(v.object, file_id, offset); r != nil do return r
		if r := find_expr_at(v.index, file_id, offset); r != nil do return r
	case ^Try_Expr:
		if r := find_expr_at(v.value, file_id, offset); r != nil do return r
	case ^Match_Expr:
		if r := find_expr_at(v.subject, file_id, offset); r != nil do return r
		for arm in v.arms {
			if r := find_in_body(arm.body, file_id, offset); r != nil do return r
		}
	}
	return e
}

find_in_body :: proc(body: [dynamic]Stmt, file_id: u16, offset: u32) -> Expr {
	for stmt in body {
		if r := find_in_stmt(stmt, file_id, offset); r != nil do return r
	}
	return nil
}

find_in_stmt :: proc(stmt: Stmt, file_id: u16, offset: u32) -> Expr {
	if stmt == nil do return nil
	#partial switch s in stmt {
	case ^Return_Stmt:
		return find_expr_at(s.value, file_id, offset)
	case ^Let_Stmt:
		return find_expr_at(s.value, file_id, offset)
	case ^Expr_Stmt:
		return find_expr_at(s.expr, file_id, offset)
	}
	return nil
}

// Верхнеуровневая точка входа: находит Expr в программе по byte offset.
// Сперва находит объемлющий Decl (функцию/метод), затем спускается внутрь.
find_expr_in_program :: proc(prog: Program, file_id: u16, offset: u32) -> Expr {
	for decl in prog.decls {
		if !span_contains(decl_span(decl), file_id, offset) do continue
		#partial switch d in decl {
		case ^Function_Decl:
			return find_in_body(d.body, file_id, offset)
		case ^Impl_Decl:
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

// Для completion: находит объемлющую top-level декларацию (функцию/impl)
// по byte offset — без спуска внутрь тела, в отличие от find_expr_in_program.
find_enclosing_decl :: proc(prog: Program, file_id: u16, offset: u32) -> Decls {
	for decl in prog.decls {
		if span_contains(decl_span(decl), file_id, offset) do return decl
	}
	return nil
}

// --- ЛОКАЛЬНЫЕ СИМВОЛЫ ДЛЯ COMPLETION ---
// Собирает все Let_Stmt-переменные и pattern-биндеры внутри тела функции
// (без учёта позиции курсора — MVP слегка over-suggest'ит: предлагает
// локали из непройденных веток if/match, но не даёт ложных отрицаний).

collect_local_symbols :: proc(res: ^Resolver_Ctx, body: [dynamic]Stmt, out: ^[dynamic]Symbol_Id) {
	for stmt in body {
		collect_local_symbols_stmt(res, stmt, out)
	}
}

collect_local_symbols_stmt :: proc(res: ^Resolver_Ctx, stmt: Stmt, out: ^[dynamic]Symbol_Id) {
	if stmt == nil do return
	#partial switch s in stmt {
	case ^Let_Stmt:
		if sym, ok := res.stmt_symbols[stmt]; ok do append(out, sym)
		collect_local_symbols_expr(res, s.value, out)
	case ^Return_Stmt:
		collect_local_symbols_expr(res, s.value, out)
	case ^Expr_Stmt:
		collect_local_symbols_expr(res, s.expr, out)
	}
}

collect_local_symbols_expr :: proc(res: ^Resolver_Ctx, expr: Expr, out: ^[dynamic]Symbol_Id) {
	if expr == nil do return
	#partial switch e in expr {
	case ^Binary_Expr:
		collect_local_symbols_expr(res, e.left, out)
		collect_local_symbols_expr(res, e.right, out)
	case ^Unary_Expr:
		collect_local_symbols_expr(res, e.right, out)
	case ^Call_Expr:
		collect_local_symbols_expr(res, e.callee, out)
		for arg in e.args do collect_local_symbols_expr(res, arg, out)
	case ^If_Expr:
		collect_local_symbols_expr(res, e.condition, out)
		for s in e.then_branch do collect_local_symbols_stmt(res, s, out)
		for s in e.else_branch do collect_local_symbols_stmt(res, s, out)
	case ^While_Expr:
		collect_local_symbols_expr(res, e.condition, out)
		for s in e.body do collect_local_symbols_stmt(res, s, out)
	case ^Tuple_Expr:
		for el in e.elements do collect_local_symbols_expr(res, el, out)
	case ^Property_Expr:
		collect_local_symbols_expr(res, e.object, out)
	case ^Lambda_Expr:
		if args, ok := res.lambda_args[expr]; ok {
			for a in args do append(out, a)
		}
		for s in e.body do collect_local_symbols_stmt(res, s, out)
	case ^Array_Expr:
		for el in e.elements do collect_local_symbols_expr(res, el, out)
	case ^Map_Expr:
		for entry in e.entries {
			collect_local_symbols_expr(res, entry.key, out)
			collect_local_symbols_expr(res, entry.value, out)
		}
	case ^Index_Expr:
		collect_local_symbols_expr(res, e.object, out)
		collect_local_symbols_expr(res, e.index, out)
	case ^Try_Expr:
		collect_local_symbols_expr(res, e.value, out)
	case ^Match_Expr:
		collect_local_symbols_expr(res, e.subject, out)
		for arm in e.arms {
			collect_pattern_binders(res, arm.pattern, out)
			for s in arm.body do collect_local_symbols_stmt(res, s, out)
		}
	}
}

collect_pattern_binders :: proc(res: ^Resolver_Ctx, pattern: Pattern, out: ^[dynamic]Symbol_Id) {
	switch p in pattern {
	case ^Pattern_Wildcard:
	case ^Pattern_Literal:
	case ^Pattern_Ident:
		if sym, ok := res.pattern_binders[p]; ok do append(out, sym)
	case ^Pattern_Constructor:
		for arg in p.args do collect_pattern_binders(res, arg, out)
	case ^Error_Pattern:
	}
}
