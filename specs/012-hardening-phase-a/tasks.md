# Tasks: Hardening Phase A — embed-диагностики, error-path тесты, nested generic capture, doc-comment hover

**Input**: Design documents from `/specs/012-hardening-phase-a/`
**Prerequisites**: `plan.md`, `spec.md`, `research.md`, `data-model.md`, `contracts/embed-diagnostics-api.md`, `quickstart.md`

**Tests**: Каждая user story в spec.md прямо требует регрессионных тестов (acceptance scenarios) — пишутся вместе с реализацией, не отдельно опционально.

**Organization**: Задачи сгруппированы по user story. US1/US2 делят один файл (`zig/embed.zig`) — сиквенс внутри него важен; US3 и US4 полностью независимы от остальных и друг от друга.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: можно выполнять параллельно с другими задачами той же фазы (разные файлы, нет зависимости).
- **[Story]**: какой user story из spec.md обслуживает задача.

## Phase 1: Setup

**Purpose**: Подтвердить зелёный baseline перед любыми изменениями.

- [X] T001 Прогнать `zig build test` и `zig build aot` на текущем `HEAD`, зафиксировать, что оба зелёные (baseline из `panos-hardening-plan-2026-08-17-verified.md` уже это утверждает на 2026-08-17 — переподтвердить перед стартом этой сессии).

**Checkpoint**: Baseline зелёный — можно начинать любую из четырёх user story в любом порядке.

---

## Phase 2: User Story 1 — Диагностики скрипта видны хосту `panos_embed` (Priority: P1) 🎯 MVP

**Goal**: `panos_embed` предоставляет готовый, отформатированный рендер диагностик — хосту не нужно переизобретать byte-offset→line/column самому.

**Independent Test**: Хост загружает через `panos_embed` скрипт с намеренной type-ошибкой, вызывает новый API, получает строку `путь:строка:колонка: сообщение`.

### Implementation for User Story 1

- [X] T002 [US1] Перенести `DiagnosticFormatError`/`formatDiagnostic` (`zig/cli/main.zig:5-32`) в `zig/core/diagnostic.zig` как `pub const FormatError` / `pub fn format(allocator, file, value) (FormatError || Allocator.Error)![]u8` — тело без изменений.
- [X] T003 [US1] Перенести `writeGraphDiagnostics` (`zig/cli/main.zig:70-84`) в `zig/core/diagnostic.zig` как `pub fn writeGraph(writer, graph, diagnostics) !void`, переиспользуя новый `format`.
- [X] T004 [US1] `zig/cli/main.zig` — заменить локальные `formatDiagnostic`/`writeGraphDiagnostics`/`DiagnosticFormatError` на вызовы/алиасы `panos_core.diagnostic.format`/`.writeGraph`/`.FormatError`; все существующие call-сайты (`writeModuleDiagnostics`, `writeAnalysisDiagnostics`, тесты строк ~689/705/733/740) не меняют поведение.
- [X] T005 [US1] `zig/embed.zig` — добавить `pub const formatDiagnostic = panos_core.diagnostic.format;` (симметрично `pub const Value`, строка 159) и `pub fn Runtime.formatDiagnostics(self, writer, diagnostics) !void`, вызывающий `panos_core.diagnostic.writeGraph(writer, self.graph(), diagnostics)`.
- [X] T006 [P] [US1] Тест: граф с намеренной type-ошибкой → `Runtime.formatDiagnostics` → строка содержит `путь:line:col:` — новый `test` блок в `zig/embed.zig`.
- [X] T007 [P] [US1] Прогнать `zig build test`, подтвердить, что вывод существующих CLI diagnostic-тестов (`cli/main.zig`) не изменился побайтово.

**Checkpoint**: US1 завершена, когда T006 зелёный и `Runtime.formatDiagnostics` работает без обращения к `zig/cli/main.zig`.

---

## Phase 3: User Story 2 — Error-пути `panos_embed` покрыты тестами (Priority: P1)

**Goal**: Задокументированные, но непроверенные error-контракты `Runtime` (сломанный скрипт, call-после-паники, несуществующий экспорт) закреплены тестами.

**Independent Test**: Три новых тестовых сценария проходят независимо от T002-T007.

**Зависимость**: тот же файл, что US1 (`zig/embed.zig`) — выполнять после T005, чтобы избежать конфликта правок в одном файле; логической зависимости от кода US1 нет.

### Implementation for User Story 2

- [X] T008 [P] [US2] Тест A: `MemoryReader` со скриптом с синтаксической/type-ошибкой → `load()`/`compile()` не бросают Zig-error → `hasGraphErrors()`/`hasCompilationErrors()` `true` → `call`/`runStart` возвращают `error.NotRunnable`/`error.NotCompiled` — новый `test` блок в `zig/embed.zig`.
- [X] T009 [P] [US2] Тест B: рабочий скрипт, один `call()` вызывает панику внутри скрипта (`.runtime_error`) → следующий `call()` — зафиксировать реальное сегодняшнее поведение (`data-model.md`'s таблица) как ожидаемый результат — новый `test` блок в `zig/embed.zig`.
- [X] T010 [P] [US2] Тест C: `call()` с несуществующим именем экспорта → `error.ExportNotFound` — новый `test` блок в `zig/embed.zig`.
- [X] T011 [US2] Прогнать `zig test zig/embed.zig`, подтвердить все три новых теста зелёные, старый тест (строки 189-240) не регрессировал.

**Checkpoint**: US2 завершена, когда T008-T010 зелёные.

---

## Phase 4: User Story 3 — Вложенные generic-поля рекурсивно резолвятся в WASM AOT closures (Priority: P2)

**Goal**: Closure, захватывающая значение с двухуровневой (и глубже) вложенностью generic-полей, компилируется в WASM AOT, если резолюция статически возможна.

**Independent Test**: Фикстура с двухуровневым nested-generic захватом компилируется и выполняется в `zig build aot` идентично native-запуску.

**Полностью независима** от US1/US2/US4 — не делит файлы.

### Tests for User Story 3

- [X] T012 [P] [US3] Написать WASM-фикстуру с closure, захватывающей значение двухуровневой вложенности (`Коробка(Коробка(T))`-подобная форма) с конкретным nominal-аргументом для `T` — в `fixtures/`.
- [SKIPPED] T013 [P] [US3] Написать негативную фикстуру: тот же паттерн, но внутренний `T` статически не выводим — ожидается диагностика об отклонении, не крах. Дропнуто: каждая проверенная фикстура, где `показать[T]`'s closure реально достижим из `старт()`, типизировалась и лоуэрилась успешно даже ДО этого фикса — ветка `null` (отклонение) не воспроизводится ни одной достижимой фикстурой в текущем пайплайне; см. комментарий перед `"DOM.на_клик recursively promotes a nested struct capture"` в `tests/wasm/aot_closures_test.zig`.

### Implementation for User Story 3

- [X] T014 [US3] Перед кодированием — проверить, есть ли в `zig/core/mir_lowering.zig` или доступном ему коде готовый helper для подстановки generic-аргументов вложенного `.nominal` типа (аналог typechecker'а `instantiate_type`/`generic_instance_cache`); если нет — решить минимальную локальную реализацию (см. `research.md`'s "Decision: nested generic capture").
- [X] T015 [US3] `concreteCaptureFieldType` (`zig/core/mir_lowering.zig:2607-2618`) — расширить веткой для `field_type` = `.nominal`: рекурсивно подставить generic-аргументы вложенного nominal через аргументы внешнего `nominal`, вернуть получившийся `TypeId`.
- [X] T016 [US3] `classifyCaptureDepth`'s `.nominal`-ветка (`zig/core/mir_lowering.zig:2625-2640`) — подтвердить, что она получает уже полностью подставленный `concrete_type` из T015 без дополнительных изменений (рекурсия по глубине уже существует, `depth == 64` cutoff не трогать).
- [X] T017 [US3] Прогнать T012 через `zig build aot`, сравнить результат WASM-запуска с native-запуском той же фикстуры.
- [SKIPPED] T018 [US3] Прогнать T013, подтвердить понятную диагностику об отклонении (не тихий неверный кодогенерация). Зависела от T013, тоже дропнута.
- [X] T019 [US3] Прогнать существующий одноуровневый generic-capture regression-тест, подтвердить отсутствие регрессии.

**Checkpoint**: US3 завершена, когда T017-T019 зелёные.

---

## Phase 5: User Story 4 — Doc-комментарии функции видны в LSP hover (Priority: P3)

**Goal**: `textDocument/hover` включает текст `///`-doc-комментария декларации вместе с типом.

**Independent Test**: Hover на использование функции с doc-комментарием возвращает doc-текст; hover без doc-комментария не регрессирует.

**Полностью независима** от US1/US2/US3.

### Implementation for User Story 4

- [X] T020 [US4] `zig/core/runner.zig`'s `SourceAnalysis` — добавить `expressionDoc(self, expression: ast.ExprId) ?[]const u8`: через `resolution().expr_symbols.get(expression)` получить `SymbolId`, инвертировать `resolution().decl_symbols` (`AutoHashMap(DeclId, SymbolId)`, `resolver.zig:175`) в `AutoHashMap(SymbolId, DeclId)` на месте, через найденный `DeclId` — `tree.decl(decl_id)`, `switch` по варианту `ast.Decl` (`ast.zig:341-413`) — вернуть `.doc`, если вариант его несёт, иначе `null`.
- [X] T021 [US4] `zig/lsp/main.zig`'s `writeHoverResponse` (строка 1076-1084) — расширить сигнатуру опциональным `doc: ?[]const u8`; при наличии непустого `doc` — `contents.value` = `doc ++ "\n\n" ++ type_name`, `kind` остаётся `"plaintext"`.
- [X] T022 [US4] `zig/lsp/main.zig`'s `hover()` (строка 195-230) — после получения `type_name`, вызвать `analysis.expressionDoc(expression)`, передать результат в `writeHoverResponse`.
- [X] T023 [P] [US4] Расширить существующий hover JSON-RPC тест (`zig/lsp/main.zig:1713`) фикстурой с `///`-комментарием перед функцией — проверить, что `contents.value` содержит doc-текст.
- [X] T024 [P] [US4] Добавить тест: hover на декларацию без doc-комментария — `contents.value` содержит только тип, без регрессии.
- [X] T025 [P] [US4] Добавить тест: hover на decl-вариант без поля `.doc` (`import`/`impl`/`foreign`/`error_node`) — не паникует, doc-секция отсутствует.

**Checkpoint**: US4 завершена, когда T023-T025 зелёные.

---

## Phase 6: Polish & Cross-Cutting Validation

**Purpose**: Убедиться, что все четыре пункта вместе не сломали общий пайплайн, и прогнать полную quickstart-матрицу.

- [X] T026 [P] Прогнать все команды из `specs/012-hardening-phase-a/quickstart.md` ("Focused development loop" + ручные проверки каждого пункта).
- [X] T027 Прогнать `zig build test`, `zig build aot`, `zig build lsp`, `zig build browser` — все зелёные.
- [X] T028 Свериться с `contracts/embed-diagnostics-api.md` — подтвердить, что финальные сигнатуры (`format`/`writeGraph`/`Runtime.formatDiagnostics`/ре-экспорт `formatDiagnostic`) совпадают с задокументированным контрактом; обновить контракт только если реализация вынужденно отклонилась (с обоснованием).
- [X] T029 Обновить `docs/src/architecture/embedding.md`, если публичный API `panos_embed` изменился видимым для хоста образом (новый `Runtime.formatDiagnostics`/ре-экспорт `formatDiagnostic`).

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: без зависимостей, выполняется первой.
- **Phase 2 (US1)**: после T001; независима от US3/US4.
- **Phase 3 (US2)**: после T001; технически можно вести параллельно с US1, но делит `zig/embed.zig` — рекомендуется выполнять после T005 (после того как US1 добавила `Runtime.formatDiagnostics`), чтобы не мержить конфликтующие правки одного файла.
- **Phase 4 (US3)**: после T001; полностью независима от US1/US2/US4.
- **Phase 5 (US4)**: после T001; полностью независима от US1/US2/US3.
- **Phase 6 (Polish)**: после всех выбранных user story.

### User Story Dependencies

- **US1 (P1)**: независимый MVP — самый дешёвый, закрывает самый нужный пробел (см. spec.md "Why this priority").
- **US2 (P1)**: технически независима логически, но делит файл с US1 — сиквенс, не блокировка.
- **US3 (P2)**: полностью независима.
- **US4 (P3)**: полностью независима.

### Parallel Opportunities

- US3 и US4 можно вести полностью параллельно с US1/US2 и друг с другом (нет общих файлов).
- Внутри US1: T002/T003 (оба в `diagnostic.zig`) сиквенс; T006/T007 параллельны после T005.
- Внутри US2: T008/T009/T010 параллельны (разные `test`-блоки, один файл — координировать порядок вставки, не логику).
- Внутри US3: T012/T013 параллельны (разные фикстуры); T015 зависит от T014.
- Внутри US4: T023/T024/T025 параллельны после T020-T022.

---

## Parallel Example: одновременный старт всех четырёх user story

```text
Developer A: T002 → T003 → T004 → T005 → T006/T007 (US1)
Developer B: (после T005) T008/T009/T010 → T011 (US2)
Developer C: T012/T013 → T014 → T015 → T016 → T017/T018/T019 (US3)
Developer D: T020 → T021 → T022 → T023/T024/T025 (US4)
```

## Implementation Strategy

### MVP First

1. Complete T001.
2. Complete US1 (T002-T007) — самый дешёвый и самый нужный пункт, закрывает реальный пробел для любого embed-хоста.
3. Validate US1 independently, при желании остановиться здесь.

### Incremental Delivery

1. T001 → US1 (MVP) → US2 (тот же файл, следующий естественный шаг) → US3 → US4 → Phase 6.
2. Каждая story добавляет ценность, не ломая предыдущие — порядок можно менять местами для US3/US4 (P2/P3 независимы друг от друга и от US1/US2).

## Notes

- Каждая задача — один changeset, коммит после каждой задачи или логической группы (не смешивать US1 и US2 правки одного файла в одном коммите).
- US2's тест B (T009) фиксирует РЕАЛЬНОЕ, не желаемое поведение — не пытаться "починить" VM-состояние после паники в рамках этой задачи (вне scope, см. `research.md`).
- US3's T014 — открытый исследовательский шаг перед кодированием, не пропускать (см. `plan.md`'s "не гадать" установка).
- Completion (`documentation`-поле `CompletionItem`) явно вне scope US4 — не добавлять в эту задачу-серию.
