const std = @import("std");
const bytecode = @import("bytecode.zig");
const value = @import("value.zig");
const sqlite3 = @import("sqlite3_bindings.zig");

const Object = union(enum) {
    string: *value.HeapString,
    aggregate: *value.Aggregate,
    array: *value.Array,
    closure: *value.Closure,
    interface: *value.Interface,
    map: *value.Map,
    file: *value.FileHandle,
    connection: *value.Connection,
    sql_connection: *value.SqlConnection,
    listener: *value.Listener,
    http_request: *value.HttpRequestHandle,
};

pub const Heap = struct {
    allocator: std.mem.Allocator,
    objects: std.ArrayList(Object) = .empty,
    // Long-lived, order-independent GC protection for an object a
    // background async-I/O worker is touching (an already-open `Файл`/
    // `Соединение`/`Соединение_БД` handle) — outlives many step() calls,
    // unlike a LIFO protect/unprotect pair that's only safe within a single
    // call with no foreign code running in between. Unpinned by VALUE
    // (search+swapRemove), not by stack position, so arbitrarily
    // interleaved pins from OTHER unrelated calls never interfere: each
    // adds and removes only its OWN entry, regardless of how long some
    // other entry has already been sitting here. Mirrors Odin's
    // gc_pin/gc_unpin (core/gc.odin), which reuses `vm.gc.protect_stack`
    // for the same reason.
    pinned: std.ArrayList(value.Value) = .empty,

    pub fn init(allocator: std.mem.Allocator) Heap {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Heap) void {
        for (self.objects.items) |object| self.destroy(object);
        self.objects.deinit(self.allocator);
        self.pinned.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn pin(self: *Heap, v: value.Value) !void {
        try self.pinned.append(self.allocator, v);
    }

    pub fn unpin(self: *Heap, v: value.Value) void {
        for (self.pinned.items, 0..) |item, index| {
            if (item.eql(v)) {
                _ = self.pinned.swapRemove(index);
                return;
            }
        }
    }

    pub fn createAggregate(self: *Heap, name: ?[]const u8, elements: []value.Value) !*value.Aggregate {
        const aggregate = try self.allocator.create(value.Aggregate);
        errdefer self.allocator.destroy(aggregate);
        errdefer self.allocator.free(elements);
        aggregate.* = .{ .name = name, .elements = elements };
        try self.objects.append(self.allocator, .{ .aggregate = aggregate });
        return aggregate;
    }

    pub fn createString(self: *Heap, bytes: []u8) !*value.HeapString {
        const string = try self.allocator.create(value.HeapString);
        errdefer self.allocator.destroy(string);
        errdefer self.allocator.free(bytes);
        string.* = .{ .bytes = bytes };
        try self.objects.append(self.allocator, .{ .string = string });
        return string;
    }

    pub fn formatString(self: *Heap, comptime format: []const u8, args: anytype) !*value.HeapString {
        return self.createString(try std.fmt.allocPrint(self.allocator, format, args));
    }

    pub fn createArray(self: *Heap, elements: []value.Value) !*value.Array {
        const array = try self.allocator.create(value.Array);
        errdefer self.allocator.destroy(array);
        errdefer self.allocator.free(elements);
        array.* = .{ .elements = elements };
        try self.objects.append(self.allocator, .{ .array = array });
        return array;
    }

    // Called only from `фс.открыть` (`vm.zig`'s `fileOpen`) — `path` is
    // duped so it outlives whatever local buffer the caller read it from.
    pub fn createFile(self: *Heap, path: []const u8) !*value.FileHandle {
        const handle = try self.allocator.create(value.FileHandle);
        errdefer self.allocator.destroy(handle);
        const owned_path = try self.allocator.dupe(u8, path);
        handle.* = .{ .path = owned_path };
        try self.objects.append(self.allocator, .{ .file = handle });
        return handle;
    }

    pub fn createConnection(self: *Heap, stream: std.Io.net.Stream) !*value.Connection {
        const connection = try self.allocator.create(value.Connection);
        errdefer self.allocator.destroy(connection);
        connection.* = .{ .stream = stream };
        try self.objects.append(self.allocator, .{ .connection = connection });
        return connection;
    }

    pub fn createSqlConnection(self: *Heap, db: anytype) !*value.SqlConnection {
        const connection = try self.allocator.create(value.SqlConnection);
        errdefer self.allocator.destroy(connection);
        connection.* = .{ .db = db };
        try self.objects.append(self.allocator, .{ .sql_connection = connection });
        return connection;
    }

    pub fn createListener(self: *Heap, server: std.Io.net.Server) !*value.Listener {
        const listener = try self.allocator.create(value.Listener);
        errdefer self.allocator.destroy(listener);
        listener.* = .{ .server = server };
        try self.objects.append(self.allocator, .{ .listener = listener });
        return listener;
    }

    // `method`/`path` are duped by the caller (delivery time, `vm.zig`) so
    // they outlive whatever worker-owned buffer they were parsed from.
    pub fn createHttpRequest(self: *Heap, stream: std.Io.net.Stream, method: []u8, path: []u8, body: []u8, headers: []value.HttpHeaderEntry) !*value.HttpRequestHandle {
        const request = try self.allocator.create(value.HttpRequestHandle);
        errdefer self.allocator.destroy(request);
        request.* = .{ .stream = stream, .method = method, .path = path, .body = body, .headers = headers };
        try self.objects.append(self.allocator, .{ .http_request = request });
        return request;
    }

    pub fn createClosure(self: *Heap, function_id: anytype, captures: []value.Value) !*value.Closure {
        const closure = try self.allocator.create(value.Closure);
        errdefer self.allocator.destroy(closure);
        errdefer self.allocator.free(captures);
        closure.* = .{ .function_id = function_id, .captures = captures };
        try self.objects.append(self.allocator, .{ .closure = closure });
        return closure;
    }

    pub fn createInterface(self: *Heap, receiver: value.Value, methods: []const bytecode.FunctionId) !*value.Interface {
        return self.createInterfacePackage(receiver, &.{methods});
    }

    pub fn createInterfacePackage(self: *Heap, receiver: value.Value, vtables: []const []const bytecode.FunctionId) !*value.Interface {
        const interface = try self.allocator.create(value.Interface);
        errdefer self.allocator.destroy(interface);
        const owned_vtables = try self.allocator.dupe([]const bytecode.FunctionId, vtables);
        errdefer self.allocator.free(owned_vtables);
        interface.* = .{ .receiver = receiver, .vtables = owned_vtables };
        try self.objects.append(self.allocator, .{ .interface = interface });
        return interface;
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
            .heap_string => |string| self.mark(.{ .string = string }),
            .aggregate => |aggregate| self.mark(.{ .aggregate = aggregate }),
            .array => |array| self.mark(.{ .array = array }),
            .closure => |closure| self.mark(.{ .closure = closure }),
            .interface => |interface| self.mark(.{ .interface = interface }),
            .process => {},
            .map => |map| self.mark(.{ .map = map }),
            .file => |file| self.mark(.{ .file = file }),
            .connection => |connection| self.mark(.{ .connection = connection }),
            .sql_connection => |connection| self.mark(.{ .sql_connection = connection }),
            .listener => |listener| self.mark(.{ .listener = listener }),
            .http_request => |request| self.mark(.{ .http_request = request }),
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
        self.markValues(self.pinned.items);
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
            .string => {},
            .aggregate => |aggregate| self.markValues(aggregate.elements),
            .array => |array| self.markValues(array.elements),
            .closure => |closure| self.markValues(closure.captures),
            .interface => |interface| self.markValue(interface.receiver),
            .map => |map| for (map.entries.items) |entry| {
                self.markValue(entry.key);
                self.markValue(entry.value);
            },
            .file => {},
            .connection => {},
            .sql_connection => {},
            .listener => {},
            .http_request => {},
        }
    }

    fn destroy(self: *Heap, object: Object) void {
        switch (object) {
            .string => |string| {
                self.allocator.free(string.bytes);
                self.allocator.destroy(string);
            },
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
            .interface => |interface| {
                self.allocator.free(interface.vtables);
                self.allocator.destroy(interface);
            },
            .map => |map| {
                map.deinit(self.allocator);
                self.allocator.destroy(map);
            },
            // No live OS descriptor to release (see `value.zig`'s
            // `FileHandle` doc comment) — just the owned path buffer.
            .file => |file_handle| {
                self.allocator.free(file_handle.path);
                self.allocator.destroy(file_handle);
            },
            // Symmetric to Odin's `close_socket_value` finalizer
            // (`core/vm_io_native.odin`) — unlike `FileHandle`, this one
            // DOES hold a live descriptor that must be released here if
            // the user never called `.закрыть()` explicitly. Real `if`/
            // `else` on the freestanding check (not early-return) so the
            // `std.Io.Threaded`-backed close is Sema-eliminated entirely
            // for the browser target, matching `ос.*`'s pattern — see
            // `value.zig`'s `Connection` doc comment.
            .connection => |connection| {
                if (connection.is_open) {
                    if (comptime @import("builtin").target.os.tag != .freestanding) {
                        var io = std.Io.Threaded.init(self.allocator, .{});
                        defer io.deinit();
                        connection.stream.close(io.io());
                    }
                }
                connection.pending.deinit(self.allocator);
                self.allocator.destroy(connection);
            },
            // Symmetric to Odin's `close_sql_connection` finalizer
            // (`core/vm_sql_native.odin`) and to `.connection` above —
            // same real-descriptor / same `if`/`else`-elimination
            // reasoning.
            .sql_connection => |connection| {
                if (connection.is_open) {
                    if (comptime @import("builtin").target.os.tag != .freestanding) {
                        _ = sqlite3.sqlite3_close_v2(connection.db);
                    }
                }
                self.allocator.destroy(connection);
            },
            // Symmetric to `.connection` above — same real-descriptor /
            // same `if`/`else`-elimination reasoning.
            .listener => |listener| {
                if (listener.is_open) {
                    if (comptime @import("builtin").target.os.tag != .freestanding) {
                        var io = std.Io.Threaded.init(self.allocator, .{});
                        defer io.deinit();
                        listener.server.deinit(io.io());
                    }
                }
                self.allocator.destroy(listener);
            },
            .http_request => |request| {
                if (!request.responded) {
                    if (comptime @import("builtin").target.os.tag != .freestanding) {
                        var io = std.Io.Threaded.init(self.allocator, .{});
                        defer io.deinit();
                        request.stream.close(io.io());
                    }
                }
                self.allocator.free(request.method);
                self.allocator.free(request.path);
                self.allocator.free(request.body);
                for (request.headers) |entry| {
                    self.allocator.free(entry.name);
                    self.allocator.free(entry.value);
                }
                self.allocator.free(request.headers);
                self.allocator.destroy(request);
            },
        }
    }
};

fn header(object: Object) *value.GcHeader {
    return switch (object) {
        .string => |string| &string.header,
        .aggregate => |aggregate| &aggregate.header,
        .array => |array| &array.header,
        .closure => |closure| &closure.header,
        .interface => |interface| &interface.header,
        .map => |map| &map.header,
        .file => |file_handle| &file_handle.header,
        .connection => |connection| &connection.header,
        .sql_connection => |connection| &connection.header,
        .listener => |listener| &listener.header,
        .http_request => |request| &request.header,
    };
}

test "heap collects unreachable dynamic strings" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const string = try heap.formatString("значение {d}", .{1});
    heap.collect(&.{.{ .heap_string = string }});
    try std.testing.expectEqual(@as(usize, 1), heap.objectCount());

    heap.collect(&.{});
    try std.testing.expectEqual(@as(usize, 0), heap.objectCount());
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

test "heap keeps a pinned object alive with zero other roots, sweeps it after unpin" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const string = try heap.formatString("в полёте", .{});
    try heap.pin(.{ .heap_string = string });

    heap.collect(&.{});
    try std.testing.expectEqual(@as(usize, 1), heap.objectCount());

    heap.unpin(.{ .heap_string = string });
    heap.collect(&.{});
    try std.testing.expectEqual(@as(usize, 0), heap.objectCount());
}

test "heap retains interface receivers" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const string = try heap.formatString("{s}", .{"значение"});
    const interface = try heap.createInterface(.{ .heap_string = string }, &.{});
    heap.collect(&.{.{ .interface = interface }});
    try std.testing.expectEqual(@as(usize, 2), heap.objectCount());

    heap.collect(&.{});
    try std.testing.expectEqual(@as(usize, 0), heap.objectCount());
}
