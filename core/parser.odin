package core

import "core:fmt"
import "core:strconv"

Parser :: struct {
	stream:      ^TokenStream,
	file_id:     u16,
	// Diagnostic/Severity определены в type_cheker.odin (тот же package) —
	// переиспользуем ту же модель accumulate-not-panic, что и там (TY_POISON).
	diagnostics: [dynamic]Diagnostic,
	// Монотонный счётчик для gensym-имён синтетических переменных
	// для-in-раскрытия (см. parse_for_stmt_into) — __for_1_idx, __for_2_idx,
	// ... Уникальности в пределах файла достаточно (разные функции и так не
	// делят scope), сбрасывать между функциями не нужно.
	for_counter: int,
}

// Аналог report() из type_cheker.odin: копит diagnostic вместо panic,
// дедуп по (span, message) — та же логика, что для type-диагностик.
report_parse :: proc(p: ^Parser, span: Span, format: string, args: ..any) {
	msg := fmt.aprintf(format, ..args)
	for d in p.diagnostics {
		if d.span == span && d.message == msg do return
	}
	append(&p.diagnostics, Diagnostic{severity = .Error, span = span, message = msg})
}

// Токены, с которых безопасно возобновить разбор после неразрешимой
// ошибки — начало новой top-level декларации или конец файла. Используется
// только в местах, где ошибка обнаруживается БЕЗ предварительного
// потребления токена (иначе гарантированный прогресс уже есть и skip не
// нужен) — см. комментарии на местах вызова.
is_sync_token :: proc(kind: TokenKind) -> bool {
	#partial switch kind {
	case .Function, .TypeDecl, .Impl, .Import, .Export, .End, .EOF:
		return true
	}
	return false
}

skip_to_sync :: proc(p: ^Parser) {
	for {
		tok := peek_token(p.stream)
		if tok == nil || is_sync_token(tok.kind) do return
		next_token(p.stream)
	}
}

Parser_Error :: enum {
	Cannot,
}

Function_Decl :: struct {
	span:        Span,
	name:        string,
	args:        [dynamic]Param_Decl,
	return_type: Type_Node,
	body:        [dynamic]Stmt,
	is_exported: bool,
}

Param_Decl :: struct {
	span:            Span,
	name:            string,
	type_annotation: Type_Node,
}

Method_Signature :: struct {
	span:        Span,
	name:        string,
	args:        [dynamic]Param_Decl,
	return_type: Type_Node,
}

Interface_Decl :: struct {
	span:        Span,
	name:        string,
	methods:     [dynamic]Method_Signature,
	is_exported: bool,
}

Field_Decl :: struct {
	span:            Span,
	name:            string,
	type_annotation: Type_Node,
}

Struct_Decl :: struct {
	span:        Span,
	name:        string,
	fields:      [dynamic]Field_Decl,
	is_exported: bool,
}

Import_Decl :: struct {
	span:  Span,
	path:  string,
	alias: string,
}

Variant_Decl :: struct {
	span:  Span,
	name:  string,
	types: [dynamic]Type_Node,
}

Enum_Decl :: struct {
	span:        Span,
	name:        string,
	variants:    [dynamic]Variant_Decl,
	is_exported: bool,
}

Impl_Decl :: struct {
	span:           Span,
	interface_name: string,
	target_type:    string,
	methods:        [dynamic]^Function_Decl,
}

// Placeholder-узел ("hole"): парсер не смог разобрать конструкцию на этом
// месте (например top-level мусор), но должен продолжить разбор остального
// файла вместо panic. Несёт только span для diagnostic'а; резолвер/тайпчекер
// трактуют его как уже отрапортованную ошибку (см. TY_POISON) и не
// каскадируют вторичные диагностики.
Error_Decl :: struct {
	span: Span,
}

Decls :: union {
	^Import_Decl,
	^Function_Decl,
	^Struct_Decl,
	^Impl_Decl,
	^Interface_Decl,
	^Enum_Decl,
	^Error_Decl,
}

Program :: struct {
	decls: [dynamic]Decls,
}

Type_Generic :: struct {
	span:   Span,
	name:   string,
	params: [dynamic]Type_Node,
}

Type_Qualified :: struct {
	span:        Span,
	module_name: string,
	name:        string,
}

Error_Type_Node :: struct {
	span: Span,
}

Type_Node :: union {
	^Type_Ident,
	^Type_Tuple,
	^Type_Function,
	^Type_Qualified,
	^Type_Generic, // Заменяет Type_Array и Type_Map
	^Error_Type_Node,
}

Type_Function :: struct {
	span:        Span,
	params:      [dynamic]Type_Node,
	return_type: Type_Node,
}

Type_Ident :: struct {
	span: Span,
	name: string,
}

Type_Tuple :: struct {
	span:     Span,
	elements: [dynamic]Type_Node,
}

Error_Stmt :: struct {
	span: Span,
}

Stmt :: union {
	^Return_Stmt,
	^Let_Stmt,
	^Expr_Stmt,
	^Continue_Stmt,
	^Break_Stmt,
	^Error_Stmt,
}

Return_Stmt :: struct {
	span:  Span,
	value: Expr,
}

Let_Stmt :: struct {
	span:            Span,
	name:            string,
	value:           Expr,
	type_annotation: Type_Node,
}

Expr_Stmt :: struct {
	span: Span,
	expr: Expr,
}

Continue_Stmt :: struct {
	span: Span,
}

Break_Stmt :: struct {
	span: Span,
}

Pattern_Wildcard :: struct {
	span: Span,
}
Pattern_Literal :: struct {
	span:  Span,
	value: Expr,
}
Pattern_Ident :: struct {
	span: Span,
	name: string,
}
Pattern_Constructor :: struct {
	span:        Span,
	module_name: string,
	name:        string,
	args:        [dynamic]Pattern,
}

Error_Pattern :: struct {
	span: Span,
}

Pattern :: union {
	^Pattern_Wildcard,
	^Pattern_Literal,
	^Pattern_Ident,
	^Pattern_Constructor,
	^Error_Pattern,
}

Match_Arm :: struct {
	span:    Span,
	pattern: Pattern,
	body:    [dynamic]Stmt,
}

Match_Expr :: struct {
	span:    Span,
	subject: Expr,
	arms:    [dynamic]Match_Arm,
}

Ident_Expr :: struct {
	span: Span,
	name: Interned,
}

Unary_Expr :: struct {
	span:  Span,
	op:    TokenKind,
	right: Expr,
}

Number_Expr :: struct {
	span:  Span,
	value: f64,
}

Boolean_Expr :: struct {
	span:  Span,
	value: bool,
}

String_Expr :: struct {
	span:  Span,
	value: string,
}

Binary_Expr :: struct {
	span:  Span,
	left:  Expr,
	op:    TokenKind, // Теперь может быть .Assign (=)
	right: Expr,
}

Call_Expr :: struct {
	span:   Span,
	args:   [dynamic]Expr,
	callee: Expr,
}

Property_Expr :: struct {
	span:     Span,
	object:   Expr,
	property: string,
}

If_Expr :: struct {
	span:        Span,
	condition:   Expr,
	then_branch: [dynamic]Stmt,
	else_branch: [dynamic]Stmt,
}

While_Expr :: struct {
	span:      Span,
	condition: Expr,
	body:      [dynamic]Stmt,
}

Tuple_Expr :: struct {
	span:     Span,
	elements: [dynamic]Expr,
}

Lambda_Expr :: struct {
	span:        Span,
	args:        [dynamic]Param_Decl,
	return_type: Type_Node,
	body:        [dynamic]Stmt,
}

Array_Expr :: struct {
	span:     Span,
	elements: [dynamic]Expr,
}

Map_Entry_Expr :: struct {
	span:  Span,
	key:   Expr,
	value: Expr,
}

Map_Expr :: struct {
	span:    Span,
	entries: [dynamic]Map_Entry_Expr,
}

Index_Expr :: struct {
	span:   Span,
	object: Expr,
	index:  Expr,
}

Try_Expr :: struct {
	span:  Span,
	value: Expr,
}

Error_Expr :: struct {
	span: Span,
}

Expr :: union {
	^Number_Expr,
	^Boolean_Expr,
	^String_Expr,
	^Binary_Expr,
	^Unary_Expr,
	^Ident_Expr,
	^Call_Expr,
	^While_Expr,
	^If_Expr,
	^Tuple_Expr,
	^Property_Expr,
	^Lambda_Expr,
	^Array_Expr,
	^Map_Expr,
	^Index_Expr,
	^Try_Expr,
	^Match_Expr,
	^Error_Expr,
}

// --- ПЕЧАТЬ AST ---

print_program :: proc(prog: Program) {
	fmt.println("Program")
	for decl in prog.decls {
		print_decl(decl)
	}
}

print_decl :: proc(decl: Decls) {
	#partial switch d in decl {
	case ^Import_Decl:
		if d.alias != "" {
			fmt.printf("Import (%s as %s)\n", d.path, d.alias)
		} else {
			fmt.printf("Import (%s)\n", d.path)
		}
	case ^Function_Decl:
		fmt.printf("%sFunction (%s)\n", d.is_exported ? "Export " : "", d.name)
		for stmt, i in d.body {
			is_last := i == len(d.body) - 1
			print_stmt(stmt, "", is_last)
		}
	case ^Struct_Decl:
		fmt.printf("%sStruct (%s)\n", d.is_exported ? "Export " : "", d.name)
		for field, i in d.fields {
			is_last := i == len(d.fields) - 1
			print_field(field, "", is_last)
		}
	case ^Impl_Decl:
		fmt.printf("Impl (%s)\n", d.target_type)
	case ^Interface_Decl:
		fmt.printf("%sInterface (%s)\n", d.is_exported ? "Export " : "", d.name)
	}
}

print_field :: proc(field: Field_Decl, prefix: string = "", is_last: bool = true) {
	marker := is_last ? "└── " : "├── "
	fmt.printf("%s%sField(%s)\n", prefix, marker, field.name)
}

print_stmt :: proc(stmt: Stmt, prefix: string = "", is_last: bool = true) {
	if stmt == nil do return

	marker := is_last ? "└── " : "├── "
	next_prefix := fmt.tprintf("%s%s", prefix, is_last ? "    " : "│   ")

	switch s in stmt {
	case ^Let_Stmt:
		fmt.printf("%s%sLet(%s)\n", prefix, marker, s.name)
		print_ast(s.value, next_prefix, true)

	case ^Return_Stmt:
		fmt.printf("%s%sReturn\n", prefix, marker)
		if s.value != nil {
			print_ast(s.value, next_prefix, true)
		}

	case ^Expr_Stmt:
		fmt.printf("%s%sExpr_Stmt\n", prefix, marker)
		print_ast(s.expr, next_prefix, true)

	case ^Continue_Stmt:
		fmt.printf("%s%sContinue\n", prefix, marker)

	case ^Break_Stmt:
		fmt.printf("%s%sBreak\n", prefix, marker)

	case ^Error_Stmt:
		fmt.printf("%s%s<parse error>\n", prefix, marker)
	}
}

print_ast :: proc(expr: Expr, prefix: string = "", is_last: bool = true) {
	if expr == nil do return

	marker := is_last ? "└── " : "├── "
	next_prefix_base := is_last ? "    " : "│   "
	next_prefix := fmt.tprintf("%s%s", prefix, next_prefix_base)

	#partial switch e in expr {
	case ^Number_Expr:
		fmt.printf("%s%sNumber(%v)\n", prefix, marker, e.value)
	case ^Boolean_Expr:
		fmt.printf("%s%sBoolean(%v)\n", prefix, marker, e.value)
	case ^String_Expr:
		fmt.printf("%s%sString(\"%s\")\n", prefix, marker, e.value)
	case ^Unary_Expr:
		fmt.printf("%s%sUnary(%v)\n", prefix, marker, e.op)
		print_ast(e.right, next_prefix, true)
	case ^Binary_Expr:
		fmt.printf("%s%sBinary(%v)\n", prefix, marker, e.op)
		print_ast(e.left, next_prefix, false)
		print_ast(e.right, next_prefix, true)
	case ^Ident_Expr:
		fmt.printf("%s%sIdent(%v)\n", prefix, marker, resolve_interned(e.name))
	case ^Call_Expr:
		fmt.printf("%s%sCall()\n", prefix, marker)
		print_ast(e.callee, next_prefix, false)
		for arg, i in e.args {
			print_ast(arg, next_prefix, i == len(e.args) - 1)
		}
	case ^While_Expr:
		fmt.printf("%s%sWhile()\n", prefix, marker)
		print_ast(e.condition, next_prefix, false)
		for stmt, i in e.body {
			print_stmt(stmt, next_prefix, i == len(e.body) - 1)
		}
	case ^If_Expr:
		fmt.printf("%s%sIf()\n", prefix, marker)
		print_ast(e.condition, next_prefix, false)
		for stmt in e.then_branch {
			print_stmt(stmt, next_prefix, false)
		}
		for stmt, i in e.else_branch {
			print_stmt(stmt, next_prefix, i == len(e.else_branch) - 1)
		}
	case ^Tuple_Expr:
		fmt.printf("%s%sTuple()\n", prefix, marker)
		for el, i in e.elements {
			print_ast(el, next_prefix, i == len(e.elements) - 1)
		}
	case ^Property_Expr:
		fmt.printf("%s%sProperty(%s)\n", prefix, marker, e.property)
		print_ast(e.object, next_prefix, true)
	case ^Lambda_Expr:
		fmt.printf("%s%sLambda()\n", prefix, marker)
		for stmt, i in e.body {
			print_stmt(stmt, next_prefix, i == len(e.body) - 1)
		}
	case ^Array_Expr:
		fmt.printf("%s%sArray()\n", prefix, marker)
		for el, i in e.elements {
			print_ast(el, next_prefix, i == len(e.elements) - 1)
		}
	case ^Map_Expr:
		fmt.printf("%s%sMap()\n", prefix, marker)
		for entry, i in e.entries {
			entry_marker := i == len(e.entries) - 1 ? "└── " : "├── "
			entry_prefix := fmt.tprintf(
				"%s%s",
				next_prefix,
				i == len(e.entries) - 1 ? "    " : "│   ",
			)
			fmt.printf("%s%sEntry\n", next_prefix, entry_marker)
			print_ast(entry.key, entry_prefix, false)
			print_ast(entry.value, entry_prefix, true)
		}
	case ^Index_Expr:
		fmt.printf("%s%sIndex()\n", prefix, marker)
		print_ast(e.object, next_prefix, false)
		print_ast(e.index, next_prefix, true)
	case ^Try_Expr:
		fmt.printf("%s%sTry(?)\n", prefix, marker)
		print_ast(e.value, next_prefix, true)
	}
}

// --- ПАРСИНГ ВЕРХНЕГО УРОВНЯ ---

parse_program :: proc(p: ^Parser) -> Program {
	prog := Program {
		decls = make([dynamic]Decls),
	}

	for peek_token(p.stream).kind != .EOF {
		is_exported := false
		if peek_token(p.stream).kind == .Export {
			next_token(p.stream)
			is_exported = true
		}

		tok_kind := peek_token(p.stream).kind
		if tok_kind == .Import {
			if is_exported {
				report_parse(p, peek_token(p.stream).span, "Синтаксическая ошибка: нельзя экспортировать импорт")
			}
			decl := parse_import_decl(p)
			append(&prog.decls, decl)
		} else if tok_kind == .Function {
			decl := parse_function(p, is_exported)
			append(&prog.decls, decl)
		} else if tok_kind == .TypeDecl {
			// Бывает короче 4 токенов у оборванного файла ("тип X" в самом
			// конце) — без bounds-check тут был бы index-out-of-range panic.
			if p.stream.current_idx+3 >= len(p.stream.tokens) {
				bad_span := peek_token(p.stream).span
				report_parse(p, bad_span, "Синтаксическая ошибка: неполное объявление типа")
				skip_to_sync(p)
				err_decl := new(Error_Decl)
				err_decl.span = span_from(p, bad_span)
				append(&prog.decls, err_decl)
				continue
			}
			third_kind := p.stream.tokens[p.stream.current_idx + 3].kind
			if third_kind == .Struct {
				decl := parse_struct_decl(p, is_exported)
				append(&prog.decls, decl)
			} else if third_kind == .Enum {
				decl := parse_enum_decl(p, is_exported)
				append(&prog.decls, decl)
			} else if third_kind == .Interface {
				decl := parse_interface_decl(p, is_exported)
				append(&prog.decls, decl)
			} else {
				// peek-only (третий токен вперёд не потреблён) — без skip
				// следующая итерация увидит тот же .TypeDecl и зациклится.
				bad_span := peek_token(p.stream).span
				report_parse(
					p,
					bad_span,
					"Синтаксическая ошибка: после 'тип X =' ожидалось 'структура', 'интерфейс' или 'перечисление', получено: %v",
					third_kind,
				)
				next_token(p.stream)
				skip_to_sync(p)
				err_decl := new(Error_Decl)
				err_decl.span = span_from(p, bad_span)
				append(&prog.decls, err_decl)
			}
		} else if tok_kind == .Impl {
			if is_exported {
				report_parse(p, peek_token(p.stream).span, "Синтаксическая ошибка: реализация не может быть экспортирована")
			}
			decl := parse_impl_decl(p)
			append(&prog.decls, decl)
		} else {
			// peek-only — без skip зациклится на том же токене.
			bad_span := peek_token(p.stream).span
			report_parse(p, bad_span, "Ожидалось объявление, импорт или экспорт, получено: %v", tok_kind)
			next_token(p.stream)
			skip_to_sync(p)
			err_decl := new(Error_Decl)
			err_decl.span = span_from(p, bad_span)
			append(&prog.decls, err_decl)
		}
	}
	return prog
}

parse_import_decl :: proc(p: ^Parser) -> ^Import_Decl {
	start := peek_token(p.stream).span
	expect(p, .Import)
	decl := new(Import_Decl)

	path_tok := next_token(p.stream)
	if path_tok.kind != .Ident && path_tok.kind != .String {
		report_parse(p, path_tok.span, "Синтаксическая ошибка: после 'импорт' ожидается имя модуля или строка пути")
	}
	decl.path = path_tok.data

	if peek_token(p.stream).kind == .As {
		next_token(p.stream)
		alias_tok := next_token(p.stream)
		if alias_tok.kind != .Ident {
			report_parse(p, alias_tok.span, "Синтаксическая ошибка: после 'как' ожидается имя псевдонима")
		}
		decl.alias = alias_tok.data
	}

	consume_semicolon_or_newline(p)
	decl.span = span_from(p, start)
	return decl
}

parse_enum_decl :: proc(p: ^Parser, is_exported: bool) -> ^Enum_Decl {
	start := peek_token(p.stream).span
	expect(p, .TypeDecl)

	name_tok := next_token(p.stream)
	if name_tok.kind != .Ident {
		report_parse(
			p,
			name_tok.span,
			"Синтаксическая ошибка: после 'тип' ожидалось имя перечисления, получено: %v",
			name_tok.kind,
		)
	}

	decl := new(Enum_Decl)
	decl.name = name_tok.data
	decl.is_exported = is_exported
	decl.variants = make([dynamic]Variant_Decl)

	expect(p, .Assign)
	expect(p, .Enum)

	seen := make(map[string]bool)
	defer delete(seen)

	for peek_token(p.stream).kind != .End && peek_token(p.stream).kind != .EOF {
		variant_tok := next_token(p.stream)
		if variant_tok.kind != .Ident {
			report_parse(
				p,
				variant_tok.span,
				"Синтаксическая ошибка: в перечислении '%s' ожидалось имя варианта, получено: %v",
				decl.name,
				variant_tok.kind,
			)
		}
		if seen[variant_tok.data] {
			report_parse(
				p,
				variant_tok.span,
				"Синтаксическая ошибка: вариант '%s' объявлен дважды в '%s'",
				variant_tok.data,
				decl.name,
			)
		}
		seen[variant_tok.data] = true

		variant := Variant_Decl {
			name  = variant_tok.data,
			types = make([dynamic]Type_Node),
		}

		if peek_token(p.stream).kind == .LParen {
			next_token(p.stream) // (
			if peek_token(p.stream).kind == .RParen {
				report_parse(
					p,
					peek_token(p.stream).span,
					"Синтаксическая ошибка: у варианта '%s.%s' должны быть либо параметры в скобках, либо скобки должны отсутствовать",
					decl.name,
					variant_tok.data,
				)
			}
			for {
				append(&variant.types, parse_type(p))
				if peek_token(p.stream).kind == .Comma {
					next_token(p.stream)
					continue
				}
				break
			}
			expect(p, .RParen)
		}

		variant.span = span_from(p, variant_tok.span)
		append(&decl.variants, variant)
		consume_semicolon_or_newline(p)
	}

	expect(p, .End)

	if len(decl.variants) == 0 {
		report_parse(
			p,
			span_from(p, start),
			"Синтаксическая ошибка: перечисление '%s' должно объявлять хотя бы один вариант",
			decl.name,
		)
	}

	decl.span = span_from(p, start)
	return decl
}

parse_interface_decl :: proc(p: ^Parser, is_exported: bool) -> ^Interface_Decl {
	start := peek_token(p.stream).span
	expect(p, .TypeDecl)
	decl := new(Interface_Decl)
	decl.methods = make([dynamic]Method_Signature)
	decl.is_exported = is_exported

	name_tok := next_token(p.stream)
	decl.name = name_tok.data

	expect(p, .Assign)
	expect(p, .Interface)

	for peek_token(p.stream).kind != .End && peek_token(p.stream).kind != .EOF {
		method_start := peek_token(p.stream).span
		expect(p, .Function)
		method_name := next_token(p.stream)
		signature := Method_Signature {
			name = method_name.data,
		}
		signature.args = parse_param_list(p, true)
		signature.return_type = parse_required_return_type(p, "метода интерфейса")
		signature.span = span_from(p, method_start)
		append(&decl.methods, signature)
		consume_semicolon_or_newline(p)
	}

	expect(p, .End)
	decl.span = span_from(p, start)
	return decl
}

parse_impl_decl :: proc(p: ^Parser) -> ^Impl_Decl {
	start := peek_token(p.stream).span
	expect(p, .Impl)

	decl := new(Impl_Decl)
	decl.methods = make([dynamic]^Function_Decl)

	first_ident := next_token(p.stream)
	if first_ident.kind != .Ident do error(p, "Ожидалось имя типа или интерфейса")

	if peek_token(p.stream).kind == .For {
		expect(p, .For)

		target_tok := next_token(p.stream)
		if target_tok.kind != .Ident do error(p, "Ожидалось имя целевой структуры")

		decl.interface_name = first_ident.data
		decl.target_type = target_tok.data
	} else {
		decl.target_type = first_ident.data
	}

	for peek_token(p.stream).kind != .End && peek_token(p.stream).kind != .EOF {
		if peek_token(p.stream).kind != .Function {
			bad := peek_token(p.stream)
			report_parse(p, bad.span, "Внутри блока реализации могут быть только функции")
			// bad сам может быть sync-токеном (TypeDecl/Impl/Import/Export) —
			// skip_to_sync тогда не продвинется вообще, а цикл выше не
			// выйдет (ждёт End/EOF), и парсер зависает навсегда. Поэтому
			// прогресс гарантируем явно: съедаем bad, потом уже skip_to_sync.
			next_token(p.stream)
			skip_to_sync(p)
			continue
		}

		method := parse_function(p, false)
		if len(method.args) == 0 || method.args[0].name != "это" {
			report_parse(
				p,
				method.span,
				"Синтаксическая ошибка: первый аргумент метода '%s' структуры '%s' должен называться 'это'",
				method.name,
				decl.target_type,
			)
		}

		method.name = fmt.tprintf("%s::%s", decl.target_type, method.name)
		append(&decl.methods, method)
	}

	expect(p, .End)
	decl.span = span_from(p, start)
	return decl
}

parse_function :: proc(p: ^Parser, is_exported: bool) -> ^Function_Decl {
	start := peek_token(p.stream).span
	expect(p, .Function)
	function := new(Function_Decl)
	function.body = make([dynamic]Stmt)
	function.is_exported = is_exported

	tok := next_token(p.stream)
	if tok.kind != .Ident do report_parse(p, tok.span, "Синтаксическая ошибка: ожидалось имя функции, получено: %v", tok.kind)
	function.name = tok.data

	function.args = parse_param_list(p, true)
	function.return_type = parse_required_return_type(p, "функции")

	for peek_token(p.stream).kind != .End && peek_token(p.stream).kind != .EOF {
		parse_stmt_into(p, &function.body)
	}
	expect(p, .End)

	function.span = span_from(p, start)
	return function
}

parse_param_list :: proc(p: ^Parser, require_types: bool) -> [dynamic]Param_Decl {
	params := make([dynamic]Param_Decl)
	expect(p, .LParen)

	if peek_token(p.stream).kind != .RParen {
		for {
			param_tok := next_token(p.stream)
			if param_tok.kind != .Ident do report_parse(p, param_tok.span, "Синтаксическая ошибка: ожидалось имя аргумента, получено: %v", param_tok.kind)

			param := Param_Decl {
				name = param_tok.data,
			}

			if peek_token(p.stream).kind == .Colon {
				next_token(p.stream)
				param.type_annotation = parse_type(p)
			} else if require_types {
				report_parse(
					p,
					param_tok.span,
					"Синтаксическая ошибка: после аргумента '%s' ожидается ': Тип'",
					param.name,
				)
			}
			param.span = span_from(p, param_tok.span)
			append(&params, param)

			if peek_token(p.stream).kind == .Comma {
				next_token(p.stream)
				if peek_token(p.stream).kind == .RParen {
					break
				}
			} else {
				break
			}
		}
	}

	expect(p, .RParen)
	return params
}

parse_required_return_type :: proc(p: ^Parser, owner: string) -> Type_Node {
	if peek_token(p.stream).kind != .Arrow {
		report_parse(
			p,
			peek_token(p.stream).span,
			"Синтаксическая ошибка: после объявления %s ожидается '-> Тип'",
			owner,
		)
	} else {
		next_token(p.stream)
	}
	return parse_type(p)
}

parse_optional_return_type :: proc(p: ^Parser) -> Type_Node {
	if peek_token(p.stream).kind != .Arrow do return nil
	next_token(p.stream)
	return parse_type(p)
}

parse_struct_decl :: proc(p: ^Parser, is_exported: bool) -> ^Struct_Decl {
	start := peek_token(p.stream).span
	expect(p, .TypeDecl)

	decl := new(Struct_Decl)
	decl.fields = make([dynamic]Field_Decl)
	decl.is_exported = is_exported

	name_tok := next_token(p.stream)
	if name_tok.kind != .Ident do error(p, "Ожидалось имя типа")
	decl.name = name_tok.data

	expect(p, .Assign)
	expect(p, .Struct)

	for peek_token(p.stream).kind != .End && peek_token(p.stream).kind != .EOF {
		field := Field_Decl{}

		field_tok := next_token(p.stream)
		if field_tok.kind != .Ident do error(p, "Ожидалось имя поля структуры")
		field.name = field_tok.data

		expect(p, .Colon)

		field.type_annotation = parse_type(p)
		field.span = span_from(p, field_tok.span)
		append(&decl.fields, field)

		consume_semicolon_or_newline(p)
	}

	expect(p, .End)
	decl.span = span_from(p, start)
	return decl
}

// --- ПАРСИНГ ТИПОВ И ИНСТРУКЦИЙ ---

parse_type :: proc(p: ^Parser) -> Type_Node {
	tok := next_token(p.stream)
	start := tok.span

	if tok.kind == .Function {
		t := new(Type_Function)
		t.params = make([dynamic]Type_Node)

		expect(p, .LParen)
		if peek_token(p.stream).kind != .RParen {
			for {
				append(&t.params, parse_type(p))
				if peek_token(p.stream).kind == .Comma {
					next_token(p.stream)
					if peek_token(p.stream).kind == .RParen {
						break
					}
				} else {
					break
				}
			}
		}
		expect(p, .RParen)
		expect(p, .Arrow)
		t.return_type = parse_type(p)
		t.span = span_from(p, start)
		return t
	}

	if tok.kind == .Ident {
		if peek_token(p.stream).kind == .Dot {
			next_token(p.stream)
			member_tok := next_token(p.stream)
			if member_tok.kind != .Ident {
				report_parse(p, member_tok.span, "Синтаксическая ошибка: после '.' ожидается имя типа")
			}
			t := new(Type_Qualified)
			t.module_name = tok.data
			t.name = member_tok.data
			t.span = span_from(p, start)
			return t
		}

		// НОВОЕ: Универсальный парсинг дженерик-типов: Массив(Число), Соответствие(Число, Строка)
		if peek_token(p.stream).kind == .LParen {
			next_token(p.stream) // съедаем (
			t := new(Type_Generic)
			t.name = tok.data
			t.params = make([dynamic]Type_Node)

			if peek_token(p.stream).kind != .RParen {
				for {
					append(&t.params, parse_type(p))
					if peek_token(p.stream).kind == .Comma {
						next_token(p.stream)
					} else {
						break
					}
				}
			}
			expect(p, .RParen)
			t.span = span_from(p, start)
			return t
		}

		// Иначе это обычный тип-идентификатор (Число, Строка)
		t := new(Type_Ident)
		t.name = tok.data
		t.span = span_from(p, start)
		return t
	}

	if tok.kind == .LParen {
		t := new(Type_Tuple)
		t.elements = make([dynamic]Type_Node)

		if peek_token(p.stream).kind != .RParen {
			for {
				append(&t.elements, parse_type(p))
				if peek_token(p.stream).kind == .Comma {
					next_token(p.stream)
				} else {
					break
				}
			}
		}
		expect(p, .RParen)
		t.span = span_from(p, start)
		return t
	}

	report_parse(p, start, "Ожидалось имя типа или тупл, получено: %v", tok.kind)
	err := new(Error_Type_Node)
	err.span = start
	return err
}

parse_stmt :: proc(p: ^Parser) -> Stmt {
	tok := peek_token(p.stream)
	if tok == nil do return nil

	#partial switch tok.kind {
	case .Return:
		return parse_return_stmt(p)
	case .Let:
		return parse_let_stmt(p)
	case .Continue:
		return parse_continue_stmt(p)
	case .Break:
		return parse_break_stmt(p)
	case:
		return parse_expr_stmt(p)
	}
}

// Единственная причина, по которой это не просто `append(&body,
// parse_stmt(p))` — для-in: "для x в expr цикл ... конец" раскрывается в
// НЕСКОЛЬКО statement'ов (инициализация индекса + сам цикл), а parse_stmt
// возвращает ровно один Stmt. Вместо нового AST-узла "блок из N
// statement'ов" (который пришлось бы учить понимать resolver/type_cheker/
// compiler) — правим единственную точку, где тело собирается из
// statement'ов, во ВСЕХ шести местах (функция/если/иначе/пока/лямбда/
// ветка выбора). Desugar целиком живёт в parser.odin — резолвер и всё,
// что ниже, вообще не знают, что для-in существует.
parse_stmt_into :: proc(p: ^Parser, body: ^[dynamic]Stmt) {
	if peek_token(p.stream).kind == .For {
		parse_for_stmt_into(p, body)
		return
	}
	append(body, parse_stmt(p))
}

// для <шаблон> в <expr> цикл <тело> конец
// шаблон := ident | '(' ident (',' ident)* ')'
//
// Раскрывается на месте в уже существующие узлы (Let_Stmt/While_Expr/
// If_Expr/Break_Stmt/Index_Expr/Property_Expr) — три statement'а на выходе:
//
//   пер __for_N_iter = <expr>
//   пер __for_N_idx = -1
//   пока истина цикл
//       __for_N_idx = __for_N_idx + 1
//       если __for_N_idx == __for_N_iter.длина() тогда прервать конец
//       пер <элемент(ы) из шаблона> = __for_N_iter[__for_N_idx]
//       <тело>
//   конец
//
// Инкремент — ПЕРЕД телом, не после: `продолжить` компилируется как
// прыжок на начало `пока`-цикла (см. Loop_Context.continue_target в
// compiler.odin), т.е. на re-check условия. Если бы инкремент стоял
// ПОСЛЕ пользовательского тела (классическое "тело; idx++"), `продолжить`
// внутри тела перепрыгивал бы через инкремент — idx никогда не рос,
// бесконечный цикл. С условием "пока истина" и инкрементом в самом
// начале тела continue корректно возвращается именно туда.
//
// Работает с чем угодно, что поддерживает .длина() + [индекс] (Массив).
// Соответствие так индексировать нельзя ([] у карты — по ключу, не по
// позиции) — для карты сначала .записи() (см. Стадия 16), которая как раз
// возвращает Массив((К,З)), совместимый с шаблоном "для (к, з) в ...".
//
// "в" — контекстный keyword: НЕ зарезервированное слово лексера (проверено
// на практике — test.ps уже использует "в" как имя переменной в шаблоне
// `Прямоугольник(ш, в)`), сравнивается по тексту токена только в этой
// одной позиции грамматики.
parse_for_stmt_into :: proc(p: ^Parser, out: ^[dynamic]Stmt) {
	start := peek_token(p.stream).span
	next_token(p.stream) // .For

	names := make([dynamic]string)
	if peek_token(p.stream).kind == .LParen {
		next_token(p.stream)
		for {
			name_tok := next_token(p.stream)
			if name_tok.kind != .Ident {
				report_parse(p, name_tok.span, "Синтаксическая ошибка: в шаблоне 'для (...)' ожидается идентификатор")
			}
			append(&names, name_tok.data)
			if peek_token(p.stream).kind == .Comma {
				next_token(p.stream)
			} else {
				break
			}
		}
		expect(p, .RParen)
	} else {
		name_tok := next_token(p.stream)
		if name_tok.kind != .Ident {
			report_parse(p, name_tok.span, "Синтаксическая ошибка: после 'для' ожидается идентификатор или '(идент, ...)'")
		}
		append(&names, name_tok.data)
	}

	in_tok := next_token(p.stream)
	if in_tok.kind != .Ident || in_tok.data != "в" {
		report_parse(p, in_tok.span, "Синтаксическая ошибка: после списка переменных 'для' ожидается 'в'")
	}

	iterable := parse_expr(p, 0)

	expect(p, .Loop)
	user_body := make([dynamic]Stmt)
	for {
		kind := peek_token(p.stream).kind
		if kind == .End || kind == .EOF do break
		parse_stmt_into(p, &user_body)
	}
	expect(p, .End)

	span := span_from(p, start)

	p.for_counter += 1
	suffix := fmt.tprintf("__for_%d", p.for_counter)
	iter_name := fmt.tprintf("%s_iter", suffix)
	idx_name := fmt.tprintf("%s_idx", suffix)

	mk_ident :: proc(name: string, span: Span) -> Expr {
		e := new(Ident_Expr)
		e.name = intern(name)
		e.span = span
		return e
	}
	mk_num :: proc(v: f64, span: Span) -> Expr {
		e := new(Number_Expr)
		e.value = v
		e.span = span
		return e
	}

	// пер __for_N_iter = <expr>
	iter_let := new(Let_Stmt)
	iter_let.name = iter_name
	iter_let.value = iterable
	iter_let.span = span
	append(out, iter_let)

	// пер __for_N_idx = -1
	neg_one := new(Unary_Expr)
	neg_one.op = .Minus
	neg_one.right = mk_num(1, span)
	neg_one.span = span
	idx_let := new(Let_Stmt)
	idx_let.name = idx_name
	idx_let.value = neg_one
	idx_let.span = span
	append(out, idx_let)

	while_node := new(While_Expr)
	true_lit := new(Boolean_Expr)
	true_lit.value = true
	true_lit.span = span
	while_node.condition = true_lit
	while_node.body = make([dynamic]Stmt)

	// __for_N_idx = __for_N_idx + 1
	incr_add := new(Binary_Expr)
	incr_add.left = mk_ident(idx_name, span)
	incr_add.op = .Plus
	incr_add.right = mk_num(1, span)
	incr_add.span = span
	incr_assign := new(Binary_Expr)
	incr_assign.left = mk_ident(idx_name, span)
	incr_assign.op = .Assign
	incr_assign.right = incr_add
	incr_assign.span = span
	incr_stmt := new(Expr_Stmt)
	incr_stmt.expr = incr_assign
	incr_stmt.span = span
	append(&while_node.body, incr_stmt)

	// если __for_N_idx == __for_N_iter.длина() тогда прервать конец
	len_prop := new(Property_Expr)
	len_prop.object = mk_ident(iter_name, span)
	len_prop.property = "длина"
	len_prop.span = span
	len_call := new(Call_Expr)
	len_call.callee = len_prop
	len_call.args = make([dynamic]Expr)
	len_call.span = span
	cmp_eq := new(Binary_Expr)
	cmp_eq.left = mk_ident(idx_name, span)
	cmp_eq.op = .Equal
	cmp_eq.right = len_call
	cmp_eq.span = span
	break_stmt := new(Break_Stmt)
	break_stmt.span = span
	exit_if := new(If_Expr)
	exit_if.condition = cmp_eq
	exit_if.then_branch = make([dynamic]Stmt)
	append(&exit_if.then_branch, break_stmt)
	exit_if.else_branch = make([dynamic]Stmt)
	exit_if.span = span
	exit_if_stmt := new(Expr_Stmt)
	exit_if_stmt.expr = exit_if
	exit_if_stmt.span = span
	append(&while_node.body, exit_if_stmt)

	// пер <элемент(ы)> = __for_N_iter[__for_N_idx]
	index_expr := new(Index_Expr)
	index_expr.object = mk_ident(iter_name, span)
	index_expr.index = mk_ident(idx_name, span)
	index_expr.span = span

	if len(names) == 1 {
		elem_let := new(Let_Stmt)
		elem_let.name = names[0]
		elem_let.value = index_expr
		elem_let.span = span
		append(&while_node.body, elem_let)
	} else {
		elem_name := fmt.tprintf("%s_elem", suffix)
		elem_let := new(Let_Stmt)
		elem_let.name = elem_name
		elem_let.value = index_expr
		elem_let.span = span
		append(&while_node.body, elem_let)

		for name, i in names {
			field_prop := new(Property_Expr)
			field_prop.object = mk_ident(elem_name, span)
			field_prop.property = fmt.tprintf("%d", i)
			field_prop.span = span
			field_let := new(Let_Stmt)
			field_let.name = name
			field_let.value = field_prop
			field_let.span = span
			append(&while_node.body, field_let)
		}
	}

	for stmt in user_body {
		append(&while_node.body, stmt)
	}

	while_node.span = span
	while_stmt := new(Expr_Stmt)
	while_stmt.expr = while_node
	while_stmt.span = span
	append(out, while_stmt)
}

parse_continue_stmt :: proc(p: ^Parser) -> Stmt {
	start := peek_token(p.stream).span
	next_token(p.stream)
	stmt := new(Continue_Stmt)
	consume_semicolon_or_newline(p)
	stmt.span = span_from(p, start)
	return stmt
}

parse_break_stmt :: proc(p: ^Parser) -> Stmt {
	start := peek_token(p.stream).span
	next_token(p.stream)
	stmt := new(Break_Stmt)
	consume_semicolon_or_newline(p)
	stmt.span = span_from(p, start)
	return stmt
}

parse_return_stmt :: proc(p: ^Parser) -> Stmt {
	start := peek_token(p.stream).span
	next_token(p.stream)
	stmt := new(Return_Stmt)

	tok := peek_token(p.stream)
	if tok.kind == .Semicolon || tok.kind == .End || tok.kind == .EOF {
		stmt.value = nil
	} else {
		stmt.value = parse_expr(p, 0)
	}

	consume_semicolon_or_newline(p)
	stmt.span = span_from(p, start)
	return stmt
}

parse_let_stmt :: proc(p: ^Parser) -> Stmt {
	start := peek_token(p.stream).span
	next_token(p.stream)
	stmt := new(Let_Stmt)

	ident_tok := next_token(p.stream)
	if ident_tok.kind != .Ident do report_parse(p, ident_tok.span, "Синтаксическая ошибка: после 'пер' ожидается идентификатор")
	stmt.name = ident_tok.data

	if peek_token(p.stream).kind == .Colon {
		next_token(p.stream)
		stmt.type_annotation = parse_type(p)
	}

	expect(p, .Assign)
	stmt.value = parse_expr(p, 0)
	consume_semicolon_or_newline(p)
	stmt.span = span_from(p, start)
	return stmt
}

parse_expr_stmt :: proc(p: ^Parser) -> Stmt {
	start := peek_token(p.stream).span
	stmt := new(Expr_Stmt)
	stmt.expr = parse_expr(p, 0)
	consume_semicolon_or_newline(p)
	stmt.span = span_from(p, start)
	return stmt
}

// --- ПАРСИНГ ВЫРАЖЕНИЙ (PRATT PARSER) ---

parse_if_expr :: proc(p: ^Parser) -> Expr {
	start := last_token_span(p.stream) // .If уже съеден вызывающим nud()
	node := new(If_Expr)
	node.condition = parse_expr(p, 0)

	expect(p, .Then)
	node.then_branch = make([dynamic]Stmt)
	for {
		kind := peek_token(p.stream).kind
		if kind == .Else || kind == .End || kind == .EOF do break
		parse_stmt_into(p, &node.then_branch)
	}

	node.else_branch = make([dynamic]Stmt)
	if peek_token(p.stream).kind == .Else {
		next_token(p.stream)
		for {
			kind := peek_token(p.stream).kind
			if kind == .End || kind == .EOF do break
			parse_stmt_into(p, &node.else_branch)
		}
	}

	expect(p, .End)
	node.span = span_from(p, start)
	return node
}

parse_while_expr :: proc(p: ^Parser) -> Expr {
	start := last_token_span(p.stream) // .While уже съеден вызывающим nud()
	node := new(While_Expr)
	node.condition = parse_expr(p, 0)

	expect(p, .Loop)
	node.body = make([dynamic]Stmt)
	for {
		kind := peek_token(p.stream).kind
		if kind == .End || kind == .EOF do break
		parse_stmt_into(p, &node.body)
	}

	expect(p, .End)
	node.span = span_from(p, start)
	return node
}

// start передаётся вызывающим кодом (parse_expr) — это span идентификатора
// `массив`/`соответствие`, а не открывающей скобки, чтобы Array_Expr
// покрывал весь литерал целиком.
parse_array_literal_after_lparen :: proc(p: ^Parser, start: Span) -> Expr {
	node := new(Array_Expr)
	node.elements = make([dynamic]Expr)

	if peek_token(p.stream).kind != .RParen {
		for {
			append(&node.elements, parse_expr(p, 0))
			if peek_token(p.stream).kind == .Comma {
				next_token(p.stream)
				if peek_token(p.stream).kind == .RParen {
					break
				}
			} else {
				break
			}
		}
	}

	expect(p, .RParen)
	node.span = span_from(p, start)
	return node
}

parse_map_literal_after_lparen :: proc(p: ^Parser, start: Span) -> Expr {
	node := new(Map_Expr)
	node.entries = make([dynamic]Map_Entry_Expr)

	if peek_token(p.stream).kind != .RParen {
		for {
			entry := Map_Entry_Expr{}
			entry_start := peek_token(p.stream).span
			entry.key = parse_expr(p, 11)
			expect(p, .Assign)
			entry.value = parse_expr(p, 0)
			entry.span = span_from(p, entry_start)
			append(&node.entries, entry)

			if peek_token(p.stream).kind == .Comma {
				next_token(p.stream)
				if peek_token(p.stream).kind == .RParen {
					break
				}
			} else {
				break
			}
		}
	}

	expect(p, .RParen)
	return node
}

parse_expr :: proc(p: ^Parser, min_bp: int) -> Expr {
	tok := next_token(p.stream)
	if tok == nil {
		report_parse(p, last_token_span(p.stream), "Синтаксическая ошибка: неожиданный конец файла в выражении")
		err := new(Error_Expr)
		err.span = last_token_span(p.stream)
		return err
	}

	left := nud(p, tok)
	// Начало всей цепочки (левый операнд до всех Call/Property/Index/Try/
	// Binary обёрток) — используется для end-inclusive span каждой новой
	// обёртки, чтобы `a.b(c)[d]` целиком покрывался одним span'ом от `a`.
	start := expr_span(left)

	for {
		op := peek_token(p.stream)
		if op == nil || op.kind == .EOF do break

		lbp, rbp, is_infix := infix_bp(op)
		if !is_infix || lbp < min_bp do break

		next_token(p.stream)

		if op.kind == .LParen {
			if ident, ok := left.(^Ident_Expr); ok {
				if ident.name == intern("массив") {
					left = parse_array_literal_after_lparen(p, ident.span)
					continue
				}
				if ident.name == intern("соответствие") {
					left = parse_map_literal_after_lparen(p, ident.span)
					continue
				}
			}

			// Вызов функции (в том числе массив() и соответствие()!)
			call := new(Call_Expr)
			call.callee = left
			call.args = make([dynamic]Expr)

			if peek_token(p.stream).kind != .RParen {
				for {
					append(&call.args, parse_expr(p, 0))
					if peek_token(p.stream).kind == .Comma {
						next_token(p.stream)
					} else {
						break
					}
				}
			}
			expect(p, .RParen)
			call.span = span_from(p, start)
			left = call

		} else if op.kind == .Dot {
			prop_tok := next_token(p.stream)
			if prop_tok.kind != .Ident && prop_tok.kind != .Number {
				report_parse(p, prop_tok.span, "Ожидалось имя поля или индекс после '.', получено: %v", prop_tok.kind)
			}
			prop := new(Property_Expr)
			prop.object = left
			prop.property = prop_tok.data
			prop.span = span_from(p, start)
			left = prop

		} else if op.kind == .LBracket {
			index := new(Index_Expr)
			index.object = left
			index.index = parse_expr(p, 0)
			expect(p, .RBracket)
			index.span = span_from(p, start)
			left = index

		} else if op.kind == .Question {
			try_expr := new(Try_Expr)
			try_expr.value = left
			try_expr.span = span_from(p, start)
			left = try_expr

		} else {
			// Обычный бинарный оператор (включая `=`)
			right := parse_expr(p, rbp)
			left = new_bin_op(op.kind, left, right, start)
		}
	}
	return left
}

nud :: proc(p: ^Parser, tok: ^Token) -> Expr {
	#partial switch tok.kind {
	case .Number:
		return new_int_lit(p, tok)

	case .Boolean:
		return new_boolean_lit(tok)

	case .String:
		s := new(String_Expr)
		s.value = tok.data
		s.span = tok.span
		return s

	case .Ident:
		return new_ident(tok)

	case .Function:
		// Лямбда-функции: функ(х) х + 1 конец
		start := tok.span
		lam := new(Lambda_Expr)
		lam.body = make([dynamic]Stmt)

		lam.args = parse_param_list(p, false)
		lam.return_type = parse_optional_return_type(p)

		for peek_token(p.stream).kind != .End && peek_token(p.stream).kind != .EOF {
			parse_stmt_into(p, &lam.body)
		}
		expect(p, .End)
		lam.span = span_from(p, start)
		return lam

	case .LParen:
		start := tok.span
		if peek_token(p.stream).kind == .RParen {
			next_token(p.stream)
			t := new(Tuple_Expr)
			t.elements = make([dynamic]Expr)
			t.span = span_from(p, start)
			return t
		}

		e := parse_expr(p, 0)

		if peek_token(p.stream).kind == .Comma {
			t := new(Tuple_Expr)
			t.elements = make([dynamic]Expr)
			append(&t.elements, e)

			for peek_token(p.stream).kind == .Comma {
				next_token(p.stream)
				if peek_token(p.stream).kind == .RParen {
					break
				}
				append(&t.elements, parse_expr(p, 0))
			}
			expect(p, .RParen)
			t.span = span_from(p, start)
			return t
		}

		expect(p, .RParen)
		return e

	case .Minus:
		rbp := prefix_bp(tok)
		rhs := parse_expr(p, rbp)
		return new_unary(tok, rhs)

	case .Negate:
		rbp := prefix_bp(tok)
		rhs := parse_expr(p, rbp)
		return new_unary(tok, rhs)

	case .If:
		return parse_if_expr(p)

	case .While:
		return parse_while_expr(p)

	case .Match:
		return parse_match_expr(p)

	case:
		report_parse(p, tok.span, "Синтаксическая ошибка: неожиданный токен '%s' (%v) в начале выражения", tok.data, tok.kind)
		err := new(Error_Expr)
		err.span = tok.span
		return err
	}
	return nil
}

parse_pattern :: proc(p: ^Parser) -> Pattern {
	start := peek_token(p.stream).span
	tok := next_token(p.stream)
	if tok.kind == .Ident {
		if tok.data == "_" {
			w := new(Pattern_Wildcard)
			w.span = span_from(p, start)
			return w
		}
		module_name := ""
		type_name := ""
		name := tok.data
		// Optional qualification: Ident.Ident (Type.Variant) or
		// Ident.Ident.Ident (module.Type.Variant).
		for peek_token(p.stream).kind == .Dot {
			next_token(p.stream)
			next_tok := next_token(p.stream)
			if next_tok.kind != .Ident {
				report_parse(p, next_tok.span, "Синтаксическая ошибка: после '.' в шаблоне ожидался идентификатор")
			}
			if module_name == "" {
				module_name = name
				name = next_tok.data
			} else {
				type_name = name
				name = next_tok.data
			}
		}
		// If only one dot was used, we don't know yet whether it was
		// Type.Variant or module.Variant — resolver decides. Store as
		// (module_name=first, name=second, type_name=""). For two dots,
		// (module_name=first, type_name=second, name=third).
		if type_name != "" {
			// Encode module.Type.Variant into Pattern_Constructor by
			// prefixing module_name with the type qualifier separator "|".
			// Simpler: store type as "module_name". We track second-level
			// via type_name concatenated. For now flatten to module.
			module_name = fmt.aprintf("%s.%s", module_name, type_name)
		}
		if peek_token(p.stream).kind == .LParen {
			next_token(p.stream)
			pat := new(Pattern_Constructor)
			pat.module_name = module_name
			pat.name = name
			pat.args = make([dynamic]Pattern)
			if peek_token(p.stream).kind == .RParen {
				report_parse(
					p,
					peek_token(p.stream).span,
					"Синтаксическая ошибка: у шаблона-конструктора '%s' пустые скобки",
					name,
				)
			}
			for {
				append(&pat.args, parse_pattern(p))
				if peek_token(p.stream).kind == .Comma {
					next_token(p.stream)
					continue
				}
				break
			}
			expect(p, .RParen)
			pat.span = span_from(p, start)
			return pat
		}
		if module_name != "" {
			pat := new(Pattern_Constructor)
			pat.module_name = module_name
			pat.name = name
			pat.args = make([dynamic]Pattern)
			pat.span = span_from(p, start)
			return pat
		}
		pat := new(Pattern_Ident)
		pat.name = name
		pat.span = span_from(p, start)
		return pat
	}
	report_parse(
		p,
		tok.span,
		"Синтаксическая ошибка: такой шаблон в выборе пока не поддерживается: %v",
		tok.kind,
	)
	err := new(Error_Pattern)
	err.span = tok.span
	return err
}

parse_match_expr :: proc(p: ^Parser) -> ^Match_Expr {
	start := last_token_span(p.stream) // .Match уже съеден вызывающим nud()
	m := new(Match_Expr)
	m.arms = make([dynamic]Match_Arm)
	m.subject = parse_expr(p, 0)

	consume_semicolon_or_newline(p)

	for peek_token(p.stream).kind != .End && peek_token(p.stream).kind != .EOF {
		arm_start := peek_token(p.stream).span
		arm := Match_Arm {
			body = make([dynamic]Stmt),
		}
		arm.pattern = parse_pattern(p)
		expect(p, .Arrow)
		// Тело ветки: один или несколько statement до разделителя ветки.
		// Разделителем считается перевод строки или `;`; следующая ветка
		// начинается со следующего Pattern (Ident/`_`).
		for {
			parse_stmt_into(p, &arm.body)
			if peek_token(p.stream).kind == .Semicolon {
				next_token(p.stream)
			}
			nxt := peek_token(p.stream).kind
			if nxt == .End || nxt == .EOF do break
			// Если следующий токен — идентификатор ИЛИ `_` (Ident), это
			// начало следующей ветки. Наивно: если после текущего stmt
			// стоит Ident в позиции начала выражения, считаем это новой
			// веткой. Для простоты сейчас поддерживаем ветки в одну
			// строку — далее берём следующую ветку сразу.
			break
		}
		arm.span = span_from(p, arm_start)
		append(&m.arms, arm)
	}
	expect(p, .End)

	if len(m.arms) == 0 {
		report_parse(p, span_from(p, start), "Синтаксическая ошибка: выбор должен содержать хотя бы одну ветку")
	}
	m.span = span_from(p, start)
	return m
}

prefix_bp :: proc(token: ^Token) -> int {
	#partial switch token.kind {
	case .Minus, .Negate:
		return 100
	}
	return 0
}

infix_bp :: proc(tok: ^Token) -> (lbp, rbp: int, ok: bool) {
	#partial switch tok.kind {
	case .Dot:
		return 90, 91, true
	case .Star, .Slash:
		return 60, 61, true
	case .Plus, .Minus:
		return 50, 51, true
	case .Less, .Greater:
		return 40, 41, true
	case .Equal, .NotEqual:
		return 30, 31, true
	case .And:
		return 28, 29, true
	case .Or:
		return 26, 27, true
	case .Assign:
		return 10, 9, true
	case .LParen:
		return 80, 0, true
	case .LBracket:
		return 80, 0, true
	case .Question:
		return 90, 91, true
	}
	return 0, 0, false
}

// --- УТИЛИТЫ ---

error :: proc(p: ^Parser, format: string, args: ..any) {
	report_parse(p, last_token_span(p.stream), format, ..args)
}

// Собирает span конструкции: start — позиция первого токена (обычно
// peek_token до начала парсинга), end — позиция последнего уже съеденного
// токена (last_token_span). Единая точка, чтобы не дублировать
// file_id-проброс в каждом parse_X.
span_from :: proc(p: ^Parser, start: Span) -> Span {
	end := last_token_span(p.stream)
	return Span{file_id = p.file_id, start = start.start, end = end.end}
}

// span произвольного Expr — нужен в Pratt-парсере, чтобы взять start
// левого операнда до того, как он обрастёт обёртками (Binary/Call/...).
expr_span :: proc(e: Expr) -> Span {
	if e == nil do return Span{}
	switch v in e {
	case ^Number_Expr:
		return v.span
	case ^Boolean_Expr:
		return v.span
	case ^String_Expr:
		return v.span
	case ^Binary_Expr:
		return v.span
	case ^Unary_Expr:
		return v.span
	case ^Ident_Expr:
		return v.span
	case ^Call_Expr:
		return v.span
	case ^While_Expr:
		return v.span
	case ^If_Expr:
		return v.span
	case ^Tuple_Expr:
		return v.span
	case ^Property_Expr:
		return v.span
	case ^Lambda_Expr:
		return v.span
	case ^Array_Expr:
		return v.span
	case ^Map_Expr:
		return v.span
	case ^Index_Expr:
		return v.span
	case ^Try_Expr:
		return v.span
	case ^Match_Expr:
		return v.span
	case ^Error_Expr:
		return v.span
	}
	return Span{}
}

expect :: proc(p: ^Parser, expected_kind: TokenKind) {
	tok := next_token(p.stream)
	if tok == nil {
		report_parse(p, last_token_span(p.stream), "Синтаксическая ошибка: ожидалось %v, но обнаружен EOF", expected_kind)
		return
	}
	if tok.kind != expected_kind {
		report_parse(p, tok.span, "Синтаксическая ошибка: ожидалось %v, обнаружен %v", expected_kind, tok.kind)
	}
}

consume_semicolon_or_newline :: proc(p: ^Parser) {
	tok := peek_token(p.stream)
	if tok.kind == .Semicolon {
		next_token(p.stream)
	} else if tok.kind == .EOF || tok.kind == .RParen {
		return
	}
}

new_int_lit :: proc(p: ^Parser, data: ^Token) -> Expr {
	lit := new(Number_Expr)
	value, ok := strconv.parse_f64(data.data)
	if !ok {
		report_parse(p, data.span, "Синтаксическая ошибка: неверный числовой литерал '%s'", data.data)
	}
	lit.value = value
	lit.span = data.span
	return lit
}

new_boolean_lit :: proc(data: ^Token) -> Expr {
	lit := new(Boolean_Expr)
	lit.value = data.data == "истина"
	lit.span = data.span
	return lit
}

new_bin_op :: proc(kind: TokenKind, left: Expr, right: Expr, start: Span) -> Expr {
	b := new(Binary_Expr)
	b.left = left
	b.op = kind
	b.right = right
	b.span = Span{file_id = start.file_id, start = start.start, end = expr_span(right).end}
	return b
}

new_unary :: proc(token: ^Token, rhs: Expr) -> Expr {
	lit := new(Unary_Expr)
	lit.op = token.kind
	lit.right = rhs
	lit.span = Span {
		file_id = token.span.file_id,
		start   = token.span.start,
		end     = expr_span(rhs).end,
	}
	return lit
}

new_ident :: proc(tok: ^Token) -> Expr {
	node := new(Ident_Expr)
	node.name = intern(tok.data)
	node.span = tok.span
	return node
}
