const std = @import("std");
const type_checker = @import("type_checker.zig");
const types = @import("types.zig");

// Примитивы бинарного кодирования (LEB128, типы значений WASM) и сборка
// секций. Соглашение о типах значений: Число/Целое → f64, Булево → i32
// (Строка/структуры/т.п. требуют object-table рантайма — вне текущей
// области `mir_lowering.zig`).

pub const wasm_f64: u8 = 0x7C;
pub const wasm_i32: u8 = 0x7F;

pub fn wasmValType(checked: *const type_checker.CheckResult, type_id: types.TypeId) u8 {
    return wasmValTypeForStore(&checked.types, type_id);
}

pub fn wasmValTypeForStore(store: *const types.TypeStore, type_id: types.TypeId) u8 {
    if (store.eql(type_id, store.builtins.boolean)) return wasm_i32;
    // Строки и именованные агрегатные значения — непрозрачные i32-хендлы,
    // которыми владеет JS AOT-рантайм. Все именованные значения используют
    // одно и то же представление.
    if (store.eql(type_id, store.builtins.string)) return wasm_i32;
    // `Ошибка` — `.primitive{.error_value}` (не `.nominal`, см.
    // `types.zig`), физически тот же 2-полевой аггрегат-хэндл, что и
    // обычная структура (`.new_aggregate` в `lowerErrorConstructor`,
    // `mir_lowering.zig`) — реальный найденный баг: без этой ветки
    // `store.get(type_id)`'s switch ниже её не ловил вообще (`.primitive`
    // там не перечислен), она молча проваливалась в дефолтный `wasm_f64`
    // — любой код, читающий/пишущий значение типа `Ошибка` как локаль/
    // поле/аргумент через `wasmValTypeForStore`, путал i32-хэндл с f64.
    if (store.eql(type_id, store.builtins.error_value)) return wasm_i32;
    if (store.get(type_id)) |entry| switch (entry.*) {
        // Функции первого класса — непрозрачные i32-индексы в WASM-таблице
        // (см. `.function_ref` в `wasm_interfaces.zig`) — та же категория
        // "непрозрачный i32-хендл", что и nominal/array/process.
        // Кортеж — та же "непрозрачный i32-хендл" категория, что именованная
        // структура (`.nominal`) — физически один и тот же `.aggregate` в
        // байткод-VM, `type_name` пустой у кортежа, только и всего.
        // `Соответствие` — свой отдельный i32-хендл рантайм (`wasm_maps.zig`).
        .nominal, .array, .process, .function, .tuple, .map => return wasm_i32,
        // Голый неразрешённый параметр generic-типа (`T` без конкретной
        // подстановки на этом этапе) — дженерики панос принципиально
        // никогда не мономорфизируются (см. доккомментарии
        // `type_checker.zig`), поэтому значение такого типа можно
        // безопасно трогать только через interface-bound (диспетчеризуется
        // через ТОТ ЖЕ boxed-i32 vtable-механизм, что и любое другое
        // interface-значение — `registerGenericInterfaceCasts`/
        // `inferGenericBoundInterfaceCall` приводят аргумент к этому
        // bound-интерфейсу в точке вызова, не здесь) — та же логика
        // "безопасного значения по умолчанию", что и в случае
        // `.poison`/`.unconstrained` ниже.
        .generic_parameter => return wasm_i32,
        // Достижение кодогенерации значением `poison`/`unconstrained`
        // означает одну конкретную вещь, а не "тайпчекер сдался в общем
        // случае": обработка `получить()` в `type_checker.zig` (~строка
        // 4146) остаётся poison, если охватывающая функция не объявляет
        // `-> Сообщение(T)` — реальное отдельное ограничение, которое
        // никогда не выводится из сужения match-веток для гораздо более
        // распространённой идиомы actor `-> Пусто` (пример `счётчик` в
        // `docs/processes.md`). Любое ДРУГОЕ poison-значение означало бы,
        // что реальная ошибка типов уже была зафиксирована, что
        // останавливает компиляцию раньше, чем эта функция вообще
        // вызывается — поэтому такое значение по умолчанию безопасно
        // специализировать: полученное сообщение чаще потребляется через
        // `match_tag`/`get_variant_field` (всегда i32-хендл варианта), чем
        // как сырое `Число`.
        .poison, .unconstrained => return wasm_i32,
        else => {},
    };
    return wasm_f64;
}

pub fn writeUleb128(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var v = value;
    while (true) {
        var byte: u8 = @intCast(v & 0x7F);
        v >>= 7;
        if (v != 0) byte |= 0x80;
        try out.append(allocator, byte);
        if (v == 0) break;
    }
}

pub fn writeSleb128(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i64) !void {
    var v = value;
    var more = true;
    while (more) {
        var byte: u8 = @intCast(v & 0x7F);
        v >>= 7;
        if ((v == 0 and byte & 0x40 == 0) or (v == -1 and byte & 0x40 != 0)) {
            more = false;
        } else {
            byte |= 0x80;
        }
        try out.append(allocator, byte);
    }
}

pub fn writeF64Le(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: f64) !void {
    var buffer: [8]u8 = undefined;
    std.mem.writeInt(u64, &buffer, @bitCast(value), .little);
    try out.appendSlice(allocator, &buffer);
}

// Секция — это `id byte, uleb128(content.len), content`: вызывающая сторона
// собирает содержимое в обычный байтовый буфер, здесь оно оборачивается.
pub fn writeSection(out: *std.ArrayList(u8), allocator: std.mem.Allocator, section_id: u8, content: []const u8) !void {
    try out.append(allocator, section_id);
    try writeUleb128(out, allocator, @intCast(content.len));
    try out.appendSlice(allocator, content);
}

pub const magic_and_version = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };

test "writeUleb128/writeSleb128 round-trip small and boundary values" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try writeUleb128(&out, allocator, 0);
    try writeUleb128(&out, allocator, 127);
    try writeUleb128(&out, allocator, 128);
    try writeUleb128(&out, allocator, 300);
    // 0, 127, 128 (0x80 0x01), 300 (0xAC 0x02)
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x7F, 0x80, 0x01, 0xAC, 0x02 }, out.items);

    var signed_out: std.ArrayList(u8) = .empty;
    defer signed_out.deinit(allocator);
    try writeSleb128(&signed_out, allocator, -1);
    try writeSleb128(&signed_out, allocator, 63);
    try writeSleb128(&signed_out, allocator, -64);
    // -1 -> 0x7F, 63 -> 0x3F, -64 -> 0x40
    try std.testing.expectEqualSlices(u8, &.{ 0x7F, 0x3F, 0x40 }, signed_out.items);
}

test "writeF64Le writes IEEE-754 little-endian bytes" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try writeF64Le(&out, allocator, 1.0);
    // 1.0 as f64 LE: 00 00 00 00 00 00 F0 3F
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F }, out.items);
}
