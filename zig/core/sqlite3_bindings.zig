// Hand-written extern declarations for the small subset of the SQLite C
// API this VM needs — mirrors Odin's `core/sqlite3_bindings.odin` (same
// vendored `external/sqlite3/` amalgamation, same "only bind what's used"
// scope). Only ever referenced from `vm.zig`'s native (non-freestanding)
// `бд.*` branches — never linked into the wasm32-freestanding browser
// build (see `build.zig`: the static library this links against is only
// attached to native-target `Compile` steps).

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

// `(void(*)(void*))-1` — SQLite's own "copy this string immediately, the
// caller does not need to keep the pointer alive" sentinel. Passed by
// value (a function pointer with this exact bit pattern, never actually
// called), not a real callback.
// Declared as a bare `?*anyopaque` rather than the C signature's real
// `void(*)(void*)` — same pointer-sized ABI representation either way,
// and this value is never actually called through (SQLite special-cases
// the exact bit pattern `-1` to mean "copy the string now", it does not
// dereference it) — sidesteps `*const fn(...)`'s stricter alignment
// requirements, which reject a comptime `@ptrFromInt` of an all-ones
// address outright.
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
