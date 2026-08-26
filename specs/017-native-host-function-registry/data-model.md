# Data Model: native host-function registry

## `HostFunctionEntry` (новый, `zig/embed.zig` или новый `zig/core/host_registry.zig`)

```zig
pub const HostFunctionEntry = struct {
    /// Имя, под которым функция видна `.pns`-стороне через
    /// `внешний "хост" функ имя(...)`.
    name: []const u8,
    param_kinds: []const ast_types.ForeignMarshalKind,
    /// Параллельно `param_kinds` — layout полей для параметров-`ff_структура`,
    /// та же форма, что `ForeignFunctionConstant.param_struct_layouts`.
    param_struct_layouts: []const []const ast_types.ForeignMarshalKind,
    return_kind: ast_types.ForeignMarshalKind,
    return_struct_layout: []const ast_types.ForeignMarshalKind,
    /// Type-erased trampoline, сгенерированный `comptime` в `hostFunctions()`
    /// — см. research.md, "Как VM зовёт...". Уникален для каждой
    /// зарегистрированной функции, стирает её реальную Zig-сигнатуру за
    /// единым интерфейсом.
    call: *const fn (args: []const value.Value) anyerror!value.Value,
};
```

Валидация (недопустимый Zig-тип параметра/возврата) происходит ДО того, как
`HostFunctionEntry` вообще создаётся — на этапе `comptime`-генерации
trampoline в `hostFunctions()` (`@compileError`), см. FR-004. Сам
`HostFunctionEntry` уже гарантированно валиден к моменту существования.

## `hostFunctions(comptime table: anytype) []const HostFunctionEntry`

Публичная `comptime`-функция (`zig/embed.zig`). `table` — анонимный структ,
имена полей = имена host-функций, значения полей = обычные Zig-функции
(`fn`, не указатели — берётся `&func` внутри). Для каждого поля:

1. `@typeInfo(@TypeOf(@field(table, field.name))).@"fn"` — получить список
   типов параметров и тип возврата.
2. Каждый тип прогоняется через `marshalKindFor(comptime T: type)
   ast_types.ForeignMarshalKind` — `@compileError`, если тип не входит в
   уже существующий набор marshal kinds (см. ниже "Соответствие типов").
3. Генерируется trampoline-функция (уникальная инстанциация на каждое
   поле — обычная Zig-generics-механика, не рантайм-код).
4. Собирается `HostFunctionEntry{ .name = field.name, ... , .call =
   &Trampoline.call }`.

Результат — `comptime`-массив, возвращаемый как `[]const HostFunctionEntry`
(время жизни — статическое, как у любых `comptime`-констант в Zig).

### Соответствие типов (переиспользует `ast_types.ForeignMarshalKind`, не
расширяет его — см. `spec.md`, Assumptions)

| Zig-тип (параметр/возврат)   | `ForeignMarshalKind` |
|-------------------------------|-----------------------|
| `u8`                           | `.int8`               |
| `i32`                          | `.int32`               |
| `i64`                          | `.int64`               |
| `f32`                          | `.float32`             |
| `f64`                          | `.float64`             |
| `[:0]const u8` / `[*:0]const u8` | `.c_string` (`КСтрока`) |
| `void`                          | `.void`                |
| struct, помеченный как соответствующий `ff_структура`-декларации | `.struct_value` (layout выводится из полей структуры теми же правилами, что уже использует `parseFfiStructDeclaration`) |
| opaque-указатель (`*anyopaque`/типизированный wrapper) | `.pointer` |

Любой другой Zig-тип параметра/возврата → `@compileError` в точке вызова
`hostFunctions(...)` (в build-логе движка, не в рантайме panos).

## `ForeignFunctionConstant` (расширение, `zig/core/bytecode.zig:16`)

```zig
pub const ForeignCallKind = enum {
    dynlib_libffi,   // существующий путь: dlopen/dlsym + ffi_prep_cif/ffi_call
    native_registry, // новый путь: HostFunctionEntry.call, без libffi
};

pub const ForeignFunctionConstant = struct {
    fn_ptr: usize,           // используется только для .dynlib_libffi
    native_call: ?*const fn (args: []const value.Value) anyerror!value.Value, // только для .native_registry
    call_kind: ForeignCallKind,
    name: []const u8,
    param_kinds: []const ast.ForeignMarshalKind,
    param_struct_layouts: []const []const ast.ForeignMarshalKind,
    return_kind: ast.ForeignMarshalKind,
    return_struct_layout: []const ast.ForeignMarshalKind,
};
```

`fn_ptr`/`native_call` — взаимоисключающие в зависимости от `call_kind`
(один из них всегда неиспользуемый для конкретной константы) — не два
раздельных union-варианта константы ради минимизации изменений в
`compiler.zig`/`vm.zig`, которые уже везде работают с одним типом
`ForeignFunctionConstant`.

## `Resolution`/`Resolver` (расширение, `zig/core/resolver.zig`)

- `Resolution` (или отдельно прокидываемый параметр
  `resolveModuleForTarget`) получает `host_registry: []const
  HostFunctionEntry = &.{}`.
- `resolveForeignFunction`: для `foreign.library == "хост"` — ПЕРЕД веткой
  `dlopen(NULL)`/`dlsym` (см. `research.md`, текущий код ~строка 923) —
  линейный поиск `foreign.name` в `host_registry`. При найденной записи:
  - Сверить количество/`ForeignMarshalKind` параметров и возврата
    `.pns`-декларации (`foreign.parameters`/`foreign.return_kind` — уже
    распарсенные к этому моменту типом резолвера) с записью реестра.
    Несовпадение → `self.report(foreign.span, "Resolve Error: ...")`,
    аналогично существующим сообщениям об отсутствующем символе.
  - При совпадении — положить в `Resolution` результат с `call_kind =
    .native_registry` и `native_call = entry.call` (не трогать
    `foreign_functions: AutoHashMap(SymbolId, usize)`, которая по смыслу
    только для `.dynlib_libffi` — либо расширить эту map, чтобы хранить
    вариант `union(ForeignCallKind)`, конкретная форма — на усмотрение
    реализации в `tasks.md`/коде, не фиксируется здесь жёстко).
  - Если не найдена — поведение НЕ меняется, идёт в существующую
    `dlopen(NULL)`/`dlsym`-ветку (FR-003).

## `Vm.invokeForeign` (расширение, `zig/core/vm.zig:4665`)

Ветвление по `info.call_kind`:

- `.dynlib_libffi` — существующий код без изменений (`ffi_prep_cif`,
  `packScalar`/`packStruct`, `ffi_call`, `unpackScalar`).
- `.native_registry` — новая ветка: собрать `args: []const value.Value` из
  того, что уже снято со стека (`self.popValues(argument_count)` — тот же
  код, что и сегодня, ДО ветвления), вызвать `info.native_call.?(args)`,
  результат — уже готовый panos `Value`, без пакования/распаковки через
  C ABI байты (trampoline на стороне регистрации уже сделал это
  Zig-типами напрямую).

## `Runtime.Config` (расширение, `zig/embed.zig:32`)

```zig
pub const Config = struct {
    // ...существующие поля без изменений...
    host_functions: []const HostFunctionEntry = &.{},
};
```

Пустой (default) слайс — воспроизводит сегодняшнее поведение один в один
(FR-007, edge case "Registry пуст").
