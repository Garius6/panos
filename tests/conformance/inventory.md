# Baseline inventory

## Scope and rules

Phase 0 starts with 31 `core/*_test.odin` files and 55 `fixtures/**/*.ps`
files. Every item below has a delivery class before it can become a manifest
case. A classification is not an implementation promise: it identifies the
runner and controlled environment required to establish an Odin golden.

- **Deterministic**: runs entirely from tracked input and has a stable outcome.
- **Controlled external**: needs a fake, loopback service, temporary directory
  or property assertion before it can be compared.
- **Target-specific**: must be captured per WASM/native target profile.
- **Support**: helper/module source; it is exercised through an entry fixture,
  not a case by itself.

## Core test files

| File | Class | Initial conformance tier |
|------|-------|--------------------------|
| `core/document_symbols_test.odin` | Deterministic | LSP features |
| `core/e2e_actors_test.odin` | Deterministic | Runtime actors/scheduler |
| `core/e2e_adt_match_test.odin` | Deterministic | Semantic and runtime ADT |
| `core/e2e_annotations_test.odin` | Deterministic | Parser and semantic annotations |
| `core/e2e_async_io_test.odin` | Controlled external | Native async I/O |
| `core/e2e_closures_test.odin` | Deterministic | Runtime closures |
| `core/e2e_control_flow_bindings_test.odin` | Deterministic | Parser, semantic and runtime control flow |
| `core/e2e_core_semantics_test.odin` | Deterministic | Core runtime semantics |
| `core/e2e_doc_comments_test.odin` | Deterministic | Lexer/parser documentation |
| `core/e2e_ffi_test.odin` | Controlled external | Native FFI |
| `core/e2e_http_server_test.odin` | Controlled external | Native HTTP server |
| `core/e2e_language_fixes_test.odin` | Deterministic | Parser and type checker |
| `core/e2e_lexer_parser_diag_test.odin` | Deterministic | Lexer/parser diagnostics |
| `core/e2e_modules_stdlib_test.odin` | Deterministic | Module graph and stdlib |
| `core/e2e_process_native_test.odin` | Controlled external | Native processes |
| `core/e2e_random_test.odin` | Controlled external | Random property checks |
| `core/e2e_runtime_gc_test.odin` | Deterministic | Tracing heap |
| `core/e2e_sql_test.odin` | Controlled external | Native SQLite |
| `core/e2e_test.odin` | Support | Odin e2e helpers |
| `core/e2e_top_level_const_test.odin` | Deterministic | Resolver/type checker constants |
| `core/e2e_type_alias_test.odin` | Deterministic | Semantic type aliases |
| `core/e2e_types_interfaces_test.odin` | Deterministic | Nominal types and interfaces |
| `core/folding_ranges_test.odin` | Deterministic | LSP features |
| `core/fuzz_test.odin` | Deterministic | Lexer/parser property checks |
| `core/mir_optimize_test.odin` | Deterministic | MIR optimization |
| `core/mir_test.odin` | Deterministic | MIR lowering/validation |
| `core/selection_range_test.odin` | Deterministic | LSP features |
| `core/semantic_tokens_test.odin` | Deterministic | LSP features |
| `core/signature_help_test.odin` | Deterministic | LSP features |
| `core/wasm_backend_test.odin` | Target-specific | AOT JS WASM |
| `core/wasm_backend_wasmtime_test.odin` | Target-specific | AOT WASI/wasmtime |

## Fixture files

| Fixture | Class | Role |
|---------|-------|------|
| `fixtures/adt_fixture_main.ps` | Deterministic | ADT module entry |
| `fixtures/adt_fixture_private_main.ps` | Deterministic | Private ADT module entry |
| `fixtures/adt_fixture_private_shapes.ps` | Support | Private ADT module |
| `fixtures/adt_fixture_private_use.ps` | Deterministic | Private ADT rejection |
| `fixtures/adt_fixture_shapes.ps` | Support | Exported ADT module |
| `fixtures/adt_fixture_short.ps` | Deterministic | Short ADT module entry |
| `fixtures/archive_fixture_main.ps` | Controlled external | Native archive/filesystem |
| `fixtures/bounded_generic_iface_fixture_main.ps` | Deterministic | Generic interface entry |
| `fixtures/bounded_generic_iface_module.ps` | Support | Generic interface module |
| `fixtures/collections_fixture_main.ps` | Deterministic | Collections module entry |
| `fixtures/const_fixture_lib.ps` | Support | Constant module |
| `fixtures/const_fixture_main.ps` | Deterministic | Exported constant entry |
| `fixtures/const_fixture_main_private.ps` | Deterministic | Private constant rejection |
| `fixtures/flags_fixture_main.ps` | Deterministic | Stdlib flags entry |
| `fixtures/generic_cross_module_fixture_lib.ps` | Support | Generic module |
| `fixtures/generic_cross_module_fixture_main.ps` | Deterministic | Generic module entry |
| `fixtures/http_router_fixture_main.ps` | Deterministic | HTTP router module entry |
| `fixtures/http_router_serve_fixture_main.ps` | Controlled external | Native HTTP server route |
| `fixtures/http_serve_sugar_fixture_main.ps` | Controlled external | Native HTTP server sugar |
| `fixtures/http_url_fixture_main.ps` | Deterministic | URL module entry |
| `fixtures/impl_qualified_target_gen.ps` | Support | Generic implementation module |
| `fixtures/impl_qualified_target_lib.ps` | Support | Qualified implementation module |
| `fixtures/impl_qualified_target_main.ps` | Deterministic | Qualified implementation entry |
| `fixtures/interface_cross_module_lib.ps` | Support | Interface module |
| `fixtures/interface_cross_module_main.ps` | Deterministic | Interface module entry |
| `fixtures/json_fixture_main.ps` | Target-specific | AOT WASM JSON regression |
| `fixtures/math_fixture_main.ps` | Deterministic | Math module entry |
| `fixtures/module_fixture_main.ps` | Deterministic | Basic module entry |
| `fixtures/module_fixture_math.ps` | Support | Imported math module |
| `fixtures/module_fixture_missing_import_main.ps` | Deterministic | Missing import diagnostic |
| `fixtures/module_fixture_nested/helper.ps` | Support | Nested imported module |
| `fixtures/module_fixture_nested_main.ps` | Deterministic | Nested module entry |
| `fixtures/qualified_generic_fixture_lib.ps` | Support | Qualified generic module |
| `fixtures/qualified_generic_fixture_main.ps` | Deterministic | Qualified generic entry |
| `fixtures/qualified_generic_fixture_main_not_exported.ps` | Deterministic | Generic visibility diagnostic |
| `fixtures/qualified_generic_fixture_main_wrong_arity.ps` | Deterministic | Generic arity diagnostic |
| `fixtures/random_fixture_main.ps` | Controlled external | Random property entry |
| `fixtures/spawn_qualified_bad_module_fixture_main.ps` | Deterministic | Spawn module diagnostic |
| `fixtures/spawn_qualified_bad_type_fixture_main.ps` | Deterministic | Spawn type diagnostic |
| `fixtures/spawn_qualified_fixture_main.ps` | Deterministic | Qualified spawn entry |
| `fixtures/spawn_qualified_module.ps` | Support | Spawn imported module |
| `fixtures/spawn_qualified_not_function_fixture_main.ps` | Deterministic | Spawn function diagnostic |
| `fixtures/stdlib_fixture_main.ps` | Deterministic | File stdlib entry |
| `fixtures/supervisor_dynamic_add_fixture_main.ps` | Deterministic | Supervisor actor entry |
| `fixtures/supervisor_dynamic_remove_fixture_main.ps` | Deterministic | Supervisor actor entry |
| `fixtures/supervisor_fixture_main.ps` | Deterministic | Supervisor actor entry |
| `fixtures/supervisor_narrow_window_fixture_main.ps` | Deterministic | Supervisor actor entry |
| `fixtures/supervisor_one_for_all_fixture_main.ps` | Deterministic | Supervisor actor entry |
| `fixtures/supervisor_rest_for_one_fixture_main.ps` | Deterministic | Supervisor actor entry |
| `fixtures/test_fixture_main.ps` | Deterministic | Test stdlib entry |
| `fixtures/toml_fixture_main.ps` | Deterministic | TOML stdlib entry |
| `fixtures/type_alias_fixture_lib.ps` | Support | Type-alias module |
| `fixtures/type_alias_fixture_main.ps` | Deterministic | Type-alias entry |
| `fixtures/логгер_fixture_main.ps` | Deterministic | Logger stdlib entry |
| `fixtures/слог_fixture_main.ps` | Deterministic | Slog stdlib entry |

## Manifest admission order

1. Deterministic lexer/parser cases.
2. Deterministic single-file semantic/runtime cases.
3. Deterministic module fixtures and negative diagnostics.
4. Controlled-external cases with a tracked fake or loopback harness.
5. Target-specific JS/WASI AOT cases.
