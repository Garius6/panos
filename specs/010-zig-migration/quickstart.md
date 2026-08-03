# Quickstart: целевой Zig-путь Panos

> Этот документ описывает команды после реализации соответствующих фаз. На
> момент создания плана Zig build graph ещё не добавлен; текущие Odin-команды
> остаются рабочим эталоном до cutover.

## Prerequisites

- Zig `0.16.0`.
- Для native FFI/SQL: вендоренные архивы `external/libffi` и
  `external/sqlite3` из репозитория.
- Для optional AOT integration suite: `wasmtime`.
- Для browser smoke: Node-compatible browser test harness, заданный CI.

## Target commands

```sh
zig build                         # native panos
zig build test                    # Zig unit + integration tests
zig build conformance             # conformance corpus against Zig
zig build lsp                     # panos-lsp
zig build browser                 # browser interpreter WASM
zig build aot-runtime-js          # runtime for generated JS WASM
zig build aot-runtime-wasi        # runtime for wasmtime tests
zig build test-aot                # optional AOT WASM suite
```

Before cutover, `zig build conformance-reference` is the only build step
allowed to invoke the Odin reference implementation. It is removed when Phase
7 gate passes.

## Manual smoke checks

```sh
zig build run -- test.ps
zig build run -- build --target=wasm fixtures/module_fixture_main.ps -o /tmp/panos.wasm
zig build lsp
```

The final `Justfile`, if kept for convenience, delegates to these Zig steps
and never calls Odin.
