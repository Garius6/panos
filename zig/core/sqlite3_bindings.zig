// Рукописные extern-декларации небольшого подмножества SQLite C API,
// нужного этой VM (только то, что реально используется). Используются
// только из нативных (non-freestanding) веток `бд.*` в `vm.zig` — никогда
// не линкуются в wasm32-freestanding браузерную сборку (см. `build.zig`:
// статическая библиотека, к которой линкуется этот файл, подключена
// только к нативным `Compile`-шагам).

const std = @import("std");

pub const sqlite3 = opaque {};
pub const sqlite3_stmt = opaque {};

pub const SQLITE_OK: c_int = 0;
pub const SQLITE_ROW: c_int = 100;
pub const SQLITE_DONE: c_int = 101;

pub const SQLITE_OPEN_READWRITE: c_int = 0x00000002;
pub const SQLITE_OPEN_CREATE: c_int = 0x00000004;

pub const SQLITE_INTEGER: c_int = 1;
pub const SQLITE_FLOAT: c_int = 2;
pub const SQLITE_TEXT: c_int = 3;
pub const SQLITE_BLOB: c_int = 4;
pub const SQLITE_NULL: c_int = 5;

// `(void(*)(void*))-1` — собственный сентинел SQLite: "скопировать строку
// немедленно, вызывающему не нужно удерживать указатель живым". Передаётся
// по значению (указатель на функцию с этим конкретным битовым паттерном,
// никогда реально не вызывается), а не настоящий колбэк.
// Объявлен как простой `?*anyopaque`, а не реальная C-сигнатура
// `void(*)(void*)` — представление в ABI по размеру указателя одинаковое
// в обоих случаях, а значение никогда не вызывается напрямую (SQLite
// специально распознаёт битовый паттерн `-1` как "скопировать строку
// сейчас", не разыменовывая его) — это обходит более строгие требования
// выравнивания `*const fn(...)`, которые отклоняют comptime `@ptrFromInt`
// от адреса из одних единиц.
pub const SQLITE_TRANSIENT: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));

pub extern "c" fn sqlite3_open_v2(filename: [*:0]const u8, ppDb: *?*sqlite3, flags: c_int, zVfs: ?[*:0]const u8) c_int;
pub extern "c" fn sqlite3_close_v2(db: ?*sqlite3) c_int;
pub extern "c" fn sqlite3_errmsg(db: ?*sqlite3) ?[*:0]const u8;
pub extern "c" fn sqlite3_prepare_v2(db: ?*sqlite3, zSql: [*]const u8, nByte: c_int, ppStmt: *?*sqlite3_stmt, pzTail: ?*?[*]const u8) c_int;
pub extern "c" fn sqlite3_bind_text(stmt: ?*sqlite3_stmt, index: c_int, text: [*:0]const u8, n: c_int, destructor: ?*anyopaque) c_int;
pub extern "c" fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;
pub extern "c" fn sqlite3_column_count(stmt: ?*sqlite3_stmt) c_int;
pub extern "c" fn sqlite3_column_name(stmt: ?*sqlite3_stmt, column: c_int) ?[*:0]const u8;
pub extern "c" fn sqlite3_column_type(stmt: ?*sqlite3_stmt, column: c_int) c_int;
pub extern "c" fn sqlite3_column_text(stmt: ?*sqlite3_stmt, column: c_int) ?[*:0]const u8;
pub extern "c" fn sqlite3_column_bytes(stmt: ?*sqlite3_stmt, column: c_int) c_int;
pub extern "c" fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
pub extern "c" fn sqlite3_changes(db: ?*sqlite3) c_int;
