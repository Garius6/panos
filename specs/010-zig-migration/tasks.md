# Tasks: Полный перенос интерпретатора Panos на Zig

**Input**: документы из `specs/010-zig-migration/`
**Prerequisites**: `plan.md`, `spec.md`, `research.md`, `data-model.md`,
`contracts/`
**Tests**: обязательны для каждого вертикального среза, поскольку FR-009 и
SC-001 требуют измеримой совместимости с эталоном.

## Phase 1: Setup and baseline

**Purpose**: Создать изолированный Zig build graph и неизменяемую базу для
сравнения, не перенося пока семантику Odin.

- [x] T001 Create Zig build graph in `build.zig` with native, test, LSP, browser, AOT runtime and conformance steps.
- [x] T002 Create Zig package metadata in `build.zig.zon` pinned to Zig `0.16.0` with no remote dependencies.
- [x] T003 [P] Create native CLI smoke executable in `zig/cli/main.zig` and test it in `zig/cli/main.zig`.
- [x] T004 [P] Create shared Zig package root in `zig/core/root.zig` with a unit-test entrypoint.
- [x] T005 [P] Define conformance corpus format and fixture policy in `tests/conformance/README.md`.
- [x] T006 [P] Create versioned empty conformance manifest in `tests/conformance/manifest.json`.
- [x] T007 Add conformance manifest parser/validator tests in `zig/conformance/manifest.zig`.
- [x] T008 Add reference-runner boundary that is the only pre-cutover Odin invocation in `zig/conformance/reference.zig`.
- [x] T009 Classify existing core tests and fixtures into deterministic, controlled-external and target-specific rows in `tests/conformance/inventory.md`.
- [x] T010 Add Zig cache/artifact ignores in `.gitignore` without changing existing Odin artifact rules.

**Checkpoint**: `zig build test` passes without Odin; every current test file
and fixture has a classification, and only an explicit reference step may call
Odin.

---

## Phase 2: Foundational source and compatibility model

**Purpose**: Build shared structures used by CLI, VM, LSP and WASM.

- [x] T011 Implement immutable source files and UTF-8 byte spans in `zig/core/source.zig`.
- [x] T012 [P] Implement accumulated Russian diagnostics in `zig/core/diagnostic.zig`.
- [ ] T013 [P] Implement canonical target profiles and builtin availability in `zig/core/target.zig`.
- [ ] T014 Implement normalized conformance outcomes in `zig/conformance/outcome.zig`.
- [ ] T015 Add source, span, diagnostic and outcome unit tests in `zig/core/source.zig` and `zig/conformance/outcome.zig`.
- [ ] T016 Add CLI diagnostic formatting contract tests in `zig/cli/main.zig` from `specs/010-zig-migration/contracts/cli.md`.

**Checkpoint**: source positions, target checks and normalized diagnostics can
be tested independently of a parser.

---

## Phase 3: User Story 1 — Run existing Panos programs (Priority: P1) 🎯 MVP

**Goal**: Execute deterministic existing Panos programs through the Zig
frontend, bytecode VM and runtime with matching observable results.

**Independent Test**: A deterministic program corpus covering lexical,
syntactic, semantic and runtime success/error cases matches reference outcomes.

- [ ] T017 [P] [US1] Port token kinds and Russian keyword lookup to `zig/core/token.zig` with lexical golden tests.
- [ ] T018 [US1] Implement UTF-8 lexer and recovery diagnostics in `zig/core/lexer.zig` with corpus tests in `tests/conformance/lexer/`.
- [ ] T019 [P] [US1] Define AST nodes, annotations and arena ownership in `zig/core/ast.zig`.
- [ ] T020 [US1] Implement expressions, statements, declarations, patterns and type syntax parser in `zig/core/parser.zig`.
- [ ] T021 [US1] Add parser recovery and span conformance tests in `tests/conformance/parser/`.
- [ ] T022 [US1] Implement symbols, lexical scopes and closure-capture metadata in `zig/core/symbols.zig`.
- [ ] T023 [US1] Implement primitive, tuple, function, nominal and collection types in `zig/core/types.zig`.
- [ ] T024 [US1] Implement resolver and accumulated semantic diagnostics in `zig/core/resolver.zig`.
- [ ] T025 [US1] Implement type inference and checking for expressions, control flow and function calls in `zig/core/type_checker.zig`.
- [ ] T026 [US1] Implement bytecode instruction model and compiler for typed core expressions in `zig/core/bytecode.zig` and `zig/core/compiler.zig`.
- [ ] T027 [US1] Implement `Value`, frames, calls, collections and runtime errors in `zig/core/value.zig` and `zig/core/vm.zig`.
- [ ] T028 [US1] Implement non-moving mark-and-sweep heap and root enumeration in `zig/core/gc.zig`.
- [ ] T029 [US1] Add deterministic end-to-end conformance cases in `tests/conformance/runtime/` for values, stdout and failures.
- [ ] T030 [US1] Wire `panos <file.ps>` and `-v|--verbose` compatibility behavior in `zig/cli/main.zig`.

**Checkpoint**: a deterministic subset of existing single-file programs runs
with matching result, stdout and diagnostics through the Zig CLI.

---

## Phase 4: User Story 2 — Modules and standard library (Priority: P1)

**Goal**: Run multi-file programs and supported standard-library features
without editing user source.

**Independent Test**: Existing module fixtures and prelude-dependent programs
resolve, typecheck and execute with matching outcomes on each applicable target.

- [ ] T031 [P] [US2] Implement module graph loading, canonical paths and cycle diagnostics in `zig/core/module_loader.zig`.
- [ ] T032 [US2] Embed and load the prelude plus file-based stdlib in `zig/core/prelude.zig` and `zig/core/stdlib.zig`.
- [ ] T033 [US2] Implement exports, qualified names and import scopes in `zig/core/resolver.zig`.
- [ ] T034 [US2] Implement generic instantiation, interfaces, ADT matching and exhaustiveness in `zig/core/type_checker.zig`.
- [ ] T035 [US2] Implement options, results, errors, arrays and maps in `zig/core/builtins.zig` and `zig/core/vm.zig`.
- [ ] T036 [US2] Add module/prelude/generic/ADT conformance fixtures in `tests/conformance/modules/`.
- [ ] T037 [US2] Enforce `Target_Profile` in type checking, bytecode dispatch and opaque-resource guards in `zig/core/target.zig` and `zig/core/builtins.zig`.

**Checkpoint**: supported imports, exports and standard-library operations match
the reference in native and expected unsupported profiles.

---

## Phase 5: User Story 3 — Build and use all delivered tools (Priority: P2)

**Goal**: Ship Zig-built native CLI, LSP and browser/AOT WASM paths.

**Independent Test**: A clean checkout with Zig builds all targets; LSP
transcripts and browser/wasmtime smoke tests pass without Odin.

- [ ] T038 [US3] Implement scheduler, actors and data-only async completions in `zig/core/scheduler.zig`.
- [ ] T039 [P] [US3] Implement filesystem, process, compression and syntax native adapters in `zig/core/native/io.zig` and `zig/core/native/process.zig`.
- [ ] T040 [P] [US3] Implement network, HTTP client and HTTP server adapters in `zig/core/native/http.zig`.
- [ ] T041 [P] [US3] Implement SQLite and libffi bindings through vendored archives in `zig/core/native/sqlite.zig` and `zig/core/native/ffi.zig`.
- [ ] T042 [US3] Add controlled native resource integration tests in `tests/integration/native/`.
- [ ] T043 [US3] Implement MIR, lowering, validation, stackification and binary emission in `zig/core/wasm/`.
- [ ] T044 [US3] Port JS and WASI AOT runtime modules to `zig/wasm_runtime/` and add `wasmtime` tests in `tests/wasm/`.
- [ ] T045 [US3] Implement browser interpreter exports and host boundary in `zig/browser/main.zig` and validate with `docs/src/assets/aot-dom-loader.js`.
- [ ] T046 [US3] Implement JSON-RPC transport and LSP document lifecycle in `zig/lsp/main.zig`.
- [ ] T047 [US3] Implement all documented LSP features in `zig/core/lsp_features/` and transcript tests in `tests/lsp/`.
- [ ] T048 [US3] Implement `panos build --target=wasm` CLI contract in `zig/cli/main.zig`.

**Checkpoint**: all three Zig-delivered tools build and pass their target
smoke suites without Odin.

---

## Phase 6: User Story 4 — Maintain the new source (Priority: P3)

**Goal**: Make Zig the understandable, testable primary implementation.

**Independent Test**: A maintainer can reproduce a conformance regression and
run the relevant target test from the documented commands only.

- [ ] T049 [US4] Document Zig build, test, debug and target commands in `README.md` and `docs/src/architecture/toolchain-and-testing.md`.
- [ ] T050 [US4] Document new pipeline and runtime boundaries in `docs/src/architecture/`.
- [ ] T051 [US4] Add CI Zig build matrix and conformance gates in `.github/workflows/`.
- [ ] T052 [US4] Record benchmark baselines and regression thresholds in `tests/conformance/benchmarks.md`.

**Checkpoint**: a new maintainer can work entirely through Zig docs and tests.

---

## Phase 7: Cutover and cross-cutting validation

**Purpose**: Switch delivery paths only after all compatibility criteria pass.

- [ ] T053 Run complete conformance matrix and resolve/classify every deviation in `tests/conformance/manifest.json`.
- [ ] T054 [P] Validate native CLI contract from `specs/010-zig-migration/contracts/cli.md` on all release platforms.
- [ ] T055 [P] Validate all LSP transcripts from `specs/010-zig-migration/contracts/lsp.md`.
- [ ] T056 [P] Validate browser and AOT WASM suites from `tests/wasm/`.
- [ ] T057 Switch documented release and Pages build paths to `build.zig` in `Justfile` and `.github/workflows/`.
- [ ] T058 Remove Odin from mandatory CI/release dependencies and retire the reference runner in `zig/conformance/reference.zig`.
- [ ] T059 Decide and document Odin source archival/removal in `docs/src/architecture/toolchain-and-testing.md`.

## Dependencies and execution order

- Phase 1 blocks every implementation phase; T001–T009 establish the
  executable compatibility baseline.
- Phase 2 blocks US1–US3 because they all need spans, diagnostics and target
  policy.
- US1 (Phase 3) supplies the semantic/runtime core needed by US2 and US3.
- US2 extends that core with module and stdlib semantics.
- US3 depends on US1/US2 for all delivered targets; T039–T041 can proceed in
  parallel after T038’s adapter protocol is stable.
- US4 documentation/CI becomes authoritative only after US3 builds, but its
  source documentation can be drafted in parallel.
- Phase 7 is the only phase that changes existing release paths.

## Parallel opportunities

- T003–T006 are independent after T001/T002.
- T011–T014 can be developed in parallel after the public package root exists.
- T017 and T019 are separate lexer/AST files; T039–T041 are separate native
  adapter files; T054–T056 are independent cutover validations.
- Parallel work must not define incompatible `Span`, `Value`, `Type_Id` or
  `Target_Profile` models; those are owned by T011–T013 and T023/T027.

## Implementation strategy

1. **MVP**: complete Phase 1 and a tiny Phase 2/US1 vertical slice — source →
   lexer → parser → diagnostics in a Zig CLI — before porting typechecker or
   VM.
2. **Expand by conformance tier**: promote parser, semantic and runtime cases
   only after their previous tier is green.
3. **Keep external boundaries last**: native services, AOT WASM and LSP attach
   to a proven core rather than driving its design.
4. **Cut over once**: no production hybrid; Odin is a reference-only oracle
   until Phase 7.
