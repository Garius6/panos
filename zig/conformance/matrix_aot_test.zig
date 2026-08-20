const std = @import("std");
const matrix_runner = @import("matrix_runner.zig");

// Компилирует в WASM и запускает `wasmtime` для каждого случая — совсем
// другой, значительно более тяжёлый путь выполнения, чем у уровней на
// байткод-VM выше. Отдельный шаг сборки (`zig build aot`), никогда не
// включается в `zig build test`/`conformance`.
test "every aot-tier manifest case's recorded expected outcome matches a real panos build --target=wasm + wasmtime run" {
    try matrix_runner.runAot(std.testing.allocator);
}
