#+build !js
package core

import "core:testing"

// compute_semantic_tokens классифицирует ТОЛЬКО Ident_Expr-использования
// (через res.node_symbols), по Symbol.kind, уже посчитанному резолвером —
// не по regex/конвенции имени.
@(test)
test_semantic_tokens_classify_by_symbol_kind :: proc(t: ^testing.T) {
	tokens := resolve_and_compute_semantic_tokens(`
		тип Точка = структура
			x: Число
		конец

		функ квадрат(n: Целое) -> Целое
			пер р = n * n
			р
		конец

		функ старт() -> Пусто
			пер п = Точка(1.0)
			квадрат(3)
		конец
	`)
	defer delete(tokens)

	counts := map[Semantic_Token_Type]int{}
	defer delete(counts)
	for tok in tokens do counts[tok.token_type] += 1

	testing.expectf(t, counts[.Parameter] >= 1, "[semantic tokens] ожидался хотя бы 1 .Parameter (n), получено %d", counts[.Parameter])
	testing.expectf(t, counts[.Variable] >= 1, "[semantic tokens] ожидался хотя бы 1 .Variable (р/п), получено %d", counts[.Variable])
	testing.expectf(t, counts[.Type] >= 1, "[semantic tokens] ожидался хотя бы 1 .Type (Точка), получено %d", counts[.Type])
	testing.expectf(t, counts[.Function] >= 1, "[semantic tokens] ожидался хотя бы 1 .Function (квадрат), получено %d", counts[.Function])
}

// Bare-идентификатор внутри `x.метод()`/`x.поле` (Property_Expr) — module-
// квалифицированный вызов резолвится ТАКЖЕ под ключом Property_Expr целиком
// (для go-to-definition), не только под Ident_Expr("математика") — без
// фильтра по типу AST-узла получили бы дублирующийся/перекрывающийся токен
// на весь "математика.пи", а не только на имя модуля.
@(test)
test_semantic_tokens_no_duplicate_for_module_qualified_call :: proc(t: ^testing.T) {
	// "строки" (не "математика") — core builtin-модуль, резолвится и без
	// полноценного графа импортов/файловой загрузки (typecheck_only-style
	// однофайловый путь тут не грузит std/*.ps с диска).
	tokens := resolve_and_compute_semantic_tokens(`
		импорт строки

		функ старт() -> Целое
			строки.длина_байт("абв")
		конец
	`)
	defer delete(tokens)

	namespace_count := 0
	max_len := 0
	for tok in tokens {
		if tok.token_type == .Namespace {
			namespace_count += 1
			length := int(tok.span.end - tok.span.start)
			if length > max_len do max_len = length
		}
	}
	testing.expectf(t, namespace_count == 1, "[semantic tokens] ожидался ровно 1 .Namespace-токен, получено %d", namespace_count)
	// "математика" — 10 рун; если бы фильтр по Ident_Expr не сработал, сюда
	// попал бы токен длиной на весь "математика.пи" (Property_Expr.span).
	testing.expectf(t, max_len <= 20, "[semantic tokens] .Namespace-токен подозрительно длинный (%d байт) — похоже на Property_Expr, не Ident_Expr", max_len)
}

resolve_and_compute_semantic_tokens :: proc(source: string) -> [dynamic]Semantic_Token {
	tokens, _ := tokenize(source)
	stream := make_stream(tokens)
	parser := Parser {
		stream = &stream,
	}
	prog := parse_program(&parser)

	res_ctx := new_resolver_ctx()
	resolve_program(&res_ctx, prog)

	type_ctx := new_type_ctx(&res_ctx)
	typecheck_program(&type_ctx, prog)

	return compute_semantic_tokens(&res_ctx)
}
