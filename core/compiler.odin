package core

import "core:fmt"
import "core:strings"

// Все heap-managed варианты Value (кроме f64/bool/^Compiled_Function —
// см. GC_State в gc.odin) встраивают GC_Header первым полем.
Aggregate_Value :: struct {
	header:   GC_Header,
	elements: [dynamic]Value, // В реальном продакшене лучше использовать фиксированный срез (slice)
}

Array_Value :: struct {
	header:   GC_Header,
	elements: [dynamic]Value,
}

Map_Entry_Value :: struct {
	key:   Value,
	value: Value,
}

Map_Value :: struct {
	header:  GC_Header,
	entries: [dynamic]Map_Entry_Value,
}

Error_Value :: struct {
	header:  GC_Header,
	// ^Panos_String, а не string — поля читаются/пишутся напрямую как
	// Panos-значения через Get_Property/Set_Property (см. vm.odin), должны
	// участвовать в mark/sweep как любой другой Value.string.
	code:    ^Panos_String,
	message: ^Panos_String,
}

Option_Value :: struct {
	header:    GC_Header,
	has_value: bool,
	value:     Value,
}

Result_Value :: struct {
	header: GC_Header,
	is_ok:  bool,
	value:  Value,
	error:  Value,
}

Interface_Value :: struct {
	header:  GC_Header,
	// Стадия 25: было ^Aggregate_Value — перечисления тоже могут
	// реализовывать интерфейсы, receiver может оказаться ^Variant_Value.
	// Value уже union из всех вариантов, ничего не меняется в остальных
	// потребителях (Invoke_Interface просто кладёт data на стек как есть).
	data:    Value,
	// VTable: связывает имя метода из контракта с реальной скомпилированной функцией
	methods: map[string]^Compiled_Function,
}

// Значение варианта пользовательского ADT (либо построенного через prelude
// Option/Result — см. plan/research). Хранит имя типа-владельца (для
// диагностики и печати), числовой индекс варианта (порядок объявления) и
// поля варианта.
Variant_Value :: struct {
	header:    GC_Header,
	type_name: string,
	tag_index: int,
	fields:    [dynamic]Value,
}

// File_Value/Socket_Value (фс/сеть builtin'ы) — определены в
// file_value_native.odin/file_value_wasm.odin (#+build split), не здесь.
// Причина: поля handle/socket типизированы ^os.File/net.TCP_Socket, а
// сам ИМПОРТ core:os падает compile-time panic'ом под js_wasm32 (браузер
// не может делать реальный ФС/сокеты) — см. заметку в ROADMAP про WASM-
// спайк.

// Стадия 24 (actor model): собственные frames/stack — НЕ VM.frames/
// VM.stack напрямую. Планировщик перед вызовом execute() свопает
// vm.frames/vm.stack на process.frames/process.stack (дешёво — dynamic
// array это заголовок ptr/len/cap, не копия данных), после — свопает
// обратно. CallFrame не хранит обратной ссылки на VM (vm.odin), так что
// frames независимо переносимы между процессами без правок в самих
// opcode-обработчиках execute(). mailbox — FIFO, простое поле, не
// отдельный gc_new'd объект (не первоклассное panos-значение, никогда
// не появляется на стеке само по себе — живёт и умирает вместе с
// владеющим Process_Value, как Map_Value.entries живёт внутри Map_Value,
// не как отдельный аллоцированный объект). is_alive=false после
// Completed (см. VM.processes) — тихий no-op при отправить() на мёртвый
// процесс, GC собирает Process_Value, когда последний хэндл на него
// исчезает.
Process_Value :: struct {
	header:   GC_Header,
	id:       int,
	mailbox:  [dynamic]Value,
	frames:   [dynamic]CallFrame,
	stack:    [dynamic]Value,
	is_alive: bool,
	// Свежеспавненный процесс ЕЩЁ НЕ выполнялся ни разу — планировщик
	// обязан дать ему хотя бы один execute()-вызов, даже если mailbox
	// пуст (тело процесса может не начинаться с получить() вообще).
	// После первого execute() has_run=true — дальше пустой mailbox уже
	// значит "действительно нечего делать", не "ещё не стартовал".
	has_run:  bool,
	// Стадия 38 (monitor): кто наблюдает за МОИМ завершением — на смерть
	// (штатную или краш) рассылаем сигнал каждому отсюда (notify_watchers,
	// vm.odin). signals — МОЯ входящая очередь DOWN-уведомлений (получить_
	// сигнал() читает отсюда) — отдельный канал от mailbox (см. ROADMAP
	// §Стадия 38, п.3 — типизированный mailbox не годится для сигналов
	// другого типа).
	watchers: [dynamic]^Process_Value,
	signals:  [dynamic]Value,
	// Стадия 44 (link): двусторонний список — связать(A, B) добавляет
	// B в A.links И A в B.links. В отличие от watchers (только
	// уведомление), крах ЛЮБОЙ стороны (не штатное завершение — см.
	// terminate_process, vm.odin) каскадно завершает и другую.
	links:    [dynamic]^Process_Value,
}

Value :: union {
	f64,
	bool,
	^Panos_String,
	^Compiled_Function,
	^Aggregate_Value,
	^Array_Value,
	^Map_Value,
	^Error_Value,
	^Option_Value,
	^Result_Value,
	^Interface_Value,
	^Variant_Value,
	^File_Value,
	^Socket_Value,
	^Process_Value,
	^Foreign_Function,
	^Closure_Value,
	^Pointer_Value,
}

// Стадия 49 (FFI): рантайм-представление Указатель(T) — opaque raw
// pointer из/в внешний код. `owned` — Стадия 49's default-safe владение:
// true ТОЛЬКО если `внешний`-декларация явно пометила возврат `свой`
// (см. Foreign_Decl.return_owned, parser.odin) — pool_release (gc.odin)
// вызывает libc free() лишь в этом случае. GC-managed (заголовок нужен
// для finalizer-паттерна, тот же приём, что File_Value/Socket_Value) —
// сам `ptr` panos не разыменовывает и не сканирует (T фантомный).
Pointer_Value :: struct {
	header: GC_Header,
	ptr:    rawptr,
	owned:  bool,
}

// Стадия 48 (замыкания, value-capture): лямбда + снапшот значений,
// захваченных из окружающего scope в МОМЕНТ построения (.Build_Closure,
// см. Opcode) — НЕ общая ячейка с внешней функцией, копия. GC-managed
// (в отличие от ^Compiled_Function, который лежит в глобальном реестре
// весь процесс) — captured может содержать heap-объекты (строки,
// массивы и т.п.), GC обязан их видеть через mark_value (gc.odin).
// `fn` — сама скомпилированная лямбда-функция (та же ^Compiled_Function,
// что раньше клался на стек напрямую константой); `captured` — значения
// в ПОРЯДКЕ ctx.res.lambda_captures[expr] — тот же порядок, что
// .Get_Captured'овские индексы внутри тела `fn`.
Closure_Value :: struct {
	header:   GC_Header,
	fn:       ^Compiled_Function,
	captured: [dynamic]Value,
}

// Стадия 47 (FFI-B): описание одного `внешний`-объявления, готовое к
// вызову через libffi. Живёт как обычная константа в Compiled_Function.
// constants (как и ^Compiled_Function для .Call), но САМ никогда не
// оказывается на стеке панос-значением — только читается опкодом
// .Call_Foreign напрямую из констант. cif — opaque rawptr (а не
// ^Ffi_Cif): compiler.odin общий для native/wasm сборок, а ffi_bindings.
// odin (реальный Ffi_Cif) — #+build !js. Готовится ЛЕНИВО и ОДИН РАЗ при
// первом реальном вызове (vm_ffi_native.odin), не на компиляции.
Foreign_Function :: struct {
	name:          string,
	fn_ptr:        rawptr,
	param_kinds:   []Foreign_Marshal_Kind,
	return_kind:   Foreign_Marshal_Kind,
	// Стадия 49: только когда return_kind == .Pointer — см.
	// Foreign_Decl.return_owned/`свой` (parser.odin).
	return_owned:  bool,
	// Стадия 51: nil-элемент, если соответствующий param_kinds[i] != .
	// Struct; ^Type владеющей ff_структура иначе (несёт ffi_field_kinds/
	// ffi_composite/ffi_offsets — см. type_cheker.odin). Аналогично
	// return_struct_type для возврата.
	param_struct_types: []^Type,
	return_struct_type: ^Type,
	cif:           rawptr,
	cif_ready:     bool,
}

Compiled_Function :: struct {
	name:          string,
	instructions:  [dynamic]u8,
	constants:     [dynamic]Value,
	frame_size:    int,
	returns_value: bool,
}

Local :: struct {
	symbol: Symbol_Id, // Берем из Resolver_Ctx
	depth:  int,
}

Loop_Context :: struct {
	continue_target: int,
	break_jumps:     [dynamic]int,
}

symbol_registry_key :: proc(store: ^Symbol_Store, id: Symbol_Id) -> string {
	if id == INVALID_SYMBOL do return ""
	sym := symbol_at(store, id)
	// Interned(0) зарезервирован под "" — отличает заданный full_name от незаполненного.
	if sym.full_name != Interned(0) do return resolve_interned(sym.full_name)
	return resolve_interned(sym.name)
}

// Стадия 48 (замыкания): эмитит код, кладущий ТЕКУЩЕЕ значение символа
// sym_id на стек. Общая логика для ДВУХ мест: (1) обычная компиляция
// Ident_Expr внутри тела (ctx = тот l_ctx, что компилирует ЭТО тело —
// может сам быть лямбдой со своими captures), и (2) построение
// .Build_Closure ВО ВНЕШНЕМ контексте — получить значение символа
// ПЕРЕД тем, как оно скопируется в captured (снапшот). Порядок
// проверки: собственный локал (Get_Local) → собственный upvalue, если
// ctx сам сейчас компилирует лямбду с captures (Get_Captured, случай
// вложенной лямбда-в-лямбде — сам символ мог быть чужим upvalue) →
// глобальная функция из реестра (константа, как раньше).
compile_symbol_value_ref :: proc(ctx: ^Compiler, sym_id: Symbol_Id) {
	#reverse for loc, i in ctx.locals {
		if loc.symbol == sym_id {
			emit_opcode(ctx, .Get_Local)
			emit_byte(ctx, u8(i))
			return
		}
	}
	for cap_sym, i in ctx.captures {
		if cap_sym == sym_id {
			emit_opcode(ctx, .Get_Captured)
			emit_byte(ctx, u8(i))
			return
		}
	}
	if fn_ptr, ok := ctx.registry^[symbol_registry_key(ctx.res.symbol_store, sym_id)]; ok {
		emit_constant(ctx, Value(fn_ptr))
		return
	}
	fmt.panicf(
		"Compiler Error: символ '%s' не найден",
		resolve_interned(symbol_at(ctx.res.symbol_store, sym_id).name),
	)
}

Compiler :: struct {
	registry:         ^map[string]^Compiled_Function, // Указатель на глобальный реестр
	current_function: ^Compiled_Function,
	tc:               ^Type_Ctx,
	res:              ^Resolver_Ctx,
	locals:           [dynamic]Local,
	loops:            [dynamic]Loop_Context,
	scope_depth:      int,
	// Стадия 48 (замыкания): пусто для обычных функций/методов.
	// Заполняется при построении l_ctx для лямбды — копия
	// ctx.res.lambda_captures[expr] (тот же порядок, что .Get_Captured
	// индексы внутри тела И .Build_Closure-пуш во внешнем контексте).
	captures:         [dynamic]Symbol_Id,
}

new_compiler :: proc(res: ^Resolver_Ctx, name: string) -> Compiler {

	c := Compiler {
		res         = res,
		locals      = make([dynamic]Local),
		loops       = make([dynamic]Loop_Context),
		scope_depth = 0,
	}
	return c
}

Opcode :: enum u8 {
	Constant, // Операнд: 1 байт (индекс в пуле констант)
	Add, // Без операндов
	Subtract,
	Multiply,
	Divide,
	Less,
	Greater,
	Equal,
	Negate,
	Get_Local, // Операнд: 1 байт (индекс слота во фрейме)
	Set_Local, // Операнд: 1 байт (индекс слота во фрейме)
	Jump_If_False, // Операнд: 2 байта (смещение прыжка)
	Jump, // Операнд: 2 байта (смещение прыжка)
	Pop, // Удалить вершину стека
	Return, // Возврат из функции
	Call,
	Build_Aggregate, // Операнд: 1 байт (количество элементов)
	Set_Property,
	Get_Property, // Операнд: 1 байт (индекс поля)
	Cast_Interface,
	Invoke_Interface,
	Build_Array,
	Build_Map,
	Get_Index,
	Set_Index,
	Invoke_Collection,
	Call_Builtin,
	Try_Unwrap,
	Match_Tag, // Операнд: 1 байт (индекс константы с int-тегом). Читает вершину без снятия, кладёт bool.
	Get_Variant_Field, // Операнд: 1 байт (индекс поля). Снимает variant, кладёт значение поля.
	Match_Fail, // Без операнда. Runtime-трап при недостижимом промахе `выбор`.
	Build_Variant, // Операнды: 3 байта (type_name_const, tag, arity). Снимает arity полей, кладёт ^Variant_Value.
	Spawn, // Операнд: 1 байт (arg_count). Стек: fn, arg1..argN (как .Call). Не выполняет callee — создаёт новый Process_Value, кладёт его как handle.
	Receive, // Без операндов. Если mailbox текущего процесса пуст — .Suspended (ip не двигается). Иначе снимает первое сообщение (FIFO), кладёт на стек.
	Int_Divide, // Целое/Целое: усечение к нулю (в отличие от .Divide — обычное деление). Выбор опкода — на компиляторе (ctx.tc.node_types), рантайм-представление то же f64.
	Modulo, // Остаток от Int_Divide — тот же принцип усечения, знак следует делимому.
	Receive_Signal, // Стадия 38: без операндов. Если очередь сигналов текущего процесса пуста — .Suspended (ip не двигается). Иначе снимает первый сигнал (Целое, Опция(Строка)), кладёт на стек.
	Call_Foreign, // Стадия 47 (FFI-B): операнды — 1 байт (индекс константы с ^Foreign_Function), 1 байт (arg_count). Стек: arg1..argN (без callee-значения, в отличие от .Call — ^Foreign_Function не пользовательское значение). Маршаллинг через libffi — см. vm_ffi_native.odin/vm_ffi_wasm.odin.
	Build_Closure, // Стадия 48 (замыкания): операнды — 1 байт (индекс константы с ^Compiled_Function лямбды), 1 байт (capture_count). Снимает capture_count значений со стека (в порядке ctx.res.lambda_captures[expr]), строит ^Closure_Value, кладёт на стек.
	Get_Captured, // Стадия 48: операнд — 1 байт (индекс в frame.closure.captured). Кладёт значение на стек. Валиден только внутри тела лямбды, скомпилированной с captures.
	// Битовые операторы — только Целое (typechecker уже проверил, см.
	// infer_binary_expr/infer_unary_expr в type_cheker.odin), рантайм-
	// представление то же f64: VM конвертирует в i64, делает битовую
	// операцию, конвертирует обратно (см. vm.odin).
	BitAnd,
	BitOr,
	BitXor,
	BitNot,
	ShiftLeft,
	ShiftRight,
}

// Записать 1 байт в массив инструкций
emit_byte :: proc(c: ^Compiler, byte: u8) {
	append(&c.current_function.instructions, byte)
}

// Записать опкод
emit_opcode :: proc(c: ^Compiler, op: Opcode) {
	emit_byte(c, u8(op))
}

// Стадия 47 (FFI-B): ^Foreign_Function строится один раз на ^Foreign_Decl
// (кэш в d.compiled_fn) — все call-сайты одной и той же decl переиспользуют
// один и тот же дескриптор. ffi_prep_cif здесь НЕ вызывается (см.
// Foreign_Function) — только на native-стороне, лениво, при первом
// реальном .Call_Foreign в VM.
get_or_build_foreign_function :: proc(d: ^Foreign_Decl) -> ^Foreign_Function {
	if d.compiled_fn != nil {
		return (^Foreign_Function)(d.compiled_fn)
	}
	kinds := make([]Foreign_Marshal_Kind, len(d.params))
	struct_types := make([]^Type, len(d.params))
	for p, i in d.params {
		kinds[i] = p.marshal
		struct_types[i] = p.resolved_struct_type
	}
	ff := new(Foreign_Function)
	ff^ = Foreign_Function {
		name               = d.name,
		fn_ptr             = d.fn_ptr,
		param_kinds        = kinds,
		return_kind        = d.return_marshal,
		return_owned       = d.return_owned,
		param_struct_types = struct_types,
		return_struct_type = d.return_resolved_struct_type,
	}
	d.compiled_fn = ff
	return ff
}

// Возвращает индекс константы в пуле (без генерации опкода .Constant)
make_constant :: proc(c: ^Compiler, value: Value) -> u8 {
	append(&c.current_function.constants, value)
	idx := len(c.current_function.constants) - 1

	if idx > 255 {
		fmt.panicf(
			"Compiler Error: слишком много констант в одной функции!",
		)
	}
	return u8(idx)
}

// Сохранить константу и сгенерировать опкод для ее загрузки на стек
emit_constant :: proc(c: ^Compiler, value: Value) {
	idx := make_constant(c, value)
	emit_opcode(c, .Constant)
	emit_byte(c, idx)
}

// Генерирует опкод прыжка и 2 пустых байта для адреса.
// Возвращает индекс, куда потом нужно будет вписать правильный адрес.
emit_jump :: proc(c: ^Compiler, op: Opcode) -> int {
	emit_opcode(c, op)
	emit_byte(c, 0xff) // Фиктивный старший байт
	emit_byte(c, 0xff) // Фиктивный младший байт
	return len(c.current_function.instructions) - 2
}

// Вызывается после того, как тело блока скомпилировано.
// Вычисляет длину прыжка и "зашивает" ее поверх 0xFFFF.
patch_jump :: proc(c: ^Compiler, offset: int) {
	// Насколько далеко нужно прыгнуть (текущая длина минус адрес прыжка минус 2 байта операнда)
	jump_length := len(c.current_function.instructions) - offset - 2

	if jump_length > 65535 {
		fmt.panicf("Too much code to jump over!")
	}

	c.current_function.instructions[offset] = u8((jump_length >> 8) & 0xff) // Старший байт
	c.current_function.instructions[offset + 1] = u8(jump_length & 0xff) // Младший байт
}

patch_signed_jump_to :: proc(c: ^Compiler, offset: int, target: int) {
	jump_length := target - (offset + 2)
	if jump_length < -32768 || jump_length > 32767 {
		fmt.panicf("Too much code to jump over!")
	}
	c.current_function.instructions[offset] = u8((jump_length >> 8) & 0xff)
	c.current_function.instructions[offset + 1] = u8(jump_length & 0xff)
}

// Создаёт пустой Compiled_Function-скелет для sym и кладёт в registry —
// общий hoisting-паттерн для Function_Decl и методов Impl_Decl (ПРОХОД 1),
// позволяющий forward-вызовы (функция А зовёт Б, объявленную ниже).
hoist_compiled_function :: proc(
	res: ^Resolver_Ctx,
	tc: ^Type_Ctx,
	registry: ^map[string]^Compiled_Function,
	sym: Symbol_Id,
) {
	fn := new(Compiled_Function)
	fn.name = symbol_registry_key(res.symbol_store, sym)
	func_type := tc.res.symbol_types[sym]
	fn.returns_value = prune_type(func_type.return_type) != TY_VOID
	fn.instructions = make([dynamic]u8)
	fn.constants = make([dynamic]Value)
	registry^[fn.name] = fn
}

// Компилирует тело функции/метода sym в уже захостенный (ПРОХОД 1)
// Compiled_Function: строит Compiler, регистрирует locals по args_syms
// (func_args ключуется AST-узлом декларации, не Symbol_Id — отдельный
// параметр key), компилирует блок, эмиттит Return. Общий паттерн для
// Function_Decl и методов Impl_Decl (ПРОХОД 2).
compile_decl_body :: proc(
	registry: ^map[string]^Compiled_Function,
	tc: ^Type_Ctx,
	res: ^Resolver_Ctx,
	sym: Symbol_Id,
	key: Decls,
	body: [dynamic]Stmt,
) {
	ctx := Compiler {
		registry         = registry,
		current_function = registry^[symbol_registry_key(res.symbol_store, sym)],
		tc               = tc,
		res              = res,
		locals           = make([dynamic]Local),
	}
	if args_syms, ok := ctx.res.func_args[key]; ok {
		for s in args_syms do append(&ctx.locals, Local{symbol = s, depth = 0})
	}
	ctx.current_function.frame_size = len(ctx.locals)
	compile_block(&ctx, body, true)
	emit_opcode(&ctx, .Return)
}

compile_program :: proc(
	res: ^Resolver_Ctx,
	tc: ^Type_Ctx,
	program: ^Program,
	registry: ^map[string]^Compiled_Function = nil,
) -> map[string]^Compiled_Function {
	registry_ptr := registry
	if registry_ptr == nil {
		local_registry := make(map[string]^Compiled_Function)
		registry_ptr = &local_registry
	}

	// ПРОХОД 1: Выделяем память под функции (Hoisting)
	// Это позволит функции 'старт' вызывать функцию 'а', даже если 'а' объявлена ниже.
	for decl in program.decls {
		#partial switch d in decl {
		case ^Import_Decl:
		// Импорты не порождают исполняемый код.
		case ^Function_Decl:
			if len(d.type_param_bounds) > 0 do continue
			hoist_compiled_function(res, tc, registry_ptr, res.decl_symbols[decl])
		case ^Impl_Decl:
			for m in d.methods {
				hoist_compiled_function(res, tc, registry_ptr, res.decl_symbols[m])
			}
		}
	}

	// Bounded traits: ПОСЛЕ hoisting (клоны могут ссылаться указателем на
	// Compiled_Function обычных методов/функций — сам skeleton уже
	// существует, тело ещё нет, это не проблема, указатель стабилен), но
	// ДО обычного ПРОХОД 2 — иначе call site'ы bounded generic-функций (см.
	// ^Call_Expr-кейс в compile_expr) не найдут свою инстанциацию в
	// registry. Сами bounded generic Function_Decl исключены из pass 1/2
	// (len(d.type_param_bounds) > 0) — шаблон никогда не компилируется
	// напрямую, только клоны (core/monomorphize.odin).
	monomorphize_program(res, tc, registry_ptr)

	// ПРОХОД 2: Компиляция тел функций
	for decl in program.decls {
		#partial switch d in decl {
		case ^Function_Decl:
			if len(d.type_param_bounds) > 0 do continue
			compile_decl_body(registry_ptr, tc, res, res.decl_symbols[decl], decl, d.body)
		case ^Impl_Decl:
			for m in d.methods {
				compile_decl_body(registry_ptr, tc, res, res.decl_symbols[m], m, m.body)
			}
		}
	}

	return registry_ptr^ // Возвращаем только готовые функции!}
}

compile_decl :: proc(c: ^Compiler, decl: Decls) {
	#partial switch d in decl {
	case ^Import_Decl:
	case ^Impl_Decl:
	case ^Struct_Decl:
	case ^Interface_Decl:
	case ^Enum_Decl:
	// Компиляция уже произошла в type checker'е: тип и варианты
	// зарегистрированы. Байткод для конструкторов эмитится в местах
	// вызова (T016/T017), не здесь.

	case ^Function_Decl:
		function := new(Compiled_Function)
		function.name = d.name

		c.current_function = function

		for stmt in d.body {
			compile_statement(c, stmt)
		}

		c.registry^[function.name] = function
	}
}

compile_statement :: proc(ctx: ^Compiler, statement: Stmt) {
	switch stmt in statement {
	case ^Let_Stmt:
		if len(stmt.names) > 0 {
			// Деструктуризация (тупл или структура — оба Aggregate_Value,
			// .Get_Property по числовому индексу работает для обоих
			// одинаково, тот же приём, что for-in уже использует для
			// `для (a, b) в ...`, см. compile_for_in_stmt).
			compile_expr(ctx, stmt.value)
			value_slot := allocate_temp_slot(ctx, "__let_destructure")
			emit_opcode(ctx, .Set_Local)
			emit_byte(ctx, u8(value_slot))

			syms := ctx.res.let_destructure_syms[statement]
			// Стадия 37: field_indices[i] — реальный индекс поля для
			// syms[i] (тождественно i для позиционной формы, реальный
			// индекс по имени для именованной — см. Type_Ctx.let_
			// destructure_field_indices/infer_let_destructure_stmt).
			field_indices := ctx.tc.let_destructure_field_indices[statement]
			for sym, i in syms {
				binder_slot := register_binder_slot(ctx, sym)
				emit_opcode(ctx, .Get_Local)
				emit_byte(ctx, u8(value_slot))
				emit_opcode(ctx, .Get_Property)
				emit_byte(ctx, u8(field_indices[i]))
				emit_opcode(ctx, .Set_Local)
				emit_byte(ctx, u8(binder_slot))
			}
		} else {
			compile_expr(ctx, stmt.value)

			sym := ctx.res.stmt_symbols[stmt]
			append(&ctx.locals, Local{symbol = sym, depth = ctx.scope_depth})
			slot_index := len(ctx.locals) - 1

			ctx.current_function.frame_size = max(ctx.current_function.frame_size, len(ctx.locals))

			emit_opcode(ctx, .Set_Local)
			emit_byte(ctx, u8(slot_index))
		}

	case ^Return_Stmt:
		if stmt.value != nil {
			compile_expr(ctx, stmt.value)
		}
		emit_opcode(ctx, .Return)

	case ^Expr_Stmt:
		compile_expr(ctx, stmt.expr)
		if expr_type, ok := ctx.tc.node_types[stmt.expr]; !ok || expr_type != TY_VOID {
			emit_opcode(ctx, .Pop)
		}

	case ^Continue_Stmt:
		if len(ctx.loops) == 0 {
			fmt.panicf("Compiler Error: 'продолжить' вне цикла")
		}
		loop := ctx.loops[len(ctx.loops) - 1]
		continue_jump := emit_jump(ctx, .Jump)
		patch_signed_jump_to(ctx, continue_jump, loop.continue_target)

	case ^Break_Stmt:
		if len(ctx.loops) == 0 {
			fmt.panicf("Compiler Error: 'прервать' вне цикла")
		}
		break_jump := emit_jump(ctx, .Jump)
		append(&ctx.loops[len(ctx.loops) - 1].break_jumps, break_jump)

	case ^Error_Stmt:
		// Компилятор запускается только после typecheck_program с нулём
		// diagnostics (main.odin) — Error_Stmt сюда дойти не должен.
		fmt.panicf("Compiler Error: внутренняя ошибка — Error_Stmt дошёл до компиляции")

	case ^For_In_Stmt:
		compile_for_in_stmt(ctx, statement, stmt)
	}
}

// Стадия 23 (Итерируемое): For_In_Stmt НЕ десахарен parser'ом — сам
// решает форму (ctx.tc.for_in_infos[stmt]) и эмитит байткод напрямую,
// без синтетического AST (Let_Stmt/While_Expr/Match_Expr), которое раньше
// строил parser.odin. Обе формы используют Loop_Context (ctx.loops) тем
// же способом, что While_Expr (compile_expr, case ^While_Expr) —
// прервать/продолжить внутри тела работают идентично.
compile_for_in_stmt :: proc(ctx: ^Compiler, statement: Stmt, s: ^For_In_Stmt) {
	info, has_info := ctx.tc.for_in_infos[statement]
	if !has_info {
		fmt.panicf("Compiler Error: for_in_infos отсутствует для for-in")
	}

	names_syms := ctx.res.for_in_names_syms[statement]
	names_slots := make([dynamic]int, context.temp_allocator)
	for sym in names_syms {
		append(&names_slots, register_binder_slot(ctx, sym))
	}

	compile_expr(ctx, s.iterable)
	iter_slot := allocate_temp_slot(ctx, "__for_iter")
	emit_opcode(ctx, .Set_Local)
	emit_byte(ctx, u8(iter_slot))

	#partial switch info.kind {
	case .Fast_Array:
		emit_constant(ctx, f64(-1))
		idx_slot := allocate_temp_slot(ctx, "__for_idx")
		emit_opcode(ctx, .Set_Local)
		emit_byte(ctx, u8(idx_slot))

		loop_start := len(ctx.current_function.instructions)
		loop_ctx := Loop_Context {
			continue_target = loop_start,
			break_jumps     = make([dynamic]int),
		}
		append(&ctx.loops, loop_ctx)

		// __for_idx = __for_idx + 1
		emit_opcode(ctx, .Get_Local)
		emit_byte(ctx, u8(idx_slot))
		emit_constant(ctx, f64(1))
		emit_opcode(ctx, .Add)
		emit_opcode(ctx, .Set_Local)
		emit_byte(ctx, u8(idx_slot))

		// пока __for_idx != __for_iter.длина() (иначе — выход из цикла).
		// NotEqual, не Equal: Jump_If_False прыгает на exit, когда УСЛОВИЕ
		// ПРОДОЛЖЕНИЯ ложно (idx == длина) — тот же принцип, что уже
		// использует Match_Tag ниже в Iterator_Protocol-ветке (пушит
		// "матч?", Jump_If_False прыгает на fail/exit при НЕ-матче).
		emit_opcode(ctx, .Get_Local)
		emit_byte(ctx, u8(idx_slot))
		emit_opcode(ctx, .Get_Local)
		emit_byte(ctx, u8(iter_slot))
		emit_opcode(ctx, .Invoke_Collection)
		emit_byte(ctx, make_constant(ctx, Value(perm_string("длина"))))
		emit_byte(ctx, 0)
		emit_opcode(ctx, .Equal)
		emit_opcode(ctx, .Negate)
		exit_jump := emit_jump(ctx, .Jump_If_False)

		// пер <элемент(ы)> = __for_iter[__for_idx]
		emit_opcode(ctx, .Get_Local)
		emit_byte(ctx, u8(iter_slot))
		emit_opcode(ctx, .Get_Local)
		emit_byte(ctx, u8(idx_slot))
		emit_opcode(ctx, .Get_Index)
		if len(names_slots) == 1 {
			emit_opcode(ctx, .Set_Local)
			emit_byte(ctx, u8(names_slots[0]))
		} else {
			elem_slot := allocate_temp_slot(ctx, "__for_elem")
			emit_opcode(ctx, .Set_Local)
			emit_byte(ctx, u8(elem_slot))
			for slot, i in names_slots {
				emit_opcode(ctx, .Get_Local)
				emit_byte(ctx, u8(elem_slot))
				emit_opcode(ctx, .Get_Property)
				emit_byte(ctx, u8(i))
				emit_opcode(ctx, .Set_Local)
				emit_byte(ctx, u8(slot))
			}
		}

		for body_stmt in s.body do compile_statement(ctx, body_stmt)

		loop_jump := emit_jump(ctx, .Jump)
		patch_signed_jump_to(ctx, loop_jump, loop_start)

		patch_jump(ctx, exit_jump)
		finished_loop := ctx.loops[len(ctx.loops) - 1]
		for break_jump in finished_loop.break_jumps do patch_jump(ctx, break_jump)
		pop(&ctx.loops)

	case .Iterator_Protocol:
		fn_ptr, found := ctx.registry^[symbol_registry_key(ctx.res.symbol_store, info.next_method_sym)]
		if !found {
			fmt.panicf("Compiler Error: метод следующий не найден")
		}
		fn_const := make_constant(ctx, Value(fn_ptr))

		loop_start := len(ctx.current_function.instructions)
		loop_ctx := Loop_Context {
			continue_target = loop_start,
			break_jumps     = make([dynamic]int),
		}
		append(&ctx.loops, loop_ctx)

		// __for_iter.следующий()
		emit_opcode(ctx, .Constant)
		emit_byte(ctx, fn_const)
		emit_opcode(ctx, .Get_Local)
		emit_byte(ctx, u8(iter_slot))
		emit_opcode(ctx, .Call)
		emit_byte(ctx, 1)

		subject_slot := allocate_temp_slot(ctx, "__for_subject")
		emit_opcode(ctx, .Set_Local)
		emit_byte(ctx, u8(subject_slot))

		// выбор __for_subject { Есть(x) -> <тело>; Нет -> прервать }
		// Тег Есть=1 (см. prelude.odin) — Match_Tag/Get_Variant_Field, те
		// же опкоды, что использует компиляция `выбор` (compile_pattern),
		// без синтетического Match_Expr узла.
		emit_opcode(ctx, .Get_Local)
		emit_byte(ctx, u8(subject_slot))
		emit_opcode(ctx, .Match_Tag)
		emit_byte(ctx, make_constant(ctx, Value(f64(1))))
		exit_jump := emit_jump(ctx, .Jump_If_False)

		// Значение из Есть(x) — x может быть туплом ("для (a, b) в ...",
		// см. infer_for_in_stmt): тот же паттерн деструктуризации, что
		// Fast_Array-ветка выше применяет к Get_Index-результату.
		emit_opcode(ctx, .Get_Local)
		emit_byte(ctx, u8(subject_slot))
		emit_opcode(ctx, .Get_Variant_Field)
		emit_byte(ctx, 0)
		if len(names_slots) == 1 {
			emit_opcode(ctx, .Set_Local)
			emit_byte(ctx, u8(names_slots[0]))
		} else {
			elem_slot := allocate_temp_slot(ctx, "__for_elem")
			emit_opcode(ctx, .Set_Local)
			emit_byte(ctx, u8(elem_slot))
			for slot, i in names_slots {
				emit_opcode(ctx, .Get_Local)
				emit_byte(ctx, u8(elem_slot))
				emit_opcode(ctx, .Get_Property)
				emit_byte(ctx, u8(i))
				emit_opcode(ctx, .Set_Local)
				emit_byte(ctx, u8(slot))
			}
		}

		for body_stmt in s.body do compile_statement(ctx, body_stmt)

		loop_jump := emit_jump(ctx, .Jump)
		patch_signed_jump_to(ctx, loop_jump, loop_start)

		patch_jump(ctx, exit_jump)
		finished_loop := ctx.loops[len(ctx.loops) - 1]
		for break_jump in finished_loop.break_jumps do patch_jump(ctx, break_jump)
		pop(&ctx.loops)
	}
}

// Эмитит приведение структуры к интерфейсу, если тайпчекер его пометил
// (ctx.tc.interface_casts, см. check_expr в type_cheker.odin). Должен
// вызываться перед КАЖДЫМ ранним return в case ^Call_Expr: (они выходят из
// compile_expr целиком, минуя общую развязку внизу), плюс один раз в самой
// развязке для всех прочих видов expr.
maybe_emit_interface_cast :: proc(ctx: ^Compiler, expr: Expr) {
	if struct_type, needs_cast := ctx.tc.interface_casts[expr]; needs_cast {
		emit_opcode(ctx, .Cast_Interface)
		emit_byte(ctx, make_constant(ctx, Value(perm_string(struct_type.name))))
	}
}

compile_expr :: proc(ctx: ^Compiler, expr: Expr) {

	switch e in expr {
	case ^Number_Expr:
		emit_constant(ctx, e.value)
	case ^Boolean_Expr:
		emit_constant(ctx, e.value)
	case ^Unary_Expr:
		compile_expr(ctx, e.right)
		#partial switch e.op {
		case .Minus:
			emit_constant(ctx, -1.0)
			emit_opcode(ctx, .Multiply)
		case .Negate:
			emit_opcode(ctx, .Negate)
		case .Tilde:
			emit_opcode(ctx, .BitNot)
		}

	case ^String_Expr:
		emit_constant(ctx, Value(perm_string(e.value)))
	case ^Lambda_Expr:
		fn := new(Compiled_Function)
		module_prefix := ""
		if ctx.res.current_module != nil do module_prefix = ctx.res.current_module.path
		if len(module_prefix) > 0 {
			fn.name = fmt.tprintf("%s::lambda_%d", module_prefix, len(ctx.registry^))
		} else {
			fn.name = fmt.tprintf("lambda_%d", len(ctx.registry^))
		}
		lambda_type := ctx.tc.node_types[expr]
		fn.returns_value = prune_type(lambda_type.return_type) != TY_VOID
		fn.instructions = make([dynamic]u8); fn.constants = make([dynamic]Value)
		ctx.registry^[fn.name] = fn

		// Стадия 48 (замыкания): захваты этой лямбды уже посчитаны
		// резолвером (упорядоченный dedup-список, тот же порядок нужен
		// И здесь для .Get_Captured-индексов внутри тела, И ниже для
		// .Build_Closure-пуша во внешнем контексте).
		captures := ctx.res.lambda_captures[expr]

		l_ctx := Compiler {
			registry         = ctx.registry,
			current_function = fn,
			tc               = ctx.tc,
			res              = ctx.res,
			locals           = make([dynamic]Local),
			captures         = captures,
		}
		if args_syms, ok := ctx.res.lambda_args[expr]; ok {
			for sym in args_syms do append(&l_ctx.locals, Local{symbol = sym, depth = 0})
		}
		l_ctx.current_function.frame_size = len(l_ctx.locals)
		compile_block(&l_ctx, e.body, true)
		emit_opcode(&l_ctx, .Return)

		if len(captures) == 0 {
			// Некапчурящая лямбда — старое поведение без изменений
			// (голая ^Compiled_Function-константа, обычный .Call).
			emit_constant(ctx, Value(fn))
		} else {
			// Захватывающая лямбда: пушим ТЕКУЩЕЕ значение каждого
			// захваченного символа ВО ВНЕШНЕМ (не l_ctx) контексте —
			// снапшот на момент построения замыкания, до .Build_Closure.
			for sym in captures {
				compile_symbol_value_ref(ctx, sym)
			}
			fn_const := make_constant(ctx, Value(fn))
			emit_opcode(ctx, .Build_Closure)
			emit_byte(ctx, fn_const)
			emit_byte(ctx, u8(len(captures)))
		}
	case ^Ident_Expr:
		sym_id := ctx.res.node_symbols[expr]
		sym := symbol_at(ctx.res.symbol_store, sym_id)
		if sym.kind == .Module {
			fmt.panicf(
				"Compiler Error: модуль '%s' нельзя использовать как значение",
				resolve_interned(sym.name),
			)
		}
		if info, ok := ctx.tc.call_infos[expr]; ok && info.kind == .Constructor_Variant {
			name_const := make_constant(ctx, Value(perm_string(info.variant.owner_type.name)))
			emit_opcode(ctx, .Build_Variant)
			emit_byte(ctx, name_const)
			emit_byte(ctx, u8(info.variant.tag_index))
			emit_byte(ctx, 0)
			return
		}
		if sym.kind == .Builtin {
			fmt.panicf(
				"Compiler Error: встроенный конструктор '%s' нужно вызвать через ()",
				resolve_interned(sym.name),
			)
		}

		compile_symbol_value_ref(ctx, sym_id)

	case ^Binary_Expr:
		if e.op == .Assign {
			if ident, ok := e.left.(^Ident_Expr); ok {
				compile_expr(ctx, e.right)
				sym_id := ctx.res.node_symbols[ident]
				slot := -1
				#reverse for loc, i in ctx.locals {
					if loc.symbol == sym_id { slot = i; break }
				}
				if slot != -1 {
					emit_opcode(ctx, .Set_Local)
					emit_byte(ctx, u8(slot))
				}
			} else if prop, ok_2 := e.left.(^Property_Expr); ok_2 {
				compile_expr(ctx, prop.object)
				compile_expr(ctx, e.right)
				idx := ctx.tc.property_indices[prop]
				emit_opcode(ctx, .Set_Property); emit_byte(ctx, u8(idx))
			} else if index_expr, ok_3 := e.left.(^Index_Expr); ok_3 {
				compile_expr(ctx, index_expr.object)
				compile_expr(ctx, index_expr.index)
				compile_expr(ctx, e.right)
				emit_opcode(ctx, .Set_Index)
			}
		} else if info, has_sugar := ctx.tc.call_infos[expr]; has_sugar && info.kind == .Method_Struct {
			// Стадия 22/23: Сравниваемое/Равнозначное/Арифметика sugar —
			// реюз того же .Method_Struct-кодогена, что Call_Expr (см. case
			// .Method_Struct выше в этом файле): push fn-константа, компиляция
			// receiver'а (e.left) и единственного арга (e.right), .Call 2.
			// Порядок push другой, чем у native-пути ниже (fn ПЕРЕД
			// операндами, не сами операнды) — этот путь сам решает, что на
			// стеке и в каком порядке, поэтому предкомпиляция e.left/e.right
			// выше не подходит. maybe_emit_interface_cast не нужен —
			// результат либо примитив (Число из сравнить/Булево из равно),
			// либо Self-структура (из сложить/вычесть/...) — ни один не
			// апкастится в интерфейс.
			fn_ptr, found := ctx.registry^[symbol_registry_key(ctx.res.symbol_store, info.symbol_ref)]
			if !found {
				fmt.panicf("Compiler Error: метод не найден")
			}
			emit_constant(ctx, Value(fn_ptr))
			compile_expr(ctx, e.left)
			compile_expr(ctx, e.right)
			emit_opcode(ctx, .Call)
			emit_byte(ctx, 2)

			#partial switch e.op {
			case .Less:
				emit_constant(ctx, Value(0.0))
				emit_opcode(ctx, .Less)
			case .Greater:
				emit_constant(ctx, Value(0.0))
				emit_opcode(ctx, .Greater)
			case .LessEqual:
				emit_constant(ctx, Value(0.0))
				emit_opcode(ctx, .Greater)
				emit_opcode(ctx, .Negate)
			case .GreaterEqual:
				emit_constant(ctx, Value(0.0))
				emit_opcode(ctx, .Less)
				emit_opcode(ctx, .Negate)
			case .NotEqual:
				emit_opcode(ctx, .Negate)
			case .Equal:
			// равно() уже возвращает Булево — результат вызова и есть ответ.
			case .Plus, .Minus, .Star, .Slash:
			// Стадия 23: сложить/вычесть/умножить/разделить уже возвращают
			// Self — результат вызова и есть ответ, без пост-обработки.
			}
		} else {
			// .And/.Or ниже сами компилируют e.left/e.right (с прыжками для
			// short-circuit). Предкомпиляция здесь удвоила бы каждый операнд, а
			// для цепочки `и`/`или` (левоассоциативной — e.left сам Binary_Expr)
			// рекурсивно: O(2^n) инструкций плюс мусор на стеке VM.
			if e.op != .And && e.op != .Or {
				compile_expr(ctx, e.left); compile_expr(ctx, e.right)
			}
			#partial switch e.op {
			case .Plus:
				emit_opcode(ctx, .Add)
			case .Minus:
				emit_opcode(ctx, .Subtract)
			case .Star:
				emit_opcode(ctx, .Multiply)
			case .Slash:
				// Опкод выбирает КОМПИЛЯТОР по статическому типу (typechecker
				// уже решил Целое/Целое vs Число/Число, см. infer_binary_expr)
				// — рантайм-представление обоих f64, VM отличить их не может.
				if ctx.tc.node_types[e.left] == TY_INT {
					emit_opcode(ctx, .Int_Divide)
				} else {
					emit_opcode(ctx, .Divide)
				}
			case .Percent:
				emit_opcode(ctx, .Modulo)
			case .Ampersand:
				emit_opcode(ctx, .BitAnd)
			case .Pipe:
				emit_opcode(ctx, .BitOr)
			case .Caret:
				emit_opcode(ctx, .BitXor)
			case .LessLess:
				emit_opcode(ctx, .ShiftLeft)
			case .GreaterGreater:
				emit_opcode(ctx, .ShiftRight)
			case .Less:
				emit_opcode(ctx, .Less)
			case .Greater:
				emit_opcode(ctx, .Greater)
			case .LessEqual:
				// a <= b == не (a > b) — тот же приём, что NotEqual ниже
				// (Equal+Negate): не заводим отдельный VM-опкод под ещё
				// одно сравнение, компонуем из уже существующих.
				emit_opcode(ctx, .Greater)
				emit_opcode(ctx, .Negate)
			case .GreaterEqual:
				emit_opcode(ctx, .Less)
				emit_opcode(ctx, .Negate)
			case .Equal:
				emit_opcode(ctx, .Equal)
			case .NotEqual:
				emit_opcode(ctx, .Equal)
				emit_opcode(ctx, .Negate)
			case .Negate:
				emit_opcode(ctx, .Negate)
			case .And:
				compile_expr(ctx, e.left)

				false_jump := emit_jump(ctx, .Jump_If_False)

				compile_expr(ctx, e.right)
				end_jump := emit_jump(ctx, .Jump)

				patch_jump(ctx, false_jump)
				emit_constant(ctx, Value(false))
				patch_jump(ctx, end_jump)

			case .Or:
				compile_expr(ctx, e.left)

				jump_eval_right := emit_jump(ctx, .Jump_If_False)

				emit_constant(ctx, Value(true))

				jump_end := emit_jump(ctx, .Jump)

				patch_jump(ctx, jump_eval_right)
				compile_expr(ctx, e.right)

				patch_jump(ctx, jump_end)
			}
		}

	case ^Property_Expr:
		if info, ok := ctx.tc.call_infos[expr]; ok && info.kind == .Constructor_Variant {
			name_const := make_constant(ctx, Value(perm_string(info.variant.owner_type.name)))
			emit_opcode(ctx, .Build_Variant)
			emit_byte(ctx, name_const)
			emit_byte(ctx, u8(info.variant.tag_index))
			emit_byte(ctx, 0)
			// Стадия 25: раньше не нужно было (enum'ы не реализовывали
			// интерфейсы) — безымянный (без payload) конструктор варианта,
			// переданный туда, где ожидается интерфейсный тип
			// (`бой(Фигура.Линия)`), тоже должен приводиться так же, как
			// Constructor_Struct уже делает.
			maybe_emit_interface_cast(ctx, expr)
			return
		}
		if sym_id, ok := ctx.res.node_symbols[expr]; ok {
			sym := symbol_at(ctx.res.symbol_store, sym_id)
			if sym.kind == .Enum_Variant {
				owner_name := sym.owner_type == INVALID_SYMBOL ? "" : resolve_interned(symbol_at(ctx.res.symbol_store, sym.owner_type).name)
				fmt.panicf(
					"Compiler Error: вариант '%s.%s' используется как значение — вызовите со скобками",
					owner_name,
					resolve_interned(sym.name),
				)
			}
			if fn_ptr, found := ctx.registry^[symbol_registry_key(ctx.res.symbol_store, sym_id)]; found {
				emit_constant(ctx, Value(fn_ptr))
				return
			}
			fmt.panicf(
				"Compiler Error: символ '%s' нельзя использовать как значение",
				resolve_interned(sym.full_name),
			)
		}
		if obj_ident, ok := e.object.(^Ident_Expr); ok {
			if obj_sym_id := ctx.res.node_symbols[e.object];
			   obj_sym_id != INVALID_SYMBOL && symbol_at(ctx.res.symbol_store, obj_sym_id).kind == .Module {
				imported_module := symbol_at(ctx.res.symbol_store, obj_sym_id).module
				if imported_module == nil {
					fmt.panicf(
						"Compiler Error: модуль '%s' не загружен",
						resolve_interned(obj_ident.name),
					)
				}
				if export_sym, found := imported_module.exports[intern(e.property)]; found {
					if fn_ptr, found_fn := ctx.registry^[symbol_registry_key(ctx.res.symbol_store, export_sym)];
					   found_fn {
						emit_constant(ctx, Value(fn_ptr))
						return
					}
					fmt.panicf(
						"Compiler Error: экспорт '%s.%s' нельзя использовать как значение",
						resolve_interned(obj_ident.name),
						e.property,
					)
				}
				fmt.panicf(
					"Compiler Error: модуль '%s' не экспортирует '%s'",
					resolve_interned(obj_ident.name),
					e.property,
				)
			}
		}
		compile_expr(ctx, e.object) // На стеке окажется структура

		idx := ctx.tc.property_indices[expr] // Берем индекс поля от Тайп-чекера

		emit_opcode(ctx, .Get_Property)
		emit_byte(ctx, u8(idx))
	case ^Index_Expr:
		compile_expr(ctx, e.object)
		compile_expr(ctx, e.index)
		emit_opcode(ctx, .Get_Index)
	case ^Try_Expr:
		compile_expr(ctx, e.value)
		emit_opcode(ctx, .Try_Unwrap)
	case ^Call_Expr:
		// Bounded traits: вызов bounded generic-функции — НЕ обычный
		// symbol_registry_key(sym_id) (шаблон никогда не компилируется,
		// см. compile_program и core/monomorphize.odin), а ключ конкретной
		// инстанциации, уже гарантированно скомпилированной monomorphize_
		// program ДО этого места (см. compile_program — вызывается первым
		// шагом).
		if concrete_types, ok := ctx.tc.generic_call_instantiations[expr]; ok {
			key := build_instantiation_key(ctx.res.symbol_store, ctx.res.node_symbols[e.callee], concrete_types)
			if fn_ptr, found := ctx.registry^[key]; found {
				emit_constant(ctx, Value(fn_ptr))
			} else {
				fmt.panicf("Compiler Error: инстанциация generic-функции '%s' не найдена", key)
			}
			for arg in e.args do compile_expr(ctx, arg)
			emit_opcode(ctx, .Call)
			emit_byte(ctx, u8(len(e.args)))
			maybe_emit_interface_cast(ctx, expr)
			return
		}
		if info, ok := ctx.tc.call_infos[expr]; ok {
			switch info.kind {
			case .Constructor_Variant:
				for arg in e.args do compile_expr(ctx, arg)
				name_const := make_constant(ctx, Value(perm_string(info.variant.owner_type.name)))
				emit_opcode(ctx, .Build_Variant)
				emit_byte(ctx, name_const)
				emit_byte(ctx, u8(info.variant.tag_index))
				emit_byte(ctx, u8(len(e.args)))
				maybe_emit_interface_cast(ctx, expr)
				return

			case .Builtin:
				for arg in e.args do compile_expr(ctx, arg)
				emit_opcode(ctx, .Call_Builtin)
				emit_byte(ctx, make_constant(ctx, Value(perm_string(info.text_name))))
				emit_byte(ctx, u8(len(e.args)))
				maybe_emit_interface_cast(ctx, expr)
				return

			case .Method_Collection:
				prop_expr := e.callee.(^Property_Expr)
				compile_expr(ctx, prop_expr.object)
				for arg in e.args do compile_expr(ctx, arg)
				emit_opcode(ctx, .Invoke_Collection)
				emit_byte(ctx, make_constant(ctx, Value(perm_string(info.text_name))))
				emit_byte(ctx, u8(len(e.args)))
				maybe_emit_interface_cast(ctx, expr)
				return

			case .Method_Interface:
				prop_expr := e.callee.(^Property_Expr)
				compile_expr(ctx, prop_expr.object)
				for arg in e.args do compile_expr(ctx, arg)
				emit_opcode(ctx, .Invoke_Interface)
				emit_byte(ctx, make_constant(ctx, Value(perm_string(info.text_name))))
				emit_byte(ctx, u8(len(e.args)))
				maybe_emit_interface_cast(ctx, expr)
				return

			case .Method_Struct:
				if fn_ptr, found := ctx.registry^[symbol_registry_key(ctx.res.symbol_store, info.symbol_ref)]; found {
					emit_constant(ctx, Value(fn_ptr))
				} else {
					fmt.panicf("Compiler Error: метод не найден")
				}
				prop_expr := e.callee.(^Property_Expr)
				compile_expr(ctx, prop_expr.object)
				for arg in e.args do compile_expr(ctx, arg)
				emit_opcode(ctx, .Call)
				emit_byte(ctx, u8(len(e.args) + 1))
				maybe_emit_interface_cast(ctx, expr)
				return

			case .Constructor_Struct:
				for arg in e.args do compile_expr(ctx, arg)
				emit_opcode(ctx, .Build_Aggregate)
				emit_byte(ctx, u8(len(e.args)))
				maybe_emit_interface_cast(ctx, expr)
				return

			case .Print_Value:
				// Стадия 23 (Печатаемое): e.args[0] реализует Печатаемое —
				// вызвать .вСтроку() (push fn, receiver = e.args[0], .Call 1),
				// РЕЗУЛЬТАТ (Строка) передать в реальный builtin (печать/
				// строка) через Call_Builtin. Без пост-обработки между —
				// вСтроку() уже даёт готовую Строку.
				if fn_ptr, found := ctx.registry^[symbol_registry_key(ctx.res.symbol_store, info.symbol_ref)]; found {
					emit_constant(ctx, Value(fn_ptr))
				} else {
					fmt.panicf("Compiler Error: метод вСтроку не найден")
				}
				compile_expr(ctx, e.args[0])
				emit_opcode(ctx, .Call)
				emit_byte(ctx, 1)
				emit_opcode(ctx, .Call_Builtin)
				emit_byte(ctx, make_constant(ctx, Value(perm_string(info.text_name))))
				emit_byte(ctx, 1)
				return

			case .Send_Copy:
				// Стадия 24: e.args[1] (сообщение) реализует Копируемое —
				// компилировать процесс, ЗАТЕМ вызвать .клонировать() на
				// сообщении (push fn, receiver = e.args[1], .Call 1), и
				// отдать УЖЕ клонированное значение в
				// "отправить_без_копии" (не "отправить" — та делает
				// reflective copy заново поверх намеренно НЕ
				// скопированных пользователем полей).
				compile_expr(ctx, e.args[0])
				if fn_ptr, found := ctx.registry^[symbol_registry_key(ctx.res.symbol_store, info.symbol_ref)]; found {
					emit_constant(ctx, Value(fn_ptr))
				} else {
					fmt.panicf("Compiler Error: метод клонировать не найден")
				}
				compile_expr(ctx, e.args[1])
				emit_opcode(ctx, .Call)
				emit_byte(ctx, 1)
				emit_opcode(ctx, .Call_Builtin)
				emit_byte(ctx, make_constant(ctx, Value(perm_string("отправить_без_копии"))))
				emit_byte(ctx, 2)
				return
			}
		}
		if ident, ok := e.callee.(^Ident_Expr); ok {
			// Стадия 47 (FFI-B): `внешний`-функция — обычный .Function
			// символ (не .Builtin), но decl — ^Foreign_Decl, не
			// ^Function_Decl, поэтому обычный .Call (constant fn_ptr +
			// .Call) не подходит: нет ^Compiled_Function, есть libffi-
			// вызов. Проверяем ДО .Builtin-ветки ниже.
			if sym_id := ctx.res.node_symbols[e.callee]; sym_id != INVALID_SYMBOL {
				if foreign_decl, is_foreign := symbol_at(ctx.res.symbol_store, sym_id).decl.(^Foreign_Decl);
				   is_foreign {
					ff := get_or_build_foreign_function(foreign_decl)
					for arg in e.args do compile_expr(ctx, arg)
					emit_opcode(ctx, .Call_Foreign)
					emit_byte(ctx, make_constant(ctx, Value(ff)))
					emit_byte(ctx, u8(len(e.args)))
					maybe_emit_interface_cast(ctx, expr)
					return
				}
			}
			if sym_id := ctx.res.node_symbols[e.callee];
			   sym_id != INVALID_SYMBOL && symbol_at(ctx.res.symbol_store, sym_id).kind == .Builtin {
				// Стадия 24 (actor model): получить() — единственный bare
				// builtin, компилирующийся НЕ в .Call_Builtin, а в свой
				// опкод .Receive (suspend/resume механика execute(), см.
				// vm.odin) — отправить() остаётся обычным .Call_Builtin.
				if resolve_interned(ident.name) == "получить" {
					emit_opcode(ctx, .Receive)
					maybe_emit_interface_cast(ctx, expr)
					return
				}
				// Стадия 38: получить_сигнал() — тот же suspend/resume
				// паттерн, свой опкод .Receive_Signal.
				if resolve_interned(ident.name) == "получить_сигнал" {
					emit_opcode(ctx, .Receive_Signal)
					maybe_emit_interface_cast(ctx, expr)
					return
				}
				for arg in e.args do compile_expr(ctx, arg)
				emit_opcode(ctx, .Call_Builtin)
				emit_byte(ctx, make_constant(ctx, Value(perm_string(resolve_interned(ident.name)))))
				emit_byte(ctx, u8(len(e.args)))
				maybe_emit_interface_cast(ctx, expr)
				return
			}
		}
		compile_expr(ctx, e.callee)
		for arg in e.args do compile_expr(ctx, arg)
		emit_opcode(ctx, .Call)
		emit_byte(ctx, u8(len(e.args)))

	case ^Match_Expr:
		compile_match_expr(ctx, e)

	case ^If_Expr:
		compile_expr(ctx, e.condition)
		else_jump := emit_jump(ctx, .Jump_If_False)
		is_val := ctx.tc.node_types[expr] != TY_VOID
		compile_block(ctx, e.then_branch, is_val)
		end_jump := emit_jump(ctx, .Jump)
		patch_jump(ctx, else_jump)
		if len(e.else_branch) > 0 do compile_block(ctx, e.else_branch, is_val)
		else if is_val do emit_constant(ctx, f64(0))
		patch_jump(ctx, end_jump)

	case ^While_Expr:
		loop_start := len(ctx.current_function.instructions)
		loop_ctx := Loop_Context {
			continue_target = loop_start,
			break_jumps     = make([dynamic]int),
		}
		append(&ctx.loops, loop_ctx)

		compile_expr(ctx, e.condition)
		exit_jump := emit_jump(ctx, .Jump_If_False)

		for stmt in e.body {
			compile_statement(ctx, stmt)
		}

		// Обратный (знаковый) прыжок в начало — .Jump эмулирует Jump_Back.
		loop_jump := emit_jump(ctx, .Jump)
		patch_signed_jump_to(ctx, loop_jump, loop_start)

		patch_jump(ctx, exit_jump)
		finished_loop := ctx.loops[len(ctx.loops) - 1]
		for break_jump in finished_loop.break_jumps {
			patch_jump(ctx, break_jump)
		}
		pop(&ctx.loops)
	case ^Tuple_Expr:
		for el in e.elements {
			compile_expr(ctx, el)
		}

		emit_opcode(ctx, .Build_Aggregate)

		if len(e.elements) > 255 {
			fmt.panicf(
				"Compiler Error: тупл не может содержать больше 255 элементов",
			)
		}
		emit_byte(ctx, u8(len(e.elements)))
	case ^Array_Expr:
		for el in e.elements {
			compile_expr(ctx, el)
		}
		if len(e.elements) > 255 {
			fmt.panicf(
				"Compiler Error: массив не может содержать больше 255 элементов",
			)
		}
		emit_opcode(ctx, .Build_Array)
		emit_byte(ctx, u8(len(e.elements)))
	case ^Map_Expr:
		for entry in e.entries {
			compile_expr(ctx, entry.key)
			compile_expr(ctx, entry.value)
		}
		if len(e.entries) > 255 {
			fmt.panicf(
				"Compiler Error: соответствие не может содержать больше 255 элементов",
			)
		}
		emit_opcode(ctx, .Build_Map)
		emit_byte(ctx, u8(len(e.entries)))

	case ^Error_Expr:
		// Компилятор запускается только после typecheck_program с нулём
		// diagnostics (main.odin) — Error_Expr сюда дойти не должен.
		fmt.panicf("Compiler Error: внутренняя ошибка — Error_Expr дошёл до компиляции")

	case ^Spawn_Expr:
		// `запусти f(args...)` — НЕ обычный вызов: push fn-константы (как
		// Ident_Expr для функции, см. выше), компиляция аргументов БЕЗ их
		// исполнения, .Spawn создаёт Process_Value в рантайме (vm.odin).
		fn_ptr: ^Compiled_Function
		found: bool
		#partial switch callee in e.call.callee {
		case ^Property_Expr:
			// Стадия 45: `запусти Модуль.функция(...)` — node_symbols не
			// резолвит Property_Expr целиком (та же логика, что обычный
			// Property_Expr-как-значение выше в этом proc'е), резолвим
			// export вручную через object/property.
			obj_ident := callee.object.(^Ident_Expr)
			obj_sym_id := ctx.res.node_symbols[callee.object]
			imported_module := symbol_at(ctx.res.symbol_store, obj_sym_id).module
			export_sym, export_found := imported_module.exports[intern(callee.property)]
			if !export_found {
				fmt.panicf(
					"Compiler Error: запусти: '%s.%s' не найден в реестре",
					resolve_interned(obj_ident.name),
					callee.property,
				)
			}
			fn_ptr, found = ctx.registry^[symbol_registry_key(ctx.res.symbol_store, export_sym)]
		case:
			callee_sym := ctx.res.node_symbols[e.call.callee]
			fn_ptr, found = ctx.registry^[symbol_registry_key(ctx.res.symbol_store, callee_sym)]
		}
		if !found {
			fmt.panicf("Compiler Error: запусти: функция не найдена в реестре")
		}
		emit_constant(ctx, Value(fn_ptr))
		for arg in e.call.args do compile_expr(ctx, arg)
		emit_opcode(ctx, .Spawn)
		emit_byte(ctx, u8(len(e.call.args)))
	}

	maybe_emit_interface_cast(ctx, expr)
}

allocate_temp_slot :: proc(ctx: ^Compiler, name: string) -> int {
	sym := new_symbol(ctx.res.symbol_store, name, .Variable, nil)
	append(&ctx.locals, Local{symbol = sym, depth = ctx.scope_depth})
	slot := len(ctx.locals) - 1
	ctx.current_function.frame_size = max(ctx.current_function.frame_size, len(ctx.locals))
	return slot
}

register_binder_slot :: proc(ctx: ^Compiler, sym: Symbol_Id) -> int {
	append(&ctx.locals, Local{symbol = sym, depth = ctx.scope_depth})
	slot := len(ctx.locals) - 1
	ctx.current_function.frame_size = max(ctx.current_function.frame_size, len(ctx.locals))
	return slot
}

compile_pattern :: proc(
	ctx: ^Compiler,
	pi: ^Pattern_Info,
	value_slot: int,
	fail_jumps: ^[dynamic]int,
) {
	switch pi.kind {
	case .Wildcard:
	// без условия — совпадает всегда
	case .Literal:
		// Обычное сравнение через .Equal — тот же опкод, что уже делает
		// структурное сравнение для оператора == (value_equals, vm.odin),
		// работает на Число/Строка/Булево без нового рантайм-механизма.
		// literal_expr компилируется как обычное выражение (Number_Expr/
		// String_Expr/Boolean_Expr, в т.ч. отрицательные числа) —
		// compile_expr сам знает, как эмитить константу.
		emit_opcode(ctx, .Get_Local)
		emit_byte(ctx, u8(value_slot))
		compile_expr(ctx, pi.literal_expr)
		emit_opcode(ctx, .Equal)
		append(fail_jumps, emit_jump(ctx, .Jump_If_False))
	case .Binder:
		binder_slot := register_binder_slot(ctx, pi.binder_sym)
		emit_opcode(ctx, .Get_Local)
		emit_byte(ctx, u8(value_slot))
		emit_opcode(ctx, .Set_Local)
		emit_byte(ctx, u8(binder_slot))
	case .Constructor:
		tag_const := make_constant(ctx, Value(f64(pi.tag_index)))
		emit_opcode(ctx, .Get_Local)
		emit_byte(ctx, u8(value_slot))
		emit_opcode(ctx, .Match_Tag)
		emit_byte(ctx, tag_const)
		append(fail_jumps, emit_jump(ctx, .Jump_If_False))
		for &sub, field_idx in pi.sub_patterns {
			if sub.kind == .Wildcard do continue
			// Извлекаем поле в temp slot, потом рекурсивно сравниваем.
			field_slot := allocate_temp_slot(ctx, "__match_field")
			emit_opcode(ctx, .Get_Local)
			emit_byte(ctx, u8(value_slot))
			emit_opcode(ctx, .Get_Variant_Field)
			emit_byte(ctx, u8(field_idx))
			emit_opcode(ctx, .Set_Local)
			emit_byte(ctx, u8(field_slot))
			compile_pattern(ctx, &sub, field_slot, fail_jumps)
		}
	case .Struct_Constructor:
		// Структура — одна форма, нет тега для проверки (в отличие от
		// .Constructor's .Match_Tag) — сразу распаковываем поля через
		// .Get_Property (тот же опкод, что и обычный s.поле, и что уже
		// использует пер-деструктуризация, Стадия 30) и рекурсивно
		// сравниваем под-шаблоны.
		for &sub, field_idx in pi.sub_patterns {
			if sub.kind == .Wildcard do continue
			field_slot := allocate_temp_slot(ctx, "__match_field")
			emit_opcode(ctx, .Get_Local)
			emit_byte(ctx, u8(value_slot))
			emit_opcode(ctx, .Get_Property)
			emit_byte(ctx, u8(field_idx))
			emit_opcode(ctx, .Set_Local)
			emit_byte(ctx, u8(field_slot))
			compile_pattern(ctx, &sub, field_slot, fail_jumps)
		}
	}
}

compile_match_expr :: proc(ctx: ^Compiler, m: ^Match_Expr) {
	arm_infos, has_infos := ctx.tc.match_arm_infos[m]
	if !has_infos {
		fmt.panicf("Compiler Error: match_arm_infos отсутствует для выбора")
	}
	is_val := ctx.tc.node_types[m] != TY_VOID
	compile_expr(ctx, m.subject)
	subject_slot := allocate_temp_slot(ctx, "__match_subject")
	emit_opcode(ctx, .Set_Local)
	emit_byte(ctx, u8(subject_slot))

	end_jumps := make([dynamic]int, context.temp_allocator)

	for arm, arm_idx in m.arms {
		pi := arm_infos[arm_idx]
		fail_jumps := make([dynamic]int, context.temp_allocator)
		compile_pattern(ctx, &pi, subject_slot, &fail_jumps)

		compile_block(ctx, arm.body, is_val)
		append(&end_jumps, emit_jump(ctx, .Jump))

		for fj in fail_jumps do patch_jump(ctx, fj)
	}

	emit_opcode(ctx, .Get_Local)
	emit_byte(ctx, u8(subject_slot))
	emit_opcode(ctx, .Match_Fail)

	for j in end_jumps do patch_jump(ctx, j)
}

compile_block :: proc(ctx: ^Compiler, body: [dynamic]Stmt, is_expr: bool) {
	if len(body) == 0 { if is_expr do emit_constant(ctx, f64(0)); return }
	for i in 0 ..< len(body) {
		stmt := body[i]
		is_last := i == len(body) - 1
		if is_last && is_expr {
			if expr_stmt, ok := stmt.(^Expr_Stmt); ok {
				compile_expr(ctx, expr_stmt.expr)
			} else {
				compile_statement(ctx, stmt)
				emit_constant(ctx, f64(0))
			}
		} else {
			compile_statement(ctx, stmt)
		}
	}
}

print_assembler :: proc(registry: map[string]^Compiled_Function) {

	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	prefix := "\t"

	for name, f in registry {

		function_name := fmt.tprintf("FUNCTION %s\n", name)
		strings.write_string(&builder, function_name)

		instructions := f.instructions
		for idx := 0; idx < len(instructions); idx += 1 {
			current_opcode := Opcode(instructions[idx])
			// Не #partial — компилятор Odin сам укажет на недостающий case,
			// если в Opcode добавится новый вариант (раньше 9 из 34 опкодов
			// молча пропускались через #partial, включая все actor-model/
			// match-опкоды: Spawn/Receive/Match_Tag и т.д.).
			switch current_opcode {
			case .Set_Property:
				idx += 1
				command := fmt.tprintf("%sSET_PROPERTY: %d\n", prefix, instructions[idx])
				strings.write_string(&builder, command)

			case .Greater:
				command := fmt.tprintf("%sGREATER\n", prefix)
				strings.write_string(&builder, command)

			case .Less:
				command := fmt.tprintf("%sLESS\n", prefix)
				strings.write_string(&builder, command)

			case .Equal:
				command := fmt.tprintf("%sEQUAL\n", prefix)
				strings.write_string(&builder, command)

			case .Negate:
				command := fmt.tprintf("%sNEGATE\n", prefix)
				strings.write_string(&builder, command)

			case .Constant:
				idx += 1
				command := fmt.tprintf("%sCONSTANT: %d\n", prefix, instructions[idx])
				strings.write_string(&builder, command)

			case .Add:
				command := fmt.tprintf("%sADD\n", prefix)
				strings.write_string(&builder, command)

			case .Subtract:
				command := fmt.tprintf("%sSUBSTACT\n", prefix)
				strings.write_string(&builder, command)

			case .Multiply:
				command := fmt.tprintf("%sMULTIPLY\n", prefix)
				strings.write_string(&builder, command)

			case .Divide:
				command := fmt.tprintf("%sDIVIDE\n", prefix)
				strings.write_string(&builder, command)

			case .Get_Local:
				idx += 1
				command := fmt.tprintf("%sGET_LOCAL: %d\n", prefix, instructions[idx])
				strings.write_string(&builder, command)

			case .Set_Local:
				idx += 1
				command := fmt.tprintf("%sSET_LOCAL: %d\n", prefix, instructions[idx])
				strings.write_string(&builder, command)

			case .Jump_If_False:
				idx += 2
				command := fmt.tprintf("%sJUMP_IF_FALSE\n", prefix)
				strings.write_string(&builder, command)

			case .Jump:
				idx += 2
				command := fmt.tprintf("%sJUMP\n", prefix)
				strings.write_string(&builder, command)

			case .Pop:
				command := fmt.tprintf("%sPOP\n", prefix)
				strings.write_string(&builder, command)

			case .Return:
				command := fmt.tprintf("%sRETURN\n", prefix)
				strings.write_string(&builder, command)

			case .Call:
				idx += 1
				command := fmt.tprintf("%sCALL\n", prefix)
				strings.write_string(&builder, command)
			case .Build_Aggregate:
				idx += 1
				command := fmt.tprintf("%sBUILD_AGGREGATE\n", prefix)
				strings.write_string(&builder, command)
			case .Get_Property:
				idx += 1
				command := fmt.tprintf("%sGET_PROPERTY\n", prefix)
				strings.write_string(&builder, command)
			case .Cast_Interface:
				idx += 1
				command := fmt.tprintf("%sCAST_INTERFACE\n", prefix)
				strings.write_string(&builder, command)

			case .Invoke_Interface:
				idx += 2
				command := fmt.tprintf("%sINVOKE_INTERFACE\n", prefix)
				strings.write_string(&builder, command)

			case .Build_Array:
				idx += 1
				command := fmt.tprintf("%sBUILD_ARRAY\n", prefix)
				strings.write_string(&builder, command)

			case .Build_Map:
				idx += 1
				command := fmt.tprintf("%sBUILD_MAP\n", prefix)
				strings.write_string(&builder, command)

			case .Get_Index:
				command := fmt.tprintf("%sGET_INDEX\n", prefix)
				strings.write_string(&builder, command)

			case .Set_Index:
				command := fmt.tprintf("%sSET_INDEX\n", prefix)
				strings.write_string(&builder, command)

			case .Invoke_Collection:
				idx += 2
				command := fmt.tprintf("%sINVOKE_COLLECTION\n", prefix)
				strings.write_string(&builder, command)

			case .Call_Builtin:
				idx += 2
				command := fmt.tprintf("%sCALL_BUILTIN\n", prefix)
				strings.write_string(&builder, command)

			case .Try_Unwrap:
				command := fmt.tprintf("%sTRY_UNWRAP\n", prefix)
				strings.write_string(&builder, command)

			case .Match_Tag:
				idx += 1
				command := fmt.tprintf("%sMATCH_TAG: %d\n", prefix, instructions[idx])
				strings.write_string(&builder, command)

			case .Get_Variant_Field:
				idx += 1
				command := fmt.tprintf("%sGET_VARIANT_FIELD: %d\n", prefix, instructions[idx])
				strings.write_string(&builder, command)

			case .Match_Fail:
				command := fmt.tprintf("%sMATCH_FAIL\n", prefix)
				strings.write_string(&builder, command)

			case .Build_Variant:
				idx += 3
				command := fmt.tprintf("%sBUILD_VARIANT\n", prefix)
				strings.write_string(&builder, command)

			case .Spawn:
				idx += 1
				command := fmt.tprintf("%sSPAWN: %d\n", prefix, instructions[idx])
				strings.write_string(&builder, command)

			case .Receive:
				command := fmt.tprintf("%sRECEIVE\n", prefix)
				strings.write_string(&builder, command)

			case .Int_Divide:
				command := fmt.tprintf("%sINT_DIVIDE\n", prefix)
				strings.write_string(&builder, command)

			case .Modulo:
				command := fmt.tprintf("%sMODULO\n", prefix)
				strings.write_string(&builder, command)

			case .BitAnd:
				command := fmt.tprintf("%sBIT_AND\n", prefix)
				strings.write_string(&builder, command)

			case .BitOr:
				command := fmt.tprintf("%sBIT_OR\n", prefix)
				strings.write_string(&builder, command)

			case .BitXor:
				command := fmt.tprintf("%sBIT_XOR\n", prefix)
				strings.write_string(&builder, command)

			case .BitNot:
				command := fmt.tprintf("%sBIT_NOT\n", prefix)
				strings.write_string(&builder, command)

			case .ShiftLeft:
				command := fmt.tprintf("%sSHIFT_LEFT\n", prefix)
				strings.write_string(&builder, command)

			case .ShiftRight:
				command := fmt.tprintf("%sSHIFT_RIGHT\n", prefix)
				strings.write_string(&builder, command)

			case .Receive_Signal:
				command := fmt.tprintf("%sRECEIVE_SIGNAL\n", prefix)
				strings.write_string(&builder, command)

			case .Call_Foreign:
				idx += 2
				command := fmt.tprintf("%sCALL_FOREIGN\n", prefix)
				strings.write_string(&builder, command)

			case .Build_Closure:
				idx += 2
				command := fmt.tprintf("%sBUILD_CLOSURE\n", prefix)
				strings.write_string(&builder, command)

			case .Get_Captured:
				idx += 1
				command := fmt.tprintf("%sGET_CAPTURED: %d\n", prefix, instructions[idx])
				strings.write_string(&builder, command)

			}
		}
	}
	res := strings.to_string(builder)

	fmt.println(res)

}
