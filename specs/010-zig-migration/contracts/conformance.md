# Conformance Corpus Contract

## Purpose

The corpus records user-observable Panos behavior once and makes it executable
by both the Odin reference runner (before cutover) and the Zig implementation.
It is the gate for every migration phase, not a collection of implementation
snapshots.

## Case record

```text
id: stable string
tier: lexer | parser | semantic | runtime | native | browser | aot | lsp
profile: native | browser_interpreter | aot_js_wasm | aot_wasi
input: inline source or fixture entry path
arguments: ordered strings
environment: deterministic overrides, if any
expected: Outcome
```

`id` is never renumbered. A fixture can provide multiple cases with distinct
profiles and expectations.

## Outcome record

```text
status: success | diagnostic | runtime_error | unsupported | controlled_external
exit_code: integer
stdout: normalized UTF-8 text
result: optional canonical value representation
diagnostics:
  - phase, severity, path, start_byte, end_byte, message
deviation: optional approved-reference-fix ID and rationale
```

- `success` compares stdout and canonical value when the case exposes one.
- `diagnostic` compares the ordered diagnostic contract.
- `runtime_error` compares the runtime error category/message/span available
  to the CLI.
- `unsupported` is valid only when the profile forbids the capability.
- `controlled_external` supplies a deterministic fake/loopback service and
  remains mandatory only in the environment declared by the case.

## Normalization

Temporary directories, host paths, timestamps, pointer addresses, worker IDs
and stack traces are normalized before comparison. Russian diagnostics, source
locations, user stdout and program-visible values are never normalized away.

## Deviation policy

An outcome difference is accepted only with a stable deviation ID, rationale,
approver and reference to a tracked defect. Missing or expired deviations fail
the run. At cutover all deviations are reviewed; only intentional fixes remain.
