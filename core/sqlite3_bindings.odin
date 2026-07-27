#+build !js
package core

// Статические архивы libsqlite3 собираются заранее для каждой платформы
// и хранятся в external/sqlite3/lib — тот же приём, что core/ffi_bindings.
// odin для libffi (см. .github/workflows/vendor-libffi.yml,
// .github/workflows/vendor-sqlite.yml — аналогичная сборка, но без
// autotools: sqlite3.c — единый портируемый amalgamation-файл).
//
// Путь считается относительно этого файла, то есть относительно core/.
when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	foreign import sqlite3lib "../external/sqlite3/lib/darwin-arm64/libsqlite3.a"
} else when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	foreign import sqlite3lib "../external/sqlite3/lib/linux-amd64/libsqlite3.a"
} else when ODIN_OS == .Windows && ODIN_ARCH == .amd64 {
	foreign import sqlite3lib "../external/sqlite3/lib/windows-amd64/libsqlite3.lib"
} else {
	#panic("libsqlite3: неподдерживаемая платформа")
}

// Непрозрачные C-типы — используются только через указатель, полей не
// читаем никогда (тело определено в sqlite3.c, здесь не нужно).
sqlite3 :: struct {}
sqlite3_stmt :: struct {}

SQLITE_OK :: i32(0)
SQLITE_ROW :: i32(100)
SQLITE_DONE :: i32(101)

// sqlite3_open_v2 flags — путь всегда открывается на чтение+запись,
// создавая файл при отсутствии (единственный режим, который нужен
// core/vm_sql_native.odin::call_builtin_sql — сужение решений вроде
// "открыть только на чтение" оставлено на будущее, не запрошено).
SQLITE_OPEN_READWRITE :: i32(0x00000002)
SQLITE_OPEN_CREATE :: i32(0x00000004)

// sqlite3_column_type() — соответствует одному из пяти "storage classes".
SQLITE_INTEGER :: i32(1)
SQLITE_FLOAT :: i32(2)
SQLITE_TEXT :: i32(3)
SQLITE_BLOB :: i32(4)
SQLITE_NULL :: i32(5)

// sqlite3_bind_text деструктор-параметр: -1 как function-pointer — общий
// C-приём (SQLITE_TRANSIENT), просит SQLite скопировать переданные байты
// сразу же, а не полагаться на то, что вызывающий сохранит буфер живым
// до следующего шага — обязателен здесь, т.к. panos-строка, из которой
// берётся cstring, освобождается сразу после вызова bind (см.
// vm_sql_native.odin).
SQLITE_TRANSIENT :: rawptr(~uintptr(0))

@(default_calling_convention = "c")
foreign sqlite3lib {
	sqlite3_open_v2 :: proc(filename: cstring, ppDb: ^^sqlite3, flags: i32, zVfs: cstring) -> i32 ---
	sqlite3_close_v2 :: proc(db: ^sqlite3) -> i32 ---
	sqlite3_errmsg :: proc(db: ^sqlite3) -> cstring ---

	sqlite3_prepare_v2 :: proc(db: ^sqlite3, zSql: cstring, nByte: i32, ppStmt: ^^sqlite3_stmt, pzTail: ^cstring) -> i32 ---
	sqlite3_finalize :: proc(stmt: ^sqlite3_stmt) -> i32 ---
	sqlite3_step :: proc(stmt: ^sqlite3_stmt) -> i32 ---
	sqlite3_changes :: proc(db: ^sqlite3) -> i32 ---

	sqlite3_bind_text :: proc(stmt: ^sqlite3_stmt, idx: i32, text: cstring, nByte: i32, destructor: rawptr) -> i32 ---
	sqlite3_bind_null :: proc(stmt: ^sqlite3_stmt, idx: i32) -> i32 ---

	sqlite3_column_count :: proc(stmt: ^sqlite3_stmt) -> i32 ---
	sqlite3_column_name :: proc(stmt: ^sqlite3_stmt, iCol: i32) -> cstring ---
	sqlite3_column_type :: proc(stmt: ^sqlite3_stmt, iCol: i32) -> i32 ---
	sqlite3_column_text :: proc(stmt: ^sqlite3_stmt, iCol: i32) -> [^]u8 ---
	sqlite3_column_bytes :: proc(stmt: ^sqlite3_stmt, iCol: i32) -> i32 ---
}
