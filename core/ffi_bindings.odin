#+build !js
package core

// Стадия 47 (FFI-B, первый срез): Odin-перевод нужного подмножества
// ffi.h из вендоренного external/libffi/ (см. README.md там). Layout
// Ffi_Type/Ffi_Cif и сигнатуры ffi_prep_cif/ffi_call сверены с
// сгенерированным external/libffi/include/darwin-arm64-ffi.h и
// подтверждены живым сквозным вызовом (dynlib.load_library("libc.dylib")
// + ffi_prep_cif + ffi_call на getpid) ДО написания этого файла — не
// предположение, а проверенный факт для ЭТОЙ платформы (darwin-arm64,
// abi = 1 = FFI_DEFAULT_ABI).
//
// Путь к .a пока захардкожен на единственную собранную платформу — когда
// появятся другие (linux-amd64 и т.п.), потребуется #+build-развилка по
// ODIN_OS/ODIN_ARCH (отдельная задача, см. external/libffi/README.md).
foreign import libffi "../external/libffi/lib/darwin-arm64/libffi.a"

Ffi_Type :: struct {
	size:      uint,
	alignment: u16,
	type:      u16,
	elements:  ^^Ffi_Type,
}

Ffi_Cif :: struct {
	abi:       i32,
	nargs:     u32,
	arg_types: ^^Ffi_Type,
	rtype:     ^Ffi_Type,
	bytes:     u32,
	flags:     u32,
}

FFI_DEFAULT_ABI :: i32(1)
FFI_OK :: i32(0)

@(default_calling_convention = "c")
foreign libffi {
	ffi_type_sint32: Ffi_Type
	ffi_type_sint64: Ffi_Type

	ffi_prep_cif :: proc(cif: ^Ffi_Cif, abi: i32, nargs: u32, rtype: ^Ffi_Type, atypes: ^^Ffi_Type) -> i32 ---
	ffi_call :: proc(cif: ^Ffi_Cif, fn: rawptr, rvalue: rawptr, avalue: ^rawptr) ---
}

// Целое(N) -> дескриптор типа libffi. Только 32/64 в первом срезе (см.
// parse_foreign_int_width, parser.odin) — других веток нет по построению.
ffi_type_for_width :: proc(width: int) -> ^Ffi_Type {
	if width == 32 {
		return &ffi_type_sint32
	}
	return &ffi_type_sint64
}
