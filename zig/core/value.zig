const std = @import("std");
const bytecode = @import("bytecode.zig");

pub const Aggregate = struct {
    header: GcHeader = .{},
    name: ?[]const u8 = null,
    elements: []Value,
};

pub const Array = struct {
    header: GcHeader = .{},
    elements: []Value,
};

pub const Closure = struct {
    header: GcHeader = .{},
    function_id: bytecode.FunctionId,
    captures: []Value,
};

pub const MapEntry = struct {
    key: Value,
    value: Value,
};

pub const Map = struct {
    header: GcHeader = .{},
    entries: std.ArrayList(MapEntry) = .empty,

    pub fn deinit(self: *Map, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        self.* = undefined;
    }
};

pub const GcHeader = struct {
    marked: bool = false,
};

pub const HeapString = struct {
    header: GcHeader = .{},
    bytes: []u8,
};

pub const Value = union(enum) {
    void: void,
    number: f64,
    boolean: bool,
    string: []const u8,
    heap_string: *HeapString,
    function_ref: bytecode.FunctionId,
    closure: *Closure,
    aggregate: *Aggregate,
    array: *Array,
    map: *Map,

    pub fn stringBytes(runtime_value: Value) ?[]const u8 {
        return switch (runtime_value) {
            .string => |string| string,
            .heap_string => |string| string.bytes,
            else => null,
        };
    }

    pub fn eql(left: Value, right: Value) bool {
        if (left.stringBytes()) |left_string| {
            const right_string = right.stringBytes() orelse return false;
            return std.mem.eql(u8, left_string, right_string);
        }
        if (right.stringBytes() != null) return false;
        return switch (left) {
            .void => right == .void,
            .number => |left_number| switch (right) {
                .number => |right_number| left_number == right_number,
                else => false,
            },
            .boolean => |left_boolean| switch (right) {
                .boolean => |right_boolean| left_boolean == right_boolean,
                else => false,
            },
            .string, .heap_string => unreachable,
            .function_ref => |left_function| switch (right) {
                .function_ref => |right_function| left_function == right_function,
                else => false,
            },
            .closure => |left_closure| switch (right) {
                .closure => |right_closure| left_closure == right_closure,
                else => false,
            },
            .aggregate => |left_aggregate| switch (right) {
                .aggregate => |right_aggregate| aggregateEql(left_aggregate, right_aggregate),
                else => false,
            },
            .array => |left_array| switch (right) {
                .array => |right_array| valueSliceEql(left_array.elements, right_array.elements),
                else => false,
            },
            .map => |left_map| switch (right) {
                .map => |right_map| mapEql(left_map, right_map),
                else => false,
            },
        };
    }
};

fn aggregateEql(left: *const Aggregate, right: *const Aggregate) bool {
    const names_match = if (left.name) |left_name|
        if (right.name) |right_name| std.mem.eql(u8, left_name, right_name) else false
    else
        right.name == null;
    return names_match and valueSliceEql(left.elements, right.elements);
}

fn valueSliceEql(left: []const Value, right: []const Value) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_value, right_value| {
        if (!left_value.eql(right_value)) return false;
    }
    return true;
}

fn mapEql(left: *const Map, right: *const Map) bool {
    if (left.entries.items.len != right.entries.items.len) return false;
    for (left.entries.items, right.entries.items) |left_entry, right_entry| {
        if (!left_entry.key.eql(right_entry.key) or !left_entry.value.eql(right_entry.value)) return false;
    }
    return true;
}

test "values compare scalars and aggregates structurally" {
    var tuple_values = [_]Value{ .{ .number = 1 }, .{ .string = "один" } };
    var left = Aggregate{ .elements = &tuple_values };
    var right = Aggregate{ .elements = &tuple_values };
    var different_name = Aggregate{ .name = "Точка", .elements = &tuple_values };

    try std.testing.expect(Value.eql(.{ .aggregate = &left }, .{ .aggregate = &right }));
    try std.testing.expect(!Value.eql(.{ .aggregate = &left }, .{ .aggregate = &different_name }));
    try std.testing.expect(Value.eql(.{ .number = 2 }, .{ .number = 2 }));
    try std.testing.expect(!Value.eql(.{ .number = 2 }, .{ .boolean = true }));
}
