const std = @import("std");

pub const FileId = u16;

pub const LineColumn = struct {
    line: u32,
    column: u32,
};

pub const Utf16Position = struct {
    line: u32,
    character: u32,
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

    pub fn byteOffsetToUtf16Position(self: SourceFile, offset: u32) Utf16Position {
        const limit = @min(@as(usize, @intCast(offset)), self.bytes.len);
        var byte_index: usize = 0;
        var line: u32 = 0;
        var character: u32 = 0;
        while (byte_index < limit) {
            if (self.bytes[byte_index] == '\n') {
                byte_index += 1;
                line += 1;
                character = 0;
                continue;
            }
            const sequence_len = std.unicode.utf8ByteSequenceLength(self.bytes[byte_index]) catch {
                byte_index += 1;
                character += 1;
                continue;
            };
            const end = byte_index + @as(usize, sequence_len);
            if (end > limit) break;
            const codepoint = std.unicode.utf8Decode(self.bytes[byte_index..end]) catch {
                byte_index += 1;
                character += 1;
                continue;
            };
            character += if (codepoint > 0xffff) 2 else 1;
            byte_index = end;
        }
        return .{ .line = line, .character = character };
    }

    pub fn utf16PositionToByteOffset(self: SourceFile, position: Utf16Position) ?u32 {
        var byte_index: usize = 0;
        var line: u32 = 0;
        var character: u32 = 0;
        while (byte_index < self.bytes.len) {
            if (line == position.line and character == position.character) return @intCast(byte_index);
            if (self.bytes[byte_index] == '\n') {
                byte_index += 1;
                line += 1;
                character = 0;
                continue;
            }
            const sequence_len = std.unicode.utf8ByteSequenceLength(self.bytes[byte_index]) catch {
                byte_index += 1;
                character += 1;
                continue;
            };
            const end = byte_index + @as(usize, sequence_len);
            if (end > self.bytes.len) return null;
            const codepoint = std.unicode.utf8Decode(self.bytes[byte_index..end]) catch {
                byte_index += 1;
                character += 1;
                continue;
            };
            const width: u32 = if (codepoint > 0xffff) 2 else 1;
            if (line == position.line and character + width > position.character) return null;
            character += width;
            byte_index = end;
        }
        if (line == position.line and character == position.character) return @intCast(byte_index);
        return null;
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

test "source converts positions between bytes and UTF-16" {
    const source = SourceFile.init(0, "пример.ps", "а😀\nб");

    try std.testing.expectEqualDeep(Utf16Position{ .line = 0, .character = 0 }, source.byteOffsetToUtf16Position(0));
    try std.testing.expectEqualDeep(Utf16Position{ .line = 0, .character = 1 }, source.byteOffsetToUtf16Position(2));
    try std.testing.expectEqualDeep(Utf16Position{ .line = 0, .character = 3 }, source.byteOffsetToUtf16Position(6));
    try std.testing.expectEqualDeep(Utf16Position{ .line = 1, .character = 0 }, source.byteOffsetToUtf16Position(7));
    try std.testing.expectEqual(@as(?u32, 6), source.utf16PositionToByteOffset(.{ .line = 0, .character = 3 }));
    try std.testing.expectEqual(@as(?u32, 7), source.utf16PositionToByteOffset(.{ .line = 1, .character = 0 }));
    try std.testing.expect(source.utf16PositionToByteOffset(.{ .line = 0, .character = 2 }) == null);
}
