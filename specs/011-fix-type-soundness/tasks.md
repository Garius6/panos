# Tasks: Sound Type Checking

**Input**: Design documents from `/specs/011-fix-type-soundness/`  
**Prerequisites**: `plan.md`, `spec.md`, `research.md`, `data-model.md`, `contracts/language-compatibility.md`, `quickstart.md`

**Tests**: Focused unit and e2e regressions are required by the feature specification; write them before each implementation slice.

**Organization**: Tasks are grouped by user story. Each phase has an independently testable checkpoint.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel with other tasks in the same phase after its stated dependencies.
- **[Story]**: User story served by the task.

## Phase 1: Setup

**Purpose**: Establish the regression matrix and exact language contract before behavior changes.

- [X] T001 Record the chosen invariant-function, multi-vtable, writable-target, and named-call rules in `specs/011-fix-type-soundness/contracts/language-compatibility.md`.
- [X] T002 [P] Add a focused regression inventory and commands for all acceptance scenarios in `specs/011-fix-type-soundness/quickstart.md`.

---

## Phase 2: Foundational Runtime Metadata

**Purpose**: Introduce the shared multi-vtable representation required by generic bounds before changing type-checker output or VM dispatch.

**⚠️ CRITICAL**: Complete this phase before User Story 2; it establishes the metadata contract consumed by checker, compiler, GC, and VM.

- [X] T003 Define multi-vtable bytecode constant and selected-vtable interface-call operands, preserving existing `u16` limits, in `zig/core/bytecode.zig`.
- [X] T004 Define the interface package as one receiver plus an ordered collection of vtables in `zig/core/value.zig`.
- [X] T005 Update interface package allocation, marking, deallocation, and deep-copy behavior for the vtable collection in `zig/core/gc.zig` and `zig/core/vm.zig`.
- [ ] T006 Add bytecode/value/GC unit coverage for a package with more than one vtable in `zig/core/bytecode.zig`, `zig/core/value.zig`, and `zig/core/gc.zig`.

**Checkpoint**: Shared runtime metadata can safely represent and copy one receiver with multiple method tables; no language behavior has changed yet.

---

## Phase 3: User Story 1 — Безопасные функции и присваивания (Priority: P1) 🎯 MVP

**Goal**: Reject unsafe function substitutions and invalid write targets before compilation or execution, while retaining valid array/map writes.

**Independent Test**: A program that passes a concrete-receiver function where an interface-receiver function is expected, or writes into a string index, fails at type checking; exact function types and array/map writes still run.

### Tests for User Story 1

- [ ] T007 [P] [US1] Add checker regressions for parameter/return/arity function mismatches, exact closures, and the `Никогда` return exception in `zig/core/type_checker.zig`.
- [ ] T008 [P] [US1] Add runner e2e programs that reject unsafe interface-function substitutions and string-index writes while accepting array/map writes in `zig/core/runner.zig`.

### Implementation for User Story 1

- [X] T009 [US1] Make function-type assignment invariant by parameter and result in `Checker.assignable` in `zig/core/type_checker.zig`, retaining only the same-parameter `Никогда` return exception.
- [X] T010 [US1] Classify assignment targets by inferred object kind in `Checker.checkAssignmentTarget` in `zig/core/type_checker.zig`; reject string indexing and non-writable target forms while preserving field/array/map writes.
- [ ] T011 [US1] Verify compiler/VM need no fallback for rejected string writes and retain valid array/map assignment behavior in `zig/core/compiler.zig` and `zig/core/vm.zig`.

**Checkpoint**: User Story 1 is complete when T007–T008 pass and no incompatible function or string write reaches code generation.

---

## Phase 4: User Story 2 — Несколько интерфейсных ограничений (Priority: P1)

**Goal**: Allow a generic value constrained by multiple interfaces to dispatch every declared user-interface bound safely, including together with `Сравниваемое`.

**Independent Test**: `T: A + B` calls one method from each interface and returns the expected result; a type missing either bound fails type checking; `T: Сравниваемое + A` both compares and dispatches `A`.

### Tests for User Story 2

- [ ] T012 [P] [US2] Add checker tests for multiple bounds, duplicate-bound diagnostics, method-name collision ordering, and a missing implementation in `zig/core/type_checker.zig`.
- [ ] T013 [P] [US2] Add VM/runner e2e regressions for two user-interface bounds, generic forwarding, and `Сравниваемое + пользовательский интерфейс` in `zig/core/vm.zig` and `zig/core/runner.zig`.
- [ ] T014 [P] [US2] Add cross-module generic-bound regression coverage in `zig/core/module_compiler.zig` and `tests/conformance/modules/`.

### Implementation for User Story 2

- [X] T015 [US2] Replace single `InterfaceCast` metadata with ordered multi-vtable cast entries and add selected vtable slot to `InterfaceCall` in `zig/core/type_checker.zig`.
- [X] T016 [US2] Validate duplicate bounds and collect all non-`Сравниваемое` bounds in declaration order during generic parameter and call analysis in `zig/core/type_checker.zig`.
- [X] T017 [US2] Resolve generic bound-interface methods to a deterministic bound slot and method index, including same-name collisions, in `zig/core/type_checker.zig`.
- [X] T018 [US2] Emit one multi-vtable constant/package cast and selected-vtable calls from checker metadata in `zig/core/compiler.zig`.
- [X] T019 [US2] Construct interface packages and dispatch through the selected vtable with range/type diagnostics in `zig/core/vm.zig`.
- [X] T020 [US2] Unwrap interface packages before existing comparable dispatch and preserve raw receiver invocation in `zig/core/vm.zig`.
- [ ] T021 [US2] Preserve all imported generic bounds and their order through import rehosting in `zig/core/type_checker.zig` and `zig/core/module_compiler.zig`.

**Checkpoint**: User Story 2 is complete when T012–T014 pass, all selected slots resolve correctly, and no generic multi-bound method call can use a wrong vtable.

---

## Phase 5: User Story 3 — Предсказуемые именованные аргументы (Priority: P2)

**Goal**: Execute named concrete-method calls in declaration order and reject named forms with no authoritative parameter names during type checking.

**Independent Test**: A local and imported concrete method with reversed named arguments yields the same result as the positional form; named enum/interface calls stop with Type Error and never with Compiler Error.

### Tests for User Story 3

- [ ] T022 [P] [US3] Add checker tests that assert `call_arguments` ordering for concrete methods and Type Error for enum/interface/generic-bound named calls in `zig/core/type_checker.zig`.
- [ ] T023 [P] [US3] Add runner/VM e2e coverage for reversed local concrete-method arguments and generic inherent methods in `zig/core/runner.zig` and `zig/core/vm.zig`.
- [ ] T024 [P] [US3] Add imported concrete-method named-call coverage in `zig/core/module_compiler.zig` and `tests/conformance/modules/`.

### Implementation for User Story 3

- [X] T025 [US3] Obtain concrete method parameter names excluding the receiver, reorder named arguments before inference, and use the ordered arguments in every method-checking loop in `zig/core/type_checker.zig`.
- [X] T026 [US3] Carry imported concrete-method parameter names through `ImportedMethod`, `ImportContext`, and module compilation in `zig/core/type_checker.zig` and `zig/core/module_compiler.zig`.
- [X] T027 [US3] Emit ordered arguments for `method_calls` and spawn calls in `zig/core/compiler.zig`.
- [X] T028 [US3] Report Type Error for named enum constructors in both enum variant inference paths in `zig/core/type_checker.zig`.
- [ ] T029 [US3] Report Type Error for named interface, generic-bound-interface, builtin, collection/prelude, FFI, lambda, and function-value calls without parameter-name metadata in `zig/core/type_checker.zig`.
- [X] T030 [US3] Consume checked ordered arguments for named struct constructors in the AOT path in `zig/core/mir_lowering.zig`.
- [X] T031 [US3] Update the supported and intentionally rejected named-call forms in `docs/src/language/functions.md`.

**Checkpoint**: User Story 3 is complete when all supported calls preserve argument-to-parameter mapping on every target and unsupported forms never escape type checking.

---

## Phase 6: Polish & Cross-Cutting Validation

**Purpose**: Verify compatibility across the full pipeline and leave the documentation aligned with behavior.

- [ ] T032 [P] Run focused checker, compiler, VM, runner, and module tests from `specs/011-fix-type-soundness/quickstart.md`.
- [ ] T033 Run `zig build test`, `zig build conformance`, `zig build lsp`, and `zig build browser`; record any pre-existing failures separately in `specs/011-fix-type-soundness/quickstart.md`.
- [ ] T034 Run `zig build aot` and confirm named structure constructor behavior in `zig/core/mir_lowering.zig` is covered by the result.
- [ ] T035 Review the final diff against `specs/011-fix-type-soundness/contracts/language-compatibility.md` and update only documentation made stale by implementation.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1**: can begin immediately.
- **Phase 2**: depends on T001; blocks the multi-vtable portion of US2.
- **US1**: may begin after T001 and is independent of Phase 2.
- **US2**: depends on T003–T006; implementation order is T015 → T016 → T017 → T018 → T019 → T020 → T021.
- **US3**: may begin after T001 and is independent of US1/US2, except that compiler changes must merge cleanly with T018.
- **Phase 6**: depends on all selected user stories.

### User Story Dependencies

- **US1 (P1)**: independently deliverable MVP.
- **US2 (P1)**: depends only on the foundational runtime metadata phase.
- **US3 (P2)**: independently deliverable after the named-call contract; imported-method coverage depends on metadata propagation T026.

### Parallel Opportunities

- T007 and T008 may run in parallel; T009 and T010 then converge in `type_checker.zig` and should be sequenced.
- T012, T013, and T014 may be authored in parallel before US2 implementation.
- T022, T023, and T024 may be authored in parallel before US3 implementation.
- US1 and Phase 2/US2 can proceed in parallel after T001; US3 can proceed in parallel after T001 if the shared `compiler.zig` edits are coordinated.

## Parallel Example: User Story 2

```text
Task: "Add checker multi-bound regressions in zig/core/type_checker.zig"
Task: "Add VM and runner multi-bound e2e regressions in zig/core/vm.zig and zig/core/runner.zig"
Task: "Add cross-module multi-bound regression in zig/core/module_compiler.zig and tests/conformance/modules/"
```

## Implementation Strategy

### MVP First

1. Complete T001, then T007–T011.
2. Validate User Story 1 independently.
3. Ship only if function compatibility and assignment-target checks have no regressions.

### Incremental Delivery

1. Deliver US1 as the safety MVP.
2. Complete foundational metadata and US2 as the multi-bound runtime slice.
3. Deliver US3 after named-call behavior is consistent in checker, native compiler, imports, and AOT.
4. Run the full regression matrix only after all slices are integrated.

## Notes

- Every task follows the required checkbox, ID, optional parallel marker, story label, and exact path format.
- Do not implement full function variance or monomorphization in this feature.
- Existing unrelated worktree changes remain outside the task scope.
