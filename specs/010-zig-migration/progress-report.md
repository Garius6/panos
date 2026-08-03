# Отчёт о состоянии Zig-миграции Panos

**Дата:** 2026-08-03
**Статус:** самостоятельный Zig-путь уже выполняет существенный однофайловый
поднабор Panos и поставляет работающие CLI/browser/LSP артефакты, но ещё не
заменяет Odin-реализацию целиком.

## Граница работы

Zig-реализация находится в `zig/` и собирается из `build.zig`. Она не вызывает
Odin-бинарники и не смешивает состояния runtime'ов. Изменения в существующих
`core/*.odin`, `main.odin` и документации остаются пользовательскими и не
включались в Zig-коммиты.

Следующий большой этап — расширить уже работающий минимальный module graph до
номинальных типов, generic'ов, методов и общей prelude/stdlib-семантики.

## Реализовано

### Общий pipeline и runtime

- Zig build graph создаёт CLI `panos`, LSP `panos-lsp`, browser WASM и
  scaffolds JS/WASI AOT runtime.
- Портированы UTF-8 source spans, lexer, parser с recovery, AST, resolver,
  type checker, bytecode compiler, VM и собственный tracing heap.
- Поддерживается проверенный однофайловый поднабор языка: функции и лямбды,
  замыкания, структуры, интерфейсы, generic-функции и типы, ADT/`выбор`,
  `Опция`/`Результат`, коллекции, циклы, `if`-выражения, процессы/акторы и
  runtime diagnostics.
- Общий API `zig/core/runner.zig` используется CLI, browser и LSP, поэтому
  parser/resolver/type checker не дублируются по delivery path.
- `zig build run -- test.ps` успешно выполняет основной демонстрационный
  файл на момент этого отчёта.

### Модули: загрузка, linking и исполнение

- `zig/core/module_loader.zig` строит локальный граф импортов, нормализует
  пути, собирает exports, сортирует зависимости и диагностирует циклы и
  отсутствующие файлы.
- `zig/core/module_linker.zig` передаёт каталог экспортов в
  `resolver.resolveWithImports`; квалифицированные имена импортов
  семантически распознаются.
- `zig/core/module_compiler.zig` компилирует graph в topological порядке в
  один `bytecode.Program`. Он сохраняет origin импортированного символа,
  подставляет реальный `FunctionId` экспортированной функции и literal
  constant, а затем запускает `старт` entry-модуля.
- Первый исполнимый срез покрывает квалифицированные вызовы экспортированных
  функций и literal constants со структурными сигнатурами (`Число`,
  `Строка`, `Булево`, `Пусто`, кортежи, функции, массивы, maps, процессы и
  указатели). Проверка аргументов проходит в importing module.
- Номинальные типы, generic parameters, методы и interface implementations
  через module boundary пока выдаются как контролируемая type diagnostic при
  использовании. Это намеренная граница: Zig пока хранит отдельные symbol и
  type stores для каждого модуля.
- CLI использует graph compiler и выполняет локальные multi-file программы.
  Browser/LSP остаются на single-source API и по-прежнему не выполняют
  импорты без filesystem/document graph.

### Target policy и runtime guards

- `zig/core/target.zig` содержит единый каталог доступности builtin'ов для
  `native`, browser bytecode VM, JS AOT WASM и WASI.
- Таблица и русскоязычные static/runtime сообщения покрыты unit-тестами.
- Реальная интеграция policy в type checker/bytecode/VM пока невозможна без
  портированных target-specific builtin'ов: Zig ещё не регистрирует
  `фс::*`, `DOM::*`, сетевые, SQL или FFI вызовы. Нельзя выдавать guard за
  рабочий, пока имя не существует в реальном dispatch.

### Browser interpreter

- `zig/browser/main.zig` собирается в `wasm32-freestanding` и экспортирует
  ABI буферов исходника/результата.
- Реализованы `panos_run`, `panos_check`, `panos_hover` и `panos_complete`.
- Browser использует тот же `runner`: run/check, диагностики, UTF-16 hover
  и методы/поля completion проходят через Zig frontend.
- `docs/src/assets/interactive.js` совместим и со старым Odin WASM, и с
  новым Zig result-buffer ABI.

### LSP

`zig/lsp/main.zig` реализует стандартный JSON-RPC transport через stdin/stdout
и `Content-Length`; stdout содержит только protocol messages.

Поддержаны и заявлены в `initialize`:

- lifecycle: `initialize`, `shutdown`, `exit`, `didOpen`, full-text
  `didChange`, `didClose`;
- diagnostics с UTF-16 line/character диапазонами;
- `textDocument/hover` и completion после `.`;
- `textDocument/foldingRange` и `textDocument/documentSymbol`;
- `textDocument/definition`, `textDocument/references` и
  `textDocument/documentHighlight` для текущего документа;
- `textDocument/signatureHelp` для обычных вызовов функций.

Новые LSP-срезы были записаны отдельными коммитами:

| Commit | Содержание |
| --- | --- |
| `51c5b99` | transport, document lifecycle, diagnostics, hover, completion |
| `16b82d7` | structural outline и folding ranges |
| `f1dee2c` | definition, references и document highlights |
| `2244b97` | signature help |

## Проверки, выполненные перед отчётом

Успешно выполнены:

```sh
zig build test --summary none
zig build conformance --summary none
zig build run -- test.ps
zig build lsp --summary none
```

Также выполнен реальный запуск CLI временного двухфайлового graph: импорт
`мат.сложить(мат.ОТВЕТ, 2)` вывел `42`.

Кроме unit-тестов, LSP запускался как отдельный процесс. Проверены настоящие
`Content-Length` кадры и JSON-RPC ответы для diagnostics, hover, completion,
outline, folding ranges, definition, references, highlights и signature help.

Не запускались Odin-тесты и не проверялись пользовательские изменения в
Odin-файлах: они не относятся к Zig-срезам и не должны быть перезаписаны.

## Оставшаяся работа

### Критичный P1: расширение module graph

Минимальный linker уже подтверждён, но module boundaries ещё не сохраняют
идентичность пользовательских типов. Следующие инварианты нужны до
полноценного cutover:

1. Дать imported nominal types стабильную graph-wide identity, а не
   пересоздавать их в каждом `TypeStore`.
2. Расширить `ImportContext` на generic definitions, enum variants, methods
   и interface vtables; не допускать несовместимых копий generic parameter
   IDs.
3. Подтвердить цепочки из трёх и более файлов, скрытые/private exports,
   missing export, import cycle и runtime diagnostics в dependency.
4. Спроектировать unsaved document graph поверх этой модели для browser/LSP.

### Builtin'ы и target guards

- Портировать native adapters: filesystem/process/compression/syntax,
  networking/HTTP server/client, SQLite и FFI.
- Ввести обычный builtin dispatch в compiler/VM с именем и
  `TargetProfile`; таблица `target.zig` проверяется до lowering и повторно
  на runtime boundary.
- Отдельно обработать opaque-resource methods: они не являются обычными
  builtin calls и требуют guard в соответствующем адаптере.
- Только после этого переносить DOM/sync HTTP и AOT WASM import surface.

### AOT и browser delivery

- Browser interpreter уже рабочий для однофайлового bytecode path, но
  отдельный AOT pipeline (MIR, lowering, validation, stackification,
  binary emission) ещё не портирован.
- JS и WASI runtime сейчас scaffolds; нужны generated-WASM и wasmtime/browser
  integration tests без Odin artifacts.
- CLI `panos build --target=wasm` пока не реализует договорённый AOT contract.

### Оставшиеся LSP capabilities

Контракт `contracts/lsp.md` ещё требует:

- `prepareRename` и `rename`;
- cross-document `definition`/`references` и unsaved override graph;
- `workspace/symbol`, `semanticTokens/full`, `codeLens`, `selectionRange`;
- полные transcript tests, включая invalid-input responses всех методов.

Текущие references/highlights намеренно ограничены одним сохранённым в LSP
документом. Это честная граница до общего module graph и index-а открытых
документов.

### Поддержка и cutover

- Обновить `README.md` и архитектурные документы Zig-командами и boundary
  model.
- Добавить CI matrix для `zig build test`, conformance, browser и AOT tests.
- Сверить/расширить conformance corpus runtime/module/native/browser/aot/lsp.
- Не переключать release/Pages/Justfile на Zig до закрытия module execution,
  native boundary и AOT exit gates.

## Рекомендуемый порядок продолжения

1. Расширить существующий graph compiler на nominal types, methods, generics
   и prelude/stdlib без копирования идентичностей типов.
3. Добавить первые native builtin adapters вместе с static + runtime target
   guards из `target.zig`.
4. На общей semantic model завершить cross-document LSP и rename/reference
   операции.
5. Портировать MIR/AOT/runtime и добавить target integration matrix.
6. Завершить docs/CI/conformance и только затем планировать cutover Odin.

## Состояние рабочей копии

В рабочей копии присутствуют изменённые, staged deleted и untracked Odin/docs
файлы, принадлежащие пользователю. Они не входят в перечисленные Zig-коммиты;
перед дальнейшими Git-операциями нужно продолжать коммитить только явные пути
из `zig/`, `build.zig` и относящихся Zig-тестов.
