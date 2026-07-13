package core

import "core:fmt"
import "core:strconv"
import "core:strings"

// --- ТИПЫ ДАННЫХ ---

Type_Kind :: enum {
	Number,
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
	Option,
	Result,
	InferVar,
	Enum,
	// Дескриптор открытого файла/потока (фс.открыть, ввод_вывод.поток) —
	// непараметрический тип, методы см. FILE_METHODS.
	File,
	// TCP-соединение (сеть.подключиться) — непараметрический тип, методы
	// см. CONNECTION_METHODS.
	Connection,
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
	ok_type:                ^Type,
	error_type:             ^Type,
	infer_id:               int,
	binding:                ^Type,
	// Для kind == .Enum (пользовательский ADT) — упорядоченный список
	// вариантов. Также заполняется для kind == .Option / .Result при
	// построении prelude, чтобы `выбор` разбирал их единым путём.
	variants:               [dynamic]Type_Variant,
	// Индекс имени варианта в `variants` — заполняется вместе с variants,
	// избавляет от O(V) линейного поиска в 3+ местах.
	variant_index:          map[string]int,
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
TY_BOOL := &Type{kind = .Bool, name = "Булево"}
TY_VOID := &Type{kind = .Void, name = "Пусто"}
TY_NEVER := &Type{kind = .Never, name = "Никогда"}
TY_STRING := &Type{kind = .String, name = "Строка"}
TY_ERROR := &Type{kind = .Error, name = "Ошибка"}
TY_FILE := &Type{kind = .File, name = "Файл"}
TY_CONNECTION := &Type{kind = .Connection, name = "Соединение"}
TY_POISON := &Type{kind = .Poison, name = "?ошибка?"}

// Имя базового типа в аннотации → интернированный Type. `Никогда` был
// пропущен здесь исторически — `функ f() -> Никогда` падал с "неизвестный
// тип", хотя TY_NEVER существовал. Fixed-size array вместо map — global
// map-литералы в Odin по умолчанию запрещены (dynamic-type literal), а
// для 6 записей линейный поиск не хуже hash-lookup'а.
Base_Type_Entry :: struct {
	name: string,
	typ:  ^Type,
}

BASE_TYPES := [?]Base_Type_Entry {
	{"Число", TY_NUM},
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

new_option_type :: proc(element_type: ^Type) -> ^Type {
	t := new(Type)
	t.kind = .Option
	t.element_type = element_type
	t.name = fmt.tprintf("Опция(%s)", element_type.name)
	return t
}

new_result_type :: proc(ok_type: ^Type, error_type: ^Type) -> ^Type {
	t := new(Type)
	t.kind = .Result
	t.ok_type = ok_type
	t.error_type = error_type
	t.name = fmt.tprintf("Результат(%s, %s)", ok_type.name, error_type.name)
	return t
}

is_valid_map_key_type :: proc(t: ^Type) -> bool {
	typ := prune_type(t)
	return typ.kind == .Number || typ.kind == .Bool || typ.kind == .String
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
	symbol_ref: Symbol_Id,         // Method_Struct
	text_name:  string,            // Builtin, Method_Interface, Method_Collection
	variant:    Variant_Call_Info, // Constructor_Variant
}

Match_Arm_Kind :: enum {
	Wildcard,
	Binder,
	Constructor,
}

Pattern_Info :: struct {
	kind:         Match_Arm_Kind,
	tag_index:    int,
	binder_sym:   Symbol_Id,
	// Для конструктора: рекурсивные под-шаблоны, по одному на поле варианта.
	sub_patterns: [dynamic]Pattern_Info,
	span:         Span,
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
	case ^Pattern_Wildcard:
		info.span = pat.span
		info.kind = .Wildcard
	case ^Pattern_Literal:
		info.span = pat.span
		report(ctx, pat.span, "Type Error: литеральные шаблоны в выборе пока не поддерживаются")
		info.kind = .Wildcard
	case ^Pattern_Ident:
		info.span = pat.span
		expected := prune_type(expected_type)
		if expected.kind == .Enum || expected.kind == .Option || expected.kind == .Result {
			enum_view := expected
			if expected.kind == .Option || expected.kind == .Result do enum_view = synth_enum_view(ctx, expected)
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
				return info
			}
		}
		binder_sym := ctx.res.pattern_binders[pat]
		if binder_sym == INVALID_SYMBOL {
			report(ctx, pat.span, "Type Error: не разрешён шаблон '%s'", pat.name)
			info.kind = .Wildcard
			return info
		}
		info.kind = .Binder
		info.binder_sym = binder_sym
		ctx.res.symbol_types[binder_sym] = expected_type
	case ^Pattern_Constructor:
		info.span = pat.span
		expected := prune_type(expected_type)
		if expected.kind != .Enum && expected.kind != .Option && expected.kind != .Result {
			report(
				ctx,
				pat.span,
				"Type Error: шаблон-конструктор '%s' ожидает значение перечисления, получено '%s'",
				pat.name,
				expected.name,
			)
			info.kind = .Wildcard
			return info
		}
		enum_view := expected
		if expected.kind == .Option || expected.kind == .Result do enum_view = synth_enum_view(ctx, expected)
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
			return info
		}
		info.kind = .Constructor
		info.tag_index = tag
		info.sub_patterns = make([dynamic]Pattern_Info)
		for arg_pat, i in pat.args {
			sub := classify_pattern(ctx, arg_pat, expected_fields[i])
			append(&info.sub_patterns, sub)
		}
	}
	return info
}

// Собираем виртуальный `.Enum` тип для встроенной `Опция(T)`, чтобы `выбор`
// разбирал её единообразно (Q5, R5). Порядок вариантов зафиксирован:
// 0 = Нет, 1 = Есть(T).
synth_option_enum :: proc(option_type: ^Type) -> ^Type {
	t := new(Type)
	t.kind = .Enum
	t.name = option_type.name
	t.variants = make([dynamic]Type_Variant)
	t.variant_index = make(map[string]int)
	append(&t.variants, Type_Variant{name = "Нет", fields = make([dynamic]^Type)})
	t.variant_index["Нет"] = 0
	есть_fields := make([dynamic]^Type)
	append(&есть_fields, option_type.element_type)
	append(&t.variants, Type_Variant{name = "Есть", fields = есть_fields})
	t.variant_index["Есть"] = 1
	return t
}

// То же для `Результат(T, E)`: 0 = Успех(T), 1 = Неудача(E).
synth_result_enum :: proc(result_type: ^Type) -> ^Type {
	t := new(Type)
	t.kind = .Enum
	t.name = result_type.name
	t.variants = make([dynamic]Type_Variant)
	t.variant_index = make(map[string]int)
	успех_fields := make([dynamic]^Type)
	append(&успех_fields, result_type.ok_type)
	append(&t.variants, Type_Variant{name = "Успех", fields = успех_fields})
	t.variant_index["Успех"] = 0
	неудача_fields := make([dynamic]^Type)
	append(&неудача_fields, result_type.error_type)
	append(&t.variants, Type_Variant{name = "Неудача", fields = неудача_fields})
	t.variant_index["Неудача"] = 1
	return t
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
			// Constructor-с-нетривиальными-подшаблонами (nested constructors or
			// non-wildcard binders) НЕ покрывает вариант целиком — семантика
			// exhaustiveness требует полного покрытия. Помечаем как covered
			// только если все подшаблоны — Wildcard или Binder.
			fully_covers := true
			for sub in pi.sub_patterns {
				if sub.kind == .Constructor {
					fully_covers = false
					break
				}
			}
			if fully_covers && covered[pi.tag_index] {
				report(
					ctx,
					pi.span,
					"Type Error: вариант '%s.%s' покрыт повторно в ветке #%d",
					subject_type.name,
					subject_type.variants[pi.tag_index].name,
					arm_idx + 1,
				)
			}
			if fully_covers do covered[pi.tag_index] = true
		}
	}

	if catch_all do return

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
	// Кэш synth-view Enum-типов для Опции/Результата: base type (Option/
	// Result) → построенный virtual-Enum. Без кэша каждый match над одной
	// Опцией/Результатом создаёт новый Type-объект (утечка + сломанный
	// identity-check).
	synth_enum_cache: map[^Type]^Type,
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
}

new_type_ctx :: proc(res: ^Resolver_Ctx) -> Type_Ctx {
	return Type_Ctx {
		res = res,
		node_types = make(map[Expr]^Type),
		property_indices = make(map[Expr]int),
		interface_casts = make(map[Expr]^Type),
		call_infos = make(map[Expr]Call_Info),
		match_arm_infos = make(map[^Match_Expr][dynamic]Pattern_Info),
		synth_enum_cache = make(map[^Type]^Type),
		diagnostics = make([dynamic]Diagnostic),
		symbol_schemes = make(map[Symbol_Id]Type_Scheme),
	}
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

// Кэширующая обёртка над synth_option_enum/synth_result_enum: один base
// type даёт один synth-Enum на весь прогон type checker'а.
synth_enum_view :: proc(ctx: ^Type_Ctx, base: ^Type) -> ^Type {
	if cached, ok := ctx.synth_enum_cache[base]; ok do return cached
	result: ^Type
	#partial switch base.kind {
	case .Option:
		result = synth_option_enum(base)
	case .Result:
		result = synth_result_enum(base)
	case:
		fmt.panicf("Type Error: internal — synth_enum_view для не-Option/Result типа '%s'", base.name)
	}
	ctx.synth_enum_cache[base] = result
	return result
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

	case .Option:
		return type_contains_infer_var(typ.element_type, needle)

	case .Result:
		return(
			type_contains_infer_var(typ.ok_type, needle) ||
			type_contains_infer_var(typ.error_type, needle) \
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
	var_type.binding = target_type
	return true
}

// Собирает infer_id непривязанных InferVar, достижимых из t — тот же обход,
// что и type_contains_infer_var, только вместо поиска конкретного needle
// копит все встреченные unbound InferVar (с дедупом). Используется
// generalize'ом (Стадия 7 Phase A).
collect_free_infer_vars :: proc(t: ^Type, out: ^[dynamic]int) {
	typ := prune_type(t)
	if typ == nil do return

	if typ.kind == .InferVar {
		for id in out {
			if id == typ.infer_id do return
		}
		append(out, typ.infer_id)
		return
	}

	#partial switch typ.kind {
	case .Function:
		for param in typ.params do collect_free_infer_vars(param, out)
		collect_free_infer_vars(typ.return_type, out)
	case .Tuple:
		for el in typ.elements do collect_free_infer_vars(el, out)
	case .Array:
		collect_free_infer_vars(typ.element_type, out)
	case .Map:
		collect_free_infer_vars(typ.key_type, out)
		collect_free_infer_vars(typ.value_type, out)
	case .Option:
		collect_free_infer_vars(typ.element_type, out)
	case .Result:
		collect_free_infer_vars(typ.ok_type, out)
		collect_free_infer_vars(typ.error_type, out)
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
instantiate_type :: proc(ctx: ^Type_Ctx, t: ^Type, subst: ^map[int]^Type) -> ^Type {
	pruned := prune_type(t)
	if pruned == nil do return nil

	#partial switch pruned.kind {
	case .InferVar:
		if fresh, ok := subst[pruned.infer_id]; ok do return fresh
		return pruned
	case .Function:
		params := make([dynamic]^Type)
		for param in pruned.params do append(&params, instantiate_type(ctx, param, subst))
		return new_function_type(params, instantiate_type(ctx, pruned.return_type, subst))
	case .Tuple:
		elements := make([dynamic]^Type)
		for el in pruned.elements do append(&elements, instantiate_type(ctx, el, subst))
		return new_tuple_type(elements)
	case .Array:
		return new_array_type(instantiate_type(ctx, pruned.element_type, subst))
	case .Map:
		return new_map_type(
			instantiate_type(ctx, pruned.key_type, subst),
			instantiate_type(ctx, pruned.value_type, subst),
		)
	case .Option:
		return new_option_type(instantiate_type(ctx, pruned.element_type, subst))
	case .Result:
		return new_result_type(
			instantiate_type(ctx, pruned.ok_type, subst),
			instantiate_type(ctx, pruned.error_type, subst),
		)
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

// Унификация либо подтверждает совместимость типов, либо фиксирует InferVar.
// Это главный механизм вывода типов в лямбдах, аргументах и присваиваниях.
unify_types :: proc(a: ^Type, b: ^Type) -> bool {
	left := prune_type(a)
	right := prune_type(b)
	if left == nil || right == nil do return false
	if left == right do return true
	if left.kind == .Never || right.kind == .Never do return true
	if left.kind == .Poison || right.kind == .Poison do return true

	if left.kind == .InferVar do return bind_infer_var(left, right)
	if right.kind == .InferVar do return bind_infer_var(right, left)

	if right.kind == .Interface && left.kind == .Struct {
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
			if !unify_types(left.elements[i], right.elements[i]) do return false
		}
		return true

	case .Function:
		if len(left.params) != len(right.params) do return false
		for i in 0 ..< len(left.params) {
			if !unify_types(left.params[i], right.params[i]) do return false
		}
		return unify_types(left.return_type, right.return_type)

	case .Array:
		return unify_types(left.element_type, right.element_type)

	case .Map:
		return(
			unify_types(left.key_type, right.key_type) &&
			unify_types(left.value_type, right.value_type) \
		)

	case .Option:
		return unify_types(left.element_type, right.element_type)

	case .Result:
		return(
			unify_types(left.ok_type, right.ok_type) &&
			unify_types(left.error_type, right.error_type) \
		)

	case .Struct, .Interface:
		return false
	}
	return true
}

// После вывода типа проверяем, что в нем не осталось неизвестных частей.
has_unresolved_infer_vars :: proc(t: ^Type) -> bool {
	typ := prune_type(t)
	if typ == nil do return false

	#partial switch typ.kind {
	case .InferVar:
		return true

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

	case .Option:
		return has_unresolved_infer_vars(typ.element_type)

	case .Result:
		return has_unresolved_infer_vars(typ.ok_type) || has_unresolved_infer_vars(typ.error_type)
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

interface_method_types_match :: proc(expected: ^Type, actual: ^Type) -> bool {
	if expected == nil || actual == nil do return false
	if expected.kind != .Function || actual.kind != .Function do return false
	if len(expected.params) != len(actual.params) do return false
	if !types_are_equal(actual.return_type, expected.return_type) do return false

	for i in 1 ..< len(expected.params) {
		if !types_are_equal(actual.params[i], expected.params[i]) do return false
	}
	return true
}

// --- ГЛАВНЫЙ ЦИКЛ ---

// Основной проход type checker'а идет в несколько стадий:
// сначала регистрируем номинальные типы, потом сигнатуры, затем реализации,
// и только после этого проверяем тела.
typecheck_program :: proc(ctx: ^Type_Ctx, prog: Program) {
	// ПРОХОД 1: создаем номинальные типы до разбора полей и сигнатур.
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
			ctx.res.symbol_types[sym] = struct_type

		case ^Interface_Decl:
			iface_type := new(Type)
			iface_type.kind = .Interface
			iface_type.name = d.name
			iface_type.interface_methods = make(map[string]^Type)
			ctx.res.symbol_types[ctx.res.decl_symbols[decl]] = iface_type

		case ^Enum_Decl:
			enum_type := new(Type)
			enum_type.kind = .Enum
			enum_type.name = d.name
			enum_type.variants = make([dynamic]Type_Variant)
			enum_type.variant_index = make(map[string]int)
			// Как у Struct — без этого `реализация X` для перечисления X
			// падала бы на nil-map assignment в ПРОХОДЕ 3.
			enum_type.methods = make(map[string]Symbol_Id)
			ctx.res.symbol_types[ctx.res.decl_symbols[decl]] = enum_type
		}
	}

	// ПРОХОД 2: заполняем структуры, интерфейсы и сигнатуры функций.
	for decl in prog.decls {
		#partial switch d in decl {
		case ^Struct_Decl:
			sym := ctx.res.decl_symbols[decl]
			struct_type := ctx.res.symbol_types[sym]
			struct_type.fields = make([dynamic]Struct_Field)

			for f in d.fields {
				field_type := resolve_type_node(ctx, f.type_annotation)
				append(&struct_type.fields, Struct_Field{name = f.name, type = field_type})
			}

		case ^Function_Decl:
			sym := ctx.res.decl_symbols[decl]
			ctx.res.symbol_types[sym] = function_type_from_decl(ctx, d)

		case ^Interface_Decl:
			iface_type := ctx.res.symbol_types[ctx.res.decl_symbols[decl]]
			iface_type.interface_methods = make(map[string]^Type)
			for m in d.methods {
				iface_type.interface_methods[m.name] = interface_method_type_from_signature(
					ctx,
					iface_type,
					m,
				)
			}

		case ^Enum_Decl:
			enum_type := ctx.res.symbol_types[ctx.res.decl_symbols[decl]]
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

	// ПРОХОД 3: Привязка реализаций (методов и контрактов) к структурам и
	// перечислениям. Интерфейсы перечисления реализовывать не могут —
	// узкий scope, не design-ограничение языка (interface_method_types_match
	// и остальной контрактный путь ниже писались и тестировались только
	// под Struct-получатели).
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
			if target_type.kind == .Enum && d.interface_name != "" {
				report(
					ctx,
					d.span,
					"Type Error: перечисление '%s' не может реализовывать интерфейс '%s'",
					d.target_type,
					d.interface_name,
				)
				continue
			}

			// Регистрируем методы
			for m in d.methods {
				sym := ctx.res.decl_symbols[m]
				method_type := function_type_from_decl(ctx, m)
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
			}

			// Строгая проверка интерфейсного контракта (только Struct — см.
			// guard выше)
			if d.interface_name != "" {
				iface_sym := ctx.res.global_scope.symbols[intern(d.interface_name)]
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
					actual_method_type := ctx.res.symbol_types[method_sym]
					if !interface_method_types_match(expected_method_type, actual_method_type) {
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

	// ПРОХОД 4: Глубокая проверка тел всех функций и методов
	for decl in prog.decls {
		#partial switch d in decl {
		case ^Function_Decl:
			func_type := ctx.res.symbol_types[ctx.res.decl_symbols[decl]]
			bind_function_args(ctx, d, func_type)
			check_function_body(ctx, d.span, d.body, func_type.return_type)
		case ^Impl_Decl:
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
				bind_function_args(ctx, m, func_type)
				check_function_body(ctx, m.span, m.body, func_type.return_type)
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
		} else if n.name == "Опция" {
			if len(n.params) != 1 do return report(ctx, n.span, "Type Error: Опция ожидает 1 параметр типа")
			return new_option_type(resolve_type_node(ctx, n.params[0]))
		} else if n.name == "Результат" {
			if len(n.params) != 2 do return report(ctx, n.span, "Type Error: Результат ожидает 2 параметра типа")
			return new_result_type(
				resolve_type_node(ctx, n.params[0]),
				resolve_type_node(ctx, n.params[1]),
			)
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

	if right.kind == .Interface && left.kind == .Struct {
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

	case .Option:
		return types_are_equal(left.element_type, right.element_type)

	case .Result:
		return(
			types_are_equal(left.ok_type, right.ok_type) &&
			types_are_equal(left.error_type, right.error_type) \
		)

	case .Struct, .Interface:
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

// Проверка обычной функции против уже известной сигнатуры.
check_func_decl :: proc(ctx: ^Type_Ctx, d: ^Function_Decl) {
	func_type := ctx.res.symbol_types[ctx.res.decl_symbols[d]]
	check_function_body(ctx, d.span, d.body, func_type.return_type)
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

	case ^Let_Stmt, ^Expr_Stmt, ^Continue_Stmt, ^Break_Stmt, ^Error_Stmt:
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

	if expected_type.kind == .Interface && actual.kind == .Struct {
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

// Таблица builtin-конструкторов (Ошибка/Есть/Нет/Успех/Неудача/длина/
// паника). Arity проверяется единообразно диспетчером; handler отвечает
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
		name = "Есть",
		arity = 1,
		handler = proc(ctx: ^Type_Ctx, call: Expr, args: [dynamic]Expr) -> ^Type {
			return new_option_type(infer_expr(ctx, args[0]))
		},
	},
	{
		name = "Нет",
		arity = 0,
		handler = proc(ctx: ^Type_Ctx, call: Expr, args: [dynamic]Expr) -> ^Type {
			return new_option_type(new_infer_var(ctx))
		},
	},
	{
		name = "Успех",
		arity = 1,
		handler = proc(ctx: ^Type_Ctx, call: Expr, args: [dynamic]Expr) -> ^Type {
			return new_result_type(infer_expr(ctx, args[0]), new_infer_var(ctx))
		},
	},
	{
		name = "Неудача",
		arity = 1,
		handler = proc(ctx: ^Type_Ctx, call: Expr, args: [dynamic]Expr) -> ^Type {
			return new_result_type(new_infer_var(ctx), infer_expr(ctx, args[0]))
		},
	},
	{
		name = "длина",
		arity = 1,
		handler = proc(ctx: ^Type_Ctx, call: Expr, args: [dynamic]Expr) -> ^Type {
			arg_type := prune_type(infer_expr(ctx, args[0]))
			if arg_type.kind == .String || arg_type.kind == .Array || arg_type.kind == .Map {
				return TY_NUM
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

OPTION_METHODS := [?]Method_Sig {
	{
		name = "есть",
		arity = 0,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {return TY_BOOL},
	},
	{
		name = "пусто",
		arity = 0,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {return TY_BOOL},
	},
	{
		name = "значение",
		arity = 0,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {
			return prune_type(receiver_type.element_type)
		},
	},
	{
		name = "получить",
		arity = 1,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {
			check_expr(ctx, args[0], receiver_type.element_type)
			return prune_type(receiver_type.element_type)
		},
	},
	{
		name = "запас",
		arity = 1,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {
			fallback_type := prune_type(infer_expr(ctx, args[0]))
			if fallback_type.kind != .Option {
				report(
					ctx,
					expr_span(call),
					"Type Error: Опция.запас() ожидает Опцию, получен '%s'",
					fallback_type.name,
				)
			} else if !unify_types(receiver_type.element_type, fallback_type.element_type) {
				report(
					ctx,
					expr_span(call),
					"Type Error: Опция.запас() ожидает Опцию(%s), получен '%s'",
					prune_type(receiver_type.element_type).name,
					fallback_type.name,
				)
			}
			return new_option_type(prune_type(receiver_type.element_type))
		},
	},
	{
		name = "ожидать",
		arity = 1,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {
			check_expr(ctx, args[0], TY_STRING)
			return prune_type(receiver_type.element_type)
		},
	},
	{
		name = "результат_или",
		arity = 1,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {
			error_type := infer_expr(ctx, args[0])
			return new_result_type(prune_type(receiver_type.element_type), prune_type(error_type))
		},
	},
	{
		name = "заменить_значение",
		arity = 1,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {
			element_type := infer_expr(ctx, args[0])
			return new_option_type(prune_type(element_type))
		},
	},
}

RESULT_METHODS := [?]Method_Sig {
	{
		name = "успех",
		arity = 0,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {return TY_BOOL},
	},
	{
		name = "ошибка",
		arity = 0,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {return TY_BOOL},
	},
	{
		name = "значение",
		arity = 0,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {
			return prune_type(receiver_type.ok_type)
		},
	},
	{
		name = "причина",
		arity = 0,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {
			return prune_type(receiver_type.error_type)
		},
	},
	{
		name = "получить",
		arity = 1,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {
			check_expr(ctx, args[0], receiver_type.ok_type)
			return prune_type(receiver_type.ok_type)
		},
	},
	{
		name = "получить_ошибку",
		arity = 1,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {
			check_expr(ctx, args[0], receiver_type.error_type)
			return prune_type(receiver_type.error_type)
		},
	},
	{
		name = "запас",
		arity = 1,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {
			fallback_type := prune_type(infer_expr(ctx, args[0]))
			if fallback_type.kind != .Result {
				report(
					ctx,
					expr_span(call),
					"Type Error: Результат.запас() ожидает Результат, получен '%s'",
					fallback_type.name,
				)
				return new_result_type(prune_type(receiver_type.ok_type), prune_type(receiver_type.error_type))
			}
			if !unify_types(receiver_type.ok_type, fallback_type.ok_type) {
				report(
					ctx,
					expr_span(call),
					"Type Error: Результат.запас() ожидает Результат(%s, ...), получен '%s'",
					prune_type(receiver_type.ok_type).name,
					fallback_type.name,
				)
			}
			return new_result_type(
				prune_type(receiver_type.ok_type),
				prune_type(fallback_type.error_type),
			)
		},
	},
	{
		name = "ожидать",
		arity = 1,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {
			check_expr(ctx, args[0], TY_STRING)
			return prune_type(receiver_type.ok_type)
		},
	},
	{
		name = "ожидать_ошибку",
		arity = 1,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {
			check_expr(ctx, args[0], TY_STRING)
			return prune_type(receiver_type.error_type)
		},
	},
	{
		name = "опция",
		arity = 0,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {
			return new_option_type(prune_type(receiver_type.ok_type))
		},
	},
	{
		name = "ошибка_опция",
		arity = 0,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {
			return new_option_type(prune_type(receiver_type.error_type))
		},
	},
	{
		name = "заменить_значение",
		arity = 1,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {
			ok_type := infer_expr(ctx, args[0])
			return new_result_type(prune_type(ok_type), prune_type(receiver_type.error_type))
		},
	},
	{
		name = "заменить_ошибку",
		arity = 1,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {
			error_type := infer_expr(ctx, args[0])
			return new_result_type(prune_type(receiver_type.ok_type), prune_type(error_type))
		},
	},
}

FILE_METHODS := [?]Method_Sig {
	{
		name = "прочитать",
		arity = 0,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {
			return new_result_type(TY_STRING, TY_ERROR)
		},
	},
	{
		name = "прочитать_строку",
		arity = 0,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {
			return new_result_type(TY_STRING, TY_ERROR)
		},
	},
	{
		name = "записать",
		arity = 1,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {
			check_expr(ctx, args[0], TY_STRING)
			return new_result_type(TY_NUM, TY_ERROR)
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
			return new_result_type(TY_STRING, TY_ERROR)
		},
	},
	{
		name = "получить_строку",
		arity = 0,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {
			return new_result_type(TY_STRING, TY_ERROR)
		},
	},
	{
		name = "отправить",
		arity = 1,
		handler = proc(ctx: ^Type_Ctx, call: Expr, receiver_type: ^Type, args: [dynamic]Expr) -> ^Type {
			check_expr(ctx, args[0], TY_STRING)
			return new_result_type(TY_NUM, TY_ERROR)
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
	case .Option:
		method_list = OPTION_METHODS[:]
	case .Result:
		method_list = RESULT_METHODS[:]
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
		if !unify_types(actual, expected[i]) {
			report(
				ctx,
				expr_span(arg),
				"Type Error: у варианта '%s.%s' поле #%d ожидает '%s', получено '%s'",
				owner_type.name,
				resolve_interned(sym.name),
				i,
				prune_type(expected[i]).name,
				prune_type(actual).name,
			)
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
		if left_t == TY_STRING && right_t == TY_STRING {
			t = TY_STRING
		} else if left_t == TY_NUM && right_t == TY_NUM {
			t = TY_NUM
		} else if left_t.kind == .Poison || right_t.kind == .Poison {
			// Прямое `==` сравнение выше не поймает Poison (не unify_types) —
			// без явного шорт-каута отчитались бы производной ошибкой поверх
			// уже отчитанной первопричины.
			t = TY_POISON
		} else {
			t = report(
				ctx,
				e.span,
				"Type Error: оператор '+' ожидает два числа или две строки, получено '%s' и '%s'",
				left_t.name,
				right_t.name,
			)
		}
	case .Minus, .Star, .Slash:
		check_expr(ctx, e.left, TY_NUM)
		check_expr(ctx, e.right, TY_NUM)
		t = TY_NUM

	case .Less, .Greater:
		check_expr(ctx, e.left, TY_NUM)
		check_expr(ctx, e.right, TY_NUM)
		t = TY_BOOL

	case .And, .Or:
		check_expr(ctx, e.left, TY_BOOL)
		check_expr(ctx, e.right, TY_BOOL)
		t = TY_BOOL

	case .Equal, .NotEqual:
		left_t := infer_expr(ctx, e.left)
		right_t := infer_expr(ctx, e.right)
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

	case .Assign:
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
		check_expr(ctx, e.right, TY_NUM)
		t = TY_NUM
	case .Negate:
		check_expr(ctx, e.right, TY_BOOL)
		t = TY_BOOL
	}
	return t
}

infer_call_expr :: proc(ctx: ^Type_Ctx, expr: Expr, e: ^Call_Expr) -> ^Type {
	callee_sym := ctx.res.node_symbols[e.callee]
	if callee_sym != INVALID_SYMBOL && symbol_at(ctx.res.symbol_store, callee_sym).kind == .Enum_Variant {
		return resolve_variant_ctor(ctx, expr, callee_sym, e.args[:], true)
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

				export_type, found_type := ctx.res.symbol_types[export_sym_id]
				if !found_type || export_type == nil {
					if export_sym.kind == .Builtin {
						export_type = builtin_export_type(resolve_interned(export_sym.full_name))
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
				#partial switch export_type.kind {
				case .Function:
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
				return TY_NUM
			case "добавить":
				if len(e.args) != 1 do return report(ctx, e.span, "Type Error: массив.добавить() ожидает 1 аргумент")
				check_expr(ctx, e.args[0], obj_type.element_type)
				ctx.call_infos[expr] = Call_Info{kind = .Method_Collection, text_name = prop_expr.property}
				return TY_VOID
			case "получить":
				if len(e.args) != 2 do return report(ctx, e.span, "Type Error: массив.получить() ожидает индекс и значение по умолчанию")
				check_expr(ctx, e.args[0], TY_NUM)
				check_expr(ctx, e.args[1], obj_type.element_type)
				ctx.call_infos[expr] = Call_Info{kind = .Method_Collection, text_name = prop_expr.property}
				return obj_type.element_type
			case "есть":
				if len(e.args) != 1 do return report(ctx, e.span, "Type Error: массив.есть() ожидает индекс")
				check_expr(ctx, e.args[0], TY_NUM)
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
				return TY_NUM
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
			if method_sym, is_method := obj_type.methods[prop_expr.property]; is_method {
				method_type := ctx.res.symbol_types[method_sym]
				if len(e.args) != len(method_type.params) - 1 {
					return report(
						ctx,
						e.span,
						"У метода %s ожидалось %d аргументов",
						resolve_interned(symbol_at(ctx.res.symbol_store, method_sym).name),
						len(method_type.params) - 1,
					)
				}
				check_expr(ctx, prop_expr.object, method_type.params[0])
				for arg, i in e.args do check_expr(ctx, arg, method_type.params[i + 1])

				ctx.call_infos[expr] = Call_Info{kind = .Method_Struct, symbol_ref = method_sym}
				return prune_type(method_type.return_type)
			}
		} else if obj_type.kind == .Enum {
			// Тот же путь диспетчеризации, что у Struct (.Method_Struct —
			// имя историческое, кодогенерация в compiler.odin трактует его
			// как "обычный вызов функции с receiver'ом первым аргументом",
			// получателю всё равно, Aggregate_Value это или Variant_Value).
			if method_sym, is_method := obj_type.methods[prop_expr.property]; is_method {
				method_type := ctx.res.symbol_types[method_sym]
				if len(e.args) != len(method_type.params) - 1 {
					return report(
						ctx,
						e.span,
						"У метода %s ожидалось %d аргументов",
						resolve_interned(symbol_at(ctx.res.symbol_store, method_sym).name),
						len(method_type.params) - 1,
					)
				}
				check_expr(ctx, prop_expr.object, method_type.params[0])
				for arg, i in e.args do check_expr(ctx, arg, method_type.params[i + 1])

				ctx.call_infos[expr] = Call_Info{kind = .Method_Struct, symbol_ref = method_sym}
				return prune_type(method_type.return_type)
			}
		} else if obj_type.kind == .Interface {
			if method_type, exists := obj_type.interface_methods[prop_expr.property]; exists {
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
		}
	}

	callee_type := prune_type(infer_expr(ctx, e.callee))
	if callee_type.kind == .Struct {
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

	} else if callee_type.kind == .Function {
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
		then_type := infer_block_type(ctx, e.then_branch)
		else_type := infer_block_type(ctx, e.else_branch)

		if !unify_types(then_type, else_type) {
			report(
				ctx,
				e.span,
				"Type Error: ветки 'если' возвращают разные типы. 'тогда' -> '%s', 'иначе' -> '%s'",
				prune_type(then_type).name,
				prune_type(else_type).name,
			)
		}
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
	element_type := infer_expr(ctx, e.elements[0])
	for el, i in e.elements {
		current_type := infer_expr(ctx, el)
		if i > 0 && !unify_types(current_type, element_type) {
			report(
				ctx,
				expr_span(el),
				"Type Error: элементы массива имеют разные типы: '%s' и '%s'",
				prune_type(element_type).name,
				prune_type(current_type).name,
			)
		}
	}
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
	key_type := infer_expr(ctx, e.entries[0].key)
	value_type := infer_expr(ctx, e.entries[0].value)
	for entry, i in e.entries {
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
		if i > 0 {
			if !unify_types(current_key_type, key_type) {
				report(
					ctx,
					expr_span(entry.key),
					"Type Error: ключи соответствия имеют разные типы: '%s' и '%s'",
					prune_type(key_type).name,
					prune_type(current_key_type).name,
				)
			}
			if !unify_types(current_value_type, value_type) {
				report(
					ctx,
					expr_span(entry.value),
					"Type Error: значения соответствия имеют разные типы: '%s' и '%s'",
					prune_type(value_type).name,
					prune_type(current_value_type).name,
				)
			}
		}
	}
	return new_map_type(prune_type(key_type), prune_type(value_type))
}

infer_index_expr :: proc(ctx: ^Type_Ctx, expr: Expr, e: ^Index_Expr) -> ^Type {
	t: ^Type
	obj_type := prune_type(infer_expr(ctx, e.object))
	if obj_type.kind == .Array {
		check_expr(ctx, e.index, TY_NUM)
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
		check_expr(ctx, e.index, TY_NUM)
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
	subject_type_actual := prune_type(infer_expr(ctx, e.subject))
	subject_type := subject_type_actual
	if subject_type.kind == .Option || subject_type.kind == .Result {
		subject_type = synth_enum_view(ctx, subject_type_actual)
	}
	if subject_type.kind != .Enum {
		// Возвращаем сразу — иначе классификация каждой ветки ниже полезет
		// в classify_pattern с невалидным subject_type и продублирует эту
		// же ошибку на каждую ветку.
		return report(
			ctx,
			e.span,
			"Type Error: выбор ожидает значение перечисления, Опции или Результата, получено '%s'",
			subject_type_actual.name,
		)
	}
	arm_infos := make([dynamic]Pattern_Info)
	result_t: ^Type
	for arm in e.arms {
		pi := classify_pattern(ctx, arm.pattern, subject_type_actual)
		append(&arm_infos, pi)

		// Тело ветки
		body_t: ^Type
		for stmt, i in arm.body {
			is_last := i == len(arm.body) - 1
			if is_last {
				if expr_stmt, ok := stmt.(^Expr_Stmt); ok {
					body_t = prune_type(infer_expr(ctx, expr_stmt.expr))
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
			} else if !unify_types(body_t, result_t) {
				report(
					ctx,
					arm.span,
					"Type Error: ветки выбора возвращают разные типы: '%s' vs '%s'",
					prune_type(result_t).name,
					prune_type(body_t).name,
				)
			}
		}
	}
	if result_t == nil do result_t = TY_NEVER
	ctx.match_arm_infos[e] = arm_infos
	check_match_coverage(ctx, e.span, subject_type, arm_infos)
	return prune_type(result_t)
}

infer_try_expr :: proc(ctx: ^Type_Ctx, expr: Expr, e: ^Try_Expr) -> ^Type {
	t: ^Type
	value_type := prune_type(infer_expr(ctx, e.value))
	if value_type.kind == .Option {
		return_type := prune_type(ctx.current_return)
		if return_type == nil || return_type.kind != .Option {
			report(
				ctx,
				e.span,
				"Type Error: оператор '?' для Опции можно использовать только в функции, возвращающей Опцию",
			)
		}
		t = prune_type(value_type.element_type)
	} else if value_type.kind == .Result {
		return_type := prune_type(ctx.current_return)
		if return_type == nil || return_type.kind != .Result {
			report(
				ctx,
				e.span,
				"Type Error: оператор '?' можно использовать только в функции, возвращающей Результат",
			)
		} else if !unify_types(value_type.error_type, return_type.error_type) {
			report(
				ctx,
				e.span,
				"Type Error: оператор '?' возвращает ошибку типа '%s', но функция ожидает '%s'",
				prune_type(value_type.error_type).name,
				prune_type(return_type.error_type).name,
			)
		}
		t = prune_type(value_type.ok_type)
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
					bt := builtin_export_type(resolve_interned(export_sym.full_name))
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

	} else if obj_type.kind == .Option || obj_type.kind == .Result {
		return report(
			ctx,
			e.span,
			"Type Error: метод '%s' нужно вызвать через ()",
			e.property,
		)

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
