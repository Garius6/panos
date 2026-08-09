# CLI Compatibility Contract

## Executable

The native executable remains `panos`.

## Invocation

```text
panos [-v|--verbose] [file.ps] [program arguments...]
panos build --target=wasm <file.ps> [-o output.wasm]
```

- With no `file.ps`, `panos` prints "Panos REPL пока не реализован" and
  exits 0. No REPL exists yet on either implementation (Odin's own `repl()`,
  `main.odin`, is an empty stub) — this is not a compatibility target,
  just the current honest behavior.
- `-v` and `--verbose` are interpreter flags only when they occur before the
  source file; subsequent arguments are exposed unchanged to
  `ос.аргументы()`.
- Only `--target=wasm` is accepted by `build`.
- With no `-o`, build output is the input basename with `.wasm` suffix.

## Results and diagnostics

- Successful execution returns status `0` unless a Panos program explicitly
  requests a supported non-zero process exit.
- Parser, resolver and type diagnostics are emitted as
  `path:line:column: message`; warning messages include `warning: ` before the
  Russian message.
- Any error diagnostic prevents lowering and execution/build, while warnings
  are printed but do not by themselves prevent it.
- Build failure writes no successful-artifact message. Successful AOT build
  prints `panos build: записан <path>`.

## Compatibility boundaries

This contract preserves documented command syntax and observable output. It
does not promise byte-for-byte identity of verbose internal AST/MIR dumps; the
conformance suite instead validates their semantic source maps and execution
result.
