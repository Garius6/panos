# Panos — Задачи

**Текущая стадия**: 0 — Foundation cleanup
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

- [ ] P2 — helper `resolve_variant_ctor` (унифицировать 3 места
      Enum_Variant construction, `type_cheker.odin:1523-1772`)
- [ ] P3 — `variant_index: map[string]int` в `Type` + helper
      `variant_index(enum_type, name) -> (int, bool)`
- [ ] P5 — synth cache `Type_Ctx.synth_enum_cache: map[^Type]^Type` +
      `synth_enum_view(ctx, base)`
- [ ] P12 — убрать двойные `prune_type(prune_type(x))` вызовы
- [ ] P13 — `BASE_TYPES` map + добавить `Никогда` (сейчас баг:
      `функ f() -> Никогда` падает)
- [ ] P14 — убрать `Match_Arm_Info` wrapper, использовать `Pattern_Info`
      напрямую
- [ ] P15 — унифицировать `variant_calls` + `variant_idents` в
      единый `variant_ctors: map[Expr]Variant_Ctor_Info` (включает P4-часть)

### Verification

- [ ] `odin test .` — 38/38 тестов зелёные
- [ ] `odin run . -- test.ps` — без регрессий
- [ ] Type-checker строк ≤ 2150 (было 2359)

### Delivery

- [ ] Коммит с русскоязычным описанием изменений

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

## Стадия 6 — TC Волна 2

Refs: [ROADMAP §Стадия 6](ROADMAP.md#стадия-6--tc-волна-2-1-неделя).

Prerequisite: Стадия 5.

- [ ] P1 — split `infer_expr` на per-case процедуры
- [ ] P4 — унификация side-tables в `Call_Info` с `Call_Kind`
- [ ] P6 — data-driven `builtin_constructor_type` +
      `standard_method_type`

---

## Стадия 7 — Generics

Refs: [ROADMAP §Стадия 7](ROADMAP.md#стадия-7--generics-2-3-недели).

Prerequisite: Стадия 6.

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
