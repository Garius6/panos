# Conformance corpus

`manifest.json` records user-observable Panos behavior once, per the
contract in `specs/010-zig-migration/contracts/conformance.md` (stable
`id`, tier, target profile, input, normalized outcome). `semantic`/
`runtime`/`native`/`aot` tier cases are populated (T053) and gated by
`zig/conformance/matrix_runner.zig`'s shared `runTier`/`runAot` — each
tier is its OWN build artifact (`matrix_semantic_test.zig`/
`matrix_runtime_test.zig`/`matrix_native_test.zig`/`matrix_aot_test.zig`,
so Zig's build graph can run them in parallel instead of one sequential
loop), running each case's `.ps` input through the Zig pipeline (bytecode
VM for `semantic`/`runtime`/`native`, the separate MIR→WASM AOT pipeline +
real `wasmtime` for `aot`) and asserting the recorded `expected` outcome
still holds. `zig build test` (fast unit tests) no longer depends on ANY
of these — `semantic`/`native` run under `zig build conformance`,
`runtime` (embeds the slow `tests/conformance/benchmarks/*.ps` fixtures)
under `zig build bench` (prefer `-Doptimize=ReleaseFast`), `aot` under
`zig build aot`.

`lexer`/`parser` tiers have equivalent coverage through their own dedicated
harnesses (`lexer_test.zig`/`parser_test.zig`, `tests/conformance/lexer/`
and `parser/`) rather than duplicate manifest cases. `browser`/`lsp` tiers
have no manifest cases — `browser` needs a WASM-memory-capable host beyond
the `wasmtime` CLI (would add a new Python dependency, see T056's
progress-report.md entry); `lsp` transcripts are JSON-RPC request/response
pairs, a shape the `Case`/`Outcome` schema doesn't model — already covered
directly by `zig/lsp/main.zig`'s own tests instead.

Each `semantic`/`runtime` `expected` outcome was determined by actually
running BOTH a freshly built Odin reference binary and the Zig CLI side by
side on the same input, not assumed. Where they genuinely differ, the case
records an `ApprovedDeviation` (id + rationale) per the contract's deviation
policy — see the `deviation` fields in `manifest.json` for examples found
this way (a number-formatting quirk in Odin's own renderer, a type-checker
error message that's less detailed on the Zig side, and a real architectural
difference in how native builtin modules are scoped). `native`/`aot` cases
are Zig-only (no Odin comparison attempted): `native` because Zig's builtin
modules are ambient without `импорт` while Odin requires it, so no single
fixture source runs on both toolchains' real CLIs; `aot` because Odin never
built an equivalent MIR-based WASM AOT backend to compare against at all.

`zig/conformance/reference.zig` (the old `odin run ...` shell-out helper,
used only for one-time manual comparisons like the ones above) was retired
in T058 — nothing in the build depends on a live Odin install anymore.
