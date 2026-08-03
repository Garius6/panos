const std = @import("std");
const symbols = @import("symbols.zig");

pub const TypeId = enum(u32) { _ };

pub const invalid_type: TypeId = @enumFromInt(0);

pub const Primitive = enum {
    number,
    integer,
    boolean,
    void,
    never,
    string,
    error_value,
};

pub const Builtins = struct {
    number: TypeId,
    integer: TypeId,
    boolean: TypeId,
    void: TypeId,
    never: TypeId,
    string: TypeId,
    error_value: TypeId,
};

pub const Type = union(enum) {
    primitive: Primitive,
    tuple: []const TypeId,
    function: struct {
        parameters: []const TypeId,
        return_type: TypeId,
    },
    nominal: struct {
        symbol: symbols.SymbolId,
        identity: u32 = 0,
        arguments: []const TypeId,
    },
    array: TypeId,
    map: struct {
        key: TypeId,
        value: TypeId,
    },
    process: TypeId,
    pointer: TypeId,
    generic_parameter: u32,
    poison: void,
};

pub const TypeStore = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    types: std.ArrayList(Type) = .empty,
    builtins: Builtins,

    pub fn init(allocator: std.mem.Allocator) !TypeStore {
        var store = TypeStore{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .builtins = undefined,
        };
        errdefer store.deinit();
        try store.types.append(allocator, .{ .poison = {} });
        store.builtins = .{
            .number = try store.add(.{ .primitive = .number }),
            .integer = try store.add(.{ .primitive = .integer }),
            .boolean = try store.add(.{ .primitive = .boolean }),
            .void = try store.add(.{ .primitive = .void }),
            .never = try store.add(.{ .primitive = .never }),
            .string = try store.add(.{ .primitive = .string }),
            .error_value = try store.add(.{ .primitive = .error_value }),
        };
        return store;
    }

    pub fn deinit(self: *TypeStore) void {
        self.types.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn get(self: *const TypeStore, id: TypeId) ?*const Type {
        const index = @intFromEnum(id);
        if (index == 0 or index >= self.types.items.len) return null;
        return &self.types.items[index];
    }

    pub fn tuple(self: *TypeStore, elements: []const TypeId) !TypeId {
        return self.add(.{ .tuple = try self.arena.allocator().dupe(TypeId, elements) });
    }

    pub fn function(self: *TypeStore, parameters: []const TypeId, return_type: TypeId) !TypeId {
        return self.add(.{ .function = .{
            .parameters = try self.arena.allocator().dupe(TypeId, parameters),
            .return_type = return_type,
        } });
    }

    pub fn nominal(self: *TypeStore, symbol: symbols.SymbolId, arguments: []const TypeId) !TypeId {
        return self.nominalWithIdentity(symbol, 0, arguments);
    }

    pub fn nominalWithIdentity(self: *TypeStore, symbol: symbols.SymbolId, identity: u32, arguments: []const TypeId) !TypeId {
        return self.add(.{ .nominal = .{
            .symbol = symbol,
            .identity = identity,
            .arguments = try self.arena.allocator().dupe(TypeId, arguments),
        } });
    }

    pub fn array(self: *TypeStore, element: TypeId) !TypeId {
        return self.add(.{ .array = element });
    }

    pub fn map(self: *TypeStore, key: TypeId, value: TypeId) !TypeId {
        return self.add(.{ .map = .{ .key = key, .value = value } });
    }

    pub fn process(self: *TypeStore, message: TypeId) !TypeId {
        return self.add(.{ .process = message });
    }

    pub fn pointer(self: *TypeStore, pointee: TypeId) !TypeId {
        return self.add(.{ .pointer = pointee });
    }

    pub fn genericParameter(self: *TypeStore, identifier: u32) !TypeId {
        return self.add(.{ .generic_parameter = identifier });
    }

    pub fn poison(self: *TypeStore) !TypeId {
        return self.add(.{ .poison = {} });
    }

    pub fn eql(self: *const TypeStore, left: TypeId, right: TypeId) bool {
        if (left == right) return true;
        const left_type = self.get(left) orelse return false;
        const right_type = self.get(right) orelse return false;
        return switch (left_type.*) {
            .primitive => |left_primitive| switch (right_type.*) {
                .primitive => |right_primitive| left_primitive == right_primitive,
                else => false,
            },
            .tuple => |left_elements| switch (right_type.*) {
                .tuple => |right_elements| self.eqlSlices(left_elements, right_elements),
                else => false,
            },
            .function => |left_function| switch (right_type.*) {
                .function => |right_function| self.eqlSlices(left_function.parameters, right_function.parameters) and self.eql(left_function.return_type, right_function.return_type),
                else => false,
            },
            .nominal => |left_nominal| switch (right_type.*) {
                .nominal => |right_nominal| (if (left_nominal.identity != 0 or right_nominal.identity != 0)
                    left_nominal.identity != 0 and left_nominal.identity == right_nominal.identity
                else
                    left_nominal.symbol == right_nominal.symbol) and self.eqlSlices(left_nominal.arguments, right_nominal.arguments),
                else => false,
            },
            .array => |left_element| switch (right_type.*) {
                .array => |right_element| self.eql(left_element, right_element),
                else => false,
            },
            .map => |left_map| switch (right_type.*) {
                .map => |right_map| self.eql(left_map.key, right_map.key) and self.eql(left_map.value, right_map.value),
                else => false,
            },
            .process => |left_message| switch (right_type.*) {
                .process => |right_message| self.eql(left_message, right_message),
                else => false,
            },
            .pointer => |left_pointee| switch (right_type.*) {
                .pointer => |right_pointee| self.eql(left_pointee, right_pointee),
                else => false,
            },
            .generic_parameter => |left_symbol| switch (right_type.*) {
                .generic_parameter => |right_symbol| left_symbol == right_symbol,
                else => false,
            },
            .poison => switch (right_type.*) {
                .poison => true,
                else => false,
            },
        };
    }

    fn add(self: *TypeStore, value: Type) !TypeId {
        const id: TypeId = @enumFromInt(self.types.items.len);
        try self.types.append(self.allocator, value);
        return id;
    }

    fn eqlSlices(self: *const TypeStore, left: []const TypeId, right: []const TypeId) bool {
        if (left.len != right.len) return false;
        for (left, right) |left_type, right_type| {
            if (!self.eql(left_type, right_type)) return false;
        }
        return true;
    }
};

test "type store keeps canonical primitive IDs" {
    var store = try TypeStore.init(std.testing.allocator);
    defer store.deinit();

    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(store.builtins.number));
    try std.testing.expect(store.eql(store.builtins.number, store.builtins.number));
    try std.testing.expect(!store.eql(store.builtins.number, store.builtins.string));
    switch (store.get(store.builtins.integer).?.*) {
        .primitive => |primitive| try std.testing.expectEqual(Primitive.integer, primitive),
        else => return error.TestUnexpectedResult,
    }
}

test "composite types own their parameter slices" {
    var store = try TypeStore.init(std.testing.allocator);
    defer store.deinit();

    var elements = [_]TypeId{ store.builtins.number, store.builtins.string };
    const tuple = try store.tuple(&elements);
    elements[0] = store.builtins.boolean;
    switch (store.get(tuple).?.*) {
        .tuple => |stored_elements| {
            try std.testing.expectEqual(store.builtins.number, stored_elements[0]);
            try std.testing.expectEqual(store.builtins.string, stored_elements[1]);
        },
        else => return error.TestUnexpectedResult,
    }

    const function = try store.function(&.{tuple}, store.builtins.void);
    switch (store.get(function).?.*) {
        .function => |signature| try std.testing.expectEqual(tuple, signature.parameters[0]),
        else => return error.TestUnexpectedResult,
    }
}

test "nominal types compare declaration identity and generic arguments" {
    var symbol_store = try symbols.SymbolStore.init(std.testing.allocator);
    defer symbol_store.deinit();
    var type_store = try TypeStore.init(std.testing.allocator);
    defer type_store.deinit();

    const option_symbol = try symbol_store.add(.{ .name = "Опция", .kind = .type, .span = .{ .file_id = 0, .start = 0, .end = 0 } });
    const result_symbol = try symbol_store.add(.{ .name = "Результат", .kind = .type, .span = .{ .file_id = 0, .start = 0, .end = 0 } });
    const option_number = try type_store.nominal(option_symbol, &.{type_store.builtins.number});
    const option_string = try type_store.nominal(option_symbol, &.{type_store.builtins.string});
    const result_number = try type_store.nominal(result_symbol, &.{type_store.builtins.number});

    try std.testing.expect(type_store.eql(option_number, option_number));
    try std.testing.expect(!type_store.eql(option_number, option_string));
    try std.testing.expect(!type_store.eql(option_number, result_number));
}

test "imported nominal types compare graph identities instead of local symbols" {
    var symbol_store = try symbols.SymbolStore.init(std.testing.allocator);
    defer symbol_store.deinit();
    var type_store = try TypeStore.init(std.testing.allocator);
    defer type_store.deinit();

    const left_symbol = try symbol_store.add(.{ .name = "Значение", .kind = .type, .span = .{ .file_id = 0, .start = 0, .end = 0 } });
    const right_symbol = try symbol_store.add(.{ .name = "Значение", .kind = .type, .span = .{ .file_id = 1, .start = 0, .end = 0 } });
    const left = try type_store.nominalWithIdentity(left_symbol, 1, &.{});
    const same_origin = try type_store.nominalWithIdentity(right_symbol, 1, &.{});
    const other_origin = try type_store.nominalWithIdentity(right_symbol, 2, &.{});

    try std.testing.expect(type_store.eql(left, same_origin));
    try std.testing.expect(!type_store.eql(left, other_origin));
}
