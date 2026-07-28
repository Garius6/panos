package mir

import core "../"
import "core:fmt"

Validation_Issue :: struct {
	message:  string,
	// true = структурная ошибка (сломанный MIR, доверять дальше нельзя);
	// false = предупреждение (напр. недостижимый блок — может быть
	// легитимным, см. план: "не обязательно отклонять").
	is_error: bool,
}

// validate_function — прогоняется ПОСЛЕ лоуринга каждой функции (Фаза 1
// верификация, см. план). Не мутирует MIR, только читает.
validate_function :: proc(
	module: ^Mir_Module,
	fn: ^Mir_Function,
	allocator := context.allocator,
) -> [dynamic]Validation_Issue {
	issues := make([dynamic]Validation_Issue, allocator)

	n_blocks := len(fn.blocks)
	n_locals := len(fn.locals)
	n_values := len(fn.value_types)

	if fn.entry == INVALID_BLOCK || int(fn.entry) >= n_blocks {
		append(
			&issues,
			Validation_Issue {
				fmt.tprintf(
					"функция '%s': entry-блок не задан или вне диапазона",
					fn.name,
				),
				true,
			},
		)
		return issues // дальше без валидного entry смысла нет
	}

	valid_block :: proc(id: Block_Id, n: int) -> bool { return int(id) < n && id != INVALID_BLOCK }
	valid_local :: proc(id: Local_Id, n: int) -> bool { return int(id) < n }
	valid_value :: proc(id: Value_Id, n: int) -> bool { return int(id) < n && id != INVALID_VALUE }

	for &blk in fn.blocks {
		if blk.terminator == nil {
			append(
				&issues,
				Validation_Issue {
					fmt.tprintf(
						"функция '%s', блок %d: нет terminator'а",
						fn.name,
						blk.id,
					),
					true,
				},
			)
			continue
		}

		switch t in blk.terminator {
		case ^Jump_Term:
			if !valid_block(t.target, n_blocks) {
				append(
					&issues,
					Validation_Issue {
						fmt.tprintf(
							"функция '%s', блок %d: Jump на несуществующий блок %d",
							fn.name,
							blk.id,
							t.target,
						),
						true,
					},
				)
			}
		case ^Branch_Term:
			if !valid_value(t.cond, n_values) {
				append(
					&issues,
					Validation_Issue {
						fmt.tprintf(
							"функция '%s', блок %d: Branch с неопределённым условием",
							fn.name,
							blk.id,
						),
						true,
					},
				)
			}
			if !valid_block(t.then_block, n_blocks) {
				append(
					&issues,
					Validation_Issue {
						fmt.tprintf(
							"функция '%s', блок %d: Branch.then на несуществующий блок %d",
							fn.name,
							blk.id,
							t.then_block,
						),
						true,
					},
				)
			}
			if !valid_block(t.else_block, n_blocks) {
				append(
					&issues,
					Validation_Issue {
						fmt.tprintf(
							"функция '%s', блок %d: Branch.else на несуществующий блок %d",
							fn.name,
							blk.id,
							t.else_block,
						),
						true,
					},
				)
			}
		case ^Return_Term:
			returns_value := core.prune_type(fn.result_type) != core.TY_VOID
			has_value := t.value != nil
			if returns_value && !has_value {
				append(
					&issues,
					Validation_Issue {
						fmt.tprintf(
							"функция '%s', блок %d: Return без значения у функции с непустым типом результата",
							fn.name,
							blk.id,
						),
						true,
					},
				)
			}
			if !returns_value && has_value {
				append(
					&issues,
					Validation_Issue {
						fmt.tprintf(
							"функция '%s', блок %d: Return со значением у функции с типом результата Пусто",
							fn.name,
							blk.id,
						),
						true,
					},
				)
			}
			if v, ok := t.value.?; ok && !valid_value(v, n_values) {
				append(
					&issues,
					Validation_Issue {
						fmt.tprintf(
							"функция '%s', блок %d: Return с неопределённым значением",
							fn.name,
							blk.id,
						),
						true,
					},
				)
			}
		case ^Unreachable_Term:
		}

		for instr in blk.instructions {
			dst, operands := instr_refs(instr)
			if d, ok := dst.?; ok && !valid_value(d, n_values) {
				append(
					&issues,
					Validation_Issue {
						fmt.tprintf(
							"функция '%s', блок %d: инструкция пишет в неопределённый Value_Id",
							fn.name,
							blk.id,
						),
						true,
					},
				)
			}
			for op in operands {
				if !valid_value(op, n_values) {
					append(
						&issues,
						Validation_Issue {
							fmt.tprintf(
								"функция '%s', блок %d: инструкция читает неопределённый Value_Id",
								fn.name,
								blk.id,
							),
							true,
						},
					)
				}
			}
			delete(operands)

			#partial switch v in instr {
			case ^Load_Local_Instr:
				if !valid_local(v.local, n_locals) {
					append(
						&issues,
						Validation_Issue {
							fmt.tprintf(
								"функция '%s', блок %d: Load_Local вне диапазона locals",
								fn.name,
								blk.id,
							),
							true,
						},
					)
				}
			case ^Store_Local_Instr:
				if !valid_local(v.local, n_locals) {
					append(
						&issues,
						Validation_Issue {
							fmt.tprintf(
								"функция '%s', блок %d: Store_Local вне диапазона locals",
								fn.name,
								blk.id,
							),
							true,
						},
					)
				}
			case ^Call_Instr:
				if int(v.callee) >= len(module.functions) {
					append(
						&issues,
						Validation_Issue {
							fmt.tprintf(
								"функция '%s', блок %d: Call на несуществующую функцию",
								fn.name,
								blk.id,
							),
							true,
						},
					)
				} else {
					callee := &module.functions[int(v.callee)]
					if len(v.args) != len(callee.parameters) {
						append(
							&issues,
							Validation_Issue {
								fmt.tprintf(
									"функция '%s', блок %d: Call в '%s' с %d аргументами, ожидалось %d",
									fn.name,
									blk.id,
									callee.name,
									len(v.args),
									len(callee.parameters),
								),
								true,
							},
						)
					}
				}
			}
		}
	}

	info := compute_cfg_info(fn, allocator)
	for i in 0 ..< n_blocks {
		if !info.reachable[i] {
			append(
				&issues,
				Validation_Issue {
					fmt.tprintf(
						"функция '%s': блок %d недостижим из entry",
						fn.name,
						i,
					),
					false,
				},
			)
		}
	}
	destroy_cfg_info(&info)

	return issues
}

validate_module :: proc(
	module: ^Mir_Module,
	allocator := context.allocator,
) -> [dynamic]Validation_Issue {
	all := make([dynamic]Validation_Issue, allocator)
	for &fn in module.functions {
		issues := validate_function(module, &fn, allocator)
		for i in issues do append(&all, i)
		delete(issues)
	}
	return all
}

// instr_refs — (dst, []operands) единой инструкции. Исчерпывающий switch
// (не #partial) — новый вариант Mir_Instruction без case здесь не
// скомпилируется, тот же принцип, что get_header/mark_value в core/gc.
// odin (см. docs/src/architecture/memory-and-gc.md).
@(private = "file")
instr_refs :: proc(
	instr: Mir_Instruction,
	allocator := context.allocator,
) -> (
	dst: Maybe(Value_Id),
	operands: [dynamic]Value_Id,
) {
	operands = make([dynamic]Value_Id, allocator)
	switch v in instr {
	case ^Const_Instr:
		dst = v.dst
	case ^Copy_Instr:
		dst = v.dst
		append(&operands, v.src)
	case ^Load_Local_Instr:
		dst = v.dst
	case ^Store_Local_Instr:
		append(&operands, v.src)
	case ^Load_Captured_Instr:
		dst = v.dst
	case ^Binary_Instr:
		dst = v.dst
		append(&operands, v.lhs, v.rhs)
	case ^Compare_Instr:
		dst = v.dst
		append(&operands, v.lhs, v.rhs)
	case ^Unary_Instr:
		dst = v.dst
		append(&operands, v.src)
	case ^Call_Instr:
		dst = v.dst
		for a in v.args do append(&operands, a)
	case ^Call_Builtin_Instr:
		dst = v.dst
		for a in v.args do append(&operands, a)
	case ^Call_Method_Instr:
		dst = v.dst
		append(&operands, v.receiver)
		for a in v.args do append(&operands, a)
	case ^Call_Async_Instr:
		dst = v.dst
		if r, ok := v.receiver.?; ok do append(&operands, r)
		for a in v.args do append(&operands, a)
	case ^Call_Foreign_Instr:
		dst = v.dst
		for a in v.args do append(&operands, a)
	case ^New_Aggregate_Instr:
		dst = v.dst
		for e in v.elements do append(&operands, e)
	case ^Get_Property_Instr:
		dst = v.dst
		append(&operands, v.object)
	case ^Set_Property_Instr:
		append(&operands, v.object, v.value)
	case ^New_Array_Instr:
		dst = v.dst
		for e in v.elements do append(&operands, e)
	case ^New_Map_Instr:
		dst = v.dst
		for k in v.keys do append(&operands, k)
		for val in v.vals do append(&operands, val)
	case ^Get_Index_Instr:
		dst = v.dst
		append(&operands, v.object, v.index)
	case ^Set_Index_Instr:
		append(&operands, v.object, v.index, v.value)
	case ^Cast_Interface_Instr:
		dst = v.dst
		append(&operands, v.src)
	case ^Invoke_Interface_Instr:
		dst = v.dst
		append(&operands, v.receiver)
		for a in v.args do append(&operands, a)
	case ^Build_Variant_Instr:
		dst = v.dst
		for f in v.fields do append(&operands, f)
	case ^Match_Tag_Instr:
		dst = v.dst
		append(&operands, v.subject)
	case ^Get_Variant_Field_Instr:
		dst = v.dst
		append(&operands, v.subject)
	case ^Build_Closure_Instr:
		dst = v.dst
		for c in v.captured do append(&operands, c)
	case ^Spawn_Instr:
		dst = v.dst
		for a in v.args do append(&operands, a)
	case ^Send_Instr:
		append(&operands, v.process, v.message)
	case ^Receive_Instr:
		dst = v.dst
	case ^Receive_Signal_Instr:
		dst = v.dst
	}
	return
}
