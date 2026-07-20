package core

// Bounded traits (мономорфизация, см. core/monomorphize.odin): тело
// bounded generic-функции компилируется ОТДЕЛЬНО на каждую конкретную
// комбинацию type-параметров, встреченную на call site'ах. `ctx.
// node_types`/`ctx.call_infos` в typechecker'е ключуются ПО УКАЗАТЕЛЮ
// AST-узла — повторный typecheck ТЕХ ЖЕ узлов с разным T перезаписал бы
// результат предыдущей инстанциации. Решение — клонировать тело перед
// каждой инстанциацией и гонять по клону обычный resolve→typecheck→
// compile (клон с T, зарезолвленным в конкретный тип, неотличим от
// обычной non-generic функции — ни один из этих трёх пайплайнов не
// меняется). Span копируется как есть — диагностики на клоне указывают
// на позицию в ОРИГИНАЛЬНОМ исходнике, что и нужно для сообщений об
// ошибках.

clone_type_node :: proc(n: Type_Node) -> Type_Node {
	if n == nil do return nil
	switch v in n {
	case ^Type_Ident:
		c := new(Type_Ident)
		c.span = v.span
		c.name = v.name
		return c
	case ^Type_Tuple:
		c := new(Type_Tuple)
		c.span = v.span
		c.elements = make([dynamic]Type_Node)
		for el in v.elements do append(&c.elements, clone_type_node(el))
		return c
	case ^Type_Function:
		c := new(Type_Function)
		c.span = v.span
		c.params = make([dynamic]Type_Node)
		for p in v.params do append(&c.params, clone_type_node(p))
		c.return_type = clone_type_node(v.return_type)
		return c
	case ^Type_Qualified:
		c := new(Type_Qualified)
		c.span = v.span
		c.module_name = v.module_name
		c.name = v.name
		return c
	case ^Type_Generic:
		c := new(Type_Generic)
		c.span = v.span
		c.name = v.name
		c.params = make([dynamic]Type_Node)
		for p in v.params do append(&c.params, clone_type_node(p))
		return c
	case ^Error_Type_Node:
		c := new(Error_Type_Node)
		c.span = v.span
		return c
	}
	return nil
}

clone_param_decl :: proc(p: Param_Decl) -> Param_Decl {
	return Param_Decl{span = p.span, name = p.name, type_annotation = clone_type_node(p.type_annotation)}
}

clone_param_list :: proc(params: [dynamic]Param_Decl) -> [dynamic]Param_Decl {
	c := make([dynamic]Param_Decl)
	for p in params do append(&c, clone_param_decl(p))
	return c
}

clone_pattern :: proc(p: Pattern) -> Pattern {
	if p == nil do return nil
	switch v in p {
	case ^Pattern_Wildcard:
		c := new(Pattern_Wildcard)
		c.span = v.span
		return c
	case ^Pattern_Literal:
		c := new(Pattern_Literal)
		c.span = v.span
		c.value = clone_expr(v.value)
		return c
	case ^Pattern_Ident:
		c := new(Pattern_Ident)
		c.span = v.span
		c.name = v.name
		return c
	case ^Pattern_Constructor:
		c := new(Pattern_Constructor)
		c.span = v.span
		c.module_name = v.module_name
		c.name = v.name
		c.args = make([dynamic]Pattern)
		for a in v.args do append(&c.args, clone_pattern(a))
		return c
	case ^Error_Pattern:
		c := new(Error_Pattern)
		c.span = v.span
		return c
	}
	return nil
}

clone_match_arm :: proc(a: Match_Arm) -> Match_Arm {
	c := Match_Arm{span = a.span, pattern = clone_pattern(a.pattern), body = make([dynamic]Stmt)}
	for s in a.body do append(&c.body, clone_stmt(s))
	return c
}

clone_expr :: proc(e: Expr) -> Expr {
	if e == nil do return nil
	switch v in e {
	case ^Number_Expr:
		c := new(Number_Expr)
		c.span = v.span
		c.value = v.value
		return c
	case ^Boolean_Expr:
		c := new(Boolean_Expr)
		c.span = v.span
		c.value = v.value
		return c
	case ^String_Expr:
		c := new(String_Expr)
		c.span = v.span
		c.value = v.value
		return c
	case ^Binary_Expr:
		c := new(Binary_Expr)
		c.span = v.span
		c.left = clone_expr(v.left)
		c.op = v.op
		c.right = clone_expr(v.right)
		return c
	case ^Unary_Expr:
		c := new(Unary_Expr)
		c.span = v.span
		c.op = v.op
		c.right = clone_expr(v.right)
		return c
	case ^Ident_Expr:
		c := new(Ident_Expr)
		c.span = v.span
		c.name = v.name
		return c
	case ^Call_Expr:
		c := new(Call_Expr)
		c.span = v.span
		c.callee = clone_expr(v.callee)
		c.args = make([dynamic]Expr)
		for a in v.args do append(&c.args, clone_expr(a))
		return c
	case ^While_Expr:
		c := new(While_Expr)
		c.span = v.span
		c.condition = clone_expr(v.condition)
		c.body = make([dynamic]Stmt)
		for s in v.body do append(&c.body, clone_stmt(s))
		return c
	case ^If_Expr:
		c := new(If_Expr)
		c.span = v.span
		c.condition = clone_expr(v.condition)
		c.then_branch = make([dynamic]Stmt)
		for s in v.then_branch do append(&c.then_branch, clone_stmt(s))
		c.else_branch = make([dynamic]Stmt)
		for s in v.else_branch do append(&c.else_branch, clone_stmt(s))
		return c
	case ^Tuple_Expr:
		c := new(Tuple_Expr)
		c.span = v.span
		c.elements = make([dynamic]Expr)
		for el in v.elements do append(&c.elements, clone_expr(el))
		return c
	case ^Property_Expr:
		c := new(Property_Expr)
		c.span = v.span
		c.object = clone_expr(v.object)
		c.property = v.property
		return c
	case ^Lambda_Expr:
		c := new(Lambda_Expr)
		c.span = v.span
		c.args = clone_param_list(v.args)
		c.return_type = clone_type_node(v.return_type)
		c.body = make([dynamic]Stmt)
		for s in v.body do append(&c.body, clone_stmt(s))
		return c
	case ^Array_Expr:
		c := new(Array_Expr)
		c.span = v.span
		c.elements = make([dynamic]Expr)
		for el in v.elements do append(&c.elements, clone_expr(el))
		return c
	case ^Map_Expr:
		c := new(Map_Expr)
		c.span = v.span
		c.entries = make([dynamic]Map_Entry_Expr)
		for entry in v.entries {
			append(
				&c.entries,
				Map_Entry_Expr{span = entry.span, key = clone_expr(entry.key), value = clone_expr(entry.value)},
			)
		}
		return c
	case ^Index_Expr:
		c := new(Index_Expr)
		c.span = v.span
		c.object = clone_expr(v.object)
		c.index = clone_expr(v.index)
		return c
	case ^Try_Expr:
		c := new(Try_Expr)
		c.span = v.span
		c.value = clone_expr(v.value)
		return c
	case ^Match_Expr:
		c := new(Match_Expr)
		c.span = v.span
		c.subject = clone_expr(v.subject)
		c.arms = make([dynamic]Match_Arm)
		for a in v.arms do append(&c.arms, clone_match_arm(a))
		return c
	case ^Error_Expr:
		c := new(Error_Expr)
		c.span = v.span
		return c
	case ^Spawn_Expr:
		c := new(Spawn_Expr)
		c.span = v.span
		c.call = clone_expr(v.call).(^Call_Expr)
		return c
	}
	return nil
}

clone_stmt :: proc(s: Stmt) -> Stmt {
	if s == nil do return nil
	switch v in s {
	case ^Return_Stmt:
		c := new(Return_Stmt)
		c.span = v.span
		c.value = clone_expr(v.value)
		return c
	case ^Let_Stmt:
		c := new(Let_Stmt)
		c.span = v.span
		c.name = v.name
		c.value = clone_expr(v.value)
		c.type_annotation = clone_type_node(v.type_annotation)
		c.is_const = v.is_const
		c.names = make([dynamic]string)
		for n in v.names do append(&c.names, n)
		c.destructure_type = v.destructure_type
		return c
	case ^Expr_Stmt:
		c := new(Expr_Stmt)
		c.span = v.span
		c.expr = clone_expr(v.expr)
		return c
	case ^Continue_Stmt:
		c := new(Continue_Stmt)
		c.span = v.span
		return c
	case ^Break_Stmt:
		c := new(Break_Stmt)
		c.span = v.span
		return c
	case ^Error_Stmt:
		c := new(Error_Stmt)
		c.span = v.span
		return c
	case ^For_In_Stmt:
		c := new(For_In_Stmt)
		c.span = v.span
		c.names = make([dynamic]string)
		for n in v.names do append(&c.names, n)
		c.iterable = clone_expr(v.iterable)
		c.body = make([dynamic]Stmt)
		for st in v.body do append(&c.body, clone_stmt(st))
		return c
	}
	return nil
}

// Клонирует сигнатуру (args/return_type) и тело — всё, что нужно
// мономорфизации, чтобы прогнать клон через обычный resolve→typecheck→
// compile независимо от шаблона. type_params/type_param_bounds НЕ
// клонируются — клон типизируется с T, УЖЕ подставленным в конкретный
// тип (см. monomorphize.odin), новых type-параметров у него нет.
clone_function_decl :: proc(d: ^Function_Decl) -> ^Function_Decl {
	c := new(Function_Decl)
	c.span = d.span
	c.name = d.name
	c.name_span = d.name_span
	c.args = clone_param_list(d.args)
	c.return_type = clone_type_node(d.return_type)
	c.body = make([dynamic]Stmt)
	for s in d.body do append(&c.body, clone_stmt(s))
	c.is_exported = d.is_exported
	return c
}
