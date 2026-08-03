const std = @import("std");
const panos_core = @import("panos_core");

const core_lsp = panos_core.lsp;
const max_message_size = 16 * 1024 * 1024;

pub const ProtocolError = error{
    MissingContentLength,
    InvalidContentLength,
    MessageTooLarge,
    UnexpectedEndOfStream,
};

pub const ResponseBuffer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) ResponseBuffer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ResponseBuffer) void {
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clearRetainingCapacity(self: *ResponseBuffer) void {
        self.bytes.clearRetainingCapacity();
    }

    pub fn appendSlice(self: *ResponseBuffer, data: []const u8) !void {
        try self.bytes.appendSlice(self.allocator, data);
    }

    pub fn append(self: *ResponseBuffer, item: u8) !void {
        try self.bytes.append(self.allocator, item);
    }

    pub fn items(self: *const ResponseBuffer) []const u8 {
        return self.bytes.items;
    }
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    documents: core_lsp.DocumentStore,

    pub fn init(allocator: std.mem.Allocator) Server {
        return .{
            .allocator = allocator,
            .documents = core_lsp.DocumentStore.init(allocator),
        };
    }

    pub fn deinit(self: *Server) void {
        self.documents.deinit();
        self.* = undefined;
    }

    pub fn handle(self: *Server, message: []const u8, output: *ResponseBuffer) !bool {
        output.clearRetainingCapacity();
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, message, .{}) catch {
            return true;
        };
        defer parsed.deinit();
        if (parsed.value != .object) return true;
        const request = parsed.value.object;
        const method = stringValue(request.get("method") orelse return true) orelse return true;
        const id = request.get("id");
        const params = request.get("params");

        if (std.mem.eql(u8, method, "initialize")) {
            if (id) |request_id| try writeResponse(output, request_id, "{\"capabilities\":{\"textDocumentSync\":1,\"hoverProvider\":true,\"completionProvider\":{\"triggerCharacters\":[\".\"]},\"foldingRangeProvider\":true,\"documentSymbolProvider\":true}}");
            return true;
        }
        if (std.mem.eql(u8, method, "shutdown")) {
            if (id) |request_id| try writeResponse(output, request_id, "null");
            return true;
        }
        if (std.mem.eql(u8, method, "exit")) return false;
        if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            try self.didOpen(params, output);
            return true;
        }
        if (std.mem.eql(u8, method, "textDocument/didChange")) {
            try self.didChange(params, output);
            return true;
        }
        if (std.mem.eql(u8, method, "textDocument/didClose")) {
            try self.didClose(params, output);
            return true;
        }
        if (std.mem.eql(u8, method, "textDocument/hover")) {
            if (id) |request_id| try self.hover(params, request_id, output);
            return true;
        }
        if (std.mem.eql(u8, method, "textDocument/completion")) {
            if (id) |request_id| try self.completion(params, request_id, output);
            return true;
        }
        if (std.mem.eql(u8, method, "textDocument/foldingRange")) {
            if (id) |request_id| try self.foldingRange(params, request_id, output);
            return true;
        }
        if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
            if (id) |request_id| try self.documentSymbol(params, request_id, output);
            return true;
        }
        if (id) |request_id| try writeError(output, request_id, -32601, "Метод ещё не поддержан Zig-версией");
        return true;
    }

    fn didOpen(self: *Server, params: ?std.json.Value, output: *ResponseBuffer) !void {
        const params_object = objectValue(params orelse return) orelse return;
        const document = objectValue(params_object.get("textDocument") orelse return) orelse return;
        const uri = stringValue(document.get("uri") orelse return) orelse return;
        const text = stringValue(document.get("text") orelse return) orelse return;
        try self.documents.replace(uri, text);
        try self.writePublishDiagnostics(output, uri);
    }

    fn didChange(self: *Server, params: ?std.json.Value, output: *ResponseBuffer) !void {
        const params_object = objectValue(params orelse return) orelse return;
        const document = objectValue(params_object.get("textDocument") orelse return) orelse return;
        const uri = stringValue(document.get("uri") orelse return) orelse return;
        const changes = switch (params_object.get("contentChanges") orelse return) {
            .array => |items| items.items,
            else => return,
        };
        if (changes.len == 0) return;
        const change = objectValue(changes[0]) orelse return;
        const text = stringValue(change.get("text") orelse return) orelse return;
        try self.documents.replace(uri, text);
        try self.writePublishDiagnostics(output, uri);
    }

    fn didClose(self: *Server, params: ?std.json.Value, output: *ResponseBuffer) !void {
        const params_object = objectValue(params orelse return) orelse return;
        const document = objectValue(params_object.get("textDocument") orelse return) orelse return;
        const uri = stringValue(document.get("uri") orelse return) orelse return;
        _ = self.documents.remove(uri);
        try writePublish(output, uri, null);
    }

    fn hover(self: *Server, params: ?std.json.Value, request_id: std.json.Value, output: *ResponseBuffer) !void {
        const context = self.documentPosition(params) orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const file = panos_core.source.SourceFile.init(0, context.uri, context.text);
        const byte_offset = file.utf16PositionToByteOffset(context.position) orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        var analysis = panos_core.runner.analyzeSource(self.allocator, context.uri, context.text) catch {
            try writeResponse(output, request_id, "null");
            return;
        };
        defer analysis.deinit();
        if (analysis.hasErrors()) {
            try writeResponse(output, request_id, "null");
            return;
        }
        const tree = analysis.tree() orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const expression = tree.findExpressionAt(0, byte_offset) orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const type_name = analysis.expressionTypeName(expression) catch {
            try writeResponse(output, request_id, "null");
            return;
        } orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const span = panos_core.ast.exprSpan(tree.expr(expression).*);
        try writeHoverResponse(output, request_id, type_name, .{
            .start = file.byteOffsetToUtf16Position(span.start),
            .end = file.byteOffsetToUtf16Position(span.end),
        });
    }

    fn completion(self: *Server, params: ?std.json.Value, request_id: std.json.Value, output: *ResponseBuffer) !void {
        const context = self.documentPosition(params) orelse {
            try writeCompletionResponse(output, request_id, null, null);
            return;
        };
        const file = panos_core.source.SourceFile.init(0, context.uri, context.text);
        const byte_offset = file.utf16PositionToByteOffset(context.position) orelse {
            try writeCompletionResponse(output, request_id, null, null);
            return;
        };
        if (byte_offset < 2 or context.text[byte_offset - 1] != '.') {
            try writeCompletionResponse(output, request_id, null, null);
            return;
        }
        const placeholder = "__panos_completion__";
        const patched_text = self.allocator.alloc(u8, context.text.len + placeholder.len) catch {
            try writeCompletionResponse(output, request_id, null, null);
            return;
        };
        defer self.allocator.free(patched_text);
        @memcpy(patched_text[0..byte_offset], context.text[0..byte_offset]);
        @memcpy(patched_text[byte_offset .. byte_offset + placeholder.len], placeholder);
        @memcpy(patched_text[byte_offset + placeholder.len ..], context.text[byte_offset..]);

        var analysis = panos_core.runner.analyzeSource(self.allocator, context.uri, patched_text) catch {
            try writeCompletionResponse(output, request_id, null, null);
            return;
        };
        defer analysis.deinit();
        const tree = analysis.tree() orelse {
            try writeCompletionResponse(output, request_id, null, null);
            return;
        };
        const expression = tree.findExpressionAt(0, byte_offset - 2) orelse {
            try writeCompletionResponse(output, request_id, null, null);
            return;
        };
        const checked = analysis.checkedResult() orelse {
            try writeCompletionResponse(output, request_id, null, null);
            return;
        };
        const type_id = checked.expression_types.get(expression) orelse {
            try writeCompletionResponse(output, request_id, null, null);
            return;
        };
        try writeCompletionResponse(output, request_id, checked, type_id);
    }

    fn foldingRange(self: *Server, params: ?std.json.Value, request_id: std.json.Value, output: *ResponseBuffer) !void {
        const uri = documentUri(params) orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const text = self.documents.sourceText(uri) orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        var analysis = panos_core.runner.analyzeSource(self.allocator, uri, text) catch {
            try writeResponse(output, request_id, "null");
            return;
        };
        defer analysis.deinit();
        const tree = analysis.tree() orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        var ranges = panos_core.lsp.foldingRanges(self.allocator, tree) catch {
            try writeResponse(output, request_id, "null");
            return;
        };
        defer ranges.deinit();
        const file = panos_core.source.SourceFile.init(0, uri, text);
        try writeFoldingRangesResponse(output, request_id, file, &ranges);
    }

    fn documentSymbol(self: *Server, params: ?std.json.Value, request_id: std.json.Value, output: *ResponseBuffer) !void {
        const uri = documentUri(params) orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const text = self.documents.sourceText(uri) orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        var analysis = panos_core.runner.analyzeSource(self.allocator, uri, text) catch {
            try writeResponse(output, request_id, "null");
            return;
        };
        defer analysis.deinit();
        const tree = analysis.tree() orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        var symbols = panos_core.lsp.documentSymbols(self.allocator, tree) catch {
            try writeResponse(output, request_id, "null");
            return;
        };
        defer symbols.deinit();
        const file = panos_core.source.SourceFile.init(0, uri, text);
        try writeDocumentSymbolsResponse(output, request_id, file, symbols.items);
    }

    fn documentPosition(self: *const Server, params: ?std.json.Value) ?DocumentPosition {
        const params_object = objectValue(params orelse return null) orelse return null;
        const document = objectValue(params_object.get("textDocument") orelse return null) orelse return null;
        const uri = stringValue(document.get("uri") orelse return null) orelse return null;
        const position_object = objectValue(params_object.get("position") orelse return null) orelse return null;
        const line = unsignedValue(position_object.get("line") orelse return null) orelse return null;
        const character = unsignedValue(position_object.get("character") orelse return null) orelse return null;
        const text = self.documents.sourceText(uri) orelse return null;
        return .{
            .uri = uri,
            .text = text,
            .position = .{ .line = line, .character = character },
        };
    }

    fn writePublishDiagnostics(self: *const Server, output: *ResponseBuffer, uri: []const u8) !void {
        var diagnostics = (try self.documents.diagnose(uri)) orelse return;
        defer diagnostics.deinit();
        try writePublish(output, uri, &diagnostics);
    }
};

fn documentUri(params: ?std.json.Value) ?[]const u8 {
    const params_object = objectValue(params orelse return null) orelse return null;
    const document = objectValue(params_object.get("textDocument") orelse return null) orelse return null;
    return stringValue(document.get("uri") orelse return null);
}

fn stringValue(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn objectValue(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

const DocumentPosition = struct {
    uri: []const u8,
    text: []const u8,
    position: panos_core.source.Utf16Position,
};

fn unsignedValue(value: std.json.Value) ?u32 {
    return switch (value) {
        .integer => |integer| if (integer >= 0) std.math.cast(u32, integer) else null,
        else => null,
    };
}

fn writeResponse(output: *ResponseBuffer, id: std.json.Value, result: []const u8) !void {
    try output.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":");
    try appendJsonValue(output, id);
    try output.appendSlice(",\"result\":");
    try output.appendSlice(result);
    try output.append('}');
}

fn writeError(output: *ResponseBuffer, id: std.json.Value, code: i32, message: []const u8) !void {
    try output.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":");
    try appendJsonValue(output, id);
    try output.appendSlice(",\"error\":{\"code\":");
    try appendNumber(output, code);
    try output.appendSlice(",\"message\":");
    try appendJsonString(output, message);
    try output.appendSlice("}}");
}

fn writeHoverResponse(output: *ResponseBuffer, id: std.json.Value, type_name: []const u8, range: core_lsp.Range) !void {
    try output.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":");
    try appendJsonValue(output, id);
    try output.appendSlice(",\"result\":{\"contents\":{\"kind\":\"plaintext\",\"value\":");
    try appendJsonString(output, type_name);
    try output.appendSlice("},\"range\":");
    try appendRange(output, range);
    try output.appendSlice("}}");
}

fn writeCompletionResponse(output: *ResponseBuffer, id: std.json.Value, checked: ?*const panos_core.type_checker.CheckResult, type_id: ?panos_core.types.TypeId) !void {
    try output.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":");
    try appendJsonValue(output, id);
    try output.appendSlice(",\"result\":{\"isIncomplete\":false,\"items\":[");
    if (checked) |result| {
        if (type_id) |value| try appendCompletionItems(output, result, value);
    }
    try output.appendSlice("]}}");
}

fn writeFoldingRangesResponse(output: *ResponseBuffer, id: std.json.Value, file: panos_core.source.SourceFile, ranges: *const core_lsp.FoldingRanges) !void {
    try output.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":");
    try appendJsonValue(output, id);
    try output.appendSlice(",\"result\":[");
    var first = true;
    for (ranges.items.items) |item| {
        const range = rangeForSpan(file, item.span);
        if (range.end.line <= range.start.line) continue;
        if (!first) try output.append(',');
        first = false;
        try output.appendSlice("{\"startLine\":");
        try appendNumber(output, range.start.line);
        try output.appendSlice(",\"endLine\":");
        try appendNumber(output, range.end.line);
        try output.append('}');
    }
    try output.appendSlice("]}");
}

fn writeDocumentSymbolsResponse(output: *ResponseBuffer, id: std.json.Value, file: panos_core.source.SourceFile, symbols: []const core_lsp.DocumentSymbol) !void {
    try output.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":");
    try appendJsonValue(output, id);
    try output.appendSlice(",\"result\":[");
    for (symbols, 0..) |symbol, index| {
        if (index != 0) try output.append(',');
        try appendDocumentSymbol(output, file, symbol);
    }
    try output.appendSlice("]}");
}

fn appendDocumentSymbol(output: *ResponseBuffer, file: panos_core.source.SourceFile, symbol: core_lsp.DocumentSymbol) !void {
    try output.appendSlice("{\"name\":");
    try appendJsonString(output, symbol.name);
    try output.appendSlice(",\"kind\":");
    try appendNumber(output, documentSymbolKind(symbol.kind));
    try output.appendSlice(",\"range\":");
    try appendRange(output, rangeForSpan(file, symbol.range));
    try output.appendSlice(",\"selectionRange\":");
    try appendRange(output, rangeForSpan(file, symbol.selection_range));
    if (symbol.children.len != 0) {
        try output.appendSlice(",\"children\":[");
        for (symbol.children, 0..) |child, index| {
            if (index != 0) try output.append(',');
            try appendDocumentSymbol(output, file, child);
        }
        try output.append(']');
    }
    try output.append('}');
}

fn rangeForSpan(file: panos_core.source.SourceFile, span: panos_core.source.Span) core_lsp.Range {
    return .{
        .start = file.byteOffsetToUtf16Position(span.start),
        .end = file.byteOffsetToUtf16Position(span.end),
    };
}

fn documentSymbolKind(kind: core_lsp.DocumentSymbolKind) u8 {
    return switch (kind) {
        .structure => 23,
        .enumeration => 10,
        .interface => 11,
        .function => 12,
        .method => 6,
        .field => 8,
        .enum_member => 22,
        .implementation => 5,
        .constant => 14,
        .type_alias => 26,
    };
}

fn writePublish(output: *ResponseBuffer, uri: []const u8, diagnostics: ?*const core_lsp.DocumentDiagnostics) !void {
    try output.appendSlice("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":");
    try appendJsonString(output, uri);
    try output.appendSlice(",\"diagnostics\":[");
    if (diagnostics) |value| {
        for (value.items.items, 0..) |item, index| {
            if (index != 0) try output.append(',');
            try output.appendSlice("{\"range\":");
            try appendRange(output, item.range);
            try output.appendSlice(",\"severity\":");
            try appendNumber(output, switch (item.severity) {
                .err => @as(u8, 1),
                .warning => @as(u8, 2),
            });
            try output.appendSlice(",\"message\":");
            try appendJsonString(output, item.message);
            try output.append('}');
        }
    }
    try output.appendSlice("]}}");
}

fn appendRange(output: *ResponseBuffer, range: core_lsp.Range) !void {
    try output.appendSlice("{\"start\":{\"line\":");
    try appendNumber(output, range.start.line);
    try output.appendSlice(",\"character\":");
    try appendNumber(output, range.start.character);
    try output.appendSlice("},\"end\":{\"line\":");
    try appendNumber(output, range.end.line);
    try output.appendSlice(",\"character\":");
    try appendNumber(output, range.end.character);
    try output.appendSlice("}}");
}

fn appendCompletionItems(output: *ResponseBuffer, checked: *const panos_core.type_checker.CheckResult, type_id: panos_core.types.TypeId) !void {
    const entry = checked.types.get(type_id) orelse return;
    var first = true;
    switch (entry.*) {
        .array => {
            try appendCompletionItem(output, &first, "длина", 2);
            try appendCompletionItem(output, &first, "добавить", 2);
            try appendCompletionItem(output, &first, "получить", 2);
            try appendCompletionItem(output, &first, "есть", 2);
            try appendCompletionItem(output, &first, "содержит", 2);
        },
        .map => {
            try appendCompletionItem(output, &first, "длина", 2);
            try appendCompletionItem(output, &first, "есть", 2);
            try appendCompletionItem(output, &first, "получить", 2);
            try appendCompletionItem(output, &first, "удалить", 2);
        },
        .nominal => |nominal| {
            if (checked.nominal_fields.get(nominal.symbol)) |fields| {
                for (fields) |field| try appendCompletionItem(output, &first, field.name, 5);
            }
            for (checked.methods.items) |method| {
                if (method.owner == nominal.symbol) try appendCompletionItem(output, &first, method.name, 2);
            }
            if (checked.interface_definitions.get(nominal.symbol)) |interface| {
                for (interface.methods) |method| try appendCompletionItem(output, &first, method.name, 2);
            }
            if (checked.enum_definitions.get(nominal.symbol)) |enumeration| {
                for (enumeration.variants) |variant| try appendCompletionItem(output, &first, variant.name, 20);
            }
        },
        else => {},
    }
}

fn appendCompletionItem(output: *ResponseBuffer, first: *bool, label: []const u8, kind: u8) !void {
    if (!first.*) try output.append(',');
    first.* = false;
    try output.appendSlice("{\"label\":");
    try appendJsonString(output, label);
    try output.appendSlice(",\"kind\":");
    try appendNumber(output, kind);
    try output.append('}');
}

fn appendJsonValue(output: *ResponseBuffer, value: std.json.Value) !void {
    switch (value) {
        .null => try output.appendSlice("null"),
        .bool => |boolean| try output.appendSlice(if (boolean) "true" else "false"),
        .integer => |integer| try appendNumber(output, integer),
        .float => |float| {
            var buffer: [64]u8 = undefined;
            try output.appendSlice(try std.fmt.bufPrint(&buffer, "{d}", .{float}));
        },
        .number_string => |number| try output.appendSlice(number),
        .string => |text| try appendJsonString(output, text),
        else => try output.appendSlice("null"),
    }
}

fn appendNumber(output: *ResponseBuffer, number: anytype) !void {
    var buffer: [32]u8 = undefined;
    try output.appendSlice(try std.fmt.bufPrint(&buffer, "{d}", .{number}));
}

fn appendJsonString(output: *ResponseBuffer, text: []const u8) !void {
    try output.append('"');
    for (text) |byte| switch (byte) {
        '"' => try output.appendSlice("\\\""),
        '\\' => try output.appendSlice("\\\\"),
        '\n' => try output.appendSlice("\\n"),
        '\r' => try output.appendSlice("\\r"),
        '\t' => try output.appendSlice("\\t"),
        0...8, 11...12, 14...0x1f => try appendControlByte(output, byte),
        else => try output.append(byte),
    };
    try output.append('"');
}

fn appendControlByte(output: *ResponseBuffer, byte: u8) !void {
    const hex = "0123456789abcdef";
    try output.appendSlice("\\u00");
    try output.append(hex[byte >> 4]);
    try output.append(hex[byte & 0x0f]);
}

pub fn readMessage(allocator: std.mem.Allocator, reader: *std.Io.Reader) (ProtocolError || std.Io.Reader.DelimiterError || std.Io.Reader.ReadAllocError)!?[]u8 {
    var content_length: ?usize = null;
    var saw_header = false;
    while (true) {
        const raw_line = (try reader.takeDelimiter('\n')) orelse {
            return if (saw_header) error.UnexpectedEndOfStream else null;
        };
        saw_header = true;
        const line = std.mem.trim(u8, raw_line, "\r\n");
        if (line.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const value = std.mem.trim(u8, line["content-length:".len..], " \t");
            content_length = std.fmt.parseInt(usize, value, 10) catch return error.InvalidContentLength;
        }
    }
    const length = content_length orelse return error.MissingContentLength;
    if (length > max_message_size) return error.MessageTooLarge;
    const message = try reader.readAlloc(allocator, length);
    return message;
}

fn writeMessage(writer: *std.Io.Writer, message: []const u8) !void {
    try writer.print("Content-Length: {d}\r\n\r\n{s}", .{ message.len, message });
    try writer.flush();
}

pub fn main(init: std.process.Init) !void {
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_file_reader: std.Io.File.Reader = .initStreaming(.stdin(), init.io, &stdin_buffer);
    const stdin = &stdin_file_reader.interface;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var server = Server.init(init.gpa);
    defer server.deinit();
    var output = ResponseBuffer.init(init.gpa);
    defer output.deinit();

    while (try readMessage(init.gpa, stdin)) |message| {
        defer init.gpa.free(message);
        const keep_running = try server.handle(message, &output);
        if (output.items().len != 0) try writeMessage(stdout, output.items());
        if (!keep_running) break;
    }
}

test "LSP server publishes diagnostics for opened and changed documents" {
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var output = ResponseBuffer.init(std.testing.allocator);
    defer output.deinit();

    try std.testing.expect(try server.handle("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}", &output));
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"textDocumentSync\":1,\"hoverProvider\":true,\"completionProvider\":{\"triggerCharacters\":[\".\"]},\"foldingRangeProvider\":true,\"documentSymbolProvider\":true}}}", output.items());

    try std.testing.expect(try server.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///пример.ps\",\"text\":\"экспорт функ старт() -> Число\\nнеизвестно\\nконец\"}}}", &output));
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"line\":1,\"character\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "Resolve Error: неопределённое имя 'неизвестно'") != null);

    try std.testing.expect(try server.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///пример.ps\"},\"contentChanges\":[{\"text\":\"экспорт функ старт() -> Число\\n42\\nконец\"}]}}", &output));
    try std.testing.expect(std.mem.endsWith(u8, output.items(), "\"diagnostics\":[]}}"));

    try std.testing.expect(try server.handle("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///пример.ps\"},\"position\":{\"line\":1,\"character\":1}}}", &output));
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"value\":\"Число\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"start\":{\"line\":1,\"character\":0}") != null);

    try std.testing.expect(try server.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///пример.ps\"},\"contentChanges\":[{\"text\":\"экспорт функ старт() -> Пусто\\nпер числа: Массив(Число) = массив()\\nчисла.\\nконец\"}]}}", &output));
    try std.testing.expect(try server.handle("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file:///пример.ps\"},\"position\":{\"line\":2,\"character\":6}}}", &output));
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"label\":\"добавить\",\"kind\":2") != null);

    try std.testing.expect(try server.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///пример.ps\"},\"contentChanges\":[{\"text\":\"тип Точка = структура\\nx: Число\\nконец\\nфунк старт() -> Число\\nесли истина тогда\\n1\\nиначе\\n2\\nконец\\nконец\"}]}}", &output));
    try std.testing.expect(try server.handle("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file:///пример.ps\"}}}", &output));
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"name\":\"Точка\",\"kind\":23") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"children\":[{\"name\":\"x\",\"kind\":8") != null);

    try std.testing.expect(try server.handle("{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"textDocument/foldingRange\",\"params\":{\"textDocument\":{\"uri\":\"file:///пример.ps\"}}}", &output));
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"startLine\":0,\"endLine\":2") != null);

    try std.testing.expect(try server.handle("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/unsupported\",\"params\":{}}", &output));
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"code\":-32601") != null);
}

test "LSP transport reads Content-Length frames" {
    var reader = std.Io.Reader.fixed("Content-Length: 17\r\nX-Test: panos\r\n\r\n{\"jsonrpc\":\"2.0\"}");
    const message = (try readMessage(std.testing.allocator, &reader)).?;
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\"}", message);
    try std.testing.expect((try readMessage(std.testing.allocator, &reader)) == null);
}
