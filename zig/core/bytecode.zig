const std = @import("std");
const ast = @import("ast.zig");

pub const FunctionId = enum(u32) { _ };

pub const invalid_function: FunctionId = @enumFromInt(std.math.maxInt(u32));

// Цель вызова `внешний` — `fn_ptr` резолвится один раз, во время resolve
// (`resolver.zig`'s `resolveForeignFunction`, через `std.DynLib`), и
// копируется сюда (владение ареной, не зависит от времени жизни
// `Resolution`), чтобы скомпилированная `Program` была полностью
// самодостаточной, как и все остальные варианты `Constant`. `0` означает,
// что resolver уже сообщил диагностику (библиотека/символ не найдены) —
// `vm.zig` трактует это как runtime panic, недостижимый, если программа
// прошла типизацию чисто.
pub const ForeignFunctionConstant = struct {
    fn_ptr: usize,
    // Имя C-символа сохраняется рядом с адресом только для диагностик и
    // опционального профиля FFI в VM. Это arena-owned строка Program, как
    // остальные строковые константы байткода.
    name: []const u8,
    param_kinds: []const ast.ForeignMarshalKind,
    // Параллельно `param_kinds` — пустой срез для любого параметра, не
    // являющегося `.struct_value`, и marshal kind полей `ff_структура` (в
    // порядке объявления) для `.struct_value`. Нужно в месте FFI-вызова VM,
    // чтобы построить libffi struct `ffi_type` (его массив `elements`) и
    // упаковать поля panos-структуры `Value` в сырые байты C ABI.
    param_struct_layouts: []const []const ast.ForeignMarshalKind,
    return_kind: ast.ForeignMarshalKind,
    // Та же форма, что и одна запись `param_struct_layouts` — пусто, если
    // не `return_kind == .struct_value`.
    return_struct_layout: []const ast.ForeignMarshalKind,
};

pub const Constant = union(enum) {
    void: void,
    number: f64,
    boolean: bool,
    string: []const u8,
    function_ref: FunctionId,
    interface_vtable: []const FunctionId,
    interface_vtables: []const []const FunctionId,
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
    await_task,
    select_wait,
    process_id,
    current_process,
    kill_process,
    link_process,
    set_mailbox_capacity,
    send_or,
    request_cancel,
    is_cancelled,
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
    time_sleep_submit,
    io_print,
    io_println,
    io_read_line,
    str_from_bytes,
    str_to_number,
    str_number_to_str,
    str_int_to_str,
    str_upper,
    str_lower,
    str_ends_with,
    str_starts_with,
    str_contains,
    str_find,
    str_replace,
    str_trim,
    str_split,
    str_join,
    str_slice,
    str_is_digit_or_letter,
    str_is_letter,
    str_is_digit,
    int_cast,
    to_display_string,
    array_slice,
    gzip_decompress_submit,
    syntax_structs,
    syntax_fields,
    syntax_imports,
    syntax_annotations,
    syntax_annotation_arg,
    syntax_field_annotations,
    syntax_field_annotation_arg,
    connection_read_submit,
    connection_read_line_submit,
    connection_write_submit,
    connection_close,
    url_encode,
    url_decode,
    http_request_submit,
    sql_open_submit,
    sql_exec_submit,
    sql_query_submit,
    sql_close,
    call_foreign,
    crypto_hmac_sha256_b64url,
    crypto_base64url_encode,
    crypto_base64url_decode,
    crypto_timing_safe_eq,
    // Неблокирующий I/O: submit-опкоды кладут задачу в воркер-пул и
    // возвращают управление сразу (не блокируют) — компилятор ВСЕГДА
    // эмитит await_async сразу после (compiler.zig, compileFilesystemBuiltin).
    // await_async — ОДНА инструкция на ВСЕ async-builtin'ы (результат
    // приходит из process.async_results, FIFO — порядок гарантирован тем,
    // что submit и await всегда эмитятся смежной парой).
    file_read_submit,
    file_write_submit,
    net_connect_submit,
    await_async,
    http_listen,
    http_accept_submit,
    http_request_method,
    http_request_path,
    http_request_body,
    http_request_header,
    http_request_respond,
    str_to_bytes,
    str_to_runes,
    str_from_runes,
    str_code_point,
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
        vtable_index: u16 = 0,
        argument_count: u16,
        // Резервный путь для значения, вошедшего в generic-область БЕЗ
        // Cast_Interface-обёртки (например, поле generic-типизированной
        // структуры, построенной снаружи и не прошедшее через известную
        // точку "оборачивания" — см. Vm.callInterface): если получатель на
        // стеке — сырой `.aggregate`, а не `.interface`, ищем метод НАПРЯМУЮ
        // по имени интерфейса/метода/структуры через
        // `Program.interfaceMethod`, вместо паники "не-интерфейс". Пустая
        // строка = нет имени (не должно происходить для реального
        // generic-bound вызова, но безопасный fallback на старый фейл).
        interface_name: []const u8 = "",
        method_name: []const u8 = "",
    },
    spawn: u16,
    send: void,
    receive: void,
    observe: void,
    get_signal: void,
    await_task: void,
    select_wait: void,
    process_id: void,
    current_process: void,
    kill_process: void,
    link_process: void,
    set_mailbox_capacity: void,
    send_or: void,
    request_cancel: void,
    is_cancelled: void,
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
    time_sleep_submit: void,
    io_print: void,
    io_println: void,
    io_read_line: void,
    str_from_bytes: void,
    str_to_number: void,
    str_number_to_str: void,
    str_int_to_str: void,
    str_upper: void,
    str_lower: void,
    str_ends_with: void,
    str_starts_with: void,
    str_contains: void,
    str_find: void,
    str_replace: void,
    str_trim: void,
    str_split: void,
    str_join: void,
    str_slice: void,
    str_is_digit_or_letter: void,
    str_is_letter: void,
    str_is_digit: void,
    int_cast: void,
    to_display_string: void,
    array_slice: void,
    gzip_decompress_submit: void,
    syntax_structs: void,
    syntax_fields: void,
    syntax_imports: void,
    syntax_annotations: void,
    syntax_annotation_arg: void,
    syntax_field_annotations: void,
    syntax_field_annotation_arg: void,
    connection_read_submit: void,
    connection_read_line_submit: void,
    connection_write_submit: void,
    connection_close: void,
    url_encode: void,
    url_decode: void,
    http_request_submit: void,
    sql_open_submit: void,
    sql_exec_submit: void,
    sql_query_submit: void,
    sql_close: void,
    // `constant_index` — слот пула констант с `ForeignFunctionConstant`
    // этого вызова; `argument_count` — сколько уже скомпилированных
    // значений-аргументов лежит на стеке под ним, та же конвенция, что и
    // у `call`.
    call_foreign: struct {
        constant_index: u16,
        argument_count: u16,
    },
    crypto_hmac_sha256_b64url: void,
    crypto_base64url_encode: void,
    crypto_base64url_decode: void,
    crypto_timing_safe_eq: void,
    file_read_submit: void,
    file_write_submit: void,
    net_connect_submit: void,
    await_async: void,
    http_listen: void,
    http_accept_submit: void,
    http_request_method: void,
    http_request_path: void,
    http_request_body: void,
    http_request_header: void,
    http_request_respond: void,
    str_to_bytes: void,
    str_to_runes: void,
    str_from_runes: void,
    str_code_point: void,
};

pub const Function = struct {
    name: []const u8,
    arity: u16,
    capture_count: u16 = 0,
    returns_value: bool = true,
    local_count: u16 = 0,
    // Скомпилирован из тела метода по умолчанию интерфейса (получатель
    // `это: Интерфейс (...)`) — `callInterface` в `vm.zig` передаёт для
    // таких методов ОБЁРНУТОЕ значение `.interface` как this-аргумент
    // (чтобы собственные вызовы `это.другой_метод()` внутри метода по
    // умолчанию тоже диспетчеризовались через vtable), в отличие от
    // обычного impl-метода, который получает СЫРОЕ базовое значение
    // (нужен настоящий доступ к полям конкретной структуры).
    is_default_interface_method: bool = false,
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

// Таблица диспетчеризации по имени, общая для двух не связанных между
// собой однометодных интерфейсов: `Сравниваемое` (операторам сравнения
// нужно знать, в RUNTIME — точное имя структуры значения известно только
// когда это уже реальный `Aggregate` в куче — объявлен ли у типа
// кастомный `реализация Сравниваемое`) и `Копируемое` (та же форма
// поиска, `отправить`/отправке сообщения нужно знать, запускать ли
// кастомное копирование при отправке, см. `send`/`deepCopyForSend` в
// `vm.zig`). Одна таблица, ключ — `interface_name`, вместо двух
// структурно идентичных `ArrayList` — `addComparableMethod`/
// `comparableMethod`/`addCopyableMethod`/`copyableMethod` ниже остаются
// тонкими обёртками с ИСХОДНЫМИ сигнатурами, так что `compiler.zig`'s
// `registerSingleMethodInterface` (вызывает их как указатели на функции)
// и точки вызова поиска в `vm.zig` не требуют изменений — чисто
// внутреннее объединение хранилища.
pub const SingleMethodInterface = struct {
    interface_name: []const u8,
    type_name: []const u8,
    function_id: FunctionId,
};

// Общая таблица (interface_name, method_name, type_name) -> FunctionId для
// ЛЮБОЙ `реализация Интерфейс для Т` (не только Сравниваемое/Копируемое,
// в отличие от `SingleMethodInterface` выше) — резервный путь диспетчеризации
// `call_interface`, когда получатель НЕ обёрнут в `.interface` (см.
// doc-комментарий поля `interface_name` у `call_interface` и
// `Vm.callInterface`).
pub const InterfaceMethod = struct {
    interface_name: []const u8,
    method_name: []const u8,
    type_name: []const u8,
    function_id: FunctionId,
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    functions: std.ArrayList(Function) = .empty,
    single_method_interfaces: std.ArrayList(SingleMethodInterface) = .empty,
    interface_methods: std.ArrayList(InterfaceMethod) = .empty,
    entry: FunctionId = invalid_function,

    pub fn init(allocator: std.mem.Allocator) Program {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Program) void {
        for (self.functions.items) |*compiled_function| compiled_function.deinit(self.allocator);
        self.single_method_interfaces.deinit(self.allocator);
        self.interface_methods.deinit(self.allocator);
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

    fn addSingleMethodInterfaceMethod(self: *Program, interface_name: []const u8, type_name: []const u8, function_id: FunctionId) !void {
        try self.single_method_interfaces.append(self.allocator, .{
            .interface_name = interface_name,
            .type_name = try self.copyString(type_name),
            .function_id = function_id,
        });
    }

    fn singleMethodInterfaceMethod(self: *const Program, interface_name: []const u8, type_name: []const u8) ?FunctionId {
        for (self.single_method_interfaces.items) |method| {
            if (std.mem.eql(u8, method.interface_name, interface_name) and std.mem.eql(u8, method.type_name, type_name)) return method.function_id;
        }
        const separator = std.mem.indexOfScalar(u8, type_name, '.') orelse return null;
        const owner = type_name[0..separator];
        for (self.single_method_interfaces.items) |method| {
            if (std.mem.eql(u8, method.interface_name, interface_name) and std.mem.eql(u8, method.type_name, owner)) return method.function_id;
        }
        return null;
    }

    pub fn addInterfaceMethod(self: *Program, interface_name: []const u8, method_name: []const u8, type_name: []const u8, function_id: FunctionId) !void {
        try self.interface_methods.append(self.allocator, .{
            .interface_name = try self.copyString(interface_name),
            .method_name = try self.copyString(method_name),
            .type_name = try self.copyString(type_name),
            .function_id = function_id,
        });
    }

    pub fn interfaceMethod(self: *const Program, interface_name: []const u8, method_name: []const u8, type_name: []const u8) ?FunctionId {
        for (self.interface_methods.items) |method| {
            if (std.mem.eql(u8, method.interface_name, interface_name) and std.mem.eql(u8, method.method_name, method_name) and std.mem.eql(u8, method.type_name, type_name)) return method.function_id;
        }
        const separator = std.mem.indexOfScalar(u8, type_name, '.') orelse return null;
        const owner = type_name[0..separator];
        for (self.interface_methods.items) |method| {
            if (std.mem.eql(u8, method.interface_name, interface_name) and std.mem.eql(u8, method.method_name, method_name) and std.mem.eql(u8, method.type_name, owner)) return method.function_id;
        }
        return null;
    }

    pub fn addComparableMethod(self: *Program, type_name: []const u8, function_id: FunctionId) !void {
        try self.addSingleMethodInterfaceMethod("Сравниваемое", type_name, function_id);
    }

    pub fn comparableMethod(self: *const Program, type_name: []const u8) ?FunctionId {
        return self.singleMethodInterfaceMethod("Сравниваемое", type_name);
    }

    pub fn addCopyableMethod(self: *Program, type_name: []const u8, function_id: FunctionId) !void {
        try self.addSingleMethodInterfaceMethod("Копируемое", type_name, function_id);
    }

    pub fn copyableMethod(self: *const Program, type_name: []const u8) ?FunctionId {
        return self.singleMethodInterfaceMethod("Копируемое", type_name);
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
