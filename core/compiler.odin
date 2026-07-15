package core

import "core:fmt"
import "core:strings"

// Все heap-managed варианты Value (кроме f64/bool/^Compiled_Function —
// см. GC_State в gc.odin) встраивают GC_Header первым полем.
Aggregate_Value :: struct {
	header:   GC_Header,
	elements: [dynamic]Value, // В реальном продакшене лучше использовать фиксированный срез (slice)
}

Array_Value :: struct {
	header:   GC_Header,
	elements: [dynamic]Value,
}

Map_Entry_Value :: struct {
	key:   Value,
	value: Value,
}

Map_Value :: struct {
	header:  GC_Header,
	entries: [dynamic]Map_Entry_Value,
}

Error_Value :: struct {
	header:  GC_Header,
	// ^Panos_String, а не string — поля читаются/пишутся напрямую как
	// Panos-значения через Get_Property/Set_Property (см. vm.odin), должны
	// участвовать в mark/sweep как любой другой Value.string.
	code:    ^Panos_String,
	message: ^Panos_String,
}

Option_Value :: struct {
	header:    GC_Header,
	has_value: bool,
	value:     Value,
}

Result_Value :: struct {
	header: GC_Header,
	is_ok:  bool,
	value:  Value,
	error:  Value,
}

Interface_Value :: struct {
	header:  GC_Header,
	data:    ^Aggregate_Value,
	// VTable: связывает имя метода из контракта с реальной скомпилированной функцией
	methods: map[string]^Compiled_Function,
}

// Значение варианта пользовательского ADT (либо построенного через prelude
// Option/Result — см. plan/research). Хранит имя типа-владельца (для
// диагностики и печати), числовой индекс варианта (порядок объявления) и
// поля варианта.
Variant_Value :: struct {
	header:    GC_Header,
	type_name: string,
	tag_index: int,
	fields:    [dynamic]Value,
}

// File_Value/Socket_Value (фс/сеть builtin'ы) — определены в
// file_value_native.odin/file_value_wasm.odin (#+build split), не здесь.
// Причина: поля handle/socket типизированы ^os.File/net.TCP_Socket, а
// сам ИМПОРТ core:os падает compile-time panic'ом под js_wasm32 (браузер
// не может делать реальный ФС/сокеты) — см. заметку в ROADMAP про WASM-
// спайк.

Value :: union {
	f64,
	bool,
	^Panos_String,
	^Compiled_Function,
	^Aggregate_Value,
	^Array_Value,
	^Map_Value,
	^Error_Value,
	^Option_Value,
	^Result_Value,
	^Interface_Value,
	^Variant_Value,
	^File_Value,
	^Socket_Value,
}

Compiled_Function :: struct {
	name:          string,
	instructions:  [dynamic]u8,
	constants:     [dynamic]Value,
	frame_size:    int,
	returns_value: bool,
}

Local :: struct {
	symbol: Symbol_Id, // Берем из Resolver_Ctx
	depth:  int,
}

Loop_Context :: struct {
	continue_target: int,
	break_jumps:     [dynamic]int,
}

symbol_registry_key :: proc(store: ^Symbol_Store, id: Symbol_Id) -> string {
	if id == INVALID_SYMBOL do return ""
	sym := symbol_at(store, id)
	// Interned(0) зарезервирован под "" — отличает заданный full_name от незаполненного.
	if sym.full_name != Interned(0) do return resolve_interned(sym.full_name)
	return resolve_interned(sym.name)
}

Compiler :: struct {
	registry:         ^map[string]^Compiled_Function, // Указатель на глобальный реестр
	current_function: ^Compiled_Function,
	tc:               ^Type_Ctx,
	res:              ^Resolver_Ctx,
	locals:           [dynamic]Local,
	loops:            [dynamic]Loop_Context,
	scope_depth:      int,
}

new_compiler :: proc(res: ^Resolver_Ctx, name: string) -> Compiler {

	c := Compiler {
		res         = res,
		locals      = make([dynamic]Local),
		loops       = make([dynamic]Loop_Context),
		scope_depth = 0,
	}
	return c
}

Opcode :: enum u8 {
	Constant, // Операнд: 1 байт (индекс в пуле констант)
	Add, // Без операндов
	Subtract,
	Multiply,
	Divide,
	Less,
	Greater,
	Equal,
	Negate,
	Get_Local, // Операнд: 1 байт (индекс слота во фрейме)
	Set_Local, // Операнд: 1 байт (индекс слота во фрейме)
	Jump_If_False, // Операнд: 2 байта (смещение прыжка)
	Jump, // Операнд: 2 байта (смещение прыжка)
	Pop, // Удалить вершину стека
	Return, // Возврат из функции
	Call,
	Build_Aggregate, // Операнд: 1 байт (количество элементов)
	Set_Property,
	Get_Property, // Операнд: 1 байт (индекс поля)
	Cast_Interface,
	Invoke_Interface,
	Build_Array,
	Build_Map,
	Get_Index,
	Set_Index,
	Invoke_Collection,
	Call_Builtin,
	Try_Unwrap,
	Match_Tag, // Операнд: 1 байт (индекс константы с int-тегом). Читает вершину без снятия, кладёт bool.
	Get_Variant_Field, // Операнд: 1 байт (индекс поля). Снимает variant, кладёт значение поля.
	Match_Fail, // Без операнда. Runtime-трап при недостижимом промахе `выбор`.
	Build_Variant, // Операнды: 3 байта (type_name_const, tag, arity). Снимает arity полей, кладёт ^Variant_Value.
}

// Записать 1 байт в массив инструкций
emit_byte :: proc(c: ^Compiler, byte: u8) {
	append(&c.current_function.instructions, byte)
}

// Записать опкод
emit_opcode :: proc(c: ^Compiler, op: Opcode) {
	emit_byte(c, u8(op))
}

// Возвращает индекс константы в пуле (без генерации опкода .Constant)
make_constant :: proc(c: ^Compiler, value: Value) -> u8 {
	append(&c.current_function.constants, value)
	idx := len(c.current_function.constants) - 1

	if idx > 255 {
		fmt.panicf(
			"Compiler Error: слишком много констант в одной функции!",
		)
	}
	return u8(idx)
}

// Сохранить константу и сгенерировать опкод для ее загрузки на стек
emit_constant :: proc(c: ^Compiler, value: Value) {
	idx := make_constant(c, value)
	emit_opcode(c, .Constant)
	emit_byte(c, idx)
}

// Генерирует опкод прыжка и 2 пустых байта для адреса.
// Возвращает индекс, куда потом нужно будет вписать правильный адрес.
emit_jump :: proc(c: ^Compiler, op: Opcode) -> int {
	emit_opcode(c, op)
	emit_byte(c, 0xff) // Фиктивный старший байт
	emit_byte(c, 0xff) // Фиктивный младший байт
	return len(c.current_function.instructions) - 2
}

// Вызывается после того, как тело блока скомпилировано.
// Вычисляет длину прыжка и "зашивает" ее поверх 0xFFFF.
patch_jump :: proc(c: ^Compiler, offset: int) {
	// Насколько далеко нужно прыгнуть (текущая длина минус адрес прыжка минус 2 байта операнда)
	jump_length := len(c.current_function.instructions) - offset - 2

	if jump_length > 65535 {
		fmt.panicf("Too much code to jump over!")
	}

	c.current_function.instructions[offset] = u8((jump_length >> 8) & 0xff) // Старший байт
	c.current_function.instructions[offset + 1] = u8(jump_length & 0xff) // Младший байт
}

patch_signed_jump_to :: proc(c: ^Compiler, offset: int, target: int) {
	jump_length := target - (offset + 2)
	if jump_length < -32768 || jump_length > 32767 {
		fmt.panicf("Too much code to jump over!")
	}
	c.current_function.instructions[offset] = u8((jump_length >> 8) & 0xff)
	c.current_function.instructions[offset + 1] = u8(jump_length & 0xff)
}

// Создаёт пустой Compiled_Function-скелет для sym и кладёт в registry —
// общий hoisting-паттерн для Function_Decl и методов Impl_Decl (ПРОХОД 1),
// позволяющий forward-вызовы (функция А зовёт Б, объявленную ниже).
hoist_compiled_function :: proc(
	res: ^Resolver_Ctx,
	tc: ^Type_Ctx,
	registry: ^map[string]^Compiled_Function,
	sym: Symbol_Id,
) {
	fn := new(Compiled_Function)
	fn.name = symbol_registry_key(res.symbol_store, sym)
	func_type := tc.res.symbol_types[sym]
	fn.returns_value = prune_type(func_type.return_type) != TY_VOID
	fn.instructions = make([dynamic]u8)
	fn.constants = make([dynamic]Value)
	registry^[fn.name] = fn
}

// Компилирует тело функции/метода sym в уже захостенный (ПРОХОД 1)
// Compiled_Function: строит Compiler, регистрирует locals по args_syms
// (func_args ключуется AST-узлом декларации, не Symbol_Id — отдельный
// параметр key), компилирует блок, эмиттит Return. Общий паттерн для
// Function_Decl и методов Impl_Decl (ПРОХОД 2).
compile_decl_body :: proc(
	registry: ^map[string]^Compiled_Function,
	tc: ^Type_Ctx,
	res: ^Resolver_Ctx,
	sym: Symbol_Id,
	key: Decls,
	body: [dynamic]Stmt,
) {
	ctx := Compiler {
		registry         = registry,
		current_function = registry^[symbol_registry_key(res.symbol_store, sym)],
		tc               = tc,
		res              = res,
		locals           = make([dynamic]Local),
	}
	if args_syms, ok := ctx.res.func_args[key]; ok {
		for s in args_syms do append(&ctx.locals, Local{symbol = s, depth = 0})
	}
	ctx.current_function.frame_size = len(ctx.locals)
	compile_block(&ctx, body, true)
	emit_opcode(&ctx, .Return)
}

compile_program :: proc(
	res: ^Resolver_Ctx,
	tc: ^Type_Ctx,
	program: ^Program,
	registry: ^map[string]^Compiled_Function = nil,
) -> map[string]^Compiled_Function {
	registry_ptr := registry
	if registry_ptr == nil {
		local_registry := make(map[string]^Compiled_Function)
		registry_ptr = &local_registry
	}

	// ПРОХОД 1: Выделяем память под функции (Hoisting)
	// Это позволит функции 'старт' вызывать функцию 'а', даже если 'а' объявлена ниже.
	for decl in program.decls {
		#partial switch d in decl {
		case ^Import_Decl:
		// Импорты не порождают исполняемый код.
		case ^Function_Decl:
			hoist_compiled_function(res, tc, registry_ptr, res.decl_symbols[decl])
		case ^Impl_Decl:
			for m in d.methods {
				hoist_compiled_function(res, tc, registry_ptr, res.decl_symbols[m])
			}
		}
	}

	// ПРОХОД 2: Компиляция тел функций
	for decl in program.decls {
		#partial switch d in decl {
		case ^Function_Decl:
			compile_decl_body(registry_ptr, tc, res, res.decl_symbols[decl], decl, d.body)
		case ^Impl_Decl:
			for m in d.methods {
				compile_decl_body(registry_ptr, tc, res, res.decl_symbols[m], m, m.body)
			}
		}
	}

	return registry_ptr^ // Возвращаем только готовые функции!}
}

compile_decl :: proc(c: ^Compiler, decl: Decls) {
	#partial switch d in decl {
	case ^Import_Decl:
	case ^Impl_Decl:
	case ^Struct_Decl:
	case ^Interface_Decl:
	case ^Enum_Decl:
	// Компиляция уже произошла в type checker'е: тип и варианты
	// зарегистрированы. Байткод для конструкторов эмитится в местах
	// вызова (T016/T017), не здесь.

	case ^Function_Decl:
		function := new(Compiled_Function)
		function.name = d.name

		c.current_function = function

		for stmt in d.body {
			compile_statement(c, stmt)
		}

		c.registry^[function.name] = function
	}
}

compile_statement :: proc(ctx: ^Compiler, statement: Stmt) {
	switch stmt in statement {
	case ^Let_Stmt:
		compile_expr(ctx, stmt.value)

		sym := ctx.res.stmt_symbols[stmt]
		append(&ctx.locals, Local{symbol = sym, depth = ctx.scope_depth})
		slot_index := len(ctx.locals) - 1

		ctx.current_function.frame_size = max(ctx.current_function.frame_size, len(ctx.locals))

		emit_opcode(ctx, .Set_Local)
		emit_byte(ctx, u8(slot_index))

	case ^Return_Stmt:
		if stmt.value != nil {
			compile_expr(ctx, stmt.value)
		}
		emit_opcode(ctx, .Return)

	case ^Expr_Stmt:
		compile_expr(ctx, stmt.expr)
		if expr_type, ok := ctx.tc.node_types[stmt.expr]; !ok || expr_type != TY_VOID {
			emit_opcode(ctx, .Pop)
		}

	case ^Continue_Stmt:
		if len(ctx.loops) == 0 {
			fmt.panicf("Compiler Error: 'продолжить' вне цикла")
		}
		loop := ctx.loops[len(ctx.loops) - 1]
		continue_jump := emit_jump(ctx, .Jump)
		patch_signed_jump_to(ctx, continue_jump, loop.continue_target)

	case ^Break_Stmt:
		if len(ctx.loops) == 0 {
			fmt.panicf("Compiler Error: 'прервать' вне цикла")
		}
		break_jump := emit_jump(ctx, .Jump)
		append(&ctx.loops[len(ctx.loops) - 1].break_jumps, break_jump)

	case ^Error_Stmt:
		// Компилятор запускается только после typecheck_program с нулём
		// diagnostics (main.odin) — Error_Stmt сюда дойти не должен.
		fmt.panicf("Compiler Error: внутренняя ошибка — Error_Stmt дошёл до компиляции")
	}
}

// Эмитит приведение структуры к интерфейсу, если тайпчекер его пометил
// (ctx.tc.interface_casts, см. check_expr в type_cheker.odin). Должен
// вызываться перед КАЖДЫМ ранним return в case ^Call_Expr: (они выходят из
// compile_expr целиком, минуя общую развязку внизу), плюс один раз в самой
// развязке для всех прочих видов expr.
maybe_emit_interface_cast :: proc(ctx: ^Compiler, expr: Expr) {
	if struct_type, needs_cast := ctx.tc.interface_casts[expr]; needs_cast {
		emit_opcode(ctx, .Cast_Interface)
		emit_byte(ctx, make_constant(ctx, Value(perm_string(struct_type.name))))
	}
}

compile_expr :: proc(ctx: ^Compiler, expr: Expr) {

	switch e in expr {
	case ^Number_Expr:
		emit_constant(ctx, e.value)
	case ^Boolean_Expr:
		emit_constant(ctx, e.value)
	case ^Unary_Expr:
		compile_expr(ctx, e.right)
		#partial switch e.op {
		case .Minus:
			emit_constant(ctx, -1.0)
			emit_opcode(ctx, .Multiply)
		case .Negate:
			emit_opcode(ctx, .Negate)
		}

	case ^String_Expr:
		emit_constant(ctx, Value(perm_string(e.value)))
	case ^Lambda_Expr:
		fn := new(Compiled_Function)
		module_prefix := ""
		if ctx.res.current_module != nil do module_prefix = ctx.res.current_module.path
		if len(module_prefix) > 0 {
			fn.name = fmt.tprintf("%s::lambda_%d", module_prefix, len(ctx.registry^))
		} else {
			fn.name = fmt.tprintf("lambda_%d", len(ctx.registry^))
		}
		lambda_type := ctx.tc.node_types[expr]
		fn.returns_value = prune_type(lambda_type.return_type) != TY_VOID
		fn.instructions = make([dynamic]u8); fn.constants = make([dynamic]Value)
		ctx.registry^[fn.name] = fn

		l_ctx := Compiler {
			registry         = ctx.registry,
			current_function = fn,
			tc               = ctx.tc,
			res              = ctx.res,
			locals           = make([dynamic]Local),
		}
		if args_syms, ok := ctx.res.lambda_args[expr]; ok {
			for sym in args_syms do append(&l_ctx.locals, Local{symbol = sym, depth = 0})
		}
		l_ctx.current_function.frame_size = len(l_ctx.locals)
		compile_block(&l_ctx, e.body, true)
		emit_opcode(&l_ctx, .Return)

		emit_constant(ctx, Value(fn))
	case ^Ident_Expr:
		sym_id := ctx.res.node_symbols[expr]
		sym := symbol_at(ctx.res.symbol_store, sym_id)
		if sym.kind == .Module {
			fmt.panicf(
				"Compiler Error: модуль '%s' нельзя использовать как значение",
				resolve_interned(sym.name),
			)
		}
		if info, ok := ctx.tc.call_infos[expr]; ok && info.kind == .Constructor_Variant {
			name_const := make_constant(ctx, Value(perm_string(info.variant.owner_type.name)))
			emit_opcode(ctx, .Build_Variant)
			emit_byte(ctx, name_const)
			emit_byte(ctx, u8(info.variant.tag_index))
			emit_byte(ctx, 0)
			return
		}
		if sym.kind == .Builtin {
			fmt.panicf(
				"Compiler Error: встроенный конструктор '%s' нужно вызвать через ()",
				resolve_interned(sym.name),
			)
		}

		slot_index := -1
		#reverse for loc, i in ctx.locals {
			if loc.symbol == sym_id {
				slot_index = i
				break
			}
		}

		if slot_index != -1 {
			emit_opcode(ctx, .Get_Local)
			emit_byte(ctx, u8(slot_index))
		} else {
			// Не локальная — ищем в глобальном реестре функций, кладём как константу.
			if fn_ptr, ok := ctx.registry^[symbol_registry_key(ctx.res.symbol_store, sym_id)]; ok {
				emit_constant(ctx, Value(fn_ptr))
			} else {
				fmt.panicf("Compiler Error: символ '%s' не найден", resolve_interned(sym.name))
			}
		}

	case ^Binary_Expr:
		if e.op == .Assign {
			if ident, ok := e.left.(^Ident_Expr); ok {
				compile_expr(ctx, e.right)
				sym_id := ctx.res.node_symbols[ident]
				slot := -1
				#reverse for loc, i in ctx.locals {
					if loc.symbol == sym_id { slot = i; break }
				}
				if slot != -1 {
					emit_opcode(ctx, .Set_Local)
					emit_byte(ctx, u8(slot))
				}
			} else if prop, ok_2 := e.left.(^Property_Expr); ok_2 {
				compile_expr(ctx, prop.object)
				compile_expr(ctx, e.right)
				idx := ctx.tc.property_indices[prop]
				emit_opcode(ctx, .Set_Property); emit_byte(ctx, u8(idx))
			} else if index_expr, ok_3 := e.left.(^Index_Expr); ok_3 {
				compile_expr(ctx, index_expr.object)
				compile_expr(ctx, index_expr.index)
				compile_expr(ctx, e.right)
				emit_opcode(ctx, .Set_Index)
			}
		} else if info, has_sugar := ctx.tc.call_infos[expr]; has_sugar && info.kind == .Method_Struct {
			// Стадия 22: Сравниваемое/Равнозначное sugar — реюз того же
			// .Method_Struct-кодогена, что Call_Expr (см. case .Method_Struct
			// выше в этом файле): push fn-константа, компиляция receiver'а
			// (e.left) и единственного арга (e.right), .Call 2. Порядок push
			// другой, чем у native-пути ниже (fn ПЕРЕД операндами, не сами
			// операнды) — этот путь сам решает, что на стеке и в каком
			// порядке, поэтому предкомпиляция e.left/e.right выше не подходит.
			// maybe_emit_interface_cast не нужен — результат всегда примитив
			// (Число из сравнить/Булево из равно), никогда не апкастится.
			fn_ptr, found := ctx.registry^[symbol_registry_key(ctx.res.symbol_store, info.symbol_ref)]
			if !found {
				fmt.panicf("Compiler Error: метод не найден")
			}
			emit_constant(ctx, Value(fn_ptr))
			compile_expr(ctx, e.left)
			compile_expr(ctx, e.right)
			emit_opcode(ctx, .Call)
			emit_byte(ctx, 2)

			#partial switch e.op {
			case .Less:
				emit_constant(ctx, Value(0.0))
				emit_opcode(ctx, .Less)
			case .Greater:
				emit_constant(ctx, Value(0.0))
				emit_opcode(ctx, .Greater)
			case .LessEqual:
				emit_constant(ctx, Value(0.0))
				emit_opcode(ctx, .Greater)
				emit_opcode(ctx, .Negate)
			case .GreaterEqual:
				emit_constant(ctx, Value(0.0))
				emit_opcode(ctx, .Less)
				emit_opcode(ctx, .Negate)
			case .NotEqual:
				emit_opcode(ctx, .Negate)
			case .Equal:
			// равно() уже возвращает Булево — результат вызова и есть ответ.
			}
		} else {
			// .And/.Or ниже сами компилируют e.left/e.right (с прыжками для
			// short-circuit). Предкомпиляция здесь удвоила бы каждый операнд, а
			// для цепочки `и`/`или` (левоассоциативной — e.left сам Binary_Expr)
			// рекурсивно: O(2^n) инструкций плюс мусор на стеке VM.
			if e.op != .And && e.op != .Or {
				compile_expr(ctx, e.left); compile_expr(ctx, e.right)
			}
			#partial switch e.op {
			case .Plus:
				emit_opcode(ctx, .Add)
			case .Minus:
				emit_opcode(ctx, .Subtract)
			case .Star:
				emit_opcode(ctx, .Multiply)
			case .Slash:
				emit_opcode(ctx, .Divide)
			case .Less:
				emit_opcode(ctx, .Less)
			case .Greater:
				emit_opcode(ctx, .Greater)
			case .LessEqual:
				// a <= b == не (a > b) — тот же приём, что NotEqual ниже
				// (Equal+Negate): не заводим отдельный VM-опкод под ещё
				// одно сравнение, компонуем из уже существующих.
				emit_opcode(ctx, .Greater)
				emit_opcode(ctx, .Negate)
			case .GreaterEqual:
				emit_opcode(ctx, .Less)
				emit_opcode(ctx, .Negate)
			case .Equal:
				emit_opcode(ctx, .Equal)
			case .NotEqual:
				emit_opcode(ctx, .Equal)
				emit_opcode(ctx, .Negate)
			case .Negate:
				emit_opcode(ctx, .Negate)
			case .And:
				compile_expr(ctx, e.left)

				false_jump := emit_jump(ctx, .Jump_If_False)

				compile_expr(ctx, e.right)
				end_jump := emit_jump(ctx, .Jump)

				patch_jump(ctx, false_jump)
				emit_constant(ctx, Value(false))
				patch_jump(ctx, end_jump)

			case .Or:
				compile_expr(ctx, e.left)

				jump_eval_right := emit_jump(ctx, .Jump_If_False)

				emit_constant(ctx, Value(true))

				jump_end := emit_jump(ctx, .Jump)

				patch_jump(ctx, jump_eval_right)
				compile_expr(ctx, e.right)

				patch_jump(ctx, jump_end)
			}
		}

	case ^Property_Expr:
		if info, ok := ctx.tc.call_infos[expr]; ok && info.kind == .Constructor_Variant {
			name_const := make_constant(ctx, Value(perm_string(info.variant.owner_type.name)))
			emit_opcode(ctx, .Build_Variant)
			emit_byte(ctx, name_const)
			emit_byte(ctx, u8(info.variant.tag_index))
			emit_byte(ctx, 0)
			return
		}
		if sym_id, ok := ctx.res.node_symbols[expr]; ok {
			sym := symbol_at(ctx.res.symbol_store, sym_id)
			if sym.kind == .Enum_Variant {
				owner_name := sym.owner_type == INVALID_SYMBOL ? "" : resolve_interned(symbol_at(ctx.res.symbol_store, sym.owner_type).name)
				fmt.panicf(
					"Compiler Error: вариант '%s.%s' используется как значение — вызовите со скобками",
					owner_name,
					resolve_interned(sym.name),
				)
			}
			if fn_ptr, found := ctx.registry^[symbol_registry_key(ctx.res.symbol_store, sym_id)]; found {
				emit_constant(ctx, Value(fn_ptr))
				return
			}
			fmt.panicf(
				"Compiler Error: символ '%s' нельзя использовать как значение",
				resolve_interned(sym.full_name),
			)
		}
		if obj_ident, ok := e.object.(^Ident_Expr); ok {
			if obj_sym_id := ctx.res.node_symbols[e.object];
			   obj_sym_id != INVALID_SYMBOL && symbol_at(ctx.res.symbol_store, obj_sym_id).kind == .Module {
				imported_module := symbol_at(ctx.res.symbol_store, obj_sym_id).module
				if imported_module == nil {
					fmt.panicf(
						"Compiler Error: модуль '%s' не загружен",
						resolve_interned(obj_ident.name),
					)
				}
				if export_sym, found := imported_module.exports[intern(e.property)]; found {
					if fn_ptr, found_fn := ctx.registry^[symbol_registry_key(ctx.res.symbol_store, export_sym)];
					   found_fn {
						emit_constant(ctx, Value(fn_ptr))
						return
					}
					fmt.panicf(
						"Compiler Error: экспорт '%s.%s' нельзя использовать как значение",
						resolve_interned(obj_ident.name),
						e.property,
					)
				}
				fmt.panicf(
					"Compiler Error: модуль '%s' не экспортирует '%s'",
					resolve_interned(obj_ident.name),
					e.property,
				)
			}
		}
		compile_expr(ctx, e.object) // На стеке окажется структура

		idx := ctx.tc.property_indices[expr] // Берем индекс поля от Тайп-чекера

		emit_opcode(ctx, .Get_Property)
		emit_byte(ctx, u8(idx))
	case ^Index_Expr:
		compile_expr(ctx, e.object)
		compile_expr(ctx, e.index)
		emit_opcode(ctx, .Get_Index)
	case ^Try_Expr:
		compile_expr(ctx, e.value)
		emit_opcode(ctx, .Try_Unwrap)
	case ^Call_Expr:
		if info, ok := ctx.tc.call_infos[expr]; ok {
			switch info.kind {
			case .Constructor_Variant:
				for arg in e.args do compile_expr(ctx, arg)
				name_const := make_constant(ctx, Value(perm_string(info.variant.owner_type.name)))
				emit_opcode(ctx, .Build_Variant)
				emit_byte(ctx, name_const)
				emit_byte(ctx, u8(info.variant.tag_index))
				emit_byte(ctx, u8(len(e.args)))
				maybe_emit_interface_cast(ctx, expr)
				return

			case .Builtin:
				for arg in e.args do compile_expr(ctx, arg)
				emit_opcode(ctx, .Call_Builtin)
				emit_byte(ctx, make_constant(ctx, Value(perm_string(info.text_name))))
				emit_byte(ctx, u8(len(e.args)))
				maybe_emit_interface_cast(ctx, expr)
				return

			case .Method_Collection:
				prop_expr := e.callee.(^Property_Expr)
				compile_expr(ctx, prop_expr.object)
				for arg in e.args do compile_expr(ctx, arg)
				emit_opcode(ctx, .Invoke_Collection)
				emit_byte(ctx, make_constant(ctx, Value(perm_string(info.text_name))))
				emit_byte(ctx, u8(len(e.args)))
				maybe_emit_interface_cast(ctx, expr)
				return

			case .Method_Interface:
				prop_expr := e.callee.(^Property_Expr)
				compile_expr(ctx, prop_expr.object)
				for arg in e.args do compile_expr(ctx, arg)
				emit_opcode(ctx, .Invoke_Interface)
				emit_byte(ctx, make_constant(ctx, Value(perm_string(info.text_name))))
				emit_byte(ctx, u8(len(e.args)))
				maybe_emit_interface_cast(ctx, expr)
				return

			case .Method_Struct:
				if fn_ptr, found := ctx.registry^[symbol_registry_key(ctx.res.symbol_store, info.symbol_ref)]; found {
					emit_constant(ctx, Value(fn_ptr))
				} else {
					fmt.panicf("Compiler Error: метод не найден")
				}
				prop_expr := e.callee.(^Property_Expr)
				compile_expr(ctx, prop_expr.object)
				for arg in e.args do compile_expr(ctx, arg)
				emit_opcode(ctx, .Call)
				emit_byte(ctx, u8(len(e.args) + 1))
				maybe_emit_interface_cast(ctx, expr)
				return

			case .Constructor_Struct:
				for arg in e.args do compile_expr(ctx, arg)
				emit_opcode(ctx, .Build_Aggregate)
				emit_byte(ctx, u8(len(e.args)))
				maybe_emit_interface_cast(ctx, expr)
				return
			}
		}
		if ident, ok := e.callee.(^Ident_Expr); ok {
			if sym_id := ctx.res.node_symbols[e.callee];
			   sym_id != INVALID_SYMBOL && symbol_at(ctx.res.symbol_store, sym_id).kind == .Builtin {
				for arg in e.args do compile_expr(ctx, arg)
				emit_opcode(ctx, .Call_Builtin)
				emit_byte(ctx, make_constant(ctx, Value(perm_string(resolve_interned(ident.name)))))
				emit_byte(ctx, u8(len(e.args)))
				maybe_emit_interface_cast(ctx, expr)
				return
			}
		}
		compile_expr(ctx, e.callee)
		for arg in e.args do compile_expr(ctx, arg)
		emit_opcode(ctx, .Call)
		emit_byte(ctx, u8(len(e.args)))

	case ^Match_Expr:
		compile_match_expr(ctx, e)

	case ^If_Expr:
		compile_expr(ctx, e.condition)
		else_jump := emit_jump(ctx, .Jump_If_False)
		is_val := ctx.tc.node_types[expr] != TY_VOID
		compile_block(ctx, e.then_branch, is_val)
		end_jump := emit_jump(ctx, .Jump)
		patch_jump(ctx, else_jump)
		if len(e.else_branch) > 0 do compile_block(ctx, e.else_branch, is_val)
		else if is_val do emit_constant(ctx, f64(0))
		patch_jump(ctx, end_jump)

	case ^While_Expr:
		loop_start := len(ctx.current_function.instructions)
		loop_ctx := Loop_Context {
			continue_target = loop_start,
			break_jumps     = make([dynamic]int),
		}
		append(&ctx.loops, loop_ctx)

		compile_expr(ctx, e.condition)
		exit_jump := emit_jump(ctx, .Jump_If_False)

		for stmt in e.body {
			compile_statement(ctx, stmt)
		}

		// Обратный (знаковый) прыжок в начало — .Jump эмулирует Jump_Back.
		loop_jump := emit_jump(ctx, .Jump)
		patch_signed_jump_to(ctx, loop_jump, loop_start)

		patch_jump(ctx, exit_jump)
		finished_loop := ctx.loops[len(ctx.loops) - 1]
		for break_jump in finished_loop.break_jumps {
			patch_jump(ctx, break_jump)
		}
		pop(&ctx.loops)
	case ^Tuple_Expr:
		for el in e.elements {
			compile_expr(ctx, el)
		}

		emit_opcode(ctx, .Build_Aggregate)

		if len(e.elements) > 255 {
			fmt.panicf(
				"Compiler Error: тупл не может содержать больше 255 элементов",
			)
		}
		emit_byte(ctx, u8(len(e.elements)))
	case ^Array_Expr:
		for el in e.elements {
			compile_expr(ctx, el)
		}
		if len(e.elements) > 255 {
			fmt.panicf(
				"Compiler Error: массив не может содержать больше 255 элементов",
			)
		}
		emit_opcode(ctx, .Build_Array)
		emit_byte(ctx, u8(len(e.elements)))
	case ^Map_Expr:
		for entry in e.entries {
			compile_expr(ctx, entry.key)
			compile_expr(ctx, entry.value)
		}
		if len(e.entries) > 255 {
			fmt.panicf(
				"Compiler Error: соответствие не может содержать больше 255 элементов",
			)
		}
		emit_opcode(ctx, .Build_Map)
		emit_byte(ctx, u8(len(e.entries)))

	case ^Error_Expr:
		// Компилятор запускается только после typecheck_program с нулём
		// diagnostics (main.odin) — Error_Expr сюда дойти не должен.
		fmt.panicf("Compiler Error: внутренняя ошибка — Error_Expr дошёл до компиляции")
	}

	maybe_emit_interface_cast(ctx, expr)
}

allocate_temp_slot :: proc(ctx: ^Compiler, name: string) -> int {
	sym := new_symbol(ctx.res.symbol_store, name, .Variable, nil)
	append(&ctx.locals, Local{symbol = sym, depth = ctx.scope_depth})
	slot := len(ctx.locals) - 1
	ctx.current_function.frame_size = max(ctx.current_function.frame_size, len(ctx.locals))
	return slot
}

register_binder_slot :: proc(ctx: ^Compiler, sym: Symbol_Id) -> int {
	append(&ctx.locals, Local{symbol = sym, depth = ctx.scope_depth})
	slot := len(ctx.locals) - 1
	ctx.current_function.frame_size = max(ctx.current_function.frame_size, len(ctx.locals))
	return slot
}

compile_pattern :: proc(
	ctx: ^Compiler,
	pi: ^Pattern_Info,
	value_slot: int,
	fail_jumps: ^[dynamic]int,
) {
	switch pi.kind {
	case .Wildcard:
	// без условия — совпадает всегда
	case .Binder:
		binder_slot := register_binder_slot(ctx, pi.binder_sym)
		emit_opcode(ctx, .Get_Local)
		emit_byte(ctx, u8(value_slot))
		emit_opcode(ctx, .Set_Local)
		emit_byte(ctx, u8(binder_slot))
	case .Constructor:
		tag_const := make_constant(ctx, Value(f64(pi.tag_index)))
		emit_opcode(ctx, .Get_Local)
		emit_byte(ctx, u8(value_slot))
		emit_opcode(ctx, .Match_Tag)
		emit_byte(ctx, tag_const)
		append(fail_jumps, emit_jump(ctx, .Jump_If_False))
		for &sub, field_idx in pi.sub_patterns {
			if sub.kind == .Wildcard do continue
			// Извлекаем поле в temp slot, потом рекурсивно сравниваем.
			field_slot := allocate_temp_slot(ctx, "__match_field")
			emit_opcode(ctx, .Get_Local)
			emit_byte(ctx, u8(value_slot))
			emit_opcode(ctx, .Get_Variant_Field)
			emit_byte(ctx, u8(field_idx))
			emit_opcode(ctx, .Set_Local)
			emit_byte(ctx, u8(field_slot))
			compile_pattern(ctx, &sub, field_slot, fail_jumps)
		}
	}
}

compile_match_expr :: proc(ctx: ^Compiler, m: ^Match_Expr) {
	arm_infos, has_infos := ctx.tc.match_arm_infos[m]
	if !has_infos {
		fmt.panicf("Compiler Error: match_arm_infos отсутствует для выбора")
	}
	is_val := ctx.tc.node_types[m] != TY_VOID
	compile_expr(ctx, m.subject)
	subject_slot := allocate_temp_slot(ctx, "__match_subject")
	emit_opcode(ctx, .Set_Local)
	emit_byte(ctx, u8(subject_slot))

	end_jumps := make([dynamic]int, context.temp_allocator)

	for arm, arm_idx in m.arms {
		pi := arm_infos[arm_idx]
		fail_jumps := make([dynamic]int, context.temp_allocator)
		compile_pattern(ctx, &pi, subject_slot, &fail_jumps)

		compile_block(ctx, arm.body, is_val)
		append(&end_jumps, emit_jump(ctx, .Jump))

		for fj in fail_jumps do patch_jump(ctx, fj)
	}

	emit_opcode(ctx, .Get_Local)
	emit_byte(ctx, u8(subject_slot))
	emit_opcode(ctx, .Match_Fail)

	for j in end_jumps do patch_jump(ctx, j)
}

compile_block :: proc(ctx: ^Compiler, body: [dynamic]Stmt, is_expr: bool) {
	if len(body) == 0 { if is_expr do emit_constant(ctx, f64(0)); return }
	for i in 0 ..< len(body) {
		stmt := body[i]
		is_last := i == len(body) - 1
		if is_last && is_expr {
			if expr_stmt, ok := stmt.(^Expr_Stmt); ok {
				compile_expr(ctx, expr_stmt.expr)
			} else {
				compile_statement(ctx, stmt)
				emit_constant(ctx, f64(0))
			}
		} else {
			compile_statement(ctx, stmt)
		}
	}
}

print_assebler :: proc(registry: map[string]^Compiled_Function) {

	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	prefix := "\t"

	for name, f in registry {

		function_name := fmt.tprintf("FUNCTION %s\n", name)
		strings.write_string(&builder, function_name)

		instructions := f.instructions
		for idx := 0; idx < len(instructions); idx += 1 {
			current_opcode := Opcode(instructions[idx])
			#partial switch current_opcode {
			case .Set_Property:
				idx += 1
				command := fmt.tprintf("%sSET_PROPERTY: %d\n", prefix, instructions[idx])
				strings.write_string(&builder, command)

			case .Greater:
				command := fmt.tprintf("%sGREATER\n", prefix)
				strings.write_string(&builder, command)

			case .Less:
				command := fmt.tprintf("%sLESS\n", prefix)
				strings.write_string(&builder, command)

			case .Equal:
				command := fmt.tprintf("%sEQUAL\n", prefix)
				strings.write_string(&builder, command)

			case .Negate:
				command := fmt.tprintf("%sNEGATE\n", prefix)
				strings.write_string(&builder, command)

			case .Constant:
				idx += 1
				command := fmt.tprintf("%sCONSTANT: %d\n", prefix, instructions[idx])
				strings.write_string(&builder, command)

			case .Add:
				command := fmt.tprintf("%sADD\n", prefix)
				strings.write_string(&builder, command)

			case .Subtract:
				command := fmt.tprintf("%sSUBSTACT\n", prefix)
				strings.write_string(&builder, command)

			case .Multiply:
				command := fmt.tprintf("%sMULTIPLY\n", prefix)
				strings.write_string(&builder, command)

			case .Divide:
				command := fmt.tprintf("%sCONSTANT\n", prefix)
				strings.write_string(&builder, command)

			case .Get_Local:
				idx += 1
				command := fmt.tprintf("%sGET_LOCAL: %d\n", prefix, instructions[idx])
				strings.write_string(&builder, command)

			case .Set_Local:
				idx += 1
				command := fmt.tprintf("%sSET_LOCAL: %d\n", prefix, instructions[idx])
				strings.write_string(&builder, command)

			case .Jump_If_False:
				idx += 2
				command := fmt.tprintf("%sJUMP_IF_FALSE\n", prefix)
				strings.write_string(&builder, command)

			case .Jump:
				idx += 2
				command := fmt.tprintf("%sJUMP\n", prefix)
				strings.write_string(&builder, command)

			case .Pop:
				command := fmt.tprintf("%sPOP\n", prefix)
				strings.write_string(&builder, command)

			case .Return:
				command := fmt.tprintf("%sRETURN\n", prefix)
				strings.write_string(&builder, command)

			case .Call:
				idx += 1
				command := fmt.tprintf("%sCALL\n", prefix)
				strings.write_string(&builder, command)
			case .Build_Aggregate:
				idx += 1
				command := fmt.tprintf("%sBUILD_AGGREGATE\n", prefix)
				strings.write_string(&builder, command)
			case .Get_Property:
				idx += 1
				command := fmt.tprintf("%sGET_PROPERTY\n", prefix)
				strings.write_string(&builder, command)
			case .Cast_Interface:
				idx += 1
				command := fmt.tprintf("%sCAST_INTERFACE\n", prefix)
				strings.write_string(&builder, command)

			case .Invoke_Interface:
				idx += 2
				command := fmt.tprintf("%sINVOKE_INTERFACE\n", prefix)
				strings.write_string(&builder, command)

			case .Build_Array:
				idx += 1
				command := fmt.tprintf("%sBUILD_ARRAY\n", prefix)
				strings.write_string(&builder, command)

			case .Build_Map:
				idx += 1
				command := fmt.tprintf("%sBUILD_MAP\n", prefix)
				strings.write_string(&builder, command)

			case .Get_Index:
				command := fmt.tprintf("%sGET_INDEX\n", prefix)
				strings.write_string(&builder, command)

			case .Set_Index:
				command := fmt.tprintf("%sSET_INDEX\n", prefix)
				strings.write_string(&builder, command)

			case .Invoke_Collection:
				idx += 2
				command := fmt.tprintf("%sINVOKE_COLLECTION\n", prefix)
				strings.write_string(&builder, command)

			case .Call_Builtin:
				idx += 2
				command := fmt.tprintf("%sCALL_BUILTIN\n", prefix)
				strings.write_string(&builder, command)

			case .Try_Unwrap:
				command := fmt.tprintf("%sTRY_UNWRAP\n", prefix)
				strings.write_string(&builder, command)

			}
		}
	}
	res := strings.to_string(builder)

	fmt.println(res)

}
