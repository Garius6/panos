package core

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

// --- ТИПЫ ДАННЫХ ---

Type_Kind :: enum {
	Number,
	// Целое — отдельный от Число тип. На РАНТАЙМЕ представлен ТЕМ ЖЕ f64
	// (нет отдельного Value-варианта, нет своего GC/opcode-семейства для
	// +/-/*), различие целиком на уровне типов: только компилятор решает,
	// какой опкод для `/` эмитить (.Divide для Число, .Int_Divide для
	// Целое — оба уже видят статические типы операндов через
	// ctx.tc.node_types). Целочисленные литералы (без точки) по умолчанию
	// Целое, но "расширяются" до Число в Число-контексте — см. check_expr
	// и infer_binary_expr, литерал остаётся Число-совместимым синтаксисом,
	// а не значением с неявной коэрцией (коэрция между УЖЕ типизированными
	// Целое/Число переменными сознательно НЕ реализована в этом проходе —
	// отложено до отдельной задачи с explicit-конверсией).
	Integer,
	Bool,
	Void,
	Never,
	String,
	Function,
	Tuple,
	Struct,
	Interface,
	Array,
	Map,
	Error,
	InferVar,
	Enum,
	// Дескриптор открытого файла/потока (фс.открыть, ввод_вывод.поток) —
	// непараметрический тип, методы см. FILE_METHODS.
	File,
	// TCP-соединение (сеть.подключиться) — непараметрический тип, методы
	// см. CONNECTION_METHODS.
	Connection,
	// Стадия 24 (actor model): Процесс(T) — T хранится в element_type
	// (тот же приём, что .Array), НЕ через Type_Scheme/instantiate_scheme
	// (Struct/Enum generics) — резолвится третьей веткой в Type_Generic-
	// цепочке (resolve_type_node), рядом с Массив/Соответствие. См.
	// new_process_type.
	Process,
	// Стадия 49 (FFI): Указатель(T) — opaque handle для внешних C-
	// указателей. Тот же приём, что Process выше — T в element_type,
	// третья/четвёртая ветка Type_Generic-цепочки (resolve_type_node),
	// БЕЗ Type_Scheme. T ЧИСТО фантомный — panos никогда не
	// разыменовывает/не читает поля через Указатель(T) в этом срезе
	// (нет ff_структура), T нужен только для типобезопасности
	// (Указатель(Файл) ≠ Указатель(Сокет) для тайпчекера). См.
	// new_pointer_type, core/vm_ffi_native.odin (Pointer_Value).
	Pointer,
	// Заглушка для узла, где уже была зарепорчена ошибка. Unify'ится с чем
	// угодно (см. unify_types/types_are_equal) — не даёт одной первопричине
	// расплодиться в десяток производных диагностик по всему выражению.
	Poison,
}

Type_Variant :: struct {
	name:   string,
	fields: [dynamic]^Type,
}

Type :: struct {
	kind:                   Type_Kind,
	name:                   string,
	// Поля ниже используются только если kind == .Function
	params:                 [dynamic]^Type,
	return_type:            ^Type,
	// Для туплов:
	elements:               [dynamic]^Type,
	// Для структур
	fields:                 [dynamic]Struct_Field,
	// Для методов/интерфейсов
	methods:                map[string]Symbol_Id,
	// Для структур: список интерфейсов, которые они реализовали
	implemented_interfaces: [dynamic]^Type,
	// Для интерфейсов: какие методы они требуют
	interface_methods:      map[string]^Type,
	element_type:           ^Type,
	key_type:               ^Type,
	value_type:             ^Type,
	infer_id:               int,
	binding:                ^Type,
	// Для kind == .Enum (пользовательский ADT, включая Опцию/Результат из
	// прелюдии — обычные generic-enum'ы) — упорядоченный список вариантов.
	variants:               [dynamic]Type_Variant,
	// Индекс имени варианта в `variants` — заполняется вместе с variants,
	// избавляет от линейного поиска по вариантам в нескольких местах.
	variant_index:          map[string]int,
	// Symbol_Id generic-декларации (Struct_Decl/Enum_Decl), от которой
	// произведён этот Type; INVALID_SYMBOL для НЕ-generic типов. Нужен
	// unify_types/types_are_equal: у рекурсивных generic-типов (тип
	// Список[T] = структура следующий: Опция(Список(T)) конец) self-ссылка
	// внутри ОДНОЙ инстанциации канонизируется через generic_instance_cache
	// только ПОСЛЕ полной унификации конструктора. До этого две разные
	// инстанциации одного объявления — физически разные ^Type-указатели,
	// хотя семантически один тип; identity-only сравнение (.Struct/.Enum
	// case) сочло бы их несовместимыми. Фоллбек на структурное сравнение
	// разрешён ТОЛЬКО при совпадении generic_origin (не по имени — коллизия
	// имён между модулями не должна давать ложный "совместим").
	generic_origin:         Symbol_Id,
	// true для InferVar, созданного как ОБЪЯВЛЕННЫЙ type-параметр generic-
	// декларации (T/E шаблона, общего на весь граф в ctx.res.symbol_types[
	// sym]), а не свежий per-call InferVar. bind_infer_var не пишет .binding
	// на такой InferVar (не мутирует шаблон), но считает unify успешным —
	// иначе одно случайное совпадение навсегда зацементировало бы T/E
	// шаблона для всей остальной программы (шаблон один на граф).
	is_decl_param:          bool,
	// Bounded traits: список интерфейсов, которые ОБЯЗАН реализовывать
	// конкретный тип, подставляемый вместо этого decl-param InferVar
	// (`[T: Сравниваемое + Печатаемое]`). Пусто у всех типов, кроме
	// bounded decl-param InferVar — заполняется в make_decl_type_params.
	// НЕ используется для method_lookup (это делает только конкретный
	// тип на этапе мономорфизации, см. core/monomorphize.odin) — только
	// для type_satisfies_interface на этапе абстрактной проверки тела.
	required_interfaces:   [dynamic]^Type,
	// Стадия 51 (FFI, ff_структура): nil для ОБЫЧНЫХ структур — заполнено
	// ТОЛЬКО для `тип X = ff_структура ... конец` (см. Struct_Decl.is_ffi,
	// parser.odin), позиционно параллельно `fields` — marshal-кинд
	// КАЖДОГО поля (Целое(N)/Число(N)), нужен VM-маршаллингу для упаковки/
	// распаковки сырого C-буфера (core/vm_ffi_native.odin).
	ffi_field_kinds:        []Foreign_Marshal_Kind,
	// Составной ^Ffi_Type (libffi, FFI_TYPE_STRUCT + elements) для ЭТОЙ
	// ff_структура — лениво строится и КЭШИРУЕТСЯ здесь при первом
	// использовании в `внешний`-вызове (тот же паттерн, что Foreign_
	// Decl.compiled_fn/Foreign_Function.cif) — opaque rawptr (не ^Ffi_
	// Type напрямую): type_cheker.odin общий для native/wasm, а ffi_
	// bindings.odin (реальный Ffi_Type) — #+build !js.
	ffi_composite:          rawptr,
	// Байтовые offset'ы полей внутри составного буфера (ffi_get_struct_
	// offsets), тот же кэш-момент, что ffi_composite, позиционно
	// параллельно fields/ffi_field_kinds.
	ffi_offsets:            []uint,
}

// Ищет позицию варианта по имени в enum-типе (обычном или synth-view
// Опции/Результата). Единая точка вместо линейного поиска по variants.
variant_index :: proc(enum_type: ^Type, name: string) -> (int, bool) {
	idx, ok := enum_type.variant_index[name]
	return idx, ok
}

Struct_Field :: struct {
	name: string,
	type: ^Type,
}

// Интернированные базовые типы
TY_NUM := &Type{kind = .Number, name = "Число"}
TY_INT := &Type{kind = .Integer, name = "Целое"}
TY_BOOL := &Type{kind = .Bool, name = "Булево"}
TY_VOID := &Type{kind = .Void, name = "Пусто"}
TY_NEVER := &Type{kind = .Never, name = "Никогда"}
TY_STRING := &Type{kind = .String, name = "Строка"}
TY_ERROR := &Type{kind = .Error, name = "Ошибка"}
TY_FILE := &Type{kind = .File, name = "Файл"}
TY_CONNECTION := &Type{kind = .Connection, name = "Соединение"}
TY_POISON := &Type{kind = .Poison, name = "?ошибка?"}

// Имя базового типа в аннотации → интернированный Type. Fixed-size array
// вместо map: global map-литералы в Odin по умолчанию запрещены (dynamic-
// type literal), а для нескольких записей линейный поиск не хуже hash-lookup.
Base_Type_Entry :: struct {
	name: string,
	typ:  ^Type,
}

BASE_TYPES := [?]Base_Type_Entry {
	{"Число", TY_NUM},
	{"Целое", TY_INT},
	{"Булево", TY_BOOL},
	{"Строка", TY_STRING},
	{"Пусто", TY_VOID},
	{"Ошибка", TY_ERROR},
	{"Никогда", TY_NEVER},
	{"Файл", TY_FILE},
	{"Соединение", TY_CONNECTION},
}

lookup_base_type :: proc(name: string) -> (^Type, bool) {
	for entry in BASE_TYPES {
		if entry.name == name do return entry.typ, true
	}
	return nil, false
}

// Построение составных типов держим в одном месте, чтобы имена и ссылки
// формировались одинаково во всех ветках type checker'а.
new_function_type :: proc(params: [dynamic]^Type, return_type: ^Type) -> ^Type {
	t := new(Type)
	t.kind = .Function
	t.name = "Function"
	t.params = params
	t.return_type = return_type
	return t
}

new_array_type :: proc(element_type: ^Type) -> ^Type {
	t := new(Type)
	t.kind = .Array
	t.element_type = element_type
	t.name = fmt.tprintf("Массив(%s)", element_type.name)
	return t
}

new_map_type :: proc(key_type: ^Type, value_type: ^Type) -> ^Type {
	t := new(Type)
	t.kind = .Map
	t.key_type = key_type
	t.value_type = value_type
	t.name = fmt.tprintf("Соответствие(%s, %s)", key_type.name, value_type.name)
	return t
}

is_valid_map_key_type :: proc(t: ^Type) -> bool {
	typ := prune_type(t)
	return typ.kind == .Number || typ.kind == .Integer || typ.kind == .Bool || typ.kind == .String
}

// Стадия 24: Процесс(T) — тот же приём, что new_array_type/new_map_type
// (builtin generic-тип, T просто хранится полем на ^Type, БЕЗ InferVar/
// Type_Scheme/instantiate_scheme — та инфраструктура нужна только для
// пользовательских Struct/Enum-деклараций).
new_process_type :: proc(message_type: ^Type) -> ^Type {
	t := new(Type)
	t.kind = .Process
	t.element_type = message_type
	t.name = fmt.tprintf("Процесс(%s)", message_type.name)
	return t
}

// Стадия 49 (FFI): Указатель(T) — тот же приём, что new_process_type
// выше, T чисто фантомный (см. Type_Kind.Pointer).
new_pointer_type :: proc(pointee_type: ^Type) -> ^Type {
	t := new(Type)
	t.kind = .Pointer
	t.element_type = pointee_type
	t.name = fmt.tprintf("Указатель(%s)", pointee_type.name)
	return t
}

// --- КОНТЕКСТ ---

Variant_Call_Info :: struct {
	owner_type: ^Type,
	tag_index:  int,
}

Call_Kind :: enum {
	Builtin,
	Method_Struct,
	Method_Interface,
	Method_Collection,
	Constructor_Struct,
	Constructor_Variant,
	Print_Value,
	// Стадия 24 (actor model): отправить(процесс, сообщение), где T
	// сообщения реализует Копируемое — вставить .клонировать()(сообщение)
	// ПЕРЕД builtin'ом, компилировать в "отправить_без_копии" (не
	// "отправить" — иначе runtime reflective copy исказил бы намеренно
	// не скопированные пользователем поля).
	Send_Copy,
}

// Стадия 23 (Итерируемое): какую форму компилировать для конкретного
// For_In_Stmt — решается typecheck'ом (знает тип `в`-выражения), читается
// compiler.odin. Fast_Array — тот же байткод, что раньше строил parser
// (idx-счётчик + .длина() + [idx]), просто эмитится в compiler.odin
// напрямую, а не десахаривается на этапе парсинга. Iterator_Protocol —
// повторный вызов .следующий() + Match_Tag/Get_Variant_Field на Опция
// (тот же опкод, что использует компиляция `выбор`, без синтетического
// Match_Expr узла).
For_In_Kind :: enum {
	Fast_Array,
	Iterator_Protocol,
}

For_In_Info :: struct {
	kind:            For_In_Kind,
	// Iterator_Protocol: Symbol_Id метода следующий() конкретного impl'а
	// (для поиска function pointer в registry, тот же путь, что
	// Method_Struct).
	next_method_sym: Symbol_Id,
}

// Единая точка истины про то, как Call_Expr (или bare Ident/Property для
// нульарных конструкторов вариантов) должен компилироваться. Раньше это
// было 6 разных map'ов на Type_Ctx (is_constructor, method_calls,
// interface_calls, collection_calls, builtin_calls, variant_ctors) —
// компилятор проверял их последовательно, порядок неявно кодировал
// приоритет. Обычный вызов функции (Call_Kind отсутствует в записи —
// значит запись просто не создаётся) остаётся default-веткой.
Call_Info :: struct {
	kind:       Call_Kind,
	symbol_ref: Symbol_Id,         // Method_Struct, Print_Value (вСтроку, если implements Печатаемое)
	text_name:  string,            // Builtin, Method_Interface, Method_Collection, Print_Value (реальный builtin: печать/строка)
	variant:    Variant_Call_Info, // Constructor_Variant
}

Match_Arm_Kind :: enum {
	Wildcard,
	Binder,
	Constructor,
	Literal,
	// `выбор точка { Точка(1, x) -> ... }` — структура вместо enum-варианта.
	// В отличие от .Constructor, тут нет тега (у структуры одна форма) —
	// компилятор не эмитит .Match_Tag, сразу распаковывает поля через
	// .Get_Property и рекурсивно проверяет sub_patterns.
	Struct_Constructor,
}

Pattern_Info :: struct {
	kind:         Match_Arm_Kind,
	tag_index:    int,
	binder_sym:   Symbol_Id,
	// Для конструктора: рекурсивные под-шаблоны, по одному на поле варианта.
	sub_patterns: [dynamic]Pattern_Info,
	span:         Span,
	// Для .Literal: сам литерал (Number_Expr/String_Expr/Boolean_Expr) —
	// compiler.odin компилирует его как обычное выражение (emit_constant
	// через compile_expr) и сравнивает через .Equal, тот же опкод, что уже
	// делает структурное сравнение для оператора == (value_equals, vm.odin).
	literal_expr: Expr,
	// Два родственных, но РАЗНЫХ вопроса про покрытие — заполняются снизу
	// вверх в classify_pattern (рекурсивно):
	//
	// - fields_fully_covered: ДАНО, что тег/форма уже зафиксирована этим
	//   шаблоном (для Constructor — конкретный tag_index, для Struct_
	//   Constructor — единственная форма структуры) — покрывают ли ВСЕ
	//   под-шаблоны СВОИ поля целиком? Это то, что нужно check_match_
	//   coverage на ВЕРХНЕМ уровне ветки: "засчитать covered[tag_index]"
	//   не зависит от того, сколько ВСЕГО вариантов у enum'а — это
	//   отдельно трекает covered[]-массив по каждой ветке.
	// - is_exhaustive: покрывает ли этот шаблон ВЕСЬ домен СВОЕГО
	//   ожидаемого типа целиком (а не только "свой тег") — для Wildcard/
	//   Binder то же, что fields_fully_covered; для Constructor — ТОЛЬКО
	//   если у enum'а ровно один вариант (иначе один тег не покрывает
	//   остальные), даже если fields_fully_covered истинно. Нужен, когда
	//   ЭТОТ шаблон сам используется как под-шаблон РОДИТЕЛЯ на уровень
	//   выше (`Событие.Клик(Точка(_, _))` — родитель Событие.Клик читает
	//   is_exhaustive у Точка(_, _), а не fields_fully_covered у себя
	//   самого) — раньше (Стадия 25/29/31) вложенный Constructor/Struct_
	//   Constructor под-шаблон ВСЕГДА считался "не покрывает", даже если
	//   сам исчерпывающий — консервативное, но раздражающее пользователя
	//   упрощение, снятое здесь.
	fields_fully_covered: bool,
	is_exhaustive:        bool,
}

classify_pattern :: proc(ctx: ^Type_Ctx, pattern: Pattern, expected_type: ^Type) -> Pattern_Info {
	info := Pattern_Info {
		tag_index = -1,
	}
	switch pat in pattern {
	case ^Error_Pattern:
		// Уже отрапортовано парсером — трактуем как wildcard, чтобы не
		// каскадировать вторичные диагностики (exhaustiveness и т.п.).
		info.span = pat.span
		info.kind = .Wildcard
		info.fields_fully_covered = true
		info.is_exhaustive = true
	case ^Pattern_Wildcard:
		info.span = pat.span
		info.kind = .Wildcard
		info.fields_fully_covered = true
		info.is_exhaustive = true
	case ^Pattern_Literal:
		info.span = pat.span
		expected := prune_type(expected_type)
		if expected.kind != .Number &&
		   expected.kind != .Integer &&
		   expected.kind != .String &&
		   expected.kind != .Bool {
			report(
				ctx,
				pat.span,
				"Type Error: литеральный шаблон ожидает Число/Целое/Строку/Булево, получено '%s'",
				expected.name,
			)
			info.kind = .Wildcard
			info.fields_fully_covered = true
			info.is_exhaustive = true
			return info
		}
		check_expr(ctx, pat.value, expected)
		info.kind = .Literal
		info.literal_expr = pat.value
		// Один литерал никогда не покрывает домен целиком — даже Булево
		// (у него всего 2 значения, но конкретный литеральный под-шаблон
		// фиксирует ровно ОДНО из них). Настоящая 2-значная exhaustiveness
		// для Булево считается отдельно, на уровне ВЕТОК match'а (см.
		// bool_covered в check_match_coverage) — не здесь, не per-шаблон.
		info.fields_fully_covered = false
		info.is_exhaustive = false
	case ^Pattern_Ident:
		info.span = pat.span
		expected := prune_type(expected_type)
		if expected.kind == .Enum {
			// Стадия 7 Phase F: Опция/Результат — обычные .Enum (прелюдия),
			// synth_enum_view (виртуальный enum-вид) больше не нужен.
			enum_view := expected
			tag, found := variant_index(enum_view, pat.name)
			if found {
				if len(enum_view.variants[tag].fields) != 0 {
					report(
						ctx,
						pat.span,
						"Type Error: вариант '%s.%s' в шаблоне без скобок, но у него есть поля",
						enum_view.name,
						pat.name,
					)
				}
				info.kind = .Constructor
				info.tag_index = tag
				info.sub_patterns = make([dynamic]Pattern_Info)
				// Нет полей — нечему не покрыться, тег зафиксирован целиком.
				info.fields_fully_covered = true
				// Но покрывает ВЕСЬ enum (для использования этого шаблона
				// как под-шаблона родителя) только если у enum'а ровно один
				// вариант — иначе это всего лишь ОДИН тег из нескольких.
				info.is_exhaustive = len(enum_view.variants) == 1
				return info
			}
		}
		binder_sym := ctx.res.pattern_binders[pat]
		if binder_sym == INVALID_SYMBOL {
			report(ctx, pat.span, "Type Error: не разрешён шаблон '%s'", pat.name)
			info.kind = .Wildcard
			info.fields_fully_covered = true
			info.is_exhaustive = true
			return info
		}
		info.kind = .Binder
		info.binder_sym = binder_sym
		info.fields_fully_covered = true
		info.is_exhaustive = true
		ctx.res.symbol_types[binder_sym] = expected_type
	case ^Pattern_Constructor:
		info.span = pat.span
		expected := prune_type(expected_type)
		if expected.kind == .Struct {
			// `Точка(1, x)` на Struct-subject: не enum-тег, а разбор полей
			// по ПОРЯДКУ ОБЪЯВЛЕНИЯ — тот же принцип, что и `пер Точка(a,
			// b) = ...` (Стадия 30), но с полноценными под-шаблонами
			// (литералы/`_`/биндеры/вложенные конструкторы), а не только
			// именами.
			if pat.name != expected.name {
				report(
					ctx,
					pat.span,
					"Type Error: шаблон-конструктор '%s' не совпадает со структурой '%s'",
					pat.name,
					expected.name,
				)
				info.kind = .Wildcard
				info.fields_fully_covered = true
				info.is_exhaustive = true
				return info
			}
			if len(pat.field_names) > 0 {
				// Именованные поля (`Точка(x: 1, y: _)`) — частичные:
				// неупомянутые поля структуры трактуются как неявный `_`
				// (не влияют на exhaustiveness этой ветки — is_exhaustive
				// неявного wildcard'а всегда true). Порядок в info.
				// sub_patterns ВСЕГДА позиционный (по объявлению структуры,
				// не по порядку в шаблоне) — compile_pattern (compiler.odin)
				// продолжает работать НЕИЗМЕННО, читает sub_patterns[i] для
				// поля #i через .Get_Property, знать не знает про имена.
				info.kind = .Struct_Constructor
				info.sub_patterns = make([dynamic]Pattern_Info, len(expected.fields))
				matched := make([dynamic]bool, len(expected.fields), context.temp_allocator)
				info.fields_fully_covered = true
				for field_name, i in pat.field_names {
					field_idx := -1
					for f, fi in expected.fields {
						if f.name == field_name {
							field_idx = fi
							break
						}
					}
					if field_idx == -1 {
						report(
							ctx,
							pat.span,
							"Type Error: у структуры '%s' нет поля '%s'",
							expected.name,
							field_name,
						)
						continue
					}
					if matched[field_idx] {
						report(
							ctx,
							pat.span,
							"Type Error: поле '%s' указано в шаблоне повторно",
							field_name,
						)
						continue
					}
					matched[field_idx] = true
					sub := classify_pattern(ctx, pat.args[i], expected.fields[field_idx].type)
					info.sub_patterns[field_idx] = sub
					if !sub.is_exhaustive do info.fields_fully_covered = false
				}
				// Неупомянутые поля — неявный `_`, не сужают покрытие.
				for was_matched, i in matched {
					if !was_matched {
						info.sub_patterns[i] = Pattern_Info {
							kind                  = .Wildcard,
							tag_index             = -1,
							span                  = pat.span,
							fields_fully_covered  = true,
							is_exhaustive         = true,
						}
					}
				}
				info.is_exhaustive = info.fields_fully_covered
				return info
			}
			if len(pat.args) != len(expected.fields) {
				report(
					ctx,
					pat.span,
					"Type Error: у структуры '%s' %d полей, в шаблоне '%s(...)' %d аргументов",
					expected.name,
					len(expected.fields),
					pat.name,
					len(pat.args),
				)
				info.kind = .Wildcard
				info.fields_fully_covered = true
				info.is_exhaustive = true
				return info
			}
			info.kind = .Struct_Constructor
			info.sub_patterns = make([dynamic]Pattern_Info)
			info.fields_fully_covered = true
			for arg_pat, i in pat.args {
				sub := classify_pattern(ctx, arg_pat, expected.fields[i].type)
				append(&info.sub_patterns, sub)
				// У структуры одна форма (нет тегов) — целиком покрывает
				// поле, только если ВСЕ под-шаблоны рекурсивно покрывают
				// СВОИ поля/тип целиком (Pattern_Info.is_exhaustive — не
				// fields_fully_covered: вложенный Constructor-подшаблон
				// сам обязан быть исчерпывающим для СВОЕГО типа, не только
				// для своего тега).
				if !sub.is_exhaustive do info.fields_fully_covered = false
			}
			// Структура — одна форма, нет тега-гейта: is_exhaustive совпадает
			// с fields_fully_covered.
			info.is_exhaustive = info.fields_fully_covered
			return info
		}
		if expected.kind != .Enum {
			report(
				ctx,
				pat.span,
				"Type Error: шаблон-конструктор '%s' ожидает значение перечисления или структуры, получено '%s'",
				pat.name,
				expected.name,
			)
			info.kind = .Wildcard
			info.fields_fully_covered = true
			info.is_exhaustive = true
			return info
		}
		if len(pat.field_names) > 0 {
			// У вариантов перечисления нет ИМЁН полей (Variant_Decl.types —
			// список типов, не именованных полей, в отличие от Struct_Decl.
			// fields) — именованная форма шаблона тут в принципе не может
			// иметь смысла.
			report(
				ctx,
				pat.span,
				"Type Error: вариант перечисления '%s' не имеет именованных полей — только позиционные",
				pat.name,
			)
			info.kind = .Wildcard
			info.fields_fully_covered = true
			info.is_exhaustive = true
			return info
		}
		enum_view := expected
		tag, found := variant_index(enum_view, pat.name)
		if !found {
			report(
				ctx,
				pat.span,
				"Type Error: вариант '%s' не найден в '%s'",
				pat.name,
				enum_view.name,
			)
			info.kind = .Wildcard
			info.fields_fully_covered = true
			info.is_exhaustive = true
			return info
		}
		expected_fields := enum_view.variants[tag].fields
		if len(pat.args) != len(expected_fields) {
			report(
				ctx,
				pat.span,
				"Type Error: у варианта '%s.%s' ожидалось %d аргументов в шаблоне, получено %d",
				enum_view.name,
				pat.name,
				len(expected_fields),
				len(pat.args),
			)
			info.kind = .Wildcard
			info.fields_fully_covered = true
			info.is_exhaustive = true
			return info
		}
		info.kind = .Constructor
		info.tag_index = tag
		info.sub_patterns = make([dynamic]Pattern_Info)
		info.fields_fully_covered = true
		for arg_pat, i in pat.args {
			sub := classify_pattern(ctx, arg_pat, expected_fields[i])
			append(&info.sub_patterns, sub)
			if !sub.is_exhaustive do info.fields_fully_covered = false
		}
		// Один конкретный тег покрывает ВЕСЬ enum (для использования этого
		// шаблона как под-шаблона родителя), только если у enum'а ровно
		// один вариант — иначе остальные теги не покрыты этим шаблоном,
		// даже если fields_fully_covered истинно (см. тот же принцип у
		// голого варианта без скобок выше).
		info.is_exhaustive = info.fields_fully_covered && len(enum_view.variants) == 1
	}
	return info
}

// Чистая процедура: получает тип-subject и arm_infos, проверяет
// исчерпываемость, недостижимость, позицию `_`. Копит ошибки через
// report() вместо немедленного panic — но продолжает разбор остальных
// веток, чтобы отчитаться сразу обо всех проблемах match'а.
check_match_coverage :: proc(
	ctx: ^Type_Ctx,
	match_span: Span,
	subject_type: ^Type,
	arm_infos: [dynamic]Pattern_Info,
) {
	total := len(subject_type.variants)
	covered := make([dynamic]bool, total, context.temp_allocator)
	catch_all := false
	// Булево — единственный литеральный тип с конечным (2-элементным) доменом,
	// поэтому для него, в отличие от Число/Строка, возможна настоящая
	// exhaustiveness-проверка без обязательного catch_all: [0]=ложь, [1]=истина.
	bool_covered: [2]bool

	for pi, arm_idx in arm_infos {
		if catch_all {
			report(
				ctx,
				pi.span,
				"Type Error: ветка выбора #%d недостижима — все случаи покрыты выше",
				arm_idx + 1,
			)
			continue
		}
		switch pi.kind {
		case .Wildcard:
			catch_all = true
			if arm_idx != len(arm_infos) - 1 {
				report(
					ctx,
					pi.span,
					"Type Error: '_' в выборе должен быть только последней веткой",
				)
			}
		case .Binder:
			catch_all = true
			if arm_idx != len(arm_infos) - 1 {
				report(
					ctx,
					pi.span,
					"Type Error: биндер-ветка выбора должна быть только последней — она покрывает все случаи",
				)
			}
		case .Constructor:
			if pi.tag_index < 0 || pi.tag_index >= total {
				// Внутренний инвариант (classify_pattern всегда даёт валидный
				// tag для .Constructor) — не user-facing, остаётся panic.
				fmt.panicf(
					"Type Error: внутренняя ошибка — тег варианта вне диапазона",
				)
			}
			// pi.fields_fully_covered — рекурсивно посчитан в classify_pattern:
			// тег УЖЕ зафиксирован (pi.tag_index) на этом верхнем уровне,
			// вопрос только "покрыты ли ЕГО поля целиком" — не "покрывает
			// ли этот единственный тег ВЕСЬ enum" (это отдельно трекает
			// covered[]-массив по каждой ветке). Рекурсия учитывает вложенный
			// Constructor/Struct_Constructor под-шаблон, если сам
			// исчерпывающий для СВОЕГО типа (`Событие.Клик(Точка(_, _))`).
			if pi.fields_fully_covered && covered[pi.tag_index] {
				report(
					ctx,
					pi.span,
					"Type Error: вариант '%s.%s' покрыт повторно в ветке #%d",
					subject_type.name,
					subject_type.variants[pi.tag_index].name,
					arm_idx + 1,
				)
			}
			if pi.fields_fully_covered do covered[pi.tag_index] = true
		case .Struct_Constructor:
			// У структуры одна форма (не enum-теги) — единственный вопрос
			// исчерпываемости: покрывает ли эта ветка ВСЕ поля целиком
			// (pi.fields_fully_covered, рекурсивно посчитан в
			// classify_pattern — вложенный Constructor/Struct_Constructor
			// под-шаблон тоже зачитывается, если сам исчерпывающий для
			// СВОЕГО типа). Если да — эквивалентно голому `_`/биндеру,
			// catch_all и обязана быть последней. Если нет (как `Точка(1,
			// x)` — первое поле сужено литералом) — просто ещё одна
			// частичная ветка, ничего не покрывает сама по себе, нужна
			// финальная catch-all ветка (см. конец функции).
			if pi.fields_fully_covered {
				catch_all = true
				if arm_idx != len(arm_infos) - 1 {
					report(
						ctx,
						pi.span,
						"Type Error: ветка-конструктор структуры, покрывающая все поля, должна быть только последней — она покрывает все случаи",
					)
				}
			}
		case .Literal:
			// Число/Строка: домен неперечислим, ничего не покрывает —
			// единственная гарантия exhaustiveness для них — обязательный
			// catch_all (проверка ниже). Булево — особый случай, покрываем
			// конкретное значение.
			if subject_type.kind == .Bool {
				if b, ok := pi.literal_expr.(^Boolean_Expr); ok {
					idx := b.value ? 1 : 0
					if bool_covered[idx] {
						report(
							ctx,
							pi.span,
							"Type Error: значение '%s' покрыто повторно в ветке #%d",
							b.value ? "истина" : "ложь",
							arm_idx + 1,
						)
					}
					bool_covered[idx] = true
				}
			}
		}
	}

	if catch_all do return

	if subject_type.kind == .Bool {
		if bool_covered[0] && bool_covered[1] do return // оба значения покрыты — действительно исчерпывающе
		missing := make([dynamic]string, context.temp_allocator)
		if !bool_covered[0] do append(&missing, "ложь")
		if !bool_covered[1] do append(&missing, "истина")
		joined := strings.join(missing[:], ", ", context.temp_allocator)
		report(ctx, match_span, "Type Error: выбор не покрывает значения: %s", joined)
		return
	}

	if subject_type.kind == .Struct {
		// У структуры одна форма — ни одна ветка выше не была fully_covers
		// (иначе catch_all уже сработал и мы вернулись раньше), значит все
		// они частично сужены (литералами/вложенными конструкторами) и
		// вместе не гарантируют покрытие. Нужна финальная catch-all ветка.
		report(
			ctx,
			match_span,
			"Type Error: выбор по '%s' должен заканчиваться веткой '_', биндером или конструктором, покрывающим все поля (например '%s(_, _)')",
			subject_type.name,
			subject_type.name,
		)
		return
	}

	if subject_type.kind != .Enum {
		// Число/Строка — домен не перечислим, в отличие от enum'а (и
		// Булево выше) тут нет способа перечислить "что осталось",
		// единственная гарантия exhaustiveness — обязательная ветка
		// `_`/биндер в конце.
		report(
			ctx,
			match_span,
			"Type Error: выбор по '%s' должен заканчиваться веткой '_' или биндером — набор литеральных веток не может быть исчерпывающим",
			subject_type.name,
		)
		return
	}

	missing := make([dynamic]string, context.temp_allocator)
	for was_covered, i in covered {
		if !was_covered do append(&missing, subject_type.variants[i].name)
	}
	if len(missing) > 0 {
		joined := strings.join(missing[:], ", ", context.temp_allocator)
		report(ctx, match_span, "Type Error: выбор не покрывает варианты: %s", joined)
	}
}

Severity :: enum {
	Error,
	Warning,
}

Diagnostic :: struct {
	severity: Severity,
	span:     Span,
	message:  string,
}

Type_Ctx :: struct {
	res:              ^Resolver_Ctx,
	node_types:       map[Expr]^Type,
	property_indices: map[Expr]int,
	interface_casts:  map[Expr]^Type,
	call_infos:       map[Expr]Call_Info,
	match_arm_infos:  map[^Match_Expr][dynamic]Pattern_Info,
	// Именованная деструктуризация (Стадия 37, `пер Тип(x: a, y: b) =
	// ...`) — .Get_Property-индекс поля для КАЖДОГО symbol'а в ctx.res.
	// let_destructure_syms[stmt] (тот же порядок). Для позиционной формы
	// (структурной или тупл) — тождественно [0, 1, 2, ...]; для именованной
	// — реальный индекс поля по имени, возможно НЕ по порядку в шаблоне
	// (частичная форма — не все поля структуры обязаны быть перечислены).
	// compiler.odin читает вместо голого `i` из цикла — единственная
	// правка в кодогене, сам .Get_Property/Set_Local-паттерн не меняется.
	let_destructure_field_indices: map[Stmt][dynamic]int,
	// Стадия 23 (Итерируемое): решение "как компилировать этот for-in"
	// (fast-path Массив vs iterator-protocol) — тот же принцип, что
	// Call_Info: не десахаривает AST, аннотирует существующий узел,
	// compiler.odin читает при кодогене.
	for_in_infos:     map[Stmt]For_In_Info,
	current_return:   ^Type,
	loop_depth:       int,
	next_infer_id:    int,
	diagnostics:      [dynamic]Diagnostic,
	// Полиморфные схемы для let-биндингов лямбд (Стадия 7 Phase A). Отдельно
	// от symbol_types (не меняем её тип — ~25 читателей в 4 файлах), карта
	// заполняется только для обобщаемых лямбд, читается только в
	// infer_ident_expr.
	symbol_schemes:   map[Symbol_Id]Type_Scheme,
	// Стадия 7 Phase A: узел ^Lambda_Expr (обёрнутый в Expr), которому СЕЙЧАС
	// разрешено остаться с непривязанными InferVar — потому что вызывающий
	// Let_Stmt сам решит, обобщить их (generalize) или зарепортить ошибку.
	// Ambient-поле save/restore, тот же паттерн, что loop_depth (set перед
	// вложенным вызовом, restore после), только identity вместо счётчика —
	// это даёт check_lambda_expr (см. ensure_type_resolved там) пропустить
	// проверку РОВНО для этой лямбды, а не для любой другой, случайно
	// оказавшейся вложенной внутри её тела (например, bare-лямбда,
	// переданная аргументом без ожидаемого типа, — для неё проверка
	// остаётся строгой).
	allow_unresolved_lambda: Expr,
	// Стадия 48 (замыкания): стек АКТИВНЫХ (сейчас типизируемых) лямбд —
	// push/pop в check_lambda_expr, тот же save/restore-паттерн, что
	// allow_unresolved_lambda чуть выше. `case .Assign:` (infer_binary_
	// expr) читает вершину стека, чтобы запретить присваивание
	// захваченной переменной ВНУТРИ лямбды — см. ctx.res.lambda_captures.
	// Проверять достаточно ТОЛЬКО вершину (самую внутреннюю активную
	// лямбду): резолвер (lookup_symbol_tracking_captures) уже
	// транзитивно прописывает символ в capture-список каждой
	// пересечённой лямбды, так что lambda_captures[вершина] всегда
	// содержит ВСЁ, что снаружи неё, независимо от глубины вложенности.
	current_lambda_stack: [dynamic]Expr,
	// Стадия 7 Phase B: имя→InferVar type-параметров ТЕКУЩЕЙ generic-функции,
	// пока резолвится её сигнатура (ПРОХОД 2) или тело (ПРОХОД 4). nil вне
	// generic-функции. Ambient-поле, тот же save/restore паттерн, что
	// allow_unresolved_lambda — resolve_type_node проверяет его первым для
	// case ^Type_Ident, до поиска в глобальных типах.
	current_type_params: map[string]^Type,
	// Персистентный мост между ПРОХОД 2 и ПРОХОД 4 для одной и той же
	// generic-функции: ПРОХОД 4 должен резолвить T в ТЕ ЖЕ InferVar-узлы,
	// что и сигнатура в ПРОХОД 2 (не свежие) — иначе unify не свяжет тело
	// с сигнатурой. В отличие от current_type_params (ambient, временное)
	// это хранится на весь typecheck_program.
	decl_type_params:        map[Symbol_Id]map[string]^Type,
	// Стадия 7 Phase C: ordered InferVar-список type-параметров generic-
	// структуры в порядке заголовка [A, B, ...] — для позиционной
	// подстановки в explicit-аннотациях (Пара(Число, Строка)).
	// decl_type_params (map) и scheme.forall (порядок структурного обхода
	// полей при generalize, может не совпасть с порядком заголовка, если
	// поля объявлены в другом порядке) для этого не подходят.
	decl_type_param_order: map[Symbol_Id][dynamic]^Type,
	// Кэш инстанциаций generic-структур/enum'ов: (символ декларации +
	// резолвленные type-аргументы) → канонический ^Type. unify_types/
	// types_are_equal сравнивают .Struct/.Enum ТОЛЬКО по identity
	// указателя — без кэша каждое текстуальное вхождение Пара(Число,
	// Строка) получало бы свой ^Type-объект, и они считались бы разными
	// типами.
	generic_instance_cache: map[string]^Type,
	// Стадия 7 Phase D: Symbol_Id generic-декларации, ЧЬЁ ТЕЛО СЕЙЧАС
	// резолвится в ПРОХОД 2 (INVALID_SYMBOL вне этого). Рекурсивная ссылка
	// на СЕБЯ ЖЕ (Дерево(T) внутри Дерево[T]) не может пройти обычную
	// instantiate_type/generic_instance_cache — шаблон ещё не полностью
	// заполнен (мы в процессе). Type_Generic-ветка, встретив ссылку на
	// этот же символ, возвращает ctx.res.symbol_types[sym] напрямую — тот
	// же мутируемый указатель, что ПРОХОД 2 продолжает достраивать
	// append'ом; к моменту реального использования (ПРОХОД 4+) он уже полон.
	currently_declaring_generic: Symbol_Id,
	// Стадия 7: очередь constraint'ов для join-точек (если/иначе, выбор-
	// ветки, элементы массива/соответствия-литералов), см. Constraint/
	// emit_constraint/solve_constraints выше. Дренируется solve_constraints
	// в конце каждой join-точки — не переживает её.
	pending_constraints: [dynamic]Constraint,
	// Стадия 24 (actor model): T сообщений процесса выводится не из
	// сигнатуры (получить() в ней не участвует), а из паттернов `выбор
	// получить()` В ТЕЛЕ функции — ambient-поле, тот же save/restore
	// паттерн, что current_type_params. nil, пока функция не содержит ни
	// одного получить(); первый вызов получить() внутри тела заводит
	// свежий InferVar, все ПОСЛЕДУЮЩИЕ получить() в ЭТОЙ ЖЕ функции
	// переиспользуют его же (один mailbox — один T на функцию).
	current_process_message_var: ^Type,
	// Персистентный (не ambient) результат: T каждой функции, где
	// получить() встретился — заполняется в check_decl_body ПОСЛЕ
	// проверки тела (когда current_process_message_var уже прунится).
	// Читается infer_spawn_expr для `запусти <вызов>`.
	process_message_types: map[Symbol_Id]^Type,
	// Обратная карта к res.decl_symbols (только Function_Decl) —
	// заполняется в ПРОХОД 2 целиком, ДО начала ПРОХОД 4 body-checking.
	// Нужна ensure_body_checked: `запусти f(...)`, встреченный ДО того,
	// как ПРОХОД 4 сам дошёл до f (f объявлена позже по файлу), должен
	// суметь типизировать f ПРЯМО СЕЙЧАС — T процесса не зависит от
	// вызывающих (только от получить()-паттернов внутри f), так что
	// внеочередная проверка тела f корректна и идемпотентна (см. checked_
	// bodies).
	symbol_to_func_decl: map[Symbol_Id]^Function_Decl,
	// Мемоизация: тело каждой функции проверяется РОВНО один раз — либо
	// обычным ПРОХОД 4 (по порядку деклараций), либо раньше — по запросу
	// ensure_body_checked из запусти. Без этого функция, спавненная ДО
	// своего "родного" места в ПРОХОД 4, проверилась бы дважды (дублируя
	// diagnostics).
	checked_bodies: map[Symbol_Id]bool,
	// Bounded traits: Call_Expr вызова bounded generic-функции -> конкретные
	// резолвленные типы её type-параметров (в порядке Function_Decl.
	// type_params), заполняется в infer_bounded_generic_call. Читает
	// core/monomorphize.odin — по этой карте driver находит, какие
	// инстанциации нужно скомпилировать, и compiler.odin — на call site
	// нужен ключ инстанциации вместо обычного symbol_registry_key.
	generic_call_instantiations: map[Expr][dynamic]^Type,
	// true во время АБСТРАКТНОГО прохода тела generic-декларации
	// (check_decl_body, T/E ещё decl-param InferVar) — см. пометку там.
	// infer_bounded_generic_call читает: не удалось вывести конкретный тип
	// параметра — при true это ожидаемо (рекурсия/вложенный generic-вызов
	// внутри абстрактного тела), не diagnostic; при false — настоящая
	// ошибка вызывающего кода. false во время typecheck клона
	// (monomorphize_one зовёт check_function_body напрямую, не через
	// check_decl_body).
	in_abstract_generic_body:    bool,
}

new_type_ctx :: proc(res: ^Resolver_Ctx) -> Type_Ctx {
	ctx := Type_Ctx {
		res = res,
		node_types = make(map[Expr]^Type),
		property_indices = make(map[Expr]int),
		interface_casts = make(map[Expr]^Type),
		call_infos = make(map[Expr]Call_Info),
		match_arm_infos = make(map[^Match_Expr][dynamic]Pattern_Info),
		diagnostics = make([dynamic]Diagnostic),
		symbol_schemes = make(map[Symbol_Id]Type_Scheme),
		decl_type_params = make(map[Symbol_Id]map[string]^Type),
		decl_type_param_order = make(map[Symbol_Id][dynamic]^Type),
		generic_instance_cache = make(map[string]^Type),
		currently_declaring_generic = INVALID_SYMBOL,
		pending_constraints = make([dynamic]Constraint),
		process_message_types = make(map[Symbol_Id]^Type),
		symbol_to_func_decl = make(map[Symbol_Id]^Function_Decl),
		checked_bodies = make(map[Symbol_Id]bool),
		generic_call_instantiations = make(map[Expr][dynamic]^Type),
		let_destructure_field_indices = make(map[Stmt][dynamic]int),
	}
	// Стадия 7 Phase F: см. Resolver_Ctx.prelude_generic_order — прелюдия
	// типизируется в СВОЁМ отдельном tc_ctx (ensure_prelude), любой другой
	// Type_Ctx нуждается в скопированном ordered type-параметре Опции/
	// Результата, иначе Опция(T)/Результат(T,E) в пользовательском модуле
	// не резолвится как generic-тип. Через res (не res.module_graph) —
	// module_graph resolve_program обнуляет после однократного резолва
	// (см. там), а res переживает весь typecheck_program.
	for sym, ordered in res.prelude_generic_order {
		ctx.decl_type_param_order[sym] = ordered
	}
	// Стадия 7 Phase F Этап 4: см. Resolver_Ctx.prelude_symbol_schemes —
	// без этого методы Опции/Результата с собственным generalize()-выводом
	// (напр. "ожидать" -> T) вызывались бы с шаблонным, не свежим T.
	for sym, scheme in res.prelude_symbol_schemes {
		ctx.symbol_schemes[sym] = scheme
	}
	// Найдено при отладке Стадии 22 (не её баг, см. Module_Graph.symbol_schemes):
	// схемы generic-функций/методов УЖЕ типизированных модулей графа — иначе
	// cross-module вызов экспортированной generic-функции получал бы
	// НЕ-инстанцированный, общий на все вызовы тип (см. infer_call_expr,
	// case .Function внутри Property_Expr-ветки). module_graph может быть
	// nil здесь (resolve_program's throwaway одномодульный граф, см. его
	// комментарий "resolved.module_graph = nil") — тогда просто нечего копировать.
	if res.module_graph != nil {
		for sym, scheme in res.module_graph.symbol_schemes {
			ctx.symbol_schemes[sym] = scheme
		}
		// Стадия 45: T процессов уже протипизированных модулей графа —
		// без этого `запусти Модуль.функция(...)`, где функция сама
		// вызывает получить() в своём теле, не видело бы её T (см.
		// Module_Graph.process_message_types).
		for sym, t in res.module_graph.process_message_types {
			ctx.process_message_types[sym] = t
		}
	}
	return ctx
}

// Копит ошибку вместо немедленного panic — так typecheck_program успевает
// пройти всю программу и показать все ошибки разом, а не только первую.
// Возвращает TY_POISON: он unify'ится с чем угодно (см. unify_types),
// поэтому один репорт не плодит цепочку производных ошибок у всех, кто
// читает результат этого выражения дальше.
//
// Дедуп по (span, message): check_function_body проверяет тело функции
// дважды (infer_block_type + infer_function_body — независимая старая
// избыточность, не связанная с этой стадией), из-за чего один и тот же
// узел мог зарепортиться 2-3 раза подряд. Раньше это было незаметно —
// panic on first срабатывал до второго прохода.
report :: proc(ctx: ^Type_Ctx, span: Span, format: string, args: ..any) -> ^Type {
	msg := fmt.aprintf(format, ..args)
	for d in ctx.diagnostics {
		if d.span == span && d.message == msg do return TY_POISON
	}
	append(&ctx.diagnostics, Diagnostic{severity = .Error, span = span, message = msg})
	return TY_POISON
}

// InferVar - внутренний временный тип. Он не равен Any: позже должен
// связаться с конкретным типом или дать ошибку.
new_infer_var :: proc(ctx: ^Type_Ctx) -> ^Type {
	t := new(Type)
	t.kind = .InferVar
	t.infer_id = ctx.next_infer_id
	t.name = fmt.tprintf("?%d", t.infer_id)
	ctx.next_infer_id += 1
	return t
}

// Полиморфная схема типа (rank-1 let-polymorphism, Стадия 7 Phase A):
// forall — infer_id'ы, обобщённые в let-биндинге; body — тип с этими
// InferVar внутри (сам узел, не копия — копии делает instantiate_type).
Type_Scheme :: struct {
	forall: [dynamic]int,
	body:   ^Type,
}

// `prune_type` снимает все промежуточные связывания и возвращает фактический тип.
prune_type :: proc(t: ^Type) -> ^Type {
	if t == nil do return nil
	if t.kind == .InferVar && t.binding != nil {
		t.binding = prune_type(t.binding)
		return t.binding
	}
	return t
}

// Нужна для защиты от циклических связываний вида `?T = (... ?T ...)`.
type_contains_infer_var :: proc(t: ^Type, needle: ^Type) -> bool {
	typ := prune_type(t)
	if typ == nil do return false
	if typ == needle do return true

	#partial switch typ.kind {
	case .Function:
		for param in typ.params {
			if type_contains_infer_var(param, needle) do return true
		}
		return type_contains_infer_var(typ.return_type, needle)

	case .Tuple:
		for el in typ.elements {
			if type_contains_infer_var(el, needle) do return true
		}

	case .Array:
		return type_contains_infer_var(typ.element_type, needle)

	case .Map:
		return(
			type_contains_infer_var(typ.key_type, needle) ||
			type_contains_infer_var(typ.value_type, needle) \
		)
	}

	return false
}

// Связывает переменную типа с найденным кандидатом, если это не создает цикл.
bind_infer_var :: proc(var_type: ^Type, target: ^Type) -> bool {
	target_type := prune_type(target)
	if target_type == nil do return false
	if target_type == var_type do return true
	if type_contains_infer_var(target_type, var_type) do return false
	// Стадия 7 Phase F: см. Type.is_decl_param — var_type ЭТО и есть T/E
	// шаблона generic-декларации (общий на весь граф), а не свежий
	// per-call InferVar. Считаем unify успешным (значение структурно
	// совместимо по построению — оно и произошло от T), но НЕ пишем
	// .binding — иначе одно случайное совпадение (напр. это: Опция,
	// переданное в Опция.Есть(x) внутри ДРУГОГО метода) навсегда
	// цементирует T/E шаблона для всей остальной программы.
	if var_type.is_decl_param do return true
	var_type.binding = target_type
	return true
}

// Собирает infer_id непривязанных InferVar, достижимых из t — тот же обход,
// что и type_contains_infer_var, только вместо поиска конкретного needle
// копит все встреченные unbound InferVar (с дедупом). Используется
// generalize'ом (Стадия 7 Phase A).
//
// Стадия 7 Phase D: Struct/Enum могут ссылаться на себя рекурсивно (тип
// Список[T] = структура значение: T следующий: Опция(Список(T)) конец) —
// без visited-множества обход зациклился бы навсегда (SIGSEGV на
// переполнении стека, подтверждено живым тестом на self_ref_struct.ps).
// visited создаётся лениво верхним вызовом (generalize, visited == nil),
// дальше передаётся по цепочке рекурсии.
collect_free_infer_vars :: proc(t: ^Type, out: ^[dynamic]int, visited: ^map[^Type]bool = nil) {
	typ := prune_type(t)
	if typ == nil do return

	if typ.kind == .InferVar {
		for id in out {
			if id == typ.infer_id do return
		}
		append(out, typ.infer_id)
		return
	}

	v := visited
	local_v: map[^Type]bool
	if v == nil {
		local_v = make(map[^Type]bool)
		v = &local_v
	}
	if typ.kind == .Struct || typ.kind == .Enum {
		if v[typ] do return
		v[typ] = true
	}

	#partial switch typ.kind {
	case .Function:
		for param in typ.params do collect_free_infer_vars(param, out, v)
		collect_free_infer_vars(typ.return_type, out, v)
	case .Tuple:
		for el in typ.elements do collect_free_infer_vars(el, out, v)
	case .Array:
		collect_free_infer_vars(typ.element_type, out, v)
	case .Map:
		collect_free_infer_vars(typ.key_type, out, v)
		collect_free_infer_vars(typ.value_type, out, v)
	case .Struct:
		for f in typ.fields do collect_free_infer_vars(f.type, out, v)
	case .Enum:
		for variant in typ.variants {
			for f in variant.fields do collect_free_infer_vars(f, out, v)
		}
	}
}

// Строит полиморфную схему типа из уже выведенного типа лямбды (Стадия 7
// Phase A). Обобщает КАЖДЫЙ InferVar, ещё не связанный после prune_type и
// достижимый из t — без анализа охватывающей среды (environment/free-var
// check). Корректно здесь и только здесь: top-level `функ` получает тип
// исключительно из явной аннотации (function_type_from_decl), инференса
// для них нет — значит нет внешней области видимости с незакрытыми
// InferVar, которые могли бы случайно попасть в forall. Если в будущей
// фазе (generic top-level функции, инференс без аннотаций) это условие
// перестанет выполняться — правило нужно пересмотреть (классическая ML
// ошибка over-eager generalization / value restriction).
generalize :: proc(ctx: ^Type_Ctx, t: ^Type) -> Type_Scheme {
	pruned := prune_type(t)
	forall := make([dynamic]int)
	collect_free_infer_vars(pruned, &forall)
	return Type_Scheme{forall = forall, body = pruned}
}

// Инстанцирует тип из схемы: глубоко копирует t, заменяя InferVar, чей
// infer_id есть в subst, на подставленный свежий InferVar; всё остальное
// (конкретные типы, Struct/Enum/Interface — не входят в forall) возвращает
// тем же указателем без копии. Обходит тот же набор Type_Kind, что
// type_contains_infer_var/collect_free_infer_vars.
//
// Стадия 7 Phase D: Struct/Enum могут ссылаться на себя рекурсивно (тип
// Дерево[T] = перечисление Узел(T, Дерево(T), Дерево(T)) конец) — наивная
// рекурсия зациклилась бы, копируя один и тот же тип бесконечно (SIGSEGV,
// подтверждено живым тестом). visited — memo-карта template-указатель →
// уже-созданная копия: копия регистрируется В НЕЙ ДО рекурсии в свои
// поля/варианты (классический приём глубокого копирования циклического
// графа), так что повторная встреча того же template-указателя внутри
// собственных полей возвращает УЖЕ созданную (пока не до конца
// заполненную) копию вместо попытки построить новую — к моменту, когда
// внешний вызов допишет её поля, все ссылки (включая внутренние на саму
// себя) видят финальное состояние через общий указатель.
instantiate_type :: proc(ctx: ^Type_Ctx, t: ^Type, subst: ^map[int]^Type, visited: ^map[^Type]^Type = nil) -> ^Type {
	pruned := prune_type(t)
	if pruned == nil do return nil

	v := visited
	local_v: map[^Type]^Type
	if v == nil {
		local_v = make(map[^Type]^Type)
		v = &local_v
	}
	if pruned.kind == .Struct || pruned.kind == .Enum {
		if existing, ok := v[pruned]; ok do return existing
	}

	#partial switch pruned.kind {
	case .InferVar:
		if fresh, ok := subst[pruned.infer_id]; ok do return fresh
		return pruned
	case .Function:
		params := make([dynamic]^Type)
		for param in pruned.params do append(&params, instantiate_type(ctx, param, subst, v))
		return new_function_type(params, instantiate_type(ctx, pruned.return_type, subst, v))
	case .Tuple:
		elements := make([dynamic]^Type)
		for el in pruned.elements do append(&elements, instantiate_type(ctx, el, subst, v))
		return new_tuple_type(elements)
	case .Array:
		return new_array_type(instantiate_type(ctx, pruned.element_type, subst, v))
	case .Map:
		return new_map_type(
			instantiate_type(ctx, pruned.key_type, subst, v),
			instantiate_type(ctx, pruned.value_type, subst, v),
		)
	case .Struct:
		t2 := new(Type)
		t2.kind = .Struct
		t2.name = pruned.name
		t2.generic_origin = pruned.generic_origin
		t2.fields = make([dynamic]Struct_Field)
		// Стадия 7 Phase E: методы type-erased (один Symbol_Id/байткод на
		// все инстанциации, см. resolve вызова метода в infer_call_expr)
		// — alias карты шаблона безопасен, методы пишутся один раз в
		// ПРОХОД 3 и никогда не мутируются потом. Odin-карты — reference
		// type, так что дальнейшее заполнение pruned.methods в ПРОХОД 3
		// (если эта инстанциация случилась раньше, во время ПРОХОД 2)
		// всё равно видно через t2.methods — тот же указатель на данные.
		t2.methods = pruned.methods
		// Стадия 7: снимок, а не пустой массив — раньше здесь стоял
		// make([dynamic]^Type), из-за чего unify_types'ова interface-
		// коэрция (см. `for iface in left.implemented_interfaces`) на
		// ЛЮБОЙ инстанциации generic-структуры всегда видела пустой
		// список, даже если шаблон честно реализует интерфейс — molча
		// ломая `x: ИнтерфейсX = generic_значение`. В отличие от .methods
		// это НЕ живой алиас (dynamic array — value-заголовок, не
		// reference type, как map) — но и не нужен: реальные инстанциации
		// (эта функция) вызываются только из ПРОХОД 4, который всегда
		// идёт строго ПОСЛЕ ПРОХОД 3 — к этому моменту
		// pruned.implemented_interfaces шаблона уже полностью заполнен и
		// больше никогда не мутируется, так что плоский снимок корректен.
		t2.implemented_interfaces = pruned.implemented_interfaces
		v[pruned] = t2 // регистрируем ДО рекурсии в поля — см. комментарий выше
		for f in pruned.fields {
			append(&t2.fields, Struct_Field{name = f.name, type = instantiate_type(ctx, f.type, subst, v)})
		}
		return t2
	case .Enum:
		t2 := new(Type)
		t2.kind = .Enum
		t2.name = pruned.name
		t2.generic_origin = pruned.generic_origin
		t2.variants = make([dynamic]Type_Variant)
		t2.variant_index = pruned.variant_index // имена→индексы не меняются копией
		t2.methods = pruned.methods // Стадия 7 Phase E: см. комментарий в .Struct-case выше
		// Стадия 25: тот же баг/фикс, что уже описан у .Struct-case выше
		// (плоский снимок, не пустой массив) — раньше недостижимо (enum'ы
		// не реализовывали интерфейсы), теперь `Опция`/`Результат`/
		// пользовательские generic-enum'ы с `реализация X для Тип` молча
		// теряли бы implemented_interfaces при КАЖДОЙ инстанциации
		// (Опция(Число), Опция(Строка) и т.д.) без этой строки.
		t2.implemented_interfaces = pruned.implemented_interfaces
		v[pruned] = t2 // регистрируем ДО рекурсии в варианты
		for variant in pruned.variants {
			fields := make([dynamic]^Type)
			for f in variant.fields do append(&fields, instantiate_type(ctx, f, subst, v))
			append(&t2.variants, Type_Variant{name = variant.name, fields = fields})
		}
		return t2
	}
	return pruned
}

// Инстанцирует полиморфную схему: каждому infer_id из forall — свежий
// InferVar, затем instantiate_type с этой подстановкой.
instantiate_scheme :: proc(ctx: ^Type_Ctx, scheme: Type_Scheme) -> ^Type {
	subst := make(map[int]^Type)
	for id in scheme.forall do subst[id] = new_infer_var(ctx)
	return instantiate_type(ctx, scheme.body, &subst)
}

// Тот же instantiate_scheme, но отдаёт вызывающему саму subst-карту
// (infer_id шаблонного decl-param -> свежий InferVar этой инстанциации).
// Нужна ТОЛЬКО infer_bounded_generic_call — обычный instantiate_scheme
// не трогаем (много вызывающих, subst им не нужна).
instantiate_scheme_with_subst :: proc(
	ctx: ^Type_Ctx,
	scheme: Type_Scheme,
	out_subst: ^map[int]^Type,
) -> ^Type {
	for id in scheme.forall do out_subst[id] = new_infer_var(ctx)
	return instantiate_type(ctx, scheme.body, out_subst)
}

// Стадия 7 Phase C: стабильный строковый ключ для generic_instance_cache —
// символ декларации + указатели резолвленных type-аргументов по порядку.
// Корректность опирается на то, что конкретные типы в этой системе —
// синглтоны (TY_NUM/TY_STRING/... и один канонический ^Type на
// структуру/enum); для вложенных generic-инстанциаций это тоже верно,
// т.к. они сами проходят через этот же кэш раньше, чем становятся
// аргументом внешней инстанциации.
generic_instance_key :: proc(sym: Symbol_Id, args: [dynamic]^Type) -> string {
	b := strings.builder_make()
	fmt.sbprintf(&b, "%d", sym)
	for a in args do fmt.sbprintf(&b, "|%p", a)
	return strings.to_string(b)
}

// Стадия 7 Phase C/D: собирает pruned-типы полей структуры / полей всех
// вариантов перечисления УЖЕ ИНСТАНЦИРОВАННОГО типа, в порядке
// структурного обхода — единый источник для generic_instance_key. И
// explicit-аннотация (Пара(Число,Строка)), и inferred-конструктор
// (Пара(1,"a")) при одинаковой семантической инстанциации ДОЛЖНЫ давать
// одинаковый ключ — раньше (Phase C) конструктор строил ключ по порядку
// ПОЛЕЙ, а аннотация — по порядку ЗАГОЛОВКА [A, B]; расходятся, если поля
// объявлены не в том же порядке, что заголовок. Единый обход убирает
// расхождение по конструкции.
collect_instance_args :: proc(instance: ^Type, out: ^[dynamic]^Type) {
	#partial switch instance.kind {
	case .Struct:
		for f in instance.fields do append(out, prune_type(f.type))
	case .Enum:
		for v in instance.variants {
			for f in v.fields do append(out, prune_type(f))
		}
	}
}

// Унификация либо подтверждает совместимость типов, либо фиксирует InferVar.
// Это главный механизм вывода типов в лямбдах, аргументах и присваиваниях.
//
// Стадия 7 Phase D: visited — пары указателей, уже сравниваемые ВЫШЕ по
// стеку рекурсии (нужно для рекурсивных generic-типов, тип Список[T] =
// структура следующий: Опция(Список(T)) конец — сравнение двух РАЗНЫХ
// инстанциаций одного объявления рекурсивно заходит в свои же поля).
// Создаётся лениво верхним вызовом (visited == nil), дальше передаётся по
// цепочке — тот же приём, что в instantiate_type/collect_free_infer_vars.
unify_types :: proc(a: ^Type, b: ^Type, visited: ^map[[2]^Type]bool = nil) -> bool {
	left := prune_type(a)
	right := prune_type(b)
	if left == nil || right == nil do return false
	if left == right do return true
	if left.kind == .Never || right.kind == .Never do return true
	if left.kind == .Poison || right.kind == .Poison do return true

	if left.kind == .InferVar do return bind_infer_var(left, right)
	if right.kind == .InferVar do return bind_infer_var(right, left)

	// Стадия 25: перечисления тоже могут реализовывать интерфейсы —
	// implemented_interfaces теперь заполняется и для .Enum (ПРОХОД 1/3).
	if right.kind == .Interface && (left.kind == .Struct || left.kind == .Enum) {
		for iface in left.implemented_interfaces {
			if iface == right do return true
		}
		return false
	}

	if left.kind != right.kind do return false

	v := visited
	local_v: map[[2]^Type]bool
	if v == nil {
		local_v = make(map[[2]^Type]bool)
		v = &local_v
	}

	#partial switch left.kind {
	case .Tuple:
		if len(left.elements) != len(right.elements) do return false
		for i in 0 ..< len(left.elements) {
			if !unify_types(left.elements[i], right.elements[i], v) do return false
		}
		return true

	case .Function:
		if len(left.params) != len(right.params) do return false
		for i in 0 ..< len(left.params) {
			if !unify_types(left.params[i], right.params[i], v) do return false
		}
		return unify_types(left.return_type, right.return_type, v)

	case .Array:
		return unify_types(left.element_type, right.element_type, v)

	case .Map:
		return(
			unify_types(left.key_type, right.key_type, v) &&
			unify_types(left.value_type, right.value_type, v) \
		)

	case .Struct, .Interface, .Enum:
		// .Enum раньше не имел case здесь вообще — свитч проваливался,
		// функция возвращала true БЕЗУСЛОВНО для любых двух разных
		// enum-типов (подтверждено живым тестом: тип А/тип Б,
		// принимает_а(Б.ВариантБ) компилировался без ошибки).
		//
		// identity (left == right) уже проверена выше и не сработала —
		// значит либо это ДЕЙСТВИТЕЛЬНО разные типы (generic_origin не
		// совпадает или INVALID_SYMBOL — не generic вовсе), либо это
		// self-ссылка ВНУТРИ рекурсивного generic-типа, ещё не
		// канонизированная через generic_instance_cache (см.
		// Type.generic_origin) — тогда сравниваем структурно.
		if left.kind == .Interface || left.generic_origin == INVALID_SYMBOL ||
		   left.generic_origin != right.generic_origin {
			return false
		}
		pair := [2]^Type{left, right}
		if v[pair] do return true // уже сравниваем эту пару выше по стеку — цикл, считаем совместимой
		v[pair] = true

		if left.kind == .Struct {
			if len(left.fields) != len(right.fields) do return false
			for i in 0 ..< len(left.fields) {
				if !unify_types(left.fields[i].type, right.fields[i].type, v) do return false
			}
			return true
		}
		// .Enum
		if len(left.variants) != len(right.variants) do return false
		for i in 0 ..< len(left.variants) {
			if left.variants[i].name != right.variants[i].name do return false
			if len(left.variants[i].fields) != len(right.variants[i].fields) do return false
			for j in 0 ..< len(left.variants[i].fields) {
				if !unify_types(left.variants[i].fields[j], right.variants[i].fields[j], v) do return false
			}
		}
		return true
	}
	return true
}

// Стадия 7: constraint-based inference (generate → solve), см. ROADMAP
// §Стадия 7 "Архитектурное решение". Применяется ТОЛЬКО к join-точкам
// (если/иначе, выбор-ветки, элементы массива/соответствия-литералов) —
// местам, где N УЖЕ полностью выведенных (bottom-up) типов должны
// совпасть друг с другом, и решение "что делать дальше" не зависит от
// диспетчеризации ВНУТРИ самого сравнения. Остальные вызовы unify_types
// в этом файле остаются eager — тайпчекер там принимает структурные
// решения (какой метод резолвится на Массив vs Соответствие,
// exhaustiveness `выбор` по .Enum и т.п.) ПО ХОДУ обхода, что
// несовместимо с отложенным solve без переписывания на HM-стиль с
// отложенной диспетчеризацией (недели работы ради нуля текущих
// функциональных проблем — Phase A-F доказали, что eager-unify
// достаточно для всего, что уже реализовано, см. заметку Phase A выше).
Constraint :: struct {
	a, b:    ^Type,
	span:    Span,
	message: string,
}

// Сообщение форматируется В МОМЕНТ emit (как раньше форматировалось
// прямо перед немедленным unify_types) — операнды join-точки уже
// полностью выведены к этому моменту, так что дальнейшее связывание
// InferVar'ов внутри ТОГО ЖЕ батча не меняет их pruned-имена задним
// числом.
emit_constraint :: proc(ctx: ^Type_Ctx, a: ^Type, b: ^Type, span: Span, message: string) {
	append(&ctx.pending_constraints, Constraint{a = a, b = b, span = span, message = message})
}

// Батч-солвер: прогоняет накопленные constraint'ы через unify_types.
// Внутренняя механика unify_types (bind_infer_var, TY_POISON, cycle-safe
// visited-карты) не меняется — солвер лишь переносит МОМЕНТ вызова с
// "сразу по ходу обхода" на "после того, как все операнды join-точки уже
// выведены". bind_infer_var — union-find-подобная мутация, порядок-
// независимая, так что итоговое состояние типов идентично eager-
// поведению; разница только в том, что ВСЕ несовпадения join-точки
// репортятся за один проход, а не по одному по ходу eager-обхода (хотя
// эффективно так уже было — циклы на join-точках и раньше не прерывались
// на первой ошибке).
solve_constraints :: proc(ctx: ^Type_Ctx) -> bool {
	all_ok := true
	for c in ctx.pending_constraints {
		if !unify_types(c.a, c.b) {
			report(ctx, c.span, "%s", c.message)
			all_ok = false
		}
	}
	clear(&ctx.pending_constraints)
	return all_ok
}

// После вывода типа проверяем, что в нем не осталось неизвестных частей.
// InferVar с is_decl_param (объявленный type-параметр generic-функции/
// метода, см. Type.is_decl_param) НЕ считается "неизвестной частью" — это
// НЕ застрявший вывод, а T/U из [T]/[T, U], намеренно неразрешённый на
// момент тайпчека САМОЙ generic-декларации (тело обязано ссылаться на
// него как есть, resolve при каждом ВЫЗОВЕ через instantiate_scheme).
// Раньше это ловило ЛЮБОЙ безымянный `пер x = ...`, чей тип содержит T —
// т.е. ЛЮБОЙ generic function body, использующий for-in (десугарится в
// `пер __for_N_iter = массив` без аннотации) или просто `пер копия =
// generic_параметр`, падал с "не удалось вывести тип переменной". Живой
// баг: подтверждён минимальным `функ f[T](m: Массив(T)) ... пер x = m ...`.
has_unresolved_infer_vars :: proc(t: ^Type) -> bool {
	typ := prune_type(t)
	if typ == nil do return false

	#partial switch typ.kind {
	case .InferVar:
		return !typ.is_decl_param

	case .Function:
		for param in typ.params {
			if has_unresolved_infer_vars(param) do return true
		}
		return has_unresolved_infer_vars(typ.return_type)

	case .Tuple:
		for el in typ.elements {
			if has_unresolved_infer_vars(el) do return true
		}

	case .Array:
		return has_unresolved_infer_vars(typ.element_type)

	case .Map:
		return has_unresolved_infer_vars(typ.key_type) || has_unresolved_infer_vars(typ.value_type)
	}

	return false
}

// Помогает ловить случаи, когда infer дошел не до конца, но код уже
// пытается использовать результат как окончательный тип.
ensure_type_resolved :: proc(ctx: ^Type_Ctx, span: Span, t: ^Type, where_text: string) {
	if has_unresolved_infer_vars(t) {
		report(ctx, span, "Type Error: не удалось вывести тип %s", where_text)
	}
}

// Для top-level функций типы параметров по-прежнему должны быть явными.
// Это упрощает раннюю регистрацию символов и не смешивает вывод с резолюцией имен.
resolve_param_types :: proc(ctx: ^Type_Ctx, args: [dynamic]Param_Decl) -> [dynamic]^Type {
	params := make([dynamic]^Type)
	for arg in args {
		if arg.type_annotation == nil {
			report(
				ctx,
				arg.span,
				"Type Error: у аргумента '%s' нет явной аннотации типа",
				arg.name,
			)
			append(&params, TY_POISON)
			continue
		}
		append(&params, resolve_type_node(ctx, arg.type_annotation))
	}
	return params
}

// Для лямбд параметры можно либо взять из ожидаемого типа, либо вывести
// как отдельные InferVar и потом связать их через тело. `span` — span
// самой лямбды, для ошибок без более точного узла (несовпадение arity/kind
// с ожидаемым типом).
infer_lambda_param_types :: proc(
	ctx: ^Type_Ctx,
	span: Span,
	args: [dynamic]Param_Decl,
	expected: ^Type = nil,
) -> [dynamic]^Type {
	params := make([dynamic]^Type)
	expected_type := prune_type(expected)
	if expected_type != nil && expected_type.kind != .Function {
		report(
			ctx,
			span,
			"Type Error: лямбду можно проверить только с типом функции",
		)
		// Деградируем до "ожидаемого типа нет" — иначе ниже упадём на
		// expected_type.params при несовпадающем kind.
		expected_type = nil
	}
	if expected_type != nil && len(args) != len(expected_type.params) {
		report(
			ctx,
			span,
			"Type Error: лямбда имеет %d аргументов, ожидалось %d",
			len(args),
			len(expected_type.params),
		)
		// То же самое: длины разошлись — дальше индексировать
		// expected_type.params[i] по len(args) небезопасно.
		expected_type = nil
	}

	for arg, i in args {
		if arg.type_annotation != nil {
			arg_type := resolve_type_node(ctx, arg.type_annotation)
			if expected_type != nil && !unify_types(arg_type, expected_type.params[i]) {
				report(
					ctx,
					arg.span,
					"Type Error: аргумент лямбды '%s' имеет тип '%s', ожидался '%s'",
					arg.name,
					prune_type(arg_type).name,
					prune_type(expected_type.params[i]).name,
				)
			}
			append(&params, arg_type)
		} else if expected_type != nil {
			append(&params, expected_type.params[i])
		} else {
			append(&params, new_infer_var(ctx))
		}
	}

	return params
}

// Сигнатура обычной функции берется только из явной декларации.
// Для top-level items inference здесь не используется.
function_type_from_decl :: proc(ctx: ^Type_Ctx, d: ^Function_Decl) -> ^Type {
	params := resolve_param_types(ctx, d.args)
	return_type := resolve_type_node(ctx, d.return_type)
	return new_function_type(params, return_type)
}

// Стадия 49: panos-тип, соответствующий marshal-кинду `внешний`-
// параметра/возврата (см. Foreign_Marshal_Kind, parser.odin). Int8/
// Int32/Int64 — все TY_INT (ширина чисто marshalling, не панос-тип, см.
// Стадия 47). Float32/Float64 — TY_NUM (та же логика: Число(N) остаётся
// обычным Число на panos-стороне). Pointer — реальный Указатель(T), T
// резолвится из pointee обычным resolve_type_node (тем же путём, что
// параметр обычной функции). Struct — resolved_struct_type уже должен
// быть заполнен ВЫЗЫВАЮЩИМ (case ^Foreign_Decl ниже резолвит struct_
// type_name ДО вызова этой функции) — тут просто читаем поле struct_
// type (Type резолвится по имени в самом struct_type, не здесь).
foreign_marshal_panos_type :: proc(ctx: ^Type_Ctx, marshal: Foreign_Marshal_Kind, pointee: Type_Node, resolved_struct_type: ^Type = nil) -> ^Type {
	switch marshal {
	case .Void:
		return TY_VOID
	case .Int8, .Int32, .Int64:
		return TY_INT
	case .Float32, .Float64:
		return TY_NUM
	case .CString:
		return TY_STRING
	case .Pointer:
		return new_pointer_type(resolve_type_node(ctx, pointee))
	case .Struct:
		if resolved_struct_type != nil do return resolved_struct_type
		return TY_INT
	}
	return TY_INT
}

// Стадия 51: резолвит имя ff_структура-типа (Foreign_Param.struct_type_
// name/Foreign_Decl.return_struct_type_name) в её ^Type — та же логика,
// что resolve_type_node's case ^Type_Ident (глобальный scope модуля),
// но с доп. проверкой "это именно ff_структура" (ffi_field_kinds != nil),
// не обычная структура/другой тип. Type Error, если имя не найдено ИЛИ
// найдено, но не ff_структура.
resolve_foreign_struct_type_name :: proc(ctx: ^Type_Ctx, name: string, span: Span) -> ^Type {
	sym := lookup_symbol(ctx.res.global_scope, intern(name))
	if sym == INVALID_SYMBOL {
		report(ctx, span, "Type Error: неизвестный тип '%s' во 'внешний'-сигнатуре", name)
		return TY_INT
	}
	typ, ok := ctx.res.symbol_types[sym]
	if !ok || typ.kind != .Struct || typ.ffi_field_kinds == nil {
		report(ctx, span, "Type Error: '%s' не является ff_структура — только ff_структура допустима как тип struct-by-value в 'внешний'", name)
		return TY_INT
	}
	return typ
}

interface_method_type_from_signature :: proc(
	ctx: ^Type_Ctx,
	iface_type: ^Type,
	m: Method_Signature,
) -> ^Type {
	params := make([dynamic]^Type)
	append(&params, iface_type)
	for arg in m.args {
		append(&params, resolve_type_node(ctx, arg.type_annotation))
	}
	return new_function_type(params, resolve_type_node(ctx, m.return_type))
}

// Привязывает параметры обычной функции к уже вычисленной сигнатуре.
bind_function_args :: proc(ctx: ^Type_Ctx, d: ^Function_Decl, func_type: ^Type) {
	if args_syms, ok := ctx.res.func_args[d]; ok {
		if len(args_syms) != len(func_type.params) {
			fmt.panicf(
				"Type Error: функция '%s' имеет рассинхронизированные аргументы",
				d.name,
			)
		}
		for arg_sym, i in args_syms {
			ctx.res.symbol_types[arg_sym] = func_type.params[i]
		}
	}
}

// То же самое для лямбды: символы аргументов должны получить типы
// тех же позиций, которые были выведены или протолкнуты сверху вниз.
bind_lambda_args :: proc(ctx: ^Type_Ctx, expr: Expr, params: [dynamic]^Type) {
	if args_syms, ok := ctx.res.lambda_args[expr]; ok {
		if len(args_syms) != len(params) {
			fmt.panicf(
				"Type Error: лямбда имеет рассинхронизированные аргументы",
			)
		}
		for sym, i in args_syms do ctx.res.symbol_types[sym] = params[i]
	}
}

// Пытается вывести тип блока callable-выражения: сначала как значение блока,
// а если значения нет, то через явные `return`.
infer_callable_body_type :: proc(ctx: ^Type_Ctx, body: [dynamic]Stmt) -> ^Type {
	body_type := infer_block_type(ctx, body)
	if body_type != TY_VOID do return body_type
	return infer_function_body(ctx, body)
}

// Лямба проверяется bidirectional-стилем:
// если ожидаемый тип известен, он проталкивается вниз; иначе тип выводится из тела.
check_lambda_expr :: proc(
	ctx: ^Type_Ctx,
	expr: Expr,
	lambda: ^Lambda_Expr,
	expected: ^Type = nil,
) -> ^Type {
	// Стадия 48: пушим ДО проверки тела (bind_lambda_args сама тело не
	// трогает, но unify/check ниже могут рекурсивно уйти во вложенные
	// лямбды — стек должен быть консистентен на всём протяжении).
	append(&ctx.current_lambda_stack, expr)
	defer pop(&ctx.current_lambda_stack)

	expected_type := prune_type(expected)
	params := infer_lambda_param_types(ctx, lambda.span, lambda.args, expected_type)
	bind_lambda_args(ctx, expr, params)

	return_type: ^Type
	if lambda.return_type != nil {
		return_type = resolve_type_node(ctx, lambda.return_type)
		if expected_type != nil && !unify_types(return_type, expected_type.return_type) {
			report(
				ctx,
				lambda.span,
				"Type Error: лямбда возвращает '%s', ожидался '%s'",
				prune_type(return_type).name,
				prune_type(expected_type.return_type).name,
			)
		}
	} else if expected_type != nil {
		return_type = expected_type.return_type
	} else {
		return_type = new_infer_var(ctx)
	}

	function_type := new_function_type(params, return_type)
	ctx.node_types[expr] = function_type

	if expected_type != nil && !unify_types(function_type, expected_type) {
		report(
			ctx,
			lambda.span,
			"Type Error: лямбда имеет тип '%s', ожидался '%s'",
			function_type.name,
			expected_type.name,
		)
	}

	if lambda.return_type != nil || expected_type != nil {
		check_function_body(ctx, lambda.span, lambda.body, return_type)
	} else {
		body_type := infer_callable_body_type(ctx, lambda.body)
		if !unify_types(body_type, return_type) {
			report(
				ctx,
				lambda.span,
				"Type Error: тело лямбды имеет тип '%s', ожидался '%s'",
				prune_type(body_type).name,
				prune_type(return_type).name,
			)
		}
	}

	// Стадия 7 Phase A: если ИМЕННО эта лямбда — прямая цель let-биндинга
	// (см. Type_Ctx.allow_unresolved_lambda), пропускаем строгую проверку —
	// вызывающий Let_Stmt сам обобщит оставшиеся InferVar в полиморфную
	// схему. Идентичность узла (не булев флаг) — чтобы проверка осталась
	// строгой для любой другой лямбды, случайно вложенной в её тело.
	if expr != ctx.allow_unresolved_lambda {
		ensure_type_resolved(ctx, lambda.span, function_type, "лямбды")
	}
	return function_type
}

// iface_type/target_type включают Self-подстановку: параметр, объявленный
// в самом интерфейсе КАК ТИП ЭТОГО ЖЕ ИНТЕРФЕЙСА (указательно == iface_type
// — interface_method_type_from_signature резолвит такую аннотацию в тот же
// iface_type, что и неявный receiver в params[0]), обязан у impl'а быть
// конкретным target_type, а не оставаться интерфейсным — иначе тело метода
// не получает доступа к полям конкретного типа (нужно для контрактов вида
// "сравни меня с другим Self", напр. Сравниваемое.сравнить(другое: Self)).
interface_method_types_match :: proc(
	expected: ^Type,
	actual: ^Type,
	iface_type: ^Type,
	target_type: ^Type,
) -> bool {
	if expected == nil || actual == nil do return false
	if expected.kind != .Function || actual.kind != .Function do return false
	if len(expected.params) != len(actual.params) do return false

	// Стадия 28: unify_types вместо types_are_equal — для НЕ-generic
	// интерфейсов (нет свободных InferVar в expected) ведёт себя ИДЕНТИЧНО
	// types_are_equal (структурное сравнение конкретных типов). Для
	// generic-интерфейсов expected уже содержит свежую InferVar на месте
	// T (подставлена вызывающим кодом перед вызовом, см. ПРОХОД 3) —
	// unify_types СВЯЗЫВАЕТ её с actual (напр. Число), types_are_equal
	// такое отвергла бы (InferVar никогда не "равна" конкретному типу).
	if expected.return_type == iface_type {
		if actual.return_type != target_type do return false
	} else if !unify_types(actual.return_type, expected.return_type) {
		return false
	}

	for i in 1 ..< len(expected.params) {
		if expected.params[i] == iface_type {
			if actual.params[i] != target_type do return false
		} else if !unify_types(actual.params[i], expected.params[i]) {
			return false
		}
	}
	return true
}

// --- ГЛАВНЫЙ ЦИКЛ ---

// Основной проход type checker'а идет в несколько стадий:
// сначала регистрируем номинальные типы, потом сигнатуры, затем реализации,
// и только после этого проверяем тела.
// Создаёт свежий InferVar (помеченный is_decl_param — см. комментарий у
// поля) на каждое имя type-параметра generic-декларации и кладёт в `into`
// по имени. `ordered`, если не nil, копит тот же список позиционно —
// нужно только Struct/Enum (decl_type_param_order, для позиционной
// подстановки в explicit-аннотации Тип(A, B)); Function_Decl и
// собственные type-параметры метода Impl_Decl это не используют.
// bounds — ТОЛЬКО у Function_Decl (см. Function_Decl.type_param_bounds);
// nil у Struct/Enum/Interface_Decl-вызовов (bounded traits сознательно
// ограничены функциями). Для каждого имени с непустым списком bounds
// резолвит имена интерфейсов ТЕМ ЖЕ путём, что resolve_type_node
// резолвит голый Type_Ident (глобальный scope модуля), проверяет
// kind == .Interface, копит в tv.required_interfaces.
make_decl_type_params :: proc(
	ctx: ^Type_Ctx,
	names: []string,
	into: ^map[string]^Type,
	ordered: ^[dynamic]^Type = nil,
	bounds: map[string][dynamic]string = nil,
	bounds_span: Span = {},
) {
	for name in names {
		tv := new_infer_var(ctx)
		tv.is_decl_param = true
		if iface_names, has_bounds := bounds[name]; has_bounds {
			for iface_name in iface_names {
				sym := lookup_symbol(ctx.res.global_scope, intern(iface_name))
				if sym == INVALID_SYMBOL {
					report(
						ctx,
						bounds_span,
						"Type Error: неизвестный интерфейс '%s' в bound'е type-параметра '%s'",
						iface_name,
						name,
					)
					continue
				}
				iface_type, has_type := ctx.res.symbol_types[sym]
				if !has_type || iface_type == nil || iface_type.kind != .Interface {
					report(
						ctx,
						bounds_span,
						"Type Error: '%s' не интерфейс, не может быть bound'ом type-параметра '%s'",
						iface_name,
						name,
					)
					continue
				}
				append(&tv.required_interfaces, iface_type)
			}
		}
		into[name] = tv
		if ordered != nil do append(ordered, tv)
	}
}

// Обобщает построенный тип в Type_Scheme и, если нашлись свободные InferVar
// (значит decl реально generic), кладёт схему в symbol_schemes — общий
// хвост для Struct/Enum/Function_Decl и методов Impl_Decl.
try_generalize :: proc(ctx: ^Type_Ctx, sym: Symbol_Id, t: ^Type) {
	scheme := generalize(ctx, t)
	if len(scheme.forall) > 0 {
		ctx.symbol_schemes[sym] = scheme
	}
}

// Тайпчекает тело функции/метода (ПРОХОД 4): связывает аргументы
// (bind_function_args), затем, если для sym сохранены type-параметры
// (generic функция/метод, см. ПРОХОД 2/3), резолвит тело в ТЕ ЖЕ
// InferVar-узлы, что и сигнатура, — иначе без подмены current_type_params.
// Общий паттерн для Function_Decl и методов Impl_Decl.
check_decl_body :: proc(ctx: ^Type_Ctx, sym: Symbol_Id, d: ^Function_Decl, func_type: ^Type) {
	bind_function_args(ctx, d, func_type)

	// Стадия 24: T сообщений — ambient на ВРЕМЯ ЭТОЙ функции (save/restore,
	// тот же паттерн, что current_type_params) — получить() внутри вложенной
	// лямбды НЕ должен путать T с T объемлющей функции (у лямбд процессов
	// не бывает, но save/restore защищает от случайной путаницы, если
	// check_decl_body вызовется реентерабельно, см. ensure_body_checked).
	prev_msg_var := ctx.current_process_message_var
	ctx.current_process_message_var = nil

	if params_map, ok := ctx.decl_type_params[sym]; ok {
		prev := ctx.current_type_params
		ctx.current_type_params = params_map
		// Bounded traits: тело ЭТОЙ generic-декларации сейчас проверяется
		// АБСТРАКТНО (T/E — decl-param InferVar, не конкретный тип) — если
		// внутри есть вызов ДРУГОЙ (или той же — рекурсия) bounded generic-
		// функции, infer_bounded_generic_call не сможет вывести конкретный
		// тип-параметр (и не должна пытаться — это НЕ ошибка, а нормальное
		// свойство абстрактного прохода, см. флаг там). Клоны (core/
		// monomorphize.odin's monomorphize_one) типизируются НЕ через
		// check_decl_body, флаг для них остаётся false.
		prev_abstract := ctx.in_abstract_generic_body
		ctx.in_abstract_generic_body = true
		check_function_body(ctx, d.span, d.body, func_type.return_type)
		ctx.in_abstract_generic_body = prev_abstract
		ctx.current_type_params = prev
	} else {
		check_function_body(ctx, d.span, d.body, func_type.return_type)
	}

	if ctx.current_process_message_var != nil {
		ctx.process_message_types[sym] = prune_type(ctx.current_process_message_var)
	}
	ctx.current_process_message_var = prev_msg_var
}

// Стадия 24: типизирует тело функции sym НЕМЕДЛЕННО, если оно ещё не было
// проверено — идемпотентно (checked_bodies), так что и обычный ПРОХОД 4
// (по порядку деклараций), и внеочередной запрос из infer_spawn_expr
// (функция объявлена ПОСЛЕ места её `запусти`) в сумме проверяют каждое
// тело РОВНО один раз. T процесса (process_message_types) зависит только
// от получить()-паттернов ВНУТРИ f, не от вызывающих — внеочередная
// проверка корректна при любом порядке.
ensure_body_checked :: proc(ctx: ^Type_Ctx, sym: Symbol_Id) {
	if ctx.checked_bodies[sym] do return
	ctx.checked_bodies[sym] = true
	d, ok := ctx.symbol_to_func_decl[sym]
	if !ok do return
	func_type := ctx.res.symbol_types[sym]
	if func_type == nil do return
	check_decl_body(ctx, sym, d, func_type)
}

// Явные фазы typecheck_program. Раньше порядок 4 проходов был зафиксирован
// только позицией функций в файле (см. type-checker review 2026-07-07,
// P9: "порядок неявный, комментарии описывают его") — теперь порядок
// задаёт ЭТОТ enum и цикл `for pass in Pass_Kind` в typecheck_program,
// а не расположение typecheck_pass_*-процедур ниже.
Pass_Kind :: enum {
	Nominal,    // номинальные типы-заглушки для Struct/Interface/Enum
	Signatures, // поля структур, сигнатуры функций/методов интерфейса, варианты enum
	Impls,      // привязка `реализация`-блоков к структурам/перечислениям
	Bodies,     // проверка тел функций и методов
}

typecheck_program :: proc(ctx: ^Type_Ctx, prog: Program) {
	for pass in Pass_Kind {
		switch pass {
		case .Nominal:    typecheck_pass_nominal(ctx, prog)
		case .Signatures: typecheck_pass_signatures(ctx, prog)
		case .Impls:      typecheck_pass_impls(ctx, prog)
		case .Bodies:     typecheck_pass_bodies(ctx, prog)
		}
	}
}

// ПРОХОД 1 (Pass_Kind.Nominal): создаём номинальные типы до разбора полей
// и сигнатур.
typecheck_pass_nominal :: proc(ctx: ^Type_Ctx, prog: Program) {
	for decl in prog.decls {
		#partial switch d in decl {
		case ^Struct_Decl:
			struct_type := new(Type)
			struct_type.kind = .Struct
			struct_type.name = d.name
			struct_type.fields = make([dynamic]Struct_Field)
			struct_type.methods = make(map[string]Symbol_Id)
			struct_type.implemented_interfaces = make([dynamic]^Type)

			sym := ctx.res.decl_symbols[decl]
			struct_type.generic_origin = sym
			ctx.res.symbol_types[sym] = struct_type

		case ^Interface_Decl:
			iface_type := new(Type)
			iface_type.kind = .Interface
			iface_type.name = d.name
			iface_type.interface_methods = make(map[string]^Type)
			iface_sym := ctx.res.decl_symbols[decl]
			// Стадия 28: generic-интерфейсы — generic_origin выставляем
			// симметрично Struct_Decl/Enum_Decl (см. ниже), хотя сам
			// механизм инстанциации иной (см. ПРОХОД 3, проверка
			// контракта) — try_generalize/scheme для интерфейсов НЕ
			// используется, T подставляется напрямую через
			// decl_type_param_order в месте проверки impl.
			if len(d.type_params) > 0 {
				iface_type.generic_origin = iface_sym
			}
			ctx.res.symbol_types[iface_sym] = iface_type

		case ^Enum_Decl:
			enum_type := new(Type)
			enum_type.kind = .Enum
			enum_type.name = d.name
			enum_type.variants = make([dynamic]Type_Variant)
			enum_type.variant_index = make(map[string]int)
			// Как у Struct — без этого `реализация X` для перечисления X
			// падала бы на nil-map assignment в ПРОХОДЕ 3.
			enum_type.methods = make(map[string]Symbol_Id)
			// Стадия 25: перечисления теперь тоже могут реализовывать
			// интерфейсы — без этого append ниже (ПРОХОД 3) писал бы в
			// nil dynamic array (append на nil работает в Odin, но поле
			// остаётся не read-инициализированным для единообразия со Struct).
			enum_type.implemented_interfaces = make([dynamic]^Type)
			enum_sym := ctx.res.decl_symbols[decl]
			enum_type.generic_origin = enum_sym
			ctx.res.symbol_types[enum_sym] = enum_type
		}
	}
}

// ПРОХОД 2 (Pass_Kind.Signatures): заполняем структуры, интерфейсы и
// сигнатуры функций.
typecheck_pass_signatures :: proc(ctx: ^Type_Ctx, prog: Program) {
	for decl in prog.decls {
		#partial switch d in decl {
		case ^Struct_Decl:
			sym := ctx.res.decl_symbols[decl]
			struct_type := ctx.res.symbol_types[sym]
			struct_type.fields = make([dynamic]Struct_Field)

			// Стадия 51 (ff_структура): без generics (parser не парсит
			// [...] для ff_структура), поле-тип вычисляется из marshal_
			// kind (Целое(N)/Число(N) → обычный Целое/Число), не через
			// resolve_type_node (f.type_annotation здесь всегда nil —
			// parse_ffi_struct_decl не парсит общий Type_Node). ffi_
			// field_kinds — позиционно параллельно struct_type.fields,
			// нужен VM-маршаллингу (vm_ffi_native.odin).
			if d.is_ffi {
				kinds := make([]Foreign_Marshal_Kind, len(d.fields))
				for f, i in d.fields {
					kinds[i] = f.marshal_kind
					append(&struct_type.fields, Struct_Field{name = f.name, type = foreign_marshal_panos_type(ctx, f.marshal_kind, nil)})
				}
				struct_type.ffi_field_kinds = kinds
			} else if len(d.type_params) > 0 {
				// Стадия 7 Phase C: generic-структура — резолвим поля с
				// type-параметрами в scope (свежий InferVar на каждое имя),
				// затем generalize в полиморфную схему (тот же механизм, что
				// Phase A/B, см. symbol_schemes). decl_type_param_order хранит
				// ordered-список для позиционной явной подстановки в
				// Type_Generic (Пара(Число, Строка)) — заполняется всегда при
				// непустом d.type_params, даже если конкретный параметр не
				// встречается ни в одном поле.
				//
				// Стадия 7 Phase D: decl_type_params/decl_type_param_order и
				// currently_declaring_generic выставляются ДО цикла резолва
				// полей (не после, как было в Phase C) — иначе самоссылка
				// (тип Список[T] = структура ... следующий: Опция(Список(T))
				// конец) не распознаётся как generic вообще на момент, когда
				// до неё доходит resolve_type_node.
				prev_params := ctx.current_type_params
				prev_declaring := ctx.currently_declaring_generic
				params_map := make(map[string]^Type)
				ordered := make([dynamic]^Type)
				make_decl_type_params(ctx, d.type_params[:], &params_map, &ordered)
				ctx.current_type_params = params_map
				ctx.decl_type_params[sym] = params_map
				ctx.decl_type_param_order[sym] = ordered
				ctx.currently_declaring_generic = sym

				for f in d.fields {
					field_type := resolve_type_node(ctx, f.type_annotation)
					append(&struct_type.fields, Struct_Field{name = f.name, type = field_type})
				}
				ctx.current_type_params = prev_params
				ctx.currently_declaring_generic = prev_declaring

				try_generalize(ctx, sym, struct_type)
			} else {
				for f in d.fields {
					field_type := resolve_type_node(ctx, f.type_annotation)
					append(&struct_type.fields, Struct_Field{name = f.name, type = field_type})
				}
			}

		case ^Function_Decl:
			sym := ctx.res.decl_symbols[decl]
			// Стадия 24: полная карта ДО начала ПРОХОД 4 — см. комментарий
			// у symbol_to_func_decl (ensure_body_checked должен находить
			// ЛЮБУЮ функцию по символу независимо от порядка деклараций).
			ctx.symbol_to_func_decl[sym] = d

			// Стадия 7 Phase B: generic-функция — резолвим сигнатуру с
			// type-параметрами в scope (свежий InferVar на каждое имя),
			// затем generalize в полиморфную схему (тот же механизм, что
			// Phase A использует для лямбд, см. symbol_schemes).
			if len(d.type_params) > 0 {
				prev := ctx.current_type_params
				params_map := make(map[string]^Type)
				make_decl_type_params(
					ctx,
					d.type_params[:],
					&params_map,
					bounds = d.type_param_bounds,
					bounds_span = d.span,
				)
				ctx.current_type_params = params_map

				func_type := function_type_from_decl(ctx, d)
				ctx.current_type_params = prev

				ctx.res.symbol_types[sym] = func_type
				try_generalize(ctx, sym, func_type)
				// ПРОХОД 4 должен резолвить T в теле в ТЕ ЖЕ узлы.
				ctx.decl_type_params[sym] = params_map
			} else {
				ctx.res.symbol_types[sym] = function_type_from_decl(ctx, d)
			}

		case ^Foreign_Decl:
			// Стадия 47/49/51: marshal-кинд — чисто marshalling-метаданные
			// (см. Foreign_Param/Foreign_Decl, parser.odin), но панос-ТИП
			// параметра/возврата зависит от него напрямую (Целое(N) ->
			// TY_INT, КСтрока -> TY_STRING, Указатель(T) -> реальный
			// Указатель(T) через resolve_type_node на pointee, Struct ->
			// resolved_struct_type через resolve_foreign_struct_type_name
			// ПО ИМЕНИ, типы ещё не существовали на этапе парсинга) — см.
			// foreign_marshal_panos_type ниже. Тела нет (ПРОХОД 4 её не
			// касается, #partial switch там её пропускает).
			foreign_sym := ctx.res.decl_symbols[decl]
			foreign_params := make([dynamic]^Type)
			for &param in d.params {
				if param.marshal == .Struct {
					param.resolved_struct_type = resolve_foreign_struct_type_name(ctx, param.struct_type_name, param.span)
				}
				append(&foreign_params, foreign_marshal_panos_type(ctx, param.marshal, param.pointee, param.resolved_struct_type))
			}
			if d.return_marshal == .Struct {
				d.return_resolved_struct_type = resolve_foreign_struct_type_name(ctx, d.return_struct_type_name, d.span)
			}
			foreign_return := foreign_marshal_panos_type(ctx, d.return_marshal, d.return_pointee, d.return_resolved_struct_type)
			ctx.res.symbol_types[foreign_sym] = new_function_type(foreign_params, foreign_return)

		case ^Interface_Decl:
			iface_sym := ctx.res.decl_symbols[decl]
			iface_type := ctx.res.symbol_types[iface_sym]
			iface_type.interface_methods = make(map[string]^Type)

			// Стадия 28: тот же паттерн, что Struct_Decl/Enum_Decl выше —
			// T резолвится в scope (свежий InferVar на имя) на время
			// резолва сигнатур методов, чтобы `Опция(T)` внутри резолвился
			// через ctx.current_type_params, как поле generic-структуры.
			if len(d.type_params) > 0 {
				prev_params := ctx.current_type_params
				params_map := make(map[string]^Type)
				ordered := make([dynamic]^Type)
				make_decl_type_params(ctx, d.type_params[:], &params_map, &ordered)
				ctx.current_type_params = params_map
				ctx.decl_type_params[iface_sym] = params_map
				ctx.decl_type_param_order[iface_sym] = ordered

				for m in d.methods {
					iface_type.interface_methods[m.name] = interface_method_type_from_signature(
						ctx,
						iface_type,
						m,
					)
				}
				ctx.current_type_params = prev_params
			} else {
				for m in d.methods {
					iface_type.interface_methods[m.name] = interface_method_type_from_signature(
						ctx,
						iface_type,
						m,
					)
				}
			}

		case ^Enum_Decl:
			enum_sym := ctx.res.decl_symbols[decl]
			enum_type := ctx.res.symbol_types[enum_sym]

			// Стадия 7 Phase D: тот же паттерн, что Struct_Decl выше —
			// decl_type_params/decl_type_param_order и
			// currently_declaring_generic выставляются ДО цикла резолва
			// вариантов (не после), иначе самоссылка (тип Дерево[T] =
			// перечисление Узел(T, Дерево(T), Дерево(T)) конец) не
			// распознаётся как generic на момент, когда до неё доходит
			// resolve_type_node.
			if len(d.type_params) > 0 {
				prev_params := ctx.current_type_params
				prev_declaring := ctx.currently_declaring_generic
				params_map := make(map[string]^Type)
				ordered := make([dynamic]^Type)
				make_decl_type_params(ctx, d.type_params[:], &params_map, &ordered)
				ctx.current_type_params = params_map
				ctx.decl_type_params[enum_sym] = params_map
				ctx.decl_type_param_order[enum_sym] = ordered
				ctx.currently_declaring_generic = enum_sym

				for variant in d.variants {
					fields := make([dynamic]^Type)
					for tn in variant.types {
						append(&fields, resolve_type_node(ctx, tn))
					}
					tag := len(enum_type.variants)
					append(&enum_type.variants, Type_Variant{name = variant.name, fields = fields})
					enum_type.variant_index[variant.name] = tag
				}
				ctx.current_type_params = prev_params
				ctx.currently_declaring_generic = prev_declaring

				try_generalize(ctx, enum_sym, enum_type)
			} else {
				for variant in d.variants {
					fields := make([dynamic]^Type)
					for tn in variant.types {
						append(&fields, resolve_type_node(ctx, tn))
					}
					tag := len(enum_type.variants)
					append(&enum_type.variants, Type_Variant{name = variant.name, fields = fields})
					enum_type.variant_index[variant.name] = tag
				}
			}
		}
	}
}

// ПРОХОД 3 (Pass_Kind.Impls): привязка реализаций (методов и контрактов) к
// структурам и перечислениям. Интерфейсы перечисления реализовывать не
// могут — узкий scope, не design-ограничение языка
// (interface_method_types_match и остальной контрактный путь ниже писались
// и тестировались только под Struct-получатели).
typecheck_pass_impls :: proc(ctx: ^Type_Ctx, prog: Program) {
	for decl in prog.decls {
		#partial switch d in decl {
		case ^Impl_Decl:
			target_sym := ctx.res.global_scope.symbols[intern(d.target_type)]
			target_type := ctx.res.symbol_types[target_sym]
			if target_type == nil || (target_type.kind != .Struct && target_type.kind != .Enum) {
				report(
					ctx,
					d.span,
					"Type Error: неизвестный тип '%s' (реализация возможна только для структуры или перечисления)",
					d.target_type,
				)
				// target_type == nil ниже разыменовывается (.methods,
				// .implemented_interfaces) — реализацию проверять нечем,
				// пропускаем весь блок.
				continue
			}
			// Стадия 7 Phase E: реализация методов на generic-структурах/
			// enum'ах поддержана — узкий отказ остался только для
			// интерфейсной формы (генерик-интерфейсы отложены, см. Phase
			// C). Раньше здесь был безусловный отказ для ЛЮБОЙ реализация
			// на generic-типе.
			is_generic_target := false
			if _, ok := ctx.decl_type_params[target_sym]; ok {
				is_generic_target = true
			}
			// Стадия 7: реализация ИНТЕРФЕЙСА на generic-цели теперь
			// поддержана — интерфейс сам по себе НЕ generic (Interface_Decl
			// не имеет [T]), поэтому ни один метод контракта не ссылается
			// на T цели: interface_method_types_match ниже сравнивает
			// параметры/возврат мимо receiver'а (i от 1), там никогда не
			// встретится InferVar цели — сравнение работает как для
			// обычных конкретных типов, без изменений. Раньше здесь стоял
			// безусловный continue, пропускавший даже РЕГИСТРАЦИЮ методов
			// (см. ниже) — т.е. `реализация X для GenericТип` не работала
			// вообще никак. generic-интерфейсы САМИ ПО СЕБЕ (тип с [T] в
			// заголовке интерфейса) — по-прежнему вне scope, отдельная
			// фича.
			// Стадия 25: перечисления теперь МОГУТ реализовывать интерфейсы
			// (раньше здесь стоял безусловный отказ) — interface_method_
			// types_match ниже уже работает mimo receiver'а generic'и,
			// Self-фикс (params[i] == iface_type -> == target_type) не
			// делает предположений о kind target_type (Struct vs Enum),
			// vtable-механизм рантайма (vm.odin, Cast_Interface) тоже
			// kind-агностичен по имени типа. Единственные реальные правки
			// — расширить interface-коэрсию (unify_types/types_are_equal,
			// check_expr) и рантайм (Interface_Value.data/Cast_Interface)
			// на .Enum — см. эти места.

			// Регистрируем методы
			for m in d.methods {
				sym := ctx.res.decl_symbols[m]
				// Именованные аргументы (Стадия 36): method_sym -> ^Function_
				// Decl, та же карта, что топ-уровневые функции получают в
				// case ^Function_Decl: выше — нужна resolve_named_call_args
				// на методах (m.args[0] — "это", исключается там же, где
				// читается).
				ctx.symbol_to_func_decl[sym] = m

				// Стадия 7 Phase E: сигнатура generic-метода резолвится под
				// теми же InferVar владельца, что и его поля/варианты
				// (ПРОХОД 2) — это: Коробка (bare Type_Ident) резолвится в
				// сам шаблонный ^Type, а T/U и т.п. в остальных параметрах
				// — в те же InferVar через current_type_params.
				//
				// Стадия 7 Phase F: метод может добавлять СОБСТВЕННЫЕ
				// type-параметры сверх владельца (функ результат_или[E]
				// (это: Опция, ошибка: E) -> Результат(T, E) — E не входит
				// в [T] Опции). combined — объединение decl_type_params
				// владельца (если generic) со свежими InferVar на m.type_
				// params (если непусто); own_scheme включается любым из
				// двух условий.
				prev := ctx.current_type_params
				own_scheme := is_generic_target || len(m.type_params) > 0
				combined: map[string]^Type
				if own_scheme {
					combined = make(map[string]^Type)
					if is_generic_target {
						for k, v in ctx.decl_type_params[target_sym] do combined[k] = v
					}
					make_decl_type_params(ctx, m.type_params[:], &combined)
					ctx.current_type_params = combined
				}
				method_type := function_type_from_decl(ctx, m)
				ctx.current_type_params = prev

				if len(method_type.params) == 0 ||
				   !types_are_equal(method_type.params[0], target_type) {
					report(
						ctx,
						m.span,
						"Type Error: первый аргумент метода '%s' должен иметь тип '%s'",
						m.name,
						target_type.name,
					)
				}
				ctx.res.symbol_types[sym] = method_type
				original_name := m.name[len(d.target_type) + 2:]
				target_type.methods[original_name] = sym

				if own_scheme {
					// Метод получает СВОЮ Type_Scheme — иначе первый же
					// вызов зацементирует T/E шаблона навсегда (structural
					// fallback в unify_types, Phase D, связал бы шаблонный
					// InferVar с конкретным типом ПОСТОЯННО, ведь это:
					// Коробка ссылается на общий на все инстанциации
					// шаблонный ^Type). generalize находит T/E
					// автоматически: это: Коробка резолвится в сам
					// шаблонный ^Type (T внутри), E — прямая InferVar-
					// ссылка в параметре; collect_free_infer_vars проходит
					// внутрь через .Struct/.Enum-case (с cycle-guard,
					// Phase D) и находит оба.
					try_generalize(ctx, sym, method_type)
					// Персистируем combined под СОБСТВЕННЫМ Symbol_Id
					// метода — ПРОХОД 4 должен резолвить T/E в теле в ТЕ
					// ЖЕ InferVar-узлы, что и сигнатура здесь, иначе тело
					// получило бы свежие (несвязанные с func_type) узлы.
					ctx.decl_type_params[sym] = combined
				}
			}

			// Строгая проверка интерфейсного контракта (только Struct — см.
			// guard выше)
			if d.interface_name != "" {
				iface_sym: Symbol_Id
				if d.interface_module != "" {
					// Стадия 40: "реализация Модуль.Интерфейс для Тип" —
					// тот же путь резолва, что Type_Qualified для
					// "модуль.Тип" в аннотациях типов (см. case
					// ^Type_Qualified выше).
					module_sym := lookup_symbol(ctx.res.global_scope, intern(d.interface_module))
					if module_sym == INVALID_SYMBOL || symbol_at(ctx.res.symbol_store, module_sym).kind != .Module {
						report(ctx, d.span, "Type Error: неизвестный модуль '%s'", d.interface_module)
						continue
					}
					imported_module := symbol_at(ctx.res.symbol_store, module_sym).module
					if imported_module == nil {
						report(ctx, d.span, "Type Error: модуль '%s' не загружен", d.interface_module)
						continue
					}
					export_sym, found := imported_module.exports[intern(d.interface_name)]
					if !found {
						report(
							ctx,
							d.span,
							"Type Error: модуль '%s' не экспортирует '%s'",
							d.interface_module,
							d.interface_name,
						)
						continue
					}
					iface_sym = export_sym
				} else {
					iface_sym = ctx.res.global_scope.symbols[intern(d.interface_name)]
				}
				iface_type := ctx.res.symbol_types[iface_sym]

				if iface_type == nil || iface_type.kind != .Interface {
					report(
						ctx,
						d.span,
						"Type Error: '%s' не является интерфейсом",
						d.interface_name,
					)
					continue
				}

				for req_name in iface_type.interface_methods {
					method_sym, found := target_type.methods[req_name]
					if !found {
						report(
							ctx,
							d.span,
							"Type Error: структура '%s' не реализует метод '%s'",
							d.target_type,
							req_name,
						)
						continue
					}

					expected_method_type := iface_type.interface_methods[req_name]

					// Стадия 28: generic-интерфейс — T в expected_method_type
					// сейчас та же InferVar, что и в ДЕКЛАРАЦИИ интерфейса
					// (общая на ВСЕ impl-блоки). Подставляем СВЕЖУЮ InferVar
					// на T ПЕРЕД сравнением — иначе связывание T первым же
					// impl'ом (interface_method_types_match ниже теперь
					// unify_types, не types_are_equal) зацементировало бы T
					// навсегда, ломая проверку второго impl с другим T.
					// instantiate_type НЕ трогает сам iface_type (нет кейса
					// под .Interface — проходит как есть, тот же указатель),
					// так что Self-проверка (params[0] == iface_type) ниже не
					// страдает — подставляются только вхождения T.
					if order, has_params := ctx.decl_type_param_order[iface_sym]; has_params && len(order) > 0 {
						subst := make(map[int]^Type)
						for tv in order do subst[tv.infer_id] = new_infer_var(ctx)
						expected_method_type = instantiate_type(ctx, expected_method_type, &subst)
					}

					actual_method_type := ctx.res.symbol_types[method_sym]
					if !interface_method_types_match(expected_method_type, actual_method_type, iface_type, target_type) {
						report(
							ctx,
							d.span,
							"Type Error: метод '%s' структуры '%s' не совпадает с контрактом интерфейса '%s'",
							req_name,
							d.target_type,
							d.interface_name,
						)
					}
				}
				append(&target_type.implemented_interfaces, iface_type)
			}
		}
	}
}

// ПРОХОД 4 (Pass_Kind.Bodies): глубокая проверка тел всех функций и методов.
typecheck_pass_bodies :: proc(ctx: ^Type_Ctx, prog: Program) {
	for decl in prog.decls {
		#partial switch d in decl {
		case ^Function_Decl:
			sym := ctx.res.decl_symbols[decl]
			// Стадия 24: могла уже быть проверена внеочередно (запусти
			// сослался на неё раньше по файлу) — ensure_body_checked не
			// продублирует.
			ensure_body_checked(ctx, sym)
		case ^Impl_Decl:
			// Стадия 7 Phase E/F: тело generic-метода резолвит T/E в ТЕ ЖЕ
			// InferVar, что и сигнатура в ПРОХОД 3 — ключ по СОБСТВЕННОМУ
			// Symbol_Id метода (не владельца), т.к. combined там уже
			// включает и владельца, и собственные type-параметры метода
			// (Опция.результат_или[E]).
			for m in d.methods {
				sym := ctx.res.decl_symbols[m]
				func_type := ctx.res.symbol_types[sym]
				if func_type == nil {
					// ПРОХОД 3 пропустил регистрацию этого метода — target
					// реализации не структура (диагностика уже зарепорчена
					// там же, см. "неизвестная структура"). Тело метода
					// проверять нечем — пропускаем, не падаем на
					// bind_function_args(nil).
					continue
				}
				check_decl_body(ctx, sym, m, func_type)
			}
		}
	}
}

// Преобразует синтаксический узел типа в внутреннее представление.
// Здесь же проверяются ограничения на generic-конструкторы.
resolve_type_node :: proc(ctx: ^Type_Ctx, node: Type_Node) -> ^Type {
	if node == nil do return TY_VOID

	switch n in node {
	case ^Type_Ident:
		// Стадия 7 Phase B: type-параметр текущей generic-функции
		// перекрывает глобальные имена типов (обычная лексическая область
		// видимости) — проверяем первым.
		if ctx.current_type_params != nil {
			if tv, ok := ctx.current_type_params[n.name]; ok do return tv
		}
		if base_type, ok := lookup_base_type(n.name); ok do return base_type
		if sym := lookup_symbol(ctx.res.global_scope, intern(n.name)); sym != INVALID_SYMBOL {
			if symbol_at(ctx.res.symbol_store, sym).kind == .Module {
				return report(
					ctx,
					n.span,
					"Type Error: модуль '%s' нельзя использовать как тип",
					n.name,
				)
			}
			if typ, ok := ctx.res.symbol_types[sym]; ok do return typ
		}
		return report(ctx, n.span, "Type Error: неизвестный тип '%s'", n.name)

	case ^Type_Tuple:
		elements := make([dynamic]^Type)
		for el_node in n.elements {
			append(&elements, resolve_type_node(ctx, el_node))
		}
		return new_tuple_type(elements)

	case ^Type_Function:
		params := make([dynamic]^Type)
		for p_node in n.params {
			append(&params, resolve_type_node(ctx, p_node))
		}
		return_type := resolve_type_node(ctx, n.return_type)
		return new_function_type(params, return_type)
	case ^Type_Qualified:
		module_sym := lookup_symbol(ctx.res.global_scope, intern(n.module_name))
		if module_sym == INVALID_SYMBOL || symbol_at(ctx.res.symbol_store, module_sym).kind != .Module {
			return report(ctx, n.span, "Type Error: неизвестный модуль '%s'", n.module_name)
		}
		imported_module := symbol_at(ctx.res.symbol_store, module_sym).module
		if imported_module == nil {
			return report(ctx, n.span, "Type Error: модуль '%s' не загружен", n.module_name)
		}
		if export_sym, found := imported_module.exports[intern(n.name)]; found {
			if typ, found_type := ctx.res.symbol_types[export_sym]; found_type {
				return typ
			}
			return report(
				ctx,
				n.span,
				"Type Error: тип '%s.%s' еще не доступен",
				n.module_name,
				n.name,
			)
		}
		return report(
			ctx,
			n.span,
			"Type Error: модуль '%s' не экспортирует '%s'",
			n.module_name,
			n.name,
		)
	case ^Type_Generic:
		if n.name == "Массив" {
			if len(n.params) != 1 do return report(ctx, n.span, "Type Error: Массив ожидает 1 параметр типа")
			return new_array_type(resolve_type_node(ctx, n.params[0]))
		} else if n.name == "Соответствие" {
			if len(n.params) != 2 do return report(ctx, n.span, "Type Error: Соответствие ожидает 2 параметра типа")
			key_type := resolve_type_node(ctx, n.params[0])
			if !is_valid_map_key_type(key_type) {
				return report(
					ctx,
					n.span,
					"Type Error: тип '%s' нельзя использовать как ключ соответствия",
					key_type.name,
				)
			}
			return new_map_type(key_type, resolve_type_node(ctx, n.params[1]))
		} else if n.name == "Процесс" {
			if len(n.params) != 1 do return report(ctx, n.span, "Type Error: Процесс ожидает 1 параметр типа")
			return new_process_type(resolve_type_node(ctx, n.params[0]))
		} else if n.name == "Указатель" {
			if len(n.params) != 1 do return report(ctx, n.span, "Type Error: Указатель ожидает 1 параметр типа")
			return new_pointer_type(resolve_type_node(ctx, n.params[0]))
		} else {
			// Стадия 7 Phase C: пользовательский generic-тип (структура).
			// Раньше здесь не было fallback'а вообще — неизвестное имя
			// молча проваливалось в `return TY_VOID` в конце функции
			// (например, Флаг(Число) для НЕ-generic структуры Флаг
			// компилировалось без единой ошибки). Теперь либо находим
			// generic-декларацию и инстанцируем, либо репортим понятную
			// ошибку.
			sym := lookup_symbol(ctx.res.global_scope, intern(n.name))
			if sym == INVALID_SYMBOL {
				return report(ctx, n.span, "Type Error: неизвестный тип '%s'", n.name)
			}
			// Стадия 7 Phase D: самоссылка (Дерево(T) внутри Дерево[T] =
			// перечисление ... конец) — шаблон ЕЩЁ строится в этом же
			// ПРОХОД 2 (variants неполны), instantiate_type/кэш
			// скопировали бы недостроенный объект. Возвращаем шаблонный
			// указатель напрямую — тот же мутируемый объект, ПРОХОД 2
			// продолжает дополнять его append'ом, к моменту реального
			// использования (ПРОХОД 4+) он уже полон.
			if sym == ctx.currently_declaring_generic {
				return ctx.res.symbol_types[sym]
			}
			ordered, is_generic := ctx.decl_type_param_order[sym]
			if !is_generic {
				return report(ctx, n.span, "Type Error: '%s' не является generic-типом", n.name)
			}
			if len(n.params) != len(ordered) {
				return report(
					ctx,
					n.span,
					"Type Error: '%s' ожидает %d параметров типа, получено %d",
					n.name,
					len(ordered),
					len(n.params),
				)
			}
			args := make([dynamic]^Type)
			for p in n.params do append(&args, resolve_type_node(ctx, p))

			subst := make(map[int]^Type)
			for tv, i in ordered do subst[tv.infer_id] = args[i]
			instance := instantiate_type(ctx, ctx.res.symbol_types[sym], &subst)

			// Стадия 7 Phase D: ключ строится ПОСЛЕ инстанциации, из
			// самого instance (collect_instance_args) — не из сырых args
			// до подстановки. Раньше (Phase C) ключ строился из args
			// (порядок заголовка), а конструктор — из полей (порядок
			// объявления); расходились, если поля объявлены не в порядке
			// заголовка. Общий обход убирает расхождение.
			canon_args := make([dynamic]^Type)
			collect_instance_args(instance, &canon_args)
			key := generic_instance_key(sym, canon_args)
			if cached, found := ctx.generic_instance_cache[key]; found do return cached
			ctx.generic_instance_cache[key] = instance
			return instance
		}
	case ^Error_Type_Node:
		// Уже отрапортовано парсером — не дублируем diagnostic.
		return TY_POISON
	}
	return TY_VOID
}

// Строгое сравнение типов без вывода и без побочных связываний.
types_are_equal :: proc(a: ^Type, b: ^Type) -> bool {
	left := prune_type(a)
	right := prune_type(b)
	if left == nil || right == nil do return false
	if left == right do return true
	if left.kind == .Poison || right.kind == .Poison do return true
	if left.kind == .InferVar || right.kind == .InferVar do return false

	// Стадия 25: перечисления тоже могут реализовывать интерфейсы —
	// implemented_interfaces теперь заполняется и для .Enum (ПРОХОД 1/3).
	if right.kind == .Interface && (left.kind == .Struct || left.kind == .Enum) {
		for iface in left.implemented_interfaces {
			if iface == right do return true
		}
		return false
	}

	if left.kind != right.kind do return false

	#partial switch left.kind {
	case .Tuple:
		if len(left.elements) != len(right.elements) do return false
		for i in 0 ..< len(left.elements) {
			if !types_are_equal(left.elements[i], right.elements[i]) do return false
		}
		return true

	case .Function:
		if len(left.params) != len(right.params) do return false
		if !types_are_equal(left.return_type, right.return_type) do return false
		for i in 0 ..< len(left.params) {
			if !types_are_equal(left.params[i], right.params[i]) do return false
		}
		return true

	case .Array:
		return types_are_equal(left.element_type, right.element_type)

	case .Map:
		return(
			types_are_equal(left.key_type, right.key_type) &&
			types_are_equal(left.value_type, right.value_type) \
		)

	case .Struct, .Interface, .Enum:
		return false
	}
	return true
}

// Имя тупла строим из имён элементов, чтобы типы было удобно читать в ошибках.
new_tuple_type :: proc(elements: [dynamic]^Type) -> ^Type {
	t := new(Type)
	t.kind = .Tuple
	t.elements = elements

	builder: strings.Builder
	strings.builder_init(&builder)
	strings.write_string(&builder, "(")
	for el, i in elements {
		strings.write_string(&builder, el.name)
		if i < len(elements) - 1 do strings.write_string(&builder, ", ")
	}
	strings.write_string(&builder, ")")
	t.name = strings.to_string(builder)
	return t
}

// --- ПРОВЕРКА БЛОКОВ (Expression-Oriented Programming) ---

// В expression-oriented блоках типом блока считается тип последнего выражения.
// Последнее выражение блока, если блок заканчивается Expr_Stmt (тот же
// критерий, что infer_block_type использует, чтобы решить, какое выражение
// "становится" типом блока) — nil, если блок заканчивается чем-то другим
// (Let/Return/пустой блок). Нужен check_function_body, чтобы дотянуться до
// самого литерала для widen_num_literal_to_int (implicit return бежит через
// infer_expr, не check_expr, поэтому обычный widening по expected-типу сюда
// не долетает сам по себе).
last_block_expr :: proc(body: [dynamic]Stmt) -> Expr {
	if len(body) == 0 do return nil
	if s, ok := body[len(body) - 1].(^Expr_Stmt); ok do return s.expr
	return nil
}

infer_block_type :: proc(ctx: ^Type_Ctx, body: [dynamic]Stmt) -> ^Type {
	if len(body) == 0 do return TY_VOID

	// Проверяем все инструкции, кроме последней (они не влияют на возврат блока)
	for i in 0 ..< len(body) - 1 {
		infer_stmt(ctx, body[i])
	}

	// Последняя инструкция решает всё
	last_stmt := body[len(body) - 1]

	#partial switch s in last_stmt {
	case ^Expr_Stmt:
		// Если блок заканчивается выражением, блок принимает его тип
		return infer_expr(ctx, s.expr)
	case:
		// Let_Stmt или Return на конце блока ничего не возвращают (как значение блока)
		infer_stmt(ctx, last_stmt)
		return TY_VOID
	}
	return TY_VOID
}

// Сначала проверяем инструкции сверху вниз, затем сверяем фактический тип
// блока и явные `return` с ожидаемым возвращаемым типом. `span` — span
// объемлющей функции/лямбды/метода, используется для диагностик, у которых
// нет более точного узла (напр. "тело не возвращает значение").
check_function_body :: proc(ctx: ^Type_Ctx, span: Span, body: [dynamic]Stmt, expected_return: ^Type) {
	expected_return_type := prune_type(expected_return)
	prev_return := ctx.current_return
	ctx.current_return = expected_return_type

	for stmt in body {
		check_stmt(ctx, stmt, expected_return_type)
	}

	body_type := prune_type(infer_block_type(ctx, body))
	// Implicit return (последнее выражение блока без `возврат`) идёт через
	// infer_expr, не check_expr — обычный литерал-widening (см. check_expr's
	// Number_Expr-кейс) сюда не попадает. Целое-возвращающая функция с
	// голым `42` последней строкой — тот же случай, что `x + 5` при
	// x: Целое, поэтому переиспользуем widen_num_literal_to_int.
	if body_type == TY_NUM && expected_return_type == TY_INT {
		if last := last_block_expr(body); last != nil {
			body_type = widen_num_literal_to_int(ctx, last, body_type, TY_INT)
		}
	}
	explicit_return_type := prune_type(infer_function_body(ctx, body))

	if expected_return_type == TY_VOID {
		// Пусто-функция не обязана заканчиваться Пусто-выражением: последний
		// statement трактуется как обычный (значение отбрасывается), а не
		// как неявный return — ровно то же самое отбрасывание, что уже
		// происходит с любым НЕ последним statement'ом тела функции
		// (compile_statement эмитит Pop для non-void Expr_Stmt). VM это уже
		// поддерживал сам по себе: .Return снимает "лишнее" значение со
		// стека, но кладёт его вызывающему только если
		// frame.function.returns_value — для Пусто-функции результат
		// молча отбрасывается. Раньше здесь была ошибка, требовавшая явно
		// избегать non-void последнего выражения в Пусто-функции — убрано
		// по запросу пользователя.
		ctx.current_return = prev_return
		return
	}

	if body_type != TY_VOID {
		if !unify_types(body_type, expected_return_type) {
			report(
				ctx,
				span,
				"Type Error: функция должна возвращать '%s', но последнее выражение имеет тип '%s'",
				prune_type(expected_return_type).name,
				prune_type(body_type).name,
			)
		}
		ctx.current_return = prev_return
		return
	}

	if explicit_return_type != nil && explicit_return_type != TY_VOID {
		if !unify_types(explicit_return_type, expected_return_type) {
			report(
				ctx,
				span,
				"Type Error: функция должна возвращать '%s', но return имеет тип '%s'",
				prune_type(expected_return_type).name,
				prune_type(explicit_return_type).name,
			)
		}
		ctx.current_return = prev_return
		return
	}

	ctx.current_return = prev_return
	report(
		ctx,
		span,
		"Type Error: функция должна возвращать '%s', но тело не возвращает значение",
		prune_type(expected_return_type).name,
	)
}

// Ищет первый явный `return` в теле callable-выражения.
infer_function_body :: proc(ctx: ^Type_Ctx, body: [dynamic]Stmt) -> ^Type {
	actual_return := TY_VOID
	for stmt in body {
		ret := infer_stmt(ctx, stmt)
		if ret != nil {
			actual_return = ret
			break
		}
	}
	return actual_return
}

// Стадия 23 (Итерируемое): For_In_Stmt НЕ десахарен parser'ом (в отличие
// от for-range, которая всегда числовая и не нуждается в типе) — сам
// выбирает форму компиляции здесь, зная тип `в`-выражения. Два пути:
//   1. Fast_Array — obj_type.kind == .Array (Соответствие НЕ поддержан
//      напрямую и раньше — только через .записи(), возвращающую Массив
//      кортежей, см. существующий error hint в infer_index_expr).
//   2. Iterator_Protocol — obj_type implements Итерируемое (nominal,
//      как остальные interface-checks в этом файле).
// Решение пишется в ctx.for_in_infos[stmt] — читает compiler.odin.
infer_for_in_stmt :: proc(ctx: ^Type_Ctx, stmt: Stmt, s: ^For_In_Stmt) {
	iter_type := prune_type(infer_expr(ctx, s.iterable))
	names_syms := ctx.res.for_in_names_syms[stmt]

	bind_poison := proc(ctx: ^Type_Ctx, syms: [dynamic]Symbol_Id) {
		for sym in syms do ctx.res.symbol_types[sym] = TY_POISON
	}

	if iter_type.kind == .Poison {
		bind_poison(ctx, names_syms)
	} else if iter_type.kind == .Array {
		elem_type := prune_type(iter_type.element_type)
		if len(s.names) == 1 {
			ctx.res.symbol_types[names_syms[0]] = elem_type
		} else if elem_type.kind == .Tuple && len(elem_type.elements) == len(s.names) {
			for i in 0 ..< len(s.names) {
				ctx.res.symbol_types[names_syms[i]] = prune_type(elem_type.elements[i])
			}
		} else {
			report(
				ctx,
				s.span,
				"Type Error: шаблон 'для (...)' из %d имён не совпадает с элементом массива типа '%s'",
				len(s.names),
				elem_type.name,
			)
			bind_poison(ctx, names_syms)
		}
		ctx.for_in_infos[stmt] = For_In_Info{kind = .Fast_Array}
	} else if iter_type.kind == .Struct &&
	   implements_prelude_interface(ctx, iter_type, ctx.res.prelude_iterable_sym) {
		method_sym, _ := method_lookup(ctx, iter_type, "следующий")
		method_type := prune_type(ctx.res.symbol_types[method_sym])
		// method_type.return_type — конкретный Опция(T) ЭТОГО impl'а
		// (variants[1] = Есть, fields[0] = T — тот же паттерн, что
		// infer_try_expr уже использует для `?`-оператора). T может быть
		// туплом ("для (a, b) в ...") — тот же паттерн деструктуризации,
		// что fast-path уже применяет к Массив((К,З)).
		option_type := prune_type(method_type.return_type)
		elem_type := prune_type(option_type.variants[1].fields[0])
		if len(s.names) == 1 {
			ctx.res.symbol_types[names_syms[0]] = elem_type
		} else if elem_type.kind == .Tuple && len(elem_type.elements) == len(s.names) {
			for i in 0 ..< len(s.names) {
				ctx.res.symbol_types[names_syms[i]] = prune_type(elem_type.elements[i])
			}
		} else {
			report(
				ctx,
				s.span,
				"Type Error: шаблон 'для (...)' из %d имён не совпадает со значением Итерируемое типа '%s'",
				len(s.names),
				elem_type.name,
			)
			bind_poison(ctx, names_syms)
		}
		ctx.for_in_infos[stmt] = For_In_Info{kind = .Iterator_Protocol, next_method_sym = method_sym}
	} else if iter_type.kind == .Map {
		// Тот же hint, что раньше давала infer_index_expr, когда старое
		// parse-time-десахаренное `для x в карта` доходило до `[idx]` с
		// Число-индексом на Map (ключ обычно НЕ Число) — теперь Map
		// перехватывается ЗДЕСЬ до всякого Index_Expr, hint нужно
		// воспроизвести явно, иначе регрессия diagnostic UX.
		report(
			ctx,
			s.span,
			"Type Error: соответствие индексируется по ключу типа '%s', получено 'Число' — Соответствие не поддерживает позиционный доступ; для перебора элементов используйте .записи() и 'для (ключ, значение) в ...'",
			prune_type(iter_type.key_type).name,
		)
		bind_poison(ctx, names_syms)
	} else {
		report(
			ctx,
			s.span,
			"Type Error: тип '%s' не поддерживает 'для x в' (нужен Массив или тип, реализующий Итерируемое)",
			iter_type.name,
		)
		bind_poison(ctx, names_syms)
		// for_in_infos НЕ пишется — diagnostics гейтят пайплайн до
		// компиляции (тот же принцип, что у всех остальных sugar-путей
		// в этом файле), compiler.odin сюда не дойдёт.
	}

	ctx.loop_depth += 1
	infer_block_type(ctx, s.body)
	ctx.loop_depth -= 1
}

// Деструктуризация в пер/конст — `пер (a, b) = кортеж` (тупл, s.names
// непусто, s.destructure_type == "") или `пер Тип(a, b) = значение`
// (структура, поля по ПОРЯДКУ ОБЪЯВЛЕНИЯ — тот же позиционный принцип,
// что и у обычного конструктора `Тип(1, 2)`). Тот же общий каркас, что
// infer_for_in_stmt использует для `для (a, b) в ...` — bind_poison на
// несовпадении формы, без каскада вторичных diagnostics.
infer_let_destructure_stmt :: proc(ctx: ^Type_Ctx, stmt: Stmt, s: ^Let_Stmt) {
	syms := ctx.res.let_destructure_syms[stmt]
	value_type := prune_type(infer_expr(ctx, s.value))

	bind_poison := proc(ctx: ^Type_Ctx, syms: [dynamic]Symbol_Id) {
		for sym in syms do ctx.res.symbol_types[sym] = TY_POISON
	}

	if value_type.kind == .Poison {
		bind_poison(ctx, syms)
		return
	}

	if s.destructure_type != "" {
		if value_type.kind != .Struct || value_type.name != s.destructure_type {
			report(
				ctx,
				s.span,
				"Type Error: шаблон 'пер %s(...)' не совпадает со значением типа '%s'",
				s.destructure_type,
				value_type.name,
			)
			bind_poison(ctx, syms)
			return
		}
		if len(s.destructure_field_names) > 0 {
			// Именованная, ЧАСТИЧНАЯ форма (Стадия 37) — в отличие от
			// позиционной ниже, не требует упомянуть ВСЕ поля структуры.
			field_indices := make([dynamic]int, len(syms))
			seen := make([dynamic]bool, len(value_type.fields), context.temp_allocator)
			ok := true
			for field_name, i in s.destructure_field_names {
				idx := -1
				for f, fi in value_type.fields {
					if f.name == field_name {
						idx = fi
						break
					}
				}
				if idx == -1 {
					report(
						ctx,
						s.span,
						"Type Error: у структуры '%s' нет поля '%s'",
						value_type.name,
						field_name,
					)
					ok = false
					continue
				}
				if seen[idx] {
					report(
						ctx,
						s.span,
						"Type Error: поле '%s' указано в деструктуризации повторно",
						field_name,
					)
					ok = false
					continue
				}
				seen[idx] = true
				field_indices[i] = idx
				ctx.res.symbol_types[syms[i]] = prune_type(value_type.fields[idx].type)
			}
			if !ok {
				bind_poison(ctx, syms)
				return
			}
			ctx.let_destructure_field_indices[stmt] = field_indices
			return
		}
		if len(value_type.fields) != len(syms) {
			report(
				ctx,
				s.span,
				"Type Error: у структуры '%s' %d полей, в шаблоне деструктуризации %d имён",
				value_type.name,
				len(value_type.fields),
				len(syms),
			)
			bind_poison(ctx, syms)
			return
		}
		field_indices := make([dynamic]int, len(syms))
		for i in 0 ..< len(syms) {
			field_indices[i] = i
			ctx.res.symbol_types[syms[i]] = prune_type(value_type.fields[i].type)
		}
		ctx.let_destructure_field_indices[stmt] = field_indices
	} else {
		if value_type.kind != .Tuple {
			report(
				ctx,
				s.span,
				"Type Error: шаблон 'пер (...)' ожидает тупл, получено '%s'",
				value_type.name,
			)
			bind_poison(ctx, syms)
			return
		}
		if len(value_type.elements) != len(syms) {
			report(
				ctx,
				s.span,
				"Type Error: тупл из %d элементов не совпадает с шаблоном из %d имён",
				len(value_type.elements),
				len(syms),
			)
			bind_poison(ctx, syms)
			return
		}
		field_indices := make([dynamic]int, len(syms))
		for i in 0 ..< len(syms) {
			field_indices[i] = i
			ctx.res.symbol_types[syms[i]] = prune_type(value_type.elements[i])
		}
		ctx.let_destructure_field_indices[stmt] = field_indices
	}
}

// --- ПРОВЕРКА ИНСТРУКЦИЙ (STATEMENTS) ---

// Statement-level проверка знает ожидаемый тип возврата окружения.
check_stmt :: proc(ctx: ^Type_Ctx, stmt: Stmt, expected_return: ^Type) {
	if stmt == nil do return

	switch s in stmt {
	case ^Return_Stmt:
		if s.value != nil {
			check_expr(ctx, s.value, expected_return)
		} else if expected_return != TY_VOID {
			report(
				ctx,
				s.span,
				"Type Error: ожидался возврат %s, но return пустой",
				expected_return.name,
			)
		}

	case ^Let_Stmt, ^Expr_Stmt, ^Continue_Stmt, ^Break_Stmt, ^Error_Stmt, ^For_In_Stmt:
		infer_stmt(ctx, stmt)
	}
}

// Вывод типа инструкции, если она сама производит значение.
infer_stmt :: proc(ctx: ^Type_Ctx, stmt: Stmt) -> ^Type {
	if stmt == nil do return nil

	switch s in stmt {
	case ^Return_Stmt:
		if s.value != nil {
			return infer_expr(ctx, s.value)
		}
		return TY_VOID

	case ^Let_Stmt:
		if len(s.names) > 0 {
			infer_let_destructure_stmt(ctx, stmt, s)
			return nil
		}
		sym := ctx.res.stmt_symbols[stmt]
		if s.type_annotation != nil {
			expected_type := resolve_type_node(ctx, s.type_annotation)
			if expected_type == TY_VOID {
				report(
					ctx,
					s.span,
					"Type Error: переменная '%s' не может иметь тип 'Пусто'",
					s.name,
				)
			}
			check_expr(ctx, s.value, expected_type)
			ctx.res.symbol_types[sym] = expected_type
		} else {
			// Стадия 7 Phase A: если s.value — лямбда, на время её инференса
			// разрешаем ЕЙ (и только ей — см. Type_Ctx.allow_unresolved_lambda)
			// остаться со свободными InferVar в теле; check_lambda_expr иначе
			// репортит "не удалось вывести тип лямбды" до того, как мы вообще
			// успеваем решить — generalize их или это правда ошибка.
			_, is_lambda := s.value.(^Lambda_Expr)
			prev_allow := ctx.allow_unresolved_lambda
			if is_lambda do ctx.allow_unresolved_lambda = s.value
			t := infer_expr(ctx, s.value)
			ctx.allow_unresolved_lambda = prev_allow

			t = prune_type(t)
			if t == TY_VOID {
				report(
					ctx,
					s.span,
					"Type Error: переменная '%s' не может иметь тип 'Пусто'",
					s.name,
				)
			}

			// Разрешение выше было условным — теперь решаем окончательно:
			// обобщаем в полиморфную схему, если остались свободные InferVar,
			// иначе (обычное значение или полностью резолвнутая лямбда) —
			// прежняя строгая проверка.
			generalized := false
			if is_lambda && t.kind == .Function {
				scheme := generalize(ctx, t)
				if len(scheme.forall) > 0 {
					ctx.symbol_schemes[sym] = scheme
					generalized = true
				}
			}
			if !generalized {
				ensure_type_resolved(ctx, s.span, t, fmt.tprintf("переменной '%s'", s.name))
			}
			ctx.res.symbol_types[sym] = t
		}

	case ^Expr_Stmt:
		infer_expr(ctx, s.expr)

	case ^Continue_Stmt:
		if ctx.loop_depth == 0 {
			report(
				ctx,
				s.span,
				"Type Error: 'продолжить' можно использовать только внутри цикла",
			)
		}

	case ^Break_Stmt:
		if ctx.loop_depth == 0 {
			report(
				ctx,
				s.span,
				"Type Error: 'прервать' можно использовать только внутри цикла",
			)
		}

	case ^Error_Stmt:
	// Уже отрапортовано парсером — нечего проверять.

	case ^For_In_Stmt:
		infer_for_in_stmt(ctx, stmt, s)
	}
	return nil
}

// --- ПРОВЕРКА ВЫРАЖЕНИЙ (EXPRESSIONS) ---

// Проверяет выражение в контексте ожидаемого типа.
// Для лямбд, коллекций и вызовов это позволяет протолкнуть типы вниз.
check_expr :: proc(ctx: ^Type_Ctx, expr: Expr, expected: ^Type) {
	if expr == nil do return
	expected_type := prune_type(expected)

	#partial switch e in expr {
	case ^Number_Expr:
		// Литерал сам по себе всегда Число (infer_expr) — Целое достижим
		// ТОЛЬКО явно, через контекст с ожидаемым Целое (аннотация/поле/
		// параметр). Дробный литерал в Целое-контексте — ошибка, не
		// молчаливое усечение.
		if expected_type == TY_INT {
			if e.value != math.trunc(e.value) {
				report(
					ctx,
					expr_span(expr),
					"Type Error: дробный литерал '%v' несовместим с Целое",
					e.value,
				)
			}
			ctx.node_types[expr] = TY_INT
			return
		}
	case ^Unary_Expr:
		// Отрицательный целочисленный литерал (`-5`) в Целое-контексте —
		// тот же принцип, что голый литерал выше, только сам литерал на
		// один уровень глубже (под Unary_Expr), см. классификацию
		// Число vs Целое по СИНТАКСИСУ выражения в целом, не отдельному
		// узлу.
		if expected_type == TY_INT && e.op == .Minus {
			if num, ok := e.right.(^Number_Expr); ok && num.value == math.trunc(num.value) {
				ctx.node_types[e.right] = TY_INT
				ctx.node_types[expr] = TY_INT
				return
			}
		}
	case ^Binary_Expr:
		// Составное арифметическое выражение (`длина(x) - 1`, `0 - 1`) в
		// Целое-контексте — литерал-кейс выше widen'ит только САМ литерал
		// напрямую под check_expr, но `а - б` тут — Binary_Expr, не
		// Number_Expr, и без явного проталкивания контекста ВНИЗ на a/b
		// (см. для-range desugar в parser.odin: `пер <сч> = <start> - 1`,
		// оба операнда литералы, ни один не видит Целое-ожидание сам по
		// себе) типизация бы застряла на Число по умолчанию.
		#partial switch e.op {
		case .Plus, .Minus, .Star:
			if expected_type == TY_INT {
				check_expr(ctx, e.left, TY_INT)
				check_expr(ctx, e.right, TY_INT)
				left_t := prune_type(infer_expr(ctx, e.left))
				right_t := prune_type(infer_expr(ctx, e.right))
				if left_t == TY_INT && right_t == TY_INT {
					ctx.node_types[expr] = TY_INT
					return
				}
			}
		}
	case ^Lambda_Expr:
		if expected_type.kind == .Function {
			check_lambda_expr(ctx, expr, e, expected_type)
			return
		}

	case ^Array_Expr:
		if expected_type.kind == .Array {
			for el in e.elements {
				check_expr(ctx, el, expected_type.element_type)
			}
			ctx.node_types[expr] = expected_type
			return
		}
	case ^Map_Expr:
		if expected_type.kind == .Map {
			for entry in e.entries {
				check_expr(ctx, entry.key, expected_type.key_type)
				check_expr(ctx, entry.value, expected_type.value_type)
			}
			ctx.node_types[expr] = expected_type
			return
		}
	}

	actual := prune_type(infer_expr(ctx, expr))

	// Стадия 25: перечисления тоже приводятся к интерфейсу.
	if expected_type.kind == .Interface && (actual.kind == .Struct || actual.kind == .Enum) {
		if unify_types(actual, expected_type) {
			ctx.interface_casts[expr] = actual
			return
		}
	}

	if !unify_types(actual, expected_type) {
		report(
			ctx,
			expr_span(expr),
			"Type Error: ожидался '%s', получен '%s'",
			prune_type(expected_type).name,
			prune_type(actual).name,
		)
	}
}

Builtin_Ctor_Sig :: struct {
	name:    string,
	arity:   int,
	handler: proc(ctx: ^Type_Ctx, call: Expr, args: [dynamic]Expr) -> ^Type,
}

// Таблица builtin-конструкторов (Ошибка/длина/паника). Есть/Нет/Успех/
// Неудача — теперь настоящие variant-конструкторы прелюдии (Стадия 7
// Phase F), идут через обычный resolve_variant_ctor путь. Arity
// проверяется единообразно диспетчером; handler отвечает
// только за построение типа-результата и (для 'длина') за
// дополнительную type-based валидацию.
BUILTIN_CTORS := [?]Builtin_Ctor_Sig {
	{
		name = "Ошибка",
		arity = 2,
		handler = proc(ctx: ^Type_Ctx, call: Expr, args: [dynamic]Expr) -> ^Type {
			check_expr(ctx, args[0], TY_STRING)
			check_expr(ctx, args[1], TY_STRING)
			return TY_ERROR
		},
	},
	{
		name = "длина",
		arity = 1,
		handler = proc(ctx: ^Type_Ctx, call: Expr, args: [dynamic]Expr) -> ^Type {
			arg_type := prune_type(infer_expr(ctx, args[0]))
			if arg_type.kind == .String || arg_type.kind == .Array || arg_type.kind == .Map {
				return TY_INT
			}
			if arg_type.kind == .Poison do return TY_POISON
			return report(
				ctx,
				expr_span(call),
				"Type Error: длина() ожидает строку, массив или соответствие, получен '%s'",
				arg_type.name,
			)
		},
	},
	{
		name = "паника",
		arity = 1,
		handler = proc(ctx: ^Type_Ctx, call: Expr, args: [dynamic]Expr) -> ^Type {
			check_expr(ctx, args[0], TY_STRING)
			return TY_NEVER
		},
	},
	{
		// Стадия 24 (actor model): получить() — bare builtin (как длина/
		// паника), но БЕЗ фиксированного типа результата. Первый вызов В
		// ТЕЛЕ ТЕКУЩЕЙ функции заводит свежий InferVar (ctx.current_
		// process_message_var), последующие вызовы В ТОЙ ЖЕ функции
		// переиспользуют его же — один mailbox, один T. Компилируется в
		// опкод .Receive (см. compiler.odin), реальное значение приходит
		// из mailbox текущего процесса в рантайме.
		name = "получить",
		arity = 0,
		handler = proc(ctx: ^Type_Ctx, call: Expr, args: [dynamic]Expr) -> ^Type {
			if ctx.current_process_message_var == nil {
				ctx.current_process_message_var = new_infer_var(ctx)
			}
			return ctx.current_process_message_var
		},
	},
	{
		// Стадия 24: себя() — Процесс(T)-хэндл ТЕКУЩЕГО процесса (T — тот
		// же message-var, что у получить() в ЭТОЙ ЖЕ функции — переиспользует
		// поле, а не заводит отдельный; себя() до первого получить() в
		// теле заводит его сам). Нужен, чтобы `старт()` мог передать
		// СВОЙ адрес спавненному процессу и получить ответ через
		// собственный получить() — единственный способ реализовать
		// "получить() на своём mailbox даёт ожидание ответа" (см. ROADMAP
		// §Стадия 24, п.6) без отдельного join/monitor-примитива.
		name = "себя",
		arity = 0,
		handler = proc(ctx: ^Type_Ctx, call: Expr, args: [dynamic]Expr) -> ^Type {
			if ctx.current_process_message_var == nil {
				ctx.current_process_message_var = new_infer_var(ctx)
			}
			return new_process_type(ctx.current_process_message_var)
		},
	},
	{
		// Стадия 24: отправить(процесс, сообщение) — обычная 2-арг
		// builtin-функция (НЕ новый опкод, см. Порядок работ ROADMAP).
		// Тихий no-op на мёртвый процесс проверяется в рантайме (Process_
		// Value.is_alive), не здесь — типизация не знает о живости.
		name = "отправить",
		arity = 2,
		handler = proc(ctx: ^Type_Ctx, call: Expr, args: [dynamic]Expr) -> ^Type {
			proc_type := prune_type(infer_expr(ctx, args[0]))
			if proc_type.kind == .Poison do return TY_VOID
			if proc_type.kind != .Process {
				return report(
					ctx,
					expr_span(args[0]),
					"Type Error: отправить() ожидает Процесс(T) первым аргументом, получен '%s'",
					proc_type.name,
				)
			}
			check_expr(ctx, args[1], proc_type.element_type)

			// Стадия 24 (actor model): copy-on-send. T реализует
			// Копируемое — компилятор вставляет .клонировать() ПЕРЕД
			// builtin'ом (тот же Call_Info-паттерн, что Print_Value у
			// Печатаемого, Стадия 23) и компилирует в
			// "отправить_без_копии" (сообщение УЖЕ независимая копия —
			// повторный reflective walk исказил бы намеренно НЕ
			// скопированные пользователем поля, см. prelude.odin). Не
			// реализует — обычный "отправить", рантайм сам обходит
			// структуру (message_deep_copy, vm.odin).
			msg_type := prune_type(proc_type.element_type)
			if (msg_type.kind == .Struct || msg_type.kind == .Enum) &&
			   implements_prelude_interface(ctx, msg_type, ctx.res.prelude_copyable_sym) {
				if method_sym, found := method_lookup(ctx, msg_type, "клонировать"); found {
					ctx.call_infos[call] = Call_Info{kind = .Send_Copy, symbol_ref = method_sym}
				}
			}
			return TY_VOID
		},
	},
	{
		// Стадия 38 (monitor): наблюдать(процесс) — регистрирует ТЕКУЩИЙ
		// процесс наблюдателем цели, для ЛЮБОГО T (типизация не знает и
		// не должна знать T цели — сигнал несёт только id + причину, не
		// само сообщение, см. получить_сигнал ниже). Обычный .Call_Builtin
		// путь (не suspend/resume) — регистрация синхронна и всегда
		// завершается немедленно.
		name = "наблюдать",
		arity = 1,
		handler = proc(ctx: ^Type_Ctx, call: Expr, args: [dynamic]Expr) -> ^Type {
			proc_type := prune_type(infer_expr(ctx, args[0]))
			if proc_type.kind == .Poison do return TY_VOID
			if proc_type.kind != .Process {
				return report(
					ctx,
					expr_span(args[0]),
					"Type Error: наблюдать() ожидает Процесс(T) первым аргументом, получен '%s'",
					proc_type.name,
				)
			}
			return TY_VOID
		},
	},
	{
		// Стадия 42 (kill-примитив): убить(процесс) — принудительно
		// останавливает ЧУЖОЙ процесс, для ЛЮБОГО T (та же логика, что
		// у наблюдать() — типизация не знает и не должна знать T цели).
		// Самоубийство/убийство "старт()" — рантайм-проверки (vm.odin),
		// не здесь: типизация не знает "текущий процесс" статически.
		name = "убить",
		arity = 1,
		handler = proc(ctx: ^Type_Ctx, call: Expr, args: [dynamic]Expr) -> ^Type {
			proc_type := prune_type(infer_expr(ctx, args[0]))
			if proc_type.kind == .Poison do return TY_VOID
			if proc_type.kind != .Process {
				return report(
					ctx,
					expr_span(args[0]),
					"Type Error: убить() ожидает Процесс(T) первым аргументом, получен '%s'",
					proc_type.name,
				)
			}
			return TY_VOID
		},
	},
	{
		// Стадия 44 (link-примитив): связать(процесс) — двусторонняя
		// связь, для ЛЮБОГО T (та же логика, что у наблюдать()/убить()).
		// Самолинковка/запрет на "старт()" — рантайм-проверки (vm.odin),
		// не здесь: типизация не знает "текущий процесс" статически.
		name = "связать",
		arity = 1,
		handler = proc(ctx: ^Type_Ctx, call: Expr, args: [dynamic]Expr) -> ^Type {
			proc_type := prune_type(infer_expr(ctx, args[0]))
			if proc_type.kind == .Poison do return TY_VOID
			if proc_type.kind != .Process {
				return report(
					ctx,
					expr_span(args[0]),
					"Type Error: связать() ожидает Процесс(T) первым аргументом, получен '%s'",
					proc_type.name,
				)
			}
			return TY_VOID
		},
	},
	{
		// Стадия 38: получить_сигнал() — ФИКСИРОВАННЫЙ тип результата
		// (Целое, Опция(Строка)), в отличие от получить() не заводит
		// InferVar — сигналы приходят от РАЗНЫХ наблюдаемых процессов с
		// разным T, единственное общее — id (Целое) и причина
		// (Нет=штатно, Есть(текст)=краш).
		name = "получить_сигнал",
		arity = 0,
		handler = proc(ctx: ^Type_Ctx, call: Expr, args: [dynamic]Expr) -> ^Type {
			id_and_reason := make([dynamic]^Type, 0, 2)
			append(&id_and_reason, TY_INT)
			append(&id_and_reason, new_option_type(ctx, TY_STRING))
			return new_tuple_type(id_and_reason)
		},
	},
	{
		// Строковая интерполяция (`"...\(x)..."`, десахаривается парсером
		// в `+`-цепочку со вставками встроку(x), см. parse_interp_string
		// в parser.odin) — но встроку() САМА по себе тоже обычный вызываемый
		// bare-builtin, как длина/паника. Принимает ЛЮБОЙ Value (тот же
		// принцип, что ввод_вывод.печать/.строка, Стадия 23): если arg —
		// struct/enum с реализация Печатаемое, компилятор вызовет
		// .вСтроку() (Call_Info.Print_Value — переиспользуем ЦЕЛИКОМ тот
		// же Call_Kind и codegen, что печать/строка, только text_name
		// указывает на нативный builtin "встроку" в vm.odin, который
		// ВОЗВРАЩАЕТ Panos_String, а не печатает и возвращает Пусто).
		// Иначе — runtime сам форматирует (value_to_display_string).
		name = "встроку",
		arity = 1,
		handler = proc(ctx: ^Type_Ctx, call: Expr, args: [dynamic]Expr) -> ^Type {
			arg_type := prune_type(infer_expr(ctx, args[0]))
			if arg_type.kind == .Poison do return TY_STRING
			if (arg_type.kind == .Struct || arg_type.kind == .Enum) &&
			   implements_prelude_interface(ctx, arg_type, ctx.res.prelude_printable_sym) {
				method_sym, _ := method_lookup(ctx, arg_type, "вСтроку")
				ctx.call_infos[call] = Call_Info {
					kind       = .Print_Value,
					symbol_ref = method_sym,
					text_name  = "встроку",
				}
			} else {
				ctx.call_infos[call] = Call_Info{kind = .Builtin, text_name = "встроку"}
			}
			return TY_STRING
		},
	},
}

builtin_constructor_type :: proc(
	ctx: ^Type_Ctx,
	call: Expr,
	name: string,
	args: [dynamic]Expr,
) -> (
	^Type,
	bool,
) {
	for sig in BUILTIN_CTORS {
		if sig.name != name do continue
		if len(args) != sig.arity {
			return report(
				ctx,
				expr_span(call),
				"Type Error: %s() ожидает %d аргументов, получено %d",
				name,
				sig.arity,
				len(args),
			), true
		}
		return sig.handler(ctx, call, args), true
	}
	return nil, false
}

Method_Sig :: struct {
	name:    string,
	arity:   int,
	handler: proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type,
}

// Стадия 7 Phase F: Опция/Результат больше не Type_Kind — обычные generic-
// enum'ы прелюдии. Общее ядро инстанциации без ctx/кэша — переиспользуется
// и ctx-based instantiate_prelude_generic (typecheck-время), и stdlib.odin
// (резолв-время, до существования Type_Ctx, только graph под рукой).
// instantiate_type сам ctx не разыменовывает (см. его тело) — nil безопасен.
instantiate_generic_raw :: proc(template: ^Type, ordered: [dynamic]^Type, args: []^Type) -> ^Type {
	subst := make(map[int]^Type)
	for tv, i in ordered do subst[tv.infer_id] = args[i]
	return instantiate_type(nil, template, &subst)
}

// FILE_METHODS/CONNECTION_METHODS всё ещё строят Результат(...) напрямую из
// ^Type (не из AST-узла), поэтому нужен вход в тот же instantiate_type/
// generic_instance_cache путь, что resolve_type_node использует для
// Тип(args...) — иначе получим неканонический ^Type, который identity-only
// unify_types (.Enum) не сочтёт равным "настоящей" Результат(Строка,
// Ошибка), инстанцированной где-то ещё.
instantiate_prelude_generic :: proc(ctx: ^Type_Ctx, sym: Symbol_Id, args: []^Type) -> ^Type {
	instance := instantiate_generic_raw(ctx.res.symbol_types[sym], ctx.decl_type_param_order[sym], args)

	canon_args := make([dynamic]^Type)
	collect_instance_args(instance, &canon_args)
	key := generic_instance_key(sym, canon_args)
	if cached, found := ctx.generic_instance_cache[key]; found do return cached
	ctx.generic_instance_cache[key] = instance
	return instance
}

new_option_type :: proc(ctx: ^Type_Ctx, element_type: ^Type) -> ^Type {
	return instantiate_prelude_generic(ctx, ctx.res.prelude_option_sym, []^Type{element_type})
}

new_result_type :: proc(ctx: ^Type_Ctx, ok_type: ^Type, error_type: ^Type) -> ^Type {
	return instantiate_prelude_generic(ctx, ctx.res.prelude_result_sym, []^Type{ok_type, error_type})
}

FILE_METHODS := [?]Method_Sig {
	{
		name = "прочитать",
		arity = 0,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {
			return new_result_type(ctx, TY_STRING, TY_ERROR)
		},
	},
	{
		name = "прочитать_строку",
		arity = 0,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {
			return new_result_type(ctx, TY_STRING, TY_ERROR)
		},
	},
	{
		name = "записать",
		arity = 1,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {
			check_expr(ctx, args[0], TY_STRING)
			return new_result_type(ctx, TY_NUM, TY_ERROR)
		},
	},
	{
		name = "закрыть",
		arity = 0,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {return TY_VOID},
	},
}

CONNECTION_METHODS := [?]Method_Sig {
	{
		name = "получить",
		arity = 0,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {
			return new_result_type(ctx, TY_STRING, TY_ERROR)
		},
	},
	{
		name = "получить_строку",
		arity = 0,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {
			return new_result_type(ctx, TY_STRING, TY_ERROR)
		},
	},
	{
		name = "отправить",
		arity = 1,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {
			check_expr(ctx, args[0], TY_STRING)
			return new_result_type(ctx, TY_NUM, TY_ERROR)
		},
	},
	{
		name = "закрыть",
		arity = 0,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {return TY_VOID},
	},
}

// Диспетчер методов Опции/Результата/Файла/Соединения: одна карта вместо
// повторяющихся case'ов (arity-check + collection_calls-запись + return).
// Handler'ы хранят только уникальную логику.
standard_method_type :: proc(
	ctx: ^Type_Ctx,
	call: Expr,
	method_name: string,
	args: [dynamic]Expr,
	receiver_type: ^Type,
) -> (
	^Type,
	bool,
) {
	method_list: []Method_Sig
	#partial switch receiver_type.kind {
	case .File:
		method_list = FILE_METHODS[:]
	case .Connection:
		method_list = CONNECTION_METHODS[:]
	case:
		return nil, false
	}
	for sig in method_list {
		if sig.name != method_name do continue
		if len(args) != sig.arity {
			return report(
				ctx,
				expr_span(call),
				"Type Error: %s.%s() ожидает %d аргументов, получено %d",
				receiver_type.name,
				method_name,
				sig.arity,
				len(args),
			), true
		}
		result := sig.handler(ctx, call, receiver_type, args)
		ctx.call_infos[call] = Call_Info{kind = .Method_Collection, text_name = method_name}
		return result, true
	}
	return nil, false
}

// Единая точка построения значения Enum_Variant — покрывает как
// bare-идентификатор без скобок (`Нет`), так и вызов со скобками
// (`Круг(3)`). `is_call == false` требует нулевой arity, `is_call ==
// true` проверяет arity аргументов и унифицирует поля. Оба пути пишут в
// `ctx.call_infos` с kind = .Constructor_Variant.
resolve_variant_ctor :: proc(
	ctx: ^Type_Ctx,
	expr: Expr,
	sym_id: Symbol_Id,
	args: []Expr,
	is_call: bool,
) -> ^Type {
	sym := symbol_at(ctx.res.symbol_store, sym_id)
	owner := sym.owner_type
	if owner == INVALID_SYMBOL {
		fmt.panicf("Type Error: у варианта '%s' нет типа-владельца", resolve_interned(sym.name))
	}
	owner_type := ctx.res.symbol_types[owner]
	if owner_type == nil {
		fmt.panicf(
			"Type Error: тип-владелец '%s' варианта '%s' ещё не построен",
			resolve_interned(symbol_at(ctx.res.symbol_store, owner).name),
			resolve_interned(sym.name),
		)
	}

	// Стадия 7 Phase D: generic enum — свежая инстанциация (тот же
	// symbol_schemes-механизм, что structs/функции/лямбды). Канонизация
	// через generic_instance_cache — ниже, после unify аргументов (нужны
	// конкретные типы полей, а не свежие InferVar).
	is_generic_owner := false
	if scheme, has_scheme := ctx.symbol_schemes[owner]; has_scheme {
		owner_type = instantiate_scheme(ctx, scheme)
		is_generic_owner = true
	}

	tag, found := variant_index(owner_type, resolve_interned(sym.name))
	if !found {
		fmt.panicf(
			"Type Error: вариант '%s' не найден в '%s'",
			resolve_interned(sym.name),
			owner_type.name,
		)
	}

	if !is_call {
		if len(owner_type.variants[tag].fields) != 0 {
			return report(
				ctx,
				expr_span(expr),
				"Type Error: вариант '%s.%s' должен быть вызван со скобками — у него есть поля",
				owner_type.name,
				resolve_interned(sym.name),
			)
		}
		ctx.call_infos[expr] = Call_Info {
			kind    = .Constructor_Variant,
			variant = Variant_Call_Info{owner_type = owner_type, tag_index = tag},
		}
		return owner_type
	}

	expected := owner_type.variants[tag].fields
	if len(args) != len(expected) {
		return report(
			ctx,
			expr_span(expr),
			"Type Error: у варианта '%s.%s' ожидалось %d аргументов, получено %d",
			owner_type.name,
			resolve_interned(sym.name),
			len(expected),
			len(args),
		)
	}
	for arg, i in args {
		actual := prune_type(infer_expr(ctx, arg))
		actual = widen_num_literal_to_int(ctx, arg, actual, prune_type(expected[i]))
		field_type := prune_type(expected[i])
		// Стадия 45: поле-интерфейс варианта (напр. СобытиеСупервизора.
		// ДобавитьЗадачу(ДочерняяЗадача)) — тот же приём coercion'а, что
		// check_expr уже делает для обычных вызовов (~строка 3140 выше).
		// Без записи в interface_casts компилятор не обернёт struct/enum-
		// значение в Interface_Value (maybe_emit_interface_cast читает
		// именно эту карту) — рантайм получил бы "сырое" значение там, где
		// ожидается интерфейс, и падал бы на первом же вызове метода через
		// него ("попытка вызвать интерфейсный метод у не-интерфейса").
		// Не всплывало раньше — ни у одного варианта в кодовой базе до
		// этой стадии не было интерфейсного поля.
		if field_type.kind == .Interface && (actual.kind == .Struct || actual.kind == .Enum) {
			if unify_types(actual, field_type) {
				ctx.interface_casts[arg] = actual
				continue
			}
		}
		if !unify_types(actual, field_type) {
			report(
				ctx,
				expr_span(arg),
				"Type Error: у варианта '%s.%s' поле #%d ожидает '%s', получено '%s'",
				owner_type.name,
				resolve_interned(sym.name),
				i,
				field_type.name,
				prune_type(actual).name,
			)
		}
	}

	// Стадия 7 Phase D: канонизация — см. комментарий у generic_instance_cache.
	// Без неё два одинаковых Дерево.Лист(3) из разных мест кода получали
	// бы разные ^Type-объекты.
	if is_generic_owner {
		canon_args := make([dynamic]^Type)
		collect_instance_args(owner_type, &canon_args)
		key := generic_instance_key(owner, canon_args)
		if cached, found := ctx.generic_instance_cache[key]; found {
			owner_type = cached
		} else {
			ctx.generic_instance_cache[key] = owner_type
		}
	}

	ctx.call_infos[expr] = Call_Info {
		kind    = .Constructor_Variant,
		variant = Variant_Call_Info{owner_type = owner_type, tag_index = tag},
	}
	return owner_type
}

infer_ident_expr :: proc(ctx: ^Type_Ctx, expr: Expr, e: ^Ident_Expr) -> ^Type {
	sym_id := ctx.res.node_symbols[expr]
	if sym_id == INVALID_SYMBOL {
		// Резолвер уже отрапортовал (undefined variable) — не каскадируем.
		return TY_POISON
	}
	sym := symbol_at(ctx.res.symbol_store, sym_id)
	if sym.kind == .Module {
		return report(
			ctx,
			e.span,
			"Type Error: модуль '%s' нельзя использовать как значение",
			resolve_interned(sym.name),
		)
	}
	if sym.kind == .Enum_Variant {
		return resolve_variant_ctor(ctx, expr, sym_id, nil, false)
	}
	if sym.kind == .Builtin {
		return report(
			ctx,
			e.span,
			"Type Error: встроенный конструктор '%s' нужно вызвать через ()",
			resolve_interned(sym.name),
		)
	}
	var_type, ok := ctx.res.symbol_types[sym_id]
	if !ok do return report(ctx, e.span, "Type Error: символ '%s' используется до инициализации", resolve_interned(sym.name))

	// Стадия 7 Phase A: если символ хранит полиморфную схему (обобщённая
	// лямбда, см. Let_Stmt в infer_stmt), каждое использование получает
	// свежий инстанс — иначе все вызовы делили бы один и тот же InferVar
	// и первый же конкретный вызов "запирал" бы тип для всех остальных.
	if scheme, has_scheme := ctx.symbol_schemes[sym_id]; has_scheme && len(scheme.forall) > 0 {
		return instantiate_scheme(ctx, scheme)
	}

	return prune_type(var_type)
}

// Стадия 22: номинальная проверка "реализует ли t именно этот prelude-
// интерфейс" (указательное сравнение с implemented_interfaces) — НЕ просто
// "есть ли метод с подходящим именем". Типизация интерфейсов в panos
// номинальная, не структурная (см. docs/src/language/interfaces.md);
// случайно одноимённый несвязанный метод не должен включать sugar.
implements_prelude_interface :: proc(ctx: ^Type_Ctx, t: ^Type, iface_sym: Symbol_Id) -> bool {
	if t == nil || iface_sym == INVALID_SYMBOL do return false
	iface_type, ok := ctx.res.symbol_types[iface_sym]
	if !ok || iface_type == nil do return false
	for impl in t.implemented_interfaces {
		if impl == iface_type do return true
	}
	return false
}

// Bounded traits: примитивы (Число/Целое/Строка/Булево) НЕ регистрируют
// себя в implemented_interfaces (их `<`/`+`/`==` — нативный хардкод в
// infer_binary_expr, не impl-блок) — без этого fallback'а `T:
// Сравниваемое` отказал бы в вызове с T=Число, хотя `<` на числах и так
// работает. Равнозначное НЕ входит сюда — это opt-in override уже
// ВСЕГДА доступного структурного `==` (Стадия 22), а не отсутствующий
// дефолт, который нужно чем-то восполнить; "T: Равнозначное" остаётся
// строго "T реализует Равнозначное явно" — так же строго, как для
// конкретных структур/enum'ов без impl'а (см. type_satisfies_interface
// ниже, .Equal/.NotEqual в infer_binary_expr).
primitive_satisfies_interface :: proc(ctx: ^Type_Ctx, t: ^Type, iface_sym: Symbol_Id) -> bool {
	if t == nil || iface_sym == INVALID_SYMBOL do return false
	switch iface_sym {
	case ctx.res.prelude_comparable_sym:
		return t == TY_NUM || t == TY_INT || t == TY_STRING
	case ctx.res.prelude_addable_sym:
		return t == TY_NUM || t == TY_INT || t == TY_STRING
	case ctx.res.prelude_subtractable_sym, ctx.res.prelude_multipliable_sym, ctx.res.prelude_divisible_sym:
		return t == TY_NUM || t == TY_INT
	}
	return false
}

// Единая точка "удовлетворяет ли конкретный/decl-param тип этому
// bound'у" — используется и абстрактной проверкой тела bounded generic-
// функции (t.kind == .InferVar && is_decl_param — сверка с required_
// interfaces, см. make_decl_type_params), и обычной sugar-резолюцией
// операторов на конкретных типах (структуры/enum'ы через impl-блок,
// примитивы через primitive_satisfies_interface).
type_satisfies_interface :: proc(ctx: ^Type_Ctx, t: ^Type, iface_sym: Symbol_Id) -> bool {
	t := prune_type(t)
	if t.kind == .InferVar && t.is_decl_param {
		iface_type, ok := ctx.res.symbol_types[iface_sym]
		if !ok || iface_type == nil do return false
		for req in t.required_interfaces {
			if req == iface_type do return true
		}
		return false
	}
	if primitive_satisfies_interface(ctx, t, iface_sym) do return true
	return implements_prelude_interface(ctx, t, iface_sym)
}

// Стадия 23: left_t уже подтверждён implements_prelude_interface(iface_sym)
// — общий хвост для +/-/*// sugar: проверить, что right_t == left_t (та же
// схема, что Стадия 22's Сравниваемое — оба операнда одного Self-типа),
// записать Call_Info для compiler.odin, вернуть Self (НЕ Число — в отличие
// от сравнить, арифметические методы возвращают Self, напр. Вектор+Вектор).
infer_arithmetic_sugar :: proc(
	ctx: ^Type_Ctx,
	expr: Expr,
	span: Span,
	left_t: ^Type,
	right_t: ^Type,
	method_name: string,
	iface_name: string,
) -> ^Type {
	// Стадия 25: unify_types вместо !=, иначе нулевой-payload вариант
	// generic-enum'а (напр. Опция.Нет(), T не выводится из самого
	// значения) ложно репортился бы как "другой тип", хотя T должен
	// связаться с тем, что предоставляет other-операнд.
	if !unify_types(left_t, right_t) {
		return report(
			ctx,
			span,
			"Type Error: тип '%s' реализует %s, но не с типом '%s'",
			left_t.name,
			iface_name,
			right_t.name,
		)
	}
	method_sym, _ := method_lookup(ctx, left_t, method_name)
	ctx.call_infos[expr] = Call_Info{kind = .Method_Struct, symbol_ref = method_sym}
	return left_t
}

// Литерал сам по себе — всегда Число (infer_expr). Но рядом с УЖЕ
// Целое-типизированным операндом (переменная/параметр/поле, явно
// объявленные Целое — единственный способ получить Целое-значение в
// этом проходе) — литерал "сужается" до Целое, чтобы `x + 5` при
// `x: Целое` работало без явной аннотации на каждом литерале. НЕ
// коэрсия произвольного Число-значения — только у самого литерала нет
// закреплённого типа до этого момента. Дробный литерал рядом с Целое-
// операндом НЕ сужается (остаётся Число, естественно даёт type error
// ниже — 1.5 никогда не Целое).
widen_num_literal_to_int :: proc(ctx: ^Type_Ctx, expr: Expr, t: ^Type, other_t: ^Type) -> ^Type {
	if t == TY_NUM && other_t == TY_INT {
		if num, ok := expr.(^Number_Expr); ok && num.value == math.trunc(num.value) {
			ctx.node_types[expr] = TY_INT
			return TY_INT
		}
		if un, ok := expr.(^Unary_Expr); ok && un.op == .Minus {
			if num, ok := un.right.(^Number_Expr); ok && num.value == math.trunc(num.value) {
				ctx.node_types[un.right] = TY_INT
				ctx.node_types[expr] = TY_INT
				return TY_INT
			}
		}
	}
	return t
}

// Общее тело для Minus/Star (Slash — отдельно, разное деление у Число/
// Целое) — идентичны с точностью до интерфейса/имени метода (в отличие
// от Plus, не имеют спец-кейса Строка+Строка, так что тело короче и
// целиком переиспользуемо).
infer_arithmetic_op :: proc(
	ctx: ^Type_Ctx,
	expr: Expr,
	e: ^Binary_Expr,
	iface_sym: Symbol_Id,
	method_name: string,
	iface_name: string,
) -> ^Type {
	left_t := prune_type(infer_expr(ctx, e.left))
	right_t := prune_type(infer_expr(ctx, e.right))
	left_t = widen_num_literal_to_int(ctx, e.left, left_t, right_t)
	right_t = widen_num_literal_to_int(ctx, e.right, right_t, left_t)

	if left_t == TY_INT && right_t == TY_INT {
		return TY_INT
	}
	if left_t == TY_NUM && right_t == TY_NUM {
		return TY_NUM
	}
	if left_t.kind == .Poison || right_t.kind == .Poison {
		return TY_POISON
	}
	// Стадия 25: перечисления тоже могут реализовывать Арифметику.
	if (left_t.kind == .Struct || left_t.kind == .Enum ||
		   (left_t.kind == .InferVar && left_t.is_decl_param)) &&
	   type_satisfies_interface(ctx, left_t, iface_sym) {
		return infer_arithmetic_sugar(ctx, expr, e.span, left_t, right_t, method_name, iface_name)
	}
	check_expr(ctx, e.left, TY_NUM)
	check_expr(ctx, e.right, TY_NUM)
	return TY_NUM
}

infer_binary_expr :: proc(ctx: ^Type_Ctx, expr: Expr, e: ^Binary_Expr) -> ^Type {
	t: ^Type
	#partial switch e.op {
	case .Plus:
		left_t := prune_type(infer_expr(ctx, e.left))
		right_t := prune_type(infer_expr(ctx, e.right))

		if left_t.kind == .InferVar && right_t == TY_STRING {
			unify_types(left_t, TY_STRING)
		} else if right_t.kind == .InferVar && left_t == TY_STRING {
			unify_types(right_t, TY_STRING)
		} else if left_t.kind == .InferVar && right_t == TY_NUM {
			unify_types(left_t, TY_NUM)
		} else if right_t.kind == .InferVar && left_t == TY_NUM {
			unify_types(right_t, TY_NUM)
		}

		left_t = prune_type(left_t)
		right_t = prune_type(right_t)
		left_t = widen_num_literal_to_int(ctx, e.left, left_t, right_t)
		right_t = widen_num_literal_to_int(ctx, e.right, right_t, left_t)
		if left_t == TY_STRING && right_t == TY_STRING {
			t = TY_STRING
		} else if left_t == TY_INT && right_t == TY_INT {
			t = TY_INT
		} else if left_t == TY_NUM && right_t == TY_NUM {
			t = TY_NUM
		} else if left_t.kind == .Poison || right_t.kind == .Poison {
			// Прямое `==` сравнение выше не поймает Poison (не unify_types) —
			// без явного шорт-каута отчитались бы производной ошибкой поверх
			// уже отчитанной первопричины.
			t = TY_POISON
		} else if (left_t.kind == .Struct || left_t.kind == .Enum ||
			   (left_t.kind == .InferVar && left_t.is_decl_param)) &&
		   type_satisfies_interface(ctx, left_t, ctx.res.prelude_addable_sym) {
			t = infer_arithmetic_sugar(ctx, expr, e.span, left_t, right_t, "сложить", "Складываемое")
		} else {
			t = report(
				ctx,
				e.span,
				"Type Error: оператор '+' ожидает два числа или две строки, получено '%s' и '%s'",
				left_t.name,
				right_t.name,
			)
		}
	case .Minus:
		t = infer_arithmetic_op(ctx, expr, e, ctx.res.prelude_subtractable_sym, "вычесть", "Вычитаемое")
	case .Star:
		t = infer_arithmetic_op(ctx, expr, e, ctx.res.prelude_multipliable_sym, "умножить", "Умножаемое")
	case .Slash:
		// Отдельно от Minus/Star (не через infer_arithmetic_op) — деление
		// Целое/Целое отличается семантически (усечение к нулю, компилятор
		// эмитит .Int_Divide) от Число/Число (обычное деление, .Divide).
		left_t := prune_type(infer_expr(ctx, e.left))
		right_t := prune_type(infer_expr(ctx, e.right))
		left_t = widen_num_literal_to_int(ctx, e.left, left_t, right_t)
		right_t = widen_num_literal_to_int(ctx, e.right, right_t, left_t)
		if left_t == TY_INT && right_t == TY_INT {
			t = TY_INT
		} else if left_t == TY_NUM && right_t == TY_NUM {
			t = TY_NUM
		} else if left_t.kind == .Poison || right_t.kind == .Poison {
			t = TY_POISON
		} else if (left_t.kind == .Struct || left_t.kind == .Enum ||
			   (left_t.kind == .InferVar && left_t.is_decl_param)) &&
		   type_satisfies_interface(ctx, left_t, ctx.res.prelude_divisible_sym) {
			t = infer_arithmetic_sugar(ctx, expr, e.span, left_t, right_t, "разделить", "Делимое")
		} else {
			check_expr(ctx, e.left, TY_NUM)
			check_expr(ctx, e.right, TY_NUM)
			t = TY_NUM
		}

	case .Percent:
		// Остаток от целочисленного деления — только Целое в этом
		// проходе (мотивирующий кейс — счётчики/индексы; float-остаток,
		// как C-шный fmod, сознательно не реализован). Усечение к нулю,
		// знак результата следует делимому (тот же принцип, что .Int_Divide
		// в компиляторе — согласовано друг с другом).
		left_t := prune_type(infer_expr(ctx, e.left))
		right_t := prune_type(infer_expr(ctx, e.right))
		left_t = widen_num_literal_to_int(ctx, e.left, left_t, right_t)
		right_t = widen_num_literal_to_int(ctx, e.right, right_t, left_t)
		if left_t == TY_INT && right_t == TY_INT {
			t = TY_INT
		} else if left_t.kind == .Poison || right_t.kind == .Poison {
			t = TY_POISON
		} else {
			t = report(
				ctx,
				e.span,
				"Type Error: оператор '%%' поддержан только для Целое, получено '%s' и '%s'",
				left_t.name,
				right_t.name,
			)
		}

	case .Less, .Greater, .LessEqual, .GreaterEqual:
		left_t := prune_type(infer_expr(ctx, e.left))
		right_t := prune_type(infer_expr(ctx, e.right))
		left_t = widen_num_literal_to_int(ctx, e.left, left_t, right_t)
		right_t = widen_num_literal_to_int(ctx, e.right, right_t, left_t)

		if left_t == TY_INT && right_t == TY_INT {
			t = TY_BOOL
		} else if left_t == TY_NUM && right_t == TY_NUM {
			t = TY_BOOL
		} else if left_t.kind == .Poison || right_t.kind == .Poison {
			t = TY_POISON
		} else if (left_t.kind == .Struct || left_t.kind == .Enum ||
			   (left_t.kind == .InferVar && left_t.is_decl_param)) &&
		   type_satisfies_interface(ctx, left_t, ctx.res.prelude_comparable_sym) {
			if unify_types(left_t, right_t) {
				method_sym, _ := method_lookup(ctx, left_t, "сравнить")
				ctx.call_infos[expr] = Call_Info{kind = .Method_Struct, symbol_ref = method_sym}
				t = TY_BOOL
			} else {
				// Grilled: left_t реализует Сравниваемое, но не с ЭТИМ
				// операндом (другой тип или Число) — точное сообщение вместо
				// вводящего в заблуждение "ожидал Число" ниже.
				t = report(
					ctx,
					e.span,
					"Type Error: тип '%s' реализует Сравниваемое, но не с типом '%s'",
					left_t.name,
					right_t.name,
				)
			}
		} else {
			check_expr(ctx, e.left, TY_NUM)
			check_expr(ctx, e.right, TY_NUM)
			t = TY_BOOL
		}

	case .And, .Or:
		check_expr(ctx, e.left, TY_BOOL)
		check_expr(ctx, e.right, TY_BOOL)
		t = TY_BOOL

	case .Equal, .NotEqual:
		left_t := prune_type(infer_expr(ctx, e.left))
		right_t := prune_type(infer_expr(ctx, e.right))
		left_t = widen_num_literal_to_int(ctx, e.left, left_t, right_t)
		right_t = widen_num_literal_to_int(ctx, e.right, right_t, left_t)

		// Стадия 25: unify_types вместо == — та же причина, что у
		// infer_arithmetic_sugar (нулевой-payload вариант generic-enum'а
		// не выводит T из самого значения, должен связаться с other-
		// операндом). Порядок важен: kind/implements ПЕРЕД unify_types —
		// unify_types мутирует InferVar'ы побочным эффектом, не должен
		// срабатывать для типов, вообще не реализующих Равнозначное.
		if (left_t.kind == .Struct || left_t.kind == .Enum ||
			   (left_t.kind == .InferVar && left_t.is_decl_param)) &&
		   type_satisfies_interface(ctx, left_t, ctx.res.prelude_equatable_sym) &&
		   unify_types(left_t, right_t) {
			method_sym, _ := method_lookup(ctx, left_t, "равно")
			ctx.call_infos[expr] = Call_Info{kind = .Method_Struct, symbol_ref = method_sym}
			t = TY_BOOL
		} else {
			// Равнозначное — opt-in override (см. Стадия 22): без impl'а
			// падаем в прежний структурный путь (unify_types + value_equals
			// в рантайме), без diagnostic — это не обязаловка, как у Ord.
			if !unify_types(left_t, right_t) {
				report(
					ctx,
					e.span,
					"Type Error: оператор '==' ожидает совместимые типы, получено '%s' и '%s'",
					prune_type(left_t).name,
					prune_type(right_t).name,
				)
			}
			t = TY_BOOL
		}

	case .Assign:
		// Стадия 27: конст-биндинг — запрещает переприсвоение самого
		// имени. Только Ident_Expr (сам биндинг) — Property_Expr/
		// Index_Expr (поля/элементы через `.`/`[]`) не входят: конст —
		// binding-immutability, не deep immutability (у panos структур
		// reference semantics, конст не защищает то, на что ссылается).
		if ident, is_ident := e.left.(^Ident_Expr); is_ident {
			if sym_id := ctx.res.node_symbols[ident];
			   sym_id != INVALID_SYMBOL && symbol_at(ctx.res.symbol_store, sym_id).is_const {
				report(
					ctx,
					e.span,
					"Type Error: попытка переприсвоить константу '%s'",
					resolve_interned(ident.name),
				)
			}
			// Стадия 48 (замыкания): захваченная переменная — снапшот на
			// момент создания лямбды, не общая ячейка с внешней функцией.
			// Присваивание ей внутри лямбды не сделало бы ничего
			// осмысленного снаружи (тихий no-op) — явная ошибка вместо
			// молчаливого сюрприза. Достаточно проверить ТОЛЬКО вершину
			// current_lambda_stack — см. комментарий у поля.
			if len(ctx.current_lambda_stack) > 0 {
				current_lambda := ctx.current_lambda_stack[len(ctx.current_lambda_stack) - 1]
				if sym_id := ctx.res.node_symbols[ident]; sym_id != INVALID_SYMBOL {
					for captured_sym in ctx.res.lambda_captures[current_lambda] {
						if captured_sym == sym_id {
							report(
								ctx,
								e.span,
								"Type Error: захваченная переменная '%s' неизменяема внутри лямбды",
								resolve_interned(ident.name),
							)
							break
						}
					}
				}
			}
		}
		left_t := infer_expr(ctx, e.left)
		check_expr(ctx, e.right, left_t)
		right_t := infer_expr(ctx, e.right)
		if !unify_types(right_t, left_t) {
			report(
				ctx,
				e.span,
				"Type Error: попытка присвоить значение типа '%s' в место типа '%s'",
				prune_type(right_t).name,
				prune_type(left_t).name,
			)
		}
		t = TY_VOID
	case:
		t = report(ctx, e.span, "Type Error: неподдерживаемый оператор %v", e.op)
	}
	return t
}

infer_unary_expr :: proc(ctx: ^Type_Ctx, expr: Expr, e: ^Unary_Expr) -> ^Type {
	t: ^Type
	#partial switch e.op {
	case .Minus:
		operand_t := prune_type(infer_expr(ctx, e.right))
		if operand_t == TY_INT {
			t = TY_INT
		} else {
			check_expr(ctx, e.right, TY_NUM)
			t = TY_NUM
		}
	case .Negate:
		check_expr(ctx, e.right, TY_BOOL)
		t = TY_BOOL
	}
	return t
}

// Стадия 7 Phase F: ищет метод через ВЛАДЕЮЩИЙ ШАБЛОН (ctx.res.symbol_
// types[obj_type.generic_origin].methods), а не через obj_type.methods
// напрямую. instantiate_type копирует .methods присваиванием (t2.methods =
// pruned.methods) — Odin-карты обычно алиасятся по ссылке, НО если .methods
// СКОПИРОВАНА ДО того, как в неё что-то добавили (карта ещё пустая,
// backing-массив не выделен), последующие вставки в ОРИГИНАЛ через ДРУГУЮ
// переменную не видны через более раннюю копию — тот же класс бага, что и
// graph.symbol_types (см. resolve_module). Живой баг: результат_или[E]
// (Опция) резолвит "Результат(T, E)" ДО того, как ПРОХОД 3 дошёл до
// "реализация Результат" (порядок деклараций в prelude.ps — Опция раньше
// Результата) — инстанцированный Результат из результат_или получал
// пустую .methods, "р.ошибка()" падал с "попытка получить поле у
// не-структуры". Чтение напрямую из ВСЕГДА-АКТУАЛЬНОГО шаблона (единственный
// объект, в который ПРОХОД 3 реально пишет) устраняет класс проблемы целиком.
method_lookup :: proc(ctx: ^Type_Ctx, obj_type: ^Type, name: string) -> (Symbol_Id, bool) {
	if obj_type.generic_origin != INVALID_SYMBOL {
		if owner_type, ok := ctx.res.symbol_types[obj_type.generic_origin]; ok && owner_type != nil {
			sym, found := owner_type.methods[name]
			return sym, found
		}
	}
	sym, found := obj_type.methods[name]
	return sym, found
}

// Стадия 24 (actor model): `запусти <вызов>` — НЕ выполняет callee,
// порождает процесс. Требуем bare-имя функции (не метод/лямбда-выражение —
// v1 сознательно ограничен, см. ROADMAP) — иначе не от кого взять
// process_message_types. Аргументы типизируются КАК у обычного вызова
// (арность + позиционная проверка), само тело f типизируется НЕМЕДЛЕННО
// через ensure_body_checked, если ещё не было (см. её комментарий) — так
// T процесса известен независимо от того, объявлена ли f раньше или позже
// текущей функции по файлу.
infer_spawn_expr :: proc(ctx: ^Type_Ctx, expr: Expr, e: ^Spawn_Expr) -> ^Type {
	call := e.call

	#partial switch callee in call.callee {
	case ^Ident_Expr:
		return infer_spawn_local_call(ctx, call, callee)
	case ^Property_Expr:
		return infer_spawn_qualified_call(ctx, call, callee)
	case:
		return report(ctx, call.span, "Type Error: 'запусти' ожидает вызов функции по имени")
	}
}

// `запусти f(...)` — f объявлена в ТОМ ЖЕ файле. Выделено из infer_spawn_
// expr при добавлении Стадии 45 (запусти Модуль.функция(...)) — раньше
// было единственным путём.
infer_spawn_local_call :: proc(ctx: ^Type_Ctx, call: ^Call_Expr, ident: ^Ident_Expr) -> ^Type {
	callee_sym := ctx.res.node_symbols[call.callee]
	if callee_sym == INVALID_SYMBOL {
		return TY_POISON // резолвер уже отрапортовал undefined-переменную
	}
	if symbol_at(ctx.res.symbol_store, callee_sym).kind != .Function {
		return report(
			ctx,
			call.span,
			"Type Error: 'запусти' ожидает вызов функции, '%s' — не функция",
			resolve_interned(ident.name),
		)
	}

	func_type := prune_type(ctx.res.symbol_types[callee_sym])
	if func_type == nil || func_type.kind != .Function {
		return report(ctx, call.span, "Type Error: '%s' — не функция", resolve_interned(ident.name))
	}
	if len(call.args) != len(func_type.params) {
		return report(
			ctx,
			call.span,
			"Type Error: функция '%s' ожидает %d аргументов, получено %d",
			resolve_interned(ident.name),
			len(func_type.params),
			len(call.args),
		)
	}
	for i in 0 ..< len(call.args) {
		check_expr(ctx, call.args[i], func_type.params[i])
	}

	ensure_body_checked(ctx, callee_sym)
	msg_type, has_msg := ctx.process_message_types[callee_sym]
	if !has_msg {
		// f никогда не вызывает получить() — валидный "fire and forget"
		// процесс. T ничем не ограничен, свежий InferVar (как у пустой
		// Опция.Нет() без контекста).
		msg_type = new_infer_var(ctx)
	}
	return new_process_type(msg_type)
}

// Стадия 45: `запусти Модуль.функция(...)` — резолв модуля/экспорта тот
// же паттерн, что infer_call_expr's Property_Expr-ветка (~строка 4339
// выше), но БЕЗ ensure_body_checked: экспортирующий модуль уже ПОЛНОСТЬЮ
// протипизирован раньше по топологическому порядку графа
// (resolve_and_typecheck_all, module_loader.odin) — его process_message_
// types уже скопирован в Module_Graph и оттуда в ctx (new_type_ctx), так
// что читаем напрямую. Не поддерживает Печатаемое-сахар и generic-схемы
// (module.экспорт) — `запусти` не спавнит builtin'ы и generic-функции
// сюда не подходят по смыслу (T процесса — не generic-параметр функции).
infer_spawn_qualified_call :: proc(ctx: ^Type_Ctx, call: ^Call_Expr, prop_expr: ^Property_Expr) -> ^Type {
	obj_ident, ok := prop_expr.object.(^Ident_Expr)
	if !ok {
		return report(ctx, call.span, "Type Error: 'запусти' ожидает вызов функции по имени")
	}
	obj_sym := ctx.res.node_symbols[prop_expr.object]
	if obj_sym == INVALID_SYMBOL || symbol_at(ctx.res.symbol_store, obj_sym).kind != .Module {
		return report(ctx, call.span, "Type Error: 'запусти' ожидает вызов функции по имени")
	}
	imported_module := symbol_at(ctx.res.symbol_store, obj_sym).module
	if imported_module == nil {
		return report(ctx, call.span, "Type Error: модуль '%s' не загружен", resolve_interned(obj_ident.name))
	}
	export_sym_id, found := imported_module.exports[intern(prop_expr.property)]
	if !found {
		return report(
			ctx,
			call.span,
			"Type Error: модуль '%s' не экспортирует '%s'",
			resolve_interned(obj_ident.name),
			prop_expr.property,
		)
	}
	export_sym := symbol_at(ctx.res.symbol_store, export_sym_id)
	if export_sym.kind != .Function {
		return report(
			ctx,
			call.span,
			"Type Error: 'запусти' ожидает вызов функции, '%s.%s' — не функция",
			resolve_interned(obj_ident.name),
			prop_expr.property,
		)
	}

	export_type, found_type := ctx.res.symbol_types[export_sym_id]
	if !found_type || export_type == nil {
		if fn_decl, has_fn_decl := export_sym.decl.(^Function_Decl); has_fn_decl {
			export_type = function_type_from_decl(ctx, fn_decl)
		}
	}
	func_type := prune_type(export_type)
	if func_type == nil || func_type.kind != .Function {
		return report(
			ctx,
			call.span,
			"Type Error: '%s.%s' — не функция",
			resolve_interned(obj_ident.name),
			prop_expr.property,
		)
	}
	if len(call.args) != len(func_type.params) {
		return report(
			ctx,
			call.span,
			"Type Error: функция '%s.%s' ожидает %d аргументов, получено %d",
			resolve_interned(obj_ident.name),
			prop_expr.property,
			len(func_type.params),
			len(call.args),
		)
	}
	for i in 0 ..< len(call.args) {
		check_expr(ctx, call.args[i], func_type.params[i])
	}

	msg_type, has_msg := ctx.process_message_types[export_sym_id]
	if !has_msg {
		msg_type = new_infer_var(ctx)
	}
	return new_process_type(msg_type)
}

// Имена параметров функции/метода в порядке объявления — для
// resolve_named_call_args. Отдельно от Struct_Field.name (структуры)
// т.к. Param_Decl — другой тип узла.
param_decl_names :: proc(args: [dynamic]Param_Decl) -> []string {
	names := make([]string, len(args))
	for arg, i in args do names[i] = arg.name
	return names
}

// Имена полей структуры в порядке объявления — для resolve_named_
// call_args на конструкторах (`Точка(x = 1, y = 2)`).
struct_field_names :: proc(struct_type: ^Type) -> []string {
	names := make([]string, len(struct_type.fields))
	for f, i in struct_type.fields do names[i] = f.name
	return names
}

// param_decl_names БЕЗ receiver'а (m.args[0], всегда "это" — методы
// объявляют получателя явным первым параметром, см. реализация-блоки).
// method_type.params[0] — тот же receiver позиционно, поэтому здесь
// пропускается симметрично.
method_param_names :: proc(m: ^Function_Decl) -> []string {
	if len(m.args) == 0 do return []string{}
	return param_decl_names(m.args)[1:]
}

// Именованные аргументы (`f(x = 1, y = 2)`) — если вызов использовал
// именованную форму (Call_Expr.arg_names непусто), переставляет e.args
// в порядок param_names ПРЯМО В AST. После этого КАЖДЫЙ из ~8 путей
// разрешения вызова ниже (обычная функция, метод структуры/enum'а/
// интерфейса, конструктор структуры, bounded generic, cross-module
// разновидности всех этих) продолжает работать НЕИЗМЕНЁННО — они все
// уже делают `for arg, i in e.args do check_expr(ctx, arg, params[i])`,
// который просто не видит разницы между "аргументы пришли позиционно"
// и "аргументы пришли именованно, но уже переставлены сюда". Только
// "всё именовано" или "всё позиционно" — parser это уже гарантировал
// (см. parse_expr's LParen-кейс), здесь только сверяем имена/арность.
resolve_named_call_args :: proc(ctx: ^Type_Ctx, e: ^Call_Expr, param_names: []string) -> bool {
	if len(e.arg_names) == 0 do return true
	if len(e.arg_names) != len(param_names) {
		report(
			ctx,
			e.span,
			"Type Error: ожидалось %d именованных аргументов, получено %d",
			len(param_names),
			len(e.arg_names),
		)
		return false
	}
	reordered := make([dynamic]Expr, len(param_names))
	matched := make([dynamic]bool, len(param_names), context.temp_allocator)
	ok := true
	for arg_name, i in e.arg_names {
		idx := -1
		for pname, pi in param_names {
			if pname == arg_name {
				idx = pi
				break
			}
		}
		if idx == -1 {
			report(ctx, e.span, "Type Error: неизвестный именованный аргумент '%s'", arg_name)
			ok = false
			continue
		}
		if matched[idx] {
			report(ctx, e.span, "Type Error: именованный аргумент '%s' указан повторно", arg_name)
			ok = false
			continue
		}
		matched[idx] = true
		reordered[idx] = e.args[i]
	}
	if !ok do return false
	e.args = reordered
	return true
}

// Bounded traits: вызов `f(...)` где f — generic-функция хотя бы с одним
// bound'ом (`f.type_param_bounds` непусто). Отдельная от общего пути
// (infer_call_expr's `callee_type.kind == .Function` ветка ниже) ветка —
// нужна собственная instantiate_scheme_with_subst (обычный instantiate_
// scheme не отдаёт subst-карту, а без неё не восстановить, какой свежий
// InferVar соответствует какому ИМЕНОВАННОМУ type-параметру после
// унификации аргументов). Пишет ctx.generic_call_instantiations[expr] —
// читает core/monomorphize.odin (какие инстанциации нужно скомпилировать)
// и core/compiler.odin (ключ инстанциации на call site вместо обычного
// symbol_registry_key).
infer_bounded_generic_call :: proc(
	ctx: ^Type_Ctx,
	expr: Expr,
	e: ^Call_Expr,
	callee_sym: Symbol_Id,
	fn_decl: ^Function_Decl,
) -> ^Type {
	scheme, has_scheme := ctx.symbol_schemes[callee_sym]
	if !has_scheme {
		return report(
			ctx,
			e.span,
			"Type Error: не удалось инстанцировать generic-функцию '%s'",
			fn_decl.name,
		)
	}
	subst := make(map[int]^Type)
	instantiated := instantiate_scheme_with_subst(ctx, scheme, &subst)
	if !resolve_named_call_args(ctx, e, param_decl_names(fn_decl.args)) {
		return TY_POISON
	}
	if len(e.args) != len(instantiated.params) {
		return report(ctx, e.span, "Type Error: неверное количество аргументов")
	}
	for arg, i in e.args do check_expr(ctx, arg, instantiated.params[i])

	template_params := ctx.decl_type_params[callee_sym]
	concrete_types := make([dynamic]^Type)
	for name in fn_decl.type_params {
		template_var := template_params[name]
		fresh_var, found := subst[template_var.infer_id]
		if !found {
			if ctx.in_abstract_generic_body do return prune_type(instantiated.return_type)
			return report(
				ctx,
				e.span,
				"Type Error: тип-параметр '%s' функции '%s' не выводится из аргументов",
				name,
				fn_decl.name,
			)
		}
		concrete := prune_type(fresh_var)
		if concrete.kind == .InferVar {
			// Абстрактный проход (рекурсия/вложенный generic-вызов внутри
			// ЕЩЁ НЕ-конкретного тела, см. ctx.in_abstract_generic_body) —
			// ожидаемо, не diagnostic. Инстанциацию не пишем (нечего писать
			// без конкретного типа) — реальные конкретные вызовы этой же
			// функции извне (или клон САМОЙ f, если f рекурсивна) закроют
			// это через свои собственные infer_bounded_generic_call.
			if ctx.in_abstract_generic_body do return prune_type(instantiated.return_type)
			return report(
				ctx,
				e.span,
				"Type Error: не удалось вывести конкретный тип для '%s' функции '%s'",
				name,
				fn_decl.name,
			)
		}
		if bound_names, has_bounds := fn_decl.type_param_bounds[name]; has_bounds {
			for iface_name in bound_names {
				iface_sym := lookup_symbol(ctx.res.global_scope, intern(iface_name))
				if !type_satisfies_interface(ctx, concrete, iface_sym) {
					report(
						ctx,
						e.span,
						"Type Error: тип '%s' не реализует '%s', требуется для type-параметра '%s' функции '%s'",
						concrete.name,
						iface_name,
						name,
						fn_decl.name,
					)
				}
			}
		}
		append(&concrete_types, concrete)
	}
	ctx.generic_call_instantiations[expr] = concrete_types
	return prune_type(instantiated.return_type)
}

infer_call_expr :: proc(ctx: ^Type_Ctx, expr: Expr, e: ^Call_Expr) -> ^Type {
	callee_sym := ctx.res.node_symbols[e.callee]
	if callee_sym != INVALID_SYMBOL && symbol_at(ctx.res.symbol_store, callee_sym).kind == .Enum_Variant {
		return resolve_variant_ctor(ctx, expr, callee_sym, e.args[:], true)
	}
	if callee_sym != INVALID_SYMBOL && symbol_at(ctx.res.symbol_store, callee_sym).kind == .Function {
		if fn_decl, has_decl := ctx.symbol_to_func_decl[callee_sym];
		   has_decl && len(fn_decl.type_param_bounds) > 0 {
			return infer_bounded_generic_call(ctx, expr, e, callee_sym, fn_decl)
		}
	}
	if ident, ok := e.callee.(^Ident_Expr); ok {
		if sym := ctx.res.node_symbols[e.callee];
		   sym != INVALID_SYMBOL && symbol_at(ctx.res.symbol_store, sym).kind == .Builtin {
			if builtin_type, handled := builtin_constructor_type(ctx, expr, resolve_interned(ident.name), e.args);
			   handled {
				return builtin_type
			}
		}
	}

	t: ^Type
	#partial switch prop_expr in e.callee {
	case ^Property_Expr:
		if obj_ident, ok := prop_expr.object.(^Ident_Expr); ok {
			if obj_sym := ctx.res.node_symbols[prop_expr.object];
			   obj_sym != INVALID_SYMBOL && symbol_at(ctx.res.symbol_store, obj_sym).kind == .Module {
				imported_module := symbol_at(ctx.res.symbol_store, obj_sym).module
				if imported_module == nil {
					return report(
						ctx,
						e.span,
						"Type Error: модуль '%s' не загружен",
						resolve_interned(obj_ident.name),
					)
				}
				export_sym_id, found := imported_module.exports[intern(prop_expr.property)]
				if !found {
					return report(
						ctx,
						e.span,
						"Type Error: модуль '%s' не экспортирует '%s'",
						resolve_interned(obj_ident.name),
						prop_expr.property,
					)
				}
				export_sym := symbol_at(ctx.res.symbol_store, export_sym_id)

				// Стадия 23 (Печатаемое): ввод_вывод::печать/строка обходят
				// обычную unификацию параметров ниже (жёстко TY_STRING через
				// builtin_export_type) — принимают ЛЮБОЙ Value. Аргумент
				// типизируется без коэрсии; если это struct с реализация
				// Печатаемое — компилятор вызовет .вСтроку() ПЕРЕД реальным
				// builtin'ом (Print_Value), иначе runtime сам форматирует
				// (Число/Строка/Булево нативно, остальное — structural dump,
				// см. value_to_display_string в vm.odin — тот же принцип, что
				// Равнозначное: интерфейс — opt-in override дефолтного пути).
				if export_sym.kind == .Builtin &&
				   (resolve_interned(export_sym.full_name) == "ввод_вывод::печать" ||
						   resolve_interned(export_sym.full_name) == "ввод_вывод::строка") {
					if len(e.args) != 1 {
						return report(ctx, e.span, "Type Error: неверное количество аргументов")
					}
					full_name := resolve_interned(export_sym.full_name)
					arg_type := prune_type(infer_expr(ctx, e.args[0]))
					// Стадия 25: перечисления тоже могут реализовывать Печатаемое.
					if (arg_type.kind == .Struct || arg_type.kind == .Enum) &&
					   implements_prelude_interface(ctx, arg_type, ctx.res.prelude_printable_sym) {
						method_sym, _ := method_lookup(ctx, arg_type, "вСтроку")
						ctx.call_infos[expr] = Call_Info {
							kind       = .Print_Value,
							symbol_ref = method_sym,
							text_name  = full_name,
						}
					} else {
						ctx.call_infos[expr] = Call_Info{kind = .Builtin, text_name = full_name}
					}
					return TY_VOID
				}

				export_type, found_type := ctx.res.symbol_types[export_sym_id]
				if !found_type || export_type == nil {
					if export_sym.kind == .Builtin {
						export_type = builtin_export_type(ctx.res.module_graph, resolve_interned(export_sym.full_name))
						if export_type != nil {
							ctx.res.symbol_types[export_sym_id] = export_type
						}
					} else if fn_decl, has_fn_decl := export_sym.decl.(^Function_Decl);
					   has_fn_decl {
						export_type = function_type_from_decl(ctx, fn_decl)
					}
					if export_type == nil {
						return report(
							ctx,
							e.span,
							"Type Error: символ '%s.%s' еще не типизирован",
							resolve_interned(obj_ident.name),
							prop_expr.property,
						)
					}
				}
				export_type = prune_type(export_type)
				// Найдено при отладке Стадии 22 (не её баг): cross-module вызов
				// generic-функции (алиас.функция(...)) без этого использовал бы
				// ОБЩИЙ, не-инстанцированный тип — первый же вызов "цементировал"
				// бы T навсегда для ВСЕХ последующих вызовов (см. пометку у
				// Module_Graph.symbol_schemes). Тот же instantiate_scheme, что
				// infer_ident_expr уже делает для same-file вызовов.
				if scheme, has_scheme := ctx.symbol_schemes[export_sym_id]; has_scheme && len(scheme.forall) > 0 {
					export_type = prune_type(instantiate_scheme(ctx, scheme))
				}
				#partial switch export_type.kind {
				case .Function:
					if len(e.arg_names) > 0 {
						fn_decl, has_fn_decl := export_sym.decl.(^Function_Decl)
						if !has_fn_decl {
							return report(
								ctx,
								e.span,
								"Type Error: именованные аргументы не поддержаны для этого вызова",
							)
						}
						if !resolve_named_call_args(ctx, e, param_decl_names(fn_decl.args)) {
							return TY_POISON
						}
					}
					if len(e.args) != len(export_type.params) {
						return report(
							ctx,
							e.span,
							"Type Error: неверное количество аргументов",
						)
					}
					for arg, i in e.args do check_expr(ctx, arg, export_type.params[i])
					if export_sym.kind == .Builtin {
						ctx.call_infos[expr] = Call_Info {
							kind      = .Builtin,
							text_name = resolve_interned(export_sym.full_name),
						}
					}
					return prune_type(export_type.return_type)

				case .Struct:
					if !resolve_named_call_args(ctx, e, struct_field_names(export_type)) {
						return TY_POISON
					}
					if len(e.args) != len(export_type.fields) {
						return report(
							ctx,
							e.span,
							"Type Error: структура '%s' имеет %d полей",
							export_type.name,
							len(export_type.fields),
						)
					}
					for arg, i in e.args do check_expr(ctx, arg, export_type.fields[i].type)
					ctx.call_infos[expr] = Call_Info{kind = .Constructor_Struct}
					return export_type

				case:
					return report(
						ctx,
						e.span,
						"Type Error: символ '%s.%s' нельзя вызвать",
						resolve_interned(obj_ident.name),
						prop_expr.property,
					)
				}
			}
		}

		obj_type := prune_type(infer_expr(ctx, prop_expr.object))

		// Стадия 7 Phase F: приёмник метода мог оказаться СЫРЫМ (не
		// инстанцированным) generic-шаблоном напрямую — например "это"
		// внутри тела метода generic-типа (Результат/Опция/пользовательский
		// generic), чьё объявленное "это: Тип" резолвится в ТОТ ЖЕ
		// разделяемый ^Type, что ctx.res.symbol_types[owner] (см. ПРОХОД 3,
		// "это: Коробка резолвится в сам шаблонный ^Type"). Если ЭТОТ метод
		// внутри своего тела вызывает ДРУГОЙ метод на это (это.успех()
		// внутри "ошибка") — unify_types(obj_type, свежий_экземпляр_
		// вызываемого_метода) связал бы СОБСТВЕННЫЕ T/E шаблона напрямую,
		// навсегда цементируя их для ВСЕЙ остальной программы (шаблон один
		// на граф, см. Module_Graph.symbol_types). Живой баг: подтверждён
		// живым тестом (Результат.ожидать возвращал нерезолвленный InferVar
		// после Результат.ошибка() вызвала это.успех() где-то раньше).
		// Свежая инстанциация здесь защищает шаблон, не меняя семантику
		// самого вызова.
		if obj_type.generic_origin != INVALID_SYMBOL &&
		   obj_type == ctx.res.symbol_types[obj_type.generic_origin] {
			if scheme, has_scheme := ctx.symbol_schemes[obj_type.generic_origin]; has_scheme {
				obj_type = instantiate_scheme(ctx, scheme)
			}
		}

		if method_type, handled := standard_method_type(
			ctx,
			expr,
			prop_expr.property,
			e.args,
			obj_type,
		); handled {
			return method_type
		}

		if obj_type.kind == .Array {
			switch prop_expr.property {
			case "длина":
				if len(e.args) != 0 do return report(ctx, e.span, "Type Error: массив.длина() не принимает аргументы")
				ctx.call_infos[expr] = Call_Info{kind = .Method_Collection, text_name = prop_expr.property}
				return TY_INT
			case "добавить":
				if len(e.args) != 1 do return report(ctx, e.span, "Type Error: массив.добавить() ожидает 1 аргумент")
				check_expr(ctx, e.args[0], obj_type.element_type)
				ctx.call_infos[expr] = Call_Info{kind = .Method_Collection, text_name = prop_expr.property}
				return TY_VOID
			case "получить":
				if len(e.args) != 2 do return report(ctx, e.span, "Type Error: массив.получить() ожидает индекс и значение по умолчанию")
				check_expr(ctx, e.args[0], TY_INT)
				check_expr(ctx, e.args[1], obj_type.element_type)
				ctx.call_infos[expr] = Call_Info{kind = .Method_Collection, text_name = prop_expr.property}
				return obj_type.element_type
			case "есть":
				if len(e.args) != 1 do return report(ctx, e.span, "Type Error: массив.есть() ожидает индекс")
				check_expr(ctx, e.args[0], TY_INT)
				ctx.call_infos[expr] = Call_Info{kind = .Method_Collection, text_name = prop_expr.property}
				return TY_BOOL
			case "содержит":
				if len(e.args) != 1 do return report(ctx, e.span, "Type Error: массив.содержит() ожидает значение")
				check_expr(ctx, e.args[0], obj_type.element_type)
				ctx.call_infos[expr] = Call_Info{kind = .Method_Collection, text_name = prop_expr.property}
				return TY_BOOL
			case:
				return report(
					ctx,
					e.span,
					"Type Error: у массива нет метода '%s'",
					prop_expr.property,
				)
			}

		} else if obj_type.kind == .Map {
			switch prop_expr.property {
			case "длина":
				if len(e.args) != 0 do return report(ctx, e.span, "Type Error: соответствие.длина() не принимает аргументы")
				ctx.call_infos[expr] = Call_Info{kind = .Method_Collection, text_name = prop_expr.property}
				return TY_INT
			case "есть":
				if len(e.args) != 1 do return report(ctx, e.span, "Type Error: соответствие.есть() ожидает ключ")
				check_expr(ctx, e.args[0], obj_type.key_type)
				ctx.call_infos[expr] = Call_Info{kind = .Method_Collection, text_name = prop_expr.property}
				return TY_BOOL
			case "получить":
				if len(e.args) != 2 do return report(ctx, e.span, "Type Error: соответствие.получить() ожидает ключ и значение по умолчанию")
				check_expr(ctx, e.args[0], obj_type.key_type)
				check_expr(ctx, e.args[1], obj_type.value_type)
				ctx.call_infos[expr] = Call_Info{kind = .Method_Collection, text_name = prop_expr.property}
				return obj_type.value_type
			case "удалить":
				if len(e.args) != 1 do return report(ctx, e.span, "Type Error: соответствие.удалить() ожидает ключ")
				check_expr(ctx, e.args[0], obj_type.key_type)
				ctx.call_infos[expr] = Call_Info{kind = .Method_Collection, text_name = prop_expr.property}
				return TY_BOOL
			case "записи":
				// В языке нет for-in — единственный способ обойти
				// произвольное Соответствие: получить Массив((Ключ,
				// Значение)) и пройтись по нему индексом через `пока`.
				if len(e.args) != 0 do return report(ctx, e.span, "Type Error: соответствие.записи() не принимает аргументы")
				ctx.call_infos[expr] = Call_Info{kind = .Method_Collection, text_name = prop_expr.property}
				entry_fields := make([dynamic]^Type)
				append(&entry_fields, obj_type.key_type)
				append(&entry_fields, obj_type.value_type)
				return new_array_type(new_tuple_type(entry_fields))
			case:
				return report(
					ctx,
					e.span,
					"Type Error: у соответствия нет метода '%s'",
					prop_expr.property,
				)
			}

		} else if obj_type.kind == .Struct {
			if method_sym, is_method := method_lookup(ctx, obj_type, prop_expr.property); is_method {
				method_type := ctx.res.symbol_types[method_sym]
				if scheme, has_scheme := ctx.symbol_schemes[method_sym]; has_scheme {
					// Стадия 7 Phase E: свежая инстанциация на КАЖДЫЙ
					// вызов — та же защита от "зацементированного" T,
					// что Phase A/B/C/D уже дают лямбдам/функциям/
					// конструкторам.
					method_type = instantiate_scheme(ctx, scheme)
				}
				if len(e.arg_names) > 0 {
					m_decl, has_m_decl := ctx.symbol_to_func_decl[method_sym]
					if !has_m_decl || !resolve_named_call_args(ctx, e, method_param_names(m_decl)) {
						return TY_POISON
					}
				}
				if len(e.args) != len(method_type.params) - 1 {
					return report(
						ctx,
						e.span,
						"У метода %s ожидалось %d аргументов",
						resolve_interned(symbol_at(ctx.res.symbol_store, method_sym).name),
						len(method_type.params) - 1,
					)
				}
				// Стадия 7 Phase F: НЕ check_expr(ctx, prop_expr.object, ...)
				// — тот заново вызвал бы infer_expr на prop_expr.object,
				// теряя защиту "свежая инстанциация вместо сырого шаблона"
				// выше (obj_type уже содержит нужный, возможно
				// переинстанцированный, тип получателя).
				if !unify_types(obj_type, method_type.params[0]) {
					report(
						ctx,
						expr_span(prop_expr.object),
						"Type Error: ожидался '%s', получен '%s'",
						prune_type(method_type.params[0]).name,
						obj_type.name,
					)
				}
				for arg, i in e.args do check_expr(ctx, arg, method_type.params[i + 1])

				ctx.call_infos[expr] = Call_Info{kind = .Method_Struct, symbol_ref = method_sym}
				return prune_type(method_type.return_type)
			}
		} else if obj_type.kind == .Enum {
			// Тот же путь диспетчеризации, что у Struct (.Method_Struct —
			// имя историческое, кодогенерация в compiler.odin трактует его
			// как "обычный вызов функции с receiver'ом первым аргументом",
			// получателю всё равно, Aggregate_Value это или Variant_Value).
			if method_sym, is_method := method_lookup(ctx, obj_type, prop_expr.property); is_method {
				method_type := ctx.res.symbol_types[method_sym]
				if scheme, has_scheme := ctx.symbol_schemes[method_sym]; has_scheme {
					method_type = instantiate_scheme(ctx, scheme)
				}
				if len(e.arg_names) > 0 {
					m_decl, has_m_decl := ctx.symbol_to_func_decl[method_sym]
					if !has_m_decl || !resolve_named_call_args(ctx, e, method_param_names(m_decl)) {
						return TY_POISON
					}
				}
				if len(e.args) != len(method_type.params) - 1 {
					return report(
						ctx,
						e.span,
						"У метода %s ожидалось %d аргументов",
						resolve_interned(symbol_at(ctx.res.symbol_store, method_sym).name),
						len(method_type.params) - 1,
					)
				}
				// Стадия 7 Phase F: см. комментарий у .Struct-ветки выше —
				// та же причина (не check_expr, теряет свежую инстанциацию).
				if !unify_types(obj_type, method_type.params[0]) {
					report(
						ctx,
						expr_span(prop_expr.object),
						"Type Error: ожидался '%s', получен '%s'",
						prune_type(method_type.params[0]).name,
						obj_type.name,
					)
				}
				for arg, i in e.args do check_expr(ctx, arg, method_type.params[i + 1])

				ctx.call_infos[expr] = Call_Info{kind = .Method_Struct, symbol_ref = method_sym}
				return prune_type(method_type.return_type)
			}
		} else if obj_type.kind == .Interface {
			if method_type, exists := obj_type.interface_methods[prop_expr.property]; exists {
				if len(e.arg_names) > 0 {
					// Интерфейсный вызов — динамическая диспетчеризация по
					// имени, interface_methods хранит только резолвленный
					// ^Type (без исходных имён параметров из Method_
					// Signature) — именованные аргументы здесь не
					// поддержаны, узкое, явно диагностируемое ограничение.
					return report(
						ctx,
						e.span,
						"Type Error: именованные аргументы не поддержаны для интерфейсных вызовов",
					)
				}
				if len(e.args) != len(method_type.params) - 1 {
					return report(ctx, e.span, "Ожидалось %d аргументов", len(method_type.params) - 1)
				}
				for arg, i in e.args do check_expr(ctx, arg, method_type.params[i + 1])

				ctx.call_infos[expr] = Call_Info{kind = .Method_Interface, text_name = prop_expr.property}
				return prune_type(method_type.return_type)
			} else {
				return report(
					ctx,
					e.span,
					"Type Error: в интерфейсе '%s' нет метода '%s'",
					obj_type.name,
					prop_expr.property,
				)
			}
		} else if obj_type.kind == .Process {
			// Стадия 38 (monitor): .номер() — единственный метод на
			// Процесс(T) пока что, даёт id для сравнения с сигналами
			// получить_сигнал() (value_equals не сравнивает
			// ^Process_Value по значению — id-сравнение проще).
			switch prop_expr.property {
			case "номер":
				if len(e.args) != 0 do return report(ctx, e.span, "Type Error: Процесс.номер() не принимает аргументы")
				ctx.call_infos[expr] = Call_Info{kind = .Method_Collection, text_name = prop_expr.property}
				return TY_INT
			case:
				return report(
					ctx,
					e.span,
					"Type Error: у Процесс(T) нет метода '%s'",
					prop_expr.property,
				)
			}
		}
	}

	callee_type := prune_type(infer_expr(ctx, e.callee))
	if callee_type.kind == .Struct {
		if !resolve_named_call_args(ctx, e, struct_field_names(callee_type)) {
			return TY_POISON
		}
		if len(e.args) != len(callee_type.fields) {
			return report(
				ctx,
				e.span,
				"Type Error: структура '%s' имеет %d полей",
				callee_type.name,
				len(callee_type.fields),
			)
		}
		for arg, i in e.args do check_expr(ctx, arg, callee_type.fields[i].type)
		ctx.call_infos[expr] = Call_Info{kind = .Constructor_Struct}
		t = callee_type

		// Стадия 7 Phase C: если это конструктор generic-структуры,
		// callee_type — свежая (одноразовая) инстанциация от
		// instantiate_scheme в infer_ident_expr, с полями, только что
		// унифицированными выше в конкретные типы. Канонизируем через
		// generic_instance_cache — иначе unify_types (сравнивает .Struct
		// только по identity указателя) счёл бы два одинаковых
		// Пара(Число, Строка) из разных мест кода разными типами.
		// collect_instance_args (не ad-hoc обход .fields) — тот же обход,
		// что resolve_type_node использует для explicit-аннотаций, иначе
		// два пути дают разные ключи при полях не в порядке заголовка.
		if callee_sym != INVALID_SYMBOL {
			if _, is_generic := ctx.decl_type_params[callee_sym]; is_generic {
				arg_types := make([dynamic]^Type)
				collect_instance_args(callee_type, &arg_types)
				key := generic_instance_key(callee_sym, arg_types)
				if cached, found := ctx.generic_instance_cache[key]; found {
					t = cached
				} else {
					ctx.generic_instance_cache[key] = t
				}
			}
		}

	} else if callee_type.kind == .Function {
		if len(e.arg_names) > 0 {
			fn_decl, has_fn_decl := ctx.symbol_to_func_decl[callee_sym]
			if !has_fn_decl {
				return report(
					ctx,
					e.span,
					"Type Error: именованные аргументы не поддержаны для этого вызова",
				)
			}
			if !resolve_named_call_args(ctx, e, param_decl_names(fn_decl.args)) {
				return TY_POISON
			}
		}
		if len(e.args) != len(callee_type.params) {
			return report(ctx, e.span, "Type Error: неверное количество аргументов")
		}
		for arg, i in e.args do check_expr(ctx, arg, callee_type.params[i])
		t = prune_type(callee_type.return_type)

	} else if callee_type.kind == .Poison {
		t = TY_POISON
	} else {
		return report(
			ctx,
			e.span,
			"Type Error: значение типа '%s' нельзя вызвать",
			callee_type.name,
		)
	}
	return t
}

infer_if_expr :: proc(ctx: ^Type_Ctx, expr: Expr, e: ^If_Expr) -> ^Type {
	t: ^Type
	check_expr(ctx, e.condition, TY_BOOL)

	if len(e.else_branch) == 0 {
		// If без else всегда возвращает Void, так как не имеет значения для ложного условия
		infer_block_type(ctx, e.then_branch)
		t = TY_VOID
	} else {
		then_type := prune_type(infer_block_type(ctx, e.then_branch))
		else_type := prune_type(infer_block_type(ctx, e.else_branch))
		// Ветка-литерал (`иначе 0 конец`) рядом с Целое-веткой (напр. чужой
		// .длина()) — тот же widening, что и бинарные операторы: без него
		// `если ... тогда x.длина() иначе 0 конец` ложно репортился бы как
		// разнотипные ветки.
		if then_last := last_block_expr(e.then_branch); then_last != nil {
			then_type = widen_num_literal_to_int(ctx, then_last, then_type, else_type)
		}
		if else_last := last_block_expr(e.else_branch); else_last != nil {
			else_type = widen_num_literal_to_int(ctx, else_last, else_type, then_type)
		}

		emit_constraint(
			ctx,
			then_type,
			else_type,
			e.span,
			fmt.aprintf(
				"Type Error: ветки 'если' возвращают разные типы. 'тогда' -> '%s', 'иначе' -> '%s'",
				prune_type(then_type).name,
				prune_type(else_type).name,
			),
		)
		solve_constraints(ctx)
		if prune_type(then_type) == TY_NEVER {
			t = prune_type(else_type)
		} else {
			t = prune_type(then_type)
		}
	}
	return t
}

infer_while_expr :: proc(ctx: ^Type_Ctx, expr: Expr, e: ^While_Expr) -> ^Type {
	check_expr(ctx, e.condition, TY_BOOL)
	ctx.loop_depth += 1
	// Обязательно проверяем внутренности цикла (чтобы типизировать локальные переменные внутри)
	infer_block_type(ctx, e.body)
	ctx.loop_depth -= 1
	return TY_VOID
}

infer_tuple_expr :: proc(ctx: ^Type_Ctx, expr: Expr, e: ^Tuple_Expr) -> ^Type {
	elements_types := make([dynamic]^Type)
	for el in e.elements {
		append(&elements_types, infer_expr(ctx, el))
	}
	return new_tuple_type(elements_types)
}

infer_array_expr :: proc(ctx: ^Type_Ctx, expr: Expr, e: ^Array_Expr) -> ^Type {
	if len(e.elements) == 0 {
		return report(
			ctx,
			e.span,
			"Type Error: для пустого массива нужна аннотация ожидаемого типа",
		)
	}
	// join-точка (Стадия 7 constraint-based) — все элементы выводятся
	// сначала, потом сравниваются батчем. Заодно убирает задвоение:
	// раньше e.elements[0] инферился дважды (тут и на i==0 внутри цикла).
	element_type := infer_expr(ctx, e.elements[0])
	for i in 1 ..< len(e.elements) {
		current_type := infer_expr(ctx, e.elements[i])
		emit_constraint(
			ctx,
			current_type,
			element_type,
			expr_span(e.elements[i]),
			fmt.aprintf(
				"Type Error: элементы массива имеют разные типы: '%s' и '%s'",
				prune_type(element_type).name,
				prune_type(current_type).name,
			),
		)
	}
	solve_constraints(ctx)
	return new_array_type(prune_type(element_type))
}

infer_map_expr :: proc(ctx: ^Type_Ctx, expr: Expr, e: ^Map_Expr) -> ^Type {
	if len(e.entries) == 0 {
		return report(
			ctx,
			e.span,
			"Type Error: для пустого соответствия нужна аннотация ожидаемого типа",
		)
	}
	// join-точка (Стадия 7 constraint-based) — ключи и значения выводятся
	// сначала, потом сравниваются батчем. is_valid_map_key_type остаётся
	// eager-проверкой (не "N сиблингов должны совпасть друг с другом", а
	// "этот конкретный тип годится как ключ вообще" — другой класс
	// проверки). Заодно убирает задвоение entries[0] (см. infer_array_expr).
	key_type := infer_expr(ctx, e.entries[0].key)
	value_type := infer_expr(ctx, e.entries[0].value)
	if !is_valid_map_key_type(key_type) {
		report(
			ctx,
			expr_span(e.entries[0].key),
			"Type Error: тип '%s' нельзя использовать как ключ соответствия",
			key_type.name,
		)
	}
	for i in 1 ..< len(e.entries) {
		entry := e.entries[i]
		current_key_type := infer_expr(ctx, entry.key)
		current_value_type := infer_expr(ctx, entry.value)
		if !is_valid_map_key_type(current_key_type) {
			report(
				ctx,
				expr_span(entry.key),
				"Type Error: тип '%s' нельзя использовать как ключ соответствия",
				current_key_type.name,
			)
		}
		emit_constraint(
			ctx,
			current_key_type,
			key_type,
			expr_span(entry.key),
			fmt.aprintf(
				"Type Error: ключи соответствия имеют разные типы: '%s' и '%s'",
				prune_type(key_type).name,
				prune_type(current_key_type).name,
			),
		)
		emit_constraint(
			ctx,
			current_value_type,
			value_type,
			expr_span(entry.value),
			fmt.aprintf(
				"Type Error: значения соответствия имеют разные типы: '%s' и '%s'",
				prune_type(value_type).name,
				prune_type(current_value_type).name,
			),
		)
	}
	solve_constraints(ctx)
	return new_map_type(prune_type(key_type), prune_type(value_type))
}

infer_index_expr :: proc(ctx: ^Type_Ctx, expr: Expr, e: ^Index_Expr) -> ^Type {
	t: ^Type
	obj_type := prune_type(infer_expr(ctx, e.object))
	if obj_type.kind == .Array {
		check_expr(ctx, e.index, TY_INT)
		t = prune_type(obj_type.element_type)
	} else if obj_type.kind == .Map {
		// Частый источник этой ошибки — для-in напрямую на Соответствие
		// (`для x в моя_карта цикл`): для-in раскрывается в позиционное
		// `[индекс]` (см. parse_for_stmt_into в parser.odin), а
		// Соответствие индексируется по ключу, не позиционно. Подсказка
		// нацелена именно на этот случай (индекс — Число, ключ — нет),
		// остальные несовпадения репортятся как обычно.
		index_type := prune_type(infer_expr(ctx, e.index))
		key_type := prune_type(obj_type.key_type)
		if !unify_types(index_type, key_type) {
			if index_type.kind == .Number && key_type.kind != .Number {
				report(
					ctx,
					e.span,
					"Type Error: соответствие индексируется по ключу типа '%s', получено 'Число' — Соответствие не поддерживает позиционный доступ; для перебора элементов используйте .записи() и 'для (ключ, значение) в ...'",
					key_type.name,
				)
			} else {
				report(
					ctx,
					e.span,
					"Type Error: ожидался '%s', получен '%s'",
					key_type.name,
					index_type.name,
				)
			}
		}
		t = prune_type(obj_type.value_type)
	} else if obj_type.kind == .String {
		check_expr(ctx, e.index, TY_INT)
		t = TY_STRING
	} else if obj_type.kind == .Poison {
		t = TY_POISON
	} else {
		t = report(
			ctx,
			e.span,
			"Type Error: индексирование поддерживают только массивы и соответствия, получен '%s'",
			obj_type.name,
		)
	}
	return t
}

infer_match_expr :: proc(ctx: ^Type_Ctx, expr: Expr, e: ^Match_Expr) -> ^Type {
	// Стадия 7 Phase F: Опция/Результат — обычные .Enum (прелюдия), не
	// нужен отдельный synth-вид.
	subject_type_actual := prune_type(infer_expr(ctx, e.subject))
	subject_type := subject_type_actual

	// Стадия 24 (actor model): subject неразрешённого типа (InferVar) —
	// получить() не знает T заранее (см. BUILTIN_CTORS-запись "получить").
	// Единственный способ узнать T без внешнего контекста — квалификация
	// паттерна (Тип.Вариант); ЗА счёт этого требуем полную квалификацию
	// (Сообщение.Увеличить, не голое Увеличить) для `выбор получить()`,
	// как в примере ROADMAP §Стадия 24. bind_infer_var — тот же
	// unify-примитив, что и везде в файле, просто источник цели —
	// найденный по имени enum, а не другое выражение.
	if subject_type.kind == .InferVar {
		for arm in e.arms {
			ctor, ok := arm.pattern.(^Pattern_Constructor)
			if !ok || ctor.module_name == "" do continue
			sym := lookup_symbol(ctx.res.global_scope, intern(ctor.module_name))
			if sym == INVALID_SYMBOL do continue
			candidate, has_type := ctx.res.symbol_types[sym]
			if !has_type || candidate == nil || candidate.kind != .Enum do continue
			bind_infer_var(subject_type, candidate)
			break
		}
		subject_type_actual = prune_type(subject_type_actual)
		subject_type = subject_type_actual
	}

	if subject_type.kind != .Enum &&
	   subject_type.kind != .Number &&
	   subject_type.kind != .Integer &&
	   subject_type.kind != .String &&
	   subject_type.kind != .Bool &&
	   subject_type.kind != .Struct {
		// Возвращаем сразу — иначе классификация каждой ветки ниже полезет
		// в classify_pattern с невалидным subject_type и продублирует эту
		// же ошибку на каждую ветку.
		return report(
			ctx,
			e.span,
			"Type Error: выбор ожидает значение перечисления, структуры, числа, строки или булево, получено '%s'",
			subject_type_actual.name,
		)
	}
	arm_infos := make([dynamic]Pattern_Info)
	result_t: ^Type
	result_expr: Expr
	for arm in e.arms {
		pi := classify_pattern(ctx, arm.pattern, subject_type_actual)
		append(&arm_infos, pi)

		// Тело ветки
		body_t: ^Type
		body_expr: Expr
		for stmt, i in arm.body {
			is_last := i == len(arm.body) - 1
			if is_last {
				if expr_stmt, ok := stmt.(^Expr_Stmt); ok {
					body_t = prune_type(infer_expr(ctx, expr_stmt.expr))
					body_expr = expr_stmt.expr
				} else {
					check_stmt(ctx, stmt, ctx.current_return)
					body_t = TY_VOID
				}
			} else {
				check_stmt(ctx, stmt, ctx.current_return)
			}
		}
		if body_t == nil do body_t = TY_VOID
		if body_t.kind != .Never {
			if result_t == nil {
				result_t = body_t
				result_expr = body_expr
			} else {
				// Литерал-ветка рядом с Целое-веткой (напр. чужой .длина())
				// — тот же widening, что если/иначе и бинарные операторы.
				if body_expr != nil {
					body_t = widen_num_literal_to_int(ctx, body_expr, body_t, result_t)
				}
				if result_expr != nil {
					result_t = widen_num_literal_to_int(ctx, result_expr, result_t, body_t)
				}
				// join-точка (Стадия 7 constraint-based) — сравнение
				// откладывается в общий батч ниже, после того как ВСЕ
				// ветки уже выведены (result_t тут — уже финальный тип
				// первой не-Never ветки, дальше не меняется).
				emit_constraint(
					ctx,
					body_t,
					result_t,
					arm.span,
					fmt.aprintf(
						"Type Error: ветки выбора возвращают разные типы: '%s' vs '%s'",
						prune_type(result_t).name,
						prune_type(body_t).name,
					),
				)
			}
		}
	}
	solve_constraints(ctx)
	if result_t == nil do result_t = TY_NEVER
	ctx.match_arm_infos[e] = arm_infos
	check_match_coverage(ctx, e.span, subject_type, arm_infos)
	return prune_type(result_t)
}

// Стадия 7 Phase F: Опция/Результат больше не Type_Kind — обычные enum'ы
// прелюдии, отличаем их от произвольного пользовательского enum'а через
// generic_origin (Symbol_Id объявления Опции/Результата в прелюдии).
// Нет=0/Есть=1 у Опции, Успех=0/Неудача=1 у Результата — тег-порядок
// зафиксирован в prelude.odin.
infer_try_expr :: proc(ctx: ^Type_Ctx, expr: Expr, e: ^Try_Expr) -> ^Type {
	t: ^Type
	value_type := prune_type(infer_expr(ctx, e.value))
	if value_type.generic_origin != INVALID_SYMBOL &&
	   value_type.generic_origin == ctx.res.prelude_option_sym {
		return_type := prune_type(ctx.current_return)
		if return_type == nil || return_type.generic_origin != ctx.res.prelude_option_sym {
			report(
				ctx,
				e.span,
				"Type Error: оператор '?' для Опции можно использовать только в функции, возвращающей Опцию",
			)
		}
		t = prune_type(value_type.variants[1].fields[0])
	} else if value_type.generic_origin != INVALID_SYMBOL &&
	   value_type.generic_origin == ctx.res.prelude_result_sym {
		return_type := prune_type(ctx.current_return)
		if return_type == nil || return_type.generic_origin != ctx.res.prelude_result_sym {
			report(
				ctx,
				e.span,
				"Type Error: оператор '?' можно использовать только в функции, возвращающей Результат",
			)
		} else if !unify_types(value_type.variants[1].fields[0], return_type.variants[1].fields[0]) {
			report(
				ctx,
				e.span,
				"Type Error: оператор '?' возвращает ошибку типа '%s', но функция ожидает '%s'",
				prune_type(value_type.variants[1].fields[0]).name,
				prune_type(return_type.variants[1].fields[0]).name,
			)
		}
		t = prune_type(value_type.variants[0].fields[0])
	} else if value_type.kind == .Poison {
		t = TY_POISON
	} else {
		t = report(
			ctx,
			e.span,
			"Type Error: оператор '?' ожидает Опцию или Результат, получен '%s'",
			value_type.name,
		)
	}
	return t
}

infer_property_expr :: proc(ctx: ^Type_Ctx, expr: Expr, e: ^Property_Expr) -> ^Type {
	if sym_id, ok := ctx.res.node_symbols[expr]; ok {
		if symbol_at(ctx.res.symbol_store, sym_id).kind == .Enum_Variant {
			return resolve_variant_ctor(ctx, expr, sym_id, nil, false)
		}
		return prune_type(ctx.res.symbol_types[sym_id])
	}
	if obj_ident, ok := e.object.(^Ident_Expr); ok {
		if obj_sym := ctx.res.node_symbols[e.object];
		   obj_sym != INVALID_SYMBOL && symbol_at(ctx.res.symbol_store, obj_sym).kind == .Module {
			imported_module := symbol_at(ctx.res.symbol_store, obj_sym).module
			if imported_module == nil {
				return report(
					ctx,
					e.span,
					"Type Error: модуль '%s' не загружен",
					resolve_interned(obj_ident.name),
				)
			}
			if export_sym_id, found := imported_module.exports[intern(e.property)]; found {
				export_sym := symbol_at(ctx.res.symbol_store, export_sym_id)
				if typ, found_type := ctx.res.symbol_types[export_sym_id];
				   found_type && typ != nil {
					return prune_type(typ)
				}
				if export_sym.kind == .Builtin {
					bt := builtin_export_type(ctx.res.module_graph, resolve_interned(export_sym.full_name))
					if bt != nil {
						ctx.res.symbol_types[export_sym_id] = bt
						return bt
					}
				} else if fn_decl, has_fn_decl := export_sym.decl.(^Function_Decl);
				   has_fn_decl {
					return function_type_from_decl(ctx, fn_decl)
				}
				return report(
					ctx,
					e.span,
					"Type Error: тип '%s.%s' еще не доступен",
					resolve_interned(obj_ident.name),
					e.property,
				)
			}
			return report(
				ctx,
				e.span,
				"Type Error: модуль '%s' не экспортирует '%s'",
				resolve_interned(obj_ident.name),
				e.property,
			)
		}
	}
	t: ^Type
	obj_type := prune_type(infer_expr(ctx, e.object))
	if obj_type.kind == .Struct {
		field_idx := -1
		for f, i in obj_type.fields {
			if f.name == e.property {
				field_idx = i
				t = f.type
				break
			}
		}
		if field_idx == -1 {
			return report(ctx, e.span, "Type Error: у структуры '%s' нет поля '%s'", obj_type.name, e.property)
		}
		ctx.property_indices[expr] = field_idx

	} else if obj_type.kind == .Tuple {
		idx, ok := strconv.parse_int(e.property)
		if !ok {
			return report(ctx, e.span, "Type Error: неверный индекс тупла '%s'", e.property)
		}
		if idx < 0 || idx >= len(obj_type.elements) {
			return report(ctx, e.span, "Type Error: индекс %d выходит за границы", idx)
		}
		t = obj_type.elements[idx]
		ctx.property_indices[expr] = idx

	} else if obj_type.kind == .Array || obj_type.kind == .Map {
		return report(
			ctx,
			e.span,
			"Type Error: метод коллекции '%s' нужно вызвать через ()",
			e.property,
		)

	} else if obj_type.kind == .Error {
		switch e.property {
		case "код":
			t = TY_STRING
			ctx.property_indices[expr] = 0
		case "сообщение":
			t = TY_STRING
			ctx.property_indices[expr] = 1
		case:
			t = report(ctx, e.span, "Type Error: у Ошибка нет поля '%s'", e.property)
		}

	} else if obj_type.kind == .Poison {
		t = TY_POISON

	} else {
		return report(
			ctx,
			e.span,
			"Type Error: попытка получить поле у не-структуры (тип: %s)",
			obj_type.name,
		)
	}
	return t
}

// Выводит тип выражения без внешнего ожидания. Диспатчер на ~15 строк —
// каждый case AST-узла делегирует в отдельную infer_X_expr процедуру,
// читаемую и тестируемую независимо от остальных.
infer_expr :: proc(ctx: ^Type_Ctx, expr: Expr) -> ^Type {
	if expr == nil do return nil
	if t, ok := ctx.node_types[expr]; ok do return t

	t: ^Type
	switch e in expr {
	case ^Number_Expr:
		// Литералы всегда Число, независимо от наличия точки в исходнике.
		// Целое сознательно не выводится из литерального синтаксиса в этом
		// проходе (коэрция Целое<->Число отложена до cast) — get Целое можно
		// только через явно Целое-типизированные значения (параметры,
		// поля структур и т.п.), не через "голый" литерал.
		t = TY_NUM
	case ^Boolean_Expr:
		t = TY_BOOL
	case ^String_Expr:
		t = TY_STRING
	case ^Lambda_Expr:
		t = check_lambda_expr(ctx, expr, e)
	case ^Ident_Expr:
		t = infer_ident_expr(ctx, expr, e)
	case ^Binary_Expr:
		t = infer_binary_expr(ctx, expr, e)
	case ^Unary_Expr:
		t = infer_unary_expr(ctx, expr, e)
	case ^Call_Expr:
		t = infer_call_expr(ctx, expr, e)
	case ^If_Expr:
		t = infer_if_expr(ctx, expr, e)
	case ^While_Expr:
		t = infer_while_expr(ctx, expr, e)
	case ^Tuple_Expr:
		t = infer_tuple_expr(ctx, expr, e)
	case ^Array_Expr:
		t = infer_array_expr(ctx, expr, e)
	case ^Map_Expr:
		t = infer_map_expr(ctx, expr, e)
	case ^Index_Expr:
		t = infer_index_expr(ctx, expr, e)
	case ^Match_Expr:
		t = infer_match_expr(ctx, expr, e)
	case ^Try_Expr:
		t = infer_try_expr(ctx, expr, e)
	case ^Property_Expr:
		t = infer_property_expr(ctx, expr, e)
	case ^Error_Expr:
		// Уже отрапортовано парсером — не дублируем diagnostic.
		t = TY_POISON
	case ^Spawn_Expr:
		t = infer_spawn_expr(ctx, expr, e)
	}

	ctx.node_types[expr] = t
	return t
}

// Отладочная печать уже вычисленных типов символов.
print_type_ctx :: proc(ctx: ^Type_Ctx) {
	for symbol_id, type in ctx.res.symbol_types {
		symbol := symbol_at(ctx.res.symbol_store, symbol_id)
		fmt.printf("Символ '%s' имеет тип %s\n", resolve_interned(symbol.name), prune_type(type).name)
	}
}
