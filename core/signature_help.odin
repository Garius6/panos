package core

// Signature help (LSP `textDocument/signatureHelp`) — находит ОХВАТЫВАЮЩИЙ
// Call_Expr вокруг курсора (АСТ без parent-указателей, поэтому отдельный
// проход — не переиспользовать find_expr_at из position.odin, той нужен
// САМЫЙ ГЛУБОКИЙ узел, а не ближайший Call_Expr), затем достаёт тип callee
// (уже посчитан тайпчекером) и имена параметров через Symbol.decl
// (Function_Decl.args) — как и hover, см. lsp/lsp_server.odin::handle_hover.
Signature_Param :: struct {
	name:      string,
	type_name: string,
}

Signature_Info :: struct {
	params:       []Signature_Param,
	return_type:  string,
	active_param: int,
}

compute_signature_help :: proc(
	res: ^Resolver_Ctx,
	tc: ^Type_Ctx,
	prog: Program,
	file_id: u16,
	offset: u32,
) -> (
	info: Signature_Info,
	ok: bool,
) {
	call := find_enclosing_call_in_program(prog, file_id, offset)
	if call == nil do return {}, false

	callee_type, has_type := tc.node_types[call.callee]
	if !has_type || callee_type == nil || callee_type.kind != .Function do return {}, false

	param_names: [dynamic]string
	if sym_id, has_sym := res.node_symbols[call.callee]; has_sym && sym_id != INVALID_SYMBOL {
		sym := symbol_at(res.symbol_store, sym_id)
		if fd, is_fn := sym.decl.(^Function_Decl); is_fn {
			for a in fd.args do append(&param_names, a.name)
		}
	}

	params := make([]Signature_Param, len(callee_type.params))
	for t, i in callee_type.params {
		name := i < len(param_names) ? param_names[i] : ""
		params[i] = Signature_Param{name = name, type_name = prune_type(t).name}
	}

	active := 0
	for arg in call.args {
		if expr_span(arg).end <= offset do active += 1
	}
	if len(params) > 0 && active >= len(params) do active = len(params) - 1

	return Signature_Info{params = params, return_type = prune_type(callee_type.return_type).name, active_param = active}, true
}

find_enclosing_call_in_program :: proc(prog: Program, file_id: u16, offset: u32) -> ^Call_Expr {
	for decl in prog.decls {
		if !span_contains(decl_span(decl), file_id, offset) do continue
		#partial switch d in decl {
		case ^Function_Decl:
			return find_call_in_body(d.body, file_id, offset)
		case ^Impl_Decl:
			for m in d.methods {
				if span_contains(m.span, file_id, offset) {
					return find_call_in_body(m.body, file_id, offset)
				}
			}
		}
		return nil
	}
	return nil
}

find_call_in_body :: proc(body: [dynamic]Stmt, file_id: u16, offset: u32) -> ^Call_Expr {
	for stmt in body {
		if r := find_call_in_stmt(stmt, file_id, offset); r != nil do return r
	}
	return nil
}

find_call_in_stmt :: proc(stmt: Stmt, file_id: u16, offset: u32) -> ^Call_Expr {
	if stmt == nil do return nil
	#partial switch s in stmt {
	case ^Return_Stmt:
		return find_call_in_expr(s.value, file_id, offset)
	case ^Let_Stmt:
		return find_call_in_expr(s.value, file_id, offset)
	case ^Expr_Stmt:
		return find_call_in_expr(s.expr, file_id, offset)
	case ^For_In_Stmt:
		if r := find_call_in_expr(s.iterable, file_id, offset); r != nil do return r
		return find_call_in_body(s.body, file_id, offset)
	}
	return nil
}

// Спускается СНАЧАЛА в аргументы (более вложенный Call_Expr внутри
// аргумента — если курсор там, нужен ОН, а не внешний вызов), иначе
// падает обратно на сам v, если это Call_Expr и он охватывает offset.
find_call_in_expr :: proc(e: Expr, file_id: u16, offset: u32) -> ^Call_Expr {
	if e == nil do return nil
	if !span_contains(expr_span(e), file_id, offset) do return nil

	#partial switch v in e {
	case ^Call_Expr:
		for arg in v.args {
			if r := find_call_in_expr(arg, file_id, offset); r != nil do return r
		}
		if r := find_call_in_expr(v.callee, file_id, offset); r != nil do return r
		return v
	case ^Binary_Expr:
		if r := find_call_in_expr(v.left, file_id, offset); r != nil do return r
		return find_call_in_expr(v.right, file_id, offset)
	case ^Unary_Expr:
		return find_call_in_expr(v.right, file_id, offset)
	case ^If_Expr:
		if r := find_call_in_expr(v.condition, file_id, offset); r != nil do return r
		if r := find_call_in_body(v.then_branch, file_id, offset); r != nil do return r
		return find_call_in_body(v.else_branch, file_id, offset)
	case ^While_Expr:
		if r := find_call_in_expr(v.condition, file_id, offset); r != nil do return r
		return find_call_in_body(v.body, file_id, offset)
	case ^Tuple_Expr:
		for el in v.elements {
			if r := find_call_in_expr(el, file_id, offset); r != nil do return r
		}
	case ^Property_Expr:
		return find_call_in_expr(v.object, file_id, offset)
	case ^Lambda_Expr:
		return find_call_in_body(v.body, file_id, offset)
	case ^Array_Expr:
		for el in v.elements {
			if r := find_call_in_expr(el, file_id, offset); r != nil do return r
		}
	case ^Map_Expr:
		for entry in v.entries {
			if r := find_call_in_expr(entry.key, file_id, offset); r != nil do return r
			if r := find_call_in_expr(entry.value, file_id, offset); r != nil do return r
		}
	case ^Index_Expr:
		if r := find_call_in_expr(v.object, file_id, offset); r != nil do return r
		return find_call_in_expr(v.index, file_id, offset)
	case ^Try_Expr:
		return find_call_in_expr(v.value, file_id, offset)
	case ^Match_Expr:
		if r := find_call_in_expr(v.subject, file_id, offset); r != nil do return r
		for arm in v.arms {
			if r := find_call_in_body(arm.body, file_id, offset); r != nil do return r
		}
	}
	return nil
}
