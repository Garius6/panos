package core

// Cfg_Info — вычисляется НА ЛЕТУ из terminator'ов блоков функции, не
// хранится как отдельный синхронизируемый граф (см. mir.odin: terminator
// каждого блока — единственный источник истины про control flow).
// Выбрасывается сразу после использования — не кэшируется в
// Mir_Function, чтобы lowering/оптимизации, меняющие terminator'ы, не
// могли оставить Cfg_Info рассинхронизированным с реальным графом.
Cfg_Info :: struct {
	predecessors:      [][dynamic]Block_Id,
	reachable:         []bool,
	reverse_postorder: []Block_Id,
}

// successors — куда из блока идёт control flow согласно ЕГО terminator'у.
// Фиксированный [2]Block_Id + count вместо []Block_Id — компаунд-литерал
// слайса из локального массива нельзя возвращать (память кадра стека),
// а больше двух преемников terminator'у сегодня взяться неоткуда.
// nil-терминатор (блок ещё строится, не завершён) — ноль преемников, как
// и Return/Unreachable.
successors :: proc(term: Mir_Terminator) -> (out: [2]Block_Id, count: int) {
	switch t in term {
	case ^Jump_Term:
		out[0] = t.target
		count = 1
	case ^Branch_Term:
		out[0] = t.then_block
		out[1] = t.else_block
		count = 2
	case ^Return_Term:
	case ^Unreachable_Term:
	}
	return
}

compute_cfg_info :: proc(fn: ^Mir_Function, allocator := context.allocator) -> Cfg_Info {
	n := len(fn.blocks)
	info := Cfg_Info {
		predecessors = make([][dynamic]Block_Id, n, allocator),
		reachable    = make([]bool, n, allocator),
	}
	for i in 0 ..< n {
		info.predecessors[i] = make([dynamic]Block_Id, allocator)
	}

	if n == 0 || fn.entry == INVALID_BLOCK {
		info.reverse_postorder = make([]Block_Id, 0, allocator)
		return info
	}

	// Итеративный post-order DFS (без рекурсии — CFG может быть глубоким
	// на длинной цепочке если/иначе, рекурсивный обход рисковал бы стеком
	// Odin-компилятора на достаточно большой функции).
	postorder := make([dynamic]Block_Id, 0, n, allocator)
	visited := make([]bool, n, allocator)
	defer delete(visited)

	Frame :: struct {
		block:      Block_Id,
		succ_index: int,
	}
	stack := make([dynamic]Frame, 0, n, allocator)
	defer delete(stack)

	visited[int(fn.entry)] = true
	info.reachable[int(fn.entry)] = true
	append(&stack, Frame{block = fn.entry, succ_index = 0})

	for len(stack) > 0 {
		frame := &stack[len(stack) - 1]
		succs, succ_count := successors(fn.blocks[int(frame.block)].terminator)

		if frame.succ_index < succ_count {
			next := succs[frame.succ_index]
			frame.succ_index += 1

			append(&info.predecessors[int(next)], frame.block)

			if !visited[int(next)] {
				visited[int(next)] = true
				info.reachable[int(next)] = true
				append(&stack, Frame{block = next, succ_index = 0})
			}
		} else {
			append(&postorder, frame.block)
			pop(&stack)
		}
	}

	// reverse_postorder — postorder, развёрнутый задом наперёд
	info.reverse_postorder = make([]Block_Id, len(postorder), allocator)
	for i in 0 ..< len(postorder) {
		info.reverse_postorder[i] = postorder[len(postorder) - 1 - i]
	}

	return info
}

destroy_cfg_info :: proc(info: ^Cfg_Info) {
	for preds in info.predecessors {
		delete(preds)
	}
	delete(info.predecessors)
	delete(info.reachable)
	delete(info.reverse_postorder)
}
