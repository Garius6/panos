# Conformance corpus

`manifest.json` records user-observable Panos behavior once, per the
contract in `specs/010-zig-migration/contracts/conformance.md` (stable
`id`, tier, target profile, input, normalized outcome). `semantic`/`runtime`
tier cases are populated (T053) and gated automatically on every
`zig build test`/`conformance` via `zig/conformance/matrix_test.zig`, which
runs each case's `.ps` input through the Zig pipeline and asserts the
recorded `expected` outcome still holds.

`lexer`/`parser` tiers have equivalent coverage through their own dedicated
harnesses (`lexer_test.zig`/`parser_test.zig`, `tests/conformance/lexer/`
and `parser/`) rather than duplicate manifest cases. `native`/`browser`/
`aot`/`lsp` tiers have no manifest cases yet — `native` is blocked by a real
architectural difference (Zig makes builtin modules like `фс`/`сеть` ambient
without `импорт`, unlike Odin, which requires it — see T053's entry in
`specs/010-zig-migration/progress-report.md`), the rest need harnesses not
built yet.

Each `expected` outcome was determined by actually running BOTH a freshly
built Odin reference binary and the Zig CLI side by side on the same input,
not assumed. Where they genuinely differ, the case records an
`ApprovedDeviation` (id + rationale) per the contract's deviation policy —
see the `deviation` fields already in `manifest.json` for two real examples
found this way (a number-formatting quirk in Odin's own renderer, and a
type-checker error message that's less detailed on the Zig side).

`zig/conformance/reference.zig` (the old `odin run ...` shell-out helper,
used only for one-time manual comparisons like the ones above) was retired
in T058 — nothing in the build depends on a live Odin install anymore.
