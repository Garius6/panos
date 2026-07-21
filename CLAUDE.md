# panos Development Guidelines

Auto-generated from feature plans. Last updated: 2026-07-21.

## Active Technologies
- mdBook (docs/) — internal architecture documentation, no new dependency (002-interpreter-architecture-docs)
- Odin (toolchain pinned via `Justfile`), stdlib packages `core:fmt`, `core:strings`, `core:strconv`.
- `core:thread` (worker pool) + `core:sync/chan` — actor-model non-blocking I/O (see Recent Changes), stdlib only, no new dependency.
- pan package manager (003-pan-package-manager): panos itself (self-hosted, `../panosiki/pan/`) using `std/кодирование/toml.ps` for manifest/lock; three new native-only core builtins (`ос.выполнить` process spawn, `ос.завершить` exit-with-code, `фс` directory-ops) as prerequisite, see `specs/003-pan-package-manager/`.
- gitsync dependency scaffolding (004-gitsync-dependency-packages): 7 new independent git repos under `../panosiki/` (each `pan init`-ed) for gitsync's oscript-library dependencies that need porting; one new panos stdlib module `std/слог.ps` (logging, replaces `logos`); no `core/` changes. See `specs/004-gitsync-dependency-packages/`.
- panos metaprogramming (not a speckit feature — see Recent Changes): `&`-annotations (parser-only AST metadata, no runtime effect — `core/parser.odin`) + `синтаксис.*` compile-time-only AST-introspection native builtin (`core/vm_syntax_native.odin`/`_wasm.odin`), no new dependency. Generic codegen driver self-hosted in `../panosiki/codegen/` (separate repo, not bundled in `std/`), invoked via `pan task`.

## Project Structure

```text
core/       # lexer, parser, resolver, type checker, compiler, VM
std/        # panos stdlib (.ps sources)
lsp/        # language server
wasm/       # wasm build entrypoint
fixtures/   # test fixtures
specs/      # speckit feature specs
```

See `AGENTS.md` for pipeline details and technical conventions — it is
authoritative for language/pipeline specifics per the constitution below.

## Commands

- `just build` — native build
- `just build-lsp` — LSP build
- `just build-wasm` — wasm build (output: `demo/panos.wasm`)
- `just test` — run `odin test ./core`
- `just debug-file <path>` — run a `.ps` file with vet/debug flags

## Code Style

Follow `AGENTS.md` and existing file conventions. No unrequested refactors
(see constitution, Principle III — Surgical Changes).

Comments MUST NOT reference development process (e.g. "Реализовано в
задаче XXX", "Стадия N", task/ticket/spec IDs, "added for feature Y").
Explain the current WHY (invariant, non-obvious constraint), not the
history of how the code came to exist — that belongs in commit messages,
not source comments.

## Recent Changes
- codegen-and-pan-task (not a speckit feature — built via plan-mode):
  generic annotation-driven codegen driver, self-hosted in panos, living
  in `../panosiki/codegen/` (separate git repo, own `v0.3.0`+ tags, NOT
  bundled in `std/`) — Dart's `build_runner`/`source_gen` pattern, not
  JSON-specific: walks every decl's `&Имя(...)` annotations via
  `синтаксис.*`, dispatches to whichever generator function is
  registered under that annotation name in a
  `Соответствие(Строка, функ(...)->...)` (named panos functions are
  first-class values, storable in a map — proven working, no core
  change needed for this). One generator registered so far — `&Json`,
  emits `реализация json.ВJSON`/`json.ИзJSON` (see below) for flat
  Число/Строка/Булево struct fields; accepts a single file or a
  directory (recursive, `<файл>_gen.ps` next to each source with
  matching annotations, others skipped silently). Invoked via new `pan
  task <имя> [аргументы...]` subcommand (`../panosiki/pan/start.ps`) —
  spawns a dependency's own `точка_входа` as a child `panos` process
  (same propagate-exit-code pattern as `pan run`), distinct from
  library-style `импорт`. Required fixing `../panosiki/pan/кэш.ps`'s
  `разложить_запись` to lay out the FULL dependency tree in
  `модули/<имя>/` (recursive copy minus `.git`) instead of only the
  entry-point file — multi-file dependencies (task's own driver+
  generator files, connected by relative imports) didn't survive the
  old flat single-file copy.
- annotations-and-syntax-introspection (not a speckit feature — built
  via plan-mode): Kotlin/1С-style `&Имя(...)` annotations
  (`core/parser.odin`) over top-level decls and struct fields — sigil
  is `&` (not `@`) deliberately, matching 1С's own `&НаКлиенте`/
  `&НаСервере` directive convention and reusing the existing
  `.Ampersand` token (bitwise AND) with zero grammar conflict
  (annotations only parse where an expression can never start).
  Compiler only parses and attaches them — resolver/typechecker/VM
  never read them; meaning is assigned entirely by external tooling
  (see codegen above). New `синтаксис.*` native builtin (`core/
  vm_syntax_native.odin`/`_wasm.odin`) exposes compile-time AST
  introspection of ANOTHER .ps file (struct/field names, type-as-text,
  annotations, as flat Массив/Опция/Результат data — same "flat data,
  no named handle type" philosophy as `ос.выполнить`) to panos scripts,
  not just Odin tools like the LSP — deliberately NOT runtime
  reflection (`reflector`, deferred in specs/004): doesn't touch VM
  value representation, no persistent state (re-parses per call).
  Fixing this to see structs whose entry file lives in a directory
  led to `фс.это_директория` (new builtin) + a resolver fix
  (`resolve_import_dir_index_path`, `core/resolver.odin`): `импорт
  ("имя")` now understands a directory as a package via a canonical
  `индекс.ps` file inside it (`index.js`/`__init__.py` convention) —
  previously a multi-file dependency laid out by `pan` could only be
  spawned as a task, never imported as a library. `std/кодирование/
  json.ps` gained `ИзJSON`/`ВJSON` interfaces (same pattern as existing
  `ИзTOML`/`ВTOML`) — `json.сериализовать_из(x)`/`json.разобрать_в(x,
  текст)` work uniformly for any struct implementing them, instead of
  a differently-named function per struct.
- 004-gitsync-dependency-packages: First stage of porting gitsync
  (git-based 1C infobase storage sync, oscript-library/gitsync) to panos —
  scaffolding only, no ported logic yet. Of gitsync's 15 runtime deps: 7 get
  an empty `pan init`-ed package skeleton in `../panosiki/` (own git repo +
  `v0.1.0` tag each, so `pan add` can resolve them later) — `tempfiles`,
  `v8runner`, `gitrunner`, `v8storage`, `cli`, `cli-selector`, `configor`;
  `logos` becomes stdlib module `std/слог.ps` (5 log-level functions,
  stdout only — no appenders/layouts, that's real `logos`'s scope, not
  ported); 6 excluded as already covered (`json`→`кодирование/json.ps`,
  `strings`→`строки`, `fs`→`фс`, `delegate`→native first-class functions,
  `opm`→`pan` itself, `1commands`→native `ос.выполнить`); `reflector`
  deferred — wraps OneScript's native reflection, which panos's language
  doesn't have at all (out of scope, not a library gap). See
  `specs/004-gitsync-dependency-packages/` (plan/research/data-model/
  contracts — full 15-row dependency map in spec.md).
- 003-pan-package-manager: Pan — git-based package manager for panos, written
  in panos, living in `../panosiki/pan/` (separate repo). Single resolved
  version per package name (Cargo-style), semver ranges over git tags,
  `модули/` dependency layout already resolved natively by
  `core/resolver_import_native.odin` (no core change needed there). `pan`
  touches `core/` with three new native-only builtins that didn't exist
  yet — `ос.выполнить` (process spawn with cwd/stdout/stderr/exit code, for
  `git clone`/`git checkout` and spawning the child `panos` process),
  `ос.завершить` (exit(code), so `pan run` can propagate the child `panos`
  process's exact exit code instead of only approximating failure via
  `паника`) and directory-ops in `фс` (recursive mkdir/list/remove, for
  `модули/`/cache layout). See `specs/003-pan-package-manager/` (plan/
  research/data-model/contracts).
- non-blocking-actor-io (not a speckit feature — built via plan-mode, see
  `git log --grep=неблокирующий`): actor-model I/O no longer blocks
  `run_scheduler` — `сеть.http_запрос`, `фс.прочитать`/`.записать`,
  `сеть.подключиться` (one-shot), and streaming `File_Value.прочитать*`/
  `.записать` + `Socket_Value.получить*`/`.отправить` (already-open
  handles) all submit to a `core:thread.Pool` worker and suspend on the new
  `Await_Async` opcode instead of running synchronously inside `execute()`.
  GC has zero locks, so workers only ever touch plain data — EXCEPT the
  streaming-handle case, which pins the `File_Value`/`Socket_Value` as a GC
  root (`gc_pin`/`gc_unpin`, `core/gc.odin`) for the duration and gates
  concurrent access with an `in_flight`/`close_requested` pair. Full design
  + rationale: `docs/src/architecture/compiler-and-vm.md` § "Неблокирующий
  I/O", `docs/src/architecture/memory-and-gc.md` § `gc_pin`/`gc_unpin`.
  Deliberately NOT covered: `сжатие::разжать_gzip` (CPU-bound, not
  I/O-wait-bound — same fix doesn't apply, separate cost/benefit call).
- 002-interpreter-architecture-docs: New mdBook section `docs/src/architecture/`
  documenting interpreter internals (pipeline, runtime, LSP, known pitfalls,
  toolchain, recipes) for maintainers editing without LLM help.
- 001-adt-pattern-matching: Added ADT + pattern matching using
  `core:fmt`, `core:strings`, `core:strconv`.

<!-- MANUAL ADDITIONS START -->

## Конституция проекта

Перед началом любой работы читай `.specify/memory/constitution.md` — это конституция проекта, обязательна к соблюдению.

<!-- MANUAL ADDITIONS END -->
