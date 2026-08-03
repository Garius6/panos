const std = @import("std");

pub const FunctionId = enum(u32) { _ };

pub const invalid_function: FunctionId = @enumFromInt(std.math.maxInt(u32));

pub const Constant = union(enum) {
    void: void,
    number: f64,
    boolean: bool,
    string: []const u8,
    function_ref: FunctionId,
};

pub const Opcode = enum {
    constant,
    add,
    subtract,
    multiply,
    divide,
    int_divide,
    modulo,
    bit_and,
    bit_or,
    bit_xor,
    bit_not,
    shift_left,
    shift_right,
    negate_number,
    logical_not,
    less,
    less_equal,
    greater,
    greater_equal,
    equal,
    not_equal,
    get_local,
    set_local,
    jump,
    jump_if_false,
    pop,
    call,
    build_closure,
    return_value,
    return_void,
    build_tuple,
    build_struct,
    build_array,
    array_length,
    build_map,
    get_index,
    set_index,
    get_property,
    set_property,
};

pub const Instruction = union(Opcode) {
    constant: u16,
    add: void,
    subtract: void,
    multiply: void,
    divide: void,
    int_divide: void,
    modulo: void,
    bit_and: void,
    bit_or: void,
    bit_xor: void,
    bit_not: void,
    shift_left: void,
    shift_right: void,
    negate_number: void,
    logical_not: void,
    less: void,
    less_equal: void,
    greater: void,
    greater_equal: void,
    equal: void,
    not_equal: void,
    get_local: u16,
    set_local: u16,
    jump: usize,
    jump_if_false: usize,
    pop: void,
    call: u16,
    build_closure: struct {
        function_id: FunctionId,
        capture_count: u16,
    },
    return_value: void,
    return_void: void,
    build_tuple: u16,
    build_struct: struct {
        name_constant: u16,
        field_count: u16,
    },
    build_array: u16,
    array_length: void,
    build_map: u16,
    get_index: void,
    set_index: void,
    get_property: u16,
    set_property: u16,
};

pub const Function = struct {
    name: []const u8,
    arity: u16,
    capture_count: u16 = 0,
    returns_value: bool = true,
    local_count: u16 = 0,
    instructions: std.ArrayList(Instruction) = .empty,
    constants: std.ArrayList(Constant) = .empty,

    pub fn deinit(self: *Function, allocator: std.mem.Allocator) void {
        self.constants.deinit(allocator);
        self.instructions.deinit(allocator);
        self.* = undefined;
    }

    pub fn emit(self: *Function, allocator: std.mem.Allocator, instruction: Instruction) !void {
        try self.instructions.append(allocator, instruction);
    }

    pub fn addConstant(self: *Function, allocator: std.mem.Allocator, constant: Constant) !u16 {
        if (self.constants.items.len > std.math.maxInt(u16)) return error.ConstantPoolFull;
        const index: u16 = @intCast(self.constants.items.len);
        try self.constants.append(allocator, constant);
        return index;
    }
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    functions: std.ArrayList(Function) = .empty,
    entry: FunctionId = invalid_function,

    pub fn init(allocator: std.mem.Allocator) Program {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Program) void {
        for (self.functions.items) |*compiled_function| compiled_function.deinit(self.allocator);
        self.functions.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn addFunction(self: *Program, name: []const u8, arity: u16) !FunctionId {
        if (self.functions.items.len > std.math.maxInt(u32)) return error.FunctionLimitReached;
        const id: FunctionId = @enumFromInt(self.functions.items.len);
        try self.functions.append(self.allocator, .{
            .name = try self.arena.allocator().dupe(u8, name),
            .arity = arity,
        });
        return id;
    }

    pub fn function(self: *Program, id: FunctionId) ?*Function {
        const index = @intFromEnum(id);
        if (index >= self.functions.items.len) return null;
        return &self.functions.items[index];
    }

    pub fn functionConst(self: *const Program, id: FunctionId) ?*const Function {
        const index = @intFromEnum(id);
        if (index >= self.functions.items.len) return null;
        return &self.functions.items[index];
    }

    pub fn copyString(self: *Program, value: []const u8) ![]const u8 {
        return self.arena.allocator().dupe(u8, value);
    }
};

test "bytecode program owns functions, constants and instructions" {
    var program = Program.init(std.testing.allocator);
    defer program.deinit();

    const function_id = try program.addFunction("сложить", 2);
    const function = program.function(function_id).?;
    const constant = try function.addConstant(std.testing.allocator, .{ .number = 42 });
    try function.emit(std.testing.allocator, .{ .constant = constant });
    try function.emit(std.testing.allocator, .{ .return_value = {} });

    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(function_id));
    try std.testing.expectEqual(@as(u16, 2), function.arity);
    try std.testing.expectEqual(@as(usize, 2), function.instructions.items.len);
    try std.testing.expectEqual(Instruction{ .constant = 0 }, function.instructions.items[0]);
    switch (function.constants.items[0]) {
        .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
        else => return error.TestUnexpectedResult,
    }
}
