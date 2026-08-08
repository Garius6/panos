# Native resource integration tests

Real, end-to-end `.ps` programs exercising native-only resources (disk, TCP
sockets, SQLite, `внешний`/libffi) — as opposed to `zig/core/runner.zig`'s
inline test sources, these are standalone fixture files so they can be run
directly (`panos tests/integration/native/file_roundtrip.ps`) for manual
inspection, not just from `native_test.zig`.

Deterministic (no real network) fixtures assert an exact result. The one
network fixture (`http_client_error.ps`) deliberately only exercises a
CONTROLLED failure path (connection refused on a closed local port) — no
fixture here depends on outbound internet access, matching the "controlled"
scope from `specs/010-zig-migration/tasks.md` T042 (the HTTP-server /
TCP-client HAPPY-PATH cases already have real-socket coverage in
`zig/core/runner.zig`, which spawns its own listener rather than reaching
out to a third-party host).

Each fixture's expected result is asserted by `native_test.zig`, wired into
`zig build test`/`zig build conformance`.
