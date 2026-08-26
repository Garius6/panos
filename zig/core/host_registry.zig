// native host-function registry — specs/017-native-host-function-registry.
//
// Альтернативный источник резолва и путь вызова для `внешний "хост" функ
// ...`: встраивающее Zig-приложение регистрирует обычные Zig-функции через
// `panos.hostFunctions(...)` (см. `zig/embed.zig`), без `pub export fn`/
// `rdynamic`. Вызов идёт напрямую (эта же сигнатура `NativeCallFn`), минуя
// `ffi_prep_cif`/`ffi_call` — см. `research.md`, "Как VM зовёт
// зарегистрированную функцию, не используя libffi".
//
// Marshal-kinds переиспользуются один в один из существующего dynlib-FFI
// (`ast.ForeignMarshalKind`) — набор НЕ расширяется. `.pointer` (panos
// `Указатель(T)`) в этом срезе не поддерживается: в текущем Zig-порте у
// него нет представления в `value.Value` (нет отдельного варианта — только
// у dynlib-FFI пути этот marshal kind вообще типизируется, и он там же
// помечен `unreachable` везде, где реально нужна упаковка/распаковка) —
// поддержать его здесь значило бы додумывать GC-owned/borrowed семантику,
// которой ещё нет даже в основном FFI. Явный `@compileError`, не тихий
// пропуск.

const std = @import("std");
const ast = @import("ast.zig");
const value = @import("value.zig");
const gc = @import("gc.zig");

/// Единая type-erased форма вызова любой зарегистрированной host-функции —
/// аргументы уже сняты со стека VM (`value.Value`), результат — тоже
/// `value.Value`. `heap` — доступ к `allocator`/GC-аллокации, нужен только
/// функциям с `КСтрока`/`ff_структура`-возвратом (`heap.createString`/
/// `heap.createAggregate`) — для чисто скалярных сигнатур игнорируется.
/// `*gc.Heap` безопасен как прямой тип здесь: `gc.zig` НЕ импортирует
/// `sqlite3_bindings.zig` (закрытие `Соединение_БД` инжектируется как
/// `?*anyopaque`-коллбэк `Heap.sql_close_fn`, заданный `vm.zig`) — этот
/// файл может импортировать `gc.zig` напрямую, не раздувая граф импортов
/// лёгких `resolver.zig`/`module_loader.zig`, которые его тоже используют.
pub const NativeCallFn = *const fn (heap: *gc.Heap, args: []const value.Value) anyerror!value.Value;

pub const HostFunctionEntry = struct {
    /// Имя, под которым функция видна `.pns`-стороне через
    /// `внешний "хост" функ имя(...)`.
    name: []const u8,
    param_kinds: []const ast.ForeignMarshalKind,
    /// Параллельно `param_kinds` — та же форма, что
    /// `bytecode.ForeignFunctionConstant.param_struct_layouts`.
    param_struct_layouts: []const []const ast.ForeignMarshalKind,
    return_kind: ast.ForeignMarshalKind,
    return_struct_layout: []const ast.ForeignMarshalKind,
    call: NativeCallFn,
};

/// `T` — Zig-тип параметра/возврата ОБЫЧНОЙ (не составной) host-функции.
/// `@compileError` для любого типа вне уже существующего FFI marshal-набора
/// — сознательно НЕ расширяет его (см. `docs/src/language/ffi.md`, тот же
/// набор используют dynlib-`внешний`-декларации).
pub fn scalarMarshalKindFor(comptime T: type) ast.ForeignMarshalKind {
    return switch (T) {
        void => .void,
        u8 => .int8,
        i32 => .int32,
        i64 => .int64,
        f32 => .float32,
        f64 => .float64,
        []const u8 => .c_string,
        else => @compileError("panos.hostFunctions: неподдерживаемый Zig-тип '" ++
            @typeName(T) ++
            "' — допустимы u8/i32/i64/f32/f64/[]const u8/void, либо struct со " ++
            "скалярными полями того же набора (для ff_структура). Указатель(T) " ++
            "в этом срезе не поддерживается native host-function registry " ++
            "(specs/017-native-host-function-registry)."),
    };
}

/// Layout полей `ff_структура`-совместимого Zig-структа — та же форма, что
/// `param_struct_layouts`/`return_struct_layout`. Поля обязаны быть
/// скалярными (никаких вложенных структур/строк) — то же ограничение, что
/// у `ff_структура` в `.pns` (см. `docs/src/language/ffi.md`).
fn structFieldLayout(comptime T: type) []const ast.ForeignMarshalKind {
    const fields = @typeInfo(T).@"struct".fields;
    comptime var layout: [fields.len]ast.ForeignMarshalKind = undefined;
    inline for (fields, 0..) |field, i| {
        const kind = scalarMarshalKindFor(field.type);
        if (kind == .void or kind == .c_string) {
            @compileError("panos.hostFunctions: поле '" ++ field.name ++
                "' структуры '" ++ @typeName(T) ++
                "' должно быть Zig-числом фиксированной ширины " ++
                "(u8/i32/i64/f32/f64) — ff_структура допускает только " ++
                "плоские числовые поля, без строк/вложенных структур.");
        }
        layout[i] = kind;
    }
    const frozen = layout;
    return &frozen;
}

/// Marshal kind для параметра/возврата — скаляр напрямую, любой Zig
/// `struct` трактуется как `ff_структура` (`.struct_value`).
pub fn marshalKindFor(comptime T: type) ast.ForeignMarshalKind {
    return switch (@typeInfo(T)) {
        .@"struct" => .struct_value,
        else => scalarMarshalKindFor(T),
    };
}

/// Layout полей для `.struct_value` — пустой срез для любого другого kind
/// (та же конвенция, что `param_struct_layouts`/`return_struct_layout` в
/// `bytecode.ForeignFunctionConstant`).
pub fn structLayoutFor(comptime T: type) []const ast.ForeignMarshalKind {
    return switch (@typeInfo(T)) {
        .@"struct" => structFieldLayout(T),
        else => &.{},
    };
}
