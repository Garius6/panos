package core

import "core:strings"

// Bounded traits: тело bounded generic-функции (`type_param_bounds`
// непусто) типизируется абстрактно ОДИН раз (см. type_cheker.odin —
// как и любой другой generic), но НИКОГДА не лоурится напрямую — оно
// клонируется под каждую конкретную комбинацию type-параметров,
// встреченную на call site'ах (ctx.generic_call_instantiations,
// заполняется infer_bounded_generic_call), и каждый клон проходит
// ПОЛНОСТЬЮ обычный resolve→typecheck→lower (см. mir_monomorphize.
// odin's lower_monomorphize_program) — ни один из этих трёх пайплайнов не
// знает о bounded traits вообще, клон с T, зарезолвленным в конкретный
// тип, неотличим от обычной non-generic функции.

// "имя_функции$Тип1,Тип2" — человекочитаемый registry-ключ (в отличие
// от generic_instance_cache, который канонизирует ^Type ПОИНТЕРЫ, не
// нужен человекочитаемым — этот ключ реальный ключ module.
// generic_instantiations, читает его и mir_lowering.odin на call site).
build_instantiation_key :: proc(store: ^Symbol_Store, sym: Symbol_Id, concrete_types: [dynamic]^Type) -> string {
	b := strings.builder_make()
	strings.write_string(&b, symbol_registry_key(store, sym))
	for t, i in concrete_types {
		strings.write_string(&b, i == 0 ? "$" : ",")
		strings.write_string(&b, prune_type(t).name)
	}
	return strings.to_string(b)
}
