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
            if (id) |request_id| try writeResponse(output, request_id, "{\"capabilities\":{\"textDocumentSync\":1,\"hoverProvider\":true,\"definitionProvider\":true,\"referencesProvider\":true,\"documentHighlightProvider\":true,\"completionProvider\":{\"triggerCharacters\":[\".\"]},\"signatureHelpProvider\":{\"triggerCharacters\":[\"(\",\",\"]},\"foldingRangeProvider\":true,\"documentSymbolProvider\":true,\"renameProvider\":{\"prepareProvider\":true},\"selectionRangeProvider\":true,\"codeLensProvider\":{},\"workspaceSymbolProvider\":true,\"semanticTokensProvider\":{\"legend\":{\"tokenTypes\":[\"namespace\",\"type\",\"enumMember\",\"function\",\"variable\",\"parameter\"],\"tokenModifiers\":[]},\"full\":true}}}");
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
        if (std.mem.eql(u8, method, "textDocument/definition")) {
            if (id) |request_id| try self.definition(params, request_id, output);
            return true;
        }
        if (std.mem.eql(u8, method, "textDocument/references")) {
            if (id) |request_id| try self.references(params, request_id, output);
            return true;
        }
        if (std.mem.eql(u8, method, "textDocument/documentHighlight")) {
            if (id) |request_id| try self.documentHighlight(params, request_id, output);
            return true;
        }
        if (std.mem.eql(u8, method, "textDocument/signatureHelp")) {
            if (id) |request_id| try self.signatureHelp(params, request_id, output);
            return true;
        }
        if (std.mem.eql(u8, method, "textDocument/prepareRename")) {
            if (id) |request_id| try self.prepareRename(params, request_id, output);
            return true;
        }
        if (std.mem.eql(u8, method, "textDocument/rename")) {
            if (id) |request_id| try self.rename(params, request_id, output);
            return true;
        }
        if (std.mem.eql(u8, method, "textDocument/selectionRange")) {
            if (id) |request_id| try self.selectionRange(params, request_id, output);
            return true;
        }
        if (std.mem.eql(u8, method, "textDocument/codeLens")) {
            if (id) |request_id| try self.codeLens(params, request_id, output);
            return true;
        }
        if (std.mem.eql(u8, method, "workspace/symbol")) {
            if (id) |request_id| try self.workspaceSymbol(params, request_id, output);
            return true;
        }
        if (std.mem.eql(u8, method, "textDocument/semanticTokens/full")) {
            if (id) |request_id| try self.semanticTokensFull(params, request_id, output);
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

    fn definition(self: *Server, params: ?std.json.Value, request_id: std.json.Value, output: *ResponseBuffer) !void {
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
        const tree = analysis.tree() orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const resolved = analysis.resolution() orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const expression = tree.findExpressionAt(0, byte_offset) orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const symbol = resolved.expr_symbols.get(expression) orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const entry = resolved.symbols.get(symbol) orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const target_span = definitionSpan(tree, resolved, symbol, entry.span);
        if (entry.kind == .builtin or !target_span.isValidFor(file)) {
            try writeResponse(output, request_id, "null");
            return;
        }
        try writeDefinitionResponse(output, request_id, context.uri, rangeForSpan(file, target_span));
    }

    fn references(self: *Server, params: ?std.json.Value, request_id: std.json.Value, output: *ResponseBuffer) !void {
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
        const tree = analysis.tree() orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const resolved = analysis.resolution() orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const expression = tree.findExpressionAt(0, byte_offset) orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const symbol = resolved.expr_symbols.get(expression) orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        try writeReferencesResponse(output, request_id, context.uri, file, tree, resolved, symbol, referenceIncludesDeclaration(params));
    }

    fn documentHighlight(self: *Server, params: ?std.json.Value, request_id: std.json.Value, output: *ResponseBuffer) !void {
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
        const tree = analysis.tree() orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const resolved = analysis.resolution() orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const expression = tree.findExpressionAt(0, byte_offset) orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const symbol = resolved.expr_symbols.get(expression) orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        try writeHighlightsResponse(output, request_id, file, tree, resolved, symbol);
    }

    fn prepareRename(self: *Server, params: ?std.json.Value, request_id: std.json.Value, output: *ResponseBuffer) !void {
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
        const tree = analysis.tree() orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const resolved = analysis.resolution() orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const expression = tree.findExpressionAt(0, byte_offset) orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const symbol = resolved.expr_symbols.get(expression) orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const entry = resolved.symbols.get(symbol) orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        if (entry.kind == .builtin) {
            try writeResponse(output, request_id, "null");
            return;
        }
        const span = panos_core.ast.exprSpan(tree.expr(expression).*);
        if (!span.isValidFor(file)) {
            try writeResponse(output, request_id, "null");
            return;
        }
        try writeRangeResponse(output, request_id, rangeForSpan(file, span));
    }

    fn rename(self: *Server, params: ?std.json.Value, request_id: std.json.Value, output: *ResponseBuffer) !void {
        const context = self.documentPosition(params) orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const new_name = renameNewName(params) orelse {
            try writeError(output, request_id, -32602, "Отсутствует или пустое имя newName");
            return;
        };
        if (!isValidIdentifier(new_name)) {
            try writeError(output, request_id, -32602, "newName не является допустимым идентификатором panos");
            return;
        }
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
        const tree = analysis.tree() orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const resolved = analysis.resolution() orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const expression = tree.findExpressionAt(0, byte_offset) orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const symbol = resolved.expr_symbols.get(expression) orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const entry = resolved.symbols.get(symbol) orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        if (entry.kind == .builtin) {
            try writeResponse(output, request_id, "null");
            return;
        }
        try writeRenameResponse(output, request_id, context.uri, file, tree, resolved, symbol, new_name);
    }

    fn signatureHelp(self: *Server, params: ?std.json.Value, request_id: std.json.Value, output: *ResponseBuffer) !void {
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
        const tree = analysis.tree() orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const resolved = analysis.resolution() orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const call = findCallAt(tree, byte_offset) orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const call_expression = tree.expr(call).call;
        const symbol = resolved.expr_symbols.get(call_expression.callee) orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        var declarations = resolved.decl_symbols.iterator();
        while (declarations.next()) |entry| {
            if (entry.value_ptr.* != symbol) continue;
            const function = switch (tree.decl(entry.key_ptr.*).*) {
                .function => |value| value,
                else => break,
            };
            const active_parameter = activeParameter(tree, call_expression, byte_offset, function.parameters.len);
            try writeSignatureHelpResponse(output, request_id, file, tree, function, active_parameter);
            return;
        }
        try writeResponse(output, request_id, "null");
    }

    // Coarse but real: innermost tier is the exact expression at the
    // cursor (`findExpressionAt`'s own span), next tier is the smallest
    // top-level declaration containing it, outermost is the whole file —
    // not full AST-statement-level granularity (this AST has no parent
    // pointers to walk block/statement nesting), but a genuine 2-3-level
    // chain, not a single flat range.
    fn selectionRange(self: *Server, params: ?std.json.Value, request_id: std.json.Value, output: *ResponseBuffer) !void {
        const params_value = params orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const params_object = objectValue(params_value) orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const document_value = params_object.get("textDocument") orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const document = objectValue(document_value) orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const uri_value = document.get("uri") orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const uri = stringValue(uri_value) orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const positions_value = params_object.get("positions") orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const positions = arrayValue(positions_value) orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const text = self.documents.sourceText(uri) orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const file = panos_core.source.SourceFile.init(0, uri, text);
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

        try output.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":");
        try appendJsonValue(output, request_id);
        try output.appendSlice(",\"result\":[");
        for (positions.items, 0..) |position_value, index| {
            if (index != 0) try output.append(',');
            const position_object = objectValue(position_value) orelse {
                try output.appendSlice("null");
                continue;
            };
            const line = if (position_object.get("line")) |v| (unsignedValue(v) orelse 0) else 0;
            const character = if (position_object.get("character")) |v| (unsignedValue(v) orelse 0) else 0;
            const byte_offset = file.utf16PositionToByteOffset(.{ .line = line, .character = character }) orelse {
                try output.appendSlice("null");
                continue;
            };
            try appendSelectionRangeChain(output, file, tree, symbols.items, byte_offset);
        }
        try output.appendSlice("]}");
    }

    fn codeLens(self: *Server, params: ?std.json.Value, request_id: std.json.Value, output: *ResponseBuffer) !void {
        const uri = documentUri(params) orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const text = self.documents.sourceText(uri) orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const file = panos_core.source.SourceFile.init(0, uri, text);
        var analysis = panos_core.runner.analyzeSource(self.allocator, uri, text) catch {
            try writeResponse(output, request_id, "null");
            return;
        };
        defer analysis.deinit();
        const tree = analysis.tree() orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        const resolved = analysis.resolution() orelse {
            try writeResponse(output, request_id, "null");
            return;
        };
        try output.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":");
        try appendJsonValue(output, request_id);
        try output.appendSlice(",\"result\":[");
        var first = true;
        const program = tree.program orelse {
            try output.appendSlice("]}");
            return;
        };
        for (program.declarations) |decl_id| {
            const function = switch (tree.decl(decl_id).*) {
                .function => |value| value,
                else => continue,
            };
            const symbol = resolved.decl_symbols.get(decl_id) orelse continue;
            const count = countReferences(resolved, symbol);
            if (!first) try output.append(',');
            first = false;
            try output.appendSlice("{\"range\":");
            try appendRange(output, rangeForSpan(file, function.name_span));
            try output.appendSlice(",\"command\":{\"title\":");
            var title_buffer: [64]u8 = undefined;
            const title = std.fmt.bufPrint(&title_buffer, "{d} ссылок", .{count}) catch "ссылки";
            try appendJsonString(output, title);
            try output.appendSlice(",\"command\":\"\"}}");
        }
        try output.appendSlice("]}");
    }

    // `textDocument/semanticTokens/full` — relative encoding per the LSP
    // spec: each token is `(deltaLine, deltaChar, length, tokenType,
    // tokenModifiers)`, `deltaChar` measured from the PREVIOUS token's
    // start ONLY when both are on the same line, otherwise from column 0.
    // Ported from `lsp/lsp_server.odin`'s `handle_semantic_tokens`.
    fn semanticTokensFull(self: *Server, params: ?std.json.Value, request_id: std.json.Value, output: *ResponseBuffer) !void {
        const uri = documentUri(params) orelse {
            try writeResponse(output, request_id, "{\"data\":[]}");
            return;
        };
        const text = self.documents.sourceText(uri) orelse {
            try writeResponse(output, request_id, "{\"data\":[]}");
            return;
        };
        const file = panos_core.source.SourceFile.init(0, uri, text);
        var analysis = panos_core.runner.analyzeSource(self.allocator, uri, text) catch {
            try writeResponse(output, request_id, "{\"data\":[]}");
            return;
        };
        defer analysis.deinit();
        const tree = analysis.tree() orelse {
            try writeResponse(output, request_id, "{\"data\":[]}");
            return;
        };
        const resolved = analysis.resolution() orelse {
            try writeResponse(output, request_id, "{\"data\":[]}");
            return;
        };

        const raw = panos_core.semantic_tokens.computeSemanticTokens(self.allocator, tree, resolved) catch {
            try writeResponse(output, request_id, "{\"data\":[]}");
            return;
        };
        defer self.allocator.free(raw);

        const PositionedToken = struct { line: u32, character: u32, length: u32, token_type: u32 };
        var items: std.ArrayList(PositionedToken) = .empty;
        defer items.deinit(self.allocator);
        for (raw) |token| {
            const start = file.byteOffsetToUtf16Position(token.span.start);
            const end = file.byteOffsetToUtf16Position(token.span.end);
            // panos identifiers are always single-line — this guards
            // against ever emitting a token that violates the spec's
            // "a semantic token cannot span more than one line" invariant,
            // rather than assuming the source data always agrees.
            if (end.line != start.line or end.character <= start.character) continue;
            try items.append(self.allocator, .{
                .line = start.line,
                .character = start.character,
                .length = end.character - start.character,
                .token_type = @intFromEnum(token.token_type),
            });
        }
        std.mem.sort(PositionedToken, items.items, {}, struct {
            fn lessThan(_: void, a: PositionedToken, b: PositionedToken) bool {
                if (a.line != b.line) return a.line < b.line;
                return a.character < b.character;
            }
        }.lessThan);

        try output.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":");
        try appendJsonValue(output, request_id);
        try output.appendSlice(",\"result\":{\"data\":[");
        var prev_line: u32 = 0;
        var prev_character: u32 = 0;
        for (items.items, 0..) |item, index| {
            const delta_line = item.line - prev_line;
            const delta_character = if (delta_line == 0) item.character - prev_character else item.character;
            if (index != 0) try output.append(',');
            var buffer: [64]u8 = undefined;
            const encoded = std.fmt.bufPrint(&buffer, "{d},{d},{d},{d},0", .{ delta_line, delta_character, item.length, item.token_type }) catch unreachable;
            try output.appendSlice(encoded);
            prev_line = item.line;
            prev_character = item.character;
        }
        try output.appendSlice("]}}");
    }

    fn workspaceSymbol(self: *Server, params: ?std.json.Value, request_id: std.json.Value, output: *ResponseBuffer) !void {
        const params_object = if (params) |value| objectValue(value) else null;
        const query = blk: {
            const object = params_object orelse break :blk "";
            const query_value = object.get("query") orelse break :blk "";
            break :blk stringValue(query_value) orelse "";
        };
        try output.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":");
        try appendJsonValue(output, request_id);
        try output.appendSlice(",\"result\":[");
        var first = true;
        var iterator = self.documents.documents.iterator();
        while (iterator.next()) |entry| {
            const uri = entry.key_ptr.*;
            const text = entry.value_ptr.text;
            var analysis = panos_core.runner.analyzeSource(self.allocator, uri, text) catch continue;
            defer analysis.deinit();
            const tree = analysis.tree() orelse continue;
            var symbols = panos_core.lsp.documentSymbols(self.allocator, tree) catch continue;
            defer symbols.deinit();
            const file = panos_core.source.SourceFile.init(0, uri, text);
            try appendMatchingSymbols(output, &first, file, uri, symbols.items, query, null);
        }
        try output.appendSlice("]}");
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

fn arrayValue(value: std.json.Value) ?std.json.Array {
    return switch (value) {
        .array => |array| array,
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

fn referenceIncludesDeclaration(params: ?std.json.Value) bool {
    const params_object = objectValue(params orelse return false) orelse return false;
    const context = objectValue(params_object.get("context") orelse return false) orelse return false;
    return switch (context.get("includeDeclaration") orelse return false) {
        .bool => |include| include,
        else => false,
    };
}

fn renameNewName(params: ?std.json.Value) ?[]const u8 {
    const params_object = objectValue(params orelse return null) orelse return null;
    const new_name = stringValue(params_object.get("newName") orelse return null) orelse return null;
    if (new_name.len == 0) return null;
    return new_name;
}

fn isValidIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    var pos: usize = 0;
    var first = true;
    while (pos < name.len) {
        const width = std.unicode.utf8ByteSequenceLength(name[pos]) catch return false;
        if (pos + width > name.len) return false;
        const codepoint = std.unicode.utf8Decode(name[pos .. pos + width]) catch return false;
        if (first) {
            if (!isIdentifierStartCodepoint(codepoint)) return false;
            first = false;
        } else if (!isIdentifierContinueCodepoint(codepoint)) {
            return false;
        }
        pos += width;
    }
    return true;
}

fn isIdentifierStartCodepoint(codepoint: u21) bool {
    if (codepoint <= 0x7F) return std.ascii.isAlphabetic(@intCast(codepoint)) or codepoint == '_';
    return switch (codepoint) {
        0x0400...0x052F, 0x2DE0...0x2DFF, 0xA640...0xA69F => true,
        else => false,
    };
}

fn isIdentifierContinueCodepoint(codepoint: u21) bool {
    if (isIdentifierStartCodepoint(codepoint)) return true;
    return codepoint <= 0x7F and std.ascii.isDigit(@intCast(codepoint));
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

fn writeDefinitionResponse(output: *ResponseBuffer, id: std.json.Value, uri: []const u8, range: core_lsp.Range) !void {
    try output.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":");
    try appendJsonValue(output, id);
    try output.appendSlice(",\"result\":");
    try appendLocation(output, uri, range);
    try output.append('}');
}

fn writeReferencesResponse(output: *ResponseBuffer, id: std.json.Value, uri: []const u8, file: panos_core.source.SourceFile, tree: *const panos_core.ast.Ast, resolved: *const panos_core.resolver.Resolution, symbol: panos_core.symbols.SymbolId, include_declaration: bool) !void {
    try output.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":");
    try appendJsonValue(output, id);
    try output.appendSlice(",\"result\":[");
    var first = true;
    if (include_declaration) {
        if (resolved.symbols.get(symbol)) |entry| {
            const span = definitionSpan(tree, resolved, symbol, entry.span);
            if (span.isValidFor(file)) {
                try appendLocation(output, uri, rangeForSpan(file, span));
                first = false;
            }
        }
    }
    var iterator = resolved.expr_symbols.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != symbol) continue;
        if (!first) try output.append(',');
        first = false;
        const span = panos_core.ast.exprSpan(tree.expr(entry.key_ptr.*).*);
        try appendLocation(output, uri, rangeForSpan(file, span));
    }
    try output.appendSlice("]}");
}

fn writeHighlightsResponse(output: *ResponseBuffer, id: std.json.Value, file: panos_core.source.SourceFile, tree: *const panos_core.ast.Ast, resolved: *const panos_core.resolver.Resolution, symbol: panos_core.symbols.SymbolId) !void {
    try output.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":");
    try appendJsonValue(output, id);
    try output.appendSlice(",\"result\":[");
    var first = true;
    var iterator = resolved.expr_symbols.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != symbol) continue;
        if (!first) try output.append(',');
        first = false;
        try output.appendSlice("{\"range\":");
        const span = panos_core.ast.exprSpan(tree.expr(entry.key_ptr.*).*);
        try appendRange(output, rangeForSpan(file, span));
        try output.appendSlice(",\"kind\":1}");
    }
    try output.appendSlice("]}");
}

fn writeRangeResponse(output: *ResponseBuffer, id: std.json.Value, range: core_lsp.Range) !void {
    try output.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":");
    try appendJsonValue(output, id);
    try output.appendSlice(",\"result\":");
    try appendRange(output, range);
    try output.append('}');
}

fn writeRenameResponse(output: *ResponseBuffer, id: std.json.Value, uri: []const u8, file: panos_core.source.SourceFile, tree: *const panos_core.ast.Ast, resolved: *const panos_core.resolver.Resolution, symbol: panos_core.symbols.SymbolId, new_name: []const u8) !void {
    try output.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":");
    try appendJsonValue(output, id);
    try output.appendSlice(",\"result\":{\"changes\":{");
    try appendJsonString(output, uri);
    try output.appendSlice(":[");
    var first = true;
    // Only include the declaration site itself when we have a PRECISE
    // name-only span for it (`decl_symbols`, function/constant) — a local
    // `пер`/`конст` binding's recorded span covers the WHOLE statement
    // (`ast.zig`'s `Stmt.let` has no separate name sub-span), so including
    // it here would replace `пер a: Число = 1` with just the new name,
    // corrupting the statement. Local declarations are therefore
    // deliberately left out of the edit set for now — only their actual
    // uses (via `expr_symbols` below) get renamed.
    if (preciseDeclarationSpan(tree, resolved, symbol)) |span| {
        if (span.isValidFor(file)) {
            try appendTextEdit(output, rangeForSpan(file, span), new_name);
            first = false;
        }
    }
    var iterator = resolved.expr_symbols.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != symbol) continue;
        if (!first) try output.append(',');
        first = false;
        const span = panos_core.ast.exprSpan(tree.expr(entry.key_ptr.*).*);
        try appendTextEdit(output, rangeForSpan(file, span), new_name);
    }
    try output.appendSlice("]}}}");
}

fn appendTextEdit(output: *ResponseBuffer, range: core_lsp.Range, new_text: []const u8) !void {
    try output.appendSlice("{\"range\":");
    try appendRange(output, range);
    try output.appendSlice(",\"newText\":");
    try appendJsonString(output, new_text);
    try output.append('}');
}

fn appendLocation(output: *ResponseBuffer, uri: []const u8, range: core_lsp.Range) !void {
    try output.appendSlice("{\"uri\":");
    try appendJsonString(output, uri);
    try output.appendSlice(",\"range\":");
    try appendRange(output, range);
    try output.append('}');
}

fn countReferences(resolved: *const panos_core.resolver.Resolution, symbol: panos_core.symbols.SymbolId) usize {
    var count: usize = 0;
    var iterator = resolved.expr_symbols.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* == symbol) count += 1;
    }
    return count;
}

// Deepest `DocumentSymbol` (by nesting) whose `range` contains `offset` —
// `null` if none does (cursor sits in top-level whitespace/outside any decl).
fn smallestSymbolContaining(symbols: []const core_lsp.DocumentSymbol, offset: u32) ?core_lsp.DocumentSymbol {
    for (symbols) |symbol| {
        if (offset < symbol.range.start or offset > symbol.range.end) continue;
        return smallestSymbolContaining(symbol.children, offset) orelse symbol;
    }
    return null;
}

// See `selectionRange`'s doc comment for why this is a 2-3-tier chain, not
// full statement-level AST nesting.
fn appendSelectionRangeChain(
    output: *ResponseBuffer,
    file: panos_core.source.SourceFile,
    tree: *const panos_core.ast.Ast,
    symbols: []const core_lsp.DocumentSymbol,
    offset: u32,
) !void {
    const whole_file_span = panos_core.source.Span{ .file_id = 0, .start = 0, .end = @intCast(file.bytes.len) };
    const enclosing_symbol = smallestSymbolContaining(symbols, offset);
    const innermost_span: ?panos_core.source.Span = blk: {
        const expression = tree.findExpressionAt(0, offset) orelse break :blk null;
        break :blk panos_core.ast.exprSpan(tree.expr(expression).*);
    };

    try output.appendSlice("{\"range\":");
    if (innermost_span) |span| {
        try appendRange(output, rangeForSpan(file, span));
    } else if (enclosing_symbol) |symbol| {
        try appendRange(output, rangeForSpan(file, symbol.range));
    } else {
        try appendRange(output, rangeForSpan(file, whole_file_span));
    }
    if (innermost_span != null) {
        try output.appendSlice(",\"parent\":{\"range\":");
        if (enclosing_symbol) |symbol| {
            try appendRange(output, rangeForSpan(file, symbol.range));
        } else {
            try appendRange(output, rangeForSpan(file, whole_file_span));
        }
        if (enclosing_symbol != null) {
            try output.appendSlice(",\"parent\":{\"range\":");
            try appendRange(output, rangeForSpan(file, whole_file_span));
            try output.append('}');
        }
        try output.append('}');
    } else if (enclosing_symbol != null) {
        try output.appendSlice(",\"parent\":{\"range\":");
        try appendRange(output, rangeForSpan(file, whole_file_span));
        try output.append('}');
    }
    try output.append('}');
}

fn appendMatchingSymbols(
    output: *ResponseBuffer,
    first: *bool,
    file: panos_core.source.SourceFile,
    uri: []const u8,
    symbols: []const core_lsp.DocumentSymbol,
    query: []const u8,
    container: ?[]const u8,
) !void {
    for (symbols) |symbol| {
        if (query.len == 0 or std.ascii.indexOfIgnoreCasePos(symbol.name, 0, query) != null) {
            if (!first.*) try output.append(',');
            first.* = false;
            try output.appendSlice("{\"name\":");
            try appendJsonString(output, symbol.name);
            try output.appendSlice(",\"kind\":");
            try appendNumber(output, documentSymbolKind(symbol.kind));
            if (container) |name| {
                try output.appendSlice(",\"containerName\":");
                try appendJsonString(output, name);
            }
            try output.appendSlice(",\"location\":");
            try appendLocation(output, uri, rangeForSpan(file, symbol.range));
            try output.append('}');
        }
        try appendMatchingSymbols(output, first, file, uri, symbol.children, query, symbol.name);
    }
}

fn definitionSpan(tree: *const panos_core.ast.Ast, resolved: *const panos_core.resolver.Resolution, symbol: panos_core.symbols.SymbolId, fallback: panos_core.source.Span) panos_core.source.Span {
    var declarations = resolved.decl_symbols.iterator();
    while (declarations.next()) |entry| {
        if (entry.value_ptr.* != symbol) continue;
        return switch (tree.decl(entry.key_ptr.*).*) {
            .function => |function| function.name_span,
            .constant => |constant| constant.name_span,
            else => fallback,
        };
    }
    return fallback;
}

// Same `decl_symbols` walk as `definitionSpan`, but returns `null` instead
// of a whole-statement fallback span when no precise name-only span
// exists (see the comment at its call site in `writeRenameResponse`).
fn preciseDeclarationSpan(tree: *const panos_core.ast.Ast, resolved: *const panos_core.resolver.Resolution, symbol: panos_core.symbols.SymbolId) ?panos_core.source.Span {
    var declarations = resolved.decl_symbols.iterator();
    while (declarations.next()) |entry| {
        if (entry.value_ptr.* != symbol) continue;
        return switch (tree.decl(entry.key_ptr.*).*) {
            .function => |function| function.name_span,
            .constant => |constant| constant.name_span,
            else => null,
        };
    }
    return null;
}

fn findCallAt(tree: *const panos_core.ast.Ast, offset: u32) ?panos_core.ast.ExprId {
    var result: ?panos_core.ast.ExprId = null;
    var result_size: u32 = std.math.maxInt(u32);
    for (tree.expressions.items, 0..) |expression, index| {
        if (expression != .call) continue;
        const span = panos_core.ast.exprSpan(expression);
        if (!span.contains(0, offset)) continue;
        const size = span.end - span.start;
        if (size >= result_size) continue;
        result = @enumFromInt(index);
        result_size = size;
    }
    return result;
}

fn activeParameter(tree: *const panos_core.ast.Ast, call: anytype, offset: u32, parameter_count: usize) u32 {
    if (parameter_count == 0) return 0;
    for (call.arguments, 0..) |argument, index| {
        const span = panos_core.ast.exprSpan(tree.expr(argument).*);
        if (offset <= span.end) return @intCast(@min(index, parameter_count - 1));
    }
    return @intCast(parameter_count - 1);
}

fn writeSignatureHelpResponse(output: *ResponseBuffer, id: std.json.Value, file: panos_core.source.SourceFile, tree: *const panos_core.ast.Ast, function: anytype, active_parameter: u32) !void {
    try output.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":");
    try appendJsonValue(output, id);
    try output.appendSlice(",\"result\":{\"signatures\":[{\"label\":");
    try appendFunctionLabel(output, file, tree, function);
    try output.appendSlice(",\"parameters\":[");
    for (function.parameters, 0..) |parameter, index| {
        if (index != 0) try output.append(',');
        try output.appendSlice("{\"label\":");
        try appendParameterLabel(output, file, tree, parameter);
        try output.append('}');
    }
    try output.appendSlice("]}],\"activeSignature\":0,\"activeParameter\":");
    try appendNumber(output, active_parameter);
    try output.appendSlice("}}");
}

fn appendFunctionLabel(output: *ResponseBuffer, file: panos_core.source.SourceFile, tree: *const panos_core.ast.Ast, function: anytype) !void {
    var label: std.ArrayList(u8) = .empty;
    defer label.deinit(output.allocator);
    try label.appendSlice(output.allocator, function.name);
    try label.append(output.allocator, '(');
    for (function.parameters, 0..) |parameter, index| {
        if (index != 0) try label.appendSlice(output.allocator, ", ");
        try appendParameterText(&label, output.allocator, file, tree, parameter);
    }
    try label.appendSlice(output.allocator, ") -> ");
    try label.appendSlice(output.allocator, typeText(file, tree, function.return_type));
    try appendJsonString(output, label.items);
}

fn appendParameterLabel(output: *ResponseBuffer, file: panos_core.source.SourceFile, tree: *const panos_core.ast.Ast, parameter: panos_core.ast.ParamDecl) !void {
    var label: std.ArrayList(u8) = .empty;
    defer label.deinit(output.allocator);
    try appendParameterText(&label, output.allocator, file, tree, parameter);
    try appendJsonString(output, label.items);
}

fn appendParameterText(label: *std.ArrayList(u8), allocator: std.mem.Allocator, file: panos_core.source.SourceFile, tree: *const panos_core.ast.Ast, parameter: panos_core.ast.ParamDecl) !void {
    try label.appendSlice(allocator, parameter.name);
    if (parameter.type_annotation) |type_annotation| {
        try label.appendSlice(allocator, ": ");
        try label.appendSlice(allocator, typeText(file, tree, type_annotation));
    }
}

fn typeText(file: panos_core.source.SourceFile, tree: *const panos_core.ast.Ast, type_id: panos_core.ast.TypeId) []const u8 {
    const span = typeSpan(tree.typeNode(type_id).*);
    if (!span.isValidFor(file)) return "<неизвестный тип>";
    return file.bytes[@intCast(span.start)..@intCast(span.end)];
}

fn typeSpan(node: panos_core.ast.TypeNode) panos_core.source.Span {
    return switch (node) {
        .ident => |value| value.span,
        .generic => |value| value.span,
        .qualified => |value| value.span,
        .tuple => |value| value.span,
        .function => |value| value.span,
        .error_node => |span| span,
    };
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

    while (true) {
        // A transport-framing error (missing/invalid `Content-Length`, a
        // message past `max_message_size`, an unexpected EOF mid-header)
        // used to propagate straight through this `while`'s `try` into
        // `main`'s own `!void` return, crashing the ENTIRE server process
        // on a single malformed frame — found via `specs/010-zig-migration`
        // T055's contract validation (`contracts/lsp.md`: "[invalid input]
        // ... never terminate the server"). A real LSP client always sends
        // well-formed frames, so this is unlikely to trigger in practice —
        // but "the whole editor's language server dies" on any transport
        // hiccup is a strictly worse failure mode than a clean shutdown, so
        // this now logs to stderr and exits the loop (ending the process
        // with a normal, successful exit) instead of an uncaught error.
        const message = readMessage(init.gpa, stdin) catch |err| {
            var stderr_buffer: [256]u8 = undefined;
            var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
            stderr_file_writer.interface.print("panos-lsp: транспортная ошибка, останавливаюсь: {t}\n", .{err}) catch {};
            stderr_file_writer.interface.flush() catch {};
            break;
        } orelse break;
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
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"textDocumentSync\":1,\"hoverProvider\":true,\"definitionProvider\":true,\"referencesProvider\":true,\"documentHighlightProvider\":true,\"completionProvider\":{\"triggerCharacters\":[\".\"]},\"signatureHelpProvider\":{\"triggerCharacters\":[\"(\",\",\"]},\"foldingRangeProvider\":true,\"documentSymbolProvider\":true,\"renameProvider\":{\"prepareProvider\":true},\"selectionRangeProvider\":true,\"codeLensProvider\":{},\"workspaceSymbolProvider\":true,\"semanticTokensProvider\":{\"legend\":{\"tokenTypes\":[\"namespace\",\"type\",\"enumMember\",\"function\",\"variable\",\"parameter\"],\"tokenModifiers\":[]},\"full\":true}}}}", output.items());

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

    try std.testing.expect(try server.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///пример.ps\"},\"contentChanges\":[{\"text\":\"экспорт функ сложить(a: Число, b: Число) -> Число\\na + b\\nконец\\nэкспорт функ старт() -> Число\\nсложить(20, 22)\\nконец\"}]}}", &output));
    try std.testing.expect(try server.handle("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///пример.ps\"},\"position\":{\"line\":4,\"character\":1}}}", &output));
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"uri\":\"file:///пример.ps\",\"range\":{\"start\":{\"line\":0,\"character\":13}") != null);

    try std.testing.expect(try server.handle("{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"textDocument/references\",\"params\":{\"textDocument\":{\"uri\":\"file:///пример.ps\"},\"position\":{\"line\":4,\"character\":1},\"context\":{\"includeDeclaration\":true}}}", &output));
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"line\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"line\":4") != null);

    try std.testing.expect(try server.handle("{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"textDocument/documentHighlight\",\"params\":{\"textDocument\":{\"uri\":\"file:///пример.ps\"},\"position\":{\"line\":4,\"character\":1}}}", &output));
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"line\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"kind\":1") != null);

    try std.testing.expect(try server.handle("{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"textDocument/signatureHelp\",\"params\":{\"textDocument\":{\"uri\":\"file:///пример.ps\"},\"position\":{\"line\":4,\"character\":8}}}", &output));
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"label\":\"сложить(a: Число, b: Число) -> Число\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"activeParameter\":0") != null);

    try std.testing.expect(try server.handle("{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"textDocument/prepareRename\",\"params\":{\"textDocument\":{\"uri\":\"file:///пример.ps\"},\"position\":{\"line\":4,\"character\":1}}}", &output));
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":11,\"result\":{\"start\":{\"line\":4,\"character\":0},\"end\":{\"line\":4,\"character\":7}}}", output.items());

    try std.testing.expect(try server.handle("{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"textDocument/prepareRename\",\"params\":{\"textDocument\":{\"uri\":\"file:///пример.ps\"},\"position\":{\"line\":5,\"character\":0}}}", &output));
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":12,\"result\":null}", output.items());

    try std.testing.expect(try server.handle("{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file:///пример.ps\"},\"position\":{\"line\":4,\"character\":1},\"newName\":\"сумма\"}}", &output));
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"changes\":{\"file:///пример.ps\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"start\":{\"line\":0,\"character\":13},\"end\":{\"line\":0,\"character\":20}},\"newText\":\"сумма\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"start\":{\"line\":4,\"character\":0},\"end\":{\"line\":4,\"character\":7}},\"newText\":\"сумма\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "line\":1") == null);

    try std.testing.expect(try server.handle("{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file:///пример.ps\"},\"position\":{\"line\":4,\"character\":1},\"newName\":\"1неверно\"}}", &output));
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"error\":{\"code\":-32602") != null);

    try std.testing.expect(try server.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///пример.ps\"},\"contentChanges\":[{\"text\":\"экспорт функ старт() -> Число\\nпер a: Число = 1\\nесли истина тогда\\nпер a: Число = 2\\na\\nконец\\na\\nконец\"}]}}", &output));
    try std.testing.expect(try server.handle("{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file:///пример.ps\"},\"position\":{\"line\":6,\"character\":0},\"newName\":\"внешняя\"}}", &output));
    // The `пер a: Число = 1` declaration itself is deliberately NOT in the
    // edit set — a local binding's recorded span covers the whole
    // statement, not just the name, so there is no safe sub-span to emit
    // (see `writeRenameResponse`'s comment). Only its actual USES get
    // renamed: line 6 (outer scope) but not line 4 (shadowed by the inner
    // `пер a: Число = 2`, a different symbol).
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"start\":{\"line\":1,\"character\":4}") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"start\":{\"line\":6,\"character\":0},\"end\":{\"line\":6,\"character\":1}},\"newText\":\"внешняя\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"start\":{\"line\":4,\"character\":0},\"end\":{\"line\":4,\"character\":1}},\"newText\":\"внешняя\"") == null);

    try std.testing.expect(try server.handle("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/unsupported\",\"params\":{}}", &output));
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"code\":-32601") != null);

    try std.testing.expect(try server.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///пример.ps\"},\"contentChanges\":[{\"text\":\"экспорт функ сложить(a: Число, b: Число) -> Число\\na + b\\nконец\\nэкспорт функ старт() -> Число\\nсложить(20, 22)\\nконец\"}]}}", &output));

    try std.testing.expect(try server.handle("{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"textDocument/selectionRange\",\"params\":{\"textDocument\":{\"uri\":\"file:///пример.ps\"},\"positions\":[{\"line\":4,\"character\":1}]}}", &output));
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"result\":[{\"range\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"parent\":") != null);

    try std.testing.expect(try server.handle("{\"jsonrpc\":\"2.0\",\"id\":17,\"method\":\"textDocument/codeLens\",\"params\":{\"textDocument\":{\"uri\":\"file:///пример.ps\"}}}", &output));
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"1 ссылок\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"0 ссылок\"") != null);

    try std.testing.expect(try server.handle("{\"jsonrpc\":\"2.0\",\"id\":18,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"слож\"}}", &output));
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"name\":\"сложить\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"location\":{\"uri\":\"file:///пример.ps\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"name\":\"старт\"") == null);

    // Document is `сложить(a, b) -> a + b` / `старт() -> сложить(20, 22)`.
    // `сложить`/`старт` themselves are DECLARATION names (not `.ident`
    // expressions, so not classified — see `semantic_tokens.zig`'s doc
    // comment); only USES land in `expr_symbols`: `a`/`b` inside `a + b`
    // (parameter, token type 5) and the `сложить` call inside `старт`
    // (function, token type 3).
    try std.testing.expect(try server.handle("{\"jsonrpc\":\"2.0\",\"id\":19,\"method\":\"textDocument/semanticTokens/full\",\"params\":{\"textDocument\":{\"uri\":\"file:///пример.ps\"}}}", &output));
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"result\":{\"data\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "\"data\":[]}") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items(), ",5,0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items(), ",3,0") != null);
}

test "LSP transport reads Content-Length frames" {
    var reader = std.Io.Reader.fixed("Content-Length: 17\r\nX-Test: panos\r\n\r\n{\"jsonrpc\":\"2.0\"}");
    const message = (try readMessage(std.testing.allocator, &reader)).?;
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\"}", message);
    try std.testing.expect((try readMessage(std.testing.allocator, &reader)) == null);
}
