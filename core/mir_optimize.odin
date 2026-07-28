package core

import "core:math"
import "core:strings"

// Фаза 3 (план): первые оптимизации над уже построенным MIR, между
// lower_module/lower_program_graph и lower_module_to_bytecode. Скоуп
// сознательно узкий (walking skeleton, тот же приём, что и у самого MIR
// в Фазе 1) — две ЛОКАЛЬНЫЕ (без cross-block dataflow) оптимизации:
// устранение соседних store_local+load_local и свёртка констант.
// Порядок ВАЖЕН: устранение соседних store/load идёт ПЕРВЫМ — оно может
// раскрыть прямую ссылку на Const_Instr, которую свёртка констант иначе
// не увидела бы (Load_Local её прятал). Одна итерация каждого прохода,
// без fixed-point — сознательно, расширение при необходимости отдельным
// этапом Фазы 3.
optimize_module :: proc(module: ^Mir_Module) {
	for &fn in module.functions {
		eliminate_adjacent_store_load(&fn)
		fold_constants(&fn)
	}
}

// eliminate_adjacent_store_load — безопасно ТОЛЬКО когда store и load
// идут ВПЛОТНУЮ (ноль инструкций между ними) в одном блоке. backend
// (core/mir_bytecode.odin) — чистый per-block linear replay: любой
// операнд, кроме Mir_Local-доступа, ожидается УЖЕ на вершине VM-стека.
// Store_Local снимает значение со стека в слот; Load_Local позже кладёт
// его обратно. Если между ними ничего не трогало стек — это истинный
// no-op (снять-и-сразу-положить-назад), обе инструкции можно удалить, а
// единственного потребителя load'а (single-use-инвариант) перенаправить
// на исходное значение НАПРЯМУЮ. Если между ними есть ХОТЬ ОДНА
// инструкция — она сама что-то толкает/снимает со стека, и store уже
// по-настоящему нужен (в этом backend'е нет адресации "на глубине N" —
// локаль-слот единственный способ пронести значение через посторонний
// стековый трафик). Дополнительно требуем ровно одно store и ровно одно
// load на локаль ВО ВСЕЙ функции — иначе рискуем тронуть локаль,
// легитимно используемую ещё где-то (напр. match-subject: одно store,
// МНОГО load — уже отсекается требованием load-count == 1).
@(private = "file")
eliminate_adjacent_store_load :: proc(fn: ^Mir_Function) {
	store_count := make(map[Local_Id]int, context.temp_allocator)
	load_count := make(map[Local_Id]int, context.temp_allocator)
	for &blk in fn.blocks {
		for instr in blk.instructions {
			switch v in instr {
			case ^Store_Local_Instr:
				store_count[v.local] += 1
			case ^Load_Local_Instr:
				load_count[v.local] += 1
			case ^Const_Instr, ^Copy_Instr, ^Load_Captured_Instr, ^Binary_Instr,
			     ^Compare_Instr, ^Unary_Instr, ^Call_Instr, ^Call_Value_Instr,
			     ^Call_Builtin_Instr, ^Call_Method_Instr, ^Call_Async_Instr,
			     ^Call_Foreign_Instr, ^New_Aggregate_Instr, ^Get_Property_Instr,
			     ^Set_Property_Instr, ^New_Array_Instr, ^New_Map_Instr,
			     ^Get_Index_Instr, ^Set_Index_Instr, ^Cast_Interface_Instr,
			     ^Invoke_Interface_Instr, ^Build_Variant_Instr, ^Match_Tag_Instr,
			     ^Get_Variant_Field_Instr, ^Build_Closure_Instr, ^Function_Ref_Instr,
			     ^Spawn_Instr, ^Send_Instr, ^Receive_Instr, ^Receive_Signal_Instr,
			     ^Try_Unwrap_Instr:
			// не затрагивают локали
			}
		}
	}

	for &blk in fn.blocks {
		i := 0
		for i < len(blk.instructions) - 1 {
			store, is_store := blk.instructions[i].(^Store_Local_Instr)
			load, is_load := blk.instructions[i + 1].(^Load_Local_Instr)
			if is_store && is_load && store.local == load.local &&
			   store_count[store.local] == 1 && load_count[store.local] == 1 {
				replace_value_id_in_block(&blk, load.dst, store.src)
				ordered_remove(&blk.instructions, i + 1) // сначала load (больший индекс)
				ordered_remove(&blk.instructions, i)
				continue // НЕ увеличиваем i — на этой позиции теперь следующая инструкция
			}
			i += 1
		}
	}
}

// Рассмотрено и ОТКЛОНЕНО (не просто отложено — принципиально небезопасно
// в этом backend'е): "узкое" расширение eliminate_adjacent_store_load на
// cross-block случай (Store_Local — последняя инструкция блока A перед
// безусловным Jump в B; Load_Local — первая в B; у B ровно один
// предшественник). Изначальный план ошибочно посчитал это безопасным по
// аналогии с same-block adjacency — реально построил, и он давал НЕВЕРНЫЙ
// результат (test_match_binder_pattern: 5 стало 0). Причина: устранение
// пары рёвайрит потребителя В БЛОКЕ B на store.src — Value_Id, ОПРЕДЕЛЁННЫЙ
// в блоке A. Это нарушает базовый инвариант (Value_Id используется только
// внутри блока, где определён), на котором держится ВЕСЬ backend
// (mir_bytecode.odin) и remove_dead_constants (fold_constants ниже,
// который считает usage ТОЛЬКО в пределах одного блока) — remove_dead_
// constants увидел v4 (const 5, определённую в A) неиспользованной
// ВНУТРИ A (её единственный потребитель после рёвайринга сидит в B) и
// молча удалил инструкцию целиком. same-block adjacency безопасна ровно
// потому, что там НЕТ границы блока между store и load — здесь она есть,
// и Jump НЕ переносит содержимое VM-стека в новый "контекст" per-block
// replay'я backend'а (каждый блок реплеится независимо, ничего не
// "наследует" из предыдущего блока, кроме того, что реально осталось на
// физическом стеке VM — а store уже снял бы это оттуда). Настоящее
// устранение такой пары потребовало бы переноса ВЫЧИСЛЕНИЯ src в блок B
// (code motion), а не просто удаления store/load — другая, более крупная
// оптимизация, вне скоупа этого раунда.

// replace_value_id_in_block — заменяет ВСЕ вхождения old операндом new во
// всех инструкциях и terminator'е ОДНОГО блока (single-use-инвариант:
// потребитель old, если он есть, живёт в том же блоке, где old
// определён — искать в других блоках не нужно). Исчерпывающий switch —
// тот же список вариантов, что instr_refs (core/mir_validate.odin),
// принцип "лучше явно перечислить все кейсы, чем молча пропустить один".
@(private = "file")
replace_value_id_in_block :: proc(blk: ^Mir_Block, old: Value_Id, new: Value_Id) {
	replace1 :: proc(v: ^Value_Id, old, new: Value_Id) {
		if v^ == old do v^ = new
	}
	replace_slice :: proc(vs: []Value_Id, old, new: Value_Id) {
		for &v in vs do if v == old do v = new
	}

	for instr in blk.instructions {
		switch v in instr {
		case ^Const_Instr, ^Load_Local_Instr, ^Load_Captured_Instr, ^Function_Ref_Instr,
		     ^Receive_Instr, ^Receive_Signal_Instr:
		// нет операндов-Value_Id
		case ^Copy_Instr:
			replace1(&v.src, old, new)
		case ^Store_Local_Instr:
			replace1(&v.src, old, new)
		case ^Binary_Instr:
			replace1(&v.lhs, old, new)
			replace1(&v.rhs, old, new)
		case ^Compare_Instr:
			replace1(&v.lhs, old, new)
			replace1(&v.rhs, old, new)
		case ^Unary_Instr:
			replace1(&v.src, old, new)
		case ^Call_Instr:
			replace_slice(v.args, old, new)
		case ^Call_Value_Instr:
			replace1(&v.callee, old, new)
			replace_slice(v.args, old, new)
		case ^Call_Builtin_Instr:
			replace_slice(v.args, old, new)
		case ^Call_Method_Instr:
			replace1(&v.receiver, old, new)
			replace_slice(v.args, old, new)
		case ^Call_Async_Instr:
			if r, ok := v.receiver.?; ok && r == old do v.receiver = new
			replace_slice(v.args, old, new)
		case ^Call_Foreign_Instr:
			replace_slice(v.args, old, new)
		case ^New_Aggregate_Instr:
			replace_slice(v.elements, old, new)
		case ^Get_Property_Instr:
			replace1(&v.object, old, new)
		case ^Set_Property_Instr:
			replace1(&v.object, old, new)
			replace1(&v.value, old, new)
		case ^New_Array_Instr:
			replace_slice(v.elements, old, new)
		case ^New_Map_Instr:
			replace_slice(v.keys, old, new)
			replace_slice(v.vals, old, new)
		case ^Get_Index_Instr:
			replace1(&v.object, old, new)
			replace1(&v.index, old, new)
		case ^Set_Index_Instr:
			replace1(&v.object, old, new)
			replace1(&v.index, old, new)
			replace1(&v.value, old, new)
		case ^Cast_Interface_Instr:
			replace1(&v.src, old, new)
		case ^Invoke_Interface_Instr:
			replace1(&v.receiver, old, new)
			replace_slice(v.args, old, new)
		case ^Build_Variant_Instr:
			replace_slice(v.fields, old, new)
		case ^Match_Tag_Instr:
			replace1(&v.subject, old, new)
		case ^Get_Variant_Field_Instr:
			replace1(&v.subject, old, new)
		case ^Build_Closure_Instr:
			replace_slice(v.captured, old, new)
		case ^Spawn_Instr:
			replace1(&v.callee, old, new)
			replace_slice(v.args, old, new)
		case ^Send_Instr:
			replace1(&v.process, old, new)
			replace1(&v.message, old, new)
		case ^Try_Unwrap_Instr:
			replace1(&v.src, old, new)
		}
	}

	switch t in blk.terminator {
	case ^Jump_Term, ^Unreachable_Term:
	case ^Branch_Term:
		if t.cond == old do t.cond = new
	case ^Return_Term:
		if val, ok := t.value.?; ok && val == old do t.value = new
	}
}

// fold_constants — арифметика/сравнения/унарные операции над
// Const_Instr-операндами свёртываются в один Const_Instr. Семантика
// операций скопирована с core/vm.odin's execute() (та же f64<->i64
// конвертация для битовых, то же усечение к нулю для Int_Divide,
// LessEqual/GreaterEqual/NotEqual — та же логическая форма, что backend
// синтезирует из Less/Greater/Equal+Negate, см. core/mir_bytecode.odin) —
// НЕ переизобретена заново, чтобы не разойтись рантайм-поведением.
// Divide/Int_Divide/Modulo с константным rhs == 0 НЕ сворачиваются —
// оставлено рантайму (Divide даёт IEEE754 Inf/NaN без паники, Int_Divide/
// Modulo паникуют "деление на ноль" — свёртка не должна тихо менять это
// поведение на compile-time). После свёртки инструкции, чьи операнды
// были Const_Instr, эти Const_Instr МОГУТ остаться с нулём потребителей
// (одноразовость операнда — единственным потребителем был as раз
// свёрнутый Binary/Compare/Unary_Instr) — backend всё равно "переиграл"
// бы их пуш в байткод, оставив мусор на VM-стеке (тот же класс бага, что
// Match_Tag peek-leftover, см. mir_bytecode.odin). Финальный проход
// чистит любой Const_Instr с нулевым usage-count.
@(private = "file")
fold_constants :: proc(fn: ^Mir_Function) {
	for &blk in fn.blocks {
		const_val := make(map[Value_Id]Const_Value, context.temp_allocator)

		for &instr in blk.instructions {
			switch v in instr {
			case ^Const_Instr:
				const_val[v.dst] = v.value

			case ^Binary_Instr:
				lv, lok := const_val[v.lhs]
				rv, rok := const_val[v.rhs]
				if !lok || !rok do continue
				if folded, ok := fold_binary(v.op, lv, rv); ok {
					instr = new_const_instr(v.dst, folded)
					const_val[v.dst] = folded
				}

			case ^Compare_Instr:
				lv, lok := const_val[v.lhs]
				rv, rok := const_val[v.rhs]
				if !lok || !rok do continue
				if folded, ok := fold_compare(v.op, lv, rv); ok {
					instr = new_const_instr(v.dst, folded)
					const_val[v.dst] = folded
				}

			case ^Unary_Instr:
				sv, sok := const_val[v.src]
				if !sok do continue
				if folded, ok := fold_unary(v.op, sv); ok {
					instr = new_const_instr(v.dst, folded)
					const_val[v.dst] = folded
				}

			case ^Copy_Instr, ^Load_Local_Instr, ^Store_Local_Instr, ^Load_Captured_Instr,
			     ^Call_Instr, ^Call_Value_Instr, ^Call_Builtin_Instr, ^Call_Method_Instr,
			     ^Call_Async_Instr, ^Call_Foreign_Instr, ^New_Aggregate_Instr,
			     ^Get_Property_Instr, ^Set_Property_Instr, ^New_Array_Instr, ^New_Map_Instr,
			     ^Get_Index_Instr, ^Set_Index_Instr, ^Cast_Interface_Instr,
			     ^Invoke_Interface_Instr, ^Build_Variant_Instr, ^Match_Tag_Instr,
			     ^Get_Variant_Field_Instr, ^Build_Closure_Instr, ^Function_Ref_Instr,
			     ^Spawn_Instr, ^Send_Instr, ^Receive_Instr, ^Receive_Signal_Instr,
			     ^Try_Unwrap_Instr:
			// не свёртываются
			}
		}

		fold_constant_branch(&blk, const_val)
		remove_dead_constants(&blk)
	}
}

// fold_constant_branch — если Branch_Term.cond свёрнут в константный
// bool (той же const_val картой, что и обычная свёртка выше в этом
// блоке), заменяем терминатор на Jump_Term к живой ветке. Безопасно и
// дёшево: Cfg_Info (core/mir_cfg.odin) пересчитывается заново из
// terminator'ов на каждый вызов (никогда не кэшируется) — backend
// (core/mir_bytecode.odin's emit_function_body) уже эмитит ТОЛЬКО блоки
// из reverse_postorder (entry-достижимые); как только "мёртвая" ветка
// теряет ЕДИНСТВЕННОГО предшественника (верно by construction — если/&&/
// || строят блоки заново на каждое выражение, не шарят), она перестаёт
// быть достижимой и просто не эмитится — существующая инфраструктура
// Фазы 2 поглощает это бесплатно, без отдельного прохода "удалить мёртвый
// блок". Константное условие означает "эта ветка математически никогда
// не исполнится ни на каком запуске" — не эвристика, поэтому отбрасывать
// её код (включая побочные эффекты внутри) безусловно корректно. Match_
// Tag_Instr's dst никогда не попадает в const_val (только Const_Instr
// туда пишет) — выбор/match естественно не задет этим проходом, без
// специального исключения.
@(private = "file")
fold_constant_branch :: proc(blk: ^Mir_Block, const_val: map[Value_Id]Const_Value) {
	branch, is_branch := blk.terminator.(^Branch_Term)
	if !is_branch do return
	cond_val, ok := const_val[branch.cond]
	if !ok do return
	cond_bool, is_bool := cond_val.(bool)
	if !is_bool do return

	jump := new(Jump_Term)
	jump.target = cond_bool ? branch.then_block : branch.else_block
	blk.terminator = jump
}

@(private = "file")
new_const_instr :: proc(dst: Value_Id, value: Const_Value) -> ^Const_Instr {
	i := new(Const_Instr)
	i.dst = dst
	i.value = value
	return i
}

// remove_dead_constants — Const_Instr с usage-count 0 в ЭТОМ блоке
// (инструкции блока + terminator) удаляются. Только Const_Instr —
// безопасно ровно потому, что у него нет побочных эффектов и нет
// стекового предусловия сверх пуша литерала; удаление орфанной
// инструкции ЛЮБОГО другого вида (напр. вызова) было бы небезопасно.
@(private = "file")
remove_dead_constants :: proc(blk: ^Mir_Block) {
	used := make(map[Value_Id]bool, context.temp_allocator)
	for instr in blk.instructions {
		_, operands := instr_refs(instr, context.temp_allocator)
		for op in operands do used[op] = true
	}
	switch t in blk.terminator {
	case ^Jump_Term, ^Unreachable_Term:
	case ^Branch_Term:
		used[t.cond] = true
	case ^Return_Term:
		if val, ok := t.value.?; ok do used[val] = true
	}

	i := 0
	for i < len(blk.instructions) {
		if c, is_const := blk.instructions[i].(^Const_Instr); is_const && !used[c.dst] {
			ordered_remove(&blk.instructions, i)
			continue
		}
		i += 1
	}
}

// НЕ private = "file" — core/mir_optimize_test.odin зовёт напрямую для
// точечной проверки "rhs==0 не сворачивается" без обхода через реальный
// не-константный источник в программе.
fold_binary :: proc(op: Bin_Op, l: Const_Value, r: Const_Value) -> (Const_Value, bool) {
	// '+' работает и над Строка (конкатенация, см. core/vm.odin's case
	// .Add) — единственный Bin_Op, который не требует f64 обеих сторон.
	if op == .Add {
		if ls, lok := l.(string); lok {
			if rs, rok := r.(string); rok do return strings.concatenate({ls, rs}), true
		}
	}

	lf, lok := l.(f64)
	rf, rok := r.(f64)
	if !lok || !rok do return nil, false

	switch op {
	case .Add:
		return lf + rf, true
	case .Subtract:
		return lf - rf, true
	case .Multiply:
		return lf * rf, true
	case .Divide:
		return lf / rf, true // rhs==0 -> Inf/NaN, то же самое, что рантайм
	case .Int_Divide:
		if rf == 0 do return nil, false // рантайм паникует "деление на ноль" — не сворачиваем
		return math.trunc(lf / rf), true
	case .Modulo:
		if rf == 0 do return nil, false
		return math.mod(lf, rf), true
	case .BitAnd:
		return f64(i64(lf) & i64(rf)), true
	case .BitOr:
		return f64(i64(lf) | i64(rf)), true
	case .BitXor:
		return f64(i64(lf) ~ i64(rf)), true
	case .ShiftLeft:
		return f64(i64(lf) << uint(i64(rf))), true
	case .ShiftRight:
		return f64(i64(lf) >> uint(i64(rf))), true
	}
	return nil, false
}

@(private = "file")
fold_compare :: proc(op: Cmp_Op, l: Const_Value, r: Const_Value) -> (Const_Value, bool) {
	// Equal/NotEqual работают над любой парой ОДНОТИПНЫХ констант
	// (f64/bool/строка) — та же структурная семантика, что value_equals
	// (core/vm.odin) для этих трёх примитивных вариантов.
	if op == .Equal || op == .NotEqual {
		eq: bool
		switch lv in l {
		case f64:
			rv, ok := r.(f64)
			if !ok do return nil, false
			eq = lv == rv
		case bool:
			rv, ok := r.(bool)
			if !ok do return nil, false
			eq = lv == rv
		case string:
			rv, ok := r.(string)
			if !ok do return nil, false
			eq = lv == rv
		case nil:
			return nil, false
		}
		return op == .Equal ? eq : !eq, true
	}

	// Less/Greater/LessEqual/GreaterEqual — только f64 (упорядоченность
	// строк/bool типизатор для < > не допускает).
	lf, lok := l.(f64)
	rf, rok := r.(f64)
	if !lok || !rok do return nil, false

	switch op {
	case .Less:
		return lf < rf, true
	case .Greater:
		return lf > rf, true
	// LessEqual/GreaterEqual — та же логическая форма, что backend
	// синтезирует из Greater/Less+Negate (core/mir_bytecode.odin) —
	// сохраняем идентичное поведение, не "просто <=" на IEEE754 NaN-
	// краях (хотя для f64 без NaN разницы нет, единообразие важнее).
	case .LessEqual:
		return !(lf > rf), true
	case .GreaterEqual:
		return !(lf < rf), true
	case .Equal, .NotEqual:
	// обработаны выше
	}
	return nil, false
}

@(private = "file")
fold_unary :: proc(op: Un_Op, src: Const_Value) -> (Const_Value, bool) {
	switch op {
	case .Negate_Num:
		if f, ok := src.(f64); ok do return -f, true
	case .Negate_Bool:
		if b, ok := src.(bool); ok do return !b, true
	case .BitNot:
		if f, ok := src.(f64); ok do return f64(~i64(f)), true
	}
	return nil, false
}
