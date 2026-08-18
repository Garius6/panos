# Embed Diagnostics API Contract (US1)

## `panos_core.diagnostic.format`

```zig
pub const FormatError = error{ FileMismatch, InvalidSpan };

pub fn format(
    allocator: std.mem.Allocator,
    file: source.SourceFile,
    value: Diagnostic,
) (FormatError || std.mem.Allocator.Error)![]u8;
```

- `value.span.file_id` MUST равняться `file.id`, иначе `error.FileMismatch`.
- `value.span` MUST быть валиден для `file` (`span.isValidFor(file)`),
  иначе `error.InvalidSpan`.
- Возвращает `"{путь}:{строка}:{колонка}: {warning: }{сообщение}"` —
  `warning: ` префикс присутствует только при `value.severity == .warning`.
- Формат идентичен сегодняшнему `cli/main.zig:formatDiagnostic` —
  перенос не меняет ни один байт вывода для уже существующих
  call-сайтов.

## `panos_core.diagnostic.writeGraph`

```zig
pub fn writeGraph(
    writer: *std.Io.Writer,
    graph: *const module_loader.Graph,
    diagnostics: *const DiagnosticList,
) !void;
```

- Для каждой диагностики в `diagnostics.items.items`: если
  `graph.moduleForFile(value.span.file_id)` находит модуль — пишет
  строку через `format(page_allocator, module.file, value)`; иначе
  пишет голое `value.message` без офсета.
- Каждая строка завершается `"\n"`.
- Не бросает ошибку на "файл не найден" — это ожидаемый fallback-путь,
  не error-условие.

## `panos_embed.Runtime.formatDiagnostics`

```zig
pub fn formatDiagnostics(
    self: *const Runtime,
    writer: *std.Io.Writer,
    diagnostics: *const panos_core.diagnostic.DiagnosticList,
) !void;
```

- Эквивалентно `panos_core.diagnostic.writeGraph(writer, self.graph(), diagnostics)`.
- `diagnostics` — обычно `self.graphDiagnostics()` или
  `self.compilationDiagnostics().?` (хост сам выбирает, какой набор
  форматировать).
- Хост НЕ обязан искать `SourceFile` вручную — весь lookup происходит
  внутри вызова.

## `panos_embed.formatDiagnostic` (ре-экспорт)

```zig
pub const formatDiagnostic = panos_core.diagnostic.format;
```

- Низкоуровневый путь для хостов, которым нужен рендер одной
  диагностики против конкретного, уже известного `SourceFile` —
  без прохода по графу модулей.

## Обратная совместимость

- `zig/cli/main.zig` после переноса вызывает те же `panos_core`
  функции под собственными локальными алиасами (`formatDiagnostic`,
  `writeGraphDiagnostics`, `writeModuleDiagnostics`) — внешнее
  поведение CLI (в т.ч. код возврата, вывод в stderr) не меняется.
- `DiagnosticFormatError` в `cli/main.zig` заменяется на
  `panos_core.diagnostic.FormatError` — если какой-то call-сайт ловит
  ошибку по имени типа (не через `catch`/`try` без явного типа),
  обновить сигнатуру.
