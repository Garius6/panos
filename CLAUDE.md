# panos Development Guidelines

Auto-generated from feature plans. Last updated: 2026-07-23.

## Active Technologies
- mdBook (docs/) — internal architecture documentation, no new dependency (002-interpreter-architecture-docs)
- Odin (toolchain pinned via `Justfile`), stdlib packages `core:fmt`, `core:strings`, `core:strconv`.
- `core:thread` (worker pool) + `core:sync/chan` — actor-model non-blocking I/O (see Recent Changes), stdlib only, no new dependency.
- pan package manager (003-pan-package-manager): panos itself (self-hosted, `../panosiki/pan/`) using `std/кодирование/toml.ps` for manifest/lock; three new native-only core builtins (`ос.выполнить` process spawn, `ос.завершить` exit-with-code, `фс` directory-ops) as prerequisite, see `specs/003-pan-package-manager/`.
- gitsync dependency scaffolding (004-gitsync-dependency-packages): 7 new independent git repos under `../panosiki/` (each `pan init`-ed) for gitsync's oscript-library dependencies that need porting; one new panos stdlib module `std/слог.ps` (logging, replaces `logos`); no `core/` changes. See `specs/004-gitsync-dependency-packages/`.
- panos metaprogramming (not a speckit feature — see Recent Changes): `&`-annotations (parser-only AST metadata, no runtime effect — `core/parser.odin`) + `синтаксис.*` compile-time-only AST-introspection native builtin (`core/vm_syntax_native.odin`/`_wasm.odin`), no new dependency. Generic codegen driver self-hosted in `../panosiki/codegen/` (separate repo, not bundled in `std/`), invoked via `pan task`.
- panos language fixes (005-language-fixes): three compiler-only grammar/typechecker fixes found while porting gitsync deps — no new dependency, touches only `core/parser.odin` + `core/type_cheker.odin`.
- gitsync dependency packages (not a speckit feature — built via plan-mode, see 004): the 6 "new package" dependencies (gitrunner/tempfiles/configor/cli-selector/v8runner/v8storage) plus `cli` all have real implementations (not just scaffolding) with e2e tests, in `../panosiki/`.
- gitsync core port (006-gitsync-port): new `../panosiki/gitsync/` package — the actual sync-loop application, composing the 7 dependency packages above with zero changes to any of them. See `specs/006-gitsync-port/`.
- gitsync per-version authorship (007-gitsync-per-version-author): extends `panosiki/v8storage` with a method wrapping `/ConfigurationRepositoryReport` (CLI, `ос.выполнить` — no COM), plus a new `panosiki/скобки` package (bracket-format 1C text parser, narrow port of `oscript-library/yabr`, MPL-2.0) to extract per-version author from the resulting MXL report; wires into `panosiki/gitsync/sync.ps` to replace 006's single-author-per-run simplification. All 9 `panosiki/*` packages now live on `github.com/Garius6/*` (public, tagged) instead of local file paths. See `specs/007-gitsync-per-version-author/`.
- gitsync auto push/pull (008-gitsync-auto-push-pull): optional `--remote <name>` flag on `gitsync sync` — `git pull --ff-only` before the version loop (abort with no progress on divergence), `git push` after only if new commits were made. Uses `panosiki/gitrunner`'s existing escape hatch (`выполнить_команду`) and `получить_текущую_ветку` — no changes to gitrunner itself. See `specs/008-gitsync-auto-push-pull/`.

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
- 008-gitsync-auto-push-pull: Optional `--remote`/`-r` flag on `gitsync
  sync`: `Контекст_Синхронизации` gains a `remote: Опция(Строка)` field
  (`Нет()` = unchanged 007 behavior, no network calls at all). When set:
  `git pull --ff-only <remote> <current branch>` runs BEFORE the version
  loop (current branch always via `gitrunner.получить_текущую_ветку`,
  never hardcoded) — any failure (including divergence/non-fast-forward)
  aborts `sync` immediately, before touching any storage version or
  `VERSION` file (no partial progress). `git push <remote> <branch>` (no
  `--force`) runs AFTER the loop, only if at least one new commit was
  made this run (reuses the existing `синхронизировано` counter — no new
  git query needed). A push failure surfaces as an overall
  `Результат.Неудача` for the CLI's exit code, but does NOT roll back the
  local commits/VERSION already written — the local sync against 1C
  storage already genuinely succeeded by that point; only the network
  step failed, and a retry later just repeats the (now no-op) push.
  `--ff-only` is a direct escape-hatch call through `Репозиторий.
  выполнить_команду`, deliberately NOT a new named `gitrunner` method
  (not common/general enough to justify one). Tested with two real local
  clones of a shared local bare repo as the "remote" — no fake binaries
  needed here (this part isn't 1C-specific), including a genuine
  divergent-history scenario to verify the abort-before-any-progress
  guarantee. Three real bugs surfaced only by this feature (never visible
  before, because 006/007 never inspected committed git state via a real
  push+clone, only ever read files off the one continuously-existing
  local disk): (1) `gitrunner.получить_текущую_ветку()` (`rev-parse
  --abbrev-ref HEAD`) fails on an unborn HEAD — normal for a freshly
  `gitsync init`-ed repo, since `repo_init.ps` writes `VERSION`/`AUTHORS`
  without ever committing — fixed with a `symbolic-ref --short HEAD`
  escape-hatch call inside `sync.ps` itself, not a `gitrunner` change; (2)
  unborn HEAD + a remote branch that already has commits — the untracked
  `VERSION`/`AUTHORS` files block a normal `git pull` ("Please move or
  remove them before you merge") — fixed with `git fetch` + `git
  checkout -B <branch> -f <remote>/<branch>` in that one specific case
  only (safe because there are zero local commits to lose); (3) `VERSION`
  was written to disk AFTER each version's commit, not before — so it
  landed in git history one version behind, and the very last version's
  `VERSION` was never committed at all, staying as an uncommitted
  working-tree change forever — invisible previously since
  `vf.прочитать_версию()` always read the live disk file directly, never
  the git-committed content. See `specs/008-gitsync-auto-push-pull/`
  (plan/research/data-model/quickstart).
- 007-gitsync-per-version-author: Extends `panosiki/v8storage` with
  `отчёт_по_версиям` (wraps `/ConfigurationRepositoryReport`, same
  `ос.выполнить` pattern as every other `v8storage` method) and adds a new
  package `panosiki/скобки` — a panos port of a NARROW slice of
  `oscript-library/yabr` (MPL-2.0): a generic recursive parser for 1C's
  "bracket format" (`{...}`-nested text serialization — used across many
  1C file types: registration logs, cluster settings, MXL tabular
  documents) plus the specific MXL-cell-addressing logic (verbatim-ported
  "magic offset" constants from `yabr`'s `ПолучитьОписаниеЯчейки`/
  `ЭтоЯчейкаТаблицы` — empirically reverse-engineered, not documented by
  1C, deliberately NOT re-derived) needed to read a storage-version report
  (`"Версия:"`/`"Пользователь:"`/`"Дата создания:"`/`"Комментарий:"` per
  version). This REVERSES 006's conclusion that per-version commit
  authorship needs MXL/COM-interop — the MXL report turns out to be plain
  bracket-format text, not OLE-binary, readable via the same
  `ос.выполнить`-plus-text-parser pattern as everything else in this
  project, no COM/native layer needed, cross-platform. Wired into
  `panosiki/gitsync/sync.ps`, replacing 006's single-author-per-run
  simplification with per-version lookup (falling back to the 006
  behavior — single run-wide author — if the report is unavailable or a
  specific version is missing from it, so `sync` never hard-fails on
  this). Test fixtures are a SYNTHETIC bracket-format sample (matching the
  structure confirmed via `yabr`'s real example `CR_versions_small.mxl`),
  not a copy of that MPL-2.0 file itself — avoids vendoring third-party
  Covered Software when an equivalent-structure fixture is enough. All 9
  `panosiki/*` packages (the 7 from 004 + `gitsync` + `скобки`) were
  pushed to real public GitHub repos under `github.com/Garius6/*` (with
  tags) during this feature — `pan.toml` sources across the ecosystem now
  point at GitHub URLs instead of local absolute file paths (`pan`'s
  clone step is a plain `git clone`, so both were always supported
  equally; only the actual repos existing remotely was new). See
  `specs/007-gitsync-per-version-author/` (plan/research/data-model/
  quickstart).
- 006-gitsync-port: New `../panosiki/gitsync/` package (own git repo, same
  pattern as the 7 dependency packages) — the actual gitsync sync-loop
  application (git-based 1C infobase config storage sync), composing
  `gitrunner`/`v8runner`/`v8storage`/`cli`/`std/кодирование/toml.ps` with
  ZERO changes to any of them. Two things that looked like gaps in the
  already-built dependencies turned out to need no extension at all: (1)
  no "list storage versions" method on `v8storage` — resolved by
  sequentially probing `версию_в_файл(N, ...)` from last-synced+1 until
  the first failure, reusing the existing method as-is (deliberately not
  extending v8storage with output-parsing for a version list — same
  unverifiable-without-real-1C risk that excluded this from v8storage the
  first time, spec 004); (2) no per-commit author parameter on
  `gitrunner`'s `закоммитить` — resolved by calling
  `установить_настройку("user.name"/"user.email", ...)` immediately
  before each commit (git reads the local config at commit time, so this
  gives correct per-version authorship without touching gitrunner).
  `VERSION` file is plain text (a single number, not the original's XML)
  and `AUTHORS` is TOML (not the original's INI) — both already decided
  in specs/004's scope discussion, reused here. Scope deliberately
  excludes (see spec.md Assumptions): the plugin/event-subscription
  system (separate `gitsync-plugins` repo in the original), automatic git
  push/pull (call `gitrunner` directly instead — NOTE: 008 above adds
  this, opt-in), http/tcp storage protocols (`v8storage` is
  file-path-only), and multi-storage sync (`all` command — unsupported
  even in the original). NOTE: 007 above supersedes this feature's
  Assumption that per-version commit authorship is infeasible without
  COM. See `specs/006-gitsync-port/` (plan/research/data-model/contracts/
  quickstart).
- 005-language-fixes: Three compiler-only grammar/typechecker fixes found while
  porting gitsync deps (specs/004) — no new dependency, `core/parser.odin` +
  `core/type_cheker.odin` only. (1) Qualified generic type as a type-annotation
  across a module boundary (`модуль.Тип(Аргумент)`) — `Type_Qualified` gains a
  `params []Type_Node` field, parsed the same way as local `Type_Generic`;
  `type_cheker.odin`'s `Type_Qualified` case instantiates via the same
  `instantiate_type`/`decl_type_param_order`/`generic_instance_cache` path
  already used for local generics. (2) Multi-statement `выбор` arm bodies —
  `Match_Arm.body` was already `[dynamic]Stmt` and both `infer_match_expr`
  (type_cheker.odin) and `compile_match_expr` (compiler.odin) already handle
  arbitrary-length bodies generically; only `parse_match_expr` hard-capped at
  one statement. Fix reuses the existing `тогда`/`конец` tokens (already used
  by `если`) as an explicit multi-statement marker — `Шаблон -> выражение`
  (unchanged single-line form) vs `Шаблон тогда стейтмент1 \n стейтмент2 \n
  конец` — deliberately NOT parser backtracking (pattern grammar `a.b(...)` is
  syntactically identical to a method-call statement, so "just keep parsing
  statements until the next arm" can't be disambiguated without either a
  marker token or true backtracking; this parser has zero backtracking
  infrastructure anywhere — checked). (3) Trailing comma in comma-separated
  lists — already safe in `parse_param_list`/array-literal/map-literal/
  function-type-params, NOT safe (confirmed bug, not just missing feature) in
  call args/enum variant types/pattern-constructor args/generic type-args/
  tuple-type elements — mechanical fix applied to the unsafe sites, matching
  the already-established safe pattern in the same file. Also added top-level
  `[экспорт] конст ИМЯ = <литерал>` (Число/Строка/Булево, compiled by
  substitution, no runtime storage — panos deliberately has no top-level
  mutable state) and `математика.Генератор` (stateful PRNG wrapper over the
  pre-existing Lehmer/Park-Miller `следующее`/`дробь`/`диапазон`, auto-seeded
  from `время.сейчас_мс()` with warm-up iterations to decorrelate close-in-time
  seeds). See `specs/005-language-fixes/` (plan/research/data-model/contracts).
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
