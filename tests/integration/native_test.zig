const std = @import("std");
const panos_core = @import("panos_core");

fn deleteTempFile(path: []const u8) void {
    var io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io.deinit();
    std.Io.Dir.cwd().deleteFile(io.io(), path) catch {};
}

// Real, standalone `.ps` fixture programs (not inline source strings) —
// exercising native-only resources end-to-end. See
// `tests/integration/native/README.md` for scope (deterministic + one
// controlled-failure network case, no outbound internet access needed).

test "integration: file_roundtrip.ps writes then reads a real file" {
    const source = @embedFile("native/file_roundtrip.ps");
    var result = try panos_core.runner.runSource(std.testing.allocator, "file_roundtrip.ps", source);
    defer result.deinit();
    defer deleteTempFile("zzz_integration_native_file.tmp");
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("панос-интеграция", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "integration: sqlite_roundtrip.ps creates, inserts, and queries a real SQLite file" {
    const source = @embedFile("native/sqlite_roundtrip.ps");
    var result = try panos_core.runner.runSource(std.testing.allocator, "sqlite_roundtrip.ps", source);
    defer result.deinit();
    defer deleteTempFile("zzz_integration_native_sqlite.tmp");
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("панос", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "integration: ffi_libc.ps calls real libc functions through внешний" {
    const source = @embedFile("native/ffi_libc.ps");
    var result = try panos_core.runner.runSource(std.testing.allocator, "ffi_libc.ps", source);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        // abs(-42) == 42, strlen("панос") == 10 (5 Cyrillic codepoints, 2
        // UTF-8 bytes each — strlen counts bytes, not codepoints).
        .success => |output| try std.testing.expectEqualStrings("52", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "integration: http_client_error.ps reports a controlled connection-refused failure" {
    const source = @embedFile("native/http_client_error.ps");
    var result = try panos_core.runner.runSource(std.testing.allocator, "http_client_error.ps", source);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
    switch (result.execution orelse return error.TestUnexpectedResult) {
        .success => |output| try std.testing.expectEqualStrings("ошибка:ConnectionRefused", output),
        .runtime_error => return error.TestUnexpectedResult,
    }
}
