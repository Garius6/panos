# Panos — Задачи

**Текущая стадия**: готовы 0, 2, 3, 6 (вне очереди), 5 частично (Symbol_Id +
LSP completions/references/rename; Type_Id отложен). Следующие
разблокированные: 1 (GC), 4 (FFI-A), 7 (Generics, требует 6 ✓). Type_Id/SoA
(остаток Стадии 5) — отдельная перформансная задача без явного триггера.
**Roadmap**: [ROADMAP.md](ROADMAP.md)

Работа отслеживается через mkdnflow.nvim в Neovim. `<CR>` на строке
переключает состояние checkbox'а. Родительские элементы обновляются
автоматически.

## Легенда

- `- [ ]` — не начато
- `- [-]` — в работе
- `- [x]` — готово

Отменённые/отложенные задачи помечаются строкой `(отложено: причина)` без
изменения checkbox'а — так они видны в progress-view.

---

## Стадия 0 — Foundation cleanup

Refs: [ROADMAP §Стадия 0](ROADMAP.md#стадия-0--foundation-cleanup),
[type-checker analysis](specs/001-adt-pattern-matching/reviews/type-checker-analysis.md).

Цель: −209 строк type-checker'а, устранение дублей и утечек памяти. Zero
risk, разблокирует всё последующее.

### Волна 1 рефакторинга type-checker'а

- [x] P2 — helper `resolve_variant_ctor` (унифицировать 3 места
      Enum_Variant construction, `type_cheker.odin:1523-1772`)
- [x] P3 — `variant_index: map[string]int` в `Type` + helper
      `variant_index(enum_type, name) -> (int, bool)`
- [x] P5 — synth cache `Type_Ctx.synth_enum_cache: map[^Type]^Type` +
      `synth_enum_view(ctx, base)`
- [x] P12 — убрать двойные `prune_type(prune_type(x))` вызовы
- [x] P13 — `BASE_TYPES` map + добавить `Никогда` (сейчас баг:
      `функ f() -> Никогда` падает)
- [x] P14 — убрать `Match_Arm_Info` wrapper, использовать `Pattern_Info`
      напрямую
- [x] P15 — унифицировать `variant_calls` + `variant_idents` в
      единый `variant_ctors: map[Expr]Variant_Ctor_Info` (включает P4-часть)

### Verification

- [x] `odin test .` — 38/38 тестов зелёные
- [x] `odin run . -- test.ps` — без регрессий
- [x] Type-checker строк ≤ 2150 (было 2359) — **не достигнуто**: итог
      2289 строк (−70). Дедупликация и утечки устранены как задумано,
      но добавленная инфраструктура (helper'ы, кэш, docstring'и)
      компенсировала часть экономии — расхождение с прогнозом отчёта
      (−209), не регрессия.

### Delivery

- [x] Коммит с русскоязычным описанием изменений — `3055f10`

---

## Стадия 1 — Runtime memory model (GC)

Refs: [ROADMAP §Стадия 1](ROADMAP.md#стадия-1--runtime-memory-model-gc-2-недели).

Prerequisite: Стадия 0 закрыта. Разблокирует FFI-B (finalizers) и
long-running scenarios.

### Prerequisites

- [ ] `^Panos_String` обёртка для runtime-строк
      (`{ bytes: []u8, len: int }`)
- [ ] Migration runtime-strings (concat, substring, string builder)

### Core GC

- [ ] `GC_State` + `mem.Allocator` interface (`gc_allocator :: proc(state)`)
- [ ] `GC_Header` layout: `{kind, mark, size, next}`, placed before payload
- [ ] `gc_new[T]` helpers через compile-time `when` для kind resolution
- [ ] Value walker для 11 вариантов Value union (force полный switch)
- [ ] Root walker: `vm.stack`, `vm.frames`, `vm.compiled_functions`
- [ ] Mark phase (recursive from roots)
- [ ] Sweep phase (walk all_objects list)
- [ ] Adaptive threshold (следующий GC при 2x live memory)

### Integration

- [ ] Split allocator lifecycle в `main.odin`: arena для compile-phase,
      GC для runtime
- [ ] Migration `new(X)` → `gc_new(X)` в vm.odin (~30 мест)
- [ ] Migration `make([dynamic]Value)` — явный allocator из GC context

### Instrumentation

- [ ] `gc_stats(state)` — статистика (allocated, freed, collections)
- [ ] `force_gc(state)` — для тестов
- [ ] Verbose mode (env var / flag) — логи каждой коллекции

### Tests

- [ ] Программа с миллионом allocation'ов в цикле — память не растёт
- [ ] Циклические ссылки собираются (interface → self)
- [ ] Closure captured variables не освобождаются пока closure жив
- [ ] Все существующие 38 тестов проходят
- [ ] Memory-tracker не показывает runtime-leaks (только compile-time
      arena, которая освобождается deferred)

### Delivery

- [ ] Отдельные коммиты per major step (allocator interface, walker,
      migration, tests)

---

## Стадия 2 — DOD Волна 1 + Diagnostic accumulation (готово, коммит `7659f8e`)

Refs: [ROADMAP §Стадия 2](ROADMAP.md#стадия-2--dod-волна-1--diagnostic-accumulation-15-недели).

Prerequisite: Стадия 0. Разблокирует LSP.

Архитектура: eager unify + `TY_POISON` (текущий подход), **не**
constraint-based generate-then-solve. Обсуждено и отклонено для этой
стадии — подробности [ROADMAP §Стадия 2](ROADMAP.md#стадия-2--dod-волна-1--diagnostic-accumulation-15-недели)
(раздел "Архитектурная развилка"). Constraint-based рассмотреть в
Стадии 7 (там он естественно нужен под let-generalization).

- [x] `Span {file_id: u16, start: u32, end: u32}` struct
- [x] Span в токенах
- [x] Span в AST-узлах — **43 struct'а, не ~15** (стек-план был занижен,
      см. подробную инвентаризацию перед реализацией)
- [x] `Interned :: distinct u32` + `String_Interner` — с mutex'ом и
      heap-allocator'ом (глобальный синглтон, `odin test` гоняет 10
      потоков параллельно, без синхронизации ловили гонку данных)
- [x] Migration `Ident_Expr.name`, `Symbol.name` на Interned. `Type.name`
      **осознанно не тронут** — используется и для equality lookup, и
      для печати в diagnostic-сообщениях; interning дал бы только
      resolve-боль без выигрыша (решение зафиксировано перед стартом)
- [x] `Diagnostic {severity, span, message}` struct (без отдельного поля
      `args` — message форматируется сразу в `report()`)
- [x] `Type_Ctx.diagnostics: [dynamic]Diagnostic`
- [x] `TY_POISON` тип для non-cascade error propagation
- [x] Migration `fmt.panicf` → `report(ctx, span, ...)` — 109 из 116
      сайтов в type_cheker.odin; 7 внутренних инвариантов (не
      user-facing, напр. рассинхронизация resolver/typechecker)
      остались panic'ами осознанно
- [x] `expect_diagnostic(t, diagnostics, expected)` + `typecheck_only(source)`
      test helper'ы в e2e_test.odin
- [x] Migration e2e-тестов на diagnostic vector — **не переписывали 9
      существующих `expect_assert`-тестов**, вместо этого добавили мост
      `panic_on_diagnostics` (паникует текстом первого diagnostic'а) —
      все прошли без изменений; `expect_diagnostic` доступен для новых
      multi-error тестов

---

## Стадия 3 — LSP MVP ✅

Refs: [ROADMAP §Стадия 3](ROADMAP.md#стадия-3--lsp-mvp-15-недели).

Prerequisite: Стадия 2.

- [x] LSP server skeleton (JSON-RPC 2.0 over stdio) — `lsp/lsp_transport.odin`
- [x] `initialize` / `shutdown` handshake
- [x] Full-reparse on `textDocument/didChange`
- [x] `textDocument/publishDiagnostics`
- [x] `textDocument/hover` — тип под курсором
- [x] `textDocument/definition` — go-to-def (только внутри одного файла,
      без графа импортов — известное ограничение MVP)
- [x] ~~VS Code extension skeleton~~ — заменено на Neovim-интеграцию
      (`editors/nvim/`, filetype-детект + `vim.lsp.start()`) по прямому
      указанию пользователя вместо VS Code
- [x] Position mapping UTF-16 ↔ UTF-8 — `lsp/lsp_position.odin`
- [x] ~~E2E тесты через vscode-languageserver-testkit~~ — верифицировано
      кастомным Python JSON-RPC клиентом + headless Neovim 0.12 вместо
      vscode-инструментария (нет VS Code extension'а)

Архитектура: код разделён на `core/` (общий пакет — лексер/парсер/резолвер/
тайпчекер/компилятор/VM) и 2 независимых `package main` бинарника —
`panos` (интерпретатор, корень) и `panos-lsp` (`lsp/`). Изначально
планировался один бинарник с `--lsp` флагом, но Odin запрещает циклические
импорты между `main` и подпакетом, который импортирует `main` обратно —
двухбинарная схема снимает проблему.

---

## Стадия 4 — FFI фаза A: raylib demo

Refs: [ROADMAP §Стадия 4](ROADMAP.md#стадия-4--ffi-фаза-a-raylib-demo-3-дня).

Prerequisite: нет. Независимо.

- [ ] `raylib_bindings.odin` — foreign import + ~50 функций
- [ ] Panos-модуль `графика` в stdlib
- [ ] Demo: pong / snake в `demos/`
- [ ] README gif с демо

---

## Стадия 5 — DOD Волна 2 + LSP расширение (частично)

Refs: [ROADMAP §Стадия 5](ROADMAP.md#стадия-5--dod-волна-2--lsp-расширение-2-3-недели).

Prerequisite: Стадия 3.

- [x] `Symbol_Id :: distinct u32` + `Symbol_Store` — реализовано как
      `[dynamic]Symbol` (AoS) + индекс, а не колоночный SoA из ROADMAP
      (columns: names/kinds/scope_ids/...). Даёт стабильные ID и дешёвые
      Symbol_Id→usage таблицы (главная цель LSP-фич ниже) без риска
      переписывать unification-семантику; полный SoA отложен вместе с
      Type_Id (см. ниже) как чисто перформансная доработка
- [x] Migration `^Symbol` → `Symbol_Id` в resolver/type_cheker/compiler/lsp
      (INVALID_SYMBOL sentinel = Symbol_Id(0), симметрично Interned(0))
- [ ] `Type_Id :: distinct u32` + `Type_Store` SoA — **отложено**. `Type` —
      рекурсивная структура с pointer-identity семантикой (unify через `==`,
      mutable `binding` для InferVar union-find, глобальные синглтоны
      TY_NUM/TY_POISON), используется в 150+ местах 2700-строчного
      type_cheker.odin. Перевод на ID-store — не переименование, а
      переписывание модели вывода типов. Не блокер для LSP-фич ниже
      (completions/references/rename нужен только Symbol_Id)
- [ ] Migration `^Type` → `Type_Id` — отложено вместе с предыдущим пунктом
- [x] LSP: `textDocument/completion` — глобальные символы модуля + параметры
      и локали объемлющей функции/метода (`lsp/lsp_position.odin:
      collect_local_symbols`). MVP: без точной блочной видимости по
      позиции курсора (over-suggest — предлагает локали из непройденных
      веток if/match, но не даёт ложных отрицаний)
- [x] LSP: `textDocument/references` через `Symbol_Id -> [dynamic]Span`
      (`lsp/lsp_server.odin: build_usages`, один проход по node_symbols
      при каждом реparse'е документа)
- [x] LSP: `textDocument/rename` через WorkspaceEdit — та же usage-таблица,
      что и references. Как и go-to-definition: single-file, без графа
      импортов (межфайловый rename не входит в MVP)

Verification: `odin test ./core` 38/38, `test.ps` без регрессий, both
binaries (`panos`, `panos-lsp`) билдятся чисто, JSON-RPC round-trip
проверен Python-клиентом на completion/references/rename.

---

## Стадия 6 — TC Волна 2 (готово, коммит `fbbc5be`)

Refs: [ROADMAP §Стадия 6](ROADMAP.md#стадия-6--tc-волна-2-1-неделя).

Prerequisite: Стадия 5 — **не закрыта, сделано вне очереди** по
явному запросу (нарушает правило приоритизации ROADMAP §6.1). Учесть
при планировании Стадии 5 (Symbol_Id/Type_Id): split `infer_expr`
из P1 придётся тронуть повторно при миграции на ID-based символы.

- [x] P1 — split `infer_expr` на per-case процедуры (854 строки →
      15 отдельных `infer_X_expr` + ~15-строчный диспатчер)
- [x] P4 — унификация 6 side-tables в `call_infos: map[Expr]Call_Info`
      с тегом `Call_Kind` (было: is_constructor, method_calls,
      interface_calls, collection_calls, builtin_calls, variant_ctors)
- [x] P6 — data-driven `builtin_constructor_type` (`BUILTIN_CTORS`) +
      `standard_method_type` (`OPTION_METHODS`, `RESULT_METHODS`)

Verification: `odin test .` 38/38 зелёные, `odin run . -- test.ps` без
регрессий. Line count не сокращён (2359→2442) — P4/P6 добавляют
табличную инфраструктуру взамен дублирования, экономия не в строках.

---

## Стадия 7 — Generics

Refs: [ROADMAP §Стадия 7](ROADMAP.md#стадия-7--generics-2-3-недели).

Prerequisite: Стадия 6.

Архитектура: переход на constraint-based inference (generate constraints
→ solve batch'ем) вместо текущего eager unify — естественный субстрат
для `generalize`/`instantiate` (let-polymorphism). Error-sentinel
(TY_POISON-эквивалент) переезжает в solver, но не исчезает — см.
[ROADMAP §Стадия 7](ROADMAP.md#стадия-7--generics-2-3-недели)
(раздел "Архитектурное решение").

- [ ] Constraint generation pass (`Equal(t1, t2)` и т.п., без solve)
- [ ] Constraint solver (batch unification над накопленными constraint'ами)
- [ ] Phase A: implicit rank-1 для лямбд
- [ ] Phase B: `функ имя[T](x: T) -> T`
- [ ] Phase C: generic struct/interface
- [ ] Phase D: generic ADT
- [ ] Phase E: `реализация Список[T]`
- [ ] Phase F: prelude cleanup (Опция/Результат как user-declared ADT)

---

## Стадия 8 — FFI фаза B: dynamic

Refs: [ROADMAP §Стадия 8](ROADMAP.md#стадия-8--ffi-фаза-b-dynamic-3-4-недели).

Prerequisite: Стадия 1 + Стадия 6.

- [ ] Грамматика `внешний "libc" функ ...`
- [ ] FFI-типы (`Число_32`, `КСтрока`, `Указатель(T)`, `ff_структура`)
- [ ] libffi static-linked binding
- [ ] Type descriptor builder (Panos type → ffi_type)
- [ ] Primitive marshalling
- [ ] Struct-by-value marshalling
- [ ] `Call_Foreign` opcode + VM handler
- [ ] Callback'и через ffi_closure
- [ ] Memory ownership аннотации + GC finalizers
- [ ] SIGSEGV recovery
- [ ] Обёртка raylib на Panos-стороне (замена FFI-A)
- [ ] Обёртка libc `фс` (миграция host stdlib)

---

## Стадия 9 — DOD Волна 3 (опционально)

Refs: [ROADMAP §Стадия 9](ROADMAP.md#стадия-9-опционально--dod-волна-3--инкремент-по-нужде).

Prerequisite: реальные perf-issues. Не начинать без данных.

- [ ] AST индексы (SoA `Ast_Storage`)
- [ ] TC инкрементальность
- [ ] Incremental parsing (tree-sitter-style)
- [ ] Persistent LSP cache

---

## Заметки

- `.claude/` и `CLAUDE.md` намеренно исключены из git (agent-context).
- При закрытии стадии — обновлять timestamp в `ROADMAP.md`.
- При изменении scope — синхронизировать оба файла (`ROADMAP.md` +
  `TASKS.md`).
