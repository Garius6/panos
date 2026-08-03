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
    var run = panos_core.runner.runSource(allocator, "плейграунд.ps", input) catch {
        setResult("[]");
        return;
    };
    defer run.deinit();

    writeDiagnostics(&run, input, true);
}

pub export fn panos_hover(_: i32, _: i32) void {
    setResult("null");
}

pub export fn panos_complete(_: i32, _: i32) void {
    setResult("[]");
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
