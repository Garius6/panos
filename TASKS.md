# Panos — Задачи

**Текущая стадия**: 0 — Foundation cleanup (готово, коммит `3055f10`)
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

## Стадия 2 — DOD Волна 1 + Diagnostic accumulation

Refs: [ROADMAP §Стадия 2](ROADMAP.md#стадия-2--dod-волна-1--diagnostic-accumulation-15-недели).

Prerequisite: Стадия 0. Разблокирует LSP.

Архитектура: eager unify + `TY_POISON` (текущий подход), **не**
constraint-based generate-then-solve. Обсуждено и отклонено для этой
стадии — подробности [ROADMAP §Стадия 2](ROADMAP.md#стадия-2--dod-волна-1--diagnostic-accumulation-15-недели)
(раздел "Архитектурная развилка"). Constraint-based рассмотреть в
Стадии 7 (там он естественно нужен под let-generalization).

- [ ] `Span {file_id: u16, start: u32, end: u32}` struct
- [ ] Span в токенах
- [ ] Span в AST-узлах (~15 struct'ов)
- [ ] `Interned :: distinct u32` + `String_Interner`
- [ ] Migration `Ident_Expr.name`, `Symbol.name`, `Type.name` на Interned
- [ ] `Diagnostic {severity, span, message, args}` struct
- [ ] `Type_Ctx.diagnostics: [dynamic]Diagnostic`
- [ ] `TY_POISON` тип для non-cascade error propagation
- [ ] Migration ~100 `fmt.panicf` → `report(ctx, span, ...)`
- [ ] `expect_diagnostic(t, source, expected)` test helper
- [ ] Migration exact-match e2e-тестов на diagnostic vector

---

## Стадия 3 — LSP MVP

Refs: [ROADMAP §Стадия 3](ROADMAP.md#стадия-3--lsp-mvp-15-недели).

Prerequisite: Стадия 2.

- [ ] LSP server skeleton (JSON-RPC 2.0 over stdio)
- [ ] `initialize` / `shutdown` handshake
- [ ] Full-reparse on `textDocument/didChange`
- [ ] `textDocument/publishDiagnostics`
- [ ] `textDocument/hover` — тип под курсором
- [ ] `textDocument/definition` — go-to-def
- [ ] VS Code extension skeleton
- [ ] Position mapping UTF-16 ↔ UTF-8
- [ ] E2E тесты через vscode-languageserver-testkit

---

## Стадия 4 — FFI фаза A: raylib demo

Refs: [ROADMAP §Стадия 4](ROADMAP.md#стадия-4--ffi-фаза-a-raylib-demo-3-дня).

Prerequisite: нет. Независимо.

- [ ] `raylib_bindings.odin` — foreign import + ~50 функций
- [ ] Panos-модуль `графика` в stdlib
- [ ] Demo: pong / snake в `demos/`
- [ ] README gif с демо

---

## Стадия 5 — DOD Волна 2 + LSP расширение

Refs: [ROADMAP §Стадия 5](ROADMAP.md#стадия-5--dod-волна-2--lsp-расширение-2-3-недели).

Prerequisite: Стадия 3.

- [ ] `Symbol_Id :: distinct u32` + `Symbol_Store` SoA
- [ ] Migration `^Symbol` → `Symbol_Id`
- [ ] `Type_Id :: distinct u32` + `Type_Store` SoA
- [ ] Migration `^Type` → `Type_Id`
- [ ] LSP: `textDocument/completion`
- [ ] LSP: `textDocument/references` через cross-reference table
- [ ] LSP: `textDocument/rename` через WorkspaceEdit

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
