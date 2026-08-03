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
        self.heap.deinit();
        self.* = undefined;
    }

    pub fn run(self: *Vm, entry: bytecode.FunctionId, arguments: []const value.Value) !Execution {
        self.failure = null;
        self.stack.clearRetainingCapacity();
        self.clearFrames();
        self.collect();
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
            .pop => _ = try self.pop(),
            .call => |argument_count| try self.call(argument_count),
            .build_closure => |closure| try self.buildClosure(closure),
            .return_value => return self.finishFrame(try self.pop()),
            .return_void => return self.finishFrame(.{ .void = {} }),
            .build_tuple => |count| try self.buildAggregate(null, count),
            .build_struct => |structure| try self.buildStruct(compiled, structure),
            .build_array => |count| try self.buildArray(count),
            .array_length => try self.arrayLength(),
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
        const right = try self.number(try self.pop());
        const left = try self.number(try self.pop());
        const result = switch (comparison) {
            .less => left < right,
            .less_equal => left <= right,
            .greater => left > right,
            .greater_equal => left >= right,
        };
        try self.stack.append(self.allocator, .{ .boolean = result });
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
            else => try self.fault("Runtime Error: индексирование поддержано только для массива и соответствия", .{}),
        }
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

test "VM matches generic enum variants" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип Опция[T] = перечисление\nНет()\nЕсть(T)\nконец\nфунк извлечь[T](опция: Опция(T), запас: T) -> T\nвыбор опция\nОпция.Есть(значение) -> значение\nОпция.Нет() -> запас\nконец\nконец\nфунк старт() -> Строка\nизвлечь(Опция.Есть(\"готово\"), \"запас\")\nконец", 0);
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
