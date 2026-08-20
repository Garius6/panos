const std = @import("std");
const matrix_runner = @import("matrix_runner.zig");

// Включает фикстуры `tests/conformance/benchmarks/*.ps` (`фиб(30)`, цикл на
// 5 миллионов итераций, 20 тыс. конкатенаций строк) — по-настоящему
// медленные под байткод-VM в Debug-режиме. Намеренно отдельный шаг сборки
// (`zig build conformance`), никогда не `zig build test` — см. doc-комментарий
// модуля `matrix_runner.zig`.
test "every runtime-tier manifest case's recorded expected outcome matches Zig's actual outcome" {
    try matrix_runner.runTier(std.testing.allocator, "runtime");
}
