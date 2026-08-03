# Baseline inventory

## Scope

На старте Phase 0 зафиксировано 31 файл `core/*_test.odin` и 55 файлов в
`fixtures/`. Полная построчная классификация вносится до первого
differential run; ни один неучтённый сценарий не может считаться
поддержанным новым runtime.

## Initial groups

| Group | Initial classification | Examples |
|-------|------------------------|----------|
| Lexer/parser/semantic | Deterministic | `e2e_lexer_parser_diag_test.odin`, `e2e_core_semantics_test.odin` |
| Modules/types/ADT | Deterministic | `e2e_modules_stdlib_test.odin`, `e2e_types_interfaces_test.odin`, `e2e_adt_match_test.odin` |
| VM/GC/actors | Deterministic | `e2e_runtime_gc_test.odin`, `e2e_actors_test.odin`, `e2e_closures_test.odin` |
| Native resources | Controlled external | `e2e_http_server_test.odin`, `e2e_sql_test.odin`, `e2e_ffi_test.odin` |
| Target-specific WASM | Target-specific | `wasm_backend_test.odin`, `wasm_backend_wasmtime_test.odin` |
| LSP computations | Deterministic | `semantic_tokens_test.odin`, `signature_help_test.odin`, `selection_range_test.odin` |

## Fixture policy

All `fixtures/*.ps` remain source inputs. A fixture receives one or more
manifest IDs only after its entry point, arguments, target profile and expected
outcome are recorded.
