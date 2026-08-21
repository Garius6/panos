const std = @import("std");
const builtin = @import("builtin");
const bytecode = @import("bytecode.zig");
const gc = @import("gc.zig");
const target_policy = @import("target.zig");
const value = @import("value.zig");
// Названы не `ast`/`lexer`/`parser` — многие тесты ниже уже локально
// затеняют эти три имени собственными `@import(...)`; обычный импорт под
// очевидным именем на уровне модуля конфликтовал бы с каждым из них.
const ast_types = @import("ast.zig");
const syntax_lexer = @import("lexer.zig");
const syntax_parser = @import("parser.zig");
const sqlite3 = @import("sqlite3_bindings.zig");
const ffi = @import("ffi_bindings.zig");

pub const Execution = union(enum) {
    success: value.Value,
    runtime_error: []const u8,
};

// Состояние продолжения процесса живёт в value.Process (см. value.zig) —
// процесс можно приостановить посреди кадра и возобновить позже
// планировщиком round-robin; здесь просто локальный алиас, т.к. большая
// часть файла уже ссылается на это как на просто `Frame`.
const Frame = value.Frame;

// Результат одного шага step(). `.suspended` значит, что текущая
// инструкция не смогла завершиться (пустой mailbox/сигналы/async_results) и
// должна быть передиспетчеризована с ТОГО ЖЕ frame.ip на следующем такте
// планировщика — инструкции, способные приостанавливаться (получить,
// получить_сигнал, Await_Async), откатывают frame.ip на единицу назад перед
// возвратом этого значения, т.к. step() безусловно продвигает ip перед
// диспетчеризацией.
const StepOutcome = union(enum) {
    none,
    completed: value.Value,
    suspended,
};

// libffi описывает сигнатуру вызова (`ffi_cif`) и layout структур отдельно
// от самих значений аргументов. И то, и другое неизменно для конкретной
// bytecode-константы `внешний`-функции, поэтому готовим один раз и храним в
// VM. Особенно важно для графических циклов: до кэша каждый DrawCube заново
// выделял несколько буферов, строил ffi_type и вызывал ffi_prep_cif.
const OwnedForeignStructType = struct {
    ptr: *ffi.FfiType,
    field_count: usize,
};

const ForeignCallMetric = struct {
    calls: u64 = 0,
    total_ns: u64 = 0,
    native_call_ns: u64 = 0,
    cache_misses: u64 = 0,
};

// Zig 0.16 маршрутизирует часы через std.Io, но держать объект Io.Threaded
// в каждой VM установило бы общесистемные обработчики сигналов ради
// опционального профайлера. Вместо этого — прямые монотонные часы платформы.
fn foreignProfileNowNanoseconds() u64 {
    if (comptime builtin.target.os.tag == .freestanding) {
        return 0;
    } else if (comptime builtin.target.os.tag == .windows) {
        const windows = std.os.windows;
        var frequency_raw: windows.LARGE_INTEGER = undefined;
        if (!windows.ntdll.RtlQueryPerformanceFrequency(&frequency_raw).toBool()) return 0;
        const frequency: u64 = @intCast(frequency_raw);
        if (frequency == 0) return 0;
        var counter_raw: windows.LARGE_INTEGER = undefined;
        if (!windows.ntdll.RtlQueryPerformanceCounter(&counter_raw).toBool()) return 0;
        const counter: u64 = @intCast(counter_raw);
        return @intCast((@as(u128, counter) * std.time.ns_per_s) / frequency);
    } else {
        const clock_id: std.posix.clockid_t = switch (builtin.target.os.tag) {
            .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => std.posix.CLOCK.UPTIME_RAW,
            else => std.posix.CLOCK.MONOTONIC,
        };
        var timestamp: std.posix.timespec = undefined;
        if (std.posix.errno(std.posix.system.clock_gettime(clock_id, &timestamp)) != .SUCCESS) return 0;
        const seconds: u64 = @intCast(timestamp.sec);
        const nanoseconds: u64 = @intCast(timestamp.nsec);
        return seconds * std.time.ns_per_s + nanoseconds;
    }
}

const PreparedForeignCall = struct {
    cif: ffi.FfiCif = undefined,
    arg_types: ?[]?*ffi.FfiType = null,
    return_type: ?*ffi.FfiType = null,
    owned_struct_types: std.ArrayList(OwnedForeignStructType) = .empty,
    param_struct_offsets: ?[]?[]usize = null,
    return_struct_offsets: ?[]usize = null,
    cell_offsets: ?[]usize = null,
    total_argument_cells: usize = 0,
    argument_storage: ?[]u64 = null,
    argument_values: ?[]?*anyopaque = null,
    return_storage: ?[]u64 = null,

    fn deinit(self: *PreparedForeignCall, allocator: std.mem.Allocator) void {
        if (self.return_storage) |storage| allocator.free(storage);
        if (self.argument_values) |values| allocator.free(values);
        if (self.argument_storage) |storage| allocator.free(storage);
        if (self.cell_offsets) |offsets| allocator.free(offsets);
        if (self.return_struct_offsets) |offsets| allocator.free(offsets);
        if (self.param_struct_offsets) |offsets| {
            for (offsets) |maybe_offsets| if (maybe_offsets) |fields| allocator.free(fields);
            allocator.free(offsets);
        }
        for (self.owned_struct_types.items) |entry| {
            allocator.free(entry.ptr.elements.?[0 .. entry.field_count + 1]);
            allocator.destroy(entry.ptr);
        }
        self.owned_struct_types.deinit(allocator);
        if (self.arg_types) |types| allocator.free(types);
    }
};

// Неблокирующий I/O. Payload — ТОЛЬКО плоские данные (никогда Value/GC-
// указатели) — воркер-поток никогда не трогает vm.heap (не потокобезопасен,
// см. gc.zig). content/err_message выделены на std.heap.page_allocator
// (см. AsyncQueue ниже), не на Vm.allocator — освобождаются сразу после
// копирования в GC-строку на главном потоке (deliverAsyncResult).
const HttpHeaderPair = struct { name: []u8, value: []u8 };

const HttpRequestResult = struct {
    status: u16,
    headers: []HttpHeaderPair,
    body: []u8,
};

const AsyncPayload = union(enum) {
    file_read: struct { content: ?[]u8, err_message: ?[]u8 },
    gzip_decompress: struct { content: ?[]u8, err_message: ?[]u8 },
    file_write: struct { bytes_written: usize, err_message: ?[]u8 },
    net_connect: struct { stream: ?std.Io.net.Stream, err_message: ?[]u8 },
    http_request: struct { result: ?HttpRequestResult, err_message: ?[]u8 },
    // `connection` закреплён (gc_pinned) на всё время полёта (см.
    // submitConnectionRead), поэтому его безопасно идентифицировать здесь по
    // сырому указателю; воркер никогда не разыменовывает его GC-заголовок,
    // только переданную ему копию значения `stream`.
    connection_read: struct { connection: *value.Connection, content: ?[]u8, err_message: ?[]u8 },
    connection_write: struct { connection: *value.Connection, bytes_written: usize, err_message: ?[]u8 },
    // `new_pending` заполнено ВСЕГДА (даже при ошибке) — всё, что воркер
    // накопил, но ещё не превратил в строку, должно быть записано обратно в
    // `connection.pending` при доставке, чтобы повтор `.получить_строку()`
    // после временной ошибки не терял уже буферизованные байты.
    connection_read_line: struct { connection: *value.Connection, line: ?[]u8, new_pending: []const u8, err_message: ?[]u8 },
    file_handle_read: struct { handle: *value.FileHandle, content: ?[]u8, new_offset: usize, err_message: ?[]u8 },
    file_handle_write: struct { handle: *value.FileHandle, bytes_written: usize, new_offset: usize, err_message: ?[]u8 },
    sql_open: struct { db: ?*sqlite3.sqlite3, err_message: ?[]u8 },
    sql_exec: struct { connection: *value.SqlConnection, rows_affected: i64, err_message: ?[]u8 },
    // `column_names`/`rows` — позиционные, не именованные по каждой строке.
    // Каждая строка — `?[]u8` на колонку: null = SQL NULL (вообще
    // исключается из итогового `Соответствие`, как и в старом синхронном
    // варианте).
    sql_query: struct { connection: *value.SqlConnection, column_names: [][]u8, rows: [][]?[]u8, err_message: ?[]u8 },
    // `listener` закрепляется ОДИН РАЗ на каждый accept в полёте (см.
    // submitHttpAccept); `Heap.pin`/`unpin` уже поддерживают несколько
    // одновременных закреплений одного значения — в отличие от единственного
    // флага `in_flight` у Connection/FileHandle/SqlConnection.
    http_accept: struct { listener: *value.Listener, stream: ?std.Io.net.Stream, method: ?[]u8, path: ?[]u8, body: ?[]u8, headers: []HttpHeaderPair, err_message: ?[]u8 },
    time_sleep: struct { millis: f64 },
};

const AsyncCompletion = struct {
    target_id: u64,
    payload: AsyncPayload,
};

fn freeAsyncPayload(payload: AsyncPayload) void {
    switch (payload) {
        .file_read => |data| {
            if (data.content) |bytes| std.heap.page_allocator.free(bytes);
            if (data.err_message) |message| std.heap.page_allocator.free(message);
        },
        .gzip_decompress => |data| {
            if (data.content) |bytes| std.heap.page_allocator.free(bytes);
            if (data.err_message) |message| std.heap.page_allocator.free(message);
        },
        .file_write => |data| {
            if (data.err_message) |message| std.heap.page_allocator.free(message);
        },
        .net_connect => |data| {
            if (data.err_message) |message| std.heap.page_allocator.free(message);
        },
        .http_request => |data| {
            if (data.result) |result| {
                for (result.headers) |header| {
                    std.heap.page_allocator.free(header.name);
                    std.heap.page_allocator.free(header.value);
                }
                std.heap.page_allocator.free(result.headers);
                std.heap.page_allocator.free(result.body);
            }
            if (data.err_message) |message| std.heap.page_allocator.free(message);
        },
        .connection_read => |data| {
            if (data.content) |bytes| std.heap.page_allocator.free(bytes);
            if (data.err_message) |message| std.heap.page_allocator.free(message);
        },
        .connection_write => |data| {
            if (data.err_message) |message| std.heap.page_allocator.free(message);
        },
        .file_handle_read => |data| {
            if (data.content) |bytes| std.heap.page_allocator.free(bytes);
            if (data.err_message) |message| std.heap.page_allocator.free(message);
        },
        .file_handle_write => |data| {
            if (data.err_message) |message| std.heap.page_allocator.free(message);
        },
        .connection_read_line => |data| {
            if (data.line) |bytes| std.heap.page_allocator.free(bytes);
            std.heap.page_allocator.free(data.new_pending);
            if (data.err_message) |message| std.heap.page_allocator.free(message);
        },
        .sql_open => |data| {
            if (data.err_message) |message| std.heap.page_allocator.free(message);
        },
        .sql_exec => |data| {
            if (data.err_message) |message| std.heap.page_allocator.free(message);
        },
        .sql_query => |data| {
            for (data.column_names) |name| std.heap.page_allocator.free(name);
            std.heap.page_allocator.free(data.column_names);
            for (data.rows) |row| {
                for (row) |cell| if (cell) |bytes| std.heap.page_allocator.free(bytes);
                std.heap.page_allocator.free(row);
            }
            std.heap.page_allocator.free(data.rows);
            if (data.err_message) |message| std.heap.page_allocator.free(message);
        },
        .http_accept => |data| {
            if (data.method) |bytes| std.heap.page_allocator.free(bytes);
            if (data.path) |bytes| std.heap.page_allocator.free(bytes);
            if (data.body) |bytes| std.heap.page_allocator.free(bytes);
            for (data.headers) |header| {
                std.heap.page_allocator.free(header.name);
                std.heap.page_allocator.free(header.value);
            }
            std.heap.page_allocator.free(data.headers);
            if (data.err_message) |message| std.heap.page_allocator.free(message);
        },
        .time_sleep => {},
    }
}

// Живёт ЦЕЛИКОМ на std.heap.page_allocator — не на Vm.allocator, который
// может быть (и в панос-CLI является) не потокобезопасным bump/arena-
// аллокатором. Воркер-потоки и главный поток никогда не должны делить один
// неатомарный аллокатор. outstanding — число задач, отправленных в пул, но
// ещё не доложивших результат push()'ом, нужен для различения "никто не
// готов, но I/O в полёте" (настоящий idle-wait) от "дедлок" в run_scheduler.
// Zig 0.16 перенёс Mutex/Condition с `std.Thread` на `std.Io` (`lock`/
// `wait` теперь принимают handle `Io`, маршрутизируется через
// `io.futexWait`/`futexWake`) — голого OS-мьютекса без такого handle больше
// не существует. Каждый метод ниже создаёт одноразовый `std.Io.Threaded`
// только чтобы получить этот handle; сам futex ключуется АДРЕСОМ общего
// атомика, а не тем, какой именно экземпляр `Threaded` сделал вызов —
// поэтому свежий экземпляр на каждый вызов (хоть с главного потока, хоть с
// воркера) всё равно корректно синхронизируется через одно и то же
// состояние `Mutex`/`Condition`. Тот же паттерн одноразового `Io` на вызов
// используется везде в этом файле для реального I/O. `lock`/`wait`
// возвращают `Cancelable!void`, но одноразовый, никогда не отменяемый
// `Threaded` не может фактически сообщить об отмене.
const AsyncQueue = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    items: std.ArrayList(AsyncCompletion) = .empty,
    outstanding: usize = 0,

    fn beginSubmit(self: *AsyncQueue) void {
        var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        self.mutex.lock(io) catch unreachable;
        defer self.mutex.unlock(io);
        self.outstanding += 1;
    }

    fn push(self: *AsyncQueue, completion: AsyncCompletion) void {
        var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        self.mutex.lock(io) catch unreachable;
        defer self.mutex.unlock(io);
        self.items.append(std.heap.page_allocator, completion) catch @panic("OOM: очередь завершений async I/O");
        self.outstanding -= 1;
        self.condition.signal(io);
    }

    // Эти четыре вызываются БЕЗУСЛОВНО из run()/run_scheduler для
    // каждой цели (в отличие от beginSubmit/push, которые достижимы только
    // через submitFileRead/submitFileWrite за собственными freestanding
    // `if`/`else` в fileReadSubmit/fileWriteSubmit, здесь нет отдельной
    // проверки на каждом месте вызова). Настоящий `if`/`else` здесь нужен,
    // чтобы сборка `browser` под wasm32-freestanding никогда не резолвила
    // `std.Io.Threaded` (его `RandomFile` тянет `posix.system.getrandom`,
    // отсутствующий на freestanding) — outstanding/items там всегда 0, т.к.
    // на этой цели ни одна async-задача никогда не отправляется.
    fn drain(self: *AsyncQueue, out: *std.ArrayList(AsyncCompletion)) void {
        if (comptime builtin.target.os.tag == .freestanding) {
            return;
        } else {
            var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            self.mutex.lock(io) catch unreachable;
            defer self.mutex.unlock(io);
            out.appendSlice(std.heap.page_allocator, self.items.items) catch @panic("OOM: слив очереди завершений async I/O");
            self.items.clearRetainingCapacity();
        }
    }

    fn hasPending(self: *AsyncQueue) bool {
        if (comptime builtin.target.os.tag == .freestanding) {
            return false;
        } else {
            var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            self.mutex.lock(io) catch unreachable;
            defer self.mutex.unlock(io);
            return self.outstanding > 0 or self.items.items.len > 0;
        }
    }

    // Блокируется (без busy-spin) до хотя бы ОДНОГО результата в очереди —
    // вызывается из run_scheduler ТОЛЬКО когда ни один процесс не готов и
    // hasPending() уже подтвердил, что есть что ждать.
    fn waitForOne(self: *AsyncQueue) void {
        if (comptime builtin.target.os.tag == .freestanding) {
            return;
        } else {
            var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            self.mutex.lock(io) catch unreachable;
            defer self.mutex.unlock(io);
            while (self.items.items.len == 0 and self.outstanding > 0) {
                self.condition.wait(io, &self.mutex) catch unreachable;
            }
        }
    }

    // Аналог Odin's thread.pool_join — блокируется, пока ВСЕ отправленные
    // задачи не доложат результат. Вызывается перед выходом из
    // run_scheduler (программа завершается немедленно при завершении
    // корневого процесса — недоставленные результаты для осиротевших
    // процессов просто остаются в items и утекают на page_allocator до
    // конца процесса, тот же trade-off, что у Odin).
    fn joinAll(self: *AsyncQueue) void {
        if (comptime builtin.target.os.tag == .freestanding) {
            return;
        } else {
            var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            self.mutex.lock(io) catch unreachable;
            defer self.mutex.unlock(io);
            while (self.outstanding > 0) {
                self.condition.wait(io, &self.mutex) catch unreachable;
            }
        }
    }
};

fn submitFileRead(vm: *Vm, path: []const u8, target_id: u64) void {
    vm.async_queue.beginSubmit();
    const owned_path = std.heap.page_allocator.dupe(u8, path) catch @panic("OOM: путь для async фс.прочитать");
    const Job = struct {
        queue: *AsyncQueue,
        target_id: u64,
        path: []u8,

        fn run(job: @This()) void {
            var io = std.Io.Threaded.init(std.heap.page_allocator, .{});
            defer io.deinit();
            const bytes = std.Io.Dir.cwd().readFileAlloc(io.io(), job.path, std.heap.page_allocator, .unlimited);
            std.heap.page_allocator.free(job.path);
            const payload: AsyncPayload = if (bytes) |content|
                .{ .file_read = .{ .content = content, .err_message = null } }
            else |err|
                .{ .file_read = .{
                    .content = null,
                    .err_message = std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{@errorName(err)}) catch @panic("OOM"),
                } };
            job.queue.push(.{ .target_id = job.target_id, .payload = payload });
        }
    };
    const thread = std.Thread.spawn(.{}, Job.run, .{Job{ .queue = &vm.async_queue, .target_id = target_id, .path = owned_path }}) catch @panic("не удалось запустить фоновый поток фс.прочитать");
    thread.detach();
}

fn submitTimeSleep(vm: *Vm, millis: f64, target_id: u64) void {
    vm.async_queue.beginSubmit();
    const Job = struct {
        queue: *AsyncQueue,
        target_id: u64,
        millis: f64,

        fn run(job: @This()) void {
            const clamped: i64 = if (job.millis > 0) @intFromFloat(job.millis) else 0;
            var io: std.Io.Threaded = .init(std.heap.page_allocator, .{});
            defer io.deinit();
            std.Io.sleep(io.io(), .fromMilliseconds(clamped), .awake) catch {};
            job.queue.push(.{ .target_id = job.target_id, .payload = .{ .time_sleep = .{ .millis = job.millis } } });
        }
    };
    const thread = std.Thread.spawn(.{}, Job.run, .{Job{ .queue = &vm.async_queue, .target_id = target_id, .millis = millis }}) catch @panic("не удалось запустить фоновый поток время.спать_мс");
    thread.detach();
}

fn submitGzipDecompress(vm: *Vm, data: []const u8, target_id: u64) void {
    vm.async_queue.beginSubmit();
    const owned_data = std.heap.page_allocator.dupe(u8, data) catch @panic("OOM: данные для async сжатие.разжать_gzip");
    const Job = struct {
        queue: *AsyncQueue,
        target_id: u64,
        data: []u8,

        fn run(job: @This()) void {
            var input: std.Io.Reader = .fixed(job.data);
            var decompress: std.compress.flate.Decompress = .init(&input, .gzip, &.{});
            var allocating: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
            defer allocating.deinit();
            const payload: AsyncPayload = blk: {
                _ = decompress.reader.streamRemaining(&allocating.writer) catch {
                    const message = decompress.err orelse error.ReadFailed;
                    break :blk .{ .gzip_decompress = .{
                        .content = null,
                        .err_message = std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{@errorName(message)}) catch @panic("OOM"),
                    } };
                };
                break :blk .{ .gzip_decompress = .{
                    .content = allocating.toOwnedSlice() catch @panic("OOM: результат async сжатие.разжать_gzip"),
                    .err_message = null,
                } };
            };
            std.heap.page_allocator.free(job.data);
            job.queue.push(.{ .target_id = job.target_id, .payload = payload });
        }
    };
    const thread = std.Thread.spawn(.{}, Job.run, .{Job{ .queue = &vm.async_queue, .target_id = target_id, .data = owned_data }}) catch @panic("не удалось запустить фоновый поток сжатие.разжать_gzip");
    thread.detach();
}

fn submitFileWrite(vm: *Vm, path: []const u8, content: []const u8, target_id: u64) void {
    vm.async_queue.beginSubmit();
    const owned_path = std.heap.page_allocator.dupe(u8, path) catch @panic("OOM: путь для async фс.записать");
    const owned_content = std.heap.page_allocator.dupe(u8, content) catch @panic("OOM: содержимое для async фс.записать");
    const Job = struct {
        queue: *AsyncQueue,
        target_id: u64,
        path: []u8,
        content: []u8,

        fn run(job: @This()) void {
            var io = std.Io.Threaded.init(std.heap.page_allocator, .{});
            defer io.deinit();
            const write_error = std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = job.path, .data = job.content });
            const bytes_written = job.content.len;
            std.heap.page_allocator.free(job.path);
            std.heap.page_allocator.free(job.content);
            const payload: AsyncPayload = if (write_error) |_|
                .{ .file_write = .{ .bytes_written = bytes_written, .err_message = null } }
            else |err|
                .{ .file_write = .{
                    .bytes_written = 0,
                    .err_message = std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{@errorName(err)}) catch @panic("OOM"),
                } };
            job.queue.push(.{ .target_id = job.target_id, .payload = payload });
        }
    };
    const thread = std.Thread.spawn(.{}, Job.run, .{Job{ .queue = &vm.async_queue, .target_id = target_id, .path = owned_path, .content = owned_content }}) catch @panic("не удалось запустить фоновый поток фс.записать");
    thread.detach();
}

fn submitNetConnect(vm: *Vm, host: []const u8, port: u16, target_id: u64) void {
    vm.async_queue.beginSubmit();
    const owned_host = std.heap.page_allocator.dupe(u8, host) catch @panic("OOM: хост для async сеть.подключиться");
    const Job = struct {
        queue: *AsyncQueue,
        target_id: u64,
        host: []u8,
        port: u16,

        fn run(job: @This()) void {
            var io = std.Io.Threaded.init(std.heap.page_allocator, .{});
            defer io.deinit();
            const payload: AsyncPayload = blk: {
                const address = std.Io.net.IpAddress.resolve(io.io(), job.host, job.port) catch |err| {
                    break :blk .{ .net_connect = .{
                        .stream = null,
                        .err_message = std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{@errorName(err)}) catch @panic("OOM"),
                    } };
                };
                const stream = std.Io.net.IpAddress.connect(&address, io.io(), .{ .mode = .stream }) catch |err| {
                    break :blk .{ .net_connect = .{
                        .stream = null,
                        .err_message = std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{@errorName(err)}) catch @panic("OOM"),
                    } };
                };
                break :blk .{ .net_connect = .{ .stream = stream, .err_message = null } };
            };
            std.heap.page_allocator.free(job.host);
            job.queue.push(.{ .target_id = job.target_id, .payload = payload });
        }
    };
    const thread = std.Thread.spawn(.{}, Job.run, .{Job{ .queue = &vm.async_queue, .target_id = target_id, .host = owned_host, .port = port }}) catch @panic("не удалось запустить фоновый поток сеть.подключиться");
    thread.detach();
}

// `owned_headers` уже склонирован на page_allocator вызывающей стороной
// (httpRequestSubmit, на главном потоке) — эта функция забирает владение им
// (сама освобождает на стороне воркера) вместе с клонами method/url/body,
// которые делает здесь же.
fn submitHttpRequest(vm: *Vm, method_text: []const u8, url: []const u8, body: []const u8, owned_headers: []HttpHeaderPair, target_id: u64, follow_redirects: bool) void {
    vm.async_queue.beginSubmit();
    const Job = struct {
        queue: *AsyncQueue,
        target_id: u64,
        method_text: []u8,
        url: []u8,
        body: []u8,
        headers: []HttpHeaderPair,
        follow_redirects: bool,

        fn fail(job: @This(), comptime format: []const u8, args: anytype) void {
            const message = std.fmt.allocPrint(std.heap.page_allocator, format, args) catch @panic("OOM");
            job.cleanupOwned();
            job.queue.push(.{ .target_id = job.target_id, .payload = .{ .http_request = .{ .result = null, .err_message = message } } });
        }

        fn cleanupOwned(job: @This()) void {
            std.heap.page_allocator.free(job.method_text);
            std.heap.page_allocator.free(job.url);
            std.heap.page_allocator.free(job.body);
            for (job.headers) |header| {
                std.heap.page_allocator.free(header.name);
                std.heap.page_allocator.free(header.value);
            }
            std.heap.page_allocator.free(job.headers);
        }

        fn run(job: @This()) void {
            var method_buffer: [16]u8 = undefined;
            if (job.method_text.len == 0 or job.method_text.len > method_buffer.len) {
                return job.fail("неизвестный HTTP-метод", .{});
            }
            for (job.method_text, 0..) |character, index| method_buffer[index] = std.ascii.toUpper(character);
            const method = std.meta.stringToEnum(std.http.Method, method_buffer[0..job.method_text.len]) orelse {
                return job.fail("неизвестный HTTP-метод", .{});
            };
            const uri = std.Uri.parse(job.url) catch |err| return job.fail("{s}", .{@errorName(err)});
            var extra_headers: std.ArrayList(std.http.Header) = .empty;
            defer extra_headers.deinit(std.heap.page_allocator);
            for (job.headers) |header| {
                extra_headers.append(std.heap.page_allocator, .{ .name = header.name, .value = header.value }) catch @panic("OOM");
            }
            var io = std.Io.Threaded.init(std.heap.page_allocator, .{});
            defer io.deinit();
            var client: std.http.Client = .{ .allocator = std.heap.page_allocator, .io = io.io() };
            defer client.deinit();
            var request = client.request(method, uri, .{
                .extra_headers = extra_headers.items,
                .redirect_behavior = if (job.follow_redirects) std.http.Client.Request.RedirectBehavior.init(3) else .unhandled,
            }) catch |err| {
                return job.fail("{s}", .{@errorName(err)});
            };
            defer request.deinit();
            if (job.body.len != 0) {
                request.transfer_encoding = .{ .content_length = job.body.len };
                var request_body = request.sendBodyUnflushed(&.{}) catch |err| return job.fail("{s}", .{@errorName(err)});
                request_body.writer.writeAll(job.body) catch |err| return job.fail("{s}", .{@errorName(err)});
                request_body.end() catch |err| return job.fail("{s}", .{@errorName(err)});
                request.connection.?.flush() catch |err| return job.fail("{s}", .{@errorName(err)});
            } else {
                request.sendBodiless() catch |err| return job.fail("{s}", .{@errorName(err)});
            }
            const redirect_buffer = std.heap.page_allocator.alloc(u8, 8192) catch @panic("OOM");
            defer std.heap.page_allocator.free(redirect_buffer);
            var response = request.receiveHead(redirect_buffer) catch |err| return job.fail("{s}", .{@errorName(err)});
            var header_pairs: std.ArrayList(HttpHeaderPair) = .empty;
            defer header_pairs.deinit(std.heap.page_allocator);
            var header_iterator = response.head.iterateHeaders();
            while (header_iterator.next()) |header| {
                header_pairs.append(std.heap.page_allocator, .{
                    .name = std.heap.page_allocator.dupe(u8, header.name) catch @panic("OOM"),
                    .value = std.heap.page_allocator.dupe(u8, header.value) catch @panic("OOM"),
                }) catch @panic("OOM");
            }
            const decompress_buffer: []u8 = switch (response.head.content_encoding) {
                .identity => &.{},
                .zstd => std.heap.page_allocator.alloc(u8, std.compress.zstd.default_window_len) catch @panic("OOM"),
                .deflate, .gzip => std.heap.page_allocator.alloc(u8, std.compress.flate.max_window_len) catch @panic("OOM"),
                .compress => return job.fail("неподдержанный Content-Encoding", .{}),
            };
            defer std.heap.page_allocator.free(decompress_buffer);
            var transfer_buffer: [64]u8 = undefined;
            var decompress: std.http.Decompress = undefined;
            const body_reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
            var allocating: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
            defer allocating.deinit();
            _ = body_reader.streamRemaining(&allocating.writer) catch {
                const body_error = response.bodyErr() orelse error.ReadFailed;
                return job.fail("{s}", .{@errorName(body_error)});
            };
            const response_body = std.heap.page_allocator.dupe(u8, allocating.written()) catch @panic("OOM");
            job.cleanupOwned();
            job.queue.push(.{ .target_id = job.target_id, .payload = .{ .http_request = .{
                .result = .{
                    .status = @intFromEnum(response.head.status),
                    .headers = header_pairs.toOwnedSlice(std.heap.page_allocator) catch @panic("OOM"),
                    .body = response_body,
                },
                .err_message = null,
            } } });
        }
    };
    const job = Job{
        .queue = &vm.async_queue,
        .target_id = target_id,
        .method_text = std.heap.page_allocator.dupe(u8, method_text) catch @panic("OOM"),
        .url = std.heap.page_allocator.dupe(u8, url) catch @panic("OOM"),
        .body = std.heap.page_allocator.dupe(u8, body) catch @panic("OOM"),
        .headers = owned_headers,
        .follow_redirects = follow_redirects,
    };
    const thread = std.Thread.spawn(.{}, Job.run, .{job}) catch @panic("не удалось запустить фоновый поток сеть.http_запрос");
    thread.detach();
}

// `connection` закреплён (gc_pinned) ВЫЗЫВАЮЩЕЙ стороной (connectionReadSubmit)
// на всё время полёта — воркер трогает только скопированное ЗНАЧЕНИЕ
// `stream` (обычная обёртка fd, безопасно использовать из другого потока,
// пока fd открыт), никогда не GC-заголовок `connection` или другое его
// поле; сам `connection` переносится только как непрозрачный идентификатор
// для доставки.
fn submitConnectionRead(vm: *Vm, connection: *value.Connection, stream: std.Io.net.Stream, drained_pending: []u8, target_id: u64) void {
    vm.async_queue.beginSubmit();
    const Job = struct {
        queue: *AsyncQueue,
        target_id: u64,
        connection: *value.Connection,
        stream: std.Io.net.Stream,
        collected: std.ArrayList(u8),

        fn run(job: @This()) void {
            var collected = job.collected;
            var io = std.Io.Threaded.init(std.heap.page_allocator, .{});
            defer io.deinit();
            var temp: [4096]u8 = undefined;
            while (true) {
                var reader = job.stream.reader(io.io(), &.{});
                const n = reader.interface.readSliceShort(&temp) catch |err| {
                    collected.deinit(std.heap.page_allocator);
                    const message = std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{@errorName(err)}) catch @panic("OOM");
                    job.queue.push(.{ .target_id = job.target_id, .payload = .{ .connection_read = .{
                        .connection = job.connection,
                        .content = null,
                        .err_message = message,
                    } } });
                    return;
                };
                collected.appendSlice(std.heap.page_allocator, temp[0..n]) catch @panic("OOM");
                if (n < temp.len) break;
            }
            const content = collected.toOwnedSlice(std.heap.page_allocator) catch @panic("OOM");
            job.queue.push(.{ .target_id = job.target_id, .payload = .{ .connection_read = .{
                .connection = job.connection,
                .content = content,
                .err_message = null,
            } } });
        }
    };
    var owned_pending: std.ArrayList(u8) = .empty;
    owned_pending.appendSlice(std.heap.page_allocator, drained_pending) catch @panic("OOM");
    const thread = std.Thread.spawn(.{}, Job.run, .{Job{
        .queue = &vm.async_queue,
        .target_id = target_id,
        .connection = connection,
        .stream = stream,
        .collected = owned_pending,
    }}) catch @panic("не удалось запустить фоновый поток Соединение.получить");
    thread.detach();
}

// Та же дисциплина gc_pin/непрозрачного идентификатора, что и у
// submitConnectionRead выше.
fn submitConnectionWrite(vm: *Vm, connection: *value.Connection, stream: std.Io.net.Stream, content: []const u8, target_id: u64) void {
    vm.async_queue.beginSubmit();
    const owned_content = std.heap.page_allocator.dupe(u8, content) catch @panic("OOM: содержимое для async Соединение.отправить");
    const Job = struct {
        queue: *AsyncQueue,
        target_id: u64,
        connection: *value.Connection,
        stream: std.Io.net.Stream,
        content: []u8,

        fn run(job: @This()) void {
            var io = std.Io.Threaded.init(std.heap.page_allocator, .{});
            defer io.deinit();
            var writer = job.stream.writer(io.io(), &.{});
            const payload: AsyncPayload = blk: {
                writer.interface.writeAll(job.content) catch |err| break :blk .{ .connection_write = .{
                    .connection = job.connection,
                    .bytes_written = 0,
                    .err_message = std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{@errorName(err)}) catch @panic("OOM"),
                } };
                writer.interface.flush() catch |err| break :blk .{ .connection_write = .{
                    .connection = job.connection,
                    .bytes_written = 0,
                    .err_message = std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{@errorName(err)}) catch @panic("OOM"),
                } };
                break :blk .{ .connection_write = .{ .connection = job.connection, .bytes_written = job.content.len, .err_message = null } };
            };
            std.heap.page_allocator.free(job.content);
            job.queue.push(.{ .target_id = job.target_id, .payload = payload });
        }
    };
    const thread = std.Thread.spawn(.{}, Job.run, .{Job{
        .queue = &vm.async_queue,
        .target_id = target_id,
        .connection = connection,
        .stream = stream,
        .content = owned_content,
    }}) catch @panic("не удалось запустить фоновый поток Соединение.отправить");
    thread.detach();
}

// `drained_pending` — всё, что уже было в `.pending` до этого вызова,
// передаётся как стартовый буфер накопления воркера (та же дисциплина
// "слить-затем-передать", что у submitConnectionRead).
fn submitConnectionReadLine(vm: *Vm, connection: *value.Connection, stream: std.Io.net.Stream, drained_pending: []const u8, target_id: u64) void {
    vm.async_queue.beginSubmit();
    var owned_pending: std.ArrayList(u8) = .empty;
    owned_pending.appendSlice(std.heap.page_allocator, drained_pending) catch @panic("OOM");
    const Job = struct {
        queue: *AsyncQueue,
        target_id: u64,
        connection: *value.Connection,
        stream: std.Io.net.Stream,
        pending: std.ArrayList(u8),

        fn run(job: @This()) void {
            var pending = job.pending;
            var io = std.Io.Threaded.init(std.heap.page_allocator, .{});
            defer io.deinit();
            var temp: [4096]u8 = undefined;
            while (true) {
                if (std.mem.indexOfScalar(u8, pending.items, '\n')) |newline_index| {
                    const raw_line = pending.items[0..newline_index];
                    const line = if (std.mem.endsWith(u8, raw_line, "\r")) raw_line[0 .. raw_line.len - 1] else raw_line;
                    const owned_line = std.heap.page_allocator.dupe(u8, line) catch @panic("OOM");
                    const remaining_len = pending.items.len - (newline_index + 1);
                    std.mem.copyForwards(u8, pending.items[0..remaining_len], pending.items[newline_index + 1 ..]);
                    pending.shrinkRetainingCapacity(remaining_len);
                    const new_pending = pending.toOwnedSlice(std.heap.page_allocator) catch @panic("OOM");
                    job.queue.push(.{ .target_id = job.target_id, .payload = .{ .connection_read_line = .{
                        .connection = job.connection,
                        .line = owned_line,
                        .new_pending = new_pending,
                        .err_message = null,
                    } } });
                    return;
                }
                var reader = job.stream.reader(io.io(), &.{});
                const n = reader.interface.readSliceShort(&temp) catch |err| {
                    const new_pending = pending.toOwnedSlice(std.heap.page_allocator) catch @panic("OOM");
                    job.queue.push(.{ .target_id = job.target_id, .payload = .{ .connection_read_line = .{
                        .connection = job.connection,
                        .line = null,
                        .new_pending = new_pending,
                        .err_message = std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{@errorName(err)}) catch @panic("OOM"),
                    } } });
                    return;
                };
                if (n == 0) {
                    const leftover = pending.toOwnedSlice(std.heap.page_allocator) catch @panic("OOM");
                    job.queue.push(.{ .target_id = job.target_id, .payload = .{ .connection_read_line = .{
                        .connection = job.connection,
                        .line = leftover,
                        .new_pending = &.{},
                        .err_message = null,
                    } } });
                    return;
                }
                pending.appendSlice(std.heap.page_allocator, temp[0..n]) catch @panic("OOM");
            }
        }
    };
    const thread = std.Thread.spawn(.{}, Job.run, .{Job{
        .queue = &vm.async_queue,
        .target_id = target_id,
        .connection = connection,
        .stream = stream,
        .pending = owned_pending,
    }}) catch @panic("не удалось запустить фоновый поток Соединение.получить_строку");
    thread.detach();
}

// Общее для `Файл.прочитать()`/`Файл.прочитать_строку()` — `want_line`
// выбирает правило нарезки для одного и того же чтения всего файла
// (переоткрываемого по пути) — см. doc-комментарий `FileHandle` в
// `value.zig` о том, почему нет постоянного OS-хендла для seek вместо
// этого.
fn submitFileHandleRead(vm: *Vm, handle: *value.FileHandle, path: []const u8, offset: usize, want_line: bool, target_id: u64) void {
    vm.async_queue.beginSubmit();
    const owned_path = std.heap.page_allocator.dupe(u8, path) catch @panic("OOM: путь для async Файл.прочитать");
    const Job = struct {
        queue: *AsyncQueue,
        target_id: u64,
        handle: *value.FileHandle,
        path: []u8,
        offset: usize,
        want_line: bool,

        fn fail(job: @This(), comptime format: []const u8, args: anytype) void {
            const message = std.fmt.allocPrint(std.heap.page_allocator, format, args) catch @panic("OOM");
            std.heap.page_allocator.free(job.path);
            job.queue.push(.{ .target_id = job.target_id, .payload = .{ .file_handle_read = .{
                .handle = job.handle,
                .content = null,
                .new_offset = job.offset,
                .err_message = message,
            } } });
        }

        fn run(job: @This()) void {
            var io = std.Io.Threaded.init(std.heap.page_allocator, .{});
            defer io.deinit();
            const full_content = std.Io.Dir.cwd().readFileAlloc(io.io(), job.path, std.heap.page_allocator, .unlimited) catch |err| {
                return job.fail("{s}", .{@errorName(err)});
            };
            defer std.heap.page_allocator.free(full_content);
            std.heap.page_allocator.free(job.path);
            const remainder = if (job.offset < full_content.len) full_content[job.offset..] else "";
            var result_slice: []const u8 = undefined;
            var new_offset: usize = undefined;
            if (job.want_line) {
                const newline_index = std.mem.indexOfScalar(u8, remainder, '\n');
                const raw_line = if (newline_index) |index| remainder[0..index] else remainder;
                new_offset = job.offset + raw_line.len + @as(usize, if (newline_index != null) 1 else 0);
                result_slice = if (std.mem.endsWith(u8, raw_line, "\r")) raw_line[0 .. raw_line.len - 1] else raw_line;
            } else {
                result_slice = remainder;
                new_offset = full_content.len;
            }
            const owned_result = std.heap.page_allocator.dupe(u8, result_slice) catch @panic("OOM");
            job.queue.push(.{ .target_id = job.target_id, .payload = .{ .file_handle_read = .{
                .handle = job.handle,
                .content = owned_result,
                .new_offset = new_offset,
                .err_message = null,
            } } });
        }
    };
    const thread = std.Thread.spawn(.{}, Job.run, .{Job{
        .queue = &vm.async_queue,
        .target_id = target_id,
        .handle = handle,
        .path = owned_path,
        .offset = offset,
        .want_line = want_line,
    }}) catch @panic("не удалось запустить фоновый поток Файл.прочитать");
    thread.detach();
}

fn submitFileHandleWrite(vm: *Vm, handle: *value.FileHandle, path: []const u8, content: []const u8, offset: usize, target_id: u64) void {
    vm.async_queue.beginSubmit();
    const owned_path = std.heap.page_allocator.dupe(u8, path) catch @panic("OOM: путь для async Файл.записать");
    const owned_content = std.heap.page_allocator.dupe(u8, content) catch @panic("OOM: содержимое для async Файл.записать");
    const Job = struct {
        queue: *AsyncQueue,
        target_id: u64,
        handle: *value.FileHandle,
        path: []u8,
        content: []u8,
        offset: usize,

        fn fail(job: @This(), comptime format: []const u8, args: anytype) void {
            const message = std.fmt.allocPrint(std.heap.page_allocator, format, args) catch @panic("OOM");
            std.heap.page_allocator.free(job.path);
            std.heap.page_allocator.free(job.content);
            job.queue.push(.{ .target_id = job.target_id, .payload = .{ .file_handle_write = .{
                .handle = job.handle,
                .bytes_written = 0,
                .new_offset = job.offset,
                .err_message = message,
            } } });
        }

        fn run(job: @This()) void {
            var io = std.Io.Threaded.init(std.heap.page_allocator, .{});
            defer io.deinit();
            const existing = std.Io.Dir.cwd().readFileAlloc(io.io(), job.path, std.heap.page_allocator, .unlimited) catch |err| {
                return job.fail("{s}", .{@errorName(err)});
            };
            defer std.heap.page_allocator.free(existing);
            const prefix_len = @min(job.offset, existing.len);
            const tail_start = job.offset + job.content.len;
            const new_len = @max(existing.len, tail_start);
            const buffer = std.heap.page_allocator.alloc(u8, new_len) catch @panic("OOM");
            defer std.heap.page_allocator.free(buffer);
            @memcpy(buffer[0..prefix_len], existing[0..prefix_len]);
            if (job.offset > prefix_len) @memset(buffer[prefix_len..job.offset], 0);
            @memcpy(buffer[job.offset..tail_start], job.content);
            if (existing.len > tail_start) @memcpy(buffer[tail_start..existing.len], existing[tail_start..existing.len]);
            std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = job.path, .data = buffer }) catch |err| {
                return job.fail("{s}", .{@errorName(err)});
            };
            const bytes_written = job.content.len;
            const new_offset = job.offset + job.content.len;
            std.heap.page_allocator.free(job.path);
            std.heap.page_allocator.free(job.content);
            job.queue.push(.{ .target_id = job.target_id, .payload = .{ .file_handle_write = .{
                .handle = job.handle,
                .bytes_written = bytes_written,
                .new_offset = new_offset,
                .err_message = null,
            } } });
        }
    };
    const thread = std.Thread.spawn(.{}, Job.run, .{Job{
        .queue = &vm.async_queue,
        .target_id = target_id,
        .handle = handle,
        .path = owned_path,
        .content = owned_content,
        .offset = offset,
    }}) catch @panic("не удалось запустить фоновый поток Файл.записать");
    thread.detach();
}

fn submitSqlOpen(vm: *Vm, path: []const u8, target_id: u64) void {
    vm.async_queue.beginSubmit();
    const owned_path = std.heap.page_allocator.dupeZ(u8, path) catch @panic("OOM: путь для async бд.открыть");
    const Job = struct {
        queue: *AsyncQueue,
        target_id: u64,
        path: [:0]u8,

        fn run(job: @This()) void {
            var db: ?*sqlite3.sqlite3 = null;
            const rc = sqlite3.sqlite3_open_v2(job.path, &db, sqlite3.SQLITE_OPEN_READWRITE | sqlite3.SQLITE_OPEN_CREATE, null);
            std.heap.page_allocator.free(job.path);
            if (rc != sqlite3.SQLITE_OK) {
                // sqlite3_open_v2 может выделить едва пригодный `db` даже при
                // ошибке, чисто чтобы sqlite3_errmsg было что вернуть; его
                // всё равно нужно закрыть.
                const message = std.mem.span(sqlite3.sqlite3_errmsg(db) orelse "не удалось открыть базу данных");
                const owned_message = std.heap.page_allocator.dupe(u8, message) catch @panic("OOM");
                _ = sqlite3.sqlite3_close_v2(db);
                job.queue.push(.{ .target_id = job.target_id, .payload = .{ .sql_open = .{ .db = null, .err_message = owned_message } } });
                return;
            }
            job.queue.push(.{ .target_id = job.target_id, .payload = .{ .sql_open = .{ .db = db, .err_message = null } } });
        }
    };
    const thread = std.Thread.spawn(.{}, Job.run, .{Job{ .queue = &vm.async_queue, .target_id = target_id, .path = owned_path }}) catch @panic("не удалось запустить фоновый поток бд.открыть");
    thread.detach();
}

const SqlPrepareWorkerOutcome = union(enum) {
    ok: ?*sqlite3.sqlite3_stmt,
    fail: []u8,
};

// Эквивалент `Vm.sqlPrepare` на стороне воркера — без доступа к `Vm`, всё на
// `page_allocator`. `params` уже провалидирован (все — Строка) и склонирован
// в обычный `[]const u8` вызывающей стороной (submitSqlExec/submitSqlQuery,
// на главном потоке) до того, как воркер вообще стартует.
fn sqlPrepareWorker(db: ?*sqlite3.sqlite3, sql_z: [:0]const u8, params: []const []const u8) SqlPrepareWorkerOutcome {
    var stmt: ?*sqlite3.sqlite3_stmt = null;
    const prepare_rc = sqlite3.sqlite3_prepare_v2(db, sql_z.ptr, -1, &stmt, null);
    if (prepare_rc != sqlite3.SQLITE_OK) {
        const message = std.mem.span(sqlite3.sqlite3_errmsg(db) orelse "ошибка SQL");
        return .{ .fail = std.heap.page_allocator.dupe(u8, message) catch @panic("OOM") };
    }
    for (params, 0..) |param, index| {
        const text_z = std.heap.page_allocator.dupeZ(u8, param) catch @panic("OOM");
        defer std.heap.page_allocator.free(text_z);
        const bind_rc = sqlite3.sqlite3_bind_text(stmt, @intCast(index + 1), text_z, -1, sqlite3.SQLITE_TRANSIENT);
        if (bind_rc != sqlite3.SQLITE_OK) {
            const message = std.mem.span(sqlite3.sqlite3_errmsg(db) orelse "ошибка привязки параметра");
            const owned_message = std.heap.page_allocator.dupe(u8, message) catch @panic("OOM");
            _ = sqlite3.sqlite3_finalize(stmt);
            return .{ .fail = owned_message };
        }
    }
    return .{ .ok = stmt };
}

fn submitSqlExec(vm: *Vm, connection: *value.SqlConnection, sql: []const u8, params: []const []const u8, target_id: u64) void {
    vm.async_queue.beginSubmit();
    const owned_sql = std.heap.page_allocator.dupeZ(u8, sql) catch @panic("OOM");
    const owned_params = std.heap.page_allocator.alloc([]u8, params.len) catch @panic("OOM");
    for (params, owned_params) |param, *slot| slot.* = std.heap.page_allocator.dupe(u8, param) catch @panic("OOM");
    const Job = struct {
        queue: *AsyncQueue,
        target_id: u64,
        connection: *value.SqlConnection,
        sql: [:0]u8,
        params: [][]u8,

        fn cleanupOwned(job: @This()) void {
            std.heap.page_allocator.free(job.sql);
            for (job.params) |param| std.heap.page_allocator.free(param);
            std.heap.page_allocator.free(job.params);
        }

        fn run(job: @This()) void {
            const outcome = sqlPrepareWorker(job.connection.db, job.sql, job.params);
            job.cleanupOwned();
            switch (outcome) {
                .fail => |message| job.queue.push(.{ .target_id = job.target_id, .payload = .{ .sql_exec = .{
                    .connection = job.connection,
                    .rows_affected = 0,
                    .err_message = message,
                } } }),
                .ok => |stmt| {
                    defer _ = sqlite3.sqlite3_finalize(stmt);
                    const step_rc = sqlite3.sqlite3_step(stmt);
                    if (step_rc != sqlite3.SQLITE_DONE and step_rc != sqlite3.SQLITE_ROW) {
                        const message = std.mem.span(sqlite3.sqlite3_errmsg(job.connection.db) orelse "ошибка выполнения SQL");
                        const owned_message = std.heap.page_allocator.dupe(u8, message) catch @panic("OOM");
                        job.queue.push(.{ .target_id = job.target_id, .payload = .{ .sql_exec = .{
                            .connection = job.connection,
                            .rows_affected = 0,
                            .err_message = owned_message,
                        } } });
                        return;
                    }
                    job.queue.push(.{ .target_id = job.target_id, .payload = .{ .sql_exec = .{
                        .connection = job.connection,
                        .rows_affected = sqlite3.sqlite3_changes(job.connection.db),
                        .err_message = null,
                    } } });
                },
            }
        }
    };
    const thread = std.Thread.spawn(.{}, Job.run, .{Job{
        .queue = &vm.async_queue,
        .target_id = target_id,
        .connection = connection,
        .sql = owned_sql,
        .params = owned_params,
    }}) catch @panic("не удалось запустить фоновый поток Соединение_БД.выполнить");
    thread.detach();
}

fn submitSqlQuery(vm: *Vm, connection: *value.SqlConnection, sql: []const u8, params: []const []const u8, target_id: u64) void {
    vm.async_queue.beginSubmit();
    const owned_sql = std.heap.page_allocator.dupeZ(u8, sql) catch @panic("OOM");
    const owned_params = std.heap.page_allocator.alloc([]u8, params.len) catch @panic("OOM");
    for (params, owned_params) |param, *slot| slot.* = std.heap.page_allocator.dupe(u8, param) catch @panic("OOM");
    const Job = struct {
        queue: *AsyncQueue,
        target_id: u64,
        connection: *value.SqlConnection,
        sql: [:0]u8,
        params: [][]u8,

        fn cleanupOwned(job: @This()) void {
            std.heap.page_allocator.free(job.sql);
            for (job.params) |param| std.heap.page_allocator.free(param);
            std.heap.page_allocator.free(job.params);
        }

        fn fail(job: @This(), message: []u8) void {
            job.queue.push(.{ .target_id = job.target_id, .payload = .{ .sql_query = .{
                .connection = job.connection,
                .column_names = &.{},
                .rows = &.{},
                .err_message = message,
            } } });
        }

        fn run(job: @This()) void {
            const outcome = sqlPrepareWorker(job.connection.db, job.sql, job.params);
            job.cleanupOwned();
            switch (outcome) {
                .fail => |message| job.fail(message),
                .ok => |stmt| {
                    defer _ = sqlite3.sqlite3_finalize(stmt);
                    const column_count = sqlite3.sqlite3_column_count(stmt);
                    var column_names = std.heap.page_allocator.alloc([]u8, @intCast(column_count)) catch @panic("OOM");
                    var column_index: c_int = 0;
                    while (column_index < column_count) : (column_index += 1) {
                        const name = std.mem.span(sqlite3.sqlite3_column_name(stmt, column_index) orelse "");
                        column_names[@intCast(column_index)] = std.heap.page_allocator.dupe(u8, name) catch @panic("OOM");
                    }
                    var rows: std.ArrayList([]?[]u8) = .empty;
                    while (true) {
                        const step_rc = sqlite3.sqlite3_step(stmt);
                        if (step_rc == sqlite3.SQLITE_DONE) break;
                        if (step_rc != sqlite3.SQLITE_ROW) {
                            const message = std.mem.span(sqlite3.sqlite3_errmsg(job.connection.db) orelse "ошибка выполнения SQL");
                            for (rows.items) |row| {
                                for (row) |cell| if (cell) |bytes| std.heap.page_allocator.free(bytes);
                                std.heap.page_allocator.free(row);
                            }
                            rows.deinit(std.heap.page_allocator);
                            for (column_names) |name| std.heap.page_allocator.free(name);
                            std.heap.page_allocator.free(column_names);
                            return job.fail(std.heap.page_allocator.dupe(u8, message) catch @panic("OOM"));
                        }
                        var row = std.heap.page_allocator.alloc(?[]u8, column_names.len) catch @panic("OOM");
                        var is_blob_row = false;
                        for (column_names, 0..) |_, index_usize| {
                            const index: c_int = @intCast(index_usize);
                            const column_type = sqlite3.sqlite3_column_type(stmt, index);
                            if (column_type == sqlite3.SQLITE_NULL) {
                                row[index_usize] = null;
                            } else if (column_type == sqlite3.SQLITE_BLOB) {
                                is_blob_row = true;
                                row[index_usize] = null;
                            } else {
                                const text = std.mem.span(sqlite3.sqlite3_column_text(stmt, index) orelse "");
                                row[index_usize] = std.heap.page_allocator.dupe(u8, text) catch @panic("OOM");
                            }
                        }
                        if (is_blob_row) {
                            for (row) |cell| if (cell) |bytes| std.heap.page_allocator.free(bytes);
                            std.heap.page_allocator.free(row);
                            for (rows.items) |existing_row| {
                                for (existing_row) |cell| if (cell) |bytes| std.heap.page_allocator.free(bytes);
                                std.heap.page_allocator.free(existing_row);
                            }
                            rows.deinit(std.heap.page_allocator);
                            for (column_names) |name| std.heap.page_allocator.free(name);
                            std.heap.page_allocator.free(column_names);
                            return job.fail(std.heap.page_allocator.dupe(u8, "BLOB-колонки не поддержаны в этой версии") catch @panic("OOM"));
                        }
                        rows.append(std.heap.page_allocator, row) catch @panic("OOM");
                    }
                    job.queue.push(.{ .target_id = job.target_id, .payload = .{ .sql_query = .{
                        .connection = job.connection,
                        .column_names = column_names,
                        .rows = rows.toOwnedSlice(std.heap.page_allocator) catch @panic("OOM"),
                        .err_message = null,
                    } } });
                },
            }
        }
    };
    const thread = std.Thread.spawn(.{}, Job.run, .{Job{
        .queue = &vm.async_queue,
        .target_id = target_id,
        .connection = connection,
        .sql = owned_sql,
        .params = owned_params,
    }}) catch @panic("не удалось запустить фоновый поток Соединение_БД.запрос");
    thread.detach();
}

// `listener.server` копируется в задачу ПО ЗНАЧЕНИЮ — `Server.accept`
// только читает его поля (хендл сокета + опции) для системного вызова,
// никогда их не меняет, поэтому независимые копии, вызывающие `.accept()`
// параллельно (сколько бы ни было `.принять_запрос()` в полёте одновременно)
// безопасны — один и тот же слушающий сокет безопасно принимать (accept) из
// нескольких потоков одновременно (обычное поведение POSIX).
fn submitHttpAccept(vm: *Vm, listener: *value.Listener, target_id: u64) void {
    vm.async_queue.beginSubmit();
    const Job = struct {
        queue: *AsyncQueue,
        target_id: u64,
        listener: *value.Listener,
        server: std.Io.net.Server,

        fn fail(job: @This(), message: []u8) void {
            job.queue.push(.{ .target_id = job.target_id, .payload = .{ .http_accept = .{
                .listener = job.listener,
                .stream = null,
                .method = null,
                .path = null,
                .body = null,
                .headers = &.{},
                .err_message = message,
            } } });
        }

        fn run(job: @This()) void {
            var io = std.Io.Threaded.init(std.heap.page_allocator, .{});
            defer io.deinit();
            var server_copy = job.server;
            const stream = server_copy.accept(io.io()) catch |err| {
                return job.fail(std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{@errorName(err)}) catch @panic("OOM"));
            };
            const head_buffer = std.heap.page_allocator.alloc(u8, 8192) catch @panic("OOM");
            defer std.heap.page_allocator.free(head_buffer);
            var reader = stream.reader(io.io(), head_buffer);
            var write_buffer: [256]u8 = undefined;
            var writer = stream.writer(io.io(), &write_buffer);
            var http_server = std.http.Server.init(&reader.interface, &writer.interface);
            var request = http_server.receiveHead() catch |err| {
                stream.close(io.io());
                return job.fail(std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{@errorName(err)}) catch @panic("OOM"));
            };
            const method_text = std.heap.page_allocator.dupe(u8, @tagName(request.head.method)) catch @panic("OOM");
            const path_text = std.heap.page_allocator.dupe(u8, request.head.target) catch @panic("OOM");
            var header_pairs: std.ArrayList(HttpHeaderPair) = .empty;
            var header_iterator = request.iterateHeaders();
            while (header_iterator.next()) |header| {
                header_pairs.append(std.heap.page_allocator, .{
                    .name = std.heap.page_allocator.dupe(u8, header.name) catch @panic("OOM"),
                    .value = std.heap.page_allocator.dupe(u8, header.value) catch @panic("OOM"),
                }) catch @panic("OOM");
            }
            // POST/PUT/PATCH-запрос БЕЗ `Content-Length` И БЕЗ
            // `Transfer-Encoding: chunked` (пустое тело без явного
            // `Content-Length: 0`, например голый `curl -X POST` без `-d`) —
            // именно тот случай, для которого
            // `std.http.Server.Request.Reader.bodyReader` (std/http.zig
            // ~444-461) НЕ возвращает уже терминированный/ограниченный
            // reader — вместо этого отдаёт СЫРОЙ, НЕОГРАНИЧЕННЫЙ reader
            // сокета соединения (`reader.in`), полагая, что вызывающий сам
            // разберётся с телом без длины. `allocRemaining` на таком сыром
            // reader'е ждёт EOF или лимит 1 МиБ, но это keep-alive
            // HTTP/1.1-соединение — ни то, ни другое никогда не наступает
            // для легитимного пустого тела, так что воркер зависает
            // навсегда. `DELETE`/`GET`/`HEAD` этого никогда не задевают
            // (`Method.requestHasBody()` для них false, `readerExpectNone`
            // сразу возвращает `.ending`) — только методы с телом,
            // отправленные БЕЗ объявления длины. Обнаруживаем то же самое
            // условие, что проверяет сам `bodyReader`
            // (`transfer_encoding == .none and content_length == null`), и
            // напрямую трактуем это как пустое тело, вообще не трогая сырой
            // reader соединения.
            const body: []u8 = if (request.head.transfer_encoding == .none and request.head.content_length == null)
                &.{}
            else blk: {
                var body_buffer: [8192]u8 = undefined;
                const body_reader = request.readerExpectNone(&body_buffer);
                break :blk body_reader.allocRemaining(std.heap.page_allocator, .limited(1024 * 1024)) catch |err| {
                    stream.close(io.io());
                    return job.fail(std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{@errorName(err)}) catch @panic("OOM"));
                };
            };
            job.queue.push(.{ .target_id = job.target_id, .payload = .{ .http_accept = .{
                .listener = job.listener,
                .stream = stream,
                .method = method_text,
                .path = path_text,
                .body = body,
                .headers = header_pairs.toOwnedSlice(std.heap.page_allocator) catch @panic("OOM"),
                .err_message = null,
            } } });
        }
    };
    const thread = std.Thread.spawn(.{}, Job.run, .{Job{
        .queue = &vm.async_queue,
        .target_id = target_id,
        .listener = listener,
        .server = listener.server,
    }}) catch @panic("не удалось запустить фоновый поток Слушатель.принять_запрос");
    thread.detach();
}

// `std.c` связывает только `getenv` — без `setenv`/`unsetenv` — поэтому эти
// два объявлены напрямую, в той же форме, что и прототипы самой libc.
// Используются только в неfreestanding-ветке `if`/`else` в
// `Vm.osEnvSet`/`osEnvUnset` — почему форма этой ветки здесь важна, см.
// комментарий у `osEnvGet`.
const posix_env = struct {
    extern "c" fn setenv(name: [*:0]const u8, value_ptr: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

// MSVC-шный ucrt вообще не имеет символов `setenv`/`unsetenv` (вместо них
// `_putenv_s`) — объявления `extern "c"` из `posix_env` выше упали бы на
// этапе ЛИНКОВКИ на Windows, не компиляции, так что простым сканом ошибок
// компиляции это не поймать. `SetEnvironmentVariableW` меняет блок
// окружения ТЕКУЩЕГО процесса напрямую (для этой версии Zig нет `std`-
// биндинга) — порождённый дочерний процесс автоматически наследует этот
// блок, если вызывающий его не переопределит, а это именно то, что нужно
// хаку с environ в `osExec` на Windows тоже (см. там).
const windows_env = struct {
    extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) c_int;
    extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buffer: ?[*]u16, size: u32) callconv(.winapi) u32;
    extern "kernel32" fn GetEnvironmentStringsW() callconv(.winapi) ?[*:0]const u16;
    extern "kernel32" fn FreeEnvironmentStringsW(penv: [*:0]const u16) callconv(.winapi) c_int;

    // `std.c.getenv` читает СОБСТВЕННУЮ кэшированную копию блока окружения
    // ucrt (заполняется при старте процесса, синхронизируется только через
    // `_putenv`/`_wputenv`) — `SetEnvironmentVariableW` меняет сырой блок
    // окружения процесса Win32 напрямую и НЕ обновляет этот кэш ucrt,
    // поэтому `ос.установить_окружение(...)`, за которым следует
    // `ос.окружение(...)`, молча увидело бы СТАРОЕ значение через
    // `std.c.getenv`. `GetEnvironmentVariableW` вместо этого читает живой
    // блок Win32, соответствующий тому, что только что записал
    // `SetEnvironmentVariableW`.
    fn getenv(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
        const name_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, name);
        defer allocator.free(name_w);
        var buffer: [4096]u16 = undefined;
        const len = GetEnvironmentVariableW(name_w, &buffer, buffer.len);
        if (len == 0 or len >= buffer.len) return null;
        return try std.unicode.wtf16LeToWtf8Alloc(allocator, buffer[0..len]);
    }

    fn setenv(allocator: std.mem.Allocator, name: []const u8, env_value: []const u8) !c_int {
        const name_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, name);
        defer allocator.free(name_w);
        const value_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, env_value);
        defer allocator.free(value_w);
        return if (SetEnvironmentVariableW(name_w, value_w) != 0) 0 else 1;
    }

    fn unsetenv(allocator: std.mem.Allocator, name: []const u8) !c_int {
        const name_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, name);
        defer allocator.free(name_w);
        return if (SetEnvironmentVariableW(name_w, null) != 0) 0 else 1;
    }

    // `std.process.Environ.Block` на Windows резолвится в `GlobalBlock`
    // (только `.empty`/`.global`, см. `Environ.zig`) — никакого способа
    // передать ему кастомный блок через обычный вход `createMap` на этой
    // платформе вообще нет. Обходим это, читая живой блок окружения
    // процесса напрямую (та же идея живого блока, что и чтение POSIX
    // `std.c.environ` в `osExec` ниже) и передавая его через
    // `Environ.Map.putWindowsBlock`, которому нужен только сырой
    // UTF-16-указатель с двойным нулевым терминатором — без
    // `Block`/`createMap`.
    fn buildEnvironMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
        var map = std.process.Environ.Map.init(allocator);
        errdefer map.deinit();
        const raw = GetEnvironmentStringsW() orelse return map;
        defer _ = FreeEnvironmentStringsW(raw);
        try map.putWindowsBlock(.{ .ptr = raw });
        return map;
    }
};

// Преобразование значения в текст для `ввод_вывод.печать`/`.строка`, также
// переиспользуется `runner.renderValue` для финальной строки возвращаемого
// значения CLI (один и тот же контракт, одна реализация) — структурный
// дамп (`Имя(поле1, поле2, ...)`, позиционный, без имён полей — совпадает с
// уже задокументированной конвенцией отображения составных значений без
// реальной реализации `Печатаемое`). Диспетчеризация к СОБСТВЕННОМУ
// `.вСтроку()` значения, когда оно реализует `Печатаемое` (ПРЕДПОЧТИТЕЛЬНЫЙ
// по документации путь), здесь НЕ делается — для этого нужно приведение к
// интерфейсу с учётом статического типа в каждой точке вызова (тот же
// механизм, что использует сахар `Складываемое` для `+`), которое
// `ввод_вывод.печать(значение: любой тип)` не может получить бесплатно, т.к.
// его параметр — не настоящий generic; сознательно оставлено на будущее,
// а не тихо наполовину поддержано.
pub fn renderRuntimeValue(allocator: std.mem.Allocator, runtime_value: value.Value) anyerror![]u8 {
    return switch (runtime_value) {
        .void => allocator.dupe(u8, ""),
        .number => |number| std.fmt.allocPrint(allocator, "{d}", .{number}),
        // Оставлено как стандартные `true`/`false` Zig (НЕ `истина`/`ложь`) —
        // совпадает с существующим отображением финального возвращаемого
        // значения CLI, на которое опирается 19+ тестов; изменение этого —
        // отдельное решение, не побочный эффект добавления `ввод_вывод`.
        .boolean => |boolean| std.fmt.allocPrint(allocator, "{}", .{boolean}),
        .string => |string| allocator.dupe(u8, string),
        .heap_string => |string| allocator.dupe(u8, string.bytes),
        .aggregate => |aggregate| blk: {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            try out.appendSlice(allocator, aggregate.name orelse "");
            try out.append(allocator, '(');
            for (aggregate.elements, 0..) |element, index| {
                if (index != 0) try out.appendSlice(allocator, ", ");
                const rendered = try renderRuntimeValue(allocator, element);
                defer allocator.free(rendered);
                try out.appendSlice(allocator, rendered);
            }
            try out.append(allocator, ')');
            break :blk out.toOwnedSlice(allocator);
        },
        .array => |array| blk: {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            try out.append(allocator, '[');
            for (array.elements, 0..) |element, index| {
                if (index != 0) try out.appendSlice(allocator, ", ");
                const rendered = try renderRuntimeValue(allocator, element);
                defer allocator.free(rendered);
                try out.appendSlice(allocator, rendered);
            }
            try out.append(allocator, ']');
            break :blk out.toOwnedSlice(allocator);
        },
        .map => |map| blk: {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            try out.append(allocator, '{');
            for (map.entries.items, 0..) |entry, index| {
                if (index != 0) try out.appendSlice(allocator, ", ");
                const key_rendered = try renderRuntimeValue(allocator, entry.key);
                defer allocator.free(key_rendered);
                const value_rendered = try renderRuntimeValue(allocator, entry.value);
                defer allocator.free(value_rendered);
                try out.appendSlice(allocator, key_rendered);
                try out.appendSlice(allocator, ": ");
                try out.appendSlice(allocator, value_rendered);
            }
            try out.append(allocator, '}');
            break :blk out.toOwnedSlice(allocator);
        },
        else => allocator.dupe(u8, "<составное значение>"),
    };
}

pub const Vm = struct {
    allocator: std.mem.Allocator,
    heap: gc.Heap,
    program: *const bytecode.Program,
    stack: std.ArrayList(value.Value) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    processes: std.ArrayList(*value.Process) = .empty,
    current_process: ?*value.Process = null,
    next_process_id: u64 = 0,
    failure: ?*value.HeapString = null,
    target_profile: target_policy.TargetProfile = .native,
    // Всё, что в командной строке после пути к скрипту — `ос.аргументы()`.
    // Пусто для любой точки входа, кроме нативного CLI (LSP, browser) — там
    // нет осмысленного argv.
    program_args: []const []const u8 = &.{},
    async_queue: AsyncQueue = .{},
    foreign_call_cache: std.AutoHashMap(*const bytecode.ForeignFunctionConstant, *PreparedForeignCall),
    // Профиль сознательно opt-in: цикл кадра не платит ни за таймстемпы, ни
    // за записи в hash-map, пока CLI не включит --profile-ffi.
    foreign_profile_enabled: bool = false,
    foreign_profile: std.AutoHashMap(*const bytecode.ForeignFunctionConstant, ForeignCallMetric),
    // Устанавливается при ПЕРВОМ вызове `время.монотонно_мс()` (только
    // native — у freestanding wasm32 вообще нет своих часов, см.
    // `timeMonotonic`) — каждый следующий вызов сообщает время, прошедшее с
    // этой точки отсчёта, что соответствует задокументированному контракту
    // "миллисекунды с момента старта VM" без нужды в отдельном хуке "старт
    // VM".
    monotonic_baseline_ns: ?i96 = null,
    // По умолчанию false — при завершении корневого процесса runScheduler
    // блокируется на joinAsyncPool(), пока не отчитаются ВСЕ отправленные
    // async-задачи (см. AsyncQueue.joinAll). Это необходимо для встраивания
    // (Runtime может звать call()/runStart() ПОВТОРНО на том же machine —
    // осиротевший поток, дописывающий в уже переиспользуемую/освобождённую
    // структуру после этого момента, был бы use-after-free) и для
    // тестового харнесса (много run_code/run_module_file в ОДНОМ процессе
    // `zig build test`). Но для настоящего одноразового CLI-запуска
    // (`panos <скрипт>`, процесс завершается сразу после этого вызова)
    // это же ожидание превращается в вечный дедлок: фоновый актор,
    // запущенный через `запусти`, чей http.обслуживать(...) документированно
    // "никогда не возвращается" (accept() навсегда в полёте, если больше не
    // придёт ни одного соединения), не даёт joinAll() увидеть outstanding
    // == 0. CLI выставляет этот флаг в true — ОС и так убьёт все detached-
    // потоки мгновенно при завершении процесса, join там просто не нужен.
    abandon_background_async_on_root_exit: bool = false,
    // `ввод_вывод.печать`/`.строка` ВСЕГДА накапливают здесь (не только
    // пишут напрямую в реальный fd) — на freestanding wasm32 browser-
    // интерпретаторе РЕАЛЬНОГО fd вообще нет (см. пакетную модель
    // "выполнить до конца, затем прочитать буфер результата" в
    // `zig/browser/main.zig`); embed/LSP/conformance тоже читают
    // `output.items` программно после возврата из `run()` — тот же
    // механизм. Для настоящего одноразового native CLI-запуска ЭТОГО
    // одного недостаточно (см. `live_stdout` ниже).
    output: std.ArrayList(u8) = .empty,
    // `true` только для настоящего одноразового native CLI-запуска
    // (`zig/cli/main.zig` `runGraph`) — печать пишет напрямую в реальный
    // stdout СРАЗУ (не только в `output` выше). Без этого `ввод_вывод.
    // печать` внутри `http.обслуживать` (блокирующий, никогда не
    // возвращается на успехе) НИКОГДА не становится видимой — весь
    // накопленный `output` печатается ЦЕЛИКОМ ТОЛЬКО когда `run()`
    // возвращается, что для живого сервера значит "никогда" (найдено при
    // разработке `дозорный`: FR-011 требует напечатать bootstrap-пароль
    // в лог при старте — молча копился в буфере, реально ничего не
    // печаталось, пока сервер не убит). Остаётся `false` (умолчание) для
    // embed/LSP/WASM/conformance — они читают `output` программно после
    // `run()`, у WASM к тому же нет реального fd для немедленной записи.
    live_stdout: bool = false,

    pub fn init(allocator: std.mem.Allocator, program: *const bytecode.Program) Vm {
        return .{
            .allocator = allocator,
            .heap = gc.Heap.init(allocator),
            .program = program,
            .foreign_call_cache = .init(allocator),
            .foreign_profile = .init(allocator),
        };
    }

    pub fn initForTarget(allocator: std.mem.Allocator, program: *const bytecode.Program, target_profile: target_policy.TargetProfile) Vm {
        var result = init(allocator, program);
        result.target_profile = target_profile;
        return result;
    }

    pub fn deinit(self: *Vm) void {
        self.clearFrames();
        self.frames.deinit(self.allocator);
        self.stack.deinit(self.allocator);
        self.clearProcesses();
        self.processes.deinit(self.allocator);
        self.output.deinit(self.allocator);
        var foreign_calls = self.foreign_call_cache.valueIterator();
        while (foreign_calls.next()) |prepared| {
            prepared.*.deinit(self.allocator);
            self.allocator.destroy(prepared.*);
        }
        self.foreign_call_cache.deinit();
        self.foreign_profile.deinit();
        self.heap.deinit();
        self.* = undefined;
    }

    pub fn writeForeignProfile(self: *const Vm, writer: *std.Io.Writer) !void {
        if (!self.foreign_profile_enabled) return;
        try writer.print("FFI PROFILE (per external declaration)\n", .{});
        if (self.foreign_profile.count() == 0) {
            try writer.print("  внешние вызовы не выполнялись\n", .{});
            return;
        }

        var entries = self.foreign_profile.iterator();
        while (entries.next()) |entry| {
            const info = entry.key_ptr.*;
            const metric = entry.value_ptr.*;
            const total_us = metric.total_ns / 1_000;
            const native_us = metric.native_call_ns / 1_000;
            const overhead_us = if (total_us >= native_us) total_us - native_us else 0;
            const average_ns = if (metric.calls > 0) metric.total_ns / metric.calls else 0;
            const cache_hits = if (metric.calls >= metric.cache_misses) metric.calls - metric.cache_misses else 0;
            try writer.print(
                "  {s}: calls={d}, total={d} us, ffi_call={d} us, pack/cache={d} us, avg={d} ns, cache hit/miss={d}/{d}\n",
                .{ info.name, metric.calls, total_us, native_us, overhead_us, average_ns, cache_hits, metric.cache_misses },
            );
        }
    }

    pub fn run(self: *Vm, entry: bytecode.FunctionId, arguments: []const value.Value) !Execution {
        self.failure = null;
        self.current_process = null;
        self.stack.clearRetainingCapacity();
        self.clearFrames();
        self.clearProcesses();
        self.next_process_id = 0;
        // Защитный сброс для переиспользуемого экземпляра Vm —
        // next_process_id перезапускается с 0 выше, поэтому любое
        // оставшееся завершение от ПРЕДЫДУЩЕГО run() иначе могло бы быть
        // доставлено не тому процессу, который случайно переиспользовал тот
        // же id.
        self.async_queue.joinAll();
        for (self.async_queue.items.items) |leftover| freeAsyncPayload(leftover.payload);
        self.async_queue.items.clearRetainingCapacity();
        self.collect();
        const root = try self.createProcess(entry, &.{}, arguments);
        return self.runScheduler(root);
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
            self.heap.markValues(process.async_results.items);
            // Продолжение только ТЕКУЩЕГО подключённого процесса живёт в
            // self.stack/self.frames (помечено выше) — у всех остальных
            // процессов их приостановленное состояние хранится напрямую в
            // собственных полях stack/frames.
            self.heap.markValues(process.stack.items);
            for (process.frames.items) |frame| self.heap.markValues(frame.locals);
        }
        if (self.failure) |failure| self.heap.markValue(.{ .heap_string = failure });
        self.heap.markValues(self.heap.pinned.items);
        self.heap.sweep();
    }

    fn step(self: *Vm) anyerror!StepOutcome {
        const frame_index = self.frames.items.len - 1;
        const frame = &self.frames.items[frame_index];
        const compiled = self.program.functionConst(frame.function_id) orelse {
            try self.fault("Runtime Error: неизвестная функция", .{});
            return .none;
        };
        if (frame.ip >= compiled.instructions.items.len) {
            return if (try self.finishFrame(.{ .void = {} })) |result| .{ .completed = result } else .none;
        }
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
            .receive => {
                if (try self.receive()) {
                    frame.ip -= 1;
                    return .suspended;
                }
            },
            .observe => try self.observe(),
            .get_signal => {
                if (try self.getSignal()) {
                    frame.ip -= 1;
                    return .suspended;
                }
            },
            .await_task => {
                if (try self.awaitTask()) {
                    frame.ip -= 1;
                    return .suspended;
                }
            },
            .select_wait => {
                if (try self.selectWait()) {
                    frame.ip -= 1;
                    return .suspended;
                }
            },
            .process_id => try self.processId(),
            .current_process => try self.currentProcess(),
            .kill_process => try self.killProcess(),
            .link_process => try self.linkProcess(),
            .set_mailbox_capacity => try self.setMailboxCapacity(),
            .send_or => try self.sendOr(),
            .request_cancel => try self.requestCancel(),
            .is_cancelled => try self.isCancelled(),
            .build_closure => |closure| try self.buildClosure(closure),
            .return_value => {
                const popped = try self.pop();
                return if (try self.finishFrame(popped)) |result| .{ .completed = result } else .none;
            },
            .return_void => return if (try self.finishFrame(.{ .void = {} })) |result| .{ .completed = result } else .none,
            .build_tuple => |count| try self.buildAggregate(null, count),
            .build_struct => |structure| try self.buildStruct(compiled, structure),
            .build_array => |count| try self.buildArray(count),
            .array_length => try self.arrayLength(),
            .string_length => try self.stringLength(),
            .array_get_or => try self.arrayGetOr(),
            .array_contains => try self.arrayContains(),
            .array_slice => try self.arraySlice(),
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
            .file_exists => try self.fileExists(),
            .file_delete => try self.fileDelete(),
            .file_read => try self.fileRead(),
            .file_write => try self.fileWrite(),
            .dir_is_dir => try self.dirIsDir(),
            .dir_create => try self.dirCreate(),
            .dir_list => try self.dirList(),
            .dir_delete => try self.dirDelete(),
            .file_open => try self.fileOpen(),
            .file_handle_read_submit => try self.fileHandleReadSubmit(),
            .file_handle_read_line_submit => try self.fileHandleReadLineSubmit(),
            .file_handle_write_submit => try self.fileHandleWriteSubmit(),
            .file_handle_close => try self.fileHandleClose(),
            .os_args => try self.osArgs(),
            .os_version => try self.osVersion(),
            .os_env_get => try self.osEnvGet(),
            .os_env_set => try self.osEnvSet(),
            .os_env_unset => try self.osEnvUnset(),
            .os_exec => try self.osExec(),
            .os_exit => try self.osExit(),
            .time_now => try self.timeNow(),
            .time_monotonic => try self.timeMonotonic(),
            .time_sleep => try self.timeSleep(),
            .time_sleep_submit => try self.timeSleepSubmit(),
            .io_print => try self.ioPrint(false),
            .io_println => try self.ioPrint(true),
            .io_read_line => try self.ioReadLine(),
            .str_from_bytes => try self.strFromBytes(),
            .str_to_bytes => try self.strToBytes(),
            .str_to_runes => try self.strToRunes(),
            .str_from_runes => try self.strFromRunes(),
            .str_code_point => try self.strCodePoint(),
            .str_to_number => try self.strToNumber(),
            .str_number_to_str => try self.strNumberToStr(),
            .str_int_to_str => try self.strIntToStr(),
            .str_upper => try self.strUpper(),
            .str_lower => try self.strLower(),
            .str_ends_with => try self.strEndsWith(),
            .str_starts_with => try self.strStartsWith(),
            .str_contains => try self.strContains(),
            .str_find => try self.strFind(),
            .str_replace => try self.strReplace(),
            .str_trim => try self.strTrim(),
            .str_split => try self.strSplit(),
            .str_join => try self.strJoin(),
            .str_slice => try self.strSlice(),
            .str_is_digit_or_letter => try self.strIsDigitOrLetter(),
            .str_is_letter => try self.strIsLetter(),
            .str_is_digit => try self.strIsDigit(),
            .int_cast => try self.intCast(),
            .to_display_string => try self.toDisplayString(),
            .gzip_decompress_submit => try self.gzipDecompressSubmit(),
            .syntax_structs => try self.syntaxStructs(),
            .syntax_fields => try self.syntaxFields(),
            .syntax_imports => try self.syntaxImports(),
            .syntax_annotations => try self.syntaxAnnotations(),
            .syntax_annotation_arg => try self.syntaxAnnotationArg(),
            .syntax_field_annotations => try self.syntaxFieldAnnotations(),
            .syntax_field_annotation_arg => try self.syntaxFieldAnnotationArg(),
            .connection_read_submit => try self.connectionReadSubmit(),
            .connection_read_line_submit => try self.connectionReadLineSubmit(),
            .connection_write_submit => try self.connectionWriteSubmit(),
            .connection_close => try self.connectionClose(),
            .url_encode => try self.urlEncode(),
            .url_decode => try self.urlDecode(),
            .http_request_submit => try self.httpRequestSubmit(),
            .http_request_no_redirect_submit => try self.httpRequestNoRedirectSubmit(),
            .sql_open_submit => try self.sqlOpenSubmit(),
            .sql_exec_submit => try self.sqlExecSubmit(),
            .sql_query_submit => try self.sqlQuerySubmit(),
            .sql_close => try self.sqlClose(),
            .crypto_hmac_sha256_b64url => try self.cryptoHmacSha256Base64Url(),
            .crypto_base64url_encode => try self.cryptoBase64UrlEncode(),
            .crypto_base64url_decode => try self.cryptoBase64UrlDecode(),
            .crypto_timing_safe_eq => try self.cryptoTimingSafeEq(),
            .crypto_sha256_b64url => try self.cryptoSha256Base64Url(),
            .crypto_pbkdf2_sha256_b64url => try self.cryptoPbkdf2Sha256Base64Url(),
            .crypto_random_bytes_b64url => try self.cryptoRandomBytesBase64Url(),
            .crypto_es256_generate_keys => try self.cryptoEs256GenerateKeys(),
            .crypto_es256_sign => try self.cryptoEs256Sign(),
            .crypto_es256_verify => try self.cryptoEs256Verify(),
            .http_request_respond_headers => try self.httpRequestRespondHeaders(),
            .http_listen => try self.httpListen(),
            .http_accept_submit => try self.httpAcceptSubmit(),
            .http_request_method => try self.httpRequestMethod(),
            .http_request_path => try self.httpRequestPath(),
            .http_request_body => try self.httpRequestBody(),
            .http_request_header => try self.httpRequestHeader(),
            .http_request_respond => try self.httpRequestRespond(),
            .call_foreign => |foreign_call| try self.callForeign(compiled, foreign_call.constant_index, foreign_call.argument_count),
            .file_read_submit => try self.fileReadSubmit(),
            .file_write_submit => try self.fileWriteSubmit(),
            .net_connect_submit => try self.netConnectSubmit(),
            .await_async => {
                if (try self.awaitAsync()) {
                    frame.ip -= 1;
                    return .suspended;
                }
            },
        }
        return .none;
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
            .interface_vtable, .interface_vtables => {
                try self.fault("Runtime Error: vtable интерфейса нельзя использовать как значение", .{});
                return;
            },
            .foreign_function => {
                try self.fault("Runtime Error: описание 'внешний'-функции нельзя использовать как значение", .{});
                return;
            },
        };
        try self.stack.append(self.allocator, runtime_value);
    }

    fn fileExists(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("фс::есть", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "фс::есть", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const path = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: фс.есть() ожидает путь типа Строка", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'фс::есть' недоступно в этом runtime-таргете", .{});
            return;
        } else {
            var io = std.Io.Threaded.init(self.allocator, .{});
            defer io.deinit();
            std.Io.Dir.cwd().access(io.io(), path, .{}) catch {
                try self.stack.append(self.allocator, .{ .boolean = false });
                return;
            };
            try self.stack.append(self.allocator, .{ .boolean = true });
        }
    }

    fn fileDelete(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("фс::удалить", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "фс::удалить", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const path = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: фс.удалить() ожидает путь типа Строка", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'фс::удалить' недоступно в этом runtime-таргете", .{});
            return;
        } else {
            var io = std.Io.Threaded.init(self.allocator, .{});
            defer io.deinit();
            std.Io.Dir.cwd().deleteFile(io.io(), path) catch {
                try self.stack.append(self.allocator, .{ .boolean = false });
                return;
            };
            try self.stack.append(self.allocator, .{ .boolean = true });
        }
    }

    fn fileRead(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("фс::прочитать", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "фс::прочитать", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const path = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: фс.прочитать() ожидает путь типа Строка", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'фс::прочитать' недоступно в этом runtime-таргете", .{});
            return;
        }
        var io = std.Io.Threaded.init(self.allocator, .{});
        defer io.deinit();
        const bytes = std.Io.Dir.cwd().readFileAlloc(io.io(), path, self.allocator, .unlimited) catch |err| {
            try self.pushErrorResult(@errorName(err));
            return;
        };
        const heap_string = try self.heap.createString(bytes);
        try self.pushSuccessResult(.{ .heap_string = heap_string });
    }

    fn fileWrite(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("фс::записать", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "фс::записать", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const content = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: фс.записать() ожидает содержимое типа Строка", .{});
            return;
        };
        const path = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: фс.записать() ожидает путь типа Строка", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'фс::записать' недоступно в этом runtime-таргете", .{});
            return;
        }
        var io = std.Io.Threaded.init(self.allocator, .{});
        defer io.deinit();
        std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = path, .data = content }) catch |err| {
            try self.pushErrorResult(@errorName(err));
            return;
        };
        try self.pushSuccessResult(.{ .number = @floatFromInt(content.len) });
    }

    fn fileReadSubmit(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("фс::прочитать", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "фс::прочитать", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const path = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: фс.прочитать() ожидает путь типа Строка", .{});
            return;
        };
        const process = self.current_process orelse {
            try self.fault("Runtime Error: фс.прочитать() вызвано вне процесса", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'фс::прочитать' недоступно в этом runtime-таргете", .{});
        } else {
            submitFileRead(self, path, process.id);
        }
    }

    fn fileWriteSubmit(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("фс::записать", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "фс::записать", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const content = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: фс.записать() ожидает содержимое типа Строка", .{});
            return;
        };
        const path = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: фс.записать() ожидает путь типа Строка", .{});
            return;
        };
        const process = self.current_process orelse {
            try self.fault("Runtime Error: фс.записать() вызвано вне процесса", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'фс::записать' недоступно в этом runtime-таргете", .{});
        } else {
            submitFileWrite(self, path, content, process.id);
        }
    }

    // Единственная точка настоящей приостановки — process.async_results
    // ОТДЕЛЬНАЯ от mailbox/signals очередь (value.zig), так что результат
    // фонового I/O не может быть перепутан с обычным сообщением или
    // сигналом наблюдателя, пришедшим, пока процесс ждал.
    fn awaitAsync(self: *Vm) anyerror!bool {
        const process = self.current_process orelse {
            try self.fault("Runtime Error: await_async вне процесса", .{});
            return false;
        };
        if (process.async_results.items.len == 0) return true;
        const result = process.async_results.orderedRemove(0);
        try self.stack.append(self.allocator, result);
        return false;
    }

    fn fileOpen(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("фс::открыть", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "фс::открыть", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const path = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: фс.открыть() ожидает путь типа Строка", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'фс::открыть' недоступно в этом runtime-таргете", .{});
            return;
        }
        var io = std.Io.Threaded.init(self.allocator, .{});
        defer io.deinit();
        // Открыть-или-создать без стирания существующего содержимого — но
        // см. doc-комментарий `FileHandle` в `value.zig` о том, почему
        // дескриптографияр не держится открытым: `access` лишь проверяет
        // существование (создавая пустой файл, если его нет), а каждый
        // последующий метод переоткрывает файл по пути.
        std.Io.Dir.cwd().access(io.io(), path, .{}) catch {
            std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = path, .data = "" }) catch |err| {
                try self.pushErrorResult(@errorName(err));
                return;
            };
        };
        const handle = try self.heap.createFile(path);
        try self.pushSuccessResult(.{ .file = handle });
    }

    fn popFileHandle(self: *Vm, method_name: []const u8) anyerror!?*value.FileHandle {
        const receiver = try self.pop();
        return switch (receiver) {
            .file => |handle| handle,
            else => {
                try self.fault("Runtime Error: {s} ожидает файловый дескриптографияр", .{method_name});
                return null;
            },
        };
    }

    fn fileHandleReadSubmit(self: *Vm) anyerror!void {
        const handle = try self.popFileHandle("Файл.прочитать()") orelse return;
        if (!handle.is_open) {
            const result = try self.buildErrorResultValue("фс", "файл уже закрыт");
            try self.appendAsyncResultForCurrentProcess(result);
            return;
        }
        if (handle.in_flight) {
            const result = try self.buildErrorResultValue("фс", "файл уже используется другой операцией");
            try self.appendAsyncResultForCurrentProcess(result);
            return;
        }
        const process = self.current_process orelse {
            try self.fault("Runtime Error: Файл.прочитать() вызвано вне процесса", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'Файл.прочитать' недоступно в этом runtime-таргете", .{});
            return;
        }
        handle.in_flight = true;
        try self.heap.pin(.{ .file = handle });
        submitFileHandleRead(self, handle, handle.path, handle.offset, false, process.id);
    }

    fn fileHandleReadLineSubmit(self: *Vm) anyerror!void {
        const handle = try self.popFileHandle("Файл.прочитать_строку()") orelse return;
        if (!handle.is_open) {
            const result = try self.buildErrorResultValue("фс", "файл уже закрыт");
            try self.appendAsyncResultForCurrentProcess(result);
            return;
        }
        if (handle.in_flight) {
            const result = try self.buildErrorResultValue("фс", "файл уже используется другой операцией");
            try self.appendAsyncResultForCurrentProcess(result);
            return;
        }
        const process = self.current_process orelse {
            try self.fault("Runtime Error: Файл.прочитать_строку() вызвано вне процесса", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'Файл.прочитать_строку' недоступно в этом runtime-таргете", .{});
            return;
        }
        handle.in_flight = true;
        try self.heap.pin(.{ .file = handle });
        submitFileHandleRead(self, handle, handle.path, handle.offset, true, process.id);
    }

    fn fileHandleWriteSubmit(self: *Vm) anyerror!void {
        const content = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: Файл.записать() ожидает содержимое типа Строка", .{});
            return;
        };
        const handle = try self.popFileHandle("Файл.записать()") orelse return;
        if (!handle.is_open) {
            const result = try self.buildErrorResultValue("фс", "файл не открыт для записи");
            try self.appendAsyncResultForCurrentProcess(result);
            return;
        }
        if (handle.in_flight) {
            const result = try self.buildErrorResultValue("фс", "файл уже используется другой операцией");
            try self.appendAsyncResultForCurrentProcess(result);
            return;
        }
        const process = self.current_process orelse {
            try self.fault("Runtime Error: Файл.записать() вызвано вне процесса", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'Файл.записать' недоступно в этом runtime-таргете", .{});
            return;
        }
        handle.in_flight = true;
        try self.heap.pin(.{ .file = handle });
        submitFileHandleWrite(self, handle, handle.path, content, handle.offset, process.id);
    }

    fn fileHandleClose(self: *Vm) anyerror!void {
        const handle = try self.popFileHandle("Файл.закрыть()") orelse return;
        handle.is_open = false;
        try self.stack.append(self.allocator, .{ .void = {} });
    }

    fn dirIsDir(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("фс::это_директория", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "фс::это_директория", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const path = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: фс.это_директория() ожидает путь типа Строка", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'фс::это_директория' недоступно в этом runtime-таргете", .{});
            return;
        }
        var io = std.Io.Threaded.init(self.allocator, .{});
        defer io.deinit();
        const stat = std.Io.Dir.cwd().statFile(io.io(), path, .{}) catch {
            try self.stack.append(self.allocator, .{ .boolean = false });
            return;
        };
        try self.stack.append(self.allocator, .{ .boolean = stat.kind == .directory });
    }

    fn dirCreate(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("фс::создать_директорию", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "фс::создать_директорию", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const path = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: фс.создать_директорию() ожидает путь типа Строка", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'фс::создать_директорию' недоступно в этом runtime-таргете", .{});
            return;
        }
        var io = std.Io.Threaded.init(self.allocator, .{});
        defer io.deinit();
        std.Io.Dir.cwd().createDirPath(io.io(), path) catch |err| {
            try self.pushErrorResult(@errorName(err));
            return;
        };
        try self.pushSuccessResult(.{ .number = 0 });
    }

    fn dirList(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("фс::список_директории", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "фс::список_директории", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const path = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: фс.список_директории() ожидает путь типа Строка", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'фс::список_директории' недоступно в этом runtime-таргете", .{});
            return;
        }
        var io = std.Io.Threaded.init(self.allocator, .{});
        defer io.deinit();
        var dir = std.Io.Dir.cwd().openDir(io.io(), path, .{ .iterate = true }) catch |err| {
            try self.pushErrorResult(@errorName(err));
            return;
        };
        defer dir.close(io.io());
        var names: std.ArrayList(value.Value) = .empty;
        errdefer names.deinit(self.allocator);
        var iterator = dir.iterate();
        while (try iterator.next(io.io())) |entry| {
            const heap_string = try self.heap.createString(try self.allocator.dupe(u8, entry.name));
            try names.append(self.allocator, .{ .heap_string = heap_string });
        }
        const array = try self.heap.createArray(try names.toOwnedSlice(self.allocator));
        try self.pushSuccessResult(.{ .array = array });
    }

    fn dirDelete(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("фс::удалить_директорию", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "фс::удалить_директорию", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const path = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: фс.удалить_директорию() ожидает путь типа Строка", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'фс::удалить_директорию' недоступно в этом runtime-таргете", .{});
            return;
        }
        var io = std.Io.Threaded.init(self.allocator, .{});
        defer io.deinit();
        // Сначала пробуем простое удаление (файл или уже пустая
        // директория), и только если оно не удалось (непустая директория) —
        // рекурсивное удаление: `deleteDir` перед `deleteTree`.
        std.Io.Dir.cwd().deleteDir(io.io(), path) catch {
            std.Io.Dir.cwd().deleteTree(io.io(), path) catch |err| {
                try self.pushErrorResult(@errorName(err));
                return;
            };
            try self.pushSuccessResult(.{ .number = 0 });
            return;
        };
        try self.pushSuccessResult(.{ .number = 0 });
    }

    fn osArgs(self: *Vm) anyerror!void {
        const elements = try self.allocator.alloc(value.Value, self.program_args.len);
        errdefer self.allocator.free(elements);
        for (self.program_args, 0..) |argument, index| {
            elements[index] = .{ .heap_string = try self.heap.createString(try self.allocator.dupe(u8, argument)) };
        }
        const array = try self.heap.createArray(elements);
        try self.stack.append(self.allocator, .{ .array = array });
    }

    fn osVersion(self: *Vm) anyerror!void {
        const heap_string = try self.heap.createString(try self.allocator.dupe(u8, "0.4.0"));
        try self.stack.append(self.allocator, .{ .heap_string = heap_string });
    }

    fn osEnvGet(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("ос::окружение", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "ос::окружение", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const name = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: ос.окружение() ожидает имя типа Строка", .{});
            return;
        };
        // `if`/`else` (не форма "ранний возврат, затем сквозной проход",
        // используемая в остальном файле) — нужна здесь, чтобы freestanding-
        // ветка вообще никогда не подвергалась семантическому анализу:
        // `std.c.getenv` — настоящий extern libc без freestanding-заглушки,
        // в отличие от вызовов `std.Io.Dir`/`std.Io.Threaded`, которые
        // используют билтины `фс.*`.
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'ос::окружение' недоступно в этом runtime-таргете", .{});
        } else if (comptime builtin.target.os.tag == .windows) {
            if (try windows_env.getenv(self.allocator, name)) |raw_value| {
                defer self.allocator.free(raw_value);
                const heap_string = try self.heap.createString(try self.allocator.dupe(u8, raw_value));
                try self.pushOption(.{ .heap_string = heap_string });
            } else {
                try self.pushOption(null);
            }
        } else {
            const name_z = try self.allocator.dupeZ(u8, name);
            defer self.allocator.free(name_z);
            if (std.c.getenv(name_z)) |raw_value| {
                const heap_string = try self.heap.createString(try self.allocator.dupe(u8, std.mem.span(raw_value)));
                try self.pushOption(.{ .heap_string = heap_string });
            } else {
                try self.pushOption(null);
            }
        }
    }

    fn osEnvSet(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("ос::установить_окружение", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "ос::установить_окружение", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const env_value = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: ос.установить_окружение() ожидает значение типа Строка", .{});
            return;
        };
        const name = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: ос.установить_окружение() ожидает имя типа Строка", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'ос::установить_окружение' недоступно в этом runtime-таргете", .{});
        } else if (comptime builtin.target.os.tag == .windows) {
            const status = try windows_env.setenv(self.allocator, name, env_value);
            if (status != 0) {
                try self.pushErrorResultForModule("ос", "не удалось установить переменную окружения");
            } else {
                try self.pushSuccessResult(.{ .number = 0 });
            }
        } else {
            const name_z = try self.allocator.dupeZ(u8, name);
            defer self.allocator.free(name_z);
            const value_z = try self.allocator.dupeZ(u8, env_value);
            defer self.allocator.free(value_z);
            if (posix_env.setenv(name_z, value_z, 1) != 0) {
                try self.pushErrorResultForModule("ос", "не удалось установить переменную окружения");
            } else {
                try self.pushSuccessResult(.{ .number = 0 });
            }
        }
    }

    fn osEnvUnset(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("ос::удалить_окружение", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "ос::удалить_окружение", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const name = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: ос.удалить_окружение() ожидает имя типа Строка", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'ос::удалить_окружение' недоступно в этом runtime-таргете", .{});
        } else if (comptime builtin.target.os.tag == .windows) {
            const status = try windows_env.unsetenv(self.allocator, name);
            try self.stack.append(self.allocator, .{ .boolean = status == 0 });
        } else {
            const name_z = try self.allocator.dupeZ(u8, name);
            defer self.allocator.free(name_z);
            try self.stack.append(self.allocator, .{ .boolean = posix_env.unsetenv(name_z) == 0 });
        }
    }

    fn osExec(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("ос::выполнить", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "ос::выполнить", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const working_dir = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: ос.выполнить() ожидает рабочую директорию типа Строка", .{});
            return;
        };
        const args_value = try self.pop();
        const args_array = switch (args_value) {
            .array => |array| array,
            else => {
                try self.fault("Runtime Error: ос.выполнить() ожидает Массив(Строка) вторым аргументом", .{});
                return;
            },
        };
        const program = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: ос.выполнить() ожидает программу типа Строка первым аргументом", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'ос::выполнить' недоступно в этом runtime-таргете", .{});
            return;
        } else {
            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(self.allocator);
            try argv.append(self.allocator, program);
            for (args_array.elements) |element| {
                const element_string = element.stringBytes() orelse {
                    try self.fault("Runtime Error: ос.выполнить() ожидает Массив(Строка) вторым аргументом", .{});
                    return;
                };
                try argv.append(self.allocator, element_string);
            }
            var io = std.Io.Threaded.init(self.allocator, .{});
            defer io.deinit();
            // `std.Io.Threaded.init(allocator, .{})` (без `.environ`)
            // выставляет `environ_initialized = options.environ.block.
            // isEmpty()` в TRUE (Zig 0.16, `Io/Threaded.zig`) — поэтому
            // ленивый вызов `scanEnviron()` внутри `processSpawn*` видит
            // "уже инициализировано" и полностью пропускает сканирование
            // РЕАЛЬНОГО окружения ОС, порождая каждый дочерний процесс с
            // абсолютно ПУСТЫМ окружением. Обходится целиком внутри этой
            // функции (VM-wide прокладки `Io` для исправления в источнике
            // нет) вручную построенным `Environ.Map` из живой глобальной
            // переменной libc `environ` (мутируется на месте через `setenv`
            // из `ос.установить_окружение`, см. `osEnvSet`) и передачей его
            // явно через `RunOptions.environ_map` — полностью обходя
            // сломанный путь авто-сканирования `Io.Threaded`.
            // `std.process.Environ.Block` — это `PosixBlock` (`.slice` из
            // записей в форме `std.c.environ`) на POSIX, но `GlobalBlock`
            // (вообще без поля `.slice`) на Windows — `windows_env.
            // buildEnvironMap` там читает живой блок иначе
            // (`GetEnvironmentStringsW`, см. её собственный комментарий).
            var environ_map = if (comptime builtin.target.os.tag == .windows)
                try windows_env.buildEnvironMap(self.allocator)
            else blk: {
                const raw_environ: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
                var environ_len: usize = 0;
                while (raw_environ[environ_len] != null) : (environ_len += 1) {}
                break :blk try std.process.Environ.createMap(.{ .block = .{ .slice = raw_environ[0..environ_len :null] } }, self.allocator);
            };
            defer environ_map.deinit();
            // Пустой `working_dir` значит "выполнить в текущей директории"
            // (задокументированный контракт, соответствует каждому реальному
            // вызывающему в panosiki — `configurator.ps`/`storage_manager.ps`
            // оба передают `""`, когда нет конкретной директории для
            // chdir). `.{ .path = "" }`, переданный в `Child.Cwd`
            // безусловно, привёл бы к ошибке: `chdir("")` в Zig 0.16 всегда
            // возвращает `error.FileNotFound` (POSIX `chdir` прямо отвергает
            // пустой путь).
            const cwd: std.process.Child.Cwd = if (working_dir.len == 0) .inherit else .{ .path = working_dir };
            const result = std.process.run(self.allocator, io.io(), .{
                .argv = argv.items,
                .cwd = cwd,
                .environ_map = &environ_map,
            }) catch |err| {
                try self.pushErrorResultForModule("ос", @errorName(err));
                return;
            };
            defer self.allocator.free(result.stdout);
            defer self.allocator.free(result.stderr);
            const exit_code: f64 = switch (result.term) {
                .exited => |code| @floatFromInt(code),
                .signal => |signal| 128 + @as(f64, @floatFromInt(@intFromEnum(signal))),
                .stopped => |signal| 128 + @as(f64, @floatFromInt(@intFromEnum(signal))),
                .unknown => |code| @floatFromInt(code),
            };
            const tuple_elements = try self.allocator.alloc(value.Value, 3);
            tuple_elements[0] = .{ .number = exit_code };
            tuple_elements[1] = .{ .heap_string = try self.heap.createString(try self.allocator.dupe(u8, result.stdout)) };
            tuple_elements[2] = .{ .heap_string = try self.heap.createString(try self.allocator.dupe(u8, result.stderr)) };
            const tuple = try self.heap.createAggregate(null, tuple_elements);
            try self.pushSuccessResult(.{ .aggregate = tuple });
        }
    }

    fn osExit(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("ос::завершить", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "ос::завершить", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const code = try self.number(try self.pop());
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'ос::завершить' недоступно в этом runtime-таргете", .{});
        } else {
            std.process.exit(@intFromFloat(code));
        }
    }

    // Часы, предоставляемые хостом, для freestanding wasm32 browser-
    // интерпретатора — у wasm32-freestanding нет собственных системных
    // вызовов (нет `std.time`), поэтому `время.сейчас_мс`/`.монотонно_мс`
    // нужно, чтобы встраивающий JS сам предоставил реальное время (так же,
    // как это уже делает объект импорта `env` в
    // `docs/src/assets/interactive.js`). Объявлено только здесь (не
    // экспортируется из `zig/browser/main.zig`) — недостижимый `extern` в
    // сборке не под wasm32 просто мёртв, линкер его никогда не
    // импортирует.
    extern "env" fn panos_host_time_now_ms() f64;
    extern "env" fn panos_host_tick_now_ms() f64;

    fn timeNow(self: *Vm) anyerror!void {
        const millis: f64 = if (comptime builtin.target.cpu.arch == .wasm32 and builtin.target.os.tag == .freestanding)
            panos_host_time_now_ms()
        else blk: {
            var io: std.Io.Threaded = .init(self.allocator, .{});
            defer io.deinit();
            const now_ns = std.Io.Timestamp.now(io.io(), .real).nanoseconds;
            break :blk @as(f64, @floatFromInt(now_ns)) / std.time.ns_per_ms;
        };
        try self.stack.append(self.allocator, .{ .number = millis });
    }

    fn timeMonotonic(self: *Vm) anyerror!void {
        const millis: f64 = if (comptime builtin.target.cpu.arch == .wasm32 and builtin.target.os.tag == .freestanding)
            panos_host_tick_now_ms()
        else blk: {
            var io: std.Io.Threaded = .init(self.allocator, .{});
            defer io.deinit();
            const now_ns = std.Io.Timestamp.now(io.io(), .awake).nanoseconds;
            if (self.monotonic_baseline_ns == null) self.monotonic_baseline_ns = now_ns;
            const delta_ns = now_ns - self.monotonic_baseline_ns.?;
            break :blk @as(f64, @floatFromInt(delta_ns)) / std.time.ns_per_ms;
        };
        try self.stack.append(self.allocator, .{ .number = millis });
    }

    fn timeSleep(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("время::спать_мс", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "время::спать_мс", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const millis = try self.number(try self.pop());
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'время::спать_мс' недоступно в этом runtime-таргете", .{});
            return;
        }
        const clamped: i64 = if (millis > 0) @intFromFloat(millis) else 0;
        var io: std.Io.Threaded = .init(self.allocator, .{});
        defer io.deinit();
        std.Io.sleep(io.io(), .fromMilliseconds(clamped), .awake) catch {};
        try self.stack.append(self.allocator, .{ .number = millis });
    }

    // Неблокирующий вариант timeSleep() выше — submit кладёт задачу в
    // воркер-пул и возвращает управление немедленно, await_async
    // (эмитится компилятором сразу после) — единственная точка настоящей
    // приостановки процесса. См. compiler.zig compileTimeBuiltin: без
    // этого `запусти другой_процесс()` перед время.спать_мс(N) никогда
    // не получал такта планировщика, пока текущий процесс "спал", потому
    // что синхронный std.Io.sleep() блокировал единственный OS-поток
    // целиком.
    fn timeSleepSubmit(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("время::спать_мс", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "время::спать_мс", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const millis = try self.number(try self.pop());
        const process = self.current_process orelse {
            try self.fault("Runtime Error: время.спать_мс() вызвано вне процесса", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'время::спать_мс' недоступно в этом runtime-таргете", .{});
            return;
        }
        submitTimeSleep(self, millis, process.id);
    }

    // Блокирующее построчное чтение реального stdin — `native_only` по
    // `target.zig`: у вкладки браузера нет реального stdin, на котором
    // можно блокироваться, та же причина, что и у freestanding-паники
    // `время.спать_мс`. Возвращает `Результат.Неудача` только при
    // НЕМЕДЛЕННОМ EOF (ни одного байта не прочитано вообще) — последняя
    // незавершённая строка перед EOF всё равно приходит как `Успех(...)`,
    // как обычное поведение `readline`/`fgets` в других местах.
    fn ioReadLine(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("ввод_вывод::прочитать_строку", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "ввод_вывод::прочитать_строку", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'ввод_вывод::прочитать_строку' недоступно в этом runtime-таргете", .{});
            return;
        }
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.allocator);
        var got_any = false;
        var buf: [1]u8 = undefined;
        // `std.posix.read(std.posix.STDIN_FILENO, ...)` не существует на
        // Windows (`fd_t` там основан на хендлах, не на POSIX-целых fd —
        // `STDIN_FILENO` — чисто POSIX-концепция) — `std.Io.File.stdin()` +
        // `.readStreaming` абстрагируют это единообразно для обеих платформ
        // (тот же паттерн, что используют `submitFileRead`/`submitFileWrite`
        // для `фс.*` выше).
        var io: std.Io.Threaded = .init(self.allocator, .{});
        defer io.deinit();
        while (true) {
            const n = std.Io.File.stdin().readStreaming(io.io(), &.{&buf}) catch |err| {
                if (err == error.EndOfStream) break;
                try self.fault("Runtime Error: не удалось прочитать stdin: {s}", .{@errorName(err)});
                return;
            };
            if (n == 0) break;
            got_any = true;
            if (buf[0] == '\n') break;
            try line.append(self.allocator, buf[0]);
        }
        if (!got_any) {
            try self.pushErrorResultForModule("ввод_вывод", "EOF");
            return;
        }
        var slice = line.items;
        if (slice.len > 0 and slice[slice.len - 1] == '\r') slice = slice[0 .. slice.len - 1];
        const heap_string = try self.heap.createString(try self.allocator.dupe(u8, slice));
        try self.pushSuccessResult(.{ .heap_string = heap_string });
    }

    fn ioPrint(self: *Vm, newline: bool) anyerror!void {
        const popped = try self.pop();
        const rendered = try renderRuntimeValue(self.allocator, popped);
        defer self.allocator.free(rendered);
        try self.output.appendSlice(self.allocator, rendered);
        if (newline) try self.output.append(self.allocator, '\n');
        if (self.live_stdout and comptime builtin.target.os.tag != .freestanding) {
            // `.writer()` (positional/pwrite-style) starts EACH new
            // `Writer` instance's position at 0 — a fresh instance per
            // call (as here) would overwrite at offset 0 instead of
            // appending, silently clobbering earlier output on a real
            // terminal/pipe fd. `.writerStreaming()` has no independent
            // position tracking, always appends — confirmed by a live
            // regression: positional dropped every print but the last.
            var io = std.Io.Threaded.init(self.allocator, .{});
            defer io.deinit();
            var writer = std.Io.File.stdout().writerStreaming(io.io(), &.{});
            writer.interface.writeAll(rendered) catch {};
            if (newline) writer.interface.writeAll("\n") catch {};
            writer.interface.flush() catch {};
        }
        try self.stack.append(self.allocator, .{ .void = {} });
    }

    // Байтовое смещение N-й руны (кодпоинта) в `string` — само `string.len`
    // тоже валидный результат (позиция сразу за последней руной),
    // используется как верхняя граница в конвертации индекса руны в байтовое
    // смещение у `strSlice`/`strFind`. Тот же обход UTF-8, что уже делает
    // `stringAt` (индексация, `s[i]`), вынесен отдельно, т.к. он нужен и
    // `строки.срез`/`.найти`.
    fn runeByteOffset(self: *Vm, string: []const u8, rune_index: usize) anyerror!usize {
        var offset: usize = 0;
        var current: usize = 0;
        while (current < rune_index) {
            if (offset >= string.len) {
                try self.fault("Runtime Error: индекс строки вне границ", .{});
                return 0;
            }
            const width = std.unicode.utf8ByteSequenceLength(string[offset]) catch {
                try self.fault("Runtime Error: строка содержит некорректный UTF-8", .{});
                return 0;
            };
            offset += width;
            current += 1;
        }
        return offset;
    }

    fn strFromBytes(self: *Vm) anyerror!void {
        const array_value = try self.pop();
        const array = switch (array_value) {
            .array => |a| a,
            else => {
                try self.fault("Runtime Error: строки.из_байтов() ожидает Массив(Целое)", .{});
                return;
            },
        };
        const bytes = try self.allocator.alloc(u8, array.elements.len);
        errdefer self.allocator.free(bytes);
        for (array.elements, 0..) |element, i| {
            const n = try self.number(element);
            if (n < 0 or n > 255 or n != std.math.trunc(n)) {
                try self.fault("Runtime Error: строки.из_байтов(): элемент вне диапазона 0..255", .{});
                return;
            }
            bytes[i] = @intFromFloat(n);
        }
        const result = try self.heap.createString(bytes);
        try self.stack.append(self.allocator, .{ .heap_string = result });
    }

    // Массовый (по всей строке) аналог `строки.байт`/`длина_байт` — тот же
    // тип/форма элементов, что и на входе `из_байтов`, только производится,
    // а не потребляется.
    fn strToBytes(self: *Vm) anyerror!void {
        const string_value = try self.pop();
        const string = string_value.stringBytes() orelse {
            try self.fault("Runtime Error: строки.в_байты() ожидает строку", .{});
            return;
        };
        const elements = try self.allocator.alloc(value.Value, string.len);
        errdefer self.allocator.free(elements);
        for (string, 0..) |byte, index| elements[index] = .{ .number = @floatFromInt(byte) };
        const array = try self.heap.createArray(elements);
        try self.stack.append(self.allocator, .{ .array = array });
    }

    // Массовое (по всей строке) декодирование рун — `Массив(Целое)` значений
    // кодпоинтов, то же UTF-8-декодирование, что у `строки.длина`/`срез`
    // (`Utf8View`).
    fn strToRunes(self: *Vm) anyerror!void {
        const string_value = try self.pop();
        const string = string_value.stringBytes() orelse {
            try self.fault("Runtime Error: строки.в_руны() ожидает строку", .{});
            return;
        };
        var view = std.unicode.Utf8View.init(string) catch {
            try self.fault("Runtime Error: строка содержит некорректный UTF-8", .{});
            return;
        };
        var codepoints = std.ArrayList(value.Value).empty;
        errdefer codepoints.deinit(self.allocator);
        var iterator = view.iterator();
        while (iterator.nextCodepoint()) |codepoint| {
            try codepoints.append(self.allocator, .{ .number = @floatFromInt(codepoint) });
        }
        const array = try self.heap.createArray(try codepoints.toOwnedSlice(self.allocator));
        try self.stack.append(self.allocator, .{ .array = array });
    }

    // Обратное к `в_руны` — кодирует каждый кодпоинт обратно в UTF-8, та же
    // форма валидации, что у `из_байтов` (проверка диапазона каждого
    // элемента до записи любого вывода).
    fn strFromRunes(self: *Vm) anyerror!void {
        const array_value = try self.pop();
        const array = switch (array_value) {
            .array => |a| a,
            else => {
                try self.fault("Runtime Error: строки.из_рун() ожидает Массив(Целое)", .{});
                return;
            },
        };
        var bytes = std.ArrayList(u8).empty;
        errdefer bytes.deinit(self.allocator);
        for (array.elements) |element| {
            const n = try self.number(element);
            if (n < 0 or n > 0x10FFFF or n != std.math.trunc(n)) {
                try self.fault("Runtime Error: строки.из_рун(): элемент вне диапазона codepoint", .{});
                return;
            }
            const codepoint: u21 = @intFromFloat(n);
            var buffer: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(codepoint, &buffer) catch {
                try self.fault("Runtime Error: строки.из_рун(): недопустимый codepoint", .{});
                return;
            };
            try bytes.appendSlice(self.allocator, buffer[0..len]);
        }
        const result = try self.heap.createString(try bytes.toOwnedSlice(self.allocator));
        try self.stack.append(self.allocator, .{ .heap_string = result });
    }

    // Значение кодпоинта первой руны — тот же контракт "декодировать только
    // ПЕРВЫЙ кодпоинт, остальное игнорировать", что у `strIsDigit`/
    // `strIsLetter` выше, для частой формы вызова
    // `строки.кодовая_точка(s[i])` (срез из одной руны), используемой в
    // примере из документации.
    fn strCodePoint(self: *Vm) anyerror!void {
        const string_value = try self.pop();
        const string = string_value.stringBytes() orelse {
            try self.fault("Runtime Error: строки.кодовая_точка() ожидает строку", .{});
            return;
        };
        if (string.len == 0) {
            try self.fault("Runtime Error: строки.кодовая_точка(): пустая строка", .{});
            return;
        }
        var view = std.unicode.Utf8View.init(string) catch {
            try self.fault("Runtime Error: строка содержит некорректный UTF-8", .{});
            return;
        };
        var iterator = view.iterator();
        const codepoint = iterator.nextCodepoint() orelse {
            try self.fault("Runtime Error: строки.кодовая_точка(): пустая строка", .{});
            return;
        };
        try self.stack.append(self.allocator, .{ .number = @floatFromInt(codepoint) });
    }

    fn strToNumber(self: *Vm) anyerror!void {
        const string_value = try self.pop();
        const string = string_value.stringBytes() orelse {
            try self.fault("Runtime Error: строки.в_число() ожидает строку", .{});
            return;
        };
        const parsed = std.fmt.parseFloat(f64, string) catch {
            try self.pushErrorResultForModule("строки", "не удалось разобрать число");
            return;
        };
        try self.pushSuccessResult(.{ .number = parsed });
    }

    fn strNumberToStr(self: *Vm) anyerror!void {
        const number_value = try self.number(try self.pop());
        const result = try self.heap.formatString("{d}", .{number_value});
        try self.stack.append(self.allocator, .{ .heap_string = result });
    }

    fn strIntToStr(self: *Vm) anyerror!void {
        const number_value = try self.number(try self.pop());
        const result = try self.heap.formatString("{d}", .{@as(i64, @intFromFloat(number_value))});
        try self.stack.append(self.allocator, .{ .heap_string = result });
    }

    // ASCII + кириллица (а-я/ё → А-Я/Ё) — два алфавита, которые реально
    // использует любой вызывающий код панос (язык с русскими ключевыми
    // словами, инструментарий вокруг 1С); полное unicode-приведение
    // регистра вне области этого среза.
    fn strUpper(self: *Vm) anyerror!void {
        const string_value = try self.pop();
        const string = string_value.stringBytes() orelse {
            try self.fault("Runtime Error: строки.верхний_регистр() ожидает строку", .{});
            return;
        };
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        var view = std.unicode.Utf8View.init(string) catch {
            try self.fault("Runtime Error: строка содержит некорректный UTF-8", .{});
            return;
        };
        var iterator = view.iterator();
        while (iterator.nextCodepoint()) |codepoint| {
            const upper: u21 = switch (codepoint) {
                'a'...'z' => codepoint - ('a' - 'A'),
                0x0430...0x044F => codepoint - (0x0430 - 0x0410), // а-я → А-Я
                0x0451 => 0x0401, // ё → Ё
                else => codepoint,
            };
            var buffer: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(upper, &buffer) catch unreachable;
            try out.appendSlice(self.allocator, buffer[0..len]);
        }
        const result = try self.heap.createString(try out.toOwnedSlice(self.allocator));
        try self.stack.append(self.allocator, .{ .heap_string = result });
    }

    fn strLower(self: *Vm) anyerror!void {
        const string_value = try self.pop();
        const string = string_value.stringBytes() orelse {
            try self.fault("Runtime Error: строки.нижний_регистр() ожидает строку", .{});
            return;
        };
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        var view = std.unicode.Utf8View.init(string) catch {
            try self.fault("Runtime Error: строка содержит некорректный UTF-8", .{});
            return;
        };
        var iterator = view.iterator();
        while (iterator.nextCodepoint()) |codepoint| {
            const lower: u21 = switch (codepoint) {
                'A'...'Z' => codepoint + ('a' - 'A'),
                0x0410...0x042F => codepoint + (0x0430 - 0x0410), // А-Я → а-я
                0x0401 => 0x0451, // Ё → ё
                else => codepoint,
            };
            var buffer: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(lower, &buffer) catch unreachable;
            try out.appendSlice(self.allocator, buffer[0..len]);
        }
        const result = try self.heap.createString(try out.toOwnedSlice(self.allocator));
        try self.stack.append(self.allocator, .{ .heap_string = result });
    }

    fn strEndsWith(self: *Vm) anyerror!void {
        const suffix_value = try self.pop();
        const string_value = try self.pop();
        const string = string_value.stringBytes() orelse {
            try self.fault("Runtime Error: строки.заканчивается_на() ожидает строки", .{});
            return;
        };
        const suffix = suffix_value.stringBytes() orelse {
            try self.fault("Runtime Error: строки.заканчивается_на() ожидает строки", .{});
            return;
        };
        try self.stack.append(self.allocator, .{ .boolean = std.mem.endsWith(u8, string, suffix) });
    }

    fn strStartsWith(self: *Vm) anyerror!void {
        const prefix_value = try self.pop();
        const string_value = try self.pop();
        const string = string_value.stringBytes() orelse {
            try self.fault("Runtime Error: строки.начинается_с() ожидает строки", .{});
            return;
        };
        const prefix = prefix_value.stringBytes() orelse {
            try self.fault("Runtime Error: строки.начинается_с() ожидает строки", .{});
            return;
        };
        try self.stack.append(self.allocator, .{ .boolean = std.mem.startsWith(u8, string, prefix) });
    }

    fn strContains(self: *Vm) anyerror!void {
        const needle_value = try self.pop();
        const string_value = try self.pop();
        const string = string_value.stringBytes() orelse {
            try self.fault("Runtime Error: строки.содержит() ожидает строки", .{});
            return;
        };
        const needle = needle_value.stringBytes() orelse {
            try self.fault("Runtime Error: строки.содержит() ожидает строки", .{});
            return;
        };
        try self.stack.append(self.allocator, .{ .boolean = std.mem.indexOf(u8, string, needle) != null });
    }

    // Возвращает индекс РУНЫ (не байтовое смещение) первого совпадения, по
    // явному контракту `docs/src/language/basic-types.md` ("строки.найти
    // возвращает рановый индекс") — конвертирует байтовое смещение,
    // найденное `std.mem.indexOf`, подсчётом кодпоинтов до него.
    fn strFind(self: *Vm) anyerror!void {
        const start_value = try self.pop();
        const needle_value = try self.pop();
        const string_value = try self.pop();
        const string = string_value.stringBytes() orelse {
            try self.fault("Runtime Error: строки.найти() ожидает строки", .{});
            return;
        };
        const needle = needle_value.stringBytes() orelse {
            try self.fault("Runtime Error: строки.найти() ожидает строки", .{});
            return;
        };
        const start_rune = try self.arrayIndex(start_value);
        const start_byte = try self.runeByteOffset(string, start_rune);
        if (start_byte > string.len) {
            try self.stack.append(self.allocator, .{ .number = -1 });
            return;
        }
        const relative_offset = std.mem.indexOf(u8, string[start_byte..], needle) orelse {
            try self.stack.append(self.allocator, .{ .number = -1 });
            return;
        };
        const rune_index = std.unicode.utf8CountCodepoints(string[0 .. start_byte + relative_offset]) catch {
            try self.fault("Runtime Error: строка содержит некорректный UTF-8", .{});
            return;
        };
        try self.stack.append(self.allocator, .{ .number = @floatFromInt(rune_index) });
    }

    fn strReplace(self: *Vm) anyerror!void {
        const replacement_value = try self.pop();
        const target_value = try self.pop();
        const string_value = try self.pop();
        const string = string_value.stringBytes() orelse {
            try self.fault("Runtime Error: строки.заменить() ожидает строки", .{});
            return;
        };
        const target = target_value.stringBytes() orelse {
            try self.fault("Runtime Error: строки.заменить() ожидает строки", .{});
            return;
        };
        const replacement = replacement_value.stringBytes() orelse {
            try self.fault("Runtime Error: строки.заменить() ожидает строки", .{});
            return;
        };
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        if (target.len == 0) {
            try out.appendSlice(self.allocator, string);
        } else {
            var remaining = string;
            while (std.mem.indexOf(u8, remaining, target)) |index| {
                try out.appendSlice(self.allocator, remaining[0..index]);
                try out.appendSlice(self.allocator, replacement);
                remaining = remaining[index + target.len ..];
            }
            try out.appendSlice(self.allocator, remaining);
        }
        const result = try self.heap.createString(try out.toOwnedSlice(self.allocator));
        try self.stack.append(self.allocator, .{ .heap_string = result });
    }

    fn strTrim(self: *Vm) anyerror!void {
        const string_value = try self.pop();
        const string = string_value.stringBytes() orelse {
            try self.fault("Runtime Error: строки.обрезать() ожидает строку", .{});
            return;
        };
        const trimmed = std.mem.trim(u8, string, " \t\r\n");
        const result = try self.heap.createString(try self.allocator.dupe(u8, trimmed));
        try self.stack.append(self.allocator, .{ .heap_string = result });
    }

    fn strSplit(self: *Vm) anyerror!void {
        const separator_value = try self.pop();
        const string_value = try self.pop();
        const string = string_value.stringBytes() orelse {
            try self.fault("Runtime Error: строки.разбить() ожидает строки", .{});
            return;
        };
        const separator = separator_value.stringBytes() orelse {
            try self.fault("Runtime Error: строки.разбить() ожидает строки", .{});
            return;
        };
        var parts: std.ArrayList(value.Value) = .empty;
        errdefer parts.deinit(self.allocator);
        if (separator.len == 0) {
            const copy = try self.heap.createString(try self.allocator.dupe(u8, string));
            try parts.append(self.allocator, .{ .heap_string = copy });
        } else {
            var iterator = std.mem.splitSequence(u8, string, separator);
            while (iterator.next()) |part| {
                const copy = try self.heap.createString(try self.allocator.dupe(u8, part));
                try parts.append(self.allocator, .{ .heap_string = copy });
            }
        }
        const array = try self.heap.createArray(try parts.toOwnedSlice(self.allocator));
        try self.stack.append(self.allocator, .{ .array = array });
    }

    fn strJoin(self: *Vm) anyerror!void {
        const separator_value = try self.pop();
        const array_value = try self.pop();
        const array = switch (array_value) {
            .array => |a| a,
            else => {
                try self.fault("Runtime Error: строки.соединить() ожидает Массив(Строка)", .{});
                return;
            },
        };
        const separator = separator_value.stringBytes() orelse {
            try self.fault("Runtime Error: строки.соединить() ожидает разделитель типа Строка", .{});
            return;
        };
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        for (array.elements, 0..) |element, i| {
            if (i != 0) try out.appendSlice(self.allocator, separator);
            const part = element.stringBytes() orelse {
                try self.fault("Runtime Error: строки.соединить(): элемент массива не является строкой", .{});
                return;
            };
            try out.appendSlice(self.allocator, part);
        }
        const result = try self.heap.createString(try out.toOwnedSlice(self.allocator));
        try self.stack.append(self.allocator, .{ .heap_string = result });
    }

    // По рунам (НЕ по байтам) — `строки.срез_байт` байтовый эквивалент, см.
    // `docs/src/language/basic-types.md` §"Байты" о том, почему существуют
    // оба варианта раздельно.
    fn strSlice(self: *Vm) anyerror!void {
        const end_value = try self.pop();
        const start_value = try self.pop();
        const string_value = try self.pop();
        const string = string_value.stringBytes() orelse {
            try self.fault("Runtime Error: строки.срез() ожидает строку", .{});
            return;
        };
        const start_rune = try self.arrayIndex(start_value);
        const end_rune = try self.arrayIndex(end_value);
        if (start_rune > end_rune) {
            try self.fault("Runtime Error: строки.срез(): границы вне диапазона", .{});
            return;
        }
        const start_byte = try self.runeByteOffset(string, start_rune);
        const end_byte = try self.runeByteOffset(string, end_rune);
        if (end_byte > string.len) {
            try self.fault("Runtime Error: строки.срез(): границы вне диапазона", .{});
            return;
        }
        const result = try self.heap.createString(try self.allocator.dupe(u8, string[start_byte..end_byte]));
        try self.stack.append(self.allocator, .{ .heap_string = result });
    }

    // Буквы ASCII + кириллицы (совпадает с областью `strUpper`) — ожидается
    // ввод из одной руны (типичный вызывающий код передаёт срез из одного
    // символа вроде `s[i]`), если дано больше — проверяется только ПЕРВАЯ
    // руна.
    fn strIsDigitOrLetter(self: *Vm) anyerror!void {
        const string_value = try self.pop();
        const string = string_value.stringBytes() orelse {
            try self.fault("Runtime Error: строки.цифра_или_буква() ожидает строку", .{});
            return;
        };
        if (string.len == 0) {
            try self.stack.append(self.allocator, .{ .boolean = false });
            return;
        }
        var view = std.unicode.Utf8View.init(string) catch {
            try self.fault("Runtime Error: строка содержит некорректный UTF-8", .{});
            return;
        };
        var iterator = view.iterator();
        const codepoint = iterator.nextCodepoint() orelse {
            try self.stack.append(self.allocator, .{ .boolean = false });
            return;
        };
        const is_match = switch (codepoint) {
            '0'...'9', 'a'...'z', 'A'...'Z' => true,
            0x0410...0x044F, 0x0401, 0x0451 => true, // А-Я, а-я, Ё, ё
            else => false,
        };
        try self.stack.append(self.allocator, .{ .boolean = is_match });
    }

    fn strIsLetter(self: *Vm) anyerror!void {
        const string_value = try self.pop();
        const string = string_value.stringBytes() orelse {
            try self.fault("Runtime Error: строки.это_буква() ожидает строку", .{});
            return;
        };
        if (string.len == 0) {
            try self.stack.append(self.allocator, .{ .boolean = false });
            return;
        }
        var view = std.unicode.Utf8View.init(string) catch {
            try self.fault("Runtime Error: строка содержит некорректный UTF-8", .{});
            return;
        };
        var iterator = view.iterator();
        const codepoint = iterator.nextCodepoint() orelse {
            try self.stack.append(self.allocator, .{ .boolean = false });
            return;
        };
        const is_match = switch (codepoint) {
            'a'...'z', 'A'...'Z' => true,
            0x0410...0x044F, 0x0401, 0x0451 => true, // А-Я, а-я, Ё, ё
            else => false,
        };
        try self.stack.append(self.allocator, .{ .boolean = is_match });
    }

    fn strIsDigit(self: *Vm) anyerror!void {
        const string_value = try self.pop();
        const string = string_value.stringBytes() orelse {
            try self.fault("Runtime Error: строки.это_цифра() ожидает строку", .{});
            return;
        };
        if (string.len == 0) {
            try self.stack.append(self.allocator, .{ .boolean = false });
            return;
        }
        var view = std.unicode.Utf8View.init(string) catch {
            try self.fault("Runtime Error: строка содержит некорректный UTF-8", .{});
            return;
        };
        var iterator = view.iterator();
        const codepoint = iterator.nextCodepoint() orelse {
            try self.stack.append(self.allocator, .{ .boolean = false });
            return;
        };
        try self.stack.append(self.allocator, .{ .boolean = codepoint >= '0' and codepoint <= '9' });
    }

    // `Целое(x)` — усечение к нулю, no-op если `x` уже целое значение (в
    // обоих случаях одно и то же представление `Value.number` как f64, см.
    // doc-комментарий `.int_cast` в `bytecode.zig`).
    fn intCast(self: *Vm) anyerror!void {
        const n = try self.number(try self.pop());
        try self.stack.append(self.allocator, .{ .number = std.math.trunc(n) });
    }

    fn toDisplayString(self: *Vm) anyerror!void {
        const popped = try self.pop();
        const rendered = try renderRuntimeValue(self.allocator, popped);
        const result = try self.heap.createString(rendered);
        try self.stack.append(self.allocator, .{ .heap_string = result });
    }

    fn gzipDecompressSubmit(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("сжатие::разжать_gzip", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "сжатие::разжать_gzip", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const data = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: сжатие.разжать_gzip() ожидает Строку", .{});
            return;
        };
        const process = self.current_process orelse {
            try self.fault("Runtime Error: сжатие.разжать_gzip() вызвано вне процесса", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'сжатие::разжать_gzip' недоступно в этом runtime-таргете", .{});
        } else {
            submitGzipDecompress(self, data, process.id);
        }
    }

    // `Результат.Успех(payload)` — та же форма tagged-aggregate, что уже
    // используют все остальные конструкции вариантов enum из prelude (см.
    // `Опция.Есть`/`Опция.Нет` в `queueSignal`).
    fn pushSuccessResult(self: *Vm, payload: value.Value) anyerror!void {
        const elements = try self.allocator.alloc(value.Value, 1);
        elements[0] = payload;
        const aggregate = try self.heap.createAggregate("Результат.Успех", elements);
        try self.stack.append(self.allocator, .{ .aggregate = aggregate });
    }

    // `Результат.Неудача(Ошибка("фс", message))` — обычная структура
    // `Ошибка` соответствует форме её конструктора `Ошибка(код, сообщение)`
    // (`compileErrorConstructor` в `compiler.zig`), поэтому доступ к полям
    // `.код`/`.сообщение` на этом значении работает точно так же, как у
    // `Ошибка`, сконструированной пользователем.
    fn pushErrorResult(self: *Vm, message: []const u8) anyerror!void {
        try self.pushErrorResultForModule("фс", message);
    }

    fn pushErrorResultForModule(self: *Vm, module: []const u8, message: []const u8) anyerror!void {
        const error_fields = try self.allocator.alloc(value.Value, 2);
        error_fields[0] = .{ .string = module };
        error_fields[1] = .{ .heap_string = try self.heap.formatString("{s}", .{message}) };
        const error_aggregate = try self.heap.createAggregate("Ошибка", error_fields);
        const elements = try self.allocator.alloc(value.Value, 1);
        elements[0] = .{ .aggregate = error_aggregate };
        const aggregate = try self.heap.createAggregate("Результат.Неудача", elements);
        try self.stack.append(self.allocator, .{ .aggregate = aggregate });
    }

    // `Опция.Есть(payload)`/`Опция.Нет()` — та же форма tagged-aggregate,
    // что у `pushSuccessResult`, для нативных функций, у которых "не
    // найдено" — не `Ошибка` (`ос.окружение`).
    fn pushOption(self: *Vm, payload: ?value.Value) anyerror!void {
        try self.stack.append(self.allocator, try self.makeOptionValue(payload));
    }

    // Та же конструкция `Опция.Есть`/`Опция.Нет`, что у `pushOption`, но
    // возвращает значение вместо того, чтобы класть его на стек — нужно,
    // когда сама `Опция` становится payload'ом `Результат.Успех(...)`
    // (`синтаксис.аргумент_аннотации`/`аргумент_аннотации_поля`).
    fn makeOptionValue(self: *Vm, payload: ?value.Value) anyerror!value.Value {
        const elements = try self.allocator.alloc(value.Value, if (payload == null) 0 else 1);
        if (payload) |some| elements[0] = some;
        const aggregate = try self.heap.createAggregate(if (payload == null) "Опция.Нет" else "Опция.Есть", elements);
        return .{ .aggregate = aggregate };
    }

    // `синтаксис.*` — compile-time интроспекция AST ДРУГОГО .ps-файла (не
    // текущей выполняющейся программы), для codegen-инструментария,
    // написанного на самом панос. Нет постоянного хендла, в отличие от
    // `Файл`/`Соединение` — каждый вызов заново читает и парсит путь с
    // нуля; приемлемо для build-time инструмента, запускаемого один раз над
    // небольшим файлом, а не для горячего пути.
    const SyntaxParseOutcome = union(enum) {
        ok: syntax_parser.ParseResult,
        fail: []u8,
    };

    fn parseSyntaxSource(self: *Vm, path: []const u8) anyerror!SyntaxParseOutcome {
        var io = std.Io.Threaded.init(self.allocator, .{});
        defer io.deinit();
        const content = std.Io.Dir.cwd().readFileAlloc(io.io(), path, self.allocator, .unlimited) catch |err| {
            return .{ .fail = try self.allocator.dupe(u8, @errorName(err)) };
        };
        defer self.allocator.free(content);
        var lexed = try syntax_lexer.tokenize(self.allocator, content, 0);
        defer lexed.deinit();
        if (lexed.diagnostics.items.items.len != 0) {
            return .{ .fail = try self.allocator.dupe(u8, lexed.diagnostics.items.items[0].message) };
        }
        var parsed = try syntax_parser.parse(self.allocator, lexed.tokens.items);
        if (parsed.diagnostics.items.items.len != 0) {
            const message = try self.allocator.dupe(u8, parsed.diagnostics.items.items[0].message);
            parsed.deinit();
            return .{ .fail = message };
        }
        return .{ .ok = parsed };
    }

    const StructLookupOutcome = union(enum) {
        // Вызывающая сторона обязана вызвать `.deinit()` на `parsed`, как
        // только закончит читать `decl.struct_decl.fields`/`.annotations`
        // (оба — срезы в арену `parsed.ast`).
        ok: struct { parsed: syntax_parser.ParseResult, decl: ast_types.Decl },
        // Ошибка `Результат.Неудача(...)` уже положена на стек —
        // вызывающая сторона просто возвращается.
        failed: void,
    };

    fn resolveSyntaxStruct(self: *Vm, path: []const u8, struct_name: []const u8) anyerror!StructLookupOutcome {
        switch (try self.parseSyntaxSource(path)) {
            .fail => |message| {
                defer self.allocator.free(message);
                try self.pushErrorResultForModule("синтаксис", message);
                return .failed;
            },
            .ok => |parsed_result| {
                var parsed = parsed_result;
                for (parsed.ast.program.?.declarations) |decl_id| {
                    const decl = parsed.ast.decl(decl_id).*;
                    switch (decl) {
                        .struct_decl => |s| if (std.mem.eql(u8, s.name, struct_name)) return .{ .ok = .{ .parsed = parsed, .decl = decl } },
                        else => {},
                    }
                }
                defer parsed.deinit();
                const message = try std.fmt.allocPrint(self.allocator, "структура '{s}' не найдена в '{s}'", .{ struct_name, path });
                defer self.allocator.free(message);
                try self.pushErrorResultForModule("синтаксис", message);
                return .failed;
            },
        }
    }

    fn findFieldDecl(fields: []const ast_types.FieldDecl, name: []const u8) ?ast_types.FieldDecl {
        for (fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return field;
        }
        return null;
    }

    fn findAnnotation(annotations: []const ast_types.Annotation, name: []const u8) ?ast_types.Annotation {
        for (annotations) |annotation| {
            if (std.mem.eql(u8, annotation.name, name)) return annotation;
        }
        return null;
    }

    // Первый позиционный строковый аргумент аннотации (`&Json("ключ")`),
    // если есть — `annotation == null` (аннотация отсутствует) тоже
    // валидный вход, просто возвращает `null`, чтобы вызывающим не нужна
    // была отдельная проверка на nil.
    fn annotationStringArg(annotation: ?ast_types.Annotation) ?[]const u8 {
        const found = annotation orelse return null;
        if (found.arguments.len == 0) return null;
        const argument = found.arguments[0];
        if (argument.name != null) return null;
        return switch (argument.value) {
            .string => |text| text,
            else => null,
        };
    }

    fn annotationNamesArray(self: *Vm, annotations: []const ast_types.Annotation) anyerror!*value.Array {
        var elements: std.ArrayList(value.Value) = .empty;
        errdefer elements.deinit(self.allocator);
        for (annotations) |annotation| {
            try elements.append(self.allocator, .{ .heap_string = try self.heap.createString(try self.allocator.dupe(u8, annotation.name)) });
        }
        return self.heap.createArray(try elements.toOwnedSlice(self.allocator));
    }

    fn annotationArgOptionValue(self: *Vm, annotations: []const ast_types.Annotation, annotation_name: []const u8) anyerror!value.Value {
        const text = annotationStringArg(findAnnotation(annotations, annotation_name)) orelse return self.makeOptionValue(null);
        const heap_string = try self.heap.createString(try self.allocator.dupe(u8, text));
        return self.makeOptionValue(.{ .heap_string = heap_string });
    }

    // Текстовое отображение `Type_Node` в том виде, как он написан в
    // исходнике — НЕ канонический `^Type`/`TypeId` тайпчекера (для этого
    // файла вообще нет протипизированного графа, это одноразовый парсинг) —
    // просто сырой синтаксис, для восприятия человеком/codegen.
    fn typeNodeText(allocator: std.mem.Allocator, tree: *const ast_types.Ast, id: ast_types.TypeId) anyerror![]u8 {
        return switch (tree.typeNode(id).*) {
            .ident => |node| allocator.dupe(u8, node.name),
            .generic => |node| blk: {
                const params = try typeNodeTextList(allocator, tree, node.parameters);
                defer allocator.free(params);
                break :blk std.fmt.allocPrint(allocator, "{s}({s})", .{ node.name, params });
            },
            .qualified => |node| blk: {
                if (node.parameters.len == 0) break :blk std.fmt.allocPrint(allocator, "{s}.{s}", .{ node.module_name, node.name });
                const params = try typeNodeTextList(allocator, tree, node.parameters);
                defer allocator.free(params);
                break :blk std.fmt.allocPrint(allocator, "{s}.{s}({s})", .{ node.module_name, node.name, params });
            },
            .tuple => |node| blk: {
                const elements = try typeNodeTextList(allocator, tree, node.elements);
                defer allocator.free(elements);
                break :blk std.fmt.allocPrint(allocator, "({s})", .{elements});
            },
            .function => allocator.dupe(u8, "(тип функции)"),
            .error_node => allocator.dupe(u8, "<ошибка типа>"),
        };
    }

    // Соединяет через запятую текст каждого типа в `ids` — общее для
    // `.generic`/`.qualified`/`.tuple` выше, каждый из которых оборачивает
    // список вложенных аргументов типа одинаковым образом.
    fn typeNodeTextList(allocator: std.mem.Allocator, tree: *const ast_types.Ast, ids: []const ast_types.TypeId) anyerror![]u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);
        for (ids, 0..) |id, index| {
            if (index != 0) try result.appendSlice(allocator, ", ");
            const rendered = try typeNodeText(allocator, tree, id);
            defer allocator.free(rendered);
            try result.appendSlice(allocator, rendered);
        }
        return result.toOwnedSlice(allocator);
    }

    fn syntaxStructs(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("синтаксис::структуры", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "синтаксис::структуры", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const path = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: синтаксис.структуры() ожидает путь типа Строка", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'синтаксис::структуры' недоступно в этом runtime-таргете", .{});
            return;
        }
        switch (try self.parseSyntaxSource(path)) {
            .fail => |message| {
                defer self.allocator.free(message);
                try self.pushErrorResultForModule("синтаксис", message);
            },
            .ok => |parsed_result| {
                var parsed = parsed_result;
                defer parsed.deinit();
                var elements: std.ArrayList(value.Value) = .empty;
                errdefer elements.deinit(self.allocator);
                for (parsed.ast.program.?.declarations) |decl_id| {
                    switch (parsed.ast.decl(decl_id).*) {
                        .struct_decl => |s| try elements.append(self.allocator, .{ .heap_string = try self.heap.createString(try self.allocator.dupe(u8, s.name)) }),
                        else => {},
                    }
                }
                const array = try self.heap.createArray(try elements.toOwnedSlice(self.allocator));
                try self.pushSuccessResult(.{ .array = array });
            },
        }
    }

    // (алиас, путь-как-написан) для каждого `импорт "путь" [как алиас]`
    // в файле — НЕобаliased импорты (`импорт математика`, без "как")
    // пропускаются: у них нет qualified-имени для codegen'а разрешать
    // (модуль связывается под собственным именем неявно), а этот builtin
    // существует ИМЕННО для разрешения квалифицированных ссылок вида
    // "алиас.Тип" на путь исходного файла (codegen'у нужного для
    // вложенных структур в другом файле) — не общая интроспекция всех
    // импортов. Путь — КАК НАПИСАН в исходнике (не резолвлен через
    // PANOS_STDLIB/модули/расширения — это чистый AST-парс одного файла,
    // без module_loader'а), вызывающему коду нужно самому разрешить его
    // относительно директории `путь` (см. std/путь.pns).
    fn syntaxImports(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("синтаксис::импорты", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "синтаксис::импорты", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const path = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: синтаксис.импорты() ожидает путь типа Строка", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'синтаксис::импорты' недоступно в этом runtime-таргете", .{});
            return;
        }
        switch (try self.parseSyntaxSource(path)) {
            .fail => |message| {
                defer self.allocator.free(message);
                try self.pushErrorResultForModule("синтаксис", message);
            },
            .ok => |parsed_result| {
                var parsed = parsed_result;
                defer parsed.deinit();
                var elements: std.ArrayList(value.Value) = .empty;
                errdefer elements.deinit(self.allocator);
                for (parsed.ast.program.?.declarations) |decl_id| {
                    switch (parsed.ast.decl(decl_id).*) {
                        .import => |imp| {
                            const alias = imp.alias orelse continue;
                            const pair_elements = try self.allocator.alloc(value.Value, 2);
                            pair_elements[0] = .{ .heap_string = try self.heap.createString(try self.allocator.dupe(u8, alias)) };
                            pair_elements[1] = .{ .heap_string = try self.heap.createString(try self.allocator.dupe(u8, imp.path)) };
                            const pair = try self.heap.createAggregate(null, pair_elements);
                            try elements.append(self.allocator, .{ .aggregate = pair });
                        },
                        else => {},
                    }
                }
                const array = try self.heap.createArray(try elements.toOwnedSlice(self.allocator));
                try self.pushSuccessResult(.{ .array = array });
            },
        }
    }

    fn syntaxFields(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("синтаксис::поля", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "синтаксис::поля", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const struct_name = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: синтаксис.поля() ожидает имя структуры типа Строка", .{});
            return;
        };
        const path = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: синтаксис.поля() ожидает путь типа Строка", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'синтаксис::поля' недоступно в этом runtime-таргете", .{});
            return;
        }
        switch (try self.resolveSyntaxStruct(path, struct_name)) {
            .failed => return,
            .ok => |lookup| {
                var parsed = lookup.parsed;
                defer parsed.deinit();
                const fields = lookup.decl.struct_decl.fields;
                var elements: std.ArrayList(value.Value) = .empty;
                errdefer elements.deinit(self.allocator);
                for (fields) |field| {
                    const type_text = if (field.type_annotation) |type_id|
                        try typeNodeText(self.allocator, &parsed.ast, type_id)
                    else
                        try self.allocator.dupe(u8, "<без типа>");
                    const pair_elements = try self.allocator.alloc(value.Value, 2);
                    pair_elements[0] = .{ .heap_string = try self.heap.createString(try self.allocator.dupe(u8, field.name)) };
                    pair_elements[1] = .{ .heap_string = try self.heap.createString(type_text) };
                    const pair = try self.heap.createAggregate(null, pair_elements);
                    try elements.append(self.allocator, .{ .aggregate = pair });
                }
                const array = try self.heap.createArray(try elements.toOwnedSlice(self.allocator));
                try self.pushSuccessResult(.{ .array = array });
            },
        }
    }

    fn syntaxAnnotations(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("синтаксис::аннотации", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "синтаксис::аннотации", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const struct_name = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: синтаксис.аннотации() ожидает имя структуры типа Строка", .{});
            return;
        };
        const path = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: синтаксис.аннотации() ожидает путь типа Строка", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'синтаксис::аннотации' недоступно в этом runtime-таргете", .{});
            return;
        }
        switch (try self.resolveSyntaxStruct(path, struct_name)) {
            .failed => return,
            .ok => |lookup| {
                var parsed = lookup.parsed;
                defer parsed.deinit();
                const array = try self.annotationNamesArray(lookup.decl.struct_decl.annotations);
                try self.pushSuccessResult(.{ .array = array });
            },
        }
    }

    fn syntaxAnnotationArg(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("синтаксис::аргумент_аннотации", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "синтаксис::аргумент_аннотации", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const annotation_name = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: синтаксис.аргумент_аннотации() ожидает имя аннотации типа Строка", .{});
            return;
        };
        const struct_name = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: синтаксис.аргумент_аннотации() ожидает имя структуры типа Строка", .{});
            return;
        };
        const path = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: синтаксис.аргумент_аннотации() ожидает путь типа Строка", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'синтаксис::аргумент_аннотации' недоступно в этом runtime-таргете", .{});
            return;
        }
        switch (try self.resolveSyntaxStruct(path, struct_name)) {
            .failed => return,
            .ok => |lookup| {
                var parsed = lookup.parsed;
                defer parsed.deinit();
                const option_value = try self.annotationArgOptionValue(lookup.decl.struct_decl.annotations, annotation_name);
                try self.pushSuccessResult(option_value);
            },
        }
    }

    fn syntaxFieldAnnotations(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("синтаксис::аннотации_поля", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "синтаксис::аннотации_поля", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const field_name = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: синтаксис.аннотации_поля() ожидает имя поля типа Строка", .{});
            return;
        };
        const struct_name = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: синтаксис.аннотации_поля() ожидает имя структуры типа Строка", .{});
            return;
        };
        const path = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: синтаксис.аннотации_поля() ожидает путь типа Строка", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'синтаксис::аннотации_поля' недоступно в этом runtime-таргете", .{});
            return;
        }
        switch (try self.resolveSyntaxStruct(path, struct_name)) {
            .failed => return,
            .ok => |lookup| {
                var parsed = lookup.parsed;
                defer parsed.deinit();
                const field = findFieldDecl(lookup.decl.struct_decl.fields, field_name) orelse {
                    const message = try std.fmt.allocPrint(self.allocator, "поле '{s}' не найдено у структуры '{s}'", .{ field_name, struct_name });
                    defer self.allocator.free(message);
                    try self.pushErrorResultForModule("синтаксис", message);
                    return;
                };
                const array = try self.annotationNamesArray(field.annotations);
                try self.pushSuccessResult(.{ .array = array });
            },
        }
    }

    fn syntaxFieldAnnotationArg(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("синтаксис::аргумент_аннотации_поля", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "синтаксис::аргумент_аннотации_поля", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const annotation_name = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: синтаксис.аргумент_аннотации_поля() ожидает имя аннотации типа Строка", .{});
            return;
        };
        const field_name = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: синтаксис.аргумент_аннотации_поля() ожидает имя поля типа Строка", .{});
            return;
        };
        const struct_name = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: синтаксис.аргумент_аннотации_поля() ожидает имя структуры типа Строка", .{});
            return;
        };
        const path = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: синтаксис.аргумент_аннотации_поля() ожидает путь типа Строка", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'синтаксис::аргумент_аннотации_поля' недоступно в этом runtime-таргете", .{});
            return;
        }
        switch (try self.resolveSyntaxStruct(path, struct_name)) {
            .failed => return,
            .ok => |lookup| {
                var parsed = lookup.parsed;
                defer parsed.deinit();
                const field = findFieldDecl(lookup.decl.struct_decl.fields, field_name) orelse {
                    const message = try std.fmt.allocPrint(self.allocator, "поле '{s}' не найдено у структуры '{s}'", .{ field_name, struct_name });
                    defer self.allocator.free(message);
                    try self.pushErrorResultForModule("синтаксис", message);
                    return;
                };
                const option_value = try self.annotationArgOptionValue(field.annotations, annotation_name);
                try self.pushSuccessResult(option_value);
            },
        }
    }

    fn urlEncode(self: *Vm) anyerror!void {
        const text = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: сеть.кодировать_url() ожидает Строку", .{});
            return;
        };
        // Percent-encoding ПОБАЙТНО, не по рунам — незарезервированные по
        // RFC 3986 (A-Z a-z 0-9 - _ . ~) как есть, всё остальное (включая
        // каждый байт многобайтовой UTF-8-руны по отдельности) как `%XX`.
        // Без ограничений по таргету, чистая манипуляция байтами.
        var encoded: std.ArrayList(u8) = .empty;
        defer encoded.deinit(self.allocator);
        const hex_digits = "0123456789ABCDEF";
        for (text) |byte| {
            const is_unreserved = (byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '-' or byte == '_' or byte == '.' or byte == '~';
            if (is_unreserved) {
                try encoded.append(self.allocator, byte);
            } else {
                try encoded.append(self.allocator, '%');
                try encoded.append(self.allocator, hex_digits[byte >> 4]);
                try encoded.append(self.allocator, hex_digits[byte & 0x0f]);
            }
        }
        const heap_string = try self.heap.createString(try encoded.toOwnedSlice(self.allocator));
        try self.stack.append(self.allocator, .{ .heap_string = heap_string });
    }

    // HTTP-клиенты percent-кодируют не-ASCII сегменты пути на проводе,
    // поэтому роутер должен декодировать сырой (всё ещё закодированный)
    // путь запроса перед сравнением с шаблонами маршрутов — иначе
    // кириллический маршрут никогда бы не совпал с реальным запросом.
    // Побайтово, симметрично `urlEncode` выше — некорректный `%`-escape (не
    // hex-пара, или `%` обрезан в конце строки) — это `Runtime Error`, не
    // тихое отбрасывание, так что некорректный путь падает громко, а не
    // совпадает не с тем маршрутом.
    fn urlDecode(self: *Vm) anyerror!void {
        const text = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: сеть.декодировать_url() ожидает Строку", .{});
            return;
        };
        var decoded: std.ArrayList(u8) = .empty;
        defer decoded.deinit(self.allocator);
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '%') {
                if (i + 2 >= text.len) {
                    try self.fault("Runtime Error: сеть.декодировать_url(): '%' в конце строки без hex-пары", .{});
                    return;
                }
                const high = std.fmt.charToDigit(text[i + 1], 16) catch {
                    try self.fault("Runtime Error: сеть.декодировать_url(): некорректный '%'-escape", .{});
                    return;
                };
                const low = std.fmt.charToDigit(text[i + 2], 16) catch {
                    try self.fault("Runtime Error: сеть.декодировать_url(): некорректный '%'-escape", .{});
                    return;
                };
                try decoded.append(self.allocator, @intCast(high << 4 | low));
                i += 3;
            } else {
                try decoded.append(self.allocator, text[i]);
                i += 1;
            }
        }
        const heap_string = try self.heap.createString(try decoded.toOwnedSlice(self.allocator));
        try self.stack.append(self.allocator, .{ .heap_string = heap_string });
    }

    fn httpRequestSubmit(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("сеть::http_запрос", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "сеть::http_запрос", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const headers_value = try self.pop();
        const headers_map = switch (headers_value) {
            .map => |map| map,
            else => {
                try self.fault("Runtime Error: сеть.http_запрос() ожидает Соответствие(Строка, Строка) четвёртым аргументом", .{});
                return;
            },
        };
        const body = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: сеть.http_запрос() ожидает тело типа Строка", .{});
            return;
        };
        const url = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: сеть.http_запрос() ожидает url типа Строка", .{});
            return;
        };
        const method_text = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: сеть.http_запрос() ожидает метод типа Строка", .{});
            return;
        };
        const process = self.current_process orelse {
            try self.fault("Runtime Error: сеть.http_запрос() вызвано вне процесса", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'сеть::http_запрос' недоступно в этом runtime-таргете", .{});
            return;
        }
        // Всё, к чему прикоснётся воркер, должно быть склонировано на
        // page_allocator ЗДЕСЬ, на главном потоке, до запуска — байты
        // Value/Map принадлежат self.allocator и небезопасны для
        // параллельного чтения фоновым потоком после возврата из этого
        // вызова. Сам массив (не только строки каждой пары) ТОЖЕ должен
        // принадлежать page_allocator и НЕ освобождаться здесь — владение
        // полностью переходит воркеру (освобождает submitHttpRequest/Job),
        // т.к. воркер продолжает читать его после возврата из этой функции.
        const owned_headers = std.heap.page_allocator.alloc(HttpHeaderPair, headers_map.entries.items.len) catch @panic("OOM");
        var header_count: usize = 0;
        for (headers_map.entries.items) |map_entry| {
            const name = map_entry.key.stringBytes() orelse continue;
            const header_value = map_entry.value.stringBytes() orelse continue;
            owned_headers[header_count] = .{
                .name = std.heap.page_allocator.dupe(u8, name) catch @panic("OOM"),
                .value = std.heap.page_allocator.dupe(u8, header_value) catch @panic("OOM"),
            };
            header_count += 1;
        }
        // Уменьшаем до реального валидного количества (не просто под-срез)
        // — воркер освобождает этот срез ТЕМ ЖЕ аллокатором с ТОЙ ЖЕ
        // длиной, что ему дали; более короткий под-срез большей аллокации —
        // невалидный вход для `free()` у `page_allocator`. Уменьшение через
        // `realloc` гарантированно успешно (никогда не требует новой
        // памяти).
        const shrunk_headers = std.heap.page_allocator.realloc(owned_headers, header_count) catch unreachable;
        submitHttpRequest(
            self,
            method_text,
            url,
            body,
            shrunk_headers,
            process.id,
            true,
        );
    }

    // Симметрично httpRequestSubmit выше, кроме follow_redirects=false —
    // 3xx возвращается КАК ЕСТЬ (Location доступен через .заголовок(...)
    // результата), не следуется автоматически. Отдельная функция, не
    // параметр на существующей — сеть.http_запрос() уже выпущен и
    // используется без этого аргумента.
    fn httpRequestNoRedirectSubmit(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("сеть::http_запрос_без_редиректа", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "сеть::http_запрос_без_редиректа", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const headers_value = try self.pop();
        const headers_map = switch (headers_value) {
            .map => |map| map,
            else => {
                try self.fault("Runtime Error: сеть.http_запрос_без_редиректа() ожидает Соответствие(Строка, Строка) четвёртым аргументом", .{});
                return;
            },
        };
        const body = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: сеть.http_запрос_без_редиректа() ожидает тело типа Строка", .{});
            return;
        };
        const url = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: сеть.http_запрос_без_редиректа() ожидает url типа Строка", .{});
            return;
        };
        const method_text = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: сеть.http_запрос_без_редиректа() ожидает метод типа Строка", .{});
            return;
        };
        const process = self.current_process orelse {
            try self.fault("Runtime Error: сеть.http_запрос_без_редиректа() вызвано вне процесса", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'сеть::http_запрос_без_редиректа' недоступно в этом runtime-таргете", .{});
            return;
        }
        const owned_headers = std.heap.page_allocator.alloc(HttpHeaderPair, headers_map.entries.items.len) catch @panic("OOM");
        var header_count: usize = 0;
        for (headers_map.entries.items) |map_entry| {
            const name = map_entry.key.stringBytes() orelse continue;
            const header_value = map_entry.value.stringBytes() orelse continue;
            owned_headers[header_count] = .{
                .name = std.heap.page_allocator.dupe(u8, name) catch @panic("OOM"),
                .value = std.heap.page_allocator.dupe(u8, header_value) catch @panic("OOM"),
            };
            header_count += 1;
        }
        const shrunk_headers = std.heap.page_allocator.realloc(owned_headers, header_count) catch unreachable;
        submitHttpRequest(
            self,
            method_text,
            url,
            body,
            shrunk_headers,
            process.id,
            false,
        );
    }

    fn buildHttpAggregateResult(self: *Vm, data: HttpRequestResult) !value.Value {
        var header_pairs: std.ArrayList(value.Value) = .empty;
        errdefer header_pairs.deinit(self.allocator);
        for (data.headers) |header| {
            const pair_elements = try self.allocator.alloc(value.Value, 2);
            pair_elements[0] = .{ .heap_string = try self.heap.createString(try self.allocator.dupe(u8, header.name)) };
            pair_elements[1] = .{ .heap_string = try self.heap.createString(try self.allocator.dupe(u8, header.value)) };
            const pair = try self.heap.createAggregate(null, pair_elements);
            try header_pairs.append(self.allocator, .{ .aggregate = pair });
        }
        const headers_array = try self.heap.createArray(try header_pairs.toOwnedSlice(self.allocator));
        const response_body = try self.heap.createString(try self.allocator.dupe(u8, data.body));
        const tuple_elements = try self.allocator.alloc(value.Value, 3);
        tuple_elements[0] = .{ .number = @floatFromInt(data.status) };
        tuple_elements[1] = .{ .array = headers_array };
        tuple_elements[2] = .{ .heap_string = response_body };
        const tuple = try self.heap.createAggregate(null, tuple_elements);
        return .{ .aggregate = tuple };
    }

    fn sqlOpenSubmit(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("бд::открыть", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "бд::открыть", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const path = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: бд.открыть() ожидает путь типа Строка", .{});
            return;
        };
        const process = self.current_process orelse {
            try self.fault("Runtime Error: бд.открыть() вызвано вне процесса", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'бд::открыть' недоступно в этом runtime-таргете", .{});
            return;
        }
        submitSqlOpen(self, path, process.id);
    }

    fn popSqlConnection(self: *Vm, method_name: []const u8) anyerror!?*value.SqlConnection {
        const receiver = try self.pop();
        return switch (receiver) {
            .sql_connection => |connection| connection,
            else => {
                try self.fault("Runtime Error: {s} ожидает соединение с БД", .{method_name});
                return null;
            },
        };
    }

    const SqlPrepareOutcome = union(enum) {
        ok: ?*sqlite3.sqlite3_stmt,
        // Заимствовано из собственного буфера `sqlite3_errmsg` — валидно
        // только до следующего вызова на том же `db`/пока он не закрыт.
        // Вызывающий обязан потребить его (например, `pushErrorResultForModule`,
        // который копирует немедленно) до любого следующего вызова sqlite3.
        fail: []const u8,
    };

    // Общий шаг prepare+позиционная привязка `?`-плейсхолдеров для
    // `Соединение_БД.выполнить`/`.запрос` — `параметры` привязываются
    // ТОЛЬКО так, во всей VM нет пути SQL через конкатенацию строк, так что
    // вызывающая сторона не может построить инъекционный запрос, даже если
    // бы захотела.
    fn sqlPrepare(self: *Vm, connection: *value.SqlConnection, sql: []const u8, params: []const value.Value) anyerror!SqlPrepareOutcome {
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        var stmt: ?*sqlite3.sqlite3_stmt = null;
        const prepare_rc = sqlite3.sqlite3_prepare_v2(connection.db, sql_z.ptr, -1, &stmt, null);
        if (prepare_rc != sqlite3.SQLITE_OK) {
            return .{ .fail = std.mem.span(sqlite3.sqlite3_errmsg(connection.db) orelse "ошибка SQL") };
        }
        for (params, 0..) |param, index| {
            const text = param.stringBytes() orelse {
                _ = sqlite3.sqlite3_finalize(stmt);
                return .{ .fail = "параметр должен быть Строкой" };
            };
            const text_z = try self.allocator.dupeZ(u8, text);
            defer self.allocator.free(text_z);
            const bind_rc = sqlite3.sqlite3_bind_text(stmt, @intCast(index + 1), text_z, -1, sqlite3.SQLITE_TRANSIENT);
            if (bind_rc != sqlite3.SQLITE_OK) {
                const message = std.mem.span(sqlite3.sqlite3_errmsg(connection.db) orelse "ошибка привязки параметра");
                _ = sqlite3.sqlite3_finalize(stmt);
                return .{ .fail = message };
            }
        }
        return .{ .ok = stmt };
    }

    // Проверяет, что каждый элемент `параметры` — Строка, и клонирует их на
    // page_allocator — общее для sqlExecSubmit/sqlQuerySubmit, обоим нужна
    // эта одинаковая подготовка перед передачей воркеру.
    fn cloneSqlParams(self: *Vm, elements: []const value.Value) anyerror!?[][]u8 {
        const owned = try self.allocator.alloc([]u8, elements.len);
        errdefer self.allocator.free(owned);
        var filled: usize = 0;
        for (elements) |element| {
            const text = element.stringBytes() orelse {
                for (owned[0..filled]) |param| std.heap.page_allocator.free(param);
                self.allocator.free(owned);
                return null;
            };
            owned[filled] = std.heap.page_allocator.dupe(u8, text) catch @panic("OOM");
            filled += 1;
        }
        return owned;
    }

    fn sqlExecSubmit(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("бд::выполнить", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "бд::выполнить", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const params_value = try self.pop();
        const params_array = switch (params_value) {
            .array => |array| array,
            else => {
                try self.fault("Runtime Error: Соединение_БД.выполнить() ожидает Массив(Строка) вторым аргументом", .{});
                return;
            },
        };
        const sql = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: Соединение_БД.выполнить() ожидает SQL типа Строка", .{});
            return;
        };
        const connection = try self.popSqlConnection("Соединение_БД.выполнить()") orelse return;
        if (!connection.is_open) {
            const result = try self.buildErrorResultValue("бд", "соединение уже закрыто");
            try self.appendAsyncResultForCurrentProcess(result);
            return;
        }
        if (connection.in_flight) {
            const result = try self.buildErrorResultValue("бд", "соединение уже используется другой операцией");
            try self.appendAsyncResultForCurrentProcess(result);
            return;
        }
        const process = self.current_process orelse {
            try self.fault("Runtime Error: Соединение_БД.выполнить() вызвано вне процесса", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'Соединение_БД.выполнить' недоступно в этом runtime-таргете", .{});
            return;
        }
        const owned_params = try self.cloneSqlParams(params_array.elements) orelse {
            const result = try self.buildErrorResultValue("бд", "параметр должен быть Строкой");
            try self.appendAsyncResultForCurrentProcess(result);
            return;
        };
        defer {
            for (owned_params) |param| std.heap.page_allocator.free(param);
            self.allocator.free(owned_params);
        }
        connection.in_flight = true;
        try self.heap.pin(.{ .sql_connection = connection });
        submitSqlExec(self, connection, sql, owned_params, process.id);
    }

    fn sqlQuerySubmit(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("бд::запрос", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "бд::запрос", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const params_value = try self.pop();
        const params_array = switch (params_value) {
            .array => |array| array,
            else => {
                try self.fault("Runtime Error: Соединение_БД.запрос() ожидает Массив(Строка) вторым аргументом", .{});
                return;
            },
        };
        const sql = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: Соединение_БД.запрос() ожидает SQL типа Строка", .{});
            return;
        };
        const connection = try self.popSqlConnection("Соединение_БД.запрос()") orelse return;
        if (!connection.is_open) {
            const result = try self.buildErrorResultValue("бд", "соединение уже закрыто");
            try self.appendAsyncResultForCurrentProcess(result);
            return;
        }
        if (connection.in_flight) {
            const result = try self.buildErrorResultValue("бд", "соединение уже используется другой операцией");
            try self.appendAsyncResultForCurrentProcess(result);
            return;
        }
        const process = self.current_process orelse {
            try self.fault("Runtime Error: Соединение_БД.запрос() вызвано вне процесса", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'Соединение_БД.запрос' недоступно в этом runtime-таргете", .{});
            return;
        }
        const owned_params = try self.cloneSqlParams(params_array.elements) orelse {
            const result = try self.buildErrorResultValue("бд", "параметр должен быть Строкой");
            try self.appendAsyncResultForCurrentProcess(result);
            return;
        };
        defer {
            for (owned_params) |param| std.heap.page_allocator.free(param);
            self.allocator.free(owned_params);
        }
        connection.in_flight = true;
        try self.heap.pin(.{ .sql_connection = connection });
        submitSqlQuery(self, connection, sql, owned_params, process.id);
    }

    fn sqlClose(self: *Vm) anyerror!void {
        const connection = try self.popSqlConnection("Соединение_БД.закрыть()") orelse return;
        if (!connection.is_open) {
            try self.stack.append(self.allocator, .{ .void = {} });
            return;
        }
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'Соединение_БД.закрыть' недоступно в этом runtime-таргете", .{});
        } else {
            _ = sqlite3.sqlite3_close_v2(connection.db);
            connection.is_open = false;
            try self.stack.append(self.allocator, .{ .void = {} });
        }
    }

    // HMAC-SHA256 + base64url — чистые функции над `std.crypto` (Zig
    // stdlib, ничего не вендорится), но `native_only` (`target.zig`): у
    // AOT WASM-кодогенерации (`wasm_emit.zig`) нет своего пути для этих
    // опкодов, а `быстряга`/JWT всё равно только server-side. Подпись
    // отдаётся СРАЗУ в base64url-текст (не сырыми байтами) — `Строка` в
    // этой VM обязана быть валидным UTF-8 (см. `фс.прочитать`), а
    // произвольный 32-байтный HMAC-дайджест им почти никогда не
    // является — то же решение, что `бд`'s "BLOB не поддержан", просто
    // здесь обойдено кодировкой, а не отказом.
    fn cryptoHmacSha256Base64Url(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("криптография::hmac_sha256_base64url", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "криптография::hmac_sha256_base64url", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const message_text = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: криптография.hmac_sha256_base64url() ожидает сообщение типа Строка вторым аргументом", .{});
            return;
        };
        const key = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: криптография.hmac_sha256_base64url() ожидает ключ типа Строка первым аргументом", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'криптография::hmac_sha256_base64url' недоступно в этом runtime-таргете", .{});
            return;
        }
        var digest: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&digest, message_text, key);
        const encoder = std.base64.url_safe_no_pad.Encoder;
        const encoded = try self.allocator.alloc(u8, encoder.calcSize(digest.len));
        defer self.allocator.free(encoded);
        _ = encoder.encode(encoded, &digest);
        const heap_string = try self.heap.createString(try self.allocator.dupe(u8, encoded));
        try self.stack.append(self.allocator, .{ .heap_string = heap_string });
    }

    fn cryptoBase64UrlEncode(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("криптография::base64url_кодировать", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "криптография::base64url_кодировать", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const text = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: криптография.base64url_кодировать() ожидает Строку", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'криптография::base64url_кодировать' недоступно в этом runtime-таргете", .{});
            return;
        }
        const encoder = std.base64.url_safe_no_pad.Encoder;
        const encoded = try self.allocator.alloc(u8, encoder.calcSize(text.len));
        defer self.allocator.free(encoded);
        _ = encoder.encode(encoded, text);
        const heap_string = try self.heap.createString(try self.allocator.dupe(u8, encoded));
        try self.stack.append(self.allocator, .{ .heap_string = heap_string });
    }

    // Декодированные байты обязаны быть валидным UTF-8, чтобы стать
    // panos `Строка` — JWT-заголовок/payload-сегменты ВСЕГДА сериализованы
    // из JSON (валидный UTF-8 по построению), так что для честного JWT
    // эта ветка не срабатывает; для мусорного/подделанного токена — это
    // `Результат.Неудача`, а не паника, тот же принцип, что у остальных
    // декодеров в проекте (`json.разобрать`, `сеть.декодировать_url`).
    fn cryptoBase64UrlDecode(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("криптография::base64url_декодировать", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "криптография::base64url_декодировать", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const text = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: криптография.base64url_декодировать() ожидает Строку", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'криптография::base64url_декодировать' недоступно в этом runtime-таргете", .{});
            return;
        }
        const decoder = std.base64.url_safe_no_pad.Decoder;
        const decoded_len = decoder.calcSizeForSlice(text) catch {
            try self.pushErrorResultForModule("криптография", "некорректная base64url-строка");
            return;
        };
        const decoded = try self.allocator.alloc(u8, decoded_len);
        defer self.allocator.free(decoded);
        decoder.decode(decoded, text) catch {
            try self.pushErrorResultForModule("криптография", "некорректная base64url-строка");
            return;
        };
        if (!std.unicode.utf8ValidateSlice(decoded)) {
            try self.pushErrorResultForModule("криптография", "декодированные байты не валидный UTF-8");
            return;
        }
        const heap_string = try self.heap.createString(try self.allocator.dupe(u8, decoded));
        try self.pushSuccessResult(.{ .heap_string = heap_string });
    }

    // Сравнение сигнатуры JWT в постоянное время — обычное `==` на
    // байтах рано выходит на первом несовпадении, что теоретически даёт
    // атакующему таймингом byte-by-byte оракул для подбора подписи;
    // XOR-аккумулятор без early-return всегда проходит по всей длине
    // более короткой строки, не завершаясь на первом расхождении.
    fn cryptoTimingSafeEq(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("криптография::сравнить_константное_время", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "криптография::сравнить_константное_время", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const right = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: криптография.сравнить_константное_время() ожидает Строку вторым аргументом", .{});
            return;
        };
        const left = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: криптография.сравнить_константное_время() ожидает Строку первым аргументом", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'криптография::сравнить_константное_время' недоступно в этом runtime-таргете", .{});
            return;
        }
        var diff: u8 = @intFromBool(left.len != right.len);
        const shorter = @min(left.len, right.len);
        for (left[0..shorter], right[0..shorter]) |left_byte, right_byte| diff |= left_byte ^ right_byte;
        try self.stack.append(self.allocator, .{ .boolean = diff == 0 });
    }

    // Плоский SHA256 (не HMAC — нет ключа) для PKCE `code_challenge =
    // BASE64URL(SHA256(code_verifier))` (RFC 7636) — HMAC с фиксированным
    // ключом НЕ эквивалентно plain SHA256 и было бы неверной реализацией
    // спеки, не просто небезопасной.
    fn cryptoSha256Base64Url(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("криптография::sha256_base64url", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "криптография::sha256_base64url", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const text = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: криптография.sha256_base64url() ожидает Строку", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'криптография::sha256_base64url' недоступно в этом runtime-таргете", .{});
            return;
        }
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
        const encoder = std.base64.url_safe_no_pad.Encoder;
        const encoded = try self.allocator.alloc(u8, encoder.calcSize(digest.len));
        defer self.allocator.free(encoded);
        _ = encoder.encode(encoded, &digest);
        const heap_string = try self.heap.createString(try self.allocator.dupe(u8, encoded));
        try self.stack.append(self.allocator, .{ .heap_string = heap_string });
    }

    // PBKDF2-HMAC-SHA256 для хранения паролей — МЕДЛЕННЫЙ (в отличие от
    // одного прохода HMAC), сырые байты дайджеста никогда не пересекают
    // границу VM (не round-trip'ятся через panos `Строка` между
    // итерациями — она обязана быть валидным UTF-8), только финальный
    // base64url-текст. `итерации` MUST быть >= 1 (`std.crypto.pbkdf2`
    // возвращает `error.WeakParameters` для 0 — превращается в
    // `Runtime Error`, не panic, тот же принцип, что у остальных
    // builtin-валидаций).
    fn cryptoPbkdf2Sha256Base64Url(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("криптография::pbkdf2_sha256_base64url", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "криптография::pbkdf2_sha256_base64url", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const iterations_value = try self.number(try self.pop());
        const salt = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: криптография.pbkdf2_sha256_base64url() ожидает соль типа Строка вторым аргументом", .{});
            return;
        };
        const password = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: криптография.pbkdf2_sha256_base64url() ожидает пароль типа Строка первым аргументом", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'криптография::pbkdf2_sha256_base64url' недоступно в этом runtime-таргете", .{});
            return;
        }
        if (iterations_value < 1 or !std.math.isFinite(iterations_value) or iterations_value > @as(f64, @floatFromInt(std.math.maxInt(u32)))) {
            try self.fault("Runtime Error: криптография.pbkdf2_sha256_base64url() ожидает итерации >= 1", .{});
            return;
        }
        const iterations: u32 = @intFromFloat(iterations_value);
        var digest: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
        std.crypto.pwhash.pbkdf2(&digest, password, salt, iterations, std.crypto.auth.hmac.sha2.HmacSha256) catch {
            try self.fault("Runtime Error: криптография.pbkdf2_sha256_base64url() ожидает итерации >= 1", .{});
            return;
        };
        const encoder = std.base64.url_safe_no_pad.Encoder;
        const encoded = try self.allocator.alloc(u8, encoder.calcSize(digest.len));
        defer self.allocator.free(encoded);
        _ = encoder.encode(encoded, &digest);
        const heap_string = try self.heap.createString(try self.allocator.dupe(u8, encoded));
        try self.stack.append(self.allocator, .{ .heap_string = heap_string });
    }

    // Единственный источник криптографически стойкой случайности во всей
    // VM — `математика.*` (Lehmer/Park-Miller PRNG) угадываем по
    // построению, годится для геймплея/джиттера, но НЕ для OAuth2
    // authorization code/access/refresh-токенов и соли пароля (RFC 6819
    // §5.1.5.2 — угадываемый code напрямую взламывает весь flow).
    // `std.crypto.random` — тот же источник, что уже используют
    // Zig-стандартные `std.crypto.random.bytes` реализации (ОС CSPRNG,
    // getrandom/arc4random), ничего не вендорится.
    fn cryptoRandomBytesBase64Url(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("криптография::случайные_байты_base64url", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "криптография::случайные_байты_base64url", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const count_value = try self.number(try self.pop());
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'криптография::случайные_байты_base64url' недоступно в этом runtime-таргете", .{});
            return;
        }
        if (count_value < 1 or !std.math.isFinite(count_value) or count_value > 65536) {
            try self.fault("Runtime Error: криптография.случайные_байты_base64url() ожидает количество байт от 1 до 65536", .{});
            return;
        }
        const count: usize = @intFromFloat(count_value);
        const raw = try self.allocator.alloc(u8, count);
        defer self.allocator.free(raw);
        var io = std.Io.Threaded.init(self.allocator, .{});
        defer io.deinit();
        io.io().random(raw);
        const encoder = std.base64.url_safe_no_pad.Encoder;
        const encoded = try self.allocator.alloc(u8, encoder.calcSize(raw.len));
        defer self.allocator.free(encoded);
        _ = encoder.encode(encoded, raw);
        const heap_string = try self.heap.createString(try self.allocator.dupe(u8, encoded));
        try self.stack.append(self.allocator, .{ .heap_string = heap_string });
    }

    // ES256 (ECDSA P-256 + SHA-256, RFC 7518 §3.4) — единственная
    // асимметричная схема доступная без вендоринга: у Zig 0.16 std.crypto
    // НЕТ RSA вообще (RS256 было бы недостижимо без стороннего кода), а
    // `std.crypto.sign.ecdsa.EcdsaP256Sha256` уже есть в стандартной
    // библиотеке. Даёт публичным OAuth2-клиентам верифицировать id_token
    // через JWKS вместо общего HS256-секрета.
    fn cryptoEs256GenerateKeys(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("криптография::es256_сгенерировать_ключи", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "криптография::es256_сгенерировать_ключи", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'криптография::es256_сгенерировать_ключи' недоступно в этом runtime-таргете", .{});
            return;
        }
        const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
        var io = std.Io.Threaded.init(self.allocator, .{});
        defer io.deinit();
        const key_pair = Ecdsa.KeyPair.generate(io.io());
        const encoder = std.base64.url_safe_no_pad.Encoder;
        const d_bytes = key_pair.secret_key.toBytes();
        const point = key_pair.public_key.toUncompressedSec1();
        // `point` — 0x04 || x(32) || y(32) (SEC1 несжатый формат).
        const x_bytes = point[1..33];
        const y_bytes = point[33..65];
        const d_encoded = try self.allocator.alloc(u8, encoder.calcSize(d_bytes.len));
        defer self.allocator.free(d_encoded);
        _ = encoder.encode(d_encoded, &d_bytes);
        const x_encoded = try self.allocator.alloc(u8, encoder.calcSize(x_bytes.len));
        defer self.allocator.free(x_encoded);
        _ = encoder.encode(x_encoded, x_bytes);
        const y_encoded = try self.allocator.alloc(u8, encoder.calcSize(y_bytes.len));
        defer self.allocator.free(y_encoded);
        _ = encoder.encode(y_encoded, y_bytes);
        const d_string = try self.heap.createString(try self.allocator.dupe(u8, d_encoded));
        const x_string = try self.heap.createString(try self.allocator.dupe(u8, x_encoded));
        const y_string = try self.heap.createString(try self.allocator.dupe(u8, y_encoded));
        const tuple_elements = try self.allocator.alloc(value.Value, 3);
        tuple_elements[0] = .{ .heap_string = d_string };
        tuple_elements[1] = .{ .heap_string = x_string };
        tuple_elements[2] = .{ .heap_string = y_string };
        const tuple = try self.heap.createAggregate(null, tuple_elements);
        try self.stack.append(self.allocator, .{ .aggregate = tuple });
    }

    fn cryptoEs256Sign(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("криптография::es256_подписать", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "криптография::es256_подписать", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const message_text = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: криптография.es256_подписать() ожидает сообщение типа Строка вторым аргументом", .{});
            return;
        };
        const d_b64url = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: криптография.es256_подписать() ожидает приватный ключ типа Строка первым аргументом", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'криптография::es256_подписать' недоступно в этом runtime-таргете", .{});
            return;
        }
        const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
        const decoder = std.base64.url_safe_no_pad.Decoder;
        const d_len = decoder.calcSizeForSlice(d_b64url) catch {
            try self.fault("Runtime Error: криптография.es256_подписать() ожидает валидный base64url приватный ключ", .{});
            return;
        };
        if (d_len != Ecdsa.SecretKey.encoded_length) {
            try self.fault("Runtime Error: криптография.es256_подписать() ожидает приватный ключ длиной {d} байт", .{Ecdsa.SecretKey.encoded_length});
            return;
        }
        var d_bytes: [Ecdsa.SecretKey.encoded_length]u8 = undefined;
        decoder.decode(&d_bytes, d_b64url) catch {
            try self.fault("Runtime Error: криптография.es256_подписать() ожидает валидный base64url приватный ключ", .{});
            return;
        };
        const secret_key = Ecdsa.SecretKey.fromBytes(d_bytes) catch {
            try self.fault("Runtime Error: криптография.es256_подписать() получил недействительный приватный ключ", .{});
            return;
        };
        const key_pair = Ecdsa.KeyPair.fromSecretKey(secret_key) catch {
            try self.fault("Runtime Error: криптография.es256_подписать() получил недействительный приватный ключ", .{});
            return;
        };
        const signature = key_pair.sign(message_text, null) catch {
            try self.fault("Runtime Error: криптография.es256_подписать() не смог подписать сообщение", .{});
            return;
        };
        const sig_bytes = signature.toBytes();
        const encoder = std.base64.url_safe_no_pad.Encoder;
        const encoded = try self.allocator.alloc(u8, encoder.calcSize(sig_bytes.len));
        defer self.allocator.free(encoded);
        _ = encoder.encode(encoded, &sig_bytes);
        const heap_string = try self.heap.createString(try self.allocator.dupe(u8, encoded));
        try self.stack.append(self.allocator, .{ .heap_string = heap_string });
    }

    fn cryptoEs256Verify(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("криптография::es256_проверить", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "криптография::es256_проверить", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const signature_b64url = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: криптография.es256_проверить() ожидает подпись типа Строка четвёртым аргументом", .{});
            return;
        };
        const message_text = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: криптография.es256_проверить() ожидает сообщение типа Строка третьим аргументом", .{});
            return;
        };
        const y_b64url = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: криптография.es256_проверить() ожидает y-координату типа Строка вторым аргументом", .{});
            return;
        };
        const x_b64url = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: криптография.es256_проверить() ожидает x-координату типа Строка первым аргументом", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'криптография::es256_проверить' недоступно в этом runtime-таргете", .{});
            return;
        }
        const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
        const decoder = std.base64.url_safe_no_pad.Decoder;
        const false_result: value.Value = .{ .boolean = false };
        const coord_len = (Ecdsa.PublicKey.uncompressed_sec1_encoded_length - 1) / 2;
        const x_len = decoder.calcSizeForSlice(x_b64url) catch {
            try self.stack.append(self.allocator, false_result);
            return;
        };
        const y_len = decoder.calcSizeForSlice(y_b64url) catch {
            try self.stack.append(self.allocator, false_result);
            return;
        };
        const sig_len = decoder.calcSizeForSlice(signature_b64url) catch {
            try self.stack.append(self.allocator, false_result);
            return;
        };
        if (x_len != coord_len or y_len != coord_len or sig_len != Ecdsa.Signature.encoded_length) {
            try self.stack.append(self.allocator, false_result);
            return;
        }
        var sec1: [Ecdsa.PublicKey.uncompressed_sec1_encoded_length]u8 = undefined;
        sec1[0] = 0x04;
        decoder.decode(sec1[1 .. 1 + coord_len], x_b64url) catch {
            try self.stack.append(self.allocator, false_result);
            return;
        };
        decoder.decode(sec1[1 + coord_len ..], y_b64url) catch {
            try self.stack.append(self.allocator, false_result);
            return;
        };
        var sig_bytes: [Ecdsa.Signature.encoded_length]u8 = undefined;
        decoder.decode(&sig_bytes, signature_b64url) catch {
            try self.stack.append(self.allocator, false_result);
            return;
        };
        const public_key = Ecdsa.PublicKey.fromSec1(&sec1) catch {
            try self.stack.append(self.allocator, false_result);
            return;
        };
        const signature = Ecdsa.Signature.fromBytes(sig_bytes);
        signature.verify(message_text, public_key) catch {
            try self.stack.append(self.allocator, false_result);
            return;
        };
        try self.stack.append(self.allocator, .{ .boolean = true });
    }

    fn callForeign(self: *Vm, compiled: *const bytecode.Function, constant_index: u16, argument_count: u16) anyerror!void {
        if (constant_index >= compiled.constants.items.len) {
            try self.fault("Runtime Error: константа вне границ пула", .{});
            return;
        }
        const constant = &compiled.constants.items[constant_index];
        const info: *const bytecode.ForeignFunctionConstant = switch (constant.*) {
            .foreign_function => &constant.foreign_function,
            else => {
                try self.fault("Runtime Error: константа не описывает 'внешний'-функцию", .{});
                return;
            },
        };
        const profile_started_at: ?u64 = if (comptime builtin.target.os.tag == .freestanding)
            null
        else if (self.foreign_profile_enabled)
            foreignProfileNowNanoseconds()
        else
            null;
        const arguments = try self.popValues(argument_count);
        defer self.allocator.free(arguments);
        if (info.fn_ptr == 0) {
            try self.fault("Runtime Panic: 'внешний' функция не была разрешена при резолве", .{});
            return;
        }
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'внешний' недоступно в этом runtime-таргете", .{});
        } else {
            const result = try self.invokeForeign(info, arguments);
            if (profile_started_at) |started_at| {
                const finished_at = foreignProfileNowNanoseconds();
                try self.recordForeignTotalTime(info, if (finished_at >= started_at) finished_at - started_at else 0);
            }
            try self.stack.append(self.allocator, result);
        }
    }

    // Упаковывает числовой `Value` панос в `dest` согласно `kind` — общее
    // для обычного скалярного аргумента/поля и одного ПОЛЯ аргумента
    // struct-by-value (поля `ff_структура` всегда один из этих пяти видов,
    // никогда `.c_string`/`.pointer`/`.struct_value` — это гарантирует
    // `parseFfiStructDeclaration` в `parser.zig` на этапе парсинга).
    fn packScalar(self: *Vm, dest: [*]u8, kind: ast_types.ForeignMarshalKind, source: value.Value) anyerror!void {
        const numeric = try self.number(source);
        switch (kind) {
            .int8 => @as(*u8, @ptrCast(@alignCast(dest))).* = @intFromFloat(numeric),
            .int32 => @as(*i32, @ptrCast(@alignCast(dest))).* = @intFromFloat(numeric),
            .int64 => @as(*i64, @ptrCast(@alignCast(dest))).* = @intFromFloat(numeric),
            .float32 => @as(*f32, @ptrCast(@alignCast(dest))).* = @floatCast(numeric),
            .float64 => @as(*f64, @ptrCast(@alignCast(dest))).* = numeric,
            .void, .c_string, .pointer, .struct_value => unreachable,
        }
    }

    // Обратное к `packScalar` — читает одно поле обратно из сырых байт C
    // ABI в `Value` панос.
    fn unpackScalar(kind: ast_types.ForeignMarshalKind, source: [*]const u8) value.Value {
        return switch (kind) {
            .int8 => .{ .number = @floatFromInt(@as(*const u8, @ptrCast(@alignCast(source))).*) },
            .int32 => .{ .number = @floatFromInt(@as(*const i32, @ptrCast(@alignCast(source))).*) },
            .int64 => .{ .number = @floatFromInt(@as(*const i64, @ptrCast(@alignCast(source))).*) },
            .float32 => .{ .number = @as(*const f32, @ptrCast(@alignCast(source))).* },
            .float64 => .{ .number = @as(*const f64, @ptrCast(@alignCast(source))).* },
            .void, .c_string, .pointer, .struct_value => unreachable,
        };
    }

    // Упаковывает аргумент struct-by-value панос (`.aggregate`, по одному
    // элементу на поле, в порядке объявления — совпадает с `layout`) в
    // `dest`, который должен быть не меньше `struct_type.size` байт
    // (заполняется `ffi_prep_cif` — вызывающая сторона обязана вызывать это
    // только ПОСЛЕ него, никогда раньше). Байтовые смещения полей приходят
    // из самой libffi (`ffi_get_struct_offsets`) — layout структуры C ABI
    // (выравнивающий padding) здесь НЕ переизобретается вручную.
    fn packStruct(self: *Vm, dest: [*]u8, layout: []const ast_types.ForeignMarshalKind, offsets: []const usize, source: value.Value) anyerror!void {
        const aggregate = switch (source) {
            .aggregate => |a| a,
            else => {
                try self.fault("Runtime Error: 'внешний' ожидает значение ff_структура для этого параметра", .{});
                return;
            },
        };
        if (aggregate.elements.len != layout.len) {
            try self.fault("Runtime Error: количество полей ff_структура не совпадает при 'внешний'-вызове", .{});
            return;
        }
        if (offsets.len != layout.len) {
            try self.fault("Runtime Error: layout ff_структура не совпадает при 'внешний'-вызове", .{});
            return;
        }
        for (layout, aggregate.elements, offsets) |kind, field_value, offset| {
            try self.packScalar(dest + offset, kind, field_value);
        }
    }

    // Обратное к `packStruct` — строит `.aggregate` панос (без тега —
    // доступ к полям чисто позиционный, `getProperty`/`setProperty` в
    // `vm.zig` никогда не смотрят на `.name`, см. `buildStruct`) из сырых
    // байт C ABI.
    fn unpackStruct(self: *Vm, source: [*]const u8, layout: []const ast_types.ForeignMarshalKind, offsets: []const usize) anyerror!value.Value {
        if (offsets.len != layout.len) {
            try self.fault("Runtime Error: layout ff_структура не совпадает при 'внешний'-вызове", .{});
            return .{ .void = {} };
        }
        const elements = try self.allocator.alloc(value.Value, layout.len);
        for (layout, offsets, elements) |kind, offset, *slot| slot.* = unpackScalar(kind, source + offset);
        const aggregate = try self.heap.createAggregate(null, elements);
        return .{ .aggregate = aggregate };
    }

    fn cachedForeignCall(self: *Vm, info: *const bytecode.ForeignFunctionConstant) anyerror!?*PreparedForeignCall {
        if (self.foreign_call_cache.get(info)) |prepared| return prepared;

        if (self.foreign_profile_enabled) {
            const metric = try self.foreignCallMetric(info);
            metric.cache_misses += 1;
        }
        const prepared = self.prepareForeignCall(info) catch |err| {
            if (err == error.ForeignPreparationFailed) return null;
            return err;
        };
        errdefer {
            prepared.deinit(self.allocator);
            self.allocator.destroy(prepared);
        }
        try self.foreign_call_cache.put(info, prepared);
        return prepared;
    }

    fn foreignCallMetric(self: *Vm, info: *const bytecode.ForeignFunctionConstant) !*ForeignCallMetric {
        const entry = try self.foreign_profile.getOrPut(info);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        return entry.value_ptr;
    }

    fn recordForeignTotalTime(self: *Vm, info: *const bytecode.ForeignFunctionConstant, elapsed_ns: u64) !void {
        const metric = try self.foreignCallMetric(info);
        metric.calls += 1;
        metric.total_ns += elapsed_ns;
    }

    fn recordForeignNativeTime(self: *Vm, info: *const bytecode.ForeignFunctionConstant, elapsed_ns: u64) !void {
        const metric = try self.foreignCallMetric(info);
        metric.native_call_ns += elapsed_ns;
    }

    fn prepareForeignCall(self: *Vm, info: *const bytecode.ForeignFunctionConstant) anyerror!*PreparedForeignCall {
        const prepared = try self.allocator.create(PreparedForeignCall);
        prepared.* = .{};
        errdefer {
            prepared.deinit(self.allocator);
            self.allocator.destroy(prepared);
        }

        const nargs = info.param_kinds.len;
        const arg_types = try self.allocator.alloc(?*ffi.FfiType, nargs);
        prepared.arg_types = arg_types;
        const param_offsets = try self.allocator.alloc(?[]usize, nargs);
        prepared.param_struct_offsets = param_offsets;
        @memset(param_offsets, null);

        for (info.param_kinds, info.param_struct_layouts, arg_types) |kind, layout, *slot| {
            if (kind == .struct_value) {
                const struct_type = try ffi.buildStructFfiType(self.allocator, layout);
                try prepared.owned_struct_types.append(self.allocator, .{ .ptr = struct_type, .field_count = layout.len });
                slot.* = struct_type;
            } else {
                slot.* = ffi.ffiTypeForMarshal(kind);
            }
        }
        const return_type = if (info.return_kind == .struct_value) blk: {
            const struct_type = try ffi.buildStructFfiType(self.allocator, info.return_struct_layout);
            try prepared.owned_struct_types.append(self.allocator, .{ .ptr = struct_type, .field_count = info.return_struct_layout.len });
            break :blk struct_type;
        } else ffi.ffiTypeForMarshal(info.return_kind);
        prepared.return_type = return_type;

        const prep_status = ffi.ffi_prep_cif(&prepared.cif, ffi.defaultAbi(), @intCast(nargs), return_type, if (nargs > 0) arg_types.ptr else null);
        if (prep_status != ffi.FFI_OK) {
            try self.fault("Runtime Error: ffi_prep_cif не удался (status={d})", .{prep_status});
            return error.ForeignPreparationFailed;
        }

        // ffi_prep_cif вычислил настоящие размеры структур. Фиксируем и
        // offsets, и буферы для последующих вызовов — они неизменны для
        // этой сигнатуры и больше не должны попадать в горячий путь.
        for (info.param_kinds, info.param_struct_layouts, arg_types, param_offsets) |kind, layout, arg_type, *slot| {
            if (kind != .struct_value) continue;
            const offsets = try self.allocator.alloc(usize, layout.len);
            slot.* = offsets;
            const offset_status = ffi.ffi_get_struct_offsets(ffi.defaultAbi(), arg_type.?, offsets.ptr);
            if (offset_status != ffi.FFI_OK) {
                try self.fault("Runtime Error: ffi_get_struct_offsets не удался (status={d})", .{offset_status});
                return error.ForeignPreparationFailed;
            }
        }
        if (info.return_kind == .struct_value) {
            const offsets = try self.allocator.alloc(usize, info.return_struct_layout.len);
            prepared.return_struct_offsets = offsets;
            const offset_status = ffi.ffi_get_struct_offsets(ffi.defaultAbi(), return_type, offsets.ptr);
            if (offset_status != ffi.FFI_OK) {
                try self.fault("Runtime Error: ffi_get_struct_offsets не удался (status={d})", .{offset_status});
                return error.ForeignPreparationFailed;
            }
        }

        const cell_offsets = try self.allocator.alloc(usize, nargs);
        prepared.cell_offsets = cell_offsets;
        var total_cells: usize = 0;
        for (info.param_kinds, arg_types, cell_offsets) |kind, arg_type, *offset| {
            offset.* = total_cells;
            const bytes: usize = if (kind == .struct_value) arg_type.?.size else 8;
            total_cells += (bytes + 7) / 8;
        }
        prepared.total_argument_cells = total_cells;
        const return_cells: usize = if (info.return_kind == .struct_value) (return_type.size + 7) / 8 else 1;
        prepared.argument_storage = try self.allocator.alloc(u64, @max(1, total_cells));
        prepared.argument_values = try self.allocator.alloc(?*anyopaque, nargs);
        prepared.return_storage = try self.allocator.alloc(u64, @max(1, return_cells));
        return prepared;
    }

    // Маршалит `arguments` и выполняет сам FFI-вызов. Подготовка сигнатуры,
    // расчёт layout и выделение хранилища кэшируются `prepareForeignCall`;
    // только сами значения — работа на горячем пути.
    fn invokeForeign(self: *Vm, info: *const bytecode.ForeignFunctionConstant, arguments: []const value.Value) anyerror!value.Value {
        const prepared = (try self.cachedForeignCall(info)) orelse return .{ .void = {} };
        const nargs = info.param_kinds.len;
        const arg_types = prepared.arg_types.?;
        const param_offsets = prepared.param_struct_offsets.?;
        const cell_offsets = prepared.cell_offsets.?;
        const argument_storage = prepared.argument_storage.?;
        const argument_values = prepared.argument_values.?;
        const return_storage = prepared.return_storage.?;

        // Аргументам `КСтрока` нужен настоящий null-терминированный буфер,
        // переживающий вызов `ffi_call` ниже. Это остаётся на каждый вызов,
        // т.к. C получает текущую строку панос, в отличие от ABI-плана выше.
        var cstring_storage: std.ArrayList([:0]u8) = .empty;
        defer {
            for (cstring_storage.items) |buffer| self.allocator.free(buffer);
            cstring_storage.deinit(self.allocator);
        }

        for (info.param_kinds, info.param_struct_layouts, arg_types, cell_offsets, 0..) |kind, layout, arg_type, cell_offset, index| {
            const dest: [*]u8 = @ptrCast(&argument_storage[cell_offset]);
            switch (kind) {
                .int8, .int32, .int64, .float32, .float64 => try self.packScalar(dest, kind, arguments[index]),
                .c_string => {
                    const text = arguments[index].stringBytes() orelse {
                        try self.fault("Runtime Error: 'внешний' ожидает Строку для параметра-КСтроки", .{});
                        return .{ .void = {} };
                    };
                    const buffer = try self.allocator.dupeZ(u8, text);
                    try cstring_storage.append(self.allocator, buffer);
                    const cell: *[*:0]const u8 = @ptrCast(@alignCast(dest));
                    cell.* = buffer.ptr;
                },
                .struct_value => try self.packStruct(dest, layout, param_offsets[index] orelse unreachable, arguments[index]),
                .void, .pointer => unreachable,
            }
            _ = arg_type;
            argument_values[index] = dest;
        }

        const native_started_at: ?u64 = if (self.foreign_profile_enabled) foreignProfileNowNanoseconds() else null;
        ffi.ffi_call(&prepared.cif, @ptrFromInt(info.fn_ptr), return_storage.ptr, if (nargs > 0) argument_values.ptr else null);
        if (native_started_at) |started_at| {
            const finished_at = foreignProfileNowNanoseconds();
            try self.recordForeignNativeTime(info, if (finished_at >= started_at) finished_at - started_at else 0);
        }
        const return_bytes: [*]const u8 = @ptrCast(return_storage.ptr);

        return switch (info.return_kind) {
            .void => .{ .void = {} },
            .int8, .int32, .int64, .float32, .float64 => unpackScalar(info.return_kind, return_bytes),
            .c_string => blk: {
                // Панос всегда копирует возвращённые C строки в GC.
                const raw: ?[*:0]const u8 = @as(*const ?[*:0]const u8, @ptrCast(@alignCast(return_bytes))).*;
                const bytes = if (raw) |pointer| std.mem.span(pointer) else "";
                const heap_string = try self.heap.createString(try self.allocator.dupe(u8, bytes));
                break :blk .{ .heap_string = heap_string };
            },
            .struct_value => try self.unpackStruct(return_bytes, info.return_struct_layout, prepared.return_struct_offsets orelse unreachable),
            .pointer => unreachable,
        };
    }

    fn netConnectSubmit(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("сеть::подключиться", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "сеть::подключиться", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const port_number = try self.number(try self.pop());
        const host = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: сеть.подключиться() ожидает хост типа Строка", .{});
            return;
        };
        const process = self.current_process orelse {
            try self.fault("Runtime Error: сеть.подключиться() вызвано вне процесса", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'сеть::подключиться' недоступно в этом runtime-таргете", .{});
            return;
        }
        if (port_number < 0 or port_number > 65535) {
            // Не отправлено в воркер-пул — синхронная валидационная ошибка
            // должна всё равно прийти через await_async (та же инструкция
            // ВСЕГДА следует за submit'ом), поэтому кладём готовый
            // Результат.Неудача сразу в async_results, а не на self.stack.
            const result = try self.buildErrorResultValue("сеть", "недопустимый номер порта");
            try process.async_results.append(self.allocator, result);
            return;
        }
        const port: u16 = @intFromFloat(port_number);
        submitNetConnect(self, host, port, process.id);
    }

    // Bind+listen — быстрый, локальный, одноразовый системный вызов — в
    // отличие от `.accept()` (который может блокироваться неопределённо
    // долго в ожидании клиента), это остаётся синхронным.
    fn httpListen(self: *Vm) anyerror!void {
        target_policy.ensureRuntimeBuiltinAvailable("сеть::http_сервер_слушать", self.target_profile) catch {
            const message = try target_policy.runtimeErrorMessage(self.allocator, "сеть::http_сервер_слушать", self.target_profile);
            defer self.allocator.free(message);
            try self.fault("{s}", .{message});
            return;
        };
        const port_number = try self.number(try self.pop());
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'сеть::http_сервер_слушать' недоступно в этом runtime-таргете", .{});
            return;
        }
        if (port_number < 0 or port_number > 65535) {
            try self.pushErrorResultForModule("сеть", "недопустимый номер порта");
            return;
        }
        const port: u16 = @intFromFloat(port_number);
        var io = std.Io.Threaded.init(self.allocator, .{});
        defer io.deinit();
        const address = std.Io.net.IpAddress.parse("0.0.0.0", port) catch |err| {
            try self.pushErrorResultForModule("сеть", @errorName(err));
            return;
        };
        const server = address.listen(io.io(), .{ .reuse_address = true }) catch |err| {
            try self.pushErrorResultForModule("сеть", @errorName(err));
            return;
        };
        const listener = try self.heap.createListener(server);
        try self.pushSuccessResult(.{ .listener = listener });
    }

    fn popListener(self: *Vm, method_name: []const u8) anyerror!?*value.Listener {
        const receiver = try self.pop();
        return switch (receiver) {
            .listener => |listener| listener,
            else => {
                try self.fault("Runtime Error: {s} ожидает слушатель", .{method_name});
                return null;
            },
        };
    }

    fn popHttpRequestHandle(self: *Vm, method_name: []const u8) anyerror!?*value.HttpRequestHandle {
        const receiver = try self.pop();
        return switch (receiver) {
            .http_request => |request| request,
            else => {
                try self.fault("Runtime Error: {s} ожидает Запрос", .{method_name});
                return null;
            },
        };
    }

    fn httpAcceptSubmit(self: *Vm) anyerror!void {
        const listener = try self.popListener("Слушатель.принять_запрос()") orelse return;
        if (!listener.is_open) {
            const result = try self.buildErrorResultValue("сеть", "слушатель уже закрыт");
            try self.appendAsyncResultForCurrentProcess(result);
            return;
        }
        const process = self.current_process orelse {
            try self.fault("Runtime Error: Слушатель.принять_запрос() вызвано вне процесса", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'Слушатель.принять_запрос' недоступно в этом runtime-таргете", .{});
            return;
        }
        // Нет флага in_flight (в отличие от Connection/FileHandle/
        // SqlConnection) — НЕСКОЛЬКО параллельных accept на одном
        // слушателе — это и есть смысл сервера (пул воркеров вычерпывает
        // "очередь" accept параллельно, сколько бы процессов ни вызывало
        // .принять_запрос()); `Heap.pin` поддерживает несколько
        // одновременных закреплений одного значения (см. комментарий у
        // `http_accept` в `AsyncPayload`). Сам accept() безопасно вызывать
        // из нескольких потоков на одном слушающем сокете.
        try self.heap.pin(.{ .listener = listener });
        submitHttpAccept(self, listener, process.id);
    }

    fn httpRequestMethod(self: *Vm) anyerror!void {
        const request = try self.popHttpRequestHandle("Запрос.метод()") orelse return;
        try self.stack.append(self.allocator, .{ .string = request.method });
    }

    fn httpRequestPath(self: *Vm) anyerror!void {
        const request = try self.popHttpRequestHandle("Запрос.путь()") orelse return;
        try self.stack.append(self.allocator, .{ .string = request.path });
    }

    fn httpRequestBody(self: *Vm) anyerror!void {
        const request = try self.popHttpRequestHandle("Запрос.тело()") orelse return;
        try self.stack.append(self.allocator, .{ .string = request.body });
    }

    fn httpRequestHeader(self: *Vm) anyerror!void {
        const name = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: Запрос.заголовок() ожидает имя типа Строка", .{});
            return;
        };
        const request = try self.popHttpRequestHandle("Запрос.заголовок()") orelse return;
        for (request.headers) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) {
                const heap_string = try self.heap.createString(try self.allocator.dupe(u8, entry.value));
                try self.pushOption(.{ .heap_string = heap_string });
                return;
            }
        }
        try self.pushOption(null);
    }

    // Синхронно, как `.закрыть()` — форматирование+запись ответа быстрая
    // локальная операция на уже подключённом сокете, нет нужды направлять
    // её через пул async-воркеров. Один запрос на соединение (без
    // keep-alive) — поток закрывается сразу после ответа.
    fn httpRequestRespond(self: *Vm) anyerror!void {
        const body = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: Запрос.ответить() ожидает тело типа Строка", .{});
            return;
        };
        const content_type = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: Запрос.ответить() ожидает тип содержимого типа Строка", .{});
            return;
        };
        const status = try self.number(try self.pop());
        const request = try self.popHttpRequestHandle("Запрос.ответить()") orelse return;
        if (request.responded) {
            try self.fault("Runtime Error: Запрос.ответить() уже было вызвано для этого запроса", .{});
            return;
        }
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'Запрос.ответить' недоступно в этом runtime-таргете", .{});
            return;
        }
        const status_code: u32 = @intFromFloat(status);
        var io = std.Io.Threaded.init(self.allocator, .{});
        defer io.deinit();
        const response_text = try std.fmt.allocPrint(
            self.allocator,
            "HTTP/1.1 {d} панос\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
            .{ status_code, content_type, body.len, body },
        );
        defer self.allocator.free(response_text);
        request.responded = true;
        // Best-effort — `Запрос.ответить()` возвращает обычное `Пусто`, не
        // `Результат`: ошибка записи здесь почти всегда просто значит, что
        // клиент уже отключился, и обработчик запроса ничего осмысленного
        // с этим сделать не может.
        var writer = request.stream.writer(io.io(), &.{});
        writer.interface.writeAll(response_text) catch {};
        writer.interface.flush() catch {};
        request.stream.close(io.io());
        try self.stack.append(self.allocator, .{ .void = {} });
    }

    // `ответить` (выше) отдаёт ровно Content-Type/Content-Length — этого
    // достаточно для JSON-ответов `быстряга`, но НЕ для редиректов
    // (`Location`) или установки сессионных cookie (`Set-Cookie`) —
    // обоих реальных потребностей OAuth2 authorization code flow
    // (`дозорный`), у которых нет способа выразиться через
    // статус+тип+тело. Отдельный метод, не необязательный параметр —
    // `ответить` уже выпущен и используется, немолчаливое расширение
    // сигнатуры сломало бы все существующие вызовы; тот же паттерн, что
    // `_с_заголовками`-варианты клиентских http.* функций.
    fn httpRequestRespondHeaders(self: *Vm) anyerror!void {
        const headers_value = try self.pop();
        const headers_map = switch (headers_value) {
            .map => |map| map,
            else => {
                try self.fault("Runtime Error: Запрос.ответить_с_заголовками() ожидает Соответствие(Строка, Строка) четвёртым аргументом", .{});
                return;
            },
        };
        const body = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: Запрос.ответить_с_заголовками() ожидает тело типа Строка", .{});
            return;
        };
        const content_type = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: Запрос.ответить_с_заголовками() ожидает тип содержимого типа Строка", .{});
            return;
        };
        const status = try self.number(try self.pop());
        const request = try self.popHttpRequestHandle("Запрос.ответить_с_заголовками()") orelse return;
        if (request.responded) {
            try self.fault("Runtime Error: Запрос.ответить_с_заголовками() уже было вызвано для этого запроса", .{});
            return;
        }
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'Запрос.ответить_с_заголовками' недоступно в этом runtime-таргете", .{});
            return;
        }
        const status_code: u32 = @intFromFloat(status);
        var extra_headers: std.ArrayList(u8) = .empty;
        defer extra_headers.deinit(self.allocator);
        for (headers_map.entries.items) |map_entry| {
            const name = map_entry.key.stringBytes() orelse continue;
            const header_value = map_entry.value.stringBytes() orelse continue;
            const header_line = try std.fmt.allocPrint(self.allocator, "{s}: {s}\r\n", .{ name, header_value });
            defer self.allocator.free(header_line);
            try extra_headers.appendSlice(self.allocator, header_line);
        }
        var io = std.Io.Threaded.init(self.allocator, .{});
        defer io.deinit();
        const response_text = try std.fmt.allocPrint(
            self.allocator,
            "HTTP/1.1 {d} панос\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n{s}Connection: close\r\n\r\n{s}",
            .{ status_code, content_type, body.len, extra_headers.items, body },
        );
        defer self.allocator.free(response_text);
        request.responded = true;
        var writer = request.stream.writer(io.io(), &.{});
        writer.interface.writeAll(response_text) catch {};
        writer.interface.flush() catch {};
        request.stream.close(io.io());
        try self.stack.append(self.allocator, .{ .void = {} });
    }

    fn popConnection(self: *Vm, method_name: []const u8) anyerror!?*value.Connection {
        const receiver = try self.pop();
        return switch (receiver) {
            .connection => |connection| connection,
            else => {
                try self.fault("Runtime Error: {s} ожидает соединение", .{method_name});
                return null;
            },
        };
    }

    fn connectionReadSubmit(self: *Vm) anyerror!void {
        const connection = try self.popConnection("Соединение.получить()") orelse return;
        if (!connection.is_open) {
            const result = try self.buildErrorResultValue("сеть", "соединение уже закрыто");
            try self.appendAsyncResultForCurrentProcess(result);
            return;
        }
        if (connection.in_flight) {
            const result = try self.buildErrorResultValue("сеть", "соединение уже используется другой операцией");
            try self.appendAsyncResultForCurrentProcess(result);
            return;
        }
        const process = self.current_process orelse {
            try self.fault("Runtime Error: Соединение.получить() вызвано вне процесса", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'Соединение.получить' недоступно в этом runtime-таргете", .{});
            return;
        }
        // Сливаем всё, что предыдущий `.получить_строку()` уже вытянул с
        // провода, но ещё не потребил — передаётся воркеру как стартовый
        // буфер, дальше он читает сырые куски (внутренний буфер нулевой
        // длины — см. doc-комментарий `Connection` в `value.zig`), пока
        // собеседник не закроет соединение.
        const drained = try connection.pending.toOwnedSlice(self.allocator);
        defer self.allocator.free(drained);
        connection.in_flight = true;
        try self.heap.pin(.{ .connection = connection });
        submitConnectionRead(self, connection, connection.stream, drained, process.id);
    }

    fn appendAsyncResultForCurrentProcess(self: *Vm, result: value.Value) !void {
        const process = self.current_process orelse return;
        try process.async_results.append(self.allocator, result);
    }

    fn connectionReadLineSubmit(self: *Vm) anyerror!void {
        const connection = try self.popConnection("Соединение.получить_строку()") orelse return;
        if (!connection.is_open) {
            const result = try self.buildErrorResultValue("сеть", "соединение уже закрыто");
            try self.appendAsyncResultForCurrentProcess(result);
            return;
        }
        if (connection.in_flight) {
            const result = try self.buildErrorResultValue("сеть", "соединение уже используется другой операцией");
            try self.appendAsyncResultForCurrentProcess(result);
            return;
        }
        const process = self.current_process orelse {
            try self.fault("Runtime Error: Соединение.получить_строку() вызвано вне процесса", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'Соединение.получить_строку' недоступно в этом runtime-таргете", .{});
            return;
        }
        const drained = try connection.pending.toOwnedSlice(self.allocator);
        defer self.allocator.free(drained);
        connection.in_flight = true;
        try self.heap.pin(.{ .connection = connection });
        submitConnectionReadLine(self, connection, connection.stream, drained, process.id);
    }

    fn connectionWriteSubmit(self: *Vm) anyerror!void {
        const content = (try self.pop()).stringBytes() orelse {
            try self.fault("Runtime Error: Соединение.отправить() ожидает содержимое типа Строка", .{});
            return;
        };
        const connection = try self.popConnection("Соединение.отправить()") orelse return;
        if (!connection.is_open) {
            const result = try self.buildErrorResultValue("сеть", "соединение уже закрыто");
            try self.appendAsyncResultForCurrentProcess(result);
            return;
        }
        if (connection.in_flight) {
            const result = try self.buildErrorResultValue("сеть", "соединение уже используется другой операцией");
            try self.appendAsyncResultForCurrentProcess(result);
            return;
        }
        const process = self.current_process orelse {
            try self.fault("Runtime Error: Соединение.отправить() вызвано вне процесса", .{});
            return;
        };
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'Соединение.отправить' недоступно в этом runtime-таргете", .{});
            return;
        }
        connection.in_flight = true;
        try self.heap.pin(.{ .connection = connection });
        submitConnectionWrite(self, connection, connection.stream, content, process.id);
    }

    fn connectionClose(self: *Vm) anyerror!void {
        const connection = try self.popConnection("Соединение.закрыть()") orelse return;
        if (!connection.is_open) {
            try self.stack.append(self.allocator, .{ .void = {} });
            return;
        }
        if (comptime builtin.target.os.tag == .freestanding) {
            try self.fault("Runtime Panic: 'Соединение.закрыть' недоступно в этом runtime-таргете", .{});
            return;
        }
        if (connection.in_flight) {
            // Не закрываем fd, пока воркер читает через него — реальный
            // close() применится в finishConnectionFlight, как только
            // текущее чтение доставит результат (см. deliverAsyncResult).
            // is_open переключается СРАЗУ (видимое поведение для panos-кода
            // — "уже закрыто" на любой дальнейший вызов), только сам
            // syscall откладывается.
            connection.close_requested = true;
            connection.is_open = false;
            try self.stack.append(self.allocator, .{ .void = {} });
            return;
        }
        var io = std.Io.Threaded.init(self.allocator, .{});
        defer io.deinit();
        connection.stream.close(io.io());
        connection.is_open = false;
        try self.stack.append(self.allocator, .{ .void = {} });
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
        const right_value = switch (try self.pop()) {
            .interface => |interface| interface.receiver,
            else => |other| other,
        };
        const left_value = switch (try self.pop()) {
            .interface => |interface| interface.receiver,
            else => |other| other,
        };
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
            const outcome = self.step() catch |err| switch (err) {
                error.RuntimeFault => {
                    nested_failure = self.failure;
                    return err;
                },
                else => return err,
            };
            switch (outcome) {
                .none => {},
                .completed => |result| return result,
                // У реализации Сравниваемое, вызывающей получить()/
                // получить_сигнал()/асинхронный билтин, здесь нет контекста
                // процесса, в который можно приостановиться — это
                // синхронный вложенный вызов, а не квант планировщика.
                .suspended => {
                    self.fault("Runtime Error: реализация Сравниваемое не может приостанавливаться (получить/асинхронный вызов)", .{}) catch |err| {
                        nested_failure = self.failure;
                        return err;
                    };
                },
            }
        }
        return .{ .void = {} };
    }

    // Та же форма вложенного вызова, что у `invokeComparable`, один
    // аргумент вместо двух (`клонировать(это)`) — синхронно выполняет
    // переопределение `реализация Копируемое` до конца и возвращает его
    // результат. Используется `deepCopyForSend` ниже.
    fn invokeCopyable(self: *Vm, function_id: bytecode.FunctionId, receiver: value.Value) anyerror!value.Value {
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

        self.pushFrame(function_id, &.{}, &.{receiver}) catch |err| switch (err) {
            error.RuntimeFault => {
                nested_failure = self.failure;
                return err;
            },
            else => return err,
        };
        while (self.frames.items.len != 0) {
            const outcome = self.step() catch |err| switch (err) {
                error.RuntimeFault => {
                    nested_failure = self.failure;
                    return err;
                },
                else => return err,
            };
            switch (outcome) {
                .none => {},
                .completed => |result| return result,
                // Та же причина, что у `invokeComparable` — у
                // переопределения Копируемое, вызывающего
                // получить()/получить_сигнал()/асинхронный билтин, здесь
                // нет контекста процесса для приостановки.
                .suspended => {
                    self.fault("Runtime Error: реализация Копируемое не может приостанавливаться (получить/асинхронный вызов)", .{}) catch |err| {
                        nested_failure = self.failure;
                        return err;
                    };
                },
            }
        }
        return .{ .void = {} };
    }

    // Обеспечивает изоляцию copy-on-send при отправке сообщения между
    // процессами. Два пути диспетчеризации, зеркалящие уже существующий
    // поиск по имени у `Сравниваемое`:
    //   - у имени рантайм-структуры сообщения есть зарегистрированное
    //     переопределение `реализация Копируемое`
    //     (`registerCopyableMethods`, `compiler.zig`) — вызываем его
    //     напрямую и доверяем результату КАК ЕСТЬ (без дальнейшего
    //     рефлективного обхода — кастомное переопределение существует
    //     именно для контроля того, что копируется, например намеренного
    //     разделения поля кэша; повторный обход после этого свёл бы это на
    //     нет).
    //   - иначе рефлективно обходим структуру значения и строим независимую
    //     копию — безопасно к циклам через `seen` (старый указатель кучи →
    //     уже построенная копия), та же форма, что и у собственной защиты
    //     от циклов GC-маркировщика, только строит копию вместо установки
    //     бита маркировки.
    // Примитивы (Число/Булево/Пусто/Никогда) и heap-строки НЕ копируются —
    // строки панос неизменяемы, поэтому делить их всегда безопасно.
    // Хендлы нативных ресурсов (Процесс/Файл/Соединение/Соединение_БД/
    // Слушатель/Запрос) тоже НЕ копируются — они идентифицируют живой
    // ресурс, а не данные; копирование было бы бессмысленным ("клонированный"
    // хендл файла не указывает на вторую копию файла), а отправка хендла
    // `Процесс(T)` должна продолжать указывать на ТОТ ЖЕ целевой процесс.
    fn deepCopyForSend(self: *Vm, source: value.Value) anyerror!value.Value {
        var seen = std.AutoHashMap(usize, value.Value).init(self.allocator);
        defer seen.deinit();
        return self.deepCopyForSendInner(source, &seen);
    }

    fn deepCopyForSendInner(self: *Vm, source: value.Value, seen: *std.AutoHashMap(usize, value.Value)) anyerror!value.Value {
        return switch (source) {
            .aggregate => |aggregate| blk: {
                const key = @intFromPtr(aggregate);
                if (seen.get(key)) |existing| break :blk existing;
                if (aggregate.name) |type_name| {
                    if (self.program.copyableMethod(type_name)) |method| {
                        const copied = try self.invokeCopyable(method, source);
                        try seen.put(key, copied);
                        break :blk copied;
                    }
                }
                const elements = try self.allocator.alloc(value.Value, aggregate.elements.len);
                const new_aggregate = try self.heap.createAggregate(aggregate.name, elements);
                const copied: value.Value = .{ .aggregate = new_aggregate };
                try seen.put(key, copied);
                for (aggregate.elements, elements) |element, *dest| dest.* = try self.deepCopyForSendInner(element, seen);
                break :blk copied;
            },
            .array => |array| blk: {
                const key = @intFromPtr(array);
                if (seen.get(key)) |existing| break :blk existing;
                const elements = try self.allocator.alloc(value.Value, array.elements.len);
                const new_array = try self.heap.createArray(elements);
                const copied: value.Value = .{ .array = new_array };
                try seen.put(key, copied);
                for (array.elements, elements) |element, *dest| dest.* = try self.deepCopyForSendInner(element, seen);
                break :blk copied;
            },
            .map => |map| blk: {
                const key = @intFromPtr(map);
                if (seen.get(key)) |existing| break :blk existing;
                const new_map = try self.heap.createMap();
                const copied: value.Value = .{ .map = new_map };
                try seen.put(key, copied);
                for (map.entries.items) |entry| {
                    try new_map.entries.append(self.allocator, .{
                        .key = try self.deepCopyForSendInner(entry.key, seen),
                        .value = try self.deepCopyForSendInner(entry.value, seen),
                    });
                }
                break :blk copied;
            },
            .closure => |closure| blk: {
                const key = @intFromPtr(closure);
                if (seen.get(key)) |existing| break :blk existing;
                const captures = try self.allocator.alloc(value.Value, closure.captures.len);
                const new_closure = try self.heap.createClosure(closure.function_id, captures);
                const copied: value.Value = .{ .closure = new_closure };
                try seen.put(key, copied);
                for (closure.captures, captures) |capture, *dest| dest.* = try self.deepCopyForSendInner(capture, seen);
                break :blk copied;
            },
            .interface => |interface| blk: {
                const key = @intFromPtr(interface);
                if (seen.get(key)) |existing| break :blk existing;
                const receiver_copy = try self.deepCopyForSendInner(interface.receiver, seen);
                const copied: value.Value = .{ .interface = try self.heap.createInterfacePackage(receiver_copy, interface.vtables) };
                try seen.put(key, copied);
                break :blk copied;
            },
            else => source,
        };
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
        const vtables = switch (compiled.constants.items[vtable_index]) {
            .interface_vtable => |vtable| &.{vtable},
            .interface_vtables => |tables| tables,
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
        const interface = try self.heap.createInterfacePackage(receiver, vtables);
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
            .aggregate => |aggregate| {
                // Значение вошло в generic-область БЕЗ Cast_Interface-обёртки
                // (например, поле generic-типизированной структуры,
                // построенное СНАРУЖИ generic-контекста, не через один из
                // известных compile-time cast-injection путей — найдено
                // вживую на `быстряга`: `Отклик(Ответ).тело`, где `Ответ`
                // — generic-bound поле, построенное внутри лямбды-обработчика
                // до пересечения generic-границы). Резервная диспетчеризация
                // напрямую по имени (interface_name, method_name, type_name)
                // — тот же проверенный приём, что уже используют
                // Сравниваемое/Копируемое (`Program.comparableMethod` и
                // т.п.), просто обобщённый на любой интерфейс. `call_info`
                // без имён (пустые строки, см. bytecode.zig) — единственный
                // существующий вызывающий это `for ... в` для Итерируемое —
                // просто не найдёт совпадения и провалится в исходный fault
                // ниже, поведение не меняется.
                if (aggregate.name) |type_name| {
                    if (self.program.interfaceMethod(call_info.interface_name, call_info.method_name, type_name)) |target_function_id| {
                        self.stack.items[interface_index] = .{ .function_ref = target_function_id };
                        try self.stack.insert(self.allocator, interface_index + 1, .{ .aggregate = aggregate });
                        try self.call(@intCast(argument_count + 1));
                        return;
                    }
                }
                try self.fault("Runtime Error: попытка вызвать интерфейсный метод у не-интерфейса", .{});
                return;
            },
            else => {
                try self.fault("Runtime Error: попытка вызвать интерфейсный метод у не-интерфейса", .{});
                return;
            },
        };
        if (call_info.vtable_index >= interface.vtables.len) {
            try self.fault("Runtime Error: vtable интерфейсного метода не найдена", .{});
            return;
        }
        const methods = interface.vtables[call_info.vtable_index];
        if (call_info.method_index >= methods.len) {
            try self.fault("Runtime Error: метод не найден в vtable интерфейса", .{});
            return;
        }
        const target_function_id = methods[call_info.method_index];
        // Собственный `это.другой_метод()` метода по умолчанию должен
        // снова диспетчеризоваться через vtable — его скомпилированный
        // параметр `это` имеет АБСТРАКТНЫЙ тип интерфейса, не конкретную
        // структуру, поэтому ему нужно ОБЁРНУТОЕ значение `.interface`, а
        // не сырое базовое, которое требуется обычному impl-методу
        // (реальный доступ к полю конкретной структуры). См.
        // doc-комментарий `bytecode.Function.is_default_interface_method`.
        const is_default = if (self.program.functionConst(target_function_id)) |target| target.is_default_interface_method else false;
        const this_argument: value.Value = if (is_default) self.stack.items[interface_index] else interface.receiver;
        self.stack.items[interface_index] = .{ .function_ref = target_function_id };
        try self.stack.insert(self.allocator, interface_index + 1, this_argument);
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
            // Глубокое копирование для изоляции акторов — см. собственный
            // комментарий `deepCopyForSend`. Делается только когда цель
            // реально жива (мёртвая цель в любом случае тихий no-op, нет
            // смысла платить за копирование).
            try target.mailbox.append(self.allocator, try self.deepCopyForSend(message));
        }
        try self.stack.append(self.allocator, .{ .void = {} });
    }

    fn receive(self: *Vm) anyerror!bool {
        const process = self.current_process orelse {
            try self.fault("Runtime Error: получить() вызвано вне процесса", .{});
            return false;
        };
        if (process.mailbox.items.len == 0) return true;
        const message = process.mailbox.orderedRemove(0);
        try self.stack.append(self.allocator, message);
        return false;
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

    fn getSignal(self: *Vm) anyerror!bool {
        const process = self.current_process orelse {
            try self.fault("Runtime Error: получить_сигнал() вызвано вне процесса", .{});
            return false;
        };
        if (process.signals.items.len == 0) return true;
        const signal = process.signals.orderedRemove(0);
        try self.stack.append(self.allocator, signal);
        return false;
    }

    // `ждать(процесс)` — в отличие от получить/получить_сигнал/await_async
    // (без параметров, блокируются на собственной очереди ТЕКУЩЕГО
    // процесса), `ждать` принимает аргумент (целевой хендл `Процесс(T)`),
    // уже лежащий на стеке от `compileExpression(call.arguments[0])`.
    // Приостановка здесь только откатывает `frame.ip` назад к ЭТОЙ
    // инструкции — инструкции вычисления аргумента перед ней НЕ
    // выполняются заново — поэтому цель нужно ПОДСМОТРЕТЬ (не снимать со
    // стека), пока она ещё в ожидании, и реально потребить только когда
    // готова положить настоящий результат.
    fn awaitTask(self: *Vm) anyerror!bool {
        const waiter = self.current_process orelse {
            _ = try self.pop();
            try self.fault("Runtime Error: ждать() вызвано вне процесса", .{});
            return false;
        };
        if (self.stack.items.len == 0) {
            try self.fault("Runtime Error: ждать() ожидает Процесс(T) первым аргументом", .{});
            return false;
        }
        const target = switch (self.stack.items[self.stack.items.len - 1]) {
            .process => |process| process,
            else => {
                _ = try self.pop();
                try self.fault("Runtime Error: ждать() ожидает Процесс(T) первым аргументом", .{});
                return false;
            },
        };
        const outcome = target.result orelse {
            // Один процесс всегда выполняет только одну инструкцию за раз
            // (кооперативно, однопоточно) — он не может уже быть
            // зарегистрирован ожидающим для ДРУГОГО ещё не завершённого
            // `ждать`, когда начинается этот, поэтому простой append здесь
            // на практике не может дать устаревшую/дублирующуюся
            // регистрацию.
            try target.task_waiters.append(self.allocator, waiter);
            return true;
        };
        _ = try self.pop();
        switch (outcome) {
            .completed => |result| try self.pushSuccessResult(result),
            .failed => |message| try self.pushErrorResultForModule("процесс", message.bytes),
        }
        return false;
    }

    // `выбор ожидание(источник) ... конец` — как и `awaitTask`, массив
    // источника подсматривается (не снимается со стека), пока ничего не
    // готово, т.к. приостановка только откатывает `frame.ip` назад к ЭТОЙ
    // инструкции, а инструкции вычисления массива заново не выполняются.
    // Порядок приоритета, когда одновременно готово несколько источников:
    // mailbox, затем signals, затем завершение процесса из списка —
    // совпадает с относительным порядком получить/получить_сигнал/ждать в
    // остальном файле (получить/получить_сигнал всегда проверяются раньше
    // любого пути завершения задачи).
    fn selectWait(self: *Vm) anyerror!bool {
        const waiter = self.current_process orelse {
            _ = try self.pop();
            try self.fault("Runtime Error: 'ожидание' вызвано вне процесса", .{});
            return false;
        };
        if (self.stack.items.len == 0) {
            try self.fault("Runtime Error: 'ожидание' ожидает Массив(Процесс(R))", .{});
            return false;
        }
        const source = switch (self.stack.items[self.stack.items.len - 1]) {
            .array => |array| array,
            else => {
                _ = try self.pop();
                try self.fault("Runtime Error: 'ожидание' ожидает Массив(Процесс(R))", .{});
                return false;
            },
        };
        if (waiter.mailbox.items.len != 0) {
            _ = try self.pop();
            const message = waiter.mailbox.orderedRemove(0);
            try self.pushSelectSource("ИсточникОжидания.Сообщение", &.{message});
            return false;
        }
        if (waiter.signals.items.len != 0) {
            _ = try self.pop();
            const signal = waiter.signals.orderedRemove(0);
            try self.pushSelectSource("ИсточникОжидания.Сигнал", &.{signal});
            return false;
        }
        for (source.elements) |element| {
            const target = switch (element) {
                .process => |process| process,
                else => continue,
            };
            const outcome = target.result orelse continue;
            _ = try self.pop();
            const result_value = switch (outcome) {
                .completed => |payload| try self.buildSuccessResultValue(payload),
                .failed => |message| try self.buildErrorResultValue("процесс", message.bytes),
            };
            try self.pushSelectSource("ИсточникОжидания.Готово", &.{ .{ .process = target }, result_value });
            return false;
        }
        // Пока ничего не готово — регистрируемся ожидающим на каждом ещё
        // не завершённом процессе из списка, защищаясь от дублирующей
        // регистрации при повторах этого же приостановленного опкода (в
        // отличие от `awaitTask`, `selectWait` МОЖЕТ легитимно повторяться
        // несколько раз до того, как что-то станет готово, например,
        // разбужен не связанным сообщением в mailbox, которого к моменту
        // повторного выполнения этой инструкции уже нет).
        for (source.elements) |element| {
            const target = switch (element) {
                .process => |process| process,
                else => continue,
            };
            if (target.result != null) continue;
            var already_registered = false;
            for (target.task_waiters.items) |existing| {
                if (existing == waiter) {
                    already_registered = true;
                    break;
                }
            }
            if (!already_registered) try target.task_waiters.append(self.allocator, waiter);
        }
        return true;
    }

    fn pushSelectSource(self: *Vm, name: []const u8, fields: []const value.Value) anyerror!void {
        const elements = try self.allocator.alloc(value.Value, fields.len);
        @memcpy(elements, fields);
        const aggregate = try self.heap.createAggregate(name, elements);
        try self.stack.append(self.allocator, .{ .aggregate = aggregate });
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

    // `ограничить_почту(N)` — устанавливает ёмкость на СОБСТВЕННОМ почтовом
    // ящике вызывающего процесса (без аргумента-цели, зеркалит форму
    // "текущий процесс" у `себя()`). Только `отправить_или` ниже вообще
    // смотрит на это — обычный `отправить` остаётся слеп к ёмкости.
    fn setMailboxCapacity(self: *Vm) anyerror!void {
        const raw = try self.pop();
        const process = self.current_process orelse {
            try self.fault("Runtime Error: ограничить_почту() вызвано вне процесса", .{});
            return;
        };
        const capacity = try self.number(raw);
        if (capacity < 0) {
            try self.fault("Runtime Error: ограничить_почту() ожидает неотрицательное число", .{});
            return;
        }
        process.mailbox_capacity = @intFromFloat(capacity);
        try self.stack.append(self.allocator, .{ .void = {} });
    }

    // `отправить_или(процесс, сообщение) -> Результат(Пусто, Ошибка)` —
    // opt-in вариант `отправить`, учитывающий backpressure. Отклоняет (без
    // добавления) только когда у ЦЕЛИ есть явная `mailbox_capacity` И она
    // уже достигнута/превышена; неограниченная цель (по умолчанию) никогда
    // не отклоняет, как и обычный `отправить`.
    fn sendOr(self: *Vm) anyerror!void {
        const message = try self.pop();
        const target = switch (try self.pop()) {
            .process => |process| process,
            else => {
                try self.fault("Runtime Error: отправить_или() ожидает Процесс(T) первым аргументом", .{});
                return;
            },
        };
        if (target.status != .ready) {
            try self.pushSuccessResult(.{ .void = {} });
            return;
        }
        if (target.mailbox_capacity) |capacity| {
            if (target.mailbox.items.len >= capacity) {
                try self.pushErrorResultForModule("почта", "почтовый ящик переполнен");
                return;
            }
        }
        try target.mailbox.append(self.allocator, try self.deepCopyForSend(message));
        try self.pushSuccessResult(.{ .void = {} });
    }

    // `отмена(процесс)` — устанавливает флаг у ЦЕЛИ; чисто рекомендательно,
    // ничто не заставляет цель это заметить. Родственно `убить()`
    // (структурно: снимает со стека `Процесс(T)`), но не нужны ограничения
    // на самоотмену/главный процесс, т.к. это само по себе никогда ничего
    // реально не останавливает.
    fn requestCancel(self: *Vm) anyerror!void {
        const target = switch (try self.pop()) {
            .process => |process| process,
            else => {
                try self.fault("Runtime Error: отмена() ожидает Процесс(T) первым аргументом", .{});
                return;
            },
        };
        target.cancel_requested = true;
        try self.stack.append(self.allocator, .{ .void = {} });
    }

    // `отменено()` — опрашивает собственный флаг ТЕКУЩЕГО процесса.
    // Процесс, который никогда его не вызывает, никогда не увидит отмену.
    fn isCancelled(self: *Vm) anyerror!void {
        const process = self.current_process orelse {
            try self.fault("Runtime Error: отменено() вызвано вне процесса", .{});
            return;
        };
        try self.stack.append(self.allocator, .{ .boolean = process.cancel_requested });
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

    const SliceOutcome = union(enum) {
        completed: value.Value,
        suspended,
        // CPU-bound процесс (цикл без блокирующего вызова внутри) исчерпал
        // бюджет инструкций, не дойдя до завершения, сбоя или блокирующей
        // операции — отличается от `.suspended`, которое значит
        // "заблокирован на пустом mailbox/signal/async-очереди, повторно
        // проверить ТУ ЖЕ инструкцию на следующем такте." У исчерпания
        // бюджета нет такого отката: цикл ниже проверяет бюджет только
        // МЕЖДУ завершёнными вызовами `step()`, никогда посреди
        // диспетчеризации, так что `frame.ip` уже стоит ровно там, откуда
        // должно возобновиться выполнение — новое сохраняемое состояние не
        // нужно сверх того, что уже поддерживает приостановка/возобновление.
        budget_exhausted,
        failed,
    };

    // Процесс выполняет не более стольких байткод-инструкций за такт
    // планировщика, прежде чем добровольно уступить управление, даже если
    // никогда не вызывает получить()/получить_сигнал()/асинхронный
    // билтин. Без этого CPU-bound `пока истина цикл ... конец` без
    // блокирующего вызова внутри повесил бы ВСЮ VM навсегда. Значение —
    // приблизительный эмпирический баланс: достаточно большое, чтобы
    // обычные короткоживущие тела процессов никогда его не достигали
    // (избегая ненужных накладных расходов на переключение в общем
    // случае), достаточно маленькое, чтобы процесс с активным циклом не
    // мог морить голодом заблокированных на сообщениях соседей дольше
    // ограниченного числа тактов планировщика.
    const process_instruction_budget: u32 = 100_000;

    // Выполняет ОДИН процесс на один такт планировщика: подставляет его
    // сохранённые stack/frames в общие vm.stack/vm.frames (дёшево —
    // заголовок ArrayList, не копия данных), шагает, пока не завершится,
    // не упадёт, не приостановится (получить/получить_сигнал/Await_Async
    // на пустой очереди) или не исчерпает бюджет инструкций, затем
    // подставляет обратно его (возможно, ещё посреди кадра) состояние.
    fn runProcessSlice(self: *Vm, process: *value.Process) anyerror!SliceOutcome {
        self.stack = process.stack;
        self.frames = process.frames;
        self.failure = null;
        self.current_process = process;
        defer {
            // Полностью переносим владение обратно (не просто копируем
            // заголовок) — если оставить self.stack/self.frames
            // алиасированными на тот же буфер, что и у
            // process.stack/process.frames, при Vm.deinit() произошёл бы
            // двойной free (и `self.frames.deinit()`, и `process.deinit()`
            // освободили бы одну и ту же аллокацию).
            process.stack = self.stack;
            process.frames = self.frames;
            self.stack = .empty;
            self.frames = .empty;
        }
        if (self.frames.items.len == 0) {
            self.pushFrame(process.function_id, process.captures, process.arguments) catch |err| switch (err) {
                error.RuntimeFault => return .failed,
                else => return err,
            };
        }
        var instructions_run: u32 = 0;
        while (self.frames.items.len != 0) {
            if (instructions_run >= process_instruction_budget) return .budget_exhausted;
            const outcome = self.step() catch |err| switch (err) {
                error.RuntimeFault => return .failed,
                else => return err,
            };
            instructions_run += 1;
            switch (outcome) {
                .none => {},
                .suspended => return .suspended,
                .completed => |result| return .{ .completed = result },
            }
        }
        return .{ .completed = .{ .void = {} } };
    }

    // Round-robin драйвер: процесс runnable, если он ещё никогда не
    // выполнялся, или у него есть ожидающее сообщение mailbox / сигнал
    // монитора / async-результат. Возвращается, как только КОРНЕВОЙ процесс
    // (индекс 0, "старт()") завершается или падает — осиротевшие процессы
    // просто забрасываются.
    fn runScheduler(self: *Vm, root: *value.Process) anyerror!Execution {
        while (true) {
            self.drainAsyncCompletions();
            var any_ran = false;
            var i: usize = 0;
            while (i < self.processes.items.len) : (i += 1) {
                const process = self.processes.items[i];
                if (process.status != .ready) continue;
                // Процесс с исчерпанным бюджетом ИЛИ ожидающий пробуждения
                // задачи НЕ заблокирован ни на чём — он всегда должен быть
                // допущен к следующему такту, иначе CPU-bound активный цикл
                // (или процесс, чья задача из `ждать` только что
                // завершилась) был бы ошибочно принят за "нет работы" в тот
                // момент, когда его mailbox/signals/async_results все
                // пусты.
                if (process.has_run and !process.budget_exhausted and !process.task_wakeup_pending and process.mailbox.items.len == 0 and process.signals.items.len == 0 and process.async_results.items.len == 0) continue;

                any_ran = true;
                process.has_run = true;
                process.task_wakeup_pending = false;
                const outcome = try self.runProcessSlice(process);
                process.budget_exhausted = outcome == .budget_exhausted;
                switch (outcome) {
                    .suspended, .budget_exhausted => {},
                    .completed => |result| {
                        process.status = .completed;
                        completeTask(process, .{ .completed = result });
                        if (process == root) {
                            if (!self.abandon_background_async_on_root_exit) self.joinAsyncPool();
                            return .{ .success = result };
                        }
                        try self.notifyWatchers(process, null);
                    },
                    .failed => {
                        if (process == root) {
                            if (!self.abandon_background_async_on_root_exit) self.joinAsyncPool();
                            return .{ .runtime_error = if (self.failure) |failure| failure.bytes else "Runtime Error: неизвестная ошибка" };
                        }
                        try self.terminateFailedProcess(process);
                    },
                }
            }
            if (!any_ran) {
                if (self.hasPendingAsyncIo()) {
                    self.blockForOneAsyncCompletion();
                    continue;
                }
                return .{ .runtime_error = "Runtime Error: все процессы заблокированы в ожидании сообщений (дедлок)" };
            }
        }
    }

    fn drainAsyncCompletions(self: *Vm) void {
        var drained: std.ArrayList(AsyncCompletion) = .empty;
        defer drained.deinit(std.heap.page_allocator);
        self.async_queue.drain(&drained);
        for (drained.items) |completion| {
            self.deliverAsyncResult(completion) catch {
                // Только настоящая нехватка памяти на ГЛАВНОМ потоке —
                // нет осмысленного частичного состояния, в которое можно
                // откатиться (та же логика, что уже применяется к OOM
                // повсюду в этом файле через `try` без отдельного catch).
                @panic("OOM: не удалось доставить результат async I/O процессу");
            };
        }
    }

    fn hasPendingAsyncIo(self: *Vm) bool {
        return self.async_queue.hasPending();
    }

    fn blockForOneAsyncCompletion(self: *Vm) void {
        self.async_queue.waitForOne();
    }

    fn joinAsyncPool(self: *Vm) void {
        self.async_queue.joinAll();
    }

    fn deliverAsyncResult(self: *Vm, completion: AsyncCompletion) !void {
        // Побочные эффекты жизненного цикла хендла (unpin, сброс
        // in_flight, применение отложенного закрытия) должны выполняться
        // НЕЗАВИСИМО от того, жив ли ещё целевой процесс — `.закрыть()`
        // пока чтение в полёте лишь устанавливает close_requested, именно
        // потому что реальное закрытие применяется ЗДЕСЬ, а не только при
        // успешной доставке.
        switch (completion.payload) {
            .connection_read => |data| self.finishConnectionFlight(data.connection),
            .connection_write => |data| self.finishConnectionFlight(data.connection),
            .file_handle_read => |data| self.finishFileHandleFlight(data.handle, data.new_offset),
            .file_handle_write => |data| self.finishFileHandleFlight(data.handle, data.new_offset),
            .connection_read_line => |data| self.finishConnectionReadLineFlight(data.connection, data.new_pending),
            .sql_exec => |data| self.finishSqlConnectionFlight(data.connection),
            .sql_query => |data| self.finishSqlConnectionFlight(data.connection),
            .http_accept => |data| self.heap.unpin(.{ .listener = data.listener }),
            else => {},
        }
        var target: ?*value.Process = null;
        for (self.processes.items) |process| {
            if (process.id == completion.target_id) {
                target = process;
                break;
            }
        }
        const process = target orelse {
            // Процесс завершился/был убит, пока I/O было в полёте — тихо
            // отбрасываем, тот же приём, что у send() на мёртвый процесс.
            freeAsyncPayload(completion.payload);
            return;
        };
        const result_value = try self.buildAsyncResultValue(completion.payload);
        try process.async_results.append(self.allocator, result_value);
    }

    fn finishConnectionFlight(self: *Vm, connection: *value.Connection) void {
        connection.in_flight = false;
        self.heap.unpin(.{ .connection = connection });
        if (connection.close_requested) {
            if (comptime builtin.target.os.tag == .freestanding) {
                // Недостижимо на практике — завершения connection_read
                // всегда происходят только из submitConnectionRead,
                // которая сама доступна только не под freestanding — но эта
                // функция вызывается безусловно из drainAsyncCompletions
                // для каждой цели, поэтому всё равно нужно настоящее
                // разделение `if`/`else`.
            } else {
                var io = std.Io.Threaded.init(self.allocator, .{});
                defer io.deinit();
                connection.stream.close(io.io());
            }
            connection.is_open = false;
        }
    }

    fn finishFileHandleFlight(self: *Vm, handle: *value.FileHandle, new_offset: usize) void {
        handle.in_flight = false;
        handle.offset = new_offset;
        self.heap.unpin(.{ .file = handle });
    }

    fn finishConnectionReadLineFlight(self: *Vm, connection: *value.Connection, new_pending: []const u8) void {
        self.finishConnectionFlight(connection);
        connection.pending.clearRetainingCapacity();
        connection.pending.appendSlice(self.allocator, new_pending) catch @panic("OOM: восстановление pending после Соединение.получить_строку");
    }

    fn finishSqlConnectionFlight(self: *Vm, connection: *value.SqlConnection) void {
        connection.in_flight = false;
        self.heap.unpin(.{ .sql_connection = connection });
    }

    fn buildAsyncResultValue(self: *Vm, payload: AsyncPayload) !value.Value {
        defer freeAsyncPayload(payload);
        switch (payload) {
            .file_read => |data| {
                if (data.err_message) |message| return self.buildErrorResultValue("фс", message);
                const heap_string = try self.heap.createString(try self.allocator.dupe(u8, data.content.?));
                return self.buildSuccessResultValue(.{ .heap_string = heap_string });
            },
            .gzip_decompress => |data| {
                if (data.err_message) |message| return self.buildErrorResultValue("сжатие", message);
                const heap_string = try self.heap.createString(try self.allocator.dupe(u8, data.content.?));
                return self.buildSuccessResultValue(.{ .heap_string = heap_string });
            },
            .file_write => |data| {
                if (data.err_message) |message| return self.buildErrorResultValue("фс", message);
                return self.buildSuccessResultValue(.{ .number = @floatFromInt(data.bytes_written) });
            },
            .net_connect => |data| {
                if (data.err_message) |message| return self.buildErrorResultValue("сеть", message);
                const connection = try self.heap.createConnection(data.stream.?);
                return self.buildSuccessResultValue(.{ .connection = connection });
            },
            .http_request => |data| {
                if (data.err_message) |message| return self.buildErrorResultValue("сеть", message);
                const tuple_value = try self.buildHttpAggregateResult(data.result.?);
                return self.buildSuccessResultValue(tuple_value);
            },
            .connection_read => |data| {
                if (data.err_message) |message| return self.buildErrorResultValue("сеть", message);
                const heap_string = try self.heap.createString(try self.allocator.dupe(u8, data.content.?));
                return self.buildSuccessResultValue(.{ .heap_string = heap_string });
            },
            .connection_write => |data| {
                if (data.err_message) |message| return self.buildErrorResultValue("сеть", message);
                return self.buildSuccessResultValue(.{ .number = @floatFromInt(data.bytes_written) });
            },
            .file_handle_read => |data| {
                if (data.err_message) |message| return self.buildErrorResultValue("фс", message);
                const heap_string = try self.heap.createString(try self.allocator.dupe(u8, data.content.?));
                return self.buildSuccessResultValue(.{ .heap_string = heap_string });
            },
            .file_handle_write => |data| {
                if (data.err_message) |message| return self.buildErrorResultValue("фс", message);
                return self.buildSuccessResultValue(.{ .number = @floatFromInt(data.bytes_written) });
            },
            .connection_read_line => |data| {
                if (data.err_message) |message| return self.buildErrorResultValue("сеть", message);
                const heap_string = try self.heap.createString(try self.allocator.dupe(u8, data.line.?));
                return self.buildSuccessResultValue(.{ .heap_string = heap_string });
            },
            .sql_open => |data| {
                if (data.err_message) |message| return self.buildErrorResultValue("бд", message);
                const connection = try self.heap.createSqlConnection(data.db);
                return self.buildSuccessResultValue(.{ .sql_connection = connection });
            },
            .sql_exec => |data| {
                if (data.err_message) |message| return self.buildErrorResultValue("бд", message);
                return self.buildSuccessResultValue(.{ .number = @floatFromInt(data.rows_affected) });
            },
            .sql_query => |data| {
                if (data.err_message) |message| return self.buildErrorResultValue("бд", message);
                var rows: std.ArrayList(value.Value) = .empty;
                errdefer rows.deinit(self.allocator);
                for (data.rows) |row| {
                    const row_map = try self.heap.createMap();
                    for (data.column_names, row) |name, cell| {
                        const text = cell orelse continue;
                        const key_string = try self.heap.createString(try self.allocator.dupe(u8, name));
                        const value_string = try self.heap.createString(try self.allocator.dupe(u8, text));
                        try row_map.entries.append(self.allocator, .{ .key = .{ .heap_string = key_string }, .value = .{ .heap_string = value_string } });
                    }
                    try rows.append(self.allocator, .{ .map = row_map });
                }
                const rows_array = try self.heap.createArray(try rows.toOwnedSlice(self.allocator));
                return self.buildSuccessResultValue(.{ .array = rows_array });
            },
            .http_accept => |data| {
                if (data.err_message) |message| return self.buildErrorResultValue("сеть", message);
                const method = try self.allocator.dupe(u8, data.method.?);
                const path = try self.allocator.dupe(u8, data.path.?);
                const body = try self.allocator.dupe(u8, data.body.?);
                const headers = try self.allocator.alloc(value.HttpHeaderEntry, data.headers.len);
                for (data.headers, headers) |source_header, *entry| {
                    entry.* = .{
                        .name = try self.allocator.dupe(u8, source_header.name),
                        .value = try self.allocator.dupe(u8, source_header.value),
                    };
                }
                const request = try self.heap.createHttpRequest(data.stream.?, method, path, body, headers);
                return self.buildSuccessResultValue(.{ .http_request = request });
            },
            .time_sleep => |data| return .{ .number = data.millis },
        }
    }

    fn buildSuccessResultValue(self: *Vm, payload: value.Value) !value.Value {
        const elements = try self.allocator.alloc(value.Value, 1);
        elements[0] = payload;
        const aggregate = try self.heap.createAggregate("Результат.Успех", elements);
        return .{ .aggregate = aggregate };
    }

    fn buildErrorResultValue(self: *Vm, module: []const u8, message: []const u8) !value.Value {
        const error_fields = try self.allocator.alloc(value.Value, 2);
        error_fields[0] = .{ .string = module };
        error_fields[1] = .{ .heap_string = try self.heap.formatString("{s}", .{message}) };
        const error_aggregate = try self.heap.createAggregate("Ошибка", error_fields);
        const elements = try self.allocator.alloc(value.Value, 1);
        elements[0] = .{ .aggregate = error_aggregate };
        const aggregate = try self.heap.createAggregate("Результат.Неудача", elements);
        return .{ .aggregate = aggregate };
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
        const failure_message = switch (reason) {
            .heap_string => |string| string,
            else => try self.heap.formatString("{s}", .{reason.stringBytes() orelse "неизвестная ошибка"}),
        };
        completeTask(process, .{ .failed = failure_message });
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

    // Доставляет финальный исход процесса и будит всё заблокированное на
    // `ждать(это)` — вызывается ровно один раз на процесс, из того пути,
    // который его реально завершает (нормальное завершение в
    // `runScheduler`, либо `terminateProcess` при крахе/принудительном
    // `убить()`). Безвредный no-op для процесса, порождённого `запусти`,
    // на котором никто никогда не вызывает `ждать` (пустой `task_waiters`,
    // `result` просто не используется).
    fn completeTask(process: *value.Process, outcome: value.TaskResult) void {
        process.result = outcome;
        for (process.task_waiters.items) |waiter| waiter.task_wakeup_pending = true;
        process.task_waiters.clearRetainingCapacity();
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

    fn arraySlice(self: *Vm) anyerror!void {
        const end_value = try self.pop();
        const start_value = try self.pop();
        const runtime_value = try self.pop();
        const array = switch (runtime_value) {
            .array => |array| array,
            else => {
                try self.fault("Runtime Error: .срез() доступен только для массива", .{});
                return;
            },
        };
        const start = try self.arrayIndex(start_value);
        const end = try self.arrayIndex(end_value);
        if (start > end or end > array.elements.len) {
            try self.fault("Runtime Error: .срез(): границы вне диапазона", .{});
            return;
        }
        const copy = try self.allocator.dupe(value.Value, array.elements[start..end]);
        const result = try self.heap.createArray(copy);
        try self.stack.append(self.allocator, .{ .array = result });
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
        // `.interface` — та же ситуация, что и раскрытая в `callInterface`
        // (см. её doc-комментарий): значение, пересёкшее generic-границу,
        // МОГЛО получить Cast_Interface-обёртку, даже когда компилятор в
        // ТОЧКЕ ДОСТУПА к полю уже знает конкретный тип (например,
        // параметр лямбды с явной конкретной аннотацией типа) и ожидает
        // сырую структуру. Обёртка всё ещё несёт исходную структуру в
        // `.receiver` — прозрачно разворачиваем вместо паники.
        const unwrapped = switch (object) {
            .interface => |interface_value| interface_value.receiver,
            else => object,
        };
        const aggregate = switch (unwrapped) {
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
        const unwrapped = switch (object) {
            .interface => |interface_value| interface_value.receiver,
            else => object,
        };
        const aggregate = switch (unwrapped) {
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

test "VM profiles repeated внешний calls and their prepared ABI cache" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    const input = "внешний \"libc\" функ abs(значение: Целое(32)) -> Целое(32)\nфунк старт() -> Целое\nпер сумма: Целое = 0\nпер i: Целое = 0\nпока i < 100 цикл\n    сумма = сумма + abs(i - 50)\n    i = i + 1\nконец\nсумма\nконец";
    var lexed = try lexer.tokenize(std.testing.allocator, input, 0);
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
    vm.foreign_profile_enabled = true;
    const outcome = try vm.run(@enumFromInt(0), &.{});
    switch (outcome) {
        .success => |runtime_value| try std.testing.expectEqual(@as(f64, 2500), runtime_value.number),
        .runtime_error => return error.TestUnexpectedResult,
    }

    try std.testing.expectEqual(@as(usize, 1), vm.foreign_profile.count());
    var profile = vm.foreign_profile.iterator();
    const entry = profile.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("abs", entry.key_ptr.*.name);
    try std.testing.expectEqual(@as(u64, 100), entry.value_ptr.calls);
    try std.testing.expectEqual(@as(u64, 1), entry.value_ptr.cache_misses);
    try std.testing.expect(entry.value_ptr.total_ns >= entry.value_ptr.native_call_ns);
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

test "VM dispatches generic interfaces through vtables" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    const source =
        \\тип Итератор[T] = интерфейс
        \\    функ следующий() -> Опция(T)
        \\конец
        \\тип Счётчик = структура
        \\    значение: Число
        \\конец
        \\реализация Итератор для Счётчик
        \\    функ следующий(это: Счётчик) -> Опция(Число)
        \\        Опция.Есть(это.значение)
        \\    конец
        \\конец
        \\функ старт() -> Число
        \\    пер итератор: Итератор(Число) = Счётчик(42.0)
        \\    итератор.следующий().получить(0.0)
        \\конец
    ;
    var lexed = try lexer.tokenize(std.testing.allocator, source, 0);
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
        .success => |runtime_value| switch (runtime_value) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM selects a generic interface vtable by type arguments" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    const source =
        \\тип Получатель[T] = интерфейс
        \\    функ получить() -> T
        \\конец
        \\тип Пара = структура
        \\    число: Число
        \\    текст: Строка
        \\конец
        \\реализация Получатель для Пара
        \\    функ получить(это: Пара) -> Число
        \\        это.число
        \\    конец
        \\конец
        \\реализация Получатель для Пара
        \\    функ получить(это: Пара) -> Строка
        \\        это.текст
        \\    конец
        \\конец
        \\функ старт() -> Строка
        \\    пер получатель: Получатель(Строка) = Пара(7.0, "верно")
        \\    получатель.получить()
        \\конец
    ;
    var lexed = try lexer.tokenize(std.testing.allocator, source, 0);
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
        .success => |runtime_value| try std.testing.expectEqualStrings("верно", runtime_value.stringBytes().?),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM substitutes top-level constants" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    const source =
        \\функ число() -> Число
        \\    если ФЛАГ тогда МИНУС иначе 0.0 конец
        \\конец
        \\функ текст() -> Строка
        \\    если ФЛАГ тогда СЛОВО иначе "ошибка" конец
        \\конец
        \\конст МИНУС = -5.0
        \\конст ФЛАГ = истина
        \\конст СЛОВО = "готово"
    ;
    var lexed = try lexer.tokenize(std.testing.allocator, source, 0);
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
    const number_outcome = try vm.run(@enumFromInt(0), &.{});
    switch (number_outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .number => |number| try std.testing.expectEqual(@as(f64, -5), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
    const string_outcome = try vm.run(@enumFromInt(1), &.{});
    switch (string_outcome) {
        .success => |runtime_value| try std.testing.expectEqualStrings("готово", runtime_value.stringBytes().?),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM iterates values through Итерируемое" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    const source =
        \\тип СчётчикДо = структура
        \\    текущее: Число
        \\    предел: Число
        \\конец
        \\реализация Итерируемое для СчётчикДо
        \\    функ следующий(это: СчётчикДо) -> Опция(Число)
        \\        если это.текущее >= это.предел тогда
        \\            Опция.Нет()
        \\        иначе
        \\            это.текущее = это.текущее + 1.0
        \\            Опция.Есть(это.текущее)
        \\        конец
        \\    конец
        \\конец
        \\функ старт() -> Число
        \\    пер счётчик = СчётчикДо(0.0, 5.0)
        \\    пер сумма = 0.0
        \\    для x в счётчик цикл
        \\        если x == 3.0 тогда
        \\            продолжить
        \\        конец
        \\        сумма = сумма + x
        \\    конец
        \\    сумма
        \\конец
    ;
    var lexed = try lexer.tokenize(std.testing.allocator, source, 0);
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
        .success => |runtime_value| switch (runtime_value) {
            .number => |number| try std.testing.expectEqual(@as(f64, 12), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM iterates interface-typed Итерируемое values" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    const source =
        \\тип СчётчикДо = структура
        \\    текущее: Число
        \\    предел: Число
        \\конец
        \\реализация Итерируемое для СчётчикДо
        \\    функ следующий(это: СчётчикДо) -> Опция(Число)
        \\        если это.текущее >= это.предел тогда
        \\            Опция.Нет()
        \\        иначе
        \\            это.текущее = это.текущее + 1.0
        \\            Опция.Есть(это.текущее)
        \\        конец
        \\    конец
        \\конец
        \\функ сумма(значения: Итерируемое(Число)) -> Число
        \\    пер результат = 0.0
        \\    для значение в значения цикл
        \\        результат = результат + значение
        \\    конец
        \\    результат
        \\конец
        \\функ старт() -> Число
        \\    сумма(СчётчикДо(0.0, 3.0))
        \\конец
    ;
    var lexed = try lexer.tokenize(std.testing.allocator, source, 0);
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
            .number => |number| try std.testing.expectEqual(@as(f64, 6), number),
            else => return error.TestUnexpectedResult,
        },
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
    var lexed = try lexer.tokenize(std.testing.allocator, "функ старт() -> Число\nпер нет: Опция(Число) = Опция.Нет()\nпер неудача: Результат(Число, Строка) = Результат.Неудача(\"нет\")\nесли нет.пусто() и не нет.есть() и нет.получить(4.0) == 4.0 и нет.запас(Опция.Есть(5.0)).получить(0.0) == 5.0 и неудача.ошибка() и не неудача.успех() и неудача.получить(6.0) == 6.0 и неудача.получить_ошибку(\"запас\") == \"нет\" и неудача.запас(Результат.Успех(7.0)).получить(0.0) == 7.0 тогда\n1.0\nиначе\n0.0\nконец\nконец", 0);
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
    var lexed = try lexer.tokenize(std.testing.allocator, "функ старт() -> Число\nпер опция: Опция(Число) = Опция.Есть(2.0)\nпер результат: Результат(Число, Строка) = Результат.Неудача(\"нет\")\nопция.значение() + опция.ожидать(\"не будет\") + если результат.причина() == \"нет\" и результат.ожидать_ошибку(\"не будет\") == \"нет\" тогда\n6.0\nиначе\n0.0\nконец\nконец", 0);
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
    var lexed = try lexer.tokenize(std.testing.allocator, "функ ошибка() -> Число\n1.0 / 0.0\nконец\nфунк старт() -> Число\nОпция.Есть(1.0).получить(ошибка())\nконец", 0);
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
    var lexed = try lexer.tokenize(std.testing.allocator, "функ старт() -> Булево\nпер есть: Опция(Число) = Опция.Есть(1.0)\nпер нет: Опция(Число) = Опция.Нет()\nпер успех: Результат(Число, Строка) = Результат.Успех(1.0)\nпер ошибка: Результат(Число, Строка) = Результат.Неудача(\"нет\")\nесть.заменить_значение(\"да\").получить(\"нет\") == \"да\" и нет.результат_или(\"пусто\").получить_ошибку(\"нет\") == \"пусто\" и успех.заменить_значение(\"готово\").получить(\"нет\") == \"готово\" и ошибка.заменить_ошибку(2.0).получить_ошибку(0.0) == 2.0 и ошибка.ошибка_опция().получить(\"запас\") == \"нет\" и успех.заменить_значение(\"да\").опция().получить(\"нет\") == \"да\"\nконец", 0);
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
    var lexed = try lexer.tokenize(std.testing.allocator, "функ поднять_опцию(значение: Опция(Число)) -> Опция(Число)\nпер число = значение?\nОпция.Есть(число + 1.0)\nконец\nфунк поднять_результат(значение: Результат(Число, Строка)) -> Результат(Число, Строка)\nпер число = значение?\nРезультат.Успех(число + 1.0)\nконец\nфунк старт() -> Число\nподнять_опцию(Опция.Нет()).получить(7.0) + поднять_опцию(Опция.Есть(2.0)).получить(0.0) + поднять_результат(Результат.Неудача(\"нет\")).получить(8.0) + поднять_результат(Результат.Успех(3.0)).получить(0.0)\nконец", 0);
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
            "1.0 -> \"один\"\n" ++
            "2.0 -> \"два\"\n" ++
            "_ -> \"другое\"\n" ++
            "конец\n" ++
            "конец\n" ++
            "функ код(x: Строка) -> Число\n" ++
            "выбор x\n" ++
            "\"да\" -> 1.0\n" ++
            "остальное -> 0.0\n" ++
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
            "Точка(0.0, y) -> y\n" ++
            "Точка(x, 0.0) -> x\n" ++
            "Точка(_, _) -> -1.0\n" ++
            "конец\n" ++
            "конец\n" ++
            "функ ось_именованно(точка: Точка) -> Число\n" ++
            "выбор точка\n" ++
            "Точка(y: 0.0) -> точка.x\n" ++
            "Точка(_, _) -> -1.0\n" ++
            "конец\n" ++
            "конец\n" ++
            "функ старт() -> Булево\n" ++
            "число(2.0) == \"два\" и код(\"нет\") == 0.0 и булево(ложь) == \"нет\" и ось(Точка(0.0, 7.0)) == 7.0 и ось_именованно(Точка(5.0, 0.0)) == 5.0\n" ++
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
    var lexed = try lexer.tokenize(std.testing.allocator, "функ старт() -> Число\nесли истина тогда\n42.0\nиначе\nпаника(\"не должно выполниться\")\nконец\nконец", 0);
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
        \\    отправить(p, 1.0)
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
    // Round-robin планировщик НЕ выполняет цель отправить() синхронно —
    // сосед() должен оставаться живым (зациклен вечно, а не завершаться),
    // чтобы связь с жертва оставалась валидной, когда жертва реально
    // попадёт в планировщик и упадёт. Идиома рандеву: сосед пингует
    // родитель обратно только ПОСЛЕ того, как выполнился связать(), так что
    // отправить(жертва, ...) ниже гарантированно происходит после того, как
    // связь уже установлена.
    const source =
        \\функ падающий() -> Пусто
        \\    получить()
        \\    паника("сбой")
        \\конец
        \\функ сосед(партнёр: Процесс(Число), родитель: Процесс(Число)) -> Пусто
        \\    связать(партнёр)
        \\    отправить(родитель, 1.0)
        \\    получить()
        \\    сосед(партнёр, родитель)
        \\конец
        \\функ проверка() -> Булево
        \\    пер жертва: Процесс(Число) = запусти падающий()
        \\    пер process: Процесс(Число) = запусти сосед(жертва, себя())
        \\    наблюдать(process)
        \\    получить()
        \\    отправить(жертва, 1.0)
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
        \\    отправить(child, 1.0)
        \\конец
        \\функ проверка() -> Булево
        \\    пер process: Процесс(Число) = запусти связанный()
        \\    наблюдать(process)
        \\    отправить(process, 1.0)
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
        \\    пер максимум_точек = макс(Точка(1.0), Точка(2.0))
        \\    максимум_чисел == 7 и максимум_точек.x == 2.0
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
    var lexed = try lexer.tokenize(std.testing.allocator, "функ вычесть(уменьшаемое: Число, вычитаемое: Число) -> Число\nуменьшаемое - вычитаемое\nконец\nфунк старт() -> Число\nвычесть(вычитаемое = 3.0, уменьшаемое = 10.0)\nконец", 0);
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
        \\    пер child: Процесс(Число) = запусти вычислить(вычитаемое = 3.0, ответ = ответ, уменьшаемое = 10.0)
        \\    отправить(child, 0.0)
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

// Именованные аргументы конструктора структуры должны собираться в
// ПОРЯДКЕ ОБЪЯВЛЕНИЯ ПОЛЕЙ, а не в порядке, в котором их написал вызывающий
// — `Точка(y = 1, x = 2)` (поля объявлены `x`, затем `y`) должно построить
// `x=2, y=1`, а не `x=1, y=2`.
test "VM reorders named struct constructor arguments" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    const source =
        \\тип Точка = структура
        \\    x: Число
        \\    y: Число
        \\конец
        \\функ старт() -> Число
        \\    пер п = Точка(y = 1.0, x = 2.0)
        \\    п.x * 10.0 + п.y
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
    const outcome = try vm.run(@enumFromInt(0), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .number => |number| try std.testing.expectEqual(@as(f64, 21), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

// `выбор`/`если`, чьи ветви — одно значение с типом интерфейса и один
// конкретный реализующий тип (оба по отдельности присваиваемы к ИЗВЕСТНОМУ
// `expected` типу, например объявленному возвращаемому типу функции),
// должны приниматься — `assignable` для интерфейсов направленное, поэтому
// взаимная попарная проверка между ветвями отклонила бы это, даже если
// каждая ветвь по отдельности удовлетворяет `expected`.
test "VM allows if/match branches that satisfy expected type asymmetrically via an interface" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    const source =
        \\тип Точка = структура
        \\    x: Число
        \\конец
        \\реализация Печатаемое для Точка
        \\    функ вСтроку(это: Точка) -> Строка
        \\        "точка"
        \\    конец
        \\конец
        \\функ выбрать(есть_значение: Опция(Точка)) -> Печатаемое
        \\    выбор есть_значение
        \\        Опция.Есть(п) -> п
        \\        Опция.Нет -> Точка(0.0)
        \\    конец
        \\конец
        \\функ старт() -> Строка
        \\    выбрать(Опция.Есть(Точка(1.0))).вСтроку()
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
        .success => |runtime_value| try std.testing.expectEqualStrings("точка", runtime_value.stringBytes() orelse return error.TestUnexpectedResult),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

// Обобщённая функция, чей параметр ограничен ПОЛЬЗОВАТЕЛЬСКИМ интерфейсом
// (`[T: ИзTOML]`), вызывающая метод на этом голом параметре внутри своего
// тела (`это.метод()`) — обобщения панос не мономорфизируются, поэтому это
// работает только если конкретный аргумент вызывающего приводится к
// связанному интерфейсу в точке вызова, а вызов метода внутри тела
// обобщённой функции диспетчеризуется через vtable того же интерфейса.
test "VM dispatches an interface method through a generic bound parameter" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    const source =
        \\тип Точка = структура
        \\    x: Число
        \\конец
        \\реализация Печатаемое для Точка
        \\    функ вСтроку(это: Точка) -> Строка
        \\        "точка"
        \\    конец
        \\конец
        \\функ показать[T: Печатаемое](значение: T) -> Строка
        \\    значение.вСтроку()
        \\конец
        \\функ старт() -> Строка
        \\    показать(Точка(1.0))
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
        .success => |runtime_value| try std.testing.expectEqualStrings("точка", runtime_value.stringBytes() orelse return error.TestUnexpectedResult),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "VM dispatches a second interface method through multiple generic bounds" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    const source =
        \\тип Точка = структура
        \\    x: Число
        \\конец
        \\тип Сдвигаемое = интерфейс
        \\    функ сдвиг() -> Число
        \\конец
        \\реализация Печатаемое для Точка
        \\    функ вСтроку(это: Точка) -> Строка
        \\        "точка"
        \\    конец
        \\конец
        \\реализация Сдвигаемое для Точка
        \\    функ сдвиг(это: Точка) -> Число
        \\        это.x + 1.0
        \\    конец
        \\конец
        \\функ сдвинуть[T: Печатаемое + Сдвигаемое](значение: T) -> Число
        \\    значение.сдвиг()
        \\конец
        \\функ старт() -> Число
        \\    сдвинуть(Точка(41.0))
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
    const outcome = try vm.run(@enumFromInt(3), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

// Тип-параметр обобщённой структуры должен выводиться даже из ПУСТОГО
// аргумента-конструктора array-литерала (`массив()` выводится как
// `Массив(poison)`, а объявленный тип возврата функции — `Коробка(T)`,
// СОБСТВЕННЫЙ `T` функции — должен унифицироваться с построенным
// `Коробка(poison)`, допуская `poison` при присваиваемости номинальных
// типов). Проверяет только ОБЪЯВЛЕНИЕ, намеренно не точку вызова: вызов
// обобщённой функции, чей тип-параметр встречается ТОЛЬКО в типе возврата
// (никогда ни в одном параметре), не может быть разрешён из типов
// аргументов в принципе — это отдельное, ортогональное ограничение.
test "type checker infers a generic struct's type parameter through an empty array literal argument" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    const source =
        \\тип Коробка[T] = структура
        \\    метка: Строка
        \\    элементы: Массив(T)
        \\конец
        \\функ новая_коробка[T](метка: Строка) -> Коробка(T)
        \\    Коробка(метка, массив())
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
}

// `новая_коробка[T](метка: Строка) -> Коробка(T)` имеет `T` ТОЛЬКО в типе
// возврата — с явной аннотацией `: Коробка(Число)` в точке вызова `T`
// должен по-настоящему разрешиться в `Число` (засеяно из ожидаемого типа),
// а не тихо откатиться на `poison`.
test "VM resolves a generic call's return-only type parameter from an annotated let" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    const source =
        \\тип Коробка[T] = структура
        \\    метка: Строка
        \\    элементы: Массив(T)
        \\конец
        \\функ новая_коробка[T](метка: Строка) -> Коробка(T)
        \\    Коробка(метка, массив())
        \\конец
        \\функ старт() -> Число
        \\    пер к: Коробка(Число) = новая_коробка("х")
        \\    к.элементы.добавить(42.0)
        \\    к.элементы.получить(0, 0.0)
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
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

// АННОТИРОВАННЫЙ вызов, чей тип-параметр обобщения ВСЁ РАВНО не может быть
// разрешён (ожидаемый тип дан, но структурно несовместим с собственным
// типом возврата функции), должен быть жёсткой ошибкой типа — не тихо
// испорченным (poison) успехом.
test "type checker reports an error when an annotated generic call's type parameter is genuinely unresolvable" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    const source =
        \\тип Коробка[T] = структура
        \\    элементы: Массив(T)
        \\конец
        \\функ пустая_коробка[T]() -> Коробка(T)
        \\    Коробка(массив())
        \\конец
        \\функ старт() -> Пусто
        \\    пер к: Строка = пустая_коробка()
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
    // `Строка` (аннотация) структурно несовместима с `Коробка(T)`
    // (реальная форма возврата функции) — `T` из неё никогда не может быть
    // засеян, а аргумента для отката тоже нет.
    var found = false;
    for (checked.diagnostics.items.items) |diagnostic_value| {
        if (std.mem.indexOf(u8, diagnostic_value.message, "не удалось вывести type-параметр") != null) found = true;
    }
    try std.testing.expect(found);
}

test "VM partially destructures a named structure field" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип Точка = структура\nx: Число\ny: Число\nконец\nфунк получить_y() -> Число\nпер точка = Точка(1.0, 2.0)\nпер Точка(y: y) = точка\ny\nконец", 0);
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
    var lexed = try lexer.tokenize(std.testing.allocator, "функ номер_себя() -> Целое\nсебя().номер()\nконец", 0);
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

test "VM guards a native builtin when bytecode bypasses static checking" {
    var program = bytecode.Program.init(std.testing.allocator);
    defer program.deinit();
    const function_id = try program.addFunction("старт", 0);
    const function = program.function(function_id).?;
    const path = try function.addConstant(std.testing.allocator, .{ .string = try program.copyString("build.zig") });
    try function.emit(std.testing.allocator, .{ .constant = path });
    try function.emit(std.testing.allocator, .{ .file_exists = {} });
    try function.emit(std.testing.allocator, .{ .return_value = {} });

    var machine = Vm.initForTarget(std.testing.allocator, &program, .browser_interpreter);
    defer machine.deinit();
    switch (try machine.run(function_id, &.{})) {
        .success => return error.TestUnexpectedResult,
        .runtime_error => |message| try std.testing.expectEqualStrings("Runtime Panic: 'фс::есть' недоступно в этом runtime-таргете", message),
    }
}

// CPU-bound процесс, никогда не вызывающий получить()/получить_сигнал()/
// асинхронный билтин, не должен морить голодом соседний процесс вечно.
// `бесконечный` ниже — по-настоящему незавершающийся цикл; процесс
// уступает планировщику каждые `process_instruction_budget` инструкций, так
// что соседний `ответчик` всё равно попадает в планировщик, отправляет свой
// ответ, и `проверка` (корень) его получает — хотя сам `бесконечный`
// никогда не завершается и просто забрасывается, когда корень возвращается.
test "VM scheduler does not let a CPU-bound process starve a sibling forever" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    const source =
        \\функ бесконечный() -> Пусто
        \\    пока истина цикл
        \\    конец
        \\конец
        \\функ ответчик(родитель: Процесс(Число)) -> Пусто
        \\    отправить(родитель, 42.0)
        \\конец
        \\функ проверка() -> Число
        \\    запусти бесконечный()
        \\    запусти ответчик(себя())
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
    const outcome = try vm.run(@enumFromInt(2), &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

// `отправить` обеспечивает гарантию изоляции copy-on-send. Отправитель
// мутирует свой собственный массив ПОСЛЕ порождения дочернего процесса и
// отправки ему структуры, оборачивающей этот массив — дочерний процесс
// должен видеть массив таким, каким он был В МОМЕНТ ОТПРАВКИ, не отражая
// последующую мутацию отправителя, что доказывает, что сообщение НЕ было
// разделено по ссылке.
test "VM deep-copies a message on send, isolating it from the sender's later mutations" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    const source =
        \\тип Ящик = структура
        \\    значения: Массив(Число)
        \\конец
        \\функ приёмник(родитель: Процесс(Число), ящик: Ящик) -> Пусто
        \\    отправить(родитель, ящик.значения.получить(0, -1.0))
        \\конец
        \\экспорт функ старт() -> Число
        \\    пер ящик = Ящик(массив())
        \\    ящик.значения.добавить(1.0)
        \\    запусти приёмник(себя(), ящик)
        \\    ящик.значения.добавить(2.0)
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
            .number => |number| try std.testing.expectEqual(@as(f64, 1), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

// Переопределение `реализация Копируемое` вызывается напрямую в момент
// отправки вместо обычного рефлективного обхода — проверяет, что реально
// выполнился кастомный клон (который намеренно заменяет поле метки), а не
// структурный обход по умолчанию (который сохранил бы исходную метку без
// изменений).
test "VM dispatches a custom Копируемое override on send instead of reflective copy" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    const source =
        \\тип Ящик = структура
        \\    метка: Строка
        \\    значения: Массив(Число)
        \\конец
        \\реализация Копируемое для Ящик
        \\    функ клонировать(это: Ящик) -> Ящик
        \\        Ящик("клон", это.значения)
        \\    конец
        \\конец
        \\функ читатель(родитель: Процесс(Строка)) -> Пусто
        \\    пер коробка: Ящик = получить()
        \\    отправить(родитель, коробка.метка)
        \\конец
        \\экспорт функ старт() -> Строка
        \\    пер приёмный_процесс: Процесс(Ящик) = запусти читатель(себя())
        \\    пер ящик = Ящик("оригинал", массив())
        \\    отправить(приёмный_процесс, ящик)
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
    const outcome = try vm.run(@enumFromInt(2), &.{});
    switch (outcome) {
        .success => |runtime_value| try std.testing.expectEqualStrings("клон", runtime_value.stringBytes() orelse return error.TestUnexpectedResult),
        .runtime_error => return error.TestUnexpectedResult,
    }
}

// `запусти <вызов>` порождает `Процесс(T)`, где T корректно выводится из
// собственного типа возврата порождаемой функции. `ждать` блокируется на
// том же хендле `Процесс(T)`, пока он не завершится и не вернёт
// `Результат.Успех(T)`.
test "VM spawns a process and ждать returns its successful result" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    const source =
        \\функ вычислить(x: Число) -> Число
        \\    x * 2.0
        \\конец
        \\экспорт функ старт() -> Число
        \\    пер p: Процесс(Число) = запусти вычислить(21.0)
        \\    выбор ждать(p)
        \\        Результат.Успех(значение) -> значение
        \\        Результат.Неудача(_) -> -1.0
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
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

// Порождённый процесс, который ПАДАЕТ (паникует), не должен обрушивать всю
// VM — `ждать` на нём возвращает `Результат.Неудача(Ошибка(...))`, точно
// как любая другая фейлящаяся нативная операция, а не распространённый
// runtime-сбой.
test "VM converts a crashed process into a failed Результат, not a VM-wide crash" {
    const compiler = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    const source =
        \\функ падает() -> Число
        \\    паника("сбой")
        \\конец
        \\экспорт функ старт() -> Булево
        \\    пер p: Процесс(Число) = запусти падает()
        \\    выбор ждать(p)
        \\        Результат.Успех(_) -> ложь
        \\        Результат.Неудача(_) -> истина
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
            .boolean => |flag| try std.testing.expect(flag),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

fn findStartFunction(resolved: anytype, compiled: anytype) ?bytecode.FunctionId {
    var it = compiled.function_ids.iterator();
    while (it.next()) |entry| {
        const symbol_entry = resolved.symbols.get(entry.key_ptr.*) orelse continue;
        if (std.mem.eql(u8, symbol_entry.name, "старт")) return entry.value_ptr.*;
    }
    return null;
}

// Методы по умолчанию на интерфейсах (`функ метод(это: Интерфейс(...),
// ...) -> Тип ... конец` внутри `тип X = интерфейс ... конец`) — метод, не
// переопределённый реализующим типом, откатывается на это тело, которое
// само может вызывать ДРУГИЕ методы интерфейса на `это` (диспетчеризуется
// динамически, точно как обычный вызов через тип интерфейса), и может быть
// вызвано напрямую на конкретном значении без явной аннотации интерфейса
// где бы то ни было (`Диапазон(...).сумма()` — в этом весь смысл фичи,
// цепочка вызовов начиная с обычного конкретного значения).
test "VM dispatches an interface default method not overridden by the implementor" {
    const compiler_mod = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver_mod = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    const source =
        \\тип Счётный[T] = интерфейс
        \\    функ следующий() -> Опция(T)
        \\    функ сумма(это: Счётный(T)) -> Число
        \\        пер итог = 0.0
        \\        пер продолжать = истина
        \\        пока продолжать цикл
        \\            выбор это.следующий()
        \\                Есть(x) тогда
        \\                    итог = итог + 1.0
        \\                конец
        \\                Нет тогда
        \\                    продолжать = ложь
        \\                конец
        \\            конец
        \\        конец
        \\        итог
        \\    конец
        \\конец
        \\тип Диапазон = структура
        \\    текущее: Число
        \\    предел: Число
        \\конец
        \\реализация Счётный для Диапазон
        \\    функ следующий(это: Диапазон) -> Опция(Число)
        \\        если это.текущее >= это.предел тогда
        \\            Опция.Нет()
        \\        иначе
        \\            это.текущее = это.текущее + 1.0
        \\            Опция.Есть(это.текущее)
        \\        конец
        \\    конец
        \\конец
        \\экспорт функ старт() -> Число
        \\    Диапазон(0.0, 5.0).сумма()
        \\конец
    ;
    var lexed = try lexer.tokenize(std.testing.allocator, source, 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver_mod.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    var compiled = try compiler_mod.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const start = findStartFunction(&resolved, &compiled) orelse return error.TestUnexpectedResult;
    const outcome = try vm.run(start, &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .number => |number| try std.testing.expectEqual(@as(f64, 5), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

// Реализующий тип, который ДЕЙСТВИТЕЛЬНО переопределяет метод по
// умолчанию, использует своё переопределение — откат в
// `defineInterfaceImplementation` срабатывает только при `matched == null`.
test "VM prefers an implementor's own override over an interface default method" {
    const compiler_mod = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver_mod = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    const source =
        \\тип Счётный[T] = интерфейс
        \\    функ следующий() -> Опция(T)
        \\    функ сумма(это: Счётный(T)) -> Число
        \\        99.0
        \\    конец
        \\конец
        \\тип Диапазон = структура
        \\    текущее: Число
        \\    предел: Число
        \\конец
        \\реализация Счётный для Диапазон
        \\    функ следующий(это: Диапазон) -> Опция(Число)
        \\        Опция.Нет()
        \\    конец
        \\    функ сумма(это: Диапазон) -> Число
        \\        7.0
        \\    конец
        \\конец
        \\экспорт функ старт() -> Число
        \\    Диапазон(0.0, 5.0).сумма()
        \\конец
    ;
    var lexed = try lexer.tokenize(std.testing.allocator, source, 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver_mod.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    var compiled = try compiler_mod.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const start = findStartFunction(&resolved, &compiled) orelse return error.TestUnexpectedResult;
    const outcome = try vm.run(start, &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .number => |number| try std.testing.expectEqual(@as(f64, 7), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

// ОБОБЩЁННАЯ структура, реализующая ОБОБЩЁННЫЙ интерфейс, диспетчеризуемая
// полиморфно при произвольной инстанциации — метод по умолчанию в стиле
// ленивого итератора (`отобразить[U]`), который строит и возвращает
// структуру-обёртку, приведённую к интерфейсу, опирается на три разных
// механизма: подстановочный откат `findInterfaceImplementation` (точное
// сравнение `eql` никогда не совпадает с СОБСТВЕННЫМИ плейсхолдерами
// обобщённой цели против конкретной инстанциации в точке вызова);
// вывод обобщённых типов на уровне метода в `inferInterfaceCall` (`U`,
// отдельный от собственного `T` интерфейса); и подстановка
// `implementation.arguments` через КОНКРЕТНУЮ цель в
// `inferDefaultInterfaceMethodCall` перед построением типа интерфейса.
// Также проверяет случай `.function` в `inferGenericSubstitution` (`U`
// встречается ТОЛЬКО в позиции возврата параметра-колбэка, больше нигде).
test "VM dispatches a default method calling a generic struct that implements a generic interface" {
    const compiler_mod = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver_mod = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    const source =
        \\тип Ит[T] = интерфейс
        \\    функ следующий() -> Опция(T)
        \\    функ собрать(это: Ит(T)) -> Массив(T)
        \\        пер результат: Массив(T) = массив()
        \\        пер продолжать = истина
        \\        пока продолжать цикл
        \\            выбор это.следующий()
        \\                Есть(x) тогда
        \\                    результат.добавить(x)
        \\                конец
        \\                Нет тогда
        \\                    продолжать = ложь
        \\                конец
        \\            конец
        \\        конец
        \\        результат
        \\    конец
        \\    функ отобразить[U](это: Ит(T), ф: функ(T) -> U) -> Ит(U)
        \\        Отображённый(это, ф)
        \\    конец
        \\конец
        \\тип Отображённый[T, U] = структура
        \\    источник: Ит(T)
        \\    ф: функ(T) -> U
        \\конец
        \\реализация Ит для Отображённый
        \\    функ следующий(это: Отображённый) -> Опция(U)
        \\        выбор это.источник.следующий()
        \\            Есть(x) -> Опция.Есть(это.ф(x))
        \\            Нет -> Опция.Нет()
        \\        конец
        \\    конец
        \\конец
        \\тип МассивИт[T] = структура
        \\    массив: Массив(T)
        \\    индекс: Целое
        \\конец
        \\реализация Ит для МассивИт
        \\    функ следующий(это: МассивИт) -> Опция(T)
        \\        если это.индекс >= это.массив.длина() тогда
        \\            Опция.Нет()
        \\        иначе
        \\            пер знач = это.массив[это.индекс]
        \\            это.индекс = это.индекс + 1
        \\            Опция.Есть(знач)
        \\        конец
        \\    конец
        \\конец
        \\экспорт функ старт() -> Массив(Число)
        \\    пер источник = МассивИт(массив(1.0, 2.0, 3.0), 0)
        \\    источник.отобразить(функ(x: Число) -> Число
        \\        x * 2.0
        \\    конец).собрать()
        \\конец
    ;
    var lexed = try lexer.tokenize(std.testing.allocator, source, 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver_mod.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    var compiled = try compiler_mod.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const start = findStartFunction(&resolved, &compiled) orelse return error.TestUnexpectedResult;
    const outcome = try vm.run(start, &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .array => |array| {
                try std.testing.expectEqual(@as(usize, 3), array.elements.len);
                try std.testing.expectEqual(@as(f64, 2), array.elements[0].number);
                try std.testing.expectEqual(@as(f64, 4), array.elements[1].number);
                try std.testing.expectEqual(@as(f64, 6), array.elements[2].number);
            },
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

// `для x в ... цикл` над значением, реализующим `Итерируемое`, должен
// продолжать работать, даже когда у интерфейса больше одного метода
// (`отобразить`/`отфильтровать`/`взять`/`собрать`, все — методы по
// умолчанию) — `iterableForIn`/`interfaceIterableElement` и
// скомпилированный `call_interface` для пути `.interface`-диспетчеризации
// ищут `следующий` по имени/индексу, а не предполагают, что у интерфейса
// ровно один метод с индексом 0.
test "VM for-in still dispatches следующий() after Итерируемое gained default methods" {
    const compiler_mod = @import("compiler.zig");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const resolver_mod = @import("resolver.zig");
    const type_checker = @import("type_checker.zig");
    const source =
        \\тип СчётчикДо = структура
        \\    текущее: Число
        \\    предел: Число
        \\конец
        \\реализация Итерируемое для СчётчикДо
        \\    функ следующий(это: СчётчикДо) -> Опция(Число)
        \\        если это.текущее >= это.предел тогда
        \\            Опция.Нет()
        \\        иначе
        \\            это.текущее = это.текущее + 1.0
        \\            Опция.Есть(это.текущее)
        \\        конец
        \\    конец
        \\конец
        \\экспорт функ старт() -> Число
        \\    пер сч = СчётчикДо(0.0, 5.0)
        \\    пер сумма = 0.0
        \\    для x в сч цикл
        \\        сумма = сумма + x
        \\    конец
        \\    сумма
        \\конец
    ;
    var lexed = try lexer.tokenize(std.testing.allocator, source, 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver_mod.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker.check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    var compiled = try compiler_mod.compile(std.testing.allocator, &parsed.ast, &resolved, &checked);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);

    var vm = Vm.init(std.testing.allocator, &compiled.program);
    defer vm.deinit();
    const start = findStartFunction(&resolved, &compiled) orelse return error.TestUnexpectedResult;
    const outcome = try vm.run(start, &.{});
    switch (outcome) {
        .success => |runtime_value| switch (runtime_value) {
            .number => |number| try std.testing.expectEqual(@as(f64, 15), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}
