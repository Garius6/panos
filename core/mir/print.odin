package mir

import "core:fmt"
import "core:strings"

// Человекочитаемый текстовый дамп MIR — верификационный инструмент Фазы 1
// (см. план: snapshot-тесты на печатное представление) и будущий бэкенд
// для --emit-mir. Формат не стабилен как API — только для чтения людьми/
// сравнения в тестах.

print_module :: proc(module: ^Mir_Module) -> string {
	b: strings.Builder
	strings.builder_init(&b)
	for &fn in module.functions {
		print_function_into(&b, &fn)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

print_function :: proc(fn: ^Mir_Function) -> string {
	b: strings.Builder
	strings.builder_init(&b)
	print_function_into(&b, fn)
	return strings.to_string(b)
}

@(private = "file")
print_function_into :: proc(b: ^strings.Builder, fn: ^Mir_Function) {
	fmt.sbprintf(b, "func %s(", fn.name)
	for p, i in fn.parameters {
		if i > 0 do strings.write_string(b, ", ")
		fmt.sbprintf(b, "local_%d", p)
	}
	strings.write_string(b, "):\n")

	for &blk in fn.blocks {
		print_block_into(b, &blk)
	}
}

@(private = "file")
print_block_into :: proc(b: ^strings.Builder, blk: ^Mir_Block) {
	fmt.sbprintf(b, "block %d:\n", blk.id)
	for instr in blk.instructions {
		strings.write_string(b, "    ")
		print_instr_into(b, instr)
		strings.write_byte(b, '\n')
	}
	strings.write_string(b, "    ")
	print_terminator_into(b, blk.terminator)
	strings.write_byte(b, '\n')
}

@(private = "file")
print_value :: proc(b: ^strings.Builder, v: Value_Id) {
	if v == INVALID_VALUE {
		strings.write_string(b, "<none>")
	} else {
		fmt.sbprintf(b, "v%d", v)
	}
}

@(private = "file")
print_const :: proc(b: ^strings.Builder, c: Const_Value) {
	switch cv in c {
	case f64:
		fmt.sbprintf(b, "%v", cv)
	case bool:
		fmt.sbprintf(b, "%v", cv)
	case string:
		fmt.sbprintf(b, "%q", cv)
	}
}

@(private = "file")
print_instr_into :: proc(b: ^strings.Builder, instr: Mir_Instruction) {
	switch v in instr {
	case ^Const_Instr:
		print_value(b, v.dst); strings.write_string(b, " = const ")
		print_const(b, v.value)
	case ^Copy_Instr:
		print_value(b, v.dst); strings.write_string(b, " = copy ")
		print_value(b, v.src)
	case ^Load_Local_Instr:
		print_value(b, v.dst); fmt.sbprintf(b, " = load_local local_%d", v.local)
	case ^Store_Local_Instr:
		fmt.sbprintf(b, "store_local local_%d, ", v.local); print_value(b, v.src)
	case ^Load_Captured_Instr:
		print_value(b, v.dst); fmt.sbprintf(b, " = load_captured %d", v.index)
	case ^Binary_Instr:
		print_value(b, v.dst); fmt.sbprintf(b, " = binary %v ", v.op)
		print_value(b, v.lhs); strings.write_string(b, ", "); print_value(b, v.rhs)
	case ^Compare_Instr:
		print_value(b, v.dst); fmt.sbprintf(b, " = compare %v ", v.op)
		print_value(b, v.lhs); strings.write_string(b, ", "); print_value(b, v.rhs)
	case ^Unary_Instr:
		print_value(b, v.dst); fmt.sbprintf(b, " = unary %v ", v.op)
		print_value(b, v.src)
	case ^Call_Instr:
		if d, ok := v.dst.?; ok { print_value(b, d); strings.write_string(b, " = ") }
		fmt.sbprintf(b, "call fn_%d(", v.callee)
		print_value_list(b, v.args)
		strings.write_byte(b, ')')
	case ^Call_Builtin_Instr:
		if d, ok := v.dst.?; ok { print_value(b, d); strings.write_string(b, " = ") }
		fmt.sbprintf(b, "call_builtin %q(", v.name)
		print_value_list(b, v.args)
		strings.write_byte(b, ')')
	case ^Call_Method_Instr:
		if d, ok := v.dst.?; ok { print_value(b, d); strings.write_string(b, " = ") }
		print_value(b, v.receiver)
		fmt.sbprintf(b, ".%s(", v.name)
		print_value_list(b, v.args)
		strings.write_byte(b, ')')
	case ^Call_Async_Instr:
		if d, ok := v.dst.?; ok { print_value(b, d); strings.write_string(b, " = ") }
		strings.write_string(b, "call_async ")
		if r, ok := v.receiver.?; ok { print_value(b, r); strings.write_byte(b, '.') }
		fmt.sbprintf(b, "%s(", v.name)
		print_value_list(b, v.args)
		strings.write_byte(b, ')')
	case ^Call_Foreign_Instr:
		if d, ok := v.dst.?; ok { print_value(b, d); strings.write_string(b, " = ") }
		fmt.sbprintf(b, "call_foreign fn_%d(", v.fn)
		print_value_list(b, v.args)
		strings.write_byte(b, ')')
	case ^New_Aggregate_Instr:
		print_value(b, v.dst)
		fmt.sbprintf(b, " = new_aggregate %q(", v.type_name)
		print_value_list(b, v.elements)
		strings.write_byte(b, ')')
	case ^Get_Property_Instr:
		print_value(b, v.dst); strings.write_string(b, " = get_property ")
		print_value(b, v.object); fmt.sbprintf(b, ", %d", v.field_index)
	case ^Set_Property_Instr:
		strings.write_string(b, "set_property ")
		print_value(b, v.object); fmt.sbprintf(b, ", %d, ", v.field_index); print_value(b, v.value)
	case ^New_Array_Instr:
		print_value(b, v.dst); strings.write_string(b, " = new_array(")
		print_value_list(b, v.elements)
		strings.write_byte(b, ')')
	case ^New_Map_Instr:
		print_value(b, v.dst); strings.write_string(b, " = new_map(")
		for k, i in v.keys {
			if i > 0 do strings.write_string(b, ", ")
			print_value(b, k); strings.write_string(b, ": "); print_value(b, v.vals[i])
		}
		strings.write_byte(b, ')')
	case ^Get_Index_Instr:
		print_value(b, v.dst); strings.write_string(b, " = get_index ")
		print_value(b, v.object); strings.write_string(b, ", "); print_value(b, v.index)
	case ^Set_Index_Instr:
		strings.write_string(b, "set_index ")
		print_value(b, v.object); strings.write_string(b, ", "); print_value(b, v.index)
		strings.write_string(b, ", "); print_value(b, v.value)
	case ^Cast_Interface_Instr:
		print_value(b, v.dst); strings.write_string(b, " = cast_interface ")
		print_value(b, v.src)
	case ^Invoke_Interface_Instr:
		if d, ok := v.dst.?; ok { print_value(b, d); strings.write_string(b, " = ") }
		print_value(b, v.receiver)
		fmt.sbprintf(b, ".%s(", v.method_name)
		print_value_list(b, v.args)
		strings.write_byte(b, ')')
	case ^Build_Variant_Instr:
		print_value(b, v.dst)
		fmt.sbprintf(b, " = build_variant %s.%s(", v.type_name, v.variant_name)
		print_value_list(b, v.fields)
		strings.write_byte(b, ')')
	case ^Match_Tag_Instr:
		print_value(b, v.dst); strings.write_string(b, " = match_tag ")
		print_value(b, v.subject); fmt.sbprintf(b, ", %d", v.tag)
	case ^Get_Variant_Field_Instr:
		print_value(b, v.dst); strings.write_string(b, " = get_variant_field ")
		print_value(b, v.subject); fmt.sbprintf(b, ", %d", v.field_index)
	case ^Build_Closure_Instr:
		print_value(b, v.dst)
		fmt.sbprintf(b, " = build_closure fn_%d(", v.fn)
		print_value_list(b, v.captured)
		strings.write_byte(b, ')')
	case ^Spawn_Instr:
		print_value(b, v.dst)
		fmt.sbprintf(b, " = spawn fn_%d(", v.callee)
		print_value_list(b, v.args)
		strings.write_byte(b, ')')
	case ^Send_Instr:
		strings.write_string(b, "send ")
		print_value(b, v.process); strings.write_string(b, ", "); print_value(b, v.message)
	case ^Receive_Instr:
		print_value(b, v.dst); strings.write_string(b, " = receive")
	case ^Receive_Signal_Instr:
		print_value(b, v.dst); strings.write_string(b, " = receive_signal")
	}
}

@(private = "file")
print_value_list :: proc(b: ^strings.Builder, vs: []Value_Id) {
	for v, i in vs {
		if i > 0 do strings.write_string(b, ", ")
		print_value(b, v)
	}
}

@(private = "file")
print_terminator_into :: proc(b: ^strings.Builder, term: Mir_Terminator) {
	switch t in term {
	case ^Jump_Term:
		fmt.sbprintf(b, "jump %d", t.target)
	case ^Branch_Term:
		strings.write_string(b, "branch ")
		print_value(b, t.cond)
		fmt.sbprintf(b, ", %d, %d", t.then_block, t.else_block)
	case ^Return_Term:
		strings.write_string(b, "return")
		if v, ok := t.value.?; ok {
			strings.write_byte(b, ' ')
			print_value(b, v)
		}
	case ^Unreachable_Term:
		fmt.sbprintf(b, "unreachable %q", t.reason)
	case nil:
		strings.write_string(b, "<нет terminator'а>")
	}
}
