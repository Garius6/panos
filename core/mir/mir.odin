package mir

import core "../"

// Отдельный Odin-пакет (не часть package core) — намеренное отступление
// от плоской конвенции core/*.odin, только для этой новой подсистемы (см.
// план в момент создания файла). Типы резолвера/тайпчекера (Symbol_Id,
// ^Type, Span) переиспользуются напрямую через core. — вся семантическая
// информация (типы, резолв имён) уже посчитана резолвером/тайпчекером
// ДО lowering; MIR её не пересчитывает, только читает (core/mir/lowering.
// odin).

Value_Id :: distinct u32
Local_Id :: distinct u32
Block_Id :: distinct u32
Function_Id :: distinct u32

INVALID_VALUE :: max(Value_Id)
INVALID_BLOCK :: max(Block_Id)

Mir_Local :: struct {
	id:     Local_Id,
	symbol: core.Symbol_Id,
	name:   string, // для print.odin — не читать имя обратно через symbol/resolver
	type:   ^core.Type,
}

Bin_Op :: enum {
	Add,
	Subtract,
	Multiply,
	Divide,
	Int_Divide, // Целое/Целое усечение к нулю — тот же выбор, что Opcode.Int_Divide в compiler.odin, по статическому типу
	Modulo,
	BitAnd,
	BitOr,
	BitXor,
	ShiftLeft,
	ShiftRight,
}

Cmp_Op :: enum {
	Less,
	Greater,
	Equal,
	LessEqual,
	GreaterEqual,
	NotEqual,
}

Un_Op :: enum {
	Negate_Num, // унарный минус
	Negate_Bool, // !
	BitNot,
}

// --- Инструкции (three-address, одна простая операция на инструкцию) ---
//
// Полный набор категорий объявлен сразу (см. план: "extended" поверх
// минимального generic-набора), но lowering (Фаза 1) заполняет только
// подмножество — литералы/локали/бинарные-унарные операторы (включая
// short-circuit через lower_condition)/вызовы/возврат. Cast_Interface/
// Build_Variant/Build_Closure/Spawn/Send/Receive/Receive_Signal/Call_Async/
// Call_Foreign — заявлены здесь, чтобы validate.odin/print.odin были
// исчерпывающими с самого начала (не дописывать case по всем местам на
// каждой следующей фазе), но lowering для них — Фаза 2.

Const_Instr :: struct {
	dst:   Value_Id,
	value: Const_Value,
}

Const_Value :: union {
	f64,
	bool,
	string, // строковый литерал как есть; интернирование/constant-pool — забота backend'а
}

Copy_Instr :: struct {
	dst: Value_Id,
	src: Value_Id,
}

Load_Local_Instr :: struct {
	dst:   Value_Id,
	local: Local_Id,
}

Store_Local_Instr :: struct {
	local: Local_Id,
	src:   Value_Id,
}

Load_Captured_Instr :: struct {
	dst:   Value_Id,
	index: int, // индекс в Closure_Value.captured — та же семантика, что Get_Captured в compiler.odin
}

Binary_Instr :: struct {
	dst: Value_Id,
	op:  Bin_Op,
	lhs: Value_Id,
	rhs: Value_Id,
}

Compare_Instr :: struct {
	dst: Value_Id,
	op:  Cmp_Op,
	lhs: Value_Id,
	rhs: Value_Id,
}

Unary_Instr :: struct {
	dst: Value_Id,
	op:  Un_Op,
	src: Value_Id,
}

// dst — Maybe: вызов может не возвращать значение (returns_value == false
// у Compiled_Function, см. compiler-and-vm.md).
Call_Instr :: struct {
	dst:    Maybe(Value_Id),
	callee: Function_Id,
	args:   []Value_Id,
}

// Call_Value_Instr — вызов через ЗНАЧЕНИЕ (не статически известный
// Function_Id): callee — Value_Id, читаемый из локали/захвата/поля и т.п.
// (например `пер f = функ(...) ... конец; f(...)`, или произвольная
// функция, переданная аргументом). Рантайм-диспетчинг (^Compiled_Function
// vs ^Closure_Value) — забота backend'а (тот же .Call опкод, что сегодня
// обрабатывает оба варианта, см. core/vm.odin), не MIR.
Call_Value_Instr :: struct {
	dst:    Maybe(Value_Id),
	callee: Value_Id,
	args:   []Value_Id,
}

Call_Builtin_Instr :: struct {
	dst:  Maybe(Value_Id),
	name: string, // "модуль::имя", как сегодня в Call_Builtin-константе
	args: []Value_Id,
}

Call_Method_Instr :: struct {
	dst:      Maybe(Value_Id),
	receiver: Value_Id,
	name:     string,
	args:     []Value_Id,
}

// Асинхронная пара (Call_Builtin_Async/Invoke_Collection_Async +
// Await_Async в сегодняшнем bytecode) — на уровне MIR ОДНА инструкция:
// решение sync/async остаётся у backend'а при лоуринге в байткод (та же
// is_async_builtin_name/is_async_stream_method логика, просто на этапе
// MIR→bytecode, а не AST→bytecode). Suspend/resume НЕ моделируется как
// отдельный terminator — на уровне VM это уже сегодня свойство одной
// обычной (не ветвящейся) инструкции (не двигать ip, если результата ещё
// нет), CFG про это ничего не знает и не должен.
Call_Async_Instr :: struct {
	dst:      Maybe(Value_Id),
	receiver: Maybe(Value_Id), // nil для Call_Builtin_Async-формы
	name:     string,
	args:     []Value_Id,
}

Call_Foreign_Instr :: struct {
	dst:  Maybe(Value_Id),
	// Внешние (`внешний`) функции — НЕ Mir_Function (нет MIR-тела, они
	// маршаллятся через libffi, см. core/vm_ffi_native.odin) — Function_Id
	// был бы типовым враньём (индексировал бы module.functions, где их
	// нет). Несём резолвенный ^core.Foreign_Function напрямую, как
	// сегодняшний байткод несёт его через constants-пул.
	fn:   ^core.Foreign_Function,
	args: []Value_Id,
}

New_Aggregate_Instr :: struct {
	dst:       Value_Id,
	type_name: string, // "" для анонимных туплов, как Aggregate_Value.type_name
	elements:  []Value_Id,
}

Get_Property_Instr :: struct {
	dst:         Value_Id,
	object:      Value_Id,
	field_index: int,
}

Set_Property_Instr :: struct {
	object:      Value_Id,
	field_index: int,
	value:       Value_Id,
}

New_Array_Instr :: struct {
	dst:      Value_Id,
	elements: []Value_Id,
}

New_Map_Instr :: struct {
	dst:  Value_Id,
	keys: []Value_Id,
	vals: []Value_Id,
}

Get_Index_Instr :: struct {
	dst:    Value_Id,
	object: Value_Id,
	index:  Value_Id,
}

Set_Index_Instr :: struct {
	object: Value_Id,
	index:  Value_Id,
	value:  Value_Id,
}

// Предрезолвенные (имя_метода, Function_Id)-пары — тот же принцип, что
// Cast_Interface в сегодняшнем байткоде (compile-time vtable через
// Symbol_Id, не рантайм-скан, см. compiler-and-vm.md).
Interface_Method_Binding :: struct {
	method_name: string,
	fn:          Function_Id,
}

Cast_Interface_Instr :: struct {
	dst:    Value_Id,
	src:    Value_Id,
	vtable: []Interface_Method_Binding,
}

Invoke_Interface_Instr :: struct {
	dst:         Maybe(Value_Id),
	receiver:    Value_Id,
	method_name: string,
	args:        []Value_Id,
}

Build_Variant_Instr :: struct {
	dst:          Value_Id,
	type_name:    string,
	variant_name: string,
	tag:          int,
	fields:       []Value_Id,
}

Match_Tag_Instr :: struct {
	dst:     Value_Id, // bool
	subject: Value_Id,
	tag:     int,
}

Get_Variant_Field_Instr :: struct {
	dst:         Value_Id,
	subject:     Value_Id,
	field_index: int,
}

// Terminator, не инструкция — недостижимый выбор (`выбор` без покрытого
// случая) паникует немедленно, дальше по CFG идти некуда, см.
// Unreachable_Term.

Build_Closure_Instr :: struct {
	dst:      Value_Id,
	fn:       Function_Id,
	captured: []Value_Id, // снимок значений на момент Build_Closure — без ячеек, см. план
}

// Function_Ref_Instr — ссылка на функцию КАК ЗНАЧЕНИЕ (не вызов): нулевые
// захватом лямбды (голая ^Compiled_Function-константа в сегодняшнем
// байткоде, без Build_Closure) и передача top-level функции по имени как
// аргумента высшего порядка — оба случая одинаковы на уровне MIR.
Function_Ref_Instr :: struct {
	dst: Value_Id,
	fn:  Function_Id,
}

Spawn_Instr :: struct {
	dst:    Value_Id,
	callee: Function_Id,
	args:   []Value_Id,
}

Send_Instr :: struct {
	process: Value_Id,
	message: Value_Id,
}

Receive_Instr :: struct {
	dst: Value_Id,
}

Receive_Signal_Instr :: struct {
	dst: Value_Id,
}

// `?`-оператор (Try_Expr, .Try_Unwrap опкод в core/vm.odin) — ОБЫЧНАЯ
// инструкция, не terminator: раннее возвращение при неудаче — рантайм-
// семантика ВНУТРИ одного опкода уже сегодня (распаковывает Опция/
// Результат/произвольный 2-вариантный Variant_Value, паникует/рано
// возвращает при неудачном варианте), тот же принцип "невидимо для
// MIR/CFG", что уже применён к Receive/Await_Async — не заводим отдельный
// branch-terminator под это.
Try_Unwrap_Instr :: struct {
	dst: Value_Id,
	src: Value_Id,
}

Mir_Instruction :: union {
	^Const_Instr,
	^Copy_Instr,
	^Load_Local_Instr,
	^Store_Local_Instr,
	^Load_Captured_Instr,
	^Binary_Instr,
	^Compare_Instr,
	^Unary_Instr,
	^Call_Instr,
	^Call_Value_Instr,
	^Call_Builtin_Instr,
	^Call_Method_Instr,
	^Call_Async_Instr,
	^Call_Foreign_Instr,
	^New_Aggregate_Instr,
	^Get_Property_Instr,
	^Set_Property_Instr,
	^New_Array_Instr,
	^New_Map_Instr,
	^Get_Index_Instr,
	^Set_Index_Instr,
	^Cast_Interface_Instr,
	^Invoke_Interface_Instr,
	^Build_Variant_Instr,
	^Match_Tag_Instr,
	^Get_Variant_Field_Instr,
	^Build_Closure_Instr,
	^Function_Ref_Instr,
	^Spawn_Instr,
	^Send_Instr,
	^Receive_Instr,
	^Receive_Signal_Instr,
	^Try_Unwrap_Instr,
}

// --- Place: адрес для присваивания (lower_place, core/mir/lowering.odin)
// — куда писать значение RHS Binary_Expr{op=.Assign}. Не instruction сама
// по себе — используется lowering'ом, чтобы решить, какую именно
// Store_Local/Set_Property/Set_Index-инструкцию эмитить. ---

Local_Place :: struct {
	local: Local_Id,
}

Property_Place :: struct {
	object:      Value_Id,
	field_index: int,
}

Index_Place :: struct {
	object: Value_Id,
	index:  Value_Id,
}

Place :: union {
	^Local_Place,
	^Property_Place,
	^Index_Place,
}

// --- Terminators (ровно один на блок, источник истины для CFG — см.
// core/mir/cfg.odin, отдельный граф не хранится) ---

Jump_Term :: struct {
	target: Block_Id,
}

Branch_Term :: struct {
	cond:       Value_Id,
	then_block: Block_Id,
	else_block: Block_Id,
}

Return_Term :: struct {
	value: Maybe(Value_Id),
}

Unreachable_Term :: struct {
	reason: string, // напр. "match exhaustion" — та же семантика, что сегодняшний Match_Fail
}

Mir_Terminator :: union {
	^Jump_Term,
	^Branch_Term,
	^Return_Term,
	^Unreachable_Term,
}

Mir_Block :: struct {
	id:           Block_Id,
	instructions: [dynamic]Mir_Instruction,
	terminator:   Mir_Terminator, // nil, пока блок не завершён — см. builder.odin
	span:         core.Span,
}

Mir_Function :: struct {
	id:          Function_Id,
	name:        string, // тот же registry-ключ, что Compiled_Function.name сегодня
	symbol:      core.Symbol_Id,
	parameters:  []Local_Id,
	locals:      [dynamic]Mir_Local,
	// value_types[i] — статический тип Value_Id(i); индекс == Value_Id,
	// как и Block_Id/Local_Id == индекс в blocks/locals (см. builder.odin
	// — держать УКАЗАТЕЛЬ на элемент dynamic-массива через границу append
	// небезопасно, поэтому везде id, не ^Mir_Block/^Mir_Local, то же
	// решение, что vm.stack: [dynamic]Value + frame_pointer-индекс вместо
	// сырых указателей, см. core/vm.odin).
	value_types: [dynamic]^core.Type,
	blocks:      [dynamic]Mir_Block,
	entry:       Block_Id,
	result_type: ^core.Type,
	span:        core.Span,
}

Mir_Module :: struct {
	functions: [dynamic]Mir_Function,
	// Ключ — build_instantiation_key (core/monomorphize.odin), тот же
	// человекочитаемый формат "имя_функции$Тип1,Тип2", что и registry-ключ
	// сегодняшнего байткода — генерик-клон не имеет одного стабильного
	// Symbol_Id, разделяемого между инстанциациями, поэтому не может жить
	// в symbol_to_function как обычная функция (см. 2.3k, core/mir/
	// lowering.odin).
	generic_instantiations: map[string]Function_Id,
}
