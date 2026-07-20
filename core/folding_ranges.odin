package core

// Folding ranges (LSP `textDocument/foldingRange`) — чисто синтаксическая
// фича: любой блок с телом ("...конец" или ветка if/while/match/lambda),
// растянутый больше чем на одну строку, складывается в свёрнутую область.
// Не нужен ни резолвер, ни граф модулей — Program уже содержит только
// декларации ОДНОГО файла (см. Program.decls), в отличие от resolver'а,
// который видит весь граф импортов.
Fold_Range :: struct {
	span: Span,
}

compute_folding_ranges :: proc(prog: Program) -> [dynamic]Fold_Range {
	ranges := make([dynamic]Fold_Range)
	for decl in prog.decls {
		collect_fold_ranges_decl(decl, &ranges)
	}
	return ranges
}

collect_fold_ranges_decl :: proc(decl: Decls, out: ^[dynamic]Fold_Range) {
	if decl == nil do return
	#partial switch d in decl {
	case ^Function_Decl:
		append(out, Fold_Range{span = d.span})
		collect_fold_ranges_body(d.body, out)
	case ^Struct_Decl:
		append(out, Fold_Range{span = d.span})
	case ^Enum_Decl:
		append(out, Fold_Range{span = d.span})
	case ^Interface_Decl:
		append(out, Fold_Range{span = d.span})
	case ^Impl_Decl:
		append(out, Fold_Range{span = d.span})
		for m in d.methods {
			append(out, Fold_Range{span = m.span})
			collect_fold_ranges_body(m.body, out)
		}
	case ^Foreign_Decl:
		append(out, Fold_Range{span = d.span})
	}
}

collect_fold_ranges_body :: proc(body: [dynamic]Stmt, out: ^[dynamic]Fold_Range) {
	for stmt in body {
		collect_fold_ranges_stmt(stmt, out)
	}
}

collect_fold_ranges_stmt :: proc(stmt: Stmt, out: ^[dynamic]Fold_Range) {
	if stmt == nil do return
	#partial switch s in stmt {
	case ^Return_Stmt:
		collect_fold_ranges_expr(s.value, out)
	case ^Let_Stmt:
		collect_fold_ranges_expr(s.value, out)
	case ^Expr_Stmt:
		collect_fold_ranges_expr(s.expr, out)
	case ^For_In_Stmt:
		append(out, Fold_Range{span = s.span})
		collect_fold_ranges_expr(s.iterable, out)
		collect_fold_ranges_body(s.body, out)
	}
}

collect_fold_ranges_expr :: proc(expr: Expr, out: ^[dynamic]Fold_Range) {
	if expr == nil do return
	#partial switch e in expr {
	case ^Binary_Expr:
		collect_fold_ranges_expr(e.left, out)
		collect_fold_ranges_expr(e.right, out)
	case ^Unary_Expr:
		collect_fold_ranges_expr(e.right, out)
	case ^Call_Expr:
		collect_fold_ranges_expr(e.callee, out)
		for arg in e.args do collect_fold_ranges_expr(arg, out)
	case ^If_Expr:
		append(out, Fold_Range{span = e.span})
		collect_fold_ranges_expr(e.condition, out)
		collect_fold_ranges_body(e.then_branch, out)
		collect_fold_ranges_body(e.else_branch, out)
	case ^While_Expr:
		append(out, Fold_Range{span = e.span})
		collect_fold_ranges_expr(e.condition, out)
		collect_fold_ranges_body(e.body, out)
	case ^Tuple_Expr:
		for el in e.elements do collect_fold_ranges_expr(el, out)
	case ^Property_Expr:
		collect_fold_ranges_expr(e.object, out)
	case ^Lambda_Expr:
		append(out, Fold_Range{span = e.span})
		collect_fold_ranges_body(e.body, out)
	case ^Array_Expr:
		for el in e.elements do collect_fold_ranges_expr(el, out)
	case ^Map_Expr:
		for entry in e.entries {
			collect_fold_ranges_expr(entry.key, out)
			collect_fold_ranges_expr(entry.value, out)
		}
	case ^Index_Expr:
		collect_fold_ranges_expr(e.object, out)
		collect_fold_ranges_expr(e.index, out)
	case ^Try_Expr:
		collect_fold_ranges_expr(e.value, out)
	case ^Match_Expr:
		append(out, Fold_Range{span = e.span})
		collect_fold_ranges_expr(e.subject, out)
		for arm in e.arms {
			collect_fold_ranges_body(arm.body, out)
		}
	}
}
