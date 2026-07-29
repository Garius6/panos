package core

import "core:fmt"

// wasm_emit.odin — Фаза 1 WASM AOT-бэкенда: обходит MIR-функцию и эмитит
// байты тела в WASM binary format. Структурные решения (loop-header?,
// тело-vs-выход цикла?, куда сливаются если/иначе?) — через
// core/wasm_stackify.odin; упаковка секций модуля — core/wasm_module.odin
// (emit_function_wasm вызывается оттуда).
//
// process_from — рекурсивный обход, где КАЖДЫЙ Value_Id уже лежит на
// вершине WASM-operand-стека к моменту потребления (тот же per-block
// linear-replay инвариант, что core/mir_bytecode.odin уже использует —
// однократное использование Value_Id ТОЛЬКО внутри блока, где он
// определён, см. core/mir_validate.odin:44-51 — здесь распространяется на
// WASM-стек естественно, без изменений).
//
// stop_at — блок, ПРИНАДЛЕЖАЩИЙ ВЫЗЫВАЮЩЕМУ (известный СТАТИЧЕСКИ, ДО
// рекурсии — см. wasm_stackify.odin's find_merge/identify_loop_body_and_exit):
// если region доходит до stop_at, он возвращает его как fallthrough БЕЗ
// эмиссии — это позволяет корректно различить "разделяемая с ВНЕШНИМ кодом
// точка" (напр. exit_block цикла, к которому ведёт и `прервать` изнутри
// вложенного если/иначе, И собственная else-ветка header'а) от "точка
// слияния МОИХ СОБСТВЕННЫХ двух веток" (если/иначе, найденная через
// доминацию до рекурсии, а не эвристикой "больше одного предшественника" —
// та путает обе ситуации, см. докстринг wasm_stackify.odin).

Emit_Ctx :: struct {
	module:            ^Mir_Module,
	fn:                ^Mir_Function,
	info:              Cfg_Info,
	rpo_index:         map[Block_Id]int,
	idom:              map[Block_Id]Block_Id,
	visited:           map[Block_Id]bool, // только для back-edge теста (Jump на уже эмитированный header)
	scope_stack:       [dynamic]Wasm_Scope,
	code:              [dynamic]u8,
	// Function_Ref_Instr непосредственно перед Call_Value_Instr — тот же
	// структурный факт, на который опирается core/mir_bytecode.odin
	// (emit_fn_ref emitted ДО аргументов на ВСЕХ call site'ах, см. её
	// докстринг). ВАЖНО: это значит callee лежит НИЖЕ аргументов на
	// MIR-стеке (Function_Ref_Instr первый, затем аргументы, затем
	// Call_Value_Instr) — а WASM's call_indirect требует table-индекс
	// СВЕРХУ (последним операндом, ПОСЛЕ аргументов), т.е. ПРОТИВОПОЛОЖНЫЙ
	// порядок. Поэтому Function_Ref_Instr НЕ кладёт значение на
	// operand-стек вообще — сохраняет его в СОБСТВЕННУЮ (на каждый
	// Function_Ref_Instr — свою, см. next_callee_local: вложенные вызовы,
	// напр. `f(g(1), 2)`, иначе перезаписали бы общую ячейку между
	// собственным Function_Ref_Instr'ом g и f) i32-scratch-локаль, а
	// Call_Value_Instr перечитывает её local.get'ом ПОСЛЕ того, как
	// аргументы уже легли на стек обычным replay — восстанавливая нужный
	// WASM-порядок.
	value_to_callee:    map[Value_Id]Callee_Info,
	next_callee_local:  int,
	scratch_base:       int, // индекс первого из 2 f64 scratch-локалей (Modulo/битовые)
	// Исходный Function_Id (индекс в module.functions) -> компактный wasm
	// funcidx/typeidx/table-slot (см. core/wasm_module.odin's
	// lower_module_to_wasm — прелюдийные функции выброшены, нумерация
	// сдвинута).
	func_index:         ^map[Function_Id]int,
	use_count:          map[Value_Id]int, // см. emit_block_instructions
}

Callee_Info :: struct {
	fn:    Function_Id,
	local: int,
}

Wasm_Scope :: struct {
	kind:   enum {
		Loop,
		If,
	},
	header: Block_Id, // осмысленно только для Loop — br к нему = continue
}

@(private = "file")
new_emit_ctx :: proc(module: ^Mir_Module, fn: ^Mir_Function, func_index: ^map[Function_Id]int) -> Emit_Ctx {
	info := compute_cfg_info(fn)
	rpo_index := build_rpo_index(&info)
	ectx := Emit_Ctx {
		module           = module,
		fn               = fn,
		info             = info,
		rpo_index        = rpo_index,
		idom             = compute_idom(fn, &info, rpo_index),
		visited          = make(map[Block_Id]bool),
		scope_stack      = make([dynamic]Wasm_Scope),
		code             = make([dynamic]u8),
		value_to_callee  = make(map[Value_Id]Callee_Info),
		scratch_base     = len(fn.locals),
		next_callee_local = len(fn.locals) + WASM_SCRATCH_COUNT,
		func_index       = func_index,
		use_count        = compute_use_count(fn),
	}
	return ectx
}

@(private = "file")
destroy_emit_ctx :: proc(ectx: ^Emit_Ctx) {
	destroy_cfg_info(&ectx.info)
	delete(ectx.rpo_index)
	delete(ectx.idom)
	delete(ectx.visited)
	delete(ectx.scope_stack)
	delete(ectx.value_to_callee)
	delete(ectx.use_count)
}

// compute_use_count — сколько раз каждый Value_Id прочитан как операнд (по
// всей функции — инвариант single-use гарантирует не больше 1, см.
// core/mir_validate.odin), включая terminator'ы (Branch.cond,
// Return.value), которые instr_refs (там же) не покрывает (он про
// инструкции блока, не про terminator).
@(private = "file")
compute_use_count :: proc(fn: ^Mir_Function, allocator := context.allocator) -> map[Value_Id]int {
	uc := make(map[Value_Id]int, allocator)
	for &blk in fn.blocks {
		for instr in blk.instructions {
			_, operands := instr_refs(instr)
			for op in operands {
				if op != INVALID_VALUE do uc[op] = uc[op] + 1
			}
			delete(operands)
		}
		switch t in blk.terminator {
		case ^Branch_Term:
			uc[t.cond] = uc[t.cond] + 1
		case ^Return_Term:
			if v, ok := t.value.?; ok do uc[v] = uc[v] + 1
		case ^Jump_Term, ^Unreachable_Term, nil:
		}
	}
	return uc
}

WASM_SCRATCH_COUNT :: 2

// emit_function_wasm — тело функции в code-секции: вектор деклараций
// локалей + сами инструкции + завершающий 0x0B. Вызывается из
// core/wasm_module.odin.
emit_function_wasm :: proc(module: ^Mir_Module, mfn: ^Mir_Function, func_index: ^map[Function_Id]int) -> [dynamic]u8 {
	ectx := new_emit_ctx(module, mfn, func_index)
	defer destroy_emit_ctx(&ectx)

	process_from(&ectx, mfn.entry, INVALID_BLOCK)

	// n_callee_locals посчитан ТОЛЬКО СЕЙЧАС (после process_from) — каждый
	// Function_Ref_Instr, встреченный по пути, завёл себе одну i32-локаль
	// (см. Callee_Info в докстринге Emit_Ctx) — то же самое, что уже было
	// сделано ниже для scratch_base/WASM_SCRATCH_COUNT: тело эмитится
	// ПЕРВЫМ, декларация локалей строится по факту того, что реально
	// понадобилось.
	n_callee_locals := ectx.next_callee_local - (ectx.scratch_base + WASM_SCRATCH_COUNT)

	out := make([dynamic]u8)
	n_body_locals := len(mfn.locals) - len(mfn.parameters)
	write_uleb128(&out, u64(n_body_locals + WASM_SCRATCH_COUNT + n_callee_locals))
	for i in len(mfn.parameters) ..< len(mfn.locals) {
		write_uleb128(&out, 1)
		append(&out, wasm_val_type(mfn.locals[i].type))
	}
	for _ in 0 ..< WASM_SCRATCH_COUNT {
		write_uleb128(&out, 1)
		append(&out, WASM_F64)
	}
	for _ in 0 ..< n_callee_locals {
		write_uleb128(&out, 1)
		append(&out, WASM_I32)
	}
	for b in ectx.code do append(&out, b)
	append(&out, 0x0B) // end функции

	return out
}

@(private = "file")
find_br_depth :: proc(ectx: ^Emit_Ctx, target: Block_Id) -> int {
	for i := len(ectx.scope_stack) - 1; i >= 0; i -= 1 {
		s := ectx.scope_stack[i]
		if s.kind == .Loop && s.header == target {
			return (len(ectx.scope_stack) - 1) - i
		}
	}
	panic("wasm backend: br-цель не найдена среди открытых scope (нарушен структурный инвариант — см. wasm_stackify.odin)")
}

// process_from — эмитит блок b и всё, структурно принадлежащее его
// региону, пока не упрётся в stop_at (граница, известная ВЫЗЫВАЮЩЕМУ
// заранее — см. докстринг файла) или в Return/Unreachable/back-edge.
// Возвращает (stop_at, true), если регион нормально "падает" в stop_at
// (вызывающий продолжает оттуда), иначе (_, false) — все пути region'а
// либо вернулись/запаниковали, либо ушли в цикл через br.
process_from :: proc(ectx: ^Emit_Ctx, start: Block_Id, stop_at: Block_Id) -> (fallthrough_block: Block_Id, ok: bool) {
	b := start
	for {
		if b == stop_at do return b, true

		if is_loop_header(&ectx.info, ectx.rpo_index, b) && !ectx.visited[b] {
			ectx.visited[b] = true
			blk := &ectx.fn.blocks[int(b)]
			br, is_branch := blk.terminator.(^Branch_Term)
			if !is_branch {
				panic("wasm backend: loop header без Branch_Term — нарушен инвариант lower_while_expr")
			}
			body, exit := identify_loop_body_and_exit(ectx.fn, b, br.then_block, br.else_block)

			append(&ectx.code, 0x03, 0x40) // loop (пустой blocktype)
			append(&ectx.scope_stack, Wasm_Scope{kind = .Loop, header = b})
			// header's собственные инструкции (вычисление cond) — ВНУТРИ
			// loop, не до него: cond — часть тела while (`пока cond
			// цикл`), должен пересчитываться КАЖДУЮ итерацию через br 0
			// назад на начало loop, а не единожды перед первым входом
			// (реальный баг, найденный через дифференциальный тест —
			// wasmtime валидатор ловит несбалансированный стек на второй
			// итерации, когда cond'а уже нет на стеке).
			emit_block_instructions(ectx, blk)
			// cond теперь на стеке — if потребляет его: true -> тело,
			// false -> пустой else, падение сквозь end/end наружу цикла.
			append(&ectx.code, 0x04, 0x40) // if (пустой blocktype)
			append(&ectx.scope_stack, Wasm_Scope{kind = .If})
			// Возврат process_from(body,...) игнорируется намеренно: тело
			// ВСЕГДА либо доходит до stop_at=exit (напр. через `прервать`,
			// возможно из вложенного если/иначе), либо завершается через
			// back-edge-br/return/unreachable — в ОБОИХ случаях к этой
			// точке (закрытие if/loop) тело уже полностью эмитировано; что
			// именно произошло, здесь не важно — дальше в любом случае
			// exit_block.
			process_from(ectx, body, exit)
			pop(&ectx.scope_stack) // if
			append(&ectx.code, 0x05) // else — пусто
			append(&ectx.code, 0x0B) // end if
			pop(&ectx.scope_stack) // loop
			append(&ectx.code, 0x0B) // end loop

			b = exit
			continue
		}

		ectx.visited[b] = true
		blk := &ectx.fn.blocks[int(b)]
		emit_block_instructions(ectx, blk)

		switch t in blk.terminator {
		case ^Jump_Term:
			if ectx.visited[t.target] && is_loop_header(&ectx.info, ectx.rpo_index, t.target) {
				depth := find_br_depth(ectx, t.target)
				append(&ectx.code, 0x0C) // br
				write_uleb128(&ectx.code, u64(depth))
				return INVALID_BLOCK, false
			}
			b = t.target
			continue

		case ^Branch_Term:
			merge, has_merge := find_merge(ectx.fn, ectx.idom, b, t.then_block, t.else_block)
			sub_stop := has_merge ? merge : stop_at

			// cond уже на стеке.
			append(&ectx.code, 0x04, 0x40) // if (пустой blocktype)
			append(&ectx.scope_stack, Wasm_Scope{kind = .If})
			then_fall, then_ok := process_from(ectx, t.then_block, sub_stop)
			append(&ectx.code, 0x05) // else
			else_fall, else_ok := process_from(ectx, t.else_block, sub_stop)
			append(&ectx.code, 0x0B) // end if
			pop(&ectx.scope_stack)

			if has_merge {
				b = merge
				continue
			}
			if then_ok {
				b = then_fall
				continue
			}
			if else_ok {
				b = else_fall
				continue
			}
			return INVALID_BLOCK, false

		case ^Return_Term:
			append(&ectx.code, 0x0F) // return
			return INVALID_BLOCK, false

		case ^Unreachable_Term:
			append(&ectx.code, 0x00) // unreachable
			return INVALID_BLOCK, false

		case nil:
			panic("wasm backend: блок без terminator'а (validate_function должен был это поймать)")
		}
	}
}

// emit_block_instructions — реплеит инструкции блока (см. докстринг файла).
// mir_bytecode.odin's replay-модели БЕЗРАЗЛИЧНО, использован ли dst
// инструкции (неиспользованное значение — просто "мусор", живущий на
// vm.stack до Return, который целиком обрезает стек фрейма) — MIR
// действительно оставляет такие (напр. lower_while_expr's 0.0-заглушка
// для while-как-выражения, см. её докстринг: "значение цикла как
// выражения не нужно... кладёт константный 0.0-заполнитель", НИКЕМ не
// потребляемый). WASM's структурный валидатор ТАК не может — каждый
// блок/if/loop/функция обязаны иметь СТАТИЧЕСКИ сбалансированную высоту
// стека на границах (см. wasm_diff_while_break_continue: без этой правки
// "expected i32 but nothing on stack" — реальная находка, не гипотеза).
// Поэтому: значение с нулём использований (use_count, см. instr_refs,
// core/mir_validate.odin) — сразу drop'ается.
@(private = "file")
emit_block_instructions :: proc(ectx: ^Emit_Ctx, blk: ^Mir_Block) {
	for instr in blk.instructions {
		emit_mir_instr(ectx, instr)
		// Function_Ref_Instr — единственная dst-инструкция, которая
		// НАМЕРЕННО не кладёт значение на стек в этом бэкенде (см. её
		// case выше) — drop для нулевого использования был бы лишним
		// и/или некорректным (нечего снимать).
		if _, is_fn_ref := instr.(^Function_Ref_Instr); is_fn_ref do continue
		dst, operands := instr_refs(instr)
		delete(operands)
		if d, ok := dst.?; ok && ectx.use_count[d] == 0 {
			append(&ectx.code, 0x1A) // drop
		}
	}
}

@(private = "file")
value_kind :: proc(ectx: ^Emit_Ctx, v: Value_Id) -> Type_Kind {
	return prune_type(ectx.fn.value_types[int(v)]).kind
}

@(private = "file")
resolve_func_index :: proc(ectx: ^Emit_Ctx, fn: Function_Id) -> int {
	idx, ok := ectx.func_index^[fn]
	if !ok {
		panic("wasm backend Фаза 1: вызов функции вне области Фазы 1 (не Число/Целое/Булево сигнатура — см. is_wasm_phase1_function)")
	}
	return idx
}

@(private = "file")
emit_mir_instr :: proc(ectx: ^Emit_Ctx, instr: Mir_Instruction) {
	code := &ectx.code
	switch v in instr {
	case ^Const_Instr:
		switch cv in v.value {
		case f64:
			append(code, 0x44) // f64.const
			write_f64_le(code, cv)
		case bool:
			append(code, 0x41) // i32.const
			write_sleb128(code, cv ? 1 : 0)
		case string:
			panic("wasm backend Фаза 1: строковые константы не поддержаны (нет heap-значений)")
		}

	case ^Load_Local_Instr:
		append(code, 0x20) // local.get
		write_uleb128(code, u64(v.local))

	case ^Store_Local_Instr:
		append(code, 0x21) // local.set
		write_uleb128(code, u64(v.local))

	case ^Binary_Instr:
		emit_binary_op(ectx, v.op)

	case ^Compare_Instr:
		emit_compare_op(ectx, v.op, value_kind(ectx, v.lhs))

	case ^Unary_Instr:
		emit_unary_op(ectx, v.op)

	case ^Function_Ref_Instr:
		// НЕ кладёт значение на operand-стек — см. Callee_Info в
		// докстринге Emit_Ctx (порядок callee/аргументов у MIR
		// противоположен тому, что нужен WASM call_indirect).
		wasm_idx := resolve_func_index(ectx, v.fn)
		local := ectx.next_callee_local
		ectx.next_callee_local += 1
		append(code, 0x41) // i32.const
		write_sleb128(code, i64(wasm_idx))
		append(code, 0x21) // local.set
		write_uleb128(code, u64(local))
		ectx.value_to_callee[v.dst] = Callee_Info{fn = v.fn, local = local}

	case ^Call_Instr:
		wasm_idx := resolve_func_index(ectx, v.callee)
		append(code, 0x10) // call
		write_uleb128(code, u64(wasm_idx))

	case ^Call_Value_Instr:
		info, known := ectx.value_to_callee[v.callee]
		if !known {
			panic("wasm backend Фаза 1: вызов через значение поддержан только для статически известного Function_Ref_Instr (см. план)")
		}
		wasm_idx := resolve_func_index(ectx, info.fn)
		append(code, 0x20) // local.get callee — ПОСЛЕ аргументов (уже на стеке из replay), см. Callee_Info
		write_uleb128(code, u64(info.local))
		append(code, 0x11) // call_indirect
		write_uleb128(code, u64(wasm_idx)) // typeidx == funcidx (см. wasm_module.odin)
		write_uleb128(code, 0) // tableidx 0

	case ^Copy_Instr,
	     ^Load_Captured_Instr,
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
	     ^Spawn_Instr,
	     ^Send_Instr,
	     ^Receive_Instr,
	     ^Receive_Signal_Instr,
	     ^Try_Unwrap_Instr:
		panic(fmt.tprintf("wasm backend Фаза 1: инструкция %T вне области Фазы 1 (см. план — heap/builtins/interfaces/closures/actors отложены)", v))
	}
}

@(private = "file")
emit_binary_op :: proc(ectx: ^Emit_Ctx, op: Bin_Op) {
	code := &ectx.code
	#partial switch op {
	case .Add:
		append(code, 0xA0) // f64.add
	case .Subtract:
		append(code, 0xA1) // f64.sub
	case .Multiply:
		append(code, 0xA2) // f64.mul
	case .Divide:
		append(code, 0xA3) // f64.div
	case .Int_Divide:
		append(code, 0xA3, 0x9C) // f64.div; f64.trunc (усечение к нулю, как math.trunc)
	case .Modulo:
		emit_modulo(ectx)
	case .BitAnd:
		emit_bitwise_f64(ectx, 0x83) // i64.and
	case .BitOr:
		emit_bitwise_f64(ectx, 0x84) // i64.or
	case .BitXor:
		emit_bitwise_f64(ectx, 0x85) // i64.xor
	case .ShiftLeft:
		emit_bitwise_f64(ectx, 0x86) // i64.shl
	case .ShiftRight:
		emit_bitwise_f64(ectx, 0x87) // i64.shr_s
	case:
		panic("wasm backend: неизвестный Bin_Op")
	}
}

// emit_modulo — l - trunc(l/r)*r (fmod-семантика, знак следует делимому,
// см. core/vm.odin's .Modulo). l/r с operand-стека (l первым, r сверху,
// см. mir_lowering.odin's lower_binary_expr) требуются ДВАЖДЫ каждый —
// single-use MIR-инвариант этого не позволяет напрямую, поэтому оба
// временно сохраняются в scratch-локали функции (см. WASM_SCRATCH_COUNT).
@(private = "file")
emit_modulo :: proc(ectx: ^Emit_Ctx) {
	code := &ectx.code
	l_slot := u64(ectx.scratch_base)
	r_slot := u64(ectx.scratch_base + 1)
	append(code, 0x21) // local.set r_slot (снимает r — верхний)
	write_uleb128(code, r_slot)
	append(code, 0x21) // local.set l_slot (снимает l)
	write_uleb128(code, l_slot)

	append(code, 0x20) // local.get l  -> [l]
	write_uleb128(code, l_slot)
	append(code, 0x20) // local.get l  -> [l, l]
	write_uleb128(code, l_slot)
	append(code, 0x20) // local.get r  -> [l, l, r]
	write_uleb128(code, r_slot)
	append(code, 0xA3) // f64.div      -> [l, l/r]
	append(code, 0x9C) // f64.trunc    -> [l, trunc(l/r)]
	append(code, 0x20) // local.get r  -> [l, trunc(l/r), r]
	write_uleb128(code, r_slot)
	append(code, 0xA2) // f64.mul      -> [l, trunc(l/r)*r]
	append(code, 0xA1) // f64.sub      -> [l - trunc(l/r)*r]
}

// emit_bitwise_f64 — panos's Целое на рантайме f64 (см. core/vm.odin's
// .BitAnd и т.п.): конвертируем оба операнда в i64, применяем битовую
// операцию, конвертируем обратно. rhs (верхний на стеке) временно
// сохраняется в scratch-локаль, чтобы можно было конвертировать lhs
// (снизу) в i64 первым — WASM-конверсии применяются только к вершине стека.
@(private = "file")
emit_bitwise_f64 :: proc(ectx: ^Emit_Ctx, i64_op: u8) {
	code := &ectx.code
	r_slot := u64(ectx.scratch_base + 1)
	append(code, 0x21) // local.set r_slot (снимает r=rhs) -> [l]
	write_uleb128(code, r_slot)
	append(code, 0xB0) // i64.trunc_f64_s (l -> l_i64) -> [l_i64]
	append(code, 0x20) // local.get r -> [l_i64, r_f64]
	write_uleb128(code, r_slot)
	append(code, 0xB0) // i64.trunc_f64_s -> [l_i64, r_i64]
	append(code, i64_op) // -> [result_i64]
	append(code, 0xB9) // f64.convert_i64_s -> [result_f64]
}

@(private = "file")
emit_unary_op :: proc(ectx: ^Emit_Ctx, op: Un_Op) {
	code := &ectx.code
	#partial switch op {
	case .Negate_Num:
		append(code, 0x9A) // f64.neg
	case .Negate_Bool:
		append(code, 0x45) // i32.eqz (x==0, инверсия 0/1-булева)
	case .BitNot:
		append(code, 0xB0) // i64.trunc_f64_s
		append(code, 0x42) // i64.const
		write_sleb128(code, -1)
		append(code, 0x85) // i64.xor (xor с -1 == побитовое НЕ)
		append(code, 0xB9) // f64.convert_i64_s
	case:
		panic("wasm backend: неизвестный Un_Op")
	}
}

@(private = "file")
emit_compare_op :: proc(ectx: ^Emit_Ctx, op: Cmp_Op, operand_kind: Type_Kind) {
	code := &ectx.code
	is_bool := operand_kind == .Bool
	#partial switch op {
	case .Less:
		if is_bool do panic("wasm backend: '<' для Булево не должно возникать (typechecker должен был отклонить)")
		append(code, 0x63) // f64.lt
	case .Greater:
		if is_bool do panic("wasm backend: '>' для Булево не должно возникать")
		append(code, 0x64) // f64.gt
	case .Equal:
		append(code, is_bool ? 0x46 : 0x61) // i32.eq / f64.eq
	case .LessEqual:
		if is_bool do panic("wasm backend: '<=' для Булево не должно возникать")
		append(code, 0x65) // f64.le
	case .GreaterEqual:
		if is_bool do panic("wasm backend: '>=' для Булево не должно возникать")
		append(code, 0x66) // f64.ge
	case .NotEqual:
		append(code, is_bool ? 0x47 : 0x62) // i32.ne / f64.ne
	case:
		panic("wasm backend: неизвестный Cmp_Op")
	}
}
