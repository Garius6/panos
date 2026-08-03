const std = @import("std");
const diagnostic = @import("panos_core").diagnostic;

pub const Status = enum {
    success,
    diagnostic,
    runtime_error,
    unsupported,
    controlled_external,
};

pub const NormalizedDiagnostic = struct {
    phase: diagnostic.Phase,
    severity: diagnostic.Severity,
    path: []const u8,
    start_byte: u32,
    end_byte: u32,
    message: []const u8,

    pub fn fromDiagnostic(path: []const u8, value: diagnostic.Diagnostic) NormalizedDiagnostic {
        return .{
            .phase = value.phase,
            .severity = value.severity,
            .path = path,
            .start_byte = value.span.start,
            .end_byte = value.span.end,
            .message = value.message,
        };
    }
};

pub const ApprovedDeviation = struct {
    id: []const u8,
    rationale: []const u8,
};

pub const Outcome = struct {
    status: Status,
    exit_code: i32,
    stdout: []const u8,
    result: ?[]const u8 = null,
    diagnostics: []const NormalizedDiagnostic = &.{},
    deviation: ?ApprovedDeviation = null,
};

pub const Mismatch = enum {
    status,
    exit_code,
    stdout,
    result,
    diagnostics,
};

pub fn firstMismatch(expected: Outcome, actual: Outcome) ?Mismatch {
    if (expected.status != actual.status) return .status;
    if (expected.exit_code != actual.exit_code) return .exit_code;
    if (!std.mem.eql(u8, expected.stdout, actual.stdout)) return .stdout;
    if (!optionalTextEqual(expected.result, actual.result)) return .result;
    if (expected.diagnostics.len != actual.diagnostics.len) return .diagnostics;

    for (expected.diagnostics, actual.diagnostics) |left, right| {
        if (!diagnosticEqual(left, right)) return .diagnostics;
    }
    return null;
}

pub fn normalizePath(
    allocator: std.mem.Allocator,
    path: []const u8,
    repo_root: ?[]const u8,
    temp_root: ?[]const u8,
) ![]u8 {
    var suffix = path;
    var prefix: []const u8 = "";

    if (repo_root) |root| {
        if (hasPathPrefix(path, root)) {
            prefix = "<repo>";
            suffix = path[root.len..];
        }
    }
    if (prefix.len == 0) {
        if (temp_root) |root| {
            if (hasPathPrefix(path, root)) {
                prefix = "<tmp>";
                suffix = path[root.len..];
            }
        }
    }

    var normalized: std.ArrayList(u8) = .empty;
    errdefer normalized.deinit(allocator);
    try normalized.appendSlice(allocator, prefix);
    for (suffix) |byte| {
        try normalized.append(allocator, if (byte == '\\') '/' else byte);
    }
    return normalized.toOwnedSlice(allocator);
}

fn optionalTextEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn diagnosticEqual(left: NormalizedDiagnostic, right: NormalizedDiagnostic) bool {
    return left.phase == right.phase and
        left.severity == right.severity and
        left.start_byte == right.start_byte and
        left.end_byte == right.end_byte and
        std.mem.eql(u8, left.path, right.path) and
        std.mem.eql(u8, left.message, right.message);
}

fn hasPathPrefix(path: []const u8, root: []const u8) bool {
    return std.mem.startsWith(u8, path, root) and
        (path.len == root.len or root.len == 0 or path[root.len] == '/' or path[root.len] == '\\');
}

test "outcomes compare every user-observable field in order" {
    const diagnostics = [_]NormalizedDiagnostic{.{
        .phase = .lexer,
        .severity = .err,
        .path = "fixtures/broken.ps",
        .start_byte = 4,
        .end_byte = 5,
        .message = "Лексическая ошибка: неожиданный символ '$'",
    }};
    const expected = Outcome{
        .status = .diagnostic,
        .exit_code = 1,
        .stdout = "",
        .diagnostics = &diagnostics,
    };
    try std.testing.expectEqual(@as(?Mismatch, null), firstMismatch(expected, expected));

    var changed = expected;
    changed.exit_code = 2;
    try std.testing.expectEqual(Mismatch.exit_code, firstMismatch(expected, changed).?);

    changed = expected;
    changed.diagnostics = &.{.{
        .phase = .lexer,
        .severity = .err,
        .path = "fixtures/broken.ps",
        .start_byte = 4,
        .end_byte = 5,
        .message = "Лексическая ошибка: незакрытая строка",
    }};
    try std.testing.expectEqual(Mismatch.diagnostics, firstMismatch(expected, changed).?);
}

test "normalization replaces only approved path roots" {
    const repo_path = try normalizePath(
        std.testing.allocator,
        "/work/panos/tests/conformance/lexer/basic.ps",
        "/work/panos",
        "/tmp",
    );
    defer std.testing.allocator.free(repo_path);
    try std.testing.expectEqualStrings("<repo>/tests/conformance/lexer/basic.ps", repo_path);

    const temp_path = try normalizePath(
        std.testing.allocator,
        "C:\\temp\\panos\\fixture.ps",
        null,
        "C:\\temp",
    );
    defer std.testing.allocator.free(temp_path);
    try std.testing.expectEqualStrings("<tmp>/panos/fixture.ps", temp_path);

    const similar_path = try normalizePath(
        std.testing.allocator,
        "/tmp2/fixture.ps",
        null,
        "/tmp",
    );
    defer std.testing.allocator.free(similar_path);
    try std.testing.expectEqualStrings("/tmp2/fixture.ps", similar_path);
}
