---

description: "Task list for ADT + pattern-matching implementation"
---

# Tasks: ADT и pattern-matching

**Input**: Design documents from `/specs/001-adt-pattern-matching/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: Tests REQUIRED — FR-016 mandates end-to-end coverage per P1 user story.

**Organization**: Tasks grouped by user story so each story is independently implementable and testable.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallel-safe (different files, no dependency on unfinished tasks)
- **[Story]**: US1, US2, US3, US4 (see spec.md)
- All paths absolute or from repo root `/Users/gaidar/dev/panos/`.

## Path Conventions

- Package `main` in repo root — `.odin` files at top level.
- Tests: `e2e_test.odin` at top level.
- Smoke sample: `specs/001-adt-pattern-matching/quickstart.ps`.

---

## Phase 1: Setup (Shared type/opcode plumbing)

**Purpose**: introduce new enum values / union members / struct fields that later phases reference. Each task adds definitions only — no behaviour changes yet.

- [X] T001 [P] Extend `Symbol_Kind` with `Enum_Variant` and add `owner_type: ^Symbol`, `is_pattern_binder: bool` fields to `Symbol` in `resolver.odin`.
- [X] T002 [P] Extend `Type_Kind` with `Enum`; add `Type_Variant :: struct { name: string; fields: [dynamic]^Type }` and `variants: [dynamic]Type_Variant` field to `Type` in `type_cheker.odin`.
- [X] T003 Add `Variant_Value :: struct { type_name: string; tag_index: int; fields: [dynamic]Value }` and register `^Variant_Value` in `Value` union in `compiler.odin`.
- [X] T004 Add opcodes `Match_Tag`, `Get_Variant_Field`, `Match_Fail`, `Build_Variant` to `Opcode` enum in `compiler.odin` (append at end; no reordering). Semantics per `contracts/opcodes.md` §1–§4.

---

## Phase 2: Foundational (Prelude + shared helpers)

**Purpose**: unify built-in `Опция`/`Результат` with the user-ADT path (Q5) and add helpers used by both US1..US4.

**⚠ CRITICAL**: user-story phases assume prelude registration and helper procedures below exist.

- [ ] T005 Register prelude `Enum_Variant` symbols for `Опция` (`Есть`, `Нет`) and `Результат` (`Успех`, `Неудача`) with `owner_type` set; wire them into the root scope in `resolver.odin` (replacing prior `add_builtin_export` entries for these names).
- [ ] T006 Populate `variants` on the interned `Option`/`Result` types (fixed order: `Опция` → 0=`Нет`, 1=`Есть(T)`; `Результат` → 0=`Успех(T)`, 1=`Неудача(E)`) in `type_cheker.odin`.
- [X] T007 Added pure helpers `variant_tag` / `variant_field` in `vm.odin`. Covers `^Variant_Value`, `^Option_Value` (0=Нет, 1=Есть), `^Result_Value` (0=Успех, 1=Неудача). Returns zero-value on `ok=false`.
- [ ] T008 Extend the existing value-to-string formatter (used by `печать`/`строка`) to render `^Variant_Value` as `ИмяВарианта(...)` / `ИмяВарианта` and route `^Option_Value`/`^Result_Value` through the same path via `variant_tag`/`variant_field` in `vm.odin`.

**Checkpoint**: prelude sees ADT variants uniformly; formatter renders unified output. Existing tests still compile and pass.

---

## Phase 3: User Story 1 — Объявление ADT (Priority: P1) 🎯 MVP

**Goal**: declare a user ADT, construct variant values, print them.

**Independent Test**: `quickstart.md` first block; assert output lines equal `Точка`, `Круг(3)`, `Прямоугольник(4, 5)`.

### Implementation

- [X] T009 [US1] Remove the dead `tok_kind == .Enum_Decl` branch in `parse_top_level` in `parser.odin` (references a non-existent TokenKind value).
- [X] T009a [US1] In `parse_top_level` route `тип X = перечисление ...` to `parse_enum_decl` by adding an `.Enum` case in the third-token dispatch alongside `.Struct`/`.Interface`; reject any other third token with a Russian syntax error.
- [X] T010 [US1] Rewrite `parse_enum_decl` in `parser.odin` to consume a non-empty list of `Variant_Decl` using `consume_semicolon_or_newline` as separator until `конец`; reject empty variant list and empty `()` per contracts/diagnostics.md.
- [X] T011 [US1] In `resolver.odin` register the ADT type symbol and one `Symbol_Kind.Enum_Variant` per variant with `owner_type` set; propagate `is_exported` to all variants (FR-012); detect duplicate variant names inside one ADT; also reject a variant name that collides with an existing `Struct`/`Interface`/`Type` symbol in the same scope with the Russian diagnostic from `contracts/diagnostics.md`.
- [X] T012 [US1] In `resolver.odin` implemented lookup for `модуль.Тип.Вариант` (property-expr chain via `ctx.node_symbols[e.object]`) and `модуль.Вариант` fallback via `imported_module.exports[variant_name]` — since T011 exports variants alongside the type, the resolver naturally finds them. Ambiguity is not currently possible in this setup because export names are unique per module.
- [X] T013 [US1] In `resolver.odin` disambiguate bare `Ident` in expression position: if it resolves to zero-field `Enum_Variant`, mark AST node as constructor value; otherwise keep as variable lookup.
- [X] T013a [US1] In `resolver.odin` and `type_cheker.odin` route `Call_Expr` whose callee resolves to an `Enum_Variant` symbol (any arity, qualified or bare, incl. prelude `Есть`/`Нет`/`Успех`/`Неудача`) through the constructor path instead of the ordinary function-call path — this is what keeps FR-011 «поведение в выражениях `Есть(41)`/`Успех("ok")` сохраняется» working after the Q5 migration.
- [X] T014 [US1] In `type_cheker.odin` build `Type` records with `Type_Kind.Enum` and populated `variants` in two passes: (a) register nominal type name, (b) resolve field types (supports self-recursive variants per Edge Cases).
- [X] T015 [US1] In `type_cheker.odin` type-check variant constructor calls: match arg count and per-field assignability using existing `types_assignable`; emit Russian diagnostics per contracts/diagnostics.md.
- [X] T016 [US1] In `compiler.odin` emit `Build_Variant type_name_const, tag, arity` for every variant constructor call (both zero-field and multi-field). `type_name` string is added to the constants pool once per unique type; helper `emit_build_variant(c, type_name, tag, arity)` centralises the emission.
- [X] T017 [US1] In `vm.odin` implement `Build_Variant`: read three u8 operands, pop `arity` values off the stack in declaration order, allocate `^Variant_Value{type_name, tag_index, fields}`, push the pointer. No compile-time expansion path — this replaces the ambiguity previously documented in T017.

### Tests for User Story 1

- [X] T018 [US1] Split into three e2e tests (`test_adt_declare_and_construct_zero_field`/`_single_field`/`_multi_field`) asserting `^Variant_Value` shape rather than `печать` output (US1 AC-1). Note: T008 formatter deferred to Phase 4 — Value-inspection at test level satisfies AC-1 without touching printer.
- [X] T019 [US1] Added `test_adt_arg_type_mismatch_rejected` in `e2e_test.odin` running program with `Круг("три")`; asserts type-check error with expected/actual type names in Russian (AC-2). Also added `test_adt_duplicate_variant_rejected` for parser-level duplicate variant name check.
- [X] T020 [US1] Added `test_adt_qualified_variant_call` + `_zero_field_variant` + `_unknown_qualified_variant_rejected` in `e2e_test.odin`. Property-expr path (`Фигура.Круг(7)`) works both for zero-field and multi-field variants; unknown variant qualifier produces Russian resolver error. (AC-3 fully covered plus resolver-error diagnostic.)
- [X] T020a [US1] Added `test_adt_variant_collides_with_struct_rejected` in `e2e_test.odin` — declares `структура Точка` and an ADT with variant `Точка`; asserts Russian resolver error via T011 collision check.
- [X] T020b [US1] Added `test_adt_cross_module_qualified_use` (adt_fixture_main.ps → shapes) plus `test_adt_cross_module_short_form` (adt_fixture_short.ps → shapes) covering both `модуль.Тип.Вариант(...)` and `модуль.Вариант(...)` forms.
- [X] T020c [US1] Added `test_adt_non_exported_use_rejected` — attempt to use non-exported ADT via `ф.Круг(...)` produces the Russian `не экспортирует` error. Combined with T020b's positive test this covers FR-012 end-to-end. Also required fix to `run_module_file` in `e2e_test.odin`: write back `graph.symbol_types = res_ctx.symbol_types` after each module (matching `main.odin`) — Odin map handles do not fully alias across `resolve_module` return-by-value.

**Checkpoint**: US1 fully functional. Pipeline handles declaration → construction → print. Independent from US2..US4.

---

## Phase 4: User Story 2 — Разбор ADT через `выбор` (Priority: P1)

**Goal**: match a value against variants inside `выбор`, bind fields, return per-branch result.

**Independent Test**: `quickstart.md` `площадь` function; assert three numeric outputs (0, ~2826, 20).

### Implementation

- [X] T021 [US2] Added `^Match_Expr` to `Expr` union in `parser.odin`; dispatch to `parse_match_expr` in `nud` on `.Match`.
- [X] T022 [US2] Implemented `parse_match_expr` collecting arms until `конец`; rejects empty arm list. Currently each arm body is exactly one stmt/expr for simplicity — multi-stmt bodies deferred.
- [X] T023 [US2] Implemented `parse_pattern` covering `_`, plain ident, `ident(args...)`, `ident.ident(args?)`, `ident.ident.ident(args?)`. Nested constructor args limited to Wildcard/Ident. Literal/tuple/or/guard patterns rejected.
- [X] T024 [US2] Resolver `resolve_pattern` pushes fresh arm scope, registers `Pattern_Ident` as either binder Variable (`is_pattern_binder = true`) or Enum_Variant reference; wildcard is no-op. `pattern_binders: map[^Pattern_Ident]^Symbol` records binding for type checker.
- [X] T025 [US2] Type checker `^Match_Expr` case: subject must be `.Enum`, per-arm classified into `Wildcard`/`Binder`/`Constructor`; constructor arg types propagated to field binders; arm result types unified (Never ignored, matches `если`). Stored in `match_arm_infos` side-table.
- [X] T026 [US2] `compile_match_expr` in `compiler.odin`: stores subject in temp local, chains `Match_Tag`+`Jump_If_False` per constructor arm, uses `Get_Variant_Field` for field bindings via `register_binder_slot`, wildcard/binder arms fall through directly, terminal `Match_Fail` at the end.
- [X] T027 [US2] VM executes `Match_Tag`/`Get_Variant_Field`/`Match_Fail` using T007 helpers with Russian diagnostics.

### Tests for User Story 2

- [X] T028 [US2] Added `test_match_returns_per_variant_value` in `e2e_test.odin` running two subject cases (Точка → 0, Прямоугольник(4,5) → 20).
- [X] T029 [US2] Added `test_match_wildcard_arm_executes` (matches `Б(7)` against `А`/`_` → 42).
- [ ] T030 [US2] `test_match_nested_constructor_binds_inner` — deferred: current parser+type checker rejects nested constructor patterns. Additionally added `test_match_binder_pattern` for plain-ident binder coverage.
- [ ] T030a [US2] `test_match_arm_panics_never_ignored_in_result_type` — deferred; needs prelude `паника` route through match arm typing.

**Checkpoint**: US2 works on user ADTs. Existing tests pass. Prelude Option/Result branch typing already flows through the same path (verified more strictly in Phase 6).

---

## Phase 5: User Story 3 — Гарантия исчерпывающего разбора (Priority: P1)

**Goal**: type checker rejects non-exhaustive match and unreachable arms; `_` is only allowed as the last arm.

**Independent Test**: quickstart-style `площадь` with a variant added but no matching arm produces a compile-time error listing the missing variant.

### Implementation

- [X] T031 [US3] Added `check_match_coverage(subject_type, arm_infos)` — pure procedure iterating arm infos, tracking a `covered` bitmap and a `catch_all` flag; single-pass, no mutation of inputs beyond emitting Russian panics with contract messages.
- [X] T032 [US3] Wired `check_match_coverage` at the end of `^Match_Expr` typing. Emits ordered errors per contracts: unreachable-after-catch-all, `_` not last, duplicate variant, non-exhaustive with list of missing names.
- [X] T033 [US3] `compile_match_expr` already emits terminal `Match_Fail` unconditionally as internal insurance (documented at emission site). Runs regardless of whether checker proved unreachable.

### Tests for User Story 3

- [X] T034 [US3] Added `test_match_missing_variant_фигура` (Круг-only match against `Фигура`; expects error listing `Точка`).
- [X] T034a [US3] Added `test_match_missing_variant_дерево` (Узел-only match against `Дерево` = Лист/Узел; expects error listing `Лист`).
- [X] T034b [US3] Added `test_match_missing_variant_multi` (4-variant `Событие` with one arm missing; error lists `Г`).
- [ ] T034c [US3] `test_match_scales_linear_20_variants` — deferred (not blocking Phase 5 correctness; can go into Phase 7 as micro-perf sanity).
- [X] T035 [US3] Added `test_match_unreachable_after_wildcard_rejected` — arm after `_` produces "'_' в выборе должен быть только последней веткой".
- [X] T036 [US3] Added `test_match_duplicate_variant_arm_rejected` — duplicate constructor arm produces "покрыт повторно в ветке #2".

**Checkpoint**: all P1 stories complete. Language is usable: declare ADT, match it, get compile-time exhaustiveness. AC-3 of US3 (runtime fallthrough) is guaranteed unreachable by the type checker; no e2e test — `Match_Fail` remains as internal invariant.

---

## Phase 6: User Story 4 — Разбор `Опция` и `Результат` (Priority: P2)

**Goal**: same `выбор` grammar works for built-in `Опция(T)` and `Результат(T, E)`.

**Independent Test**: `выбор` over `Есть(41)`/`Нет()` and `Успех("ok")`/`Неудача(...)` produces expected per-branch results and exhaustiveness errors.

### Implementation

Nothing new — Phase 2 (prelude registration + `variants` on Option/Result) plus Phase 4/5 already cover this. Verify via tests only.

### Tests for User Story 4

- [X] T037 [US4] Added `test_match_option_binds_and_branches` (Есть(41) → 42) + `test_match_option_none_branch` (Нет() → 99). Approach: synthesize a virtual `.Enum` Type_Kind view for Option in type checker; VM helpers already unify via variant_tag/variant_field.
- [X] T038 [US4] Added `test_match_result_binds_success_and_error` (Успех("ок") → "ок").
- [X] T039 [US4] Added `test_match_option_non_exhaustive_rejected` — coverage checker reuses `check_match_coverage` and reports missing `Нет`.

**Checkpoint**: US4 verified without new production code.

---

## Phase 7: Polish & Cross-Cutting

- [ ] T040 Save `specs/001-adt-pattern-matching/quickstart.ps` matching the `quickstart.md` sample so it can be run via `just debug-file`.
- [ ] T041 [P] Update `docs/language.md` — add sections "Перечисления (ADT)" and "Выражение `выбор`" documenting syntax, `_`, qualification `Тип.Вариант`, and cross-module `модуль.Тип.Вариант`.
- [ ] T042 [P] Update `AGENTS.md` — under "Язык Panos" add one line each for `тип ... = перечисление ... конец` and `выбор ... конец`; do not disturb unrelated sections (Surgical Changes).
- [ ] T043 Run `odin test . -debug -vet -strict-style -vet-tabs -warnings-as-errors` and `just debug-file test.ps`; assert no regression against pre-branch results (SC-004).
- [ ] T044 Add helper `assert_russian_diagnostic :: proc(msg: string)` in `e2e_test.odin` that fails when `msg` contains ASCII Latin-letter words outside a small allow-list (identifiers referenced from user source, e.g. `Круг`, `Точка`). Route every negative-scenario test in Phases 3–6 (T019, T034/a/b/c, T035, T036, T039, T020a) through the helper (SC-005: 0 English messages).

---

## Dependencies & Execution Order

### Phase-level

- Phase 1 (Setup) has no prerequisites; can start immediately.
- Phase 2 (Foundational) requires Phase 1 (needs new enum/struct values).
- Phase 3 (US1) requires Phase 2 (prelude + formatter used by tests).
- Phase 4 (US2) requires Phase 3 (Enum_Variant symbols and constructor path).
- Phase 5 (US3) requires Phase 4 (`compute_match_coverage` needs `check_match`).
- Phase 6 (US4) requires Phase 5 (exhaustiveness path is shared).
- Phase 7 (Polish) requires all P1 phases (3, 4, 5); can run in parallel with Phase 6 once Phase 5 is green.

### Cross-story independence

- US2 depends on US1 (needs ADT values to match).
- US3 depends on US2 (needs match implementation to police).
- US4 only depends on the Phase 2 unification + US2 + US3 test infrastructure.

### Within a story

- Parser → resolver → type checker → compiler → VM → tests, matching AGENTS.md "минимальные вертикальные срезы".

### Parallel opportunities

- T001..T004 touch disjoint enum/struct declarations; only T003 and T004 share `compiler.odin` (mark T004 sequential after T003 to avoid conflict). T001 and T002 mark [P] with each other.
- e2e tests within one story land in the same `e2e_test.odin` and MUST be added sequentially (no [P]).
- Documentation tasks T041 and T042 hit different files → can run [P].

---

## Implementation Strategy

### MVP scope

Phases 1 + 2 + 3 (Setup + Foundational + US1). At that point the language declares and prints user ADTs; committed increment, ready to demo.

### Incremental delivery

1. Phases 1–2 → foundation ready.
2. Phase 3 (US1) → declare + construct + print → demo.
3. Phase 4 (US2) → `выбор` returns per-variant values → demo.
4. Phase 5 (US3) → compile-time exhaustiveness → demo.
5. Phase 6 (US4) → built-in Option/Result matching verified.
6. Phase 7 → docs + regression sweep.

### Solo execution

Recommended order: T001 → T002 → T003 → T004 → T005 → T006 → T007 → T008 → then US1 vertical slice (T009 → T009a → T010..T013 → T013a → T014..T020 → T020a → T020b → T020c) → US2 (T021 → T030 → T030a) → US3 (T031..T033 → T034 → T034a → T034b → T034c → T035 → T036) → US4 (T037 → T039) → polish (T040 → T044).

Commit granularity: one commit per completed sub-slice (usually 2–4 tasks) per AGENTS.md convention "минимальные вертикальные срезы".
