package core

// Selection range (LSP `textDocument/selectionRange`, "Expand/Shrink
// Selection") — цепочка вложенных span'ов от курсора наружу: выражение ->
// объемлющее выражение -> stmt -> тело -> декларация целиком. АСТ без
// parent-указателей (см. тот же компромисс в signature_help.odin), поэтому
// отдельный спуск, собирающий КАЖДЫЙ span на пути, а не только глубочайший
// узел (в отличие от find_expr_at в position.odin).
stmt_span :: proc(stmt: Stmt) -> Span {
	if stmt == nil do return Span{}
	switch s in stmt {
	case ^Return_Stmt:
		return s.span
	case ^Let_Stmt:
		return s.span
	case ^Expr_Stmt:
		return s.span
	case ^Continue_Stmt:
		return s.span
	case ^Break_Stmt:
		return s.span
	case ^Error_Stmt:
		return s.span
	case ^For_In_Stmt:
		return s.span
	}
	return Span{}
}

// Собирает span'ы от объемлющей декларации до самого глубокого узла,
// содержащего offset, В ПОРЯДКЕ СНАРУЖИ ВНУТРЬ (вызывающий разворачивает
// для LSP, которому нужен порядок изнутри наружу — см. lsp/lsp_server.odin).
collect_selection_spans :: proc(prog: Program, file_id: u16, offset: u32) -> [dynamic]Span {
	out := make([dynamic]Span)
	for decl in prog.decls {
		dsp := decl_span(decl)
		if !span_contains(dsp, file_id, offset) do continue
		append(&out, dsp)
		#partial switch d in decl {
		case ^Function_Decl:
			collect_selection_spans_body(d.body, file_id, offset, &out)
		case ^Impl_Decl:
			for m in d.methods {
				if span_contains(m.span, file_id, offset) {
					append(&out, m.span)
					collect_selection_spans_body(m.body, file_id, offset, &out)
					break
				}
			}
		}
		break
	}
	return out
}

collect_selection_spans_body :: proc(body: [dynamic]Stmt, file_id: u16, offset: u32, out: ^[dynamic]Span) {
	for stmt in body {
		sp := stmt_span(stmt)
		if !span_contains(sp, file_id, offset) do continue
		append(out, sp)
		collect_selection_spans_stmt(stmt, file_id, offset, out)
		return
	}
}

collect_selection_spans_stmt :: proc(stmt: Stmt, file_id: u16, offset: u32, out: ^[dynamic]Span) {
	#partial switch s in stmt {
	case ^Return_Stmt:
		collect_selection_spans_expr(s.value, file_id, offset, out)
	case ^Let_Stmt:
		collect_selection_spans_expr(s.value, file_id, offset, out)
	case ^Expr_Stmt:
		collect_selection_spans_expr(s.expr, file_id, offset, out)
	case ^For_In_Stmt:
		if span_contains(expr_span(s.iterable), file_id, offset) {
			append(out, expr_span(s.iterable))
			collect_selection_spans_expr(s.iterable, file_id, offset, out)
			return
		}
		collect_selection_spans_body(s.body, file_id, offset, out)
	}
}

collect_selection_spans_expr :: proc(e: Expr, file_id: u16, offset: u32, out: ^[dynamic]Span) {
	if e == nil do return
	if !span_contains(expr_span(e), file_id, offset) do return
	append(out, expr_span(e))

	#partial switch v in e {
	case ^Binary_Expr:
		if span_contains(expr_span(v.left), file_id, offset) {
			collect_selection_spans_expr(v.left, file_id, offset, out)
		} else {
			collect_selection_spans_expr(v.right, file_id, offset, out)
		}
	case ^Unary_Expr:
		collect_selection_spans_expr(v.right, file_id, offset, out)
	case ^Call_Expr:
		for arg in v.args {
			if span_contains(expr_span(arg), file_id, offset) {
				collect_selection_spans_expr(arg, file_id, offset, out)
				return
			}
		}
		collect_selection_spans_expr(v.callee, file_id, offset, out)
	case ^If_Expr:
		if span_contains(expr_span(v.condition), file_id, offset) {
			collect_selection_spans_expr(v.condition, file_id, offset, out)
			return
		}
		collect_selection_spans_body(v.then_branch, file_id, offset, out)
		collect_selection_spans_body(v.else_branch, file_id, offset, out)
	case ^While_Expr:
		if span_contains(expr_span(v.condition), file_id, offset) {
			collect_selection_spans_expr(v.condition, file_id, offset, out)
			return
		}
		collect_selection_spans_body(v.body, file_id, offset, out)
	case ^Tuple_Expr:
		for el in v.elements {
			if span_contains(expr_span(el), file_id, offset) {
				collect_selection_spans_expr(el, file_id, offset, out)
				return
			}
		}
	case ^Property_Expr:
		collect_selection_spans_expr(v.object, file_id, offset, out)
	case ^Lambda_Expr:
		collect_selection_spans_body(v.body, file_id, offset, out)
	case ^Array_Expr:
		for el in v.elements {
			if span_contains(expr_span(el), file_id, offset) {
				collect_selection_spans_expr(el, file_id, offset, out)
				return
			}
		}
	case ^Map_Expr:
		for entry in v.entries {
			if span_contains(expr_span(entry.key), file_id, offset) {
				collect_selection_spans_expr(entry.key, file_id, offset, out)
				return
			}
			if span_contains(expr_span(entry.value), file_id, offset) {
				collect_selection_spans_expr(entry.value, file_id, offset, out)
				return
			}
		}
	case ^Index_Expr:
		if span_contains(expr_span(v.object), file_id, offset) {
			collect_selection_spans_expr(v.object, file_id, offset, out)
			return
		}
		collect_selection_spans_expr(v.index, file_id, offset, out)
	case ^Try_Expr:
		collect_selection_spans_expr(v.value, file_id, offset, out)
	case ^Match_Expr:
		if span_contains(expr_span(v.subject), file_id, offset) {
			collect_selection_spans_expr(v.subject, file_id, offset, out)
			return
		}
		for arm in v.arms {
			collect_selection_spans_body(arm.body, file_id, offset, out)
		}
	}
}
