# panos Development Guidelines

Auto-generated from feature plans. Last updated: 2026-07-20.

## Active Technologies
- mdBook (docs/) — internal architecture documentation, no new dependency (002-interpreter-architecture-docs)
- Odin (toolchain pinned via `Justfile`), stdlib packages `core:fmt`, `core:strings`, `core:strconv`.

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

## Recent Changes
- 002-interpreter-architecture-docs: New mdBook section `docs/src/architecture/`
  documenting interpreter internals (pipeline, runtime, LSP, known pitfalls,
  toolchain, recipes) for maintainers editing without LLM help.
- 001-adt-pattern-matching: Added ADT + pattern matching using
  `core:fmt`, `core:strings`, `core:strconv`.

<!-- MANUAL ADDITIONS START -->

## Конституция проекта

Перед началом любой работы читай `.specify/memory/constitution.md` — это конституция проекта, обязательна к соблюдению.

<!-- MANUAL ADDITIONS END -->
