#+build !js
package core

import "core:fmt"

// Статические архивы libffi собираются заранее для каждой платформы
// и хранятся в external/libffi/lib.
//
// Путь считается относительно этого файла, то есть относительно core/.
when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	foreign import libffi "../external/libffi/lib/darwin-arm64/libffi.a"
} else when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	foreign import libffi "../external/libffi/lib/linux-amd64/libffi.a"
} else when ODIN_OS == .Windows && ODIN_ARCH == .amd64 {
	foreign import libffi "../external/libffi/lib/windows-amd64/libffi.lib"
} else {
	#panic("libffi: неподдерживаемая платформа")
}

// Соответствует ffi_type.
//
// Layout одинаков для поддерживаемых 64-битных платформ:
// size_t                 -> uint
// unsigned short         -> u16
// struct _ffi_type **    -> ^^Ffi_Type
Ffi_Type :: struct {
	size:      uint,
	alignment: u16,
	type:      u16,
	elements:  ^^Ffi_Type,
}

// Базовая часть ffi_cif:
//
// typedef struct {
//     ffi_abi abi;
//     unsigned nargs;
//     ffi_type **arg_types;
//     ffi_type *rtype;
//     unsigned bytes;
//     unsigned flags;
//     FFI_EXTRA_CIF_FIELDS;
// } ffi_cif;
//
// На Apple AArch64 FFI_EXTRA_CIF_FIELDS разворачивается в:
//
//     unsigned aarch64_nfixedargs;
//
// На Linux x86-64 и Windows x86-64 дополнительного поля для
// используемой конфигурации нет.
when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	Ffi_Cif :: struct {
		abi:                i32,
		nargs:              u32,
		arg_types:          ^^Ffi_Type,
		rtype:              ^Ffi_Type,
		bytes:              u32,
		flags:              u32,
		aarch64_nfixedargs: u32,
	}
} else {
	Ffi_Cif :: struct {
		abi:       i32,
		nargs:     u32,
		arg_types: ^^Ffi_Type,
		rtype:     ^Ffi_Type,
		bytes:     u32,
		flags:     u32,
	}
}

FFI_OK :: i32(0)

FFI_TYPE_STRUCT :: u16(13)

@(default_calling_convention = "c")
foreign libffi {
	ffi_type_void: Ffi_Type
	ffi_type_uint8: Ffi_Type
	ffi_type_sint32: Ffi_Type
	ffi_type_sint64: Ffi_Type
	ffi_type_float: Ffi_Type
	ffi_type_double: Ffi_Type
	ffi_type_pointer: Ffi_Type

	// libffi 3.7.1 экспортирует эту функцию.
	//
	// Используем её вместо хардкода:
	// - Darwin AArch64: FFI_SYSV;
	// - Linux AMD64: FFI_UNIX64;
	// - Windows AMD64: ABI зависит от конфигурации сборки libffi.
	ffi_get_default_abi :: proc() -> u32 ---

	ffi_prep_cif :: proc(cif: ^Ffi_Cif, abi: i32, nargs: u32, rtype: ^Ffi_Type, atypes: ^^Ffi_Type) -> i32 ---

	ffi_call :: proc(cif: ^Ffi_Cif, fn: rawptr, rvalue: rawptr, avalue: ^rawptr) ---

	ffi_get_struct_offsets :: proc(abi: i32, struct_type: ^Ffi_Type, offsets: ^uint) -> i32 ---
}

// Единственное место, где default ABI преобразуется к типу,
// используемому Odin-биндингом.
ffi_default_abi :: #force_inline proc() -> i32 {
	return i32(ffi_get_default_abi())
}

// Foreign_Marshal_Kind -> ffi_type.
ffi_type_for_marshal :: proc(marshal: Foreign_Marshal_Kind) -> ^Ffi_Type {
	switch marshal {
	case .Void:
		return &ffi_type_void

	case .Int8:
		return &ffi_type_uint8

	case .Int32:
		return &ffi_type_sint32

	case .Int64:
		return &ffi_type_sint64

	case .Float32:
		return &ffi_type_float

	case .Float64:
		return &ffi_type_double

	case .CString, .Pointer:
		return &ffi_type_pointer

	case .Struct:
		fmt.panicf("Compiler Error: ffi_type_for_marshal вызван для .Struct")
	}

	return &ffi_type_sint32
}
