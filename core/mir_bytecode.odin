package core

import "core:fmt"

// MIR -> bytecode (Стадия 2.4, план). Per-block ЛИНЕЙНЫЙ replay, НЕ
// register allocator — держится на инварианте, зафиксированном в плане
// Фазы 2 и перепроверенном валидатором (core/mir/validate.odin): каждый
// Value_Id используется НЕ БОЛЬШЕ одного раза и только внутри блока, где
// определён. Из этого следует, что операнд ЛЮБОЙ инструкции, если он не
// Mir_Local (Get_Local/Set_Local индекс — тот же слот, что и сегодня), в
// момент использования уже лежит на вершине VM-стека — backend просто
// переигрывает MIR-инструкции блока по порядку, ничего не отслеживая
// самостоятельно (тот же стек-машинный инвариант, что compile_expr уже
// использует сегодня: любое скомпилированное выражение имеет чистый
// эффект стека "+1", не трогая ничего под своими собственными пушами).
//
// ОДНО реальное исключение из "просто переиграть": callee для .Call/
// .Spawn core/vm.odin читает СО СТЕКА СТРОГО ПОД аргументами
// (`callee_index := len(vm.stack) - 1 - arg_count`) — lowering.odin уже
// подготовил это правильно (emit_fn_ref эмитится ДО аргументов на всех
// call site'ах, см. её докстринг) — backend просто переигрывает и это
// корректно "бесплатно". ЕДИНСТВЕННОЕ место, требующее backend-специфичной
// (не чисто replay) логики — Match_Tag: core/vm.odin's .Match_Tag ЧИТАЕТ
// subject БЕЗ снятия (peek), кладёт bool ПОВЕРХ — после потребления bool
// веткой (Jump_If_False) subject остаётся на стеке МУСОРОМ. Старый
// компилятор с этим мирится (реальный `.Return` целиком обрезает стек
// текущего фрейма — resize(&vm.stack, callee_index) в return_from_
// current_frame, так что промежуточный мусор невиден программе, только
// временно живёт до конца текущего вызова функции — эмпирически
// проверено, core/vm.odin:157). MIR-модель трактует subject как ОБЫЧНО
// потреблённое значение (single-use), поэтому backend явно эмитит Pop на
// ОБЕИХ ветках Branch, если её cond пришёл от Match_Tag_Instr — стек
// остаётся сбалансированным без опоры на "почистится при Return".

Bytecode_Fixup :: struct {
	operand_pos: int, // байтовая позиция начала 2-байтового операнда
	target:      Block_Id,
	// Jump_If_False (core/vm.odin) декодирует операнд как ЗНАКОВЫЙ i16 НЕТ
	// — как БЕЗЗНАКОВЫЙ u16, добавляемый напрямую (`frame.ip += int(offset)`),
	// т.е. всегда вперёд. Jump — знаковый i16 (может назад, для циклов).
	// См. core/vm.odin case .Jump_If_False/.Jump.
	unsigned_forward_only: bool,
}

Bytecode_Ctx :: struct {
	module:         ^Mir_Module,
	fn:             ^Compiled_Function,
	mir_fn:         ^Mir_Function,
	block_offsets:  map[Block_Id]int,
	fixups:         [dynamic]Bytecode_Fixup,
	// Function_Id -> уже созданный (возможно ещё не заполненный телом)
	// ^Compiled_Function — тот же двухпроходный hoist-затем-compile
	// принцип, что core/compiler.odin's compile_program, нужен для
	// Function_Ref_Instr/Cast_Interface.vtable (forward references/
	// рекурсия между функциями).
	compiled:       ^map[Function_Id]^Compiled_Function,
}

// lower_module_to_bytecode — единственная точка входа. Возвращает тот же
// map[string]^Compiled_Function registry-shape, что compile_program
// сегодня — взаимозаменяемо для run_scheduler/new_vm.
lower_module_to_bytecode :: proc(module: ^Mir_Module) -> map[string]^Compiled_Function {
	registry := make(map[string]^Compiled_Function)
	compiled := make(map[Function_Id]^Compiled_Function)

	// Проход 1: заготовки (имя/frame_size/returns_value уже известны из
	// Mir_Function без лоуринга тела) — forward references.
	for &mfn, i in module.functions {
		fn := new(Compiled_Function)
		fn.name = mfn.name
		fn.instructions = make([dynamic]u8)
		fn.constants = make([dynamic]Value)
		fn.frame_size = len(mfn.locals)
		fn.returns_value = prune_type(mfn.result_type) != TY_VOID
		registry[mfn.name] = fn
		compiled[Function_Id(i)] = fn
	}

	// Проход 2: тела.
	for &mfn, i in module.functions {
		bctx := Bytecode_Ctx {
			module        = module,
			fn            = compiled[Function_Id(i)],
			mir_fn        = &mfn,
			block_offsets = make(map[Block_Id]int),
			fixups        = make([dynamic]Bytecode_Fixup),
			compiled      = &compiled,
		}
		emit_function_body(&bctx)
	}

	return registry
}

@(private = "file")
emit_function_body :: proc(bctx: ^Bytecode_Ctx) {
	info := compute_cfg_info(bctx.mir_fn)
	defer destroy_cfg_info(&info)

	for block_id in info.reverse_postorder {
		bctx.block_offsets[block_id] = len(bctx.fn.instructions)
		blk := &bctx.mir_fn.blocks[int(block_id)]
		emit_block_body(bctx, blk)
		emit_terminator(bctx, blk, blk.terminator)
	}

	// Разрешаем все fixup'ы теперь, когда block_offsets полон.
	for fx in bctx.fixups {
		target_offset, ok := bctx.block_offsets[fx.target]
		if !ok {
			panic("bytecode backend: fixup ссылается на недостижимый/несуществующий блок")
		}
		rel := target_offset - (fx.operand_pos + 2)
		if fx.unsigned_forward_only {
			if rel < 0 {
				panic("bytecode backend: Jump_If_False на блок НАЗАД — нарушен инвариант (Branch_Term должен быть вперёд, см. reverse_postorder)")
			}
			write_u16(bctx.fn, fx.operand_pos, u16(rel))
		} else {
			write_u16(bctx.fn, fx.operand_pos, u16(i16(rel)))
		}
	}
}

@(private = "file")
write_u16 :: proc(fn: ^Compiled_Function, pos: int, v: u16) {
	fn.instructions[pos] = u8(v >> 8)
	fn.instructions[pos + 1] = u8(v & 0xFF)
}

@(private = "file")
mir_emit_byte :: proc(fn: ^Compiled_Function, b: u8) {
	append(&fn.instructions, b)
}

@(private = "file")
emit_op :: proc(fn: ^Compiled_Function, op: Opcode) {
	append(&fn.instructions, u8(op))
}

@(private = "file")
make_const :: proc(fn: ^Compiled_Function, v: Value) -> u8 {
	if len(fn.constants) >= 255 {
		panic("bytecode backend: константный пул функции переполнен (>255)")
	}
	append(&fn.constants, v)
	return u8(len(fn.constants) - 1)
}

@(private = "file")
const_str :: proc(fn: ^Compiled_Function, s: string) -> u8 {
	return make_const(fn, Value(perm_string(s)))
}

// emit_placeholder_jump — эмитит opcode + 2-байтовый placeholder,
// регистрирует fixup. Возвращает byte-позицию начала операнда.
@(private = "file")
emit_placeholder_jump :: proc(bctx: ^Bytecode_Ctx, op: Opcode, target: Block_Id, unsigned_forward_only: bool) {
	emit_op(bctx.fn, op)
	pos := len(bctx.fn.instructions)
	mir_emit_byte(bctx.fn, 0xFF)
	mir_emit_byte(bctx.fn, 0xFF)
	append(&bctx.fixups, Bytecode_Fixup{operand_pos = pos, target = target, unsigned_forward_only = unsigned_forward_only})
}

// block_ends_with_match_tag — true если блок's ПОСЛЕДНЯЯ инструкция —
// Match_Tag_Instr, чей dst равен переданному cond (т.е. blk.terminator —
// Branch_Term, потребляющий РОВНО этот Match_Tag напрямую). lower_pattern
// (core/mir/lowering.odin) ВСЕГДА строит именно такую форму (Match_Tag —
// последняя инструкция блока, немедленно перед terminate(Branch_Term)),
// так что эта проверка надёжна для ВСЕГО текущего lowering — не
// эвристика "на всякий случай", а прямое следствие lower_pattern's
// структуры.
@(private = "file")
block_ends_with_match_tag :: proc(blk: ^Mir_Block, cond: Value_Id) -> bool {
	if len(blk.instructions) == 0 do return false
	last := blk.instructions[len(blk.instructions) - 1]
	mt, ok := last.(^Match_Tag_Instr)
	return ok && mt.dst == cond
}

@(private = "file")
emit_terminator :: proc(bctx: ^Bytecode_Ctx, blk: ^Mir_Block, term: Mir_Terminator) {
	switch t in term {
	case ^Jump_Term:
		emit_placeholder_jump(bctx, .Jump, t.target, false)
	case ^Branch_Term:
		// Match_Tag (core/vm.odin) ЧИТАЕТ subject БЕЗ СНЯТИЯ (peek),
		// кладёт bool ПОВЕРХ — после того, как Jump_If_False снимает bool
		// как условие, subject остаётся мусором на стеке НА ОБЕИХ ветках.
		// MIR трактует subject как ОБЫЧНО потреблённое значение (single-
		// use) — явно балансируем стек Pop'ом на обеих ветках, вместо
		// того чтобы полагаться на "почистится при .Return" (см. докстринг
		// в начале файла — так делает старый компилятор, но это НЕ
		// свойство, на которое стоит молчаливо полагаться в новом коде).
		if block_ends_with_match_tag(blk, t.cond) {
			// И else_block, И then_block могут быть РАЗДЕЛЯЕМЫ другими
			// предшественниками (например Literal-паттерн, не проходящий
			// через Match_Tag вообще — тот же общий fail_block, см.
			// lower_pattern) — нельзя вставить Pop В НАЧАЛО общего блока,
			// это затронуло бы предшественников, которым Pop не нужен.
			// Вместо этого — Pop эмитится ИНЛАЙН здесь же, на обеих
			// ветках, ДО прыжка на реальный target (никакого нового MIR-
			// блока не создаётся, просто пара лишних байт в ТЕКУЩЕЙ
			// позиции потока байткода):
			//   Jump_If_False <inline-false-stub>
			//   Pop; Jump <then_block>            (true-путь)
			//   <inline-false-stub:> Pop; Jump <else_block>  (false-путь)
			jf_pos := len(bctx.fn.instructions)
			emit_op(bctx.fn, .Jump_If_False)
			mir_emit_byte(bctx.fn, 0xFF)
			mir_emit_byte(bctx.fn, 0xFF)

			emit_op(bctx.fn, .Pop)
			emit_placeholder_jump(bctx, .Jump, t.then_block, false)

			false_stub_offset := len(bctx.fn.instructions)
			write_u16(bctx.fn, jf_pos + 1, u16(false_stub_offset - (jf_pos + 3)))

			emit_op(bctx.fn, .Pop)
			emit_placeholder_jump(bctx, .Jump, t.else_block, false)
			return
		}
		emit_placeholder_jump(bctx, .Jump_If_False, t.else_block, true)
		emit_placeholder_jump(bctx, .Jump, t.then_block, false)
	case ^Return_Term:
		if v, ok := t.value.?; ok {
			_ = v // значение уже на стеке (single-use, только что вычислено)
		}
		emit_op(bctx.fn, .Return)
	case ^Unreachable_Term:
		// Match_Fail — рантайм-паника на недостижимую ветку (Match_Fail
		// исторически снимает subject как аргумент диагностики, см.
		// core/vm.odin — но у Unreachable_Term нет привязанного Value_Id
		// (может быть достигнут без subject'а, напр. если/выбор с обеими
		// ветками расходящимися) — эмитим Match_Fail с фиктивным nil-
		// значением через Constant, сохраняя опкод, а не изобретая новый.
		emit_op(bctx.fn, .Constant)
		mir_emit_byte(bctx.fn, const_str(bctx.fn, t.reason))
		emit_op(bctx.fn, .Match_Fail)
	case nil:
		panic("bytecode backend: блок без terminator'а дошёл до backend'а (validate_function должен был это поймать)")
	}
}

@(private = "file")
emit_block_body :: proc(bctx: ^Bytecode_Ctx, blk: ^Mir_Block) {
	for idx in 0 ..< len(blk.instructions) {
		instr := blk.instructions[idx]
		emit_instr(bctx, instr)
	}
}

@(private = "file")
resolve_fn :: proc(bctx: ^Bytecode_Ctx, fn_id: Function_Id) -> ^Compiled_Function {
	return bctx.compiled^[fn_id]
}

@(private = "file")
emit_instr :: proc(bctx: ^Bytecode_Ctx, instr: Mir_Instruction) {
	fn := bctx.fn
	switch v in instr {
	case ^Const_Instr:
		switch cv in v.value {
		case f64:
			emit_op(fn, .Constant)
			mir_emit_byte(fn, make_const(fn, Value(cv)))
		case bool:
			emit_op(fn, .Constant)
			mir_emit_byte(fn, make_const(fn, Value(cv)))
		case string:
			emit_op(fn, .Constant)
			mir_emit_byte(fn, const_str(fn, cv))
		}

	case ^Copy_Instr:
	// Value_Id-алиас без своей инструкции сегодня не эмитится lowering'ом
	// (Copy_Instr объявлен для будущих optimization-проходов, Фаза 3) —
	// если когда-нибудь появится, копия — просто "ничего не делать",
	// значение и так на стеке под тем же именем.

	case ^Load_Local_Instr:
		emit_op(fn, .Get_Local)
		mir_emit_byte(fn, u8(v.local))

	case ^Store_Local_Instr:
		emit_op(fn, .Set_Local)
		mir_emit_byte(fn, u8(v.local))

	case ^Load_Captured_Instr:
		emit_op(fn, .Get_Captured)
		mir_emit_byte(fn, u8(v.index))

	case ^Binary_Instr:
		#partial switch v.op {
		case .Add: emit_op(fn, .Add)
		case .Subtract: emit_op(fn, .Subtract)
		case .Multiply: emit_op(fn, .Multiply)
		case .Divide: emit_op(fn, .Divide)
		case .Int_Divide: emit_op(fn, .Int_Divide)
		case .Modulo: emit_op(fn, .Modulo)
		case .BitAnd: emit_op(fn, .BitAnd)
		case .BitOr: emit_op(fn, .BitOr)
		case .BitXor: emit_op(fn, .BitXor)
		case .ShiftLeft: emit_op(fn, .ShiftLeft)
		case .ShiftRight: emit_op(fn, .ShiftRight)
		}

	case ^Compare_Instr:
		#partial switch v.op {
		case .Less: emit_op(fn, .Less)
		case .Greater: emit_op(fn, .Greater)
		case .Equal: emit_op(fn, .Equal)
		case .LessEqual: emit_op(fn, .Greater); emit_op(fn, .Negate)
		case .GreaterEqual: emit_op(fn, .Less); emit_op(fn, .Negate)
		case .NotEqual: emit_op(fn, .Equal); emit_op(fn, .Negate)
		}

	case ^Unary_Instr:
		#partial switch v.op {
		case .Negate_Num:
			emit_op(fn, .Constant)
			mir_emit_byte(fn, make_const(fn, Value(f64(-1))))
			emit_op(fn, .Multiply)
		case .Negate_Bool: emit_op(fn, .Negate)
		case .BitNot: emit_op(fn, .BitNot)
		}

	case ^Function_Ref_Instr:
		emit_op(fn, .Constant)
		mir_emit_byte(fn, make_const(fn, Value(resolve_fn(bctx, v.fn))))

	case ^Call_Instr:
		// lowering.odin больше не эмитит Call_Instr напрямую (всегда через
		// Function_Ref_Instr + Call_Value_Instr, см. lowering.odin's
		// emit_fn_ref докстринг) — оставлен как валидный, но недостижимый
		// в текущем lowering случай (полная поддержка, не паника, на
		// случай будущего прямого использования оптимизациями).
		emit_op(fn, .Call)
		mir_emit_byte(fn, u8(len(v.args)))

	case ^Call_Value_Instr:
		emit_op(fn, .Call)
		mir_emit_byte(fn, u8(len(v.args)))

	case ^Call_Builtin_Instr:
		emit_op(fn, .Call_Builtin)
		mir_emit_byte(fn, const_str(fn, v.name))
		mir_emit_byte(fn, u8(len(v.args)))

	case ^Call_Method_Instr:
		emit_op(fn, .Invoke_Collection)
		mir_emit_byte(fn, const_str(fn, v.name))
		mir_emit_byte(fn, u8(len(v.args)))

	case ^Call_Async_Instr:
		if _, has_receiver := v.receiver.?; has_receiver {
			emit_op(fn, .Invoke_Collection_Async)
		} else {
			emit_op(fn, .Call_Builtin_Async)
		}
		mir_emit_byte(fn, const_str(fn, v.name))
		mir_emit_byte(fn, u8(len(v.args)))
		emit_op(fn, .Await_Async)

	case ^Call_Foreign_Instr:
		emit_op(fn, .Call_Foreign)
		mir_emit_byte(fn, make_const(fn, Value(v.fn)))
		mir_emit_byte(fn, u8(len(v.args)))

	case ^New_Aggregate_Instr:
		if v.type_name == "" {
			emit_op(fn, .Build_Aggregate)
			mir_emit_byte(fn, u8(len(v.elements)))
		} else {
			emit_op(fn, .Build_Aggregate_Named)
			mir_emit_byte(fn, const_str(fn, v.type_name))
			mir_emit_byte(fn, u8(len(v.elements)))
		}

	case ^Get_Property_Instr:
		emit_op(fn, .Get_Property)
		mir_emit_byte(fn, u8(v.field_index))

	case ^Set_Property_Instr:
		emit_op(fn, .Set_Property)
		mir_emit_byte(fn, u8(v.field_index))

	case ^New_Array_Instr:
		emit_op(fn, .Build_Array)
		mir_emit_byte(fn, u8(len(v.elements)))

	case ^New_Map_Instr:
		emit_op(fn, .Build_Map)
		mir_emit_byte(fn, u8(len(v.keys)))

	case ^Get_Index_Instr:
		emit_op(fn, .Get_Index)

	case ^Set_Index_Instr:
		emit_op(fn, .Set_Index)

	case ^Cast_Interface_Instr:
		emit_op(fn, .Cast_Interface)
		if len(v.vtable) > 255 {
			panic("bytecode backend: слишком много методов для интерфейсной vtable (>255)")
		}
		mir_emit_byte(fn, u8(len(v.vtable)))
		for binding in v.vtable {
			mir_emit_byte(fn, const_str(fn, binding.method_name))
			mir_emit_byte(fn, make_const(fn, Value(resolve_fn(bctx, binding.fn))))
		}

	case ^Invoke_Interface_Instr:
		emit_op(fn, .Invoke_Interface)
		mir_emit_byte(fn, const_str(fn, v.method_name))
		mir_emit_byte(fn, u8(len(v.args)))

	case ^Build_Variant_Instr:
		emit_op(fn, .Build_Variant)
		mir_emit_byte(fn, const_str(fn, v.type_name))
		mir_emit_byte(fn, const_str(fn, v.variant_name))
		mir_emit_byte(fn, u8(v.tag))
		mir_emit_byte(fn, u8(len(v.fields)))

	case ^Match_Tag_Instr:
		emit_op(fn, .Match_Tag)
		mir_emit_byte(fn, make_const(fn, Value(f64(v.tag))))
	// Match_Tag ЧИТАЕТ БЕЗ СНЯТИЯ (peek) — оставляет subject под
	// результирующим bool. Потребитель (всегда Branch_Term по MIR-
	// дизайну lower_pattern) обязан убрать этот "хвост" сам — см.
	// emit_terminator's особый случай ниже (branch_cond_is_match_tag).

	case ^Get_Variant_Field_Instr:
		emit_op(fn, .Get_Variant_Field)
		mir_emit_byte(fn, u8(v.field_index))

	case ^Build_Closure_Instr:
		emit_op(fn, .Build_Closure)
		mir_emit_byte(fn, make_const(fn, Value(resolve_fn(bctx, v.fn))))
		mir_emit_byte(fn, u8(len(v.captured)))

	case ^Spawn_Instr:
		emit_op(fn, .Spawn)
		mir_emit_byte(fn, u8(len(v.args)))

	case ^Send_Instr:
	// Сегодняшний lowering не эмитит Send_Instr напрямую (отправить()
	// идёт через Call_Builtin_Instr, см. lower_call_expr) — оставлен для
	// полноты Mir_Instruction, недостижим из текущего lowering.
	case ^Receive_Instr:
		emit_op(fn, .Receive)
	case ^Receive_Signal_Instr:
		emit_op(fn, .Receive_Signal)
	case ^Try_Unwrap_Instr:
		emit_op(fn, .Try_Unwrap)
	}
}

@(private = "file")
value_type_from_id :: proc(mir_fn: ^Mir_Function, v: Value_Id) -> ^Type {
	if v == INVALID_VALUE do return nil
	return mir_fn.value_types[int(v)]
}
