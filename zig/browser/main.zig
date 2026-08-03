const std = @import("std");
const builtin = @import("builtin");
const panos_core = @import("panos_core");

const source_capacity: usize = 65_536;
const result_capacity: usize = 65_536;
const allocator = if (builtin.target.cpu.arch == .wasm32) std.heap.wasm_allocator else std.heap.page_allocator;

var source_buffer: [source_capacity]u8 = undefined;
var result_buffer: [result_capacity]u8 = undefined;
var result_len: usize = 0;

pub export fn panos_source_ptr() *u8 {
    return &source_buffer[0];
}

pub export fn panos_source_capacity() u32 {
    return source_capacity;
}

pub export fn panos_result_ptr() *u8 {
    return &result_buffer[0];
}

pub export fn panos_result_len() u32 {
    return @intCast(result_len);
}

pub export fn panos_run(source_len: i32) void {
    const input = sourceFromBuffer(source_len) orelse {
        setResult("Ошибка спайка: исходник длиннее буфера демо\n");
        return;
    };
    var run = panos_core.runner.runSource(allocator, "плейграунд.ps", input) catch {
        setResult("Ошибка выполнения Zig-версии\n");
        return;
    };
    defer run.deinit();

    writeDiagnostics(&run, input, false);
    if (run.hasErrors()) return;
    switch (run.execution orelse return) {
        .success => |output| if (output.len != 0) {
            appendResult(output);
            appendResult("\n");
        },
        .runtime_error => |message| {
            appendResult(message);
            appendResult("\n");
        },
    }
}

pub export fn panos_check(source_len: i32) void {
    const input = sourceFromBuffer(source_len) orelse {
        setResult("[]");
        return;
    };
    var run = panos_core.runner.checkSource(allocator, "плейграунд.ps", input) catch {
        setResult("[]");
        return;
    };
    defer run.deinit();

    writeDiagnostics(&run, input, true);
}

pub export fn panos_hover(source_len: i32, utf16_offset: i32) void {
    const input = sourceFromBuffer(source_len) orelse {
        setResult("null");
        return;
    };
    const byte_offset = utf16OffsetToByte(input, utf16_offset) orelse {
        setResult("null");
        return;
    };
    var analysis = panos_core.runner.analyzeSource(allocator, "плейграунд.ps", input) catch {
        setResult("null");
        return;
    };
    defer analysis.deinit();
    if (analysis.hasErrors()) {
        setResult("null");
        return;
    }
    const tree = analysis.tree() orelse {
        setResult("null");
        return;
    };
    const expression = tree.findExpressionAt(0, @intCast(byte_offset)) orelse {
        setResult("null");
        return;
    };
    const type_name = analysis.expressionTypeName(expression) catch {
        setResult("null");
        return;
    } orelse {
        setResult("null");
        return;
    };
    const span = panos_core.ast.exprSpan(tree.expr(expression).*);
    result_len = 0;
    appendResult("{\"type\":");
    appendJsonString(type_name);
    appendResult(",\"from\":");
    appendNumber(byteOffsetToUtf16(input, span.start));
    appendResult(",\"to\":");
    appendNumber(byteOffsetToUtf16(input, span.end));
    appendResult("}");
}

pub export fn panos_complete(source_len: i32, utf16_offset: i32) void {
    const input = sourceFromBuffer(source_len) orelse {
        setResult("[]");
        return;
    };
    const byte_offset = utf16OffsetToByte(input, utf16_offset) orelse {
        setResult("[]");
        return;
    };
    if (byte_offset < 2 or input[byte_offset - 1] != '.') {
        setResult("[]");
        return;
    }
    const placeholder = "__panos_completion__";
    var patched_input: ?[]u8 = null;
    defer if (patched_input) |bytes| allocator.free(bytes);
    const analysis_input = blk: {
        const bytes = allocator.alloc(u8, input.len + placeholder.len) catch break :blk input;
        patched_input = bytes;
        @memcpy(bytes[0..byte_offset], input[0..byte_offset]);
        @memcpy(bytes[byte_offset .. byte_offset + placeholder.len], placeholder);
        @memcpy(bytes[byte_offset + placeholder.len ..], input[byte_offset..]);
        break :blk bytes;
    };
    var analysis = panos_core.runner.analyzeSource(allocator, "плейграунд.ps", analysis_input) catch {
        setResult("[]");
        return;
    };
    defer analysis.deinit();
    const tree = analysis.tree() orelse {
        setResult("[]");
        return;
    };
    const expression = tree.findExpressionAt(0, @intCast(byte_offset - 2)) orelse {
        setResult("[]");
        return;
    };
    const checked = analysis.checkedResult() orelse {
        setResult("[]");
        return;
    };
    const type_id = checked.expression_types.get(expression) orelse {
        setResult("[]");
        return;
    };
    writeCompletions(checked, type_id);
}

fn sourceFromBuffer(source_len: i32) ?[]const u8 {
    if (source_len < 0 or source_len > source_capacity) return null;
    return source_buffer[0..@intCast(source_len)];
}

fn writeDiagnostics(run: *const panos_core.runner.SourceRun, input: []const u8, as_json: bool) void {
    result_len = 0;
    if (as_json) {
        appendResult("[");
        for (run.diagnostics.items.items, 0..) |item, index| {
            if (index != 0) appendResult(",");
            appendResult("{\"from\":");
            appendNumber(byteOffsetToUtf16(input, item.span.start));
            appendResult(",\"to\":");
            appendNumber(byteOffsetToUtf16(input, item.span.end));
            appendResult(",\"severity\":");
            appendJsonString(switch (item.severity) {
                .err => "error",
                .warning => "warning",
            });
            appendResult(",\"message\":");
            appendJsonString(item.message);
            appendResult("}");
        }
        appendResult("]");
        return;
    }

    for (run.diagnostics.items.items) |item| {
        appendResult(item.message);
        appendResult("\n");
    }
}

fn byteOffsetToUtf16(input: []const u8, byte_offset: u32) usize {
    const limit = @min(@as(usize, @intCast(byte_offset)), input.len);
    var byte_index: usize = 0;
    var utf16_offset: usize = 0;
    while (byte_index < limit) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(input[byte_index]) catch {
            byte_index += 1;
            utf16_offset += 1;
            continue;
        };
        const end = byte_index + @as(usize, sequence_len);
        if (end > limit) break;
        const codepoint = std.unicode.utf8Decode(input[byte_index..end]) catch {
            byte_index += 1;
            utf16_offset += 1;
            continue;
        };
        utf16_offset += if (codepoint > 0xffff) 2 else 1;
        byte_index = end;
    }
    return utf16_offset;
}

fn utf16OffsetToByte(input: []const u8, utf16_offset: i32) ?usize {
    if (utf16_offset < 0) return null;
    const target: usize = @intCast(utf16_offset);
    var byte_index: usize = 0;
    var current_offset: usize = 0;
    while (byte_index < input.len) {
        if (current_offset == target) return byte_index;
        const sequence_len = std.unicode.utf8ByteSequenceLength(input[byte_index]) catch {
            byte_index += 1;
            current_offset += 1;
            continue;
        };
        const end = byte_index + @as(usize, sequence_len);
        if (end > input.len) return null;
        const codepoint = std.unicode.utf8Decode(input[byte_index..end]) catch {
            byte_index += 1;
            current_offset += 1;
            continue;
        };
        const units: usize = if (codepoint > 0xffff) 2 else 1;
        if (current_offset + units > target) return byte_index;
        current_offset += units;
        byte_index = end;
    }
    return if (current_offset == target) byte_index else null;
}

fn appendNumber(number: anytype) void {
    var buffer: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{number}) catch return;
    appendResult(text);
}

fn appendJsonString(value: []const u8) void {
    appendResult("\"");
    for (value) |byte| switch (byte) {
        '"' => appendResult("\\\""),
        '\\' => appendResult("\\\\"),
        '\n' => appendResult("\\n"),
        '\r' => appendResult("\\r"),
        '\t' => appendResult("\\t"),
        0...8, 11...12, 14...0x1f => appendControlByte(byte),
        else => appendResult(&.{byte}),
    };
    appendResult("\"");
}

fn appendControlByte(byte: u8) void {
    const hex = "0123456789abcdef";
    appendResult("\\u00");
    appendResult(&.{ hex[byte >> 4], hex[byte & 0x0f] });
}

fn writeCompletions(checked: *const panos_core.type_checker.CheckResult, type_id: panos_core.types.TypeId) void {
    result_len = 0;
    appendResult("[");
    var first = true;
    const entry = checked.types.get(type_id) orelse {
        appendResult("]");
        return;
    };
    switch (entry.*) {
        .array => {
            appendCompletion(&first, "длина", "method");
            appendCompletion(&first, "добавить", "method");
            appendCompletion(&first, "получить", "method");
            appendCompletion(&first, "есть", "method");
            appendCompletion(&first, "содержит", "method");
        },
        .map => {
            appendCompletion(&first, "длина", "method");
            appendCompletion(&first, "есть", "method");
            appendCompletion(&first, "получить", "method");
            appendCompletion(&first, "удалить", "method");
        },
        .nominal => |nominal| {
            if (checked.nominal_fields.get(nominal.symbol)) |fields| {
                for (fields) |field| appendCompletion(&first, field.name, "field");
            }
            for (checked.methods.items) |method| {
                if (method.owner == nominal.symbol) appendCompletion(&first, method.name, "method");
            }
            if (checked.interface_definitions.get(nominal.symbol)) |interface| {
                for (interface.methods) |method| appendCompletion(&first, method.name, "method");
            }
            if (checked.enum_definitions.get(nominal.symbol)) |enumeration| {
                for (enumeration.variants) |variant| appendCompletion(&first, variant.name, "variant");
            }
        },
        else => {},
    }
    appendResult("]");
}

fn appendCompletion(first: *bool, label: []const u8, kind: []const u8) void {
    if (!first.*) appendResult(",");
    first.* = false;
    appendResult("{\"label\":");
    appendJsonString(label);
    appendResult(",\"kind\":");
    appendJsonString(kind);
    appendResult("}");
}

fn setResult(value: []const u8) void {
    result_len = 0;
    appendResult(value);
}

fn appendResult(value: []const u8) void {
    const remaining = result_capacity - result_len;
    const copied = @min(value.len, remaining);
    @memcpy(result_buffer[result_len .. result_len + copied], value[0..copied]);
    result_len += copied;
}

test "browser run returns the program result through the shared buffer" {
    const input = "экспорт функ старт() -> Число\n2 + 3\nконец";
    @memcpy(source_buffer[0..input.len], input);
    panos_run(@intCast(input.len));

    try std.testing.expectEqualStrings("5\n", result_buffer[0..result_len]);
}

test "browser check serializes diagnostics for the editor contract" {
    const input = "функ старт() -> Число\nнеизвестно\nконец";
    @memcpy(source_buffer[0..input.len], input);
    panos_check(@intCast(input.len));

    try std.testing.expect(std.mem.startsWith(u8, result_buffer[0..result_len], "[{\"from\":22,\"to\":32,"));
    try std.testing.expect(std.mem.indexOf(u8, result_buffer[0..result_len], "Resolve Error: неопределённое имя 'неизвестно'") != null);
}

test "browser check does not require an entry function" {
    const input = "экспорт функ значение() -> Число\n42\nконец";
    @memcpy(source_buffer[0..input.len], input);
    panos_check(@intCast(input.len));

    try std.testing.expectEqualStrings("[]", result_buffer[0..result_len]);
}

test "browser check rejects unsupported imports" {
    const input = "импорт \"математика\"";
    @memcpy(source_buffer[0..input.len], input);
    panos_check(@intCast(input.len));

    try std.testing.expect(std.mem.indexOf(u8, result_buffer[0..result_len], "выполнение импортов ещё не поддержано Zig-версией") != null);
}

test "browser hover returns an inferred type at a UTF-16 offset" {
    const input = "экспорт функ старт() -> Число\n42\nконец";
    @memcpy(source_buffer[0..input.len], input);
    panos_hover(@intCast(input.len), 30);

    try std.testing.expectEqualStrings("{\"type\":\"Число\",\"from\":30,\"to\":32}", result_buffer[0..result_len]);
}

test "browser completion exposes array methods after a dot" {
    const input = "экспорт функ старт() -> Пусто\nпер числа: Массив(Число) = массив()\nчисла.\nконец";
    @memcpy(source_buffer[0..input.len], input);
    const cursor = std.mem.indexOf(u8, input, "числа.").? + "числа.".len;
    panos_complete(@intCast(input.len), @intCast(byteOffsetToUtf16(input, @intCast(cursor))));

    try std.testing.expect(std.mem.indexOf(u8, result_buffer[0..result_len], "{\"label\":\"добавить\",\"kind\":\"method\"}") != null);
}
