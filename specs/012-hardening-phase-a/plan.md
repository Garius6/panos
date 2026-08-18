# Implementation Plan: Hardening Phase A — embed-диагностики, error-path тесты, nested generic capture, doc-comment hover

**Branch**: `012-hardening-phase-a` | **Date**: 2026-08-18 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `specs/012-hardening-phase-a/spec.md`

## Summary

Четыре независимых, узких hardening-фикса, взятых из
`panos-hardening-plan-2026-08-17-verified.md` Phase A: (1) переместить
рендер диагностик (`formatDiagnostic`/`writeGraphDiagnostics`) из
`zig/cli/main.zig` в `panos_core.diagnostic`, ре-экспортировать через
`panos_embed`; (2) добавить error-path тесты на уже задокументированные,
но непроверенные контракты `Runtime` (сломанный скрипт,
call-после-паники, несуществующий экспорт); (3) сделать
`concreteCaptureFieldType`/`classifyCaptureDepth` в
`zig/core/mir_lowering.zig` рекурсивными по вложенным generic-полям
closure-захватов вместо однократной прямой подстановки; (4) прокинуть
уже собираемые лексером/парсером `///`-doc-комментарии (`ast.Decl`'s
`.doc` поле) через новый `SourceAnalysis.expressionDoc` в LSP
`textDocument/hover`. Каждый пункт независимо тестируем и не меняет
поведение остальных трёх.

## Technical Context

**Language/Version**: Zig 0.16.0 (единственный тулчейн, Odin полностью
удалён — `specs/010-zig-migration`)
**Primary Dependencies**: `panos_core` (единый Zig-модуль: lexer/parser/
resolver/type_checker/compiler/vm/mir_lowering), `panos_embed`
(зависит от `panos_core`), `zig/cli` (зависит от обоих), `zig/lsp`
(зависит от `panos_core`)
**Storage**: N/A
**Testing**: `zig build test` (юнит-тесты `test` блоков в затронутых
файлах), `zig build aot` (WASM AOT для User Story 3), существующий
LSP hover regression-тест (`zig/lsp/main.zig`, JSON-RPC через
`Server.handle`) для User Story 4
**Target Platform**: native CLI/embed-хост (US1, US2), `wasm32` AOT
(US3), LSP-сервер (любая платформа, US4)
**Project Type**: interpreter/compiler (единый репозиторий, нет
отдельных frontend/backend)
**Performance Goals**: без измеримой деградации — US1/US2/US4 не
затрагивают горячий путь исполнения; US3 добавляет ограниченную
глубину рекурсии в compile-time классификации захвата (уже есть
`depth == 64` cutoff, переиспользуется)
**Constraints**: не менять формат вывода CLI-диагностик побайтово
(US1); не менять поведение уже поддерживаемого одноуровневого
generic-захвата и non-generic closures (US3); не менять формат hover
для деклараций без doc-комментария (US4); reset/reload и sandboxing
`panos_embed` (§2/§3 `panos-embed-api-followup-plan-2026-08-17.md`) —
вне scope
**Scale/Scope**: `zig/core/diagnostic.zig`, `zig/cli/main.zig`,
`zig/embed.zig`, `zig/core/mir_lowering.zig`, `zig/core/runner.zig`,
`zig/core/resolver.zig` (только чтение существующего `decl_symbols`),
`zig/lsp/main.zig`, плюс регрессионные тесты/фикстуры в каждом

## Constitution Check

| Principle | Result | Evidence |
|---|---|---|
| Think Before Coding | Pass | Каждый из 4 пунктов уже расследован против живого `HEAD` (не по памяти) в `panos-hardening-plan-2026-08-17-verified.md` и `panos-embed-api-followup-plan-2026-08-17.md`; в этом plan-проходе подтверждены реальные строки/сигнатуры (`zig/embed.zig`, `zig/cli/main.zig`, `zig/core/mir_lowering.zig:2607-2646`, `zig/lsp/main.zig:195-230`, `zig/core/ast.zig:341-413`) до написания research.md. |
| Simplicity First | Pass | US1 — чистый перенос существующего кода, ноль новой абстракции. US2 — только тесты, ноль нового production-кода. US3 — расширение существующей рекурсии (`classifyCaptureDepth` уже рекурсивна по `.array`; тот же паттерн для `.nominal`), не новый механизм. US4 — hover остаётся `plaintext` (не переключается на `markdown` kind), инверсия `decl_symbols` строится на месте без постоянного индекса — минимум нового кода. |
| Surgical Changes | Pass | Каждая User Story трогает только файлы, перечисленные в её acceptance-сценариях; никаких смежных рефакторингов. |

## Project Structure

### Documentation (this feature)

```text
specs/012-hardening-phase-a/
├── plan.md              # этот файл
├── research.md           # Phase 0 — 4 независимых решения
├── data-model.md          # Phase 1 — задействованные структуры
├── quickstart.md          # Phase 1 — как проверить каждый пункт
└── contracts/
    └── embed-diagnostics-api.md   # публичный контракт US1
```

### Source Code (repository root)

```text
zig/core/
├── diagnostic.zig        # US1: новая `pub fn format`/DiagnosticFormatError сюда
├── mir_lowering.zig       # US3: concreteCaptureFieldType/classifyCaptureDepth рекурсия
├── runner.zig             # US4: новый SourceAnalysis.expressionDoc
└── resolver.zig            # US4: чтение существующего Resolution.decl_symbols (без изменений схемы)

zig/cli/
└── main.zig               # US1: formatDiagnostic/writeGraphDiagnostics — заменить на вызов panos_core

zig/embed.zig               # US1: ре-экспорт форматирования + Runtime.formatDiagnostics helper
                             # US2: новые error-path test-блоки

zig/lsp/
└── main.zig                # US4: hover() дёргает expressionDoc, writeHoverResponse включает doc-текст

tests/
├── embed_test.zig или embed_diagnostics_test.zig   # US1 (если решено не держать тест внутри embed.zig)
└── embed_host_test.zig                              # US2, если решено разместить error-path тесты здесь, а не в embed.zig

fixtures/
└── (новая .pns-фикстура для WASM AOT nested-generic-capture, US3)
```

**Structure Decision**: Все четыре пункта — точечные изменения внутри
уже существующей единой Zig-кодовой базы (`zig/core`, `zig/cli`,
`zig/embed.zig`, `zig/lsp`); новых директорий/проектов не заводится.

## Complexity Tracking

*Нет нарушений Constitution Check — секция не заполняется.*

## Implementation Outline

### US1 — рендер диагностик в `panos_embed`

1. Перенести `DiagnosticFormatError` + тело `formatDiagnostic`
   (`zig/cli/main.zig:5-32`) в `zig/core/diagnostic.zig` как
   `pub fn format(allocator, file: source.SourceFile, value: Diagnostic) (FormatError || Allocator.Error)![]u8` —
   логика без изменений (то же `file.lineColumn`, тот же
   `"{s}:{d}:{d}: {s}{s}"` формат).
2. Перенести `writeGraphDiagnostics` (`zig/cli/main.zig:70-84`) туда же
   как `pub fn writeGraph(writer, graph: *const module_loader.Graph, diagnostics: *const DiagnosticList) !void`
   — тот же fallback на голое `message`, если `moduleForFile` не находит
   файл.
3. `zig/cli/main.zig` — заменить локальные определения на алиасы/прямые
   вызовы `panos_core.diagnostic.format`/`.writeGraph`; все текущие
   call-сайты (`writeModuleDiagnostics`, `writeAnalysisDiagnostics`,
   тесты на строках 689/705/733/740) продолжают работать без изменения
   ожидаемого вывода.
4. `zig/embed.zig` — добавить `pub const formatDiagnostic = panos_core.diagnostic.format;`
   (симметрично уже существующему `pub const Value = panos_core.value.Value;`,
   строка 159) и `pub fn Runtime.formatDiagnostics(self, writer, diagnostics) !void`,
   вызывающий `panos_core.diagnostic.writeGraph(writer, &self.graph_state, diagnostics)`.
5. Новый тест: граф с намеренной type-ошибкой → `Runtime.formatDiagnostics`
   → строка содержит `путь:line:col:`.

### US2 — error-path тесты `panos_embed`

1. Тест A: `MemoryReader` со скриптом с синтаксической/type-ошибкой →
   `load()`/`compile()` не бросают Zig-error → `hasGraphErrors()`/
   `hasCompilationErrors()` `true` → последующий `call`/`runStart`
   возвращает `error.NotRunnable`/`error.NotCompiled`.
2. Тест B: рабочий скрипт, один `call()` вызывает панику внутри скрипта
   (`.runtime_error` вариант `Execution`) → следующий `call()` (другой
   или тот же экспорт) — зафиксировать реальное сегодняшнее поведение
   (`run()` только чистит `machine.output`, `machine`/VM-состояние
   между вызовами не сбрасывается) как ожидаемый результат теста, не
   домысленное "должно работать".
3. Тест C: `call()` с несуществующим именем → `error.ExportNotFound`
   (`rootExportFunction` возвращает `null` → `zig/embed.zig:116`).
4. Разместить рядом с существующим тестом в `zig/embed.zig` (тот же
   файл уже держит один `test` блок, строки 189-240) — не заводить
   отдельный `tests/embed_diagnostics_test.zig`, пока не понадобится
   вынести (Simplicity First).

### US3 — рекурсивная резолюция вложенных generic-полей

1. `concreteCaptureFieldType` (`zig/core/mir_lowering.zig:2607-2618`)
   сегодня подставляет параметр, только если `field_type` — САМ бэрный
   `.generic_parameter`. Если `field_type` — `.nominal` с аргументами,
   часть из которых сама `.generic_parameter` (случай `Коробка(T)`
   внутри `Коробка(Коробка(T))`), эти аргументы не подставляются вовсе
   — нужен рекурсивный шаг: для `.nominal` field_type построить новый
   `TypeId` с аргументами, каждый из которых прогнан через
   `concreteCaptureFieldType(checked, nominal, arg)` относительно
   ВНЕШНЕГО `nominal` (родителя), прежде чем передавать получившийся
   тип дальше в `classifyCaptureDepth`.
2. Уточнить перед реализацией: как в этой кодовой базе строится новый
   `TypeId` с подставленными generic-аргументами вне typechecker'а —
   проверить, есть ли уже готовый helper (например, что-то в духе
   `instantiate_type`/`generic_instance_cache`, упоминаемого в
   `CLAUDE.md`'s Recent Changes для typechecker'а) прежде чем писать
   новый; если нет прямого аналога в `mir_lowering.zig`, это отдельный
   research-вопрос перед кодированием (не гадать).
3. `classifyCaptureDepth`'s `.nominal` ветка (2625-2640) — после
   получения корректно подставленного `concrete_type` для каждого
   поля, рекурсия `classifyCaptureDepth(checked, concrete_type, depth + 1)`
   уже существует и не требует изменений — только вход в неё должен
   быть по-настоящему конкретным типом, не частично-generic.
4. Новая WASM-фикстура: closure захватывает значение двухуровневой
   вложенности (`Коробка(Коробка(T))`-подобная форма) с конкретным
   nominal-аргументом для `T` — компиляция + `zig build aot`-запуск,
   сравнение результата с native.
5. Негативный regression: тот же паттерн, но внутренний `T` не выводим
   статически — подтвердить, что диагностика остаётся понятной
   (не тихий неверный кодогенерация), тем же путём, что сегодня
   работает для одноуровневого случая.
6. Существующий одноуровневый generic-capture regression-тест — прогнать
   без изменений, подтвердить отсутствие регрессии.

### US4 — doc-комментарии в LSP hover

1. `zig/core/runner.zig`'s `SourceAnalysis` (строка 46) — новый метод
   `expressionDoc(self, expression: ast.ExprId) ?[]const u8`, симметричный
   `expressionTypeName` (строка 96): через `resolution().expr_symbols.get(expression)`
   получить `SymbolId`; инвертировать `resolution().decl_symbols`
   (`std.AutoHashMap(ast.DeclId, symbols.SymbolId)`, `resolver.zig:175`)
   в `AutoHashMap(SymbolId, DeclId)` на месте (одна LSP-сессия, decl'ов
   немного — O(n) построение приемлемо, постоянный индекс не нужен);
   через найденный `DeclId` — `tree.decl(decl_id)`, `switch` по варианту
   `ast.Decl` (`ast.zig:341-413`) — забрать `.doc`, если вариант его
   несёт (`.function`/`.struct_decl`/`.interface_decl`/`.enum_decl`/
   `.constant`/`.type_alias`), иначе `null`.
2. `zig/lsp/main.zig`'s `hover()` (строка 195-230) — после получения
   `type_name`, дополнительно вызвать `analysis.expressionDoc(expression)`.
3. `writeHoverResponse` (строка 1076-1084) — расширить сигнатуру
   опциональным doc-параметром; при наличии — включить перед типом в
   тот же `"plaintext"` `contents.value` (например `doc ++ "\n\n" ++ type_name`),
   не переключать `kind` на `"markdown"` (минимальное изменение формата,
   Simplicity First — переключение на markdown осталось бы совместимым
   с большинством клиентов, но не требуется этой спецификацией).
4. Тест: существующий hover JSON-RPC тест (`zig/lsp/main.zig:1713`) —
   расширить фикстурой с `///`-комментарием перед функцией, проверить
   что doc-текст присутствует в `contents.value`; отдельный тест на
   декларацию без doc-комментария — ответ не содержит doc-секции
   (регрессия из Edge Cases spec.md).
5. Completion (`zig/lsp/main.zig:236`, `documentation`-поле
   `CompletionItem`) — явно вне scope этой спецификации (assumption в
   spec.md), не трогать в этом проходе.

## Порядок реализации

Все четыре User Story независимы (нет общих файлов между US1/US2 и
US3/US4), можно вести параллельно. Рекомендуемый порядок внутри одной
последовательной сессии — по дешевизне, как в исходном hardening-плане:
US1 → US2 → US3 → US4. После каждого пункта — `zig build test` (плюс
`zig build aot` для US3, ручной `Server.handle`-прогон для US4) перед
переходом к следующему.
