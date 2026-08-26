# Tasks: Нативный host-function registry для `внешний "хост"`

**Input**: Design documents from `specs/017-native-host-function-registry/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/embed-api.md, quickstart.md

**Tests**: включены — `spec.md` User Story 2 и User Story 4 по сути ЯВЛЯЮТСЯ
требованиями к диагностике/regression-безопасности, не проверяемыми иначе,
чем тестами.

**Organization**: задачи сгруппированы по user story из `spec.md` (US1..US4,
приоритеты P1/P1/P2/P1 соответственно — US3 (P2) идёт последней по
приоритету, хотя логически может делаться параллельно с US2/US4).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: можно делать параллельно (разные файлы, нет зависимости от
  незавершённых задач)
- **[Story]**: US1..US4, см. `spec.md`
- Пути файлов — абсолютные относительно корня `panos`-репозитория

## Path Conventions

Single project (сам panos-репозиторий, расширение существующих модулей —
см. `plan.md` "Project Structure", новых top-level директорий не создаётся):

- `zig/core/bytecode.zig`, `zig/core/resolver.zig`, `zig/core/vm.zig`
- `zig/embed.zig`
- `tests/embed_host_test.zig`
- `docs/src/architecture/embedding.md`

---

## Phase 1: Setup

**Purpose**: зафиксировать чистую отправную точку перед изменениями.

- [x] T001 Убедиться, что `zig build test && zig build integration` проходят
      на текущем `HEAD` ветки `017-native-host-function-registry` ДО первой
      правки (baseline для сравнения — вся фича обязана не сломать этот
      прогон, FR-007). **Готово**: `zig build test` — 63/63 шага,
      1860/1860 тестов; `zig build integration` — 5/5 шагов, 4/4 теста.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: инфраструктура, без которой ни один user story не собирается.

**⚠️ CRITICAL**: ни одна из задач Phase 3+ не начинается раньше завершения
этой фазы.

- [x] T002 [P] Добавить `pub fn marshalKindFor(comptime T: type)
      ast.ForeignMarshalKind` (comptime, `@compileError` на
      неподдерживаемый Zig-тип). **Отклонение от data-model.md,
      зафиксировано по ходу реализации**: живёт в новом
      `zig/core/host_registry.zig` (не `zig/embed.zig`) — `resolver.zig`
      (ядро) не может импортировать `zig/embed.zig` (тот наоборот зависит
      от ядра), поэтому тип `HostFunctionEntry`/логика marshal-вывода
      обязаны жить в `zig/core/`, `embed.zig` только реэкспортирует.
      `КСтрока` на Zig-стороне — `[]const u8` (не `[:0]const u8`): для
      native-пути (Zig→Zig, не настоящий C ABI) null-terminated буфer не
      нужен вообще, это чистый выигрыш простоты. `.pointer` — явный
      `@compileError` (см. комментарий в файле: у него до сих пор нет
      представления в `value.Value` даже на dynlib-FFI пути).
- [x] T003 [P] Добавить `pub const HostFunctionEntry` struct и
      `pub const NativeCallFn` в `zig/core/host_registry.zig` (поля — см.
      `data-model.md` с поправкой: `call: NativeCallFn = *const fn (heap:
      *gc.Heap, args: []const value.Value) anyerror!value.Value` — `*gc.Heap`,
      не просто `std.mem.Allocator`, потому что возврат `КСтрока`/
      `ff_структура` должен идти через `heap.createString`/
      `heap.createAggregate` — тот же GC-путь, что уже использует
      dynlib-FFI в `vm.zig` (`invokeForeign`), иначе возвращаемые строки/
      структуры не были бы GC-отслеживаемыми).
- [ ] T004 Добавить `pub const ForeignCallKind = enum { dynlib_libffi,
      native_registry }` и поля `call_kind: ForeignCallKind`, `native_call:
      ?*const fn ([]const value.Value) anyerror!value.Value` в
      `bytecode.ForeignFunctionConstant` (`zig/core/bytecode.zig:16`).
      Существующее поле `fn_ptr` остаётся, используется только при
      `call_kind == .dynlib_libffi`.
- [x] T005 Проверить места конструирования `.foreign_function = .{...}`
      (единственное — `compiler.zig:1293`). **Правка не потребовалась**:
      T004 дал новым полям (`call_kind`, `native_call`, `fn_ptr`)
      Zig-defaults, существующий литерал компилируется и ведёт себя
      идентично без единой правки (`zig build` зелёный) — более
      хирургично, чем изначально предполагалось в этой задаче.
- [x] T006 Прокинуть `host_registry`. **Реализовано проще, чем
      предполагалось** (реальный вызывающий граф оказался у́же): единственный
      прямой вызывающий `resolveModuleForTarget` вне `resolver.zig` —
      `module_compiler.zig:985`. Вместо протаскивания нового параметра
      через 13+ вызывающих `compileGraph`/`compileGraphForTarget` мест —
      добавлено поле `host_registry: []const host_registry.HostFunctionEntry
      = &.{}` прямо в `module_loader.Graph` (тот же паттерн, что уже есть
      у `global_search_roots`), плюс НОВЫЙ параметр в
      `resolveModuleForTarget`/`Resolver`/`Resolution.native_foreign_functions`
      (только это единственное место вызова + `resolveModule`-обёртка).
      `compileGraph`/`compileGraphForTarget` и все их 13 вызывающих не
      тронуты — читают `graph.host_registry` неявно. Добавлен
      `Resolver.findHostRegistryEntry` + ветка в `resolveForeignFunction`
      ДО `dlopen(NULL)`/`dlsym` — этим же проходом закрыты T009 (поиск в
      registry) и T012 (валидация сигнатуры, US2), см. их пометки ниже.
      **Промежуточное отклонение от data-model.md (позже устранено)**:
      сначала `NativeCallFn`/`ForeignFunctionConstant.native_call` взяли
      `heap: *anyopaque`, не `*gc.Heap` — `bytecode.zig`/`host_registry.zig`
      импортируются лёгкими core-модулями (`resolver.zig`,
      `module_loader.zig`), которым нельзя тянуть `gc.zig` →
      `sqlite3_bindings.zig` (ловил на практике: `zig build test` ломался
      — 15 таргетов, `undefined symbol: _sqlite3_close_v2`, т.к. build.zig
      не линкует sqlite3 для этих per-file test-таргетов).
      **По прямому вопросу пользователя ("зачем gc вообще тащит sqlite3, и
      почему anyopaque — это хорошая идея") пересмотрено и исправлено в
      корне**: единственная причина связки — `Heap.destroy()`'s ветка
      `.sql_connection` (`gc.zig`, была строка 293) напрямую звала
      `sqlite3.sqlite3_close_v2`. Убрал импорт `sqlite3_bindings.zig` из
      `gc.zig` целиком; добавил `Heap.sql_close_fn: ?*const fn (db:
      ?*anyopaque) void = null` — инжектируется `Vm.init` (`vm.zig`,
      который и так уже импортирует sqlite3 для `бд.*`), под тем же
      `comptime builtin.target.os.tag != .freestanding`-гардом, что и
      остальные sqlite3-точки этого файла (иначе взятие адреса
      `&closeSqlConnection` заставило бы freestanding/browser-таргет тоже
      требовать линковку sqlite3 — проверено, что без гарда сломало бы
      `zig build browser`). После этого `NativeCallFn`/
      `ForeignFunctionConstant.native_call`/трамплины `hostFunctions()`
      вернули `*gc.Heap` НАПРЯМУЮ — каст `@ptrCast(@alignCast(...))`
      убран полностью, полная типобезопасность. Полный прогон после
      фикса: `test` 65/65/1944/1944 (было 1884 — рост за счёт того, что
      `gc.zig`'s собственные тесты теперь безопасно достижимы из большего
      числа таргетов), `conformance` 23/23/46/46, `integration` 5/5/4/4
      (реальные SQLite-тесты — подтверждают, что `closeSqlConnection`
      функционально корректен, не только компилируется), `aot` 29/29/66/66,
      `lsp`/`browser` — оба чисто собираются.
- [x] T007 Добавлено поле `host_functions: []const
      panos_core.host_registry.HostFunctionEntry = &.{}` в `Runtime.Config`
      (`zig/embed.zig`), `Runtime.init` кладёт его в
      `graph_state.host_registry` (тот же паттерн, что `global_search_roots`).

**Checkpoint пройден**: `zig build test` — 63/63 шага, 1879/1879 тестов
(было 1860 на T001-baseline — рост за счёт новых веток
reachability/тестов через раздвинутый граф импортов, не регрессия);
`zig build integration` — 5/5, 4/4. Registry существует и прокинут по всей
цепочке до реального вызова (тот всё ещё не подключён — Phase 3).

---

## Phase 3: User Story 1 — Регистрация без `pub export fn`/`rdynamic` (Priority: P1) 🎯 MVP

**Goal**: движок регистрирует Zig-функцию, `.pns`-скрипт зовёт её через
`внешний "хост"`, без `pub export fn`/`rdynamic`.

**Independent Test**: `Runtime.init` с `host_functions =
panos.hostFunctions(.{ .scale = scale })`, скрипт `внешний "хост" функ
scale(x: Число(64)) -> Число(64)`, `scale(21.0)` возвращает `42.0`; тестовый
бинарник собирается без `rdynamic`.

### Implementation for User Story 1

- [x] T008 [US1] Реализовано `pub fn hostFunctions(comptime table: anytype)
      []const HostFunctionEntry` в `zig/embed.zig` + `buildHostFunctionEntry`
      + `unpackHostArg`/`unpackHostStruct`/`packHostResult`/`packHostStruct`.
      **Найдено по ходу и потребовало отдельного фикса**: сам вызов
      `hostFunctions(...)` в обычной (не comptime) позиции — например,
      прямо внутри `Runtime.Config`-литерала — НЕ форсирует comptime-
      вычисление всего тела только потому, что параметр помечен
      `comptime table: anytype` (это фиксирует лишь сам параметр); без
      явного `return comptime blk: { ... }` компиляция падала с "cannot
      store runtime value in compile time variable". Trampoline —
      `fn (heap: *gc.Heap, args: []const Value) anyerror!Value` (после
      фикса связки gc/sqlite3, см. T006 — изначально был `*anyopaque` с
      ручным кастом, сейчас типобезопасно напрямую).
      Возврат `[]const u8`/`ff_структура` копируется в GC через
      `heap.createString`/`heap.createAggregate` (та же конвенция, что
      dynlib-путь в `vm.zig`).
- [x] T009 [US1] Реализовано вместе с T006 (см. пометку там) —
      `Resolver.findHostRegistryEntry` + ветка в `resolveForeignFunction`
      ПЕРЕД `dlopen(NULL)`/`dlsym`.
- [x] T010 [US1] В `vm.zig`: `callForeign`'s guard `fn_ptr == 0` разведён
      по `call_kind` (native_registry проверяет `native_call == null`, не
      `fn_ptr` — тот всегда 0 для этого пути, это не признак ошибки).
      `invokeForeign` в самом начале — `if (info.call_kind ==
      .native_registry) return info.native_call.?(&self.heap, arguments);`
      — до входа в `cachedForeignCall`/`ffi_prep_cif`/`ffi_call` целиком.
      `.dynlib_libffi` — код ниже не тронут.
- [x] T011 [US1] Отдельный файл `tests/embed_host_registry_test.zig` (не
      `embed_host_test.zig` — тот уже требует `rdynamic` для СВОЕГО
      сценария в том же build-таргете, отдельный файл даёт отдельный
      build.zig-таргет БЕЗ `rdynamic`, честно доказывая независимость
      registry-пути). Тест "registry-resolved host function works without
      pub export fn/rdynamic" — зелёный.

**Checkpoint пройден**: US1 полностью работает и тестируется независимо
(`zig build test` — 65/65 шагов, 1883/1883 тестов; `zig build integration`
— 5/5, 4/4). MVP-срез фичи готов.

---

## Phase 4: User Story 2 — Несовпадение сигнатуры ловится до выполнения (Priority: P1)

**Goal**: рассинхронизация `.pns`-декларации и зарегистрированной
Zig-функции — `Resolve Error`, не крэш/UB.

**Independent Test**: зарегистрирована функция с N параметрами, `.pns`
объявляет `внешний "хост"` с другим N (или другим marshal kind) —
`Runtime.compile()`/резолв возвращает диагностику, дальше не идёт.

### Implementation for User Story 2

- [x] T012 [US2] Реализовано вместе с T006/T009 — проверка числа
      параметров, marshal kind каждого параметра, marshal kind возврата,
      каждая — отдельный `self.report(foreign.span, "Resolve Error: ...")`
      с именем функции и характером несовпадения, `return` без записи в
      `native_foreign_functions`.
- [x] T013 [P] [US2] Тест "signature mismatch (parameter count) is a
      Resolve Error, not a crash" в `tests/embed_host_registry_test.zig` —
      зарегистрирована `scale(f64) f64`, `.pns` объявляет 2 параметра.
      **Уточнение по ходу**: ошибка резолва `внешний` появляется на этапе
      `Runtime.compile()` (не `load()`) — `hasGraphErrors()` после
      `load()` остаётся `false`, нужно `try runtime.compile()` +
      `hasCompilationErrors()`. Зелёный.
- [x] T014 [P] [US2] Тест "signature mismatch (marshal kind) is a Resolve
      Error, not a crash" — `addInts(i32, i32) i32`, `.pns` объявляет
      `Число(64)` вместо `Целое(32)`. Та же уточнённая проверка через
      `compile()`. Зелёный.

**Checkpoint пройден**: несовпадающие сигнатуры гарантированно не
доходят до вызова — обе диагностики ловятся на резолве.

---

## Phase 5: User Story 4 — Существующий путь не ломается, registry приоритетнее (Priority: P1)

**Goal**: `pub export fn`+`rdynamic`+`dlsym`-путь продолжает работать
один в один; при коллизии имени registry побеждает.

**Independent Test**: `zig build test`/`zig build integration` без
изменений в существующем `tests/embed_host_test.zig`-сценарии проходят
как раньше; отдельный тест на коллизию имени подтверждает приоритет
registry.

### Implementation for User Story 4

- [x] T015 [US4] Ревью подтверждён: `findHostRegistryEntry` — отдельная
      `else if`-ветка ВЫШЕ существующей `dlopen(NULL)`/`dlsym`-ветки в
      `resolveForeignFunction`, не встроена внутрь неё. При `null`
      (пусто/нет совпадения) `if`-цепочка проваливается в следующую
      `else if` без побочных эффектов — существующий код байт-в-байт.
- [x] T016 [P] [US4] `tests/embed_host_test.zig` — файл НЕ ИЗМЕНЁН,
      проходит в общем прогоне (65/65 шагов, 1883/1883 тестов) — 0
      регрессии.
- [x] T017 [US4] Тест "registry entry wins over a same-named pub export fn
      symbol" в `tests/embed_host_registry_test.zig` —
      `panos_embed_host_priority_probe` существует и как `pub export fn`
      (`+1000.0`, недостижим — файл этого таргета БЕЗ `rdynamic`), и как
      registry-запись (`+1.0`, реально вызывается) — результат подтверждает
      победу registry. Побочный эффект: раз `rdynamic` не включён для
      этого таргета, тест заодно доказывает, что fallback на dlsym для
      этого имени физически не сработал бы (символа нет в таблице) —
      усиливает, не ослабляет проверку. Зелёный.

**Checkpoint пройден**: обратная совместимость (0 регрессии) и приоритет
registry подтверждены тестами.

---

## Phase 6: User Story 3 — Вызов минует libffi на горячем пути (Priority: P2)

**Goal**: registry-вызов не создаёт `ffi_cif`, не вызывает `ffi_call`.

**Independent Test**: N вызовов registry-функции подряд — ноль обращений
к `ffi_prep_cif`/`ffi_call` (проверяется на уровне реализации/структурно,
не только "по дизайну").

### Implementation for User Story 3

- [x] T018 [US3] Тест "registry path never touches the libffi cif cache"
      в `tests/embed_host_registry_test.zig` — использует существующий
      `--profile-ffi`-механизм (`foreign_profile_enabled` +
      `writeForeignProfile`) как чёрный ящик: после 5 вызовов профиль
      обязан показать `ffi_call=0 us` (заполняется только
      `recordForeignNativeTime`, вызывается только из libffi-ветки) И
      `cache hit/miss=5/0` (0 промахов НИ РАЗУ, включая первый вызов —
      недостижимо для dynlib-пути, где кэш стартует пустым). Оба сигнала
      напрямую следуют из того, что `invokeForeign` возвращает через
      `.native_registry`-ветку ДО входа в `cachedForeignCall` — единственное
      место, где вообще существует libffi-код. Зелёный.
- [~] T019 [P] [US3] Опциональный микро-бенчмарк — **осознанно пропущен**.
      Явно помечен опциональным и не блокирующим в самой задаче/spec.md
      ("Не строгий SLA... не блокирует прохождение фичи"); структурное
      доказательство T018 уже даёт то, что реально требуют FR/SC этой
      фичи (SC-003 — "измеримо инструментацией/тестом... не только по
      дизайну", что T018 и есть). Добавлять инфраструктуру формального
      бенчмарка ради необязательной задачи — лишний вес (Simplicity
      First, `.specify/memory/constitution.md`).

**Checkpoint пройден**: заявленная в US3 экономия подтверждена структурно
и тестом (T018), не только по дизайну.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [x] T020 [P] Дополнен `docs/src/architecture/embedding.md` разделом
      "Альтернатива: регистрация без pub export fn/rdynamic" — пример,
      диагностика, приоритет при коллизии. Заодно поправлен doc-комментарий
      `Runtime` в `zig/embed.zig` (раньше утверждал, что `pub export fn`+
      `rdynamic` — единственный путь).
- [x] T021 Полный прогон: `test` 65/65 шагов/1884/1884 тестов,
      `conformance` 23/23/46/46, `integration` 5/5/4/4, `aot` 29/29/66/66,
      `lsp`/`browser` (wasm32-freestanding) — оба собираются чисто. Ноль
      падений вне зоны фичи, ноль регрессии freestanding-таргета (важно —
      `внешний`/registry обязаны оставаться недоступны там).
- [x] T022 Пройден шаг за шагом как временный test-таргет (собран,
      прогнан, удалён вместе с временной правкой `build.zig` — не осталось
      в дереве). **Нашёл и исправил реальное расхождение**: шаг 5
      утверждал, что `runtime.compile()` возвращает
      `error.ScriptCompileFailed` при несовпадении сигнатуры — по факту
      `compile()` возвращает `void` без ошибки, несовпадение видно только
      через `hasCompilationErrors()` (та же семантика, что и любая другая
      ошибка компиляции скрипта). Поправлено в `quickstart.md`.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: без зависимостей.
- **Foundational (Phase 2)**: зависит от Phase 1 — БЛОКИРУЕТ все user
  stories (T002-T007 создают типы/плумбинг, которым пользуются все
  четыре истории).
- **US1 (Phase 3)**: зависит от Phase 2. Это MVP — минимальный срез,
  доказывающий, что схема в целом работает.
- **US2 (Phase 4)**: зависит от Phase 3 (T009 — точка вставки, которую
  T012 расширяет проверкой сигнатуры) — не независима от US1 на уровне
  кода, хотя по духу spec.md это отдельная история.
- **US4 (Phase 5)**: зависит от Phase 3 (T009) для T017 (тест приоритета);
  T015/T016 технически можно гонять сразу после Phase 2 (это проверки
  СУЩЕСТВУЮЩЕГО кода), но логичнее держать рядом с остальной валидацией
  того же среза.
- **US3 (Phase 6)**: зависит от Phase 3 (T010 — реализация
  `.native_registry`-вызова, которую T018 проверяет).
- **Polish (Phase 7)**: зависит от завершения всех выбранных user stories.

### Parallel Opportunities

- T002/T003 (Phase 2) — разные декларации в одном файле, но независимы
  друг от друга по содержанию — можно писать параллельно, коммитить
  вместе.
- T013/T014 (US2) — разные тестовые кейсы, независимы.
- T016 (US4, прогон существующего теста) не пересекается по файлам ни с
  чем — параллелится с T012-T014.
- T019 (US3, бенчмарк) — опционален, не блокирует ничего дальше.

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Phase 1 (T001, baseline).
2. Phase 2 (T002-T007, инфраструктура — без неё ничего не собирается).
3. Phase 3 (T008-T011, US1) — движок может регистрировать и вызывать
   host-функции без `pub export fn`/`rdynamic`.
4. **STOP and VALIDATE**: T011 проходит, `zig build test` зелёный.

На этом этапе фича уже даёт основную заявленную ценность (SC-001). US2/
US4/US3 закрывают безопасность (несовпадение сигнатур), совместимость и
производительность — важны для продакшена, но не для демонстрации
жизнеспособности идеи.

### Incremental Delivery

1. Phase 1+2 → фундамент, ничего пользовательского ещё не видно.
2. + US1 (Phase 3) → MVP: `hostFunctions` работает end-to-end.
3. + US2 (Phase 4) → безопасно для реального использования (плохая
   сигнатура не роняет рантайм).
4. + US4 (Phase 5) → подтверждено, что ничего не сломано у существующих
   потребителей (`../jijka` может подключать фичу без страха регрессии).
5. + US3 (Phase 6) → подтверждена вторая половина исходной мотивации
   (оверхед на горячих путях).
6. Phase 7 → документация и финальный regression gate.

---

## Notes

- [P] задачи — разные файлы/разные независимые куски одного файла, без
  зависимости от незавершённых задач.
- Commit — после каждой задачи или логической группы (T008-T011 как один
  логический блок US1, например) — конвенция коммитов на русском языке,
  без упоминания ассистента (`.specify/memory/constitution.md`,
  "Commit Messages").
- Останавливаться и проверять на каждом Checkpoint — не переходить к
  следующей фазе с непройденными тестами предыдущей.
