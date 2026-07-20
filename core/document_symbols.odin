package core

// Document symbols (LSP `textDocument/documentSymbol`, файловый outline) —
// как folding ranges: чисто структурная фича над Program текущего файла,
// резолвер/граф не нужны. Doc_Symbol_Kind — свой enum (не resolver'ный
// Symbol_Kind: тому не хватает различия Struct/Enum/Interface/Field/
// EnumMember/Method — все они у резолвера разной кучей смешаны в Type/
// Variable/Function), маппится в proto.SymbolKind в lsp/lsp_server.odin.
Doc_Symbol_Kind :: enum {
	Struct,
	Enum,
	Interface,
	Function,
	Method,
	Field,
	EnumMember,
	// "реализация X для Y" — LSP не различает impl-блоки отдельным kind'ом,
	// маппим в SymbolKind.Class на стороне LSP (ближайший смысловой аналог:
	// "сумка методов для типа").
	Impl,
}

Doc_Symbol :: struct {
	name:      string,
	kind:      Doc_Symbol_Kind,
	// Span объявления целиком.
	span:      Span,
	// Span одного имени (Function_Decl.name_span) — заполнен ТОЛЬКО для
	// функций (top-level и методы реализация, оба — ^Function_Decl); нулевое
	// значение (zero Span) для остального (Struct/Enum/Interface/Field/
	// EnumMember/Impl/Interface-методы — Method_Signature своего name_span
	// не имеет), вызывающий на LSP-стороне тогда падает обратно на span.
	name_span: Span,
	children:  [dynamic]Doc_Symbol,
}

compute_document_symbols :: proc(prog: Program) -> [dynamic]Doc_Symbol {
	out := make([dynamic]Doc_Symbol)
	for decl in prog.decls {
		#partial switch d in decl {
		case ^Function_Decl:
			append(&out, Doc_Symbol{name = d.name, kind = .Function, span = d.span, name_span = d.name_span})
		case ^Struct_Decl:
			children := make([dynamic]Doc_Symbol)
			for f in d.fields {
				append(&children, Doc_Symbol{name = f.name, kind = .Field, span = f.span})
			}
			append(&out, Doc_Symbol{name = d.name, kind = .Struct, span = d.span, children = children})
		case ^Enum_Decl:
			children := make([dynamic]Doc_Symbol)
			for v in d.variants {
				append(&children, Doc_Symbol{name = v.name, kind = .EnumMember, span = v.span})
			}
			append(&out, Doc_Symbol{name = d.name, kind = .Enum, span = d.span, children = children})
		case ^Interface_Decl:
			children := make([dynamic]Doc_Symbol)
			for m in d.methods {
				append(&children, Doc_Symbol{name = m.name, kind = .Method, span = m.span})
			}
			append(&out, Doc_Symbol{name = d.name, kind = .Interface, span = d.span, children = children})
		case ^Impl_Decl:
			children := make([dynamic]Doc_Symbol)
			for m in d.methods {
				append(&children, Doc_Symbol{name = m.name, kind = .Method, span = m.span, name_span = m.name_span})
			}
			append(&out, Doc_Symbol{name = d.target_type, kind = .Impl, span = d.span, children = children})
		case ^Foreign_Decl:
			append(&out, Doc_Symbol{name = d.name, kind = .Function, span = d.span})
		}
	}
	return out
}
