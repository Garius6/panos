// Hand-written libffi bindings — mirrors Odin's `core/ffi_bindings.odin`
// (same vendored `external/libffi/` prebuilt archives, same struct
// layouts, same tiny C API surface). Only ever referenced from `vm.zig`'s
// `внешний` call handling — never linked into the wasm32-freestanding
// browser build (see `build.zig`: the archive is only attached to
// native-target `Compile` steps).

const builtin = @import("builtin");

// Layout matches `ffi_type` on the supported 64-bit platforms:
// size_t -> usize, unsigned short -> u16, struct _ffi_type** -> ?[*]?*FfiType.
pub const FfiType = extern struct {
    size: usize,
    alignment: u16,
    type: u16,
    elements: ?[*]?*FfiType,
};

// Base `ffi_cif` layout:
//   ffi_abi abi; unsigned nargs; ffi_type **arg_types; ffi_type *rtype;
//   unsigned bytes; unsigned flags; FFI_EXTRA_CIF_FIELDS;
// On Apple AArch64, FFI_EXTRA_CIF_FIELDS expands to one extra field
// (`aarch64_nfixedargs`); Linux/Windows x86-64 add nothing for the
// configuration vendored here.
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

// libffi 3.7.1 (vendored here) exports this — used instead of hardcoding
// FFI_SYSV/FFI_UNIX64/platform-dependent-on-Windows.
pub extern "c" fn ffi_get_default_abi() u32;
pub extern "c" fn ffi_prep_cif(cif: *FfiCif, abi: i32, nargs: u32, rtype: ?*FfiType, atypes: ?[*]?*FfiType) i32;
pub extern "c" fn ffi_call(cif: *FfiCif, function: ?*anyopaque, rvalue: ?*anyopaque, avalue: ?[*]?*anyopaque) void;
pub extern "c" fn ffi_get_struct_offsets(abi: i32, struct_type: *FfiType, offsets: [*]usize) i32;

pub fn defaultAbi() i32 {
    return @intCast(ffi_get_default_abi());
}

// `ast.ForeignMarshalKind` -> `*FfiType`. `.struct_value` is unsupported
// in this Zig port (see `vm.zig`'s foreign-call handling) — callers must
// reject it before reaching here, same as Odin's `fmt.panicf` guard for
// the same case.
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
