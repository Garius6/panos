const std = @import("std");

pub const FileId = u16;

pub const LineColumn = struct {
    line: u32,
    column: u32,
};

pub const Span = struct {
    file_id: FileId,
    start: u32,
    end: u32,

    pub fn contains(self: Span, file_id: FileId, offset: u32) bool {
        return self.file_id == file_id and self.start <= offset and offset < self.end;
    }

    pub fn isValidFor(self: Span, source: SourceFile) bool {
        return self.file_id == source.id and self.start <= self.end and self.end <= source.bytes.len;
    }
};

pub const SourceFile = struct {
    id: FileId,
    path: []const u8,
    bytes: []const u8,

    pub fn init(id: FileId, path: []const u8, bytes: []const u8) SourceFile {
        return .{
            .id = id,
            .path = path,
            .bytes = bytes,
        };
    }

    pub fn isUtf8(self: SourceFile) bool {
        return std.unicode.utf8ValidateSlice(self.bytes);
    }

    pub fn lineColumn(self: SourceFile, offset: u32) LineColumn {
        const limit = @min(@as(usize, @intCast(offset)), self.bytes.len);
        var line: u32 = 1;
        var column: u32 = 1;

        for (self.bytes[0..limit]) |byte| {
            if (byte == '\n') {
                line += 1;
                column = 1;
            } else {
                column += 1;
            }
        }
        return .{ .line = line, .column = column };
    }
};

test "source positions use byte columns and one-based lines" {
    const source = SourceFile.init(4, "пример.ps", "путь\n42");

    try std.testing.expect(source.isUtf8());
    try std.testing.expectEqualDeep(LineColumn{ .line = 1, .column = 1 }, source.lineColumn(0));
    try std.testing.expectEqualDeep(LineColumn{ .line = 2, .column = 1 }, source.lineColumn(9));
    try std.testing.expectEqualDeep(LineColumn{ .line = 2, .column = 3 }, source.lineColumn(99));
}

test "spans stay inside their source file" {
    const source = SourceFile.init(7, "main.ps", "пер имя = 1");
    const span = Span{ .file_id = 7, .start = 0, .end = 6 };

    try std.testing.expect(span.isValidFor(source));
    try std.testing.expect(span.contains(7, 0));
    try std.testing.expect(!span.contains(8, 0));
    try std.testing.expect(!(Span{ .file_id = 7, .start = 6, .end = 5 }).isValidFor(source));
}

test "source reports invalid UTF-8 without decoding it" {
    const source = SourceFile.init(0, "broken.ps", "\xff");

    try std.testing.expect(!source.isUtf8());
}
