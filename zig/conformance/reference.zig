const std = @import("std");

pub const Reference_Result = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *Reference_Result, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

pub fn buildArgs(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    program_args: []const []const u8,
) ![]const []const u8 {
    const args = try allocator.alloc([]const u8, 5 + program_args.len);
    args[0] = "odin";
    args[1] = "run";
    args[2] = ".";
    args[3] = "--";
    args[4] = source_path;
    @memcpy(args[5..], program_args);
    return args;
}

pub fn runFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    source_path: []const u8,
    program_args: []const []const u8,
) !Reference_Result {
    const args = try buildArgs(allocator, source_path, program_args);
    defer allocator.free(args);

    const result = try std.process.run(allocator, io, .{
        .argv = args,
        .cwd = .{ .path = repo_root },
    });
    return .{
        .term = result.term,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

test "reference command keeps program arguments after the separator" {
    const args = try buildArgs(std.testing.allocator, "fixtures/module_fixture_main.ps", &.{ "first", "second" });
    defer std.testing.allocator.free(args);

    const expected = [_][]const u8{
        "odin",
        "run",
        ".",
        "--",
        "fixtures/module_fixture_main.ps",
        "first",
        "second",
    };
    try std.testing.expectEqualSlices([]const u8, &expected, args);
}
