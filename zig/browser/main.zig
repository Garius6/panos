const source_capacity: usize = 65_536;
const result_capacity: usize = 65_536;

var source_buffer: [source_capacity]u8 = undefined;
var result_buffer: [result_capacity]u8 = undefined;
var result_len: u32 = 0;

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
    return result_len;
}

pub export fn panos_run(_: i32) void {
    setResult("[]");
}

pub export fn panos_check(_: i32) void {
    setResult("[]");
}

pub export fn panos_hover(_: i32, _: i32) void {
    setResult("null");
}

pub export fn panos_complete(_: i32, _: i32) void {
    setResult("[]");
}

fn setResult(value: []const u8) void {
    @memcpy(result_buffer[0..value.len], value);
    result_len = @intCast(value.len);
}
