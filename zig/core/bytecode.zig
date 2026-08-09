const std = @import("std");
const ast = @import("ast.zig");

pub const FunctionId = enum(u32) { _ };

pub const invalid_function: FunctionId = @enumFromInt(std.math.maxInt(u32));

// A `внешний` call target — `fn_ptr` is resolved once, at resolve time
// (`resolver.zig`'s `resolveForeignFunction`, via `std.DynLib`), and
// copied here (arena-owned, independent of `Resolution`'s lifetime) so
// the compiled `Program` is fully self-contained, matching every other
// `Constant` variant. `0` means the resolver already reported a
// diagnostic (library/symbol not found) — `vm.zig` treats it as a
// runtime panic, unreachable if the program actually type-checked clean.
pub const ForeignFunctionConstant = struct {
    fn_ptr: usize,
    param_kinds: []const ast.ForeignMarshalKind,
    return_kind: ast.ForeignMarshalKind,
};

pub const Constant = union(enum) {
    void: void,
    number: f64,
    boolean: bool,
    string: []const u8,
    function_ref: FunctionId,
    interface_vtable: []const FunctionId,
    foreign_function: ForeignFunctionConstant,
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
    match_enum,
    panic,
    pop,
    call,
    cast_interface,
    call_interface,
    spawn,
    send,
    receive,
    observe,
    get_signal,
    process_id,
    current_process,
    kill_process,
    link_process,
    build_closure,
    return_value,
    return_void,
    build_tuple,
    build_struct,
    build_array,
    array_length,
    string_length,
    array_get_or,
    array_contains,
    build_map,
    map_length,
    map_get_or,
    map_entries,
    array_has_index,
    map_has_key,
    map_remove_key,
    array_append,
    get_index,
    set_index,
    get_property,
    set_property,
    file_exists,
    file_delete,
    file_read,
    file_write,
    dir_is_dir,
    dir_create,
    dir_list,
    dir_delete,
    file_open,
    file_handle_read_submit,
    file_handle_read_line_submit,
    file_handle_write_submit,
    file_handle_close,
    os_args,
    os_version,
    os_env_get,
    os_env_set,
    os_env_unset,
    os_exec,
    os_exit,
    time_now,
    time_monotonic,
    time_sleep,
    gzip_decompress,
    syntax_structs,
    syntax_fields,
    syntax_annotations,
    syntax_annotation_arg,
    syntax_field_annotations,
    syntax_field_annotation_arg,
    connection_read_submit,
    connection_read_line_submit,
    connection_write_submit,
    connection_close,
    url_encode,
    http_request_submit,
    sql_open_submit,
    sql_exec_submit,
    sql_query_submit,
    sql_close,
    call_foreign,
    // Неблокирующий I/O: submit-опкоды кладут задачу в воркер-пул и
    // возвращают управление сразу (не блокируют) — компилятор ВСЕГДА
    // эмитит await_async сразу после (compiler.zig, compileFilesystemBuiltin)
    // — та же пара, что Odin's Call_Builtin_Async/Await_Async
    // (core/vm.odin). await_async — ОДНА инструкция на ВСЕ async-builtin'ы
    // (результат приходит из process.async_results, FIFO — порядок
    // гарантирован тем, что submit и await всегда эмитятся смежной парой).
    file_read_submit,
    file_write_submit,
    net_connect_submit,
    await_async,
    http_listen,
    http_accept_submit,
    http_request_method,
    http_request_path,
    http_request_header,
    http_request_respond,
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
    match_enum: u16,
    panic: void,
    pop: void,
    call: u16,
    cast_interface: u16,
    call_interface: struct {
        method_index: u16,
        argument_count: u16,
    },
    spawn: u16,
    send: void,
    receive: void,
    observe: void,
    get_signal: void,
    process_id: void,
    current_process: void,
    kill_process: void,
    link_process: void,
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
    string_length: void,
    array_get_or: void,
    array_contains: void,
    build_map: u16,
    map_length: void,
    map_get_or: void,
    map_entries: void,
    array_has_index: void,
    map_has_key: void,
    map_remove_key: void,
    array_append: void,
    get_index: void,
    set_index: void,
    get_property: u16,
    set_property: u16,
    file_exists: void,
    file_delete: void,
    file_read: void,
    file_write: void,
    dir_is_dir: void,
    dir_create: void,
    dir_list: void,
    dir_delete: void,
    file_open: void,
    file_handle_read_submit: void,
    file_handle_read_line_submit: void,
    file_handle_write_submit: void,
    file_handle_close: void,
    os_args: void,
    os_version: void,
    os_env_get: void,
    os_env_set: void,
    os_env_unset: void,
    os_exec: void,
    os_exit: void,
    time_now: void,
    time_monotonic: void,
    time_sleep: void,
    gzip_decompress: void,
    syntax_structs: void,
    syntax_fields: void,
    syntax_annotations: void,
    syntax_annotation_arg: void,
    syntax_field_annotations: void,
    syntax_field_annotation_arg: void,
    connection_read_submit: void,
    connection_read_line_submit: void,
    connection_write_submit: void,
    connection_close: void,
    url_encode: void,
    http_request_submit: void,
    sql_open_submit: void,
    sql_exec_submit: void,
    sql_query_submit: void,
    sql_close: void,
    // `constant_index` — the pool slot holding this call's
    // `ForeignFunctionConstant`; `argument_count` — how many already-
    // compiled argument values are on the stack below it, same
    // convention as `call`.
    call_foreign: struct {
        constant_index: u16,
        argument_count: u16,
    },
    file_read_submit: void,
    file_write_submit: void,
    net_connect_submit: void,
    await_async: void,
    http_listen: void,
    http_accept_submit: void,
    http_request_method: void,
    http_request_path: void,
    http_request_header: void,
    http_request_respond: void,
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

pub const ComparableMethod = struct {
    type_name: []const u8,
    function_id: FunctionId,
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    functions: std.ArrayList(Function) = .empty,
    comparable_methods: std.ArrayList(ComparableMethod) = .empty,
    entry: FunctionId = invalid_function,

    pub fn init(allocator: std.mem.Allocator) Program {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Program) void {
        for (self.functions.items) |*compiled_function| compiled_function.deinit(self.allocator);
        self.comparable_methods.deinit(self.allocator);
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

    pub fn addComparableMethod(self: *Program, type_name: []const u8, function_id: FunctionId) !void {
        try self.comparable_methods.append(self.allocator, .{
            .type_name = try self.copyString(type_name),
            .function_id = function_id,
        });
    }

    pub fn comparableMethod(self: *const Program, type_name: []const u8) ?FunctionId {
        for (self.comparable_methods.items) |method| {
            if (std.mem.eql(u8, method.type_name, type_name)) return method.function_id;
        }
        const separator = std.mem.indexOfScalar(u8, type_name, '.') orelse return null;
        const owner = type_name[0..separator];
        for (self.comparable_methods.items) |method| {
            if (std.mem.eql(u8, method.type_name, owner)) return method.function_id;
        }
        return null;
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
