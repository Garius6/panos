# Data Model: Hardening Phase A

Ни один пункт Phase A не вводит новую персистентную сущность — все
четыре расширяют существующие структуры `panos_core`/LSP новыми
методами или заполняют уже существующие, но недочитанные поля.

## Diagnostic rendering (US1)

| Поле/функция | Расположение (после переноса) | Смысл |
|---|---|---|
| `diagnostic.format(allocator, file, value)` | `zig/core/diagnostic.zig` | Байтовый offset → `путь:строка:колонка: сообщение`; идентичен сегодняшнему `cli/main.zig:formatDiagnostic`. |
| `diagnostic.writeGraph(writer, graph, diagnostics)` | `zig/core/diagnostic.zig` | Для каждой диагностики находит `SourceFile` через `graph.moduleForFile`, иначе печатает голое `message`. |
| `Runtime.formatDiagnostics(self, writer, diagnostics)` | `zig/embed.zig` | Обёртка над `writeGraph`, использует `self.graph_state` как граф. |

Инвариант: `format`/`writeGraph` — чистые функции без побочного
состояния (кроме переданного `writer`/`allocator`); поведение не
зависит от того, вызваны они из CLI или из embed-хоста.

## Runtime error-контракты (US2)

Существующая машина состояний `Runtime.Stage` (`empty → loaded →
compiled`, `zig/embed.zig:23-27`) не меняется. Таблица фиксирует
контракт, который тесты должны подтвердить:

| Стадия / событие | Ожидаемый результат |
|---|---|
| `load()`/`compile()` на скрипте с диагностиками | Не бросает Zig-error; диагностики доступны через `graphDiagnostics()`/`compilationDiagnostics()`. |
| `call`/`runStart` при `hasGraphErrors()`/`hasCompilationErrors() == true` | `error.NotRunnable` (если `machine` не инициализирован) или `error.NotCompiled` (`runStart`, если `compiledGraph()` пуст). |
| `call()` после `.runtime_error` результата предыдущего вызова | Фиксируется РЕАЛЬНОЕ поведение (см. research.md) — `Runtime` не сбрасывает состояние между вызовами, только `machine.output`. |
| `call()` с несуществующим именем экспорта | `error.ExportNotFound` (`rootExportFunction` возвращает `null`). |

## Захватываемое generic-поле closure (US3)

| Понятие | Сегодня | После фикса |
|---|---|---|
| `concreteCaptureFieldType(checked, nominal, field_type)` | Подставляет `field_type`, только если он сам бэрный `.generic_parameter`; вложенный `.nominal` с generic-аргументами возвращается как есть (не подставлен). | Рекурсивно подставляет generic-аргументы вложенного `.nominal` через аргументы внешнего `nominal`, прежде чем вернуть результат. |
| `classifyCaptureDepth(checked, type_id, depth)` | `.nominal`-ветка уже рекурсивна по глубине (`depth == 64` cutoff), но получает частично-неподставленный тип для двухуровневой вложенности. | Получает полностью подставленный (насколько статически возможно) `concrete_type` на каждом уровне — рекурсия остаётся той же, вход становится корректным. |
| `CaptureKind.unsupported` | Возвращается, если резолюция вложенного generic-плейсхолдера невозможна (нет соответствующего конкретного аргумента). | Не меняется — остаётся честной диагностикой отклонения, не тихой некорректной кодогенерацией. |

## LSP hover doc (US4)

| Поле/функция | Расположение | Смысл |
|---|---|---|
| `token.doc` / `ast.Decl` варианты `.doc` | `zig/core/lexer.zig`, `zig/core/ast.zig:341-413` | Уже существующие, contiguous `///`-строки перед декларацией — не изменяются этой работой. |
| `Resolution.decl_symbols: AutoHashMap(DeclId, SymbolId)` | `zig/core/resolver.zig:175` | Уже существующая прямая карта, источник для инверсии. |
| `SourceAnalysis.expressionDoc(self, expression) ?[]const u8` (новый) | `zig/core/runner.zig` | `expr_symbols → SymbolId` → инверсия `decl_symbols` (построенная на месте) `→ DeclId` → `tree.decl(decl_id).doc`, если вариант декларации несёт `.doc`. |
| `writeHoverResponse(..., doc: ?[]const u8, ...)` (расширенная сигнатура) | `zig/lsp/main.zig:1076` | `contents.value` = `doc ++ "\n\n" ++ type_name`, если `doc` не `null` и не пустая строка; иначе только `type_name`, как сегодня. |

Инвариант: decl-варианты без поля `.doc` (`import`, `impl`, `foreign`,
`error_node`) обрабатываются через `switch`-ветку без `.doc` —
`expressionDoc` возвращает `null`, hover не регрессирует.
