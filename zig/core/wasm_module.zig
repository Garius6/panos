const std = @import("std");
const type_checker = @import("type_checker.zig");
const types = @import("types.zig");

// Ported from `core/wasm_module.odin` — binary encoding primitives (LEB128,
// WASM value types) and section assembly. Phase 1 value-type convention,
// same as Odin: Число/Целое → f64, Булево → i32 (Строка/структуры/etc.
// would need an object-table runtime — out of `mir_lowering.zig`'s current
// scope, so not needed here yet either).

pub const wasm_f64: u8 = 0x7C;
pub const wasm_i32: u8 = 0x7F;

pub fn wasmValType(checked: *const type_checker.CheckResult, type_id: types.TypeId) u8 {
    if (checked.types.eql(type_id, checked.types.builtins.boolean)) return wasm_i32;
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

// A section is `id byte, uleb128(content.len), content` — built by the
// caller into a plain byte buffer, wrapped here.
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
