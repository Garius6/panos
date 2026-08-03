const std = @import("std");
const value = @import("value.zig");

const Object = union(enum) {
    aggregate: *value.Aggregate,
    array: *value.Array,
    closure: *value.Closure,
    map: *value.Map,
};

pub const Heap = struct {
    allocator: std.mem.Allocator,
    objects: std.ArrayList(Object) = .empty,

    pub fn init(allocator: std.mem.Allocator) Heap {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Heap) void {
        for (self.objects.items) |object| self.destroy(object);
        self.objects.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn createAggregate(self: *Heap, name: ?[]const u8, elements: []value.Value) !*value.Aggregate {
        const aggregate = try self.allocator.create(value.Aggregate);
        errdefer self.allocator.destroy(aggregate);
        errdefer self.allocator.free(elements);
        aggregate.* = .{ .name = name, .elements = elements };
        try self.objects.append(self.allocator, .{ .aggregate = aggregate });
        return aggregate;
    }

    pub fn createArray(self: *Heap, elements: []value.Value) !*value.Array {
        const array = try self.allocator.create(value.Array);
        errdefer self.allocator.destroy(array);
        errdefer self.allocator.free(elements);
        array.* = .{ .elements = elements };
        try self.objects.append(self.allocator, .{ .array = array });
        return array;
    }

    pub fn createClosure(self: *Heap, function_id: anytype, captures: []value.Value) !*value.Closure {
        const closure = try self.allocator.create(value.Closure);
        errdefer self.allocator.destroy(closure);
        errdefer self.allocator.free(captures);
        closure.* = .{ .function_id = function_id, .captures = captures };
        try self.objects.append(self.allocator, .{ .closure = closure });
        return closure;
    }

    pub fn createMap(self: *Heap) !*value.Map {
        const map = try self.allocator.create(value.Map);
        errdefer self.allocator.destroy(map);
        map.* = .{};
        try self.objects.append(self.allocator, .{ .map = map });
        return map;
    }

    pub fn clearMarks(self: *Heap) void {
        for (self.objects.items) |object| header(object).marked = false;
    }

    pub fn markValues(self: *Heap, values: []const value.Value) void {
        for (values) |runtime_value| self.markValue(runtime_value);
    }

    pub fn markValue(self: *Heap, runtime_value: value.Value) void {
        switch (runtime_value) {
            .aggregate => |aggregate| self.mark(.{ .aggregate = aggregate }),
            .array => |array| self.mark(.{ .array = array }),
            .closure => |closure| self.mark(.{ .closure = closure }),
            .map => |map| self.mark(.{ .map = map }),
            else => {},
        }
    }

    pub fn sweep(self: *Heap) void {
        var index: usize = 0;
        while (index < self.objects.items.len) {
            const object = self.objects.items[index];
            if (header(object).marked) {
                index += 1;
                continue;
            }
            _ = self.objects.swapRemove(index);
            self.destroy(object);
        }
    }

    pub fn collect(self: *Heap, roots: []const value.Value) void {
        self.clearMarks();
        self.markValues(roots);
        self.sweep();
    }

    pub fn objectCount(self: *const Heap) usize {
        return self.objects.items.len;
    }

    fn mark(self: *Heap, object: Object) void {
        const object_header = header(object);
        if (object_header.marked) return;
        object_header.marked = true;
        switch (object) {
            .aggregate => |aggregate| self.markValues(aggregate.elements),
            .array => |array| self.markValues(array.elements),
            .closure => |closure| self.markValues(closure.captures),
            .map => |map| for (map.entries.items) |entry| {
                self.markValue(entry.key);
                self.markValue(entry.value);
            },
        }
    }

    fn destroy(self: *Heap, object: Object) void {
        switch (object) {
            .aggregate => |aggregate| {
                self.allocator.free(aggregate.elements);
                self.allocator.destroy(aggregate);
            },
            .array => |array| {
                self.allocator.free(array.elements);
                self.allocator.destroy(array);
            },
            .closure => |closure| {
                self.allocator.free(closure.captures);
                self.allocator.destroy(closure);
            },
            .map => |map| {
                map.deinit(self.allocator);
                self.allocator.destroy(map);
            },
        }
    }
};

fn header(object: Object) *value.GcHeader {
    return switch (object) {
        .aggregate => |aggregate| &aggregate.header,
        .array => |array| &array.header,
        .closure => |closure| &closure.header,
        .map => |map| &map.header,
    };
}

test "heap collects unreachable array cycles and retains roots" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const left_elements = try std.testing.allocator.alloc(value.Value, 1);
    const right_elements = try std.testing.allocator.alloc(value.Value, 1);
    const left = try heap.createArray(left_elements);
    const right = try heap.createArray(right_elements);
    left.elements[0] = .{ .array = right };
    right.elements[0] = .{ .array = left };

    heap.collect(&.{.{ .array = left }});
    try std.testing.expectEqual(@as(usize, 2), heap.objectCount());

    heap.collect(&.{});
    try std.testing.expectEqual(@as(usize, 0), heap.objectCount());
}
