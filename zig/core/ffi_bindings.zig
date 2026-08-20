// Написанные вручную биндинги libffi, использует те же вендоренные
// прекомпилированные архивы `external/libffi/`. Задействуется только из
// обработки вызовов `внешний` в `vm.zig` — никогда не линкуется в сборку
// браузера wasm32-freestanding (см. `build.zig`: архив подключается только
// к нативным `Compile`-шагам).

const builtin = @import("builtin");
const std = @import("std");
const ast = @import("ast.zig");

// Раскладка соответствует `ffi_type` на поддерживаемых 64-битных платформах:
// size_t -> usize, unsigned short -> u16, struct _ffi_type** -> ?[*]?*FfiType.
pub const FfiType = extern struct {
    size: usize,
    alignment: u16,
    type: u16,
    elements: ?[*]?*FfiType,
};

// Базовая раскладка `ffi_cif`:
//   ffi_abi abi; unsigned nargs; ffi_type **arg_types; ffi_type *rtype;
//   unsigned bytes; unsigned flags; FFI_EXTRA_CIF_FIELDS;
// На Apple AArch64 FFI_EXTRA_CIF_FIELDS раскрывается в одно дополнительное
// поле (`aarch64_nfixedargs`); Linux/Windows x86-64 в вендоренной здесь
// конфигурации ничего не добавляют.
pub const FfiCif = if (builtin.target.os.tag == .macos and builtin.target.cpu.arch == .aarch64)
    extern struct {
        abi: i32,
        nargs: u32,
        arg_types: ?[*]?*FfiType,
        rtype: ?*FfiType,
        bytes: u32,
        flags: u32,
        aarch64_nfixedargs: u32 = 0,
    }
else
    extern struct {
        abi: i32,
        nargs: u32,
        arg_types: ?[*]?*FfiType,
        rtype: ?*FfiType,
        bytes: u32,
        flags: u32,
    };

pub const FFI_OK: i32 = 0;
pub const FFI_TYPE_STRUCT: u16 = 13;

pub extern "c" var ffi_type_void: FfiType;
pub extern "c" var ffi_type_uint8: FfiType;
pub extern "c" var ffi_type_sint32: FfiType;
pub extern "c" var ffi_type_sint64: FfiType;
pub extern "c" var ffi_type_float: FfiType;
pub extern "c" var ffi_type_double: FfiType;
pub extern "c" var ffi_type_pointer: FfiType;

// Экспортируется вендоренной здесь libffi 3.7.1 — используется вместо
// жёсткого выбора FFI_SYSV/FFI_UNIX64/платформозависимого значения на Windows.
pub extern "c" fn ffi_get_default_abi() u32;
pub extern "c" fn ffi_prep_cif(cif: *FfiCif, abi: i32, nargs: u32, rtype: ?*FfiType, atypes: ?[*]?*FfiType) i32;
pub extern "c" fn ffi_call(cif: *FfiCif, function: ?*anyopaque, rvalue: ?*anyopaque, avalue: ?[*]?*anyopaque) void;
pub extern "c" fn ffi_get_struct_offsets(abi: i32, struct_type: *FfiType, offsets: [*]usize) i32;

pub fn defaultAbi() i32 {
    return @intCast(ffi_get_default_abi());
}

// `ast.ForeignMarshalKind` -> `*FfiType`. Для `.struct_value` нужен
// СОБСТВЕННЫЙ `FfiType` на каждую структуру (строится ниже в
// `buildStructFfiType` из раскладки полей `ff_структура`) — вызывающий код
// обязан построить его отдельно и никогда не должен попадать сюда с
// `.struct_value`.
pub fn ffiTypeForMarshal(marshal: anytype) *FfiType {
    return switch (marshal) {
        .void => &ffi_type_void,
        .int8 => &ffi_type_uint8,
        .int32 => &ffi_type_sint32,
        .int64 => &ffi_type_sint64,
        .float32 => &ffi_type_float,
        .float64 => &ffi_type_double,
        .c_string, .pointer => &ffi_type_pointer,
        .struct_value => unreachable,
    };
}

// Строит libffi-структуру `ffi_type`, описывающую раскладку полей
// `ff_структура` (`fields` в порядке объявления — каждое поле является
// плоским скаляром, это обеспечивает `parseFfiStructDeclaration` в
// `parser.zig` на этапе разбора, поэтому `ffiTypeForMarshal` здесь никогда
// не попадает в свой собственный кейс `.struct_value` при заполнении
// `elements`). `size`/`alignment` намеренно оставлены равными `0` — libffi
// вычисляет и заполняет их сама во время `ffi_prep_cif`, как только этот
// тип оказывается указан в массиве типов аргументов/возврата; чтение этих
// полей до такого вызова вернёт мусор, а не реальные значения.
pub fn buildStructFfiType(allocator: std.mem.Allocator, fields: []const ast.ForeignMarshalKind) !*FfiType {
    const elements = try allocator.alloc(?*FfiType, fields.len + 1);
    for (fields, elements[0..fields.len]) |field, *slot| slot.* = ffiTypeForMarshal(field);
    elements[fields.len] = null;
    const struct_type = try allocator.create(FfiType);
    struct_type.* = .{ .size = 0, .alignment = 0, .type = FFI_TYPE_STRUCT, .elements = elements.ptr };
    return struct_type;
}
