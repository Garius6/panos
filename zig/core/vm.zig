const std = @import("std");
const bytecode = @import("bytecode.zig");
const gc = @import("gc.zig");
const value = @import("value.zig");

pub const Execution = union(enum) {
    success: value.Value,
    runtime_error: []const u8,
};

const Frame = struct {
    function_id: bytecode.FunctionId,
    ip: usize = 0,
    locals: []value.Value,
};

pub const Vm = struct {
    allocator: std.mem.Allocator,
    heap: gc.Heap,
    program: *const bytecode.Program,
    stack: std.ArrayList(value.Value) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    processes: std.ArrayList(*value.Process) = .empty,
    active_processes: std.ArrayList(*value.Process) = .empty,
    current_process: ?*value.Process = null,
    current_message: ?value.Value = null,
    next_process_id: u64 = 0,
    failure: ?*value.HeapString = null,

    pub fn init(allocator: std.mem.Allocator, program: *const bytecode.Program) Vm {
        return .{
            .allocator = allocator,
            .heap = gc.Heap.init(allocator),
            .program = program,
        };
    }

    pub fn deinit(self: *Vm) void {
        self.clearFrames();
        self.frames.deinit(self.allocator);
        self.stack.deinit(self.allocator);
        self.clearProcesses();
        self.processes.deinit(self.allocator);
        self.active_processes.deinit(self.allocator);
        self.heap.deinit();
        self.* = undefined;
    }

    pub fn run(self: *Vm, entry: bytecode.FunctionId, arguments: []const value.Value) !Execution {
        self.failure = null;
        self.current_process = null;
        self.current_message = null;
        self.stack.clearRetainingCapacity();
        self.clearFrames();
        self.clearProcesses();
        self.active_processes.clearRetainingCapacity();
        self.next_process_id = 0;
        self.collect();
        const root = try self.createProcess(entry, &.{}, arguments);
        try self.active_processes.append(self.allocator, root);
        defer self.active_processes.clearRetainingCapacity();
        self.current_process = root;
        self.pushFrame(entry, &.{}, arguments) catch |err| switch (err) {
            error.RuntimeFault => return .{ .runtime_error = if (self.failure) |failure| failure.bytes else "Runtime Error: неизвестная ошибка" },
            else => return err,
        };

        while (self.frames.items.len != 0) {
            const completed = self.step() catch |err| switch (err) {
                error.RuntimeFault => return .{ .runtime_error = if (self.failure) |failure| failure.bytes else "Runtime Error: неизвестная ошибка" },
                else => return err,
            };
            if (completed) |result| return .{ .success = result };
        }
        return .{ .success = .{ .void = {} } };
    }

    pub fn collect(self: *Vm) void {
        self.heap.clearMarks();
        self.heap.markValues(self.stack.items);
        for (self.frames.items) |frame| self.heap.markValues(frame.locals);
        for (self.processes.items) |process| {
            self.heap.markValues(process.captures);
            self.heap.markValues(process.arguments);
            self.heap.markValues(process.mailbox.items);
            self.heap.markValues(process.signals.items);
        }
        if (self.current_message) |message| self.heap.markValue(message);
        if (self.failure) |failure| self.heap.markValue(.{ .heap_string = failure });
        self.heap.sweep();
    }

    fn step(self: *Vm) anyerror!?value.Value {
        const frame_index = self.frames.items.len - 1;
        const frame = &self.frames.items[frame_index];
        const compiled = self.program.functionConst(frame.function_id) orelse {
            try self.fault("Runtime Error: неизвестная функция", .{});
            return null;
        };
        if (frame.ip >= compiled.instructions.items.len) return self.finishFrame(.{ .void = {} });
        const instruction = compiled.instructions.items[frame.ip];
        frame.ip += 1;

        switch (instruction) {
            .constant => |index| try self.pushConstant(compiled, index),
            .add => try self.add(),
            .subtract => try self.numericBinary(.subtract),
            .multiply => try self.numericBinary(.multiply),
            .divide => try self.numericBinary(.divide),
            .int_divide => try self.numericBinary(.int_divide),
            .modulo => try self.numericBinary(.modulo),
            .bit_and => try self.bitwise(.bit_and),
            .bit_or => try self.bitwise(.bit_or),
            .bit_xor => try self.bitwise(.bit_xor),
            .bit_not => try self.bitNot(),
            .shift_left => try self.shift(.shift_left),
            .shift_right => try self.shift(.shift_right),
            .negate_number => try self.negateNumber(),
            .logical_not => try self.logicalNot(),
            .less => try self.compare(.less),
            .less_equal => try self.compare(.less_equal),
            .greater => try self.compare(.greater),
            .greater_equal => try self.compare(.greater_equal),
            .equal => try self.equal(false),
            .not_equal => try self.equal(true),
            .get_local => |slot| try self.getLocal(slot),
            .set_local => |slot| try self.setLocal(slot),
            .jump => |target| try self.jump(target),
            .jump_if_false => |target| try self.jumpIfFalse(target),
            .match_enum => |name_constant| try self.matchEnum(compiled, name_constant),
            .panic => try self.panic(),
            .pop => _ = try self.pop(),
            .call => |argument_count| try self.call(argument_count),
            .cast_interface => |vtable| try self.castInterface(compiled, vtable),
            .call_interface => |interface_call| try self.callInterface(interface_call),
            .spawn => |argument_count| try self.spawn(argument_count),
            .send => try self.send(),
            .receive => try self.receive(),
            .observe => try self.observe(),
            .get_signal => try self.getSignal(),
            .process_id => try self.processId(),
            .current_process => try self.currentProcess(),
            .kill_process => try self.killProcess(),
            .link_process => try self.linkProcess(),
            .build_closure => |closure| try self.buildClosure(closure),
            .return_value => return self.finishFrame(try self.pop()),
            .return_void => return self.finishFrame(.{ .void = {} }),
            .build_tuple => |count| try self.buildAggregate(null, count),
            .build_struct => |structure| try self.buildStruct(compiled, structure),
            .build_array => |count| try self.buildArray(count),
            .array_length => try self.arrayLength(),
            .string_length => try self.stringLength(),
            .array_get_or => try self.arrayGetOr(),
            .array_contains => try self.arrayContains(),
            .build_map => |count| try self.buildMap(count),
            .map_length => try self.mapLength(),
            .map_get_or => try self.mapGetOr(),
            .map_entries => try self.mapEntries(),
            .array_has_index => try self.arrayHasIndex(),
            .map_has_key => try self.mapHasKey(),
            .map_remove_key => try self.mapRemoveKey(),
            .array_append => try self.arrayAppend(),
            .get_index => try self.getIndex(),
            .set_index => try self.setIndex(),
            .get_property => |field| try self.getProperty(field),
            .set_property => |field| try self.setProperty(field),
        }
        return null;
    }

    fn pushFrame(self: *Vm, function_id: bytecode.FunctionId, captures: []const value.Value, arguments: []const value.Value) anyerror!void {
        const compiled = self.program.functionConst(function_id) orelse {
            try self.fault("Runtime Error: неизвестная функция", .{});
            return;
        };
        if (arguments.len != compiled.arity) {
            try self.fault("Runtime Error: неверное количество аргументов функции", .{});
            return;
        }
        if (captures.len != compiled.capture_count) {
            try self.fault("Runtime Error: неверное количество захватов замыкания", .{});
            return;
        }
        const required_locals = @as(usize, compiled.capture_count) + @as(usize, compiled.arity);
        if (compiled.local_count < required_locals) {
            try self.fault("Runtime Error: повреждённый фрейм функции", .{});
            return;
        }
        const locals = try self.allocator.alloc(value.Value, compiled.local_count);
        errdefer self.allocator.free(locals);
        for (locals) |*local| local.* = .{ .void = {} };
        @memcpy(locals[0..captures.len], captures);
        @memcpy(locals[captures.len .. captures.len + arguments.len], arguments);
        try self.frames.append(self.allocator, .{ .function_id = function_id, .locals = locals });
    }

    fn finishFrame(self: *Vm, result: value.Value) !?value.Value {
        const frame = self.frames.pop().?;
        self.allocator.free(frame.locals);
        if (self.frames.items.len == 0) return result;
        try self.stack.append(self.allocator, result);
        return null;
    }

    fn pushConstant(self: *Vm, compiled: *const bytecode.Function, index: u16) anyerror!void {
        if (index >= compiled.constants.items.len) {
            try self.fault("Runtime Error: константа вне границ пула", .{});
            return;
        }
        const constant = compiled.constants.items[index];
        const runtime_value: value.Value = switch (constant) {
            .void => .{ .void = {} },
            .number => |constant_number| .{ .number = constant_number },
            .boolean => |constant_boolean| .{ .boolean = constant_boolean },
            .string => |string| .{ .string = string },
            .function_ref => |function_id| .{ .function_ref = function_id },
            .interface_vtable => {
                try self.fault("Runtime Error: vtable интерфейса нельзя использовать как значение", .{});
                return;
            },
        };
        try self.stack.append(self.allocator, runtime_value);
    }

    fn pop(self: *Vm) anyerror!value.Value {
        return self.stack.pop() orelse {
            try self.fault("Runtime Error: недостаточно значений на стеке", .{});
            return .{ .void = {} };
        };
    }

    fn popValues(self: *Vm, count: usize) anyerror![]value.Value {
        if (self.stack.items.len < count) {
            try self.fault("Runtime Error: недостаточно значений на стеке", .{});
            return &.{};
        }
        const start = self.stack.items.len - count;
        const values = try self.allocator.dupe(value.Value, self.stack.items[start..]);
        self.stack.shrinkRetainingCapacity(start);
        return values;
    }

    fn number(self: *Vm, runtime_value: value.Value) anyerror!f64 {
        return switch (runtime_value) {
            .number => |runtime_number| runtime_number,
            else => {
                try self.fault("Runtime Error: оператор ожидает число", .{});
                return 0;
            },
        };
    }

    fn boolean(self: *Vm, runtime_value: value.Value) anyerror!bool {
        return switch (runtime_value) {
            .boolean => |runtime_boolean| runtime_boolean,
            else => {
                try self.fault("Runtime Error: условие должно иметь тип Булево", .{});
                return false;
            },
        };
    }

    fn add(self: *Vm) anyerror!void {
        const right = try self.pop();
        const left = try self.pop();
        if (left.stringBytes()) |left_string| {
            const right_string = right.stringBytes() orelse {
                try self.fault("Runtime Error: оператор '+' ожидает два числа или две строки", .{});
                return;
            };
            const joined = try self.heap.formatString("{s}{s}", .{ left_string, right_string });
            try self.stack.append(self.allocator, .{ .heap_string = joined });
            return;
        }
        switch (left) {
            .number => |left_number| {
                const right_number = try self.number(right);
                try self.stack.append(self.allocator, .{ .number = left_number + right_number });
            },
            .string, .heap_string => unreachable,
            else => try self.fault("Runtime Error: оператор '+' ожидает два числа или две строки", .{}),
        }
    }

    const NumericOperation = enum { subtract, multiply, divide, int_divide, modulo };

    fn numericBinary(self: *Vm, operation: NumericOperation) anyerror!void {
        const right = try self.number(try self.pop());
        const left = try self.number(try self.pop());
        const result = switch (operation) {
            .subtract => left - right,
            .multiply => left * right,
            .divide => blk: {
                if (right == 0) {
                    try self.fault("Runtime Error: деление на ноль", .{});
                    return;
                }
                break :blk left / right;
            },
            .int_divide => blk: {
                if (right == 0) {
                    try self.fault("Runtime Error: деление на ноль", .{});
                    return;
                }
                break :blk std.math.trunc(left / right);
            },
            .modulo => blk: {
                if (right == 0) {
                    try self.fault("Runtime Error: деление на ноль (остаток)", .{});
                    return;
                }
                break :blk try std.math.mod(f64, left, right);
            },
        };
        try self.stack.append(self.allocator, .{ .number = result });
    }

    const BitwiseOperation = enum { bit_and, bit_or, bit_xor };

    fn bitwise(self: *Vm, operation: BitwiseOperation) anyerror!void {
        const right: i64 = @intFromFloat(try self.number(try self.pop()));
        const left: i64 = @intFromFloat(try self.number(try self.pop()));
        const result = switch (operation) {
            .bit_and => left & right,
            .bit_or => left | right,
            .bit_xor => left ^ right,
        };
        try self.stack.append(self.allocator, .{ .number = @floatFromInt(result) });
    }

    fn bitNot(self: *Vm) anyerror!void {
        const integer: i64 = @intFromFloat(try self.number(try self.pop()));
        try self.stack.append(self.allocator, .{ .number = @floatFromInt(~integer) });
    }

    const ShiftOperation = enum { shift_left, shift_right };

    fn shift(self: *Vm, operation: ShiftOperation) anyerror!void {
        const right: i64 = @intFromFloat(try self.number(try self.pop()));
        const left: i64 = @intFromFloat(try self.number(try self.pop()));
        if (right < 0 or right > 63) {
            try self.fault("Runtime Error: сдвиг должен быть в диапазоне от 0 до 63", .{});
            return;
        }
        const amount: u6 = @intCast(right);
        const result = switch (operation) {
            .shift_left => left << amount,
            .shift_right => left >> amount,
        };
        try self.stack.append(self.allocator, .{ .number = @floatFromInt(result) });
    }

    fn negateNumber(self: *Vm) anyerror!void {
        try self.stack.append(self.allocator, .{ .number = -(try self.number(try self.pop())) });
    }

    fn logicalNot(self: *Vm) anyerror!void {
        try self.stack.append(self.allocator, .{ .boolean = !(try self.boolean(try self.pop())) });
    }

    const Comparison = enum { less, less_equal, greater, greater_equal };

    fn compare(self: *Vm, comparison: Comparison) anyerror!void {
        const right_value = try self.pop();
        const left_value = try self.pop();
        const result = switch (right_value) {
            .number => |right| blk: {
                const left = try self.number(left_value);
                break :blk switch (comparison) {
                    .less => left < right,
                    .less_equal => left <= right,
                    .greater => left > right,
                    .greater_equal => left >= right,
                };
            },
            else => blk: {
                const left_aggregate = switch (left_value) {
                    .aggregate => |aggregate| aggregate,
                    else => {
                        try self.fault("Runtime Error: оператор сравнения ожидает числа или Сравниваемое", .{});
                        return;
                    },
                };
                const right_aggregate = switch (right_value) {
                    .aggregate => |aggregate| aggregate,
                    else => {
                        try self.fault("Runtime Error: оператор сравнения ожидает числа или Сравниваемое", .{});
                        return;
                    },
                };
                const type_name = left_aggregate.name orelse {
                    try self.fault("Runtime Error: оператор сравнения ожидает числа или Сравниваемое", .{});
                    return;
                };
                if (right_aggregate.name == null or !std.mem.eql(u8, type_name, right_aggregate.name.?)) {
                    try self.fault("Runtime Error: оператор сравнения ожидает значения одного типа", .{});
                    return;
                }
                const method = self.program.comparableMethod(type_name) orelse {
                    try self.fault("Runtime Error: тип не реализует Сравниваемое", .{});
                    return;
                };
                const ordering = try self.number(try self.invokeComparable(method, left_value, right_value));
                break :blk switch (comparison) {
                    .less => ordering < 0,
                    .less_equal => ordering <= 0,
                    .greater => ordering > 0,
                    .greater_equal => ordering >= 0,
                };
            },
        };
        try self.stack.append(self.allocator, .{ .boolean = result });
    }

    fn invokeComparable(self: *Vm, function_id: bytecode.FunctionId, receiver: value.Value, other: value.Value) anyerror!value.Value {
        const saved_stack = self.stack;
        const saved_frames = self.frames;
        const saved_failure = self.failure;
        var nested_failure: ?*value.HeapString = null;
        self.stack = .empty;
        self.frames = .empty;
        self.failure = null;
        defer {
            self.clearFrames();
            self.frames.deinit(self.allocator);
            self.stack.deinit(self.allocator);
            self.stack = saved_stack;
            self.frames = saved_frames;
            self.failure = nested_failure orelse saved_failure;
        }

        self.pushFrame(function_id, &.{}, &.{ receiver, other }) catch |err| switch (err) {
            error.RuntimeFault => {
                nested_failure = self.failure;
                return err;
            },
            else => return err,
        };
        while (self.frames.items.len != 0) {
            const completed = self.step() catch |err| switch (err) {
                error.RuntimeFault => {
                    nested_failure = self.failure;
                    return err;
                },
                else => return err,
            };
            if (completed) |result| return result;
        }
        return .{ .void = {} };
    }

    fn equal(self: *Vm, negate: bool) anyerror!void {
        const right = try self.pop();
        const left = try self.pop();
        try self.stack.append(self.allocator, .{ .boolean = value.Value.eql(left, right) != negate });
    }

    fn getLocal(self: *Vm, slot: u16) anyerror!void {
        const frame = &self.frames.items[self.frames.items.len - 1];
        if (slot >= frame.locals.len) {
            try self.fault("Runtime Error: локальная переменная вне границ фрейма", .{});
            return;
        }
        try self.stack.append(self.allocator, frame.locals[slot]);
    }

    fn setLocal(self: *Vm, slot: u16) anyerror!void {
        const runtime_value = try self.pop();
        const frame = &self.frames.items[self.frames.items.len - 1];
        if (slot >= frame.locals.len) {
            try self.fault("Runtime Error: локальная переменная вне границ фрейма", .{});
            return;
        }
        frame.locals[slot] = runtime_value;
    }

    fn jump(self: *Vm, target: usize) anyerror!void {
        const compiled = self.currentFunction() orelse return;
        if (target > compiled.instructions.items.len) {
            try self.fault("Runtime Error: переход вне границ инструкции", .{});
            return;
        }
        self.frames.items[self.frames.items.len - 1].ip = target;
    }

    fn jumpIfFalse(self: *Vm, target: usize) anyerror!void {
        const condition = try self.boolean(try self.pop());
        if (!condition) try self.jump(target);
    }

    fn call(self: *Vm, argument_count: u16) anyerror!void {
        const count: usize = argument_count;
        if (self.stack.items.len < count + 1) {
            try self.fault("Runtime Error: недостаточно аргументов функции", .{});
            return;
        }
        const function_index = self.stack.items.len - count - 1;
        const callee = self.stack.items[function_index];
        switch (callee) {
            .function_ref => |function_id| try self.pushFrame(function_id, &.{}, self.stack.items[function_index + 1 ..]),
            .closure => |closure| try self.pushFrame(closure.function_id, closure.captures, self.stack.items[function_index + 1 ..]),
            else => {
                try self.fault("Runtime Error: попытка вызвать не функцию", .{});
                return;
            },
        }
        self.stack.shrinkRetainingCapacity(function_index);
    }

    fn castInterface(self: *Vm, compiled: *const bytecode.Function, vtable_index: u16) anyerror!void {
        if (vtable_index >= compiled.constants.items.len) {
            try self.fault("Runtime Error: vtable интерфейса вне границ пула", .{});
            return;
        }
        const methods = switch (compiled.constants.items[vtable_index]) {
            .interface_vtable => |vtable| vtable,
            else => {
                try self.fault("Runtime Error: vtable интерфейса имеет неверный тип", .{});
                return;
            },
        };
        const receiver = try self.pop();
        switch (receiver) {
            .aggregate => {},
            else => {
                try self.fault("Runtime Error: в интерфейс можно привести только структуру или перечисление", .{});
                return;
            },
        }
        const interface = try self.heap.createInterface(receiver, methods);
        try self.stack.append(self.allocator, .{ .interface = interface });
    }

    fn callInterface(self: *Vm, call_info: anytype) anyerror!void {
        const argument_count: usize = call_info.argument_count;
        if (self.stack.items.len < argument_count + 1) {
            try self.fault("Runtime Error: недостаточно аргументов интерфейсного метода", .{});
            return;
        }
        const interface_index = self.stack.items.len - argument_count - 1;
        const interface = switch (self.stack.items[interface_index]) {
            .interface => |interface_value| interface_value,
            else => {
                try self.fault("Runtime Error: попытка вызвать интерфейсный метод у не-интерфейса", .{});
                return;
            },
        };
        if (call_info.method_index >= interface.methods.len) {
            try self.fault("Runtime Error: метод не найден в vtable интерфейса", .{});
            return;
        }
        self.stack.items[interface_index] = .{ .function_ref = interface.methods[call_info.method_index] };
        try self.stack.insert(self.allocator, interface_index + 1, interface.receiver);
        try self.call(@intCast(argument_count + 1));
    }

    fn spawn(self: *Vm, argument_count: u16) anyerror!void {
        const count: usize = argument_count;
        if (self.stack.items.len < count + 1) {
            try self.fault("Runtime Error: недостаточно аргументов процесса", .{});
            return;
        }
        const callee_index = self.stack.items.len - count - 1;
        const callee = self.stack.items[callee_index];
        const process = switch (callee) {
            .function_ref => |function_id| try self.createProcess(function_id, &.{}, self.stack.items[callee_index + 1 ..]),
            .closure => |closure| try self.createProcess(closure.function_id, closure.captures, self.stack.items[callee_index + 1 ..]),
            else => {
                try self.fault("Runtime Error: запусти ожидает функцию", .{});
                return;
            },
        };
        self.stack.shrinkRetainingCapacity(callee_index);
        try self.stack.append(self.allocator, .{ .process = process });
    }

    fn send(self: *Vm) anyerror!void {
        const message = try self.pop();
        const target = switch (try self.pop()) {
            .process => |process| process,
            else => {
                try self.fault("Runtime Error: отправить() ожидает Процесс(T) первым аргументом", .{});
                return;
            },
        };
        if (target.status == .ready) {
            try target.mailbox.append(self.allocator, message);
            if (!self.isProcessActive(target)) try self.runProcess(target);
        }
        try self.stack.append(self.allocator, .{ .void = {} });
    }

    fn receive(self: *Vm) anyerror!void {
        if (self.current_message) |message| {
            self.current_message = null;
            try self.stack.append(self.allocator, message);
            return;
        }
        const process = self.current_process orelse {
            try self.fault("Runtime Error: получить() вызвано вне процесса", .{});
            return;
        };
        if (process.mailbox.items.len == 0) {
            try self.fault("Runtime Error: получить() ожидает сообщение", .{});
            return;
        }
        const message = process.mailbox.orderedRemove(0);
        try self.stack.append(self.allocator, message);
    }

    fn observe(self: *Vm) anyerror!void {
        const target = switch (try self.pop()) {
            .process => |process| process,
            else => {
                try self.fault("Runtime Error: наблюдать() ожидает Процесс(T) первым аргументом", .{});
                return;
            },
        };
        const watcher = self.current_process orelse {
            try self.fault("Runtime Error: наблюдать() вызвано вне процесса", .{});
            return;
        };
        if (target.status == .ready) {
            try target.watchers.append(self.allocator, watcher);
        } else {
            const reason = try self.heap.formatString("процесс уже не существует", .{});
            try self.queueSignal(watcher, target.id, .{ .heap_string = reason });
        }
        try self.stack.append(self.allocator, .{ .void = {} });
    }

    fn getSignal(self: *Vm) anyerror!void {
        const process = self.current_process orelse {
            try self.fault("Runtime Error: получить_сигнал() вызвано вне процесса", .{});
            return;
        };
        if (process.signals.items.len == 0) {
            try self.fault("Runtime Error: нет доступных сигналов процесса", .{});
            return;
        }
        const signal = process.signals.orderedRemove(0);
        try self.stack.append(self.allocator, signal);
    }

    fn processId(self: *Vm) anyerror!void {
        const process = switch (try self.pop()) {
            .process => |value_process| value_process,
            else => {
                try self.fault("Runtime Error: номер() доступен только для Процесс(T)", .{});
                return;
            },
        };
        try self.stack.append(self.allocator, .{ .number = @floatFromInt(process.id) });
    }

    fn currentProcess(self: *Vm) anyerror!void {
        const process = self.current_process orelse {
            try self.fault("Runtime Error: себя() вызвано вне процесса", .{});
            return;
        };
        try self.stack.append(self.allocator, .{ .process = process });
    }

    fn killProcess(self: *Vm) anyerror!void {
        const target = switch (try self.pop()) {
            .process => |process| process,
            else => {
                try self.fault("Runtime Error: убить() ожидает Процесс(T) первым аргументом", .{});
                return;
            },
        };
        const current = self.current_process orelse {
            try self.fault("Runtime Error: убить() вызвано вне процесса", .{});
            return;
        };
        if (target == current) {
            try self.fault("Runtime Error: убить() нельзя применить к самому себе", .{});
            return;
        }
        if (target.id == 0) {
            try self.fault("Runtime Error: убить() нельзя применить к главному процессу", .{});
            return;
        }
        if (target.status == .ready) {
            const reason = try self.heap.formatString("процесс принудительно остановлен (убить())", .{});
            try self.terminateProcess(target, .{ .heap_string = reason });
        }
        try self.stack.append(self.allocator, .{ .void = {} });
    }

    fn linkProcess(self: *Vm) anyerror!void {
        const target = switch (try self.pop()) {
            .process => |process| process,
            else => {
                try self.fault("Runtime Error: связать() ожидает Процесс(T) первым аргументом", .{});
                return;
            },
        };
        const current = self.current_process orelse {
            try self.fault("Runtime Error: связать() вызвано вне процесса", .{});
            return;
        };
        if (current.id == 0) {
            try self.fault("Runtime Error: связать() нельзя вызвать из главного процесса", .{});
            return;
        }
        if (target.id == 0) {
            try self.fault("Runtime Error: связать() нельзя применить к главному процессу", .{});
            return;
        }
        if (target.status == .ready) {
            try current.links.append(self.allocator, target);
            try target.links.append(self.allocator, current);
        }
        try self.stack.append(self.allocator, .{ .void = {} });
    }

    fn createProcess(self: *Vm, function_id: bytecode.FunctionId, captures: []const value.Value, arguments: []const value.Value) !*value.Process {
        const owned_captures = try self.allocator.dupe(value.Value, captures);
        errdefer self.allocator.free(owned_captures);
        const owned_arguments = try self.allocator.dupe(value.Value, arguments);
        errdefer self.allocator.free(owned_arguments);
        const process = try self.allocator.create(value.Process);
        errdefer self.allocator.destroy(process);
        process.* = .{
            .id = self.next_process_id,
            .function_id = function_id,
            .captures = owned_captures,
            .arguments = owned_arguments,
        };
        try self.processes.append(self.allocator, process);
        self.next_process_id += 1;
        return process;
    }

    fn isProcessActive(self: *const Vm, process: *const value.Process) bool {
        for (self.active_processes.items) |active| {
            if (active == process) return true;
        }
        return false;
    }

    fn runProcess(self: *Vm, process: *value.Process) anyerror!void {
        if (process.status != .ready or process.mailbox.items.len == 0 or self.isProcessActive(process)) return;
        const message = process.mailbox.orderedRemove(0);
        const saved_stack = self.stack;
        const saved_frames = self.frames;
        const saved_failure = self.failure;
        const saved_process = self.current_process;
        const saved_message = self.current_message;
        self.stack = .empty;
        self.frames = .empty;
        self.failure = null;
        self.current_process = process;
        self.current_message = message;
        try self.active_processes.append(self.allocator, process);
        defer {
            _ = self.active_processes.pop();
            self.clearFrames();
            self.frames.deinit(self.allocator);
            self.stack.deinit(self.allocator);
            self.stack = saved_stack;
            self.frames = saved_frames;
            self.failure = saved_failure;
            self.current_process = saved_process;
            self.current_message = saved_message;
        }

        self.pushFrame(process.function_id, process.captures, process.arguments) catch |err| switch (err) {
            error.RuntimeFault => {
                try self.terminateFailedProcess(process);
                return;
            },
            else => return err,
        };
        while (self.frames.items.len != 0) {
            const completed = self.step() catch |err| switch (err) {
                error.RuntimeFault => {
                    try self.terminateFailedProcess(process);
                    return;
                },
                else => return err,
            };
            if (process.status != .ready) return;
            if (completed != null) {
                process.status = .completed;
                try self.notifyWatchers(process, null);
                return;
            }
        }
        process.status = .completed;
        try self.notifyWatchers(process, null);
    }

    fn terminateFailedProcess(self: *Vm, process: *value.Process) !void {
        const reason: value.Value = if (self.failure) |failure|
            .{ .heap_string = failure }
        else
            .{ .heap_string = try self.heap.formatString("неизвестная ошибка процесса", .{}) };
        try self.terminateProcess(process, reason);
    }

    fn terminateProcess(self: *Vm, process: *value.Process, reason: value.Value) !void {
        if (process.status != .ready) return;
        process.status = .failed;
        process.mailbox.clearRetainingCapacity();
        try self.notifyWatchers(process, reason);
        const reason_text = reason.stringBytes() orelse "неизвестная ошибка";
        const linked_reason = try self.heap.formatString("связанный процесс #{d} упал: {s}", .{ process.id, reason_text });
        for (process.links.items) |linked| try self.terminateProcess(linked, .{ .heap_string = linked_reason });
        process.links.clearRetainingCapacity();
    }

    fn notifyWatchers(self: *Vm, process: *value.Process, reason: ?value.Value) !void {
        for (process.watchers.items) |watcher| try self.queueSignal(watcher, process.id, reason);
        process.watchers.clearRetainingCapacity();
    }

    fn queueSignal(self: *Vm, watcher: *value.Process, process_id: u64, reason: ?value.Value) !void {
        const option_elements = try self.allocator.alloc(value.Value, if (reason == null) 0 else 1);
        if (reason) |failure| option_elements[0] = failure;
        const option = try self.heap.createAggregate(if (reason == null) "Опция.Нет" else "Опция.Есть", option_elements);
        const signal_elements = try self.allocator.alloc(value.Value, 2);
        signal_elements[0] = .{ .number = @floatFromInt(process_id) };
        signal_elements[1] = .{ .aggregate = option };
        const signal = try self.heap.createAggregate(null, signal_elements);
        try watcher.signals.append(self.allocator, .{ .aggregate = signal });
    }

    fn buildClosure(self: *Vm, closure: anytype) anyerror!void {
        const compiled = self.program.functionConst(closure.function_id) orelse {
            try self.fault("Runtime Error: неизвестная функция замыкания", .{});
            return;
        };
        if (closure.capture_count != compiled.capture_count) {
            try self.fault("Runtime Error: неверное количество захватов замыкания", .{});
            return;
        }
        const runtime_closure = try self.heap.createClosure(closure.function_id, try self.popValues(closure.capture_count));
        try self.stack.append(self.allocator, .{ .closure = runtime_closure });
    }

    fn buildAggregate(self: *Vm, name: ?[]const u8, count: u16) !void {
        const aggregate = try self.heap.createAggregate(name, try self.popValues(count));
        try self.stack.append(self.allocator, .{ .aggregate = aggregate });
    }

    fn buildStruct(self: *Vm, compiled: *const bytecode.Function, structure: anytype) anyerror!void {
        if (structure.name_constant >= compiled.constants.items.len) {
            try self.fault("Runtime Error: имя структуры вне константного пула", .{});
            return;
        }
        const name = switch (compiled.constants.items[structure.name_constant]) {
            .string => |string| string,
            else => {
                try self.fault("Runtime Error: имя структуры имеет неверный тип", .{});
                return;
            },
        };
        try self.buildAggregate(name, structure.field_count);
    }

    fn matchEnum(self: *Vm, compiled: *const bytecode.Function, name_constant: u16) anyerror!void {
        if (name_constant >= compiled.constants.items.len) {
            try self.fault("Runtime Error: имя варианта вне константного пула", .{});
            return;
        }
        const expected_name = switch (compiled.constants.items[name_constant]) {
            .string => |name| name,
            else => {
                try self.fault("Runtime Error: имя варианта имеет неверный тип", .{});
                return;
            },
        };
        const runtime_value = try self.pop();
        const aggregate = switch (runtime_value) {
            .aggregate => |aggregate_value| aggregate_value,
            else => {
                try self.fault("Runtime Error: сопоставление варианта ожидает перечисление", .{});
                return;
            },
        };
        const actual_name = aggregate.name orelse {
            try self.fault("Runtime Error: сопоставление варианта ожидает перечисление", .{});
            return;
        };
        try self.stack.append(self.allocator, .{ .boolean = std.mem.eql(u8, actual_name, expected_name) });
    }

    fn panic(self: *Vm) anyerror!void {
        const message = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: паника ожидает строку", .{});
            return;
        };
        try self.fault("Runtime Panic: {s}", .{message});
    }

    fn buildArray(self: *Vm, count: u16) !void {
        const array = try self.heap.createArray(try self.popValues(count));
        try self.stack.append(self.allocator, .{ .array = array });
    }

    fn arrayLength(self: *Vm) anyerror!void {
        const runtime_value = try self.pop();
        const array = switch (runtime_value) {
            .array => |array| array,
            else => {
                try self.fault("Runtime Error: длина доступна только для массива", .{});
                return;
            },
        };
        try self.stack.append(self.allocator, .{ .number = @floatFromInt(array.elements.len) });
    }

    fn stringLength(self: *Vm) anyerror!void {
        const string = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: длина доступна только для строки", .{});
            return;
        };
        const length = std.unicode.utf8CountCodepoints(string) catch {
            try self.fault("Runtime Error: строка содержит некорректный UTF-8", .{});
            return;
        };
        try self.stack.append(self.allocator, .{ .number = @floatFromInt(length) });
    }

    fn arrayGetOr(self: *Vm) anyerror!void {
        const fallback = try self.pop();
        const index = try self.pop();
        const runtime_value = try self.pop();
        const array = switch (runtime_value) {
            .array => |array| array,
            else => {
                try self.fault("Runtime Error: безопасное чтение доступно только для массива", .{});
                return;
            },
        };
        const offset = try self.arrayIndex(index);
        try self.stack.append(self.allocator, if (offset < array.elements.len) array.elements[offset] else fallback);
    }

    fn arrayContains(self: *Vm) anyerror!void {
        const sought = try self.pop();
        const runtime_value = try self.pop();
        const array = switch (runtime_value) {
            .array => |array| array,
            else => {
                try self.fault("Runtime Error: поиск значения доступен только для массива", .{});
                return;
            },
        };
        for (array.elements) |element| {
            if (!element.eql(sought)) continue;
            try self.stack.append(self.allocator, .{ .boolean = true });
            return;
        }
        try self.stack.append(self.allocator, .{ .boolean = false });
    }

    fn buildMap(self: *Vm, count: u16) !void {
        const values = try self.popValues(@as(usize, count) * 2);
        defer self.allocator.free(values);
        const map = try self.heap.createMap();
        for (0..count) |index| {
            try map.entries.append(self.allocator, .{
                .key = values[index * 2],
                .value = values[index * 2 + 1],
            });
        }
        try self.stack.append(self.allocator, .{ .map = map });
    }

    fn mapLength(self: *Vm) anyerror!void {
        const runtime_value = try self.pop();
        const map = switch (runtime_value) {
            .map => |map| map,
            else => {
                try self.fault("Runtime Error: длина доступна только для соответствия", .{});
                return;
            },
        };
        try self.stack.append(self.allocator, .{ .number = @floatFromInt(map.entries.items.len) });
    }

    fn mapGetOr(self: *Vm) anyerror!void {
        const fallback = try self.pop();
        const key = try self.pop();
        const runtime_value = try self.pop();
        const map = switch (runtime_value) {
            .map => |map| map,
            else => {
                try self.fault("Runtime Error: безопасное чтение доступно только для соответствия", .{});
                return;
            },
        };
        for (map.entries.items) |entry| {
            if (!entry.key.eql(key)) continue;
            try self.stack.append(self.allocator, entry.value);
            return;
        }
        try self.stack.append(self.allocator, fallback);
    }

    fn mapEntries(self: *Vm) anyerror!void {
        const runtime_value = try self.pop();
        const map = switch (runtime_value) {
            .map => |map| map,
            else => {
                try self.fault("Runtime Error: записи доступны только для соответствия", .{});
                return;
            },
        };
        const elements = try self.allocator.alloc(value.Value, map.entries.items.len);
        errdefer self.allocator.free(elements);
        for (map.entries.items, 0..) |entry, index| {
            const pair_elements = try self.allocator.alloc(value.Value, 2);
            pair_elements[0] = entry.key;
            pair_elements[1] = entry.value;
            const pair = try self.heap.createAggregate(null, pair_elements);
            elements[index] = .{ .aggregate = pair };
        }
        const array = try self.heap.createArray(elements);
        try self.stack.append(self.allocator, .{ .array = array });
    }

    fn arrayHasIndex(self: *Vm) anyerror!void {
        const index = try self.number(try self.pop());
        const runtime_value = try self.pop();
        const array = switch (runtime_value) {
            .array => |array| array,
            else => {
                try self.fault("Runtime Error: проверка индекса доступна только для массива", .{});
                return;
            },
        };
        const exists = index >= 0 and index == std.math.trunc(index) and index < @as(f64, @floatFromInt(array.elements.len));
        try self.stack.append(self.allocator, .{ .boolean = exists });
    }

    fn mapHasKey(self: *Vm) anyerror!void {
        const key = try self.pop();
        const runtime_value = try self.pop();
        const map = switch (runtime_value) {
            .map => |map| map,
            else => {
                try self.fault("Runtime Error: проверка ключа доступна только для соответствия", .{});
                return;
            },
        };
        for (map.entries.items) |entry| {
            if (!entry.key.eql(key)) continue;
            try self.stack.append(self.allocator, .{ .boolean = true });
            return;
        }
        try self.stack.append(self.allocator, .{ .boolean = false });
    }

    fn mapRemoveKey(self: *Vm) anyerror!void {
        const key = try self.pop();
        const runtime_value = try self.pop();
        const map = switch (runtime_value) {
            .map => |map| map,
            else => {
                try self.fault("Runtime Error: удаление доступно только для соответствия", .{});
                return;
            },
        };
        for (map.entries.items, 0..) |entry, index| {
            if (!entry.key.eql(key)) continue;
            _ = map.entries.orderedRemove(index);
            try self.stack.append(self.allocator, .{ .boolean = true });
            return;
        }
        try self.stack.append(self.allocator, .{ .boolean = false });
    }

    fn arrayAppend(self: *Vm) anyerror!void {
        const appended = try self.pop();
        const runtime_value = try self.pop();
        const array = switch (runtime_value) {
            .array => |array| array,
            else => {
                try self.fault("Runtime Error: добавление доступно только для массива", .{});
                return;
            },
        };
        const elements = try self.allocator.alloc(value.Value, array.elements.len + 1);
        errdefer self.allocator.free(elements);
        @memcpy(elements[0..array.elements.len], array.elements);
        elements[array.elements.len] = appended;
        self.allocator.free(array.elements);
        array.elements = elements;
        try self.stack.append(self.allocator, .{ .void = {} });
    }

    fn getIndex(self: *Vm) anyerror!void {
        const index = try self.pop();
        const object = try self.pop();
        switch (object) {
            .array => |array| {
                const offset = try self.arrayOffset(index, array.elements.len);
                try self.stack.append(self.allocator, array.elements[offset]);
            },
            .map => |map| {
                for (map.entries.items) |entry| {
                    if (entry.key.eql(index)) {
                        try self.stack.append(self.allocator, entry.value);
                        return;
                    }
                }
                try self.fault("Runtime Error: ключ отсутствует в соответствии", .{});
            },
            else => {
                const string = object.stringBytes() orelse {
                    try self.fault("Runtime Error: индексирование поддержано только для строки, массива и соответствия", .{});
                    return;
                };
                const character = try self.stringAt(string, index);
                const result = try self.heap.createString(try self.allocator.dupe(u8, character));
                try self.stack.append(self.allocator, .{ .heap_string = result });
            },
        }
    }

    fn stringAt(self: *Vm, string: []const u8, index: value.Value) anyerror![]const u8 {
        const target = try self.arrayIndex(index);
        var offset: usize = 0;
        var current: usize = 0;
        while (offset < string.len) {
            const width = std.unicode.utf8ByteSequenceLength(string[offset]) catch {
                try self.fault("Runtime Error: строка содержит некорректный UTF-8", .{});
                return "";
            };
            if (offset + width > string.len or std.unicode.utf8Decode(string[offset .. offset + width]) catch null == null) {
                try self.fault("Runtime Error: строка содержит некорректный UTF-8", .{});
                return "";
            }
            if (current == target) return string[offset .. offset + width];
            current += 1;
            offset += width;
        }
        try self.fault("Runtime Error: индекс строки вне границ", .{});
        return "";
    }

    fn setIndex(self: *Vm) anyerror!void {
        const replacement = try self.pop();
        const index = try self.pop();
        const object = try self.pop();
        switch (object) {
            .array => |array| {
                const offset = try self.arrayOffset(index, array.elements.len);
                array.elements[offset] = replacement;
            },
            .map => |map| {
                for (map.entries.items) |*entry| {
                    if (entry.key.eql(index)) {
                        entry.value = replacement;
                        return;
                    }
                }
                try map.entries.append(self.allocator, .{ .key = index, .value = replacement });
            },
            else => try self.fault("Runtime Error: индексирование поддержано только для массива и соответствия", .{}),
        }
    }

    fn getProperty(self: *Vm, field: u16) anyerror!void {
        const object = try self.pop();
        const aggregate = switch (object) {
            .aggregate => |aggregate| aggregate,
            else => {
                try self.fault("Runtime Error: доступ к полю поддержан только для структуры", .{});
                return;
            },
        };
        if (field >= aggregate.elements.len) {
            try self.fault("Runtime Error: поле структуры вне границ", .{});
            return;
        }
        try self.stack.append(self.allocator, aggregate.elements[field]);
    }

    fn setProperty(self: *Vm, field: u16) anyerror!void {
        const replacement = try self.pop();
        const object = try self.pop();
        const aggregate = switch (object) {
            .aggregate => |aggregate| aggregate,
            else => {
                try self.fault("Runtime Error: доступ к полю поддержан только для структуры", .{});
                return;
            },
        };
        if (field >= aggregate.elements.len) {
            try self.fault("Runtime Error: поле структуры вне границ", .{});
            return;
        }
        aggregate.elements[field] = replacement;
    }

    fn arrayOffset(self: *Vm, index: value.Value, length: usize) anyerror!usize {
        const offset = try self.arrayIndex(index);
        if (offset >= length) {
            try self.fault("Runtime Error: индекс массива вне границ", .{});
            return 0;
        }
        return offset;
    }

    fn arrayIndex(self: *Vm, index: value.Value) anyerror!usize {
        const index_number = try self.number(index);
        if (index_number < 0 or index_number != std.math.trunc(index_number)) {
            try self.fault("Runtime Error: индекс массива должен быть неотрицательным целым", .{});
            return 0;
        }
        return @intFromFloat(index_number);
    }

    fn currentFunction(self: *const Vm) ?*const bytecode.Function {
        if (self.frames.items.len == 0) return null;
        return self.program.functionConst(self.frames.items[self.frames.items.len - 1].function_id);
    }

    fn clearFrames(self: *Vm) void {
        while (self.frames.pop()) |frame| self.allocator.free(frame.locals);
    }

    fn clearProcesses(self: *Vm) void {
        while (self.processes.pop()) |process| {
            process.deinit(self.allocator);
            self.allocator.destroy(process);
        }
    }

    fn fault(self: *Vm, comptime format: []const u8, args: anytype) anyerror!void {
        self.failure = try self.heap.formatString(format, args);
        return error.RuntimeFault;
    }
};

test "VM collection retains stack and frame roots" {
    var program = bytecode.Program.init(std.testing.allocator);
    defer program.deinit();
    const function_id = try program.addFunction("старт", 0);
    program.function(function_id).?.local_count = 1;

    var vm = Vm.init(std.testing.allocator, &program);
    defer vm.deinit();
    const elements = try std.testing.allocator.alloc(value.Value, 0);
    const array = try vm.heap.createArray(elements);
    try vm.stack.append(std.testing.allocator, .{ .array = array });
    vm.collect();
    try std.testing.expectEqual(@as(usize, 1), vm.heap.objectCount());

    vm.stack.clearRetainingCapacity();
    try vm.pushFrame(function_id, &.{}, &.{});
    vm.frames.items[0].locals[0] = .{ .array = array };
    vm.collect();
    try std.testing.expectEqual(@as(usize, 1), vm.heap.objectCount());

    vm.clearFrames();
    vm.collect();
    try std.testing.expectEqual(@as(usize, 0), vm.heap.objectCount());
}

test "VM stores concatenated strings in the managed heap" {
    var program = bytecode.Program.init(std.testing.allocator);
    defer program.deinit();
    const function_id = try program.addFunction("строка", 0);
    const function = program.function(function_id).?;
    const first = try function.addConstant(std.testing.allocator, .{ .string = "Пано" });
    const second = try function.addConstant(std.testing.allocator, .{ .string = "с" });
    try function.emit(std.testing.allocator, .{ .constant = first });
    try function.emit(std.testing.allocator, .{ .constant = second });
    try function.emit(std.testing.allocator, .{ .add = {} });
    try function.emit(std.testing.allocator, .{ .return_value = {} });

    var vm = Vm.init(std.testing.allocator, &program);
    defer vm.deinit();
    const outcome = try vm.run(function_id, &.{});
    switch (outcome) {
        .success => |runtime_value| {
            try std.testing.expectEqualStrings("Панос", runtime_value.stringBytes().?);
            try std.testing.expectEqual(@as(usize, 1), vm.heap.objectCount());
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM executes generic functions" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ вернуть[T](значение: T) -> T\nзначение\nконец\nфунк старт() -> Строка\nвернуть(\"готово\")\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(1), &.{});
    switch (outcome) {
        .success => |runtime_value| try std.testing.expectEqualStrings("готово", runtime_value.stringBytes().?),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM constructs generic structures" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип Коробка[T] = структура\nзначение: T\nконец\nфунк старт() -> Строка\nпер коробка = Коробка(\"готово\")\nкоробка.значение\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(0), &.{});
    switch (outcome) {
        .success => |runtime_value| try std.testing.expectEqualStrings("готово", runtime_value.stringBytes().?),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM executes generic structure methods" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип Коробка[T] = структура\nзначение: T\nконец\nреализация Коробка\nфунк получить(это: Коробка) -> T\nэто.значение\nконец\nфунк обернуть[U](это: Коробка, значение: U) -> U\nзначение\nконец\nконец\nфунк старт() -> Строка\nпер коробка = Коробка(\"готово\")\nкоробка.получить() + коробка.обернуть(\"!\")\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(2), &.{});
    switch (outcome) {
        .success => |runtime_value| try std.testing.expectEqualStrings("готово!", runtime_value.stringBytes().?),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM dispatches generic structures through interfaces" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(
        std.testing.allocator,
        "тип Печатаемый = интерфейс\n" ++
            "функ вСтроку() -> Строка\n" ++
            "конец\n" ++
            "тип Коробка[T] = структура\n" ++
            "значение: T\n" ++
            "конец\n" ++
            "реализация Печатаемый для Коробка\n" ++
            "функ вСтроку(это: Коробка) -> Строка\n" ++
            "\"коробка\"\n" ++
            "конец\n" ++
            "конец\n" ++
            "функ показать(значение: Печатаемый) -> Строка\n" ++
            "значение.вСтроку()\n" ++
            "конец\n" ++
            "функ старт() -> Строка\n" ++
            "пер значение: Печатаемый = Коробка(\"готово\")\n" ++
            "показать(значение) + \": \" + показать(Коробка(\"ещё\"))\n" ++
            "конец",
        0,
    );
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(2), &.{});
    switch (outcome) {
        .success => |runtime_value| try std.testing.expectEqualStrings("коробка: коробка", runtime_value.stringBytes().?),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM constructs enum variants" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип Ответ = перечисление\nДа(Строка)\nконец\nтип Опция[T] = перечисление\nЕсть(T)\nНет()\nконец\nфунк ответ() -> Ответ\nОтвет.Да(\"да\")\nконец\nфунк опция() -> Опция(Строка)\nОпция.Есть(\"готово\")\nконец\nфунк пусто() -> Опция(Строка)\nОпция.Нет()\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const first_outcome = try vm.run(@enumFromInt(0), &.{});
    switch (first_outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .aggregate => |aggregate| {
                try std.testing.expectEqualStrings("Ответ.Да", aggregate.name.?);
                try std.testing.expectEqualStrings("да", aggregate.elements[0].stringBytes().?);
            },
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
    const second_outcome = try vm.run(@enumFromInt(1), &.{});
    switch (second_outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .aggregate => |aggregate| {
                try std.testing.expectEqualStrings("Опция.Есть", aggregate.name.?);
                try std.testing.expectEqualStrings("готово", aggregate.elements[0].stringBytes().?);
            },
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
    const third_outcome = try vm.run(@enumFromInt(2), &.{});
    switch (third_outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .aggregate => |aggregate| try std.testing.expectEqualStrings("Опция.Нет", aggregate.name.?),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM provides option and result from the prelude" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ старт() -> Строка\nпер опция: Опция(Строка) = Опция.Есть(\"готово\")\nпер результат: Результат(Строка, Строка) = Результат.Успех(\"готово\")\nвыбор опция\nЕсть(значение) -> выбор результат\nУспех(_) -> значение\nНеудача(_) -> \"ошибка\"\nконец\nНет -> \"пусто\"\nконец\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(0), &.{});
    switch (outcome) {
        .success => |runtime_value| try std.testing.expectEqualStrings("готово", runtime_value.stringBytes().?),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM executes safe prelude option and result methods" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ старт() -> Число\nпер нет: Опция(Число) = Опция.Нет()\nпер неудача: Результат(Число, Строка) = Результат.Неудача(\"нет\")\nесли нет.пусто() и не нет.есть() и нет.получить(4) == 4 и нет.запас(Опция.Есть(5)).получить(0) == 5 и неудача.ошибка() и не неудача.успех() и неудача.получить(6) == 6 и неудача.получить_ошибку(\"запас\") == \"нет\" и неудача.запас(Результат.Успех(7)).получить(0) == 7 тогда\n1\nиначе\n0\nконец\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(0), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .number => |number| try std.testing.expectEqual(@as(f64, 1), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM executes strict prelude option and result methods" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ старт() -> Число\nпер опция: Опция(Число) = Опция.Есть(2)\nпер результат: Результат(Число, Строка) = Результат.Неудача(\"нет\")\nопция.значение() + опция.ожидать(\"не будет\") + если результат.причина() == \"нет\" и результат.ожидать_ошибку(\"не будет\") == \"нет\" тогда\n6\nиначе\n0\nконец\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(0), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .number => |number| try std.testing.expectEqual(@as(f64, 10), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM reports a missing strict option value" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ старт() -> Число\nпер опция: Опция(Число) = Опция.Нет()\nопция.значение()\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(0), &.{});
    switch (outcome) {
        .runtime_error => |message| try std.testing.expectEqualStrings("Runtime Panic: нет значения", message),
        .success => return error.TestUnexpectedResult,
    }
}

test "VM eagerly evaluates fallback arguments of prelude methods" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ ошибка() -> Число\n1 / 0\nконец\nфунк старт() -> Число\nОпция.Есть(1).получить(ошибка())\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(1), &.{});
    switch (outcome) {
        .runtime_error => |message| try std.testing.expectEqualStrings("Runtime Error: деление на ноль", message),
        .success => return error.TestUnexpectedResult,
    }
}

test "VM transforms prelude option and result values" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ старт() -> Булево\nпер есть: Опция(Число) = Опция.Есть(1)\nпер нет: Опция(Число) = Опция.Нет()\nпер успех: Результат(Число, Строка) = Результат.Успех(1)\nпер ошибка: Результат(Число, Строка) = Результат.Неудача(\"нет\")\nесть.заменить_значение(\"да\").получить(\"нет\") == \"да\" и нет.результат_или(\"пусто\").получить_ошибку(\"нет\") == \"пусто\" и успех.заменить_значение(\"готово\").получить(\"нет\") == \"готово\" и ошибка.заменить_ошибку(2).получить_ошибку(0) == 2 и ошибка.ошибка_опция().получить(\"запас\") == \"нет\" и успех.заменить_значение(\"да\").опция().получить(\"нет\") == \"да\"\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(0), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .boolean => |boolean| try std.testing.expect(boolean),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM unwraps prelude option and result values" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ поднять_опцию(значение: Опция(Число)) -> Опция(Число)\nпер число = значение?\nОпция.Есть(число + 1)\nконец\nфунк поднять_результат(значение: Результат(Число, Строка)) -> Результат(Число, Строка)\nпер число = значение?\nРезультат.Успех(число + 1)\nконец\nфунк старт() -> Число\nподнять_опцию(Опция.Нет()).получить(7) + поднять_опцию(Опция.Есть(2)).получить(0) + поднять_результат(Результат.Неудача(\"нет\")).получить(8) + поднять_результат(Результат.Успех(3)).получить(0)\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(2), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .number => |number| try std.testing.expectEqual(@as(f64, 22), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM constructs error values for result failures" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ старт() -> Строка\nпер ошибка: Ошибка = Ошибка(\"фс\", \"нет файла\")\nпер результат: Результат(Число, Ошибка) = Результат.Неудача(ошибка)\nрезультат.получить_ошибку(Ошибка(\"нет\", \"запас\")).код + \": \" + ошибка.сообщение\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(0), &.{});
    switch (outcome) {
        .success => |runtime_value| try std.testing.expectEqualStrings("фс: нет файла", runtime_value.stringBytes().?),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM measures and indexes Unicode strings" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ старт() -> Булево\nпер строка = \"я\" + \"блоко\"\nдлина(строка) == 6 и строка[0] == \"я\" и строка[5] == \"о\"\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(0), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .boolean => |boolean| try std.testing.expect(boolean),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM matches generic enum variants" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип Ячейка[T] = перечисление\nНет()\nЕсть(T)\nконец\nфунк извлечь[T](ячейка: Ячейка(T), запас: T) -> T\nвыбор ячейка\nЕсть(значение) -> значение\nНет -> запас\nконец\nконец\nфунк старт() -> Строка\nизвлечь(Ячейка.Есть(\"готово\"), \"запас\")\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(1), &.{});
    switch (outcome) {
        .success => |runtime_value| try std.testing.expectEqualStrings("готово", runtime_value.stringBytes().?),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM matches literals and structure patterns" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(
        std.testing.allocator,
        "тип Точка = структура\n" ++
            "x: Число\n" ++
            "y: Число\n" ++
            "конец\n" ++
            "функ число(x: Число) -> Строка\n" ++
            "выбор x\n" ++
            "1 -> \"один\"\n" ++
            "2 -> \"два\"\n" ++
            "_ -> \"другое\"\n" ++
            "конец\n" ++
            "конец\n" ++
            "функ код(x: Строка) -> Число\n" ++
            "выбор x\n" ++
            "\"да\" -> 1\n" ++
            "остальное -> 0\n" ++
            "конец\n" ++
            "конец\n" ++
            "функ булево(x: Булево) -> Строка\n" ++
            "выбор x\n" ++
            "истина -> \"да\"\n" ++
            "ложь -> \"нет\"\n" ++
            "конец\n" ++
            "конец\n" ++
            "функ ось(точка: Точка) -> Число\n" ++
            "выбор точка\n" ++
            "Точка(0, y) -> y\n" ++
            "Точка(x, 0) -> x\n" ++
            "Точка(_, _) -> -1\n" ++
            "конец\n" ++
            "конец\n" ++
            "функ ось_именованно(точка: Точка) -> Число\n" ++
            "выбор точка\n" ++
            "Точка(y: 0) -> точка.x\n" ++
            "Точка(_, _) -> -1\n" ++
            "конец\n" ++
            "конец\n" ++
            "функ старт() -> Булево\n" ++
            "число(2) == \"два\" и код(\"нет\") == 0 и булево(ложь) == \"нет\" и ось(Точка(0, 7)) == 7 и ось_именованно(Точка(5, 0)) == 5\n" ++
            "конец",
        0,
    );
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(5), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .boolean => |matched| try std.testing.expect(matched),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM executes compiled calls and control flow" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ сложить(a: Число, b: Число) -> Число\na + b\nконец\nфунк старт() -> Число\nесли истина тогда\nсложить(2, 3)\nиначе\n0\nконец\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(1), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .number => |number| try std.testing.expectEqual(@as(f64, 5), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM types panic as Never in an unreachable branch" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ старт() -> Число\nесли истина тогда\n42\nиначе\nпаника(\"не должно выполниться\")\nконец\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(0), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM executes capture-free lambdas" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ применить(f: функ(Число) -> Число, x: Число) -> Число\nf(x)\nконец\nфунк старт() -> Число\nпер удвоить: функ(Число) -> Число = функ(значение)\nзначение * 2\nконец\nприменить(удвоить, 3)\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(1), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .number => |number| try std.testing.expectEqual(@as(f64, 6), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM executes closures with captured locals" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ старт() -> Число\nпер сдвиг = 2\nпер добавить: функ(Число) -> Число = функ(значение)\nзначение + сдвиг\nконец\nдобавить(3)\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(0), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .number => |number| try std.testing.expectEqual(@as(f64, 5), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM short-circuits logical operators" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ опасно() -> Булево\n1 / 0 > 0\nконец\nфунк проверить() -> Булево\nесли ложь и опасно() тогда\nложь\nиначе\nистина или опасно()\nконец\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(1), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .boolean => |boolean| try std.testing.expect(boolean),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM reports division by zero without crashing" {
    var program = bytecode.Program.init(std.testing.allocator);
    defer program.deinit();
    const function_id = try program.addFunction("ошибка", 0);
    const function = program.function(function_id).?;
    const one = try function.addConstant(std.testing.allocator, .{ .number = 1 });
    const zero = try function.addConstant(std.testing.allocator, .{ .number = 0 });
    try function.emit(std.testing.allocator, .{ .constant = one });
    try function.emit(std.testing.allocator, .{ .constant = zero });
    try function.emit(std.testing.allocator, .{ .divide = {} });
    try function.emit(std.testing.allocator, .{ .return_value = {} });

    var vm = Vm.init(std.testing.allocator, &program);
    defer vm.deinit();
    const outcome = try vm.run(function_id, &.{});
    switch (outcome) {
        .runtime_error => |message| try std.testing.expectEqualStrings("Runtime Error: деление на ноль", message),
        .success => return error.TestUnexpectedResult,
    }
}

test "VM guards interface calls against non-interface receivers" {
    var program = bytecode.Program.init(std.testing.allocator);
    defer program.deinit();
    const function_id = try program.addFunction("интерфейс", 0);
    const function = program.function(function_id).?;
    const receiver = try function.addConstant(std.testing.allocator, .{ .number = 1 });
    try function.emit(std.testing.allocator, .{ .constant = receiver });
    try function.emit(std.testing.allocator, .{ .call_interface = .{
        .method_index = 0,
        .argument_count = 0,
    } });
    try function.emit(std.testing.allocator, .{ .return_value = {} });

    var vm = Vm.init(std.testing.allocator, &program);
    defer vm.deinit();
    const outcome = try vm.run(function_id, &.{});
    switch (outcome) {
        .runtime_error => |message| try std.testing.expectEqualStrings("Runtime Error: попытка вызвать интерфейсный метод у не-интерфейса", message),
        .success => return error.TestUnexpectedResult,
    }
}

test "VM guards interface casts against primitive values" {
    var program = bytecode.Program.init(std.testing.allocator);
    defer program.deinit();
    const function_id = try program.addFunction("приведение", 0);
    const function = program.function(function_id).?;
    const receiver = try function.addConstant(std.testing.allocator, .{ .number = 1 });
    const vtable = try function.addConstant(std.testing.allocator, .{ .interface_vtable = &.{} });
    try function.emit(std.testing.allocator, .{ .constant = receiver });
    try function.emit(std.testing.allocator, .{ .cast_interface = vtable });
    try function.emit(std.testing.allocator, .{ .return_value = {} });

    var vm = Vm.init(std.testing.allocator, &program);
    defer vm.deinit();
    const outcome = try vm.run(function_id, &.{});
    switch (outcome) {
        .runtime_error => |message| try std.testing.expectEqualStrings("Runtime Error: в интерфейс можно привести только структуру или перечисление", message),
        .success => return error.TestUnexpectedResult,
    }
}

test "VM guards enum matches against non-enum values" {
    var program = bytecode.Program.init(std.testing.allocator);
    defer program.deinit();
    const function_id = try program.addFunction("выбор", 0);
    const function = program.function(function_id).?;
    const number = try function.addConstant(std.testing.allocator, .{ .number = 1 });
    const variant = try function.addConstant(std.testing.allocator, .{ .string = "Опция.Есть" });
    try function.emit(std.testing.allocator, .{ .constant = number });
    try function.emit(std.testing.allocator, .{ .match_enum = variant });
    try function.emit(std.testing.allocator, .{ .return_value = {} });

    var vm = Vm.init(std.testing.allocator, &program);
    defer vm.deinit();
    const outcome = try vm.run(function_id, &.{});
    switch (outcome) {
        .runtime_error => |message| try std.testing.expectEqualStrings("Runtime Error: сопоставление варианта ожидает перечисление", message),
        .success => return error.TestUnexpectedResult,
    }
}

test "VM guards panic against non-string values" {
    var program = bytecode.Program.init(std.testing.allocator);
    defer program.deinit();
    const function_id = try program.addFunction("паника", 0);
    const function = program.function(function_id).?;
    const number = try function.addConstant(std.testing.allocator, .{ .number = 1 });
    try function.emit(std.testing.allocator, .{ .constant = number });
    try function.emit(std.testing.allocator, .{ .panic = {} });
    try function.emit(std.testing.allocator, .{ .return_void = {} });

    var vm = Vm.init(std.testing.allocator, &program);
    defer vm.deinit();
    const outcome = try vm.run(function_id, &.{});
    switch (outcome) {
        .runtime_error => |message| try std.testing.expectEqualStrings("Runtime Error: паника ожидает строку", message),
        .success => return error.TestUnexpectedResult,
    }
}

test "VM guards array length against non-array values" {
    var program = bytecode.Program.init(std.testing.allocator);
    defer program.deinit();
    const function_id = try program.addFunction("длина", 0);
    const function = program.function(function_id).?;
    const number = try function.addConstant(std.testing.allocator, .{ .number = 1 });
    try function.emit(std.testing.allocator, .{ .constant = number });
    try function.emit(std.testing.allocator, .{ .array_length = {} });
    try function.emit(std.testing.allocator, .{ .return_value = {} });

    var vm = Vm.init(std.testing.allocator, &program);
    defer vm.deinit();
    const outcome = try vm.run(function_id, &.{});
    switch (outcome) {
        .runtime_error => |message| try std.testing.expectEqualStrings("Runtime Error: длина доступна только для массива", message),
        .success => return error.TestUnexpectedResult,
    }
}

test "VM guards string length against non-string values" {
    var program = bytecode.Program.init(std.testing.allocator);
    defer program.deinit();
    const function_id = try program.addFunction("длина", 0);
    const function = program.function(function_id).?;
    const number = try function.addConstant(std.testing.allocator, .{ .number = 1 });
    try function.emit(std.testing.allocator, .{ .constant = number });
    try function.emit(std.testing.allocator, .{ .string_length = {} });
    try function.emit(std.testing.allocator, .{ .return_value = {} });

    var vm = Vm.init(std.testing.allocator, &program);
    defer vm.deinit();
    const outcome = try vm.run(function_id, &.{});
    switch (outcome) {
        .runtime_error => |message| try std.testing.expectEqualStrings("Runtime Error: длина доступна только для строки", message),
        .success => return error.TestUnexpectedResult,
    }
}

test "VM guards map length against non-map values" {
    var program = bytecode.Program.init(std.testing.allocator);
    defer program.deinit();
    const function_id = try program.addFunction("длина", 0);
    const function = program.function(function_id).?;
    const number = try function.addConstant(std.testing.allocator, .{ .number = 1 });
    try function.emit(std.testing.allocator, .{ .constant = number });
    try function.emit(std.testing.allocator, .{ .map_length = {} });
    try function.emit(std.testing.allocator, .{ .return_value = {} });

    var vm = Vm.init(std.testing.allocator, &program);
    defer vm.deinit();
    const outcome = try vm.run(function_id, &.{});
    switch (outcome) {
        .runtime_error => |message| try std.testing.expectEqualStrings("Runtime Error: длина доступна только для соответствия", message),
        .success => return error.TestUnexpectedResult,
    }
}

test "VM guards collection presence checks" {
    var program = bytecode.Program.init(std.testing.allocator);
    defer program.deinit();
    const array_id = try program.addFunction("массив", 0);
    const array = program.function(array_id).?;
    const one = try array.addConstant(std.testing.allocator, .{ .number = 1 });
    try array.emit(std.testing.allocator, .{ .constant = one });
    try array.emit(std.testing.allocator, .{ .constant = one });
    try array.emit(std.testing.allocator, .{ .array_has_index = {} });
    try array.emit(std.testing.allocator, .{ .return_value = {} });

    var vm = Vm.init(std.testing.allocator, &program);
    defer vm.deinit();
    const outcome = try vm.run(array_id, &.{});
    switch (outcome) {
        .runtime_error => |message| try std.testing.expectEqualStrings("Runtime Error: проверка индекса доступна только для массива", message),
        .success => return error.TestUnexpectedResult,
    }
}

test "VM guards array append against non-array values" {
    var program = bytecode.Program.init(std.testing.allocator);
    defer program.deinit();
    const function_id = try program.addFunction("добавить", 0);
    const function = program.function(function_id).?;
    const one = try function.addConstant(std.testing.allocator, .{ .number = 1 });
    try function.emit(std.testing.allocator, .{ .constant = one });
    try function.emit(std.testing.allocator, .{ .constant = one });
    try function.emit(std.testing.allocator, .{ .array_append = {} });
    try function.emit(std.testing.allocator, .{ .return_value = {} });

    var vm = Vm.init(std.testing.allocator, &program);
    defer vm.deinit();
    const outcome = try vm.run(function_id, &.{});
    switch (outcome) {
        .runtime_error => |message| try std.testing.expectEqualStrings("Runtime Error: добавление доступно только для массива", message),
        .success => return error.TestUnexpectedResult,
    }
}

test "VM guards array containment against non-array values" {
    var program = bytecode.Program.init(std.testing.allocator);
    defer program.deinit();
    const function_id = try program.addFunction("содержит", 0);
    const function = program.function(function_id).?;
    const one = try function.addConstant(std.testing.allocator, .{ .number = 1 });
    try function.emit(std.testing.allocator, .{ .constant = one });
    try function.emit(std.testing.allocator, .{ .constant = one });
    try function.emit(std.testing.allocator, .{ .array_contains = {} });
    try function.emit(std.testing.allocator, .{ .return_value = {} });

    var vm = Vm.init(std.testing.allocator, &program);
    defer vm.deinit();
    const outcome = try vm.run(function_id, &.{});
    switch (outcome) {
        .runtime_error => |message| try std.testing.expectEqualStrings("Runtime Error: поиск значения доступен только для массива", message),
        .success => return error.TestUnexpectedResult,
    }
}

test "VM guards safe array reads against non-array values" {
    var program = bytecode.Program.init(std.testing.allocator);
    defer program.deinit();
    const function_id = try program.addFunction("получить", 0);
    const function = program.function(function_id).?;
    const one = try function.addConstant(std.testing.allocator, .{ .number = 1 });
    try function.emit(std.testing.allocator, .{ .constant = one });
    try function.emit(std.testing.allocator, .{ .constant = one });
    try function.emit(std.testing.allocator, .{ .constant = one });
    try function.emit(std.testing.allocator, .{ .array_get_or = {} });
    try function.emit(std.testing.allocator, .{ .return_value = {} });

    var vm = Vm.init(std.testing.allocator, &program);
    defer vm.deinit();
    const outcome = try vm.run(function_id, &.{});
    switch (outcome) {
        .runtime_error => |message| try std.testing.expectEqualStrings("Runtime Error: безопасное чтение доступно только для массива", message),
        .success => return error.TestUnexpectedResult,
    }
}

test "VM guards safe map reads against non-map values" {
    var program = bytecode.Program.init(std.testing.allocator);
    defer program.deinit();
    const function_id = try program.addFunction("получить", 0);
    const function = program.function(function_id).?;
    const one = try function.addConstant(std.testing.allocator, .{ .number = 1 });
    try function.emit(std.testing.allocator, .{ .constant = one });
    try function.emit(std.testing.allocator, .{ .constant = one });
    try function.emit(std.testing.allocator, .{ .constant = one });
    try function.emit(std.testing.allocator, .{ .map_get_or = {} });
    try function.emit(std.testing.allocator, .{ .return_value = {} });

    var vm = Vm.init(std.testing.allocator, &program);
    defer vm.deinit();
    const outcome = try vm.run(function_id, &.{});
    switch (outcome) {
        .runtime_error => |message| try std.testing.expectEqualStrings("Runtime Error: безопасное чтение доступно только для соответствия", message),
        .success => return error.TestUnexpectedResult,
    }
}

test "VM guards map entries against non-map values" {
    var program = bytecode.Program.init(std.testing.allocator);
    defer program.deinit();
    const function_id = try program.addFunction("записи", 0);
    const function = program.function(function_id).?;
    const one = try function.addConstant(std.testing.allocator, .{ .number = 1 });
    try function.emit(std.testing.allocator, .{ .constant = one });
    try function.emit(std.testing.allocator, .{ .map_entries = {} });
    try function.emit(std.testing.allocator, .{ .return_value = {} });

    var vm = Vm.init(std.testing.allocator, &program);
    defer vm.deinit();
    const outcome = try vm.run(function_id, &.{});
    switch (outcome) {
        .runtime_error => |message| try std.testing.expectEqualStrings("Runtime Error: записи доступны только для соответствия", message),
        .success => return error.TestUnexpectedResult,
    }
}

test "VM guards map deletion against non-map values" {
    var program = bytecode.Program.init(std.testing.allocator);
    defer program.deinit();
    const function_id = try program.addFunction("удалить", 0);
    const function = program.function(function_id).?;
    const one = try function.addConstant(std.testing.allocator, .{ .number = 1 });
    try function.emit(std.testing.allocator, .{ .constant = one });
    try function.emit(std.testing.allocator, .{ .constant = one });
    try function.emit(std.testing.allocator, .{ .map_remove_key = {} });
    try function.emit(std.testing.allocator, .{ .return_value = {} });

    var vm = Vm.init(std.testing.allocator, &program);
    defer vm.deinit();
    const outcome = try vm.run(function_id, &.{});
    switch (outcome) {
        .runtime_error => |message| try std.testing.expectEqualStrings("Runtime Error: удаление доступно только для соответствия", message),
        .success => return error.TestUnexpectedResult,
    }
}

test "VM guards closure capture metadata" {
    var program = bytecode.Program.init(std.testing.allocator);
    defer program.deinit();
    const main_id = try program.addFunction("старт", 0);
    const closure_id = try program.addFunction("лямбда", 0);
    const closure = program.function(closure_id).?;
    closure.capture_count = 1;
    closure.local_count = 1;
    try closure.emit(std.testing.allocator, .{ .return_void = {} });
    const main = program.function(main_id).?;
    try main.emit(std.testing.allocator, .{ .build_closure = .{ .function_id = closure_id, .capture_count = 0 } });
    try main.emit(std.testing.allocator, .{ .return_value = {} });

    var vm = Vm.init(std.testing.allocator, &program);
    defer vm.deinit();
    const outcome = try vm.run(main_id, &.{});
    switch (outcome) {
        .runtime_error => |message| try std.testing.expectEqualStrings("Runtime Error: неверное количество захватов замыкания", message),
        .success => return error.TestUnexpectedResult,
    }
}

test "VM executes structures and mutable collections" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип Точка = структура\nx: Число\nконец\nфунк получить() -> Число\nпер точка = Точка(1)\nточка.x = 2\nпер числа = массив(3)\nчисла[0] = 4\nпер цены = соответствие(\"итог\" = точка.x + числа[0])\nцены[\"итог\"]\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(0), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .number => |number| try std.testing.expectEqual(@as(f64, 6), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM executes collection length methods" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ длины() -> Целое\nпер числа = массив(1, 2, 3)\nпер цены = соответствие(\"a\" = 1, \"b\" = 2)\nчисла.длина() + цены.длина()\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(0), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .number => |number| try std.testing.expectEqual(@as(f64, 5), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM executes collection presence methods" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ проверить() -> Булево\nпер числа = массив(10)\nпер цены = соответствие(\"a\" = 1)\nчисла.есть(0) и не числа.есть(1) и цены.есть(\"a\") и не цены.есть(\"b\")\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(0), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .boolean => |boolean| try std.testing.expect(boolean),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM appends array elements" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ добавить() -> Целое\nпер числа = массив(1)\nчисла.добавить(2)\nчисла.длина() + числа[1]\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(0), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .number => |number| try std.testing.expectEqual(@as(f64, 4), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM searches array elements structurally" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ содержит() -> Булево\nпер числа = массив((1, \"a\"), (2, \"b\"))\nчисла.содержит((2, \"b\")) и не числа.содержит((3, \"c\"))\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(0), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .boolean => |boolean| try std.testing.expect(boolean),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM removes map keys" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ удалить() -> Булево\nпер цены = соответствие(\"a\" = 1, \"b\" = 2)\nцены.удалить(\"a\") и не цены.есть(\"a\") и не цены.удалить(\"a\") и цены.длина() == 1\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(0), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .boolean => |boolean| try std.testing.expect(boolean),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM reads collection values with fallbacks" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ получить() -> Число\nпер числа = массив(1, 2)\nпер цены = соответствие(\"a\" = 3)\nчисла.получить(5, 10) + цены.получить(\"b\", 20) + числа.получить(1, 0) + цены.получить(\"a\", 0)\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(0), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .number => |number| try std.testing.expectEqual(@as(f64, 35), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM iterates map entries with destructuring" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ сумма() -> Число\nпер цены = соответствие(\"a\" = 1, \"b\" = 2, \"c\" = 3)\nпер результат = 0\nдля (ключ, значение) в цены.записи() цикл\nесли ключ == \"b\" тогда\nпродолжить\nконец\nрезультат = результат + значение\nконец\nрезультат\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(0), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .number => |number| try std.testing.expectEqual(@as(f64, 4), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM executes tuple destructuring" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ сумма() -> Число\nпер (первое, второе, третье) = (1, 2, 3)\nпервое + второе + третье\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(0), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .number => |number| try std.testing.expectEqual(@as(f64, 6), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM reads tuple fields by numeric property" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ сложить() -> Число\nпер координаты = ((1, 2), (3, 4))\nкоординаты.1.0 + координаты.0.1\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(0), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .number => |number| try std.testing.expectEqual(@as(f64, 5), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM destructures structures by named fields" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип Точка = структура\nx: Число\ny: Число\nконец\nфунк число() -> Число\nпер точка = Точка(1, 2)\nпер Точка(y: y, x: x) = точка\nx * 10 + y\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(0), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .number => |number| try std.testing.expectEqual(@as(f64, 12), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM executes numeric ranges with continue and break" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ сумма() -> Целое\nпер итог: Целое = 0\nдля i = 1 по 5 цикл\nесли i == 2 тогда\nпродолжить\nконец\nесли i == 4 тогда\nпрервать\nконец\nитог = итог + i\nконец\nитог\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(0), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .number => |number| try std.testing.expectEqual(@as(f64, 4), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM executes array loops with continue and break" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ сумма() -> Число\nпер числа = массив(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)\nпер итог = 0\nпер посещено = 0\nдля число в числа цикл\nпосещено = посещено + 1\nесли посещено == 8 тогда\nпрервать\nконец\nесли число == 3 тогда\nпродолжить\nконец\nитог = итог + число\nконец\nитог\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(0), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .number => |number| try std.testing.expectEqual(@as(f64, 25), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM reports an array bounds error without crashing" {
    var program = bytecode.Program.init(std.testing.allocator);
    defer program.deinit();
    const function_id = try program.addFunction("граница", 0);
    const function = program.function(function_id).?;
    const zero = try function.addConstant(std.testing.allocator, .{ .number = 0 });
    try function.emit(std.testing.allocator, .{ .build_array = 0 });
    try function.emit(std.testing.allocator, .{ .constant = zero });
    try function.emit(std.testing.allocator, .{ .get_index = {} });
    try function.emit(std.testing.allocator, .{ .return_value = {} });

    var vm = Vm.init(std.testing.allocator, &program);
    defer vm.deinit();
    const outcome = try vm.run(function_id, &.{});
    switch (outcome) {
        .runtime_error => |message| try std.testing.expectEqualStrings("Runtime Error: индекс массива вне границ", message),
        .success => return error.TestUnexpectedResult,
    }
}

test "VM delivers process completion and failure signals" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    const source =
        \\тип Задача = перечисление
        \\    Выполнить
        \\конец
        \\функ спокойный() -> Пусто
        \\    выбор получить()
        \\        Задача.Выполнить -> 0
        \\    конец
        \\конец
        \\функ рабочий() -> Пусто
        \\    выбор получить()
        \\        Задача.Выполнить -> паника("не справился")
        \\    конец
        \\конец
        \\функ проверка() -> Булево
        \\    пер тихий: Процесс(Задача) = запусти спокойный()
        \\    наблюдать(тихий)
        \\    отправить(тихий, Задача.Выполнить)
        \\    пер (id1, причина1) = получить_сигнал()
        \\    пер штатно = выбор причина1
        \\        Нет -> id1 == тихий.номер()
        \\        Есть(_) -> ложь
        \\    конец
        \\    пер плохой: Процесс(Задача) = запусти рабочий()
        \\    наблюдать(плохой)
        \\    отправить(плохой, Задача.Выполнить)
        \\    пер (id2, причина2) = получить_сигнал()
        \\    пер авария = выбор причина2
        \\        Нет -> ложь
        \\        Есть(_) -> id2 == плохой.номер()
        \\    конец
        \\    штатно и авария
        \\конец
    ;
    var lexed = try lexer.tokenize(std.testing.allocator, source, 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(2), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .boolean => |result| try std.testing.expect(result),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM guards process sends against non-process values" {
    var program = bytecode.Program.init(std.testing.allocator);
    defer program.deinit();
    const function_id = try program.addFunction("отправить", 0);
    const function = program.function(function_id).?;
    const number = try function.addConstant(std.testing.allocator, .{ .number = 1 });
    try function.emit(std.testing.allocator, .{ .constant = number });
    try function.emit(std.testing.allocator, .{ .constant = number });
    try function.emit(std.testing.allocator, .{ .send = {} });
    try function.emit(std.testing.allocator, .{ .return_void = {} });

    var vm = Vm.init(std.testing.allocator, &program);
    defer vm.deinit();
    const outcome = try vm.run(function_id, &.{});
    switch (outcome) {
        .runtime_error => |message| try std.testing.expectEqualStrings("Runtime Error: отправить() ожидает Процесс(T) первым аргументом", message),
        .success => return error.TestUnexpectedResult,
    }
}

test "VM kills ready processes and reports a failure signal" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    const source =
        \\функ ждёт() -> Пусто
        \\    получить()
        \\конец
        \\функ проверка() -> Булево
        \\    пер p: Процесс(Число) = запусти ждёт()
        \\    наблюдать(p)
        \\    убить(p)
        \\    отправить(p, 1)
        \\    пер (id, причина) = получить_сигнал()
        \\    выбор причина
        \\        Нет -> ложь
        \\        Есть(_) -> id == p.номер()
        \\    конец
        \\конец
    ;
    var lexed = try lexer.tokenize(std.testing.allocator, source, 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(1), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .boolean => |result| try std.testing.expect(result),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM guards process kills against non-process values" {
    var program = bytecode.Program.init(std.testing.allocator);
    defer program.deinit();
    const function_id = try program.addFunction("убить", 0);
    const function = program.function(function_id).?;
    const number = try function.addConstant(std.testing.allocator, .{ .number = 1 });
    try function.emit(std.testing.allocator, .{ .constant = number });
    try function.emit(std.testing.allocator, .{ .kill_process = {} });
    try function.emit(std.testing.allocator, .{ .return_void = {} });

    var vm = Vm.init(std.testing.allocator, &program);
    defer vm.deinit();
    const outcome = try vm.run(function_id, &.{});
    switch (outcome) {
        .runtime_error => |message| try std.testing.expectEqualStrings("Runtime Error: убить() ожидает Процесс(T) первым аргументом", message),
        .success => return error.TestUnexpectedResult,
    }
}

test "VM cascades linked process failures" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    const source =
        \\функ падающий() -> Пусто
        \\    получить()
        \\    паника("сбой")
        \\конец
        \\функ связанный() -> Пусто
        \\    пер child: Процесс(Число) = запусти падающий()
        \\    связать(child)
        \\    отправить(child, 1)
        \\конец
        \\функ проверка() -> Булево
        \\    пер process: Процесс(Число) = запусти связанный()
        \\    наблюдать(process)
        \\    отправить(process, 1)
        \\    пер (id, причина) = получить_сигнал()
        \\    выбор причина
        \\        Нет -> ложь
        \\        Есть(_) -> id == process.номер()
        \\    конец
        \\конец
    ;
    var lexed = try lexer.tokenize(std.testing.allocator, source, 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(2), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .boolean => |result| try std.testing.expect(result),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM does not cascade linked process completion" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    const source =
        \\функ штатный() -> Пусто
        \\    получить()
        \\конец
        \\функ связанный() -> Пусто
        \\    пер child: Процесс(Число) = запусти штатный()
        \\    связать(child)
        \\    отправить(child, 1)
        \\конец
        \\функ проверка() -> Булево
        \\    пер process: Процесс(Число) = запусти связанный()
        \\    наблюдать(process)
        \\    отправить(process, 1)
        \\    пер (_, причина) = получить_сигнал()
        \\    выбор причина
        \\        Нет -> истина
        \\        Есть(_) -> ложь
        \\    конец
        \\конец
    ;
    var lexed = try lexer.tokenize(std.testing.allocator, source, 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(2), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .boolean => |result| try std.testing.expect(result),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM guards process links against non-process values" {
    var program = bytecode.Program.init(std.testing.allocator);
    defer program.deinit();
    const function_id = try program.addFunction("связать", 0);
    const function = program.function(function_id).?;
    const number = try function.addConstant(std.testing.allocator, .{ .number = 1 });
    try function.emit(std.testing.allocator, .{ .constant = number });
    try function.emit(std.testing.allocator, .{ .link_process = {} });
    try function.emit(std.testing.allocator, .{ .return_void = {} });

    var vm = Vm.init(std.testing.allocator, &program);
    defer vm.deinit();
    const outcome = try vm.run(function_id, &.{});
    switch (outcome) {
        .runtime_error => |message| try std.testing.expectEqualStrings("Runtime Error: связать() ожидает Процесс(T) первым аргументом", message),
        .success => return error.TestUnexpectedResult,
    }
}

test "VM compares bounded generic values through Comparable" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    const source =
        \\тип Точка = структура
        \\    x: Число
        \\конец
        \\реализация Сравниваемое для Точка
        \\    функ сравнить(это: Точка, другое: Точка) -> Число
        \\        это.x - другое.x
        \\    конец
        \\конец
        \\функ макс[T: Сравниваемое](a: T, b: T) -> T
        \\    если a > b тогда a иначе b конец
        \\конец
        \\функ проверить() -> Булево
        \\    пер максимум_чисел = макс(3, 7)
        \\    пер максимум_точек = макс(Точка(1), Точка(2))
        \\    максимум_чисел == 7 и максимум_точек.x == 2
        \\конец
    ;
    var lexed = try lexer.tokenize(std.testing.allocator, source, 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    try std.testing.expect(compiled.program.comparableMethod("Точка") != null);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(2), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .boolean => |result| try std.testing.expect(result),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM reorders named function arguments" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ вычесть(уменьшаемое: Число, вычитаемое: Число) -> Число\nуменьшаемое - вычитаемое\nконец\nфунк старт() -> Число\nвычесть(вычитаемое = 3, уменьшаемое = 10)\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(1), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .number => |number| try std.testing.expectEqual(@as(f64, 7), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM reorders named spawn arguments" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    const source =
        \\функ вычислить(ответ: Процесс(Число), уменьшаемое: Число, вычитаемое: Число) -> Пусто
        \\    отправить(ответ, уменьшаемое - вычитаемое)
        \\конец
        \\функ проверка() -> Число
        \\    пер ответ: Процесс(Число) = себя()
        \\    пер child: Процесс(Число) = запусти вычислить(вычитаемое = 3, ответ = ответ, уменьшаемое = 10)
        \\    отправить(child, 0)
        \\    получить()
        \\конец
    ;
    var lexed = try lexer.tokenize(std.testing.allocator, source, 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(1), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .number => |number| try std.testing.expectEqual(@as(f64, 7), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM partially destructures a named structure field" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип Точка = структура\nx: Число\ny: Число\nконец\nфунк получить_y() -> Число\nпер точка = Точка(1, 2)\nпер Точка(y: y) = точка\ny\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(0), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .number => |number| try std.testing.expectEqual(@as(f64, 2), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM returns the current process" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ номер_себя() -> Число\nсебя().номер()\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    var compiled = try compiler.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const outcome = try vm.run(@enumFromInt(0), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .number => |number| try std.testing.expectEqual(@as(f64, 0), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}
