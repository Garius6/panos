const std = @import("std");
const panos = @import("panos_embed");

// This is the exact shape a future Zig game executable uses: the host owns
// the implementation and publishes a narrow C ABI; Panos resolves it through
// `внешний "хост"`, without a game-specific builtin in the interpreter.
pub export fn panos_embed_host_scale(value: f64) f64 {
    return value * 2.0;
}

const MemoryReader = struct {
    source: []const u8,

    pub fn read(self: *const MemoryReader, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        if (!std.mem.eql(u8, path, "сценарий.pns")) return error.FileNotFound;
        return allocator.dupe(u8, self.source);
    }
};

test "embedded runtime calls a C-ABI host export" {
    const reader = MemoryReader{
        .source = "внешний \"хост\" функ panos_embed_host_scale(значение: Число(64)) -> Число(64)\n" ++
            "экспорт функ обновить(дельта: Число) -> Число\n" ++
            "panos_embed_host_scale(дельта)\n" ++
            "конец",
    };

    var runtime = panos.Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();
    try runtime.load(&reader, "сценарий.pns");
    try std.testing.expect(!runtime.hasGraphErrors());
    try runtime.compile();
    try std.testing.expect(!runtime.hasCompilationErrors());

    switch (try runtime.call("обновить", &.{.{ .number = 21.0 }})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42.0), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}
