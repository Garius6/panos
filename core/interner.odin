package core

import "base:runtime"
import "core:strings"
import "core:sync"

// Интернирование строк для идентификаторов (Ident_Expr.name, Symbol.name/
// full_name). Дедупликация + сравнение имён через целое вместо string ==.
// Не трогает Type.name/Struct_Field.name/Property_Expr.property и т.п. — те
// остаются string (интернируются только identifiers из parser/resolver, не
// display-строки типов).
Interned :: distinct u32

String_Interner :: struct {
	table: map[string]Interned,
	names: [dynamic]string,
}

INTERNER: String_Interner
// INTERNER — общий на весь процесс синглтон, а тесты гоняются в несколько
// потоков (ODIN_TEST_THREADS). Без мьютекса конкурентные intern() ломают
// map/dynamic array (гонка на append/insert).
INTERNER_MUTEX: sync.Mutex

// Индекс 0 зарезервирован под "" — так zero-value Interned{} (из new(Symbol)
// без явного name) однозначно значит "не задано".
//
// context.allocator пином на heap_allocator, и каждая строка клонируется
// перед сохранением: INTERNER живёт дольше любого одного вызова, а входной
// `s` часто приходит из temp_allocator (fmt.tprintf) или из чужого
// tracking-контекста теста. Без клонирования и стабильного allocator'а —
// порча памяти: (1) append()-реаллокация массива, вызванная позже из другого
// теста, пытается free() буфер через чужой allocator ("bad free"); (2) сырые
// байты `s` могли быть уже освобождены владельцем temp_allocator'а к моменту
// чтения через resolve_interned().
intern :: proc(s: string) -> Interned {
	sync.mutex_lock(&INTERNER_MUTEX)
	defer sync.mutex_unlock(&INTERNER_MUTEX)
	context.allocator = vm_heap_allocator()
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
