package mir

import core "../"

// Mir_Builder — тонкая обёртка над ОДНОЙ функцией модуля, накапливающая
// инструкции в "текущий" блок. Ссылается на функцию через module+fn_id
// (индекс), НЕ через сырой ^Mir_Function — тот же принцип, что уже
// применён к Block_Id/Local_Id/Value_Id (append в dynamic-массив может
// реаллоцировать backing buffer, инвалидируя любой ранее взятый ^T).
// Раньше (Фаза 1) держался сырой ^Mir_Function, что было безопасно ПОКА
// module.functions не менялся во время лоуринга тела — двухпроходный
// lowering.odin гарантировал это для top-level функций. Замыкания (Фаза
// 2) ломают эту гарантию: Lambda_Expr регистрирует СВОЙ Mir_Function
// ЛЕНИВО, посреди лоуринга ВНЕШНЕЙ функции (тот же приём, что
// core/compiler.odin делает для Compiled_Function лямбды сегодня — нет
// отдельного хостинг-прохода для лямбд), а append в module.functions на
// этом моменте мог бы реаллоцировать и инвалидировать держащийся снаружи
// указатель. Индекс+свежий разыменование на каждое обращение снимает эту
// проблему целиком — как и убирает необходимость в инварианте "все
// new_function ДО лоуринга тел" (см. историю этого файла).
Mir_Builder :: struct {
	module:        ^Mir_Module,
	fn_id:         Function_Id,
	current_block: Block_Id,
	terminated:    bool, // true между terminate() и следующим set_current_block()
}

new_module :: proc() -> Mir_Module {
	return Mir_Module {
		functions = make([dynamic]Mir_Function),
		generic_instantiations = make(map[string]Function_Id),
	}
}

// Резервирует слот функции в модуле. Безопасно вызывать в ЛЮБОЙ момент —
// в т.ч. посреди лоуринга ТЕЛА другой функции (замыкания) — все ссылки
// на функцию идут через Function_Id, не через указатель.
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

// current_function — свежее разыменование module.functions[fn_id] НА
// КАЖДЫЙ вызов (не кэшируется в Mir_Builder), см. комментарий над
// Mir_Builder.
current_function :: proc(b: ^Mir_Builder) -> ^Mir_Function {
	return &b.module.functions[int(b.fn_id)]
}

// begin_function — создаёт билдер для лоуринга ТЕЛА функции, уже
// зарезервированной через new_function. Сразу заводит entry-блок.
begin_function :: proc(module: ^Mir_Module, fn_id: Function_Id) -> Mir_Builder {
	b := Mir_Builder {
		module = module,
		fn_id  = fn_id,
	}
	entry := new_block(&b)
	current_function(&b).entry = entry
	set_current_block(&b, entry)
	return b
}

new_block :: proc(b: ^Mir_Builder) -> Block_Id {
	fn := current_function(b)
	id := Block_Id(len(fn.blocks))
	append(&fn.blocks, Mir_Block{id = id, instructions = make([dynamic]Mir_Instruction)})
	return id
}

set_current_block :: proc(b: ^Mir_Builder, id: Block_Id) {
	b.current_block = id
	b.terminated = current_function(b).blocks[int(id)].terminator != nil
}

new_local :: proc(
	b: ^Mir_Builder,
	symbol: core.Symbol_Id,
	name: string,
	type: ^core.Type,
) -> Local_Id {
	fn := current_function(b)
	id := Local_Id(len(fn.locals))
	append(&fn.locals, Mir_Local{id = id, symbol = symbol, name = name, type = type})
	return id
}

new_value :: proc(b: ^Mir_Builder, type: ^core.Type) -> Value_Id {
	fn := current_function(b)
	id := Value_Id(len(fn.value_types))
	append(&fn.value_types, type)
	return id
}

value_type :: proc(b: ^Mir_Builder, v: Value_Id) -> ^core.Type {
	return current_function(b).value_types[int(v)]
}

current_block :: proc(b: ^Mir_Builder) -> ^Mir_Block {
	return &current_function(b).blocks[int(b.current_block)]
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
