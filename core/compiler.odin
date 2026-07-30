package core

// Рантайм-представления значений (Value union + heap-managed варианты) и
// байткод-формат (Opcode, Compiled_Function) — общие для VM (core/vm.odin)
// и MIR-бэкенда (core/mir_bytecode.odin), НЕ специфичны для какого-либо
// компилятора. Старый прямой AST→байткод компилятор (compile_program/
// compile_expr/compile_statement и т.п.) жил в этом файле раньше — удалён
// целиком после перехода на MIR (core/mir_lowering.odin +
// core/mir_bytecode.odin как единственный путь AST→байткод, см. git log).

// Все heap-managed варианты Value (кроме f64/bool/^Compiled_Function —
// см. GC_State в gc.odin) встраивают GC_Header первым полем.
Aggregate_Value :: struct {
	header:    GC_Header,
	elements:  [dynamic]Value, // В реальном продакшене лучше использовать фиксированный срез (slice)
	// "" для анонимных туплов (Tuple_Expr, `.Build_Aggregate` — включая
	// tuple-возвраты из нативных builtin'ов через gc_new, см. vm_*_native.
	// odin) — у тупла структурно нет имени. Непустое только для реального
	// `Тип(...)` struct-литерала (`.Build_Aggregate_Named`, тот же приём,
	// что у Variant_Value.type_name для enum'ов — константа из пула,
	// известна компилятору статически). value_to_display_string (vm.odin)
	// печатает "Тип(...)" если непусто, иначе голый "(...)" — как раньше.
	type_name: string,
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
	header:       GC_Header,
	type_name:    string, // имя типа-перечисления (напр. "Фигура")
	// Имя КОНКРЕТНОГО варианта (напр. "Круг") — отдельно от type_name,
	// нужно value_to_display_string (vm.odin), чтобы structural-дамп
	// печатал полное "Фигура.Круг(5)", а не голое "Круг(5)" и не старое
	// ошибочное "Фигура(5)". До этого поля variant_name не было вовсе —
	// дефолтный дамп ЛЮБОГО варианта с полями ошибочно печатал только имя
	// ТИПА вместо имени варианта.
	variant_name: string,
	tag_index:    int,
	fields:       [dynamic]Value,
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
	// Неблокирующий I/O: результаты асинхронных builtin-вызовов (см.
	// .Await_Async, vm.odin). ОТДЕЛЬНАЯ от mailbox очередь — тот же мотив,
	// что у signals выше (Стадия 38): пока процесс ждёт результат СВОЕГО
	// сеть.http_запрос(...), ДРУГОЙ процесс может легально отправить() ему
	// обычное сообщение — если бы оба шли в один mailbox, .Await_Async мог
	// бы забрать чужое сообщение вместо результата I/O (или наоборот).
	async_results: [dynamic]Value,
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
	^Http_Listener_Value,
	^Http_Request_Value,
	^Sql_Connection_Value,
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
	// План interop с внешний (WASM AOT) — "либа" из `внешний "либа"
	// функ имя(...)`, нужна wasm-бэкенду как имя WASM-import-модуля
	// (core/wasm_module.odin) — раньше нигде не сохранялась (native-
	// сторона резолвит библиотеку САМА, до этой структуры, через
	// resolver.odin's dynlib.load_library, ей эта строка была не нужна
	// повторно).
	library:       string,
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

symbol_registry_key :: proc(store: ^Symbol_Store, id: Symbol_Id) -> string {
	if id == INVALID_SYMBOL do return ""
	sym := symbol_at(store, id)
	// Interned(0) зарезервирован под "" — отличает заданный full_name от незаполненного.
	if sym.full_name != Interned(0) do return resolve_interned(sym.full_name)
	return resolve_interned(sym.name)
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
	Build_Aggregate, // Операнд: 1 байт (количество элементов) — АНОНИМНЫЙ (тупл, без имени типа)
	Build_Aggregate_Named, // Операнды: 2 байта (type_name_const, количество элементов) — реальный struct-литерал
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
	Build_Variant, // Операнды: 4 байта (type_name_const, variant_name_const, tag, arity). Снимает arity полей, кладёт ^Variant_Value.
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
	// Неблокирующий I/O: пара опкодов вместо одного .Call_Builtin — та же
	// операнд-форма (1 байт имя-константа, 1 байт arg_count), но НЕ
	// блокирует поток VM. .Call_Builtin_Async снимает args, передаёт их
	// воркер-пулу (submit_async_io, vm.odin) и СРАЗУ идёт дальше (submit
	// не блокирует — просто кладёт задачу в очередь); ip естественно
	// сдвигается на следующую инструкцию — ВСЕГДА .Await_Async сразу
	// после (компилятор эмитит их парой, см. compile_expr case .Builtin).
	// .Await_Async — suspend/resume механика как у .Receive_Signal, но
	// над process.async_results, а НЕ над mailbox: пока процесс ждёт
	// результат СВОЕГО async-вызова, другой процесс может легально
	// отправить() ему обычное сообщение — общая очередь дала бы гонку
	// между чужим сообщением и результатом I/O.
	Call_Builtin_Async,
	Await_Async,
	// Фаза 4/5 (стриминговый I/O): пара с .Await_Async, та же операнд-форма,
	// что .Invoke_Collection (1 байт имя-константа, 1 байт arg_count), но
	// receiver дополнительно снимается со стека (см. execute(), vm.odin).
	// Эмитится ТОЛЬКО для File_Value.прочитать/прочитать_строку/записать и
	// Socket_Value.получить/получить_строку/отправить (is_async_stream_
	// method ниже) — эти методы читают/пишут через УЖЕ открытый хендл
	// (bufio.Reader или сам handle/socket), встроенный полем в GC-managed
	// объект (в отличие от Call_Builtin_Async, где воркер получает только
	// копии простых данных) — владение хендлом между потоками решено через
	// gc_pin/in_flight (см. gc.odin/file_value_native.odin), а не
	// переносом семантики suspend/resume, которая тут та же самая.
	Invoke_Collection_Async,
}

// Неблокирующий I/O: allowlist builtin'ов, для которых компилятор эмитит
// Call_Builtin_Async+Await_Async вместо Call_Builtin (см. case .Builtin
// выше). Тот же паттерн, что is_builtin_module_name (core/stdlib.odin) —
// список маленький, растёт по одному имени за фазу (см. план "Неблокирующий
// I/O для actor model panos" — фаза 3+: одноразовые файловые/сокетные
// операции добавятся сюда так же).
is_async_builtin_name :: proc(name: string) -> bool {
	switch name {
	case "сеть::http_запрос", "фс::прочитать", "фс::записать", "сеть::подключиться":
		return true
	}
	return false
}

// Фаза 4/5: та же роль, что is_async_builtin_name выше, но для МЕТОД-вызовов
// (case .Method_Collection ниже) — сравнение по СТАТИЧЕСКОМУ типу receiver'а
// (TY_FILE/TY_CONNECTION, type_cheker.odin), а не только по имени метода:
// "получить" — метод одновременно у Option/Result/Array/Map (чистый
// get-with-default) И у Socket_Value (блокирующий сетевой read) —
// invoke_collection_method диспетчит их рантайм-типом, так что без
// проверки receiver_type компилятор не отличил бы Соединение.получить()
// от Массив(Т).получить(). .закрыть() сознательно вне списка — остаётся
// синхронным (immediate/deferred close, см. invoke_io_method).
is_async_stream_method :: proc(receiver_type: ^Type, method_name: string) -> bool {
	if receiver_type == TY_FILE {
		return method_name == "прочитать" || method_name == "прочитать_строку" || method_name == "записать"
	}
	if receiver_type == TY_CONNECTION {
		return method_name == "получить" || method_name == "получить_строку" || method_name == "отправить"
	}
	if receiver_type == TY_HTTP_LISTENER {
		// Единственный async-метод здесь — блокирующий chan.recv на входящий
		// запрос (research.md §3, specs/009-http-server). .закрыть() —
		// синхронный, как и везде (graceful shutdown не ждёт изнутри вызова).
		return method_name == "принять_запрос"
	}
	if receiver_type == TY_SQL_CONNECTION {
		// sqlite3_step может блокироваться на дисковом I/O — оба метода,
		// меняющие данные (выполнить) и читающие (запрос), идут через
		// воркер-пул. .закрыть() — синхронный, как и везде.
		return method_name == "выполнить" || method_name == "запрос"
	}
	return false
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
		library            = d.library,
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

