package core

// wasm_stackify.odin — структурные запросы над MIR CFG (core/mir_cfg.odin),
// нужные wasm_emit.odin, чтобы решить, где открывать/закрывать WASM
// `loop`/`if` (структурный control flow — блок/loop/if, без goto). Не
// строит отдельное IR-дерево — чистые ЗАПРОСЫ, вызываемые прямо из
// emit-прохода (см. wasm_emit.odin's process_from).
//
// Почему не полноценный Emscripten-style relooper: panos как ЯЗЫК не
// имеет goto/произвольных переходов — ЕДИНСТВЕННЫЙ источник MIR CFG —
// mir_lowering.odin, а он строит если/иначе и пока СТРУКТУРНО (см.
// lower_if_expr/lower_while_expr): граф всегда reducible. Но "куда
// сливаются ветки если/иначе" и "какая ветка Branch у loop-header — тело,
// какая — выход" НЕЛЬЗЯ надёжно определить одной лишь reverse_postorder-
// позицией (в отличие от back-edge, см. is_loop_header) — нужна
// доминация: merge если/иначе — единственный блок M с idom[M]==branch_block,
// M ∉ {then_block, else_block} (см. find_merge) — только у ТАКОГО M ВСЕ
// пути схождения проходят исключительно через branch_block, что и значит
// "точка слияния именно ЭТОГО если/иначе", а не блок, разделяемый с
// чем-то внешним (напр. exit_block цикла, к которому может вести и
// `прервать` изнутри if/else, и собственная else-ветка header'а — то есть
// БЕЗ доминации простая эвристика "больше одного предшественника" путает
// "слияние моих двух веток" с "разделяемая с внешним кодом точка", см.
// process_from's stop_at-параметр в wasm_emit.odin).

build_rpo_index :: proc(info: ^Cfg_Info, allocator := context.allocator) -> map[Block_Id]int {
	idx := make(map[Block_Id]int, allocator)
	for b, i in info.reverse_postorder do idx[b] = i
	return idx
}

// is_loop_header — true, если у блока b есть предшественник p с
// rpo_index[p] >= rpo_index[b] (back-edge). Верно именно потому, что jump-
// на-header цикла — единственное "назад" ребро, которое вообще может
// возникнуть в MIR этого лоуринга (тот же факт, на который уже опирается
// core/mir_bytecode.odin: "Branch_Term всегда вперёд").
is_loop_header :: proc(info: ^Cfg_Info, rpo_index: map[Block_Id]int, b: Block_Id) -> bool {
	bi, bok := rpo_index[b]
	if !bok do return false
	for p in info.predecessors[int(b)] {
		pi, pok := rpo_index[p]
		if pok && pi >= bi do return true
	}
	return false
}

// can_reach — достижим ли target из from по successors() (см.
// core/mir_cfg.odin), не заходя за уже посещённые блоки.
can_reach :: proc(fn: ^Mir_Function, from: Block_Id, target: Block_Id) -> bool {
	visited := make(map[Block_Id]bool)
	defer delete(visited)
	stack := make([dynamic]Block_Id)
	defer delete(stack)
	append(&stack, from)
	for len(stack) > 0 {
		b := pop(&stack)
		if b == target do return true
		if visited[b] do continue
		visited[b] = true
		succs, count := successors(fn.blocks[int(b)].terminator)
		for i in 0 ..< count {
			if !visited[succs[i]] do append(&stack, succs[i])
		}
	}
	return false
}

// identify_loop_body_and_exit — header's Branch_Term(cond, t, e): который
// из t/e — тело цикла (может дойти назад до header), который — блок после
// цикла. Не полагается на порядок аргументов Branch_Term (which arm is
// "then") — проверяет структурно.
identify_loop_body_and_exit :: proc(
	fn: ^Mir_Function,
	header: Block_Id,
	t: Block_Id,
	e: Block_Id,
) -> (
	body: Block_Id,
	exit: Block_Id,
) {
	if can_reach(fn, t, header) do return t, e
	return e, t
}

// compute_idom — immediate dominators, стандартный итеративный алгоритм
// (Cooper/Harvey/Kennedy, "A Simple, Fast Dominance Algorithm") поверх
// reverse_postorder + predecessors, которые уже посчитаны Cfg_Info.
compute_idom :: proc(
	fn: ^Mir_Function,
	info: ^Cfg_Info,
	rpo_index: map[Block_Id]int,
	allocator := context.allocator,
) -> map[Block_Id]Block_Id {
	idom := make(map[Block_Id]Block_Id, allocator)
	entry := fn.entry
	idom[entry] = entry

	changed := true
	for changed {
		changed = false
		for b in info.reverse_postorder {
			if b == entry do continue
			new_idom := INVALID_BLOCK
			for p in info.predecessors[int(b)] {
				_, p_done := idom[p]
				if !p_done do continue
				if new_idom == INVALID_BLOCK {
					new_idom = p
				} else {
					new_idom = intersect_doms(idom, rpo_index, new_idom, p)
				}
			}
			if new_idom != INVALID_BLOCK {
				old, had_old := idom[b]
				if !had_old || old != new_idom {
					idom[b] = new_idom
					changed = true
				}
			}
		}
	}
	return idom
}

@(private = "file")
intersect_doms :: proc(idom: map[Block_Id]Block_Id, rpo_index: map[Block_Id]int, a, b: Block_Id) -> Block_Id {
	x, y := a, b
	for x != y {
		for rpo_index[x] > rpo_index[y] do x = idom[x]
		for rpo_index[y] > rpo_index[x] do y = idom[y]
	}
	return x
}

// find_merge — единственный блок M с idom[M]==branch_block, кроме самих
// then_block/else_block (см. докстринг файла). ok=false — обе ветки
// завершают выполнение (возврат/паника/цикл навечно), слияния нет.
find_merge :: proc(
	fn: ^Mir_Function,
	idom: map[Block_Id]Block_Id,
	branch_block, then_block, else_block: Block_Id,
) -> (
	merge: Block_Id,
	ok: bool,
) {
	for i in 0 ..< len(fn.blocks) {
		b := Block_Id(i)
		if b == then_block || b == else_block || b == branch_block do continue
		d, has := idom[b]
		if has && d == branch_block do return b, true
	}
	return INVALID_BLOCK, false
}
