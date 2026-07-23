package core

// Semantic tokens (LSP `textDocument/semanticTokens/full`) — классификация
// идентификаторов по УЖЕ посчитанному резолвером Symbol.kind, а не по
// regex/конвенции именования (см. syntax/panos.vim в panos.nvim — та
// regex-подсветка не может отличить переменную от функции от типа по
// одному только имени, особенно с кириллицей, где нет единой конвенции
// вроде "Type начинается с большой буквы" на 100%). Порядок вариантов
// здесь ДОЛЖЕН совпадать с SEMANTIC_TOKEN_TYPE_NAMES (индекс — это и есть
// LSP-протокольный token type, см. lsp/lsp_server.odin).
Semantic_Token_Type :: enum {
	Namespace,
	Type,
	EnumMember,
	Function,
	Variable,
	Parameter,
}

SEMANTIC_TOKEN_TYPE_NAMES := [?]string{"namespace", "type", "enumMember", "function", "variable", "parameter"}

Semantic_Token :: struct {
	span:       Span,
	token_type: Semantic_Token_Type,
}

// Только "голые" идентификаторы (Ident_Expr, через node_symbols — Expr,
// резолвившийся в конкретный символ). Property_Expr (`x.поле`/`x.метод()`)
// сюда НЕ попадает (это не Ident_Expr, node_symbols её не индексирует) —
// поля/методы структур пока не классифицируются, только module-level
// идентификаторы (переменные, параметры, функции, типы, enum-варианты,
// имена модулей).
compute_semantic_tokens :: proc(res: ^Resolver_Ctx) -> [dynamic]Semantic_Token {
	tokens := make([dynamic]Semantic_Token)
	for expr, sym_id in res.node_symbols {
		// node_symbols индексирует не только Ident_Expr — для
		// module-квалифицированных вызовов (`математика.пи()`) резолвер
		// пишет резолвленный символ ТАКЖЕ под ключом Property_Expr целиком
		// (нужно go-to-definition), чей span покрывает "математика.пи"
		// целиком — без этого фильтра получили бы два перекрывающихся
		// токена (namespace на "математика" от Ident_Expr И function на
		// "математика.пи" от Property_Expr).
		if _, is_ident := expr.(^Ident_Expr); !is_ident do continue
		if sym_id == INVALID_SYMBOL do continue
		sym := symbol_at(res.symbol_store, sym_id)
		tok_type: Semantic_Token_Type
		classified := true
		switch sym.kind {
		case .Type:
			tok_type = .Type
		case .Enum_Variant:
			tok_type = .EnumMember
		case .Function:
			tok_type = .Function
		case .Module:
			tok_type = .Namespace
		case .Variable:
			tok_type = .Parameter if is_parameter_symbol(res, sym_id) else .Variable
		case .Constant:
			tok_type = .Variable
		case .Builtin:
			classified = false
		case:
			classified = false
		}
		if !classified do continue
		append(&tokens, Semantic_Token{span = expr_span(expr), token_type = tok_type})
	}
	return tokens
}

// Параметр — Symbol_Id, встречающийся хоть в чьём-то func_args (см.
// resolve_function_body в resolver.odin) — единственный способ отличить
// параметр от обычной локальной `пер`-переменной: оба Symbol_Kind.Variable,
// разница только в том, откуда символ появился, а это func_args и знает.
is_parameter_symbol :: proc(res: ^Resolver_Ctx, sym_id: Symbol_Id) -> bool {
	for _, args_syms in res.func_args {
		for s in args_syms {
			if s == sym_id do return true
		}
	}
	return false
}
