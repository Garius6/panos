package core

import "core:fmt"
import "core:strconv"

Parser :: struct {
	stream:      ^TokenStream,
	file_id:     u16,
	// Diagnostic/Severity определены в type_cheker.odin (тот же package),
	// модель accumulate-not-panic общая (TY_POISON).
	diagnostics: [dynamic]Diagnostic,
	// Монотонный счётчик для gensym-имён синтетических переменных
	// для-in-раскрытия (см. parse_for_stmt_into): __for_1_idx, __for_2_idx, ...
	// Уникальности в пределах файла достаточно (разные функции не делят scope).
	for_counter: int,
}

// Аналог report() из type_cheker.odin: копит diagnostic вместо panic,
// дедуп по (span, message).
report_parse :: proc(p: ^Parser, span: Span, format: string, args: ..any) {
	msg := fmt.aprintf(format, ..args)
	for d in p.diagnostics {
		if d.span == span && d.message == msg do return
	}
	append(&p.diagnostics, Diagnostic{severity = .Error, span = span, message = msg})
}

// Токены, с которых безопасно возобновить разбор после неразрешимой ошибки:
// начало новой top-level декларации или конец файла. skip_to_sync НЕ
// продвигает поток, стоя на sync-токене — поэтому вызывающий обязан сам
// потребить хотя бы один токен перед skip (иначе цикл зависает на месте).
// См. места вызова.
is_sync_token :: proc(kind: TokenKind) -> bool {
	#partial switch kind {
	case .Function, .TypeDecl, .Impl, .Import, .Export, .End, .EOF:
		return true
	}
	return false
}

skip_to_sync :: proc(p: ^Parser) {
	for {
		tok := peek_token(p.stream)
		if tok == nil || is_sync_token(tok.kind) do return
		next_token(p.stream)
	}
}

Parser_Error :: enum {
	Cannot,
}

Function_Decl :: struct {
	span:        Span,
	name:        string,
	// Имена type-параметров из `[T, U]` после имени функции. Пусто для
	// обычных (не-generic) функций.
	type_params: [dynamic]string,
	// Bounded traits: `[T: Сравниваемое + Печатаемое]` — имя type-параметра
	// -> список имён интерфейсов-ограничений (пусто/нет ключа = без
	// bound'а). ТОЛЬКО у функций — Struct_Decl/Interface_Decl.type_params
	// это поле не имеют (см. ROADMAP — scope сознательно ограничен
	// функциями). Заполняется в parse_function_type_params.
	type_param_bounds: map[string][dynamic]string,
	args:        [dynamic]Param_Decl,
	return_type: Type_Node,
	body:        [dynamic]Stmt,
	is_exported: bool,
}

Param_Decl :: struct {
	span:            Span,
	name:            string,
	type_annotation: Type_Node,
}

Method_Signature :: struct {
	span:        Span,
	name:        string,
	args:        [dynamic]Param_Decl,
	return_type: Type_Node,
}

Interface_Decl :: struct {
	span:        Span,
	name:        string,
	// Стадия 28: имена type-параметров из `[T]` после имени интерфейса
	// (та же форма, что Struct_Decl.type_params). Пусто для обычных
	// (не-generic) интерфейсов.
	type_params: [dynamic]string,
	methods:     [dynamic]Method_Signature,
	is_exported: bool,
}

Field_Decl :: struct {
	span:            Span,
	name:            string,
	type_annotation: Type_Node,
	// Стадия 51: заполнено ТОЛЬКО когда владеющий Struct_Decl.is_ffi ==
	// true (ff_структура) — type_annotation в этом случае не парсится
	// (см. parse_ffi_struct_decl), панос-тип поля вычисляется из
	// marshal_kind на typecheck (Целое/Число, см. foreign_marshal_
	// panos_type в type_cheker.odin).
	marshal_kind:    Foreign_Marshal_Kind,
}

Struct_Decl :: struct {
	span:        Span,
	name:        string,
	// Имена type-параметров из `[A, B]` после имени структуры. Пусто для
	// обычных (не-generic) структур.
	type_params: [dynamic]string,
	fields:      [dynamic]Field_Decl,
	is_exported: bool,
	// Стадия 51: true для `тип X = ff_структура ... конец` — C ABI
	// struct-by-value для `внешний` (Vector2/Color-style). Поля обязаны
	// быть Целое(8|32|64)/Число(32|64) (см. field.marshal_kind) —
	// вложенные структуры/строки/указатели не поддержаны в этом срезе
	// (плоский layout). generics НЕ поддержаны для ff_структура (raylib
	// не нуждается, упрощает marshalling).
	is_ffi:      bool,
}

Import_Decl :: struct {
	span:  Span,
	path:  string,
	alias: string,
}

Variant_Decl :: struct {
	span:  Span,
	name:  string,
	types: [dynamic]Type_Node,
}

Enum_Decl :: struct {
	span:        Span,
	name:        string,
	// Имена type-параметров из `[T]` после имени enum'а. Пусто для обычных
	// (не-generic) перечислений.
	type_params: [dynamic]string,
	variants:    [dynamic]Variant_Decl,
	is_exported: bool,
}

Impl_Decl :: struct {
	span:              Span,
	// Стадия 40: непусто = "реализация Модуль.Интерфейс для Тип" —
	// cross-module интерфейс. Пусто = старая форма (локальный интерфейс
	// либо простой impl без интерфейса вовсе).
	interface_module:  string,
	interface_name:    string,
	target_type:       string,
	methods:           [dynamic]^Function_Decl,
}

// Placeholder-узел ("hole"): парсер не смог разобрать конструкцию на этом
// месте (например top-level мусор), но должен продолжить разбор остального
// файла вместо panic. Несёт только span для diagnostic'а; резолвер/тайпчекер
// трактуют его как уже отрапортованную ошибку (см. TY_POISON) и не
// каскадируют вторичные диагностики.
Error_Decl :: struct {
	span: Span,
}

// Стадия 47 (FFI-B, первый срез): `внешний "libc" функ getpid() -> Целое(32)`.
// Стадия 49 расширила поддержанные формы типа до `КСтрока`/`Указатель(T)`
// (см. parse_foreign_marshal_type) — синтаксис ПО-ПРЕЖНЕМУ валиден
// ТОЛЬКО здесь (не общий `parse_type`, кроме T внутри `Указатель(T)` —
// та часть уже обычный `parse_type`), поэтому Foreign_Param остаётся
// своим узким типом, не Type_Node напрямую. `marshal` — чисто
// marshalling-метаданные для libffi (какой `ffi_type_*` использовать),
// НЕ панос-тип: панос-типом параметра/возврата остаётся обычный
// Целое/Строка/Указатель(T) — не новый способ типизации, просто выбор
// СУЩЕСТВУЮЩЕГО типа по marshal (см. type_cheker.odin, case
// ^Foreign_Decl).
Foreign_Marshal_Kind :: enum {
	// Стадия 51: ТОЛЬКО как возврат ("Пусто") — libc/raylib функции без
	// результата (SetTargetFPS, BeginDrawing и т.п.). Как тип параметра
	// не встречается синтаксически (нет смысла передавать "ничего").
	Void,
	Int8,
	Int32,
	Int64,
	// Стадия 51: float/double — raylib почти везде float. Панос-тип
	// параметра/возврата — обычный Число (как Целое(N) остаётся Целое),
	// ширина чисто marshalling-метаданные, см. докstring выше.
	Float32,
	Float64,
	CString,
	Pointer,
	// Стадия 51: C-структура по значению (ff_структура) — raylib's
	// Vector2/Color передаются В САМИХ функциях отрисовки по значению,
	// не по указателю. struct_type_name (Foreign_Param)/return_struct_
	// type_name (Foreign_Decl) — имя ff_структура-типа, резолвится в
	// resolved_struct_type на typecheck (типы ещё не существуют на
	// этапе парсинга, см. type_cheker.odin, case ^Foreign_Decl).
	Struct,
}

Foreign_Param :: struct {
	span:    Span,
	name:    string,
	marshal: Foreign_Marshal_Kind,
	// Заполнено ТОЛЬКО когда marshal == .Pointer — T внутри
	// Указатель(T), обычный parse_type-путь (T сам может быть чем
	// угодно, panos никогда не заглядывает внутрь — см. Type_Kind.Pointer).
	pointee: Type_Node,
	// Стадия 51: заполнено ТОЛЬКО когда marshal == .Struct — имя ff_
	// структура-типа (напр. "Vector2"), резолвится в resolved_struct_
	// type на typecheck.
	struct_type_name: string,
	resolved_struct_type: ^Type,
}

Foreign_Decl :: struct {
	span:          Span,
	library:       string, // "libc" — без платформенного расширения/пути, резолвер добавляет
	name:          string, // "getpid"
	params:        [dynamic]Foreign_Param,
	return_marshal: Foreign_Marshal_Kind,
	return_pointee: Type_Node, // как Foreign_Param.pointee, только для возврата
	// Стадия 51: как Foreign_Param.struct_type_name/resolved_struct_type,
	// только для возврата.
	return_struct_type_name: string,
	return_resolved_struct_type: ^Type,
	// Стадия 49: постфикс владения ПОСЛЕ возвращаемого Указатель(T) —
	// `свой` (panos аллоцирует/освобождает через pool_release, libc
	// free()) vs `чужой` (default — НИКОГДА не освобождать чужую
	// память). Смысл только когда return_marshal == .Pointer.
	return_owned:  bool,
	// Заполняется резолвером (dynlib.load_library + symbol_address) —
	// компилятор читает напрямую отсюда при генерации Call_Foreign,
	// отдельная Symbol_Id-карта не нужна: и адрес, и marshal-инфо уже
	// здесь.
	fn_ptr:        rawptr,
	// Заполняется компилятором (core/compiler.odin) при первой компиляции
	// вызова этой декларации — ^Foreign_Function, переиспользуется всеми
	// последующими call-сайтами этой же decl (ffi_prep_cif внутри готовится
	// ещё позже, лениво, при первом РЕАЛЬНОМ вызове в VM).
	compiled_fn:   rawptr,
}

Decls :: union {
	^Import_Decl,
	^Function_Decl,
	^Struct_Decl,
	^Impl_Decl,
	^Interface_Decl,
	^Enum_Decl,
	^Error_Decl,
	^Foreign_Decl,
}

Program :: struct {
	decls: [dynamic]Decls,
}

Type_Generic :: struct {
	span:   Span,
	name:   string,
	params: [dynamic]Type_Node,
}

Type_Qualified :: struct {
	span:        Span,
	module_name: string,
	name:        string,
}

Error_Type_Node :: struct {
	span: Span,
}

Type_Node :: union {
	^Type_Ident,
	^Type_Tuple,
	^Type_Function,
	^Type_Qualified,
	^Type_Generic, // Заменяет Type_Array и Type_Map
	^Error_Type_Node,
}

Type_Function :: struct {
	span:        Span,
	params:      [dynamic]Type_Node,
	return_type: Type_Node,
}

Type_Ident :: struct {
	span: Span,
	name: string,
}

Type_Tuple :: struct {
	span:     Span,
	elements: [dynamic]Type_Node,
}

Error_Stmt :: struct {
	span: Span,
}

Stmt :: union {
	^Return_Stmt,
	^Let_Stmt,
	^Expr_Stmt,
	^Continue_Stmt,
	^Break_Stmt,
	^Error_Stmt,
	^For_In_Stmt,
}

// Стадия 23 (Итерируемое): НЕ десахаривается на этапе парсинга (в
// отличие от for-range, `parse_for_range_stmt_into` ниже) — тип
// `iterable` неизвестен парсеру, а выбор формы компиляции (fast-path
// для Массив/Строка vs iterator-protocol для Итерируемое) требует
// типа. Резолвится/типизируется как обычный узел, десахаривание/кодоген
// — в compiler.odin (см. ctx.tc.for_in_infos).
For_In_Stmt :: struct {
	span:     Span,
	names:    [dynamic]string,
	iterable: Expr,
	body:     [dynamic]Stmt,
}

Return_Stmt :: struct {
	span:  Span,
	value: Expr,
}

Let_Stmt :: struct {
	span:            Span,
	name:            string,
	value:           Expr,
	type_annotation: Type_Node,
	is_const:        bool,
	// Деструктуризация: непусто вместо name для `пер (a, b) = ...` (tuple,
	// destructure_type == "") или `пер Тип(a, b) = ...` (структура,
	// destructure_type == "Тип" — поля берутся по ПОРЯДКУ ОБЪЯВЛЕНИЯ, тем
	// же позиционным принципом, что и обычный конструктор `Тип(1, 2)`).
	// Та же форма, что For_In_Stmt.names.
	names:            [dynamic]string,
	destructure_type: string,
	// Именованная форма (`пер Тип(x: a, y: b) = значение`) — ТОЛЬКО у
	// структурной деструктуризации (тупл-форма без имён полей, как enum-
	// варианты в match-шаблонах). Параллельно `names`, пусто целиком =
	// позиционная форма. `имя_поля: имя_переменной` — тот же `:`, что
	// именованные под-шаблоны в `выбор` (Стадия 35), не `=`, как
	// именованные аргументы вызова (Стадия 36) — деструктуризация
	// концептуально ближе к сопоставлению с шаблоном, чем к вызову.
	// Может быть ЧАСТИЧНОЙ (в отличие от вызовов) — неупомянутые поля
	// просто не извлекаются, не связывается никакая локальная переменная.
	destructure_field_names: [dynamic]string,
}

Expr_Stmt :: struct {
	span: Span,
	expr: Expr,
}

Continue_Stmt :: struct {
	span: Span,
}

Break_Stmt :: struct {
	span: Span,
}

Pattern_Wildcard :: struct {
	span: Span,
}
Pattern_Literal :: struct {
	span:  Span,
	value: Expr,
}
Pattern_Ident :: struct {
	span: Span,
	name: string,
}
Pattern_Constructor :: struct {
	span:        Span,
	module_name: string,
	name:        string,
	args:        [dynamic]Pattern,
	// Именованные поля (`Точка(x: 1, y: _)`) — параллельно args, тот же
	// индекс. Пусто целиком, если использована обычная позиционная форма
	// (`Точка(1, _)`) — единственная форма, поддержанная у enum-вариантов
	// (у них нет имён полей, только позиционные типы). Смешивать формы в
	// одном шаблоне нельзя — решается по ПЕРВОМУ аргументу при парсинге.
	field_names: [dynamic]string,
}

Error_Pattern :: struct {
	span: Span,
}

Pattern :: union {
	^Pattern_Wildcard,
	^Pattern_Literal,
	^Pattern_Ident,
	^Pattern_Constructor,
	^Error_Pattern,
}

Match_Arm :: struct {
	span:    Span,
	pattern: Pattern,
	body:    [dynamic]Stmt,
}

Match_Expr :: struct {
	span:    Span,
	subject: Expr,
	arms:    [dynamic]Match_Arm,
}

Ident_Expr :: struct {
	span: Span,
	name: Interned,
}

Unary_Expr :: struct {
	span:  Span,
	op:    TokenKind,
	right: Expr,
}

Number_Expr :: struct {
	span:  Span,
	value: f64,
}

Boolean_Expr :: struct {
	span:  Span,
	value: bool,
}

String_Expr :: struct {
	span:  Span,
	value: string,
}

Binary_Expr :: struct {
	span:  Span,
	left:  Expr,
	op:    TokenKind, // Теперь может быть .Assign (=)
	right: Expr,
}

Call_Expr :: struct {
	span:      Span,
	args:      [dynamic]Expr,
	callee:    Expr,
	// Именованные аргументы (`f(x = 1, y = 2)`) — параллельно args, пусто
	// целиком у позиционной формы (нулевой риск регрессии). `=`, не `:` —
	// та же нотация, что у записей соответствие(ключ = значение), не
	// field-аннотации структур. Смешивать с позиционной формой в одном
	// вызове нельзя, решается по ПЕРВОМУ аргументу при парсинге.
	arg_names: [dynamic]string,
}

// Стадия 24 (actor model): `запусти <вызов>` — оборачивает Call_Expr, не
// заменяет его. Резолвер/типизатор проверяют/резолвят call ТАК ЖЕ, как
// обычный вызов (resolve_expr(ctx, e.call) переиспользует ^Call_Expr-
// ветку целиком) — Spawn_Expr лишь маркирует "не выполнять callee
// синхронно, породить процесс".
Spawn_Expr :: struct {
	span: Span,
	call: ^Call_Expr,
}

Property_Expr :: struct {
	span:     Span,
	object:   Expr,
	property: string,
}

If_Expr :: struct {
	span:        Span,
	condition:   Expr,
	then_branch: [dynamic]Stmt,
	else_branch: [dynamic]Stmt,
}

While_Expr :: struct {
	span:      Span,
	condition: Expr,
	body:      [dynamic]Stmt,
}

Tuple_Expr :: struct {
	span:     Span,
	elements: [dynamic]Expr,
}

Lambda_Expr :: struct {
	span:        Span,
	args:        [dynamic]Param_Decl,
	return_type: Type_Node,
	body:        [dynamic]Stmt,
}

Array_Expr :: struct {
	span:     Span,
	elements: [dynamic]Expr,
}

Map_Entry_Expr :: struct {
	span:  Span,
	key:   Expr,
	value: Expr,
}

Map_Expr :: struct {
	span:    Span,
	entries: [dynamic]Map_Entry_Expr,
}

Index_Expr :: struct {
	span:   Span,
	object: Expr,
	index:  Expr,
}

Try_Expr :: struct {
	span:  Span,
	value: Expr,
}

Error_Expr :: struct {
	span: Span,
}

Expr :: union {
	^Number_Expr,
	^Boolean_Expr,
	^String_Expr,
	^Binary_Expr,
	^Unary_Expr,
	^Ident_Expr,
	^Call_Expr,
	^While_Expr,
	^If_Expr,
	^Tuple_Expr,
	^Property_Expr,
	^Lambda_Expr,
	^Array_Expr,
	^Map_Expr,
	^Index_Expr,
	^Try_Expr,
	^Match_Expr,
	^Error_Expr,
	^Spawn_Expr,
}

// --- ПЕЧАТЬ AST ---

print_program :: proc(prog: Program) {
	fmt.println("Program")
	for decl in prog.decls {
		print_decl(decl)
	}
}

print_decl :: proc(decl: Decls) {
	#partial switch d in decl {
	case ^Import_Decl:
		if d.alias != "" {
			fmt.printf("Import (%s as %s)\n", d.path, d.alias)
		} else {
			fmt.printf("Import (%s)\n", d.path)
		}
	case ^Function_Decl:
		fmt.printf("%sFunction (%s)\n", d.is_exported ? "Export " : "", d.name)
		for stmt, i in d.body {
			is_last := i == len(d.body) - 1
			print_stmt(stmt, "", is_last)
		}
	case ^Struct_Decl:
		fmt.printf("%sStruct (%s)\n", d.is_exported ? "Export " : "", d.name)
		for field, i in d.fields {
			is_last := i == len(d.fields) - 1
			print_field(field, "", is_last)
		}
	case ^Impl_Decl:
		fmt.printf("Impl (%s)\n", d.target_type)
	case ^Interface_Decl:
		fmt.printf("%sInterface (%s)\n", d.is_exported ? "Export " : "", d.name)
	}
}

print_field :: proc(field: Field_Decl, prefix: string = "", is_last: bool = true) {
	marker := is_last ? "└── " : "├── "
	fmt.printf("%s%sField(%s)\n", prefix, marker, field.name)
}

print_stmt :: proc(stmt: Stmt, prefix: string = "", is_last: bool = true) {
	if stmt == nil do return

	marker := is_last ? "└── " : "├── "
	next_prefix := fmt.tprintf("%s%s", prefix, is_last ? "    " : "│   ")

	switch s in stmt {
	case ^Let_Stmt:
		fmt.printf("%s%sLet(%s)\n", prefix, marker, s.name)
		print_ast(s.value, next_prefix, true)

	case ^Return_Stmt:
		fmt.printf("%s%sReturn\n", prefix, marker)
		if s.value != nil {
			print_ast(s.value, next_prefix, true)
		}

	case ^Expr_Stmt:
		fmt.printf("%s%sExpr_Stmt\n", prefix, marker)
		print_ast(s.expr, next_prefix, true)

	case ^Continue_Stmt:
		fmt.printf("%s%sContinue\n", prefix, marker)

	case ^Break_Stmt:
		fmt.printf("%s%sBreak\n", prefix, marker)

	case ^Error_Stmt:
		fmt.printf("%s%s<parse error>\n", prefix, marker)

	case ^For_In_Stmt:
		fmt.printf("%s%sFor_In(%v)\n", prefix, marker, s.names)
		print_ast(s.iterable, next_prefix, false)
		for body_stmt, i in s.body {
			print_stmt(body_stmt, next_prefix, i == len(s.body) - 1)
		}
	}
}

print_ast :: proc(expr: Expr, prefix: string = "", is_last: bool = true) {
	if expr == nil do return

	marker := is_last ? "└── " : "├── "
	next_prefix_base := is_last ? "    " : "│   "
	next_prefix := fmt.tprintf("%s%s", prefix, next_prefix_base)

	#partial switch e in expr {
	case ^Number_Expr:
		fmt.printf("%s%sNumber(%v)\n", prefix, marker, e.value)
	case ^Boolean_Expr:
		fmt.printf("%s%sBoolean(%v)\n", prefix, marker, e.value)
	case ^String_Expr:
		fmt.printf("%s%sString(\"%s\")\n", prefix, marker, e.value)
	case ^Unary_Expr:
		fmt.printf("%s%sUnary(%v)\n", prefix, marker, e.op)
		print_ast(e.right, next_prefix, true)
	case ^Binary_Expr:
		fmt.printf("%s%sBinary(%v)\n", prefix, marker, e.op)
		print_ast(e.left, next_prefix, false)
		print_ast(e.right, next_prefix, true)
	case ^Ident_Expr:
		fmt.printf("%s%sIdent(%v)\n", prefix, marker, resolve_interned(e.name))
	case ^Call_Expr:
		fmt.printf("%s%sCall()\n", prefix, marker)
		print_ast(e.callee, next_prefix, false)
		for arg, i in e.args {
			print_ast(arg, next_prefix, i == len(e.args) - 1)
		}
	case ^While_Expr:
		fmt.printf("%s%sWhile()\n", prefix, marker)
		print_ast(e.condition, next_prefix, false)
		for stmt, i in e.body {
			print_stmt(stmt, next_prefix, i == len(e.body) - 1)
		}
	case ^If_Expr:
		fmt.printf("%s%sIf()\n", prefix, marker)
		print_ast(e.condition, next_prefix, false)
		for stmt in e.then_branch {
			print_stmt(stmt, next_prefix, false)
		}
		for stmt, i in e.else_branch {
			print_stmt(stmt, next_prefix, i == len(e.else_branch) - 1)
		}
	case ^Tuple_Expr:
		fmt.printf("%s%sTuple()\n", prefix, marker)
		for el, i in e.elements {
			print_ast(el, next_prefix, i == len(e.elements) - 1)
		}
	case ^Property_Expr:
		fmt.printf("%s%sProperty(%s)\n", prefix, marker, e.property)
		print_ast(e.object, next_prefix, true)
	case ^Lambda_Expr:
		fmt.printf("%s%sLambda()\n", prefix, marker)
		for stmt, i in e.body {
			print_stmt(stmt, next_prefix, i == len(e.body) - 1)
		}
	case ^Array_Expr:
		fmt.printf("%s%sArray()\n", prefix, marker)
		for el, i in e.elements {
			print_ast(el, next_prefix, i == len(e.elements) - 1)
		}
	case ^Map_Expr:
		fmt.printf("%s%sMap()\n", prefix, marker)
		for entry, i in e.entries {
			entry_marker := i == len(e.entries) - 1 ? "└── " : "├── "
			entry_prefix := fmt.tprintf(
				"%s%s",
				next_prefix,
				i == len(e.entries) - 1 ? "    " : "│   ",
			)
			fmt.printf("%s%sEntry\n", next_prefix, entry_marker)
			print_ast(entry.key, entry_prefix, false)
			print_ast(entry.value, entry_prefix, true)
		}
	case ^Index_Expr:
		fmt.printf("%s%sIndex()\n", prefix, marker)
		print_ast(e.object, next_prefix, false)
		print_ast(e.index, next_prefix, true)
	case ^Try_Expr:
		fmt.printf("%s%sTry(?)\n", prefix, marker)
		print_ast(e.value, next_prefix, true)
	}
}

// --- ПАРСИНГ ВЕРХНЕГО УРОВНЯ ---

parse_program :: proc(p: ^Parser) -> Program {
	prog := Program {
		decls = make([dynamic]Decls),
	}

	for peek_token(p.stream).kind != .EOF {
		is_exported := false
		if peek_token(p.stream).kind == .Export {
			next_token(p.stream)
			is_exported = true
		}

		tok_kind := peek_token(p.stream).kind
		if tok_kind == .Import {
			if is_exported {
				report_parse(p, peek_token(p.stream).span, "Синтаксическая ошибка: нельзя экспортировать импорт")
			}
			decl := parse_import_decl(p)
			append(&prog.decls, decl)
		} else if tok_kind == .Function {
			decl := parse_function(p, is_exported)
			append(&prog.decls, decl)
		} else if tok_kind == .TypeDecl {
			// Бывает короче 4 токенов у оборванного файла ("тип X" в самом
			// конце) — без bounds-check тут был бы index-out-of-range panic.
			if p.stream.current_idx+3 >= len(p.stream.tokens) {
				bad_span := peek_token(p.stream).span
				report_parse(p, bad_span, "Синтаксическая ошибка: неполное объявление типа")
				// .TypeDecl сам по себе sync-токен (is_sync_token): без
				// next_token skip_to_sync вернулся бы немедленно, не продвинув
				// поток, а внешний for снова увидел бы тот же .TypeDecl —
				// бесконечный цикл. Потребляем токен ПЕРЕД skip_to_sync.
				next_token(p.stream)
				skip_to_sync(p)
				err_decl := new(Error_Decl)
				err_decl.span = span_from(p, bad_span)
				append(&prog.decls, err_decl)
				continue
			}
			// Фиксированный offset +3 ('тип' NAME '=' BODY_KIND) не годится:
			// 'тип Пара[A, B] = структура' вставляет переменное число токенов
			// между именем и '='. peek_type_decl_body_kind не потребляет
			// токены — сканирует мимо опционального '[...]' до '=' и возвращает
			// токен сразу после него.
			third_kind := peek_type_decl_body_kind(p)
			if third_kind == .Struct {
				decl := parse_struct_decl(p, is_exported)
				append(&prog.decls, decl)
			} else if third_kind == .Enum {
				decl := parse_enum_decl(p, is_exported)
				append(&prog.decls, decl)
			} else if third_kind == .Interface {
				decl := parse_interface_decl(p, is_exported)
				append(&prog.decls, decl)
			} else if third_kind == .FFStruct {
				decl := parse_ffi_struct_decl(p, is_exported)
				append(&prog.decls, decl)
			} else {
				// peek-only (третий токен вперёд не потреблён) — без skip
				// следующая итерация увидит тот же .TypeDecl и зациклится.
				bad_span := peek_token(p.stream).span
				report_parse(
					p,
					bad_span,
					"Синтаксическая ошибка: после 'тип X =' ожидалось 'структура', 'интерфейс', 'перечисление' или 'ff_структура', получено: %v",
					third_kind,
				)
				next_token(p.stream)
				skip_to_sync(p)
				err_decl := new(Error_Decl)
				err_decl.span = span_from(p, bad_span)
				append(&prog.decls, err_decl)
			}
		} else if tok_kind == .Impl {
			if is_exported {
				report_parse(p, peek_token(p.stream).span, "Синтаксическая ошибка: реализация не может быть экспортирована")
			}
			decl := parse_impl_decl(p)
			append(&prog.decls, decl)
		} else if tok_kind == .Foreign {
			if is_exported {
				report_parse(p, peek_token(p.stream).span, "Синтаксическая ошибка: 'внешний' не может быть экспортирован")
			}
			decl := parse_foreign_decl(p)
			append(&prog.decls, decl)
		} else {
			// peek-only — без skip зациклится на том же токене.
			bad_span := peek_token(p.stream).span
			report_parse(p, bad_span, "Ожидалось объявление, импорт или экспорт, получено: %v", tok_kind)
			next_token(p.stream)
			skip_to_sync(p)
			err_decl := new(Error_Decl)
			err_decl.span = span_from(p, bad_span)
			append(&prog.decls, err_decl)
		}
	}
	return prog
}

parse_import_decl :: proc(p: ^Parser) -> ^Import_Decl {
	start := peek_token(p.stream).span
	expect(p, .Import)
	decl := new(Import_Decl)

	path_tok := next_token(p.stream)
	if path_tok.kind != .Ident && path_tok.kind != .String {
		report_parse(p, path_tok.span, "Синтаксическая ошибка: после 'импорт' ожидается имя модуля или строка пути")
	}
	decl.path = path_tok.data

	if peek_token(p.stream).kind == .As {
		next_token(p.stream)
		alias_tok := next_token(p.stream)
		if alias_tok.kind != .Ident {
			report_parse(p, alias_tok.span, "Синтаксическая ошибка: после 'как' ожидается имя псевдонима")
		}
		decl.alias = alias_tok.data
	}

	consume_semicolon_or_newline(p)
	decl.span = span_from(p, start)
	return decl
}

// `внешний "libc" функ getpid() -> Целое(32)` — не переиспользует
// parse_param_list/parse_type (общий `Type_Node`-парсер): единственный
// поддержанный тип параметра/возврата сейчас — `Целое` с ОБЯЗАТЕЛЬНЫМ
// width-модификатором `(32)`/`(64)`, синтаксис валиден ТОЛЬКО здесь (см.
// докstring у Foreign_Decl). Нет тела/`конец` — однострочная декларация.
parse_foreign_decl :: proc(p: ^Parser) -> ^Foreign_Decl {
	start := peek_token(p.stream).span
	expect(p, .Foreign)

	lib_tok := next_token(p.stream)
	if lib_tok.kind != .String {
		report_parse(p, lib_tok.span, "Синтаксическая ошибка: после 'внешний' ожидается имя библиотеки строкой, получено: %v", lib_tok.kind)
	}
	decl := new(Foreign_Decl)
	decl.library = lib_tok.data

	expect(p, .Function)
	name_tok := next_token(p.stream)
	if name_tok.kind != .Ident {
		report_parse(p, name_tok.span, "Синтаксическая ошибка: ожидалось имя функции, получено: %v", name_tok.kind)
	}
	decl.name = name_tok.data

	decl.params = make([dynamic]Foreign_Param)
	expect(p, .LParen)
	if peek_token(p.stream).kind != .RParen {
		for {
			param_span := peek_token(p.stream).span
			param_name_tok := next_token(p.stream)
			if param_name_tok.kind != .Ident {
				report_parse(p, param_name_tok.span, "Синтаксическая ошибка: ожидалось имя параметра, получено: %v", param_name_tok.kind)
			}
			expect(p, .Colon)
			marshal, pointee, struct_name := parse_foreign_marshal_type(p)
			if marshal == .Void {
				report_parse(p, param_span, "Синтаксическая ошибка: 'Пусто' допустим только как возвращаемый тип 'внешний', не как тип параметра")
			}
			append(&decl.params, Foreign_Param{span = span_from(p, param_span), name = param_name_tok.data, marshal = marshal, pointee = pointee, struct_type_name = struct_name})
			if peek_token(p.stream).kind == .Comma {
				next_token(p.stream)
			} else {
				break
			}
		}
	}
	expect(p, .RParen)

	expect(p, .Arrow)
	decl.return_marshal, decl.return_pointee, decl.return_struct_type_name = parse_foreign_marshal_type(p)
	if decl.return_marshal == .Pointer {
		decl.return_owned = parse_foreign_ownership_suffix(p)
	}

	consume_semicolon_or_newline(p)
	decl.span = span_from(p, start)
	return decl
}

// Стадия 47/49/51: поддержанные формы типа в `внешний`-сигнатуре —
// `Пусто` (ТОЛЬКО возврат, void), `Целое(8|32|64)` (marshalling-ширина
// libffi ffi_type_[u]int8/sint32/64), `Число(32|64)` (float/double),
// `КСтрока` (голый идентификатор без параметров — C char*, marshalling
// ↔ panos Строка), `Указатель(T)` (T — обычный parse_type, чисто
// фантомный на panos-стороне, marshalling — raw pointer), ЛЮБОЙ ДРУГОЙ
// идентификатор — имя ff_структура-типа (marshalling — struct-by-
// value, имя резолвится позже на typecheck, см. type_cheker.odin, case
// ^Foreign_Decl — типов ещё не существует на этапе парсинга). Ни одно
// из имён — не keyword лексера, распознаются строковым сравнением
// ТОЛЬКО в этом контексте (тот же приём, что уже был у 'Целое').
parse_foreign_marshal_type :: proc(p: ^Parser) -> (marshal: Foreign_Marshal_Kind, pointee: Type_Node, struct_type_name: string) {
	type_tok := peek_token(p.stream)
	if type_tok.kind != .Ident {
		report_parse(p, type_tok.span, "Синтаксическая ошибка: во 'внешний' ожидался тип (Целое/Число/КСтрока/Указатель/Пусто), получено: %v", type_tok.kind)
		next_token(p.stream)
		return .Int32, nil, ""
	}

	switch type_tok.data {
	case "Пусто":
		next_token(p.stream)
		return .Void, nil, ""
	case "Целое":
		next_token(p.stream)
		expect(p, .LParen)
		width_tok := next_token(p.stream)
		if width_tok.kind != .Number || (width_tok.data != "8" && width_tok.data != "32" && width_tok.data != "64") {
			report_parse(p, width_tok.span, "Синтаксическая ошибка: 'Целое(...)' в 'внешний' ожидает ширину 8, 32 или 64, получено: %v", width_tok.data)
			expect(p, .RParen)
			return .Int32, nil, ""
		}
		expect(p, .RParen)
		width_kind: Foreign_Marshal_Kind
		switch width_tok.data {
		case "8": width_kind = .Int8
		case "32": width_kind = .Int32
		case: width_kind = .Int64
		}
		return width_kind, nil, ""
	case "Число":
		next_token(p.stream)
		expect(p, .LParen)
		width_tok := next_token(p.stream)
		if width_tok.kind != .Number || (width_tok.data != "32" && width_tok.data != "64") {
			report_parse(p, width_tok.span, "Синтаксическая ошибка: 'Число(...)' в 'внешний' ожидает ширину 32 или 64, получено: %v", width_tok.data)
			expect(p, .RParen)
			return .Float32, nil, ""
		}
		expect(p, .RParen)
		return (width_tok.data == "32" ? Foreign_Marshal_Kind.Float32 : Foreign_Marshal_Kind.Float64), nil, ""
	case "КСтрока":
		next_token(p.stream)
		return .CString, nil, ""
	case "Указатель":
		next_token(p.stream)
		expect(p, .LParen)
		t := parse_type(p)
		expect(p, .RParen)
		return .Pointer, t, ""
	case:
		// Стадия 51: любое другое имя — ссылка на ff_структура-тип,
		// проверяется на typecheck (тип ещё не резолвится здесь).
		next_token(p.stream)
		return .Struct, nil, type_tok.data
	}
}

// Стадия 49: постфикс владения ПОСЛЕ Указатель(T) на возврате —
// `свой`/`чужой`, только строковое сравнение (не keyword), тот же
// приём, что типы выше. Отсутствие суффикса — тоже валидно, default
// `чужой` (безопасный: никогда не освобождать чужую память).
parse_foreign_ownership_suffix :: proc(p: ^Parser) -> bool {
	tok := peek_token(p.stream)
	if tok.kind != .Ident {
		return false
	}
	switch tok.data {
	case "свой":
		next_token(p.stream)
		return true
	case "чужой":
		next_token(p.stream)
		return false
	}
	return false
}

parse_enum_decl :: proc(p: ^Parser, is_exported: bool) -> ^Enum_Decl {
	start := peek_token(p.stream).span
	expect(p, .TypeDecl)

	name_tok := next_token(p.stream)
	if name_tok.kind != .Ident {
		report_parse(
			p,
			name_tok.span,
			"Синтаксическая ошибка: после 'тип' ожидалось имя перечисления, получено: %v",
			name_tok.kind,
		)
	}

	decl := new(Enum_Decl)
	decl.name = name_tok.data
	decl.is_exported = is_exported
	decl.variants = make([dynamic]Variant_Decl)

	if peek_token(p.stream).kind == .LBracket {
		decl.type_params = parse_type_params(p)
	}

	expect(p, .Assign)
	expect(p, .Enum)

	seen := make(map[string]bool)
	defer delete(seen)

	for peek_token(p.stream).kind != .End && peek_token(p.stream).kind != .EOF {
		variant_tok := next_token(p.stream)
		if variant_tok.kind != .Ident {
			report_parse(
				p,
				variant_tok.span,
				"Синтаксическая ошибка: в перечислении '%s' ожидалось имя варианта, получено: %v",
				decl.name,
				variant_tok.kind,
			)
		}
		if seen[variant_tok.data] {
			report_parse(
				p,
				variant_tok.span,
				"Синтаксическая ошибка: вариант '%s' объявлен дважды в '%s'",
				variant_tok.data,
				decl.name,
			)
		}
		seen[variant_tok.data] = true

		variant := Variant_Decl {
			name  = variant_tok.data,
			types = make([dynamic]Type_Node),
		}

		if peek_token(p.stream).kind == .LParen {
			next_token(p.stream) // (
			if peek_token(p.stream).kind == .RParen {
				report_parse(
					p,
					peek_token(p.stream).span,
					"Синтаксическая ошибка: у варианта '%s.%s' должны быть либо параметры в скобках, либо скобки должны отсутствовать",
					decl.name,
					variant_tok.data,
				)
			}
			for {
				append(&variant.types, parse_type(p))
				if peek_token(p.stream).kind == .Comma {
					next_token(p.stream)
					continue
				}
				break
			}
			expect(p, .RParen)
		}

		variant.span = span_from(p, variant_tok.span)
		append(&decl.variants, variant)
		consume_semicolon_or_newline(p)
	}

	expect(p, .End)

	if len(decl.variants) == 0 {
		report_parse(
			p,
			span_from(p, start),
			"Синтаксическая ошибка: перечисление '%s' должно объявлять хотя бы один вариант",
			decl.name,
		)
	}

	decl.span = span_from(p, start)
	return decl
}

parse_interface_decl :: proc(p: ^Parser, is_exported: bool) -> ^Interface_Decl {
	start := peek_token(p.stream).span
	expect(p, .TypeDecl)
	decl := new(Interface_Decl)
	decl.methods = make([dynamic]Method_Signature)
	decl.is_exported = is_exported

	name_tok := next_token(p.stream)
	decl.name = name_tok.data

	if peek_token(p.stream).kind == .LBracket {
		decl.type_params = parse_type_params(p)
	}

	expect(p, .Assign)
	expect(p, .Interface)

	for peek_token(p.stream).kind != .End && peek_token(p.stream).kind != .EOF {
		method_start := peek_token(p.stream).span
		expect(p, .Function)
		method_name := next_token(p.stream)
		signature := Method_Signature {
			name = method_name.data,
		}
		signature.args = parse_param_list(p, true)
		signature.return_type = parse_required_return_type(p, "метода интерфейса")
		signature.span = span_from(p, method_start)
		append(&decl.methods, signature)
		consume_semicolon_or_newline(p)
	}

	expect(p, .End)
	decl.span = span_from(p, start)
	return decl
}

parse_impl_decl :: proc(p: ^Parser) -> ^Impl_Decl {
	start := peek_token(p.stream).span
	expect(p, .Impl)

	decl := new(Impl_Decl)
	decl.methods = make([dynamic]^Function_Decl)

	first_ident := next_token(p.stream)
	if first_ident.kind != .Ident do error(p, "Ожидалось имя типа или интерфейса")

	// Стадия 40: "реализация Модуль.Интерфейс для Тип" — квалификация
	// допустима ТОЛЬКО у имени интерфейса (первого идента), не у target_
	// type (тот всегда локальная структура/перечисление того же файла).
	interface_module := ""
	interface_ident := first_ident
	if peek_token(p.stream).kind == .Dot {
		next_token(p.stream) // .Dot
		qualified_tok := next_token(p.stream)
		if qualified_tok.kind != .Ident {
			report_parse(p, qualified_tok.span, "Синтаксическая ошибка: после '.' в имени интерфейса ожидается идентификатор")
		}
		interface_module = first_ident.data
		interface_ident = qualified_tok
	}

	if peek_token(p.stream).kind == .For {
		expect(p, .For)

		target_tok := next_token(p.stream)
		if target_tok.kind != .Ident do error(p, "Ожидалось имя целевой структуры")

		decl.interface_module = interface_module
		decl.interface_name = interface_ident.data
		decl.target_type = target_tok.data
	} else {
		if interface_module != "" {
			report_parse(
				p,
				first_ident.span,
				"Синтаксическая ошибка: квалифицированное имя допустимо только в форме 'реализация Модуль.Интерфейс для Тип'",
			)
		}
		decl.target_type = first_ident.data
	}

	for peek_token(p.stream).kind != .End && peek_token(p.stream).kind != .EOF {
		if peek_token(p.stream).kind != .Function {
			bad := peek_token(p.stream)
			report_parse(p, bad.span, "Внутри блока реализации могут быть только функции")
			// bad сам может быть sync-токеном (TypeDecl/Impl/Import/Export):
			// skip_to_sync тогда не продвинется, а цикл выше ждёт End/EOF —
			// зависание. Съедаем bad ПЕРЕД skip_to_sync.
			next_token(p.stream)
			skip_to_sync(p)
			continue
		}

		method := parse_function(p, false)
		if len(method.args) == 0 || method.args[0].name != "это" {
			report_parse(
				p,
				method.span,
				"Синтаксическая ошибка: первый аргумент метода '%s' структуры '%s' должен называться 'это'",
				method.name,
				decl.target_type,
			)
		}
		// Собственные type-параметры метода (функ м[E](это: Тип, x: E) -> ...)
		// поддержаны: type_cheker.odin объединяет type-параметры владельца [T]
		// с собственными InferVar метода в один current_type_params при
		// резолве сигнатуры.

		method.name = fmt.tprintf("%s::%s", decl.target_type, method.name)
		append(&decl.methods, method)
	}

	expect(p, .End)
	decl.span = span_from(p, start)
	return decl
}

parse_function :: proc(p: ^Parser, is_exported: bool) -> ^Function_Decl {
	start := peek_token(p.stream).span
	expect(p, .Function)
	function := new(Function_Decl)
	function.body = make([dynamic]Stmt)
	function.is_exported = is_exported

	tok := next_token(p.stream)
	if tok.kind != .Ident do report_parse(p, tok.span, "Синтаксическая ошибка: ожидалось имя функции, получено: %v", tok.kind)
	function.name = tok.data

	if peek_token(p.stream).kind == .LBracket {
		function.type_params, function.type_param_bounds = parse_function_type_params(p)
	}

	function.args = parse_param_list(p, true)
	function.return_type = parse_required_return_type(p, "функции")

	for peek_token(p.stream).kind != .End && peek_token(p.stream).kind != .EOF {
		parse_stmt_into(p, &function.body)
	}
	expect(p, .End)

	function.span = span_from(p, start)
	return function
}

// `[T]` или `[T, U]` после имени. Вызывающий только peek'ает `.LBracket` —
// съедаем его сами.
parse_type_params :: proc(p: ^Parser) -> [dynamic]string {
	next_token(p.stream) // .LBracket
	names := make([dynamic]string)
	for {
		name_tok := next_token(p.stream)
		if name_tok.kind != .Ident {
			report_parse(p, name_tok.span, "Синтаксическая ошибка: в списке type-параметров '[...]' ожидается идентификатор")
		}
		append(&names, name_tok.data)
		if peek_token(p.stream).kind == .Comma {
			next_token(p.stream)
		} else {
			break
		}
	}
	expect(p, .RBracket)
	return names
}

// `[T]`, `[T, U]` или `[T: Интерфейс1 + Интерфейс2, U]` после имени
// функции — bounded traits, ТОЛЬКО у функций (parse_type_params выше —
// общий для Struct/Interface, где bound'ов нет, см. ROADMAP). После
// имени type-параметра опциональный `: Интерфейс (+ Интерфейс)*` уходит
// в bounds-карту; без `:` параметр остаётся unbounded, как раньше.
parse_function_type_params :: proc(p: ^Parser) -> ([dynamic]string, map[string][dynamic]string) {
	next_token(p.stream) // .LBracket
	names := make([dynamic]string)
	bounds := make(map[string][dynamic]string)
	for {
		name_tok := next_token(p.stream)
		if name_tok.kind != .Ident {
			report_parse(p, name_tok.span, "Синтаксическая ошибка: в списке type-параметров '[...]' ожидается идентификатор")
		}
		append(&names, name_tok.data)

		if peek_token(p.stream).kind == .Colon {
			next_token(p.stream) // .Colon
			ifaces := make([dynamic]string)
			for {
				iface_tok := next_token(p.stream)
				if iface_tok.kind != .Ident {
					report_parse(p, iface_tok.span, "Синтаксическая ошибка: после ':' в bound'е type-параметра ожидается имя интерфейса")
				}
				append(&ifaces, iface_tok.data)
				if peek_token(p.stream).kind == .Plus {
					next_token(p.stream) // .Plus
				} else {
					break
				}
			}
			bounds[name_tok.data] = ifaces
		}

		if peek_token(p.stream).kind == .Comma {
			next_token(p.stream)
		} else {
			break
		}
	}
	expect(p, .RBracket)
	return names, bounds
}

// Read-only lookahead: НЕ потребляет токены (в отличие от parse_type_params).
// Начиная с токена сразу после 'тип NAME' (current_idx+2), пропускает
// опциональный '[...]' (с учётом вложенности скобок) и возвращает kind токена
// сразу после '='. Если на месте '=' стоит что-то другое — возвращает этот
// токен как есть, чтобы parse_program сообщил о нём в ошибке.
peek_type_decl_body_kind :: proc(p: ^Parser) -> TokenKind {
	idx := p.stream.current_idx + 2 // токен сразу после 'тип NAME'
	if idx < len(p.stream.tokens) && p.stream.tokens[idx].kind == .LBracket {
		depth := 1
		idx += 1
		for idx < len(p.stream.tokens) && depth > 0 {
			#partial switch p.stream.tokens[idx].kind {
			case .LBracket:
				depth += 1
			case .RBracket:
				depth -= 1
			case .EOF:
				return .EOF
			}
			idx += 1
		}
	}
	if idx >= len(p.stream.tokens) do return .EOF
	if p.stream.tokens[idx].kind != .Assign do return p.stream.tokens[idx].kind
	idx += 1
	if idx >= len(p.stream.tokens) do return .EOF
	return p.stream.tokens[idx].kind
}

parse_param_list :: proc(p: ^Parser, require_types: bool) -> [dynamic]Param_Decl {
	params := make([dynamic]Param_Decl)
	expect(p, .LParen)

	if peek_token(p.stream).kind != .RParen {
		for {
			param_tok := next_token(p.stream)
			if param_tok.kind != .Ident do report_parse(p, param_tok.span, "Синтаксическая ошибка: ожидалось имя аргумента, получено: %v", param_tok.kind)

			param := Param_Decl {
				name = param_tok.data,
			}

			if peek_token(p.stream).kind == .Colon {
				next_token(p.stream)
				param.type_annotation = parse_type(p)
			} else if require_types {
				report_parse(
					p,
					param_tok.span,
					"Синтаксическая ошибка: после аргумента '%s' ожидается ': Тип'",
					param.name,
				)
			}
			param.span = span_from(p, param_tok.span)
			append(&params, param)

			if peek_token(p.stream).kind == .Comma {
				next_token(p.stream)
				if peek_token(p.stream).kind == .RParen {
					break
				}
			} else {
				break
			}
		}
	}

	expect(p, .RParen)
	return params
}

parse_required_return_type :: proc(p: ^Parser, owner: string) -> Type_Node {
	if peek_token(p.stream).kind != .Arrow {
		report_parse(
			p,
			peek_token(p.stream).span,
			"Синтаксическая ошибка: после объявления %s ожидается '-> Тип'",
			owner,
		)
	} else {
		next_token(p.stream)
	}
	return parse_type(p)
}

parse_optional_return_type :: proc(p: ^Parser) -> Type_Node {
	if peek_token(p.stream).kind != .Arrow do return nil
	next_token(p.stream)
	return parse_type(p)
}

parse_struct_decl :: proc(p: ^Parser, is_exported: bool) -> ^Struct_Decl {
	start := peek_token(p.stream).span
	expect(p, .TypeDecl)

	decl := new(Struct_Decl)
	decl.fields = make([dynamic]Field_Decl)
	decl.is_exported = is_exported

	name_tok := next_token(p.stream)
	if name_tok.kind != .Ident do error(p, "Ожидалось имя типа")
	decl.name = name_tok.data

	if peek_token(p.stream).kind == .LBracket {
		decl.type_params = parse_type_params(p)
	}

	expect(p, .Assign)
	expect(p, .Struct)

	for peek_token(p.stream).kind != .End && peek_token(p.stream).kind != .EOF {
		field := Field_Decl{}

		field_tok := next_token(p.stream)
		if field_tok.kind != .Ident do error(p, "Ожидалось имя поля структуры")
		field.name = field_tok.data

		expect(p, .Colon)

		field.type_annotation = parse_type(p)
		field.span = span_from(p, field_tok.span)
		append(&decl.fields, field)

		consume_semicolon_or_newline(p)
	}

	expect(p, .End)
	decl.span = span_from(p, start)
	return decl
}

// Стадия 51: `тип X = ff_структура поле: Целое(N)|Число(N) ... конец` —
// C ABI struct-by-value для `внешний` (Vector2/Color-style). Поля через
// parse_foreign_marshal_type (переиспользование ширины-парсинга), но
// только Int8/Int32/Int64/Float32/Float64 допустимы — CString/Pointer/
// Struct/Void внутри поля — Type Error (плоский layout, без вложенности
// в этом срезе). Без generics (raylib не нуждается).
parse_ffi_struct_decl :: proc(p: ^Parser, is_exported: bool) -> ^Struct_Decl {
	start := peek_token(p.stream).span
	expect(p, .TypeDecl)

	decl := new(Struct_Decl)
	decl.fields = make([dynamic]Field_Decl)
	decl.is_exported = is_exported
	decl.is_ffi = true

	name_tok := next_token(p.stream)
	if name_tok.kind != .Ident do error(p, "Ожидалось имя типа")
	decl.name = name_tok.data

	expect(p, .Assign)
	expect(p, .FFStruct)

	for peek_token(p.stream).kind != .End && peek_token(p.stream).kind != .EOF {
		field := Field_Decl{}

		field_tok := next_token(p.stream)
		if field_tok.kind != .Ident do error(p, "Ожидалось имя поля ff_структура")
		field.name = field_tok.data

		expect(p, .Colon)

		marshal, _, struct_name := parse_foreign_marshal_type(p)
		#partial switch marshal {
		case .Int8, .Int32, .Int64, .Float32, .Float64:
			field.marshal_kind = marshal
		case:
			report_parse(
				p,
				field_tok.span,
				"Синтаксическая ошибка: поле ff_структура поддерживает только Целое(8|32|64)/Число(32|64), получено %s",
				struct_name != "" ? struct_name : fmt.tprintf("%v", marshal),
			)
			field.marshal_kind = .Int32
		}
		field.span = span_from(p, field_tok.span)
		append(&decl.fields, field)

		consume_semicolon_or_newline(p)
	}

	expect(p, .End)
	decl.span = span_from(p, start)
	return decl
}

// --- ПАРСИНГ ТИПОВ И ИНСТРУКЦИЙ ---

parse_type :: proc(p: ^Parser) -> Type_Node {
	tok := next_token(p.stream)
	start := tok.span

	if tok.kind == .Function {
		t := new(Type_Function)
		t.params = make([dynamic]Type_Node)

		expect(p, .LParen)
		if peek_token(p.stream).kind != .RParen {
			for {
				append(&t.params, parse_type(p))
				if peek_token(p.stream).kind == .Comma {
					next_token(p.stream)
					if peek_token(p.stream).kind == .RParen {
						break
					}
				} else {
					break
				}
			}
		}
		expect(p, .RParen)
		expect(p, .Arrow)
		t.return_type = parse_type(p)
		t.span = span_from(p, start)
		return t
	}

	if tok.kind == .Ident {
		if peek_token(p.stream).kind == .Dot {
			next_token(p.stream)
			member_tok := next_token(p.stream)
			if member_tok.kind != .Ident {
				report_parse(p, member_tok.span, "Синтаксическая ошибка: после '.' ожидается имя типа")
			}
			t := new(Type_Qualified)
			t.module_name = tok.data
			t.name = member_tok.data
			t.span = span_from(p, start)
			return t
		}

		// Дженерик-типы: Массив(Число), Соответствие(Число, Строка).
		// nl_before-проверка обязательна: без неё `-> Число\n\t(1 + 2)`
		// (тело функции, начинающееся с выражения в скобках) ошибочно читается
		// как generic-тип `Число(1 + 2)` — '(' достижим по peek независимо от
		// перевода строки. `Массив(Число)` всегда на одной строке, так что
		// запрет nl_before ничего легитимного не ломает.
		if peek_token(p.stream).kind == .LParen && !peek_token(p.stream).nl_before {
			next_token(p.stream) // съедаем (
			t := new(Type_Generic)
			t.name = tok.data
			t.params = make([dynamic]Type_Node)

			if peek_token(p.stream).kind != .RParen {
				for {
					append(&t.params, parse_type(p))
					if peek_token(p.stream).kind == .Comma {
						next_token(p.stream)
					} else {
						break
					}
				}
			}
			expect(p, .RParen)
			t.span = span_from(p, start)
			return t
		}

		// Иначе это обычный тип-идентификатор (Число, Строка)
		t := new(Type_Ident)
		t.name = tok.data
		t.span = span_from(p, start)
		return t
	}

	if tok.kind == .LParen {
		t := new(Type_Tuple)
		t.elements = make([dynamic]Type_Node)

		if peek_token(p.stream).kind != .RParen {
			for {
				append(&t.elements, parse_type(p))
				if peek_token(p.stream).kind == .Comma {
					next_token(p.stream)
				} else {
					break
				}
			}
		}
		expect(p, .RParen)
		t.span = span_from(p, start)
		return t
	}

	report_parse(p, start, "Ожидалось имя типа или тупл, получено: %v", tok.kind)
	err := new(Error_Type_Node)
	err.span = start
	return err
}

parse_stmt :: proc(p: ^Parser) -> Stmt {
	tok := peek_token(p.stream)
	if tok == nil do return nil

	#partial switch tok.kind {
	case .Return:
		return parse_return_stmt(p)
	case .Let, .Const:
		return parse_let_stmt(p)
	case .Continue:
		return parse_continue_stmt(p)
	case .Break:
		return parse_break_stmt(p)
	case:
		return parse_expr_stmt(p)
	}
}

// Не просто `append(&body, parse_stmt(p))` из-за для-in: "для x в expr цикл
// ... конец" раскрывается в НЕСКОЛЬКО statement'ов, а parse_stmt возвращает
// ровно один Stmt. Вместо AST-узла "блок из N statement'ов" (который пришлось
// бы учить понимать resolver/type_cheker/compiler) — единая точка сборки тела,
// используемая во всех шести местах (функция/если/иначе/пока/лямбда/ветка
// выбора). Desugar целиком в parser.odin: ниже по конвейеру про для-in не
// знают.
parse_stmt_into :: proc(p: ^Parser, body: ^[dynamic]Stmt) {
	if peek_token(p.stream).kind == .For {
		parse_for_stmt_into(p, body)
		return
	}
	append(body, parse_stmt(p))
}

// для <шаблон> в <expr> цикл <тело> конец
// шаблон := ident | '(' ident (',' ident)* ')'
//
// Раскрывается на месте в уже существующие узлы (Let_Stmt/While_Expr/
// If_Expr/Break_Stmt/Index_Expr/Property_Expr) — три statement'а на выходе:
//
//   пер __for_N_iter = <expr>
//   пер __for_N_idx = -1
//   пока истина цикл
//       __for_N_idx = __for_N_idx + 1
//       если __for_N_idx == __for_N_iter.длина() тогда прервать конец
//       пер <элемент(ы) из шаблона> = __for_N_iter[__for_N_idx]
//       <тело>
//   конец
//
// Инкремент — ПЕРЕД телом, не после: `продолжить` компилируется как прыжок
// на начало `пока`-цикла (см. Loop_Context.continue_target в compiler.odin),
// т.е. на re-check условия. При инкременте ПОСЛЕ тела `продолжить` перепрыгнул
// бы через него — idx не растёт, бесконечный цикл. С условием "пока истина" и
// инкрементом в начале тела continue возвращается именно туда.
//
// Работает с чем угодно, что поддерживает .длина() + [индекс] (Массив).
// Соответствие так индексировать нельзя ([] у карты — по ключу, не по
// позиции); для карты сначала .записи(), возвращающая Массив((К,З)),
// совместимый с шаблоном "для (к, з) в ...".
//
// "в" — настоящий keyword лексера (TokenKind.In, lexer.odin), как "для"/
// "как"/"запусти". Раньше сравнивался по тексту токена в этой одной
// позиции грамматики и не резервировал имя вовсе — приведено к единой
// hard-reserved политике (см. docs/src/language/basic-types.md
// "Зарезервированные слова"): всё зарезервированное слово либо жёсткий
// keyword лексера (как здесь), либо reserved-имя в резолвере
// (install_standard_symbols + check_not_reserved, resolver.odin) —
// ничего не затеняемо пользовательским кодом.
parse_for_stmt_into :: proc(p: ^Parser, out: ^[dynamic]Stmt) {
	start := peek_token(p.stream).span
	next_token(p.stream) // .For

	names := make([dynamic]string)
	if peek_token(p.stream).kind == .LParen {
		next_token(p.stream)
		for {
			name_tok := next_token(p.stream)
			if name_tok.kind != .Ident {
				report_parse(p, name_tok.span, "Синтаксическая ошибка: в шаблоне 'для (...)' ожидается идентификатор")
			}
			append(&names, name_tok.data)
			if peek_token(p.stream).kind == .Comma {
				next_token(p.stream)
			} else {
				break
			}
		}
		expect(p, .RParen)
	} else {
		name_tok := next_token(p.stream)
		if name_tok.kind != .Ident {
			report_parse(p, name_tok.span, "Синтаксическая ошибка: после 'для' ожидается идентификатор или '(идент, ...)'")
		}
		append(&names, name_tok.data)

		// Числовой диапазон: `для сч = 0 по 4 цикл` — одиночный идентификатор,
		// за которым сразу `=` вместо `в`, отличает эту форму от for-in.
		if peek_token(p.stream).kind == .Assign {
			parse_for_range_stmt_into(p, out, start, name_tok.data)
			return
		}
	}

	in_tok := next_token(p.stream)
	if in_tok.kind != .In {
		report_parse(p, in_tok.span, "Синтаксическая ошибка: после списка переменных 'для' ожидается 'в'")
	}

	iterable := parse_expr(p, 0)

	expect(p, .Loop)
	user_body := make([dynamic]Stmt)
	for {
		kind := peek_token(p.stream).kind
		if kind == .End || kind == .EOF do break
		parse_stmt_into(p, &user_body)
	}
	expect(p, .End)

	span := span_from(p, start)

	stmt := new(For_In_Stmt)
	stmt.span = span
	stmt.names = names
	stmt.iterable = iterable
	stmt.body = user_body
	append(out, stmt)
}

// Разворачивает числовой диапазон `для сч = <start> по <end> цикл ... конец`
// (границы включительно с обеих сторон) в:
//
//   пока истина цикл                 // ①  внешняя обёртка — только ради
//       пер <сч> = <start> - 1       //     собственного scope у <сч>/end,
//       пер __for_N_end = <end>      //     см. ниже; выполняется РОВНО 1 раз
//       пока истина цикл             // ②  сам диапазон
//           <сч> = <сч> + 1
//           если <сч> > __for_N_end тогда прервать конец
//           <тело>
//       конец
//       прервать                     // безусловно — конец обёртки ①
//   конец
//
// В отличие от for-in (где элемент на каждой итерации ЗАНОВО привязывается
// через `пер`), здесь <сч> — единственная живая переменная-счётчик. Если тело
// меняет <сч> (`сч = сч + 1`), это по-настоящему сдвигает следующую итерацию,
// как в C-style `for`. Осознанный выбор ради шаблона "прочитать значение по
// сч+1 и пропустить его следующей итерацией": `для` не даёт доступа к
// внутреннему индексу, так что без live счётчика пропуск невозможен.
//
// Внешняя обёртка ① нужна, т.к. `пер <сч> = ...` объявлен ПРЯМО в теле (а не
// перепривязывается внутри цикла, как у for-in) — без своего scope он утёк бы
// в объемлющий блок, и второй такой `для` в той же функции упал бы с "Имя сч
// уже объявлено". resolver.odin заводит новый scope на каждый While_Expr.body;
// тело ① исполняется ровно 1 раз и сразу прерывается.
//
// Continue-safety та же, что и в for-in: инкремент первым в теле ②, до
// пользовательского кода, чтобы `продолжить` (прыжок на начало цикла ②)
// проходил через инкремент, а не перепрыгивал. <end> считаем один раз в
// отдельную переменную ДО цикла.
//
// Вызывается из parse_for_stmt_into сразу после одиночного идентификатора,
// когда за ним следует `=` вместо `в`; `=` ещё не съеден.
parse_for_range_stmt_into :: proc(p: ^Parser, out: ^[dynamic]Stmt, start: Span, var_name: string) {
	next_token(p.stream) // .Assign

	start_expr := parse_expr(p, 0)

	po_tok := next_token(p.stream)
	if po_tok.kind != .Ident || po_tok.data != "по" {
		report_parse(p, po_tok.span, "Синтаксическая ошибка: после начала диапазона 'для X = ...' ожидается 'по'")
	}

	end_expr := parse_expr(p, 0)

	expect(p, .Loop)
	user_body := make([dynamic]Stmt)
	for {
		kind := peek_token(p.stream).kind
		if kind == .End || kind == .EOF do break
		parse_stmt_into(p, &user_body)
	}
	expect(p, .End)

	span := span_from(p, start)

	p.for_counter += 1
	end_name := fmt.tprintf("__for_%d_end", p.for_counter)

	inner_body := make([dynamic]Stmt)
	// <сч> = <сч> + 1
	append(&inner_body, mk_incr(var_name, span))
	// если <сч> > __for_N_end тогда прервать конец
	cmp_gt := mk_bin(.Greater, mk_ident(var_name, span), mk_ident(end_name, span), span)
	append(&inner_body, mk_if_break(cmp_gt, span))
	for stmt in user_body {
		append(&inner_body, stmt)
	}

	outer_body := make([dynamic]Stmt)
	// пер <сч> = <start> - 1
	// Аннотация Целое обязательна: без неё счётчик выводился бы как Число
	// (голый литерал по умолчанию, см. Type_Kind.Integer) — а индексация
	// массивов/строк требует именно Целое, `для i = A по B ... arr[i]` —
	// основной паттерн индексного доступа в языке (см. std/коллекции.ps's
	// отсортировать), должен работать без явной аннотации у пользователя.
	counter_let := mk_let(var_name, mk_bin(.Minus, start_expr, mk_num(1, span), span), span)
	counter_let.(^Let_Stmt).type_annotation = mk_type_ident_int(span)
	append(&outer_body, counter_let)
	// пер __for_N_end = <end> — тоже Целое, иначе `<сч> > __for_N_end`
	// сравнивал бы Целое с Число.
	end_let := mk_let(end_name, end_expr, span)
	end_let.(^Let_Stmt).type_annotation = mk_type_ident_int(span)
	append(&outer_body, end_let)
	append(&outer_body, mk_while(mk_bool(true, span), inner_body, span))
	append(&outer_body, mk_break(span))

	append(out, mk_while(mk_bool(true, span), outer_body, span))
}

parse_continue_stmt :: proc(p: ^Parser) -> Stmt {
	start := peek_token(p.stream).span
	next_token(p.stream)
	stmt := new(Continue_Stmt)
	consume_semicolon_or_newline(p)
	stmt.span = span_from(p, start)
	return stmt
}

parse_break_stmt :: proc(p: ^Parser) -> Stmt {
	start := peek_token(p.stream).span
	next_token(p.stream)
	stmt := new(Break_Stmt)
	consume_semicolon_or_newline(p)
	stmt.span = span_from(p, start)
	return stmt
}

parse_return_stmt :: proc(p: ^Parser) -> Stmt {
	start := peek_token(p.stream).span
	next_token(p.stream)
	stmt := new(Return_Stmt)

	tok := peek_token(p.stream)
	if tok.kind == .Semicolon || tok.kind == .End || tok.kind == .EOF {
		stmt.value = nil
	} else {
		stmt.value = parse_expr(p, 0)
	}

	consume_semicolon_or_newline(p)
	stmt.span = span_from(p, start)
	return stmt
}

parse_let_stmt :: proc(p: ^Parser) -> Stmt {
	start := peek_token(p.stream).span
	is_const := peek_token(p.stream).kind == .Const
	next_token(p.stream)
	stmt := new(Let_Stmt)
	stmt.is_const = is_const

	if peek_token(p.stream).kind == .LParen {
		// Тупл-деструктуризация: пер (a, b) = ... — тупл без имён полей,
		// именованная форма не имеет смысла (та же причина, что enum-
		// варианты в match-шаблонах, Стадия 35).
		stmt.names, _ = parse_destructure_names(p, false)
	} else {
		ident_tok := next_token(p.stream)
		if ident_tok.kind != .Ident {
			keyword := is_const ? "конст" : "пер"
			report_parse(p, ident_tok.span, "Синтаксическая ошибка: после '%s' ожидается идентификатор", keyword)
		}
		if peek_token(p.stream).kind == .LParen {
			// Структурная деструктуризация: пер Тип(a, b) = ... (позиционная,
			// поля по порядку объявления) или пер Тип(x: a, y: b) = ...
			// (именованная, частичная — Стадия 37).
			stmt.names, stmt.destructure_field_names = parse_destructure_names(p, true)
			stmt.destructure_type = ident_tok.data
		} else {
			stmt.name = ident_tok.data
			if peek_token(p.stream).kind == .Colon {
				next_token(p.stream)
				stmt.type_annotation = parse_type(p)
			}
		}
	}

	expect(p, .Assign)
	stmt.value = parse_expr(p, 0)
	consume_semicolon_or_newline(p)
	stmt.span = span_from(p, start)
	return stmt
}

// Общий разбор "(a, b, ...)" (позиционная) или "(x: a, y: b, ...)"
// (именованная, только если allow_named — структурная форма) для обеих
// форм деструктуризации `пер` — зеркалит for-in'овый список имён
// (parse_for_stmt_into) плюс именованный вариант из Стадии 35/36 (та же
// схема: решается по ПЕРВОМУ элементу, `Ident Colon` впереди однозначно
// сигналит именованную форму, смешивать с позиционной нельзя).
parse_destructure_names :: proc(p: ^Parser, allow_named: bool) -> (names: [dynamic]string, field_names: [dynamic]string) {
	next_token(p.stream) // '('
	names = make([dynamic]string)
	is_named :=
		allow_named &&
		peek_token(p.stream).kind == .Ident &&
		peek_second_token(p.stream).kind == .Colon
	if is_named {
		field_names = make([dynamic]string)
	}
	for {
		if is_named {
			field_tok := next_token(p.stream)
			if field_tok.kind != .Ident {
				report_parse(
					p,
					field_tok.span,
					"Синтаксическая ошибка: ожидалось имя поля перед ':' в именованной деструктуризации",
				)
			}
			expect(p, .Colon)
			append(&field_names, field_tok.data)
		} else if allow_named && peek_token(p.stream).kind == .Ident && peek_second_token(p.stream).kind == .Colon {
			report_parse(
				p,
				peek_token(p.stream).span,
				"Синтаксическая ошибка: нельзя смешивать позиционную и именованную деструктуризацию в одном выражении",
			)
		}
		name_tok := next_token(p.stream)
		if name_tok.kind != .Ident {
			report_parse(p, name_tok.span, "Синтаксическая ошибка: в шаблоне деструктуризации ожидается идентификатор")
		}
		append(&names, name_tok.data)
		if peek_token(p.stream).kind == .Comma {
			next_token(p.stream)
		} else {
			break
		}
	}
	expect(p, .RParen)
	return names, field_names
}

parse_expr_stmt :: proc(p: ^Parser) -> Stmt {
	start := peek_token(p.stream).span
	stmt := new(Expr_Stmt)
	stmt.expr = parse_expr(p, 0)
	consume_semicolon_or_newline(p)
	stmt.span = span_from(p, start)
	return stmt
}

// --- ПАРСИНГ ВЫРАЖЕНИЙ (PRATT PARSER) ---

parse_if_expr :: proc(p: ^Parser) -> Expr {
	start := last_token_span(p.stream) // .If уже съеден вызывающим nud()
	node := new(If_Expr)
	node.condition = parse_expr(p, 0)

	expect(p, .Then)
	node.then_branch = make([dynamic]Stmt)
	for {
		kind := peek_token(p.stream).kind
		if kind == .Else || kind == .End || kind == .EOF do break
		parse_stmt_into(p, &node.then_branch)
	}

	node.else_branch = make([dynamic]Stmt)
	if peek_token(p.stream).kind == .Else {
		next_token(p.stream)
		for {
			kind := peek_token(p.stream).kind
			if kind == .End || kind == .EOF do break
			parse_stmt_into(p, &node.else_branch)
		}
	}

	expect(p, .End)
	node.span = span_from(p, start)
	return node
}

parse_while_expr :: proc(p: ^Parser) -> Expr {
	start := last_token_span(p.stream) // .While уже съеден вызывающим nud()
	node := new(While_Expr)
	node.condition = parse_expr(p, 0)

	expect(p, .Loop)
	node.body = make([dynamic]Stmt)
	for {
		kind := peek_token(p.stream).kind
		if kind == .End || kind == .EOF do break
		parse_stmt_into(p, &node.body)
	}

	expect(p, .End)
	node.span = span_from(p, start)
	return node
}

// start передаётся вызывающим кодом (parse_expr) — это span идентификатора
// `массив`/`соответствие`, а не открывающей скобки, чтобы Array_Expr
// покрывал весь литерал целиком.
parse_array_literal_after_lparen :: proc(p: ^Parser, start: Span) -> Expr {
	node := new(Array_Expr)
	node.elements = make([dynamic]Expr)

	if peek_token(p.stream).kind != .RParen {
		for {
			append(&node.elements, parse_expr(p, 0))
			if peek_token(p.stream).kind == .Comma {
				next_token(p.stream)
				if peek_token(p.stream).kind == .RParen {
					break
				}
			} else {
				break
			}
		}
	}

	expect(p, .RParen)
	node.span = span_from(p, start)
	return node
}

parse_map_literal_after_lparen :: proc(p: ^Parser, start: Span) -> Expr {
	node := new(Map_Expr)
	node.entries = make([dynamic]Map_Entry_Expr)

	if peek_token(p.stream).kind != .RParen {
		for {
			entry := Map_Entry_Expr{}
			entry_start := peek_token(p.stream).span
			entry.key = parse_expr(p, 11)
			expect(p, .Assign)
			entry.value = parse_expr(p, 0)
			entry.span = span_from(p, entry_start)
			append(&node.entries, entry)

			if peek_token(p.stream).kind == .Comma {
				next_token(p.stream)
				if peek_token(p.stream).kind == .RParen {
					break
				}
			} else {
				break
			}
		}
	}

	expect(p, .RParen)
	return node
}

parse_expr :: proc(p: ^Parser, min_bp: int) -> Expr {
	tok := next_token(p.stream)
	if tok == nil {
		report_parse(p, last_token_span(p.stream), "Синтаксическая ошибка: неожиданный конец файла в выражении")
		err := new(Error_Expr)
		err.span = last_token_span(p.stream)
		return err
	}

	left := nud(p, tok)
	// Начало всей цепочки (левый операнд до всех Call/Property/Index/Try/
	// Binary обёрток) — используется для end-inclusive span каждой новой
	// обёртки, чтобы `a.b(c)[d]` целиком покрывался одним span'ом от `a`.
	start := expr_span(left)

	for {
		op := peek_token(p.stream)
		if op == nil || op.kind == .EOF do break

		lbp, rbp, is_infix := infix_bp(op)
		if !is_infix || lbp < min_bp do break
		// '(' на новой строке — НЕ продолжение вызова текущего выражения
		// (`7\n(а <= б)` — это `7`, затем НОВЫЙ statement `(а <= б)`, а не
		// вызов `7(а <= б)`). peek на '(' срабатывает независимо от перевода
		// строки, поэтому нужна явная проверка nl_before (ср. parse_type).
		if op.kind == .LParen && op.nl_before do break

		next_token(p.stream)

		if op.kind == .LParen {
			if ident, ok := left.(^Ident_Expr); ok {
				if ident.name == intern("массив") {
					left = parse_array_literal_after_lparen(p, ident.span)
					continue
				}
				if ident.name == intern("соответствие") {
					left = parse_map_literal_after_lparen(p, ident.span)
					continue
				}
			}

			// Вызов функции (в том числе массив() и соответствие()!)
			call := new(Call_Expr)
			call.callee = left
			call.args = make([dynamic]Expr)

			if peek_token(p.stream).kind != .RParen {
				// Именованные аргументы (`f(x = 1, y = 2)`) — решается по
				// ПЕРВОМУ аргументу: `Ident Assign` впереди однозначно
				// сигналит именованную форму. `x = 1` как позиционное
				// выражение-присваивание тут не теряется по факту —
				// присваивание возвращает Пусто, а Пусто нигде не может
				// быть типом параметра, так что старая интерпретация
				// НИКОГДА не типизировалась бы успешно ни в одной
				// реальной программе.
				is_named :=
					peek_token(p.stream).kind == .Ident &&
					peek_second_token(p.stream).kind == .Assign
				if is_named {
					call.arg_names = make([dynamic]string)
				}
				for {
					if is_named {
						name_tok := next_token(p.stream)
						if name_tok.kind != .Ident {
							report_parse(
								p,
								name_tok.span,
								"Синтаксическая ошибка: ожидалось имя аргумента перед '=' в именованном вызове",
							)
						}
						expect(p, .Assign)
						append(&call.arg_names, name_tok.data)
					} else if peek_token(p.stream).kind == .Ident && peek_second_token(p.stream).kind == .Assign {
						report_parse(
							p,
							peek_token(p.stream).span,
							"Синтаксическая ошибка: нельзя смешивать позиционные и именованные аргументы в одном вызове",
						)
					}
					append(&call.args, parse_expr(p, 0))
					if peek_token(p.stream).kind == .Comma {
						next_token(p.stream)
					} else {
						break
					}
				}
			}
			expect(p, .RParen)
			call.span = span_from(p, start)
			left = call

		} else if op.kind == .Dot {
			prop_tok := next_token(p.stream)
			if prop_tok.kind != .Ident && prop_tok.kind != .Number {
				report_parse(p, prop_tok.span, "Ожидалось имя поля или индекс после '.', получено: %v", prop_tok.kind)
			}
			prop := new(Property_Expr)
			prop.object = left
			prop.property = prop_tok.data
			prop.span = span_from(p, start)
			left = prop

		} else if op.kind == .LBracket {
			index := new(Index_Expr)
			index.object = left
			index.index = parse_expr(p, 0)
			expect(p, .RBracket)
			index.span = span_from(p, start)
			left = index

		} else if op.kind == .Question {
			try_expr := new(Try_Expr)
			try_expr.value = left
			try_expr.span = span_from(p, start)
			left = try_expr

		} else {
			// Обычный бинарный оператор (включая `=`)
			right := parse_expr(p, rbp)
			left = new_bin_op(op.kind, left, right, start)
		}
	}
	return left
}

nud :: proc(p: ^Parser, tok: ^Token) -> Expr {
	#partial switch tok.kind {
	case .Number:
		return new_int_lit(p, tok)

	case .Boolean:
		return new_boolean_lit(tok)

	case .String:
		s := new(String_Expr)
		s.value = tok.data
		s.span = tok.span
		return s

	case .InterpStringStart:
		return parse_interp_string(p, tok)

	case .Ident:
		return new_ident(tok)

	case .Function:
		// Лямбда-функции: функ(х) х + 1 конец
		start := tok.span
		lam := new(Lambda_Expr)
		lam.body = make([dynamic]Stmt)

		lam.args = parse_param_list(p, false)
		lam.return_type = parse_optional_return_type(p)

		for peek_token(p.stream).kind != .End && peek_token(p.stream).kind != .EOF {
			parse_stmt_into(p, &lam.body)
		}
		expect(p, .End)
		lam.span = span_from(p, start)
		return lam

	case .LParen:
		start := tok.span
		if peek_token(p.stream).kind == .RParen {
			next_token(p.stream)
			t := new(Tuple_Expr)
			t.elements = make([dynamic]Expr)
			t.span = span_from(p, start)
			return t
		}

		e := parse_expr(p, 0)

		if peek_token(p.stream).kind == .Comma {
			t := new(Tuple_Expr)
			t.elements = make([dynamic]Expr)
			append(&t.elements, e)

			for peek_token(p.stream).kind == .Comma {
				next_token(p.stream)
				if peek_token(p.stream).kind == .RParen {
					break
				}
				append(&t.elements, parse_expr(p, 0))
			}
			expect(p, .RParen)
			t.span = span_from(p, start)
			return t
		}

		expect(p, .RParen)
		return e

	case .Minus:
		rbp := prefix_bp(tok)
		rhs := parse_expr(p, rbp)
		return new_unary(tok, rhs)

	case .Negate:
		rbp := prefix_bp(tok)
		rhs := parse_expr(p, rbp)
		return new_unary(tok, rhs)

	case .If:
		return parse_if_expr(p)

	case .While:
		return parse_while_expr(p)

	case .Match:
		return parse_match_expr(p)

	case .Spawn:
		start := tok.span
		rbp := prefix_bp(tok)
		operand := parse_expr(p, rbp)
		call, ok := operand.(^Call_Expr)
		if !ok {
			report_parse(p, span_from(p, start), "Синтаксическая ошибка: 'запусти' ожидает вызов функции")
			err := new(Error_Expr)
			err.span = span_from(p, start)
			return err
		}
		s := new(Spawn_Expr)
		s.call = call
		s.span = span_from(p, start)
		return s

	case:
		report_parse(p, tok.span, "Синтаксическая ошибка: неожиданный токен '%s' (%v) в начале выражения", tok.data, tok.kind)
		err := new(Error_Expr)
		err.span = tok.span
		return err
	}
	return nil
}

parse_pattern :: proc(p: ^Parser) -> Pattern {
	start := peek_token(p.stream).span
	tok := next_token(p.stream)
	if tok.kind == .Ident {
		if tok.data == "_" {
			w := new(Pattern_Wildcard)
			w.span = span_from(p, start)
			return w
		}
		module_name := ""
		type_name := ""
		name := tok.data
		// Optional qualification: Ident.Ident (Type.Variant) or
		// Ident.Ident.Ident (module.Type.Variant).
		for peek_token(p.stream).kind == .Dot {
			next_token(p.stream)
			next_tok := next_token(p.stream)
			if next_tok.kind != .Ident {
				report_parse(p, next_tok.span, "Синтаксическая ошибка: после '.' в шаблоне ожидался идентификатор")
			}
			if module_name == "" {
				module_name = name
				name = next_tok.data
			} else {
				type_name = name
				name = next_tok.data
			}
		}
		// Одна точка: ещё неизвестно, Type.Variant это или module.Variant —
		// решает resolver. Храним (module_name=first, name=second). Две точки:
		// (module_name=first, type_name=second, name=third).
		if type_name != "" {
			// module.Type.Variant кодируем в Pattern_Constructor, схлопывая
			// module.Type в module_name = "module.Type"; resolver разбирает.
			module_name = fmt.aprintf("%s.%s", module_name, type_name)
		}
		if peek_token(p.stream).kind == .LParen {
			next_token(p.stream)
			pat := new(Pattern_Constructor)
			pat.module_name = module_name
			pat.name = name
			pat.args = make([dynamic]Pattern)
			if peek_token(p.stream).kind == .RParen {
				report_parse(
					p,
					peek_token(p.stream).span,
					"Синтаксическая ошибка: у шаблона-конструктора '%s' пустые скобки",
					name,
				)
			}
			// Именованные поля (`Точка(x: 1, y: _)`) — решается по ПЕРВОМУ
			// аргументу: `Ident Colon` впереди однозначно сигналит именованную
			// форму (ни один валидный позиционный под-шаблон не начинается с
			// голого `идент:`). Смешивать формы в одном шаблоне нельзя.
			is_named :=
				peek_token(p.stream).kind == .Ident &&
				peek_second_token(p.stream).kind == .Colon
			if is_named {
				pat.field_names = make([dynamic]string)
			}
			for {
				if is_named {
					field_tok := next_token(p.stream)
					if field_tok.kind != .Ident {
						report_parse(
							p,
							field_tok.span,
							"Синтаксическая ошибка: ожидалось имя поля перед ':' в именованном шаблоне",
						)
					}
					expect(p, .Colon)
					append(&pat.field_names, field_tok.data)
				} else if peek_token(p.stream).kind == .Ident && peek_second_token(p.stream).kind == .Colon {
					report_parse(
						p,
						peek_token(p.stream).span,
						"Синтаксическая ошибка: нельзя смешивать позиционные и именованные поля в одном шаблоне",
					)
				}
				append(&pat.args, parse_pattern(p))
				if peek_token(p.stream).kind == .Comma {
					next_token(p.stream)
					continue
				}
				break
			}
			expect(p, .RParen)
			pat.span = span_from(p, start)
			return pat
		}
		if module_name != "" {
			pat := new(Pattern_Constructor)
			pat.module_name = module_name
			pat.name = name
			pat.args = make([dynamic]Pattern)
			pat.span = span_from(p, start)
			return pat
		}
		pat := new(Pattern_Ident)
		pat.name = name
		pat.span = span_from(p, start)
		return pat
	}
	if tok.kind == .Number {
		pat := new(Pattern_Literal)
		pat.value = new_int_lit(p, tok)
		pat.span = span_from(p, start)
		return pat
	}
	if tok.kind == .String {
		lit := new(String_Expr)
		lit.value = tok.data
		lit.span = tok.span
		pat := new(Pattern_Literal)
		pat.value = lit
		pat.span = span_from(p, start)
		return pat
	}
	if tok.kind == .Boolean {
		pat := new(Pattern_Literal)
		pat.value = new_boolean_lit(tok)
		pat.span = span_from(p, start)
		return pat
	}
	report_parse(
		p,
		tok.span,
		"Синтаксическая ошибка: такой шаблон в выборе пока не поддерживается: %v",
		tok.kind,
	)
	err := new(Error_Pattern)
	err.span = tok.span
	return err
}

parse_match_expr :: proc(p: ^Parser) -> ^Match_Expr {
	start := last_token_span(p.stream) // .Match уже съеден вызывающим nud()
	m := new(Match_Expr)
	m.arms = make([dynamic]Match_Arm)
	m.subject = parse_expr(p, 0)

	consume_semicolon_or_newline(p)

	for peek_token(p.stream).kind != .End && peek_token(p.stream).kind != .EOF {
		arm_start := peek_token(p.stream).span
		arm := Match_Arm {
			body = make([dynamic]Stmt),
		}
		arm.pattern = parse_pattern(p)
		expect(p, .Arrow)
		// Тело ветки — один statement (ветки в одну строку); `;` после него
		// опционален, следующая ветка начинается со своего Pattern.
		for {
			parse_stmt_into(p, &arm.body)
			if peek_token(p.stream).kind == .Semicolon {
				next_token(p.stream)
			}
			nxt := peek_token(p.stream).kind
			if nxt == .End || nxt == .EOF do break
			break
		}
		arm.span = span_from(p, arm_start)
		append(&m.arms, arm)
	}
	expect(p, .End)

	if len(m.arms) == 0 {
		report_parse(p, span_from(p, start), "Синтаксическая ошибка: выбор должен содержать хотя бы одну ветку")
	}
	m.span = span_from(p, start)
	return m
}

// 70 — между Call/Index (lbp 80) и Star/Slash (lbp 60/61). Postfix
// (`.`/`()`/`[]`) обязан биндиться ТУЖЕ префиксного `-`/`не`, иначе
// `не x.y.z` парсится как `(не x).y.z` вместо `не (x.y.z)`: операнд префикса
// (rbp здесь = min_bp для operand) обрывается на первом же `.`/`(`/`[`, не
// забирая postfix-цепочку внутрь, и она навешивается СНАРУЖИ на готовый
// Unary_Expr в вызывающем цикле.
prefix_bp :: proc(token: ^Token) -> int {
	#partial switch token.kind {
	case .Minus, .Negate:
		return 70
	}
	return 0
}

infix_bp :: proc(tok: ^Token) -> (lbp, rbp: int, ok: bool) {
	#partial switch tok.kind {
	case .Dot:
		return 90, 91, true
	case .Star, .Slash, .Percent:
		return 60, 61, true
	case .Plus, .Minus:
		return 50, 51, true
	case .Less, .Greater, .LessEqual, .GreaterEqual:
		return 40, 41, true
	case .Equal, .NotEqual:
		return 30, 31, true
	case .And:
		return 28, 29, true
	case .Or:
		return 26, 27, true
	case .Assign:
		return 10, 9, true
	case .LParen:
		return 80, 0, true
	case .LBracket:
		return 80, 0, true
	case .Question:
		return 90, 91, true
	}
	return 0, 0, false
}

// --- AST-BUILDER ХЕЛПЕРЫ ДЛЯ DESUGAR ---
//
// `для` (for-in и числовой диапазон) разворачивается на этапе parse в
// обычные узлы AST (While_Expr/If_Expr/...) — см. parse_for_stmt_into и
// parse_for_range_stmt_into. Без этих хелперов каждый узел собирался бы
// вручную (new(X); x.field = ...; на 4-6 строк), и desugar-функции
// раздувались бы пропорционально числу узлов в развёрнутом виде.

mk_ident :: proc(name: string, span: Span) -> Expr {
	e := new(Ident_Expr)
	e.name = intern(name)
	e.span = span
	return e
}

mk_type_ident_int :: proc(span: Span) -> Type_Node {
	t := new(Type_Ident)
	t.name = "Целое"
	t.span = span
	return t
}

mk_num :: proc(v: f64, span: Span) -> Expr {
	e := new(Number_Expr)
	e.value = v
	e.span = span
	return e
}

mk_bool :: proc(v: bool, span: Span) -> Expr {
	e := new(Boolean_Expr)
	e.value = v
	e.span = span
	return e
}

mk_unary :: proc(op: TokenKind, operand: Expr, span: Span) -> Expr {
	e := new(Unary_Expr)
	e.op = op
	e.right = operand
	e.span = span
	return e
}

mk_bin :: proc(op: TokenKind, l: Expr, r: Expr, span: Span) -> Expr {
	e := new(Binary_Expr)
	e.left = l
	e.op = op
	e.right = r
	e.span = span
	return e
}

mk_prop :: proc(obj: Expr, name: string, span: Span) -> Expr {
	e := new(Property_Expr)
	e.object = obj
	e.property = name
	e.span = span
	return e
}

// Только нуль-арные вызовы — единственная форма, нужная desugar'у (.длина()).
mk_call0 :: proc(callee: Expr, span: Span) -> Expr {
	e := new(Call_Expr)
	e.callee = callee
	e.args = make([dynamic]Expr)
	e.span = span
	return e
}

mk_index :: proc(obj: Expr, idx: Expr, span: Span) -> Expr {
	e := new(Index_Expr)
	e.object = obj
	e.index = idx
	e.span = span
	return e
}

mk_expr_stmt :: proc(e: Expr, span: Span) -> Stmt {
	s := new(Expr_Stmt)
	s.expr = e
	s.span = span
	return s
}

mk_let :: proc(name: string, value: Expr, span: Span) -> Stmt {
	s := new(Let_Stmt)
	s.name = name
	s.value = value
	s.span = span
	return s
}

// <name> = <value>
mk_assign :: proc(name: string, value: Expr, span: Span) -> Stmt {
	return mk_expr_stmt(mk_bin(.Assign, mk_ident(name, span), value, span), span)
}

// <name> = <name> + 1
mk_incr :: proc(name: string, span: Span) -> Stmt {
	return mk_assign(name, mk_bin(.Plus, mk_ident(name, span), mk_num(1, span), span), span)
}

// если <cond> тогда прервать конец
mk_if_break :: proc(cond: Expr, span: Span) -> Stmt {
	break_stmt := new(Break_Stmt)
	break_stmt.span = span
	node := new(If_Expr)
	node.condition = cond
	node.then_branch = make([dynamic]Stmt)
	append(&node.then_branch, break_stmt)
	node.else_branch = make([dynamic]Stmt)
	node.span = span
	return mk_expr_stmt(node, span)
}

// прервать (безусловно)
mk_break :: proc(span: Span) -> Stmt {
	s := new(Break_Stmt)
	s.span = span
	return s
}

// пока <cond> цикл <body> конец
mk_while :: proc(cond: Expr, body: [dynamic]Stmt, span: Span) -> Stmt {
	node := new(While_Expr)
	node.condition = cond
	node.body = body
	node.span = span
	return mk_expr_stmt(node, span)
}

// --- УТИЛИТЫ ---

error :: proc(p: ^Parser, format: string, args: ..any) {
	report_parse(p, last_token_span(p.stream), format, ..args)
}

// Собирает span конструкции: start — позиция первого токена (обычно
// peek_token до начала парсинга), end — позиция последнего уже съеденного
// токена (last_token_span). Единая точка, чтобы не дублировать
// file_id-проброс в каждом parse_X.
span_from :: proc(p: ^Parser, start: Span) -> Span {
	end := last_token_span(p.stream)
	return Span{file_id = p.file_id, start = start.start, end = end.end}
}

// span произвольного Expr — нужен в Pratt-парсере, чтобы взять start
// левого операнда до того, как он обрастёт обёртками (Binary/Call/...).
expr_span :: proc(e: Expr) -> Span {
	if e == nil do return Span{}
	switch v in e {
	case ^Number_Expr:
		return v.span
	case ^Boolean_Expr:
		return v.span
	case ^String_Expr:
		return v.span
	case ^Binary_Expr:
		return v.span
	case ^Unary_Expr:
		return v.span
	case ^Ident_Expr:
		return v.span
	case ^Call_Expr:
		return v.span
	case ^While_Expr:
		return v.span
	case ^If_Expr:
		return v.span
	case ^Tuple_Expr:
		return v.span
	case ^Property_Expr:
		return v.span
	case ^Lambda_Expr:
		return v.span
	case ^Array_Expr:
		return v.span
	case ^Map_Expr:
		return v.span
	case ^Index_Expr:
		return v.span
	case ^Try_Expr:
		return v.span
	case ^Match_Expr:
		return v.span
	case ^Error_Expr:
		return v.span
	case ^Spawn_Expr:
		return v.span
	}
	return Span{}
}

expect :: proc(p: ^Parser, expected_kind: TokenKind) {
	tok := next_token(p.stream)
	if tok == nil {
		report_parse(p, last_token_span(p.stream), "Синтаксическая ошибка: ожидалось %v, но обнаружен EOF", expected_kind)
		return
	}
	if tok.kind != expected_kind {
		report_parse(p, tok.span, "Синтаксическая ошибка: ожидалось %v, обнаружен %v", expected_kind, tok.kind)
	}
}

consume_semicolon_or_newline :: proc(p: ^Parser) {
	tok := peek_token(p.stream)
	if tok.kind == .Semicolon {
		next_token(p.stream)
	} else if tok.kind == .EOF || tok.kind == .RParen {
		return
	}
}

new_int_lit :: proc(p: ^Parser, data: ^Token) -> Expr {
	lit := new(Number_Expr)
	value, ok := strconv.parse_f64(data.data)
	if !ok {
		report_parse(p, data.span, "Синтаксическая ошибка: неверный числовой литерал '%s'", data.data)
	}
	lit.value = value
	lit.span = data.span
	return lit
}

new_boolean_lit :: proc(data: ^Token) -> Expr {
	lit := new(Boolean_Expr)
	lit.value = data.data == "истина"
	lit.span = data.span
	return lit
}

// Строковая интерполяция (`"Привет, \(имя)!"`, Swift-style) — лексер уже
// разбил литерал на InterpStringStart/Mid/End токены вокруг встраиваемых
// выражений (см. lexer.odin: interp_paren_depth), здесь всё ДЕСАХАРИВАЕТСЯ
// в обычную `+`-конкатенацию (String_Expr + Call_Expr(встроку, expr) +
// ...) — резолверу/тайпчекеру/компилятору не нужно знать про
// интерполяцию вообще, они видят то же дерево, что дал бы вручную
// написанный `"a" + встроку(x) + "b"`. Каждое встраиваемое значение
// оборачивается в builtin встроку() (BUILTIN_CTORS, type_cheker.odin) —
// та же Печатаемое-конверсия, что использует ввод_вывод.печать, только
// результат — Строка, а не побочный эффект печати.
parse_interp_string :: proc(p: ^Parser, start_tok: ^Token) -> Expr {
	result: Expr

	if start_tok.data != "" {
		lit := new(String_Expr)
		lit.value = start_tok.data
		lit.span = start_tok.span
		result = lit
	}

	for {
		embedded := parse_expr(p, 0)

		name_tok := Token{kind = .Ident, data = "встроку", span = expr_span(embedded)}
		callee := new_ident(&name_tok)
		call := new(Call_Expr)
		call.callee = callee
		call.args = make([dynamic]Expr)
		append(&call.args, embedded)
		call.span = expr_span(embedded)

		if result == nil {
			result = call
		} else {
			result = new_bin_op(.Plus, result, call, expr_span(result))
		}

		next := next_token(p.stream)
		#partial switch next.kind {
		case .InterpStringMid:
			if next.data != "" {
				lit := new(String_Expr)
				lit.value = next.data
				lit.span = next.span
				result = new_bin_op(.Plus, result, lit, expr_span(result))
			}
			continue
		case .InterpStringEnd:
			if next.data != "" {
				lit := new(String_Expr)
				lit.value = next.data
				lit.span = next.span
				result = new_bin_op(.Plus, result, lit, expr_span(result))
			}
			return result
		case:
			report_parse(
				p,
				next.span,
				"Синтаксическая ошибка: ожидалось продолжение строковой интерполяции, получено %v",
				next.kind,
			)
			return result
		}
	}
}

new_bin_op :: proc(kind: TokenKind, left: Expr, right: Expr, start: Span) -> Expr {
	b := new(Binary_Expr)
	b.left = left
	b.op = kind
	b.right = right
	b.span = Span{file_id = start.file_id, start = start.start, end = expr_span(right).end}
	return b
}

new_unary :: proc(token: ^Token, rhs: Expr) -> Expr {
	lit := new(Unary_Expr)
	lit.op = token.kind
	lit.right = rhs
	lit.span = Span {
		file_id = token.span.file_id,
		start   = token.span.start,
		end     = expr_span(rhs).end,
	}
	return lit
}

new_ident :: proc(tok: ^Token) -> Expr {
	node := new(Ident_Expr)
	node.name = intern(tok.data)
	node.span = tok.span
	return node
}
