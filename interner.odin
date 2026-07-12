package main

import "base:runtime"
import "core:strings"
import "core:sync"

// Интернирование строк для идентификаторов (Ident_Expr.name, Symbol.name/
// full_name). Дедупликация + сравнение имён через целое вместо string ==
// (посимвольного сравнения). Не трогает Type.name/Struct_Field.name/
// Property_Expr.property и т.п. — те остаются string (см. решение по
// Стадии 2: interning только identifiers из parser/resolver, не
// display-строки типов).
Interned :: distinct u32

String_Interner :: struct {
	table: map[string]Interned,
	names: [dynamic]string,
}

INTERNER: String_Interner
// e2e_test.odin гоняет тесты в 10 потоков (ODIN_TEST_THREADS), и INTERNER —
// общий на весь процесс синглтон. Без мьютекса конкурентные intern()
// ломают map/dynamic array (гонка на append/insert) — вылезало как
// "undefined variable" для реально объявленных имён и segfault'ы.
INTERNER_MUTEX: sync.Mutex

// Индекс 0 всегда зарезервирован под "" — так zero-value Interned{}
// (получается из new(Symbol) без явного name) однозначно значит "не
// задано", как раньше значило string("").
//
// context.allocator пином на runtime.heap_allocator(), и каждая строка
// клонируется перед сохранением: INTERNER — глобальный синглтон, живущий
// дольше любого одного вызова, а входной `s` часто приходит из
// temp_allocator (fmt.tprintf) или из чужого tracking-контекста (e2e-тест).
// Без клонирования и стабильного allocator'а — двойная порча памяти:
// (1) append()-реаллокация массива, вызванная ПОЗЖЕ из другого теста с
// другим tracking-контекстом, пытается free() буфер через чужой allocator
// ("bad free"); (2) даже при стабильном allocator'е массива, сырые байты
// `s` могли уже быть освобождены владельцем temp_allocator'а к моменту
// чтения через resolve_interned().
intern :: proc(s: string) -> Interned {
	sync.mutex_lock(&INTERNER_MUTEX)
	defer sync.mutex_unlock(&INTERNER_MUTEX)
	context.allocator = runtime.heap_allocator()
	if INTERNER.table == nil {
		INTERNER.table = make(map[string]Interned)
		INTERNER.names = make([dynamic]string)
		empty := strings.clone("")
		append(&INTERNER.names, empty)
		INTERNER.table[empty] = Interned(0)
	}
	if id, ok := INTERNER.table[s]; ok do return id
	durable := strings.clone(s)
	id := Interned(len(INTERNER.names))
	append(&INTERNER.names, durable)
	INTERNER.table[durable] = id
	return id
}

// Обратное преобразование — нужно везде, где Interned печатается в
// diagnostic-сообщении (%s ожидает string, не число). Тот же мьютек, что и
// intern(): resolve_interned() может читать INTERNER.names, пока другой
// поток резервирует память под append() в intern().
resolve_interned :: proc(id: Interned) -> string {
	sync.mutex_lock(&INTERNER_MUTEX)
	defer sync.mutex_unlock(&INTERNER_MUTEX)
	return INTERNER.names[int(id)]
}
