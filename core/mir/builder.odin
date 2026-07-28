package mir

import core "../"

// Mir_Builder — тонкая обёртка над одной ^Mir_Function, накапливающая
// инструкции в "текущий" блок. Block_Id/Local_Id/Value_Id — ИНДЕКСЫ в
// function.blocks/locals/value_types (не сырые указатели) — append в
// dynamic-массив может реаллоцировать backing buffer, инвалидируя любой
// ранее взятый ^T (тот же паттерн, что vm.stack: [dynamic]Value +
// frame_pointer-индекс в core/vm.odin, а не сырой указатель на слот).
Mir_Builder :: struct {
	function:      ^Mir_Function,
	current_block: Block_Id,
	terminated:    bool, // true между terminate() и следующим set_current_block()
}

new_module :: proc() -> Mir_Module {
	return Mir_Module{functions = make([dynamic]Mir_Function)}
}

// Резервирует слот функции в модуле. ВАЖНО (двухпроходный lowering, см.
// core/mir/lowering.odin): все new_function-вызовы для модуля должны
// завершиться ДО того, как что-либо берёт индекс/билдер для лоуринга тел
// — после начала лоуринга тел (проход 2) в module.functions больше
// ничего не добавляется, иначе индексы, взятые в проходе 2, могли бы
// указывать не туда после реаллокации (в данном случае используются
// именно ИНДЕКСЫ, не указатели, так что реаллокация сама по себе не
// ломает корректность — но добавлять функции по ходу прохода 2 всё равно
// не предусмотрено дизайном: symbol_to_function должен быть полным ДО
// прохода 2).
new_function :: proc(
	module: ^Mir_Module,
	name: string,
	symbol: core.Symbol_Id,
	result_type: ^core.Type,
	span: core.Span,
) -> Function_Id {
	id := Function_Id(len(module.functions))
	append(
		&module.functions,
		Mir_Function {
			id = id,
			name = name,
			symbol = symbol,
			locals = make([dynamic]Mir_Local),
			value_types = make([dynamic]^core.Type),
			blocks = make([dynamic]Mir_Block),
			entry = INVALID_BLOCK,
			result_type = result_type,
			span = span,
		},
	)
	return id
}

// begin_function — создаёт билдер для лоуринга ТЕЛА функции, уже
// зарезервированной через new_function. Сразу заводит entry-блок.
begin_function :: proc(module: ^Mir_Module, fn_id: Function_Id) -> Mir_Builder {
	fn := &module.functions[int(fn_id)]
	b := Mir_Builder {
		function = fn,
	}
	entry := new_block(&b)
	fn.entry = entry
	set_current_block(&b, entry)
	return b
}

new_block :: proc(b: ^Mir_Builder) -> Block_Id {
	id := Block_Id(len(b.function.blocks))
	append(&b.function.blocks, Mir_Block{id = id, instructions = make([dynamic]Mir_Instruction)})
	return id
}

set_current_block :: proc(b: ^Mir_Builder, id: Block_Id) {
	b.current_block = id
	b.terminated = b.function.blocks[int(id)].terminator != nil
}

new_local :: proc(
	b: ^Mir_Builder,
	symbol: core.Symbol_Id,
	name: string,
	type: ^core.Type,
) -> Local_Id {
	id := Local_Id(len(b.function.locals))
	append(&b.function.locals, Mir_Local{id = id, symbol = symbol, name = name, type = type})
	return id
}

new_value :: proc(b: ^Mir_Builder, type: ^core.Type) -> Value_Id {
	id := Value_Id(len(b.function.value_types))
	append(&b.function.value_types, type)
	return id
}

value_type :: proc(b: ^Mir_Builder, v: Value_Id) -> ^core.Type {
	return b.function.value_types[int(v)]
}

current_block :: proc(b: ^Mir_Builder) -> ^Mir_Block {
	return &b.function.blocks[int(b.current_block)]
}

// emit/terminate паникуют, если текущий блок УЖЕ завершён — тот же
// инвариант, что Flow_Result в lowering.odin обязан соблюдать: после
// возврат/прервать/продолжить lowering не должен пытаться дописать в тот
// же блок (core/mir/lowering.odin читает Flow_Result и сам не зовёт
// emit/terminate дальше, эта паника — второй, defensive рубеж).
emit :: proc(b: ^Mir_Builder, instr: Mir_Instruction) {
	if b.terminated {
		panic("mir.emit: текущий блок уже завершён terminator'ом")
	}
	blk := current_block(b)
	append(&blk.instructions, instr)
}

terminate :: proc(b: ^Mir_Builder, term: Mir_Terminator) {
	if b.terminated {
		panic("mir.terminate: текущий блок уже завершён terminator'ом")
	}
	blk := current_block(b)
	blk.terminator = term
	b.terminated = true
}

is_terminated :: proc(b: ^Mir_Builder) -> bool {
	return b.terminated
}
