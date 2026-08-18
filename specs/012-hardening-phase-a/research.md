# Research: Hardening Phase A

## Decision: перенести рендер диагностик в `panos_core.diagnostic`, не в `panos_embed`

**Rationale**: `zig/cli/main.zig`'s `formatDiagnostic`/`writeGraphDiagnostics`
(строки 5-32, 70-84) уже используют только `panos_core` типы
(`source.SourceFile`, `diagnostic.Diagnostic`, `module_loader.Graph`) —
никакой CLI-специфичной логики внутри нет. `panos_core.diagnostic` —
естественное место рядом с `Diagnostic`/`DiagnosticList` самими.
Помещение в `panos_embed` вместо этого сделало бы `zig/cli` зависимым
от `panos_embed` только ради рендера (лишняя зависимость), тогда как
и CLI, и embed уже оба зависят от `panos_core` напрямую (`build.zig`).

**Alternatives considered**:

- Оставить копию в `zig/cli/main.zig`, добавить отдельную копию в
  `zig/embed.zig`: воспроизводит уже существующее дублирование, прямо
  то, что план называет проблемой.
- Поместить в `panos_embed`, `zig/cli` — импортировать оттуда: рабочий
  вариант, но создаёт асимметричную зависимость (CLI не должен
  зависеть от embed-API, это разные уровни абстракции — embed
  оборачивает core для внешних хостов, CLI сам является хостом).

## Decision: `Runtime.formatDiagnostics` как высокоуровневый helper поверх ре-экспортированного `format`

**Rationale**: Низкоуровневый `panos_core.diagnostic.format` требует
`SourceFile` на входе — хост должен был бы сам искать нужный файл в
графе модулей. `writeGraphDiagnostics`-логика (`moduleForFile` lookup +
fallback на голое сообщение) уже решает это один раз в `cli/main.zig` —
перенос её целиком в `panos_core.diagnostic.writeGraph` и обёртка
`Runtime.formatDiagnostics` избавляет каждого будущего embed-хоста от
повторного изобретения этого lookup.

**Alternatives considered**:

- Экспортировать только низкоуровневый `format`, оставить lookup хосту:
  дешевле в реализации, но воспроизводит именно тот пробел, что находка
  плана явно называет ("хост обязан САМ переизобрести... рендер").

## Decision: error-path тесты живут в `zig/embed.zig`, не в отдельном файле

**Rationale**: Единственный существующий тест `panos_embed` уже живёт
внутри `zig/embed.zig` (строки 189-240), использует `MemoryReader`,
объявленный там же. Три новых теста — тот же размер и тот же стиль;
вынос в `tests/embed_diagnostics_test.zig` добавил бы файл и
дублирующий `MemoryReader`/импорты без выигрыша (Simplicity First).

**Alternatives considered**:

- `tests/embed_host_test.zig` (уже существующий e2e-тест): читает
  реальные `.pns`-файлы с диска через настоящий `Runtime`, другой стиль
  (host-integration, не unit) — не подходящее место для узких
  error-контрактов.

## Decision: тест B (call после runtime-паники) фиксирует РЕАЛЬНОЕ поведение, не желаемое

**Rationale**: `Runtime.run()` (`zig/embed.zig`, внутренний `fn run`)
только чистит `machine.output` перед каждым вызовом — не сбрасывает и
не проверяет никакое состояние VM после `.runtime_error`. Контракт
plan.md's US2 Acceptance Scenario 2 явно допускает оба исхода ("либо
поведение явно задокументировано, если Runtime намеренно переходит в
нерабочее состояние") — задача теста здесь не решить архитектурный
вопрос "должен ли Runtime переживать панику", а зафиксировать текущее
поведение как явный regression-тест, чтобы будущее изменение было
осознанным, не случайным.

**Alternatives considered**:

- Считать поведение багом и чинить VM/embed layer, чтобы гарантировать
  переживание паники: выходит за рамки "тестовое покрытие" (US2) в
  архитектурное изменение `panos_core.vm` — не входит в Phase A по
  spec.md (не new capability, а verification).

## Decision: nested generic capture — подстановка через существующий nominal-arguments путь, не новая type-инстанциация

**Rationale**: `concreteCaptureFieldType` уже умеет резолвить БЭРНЫЙ
`.generic_parameter` через `nominal.arguments` заданного (внешнего)
nominal-типа (`type_checker.nominalParametersOf`). Проблема — только в
том, что при `field_type` = вложенный `.nominal` (не бэрный
placeholder) функция сегодня возвращает его КАК ЕСТЬ, не подставляя
generic-аргументы этого вложенного nominal-типа собственными
аргументами внешнего. Правильная рекурсия — не создание нового
type-инстанциирующего механизма, а применение УЖЕ существующей
one-level подстановки к каждому аргументу вложенного nominal перед тем,
как передать получившийся тип дальше в `classifyCaptureDepth`.

**Alternatives considered**:

- Полноценная generic-инстанциация типа (аналог typechecker'а
  `instantiate_type`/`generic_instance_cache`, упомянутых в
  `CLAUDE.md`): более общее решение, но typechecker'а API работает на
  уровне `type_checker.CheckResult` до compile-time лоуэринга;
  переиспользование напрямую в `mir_lowering.zig` требует
  предварительной проверки, доступен ли этот механизм в нужной точке
  пайплайна (см. plan.md's US3 шаг 2 — открытый вопрос перед
  кодированием, не решается заранее в research).
- Ограничиться диагностикой на любую вложенность глубже одного уровня
  (статус-кво): не решает FR-005/US3, оставляет узкий, но
  задокументированный gap открытым — именно то, что этот проход должен
  закрыть.

## Decision: hover остаётся `"plaintext"`, doc-текст конкатенируется перед типом

**Rationale**: `writeHoverResponse` сегодня жёстко пишет
`"kind":"plaintext"` (`zig/lsp/main.zig:1076-1084`). LSP-протокол
поддерживает `MarkupContent.kind = "markdown"`, что дало бы более
чистое форматирование (например, doc в отдельном блоке, тип —
code-span), но это смена формата ответа для ВСЕХ hover-клиентов, не
только тех, что показывают doc. Простая конкатенация в существующем
`plaintext`-формате — минимальное изменение, достаточное для FR-007/
FR-008, не меняющее ничего для деклараций без doc-комментария.

**Alternatives considered**:

- Переключить на `"markdown"` kind: лучше выглядит в редакторах с
  markdown-рендером hover, но не запрошено ни в spec.md, ни в исходном
  hardening-плане — спекулятивное расширение, отклонено по Simplicity
  First.

## Decision: `expressionDoc` строит обратную карту `SymbolId → DeclId` на месте, без постоянного индекса

**Rationale**: `Resolution.decl_symbols` — прямая карта `DeclId →
SymbolId` (`resolver.zig:175`), обратного индекса нет. LSP-сессия
анализирует один файл за раз (`analyzeSource` в `hover()`), decl'ов на
файл — единицы-десятки; построение `AutoHashMap(SymbolId, DeclId)`
инвертированием на каждый hover-запрос — O(n) по декларациям файла,
пренебрежимо дёшево относительно остальной работы `analyzeSource`
(полный lex→parse→resolve→typecheck). Постоянный индекс добавил бы
состояние, которое нужно инвалидировать при каждом изменении документа
— не оправдано для этого объёма данных.

**Alternatives considered**:

- Добавить обратную карту прямо в `Resolution` (заполнять во время
  резолвинга): дешевле на каждый hover, но меняет структуру данных,
  используемую везде в резолвере, ради одного потребителя (LSP hover) —
  нарушает Surgical Changes для минимальной пользы при таком масштабе
  данных.
