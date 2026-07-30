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
	// closures (см. план): И Function_Ref_Instr, И Build_Closure_Instr
	// строят один и тот же вид объекта — [fn_index, captured_0, ...]
	// arena-хендл (см. emit_closure_value) и КЛАДУТ его на operand-стек
	// НОРМАЛЬНО, как любая другая dst-инструкция — НЕ по-особому (первая
	// версия этого бэкенда пыталась не класть хендл на стек вовсе, как
	// раньше делал только Function_Ref_Instr для callee — оказалось
	// некорректно: тот же Value_Id может быть потреблён Store_Local_
	// Instr'ом (`пер f = функ(...)...конец`) или обычным аргументом
	// (`применить(удвоить, 21)` — Function_Ref_Instr'а докстринг САМ
	// описывает этот случай), а не только немедленным Call_Value_Instr —
	// найдено реальным "expected i32 but nothing on stack" от wasmtime,
	// не гипотезой).
	//
	// Раз callee всегда лоурится ДО аргументов (структурный факт, на
	// который опирается и core/mir_bytecode.odin — emit_fn_ref эмитится
	// ДО аргументов на ВСЕХ call site'ах), а WASM's call_indirect
	// требует table-индекс СВЕРХУ (последним операндом, ПОСЛЕ
	// аргументов) — Call_Value_Instr САМ разгребает порядок на месте:
	// снимает args в scratch (в обратном порядке), снимает callee в
	// scratch, восстанавливает args — см. её case. value_to_closure_fn
	// НЕ участвует в этой механике вообще — это ЧИСТО O(1)-путь для
	// typeidx: когда callee — Value_Id, произведённый Function_Ref_
	// Instr/Build_Closure_Instr В ТОЙ ЖЕ функции (не через Store_Local/
	// Load_Local — самый частый случай, включая ВСЕ существовавшие ДО
	// closures тесты, см. emit_fn_ref/emit_call_value в mir_lowering.
	// odin), fn известен статически — resolve_func_index даёт typeidx
	// без структурного скана. Когда callee пришёл ИЗДАЛЕКА (через
	// локаль/параметр/захват — настоящее значение-функция) — записи не
	// будет, find_call_value_typeidx делает структурный скан-фоллбэк
	// (см. её докстринг).
	value_to_closure_fn: map[Value_Id]Function_Id,
	scratch_base:       int, // индекс первого из 2 f64 scratch-локалей (Modulo/битовые)
	i32_pool_base:      int, // индекс первого из I32_SCRATCH_POOL_SIZE scratch-локалей
	f64_pool_base:      int, // индекс первого из F64_SCRATCH_POOL_SIZE scratch-локалей
	next_i32_scratch:   int,
	next_f64_scratch:   int,
	// Исходный Function_Id (индекс в module.functions) -> компактный wasm
	// funcidx/typeidx/table-slot (см. core/wasm_module.odin's
	// lower_module_to_wasm — прелюдийные функции выброшены, нумерация
	// сдвинута).
	func_index:         ^map[Function_Id]int,
	// План interop с внешний: ^Foreign_Function (get_or_build_foreign_
	// function кеширует ОДИН на Foreign_Decl, переиспользуется всеми call
	// site'ами — pointer identity надёжнее строкового "либа::имя" ключа)
	// -> funcidx нового wasm-import'а (core/wasm_module.odin). Пустая
	// map, если в программе нет ни одного внешний.
	foreign_func_index: ^map[^Foreign_Function]int,
	// План todo-демо: база "сеть"-import-группы (core/wasm_module.odin's
	// net_base) — самостоятельная переменная, НЕ компайл-тайм константа
	// (в отличие от PW_DOM_*), т.к. dom и сеть эмитятся НЕЗАВИСИМО друг
	// от друга — сдвиг сети зависит от того, эмитирован ли dom. Читается
	// только когда сеть::http_запрос_sync реально эмитируется — самосог-
	// ласовано тем же принципом, что PW_DOM_*-константы (см. их докстринг
	// в wasm_module.odin).
	net_base:           int,
	use_count:          map[Value_Id]int, // см. emit_block_instructions
}

Wasm_Scope :: struct {
	kind:   enum {
		Loop,
		If,
	},
	header: Block_Id, // осмысленно только для Loop — br к нему = continue
}

@(private = "file")
new_emit_ctx :: proc(
	module: ^Mir_Module,
	fn: ^Mir_Function,
	func_index: ^map[Function_Id]int,
	foreign_func_index: ^map[^Foreign_Function]int,
	net_base: int,
) -> Emit_Ctx {
	info := compute_cfg_info(fn)
	rpo_index := build_rpo_index(&info)
	// +1: __env занимает WASM-параметр-слот P (см. план closures,
	// "Local-index collision") — тело-локали и scratch-пулы сдвинуты
	// на один WASM-индекс относительно len(fn.locals) (было ==,
	// т.к. Local_Id == WASM-индекс без __env).
	scratch_base := len(fn.locals) + 1
	i32_pool_base := scratch_base + WASM_SCRATCH_COUNT
	f64_pool_base := i32_pool_base + I32_SCRATCH_POOL_SIZE
	ectx := Emit_Ctx {
		module                 = module,
		fn                     = fn,
		info                   = info,
		rpo_index              = rpo_index,
		idom                   = compute_idom(fn, &info, rpo_index),
		visited                = make(map[Block_Id]bool),
		scope_stack            = make([dynamic]Wasm_Scope),
		code                   = make([dynamic]u8),
		value_to_closure_fn    = make(map[Value_Id]Function_Id),
		scratch_base           = scratch_base,
		i32_pool_base          = i32_pool_base,
		f64_pool_base          = f64_pool_base,
		next_i32_scratch       = i32_pool_base,
		next_f64_scratch       = f64_pool_base,
		func_index             = func_index,
		foreign_func_index     = foreign_func_index,
		net_base               = net_base,
		use_count              = compute_use_count(fn),
	}
	return ectx
}

// alloc_i32_scratch/alloc_f64_scratch — свежая локаль из фиксированного
// пула (см. Emit_Ctx's докстринг про Function_Ref_Instr/New_Aggregate_
// Instr) — размер пула фиксирован ЗАРАНЕЕ (I32/F64_SCRATCH_POOL_SIZE),
// поэтому декларация локалей функции (emit_function_wasm) не должна ждать
// конца эмиссии тела, чтобы узнать точный размер (в отличие от Фазы 1,
// где n_callee_locals считался ПОСЛЕ process_from) — просто, ценой
// декларации фиксированного числа локалей даже если реально использована
// лишь часть (незаметные лишние байты в секции локалей, не рантайм-
// накладные расходы — оправдано для размера фикстур Фазы 1.5).
@(private = "file")
alloc_i32_scratch :: proc(ectx: ^Emit_Ctx) -> int {
	idx := ectx.next_i32_scratch
	ectx.next_i32_scratch += 1
	if idx >= ectx.i32_pool_base + I32_SCRATCH_POOL_SIZE {
		panic("wasm backend Фаза 1.5: исчерпан пул i32 scratch-локалей — см. I32_SCRATCH_POOL_SIZE")
	}
	return idx
}

@(private = "file")
alloc_f64_scratch :: proc(ectx: ^Emit_Ctx) -> int {
	idx := ectx.next_f64_scratch
	ectx.next_f64_scratch += 1
	if idx >= ectx.f64_pool_base + F64_SCRATCH_POOL_SIZE {
		panic("wasm backend Фаза 1.5: исчерпан пул f64 scratch-локалей — см. F64_SCRATCH_POOL_SIZE")
	}
	return idx
}

// wasm_local_index — Local_Id -> реальный WASM local-индекс. Params
// (Local_Id 0..P-1) не сдвинуты; тело-локали (Local_Id >= P) сдвинуты
// на +1 из-за __env, занявшего WASM-параметр-слот P (см. план closures,
// "Local-index collision" — НЕ блэнкет +1, params не трогать).
@(private = "file")
wasm_local_index :: proc(ectx: ^Emit_Ctx, local: Local_Id) -> int {
	p := len(ectx.fn.parameters)
	return int(local) < p ? int(local) : int(local) + 1
}

@(private = "file")
destroy_emit_ctx :: proc(ectx: ^Emit_Ctx) {
	destroy_cfg_info(&ectx.info)
	delete(ectx.rpo_index)
	delete(ectx.idom)
	delete(ectx.visited)
	delete(ectx.scope_stack)
	delete(ectx.value_to_closure_fn)
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

WASM_SCRATCH_COUNT :: 2 // f64 scratch для Modulo/битовых, см. emit_modulo/emit_bitwise_f64
I32_SCRATCH_POOL_SIZE :: 64
F64_SCRATCH_POOL_SIZE :: 64

// emit_function_wasm — тело функции в code-секции: вектор деклараций
// локалей + сами инструкции + завершающий 0x0B. Вызывается из
// core/wasm_module.odin. Пулы scratch-локалей — ФИКСИРОВАННОГО размера
// (см. alloc_i32_scratch/alloc_f64_scratch) — декларация не должна ждать
// конца эмиссии тела, чтобы узнать точный размер.
emit_function_wasm :: proc(
	module: ^Mir_Module,
	mfn: ^Mir_Function,
	func_index: ^map[Function_Id]int,
	foreign_func_index: ^map[^Foreign_Function]int,
	net_base: int,
) -> [dynamic]u8 {
	ectx := new_emit_ctx(module, mfn, func_index, foreign_func_index, net_base)
	defer destroy_emit_ctx(&ectx)

	process_from(&ectx, mfn.entry, INVALID_BLOCK)

	out := make([dynamic]u8)
	n_body_locals := len(mfn.locals) - len(mfn.parameters)
	write_uleb128(&out, u64(n_body_locals + WASM_SCRATCH_COUNT + I32_SCRATCH_POOL_SIZE + F64_SCRATCH_POOL_SIZE))
	for i in len(mfn.parameters) ..< len(mfn.locals) {
		write_uleb128(&out, 1)
		append(&out, wasm_val_type(mfn.locals[i].type))
	}
	for _ in 0 ..< WASM_SCRATCH_COUNT {
		write_uleb128(&out, 1)
		append(&out, WASM_F64)
	}
	for _ in 0 ..< I32_SCRATCH_POOL_SIZE {
		write_uleb128(&out, 1)
		append(&out, WASM_I32)
	}
	for _ in 0 ..< F64_SCRATCH_POOL_SIZE {
		write_uleb128(&out, 1)
		append(&out, WASM_F64)
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

// pw_typed_import — Число/Целое пишутся/читаются через *_F64-импорты,
// Булево/Строка/Struct/Ошибка/тупл/Массив/перечисление (все i32-handle-
// представленные, см. wasm_field_is_i32) — через *_I32-пары. Один и тот
// же выбор повторялся дословно на 6 сайтах (Get_Variant_Field_Instr,
// Get_Index_Instr, эмит Соответствие-методов, Try_Unwrap) — вынесено
// сюда, а не оставлено как копипаста тернарника на каждом.
@(private = "file")
pw_typed_import :: proc(ectx: ^Emit_Ctx, v: Value_Id, i32_import, f64_import: int) -> int {
	return wasm_field_is_i32(value_kind(ectx, v)) ? i32_import : f64_import
}

@(private = "file")
value_type_of :: proc(ectx: ^Emit_Ctx, v: Value_Id) -> ^Type {
	return prune_type(ectx.fn.value_types[int(v)])
}

// wasm_field_setter/getter — Булево/Строка (WASM i32-представление, см.
// wasm_val_type) идут через pw_*_field_i32, Число/Целое — через
// pw_*_field_f64. Struct/Ошибка/тупл-типизированные поля (вложенные
// агрегаты) ТОЖЕ i32 (handle) — см. wasm_val_type's .Struct/.Error/
// .Tuple case. Это ОТДЕЛЬНЫЙ от wasm_val_type switch (не переиспользует
// его) — Фазы 2.12/2.13 обе нашли реальный баг именно здесь: добавление
// нового kind в wasm_val_type/is_wasm_phase1_type само по себе НЕ
// чинит доступ к значениям этого kind как к ПОЛЮ/ЭЛЕМЕНТУ — этот switch
// держит СВОЙ независимый список типов. .Array/.Enum/.Map ВСЁ ЕЩЁ
// отсутствуют здесь — латентный, задокументированный (не исправленный)
// пробел: ни одна текущая фикстура не вкладывает массив/enum/карту КАК
// ПОЛЕ структуры/тупла/варианта, так что он пока не проявился на
// практике — проверить в первую очередь, если такое появится.
@(private = "file")
wasm_field_is_i32 :: proc(kind: Type_Kind) -> bool {
	return kind == .Bool || kind == .String || kind == .Struct || kind == .Error || kind == .Tuple || kind == .Function || kind == .Interface
}

// emit_construct_object — общая эмиссия для New_Aggregate_Instr/
// New_Array_Instr/Build_Variant_Instr/closures (Фаза 2.1 + план closures:
// ВСЕ — тот же field_count*FIELD_SIZE arena-объект, только выбор ALLOC-
// импорта, наличие tag-аргумента и (для closures) наличие ИНЪЕЦИРОВАННОЙ
// константы в поле 0 отличаются, см. wasm_runtime/runtime.odin's
// pw_alloc_aggregate/pw_build_variant). Элементы уже на стеке пачкой
// (обычный replay), но заполнение полей нужно по одному вперемешку с
// handle/индексом — снимаем все элементы в scratch-локали (в ОБРАТНОМ
// порядке, раз последний элемент сверху), затем собираем объект и
// заполняем поля в прямом порядке.
//
// leading_const — если задан, пишется в поле 0 КАК КОНСТАНТА (не
// Value_Id — closures нужен fn_index, известный на этапе эмиссии, не
// значение со стека), остальные элементы сдвигаются на поле 1..N.
// push_result — управляет, кладётся ли итоговый handle на стек
// (единообразно true везде сегодня, включая closures — см. Emit_Ctx's
// докстринг про то, почему closures НЕ могут не класть хендл на стек);
// параметр оставлен на случай будущего вызывающего, которому handle_
// local нужен БЕЗ побочного эффекта на стек.
@(private = "file")
emit_construct_object :: proc(
	ectx: ^Emit_Ctx,
	elements: []Value_Id,
	alloc_import: int,
	tag: Maybe(i64),
	leading_const: Maybe(i64) = nil,
	push_result: bool = true,
) -> (
	handle_local: int,
) {
	code := &ectx.code
	n := len(elements)
	field_offset := 0
	if _, has_lc := leading_const.?; has_lc do field_offset = 1
	field_count := n + field_offset

	elem_locals := make([]int, n, context.temp_allocator)
	elem_is_i32 := make([]bool, n, context.temp_allocator)
	for i := n - 1; i >= 0; i -= 1 {
		is_i32 := wasm_field_is_i32(value_kind(ectx, elements[i]))
		elem_is_i32[i] = is_i32
		local := is_i32 ? alloc_i32_scratch(ectx) : alloc_f64_scratch(ectx)
		elem_locals[i] = local
		append(code, 0x21) // local.set (снимает текущий верх стека — элемент i, т.к. идём с конца)
		write_uleb128(code, u64(local))
	}

	handle_local = alloc_i32_scratch(ectx)
	if t, has_tag := tag.?; has_tag {
		append(code, 0x41) // i32.const tag (pw_build_variant(tag, field_count))
		write_sleb128(code, t)
	}
	append(code, 0x41) // i32.const field_count
	write_sleb128(code, i64(field_count))
	append(code, 0x10) // call pw_alloc_aggregate/pw_build_variant
	write_uleb128(code, u64(alloc_import))
	append(code, 0x21) // local.set handle
	write_uleb128(code, u64(handle_local))

	if lc, has_lc := leading_const.?; has_lc {
		append(code, 0x20) // local.get handle
		write_uleb128(code, u64(handle_local))
		append(code, 0x41) // i32.const 0 (field index)
		write_sleb128(code, 0)
		append(code, 0x41) // i32.const fn_index (value)
		write_sleb128(code, lc)
		append(code, 0x10) // call pw_set_field_i32
		write_uleb128(code, u64(PW_SET_FIELD_I32))
	}

	for i in 0 ..< n {
		append(code, 0x20) // local.get handle
		write_uleb128(code, u64(handle_local))
		append(code, 0x41) // i32.const index
		write_sleb128(code, i64(i + field_offset))
		append(code, 0x20) // local.get элемент (тип берётся из декларации локали, не из опкода)
		write_uleb128(code, u64(elem_locals[i]))
		append(code, 0x10)
		write_uleb128(code, u64(elem_is_i32[i] ? PW_SET_FIELD_I32 : PW_SET_FIELD_F64))
	}

	if push_result {
		append(code, 0x20) // local.get handle — итоговое значение
		write_uleb128(code, u64(handle_local))
	}
	return handle_local
}

// emit_try_unwrap — `?`-оператор (Try_Unwrap_Instr). Типчекер уже
// гарантирует src — Опция/Результат (infer_try_expr, core/type_cheker.
// odin) и dst's тип совпадает с успешным payload'ом — здесь только
// рантайм-разветвление. src (handle) снимается в scratch-локаль, т.к.
// нужен ДВАЖДЫ (pw_match_tag на проверку, затем pw_get_field_* НА
// УСПЕШНОЙ ветке ИЛИ сам handle целиком на ветке раннего возврата — ни
// один MIR Value_Id не читается дважды, но handle_local — обычная WASM-
// локаль, не Value_Id, ей это можно). Тег успеха — 1 (Есть) для Опции,
// 0 (Успех) для Результата, ТЕ ЖЕ константы, что core/vm.odin's
// байткодный .Try_Unwrap опкод (variant-порядок объявлен в core/
// prelude.odin, тайпчекер и рантайм должны совпадать по построению).
// `if` здесь — ЕДИНСТВЕННОЕ типизированное (не пустое 0x40) blocktype
// во всём бэкенде: blocktype-байт напрямую совпадает с WASM_I32/
// WASM_F64 (кодировка valtype и однорезультатный blocktype — один и тот
// же байт в MVP). Else-ветка кончается `return` (0x0F) — по спецификации
// код после безусловного return/unreachable стек-полиморфен, так что
// компилятору не нужно "балансировать" тип else-ветки под тип if-ветки
// отдельно — сам факт, что она никогда не проваливается сквозь `end`,
// уже валиден.
@(private = "file")
emit_try_unwrap :: proc(ectx: ^Emit_Ctx, v: ^Try_Unwrap_Instr) {
	code := &ectx.code
	src_type := value_type_of(ectx, v.src)
	success_tag: i64
	switch src_type.name {
	case "Опция":
		success_tag = 1
	case "Результат":
		success_tag = 0
	case:
		panic(
			fmt.tprintf(
				"wasm backend: '?' на типе '%s' — тайпчекер должен был отсечь всё, кроме Опции/Результата (см. infer_try_expr)",
				src_type.name,
			),
		)
	}

	handle_local := alloc_i32_scratch(ectx)
	append(code, 0x21) // local.set handle (снимает src со стека)
	write_uleb128(code, u64(handle_local))

	append(code, 0x20) // local.get handle
	write_uleb128(code, u64(handle_local))
	append(code, 0x41) // i32.const success_tag
	write_sleb128(code, success_tag)
	append(code, 0x10) // call pw_match_tag
	write_uleb128(code, u64(PW_MATCH_TAG))

	dst_wasm_type := wasm_val_type(value_type_of(ectx, v.dst))
	append(code, 0x04) // if (typed blocktype)
	append(code, dst_wasm_type)

	append(code, 0x20) // local.get handle
	write_uleb128(code, u64(handle_local))
	append(code, 0x41) // i32.const 0 — payload всегда поле 0 у Есть(x)/Успех(x)
	write_sleb128(code, 0)
	field_getter := pw_typed_import(ectx, v.dst, PW_GET_FIELD_I32, PW_GET_FIELD_F64)
	append(code, 0x10)
	write_uleb128(code, u64(field_getter))

	append(code, 0x05) // else
	append(code, 0x20) // local.get handle — ранний возврат ВСЕГО Опции/Результата как есть
	write_uleb128(code, u64(handle_local))
	append(code, 0x0F) // return

	append(code, 0x0B) // end if
}

// emit_new_map — Фаза 2.4 (Соответствие): НЕ переиспользует emit_
// construct_object напрямую — тот пишет element i -> field i, а тут
// element i (ключ ИЛИ значение) должен попасть в РАЗНЫЙ field-индекс
// (2i для ключа, 2i+1 для значения). Реальный стек-порядок — НЕ "все
// ключи, потом все значения" (это лишь порядок в mir_validate.odin's
// instr_refs, для валидации, не для replay) — а ИНТЕРЛИВЛЕННЫЙ, per-
// entry: `для entry в e.entries { лоурить key; лоурить value }`
// (core/mir_lowering.odin's Map_Expr case, строки ~519-529) — т.е. на
// стеке [key0,val0,key1,val1,...], верх — val(n-1). Найдено эмпирически
// (wasmtime "type mismatch: expected f64, found i32" — исходная
// keys-затем-vals попытка снимала операнды не в том порядке, ловила
// значение в локаль не того типа), не по чтению кода.
@(private = "file")
emit_new_map :: proc(ectx: ^Emit_Ctx, v: ^New_Map_Instr) {
	code := &ectx.code
	n := len(v.keys)

	key_locals := make([]int, n, context.temp_allocator)
	key_is_i32 := make([]bool, n, context.temp_allocator)
	val_locals := make([]int, n, context.temp_allocator)
	val_is_i32 := make([]bool, n, context.temp_allocator)
	for i := n - 1; i >= 0; i -= 1 {
		// val[i] пушился ПОСЛЕДНИМ в своей паре — снимается ПЕРВЫМ.
		v_is_i32 := wasm_field_is_i32(value_kind(ectx, v.vals[i]))
		val_is_i32[i] = v_is_i32
		vlocal := v_is_i32 ? alloc_i32_scratch(ectx) : alloc_f64_scratch(ectx)
		val_locals[i] = vlocal
		append(code, 0x21)
		write_uleb128(code, u64(vlocal))

		k_is_i32 := wasm_field_is_i32(value_kind(ectx, v.keys[i]))
		key_is_i32[i] = k_is_i32
		klocal := k_is_i32 ? alloc_i32_scratch(ectx) : alloc_f64_scratch(ectx)
		key_locals[i] = klocal
		append(code, 0x21)
		write_uleb128(code, u64(klocal))
	}

	handle_local := alloc_i32_scratch(ectx)
	append(code, 0x41) // i32.const field_count (2n)
	write_sleb128(code, i64(n * 2))
	append(code, 0x10)
	write_uleb128(code, u64(PW_ALLOC_AGGREGATE))
	append(code, 0x21)
	write_uleb128(code, u64(handle_local))

	for i in 0 ..< n {
		append(code, 0x20) // local.get handle
		write_uleb128(code, u64(handle_local))
		append(code, 0x41) // i32.const 2i (key field)
		write_sleb128(code, i64(i * 2))
		append(code, 0x20)
		write_uleb128(code, u64(key_locals[i]))
		append(code, 0x10)
		write_uleb128(code, u64(key_is_i32[i] ? PW_SET_FIELD_I32 : PW_SET_FIELD_F64))

		append(code, 0x20) // local.get handle
		write_uleb128(code, u64(handle_local))
		append(code, 0x41) // i32.const 2i+1 (value field)
		write_sleb128(code, i64(i * 2 + 1))
		append(code, 0x20)
		write_uleb128(code, u64(val_locals[i]))
		append(code, 0x10)
		write_uleb128(code, u64(val_is_i32[i] ? PW_SET_FIELD_I32 : PW_SET_FIELD_F64))
	}

	append(code, 0x20) // local.get handle — итоговое значение
	write_uleb128(code, u64(handle_local))
}

// emit_set_property — object и value уже на стеке В ЭТОМ порядке (см.
// instr_refs: [object, value], value сверху) — pw_set_field_* нужен
// (handle, index, value), т.е. index должен встать МЕЖДУ ними. Снимаем
// value в scratch, кладём его назад ПОСЛЕ индекса.
@(private = "file")
emit_set_property :: proc(ectx: ^Emit_Ctx, v: ^Set_Property_Instr) {
	code := &ectx.code
	is_i32 := wasm_field_is_i32(value_kind(ectx, v.value))
	local := is_i32 ? alloc_i32_scratch(ectx) : alloc_f64_scratch(ectx)
	append(code, 0x21) // local.set value (снимает верх стека — object остаётся)
	write_uleb128(code, u64(local))
	append(code, 0x41) // i32.const field_index
	write_sleb128(code, i64(v.field_index))
	append(code, 0x20) // local.get value
	write_uleb128(code, u64(local))
	append(code, 0x10)
	write_uleb128(code, u64(is_i32 ? PW_SET_FIELD_I32 : PW_SET_FIELD_F64))
}

// emit_set_index — object, index(Целое/f64), value уже на стеке в этом
// порядке (см. instr_refs: [object, index, value], value сверху).
// pw_set_field_* нужен (handle, index_i32, value) — снимаем value в
// scratch (object остаётся снизу, index — теперь сверху), конвертируем
// index на месте, кладём value назад.
@(private = "file")
emit_set_index :: proc(ectx: ^Emit_Ctx, v: ^Set_Index_Instr) {
	if value_type_of(ectx, v.object).kind == .Map {
		emit_map_set_index(ectx, v)
		return
	}
	code := &ectx.code
	is_i32 := wasm_field_is_i32(value_kind(ectx, v.value))
	local := is_i32 ? alloc_i32_scratch(ectx) : alloc_f64_scratch(ectx)
	append(code, 0x21) // local.set value (снимает верх стека)
	write_uleb128(code, u64(local))
	append(code, 0xAA) // i32.trunc_f64_s (index — теперь верх стека)
	append(code, 0x20) // local.get value
	write_uleb128(code, u64(local))
	append(code, 0x10)
	write_uleb128(code, u64(is_i32 ? PW_SET_FIELD_I32 : PW_SET_FIELD_F64))
}

// emit_map_set_index — Фаза 2.7: m[k]=v на Соответствие. object, key,
// value уже на стеке в ЭТОМ порядке (value сверху, см. instr_refs) —
// СОВПАДАЕТ с pw_map_set_*(handle, key, value) один-в-один: ПРОЩЕ, чем
// Массив-путь выше (там нужен scratch-реордер из-за truncation индекса)
// — ключ Соответствия НИКОГДА не усекается (не байтовый индекс, сам
// ключ, см. emit_map_get_index), значит и переставлять нечего.
// pw_map_set_*'s i32-результат (успех/провал) отбрасывается — Set_
// Index_Instr не имеет dst (m[k]=v — statement, не expression).
@(private = "file")
emit_map_set_index :: proc(ectx: ^Emit_Ctx, v: ^Set_Index_Instr) {
	code := &ectx.code
	map_type := value_type_of(ectx, v.object)
	key_is_str := wasm_field_is_i32(prune_type(map_type.key_type).kind)
	val_is_i32 := wasm_field_is_i32(value_kind(ectx, v.value))
	setter := PW_MAP_SET_NUMKEY_F64
	switch {
	case key_is_str && val_is_i32:
		setter = PW_MAP_SET_STRKEY_I32
	case key_is_str && !val_is_i32:
		setter = PW_MAP_SET_STRKEY_F64
	case !key_is_str && val_is_i32:
		setter = PW_MAP_SET_NUMKEY_I32
	case !key_is_str && !val_is_i32:
		setter = PW_MAP_SET_NUMKEY_F64
	}
	append(code, 0x10)
	write_uleb128(code, u64(setter))
	append(code, 0x1A) // drop — i32-результат set'а никому не нужен
}

// emit_map_get_index — Фаза 2.4: m[k] на Соответствие. object, key уже
// на стеке в этом порядке (index сверху) — В ОТЛИЧИЕ от Массив, key НЕ
// конвертируется в i32 (это не байтовый индекс — сам ключ, f64 если
// Число, i32-handle если Строка, передаётся pw_map_get_* как есть).
// Байткод-VM паникует на отсутствующий ключ (core/vm.odin:2243-2249) —
// здесь вместо трапа emitим ноль-литерал fallback (тот же принятый
// gap, что у Массив: OOB читает соседнюю память вместо трапа, см. Фаза
// 2.1) — pw_map_get_* уже принимает fallback (переиспользуется
// получить()-семейством ниже), значит здесь просто эмитим 0/0.0
// ПОСЛЕ [object, key] — без scratch-переупорядочивания, т.к. fallback
// не с стека, а компайл-тайм константа.
@(private = "file")
emit_map_get_index :: proc(ectx: ^Emit_Ctx, v: ^Get_Index_Instr) {
	code := &ectx.code
	map_type := value_type_of(ectx, v.object)
	key_is_str := wasm_field_is_i32(prune_type(map_type.key_type).kind)
	val_is_i32 := wasm_field_is_i32(value_kind(ectx, v.dst))
	if val_is_i32 {
		append(code, 0x41) // i32.const 0
		write_sleb128(code, 0)
	} else {
		append(code, 0x44) // f64.const 0.0
		write_f64_le(code, 0)
	}
	getter := PW_MAP_GET_NUMKEY_F64
	switch {
	case key_is_str && val_is_i32:
		getter = PW_MAP_GET_STRKEY_I32
	case key_is_str && !val_is_i32:
		getter = PW_MAP_GET_STRKEY_F64
	case !key_is_str && val_is_i32:
		getter = PW_MAP_GET_NUMKEY_I32
	case !key_is_str && !val_is_i32:
		getter = PW_MAP_GET_NUMKEY_F64
	}
	append(code, 0x10)
	write_uleb128(code, u64(getter))
}

// emit_map_method_call — Фаза 2.4: Call_Method_Instr на Соответствие
// (Method_Collection, type_cheker.odin — длина/есть/получить/удалить).
// receiver затем args уже на стеке в естественном MIR-порядке (см.
// Call_Method_Instr's instr_refs: [receiver, args...]), СОВПАДАЕТ с
// параметрами каждой pw_map_* сигнатуры один-в-один (handle, key[,
// fallback]) — никакого scratch-переупорядочивания не нужно, ключ НЕ
// конвертируется (в отличие от Массив: ключ — это сам ключ, не
// байтовый индекс).
@(private = "file")
emit_map_method_call :: proc(ectx: ^Emit_Ctx, v: ^Call_Method_Instr) {
	code := &ectx.code
	map_type := value_type_of(ectx, v.receiver)
	key_is_str := wasm_field_is_i32(prune_type(map_type.key_type).kind)
	switch v.name {
	case "длина":
		append(code, 0x10)
		write_uleb128(code, u64(PW_MAP_LENGTH))
		append(code, 0xB7) // f64.convert_i32_s — длина() -> Целое
	case "есть":
		append(code, 0x10)
		write_uleb128(code, u64(key_is_str ? PW_MAP_HAS_STRKEY : PW_MAP_HAS_NUMKEY))
	case "получить":
		val_is_i32 := wasm_field_is_i32(value_kind(ectx, v.dst.(Value_Id)))
		getter := PW_MAP_GET_NUMKEY_F64
		switch {
		case key_is_str && val_is_i32:
			getter = PW_MAP_GET_STRKEY_I32
		case key_is_str && !val_is_i32:
			getter = PW_MAP_GET_STRKEY_F64
		case !key_is_str && val_is_i32:
			getter = PW_MAP_GET_NUMKEY_I32
		case !key_is_str && !val_is_i32:
			getter = PW_MAP_GET_NUMKEY_F64
		}
		append(code, 0x10)
		write_uleb128(code, u64(getter))
	case "удалить":
		append(code, 0x10)
		write_uleb128(code, u64(key_is_str ? PW_MAP_DELETE_STRKEY : PW_MAP_DELETE_NUMKEY))
	case "записи":
		append(code, 0x10)
		write_uleb128(code, u64(PW_MAP_ENTRIES))
	case:
		panic(fmt.tprintf("wasm backend Фаза 2.4: метод '%s' на Соответствие вне области (см. план)", v.name))
	}
}

// emit_array_method_call — Фаза 2.2: Call_Method_Instr на Массив
// (Method_Collection, type_cheker.odin — длина/получить/есть/содержит/
// срез, 5 не-мутирующих методов; добавить вне области — arena не
// поддерживает рост объекта на месте, см. план). receiver затем args
// уже на стеке в естественном MIR-порядке (instr_refs: [receiver,
// args...]), но КАЖДЫЙ индексный аргумент (idx у есть/получить,
// start/end у срез) — Целое, т.е. f64 на этом бэкенде (Фаза 1: Число/
// Целое не различаются рантайм-представлением) — pw_array_* принимают
// его как i32 (байтовая арифметика внутри wasm_runtime), нужен
// i32.trunc_f64_s. Если индекс — не верх стека (получить/срез), тот же
// приём, что emit_set_index/emit_set_property: снять верхние операнды в
// scratch-локаль, сконвертировать, вернуть на место.
@(private = "file")
emit_array_method_call :: proc(ectx: ^Emit_Ctx, v: ^Call_Method_Instr) {
	code := &ectx.code
	switch v.name {
	case "длина":
		append(code, 0x10)
		write_uleb128(code, u64(PW_ARRAY_LENGTH))
		append(code, 0xB7) // f64.convert_i32_s — длина() -> Целое
	case "есть":
		// [receiver, idx] — idx уже верх стека.
		append(code, 0xAA) // i32.trunc_f64_s
		append(code, 0x10)
		write_uleb128(code, u64(PW_ARRAY_IN_BOUNDS))
	case "получить":
		// [receiver, idx, fallback] — fallback сверху, idx под ним.
		is_i32 := wasm_field_is_i32(value_kind(ectx, v.args[1]))
		local := is_i32 ? alloc_i32_scratch(ectx) : alloc_f64_scratch(ectx)
		append(code, 0x21) // local.set fallback (снимает верх стека)
		write_uleb128(code, u64(local))
		append(code, 0xAA) // i32.trunc_f64_s (idx — теперь верх)
		append(code, 0x20) // local.get fallback
		write_uleb128(code, u64(local))
		getter := is_i32 ? PW_ARRAY_GET_I32 : PW_ARRAY_GET_F64
		append(code, 0x10)
		write_uleb128(code, u64(getter))
	case "содержит":
		// [receiver, needle] — needle остаётся как есть (не индекс, само
		// значение — f64 или i32 в зависимости от типа элемента).
		checker := pw_typed_import(ectx, v.args[0], PW_ARRAY_CONTAINS_I32, PW_ARRAY_CONTAINS_F64)
		append(code, 0x10)
		write_uleb128(code, u64(checker))
	case "срез":
		// [receiver, start, end] — end сверху, ОБА нужно конвертировать в
		// i32: конвертируем end на месте, снимаем в i32-scratch,
		// конвертируем start (теперь верх), возвращаем end.
		end_local := alloc_i32_scratch(ectx)
		append(code, 0xAA) // i32.trunc_f64_s (end)
		append(code, 0x21) // local.set end
		write_uleb128(code, u64(end_local))
		append(code, 0xAA) // i32.trunc_f64_s (start — теперь верх)
		append(code, 0x20) // local.get end
		write_uleb128(code, u64(end_local))
		append(code, 0x10)
		write_uleb128(code, u64(PW_ARRAY_SLICE))
	case "добавить":
		// Фаза 2.7: [receiver, value] уже на стеке — СОВПАДАЕТ с
		// pw_array_push_*(handle, value) один-в-один, никакой индекс не
		// участвует (в отличие от получить/срез), переупорядочивание не
		// нужно. Результат (i32 успех/провал) НЕ дропаем здесь явно —
		// Call_Method_Instr.dst (Maybe(Value_Id)) ВСЕГДА Some(...) (см.
		// mir_lowering.odin's emit_call_method — не смотрит на result_
		// type == Пусто), значит emit_block_instructions's общий use_
		// count-based drop (core/wasm_emit.odin:360) УЖЕ снимет это
		// значение сам, раз добавить()'s результат нигде не используется
		// — явный drop здесь оставил бы стек пустым ДО того, как общий
		// механизм попытается дропнуть ЕЩЁ раз — underflow (найдено
		// эмпирически через wasmtime: "expected a type but nothing on
		// stack", не по чтению кода).
		pusher := pw_typed_import(ectx, v.args[0], PW_ARRAY_PUSH_I32, PW_ARRAY_PUSH_F64)
		append(code, 0x10)
		write_uleb128(code, u64(pusher))
	case:
		panic(fmt.tprintf("wasm backend Фаза 2.2: метод '%s' вне области (см. план)", v.name))
	}
}

@(private = "file")
resolve_func_index :: proc(ectx: ^Emit_Ctx, fn: Function_Id) -> int {
	idx, ok := ectx.func_index^[fn]
	if !ok {
		panic("wasm backend Фаза 1: вызов функции вне области Фазы 1 (не Число/Целое/Булево сигнатура — см. is_wasm_phase1_function)")
	}
	return idx
}

// emit_closure_value — ЕДИНЫЙ эмиттер для Function_Ref_Instr (captured
// == {}) И Build_Closure_Instr (captured != {}) — см. план closures: оба
// строят один и тот же [fn_index, captured...] arena-хендл через emit_
// construct_object И КЛАДУТ его на стек нормально (см. Emit_Ctx's
// докстринг про то, почему НЕ по-особому — реальный баг был найден
// именно на этом).
@(private = "file")
emit_closure_value :: proc(ectx: ^Emit_Ctx, dst: Value_Id, fn: Function_Id, captured: []Value_Id) {
	wasm_idx := resolve_func_index(ectx, fn)
	emit_construct_object(ectx, captured, PW_ALLOC_AGGREGATE, nil, i64(wasm_idx), true)
	ectx.value_to_closure_fn[dst] = fn
}

// find_call_value_typeidx — фоллбэк-путь Call_Value_Instr, когда callee
// НЕ найден в value_to_closure_fn (пришёл издалека — Load_Local_Instr от
// параметра/сохранённого значения, настоящее замыкание как значение, не
// немедленно вызванное). Конкретный Function_Id здесь недоступен —
// известен только СТАТИЧЕСКИЙ ТИП вызова (panos's типчекер гарантирует:
// в этом значении может оказаться только функция с ИМЕННО такой
// сигнатурой). WASM's call_indirect типизирован СТРУКТУРНО (сверяет
// functype таблицы с functype по typeidx побайтово) — НЕ требует, чтобы
// typeidx был "родным" для конкретной функции в слоте, так что подходит
// ЛЮБАЯ Phase-1-включённая функция с той же (params, result) формой;
// panos's типобезопасность гарантирует, что искомая — среди них (иначе
// она сама не прошла бы is_wasm_phase1_function при своей эмиссии).
// O(n) по числу включённых функций — приемлемо на масштабе фикстур этого
// бэкенда (тот же "корректность важнее скорости" прецедент, что и
// O(n·m)-строковый поиск Фазы 2.0); ТОЛЬКО фоллбэк-путь, обычные вызовы
// (Function_Ref_Instr в области видимости) идут через O(1) resolve_
// func_index в Call_Value_Instr напрямую.
@(private = "file")
find_call_value_typeidx :: proc(ectx: ^Emit_Ctx, v: ^Call_Value_Instr) -> int {
	want_returns, want_result_byte := call_value_result_shape(ectx, v)
	for &mfn in ectx.module.functions {
		wasm_idx, included := ectx.func_index^[mfn.id]
		if !included do continue
		if len(mfn.parameters) != len(v.args) do continue
		match := true
		for a, i in v.args {
			pt := mfn.locals[int(mfn.parameters[i])].type
			if wasm_val_type(pt) != wasm_val_type(value_type_of(ectx, a)) {
				match = false
				break
			}
		}
		if !match do continue
		fn_returns := prune_type(mfn.result_type) != TY_VOID
		if fn_returns != want_returns do continue
		if want_returns && wasm_val_type(mfn.result_type) != want_result_byte do continue
		return wasm_idx
	}
	panic("wasm backend: не найдена функция, соответствующая сигнатуре вызова через значение — нарушена типобезопасность (см. план closures)")
}

@(private = "file")
call_value_result_shape :: proc(ectx: ^Emit_Ctx, v: ^Call_Value_Instr) -> (returns: bool, byte: u8) {
	d, ok := v.dst.?
	if !ok do return false, 0
	return true, wasm_val_type(value_type_of(ectx, d))
}

// pop_leading_and_args — общий приём для ЛЮБОЙ инструкции, чей "ведущий"
// операнд (Call_Value_Instr's callee, Invoke_Interface_Instr's receiver)
// лоурится РАНЬШЕ args (структурный факт MIR) и потому лежит НА СТЕКЕ
// ПОД args к моменту исполнения самой инструкции — снимаем args в
// scratch (в ОБРАТНОМ порядке — последний сверху), затем ведущее
// значение, оставляя вызывающему решать, В КАКОМ порядке (и с какими
// доп. значениями, см. Invoke_Interface_Instr — это_receiver вставляется
// ПЕРЕД args) всё это возвращать на стек.
@(private = "file")
pop_leading_and_args :: proc(ectx: ^Emit_Ctx, args: []Value_Id) -> (leading_local: int, arg_locals: []int) {
	code := &ectx.code
	n := len(args)
	arg_locals = make([]int, n, context.temp_allocator)
	for i := n - 1; i >= 0; i -= 1 {
		is_i32 := wasm_val_type(value_type_of(ectx, args[i])) == WASM_I32
		local := is_i32 ? alloc_i32_scratch(ectx) : alloc_f64_scratch(ectx)
		arg_locals[i] = local
		append(code, 0x21) // local.set
		write_uleb128(code, u64(local))
	}
	leading_local = alloc_i32_scratch(ectx)
	append(code, 0x21) // local.set (ведущее значение — callee/receiver)
	write_uleb128(code, u64(leading_local))
	return leading_local, arg_locals
}

// MAX_INTERFACE_METHODS — верхняя граница числа методов интерфейса,
// поддержанная Invoke_Interface_Instr's развёрнутой (unrolled) цепочкой
// сравнений (см. emit_invoke_interface) — panos'овские интерфейсы не
// превышают 5 методов (Логгер, std/слог.ps), 16 — щедрый запас. ПОЧЕМУ
// unrolled, а не настоящий WASM-цикл: индекс поля 2+2i/3+2i остаётся
// КОМПАЙЛ-ТАЙМ константой при развёртке (i — компайл-тайм), избегая
// рантайм-арифметики над индексами полей — первого в этом бэкенде
// хендролленного цикла с арифметикой не потребовалось вообще (реальный
// design-фork, решённый через AskUserQuestion — см. план interfaces).
MAX_INTERFACE_METHODS :: 16

// emit_cast_interface — Cast_Interface_Instr: строит [receiver,
// method_count, name_0, handle_0, ..., name_{k-1}, handle_{k-1}]
// arena-объект (k = len(v.vtable), НЕ дополненный до MAX — Invoke_
// Interface_Instr читает method_count и никогда не читает за его
// пределы, см. её докстринг). Каждый method_i handle — ТОТ ЖЕ
// [fn_index]-объект, что emit_closure_value строит для некапчурящего
// Function_Ref_Instr (переиспользует emit_construct_object напрямую) —
// поэтому финальный вызов через найденный handle идентичен Call_Value_
// Instr's механике (fn_index из поля 0, handle сам как __env), новой
// calling convention не потребовалось.
//
// Диспетчинг СТРОКОВЫЙ (не позиционный): struct_type.methods — Odin
// map[string]Symbol_Id, порядок итерации НЕ детерминирован между
// разными Cast_Interface_Instr одного и того же интерфейса (см. план
// interfaces, п.2) — bytecode VM's Interface_Value{data, methods:
// map[string]^Compiled_Function} уже делает диспетчинг по имени
// рантайм-ово, не позиционно; wasm обязан повторить это, а не
// полагаться на совпадение индексов между кастами.
@(private = "file")
emit_cast_interface :: proc(ectx: ^Emit_Ctx, v: ^Cast_Interface_Instr) {
	code := &ectx.code
	k := len(v.vtable)
	if k > MAX_INTERFACE_METHODS {
		panic(
			fmt.tprintf(
				"wasm backend: интерфейс с %d методами превышает MAX_INTERFACE_METHODS=%d (см. план interfaces)",
				k,
				MAX_INTERFACE_METHODS,
			),
		)
	}

	receiver_local := alloc_i32_scratch(ectx)
	append(code, 0x21) // local.set (снимает v.src со стека)
	write_uleb128(code, u64(receiver_local))

	name_locals := make([]int, k, context.temp_allocator)
	handle_locals := make([]int, k, context.temp_allocator)
	for binding, i in v.vtable {
		emit_string_const(ectx, binding.method_name)
		name_locals[i] = alloc_i32_scratch(ectx)
		append(code, 0x21) // local.set
		write_uleb128(code, u64(name_locals[i]))

		wasm_idx := resolve_func_index(ectx, binding.fn)
		handle_locals[i] = emit_construct_object(ectx, {}, PW_ALLOC_AGGREGATE, nil, i64(wasm_idx), false)
	}

	field_count := 2 + 2 * k
	iface_local := alloc_i32_scratch(ectx)
	append(code, 0x41) // i32.const field_count
	write_sleb128(code, i64(field_count))
	append(code, 0x10) // call pw_alloc_aggregate
	write_uleb128(code, u64(PW_ALLOC_AGGREGATE))
	append(code, 0x21) // local.set handle
	write_uleb128(code, u64(iface_local))

	emit_set_field_i32_const(ectx, iface_local, 0, receiver_local)
	emit_set_field_i32_literal(ectx, iface_local, 1, i64(k))
	for i in 0 ..< k {
		emit_set_field_i32_const(ectx, iface_local, 2 + 2 * i, name_locals[i])
		emit_set_field_i32_const(ectx, iface_local, 3 + 2 * i, handle_locals[i])
	}

	append(code, 0x20) // local.get handle — итоговое значение
	write_uleb128(code, u64(iface_local))
}

// emit_set_field_i32_const/emit_set_field_i32_literal — маленькие
// хелперы для emit_cast_interface's поля-из-локали / поле-из-константы
// записей (pw_set_field_i32(handle, index, value)) — то же самое, что
// emit_construct_object уже делает построчно, но здесь поля собираются
// из РАЗНОРОДНЫХ источников (Value_Id, свежепостроенные локали,
// компайл-тайм константы), не единого elements-массива, так что
// emit_construct_object как есть не подходит без искусственного
// оборачивания каждого источника в Value_Id.
@(private = "file")
emit_set_field_i32_const :: proc(ectx: ^Emit_Ctx, handle_local: int, field_index: int, value_local: int) {
	code := &ectx.code
	append(code, 0x20) // local.get handle
	write_uleb128(code, u64(handle_local))
	append(code, 0x41) // i32.const field_index
	write_sleb128(code, i64(field_index))
	append(code, 0x20) // local.get value
	write_uleb128(code, u64(value_local))
	append(code, 0x10) // call pw_set_field_i32
	write_uleb128(code, u64(PW_SET_FIELD_I32))
}

@(private = "file")
emit_set_field_i32_literal :: proc(ectx: ^Emit_Ctx, handle_local: int, field_index: int, value: i64) {
	code := &ectx.code
	append(code, 0x20) // local.get handle
	write_uleb128(code, u64(handle_local))
	append(code, 0x41) // i32.const field_index
	write_sleb128(code, i64(field_index))
	append(code, 0x41) // i32.const value
	write_sleb128(code, value)
	append(code, 0x10) // call pw_set_field_i32
	write_uleb128(code, u64(PW_SET_FIELD_I32))
}

// find_interface_typeidx — Invoke_Interface_Instr's typeidx-резолюция.
// НЕ переиспользует find_call_value_typeidx напрямую (обсуждалось в
// плане как возможность, отклонено при реализации): позиция 0
// (это/receiver) метода намеренно НЕ сверяется по типу — Invoke_
// Interface_Instr.receiver's MIR-тип на месте вызова — это тип ЛОКАЛИ/
// параметра, через который пришло значение (после mir_lowering.odin's
// фикса Cast_Interface_Instr.dst — тип ИСХОДНОЙ структуры на самом
// касте, но на join-точках если/иначе локаль часто типизирована как
// САМ ИНТЕРФЕЙС, см. Let_Stmt's node_types[s.value]) — ни один из этих
// двух вариантов совпадает с РЕАЛЬНЫМ это-параметром искомого метода
// (конкретный struct/enum, известный только методу). Тайпчекер уже
// гарантирует совместимость на этой позиции — сверяем только arity и
// ОСТАЛЬНЫЕ (1..) позиции + тип результата.
@(private = "file")
find_interface_typeidx :: proc(ectx: ^Emit_Ctx, v: ^Invoke_Interface_Instr) -> int {
	want_returns, want_result_byte := invoke_interface_result_shape(ectx, v)
	for &mfn in ectx.module.functions {
		wasm_idx, included := ectx.func_index^[mfn.id]
		if !included do continue
		if len(mfn.parameters) != len(v.args) + 1 do continue
		match := true
		for a, i in v.args {
			pt := mfn.locals[int(mfn.parameters[i + 1])].type
			if wasm_val_type(pt) != wasm_val_type(value_type_of(ectx, a)) {
				match = false
				break
			}
		}
		if !match do continue
		fn_returns := prune_type(mfn.result_type) != TY_VOID
		if fn_returns != want_returns do continue
		if want_returns && wasm_val_type(mfn.result_type) != want_result_byte do continue
		return wasm_idx
	}
	panic("wasm backend: не найдена функция, соответствующая сигнатуре вызова интерфейсного метода — нарушена типобезопасность (см. план interfaces)")
}

@(private = "file")
invoke_interface_result_shape :: proc(ectx: ^Emit_Ctx, v: ^Invoke_Interface_Instr) -> (returns: bool, byte: u8) {
	d, ok := v.dst.?
	if !ok do return false, 0
	return true, wasm_val_type(value_type_of(ectx, d))
}

// emit_invoke_interface — Invoke_Interface_Instr: находит method_name
// (компайл-тайм строка) в receiver's [receiver, method_count, name_0,
// handle_0, ...]-объекте через РАЗВЁРНУТУЮ (MAX_INTERFACE_METHODS
// итераций, i — компайл-тайм) цепочку сравнений (см. её докстринг для
// MAX_INTERFACE_METHODS выше про то, почему НЕ настоящий цикл), затем
// вызывает найденный handle ТОЧНО как Call_Value_Instr вызывает
// closure-хендл (fn_index из поля 0, handle сам как __env) — с ОДНИМ
// отличием: реальный receiver (сырой struct/enum, поле 0 хендла,
// НЕ сам interface-wrapper) идёт ПЕРВЫМ реальным аргументом (это),
// перед v.args.
@(private = "file")
emit_invoke_interface :: proc(ectx: ^Emit_Ctx, v: ^Invoke_Interface_Instr) {
	code := &ectx.code
	iface_local, arg_locals := pop_leading_and_args(ectx, v.args)

	method_count_local := alloc_i32_scratch(ectx)
	append(code, 0x20) // local.get iface
	write_uleb128(code, u64(iface_local))
	append(code, 0x41) // i32.const 1 (field index)
	write_sleb128(code, 1)
	append(code, 0x10) // call pw_get_field_i32
	write_uleb128(code, u64(PW_GET_FIELD_I32))
	append(code, 0x21) // local.set method_count
	write_uleb128(code, u64(method_count_local))

	emit_string_const(ectx, v.method_name)
	target_name_local := alloc_i32_scratch(ectx)
	append(code, 0x21) // local.set
	write_uleb128(code, u64(target_name_local))

	found_flag_local := alloc_i32_scratch(ectx)
	found_handle_local := alloc_i32_scratch(ectx)
	append(code, 0x41) // i32.const 0
	write_sleb128(code, 0)
	append(code, 0x21) // local.set found_flag = 0
	write_uleb128(code, u64(found_flag_local))

	for i in 0 ..< MAX_INTERFACE_METHODS {
		// if found_flag == 0
		append(code, 0x20) // local.get found_flag
		write_uleb128(code, u64(found_flag_local))
		append(code, 0x45) // i32.eqz
		append(code, 0x04, 0x40) // if (пустой blocktype)

		// if i < method_count
		append(code, 0x41) // i32.const i
		write_sleb128(code, i64(i))
		append(code, 0x20) // local.get method_count
		write_uleb128(code, u64(method_count_local))
		append(code, 0x48) // i32.lt_s
		append(code, 0x04, 0x40)

		// if pw_string_equal(name_i, target_name)
		append(code, 0x20) // local.get iface
		write_uleb128(code, u64(iface_local))
		append(code, 0x41) // i32.const 2+2i (name_i field index)
		write_sleb128(code, i64(2 + 2 * i))
		append(code, 0x10) // call pw_get_field_i32
		write_uleb128(code, u64(PW_GET_FIELD_I32))
		append(code, 0x20) // local.get target_name
		write_uleb128(code, u64(target_name_local))
		append(code, 0x10) // call pw_string_equal
		write_uleb128(code, u64(PW_STRING_EQUAL))
		append(code, 0x04, 0x40)

		// found_handle = pw_get_field_i32(iface, 3+2i)
		append(code, 0x20) // local.get iface
		write_uleb128(code, u64(iface_local))
		append(code, 0x41) // i32.const 3+2i
		write_sleb128(code, i64(3 + 2 * i))
		append(code, 0x10)
		write_uleb128(code, u64(PW_GET_FIELD_I32))
		append(code, 0x21) // local.set found_handle
		write_uleb128(code, u64(found_handle_local))
		// found_flag = 1
		append(code, 0x41)
		write_sleb128(code, 1)
		append(code, 0x21)
		write_uleb128(code, u64(found_flag_local))

		append(code, 0x0B) // end (string_equal if)
		append(code, 0x0B) // end (i < method_count if)
		append(code, 0x0B) // end (found_flag == 0 if)
	}

	receiver_local := alloc_i32_scratch(ectx)
	append(code, 0x20) // local.get iface
	write_uleb128(code, u64(iface_local))
	append(code, 0x41) // i32.const 0 (receiver field index)
	write_sleb128(code, 0)
	append(code, 0x10)
	write_uleb128(code, u64(PW_GET_FIELD_I32))
	append(code, 0x21) // local.set receiver
	write_uleb128(code, u64(receiver_local))

	append(code, 0x20) // local.get receiver (это — первый реальный арг)
	write_uleb128(code, u64(receiver_local))
	for i in 0 ..< len(arg_locals) {
		append(code, 0x20) // local.get arg i
		write_uleb128(code, u64(arg_locals[i]))
	}

	typeidx := find_interface_typeidx(ectx, v)

	append(code, 0x20) // local.get found_handle (как __env)
	write_uleb128(code, u64(found_handle_local))

	append(code, 0x20) // local.get found_handle (снова — fn_index из поля 0)
	write_uleb128(code, u64(found_handle_local))
	append(code, 0x41) // i32.const 0
	write_sleb128(code, 0)
	append(code, 0x10)
	write_uleb128(code, u64(PW_GET_FIELD_I32))

	append(code, 0x11) // call_indirect
	write_uleb128(code, u64(typeidx))
	write_uleb128(code, 0) // tableidx 0
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
			emit_string_const(ectx, cv)
		}

	case ^Load_Local_Instr:
		append(code, 0x20) // local.get
		write_uleb128(code, u64(wasm_local_index(ectx, v.local)))

	case ^Store_Local_Instr:
		append(code, 0x21) // local.set
		write_uleb128(code, u64(wasm_local_index(ectx, v.local)))

	case ^Binary_Instr:
		if v.op == .Add && value_kind(ectx, v.lhs) == .String {
			// panos's `+` на Строка — конкатенация (см. core/vm.odin's
			// .Add: полиморфный опкод, число-vs-строка решается по
			// РАНТАЙМ-типу там; здесь решаем СТАТИЧЕСКИ, per Compare_Instr's
			// уже устоявшийся паттерн для is_bool ниже).
			append(code, 0x10)
			write_uleb128(code, u64(PW_CONCAT_STRINGS))
		} else {
			emit_binary_op(ectx, v.op)
		}

	case ^Compare_Instr:
		emit_compare_op(ectx, v.op, value_kind(ectx, v.lhs))

	case ^Unary_Instr:
		emit_unary_op(ectx, v.op)

	case ^Function_Ref_Instr:
		emit_closure_value(ectx, v.dst, v.fn, {})

	case ^Build_Closure_Instr:
		emit_closure_value(ectx, v.dst, v.fn, v.captured)

	case ^Call_Instr:
		// Мёртвый код: lowering.odin никогда не строит Call_Instr
		// (см. план closures — ВСЕ реальные вызовы идут через
		// Call_Value_Instr). Если бы этот case когда-нибудь исполнился,
		// он был бы неверен после введения __env (прямой call без
		// трейлинг-аргумента не совпал бы с новой сигнатурой функции) —
		// не чинится намеренно, т.к. недостижимо.
		wasm_idx := resolve_func_index(ectx, v.callee)
		append(code, 0x10) // call
		write_uleb128(code, u64(wasm_idx))

	case ^Call_Value_Instr:
		// closures (см. план): callee — ВСЕГДА [fn_index, captured...]
		// хендл (emit_closure_value), никогда голый funcidx, и ВСЕГДА
		// положен на стек ОБЫЧНЫМ replay'ем (см. Emit_Ctx's докстринг) —
		// т.е. лежит ПОД аргументами (callee лоурится раньше args, см.
		// mir_lowering.odin), а call_indirect нужен ПОСЛЕ них —
		// pop_leading_and_args разгребает порядок (тот же приём для
		// Invoke_Interface_Instr, см. её case).
		handle_local, arg_locals := pop_leading_and_args(ectx, v.args)
		for i in 0 ..< len(arg_locals) {
			append(code, 0x20) // local.get arg i
			write_uleb128(code, u64(arg_locals[i]))
		}

		// typeidx — O(1) через value_to_closure_fn, когда callee —
		// известный Function_Ref_Instr/Build_Closure_Instr В ЭТОЙ
		// функции (не через локаль/захват), иначе O(n) структурный
		// скан-фоллбэк (см. find_call_value_typeidx).
		fn, known := ectx.value_to_closure_fn[v.callee]
		typeidx := known ? resolve_func_index(ectx, fn) : find_call_value_typeidx(ectx, v)

		append(code, 0x20) // local.get handle (как __env — трейлинг-аргумент)
		write_uleb128(code, u64(handle_local))

		append(code, 0x20) // local.get handle (снова — fn_index из поля 0)
		write_uleb128(code, u64(handle_local))
		append(code, 0x41) // i32.const 0
		write_sleb128(code, 0)
		append(code, 0x10) // call pw_get_field_i32
		write_uleb128(code, u64(PW_GET_FIELD_I32))

		append(code, 0x11) // call_indirect
		write_uleb128(code, u64(typeidx))
		write_uleb128(code, 0) // tableidx 0

	case ^New_Aggregate_Instr:
		emit_construct_object(ectx, v.elements, PW_ALLOC_AGGREGATE, nil)

	case ^New_Array_Instr:
		// Массив — та же raw-раскладка, что структура (см. план Фазы 2.1:
		// wasm_runtime не различает "структура" и "массив" на уровне
		// хранения, только сам факт field_count*FIELD_SIZE-объекта) —
		// тот же alloc-импорт, что New_Aggregate_Instr.
		emit_construct_object(ectx, v.elements, PW_ALLOC_AGGREGATE, nil)

	case ^New_Map_Instr:
		emit_new_map(ectx, v)

	case ^Get_Property_Instr:
		// object (handle) уже на стеке — pw_get_field_* принимает
		// (handle, index), нужен ЕЩЁ индекс сверху ПЕРЕД вызовом.
		append(code, 0x41) // i32.const field_index
		write_sleb128(code, i64(v.field_index))
		field_getter := pw_typed_import(ectx, v.dst, PW_GET_FIELD_I32, PW_GET_FIELD_F64)
		append(code, 0x10)
		write_uleb128(code, u64(field_getter))

	case ^Set_Property_Instr:
		// Set_Property_Instr не имеет dst — object и value УЖЕ на стеке в
		// этом порядке (см. instr_refs: append(&operands, v.object, v.value)),
		// но pw_set_field_* нужен порядок (handle, index, value) — index
		// между ними, поэтому здесь нельзя просто "оставить как есть":
		// нужна scratch-локаль для value, чтобы вставить index между handle
		// и value (тот же класс проблемы порядка, что Call_Value_Instr's
		// args/callee-разгребание, см. её case).
		emit_set_property(ectx, v)

	case ^Get_Index_Instr:
		#partial switch value_type_of(ectx, v.object).kind {
		case .Map:
			emit_map_get_index(ectx, v)
		case .String:
			// Фаза 2.8: text[i] — рунный индекс, [object, index] уже на
			// стеке (index сверху), i32.trunc_f64_s на месте (та же
			// прямая конверсия, что Array-путь ниже), pw_string_char_at
			// (handle, rune_idx) — совпадает с (object, index) один-в-
			// один, реордер не нужен.
			append(code, 0xAA)
			append(code, 0x10)
			write_uleb128(code, u64(PW_STRING_CHAR_AT))
		case:
			// object, index уже на стеке в этом порядке (см. instr_refs:
			// [object, index], index сверху). index — Целое (f64-
			// представление, см. wasm_val_type), pw_get_field_* принимает
			// i32 — конвертируем ПРЯМО на месте (index уже на вершине
			// стека, конверсия не требует scratch-локали, в отличие от
			// Set_Index_Instr ниже).
			append(code, 0xAA) // i32.trunc_f64_s
			field_getter := pw_typed_import(ectx, v.dst, PW_GET_FIELD_I32, PW_GET_FIELD_F64)
			append(code, 0x10)
			write_uleb128(code, u64(field_getter))
		}

	case ^Set_Index_Instr:
		emit_set_index(ectx, v)

	case ^Build_Variant_Instr:
		emit_construct_object(ectx, v.fields, PW_BUILD_VARIANT, i64(v.tag))

	case ^Match_Tag_Instr:
		// subject уже на стеке — ОБЫЧНЫЙ, полностью потребляемый операнд в
		// этом бэкенде (в отличие от core/mir_bytecode.odin's .Match_Tag,
		// который PEEK'ает subject и требует явного Pop на обеих ветках,
		// см. её докстринг — здесь этот воркэраунд не нужен: этот бэкенд
		// никогда не оставляет на стеке ничего, что не потребляется сразу
		// же, single-use держится буквально).
		append(code, 0x41) // i32.const tag
		write_sleb128(code, i64(v.tag))
		append(code, 0x10)
		write_uleb128(code, u64(PW_MATCH_TAG))

	case ^Get_Variant_Field_Instr:
		// Идентично Get_Property_Instr — field_index известен статически.
		append(code, 0x41) // i32.const field_index
		write_sleb128(code, i64(v.field_index))
		field_getter := pw_typed_import(ectx, v.dst, PW_GET_FIELD_I32, PW_GET_FIELD_F64)
		append(code, 0x10)
		write_uleb128(code, u64(field_getter))

	case ^Call_Builtin_Instr:
		// Фаза 2.0: единственный поддержанный builtin — ввод_вывод::печать
		// (dst == nil / Пусто, не паникует use_count-based drop-логику
		// emit_block_instructions — instr_refs для Call_Builtin_Instr
		// возвращает dst = v.dst напрямую, т.е. nil здесь).
		switch v.name {
		case "ввод_вывод::печать":
			append(code, 0x10) // call
			write_uleb128(code, u64(PW_PRINT_STRING))
		case "ввод_вывод::строка":
			// fmt.println — печать с завершающим переводом строки.
			append(code, 0x10) // call
			write_uleb128(code, u64(PW_PRINTLN_STRING))
		case "сеть::кодировать_url":
			append(code, 0x10)
			write_uleb128(code, u64(PW_URL_ENCODE))

		// --- DOM target (браузер) — все direct-call, БЕЗ переупорядочивания
		// операндов: аргументы уже в естественном MIR-порядке на стеке, и
		// "dom"-импорты (core/wasm_module.odin) принимают их в том же
		// порядке один-в-один. Опция(Строка)-возвращающие (текст/атрибут)
		// получают УЖЕ полностью собранный Опция-хендл от JS-стороны
		// (dom_get_text/dom_get_attribute сами вызывают pw_build_variant —
		// см. docs/src/assets/aot-dom-loader.js) — здесь нет разницы с
		// Булево-возвращающими, оба просто i32.
		case "DOM::текст":
			append(code, 0x10)
			write_uleb128(code, u64(PW_DOM_GET_TEXT))
		case "DOM::установить_текст":
			append(code, 0x10)
			write_uleb128(code, u64(PW_DOM_SET_TEXT))
		case "DOM::атрибут":
			append(code, 0x10)
			write_uleb128(code, u64(PW_DOM_GET_ATTRIBUTE))
		case "DOM::установить_атрибут":
			append(code, 0x10)
			write_uleb128(code, u64(PW_DOM_SET_ATTRIBUTE))
		case "DOM::удалить_атрибут":
			append(code, 0x10)
			write_uleb128(code, u64(PW_DOM_REMOVE_ATTRIBUTE))
		case "DOM::создать_и_добавить":
			append(code, 0x10)
			write_uleb128(code, u64(PW_DOM_CREATE_AND_APPEND))
		case "DOM::удалить":
			append(code, 0x10)
			write_uleb128(code, u64(PW_DOM_REMOVE))
		case "DOM::на_клик":
			// План todo-демо: контекст (3-й арг) уже на стеке в естественном
			// порядке вместе с селектором/именем — dom_on_click сама
			// запоминает его на JS-стороне и передаёт обработчику при
			// каждом клике (см. aot-dom-loader.js's registerHandler).
			append(code, 0x10)
			write_uleb128(code, u64(PW_DOM_ON_CLICK))
		case "DOM::на_ввод":
			append(code, 0x10)
			write_uleb128(code, u64(PW_DOM_ON_INPUT))
		case "DOM::значение_поля":
			// План todo-демо: ЖИВОЕ element.value (не HTML-атрибут — см.
			// PW_DOM_GET_VALUE's докстринг в wasm_module.odin).
			append(code, 0x10)
			write_uleb128(code, u64(PW_DOM_GET_VALUE))
		case "DOM::установить_значение_поля":
			append(code, 0x10)
			write_uleb128(code, u64(PW_DOM_SET_VALUE))

		case "сеть::http_запрос_sync":
			// План todo-демо: синхронный XHR на JS-стороне (aot-dom-loader.js)
			// — единственный способ сделать реальный fetch из wasm-кода без
			// suspend/resume, которого WASM MVP не даёт (см. [[project_
			// panos_wasm_actors_cps_design]] про то же ограничение у
			// actors). net_base — НЕ компайл-тайм константа (в отличие от
			// PW_DOM_*), см. Emit_Ctx.net_base's докстринг.
			append(code, 0x10)
			write_uleb128(code, u64(ectx.net_base))

		case "паника":
			// Фаза 2.6: паника(сообщение) — Строка-arg уже на стеке
			// (единственный операнд, см. instr_refs). Байткод-VM не
			// роняет процесс (Runtime Panic перехватывается наблюдателем/
			// супервизором, Стадия 38) — здесь такого механизма нет,
			// печатаем сообщение (переиспользуем pw_print_string, тот же
			// stdout-путь, что ввод_вывод::печать) и трапим WASM'ом
			// (0x00 unreachable) — ЖЁСТКАЯ остановка модуля, не catchable
			// изнутри panos-программы (актёры/супервизоры не реализованы
			// в этом бэкенде вообще, ловить панику некому). unreachable —
			// официальный WASM-маркер "дальше недостижимо": валидатор
			// принимает ЛЮБОЙ тип стека после него, дополнительных
			// инструкций для баланса стека не нужно (паника() типизирован
			// Никогда, dst отсутствует — тот же no-dst паттерн, что и
			// печать).
			append(code, 0x10)
			write_uleb128(code, u64(PW_PRINT_STRING))
			append(code, 0x00) // unreachable
		case "строки::длина_байт":
			// pw_string_len возвращает i32, но строки::длина_байт -> Целое
			// (см. core/stdlib.odin), а Целое в этом бэкенде — f64
			// (Фаза 1: рантайм-представление Целое/Число не различается,
			// см. wasm_val_type) — конвертируем.
			append(code, 0x10)
			write_uleb128(code, u64(PW_STRING_LEN))
			append(code, 0xB7) // f64.convert_i32_s
		case "строки::начинается_с":
			append(code, 0x10)
			write_uleb128(code, u64(PW_STRING_STARTS_WITH))
		case "строки::заканчивается_на":
			append(code, 0x10)
			write_uleb128(code, u64(PW_STRING_ENDS_WITH))
		case "строки::содержит":
			append(code, 0x10)
			write_uleb128(code, u64(PW_STRING_CONTAINS))
		case "строки::из_целого":
			append(code, 0x10)
			write_uleb128(code, u64(PW_INT_TO_STRING))
		case "строки::сравнить":
			append(code, 0x10)
			write_uleb128(code, u64(PW_STRING_COMPARE))
		case "строки::заменить":
			append(code, 0x10)
			write_uleb128(code, u64(PW_STRING_REPLACE_ALL))
		case "ос::версия_паноса":
			// Константа, не вызов — тот же emit_string_const, что
			// Const_Instr(string), см. её докстринг (PW_SCRATCH_SET-цикл +
			// pw_alloc_from_scratch).
			emit_string_const(ectx, PANOS_VERSION)
		case "время::монотонно_мс":
			append(code, 0x10)
			write_uleb128(code, u64(PW_MONOTONIC_MS))
		case "время::сейчас_мс":
			append(code, 0x10)
			write_uleb128(code, u64(PW_NOW_MS))

		// --- Фаза 2.8: рун-осведомлённые строковые builtin'ы --------------
		case "строки::срез", "строки::срез_байт":
			// [text, start, end] — end сверху, ОБА индекса нужно
			// конвертировать в i32 — тот же приём, что Массив.срез
			// (Фаза 2.2): конвертируем end на месте, снимаем в i32-
			// scratch, конвертируем start (теперь верх), возвращаем end.
			end_local := alloc_i32_scratch(ectx)
			append(code, 0xAA) // i32.trunc_f64_s (end)
			append(code, 0x21)
			write_uleb128(code, u64(end_local))
			append(code, 0xAA) // i32.trunc_f64_s (start — теперь верх)
			append(code, 0x20)
			write_uleb128(code, u64(end_local))
			append(code, 0x10)
			write_uleb128(code, u64(v.name == "строки::срез" ? PW_STRING_SLICE_RUNE : PW_STRING_SLICE_BYTE))
		case "строки::найти":
			// [text, pattern, from_idx] — from_idx сверху, конвертация на
			// месте, реордер не нужен. Результат — Целое, конвертируем.
			append(code, 0xAA)
			append(code, 0x10)
			write_uleb128(code, u64(PW_STRING_FIND_RUNE))
			append(code, 0xB7) // f64.convert_i32_s
		case "строки::байт":
			// [text, idx] — idx сверху, конвертация на месте.
			append(code, 0xAA)
			append(code, 0x10)
			write_uleb128(code, u64(PW_STRING_BYTE_AT))
			append(code, 0xB7)
		case "строки::из_байтов":
			append(code, 0x10)
			write_uleb128(code, u64(PW_STRING_FROM_BYTES))
		case "строки::в_байты":
			append(code, 0x10)
			write_uleb128(code, u64(PW_STRING_TO_BYTES))
		case "строки::кодовая_точка":
			append(code, 0x10)
			write_uleb128(code, u64(PW_STRING_CODEPOINT_AT_START))
			append(code, 0xB7)
		case "строки::в_руны":
			append(code, 0x10)
			write_uleb128(code, u64(PW_STRING_TO_RUNES))
		case "строки::из_рун":
			append(code, 0x10)
			write_uleb128(code, u64(PW_STRING_FROM_RUNES))
		case "строки::это_цифра":
			append(code, 0x10)
			write_uleb128(code, u64(PW_STRING_IS_DIGIT))
		case "строки::это_буква":
			append(code, 0x10)
			write_uleb128(code, u64(PW_STRING_IS_ALPHA))
		case "строки::цифра_или_буква":
			append(code, 0x10)
			write_uleb128(code, u64(PW_STRING_IS_DIGIT_OR_ALPHA))
		case "строки::верхний_регистр":
			append(code, 0x10)
			write_uleb128(code, u64(PW_STRING_TO_UPPER))
		case "строки::нижний_регистр":
			append(code, 0x10)
			write_uleb128(code, u64(PW_STRING_TO_LOWER))

		// --- Фаза 2.10: строки::в_число / из_числа ------------------------
		case "строки::из_числа":
			append(code, 0x10)
			write_uleb128(code, u64(PW_NUMBER_TO_STRING))
		case "строки::в_число":
			append(code, 0x10)
			write_uleb128(code, u64(PW_STRING_TO_NUMBER))

		// --- Фаза 2.11: строки::разбить / соединить / обрезать -------------
		case "строки::обрезать":
			append(code, 0x10)
			write_uleb128(code, u64(PW_STRING_TRIM))
		case "строки::разбить":
			append(code, 0x10)
			write_uleb128(code, u64(PW_STRING_SPLIT))
		case "строки::соединить":
			append(code, 0x10)
			write_uleb128(code, u64(PW_STRING_JOIN))

		case "длина":
			// Фаза 2.8: свободный длина(x) — полиморфен по РАСПОЗНАННОМУ
			// СТАТИЧЕСКИ типу x (Строка/Массив/Соответствие, core/vm.
			// odin:1120-1133 диспетчерит рантайм-типом — здесь заменяем
			// на compile-time value_kind, тот же принцип, что весь
			// остальной static-dispatch в этом бэкенде). Массив/
			// Соответствие переиспользуют УЖЕ существующие импорты —
			// новый рантайм-код нужен только для Строка (рунный счёт).
			#partial switch value_kind(ectx, v.args[0]) {
			case .String:
				append(code, 0x10)
				write_uleb128(code, u64(PW_STRING_LENGTH_RUNES))
			case .Array:
				append(code, 0x10)
				write_uleb128(code, u64(PW_ARRAY_LENGTH))
			case .Map:
				append(code, 0x10)
				write_uleb128(code, u64(PW_MAP_LENGTH))
			case:
				panic(fmt.tprintf("wasm backend Фаза 2.8: длина() на типе %v вне области", value_kind(ectx, v.args[0])))
			}
			append(code, 0xB7)
		case:
			panic(fmt.tprintf("wasm backend Фаза 2.0: builtin '%s' вне области (см. план)", v.name))
		}

	case ^Call_Method_Instr:
		if value_type_of(ectx, v.receiver).kind == .Map {
			emit_map_method_call(ectx, v)
		} else {
			emit_array_method_call(ectx, v)
		}

	case ^Try_Unwrap_Instr:
		emit_try_unwrap(ectx, v)

	case ^Copy_Instr:
	// Никогда не конструируется lowering'ом сегодня (зарезервирован для
	// будущих optimization-проходов, см. core/mir_bytecode.odin's
	// докстринг на этом же case) — но семантически тривиален для этого
	// бэкенда: src уже на стеке (обычный replay), dst — просто НОВОЕ имя
	// для ТОГО ЖЕ значения, никакой доп. эмиссии не нужно.

	case ^Load_Captured_Instr:
		// closures (см. план): __env — ПОСЛЕДНИЙ WASM-параметр текущей
		// функции (её собственный closure-хендл), см. wasm_module.odin's
		// per-function functype. Индекс+1 — поле 0 хендла зарезервировано
		// под fn_index (см. emit_closure_value), captured_i лежит в поле
		// i+1.
		env_local := len(ectx.fn.parameters)
		append(code, 0x20) // local.get __env
		write_uleb128(code, u64(env_local))
		append(code, 0x41) // i32.const (index+1)
		write_sleb128(code, i64(v.index + 1))
		field_getter := pw_typed_import(ectx, v.dst, PW_GET_FIELD_I32, PW_GET_FIELD_F64)
		append(code, 0x10)
		write_uleb128(code, u64(field_getter))

	case ^Cast_Interface_Instr:
		emit_cast_interface(ectx, v)

	case ^Invoke_Interface_Instr:
		emit_invoke_interface(ectx, v)

	case ^Call_Foreign_Instr:
		// План interop с внешний: args уже на стеке в порядке (обычный
		// replay) — внешний-импорт НЕ панос-компилируемая функция,
		// __env-трейлинг-параметр (см. план closures) сюда не относится
		// вообще, никакого разгребания порядка не нужно (в отличие от
		// Call_Value_Instr/Invoke_Interface_Instr — там callee/receiver
		// сам был значением НА стеке; здесь funcidx известен статически,
		// как у обычного Call_Instr). Тип-безопасность аргументов уже
		// гарантирована тайпчекером против Foreign_Decl-сигнатуры —
		// сверять их ещё раз здесь не нужно.
		wasm_idx, found := ectx.foreign_func_index^[v.fn]
		if !found {
			panic("wasm backend: внешний-функция не найдена в foreign_func_index — см. план interop (скан Call_Foreign_Instr в wasm_module.odin)")
		}
		append(code, 0x10) // call
		write_uleb128(code, u64(wasm_idx))

	case ^Call_Async_Instr,
	     ^Spawn_Instr,
	     ^Send_Instr,
	     ^Receive_Instr,
	     ^Receive_Signal_Instr:
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
	is_string := operand_kind == .String
	if is_string {
		#partial switch op {
		case .Equal:
			append(code, 0x10) // call pw_string_equal (уже возвращает i32 0/1)
			write_uleb128(code, u64(PW_STRING_EQUAL))
		case .NotEqual:
			append(code, 0x10)
			write_uleb128(code, u64(PW_STRING_EQUAL))
			append(code, 0x45) // i32.eqz — инверсия 0/1
		case:
			panic("wasm backend: этот Cmp_Op для Строка не должен возникать (typechecker должен был отклонить)")
		}
		return
	}
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

// emit_string_const — байты строковой константы передаются в wasm_runtime
// ПОБАЙТОВО через pw_scratch_set (не сырым адресом — см. докстринг
// wasm_runtime/runtime.odin про раздельно слинкованные модули), затем
// pw_alloc_from_scratch кладёт handle (i32) на стек — та же
// WASM_I32-репрезентация, что wasm_val_type даёт Строка.
@(private = "file")
emit_string_const :: proc(ectx: ^Emit_Ctx, s: string) {
	code := &ectx.code
	bytes := transmute([]u8)s
	for b, i in bytes {
		append(code, 0x41) // i32.const index
		write_sleb128(code, i64(i))
		append(code, 0x41) // i32.const byte
		write_sleb128(code, i64(b))
		append(code, 0x10) // call pw_scratch_set
		write_uleb128(code, u64(PW_SCRATCH_SET))
	}
	append(code, 0x41) // i32.const length
	write_sleb128(code, i64(len(bytes)))
	append(code, 0x10) // call pw_alloc_from_scratch
	write_uleb128(code, u64(PW_ALLOC_FROM_SCRATCH))
}
