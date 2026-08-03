const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const source = @import("source.zig");
const token = @import("token.zig");

pub const Tokenization = struct {
    allocator: std.mem.Allocator,
    tokens: std.ArrayList(token.Token) = .empty,
    diagnostics: diagnostic.DiagnosticList = .{},
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) Tokenization {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Tokenization) void {
        self.tokens.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }
};

const Decoded = union(enum) {
    eof,
    invalid,
    valid: struct {
        codepoint: u21,
        width: usize,
    },
};

const Skipped = struct {
    nl_before: bool,
    doc: []const u8,
};

const StringFragmentTerminator = enum {
    quote,
    interpolation,
    eof,
};

const StringFragment = struct {
    text: []const u8,
    terminator: StringFragmentTerminator,
};

const Lexer = struct {
    input: []const u8,
    file_id: source.FileId,
    pos: usize = 0,
    output: *Tokenization,
    interp_paren_depth: std.ArrayList(usize) = .empty,

    fn deinit(self: *Lexer) void {
        self.interp_paren_depth.deinit(self.output.allocator);
        self.* = undefined;
    }

    fn arenaAllocator(self: *Lexer) std.mem.Allocator {
        return self.output.arena.allocator();
    }

    fn current(self: *const Lexer) Decoded {
        return decodeAt(self.input, self.pos);
    }

    fn advance(self: *Lexer, width: usize) void {
        self.pos += width;
    }

    fn followsAscii(self: *const Lexer, expected: u8) bool {
        return self.pos + 1 < self.input.len and self.input[self.pos + 1] == expected;
    }

    fn makeSpan(self: *const Lexer, start: usize, end: usize) source.Span {
        return .{
            .file_id = self.file_id,
            .start = @intCast(start),
            .end = @intCast(end),
        };
    }

    fn currentSpan(self: *const Lexer) source.Span {
        const end = switch (self.current()) {
            .valid => |decoded| self.pos + decoded.width,
            .eof => self.pos,
            .invalid => self.pos + 1,
        };
        return self.makeSpan(self.pos, end);
    }

    fn makeToken(
        self: *const Lexer,
        kind: token.TokenKind,
        lexeme: []const u8,
        start: usize,
        skipped: Skipped,
    ) token.Token {
        return .{
            .kind = kind,
            .lexeme = lexeme,
            .span = self.makeSpan(start, self.pos),
            .nl_before = skipped.nl_before,
            .doc = skipped.doc,
        };
    }

    fn report(self: *Lexer, span: source.Span, message: []const u8) !void {
        _ = try self.output.diagnostics.appendUnique(self.output.allocator, .{
            .phase = .lexer,
            .severity = .err,
            .span = span,
            .message = message,
        });
    }

    fn reportInvalidUtf8(self: *Lexer) !void {
        try self.report(self.currentSpan(), "Лексическая ошибка: некорректный UTF-8");
    }

    fn reportUnexpected(self: *Lexer, codepoint: u21) !void {
        const message = try std.fmt.allocPrint(
            self.arenaAllocator(),
            "Лексическая ошибка: неожиданный символ '{u}'",
            .{codepoint},
        );
        try self.report(self.currentSpan(), message);
    }

    fn reportUnknownEscape(self: *Lexer, codepoint: u21) !void {
        const message = try std.fmt.allocPrint(
            self.arenaAllocator(),
            "Лексическая ошибка: неизвестная escape-последовательность '\\{u}'",
            .{codepoint},
        );
        try self.report(self.currentSpan(), message);
    }

    fn skipWhitespaceAndComments(self: *Lexer) !Skipped {
        var doc_lines: std.ArrayList([]const u8) = .empty;
        defer doc_lines.deinit(self.output.allocator);

        var saw_newline = false;
        var newline_run: usize = 0;

        while (true) {
            switch (self.current()) {
                .valid => |decoded| {
                    if (isWhitespace(decoded.codepoint)) {
                        if (decoded.codepoint == '\n') {
                            saw_newline = true;
                            newline_run += 1;
                            if (newline_run >= 2) doc_lines.clearRetainingCapacity();
                        }
                        self.advance(decoded.width);
                        continue;
                    }

                    if (decoded.codepoint != '/' or !self.followsAscii('/')) break;

                    self.advance(2);
                    const is_doc = switch (self.current()) {
                        .valid => |next| next.codepoint == '/',
                        .eof, .invalid => false,
                    };
                    if (is_doc) self.advance(1);

                    const start = self.pos;
                    while (self.pos < self.input.len and self.input[self.pos] != '\n') {
                        self.advance(1);
                    }
                    if (is_doc) {
                        try doc_lines.append(
                            self.output.allocator,
                            std.mem.trim(u8, self.input[start..self.pos], " \t\r"),
                        );
                    } else {
                        doc_lines.clearRetainingCapacity();
                    }
                    newline_run = 0;
                },
                .eof, .invalid => break,
            }
        }

        return .{
            .nl_before = saw_newline,
            .doc = try joinDocLines(self.arenaAllocator(), doc_lines.items),
        };
    }

    fn readIdentifier(self: *Lexer) void {
        while (true) {
            switch (self.current()) {
                .valid => |decoded| {
                    if (!isIdentifierContinue(decoded.codepoint)) return;
                    self.advance(decoded.width);
                },
                .eof, .invalid => return,
            }
        }
    }

    fn readNumber(self: *Lexer) void {
        while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) {
            self.advance(1);
        }

        if (self.pos + 1 < self.input.len and
            self.input[self.pos] == '.' and
            std.ascii.isDigit(self.input[self.pos + 1]))
        {
            self.advance(1);
            while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) {
                self.advance(1);
            }
        }
    }

    fn readStringFragment(self: *Lexer) !StringFragment {
        var text: std.ArrayList(u8) = .empty;
        const allocator = self.arenaAllocator();

        while (true) {
            switch (self.current()) {
                .eof => {
                    try self.report(self.currentSpan(), "Лексическая ошибка: незакрытая строка");
                    return .{
                        .text = try text.toOwnedSlice(allocator),
                        .terminator = .eof,
                    };
                },
                .invalid => {
                    try self.reportInvalidUtf8();
                    self.advance(1);
                },
                .valid => |decoded| switch (decoded.codepoint) {
                    '"' => {
                        self.advance(decoded.width);
                        return .{
                            .text = try text.toOwnedSlice(allocator),
                            .terminator = .quote,
                        };
                    },
                    '\\' => {
                        self.advance(decoded.width);
                        switch (self.current()) {
                            .eof => {
                                try self.report(self.currentSpan(), "Лексическая ошибка: незакрытая строка");
                                return .{
                                    .text = try text.toOwnedSlice(allocator),
                                    .terminator = .eof,
                                };
                            },
                            .invalid => {
                                try self.reportInvalidUtf8();
                                self.advance(1);
                            },
                            .valid => |escaped| switch (escaped.codepoint) {
                                'n' => {
                                    try text.append(allocator, '\n');
                                    self.advance(escaped.width);
                                },
                                't' => {
                                    try text.append(allocator, '\t');
                                    self.advance(escaped.width);
                                },
                                'r' => {
                                    try text.append(allocator, '\r');
                                    self.advance(escaped.width);
                                },
                                '"' => {
                                    try text.append(allocator, '"');
                                    self.advance(escaped.width);
                                },
                                '\\' => {
                                    try text.append(allocator, '\\');
                                    self.advance(escaped.width);
                                },
                                '(' => {
                                    self.advance(escaped.width);
                                    return .{
                                        .text = try text.toOwnedSlice(allocator),
                                        .terminator = .interpolation,
                                    };
                                },
                                else => {
                                    try self.reportUnknownEscape(escaped.codepoint);
                                    try appendCodepoint(&text, allocator, escaped.codepoint);
                                    self.advance(escaped.width);
                                },
                            },
                        }
                    },
                    else => {
                        try appendCodepoint(&text, allocator, decoded.codepoint);
                        self.advance(decoded.width);
                    },
                },
            }
        }
    }

    fn nextToken(self: *Lexer) !token.Token {
        while (true) {
            const skipped = try self.skipWhitespaceAndComments();
            const start = self.pos;

            switch (self.current()) {
                .eof => return self.makeToken(.eof, "EOF", start, skipped),
                .invalid => {
                    try self.reportInvalidUtf8();
                    self.advance(1);
                    continue;
                },
                .valid => |decoded| switch (decoded.codepoint) {
                    '<' => {
                        if (self.followsAscii('>')) {
                            self.advance(2);
                            return self.makeToken(.not_equal, self.input[start..self.pos], start, skipped);
                        }
                        if (self.followsAscii('=')) {
                            self.advance(2);
                            return self.makeToken(.less_equal, self.input[start..self.pos], start, skipped);
                        }
                        if (self.followsAscii('<')) {
                            self.advance(2);
                            return self.makeToken(.less_less, self.input[start..self.pos], start, skipped);
                        }
                        self.advance(1);
                        return self.makeToken(.less, self.input[start..self.pos], start, skipped);
                    },
                    '>' => {
                        if (self.followsAscii('=')) {
                            self.advance(2);
                            return self.makeToken(.greater_equal, self.input[start..self.pos], start, skipped);
                        }
                        if (self.followsAscii('>')) {
                            self.advance(2);
                            return self.makeToken(.greater_greater, self.input[start..self.pos], start, skipped);
                        }
                        self.advance(1);
                        return self.makeToken(.greater, self.input[start..self.pos], start, skipped);
                    },
                    '=' => {
                        if (self.followsAscii('=')) {
                            self.advance(2);
                            return self.makeToken(.equal, self.input[start..self.pos], start, skipped);
                        }
                        self.advance(1);
                        return self.makeToken(.assign, self.input[start..self.pos], start, skipped);
                    },
                    '-' => {
                        if (self.followsAscii('>')) {
                            self.advance(2);
                            return self.makeToken(.arrow, self.input[start..self.pos], start, skipped);
                        }
                        self.advance(1);
                        return self.makeToken(.minus, self.input[start..self.pos], start, skipped);
                    },
                    '+' => return self.singleAsciiToken(.plus, start, skipped),
                    '*' => return self.singleAsciiToken(.star, start, skipped),
                    '/' => return self.singleAsciiToken(.slash, start, skipped),
                    '%' => return self.singleAsciiToken(.percent, start, skipped),
                    '&' => return self.singleAsciiToken(.ampersand, start, skipped),
                    '|' => return self.singleAsciiToken(.pipe, start, skipped),
                    '^' => return self.singleAsciiToken(.caret, start, skipped),
                    '~' => return self.singleAsciiToken(.tilde, start, skipped),
                    '(' => {
                        if (self.interp_paren_depth.items.len > 0) {
                            const depth = self.interp_paren_depth.items.len - 1;
                            self.interp_paren_depth.items[depth] += 1;
                        }
                        return self.singleAsciiToken(.l_paren, start, skipped);
                    },
                    ')' => {
                        if (self.interp_paren_depth.items.len > 0 and
                            self.interp_paren_depth.items[self.interp_paren_depth.items.len - 1] == 0)
                        {
                            self.interp_paren_depth.items.len -= 1;
                            self.advance(1);
                            const fragment = try self.readStringFragment();
                            if (fragment.terminator == .interpolation) {
                                try self.interp_paren_depth.append(self.output.allocator, 0);
                                return self.makeToken(.interp_string_mid, fragment.text, start, skipped);
                            }
                            return self.makeToken(.interp_string_end, fragment.text, start, skipped);
                        }
                        if (self.interp_paren_depth.items.len > 0) {
                            const depth = self.interp_paren_depth.items.len - 1;
                            self.interp_paren_depth.items[depth] -= 1;
                        }
                        return self.singleAsciiToken(.r_paren, start, skipped);
                    },
                    '[' => return self.singleAsciiToken(.l_bracket, start, skipped),
                    ']' => return self.singleAsciiToken(.r_bracket, start, skipped),
                    ',' => return self.singleAsciiToken(.comma, start, skipped),
                    '?' => return self.singleAsciiToken(.question, start, skipped),
                    '.' => return self.singleAsciiToken(.dot, start, skipped),
                    ':' => return self.singleAsciiToken(.colon, start, skipped),
                    ';' => return self.singleAsciiToken(.semicolon, start, skipped),
                    '"' => {
                        self.advance(1);
                        const fragment = try self.readStringFragment();
                        if (fragment.terminator == .interpolation) {
                            try self.interp_paren_depth.append(self.output.allocator, 0);
                            return self.makeToken(.interp_string_start, fragment.text, start, skipped);
                        }
                        return self.makeToken(.string, fragment.text, start, skipped);
                    },
                    else => {
                        if (isIdentifierStart(decoded.codepoint)) {
                            self.readIdentifier();
                            const lexeme = self.input[start..self.pos];
                            return self.makeToken(token.lookupKeyword(lexeme), lexeme, start, skipped);
                        }
                        if (isAsciiDigit(decoded.codepoint)) {
                            self.readNumber();
                            return self.makeToken(.number, self.input[start..self.pos], start, skipped);
                        }
                        try self.reportUnexpected(decoded.codepoint);
                        self.advance(decoded.width);
                    },
                },
            }
        }
    }

    fn singleAsciiToken(
        self: *Lexer,
        kind: token.TokenKind,
        start: usize,
        skipped: Skipped,
    ) token.Token {
        self.advance(1);
        return self.makeToken(kind, self.input[start..self.pos], start, skipped);
    }
};

pub fn tokenize(
    allocator: std.mem.Allocator,
    input: []const u8,
    file_id: source.FileId,
) !Tokenization {
    var output = Tokenization.init(allocator);
    errdefer output.deinit();

    var lexer = Lexer{
        .input = input,
        .file_id = file_id,
        .output = &output,
    };
    defer lexer.deinit();

    while (true) {
        const next = try lexer.nextToken();
        try output.tokens.append(allocator, next);
        if (next.kind == .eof) break;
    }

    return output;
}

fn decodeAt(input: []const u8, pos: usize) Decoded {
    if (pos >= input.len) return .eof;

    const width: usize = std.unicode.utf8ByteSequenceLength(input[pos]) catch return .invalid;
    if (pos + width > input.len) return .invalid;
    const codepoint = std.unicode.utf8Decode(input[pos .. pos + width]) catch return .invalid;
    return .{ .valid = .{ .codepoint = codepoint, .width = width } };
}

fn isWhitespace(codepoint: u21) bool {
    return switch (codepoint) {
        ' ', '\t'...'\r', 0x0085, 0x00A0, 0x1680, 0x2000...0x200A, 0x2028...0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

fn isIdentifierStart(codepoint: u21) bool {
    if (codepoint <= 0x7F) return std.ascii.isAlphabetic(@intCast(codepoint)) or codepoint == '_';
    return switch (codepoint) {
        0x0400...0x052F, 0x2DE0...0x2DFF, 0xA640...0xA69F => true,
        else => false,
    };
}

fn isIdentifierContinue(codepoint: u21) bool {
    return isIdentifierStart(codepoint) or isAsciiDigit(codepoint);
}

fn isAsciiDigit(codepoint: u21) bool {
    return codepoint <= 0x7F and std.ascii.isDigit(@intCast(codepoint));
}

fn appendCodepoint(
    bytes: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    codepoint: u21,
) !void {
    var encoded: [4]u8 = undefined;
    const width = try std.unicode.utf8Encode(codepoint, &encoded);
    try bytes.appendSlice(allocator, encoded[0..width]);
}

fn joinDocLines(allocator: std.mem.Allocator, lines: []const []const u8) ![]const u8 {
    if (lines.len == 0) return "";

    var result: std.ArrayList(u8) = .empty;
    for (lines, 0..) |line, index| {
        if (index != 0) try result.append(allocator, '\n');
        try result.appendSlice(allocator, line);
    }
    return result.toOwnedSlice(allocator);
}

test "lexer retains byte spans, newlines and tuple-index dots" {
    var result = try tokenize(std.testing.allocator, "пер имя=12.5\nимя.1.длина()", 9);
    defer result.deinit();

    const expected = [_]token.TokenKind{
        .let,
        .ident,
        .assign,
        .number,
        .ident,
        .dot,
        .number,
        .dot,
        .ident,
        .l_paren,
        .r_paren,
        .eof,
    };
    try std.testing.expectEqual(expected.len, result.tokens.items.len);
    for (expected, result.tokens.items) |kind, actual| {
        try std.testing.expectEqual(kind, actual.kind);
        try std.testing.expectEqual(@as(source.FileId, 9), actual.span.file_id);
    }
    try std.testing.expectEqualStrings("12.5", result.tokens.items[3].lexeme);
    try std.testing.expect(result.tokens.items[4].nl_before);
    try std.testing.expectEqualDeep(source.Span{ .file_id = 9, .start = 7, .end = 13 }, result.tokens.items[1].span);
    try std.testing.expectEqualDeep(source.Span{ .file_id = 9, .start = 19, .end = 25 }, result.tokens.items[4].span);
}

test "lexer recognizes every symbolic operator and delimiter" {
    var result = try tokenize(std.testing.allocator, "< <> <= << > >= >> = == + - -> * / % & | ^ ~ [ ] , ? : ;", 0);
    defer result.deinit();

    const expected = [_]token.TokenKind{
        .less,
        .not_equal,
        .less_equal,
        .less_less,
        .greater,
        .greater_equal,
        .greater_greater,
        .assign,
        .equal,
        .plus,
        .minus,
        .arrow,
        .star,
        .slash,
        .percent,
        .ampersand,
        .pipe,
        .caret,
        .tilde,
        .l_bracket,
        .r_bracket,
        .comma,
        .question,
        .colon,
        .semicolon,
        .eof,
    };
    try std.testing.expectEqual(expected.len, result.tokens.items.len);
    for (expected, result.tokens.items) |kind, actual| {
        try std.testing.expectEqual(kind, actual.kind);
    }
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);
}

test "lexer decodes string escapes and recovers unknown escapes" {
    var result = try tokenize(std.testing.allocator, "\"строка\\n\\\\\\q\"", 0);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.tokens.items.len);
    try std.testing.expectEqual(token.TokenKind.string, result.tokens.items[0].kind);
    try std.testing.expectEqualStrings("строка\n\\q", result.tokens.items[0].lexeme);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.items.items.len);
    try std.testing.expectEqualStrings(
        "Лексическая ошибка: неизвестная escape-последовательность '\\q'",
        result.diagnostics.items.items[0].message,
    );
}

test "lexer emits fragments for nested string interpolation" {
    var result = try tokenize(std.testing.allocator, "\"a \\(\"b \\(x)\") c\"", 0);
    defer result.deinit();

    const expected = [_]token.TokenKind{
        .interp_string_start,
        .interp_string_start,
        .ident,
        .interp_string_end,
        .interp_string_end,
        .eof,
    };
    try std.testing.expectEqual(expected.len, result.tokens.items.len);
    for (expected, result.tokens.items) |kind, actual| {
        try std.testing.expectEqual(kind, actual.kind);
    }
    try std.testing.expectEqualStrings("a ", result.tokens.items[0].lexeme);
    try std.testing.expectEqualStrings("b ", result.tokens.items[1].lexeme);
    try std.testing.expectEqualStrings("x", result.tokens.items[2].lexeme);
    try std.testing.expectEqualStrings("", result.tokens.items[3].lexeme);
    try std.testing.expectEqualStrings(" c", result.tokens.items[4].lexeme);
}

test "lexer attaches only contiguous doc comments" {
    var attached = try tokenize(std.testing.allocator, "/// Первый\n/// Второй\nфунк", 0);
    defer attached.deinit();
    try std.testing.expectEqualStrings("Первый\nВторой", attached.tokens.items[0].doc);

    var detached = try tokenize(std.testing.allocator, "/// Отделён\n\nфунк", 0);
    defer detached.deinit();
    try std.testing.expectEqualStrings("", detached.tokens.items[0].doc);
}

test "lexer accepts embedded conformance fixtures" {
    var basic = try tokenize(
        std.testing.allocator,
        "/// Складывает два числа.\nфунк сложить(a: Число, b: Число) -> Число\n    a + b\nконец\n",
        0,
    );
    defer basic.deinit();
    try std.testing.expectEqual(token.TokenKind.function, basic.tokens.items[0].kind);
    try std.testing.expectEqualStrings("Складывает два числа.", basic.tokens.items[0].doc);
    try std.testing.expectEqual(@as(usize, 0), basic.diagnostics.items.items.len);

    var interpolation = try tokenize(
        std.testing.allocator,
        "пер приветствие = \"Привет, \\(имя)!\"\n",
        0,
    );
    defer interpolation.deinit();
    const expected = [_]token.TokenKind{
        .let,
        .ident,
        .assign,
        .interp_string_start,
        .ident,
        .interp_string_end,
        .eof,
    };
    try std.testing.expectEqual(expected.len, interpolation.tokens.items.len);
    for (expected, interpolation.tokens.items) |kind, actual| {
        try std.testing.expectEqual(kind, actual.kind);
    }
}

test "lexer recovers from unexpected characters and unterminated strings" {
    var unexpected = try tokenize(std.testing.allocator, "$ пер имя = 1", 0);
    defer unexpected.deinit();
    try std.testing.expectEqual(token.TokenKind.let, unexpected.tokens.items[0].kind);
    try std.testing.expectEqualStrings(
        "Лексическая ошибка: неожиданный символ '$'",
        unexpected.diagnostics.items.items[0].message,
    );

    var unterminated = try tokenize(std.testing.allocator, "\"не закрыта", 0);
    defer unterminated.deinit();
    try std.testing.expectEqual(token.TokenKind.string, unterminated.tokens.items[0].kind);
    try std.testing.expectEqualStrings("не закрыта", unterminated.tokens.items[0].lexeme);
    try std.testing.expectEqualStrings(
        "Лексическая ошибка: незакрытая строка",
        unterminated.diagnostics.items.items[0].message,
    );
}

test "lexer reports invalid UTF-8 and continues" {
    var result = try tokenize(std.testing.allocator, "\xffпер", 3);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.tokens.items.len);
    try std.testing.expectEqual(token.TokenKind.let, result.tokens.items[0].kind);
    try std.testing.expectEqualDeep(source.Span{ .file_id = 3, .start = 1, .end = 7 }, result.tokens.items[0].span);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Лексическая ошибка: некорректный UTF-8", result.diagnostics.items.items[0].message);
    try std.testing.expectEqualDeep(source.Span{ .file_id = 3, .start = 0, .end = 1 }, result.diagnostics.items.items[0].span);
}
