package core

// Общая логика dot-completion (`receiver.` -> список полей/методов/
// вариантов) — переиспользуется и panos-lsp (lsp/lsp_server.odin),
// и WASM-демо (wasm/main.odin), не дублируется между ними.
Completion_Member_Kind :: enum {
	Field,
	Method,
	Variant,
}

Completion_Member :: struct {
	name: string,
	kind: Completion_Member_Kind,
}

// receiver_type должен быть уже resolved (prune_type применяется внутри).
// .Массив/.Соответствие — builtin-методы БЕЗ Symbol_Id (диспетчеризуются
// хардкодом в vm.odin's invoke_collection_method, не через typ.methods) —
// синхронизировать вручную при добавлении новых. .Struct/.Enum — берём
// прямо из typ.fields/typ.variants/typ.methods (последнее покрывает и
// Опция/Результат — их методы регистрируются обычным `реализация`-блоком
// в prelude.odin, тот же путь, что у пользовательских типов).
type_completion_members :: proc(t: ^Type) -> [dynamic]Completion_Member {
	items := make([dynamic]Completion_Member)
	typ := prune_type(t)
	if typ == nil do return items

	#partial switch typ.kind {
	case .Struct:
		for f in typ.fields {
			append(&items, Completion_Member{name = f.name, kind = .Field})
		}
		for name in typ.methods {
			append(&items, Completion_Member{name = name, kind = .Method})
		}
	case .Enum:
		for v in typ.variants {
			append(&items, Completion_Member{name = v.name, kind = .Variant})
		}
		for name in typ.methods {
			append(&items, Completion_Member{name = name, kind = .Method})
		}
	case .Array:
		array_methods := [?]string{"длина", "добавить", "получить", "есть", "содержит"}
		for name in array_methods {
			append(&items, Completion_Member{name = name, kind = .Method})
		}
	case .Map:
		map_methods := [?]string{"длина", "есть", "получить", "удалить", "записи"}
		for name in map_methods {
			append(&items, Completion_Member{name = name, kind = .Method})
		}
	}
	return items
}
