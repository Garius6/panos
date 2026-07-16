package core

// Опция(T)/Результат(T,E) — обычные generic-enum'ы (не хардкод Type_Kind),
// объявленные здесь и неявно доступные КАЖДОМУ модулю без "импорт":
// единственный способ сохранить их "всегда под рукой", раз panos не сливает
// имена импортированного модуля в scope (см. resolve_module ниже).
//
// Embedded-строка, не файл на диске — panos file.ps должен работать
// независимо от текущей директории/установки, без поиска "где лежит stdlib".
//
// Тег-порядок вариантов (Нет=0/Есть=1, Успех=0/Неудача=1) фиксирован —
// vm.odin предполагает его для variant_tag/variant_field.
PRELUDE_SOURCE :: `
экспорт тип Опция[T] = перечисление
	Нет
	Есть(T)
конец

экспорт тип Результат[T, E] = перечисление
	Успех(T)
	Неудача(E)
конец

// Стадия 22: сравнить возвращает Число по конвенции
// отрицательное/0/положительное — переиспользует существующие числовые
// опкоды для </>/<=/>= вместо нового рантайм-представления сравнения.
экспорт тип Сравниваемое = интерфейс
	функ сравнить(другое: Сравниваемое) -> Число
конец

// Опционален (opt-in override) — структурное == уже работает на любых
// типах (value_equals, vm.odin), Равнозначное переопределяет его для
// типов, которым дефолт не подходит.
экспорт тип Равнозначное = интерфейс
	функ равно(другое: Равнозначное) -> Булево
конец

// Стадия 23: Арифметика — 4 раздельных интерфейса (не один, как
// Сравниваемое), потому что +/-/*// мат. независимы друг от друга —
// тип может поддерживать сложение без деления (вектор без деления на
// вектор). Self-тип (параметр и возврат) — тот же механизм, что у
// Сравниваемое.сравнить.
экспорт тип Складываемое = интерфейс
	функ сложить(другое: Складываемое) -> Складываемое
конец

экспорт тип Вычитаемое = интерфейс
	функ вычесть(другое: Вычитаемое) -> Вычитаемое
конец

экспорт тип Умножаемое = интерфейс
	функ умножить(другое: Умножаемое) -> Умножаемое
конец

экспорт тип Делимое = интерфейс
	функ разделить(другое: Делимое) -> Делимое
конец

// Стадия 23: Печатаемое — opt-in override форматирования (тот же принцип,
// что Равнозначное: дефолт есть без неё — structural-дамп полей, живёт в
// vm.odin's value_to_display_string, зеркалит value_equals). Только Self-
// ПАРАМЕТР (неявный receiver) — возврат Строка, не Self, так что фикс
// Стадии 23 под Self-возврат тут не участвует.
экспорт тип Печатаемое = интерфейс
	функ вСтроку() -> Строка
конец

// Стадия 23: Копируемое — единственный способ получить независимую
// копию структуры (panos структуры reference semantics по умолчанию,
// присваивание копирует указатель, не поля). НЕ operator sugar (в
// отличие от Сравниваемое/Равнозначное/Арифметики) — .клонировать()
// обычный прямой вызов метода, работает через уже существующий generic
// interface-dispatch (Стадия 6) без единой строчки нового кода в
// type_cheker.odin/compiler.odin — Self-возврат уже покрыт фиксом,
// добавленным для Арифметики (interface_method_types_match). "Глубокая
// копия" — НЕ auto-derive (как и у всех прочих интерфейсов, тело метода
// пишется руками): чтобы клон был действительно глубоким, тело обязано
// САМО рекурсивно звать .клонировать() на вложенных struct-полях, а не
// просто копировать их как есть (иначе получится поверхностная копия
// с расшаренными вложенными структурами).
экспорт тип Копируемое = интерфейс
	функ клонировать() -> Копируемое
конец

реализация Опция
	функ есть(это: Опция) -> Булево
		выбор это
			Нет -> ложь
			Есть(_) -> истина
		конец
	конец

	функ пусто(это: Опция) -> Булево
		не это.есть()
	конец

	функ значение(это: Опция) -> T
		выбор это
			Есть(x) -> x
			Нет -> паника("нет значения")
		конец
	конец

	функ получить(это: Опция, запасное: T) -> T
		выбор это
			Есть(x) -> x
			Нет -> запасное
		конец
	конец

	функ запас(это: Опция, другая: Опция) -> Опция
		выбор это
			Есть(_) -> это
			Нет -> другая
		конец
	конец

	функ ожидать(это: Опция, сообщение: Строка) -> T
		выбор это
			Есть(x) -> x
			Нет -> паника(сообщение)
		конец
	конец

	функ результат_или[E](это: Опция, ошибка: E) -> Результат(T, E)
		выбор это
			Есть(x) -> Результат.Успех(x)
			Нет -> Результат.Неудача(ошибка)
		конец
	конец

	функ заменить_значение[U](это: Опция, новое: U) -> Опция(U)
		выбор это
			Есть(_) -> Опция.Есть(новое)
			Нет -> Опция.Нет()
		конец
	конец
конец

реализация Результат
	функ успех(это: Результат) -> Булево
		выбор это
			Успех(_) -> истина
			Неудача(_) -> ложь
		конец
	конец

	функ ошибка(это: Результат) -> Булево
		не это.успех()
	конец

	функ значение(это: Результат) -> T
		выбор это
			Успех(x) -> x
			Неудача(_) -> паника("нет значения")
		конец
	конец

	функ причина(это: Результат) -> E
		выбор это
			Неудача(e) -> e
			Успех(_) -> паника("нет ошибки")
		конец
	конец

	функ получить(это: Результат, запасное: T) -> T
		выбор это
			Успех(x) -> x
			Неудача(_) -> запасное
		конец
	конец

	функ получить_ошибку(это: Результат, запасное: E) -> E
		выбор это
			Неудача(e) -> e
			Успех(_) -> запасное
		конец
	конец

	функ запас(это: Результат, другой: Результат) -> Результат
		выбор это
			Успех(_) -> это
			Неудача(_) -> другой
		конец
	конец

	функ ожидать(это: Результат, сообщение: Строка) -> T
		выбор это
			Успех(x) -> x
			Неудача(_) -> паника(сообщение)
		конец
	конец

	функ ожидать_ошибку(это: Результат, сообщение: Строка) -> E
		выбор это
			Неудача(e) -> e
			Успех(_) -> паника(сообщение)
		конец
	конец

	функ опция(это: Результат) -> Опция
		выбор это
			Успех(x) -> Опция.Есть(x)
			Неудача(_) -> Опция.Нет()
		конец
	конец

	функ ошибка_опция(это: Результат) -> Опция
		выбор это
			Неудача(e) -> Опция.Есть(e)
			Успех(_) -> Опция.Нет()
		конец
	конец

	функ заменить_значение[U](это: Результат, новое: U) -> Результат(U, E)
		выбор это
			Успех(_) -> Результат.Успех(новое)
			Неудача(e) -> Результат.Неудача(e)
		конец
	конец

	функ заменить_ошибку[V](это: Результат, новая: V) -> Результат(T, V)
		выбор это
			Успех(x) -> Результат.Успех(x)
			Неудача(_) -> Результат.Неудача(новая)
		конец
	конец
конец
`

PRELUDE_MODULE_KEY :: "@prelude"
// u16-максимум — гарантированно не столкнётся с последовательными
// file_id обычных модулей (0, 1, 2, ...), в т.ч. в run_code'вском
// однократном графе, где file_id реальной программы — тоже 0.
PRELUDE_FILE_ID :: max(u16)

// Резолвит и типизирует прелюдию РОВНО ОДИН РАЗ на graph (мемоизация на
// graph.modules[PRELUDE_MODULE_KEY]) — важно для cross-module identity:
// если бы каждый модуль резолвил свою копию Опции, у них были бы РАЗНЫЕ
// Symbol_Id/^Type для "одного" типа, ломая unify_types между модулями.
ensure_prelude :: proc(graph: ^Module_Graph) -> ^Module {
	if existing, ok := graph.modules[PRELUDE_MODULE_KEY]; ok {
		return existing
	}

	tokens, lex_diags := tokenize(PRELUDE_SOURCE, PRELUDE_FILE_ID)
	for d in lex_diags do append(&graph.parse_diagnostics, d)
	stream := make_stream(tokens)
	defer destroy_stream(&stream)

	parser := Parser {
		stream  = &stream,
		file_id = PRELUDE_FILE_ID,
	}
	prog := parse_program(&parser)
	for d in parser.diagnostics do append(&graph.parse_diagnostics, d)

	module := new(Module)
	module.path = PRELUDE_MODULE_KEY
	module.dir = ""
	module.exports = make(map[Interned]Symbol_Id)
	module.file_id = PRELUDE_FILE_ID
	module.source = PRELUDE_SOURCE
	module.ast = prog

	graph.file_paths[PRELUDE_FILE_ID] = PRELUDE_MODULE_KEY
	graph.file_sources[PRELUDE_FILE_ID] = PRELUDE_SOURCE

	// Регистрируем ДО resolve_module: resolve_module для НЕ-прелюдийных
	// модулей сам вызывает ensure_prelude, а мемоизация выше делает
	// повторный вход no-op. Заодно защищает от рекурсии, если резолв самой
	// прелюдии где-то попытается её же и найти.
	graph.modules[PRELUDE_MODULE_KEY] = module

	// Хип-аллоцированы (не локальные) — ensure_prelude_compiled использует
	// эти res_ctx/tc_ctx ПОЗЖЕ, после возврата отсюда (компиляция методов
	// Опции/Результата в registry — отдельный этап), стековые указатели к
	// тому моменту были бы висячими.
	graph.prelude_res_ctx = new(Resolver_Ctx)
	graph.prelude_res_ctx^ = resolve_module(graph, module)
	for d in graph.prelude_res_ctx.diagnostics do append(&graph.parse_diagnostics, d)

	graph.prelude_tc_ctx = new(Type_Ctx)
	graph.prelude_tc_ctx^ = new_type_ctx(graph.prelude_res_ctx)
	typecheck_program(graph.prelude_tc_ctx, module.ast)
	for d in graph.prelude_tc_ctx.diagnostics do append(&graph.parse_diagnostics, d)

	// Копируем в graph.prelude_generic_order — без этого Опция(T)/
	// Результат(T,E) не резолвились бы как generic-типы ни в одном
	// пользовательском модуле (в их СОБСТВЕННОМ Type_Ctx это поле пустое,
	// т.к. Опция/Результат не объявлены в их AST).
	if graph.prelude_generic_order == nil {
		graph.prelude_generic_order = make(map[Symbol_Id][dynamic]^Type)
	}
	for sym, ordered in graph.prelude_tc_ctx.decl_type_param_order {
		graph.prelude_generic_order[sym] = ordered
	}
	// Копируем в graph.prelude_symbol_schemes — без этого методы Опции/
	// Результата (ожидать/результат_или/...) вызывались бы с НЕ-инстан-
	// цированным (шаблонным, зацементированным после первого вызова) T/E
	// в любом пользовательском модуле.
	if graph.prelude_symbol_schemes == nil {
		graph.prelude_symbol_schemes = make(map[Symbol_Id]Type_Scheme)
	}
	for sym, scheme in graph.prelude_tc_ctx.symbol_schemes {
		graph.prelude_symbol_schemes[sym] = scheme
	}
	graph.prelude_option_sym = module.exports[intern("Опция")]
	graph.prelude_result_sym = module.exports[intern("Результат")]
	graph.prelude_comparable_sym = module.exports[intern("Сравниваемое")]
	graph.prelude_equatable_sym = module.exports[intern("Равнозначное")]
	graph.prelude_addable_sym = module.exports[intern("Складываемое")]
	graph.prelude_subtractable_sym = module.exports[intern("Вычитаемое")]
	graph.prelude_multipliable_sym = module.exports[intern("Умножаемое")]
	graph.prelude_divisible_sym = module.exports[intern("Делимое")]
	graph.prelude_printable_sym = module.exports[intern("Печатаемое")]
	graph.prelude_copyable_sym = module.exports[intern("Копируемое")]

	// graph.symbol_types уже общий указатель на ту же map, что res_ctx.
	// symbol_types — типы Опции/Результата видны каждому следующему модулю.
	// Но graph.symbol_types САМ может быть nil на первом использовании графа
	// (ни один модуль ещё не резолвился) — синхронизируем явно, как делает
	// resolve_and_typecheck_all для обычных модулей.
	graph.symbol_types = graph.prelude_res_ctx.symbol_types

	return module
}

// Методы Опции/Результата — настоящие Impl_Decl в прелюдии, компилируются в
// Compiled_Function так же, как реализация пользовательской структуры. Нужно
// явно скомпилировать AST прелюдии в тот же registry, что и пользовательский
// код, и ОБЯЗАТЕЛЬНО ДО него: .Method_Struct-диспетчер (compile_expr) кладёт
// в байткод уже скомпилированный указатель на функцию (emit_constant(fn_ptr)),
// не отложенный лукап по имени — если тело пользовательской функции,
// вызывающее Опция.значение()/т.п., скомпилируется раньше прелюдии, реестр
// пуст и compile_expr падает с "метод не найден". Принимает res (не graph):
// resolve_program обнуляет module_graph после резолва, а res.prelude_res_ctx/
// prelude_tc_ctx (скопированы в merge_prelude_exports) переживают это.
// Повторный вызов безвреден (перезапись идентичным байткодом), но вызывающие
// зовут ровно один раз на compile-проход.
ensure_prelude_compiled :: proc(res: ^Resolver_Ctx, registry: ^map[string]^Compiled_Function) {
	prelude_res := res.prelude_res_ctx
	prelude_tc := res.prelude_tc_ctx
	compile_program(prelude_res, prelude_tc, &prelude_res.current_module.ast, registry)
}

// Сливает exports прелюдии напрямую в scope резолвящегося модуля (module.
// scope.symbols) — НЕ через .Module-обёртку обычного импорта: импорт в
// panos не сливает имена в scope, даёт только alias.Имя. Прелюдия должна
// быть доступна БЕЗ квалификации и без "импорт" (Опция(T), не
// прелюдия.Опция(T)) — единственный способ — прямая запись Symbol_Id в
// scope, как если бы пользователь сам объявил тип у себя в файле.
//
// module.variants (двухуровневая map вариантов) мержить НЕ нужно —
// Тип.Вариант резолвится через .module-поле САМОГО символа типа, который
// уже указывает на прелюдию независимо от того, откуда на него сослались.
merge_prelude_exports :: proc(ctx: ^Resolver_Ctx, graph: ^Module_Graph, module: ^Module, prelude: ^Module) {
	// prelude.exports содержит И типы (Опция/Результат), И их варианты
	// (Есть/Нет/Успех/Неудача — экспортированы для Тип.Вариант). В scope
	// льём ТОЛЬКО типы — варианты должны быть доступны исключительно через
	// Опция.Есть(...)/Результат.Успех(...); слияние вариантов в scope
	// сделало бы голый Есть(...)/Успех(...) снова резолвящимся.
	for name, sym in prelude.exports {
		if symbol_at(ctx.symbol_store, sym).kind != .Type do continue
		module.scope.symbols[name] = sym
	}
	ctx.prelude_option_sym = prelude.exports[intern("Опция")]
	ctx.prelude_result_sym = prelude.exports[intern("Результат")]
	ctx.prelude_comparable_sym = prelude.exports[intern("Сравниваемое")]
	ctx.prelude_equatable_sym = prelude.exports[intern("Равнозначное")]
	ctx.prelude_addable_sym = prelude.exports[intern("Складываемое")]
	ctx.prelude_subtractable_sym = prelude.exports[intern("Вычитаемое")]
	ctx.prelude_multipliable_sym = prelude.exports[intern("Умножаемое")]
	ctx.prelude_divisible_sym = prelude.exports[intern("Делимое")]
	ctx.prelude_printable_sym = prelude.exports[intern("Печатаемое")]
	ctx.prelude_copyable_sym = prelude.exports[intern("Копируемое")]
	// Копия graph.prelude_generic_order в САМ Resolver_Ctx — module_graph
	// не переживает resolve_program (resolved.module_graph = nil), а
	// decl_type_param_order должен пережить весь typecheck_program.
	ctx.prelude_generic_order = graph.prelude_generic_order
	ctx.prelude_symbol_schemes = graph.prelude_symbol_schemes
	// Копии для ensure_prelude_compiled — тот же мотив: module_graph
	// нулится, эти поля на Resolver_Ctx — нет.
	ctx.prelude_res_ctx = graph.prelude_res_ctx
	ctx.prelude_tc_ctx = graph.prelude_tc_ctx
}
