const std = @import("std");
const builtin = @import("builtin");
const bytecode = @import("bytecode.zig");
const gc = @import("gc.zig");
const target_policy = @import("target.zig");
const value = @import("value.zig");
// Renamed (not `ast`/`lexer`/`parser`) — many existing tests below already
// locally shadow those three names with their own `@import(...)` (written
// before any module-scope import of them existed here); a plain top-level
// import under the obvious name would conflict with every one of them.
const ast_types = @import("ast.zig");
const syntax_lexer = @import("lexer.zig");
const syntax_parser = @import("parser.zig");
const sqlite3 = @import("sqlite3_bindings.zig");
const ffi = @import("ffi_bindings.zig");

pub const Execution = union(enum) {
    success: value.Value,
    runtime_error: []const u8,
};

// Persistent per-process continuation state now lives on value.Process
// itself (see value.zig) so a process can be suspended mid-frame and
// resumed later by the round-robin scheduler — kept as a local alias since
// most of this file already refers to it as plain `Frame`.
const Frame = value.Frame;

// Outcome of a single step() dispatch. `.suspended` means the current
// instruction could not complete yet (empty mailbox/signals/async_results)
// and must be re-dispatched from the SAME frame.ip on the next scheduling
// slice — the handful of suspend-capable instructions (получить,
// получить_сигнал, Await_Async) roll frame.ip back by one before returning
// this, since step() unconditionally advances ip before dispatch.
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

// Zig 0.16 routes clocks through std.Io, but keeping an Io.Threaded object
// in every VM would install process-wide signal handlers just for an
// optional profiler. Use direct monotonic platform clocks instead.
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
    file_write: struct { bytes_written: usize, err_message: ?[]u8 },
    net_connect: struct { stream: ?std.Io.net.Stream, err_message: ?[]u8 },
    http_request: struct { result: ?HttpRequestResult, err_message: ?[]u8 },
    // `connection` — gc_pinned for the whole flight (see submitConnectionRead)
    // so it's safe to identify by raw pointer here; the worker never
    // dereferences its GC header, only the copied `stream` value it was
    // handed.
    connection_read: struct { connection: *value.Connection, content: ?[]u8, err_message: ?[]u8 },
    connection_write: struct { connection: *value.Connection, bytes_written: usize, err_message: ?[]u8 },
    // `new_pending` is ALWAYS set (even on error) — whatever the worker had
    // accumulated but not yet consumed into a line must be written back to
    // `connection.pending` at delivery, so a retried `.получить_строку()`
    // after a transient error doesn't lose already-buffered bytes.
    connection_read_line: struct { connection: *value.Connection, line: ?[]u8, new_pending: []const u8, err_message: ?[]u8 },
    file_handle_read: struct { handle: *value.FileHandle, content: ?[]u8, new_offset: usize, err_message: ?[]u8 },
    file_handle_write: struct { handle: *value.FileHandle, bytes_written: usize, new_offset: usize, err_message: ?[]u8 },
    sql_open: struct { db: ?*sqlite3.sqlite3, err_message: ?[]u8 },
    sql_exec: struct { connection: *value.SqlConnection, rows_affected: i64, err_message: ?[]u8 },
    // `column_names`/`rows` — positional, not per-row named (same layout as
    // Odin's `Sql_Query_Result_Data`). Each row is `?[]u8` per column: null
    // = SQL NULL (omitted from the delivered `Соответствие` entirely, same
    // convention as the old synchronous `sqlReadRow`).
    sql_query: struct { connection: *value.SqlConnection, column_names: [][]u8, rows: [][]?[]u8, err_message: ?[]u8 },
    // `listener` — pinned ONCE per in-flight accept (see submitHttpAccept);
    // `Heap.pin`/`unpin` already support multiple concurrent pins of the
    // same value, unlike Connection/FileHandle/SqlConnection's single
    // `in_flight` flag.
    http_accept: struct { listener: *value.Listener, stream: ?std.Io.net.Stream, method: ?[]u8, path: ?[]u8, body: ?[]u8, headers: []HttpHeaderPair, err_message: ?[]u8 },
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
    }
}

// Живёт ЦЕЛИКОМ на std.heap.page_allocator — не на Vm.allocator, который
// может (и в панос-CLI является) не потокобезопасным bump/arena-
// аллокатором. Та же причина, что у Odin's vm_heap_allocator()
// (core/gc.odin) — воркер-потоки и главный поток никогда не должны делить
// один неатомарный аллокатор. outstanding — число задач, отправленных в
// пул, но ещё не доложивших результат push()'ом (аналог Odin's
// thread.pool_num_outstanding), нужен для различения "никто не готов, но
// I/O в полёте" (настоящий idle-wait) от "дедлок" в run_scheduler.
// Zig 0.16 moved Mutex/Condition off `std.Thread` onto `std.Io` (`lock`/
// `wait` now take an `Io` handle, routed through `io.futexWait`/
// `futexWake`) — there is no longer a raw OS mutex usable without one.
// Each method below builds a throwaway `std.Io.Threaded` purely to obtain
// that handle; the futex itself is keyed by the shared atomic's ADDRESS,
// not by which `Threaded` instance issued the call, so a fresh one per
// call from either the main thread or a worker thread still correctly
// synchronizes through the same underlying `Mutex`/`Condition` state. Same
// throwaway-Io-per-call pattern already used everywhere else in this file
// for real I/O. `lock`/`wait` return `Cancelable!void` but a throwaway,
// never-cancelled `Threaded` can never actually report cancellation.
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

    // These four are called UNCONDITIONALLY from run()/run_scheduler for
    // every target (there is no per-call-site freestanding guard, unlike
    // beginSubmit/push — those are only ever reached through
    // submitFileRead/submitFileWrite, themselves behind fileReadSubmit's/
    // fileWriteSubmit's own freestanding `if`/`else`). A real `if`/`else`
    // here is therefore required so the wasm32-freestanding `browser`
    // build never has to resolve `std.Io.Threaded` (its `RandomFile` pulls
    // in `posix.system.getrandom`, missing on freestanding) — outstanding/
    // items are always 0 there anyway, since no async job is ever
    // submitted on that target.
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

// `owned_headers` — already cloned onto page_allocator by the caller
// (httpRequestSubmit, on the main thread) — this function takes ownership
// of it (frees it itself, worker-side) along with the method/url/body
// clones it makes here.
fn submitHttpRequest(vm: *Vm, method_text: []const u8, url: []const u8, body: []const u8, owned_headers: []HttpHeaderPair, target_id: u64) void {
    vm.async_queue.beginSubmit();
    const Job = struct {
        queue: *AsyncQueue,
        target_id: u64,
        method_text: []u8,
        url: []u8,
        body: []u8,
        headers: []HttpHeaderPair,

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
            var request = client.request(method, uri, .{ .extra_headers = extra_headers.items }) catch |err| {
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
    };
    const thread = std.Thread.spawn(.{}, Job.run, .{job}) catch @panic("не удалось запустить фоновый поток сеть.http_запрос");
    thread.detach();
}

// `connection` is gc_pinned by the CALLER (connectionReadSubmit) for the
// whole flight — the worker only ever touches the copied `stream` VALUE
// (a plain fd wrapper, safe to use from another thread while the fd stays
// open), never `connection`'s GC header or any other field; `connection`
// itself is carried only as an opaque identifier for delivery.
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

// Same gc_pin/opaque-identifier discipline as submitConnectionRead above.
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

// `drained_pending` — whatever `.pending` already held before this call,
// handed over as the worker's starting accumulation buffer (same drain-
// then-transfer discipline as submitConnectionRead).
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

// `Файл.прочитать()`/`Файл.прочитать_строку()` share this — `want_line`
// picks which slicing rule applies to the same reopen-by-path whole-file
// read (see `value.zig`'s `FileHandle` doc comment for why there's no
// persistent OS handle to seek through instead).
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
                // See the old synchronous sqlOpen — sqlite3_open_v2 can
                // allocate a barely-usable `db` even on failure, purely so
                // sqlite3_errmsg has something to report; must still close it.
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

// Worker-side equivalent of `Vm.sqlPrepare` — no `Vm` access, everything on
// `page_allocator`. `params` is already validated (all-Строка) and cloned
// to plain `[]const u8` by the caller (submitSqlExec/submitSqlQuery, on the
// main thread) before the worker ever starts.
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

// `listener.server` is copied by VALUE into the job — `Server.accept` only
// reads its fields (socket handle + options) to issue the syscall, never
// mutates them, so independent copies calling `.accept()` concurrently
// (from however many `.принять_запрос()` calls are in flight at once) are
// safe — the same shared listening socket, safe to accept() from multiple
// threads simultaneously (ordinary POSIX behavior).
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
            var body_buffer: [8192]u8 = undefined;
            const body_reader = request.readerExpectNone(&body_buffer);
            const body = body_reader.allocRemaining(std.heap.page_allocator, .limited(1024 * 1024)) catch |err| {
                stream.close(io.io());
                return job.fail(std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{@errorName(err)}) catch @panic("OOM"));
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

// `std.c` only binds `getenv` — no `setenv`/`unsetenv` — so those two are
// declared directly, same shape as libc's own prototypes. Only referenced
// from `Vm.osEnvSet`/`osEnvUnset`'s non-freestanding `if`/`else` branch —
// see the comment on `osEnvGet` for why that branch shape matters here.
const posix_env = struct {
    extern "c" fn setenv(name: [*:0]const u8, value_ptr: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

// MSVC's ucrt has no `setenv`/`unsetenv` symbols at all (it's `_putenv_s`
// instead) — `posix_env`'s `extern "c"` declarations above would fail at
// LINK time on Windows, not compile time, so this was never caught by a
// plain compile-error scan. `SetEnvironmentVariableW` mutates the CURRENT
// process's env block directly (no `std` binding for it in this Zig
// version — same gap `resolver.zig`'s `WindowsDynLib` already worked
// around for `LoadLibraryW`/`GetProcAddress`) — a spawned child inherits
// that block automatically unless a caller overrides it, which is exactly
// what `osExec`'s environ-hack needs on Windows too (see there).
const windows_env = struct {
    extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) c_int;
    extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buffer: ?[*]u16, size: u32) callconv(.winapi) u32;
    extern "kernel32" fn GetEnvironmentStringsW() callconv(.winapi) ?[*:0]const u16;
    extern "kernel32" fn FreeEnvironmentStringsW(penv: [*:0]const u16) callconv(.winapi) c_int;

    // `std.c.getenv` reads ucrt's OWN cached copy of the environment
    // block (populated at process startup, only kept in sync by
    // `_putenv`/`_wputenv`) — `SetEnvironmentVariableW` mutates the raw
    // Win32 process environment block directly and does NOT update that
    // ucrt cache, so a `ос.установить_окружение(...)` followed by
    // `ос.окружение(...)` would silently see the OLD value through
    // `std.c.getenv`. `GetEnvironmentVariableW` reads the live Win32
    // block instead, matching what `SetEnvironmentVariableW` just wrote.
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

    // `std.process.Environ.Block` resolves to `GlobalBlock` on Windows
    // (only `.empty`/`.global`, see `Environ.zig`) — no way to hand it a
    // custom block through the normal `createMap` entry point at all on
    // this platform. Bypasses that by reading the live process
    // environment block directly (same live-block idea as the POSIX
    // `std.c.environ` read in `osExec` below) and feeding it through
    // `Environ.Map.putWindowsBlock`, which only needs a raw UTF-16
    // double-null-terminated pointer — no `Block`/`createMap` involved.
    fn buildEnvironMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
        var map = std.process.Environ.Map.init(allocator);
        errdefer map.deinit();
        const raw = GetEnvironmentStringsW() orelse return map;
        defer _ = FreeEnvironmentStringsW(raw);
        try map.putWindowsBlock(.{ .ptr = raw });
        return map;
    }
};

// `ввод_вывод.печать`/`.строка`'s value-to-text conversion, also reused by
// `runner.renderValue` for the CLI's final return-value line (same
// contract, one implementation) — a structural dump (`Имя(поле1, поле2,
// ...)`, positional, no field names — matches the display-string
// convention already documented for compound values without a real
// `Печатаемое` implementation). Dispatching to a value's OWN `.вСтроку()`
// when it implements `Печатаемое` (the docs' PREFERRED path) is NOT done
// here — that needs static-type-aware interface casting at each call
// site (the same mechanism `Складываемое`-sugar uses for `+`), which
// `ввод_вывод.печать(значение: любой тип)` can't get for free since its
// parameter isn't a real generic; deliberately left for a follow-up
// rather than silently only half-supporting it.
pub fn renderRuntimeValue(allocator: std.mem.Allocator, runtime_value: value.Value) anyerror![]u8 {
    return switch (runtime_value) {
        .void => allocator.dupe(u8, ""),
        .number => |number| std.fmt.allocPrint(allocator, "{d}", .{number}),
        // Kept as Zig's default `true`/`false` (NOT `истина`/`ложь`) —
        // matches the CLI's existing final-return-value rendering, which
        // 19+ existing tests already assert on; changing it is a separate
        // decision, not a side effect of adding `ввод_вывод`.
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
    // Everything on the command line after the script path — `ос.
    // аргументы()`, symmetric to Odin's `vm.program_args` (`core/vm.odin`,
    // set from `main.odin`'s `run_file`). Empty for every entry point that
    // isn't the native CLI (LSP, browser) — there is no meaningful argv
    // there, same as Odin.
    program_args: []const []const u8 = &.{},
    async_queue: AsyncQueue = .{},
    foreign_call_cache: std.AutoHashMap(*const bytecode.ForeignFunctionConstant, *PreparedForeignCall),
    // The profile is deliberately opt-in: a frame loop pays neither for
    // timestamps nor hash-map writes unless the CLI enables --profile-ffi.
    foreign_profile_enabled: bool = false,
    foreign_profile: std.AutoHashMap(*const bytecode.ForeignFunctionConstant, ForeignCallMetric),
    // Set on the FIRST `время.монотонно_мс()` call (native only — the
    // freestanding wasm32 side has no clock of its own at all, see
    // `timeMonotonic`) — every subsequent call reports elapsed time since
    // this baseline, matching the documented "миллисекунды с момента
    // старта VM" contract without needing a real "VM start" hook.
    monotonic_baseline_ns: ?i96 = null,
    // `ввод_вывод.печать`/`.строка` accumulate here instead of writing
    // directly to a real fd — there IS no real fd on the freestanding
    // wasm32 browser interpreter (see `zig/browser/main.zig`'s batch
    // "run to completion, then read the result buffer" model), so both
    // targets share one mechanism: the CALLER (`zig/cli/main.zig`'s
    // native run path, `runner.zig`'s `runSourceWithVerboseForTarget`,
    // which `zig/browser/main.zig` goes through too) reads `output.items`
    // once `run()` returns and emits/appends it before the final
    // return-value line — ordering is still correct since nothing reads
    // it mid-execution.
    output: std.ArrayList(u8) = .empty,

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
        // Defensive reset for a reused Vm instance — next_process_id restarts
        // from 0 above, so any leftover completion from a PRIOR run() could
        // otherwise be delivered to an unrelated process that happens to
        // reuse the same id.
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
            // Only the CURRENTLY swapped-in process's continuation lives in
            // self.stack/self.frames (marked above) — every other process's
            // own stack/frames fields hold its suspended state directly.
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
            .io_print => try self.ioPrint(false),
            .io_println => try self.ioPrint(true),
            .io_read_line => try self.ioReadLine(),
            .str_byte => try self.strByte(),
            .str_len_bytes => try self.strLenBytes(),
            .str_slice_bytes => try self.strSliceBytes(),
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
            .gzip_decompress => try self.gzipDecompress(),
            .syntax_structs => try self.syntaxStructs(),
            .syntax_fields => try self.syntaxFields(),
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
            .sql_open_submit => try self.sqlOpenSubmit(),
            .sql_exec_submit => try self.sqlExecSubmit(),
            .sql_query_submit => try self.sqlQuerySubmit(),
            .sql_close => try self.sqlClose(),
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
        // Open-or-create without wiping existing content, matching Odin's
        // `os.open(path, {.Read, .Write, .Create}, ...)` (`фс::открыть`,
        // `core/vm_io_native.odin`) — but see `value.zig`'s `FileHandle`
        // doc comment for why this doesn't keep a descriptor open: `access`
        // just probes existence (creating an empty file if missing), then
        // every subsequent method reopens the file by path.
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
                try self.fault("Runtime Error: {s} ожидает файловый дескриптор", .{method_name});
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
        // Odin's `удалить_директорию` tries a plain remove first (file or
        // already-empty dir) then falls back to a recursive delete only if
        // that fails (non-empty dir) — same two-step here, `deleteDir`
        // before `deleteTree`.
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
        const heap_string = try self.heap.createString(try self.allocator.dupe(u8, "0.3.4"));
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
        // `if`/`else` (not the early-return-then-fallthrough shape used
        // elsewhere in this file) — required here so the freestanding
        // branch never gets semantically analyzed at all: `std.c.getenv`
        // is a real libc extern with no freestanding stub, unlike the
        // `std.Io.Dir`/`std.Io.Threaded` calls the `фс.*` builtins use.
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
            // `std.Io.Threaded.init(allocator, .{})` (no `.environ`
            // supplied) sets `environ_initialized = options.environ.
            // block.isEmpty()` to TRUE (Zig 0.16's `Io/Threaded.zig`) —
            // so the lazy `scanEnviron()` call inside `processSpawn*`
            // sees "already initialized" and skips scanning the REAL OS
            // environment entirely, spawning every child with a
            // completely EMPTY environment. Real bug found auditing
            // panosiki's `gitsync` (`ос.установить_окружение(...)`
            // followed by `ос.выполнить(...)` — the fake-1cv8 test
            // harness reads `$GITSYNC_TEST_MAX_VERSION` to know when to
            // stop, so the version-probing loop in `sync.ps` never saw
            // the variable and looped until the DEFAULT fallback of
            // 999999, spawning a subprocess per iteration — indistinguishable
            // from an infinite hang). Worked around entirely within this
            // function (no VM-wide `Io` plumbing exists to fix at the
            // source) by hand-building an `Environ.Map` from the live
            // libc `environ` global (mutated in place by `ос.
            // установить_окружение`'s `setenv`, see `osEnvSet`) and
            // passing it explicitly via `RunOptions.environ_map` —
            // bypassing `Io.Threaded`'s broken auto-scan path entirely.
            // `std.process.Environ.Block` is `PosixBlock` (a `.slice` of
            // `std.c.environ`-shaped entries) on POSIX, but `GlobalBlock`
            // (no `.slice` field at all) on Windows — `windows_env.
            // buildEnvironMap` reads the live block a different way there
            // (`GetEnvironmentStringsW`, see its own comment).
            var environ_map = if (comptime builtin.target.os.tag == .windows)
                try windows_env.buildEnvironMap(self.allocator)
            else blk: {
                const raw_environ: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
                var environ_len: usize = 0;
                while (raw_environ[environ_len] != null) : (environ_len += 1) {}
                break :blk try std.process.Environ.createMap(.{ .block = .{ .slice = raw_environ[0..environ_len :null] } }, self.allocator);
            };
            defer environ_map.deinit();
            // An empty `working_dir` means "run in the current directory"
            // (documented contract, matches every real panosiki caller —
            // `configurator.ps`/`storage_manager.ps` both pass `""` when
            // they have no specific directory to chdir into) — real bug
            // found auditing `v8runner`: `.{ .path = "" }` was passed to
            // `Child.Cwd` UNCONDITIONALLY, and Zig 0.16's `chdir("")`
            // fails `error.FileNotFound` (POSIX `chdir` rejects an empty
            // path outright) — so EVERY `ос.выполнить(..., "")` call
            // failed before the child process even spawned, regardless
            // of whether the program path itself was valid.
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

    // Host-provided clock for the freestanding wasm32 browser interpreter —
    // wasm32-freestanding has no syscalls of its own (no `std.time`), so
    // `время.сейчас_мс`/`.монотонно_мс` need the embedding JS to supply
    // real time the same way `docs/src/assets/interactive.js`'s `env`
    // import object already does for this exact purpose. Declared only
    // here (not exported from `zig/browser/main.zig`) — an unreferenced
    // `extern` on a non-wasm32 build is simply dead, never actually
    // imported by the linker.
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

    // Blocking, line-buffered real-stdin read — real gap found auditing
    // panosiki's `cli-selector` package (an interactive menu that reads
    // stdin lines to drive prompts): `native_only` per `target.zig`
    // (already anticipated this exact name before it was implemented) —
    // a browser tab has no real stdin to block on, same rationale as
    // `время.спать_мс`'s freestanding panic. Returns `Результат.Неудача`
    // only on IMMEDIATE EOF (zero bytes ever read) — a final
    // unterminated line before EOF still comes back as `Успех(...)`,
    // matching normal `readline`/`fgets` behavior elsewhere.
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
        // `std.posix.read(std.posix.STDIN_FILENO, ...)` doesn't exist on
        // Windows (`fd_t` there is handle-based, not a POSIX integer fd —
        // `STDIN_FILENO` is a POSIX-only concept) — `std.Io.File.stdin()`
        // + `.readStreaming` abstracts over both uniformly (already the
        // pattern `submitFileRead`/`submitFileWrite` use for `фс.*` above).
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
        try self.stack.append(self.allocator, .{ .void = {} });
    }

    // Byte offset of the Nth rune (codepoint) in `string` — `string.len`
    // itself is a valid result (the position just past the last rune),
    // used as the upper bound by `strSlice`/`strFind`'s rune-index-to-
    // byte-offset conversion. Same UTF-8 walk `stringAt` (indexing, `s[i]`)
    // already does, factored out since `строки.срез`/`.найти` need it too.
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

    fn strByte(self: *Vm) anyerror!void {
        const index_value = try self.pop();
        const string_value = try self.pop();
        const string = string_value.stringBytes() orelse {
            try self.fault("Runtime Error: строки.байт() ожидает строку", .{});
            return;
        };
        const index = try self.arrayIndex(index_value);
        if (index >= string.len) {
            try self.fault("Runtime Error: строки.байт(): индекс вне границ", .{});
            return;
        }
        try self.stack.append(self.allocator, .{ .number = @floatFromInt(string[index]) });
    }

    fn strLenBytes(self: *Vm) anyerror!void {
        const string_value = try self.pop();
        const string = string_value.stringBytes() orelse {
            try self.fault("Runtime Error: строки.длина_байт() ожидает строку", .{});
            return;
        };
        try self.stack.append(self.allocator, .{ .number = @floatFromInt(string.len) });
    }

    fn strSliceBytes(self: *Vm) anyerror!void {
        const end_value = try self.pop();
        const start_value = try self.pop();
        const string_value = try self.pop();
        const string = string_value.stringBytes() orelse {
            try self.fault("Runtime Error: строки.срез_байт() ожидает строку", .{});
            return;
        };
        const start = try self.arrayIndex(start_value);
        const end = try self.arrayIndex(end_value);
        if (start > end or end > string.len) {
            try self.fault("Runtime Error: строки.срез_байт(): границы вне диапазона", .{});
            return;
        }
        // `строки.найти` returns a RUNE index, `срез_байт` takes BYTE
        // indices — mixing the two (a real, confirmed-by-running trap:
        // `строки.срез_байт(текст, строки.найти(текст, "хлеб", 0), ...)`
        // silently produced mangled output on Cyrillic input, since a
        // rune offset landing mid-character is a perfectly valid byte
        // offset арифметически, just not a valid UTF-8 boundary) is not
        // fixable by guessing which index kind the caller meant — but a
        // continuation byte (`10xxxxxx`) at either boundary means the
        // slice cuts a multi-byte rune in half, which is NEVER correct
        // regardless of which index kind was intended. Converts silent
        // corruption into a loud, debuggable error at the exact call
        // site that got it wrong, instead of mangled output surfacing
        // however many operations later someone finally looks at the
        // string.
        const is_continuation_byte = struct {
            fn check(bytes: []const u8, offset: usize) bool {
                return offset < bytes.len and bytes[offset] & 0xC0 == 0x80;
            }
        }.check;
        if (is_continuation_byte(string, start) or is_continuation_byte(string, end)) {
            try self.fault("Runtime Error: строки.срез_байт(): граница внутри UTF-8-руны — вероятно, перепутаны rune- и byte-индексы", .{});
            return;
        }
        const result = try self.heap.createString(try self.allocator.dupe(u8, string[start..end]));
        try self.stack.append(self.allocator, .{ .heap_string = result });
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

    // Mass (whole-string) counterpart to `строки.байт`/`длина_байт` — same
    // element type/shape as `из_байтов`'s input, just produced instead of
    // consumed.
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

    // Mass (whole-string) rune decode — `Массив(Целое)` of codepoint
    // values, same UTF-8 decoding as `строки.длина`/`срез` (`Utf8View`).
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

    // Inverse of `в_руны` — encodes each codepoint back to UTF-8, same
    // validation shape as `из_байтов` (range-check every element before
    // committing any output).
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

    // First rune's codepoint value — same "decode just the FIRST
    // codepoint, ignore the rest" contract as `strIsDigit`/`strIsLetter`
    // above, for the common `строки.кодовая_точка(s[i])` (single-rune
    // slice) call shape the docs example uses.
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

    // ASCII + Cyrillic (а-я/ё → А-Я/Ё) — the two alphabets any real panos
    // caller (Russian-keyword language, 1С-adjacent tooling) actually
    // uses; full Unicode case-folding is out of scope for this slice.
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

    // Returns the RUNE index (not byte offset) of the first match, per
    // `docs/src/language/basic-types.md`'s explicit contract ("строки.
    // найти возвращает рановый индекс") — converts the byte offset
    // `std.mem.indexOf` finds by counting codepoints up to it.
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

    // Rune-based (NOT byte-based) — `строки.срез_байт` is the byte-offset
    // equivalent, see `docs/src/language/basic-types.md` §"Байты" for why
    // both exist separately.
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

    // ASCII + Cyrillic letters (matches `strUpper`'s scope) — single-rune
    // input expected (typical caller passes a one-character index slice
    // like `s[i]`), only the FIRST rune is inspected if given more.
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

    // `Целое(x)` — truncates toward zero, a no-op if `x` is already an
    // integer value (same `Value.number` f64 representation either way,
    // see `bytecode.zig`'s `.int_cast` doc comment).
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

    fn gzipDecompress(self: *Vm) anyerror!void {
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
        // Pure in-memory codec (no OS/threading dependency at all, unlike
        // фс.*/ос.*) — no `std.Io.Threaded`/comptime-freestanding branch
        // needed; `target_policy` above is the only gate, matching Odin's
        // restriction (see `builtin_availability.odin`), not a real Zig
        // compilation limitation.
        var input: std.Io.Reader = .fixed(data);
        var decompress: std.compress.flate.Decompress = .init(&input, .gzip, &.{});
        var allocating: std.Io.Writer.Allocating = .init(self.allocator);
        defer allocating.deinit();
        _ = decompress.reader.streamRemaining(&allocating.writer) catch {
            const message = decompress.err orelse error.ReadFailed;
            try self.pushErrorResultForModule("сжатие", @errorName(message));
            return;
        };
        const heap_string = try self.heap.createString(try self.allocator.dupe(u8, allocating.written()));
        try self.pushSuccessResult(.{ .heap_string = heap_string });
    }

    // `Результат.Успех(payload)` — matches the tagged-aggregate shape every
    // other prelude enum variant construction already uses (see
    // `queueSignal`'s `Опция.Есть`/`Опция.Нет`).
    fn pushSuccessResult(self: *Vm, payload: value.Value) anyerror!void {
        const elements = try self.allocator.alloc(value.Value, 1);
        elements[0] = payload;
        const aggregate = try self.heap.createAggregate("Результат.Успех", elements);
        try self.stack.append(self.allocator, .{ .aggregate = aggregate });
    }

    // `Результат.Неудача(Ошибка("фс", message))` — the plain `Ошибка` struct
    // matches its `Ошибка(код, сообщение)` constructor shape
    // (`compiler.zig`'s `compileErrorConstructor`), so `.код`/`.сообщение`
    // field access on the value this pushes works exactly like a
    // user-constructed `Ошибка`.
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

    // `Опция.Есть(payload)`/`Опция.Нет()` — same tagged-aggregate shape as
    // `pushSuccessResult`, for natives whose "not found" isn't an `Ошибка`
    // (`ос.окружение`).
    fn pushOption(self: *Vm, payload: ?value.Value) anyerror!void {
        try self.stack.append(self.allocator, try self.makeOptionValue(payload));
    }

    // Same `Опция.Есть`/`Опция.Нет` construction as `pushOption`, but
    // returns the value instead of pushing it — needed when an `Опция`
    // itself becomes the payload of a `Результат.Успех(...)` (`синтаксис.
    // аргумент_аннотации`/`аргумент_аннотации_поля`).
    fn makeOptionValue(self: *Vm, payload: ?value.Value) anyerror!value.Value {
        const elements = try self.allocator.alloc(value.Value, if (payload == null) 0 else 1);
        if (payload) |some| elements[0] = some;
        const aggregate = try self.heap.createAggregate(if (payload == null) "Опция.Нет" else "Опция.Есть", elements);
        return .{ .aggregate = aggregate };
    }

    // `синтаксис.*` — compile-time AST introspection of ANOTHER .ps file
    // (not the currently-running program), for codegen tooling written in
    // panos itself (mirrors `core/vm_syntax_native.odin`). No persistent
    // handle, unlike `Файл`/`Соединение` — every call re-reads and
    // re-parses the path from scratch; acceptable for a build-time tool
    // run once over a small file, not a hot path (same tradeoff Odin's
    // version documents).
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
        // `parsed` must be `.deinit()`-ed by the caller once done reading
        // `decl.struct_decl.fields`/`.annotations` (both are slices into
        // `parsed.ast`'s arena).
        ok: struct { parsed: syntax_parser.ParseResult, decl: ast_types.Decl },
        // An error `Результат.Неудача(...)` was already pushed onto the
        // stack — caller just returns.
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

    // First positional string argument of an annotation (`&Json("ключ")`),
    // if any — `annotation == null` (annotation absent) is also a valid
    // input, just returns `null`, so callers don't need a separate nil
    // check (mirrors Odin's `annotation_string_arg`).
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

    // Textual rendering of a `Type_Node` as written in the source — NOT
    // the checker's canonical `^Type`/`TypeId` (there is no type-checked
    // graph for this file at all, it's a throwaway parse) — just the raw
    // syntax, for human/codegen consumption. Mirrors Odin's
    // `type_node_to_string` (`core/syntax_parser.odin`).
    fn typeNodeText(allocator: std.mem.Allocator, tree: *const ast_types.Ast, id: ast_types.TypeId) ![]u8 {
        return switch (tree.typeNode(id).*) {
            .ident => |node| allocator.dupe(u8, node.name),
            .generic => |node| std.fmt.allocPrint(allocator, "{s}(...)", .{node.name}),
            .qualified => |node| std.fmt.allocPrint(allocator, "{s}.{s}", .{ node.module_name, node.name }),
            .tuple => allocator.dupe(u8, "(кортеж)"),
            .function => allocator.dupe(u8, "(тип функции)"),
            .error_node => allocator.dupe(u8, "<ошибка типа>"),
        };
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
        // Percent-encoding by BYTE, not rune — RFC 3986 unreserved
        // (A-Z a-z 0-9 - _ . ~) as-is, everything else (including every
        // byte of a multi-byte UTF-8 rune individually) as `%XX`. Matches
        // Odin's `сеть::кодировать_url` (`core/vm.odin`) exactly — no
        // target restriction, pure byte manipulation.
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

    // Real gap found this session running `std/сеть/http.pns`'s router
    // against a real curl request: HTTP clients percent-encode non-ASCII
    // path segments on the wire (confirmed via `curl -sv` sending
    // `/api/%d0%b7...` for a route registered as `/api/задачи`), and the
    // router compared the RAW (still-encoded) request path against route
    // templates — a Cyrillic route could never match a real request. No
    // decode counterpart to `urlEncode` existed anywhere (native, std/,
    // nothing) before this. Byte-level, symmetric with `urlEncode` above
    // — a malformed `%`-escape (not a hex pair, or `%` truncated at the
    // end of the string) is a `Runtime Error`, not a silent drop, so a
    // malformed path fails loudly instead of matching the wrong route.
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
        // Everything the worker touches must be cloned onto page_allocator
        // HERE, on the main thread, before spawning — the Value/Map bytes
        // are self.allocator-owned and not safe for a background thread to
        // read concurrently once this call returns. The array itself (not
        // just each pair's strings) must ALSO be page_allocator-owned and
        // NOT freed here — ownership transfers fully to the worker
        // (submitHttpRequest/Job frees it), since the worker keeps reading
        // it after this function returns.
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
        // Shrink to the actual valid count (not just a sub-slice) — the
        // worker frees this slice by the SAME allocator with the SAME
        // length it was given; a shorter sub-slice of a longer allocation
        // is not a valid `free()` input for `page_allocator`. Shrinking via
        // `realloc` is guaranteed to succeed (never needs new memory).
        const shrunk_headers = std.heap.page_allocator.realloc(owned_headers, header_count) catch unreachable;
        submitHttpRequest(
            self,
            method_text,
            url,
            body,
            shrunk_headers,
            process.id,
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
        // Borrowed from `sqlite3_errmsg`'s own buffer — valid only until
        // the next call on the same `db`/until it's closed. Callers must
        // consume it (e.g. `pushErrorResultForModule`, which copies it
        // immediately) before making any further sqlite3 call.
        fail: []const u8,
    };

    // Shared prepare+positionally-bind-`?`-placeholders step for
    // `Соединение_БД.выполнить`/`.запрос` — `параметры` bind ONLY this
    // way, there is no string-concatenation SQL path anywhere in this
    // VM, so callers can't build an injectable query even if they wanted
    // to.
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

    // Validates that every element of `параметры` is a Строка and clones
    // them onto page_allocator — shared by sqlExecSubmit/sqlQuerySubmit,
    // both need this identical prep before handing off to a worker.
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

    // Packs a numeric panos `Value` into `dest` per `kind` — shared by
    // both a plain scalar argument/field and one FIELD of a struct-by-value
    // argument (`ff_структура` fields are always one of these five kinds,
    // never `.c_string`/`.pointer`/`.struct_value` — `parser.zig`'s
    // `parseFfiStructDeclaration` enforces that at parse time).
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

    // Inverse of `packScalar` — reads one field back out of raw C ABI
    // bytes into a panos `Value`.
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

    // Packs a panos struct-by-value argument (`.aggregate`, one element per
    // field, declaration order — matches `layout`) into `dest`, which must
    // be at least `struct_type.size` bytes (populated by `ffi_prep_cif` —
    // callers must call this only AFTER that, never before). Field byte
    // offsets come from libffi itself (`ffi_get_struct_offsets`) — C ABI
    // struct layout (padding for alignment) is NOT something to
    // reimplement by hand here.
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

    // Inverse of `packStruct` — builds a panos `.aggregate` (untagged —
    // field access is purely positional, `vm.zig`'s `getProperty`/
    // `setProperty` never consult `.name`, see `buildStruct`) from raw C
    // ABI bytes.
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

    // Marshals `arguments` and performs the actual FFI call. Signature
    // preparation, layout calculation and storage allocation are cached by
    // `prepareForeignCall`; only the values themselves are hot-path work.
    fn invokeForeign(self: *Vm, info: *const bytecode.ForeignFunctionConstant, arguments: []const value.Value) anyerror!value.Value {
        const prepared = (try self.cachedForeignCall(info)) orelse return .{ .void = {} };
        const nargs = info.param_kinds.len;
        const arg_types = prepared.arg_types.?;
        const param_offsets = prepared.param_struct_offsets.?;
        const cell_offsets = prepared.cell_offsets.?;
        const argument_storage = prepared.argument_storage.?;
        const argument_values = prepared.argument_values.?;
        const return_storage = prepared.return_storage.?;

        // `КСтрока` arguments need a real null-terminated buffer that
        // outlives the `ffi_call` below. This remains per-call because C
        // receives the current panos string, unlike the ABI plan above.
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
                // Panos always copies C-owned returned strings into the GC.
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

    // Bind+listen is a fast, local, one-shot syscall — unlike `.accept()`
    // (which can block indefinitely waiting for a client), this stays
    // synchronous, same reasoning as `сеть.подключиться`'s DNS resolve NOT
    // needing to be split from its own connect.
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
        // No in_flight gate, no gc_pin — unlike Connection/FileHandle/
        // SqlConnection, MULTIPLE concurrent accepts on the same listener
        // are exactly the point of a server (worker pool draining the
        // accept "queue" concurrently across however many processes are
        // calling .принять_запрос()). accept() itself is safe to call from
        // multiple threads on the same listening socket.
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

    // Synchronous, like `.закрыть()` — formatting+writing a response is a
    // fast local operation on an already-connected socket, no need to
    // route it through the async worker pool. One request per connection
    // (no keep-alive) — the stream is closed right after responding.
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
        // Best-effort — `Запрос.ответить()` returns plain `Пусто`, not a
        // `Результат`: a write failure here almost always just means the
        // client already disconnected, and there is nothing a request
        // handler could meaningfully do differently in that case.
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
        // Drain whatever a previous `.получить_строку()` already pulled off
        // the wire but hadn't consumed yet — handed to the worker as its
        // starting buffer, then it keeps reading raw chunks (zero-length
        // internal buffer — see `value.zig`'s `Connection` doc comment)
        // until the peer closes the connection.
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
                // A Сравниваемое implementation calling получить()/
                // получить_сигнал()/an async builtin has no process context
                // to suspend into here — this is a synchronous nested call,
                // not a scheduled slice.
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

    // Same nested-call shape as `invokeComparable`, one argument instead
    // of two (`клонировать(это)`) — synchronously runs a `реализация
    // Копируемое` override to completion and returns its result. Used by
    // `deepCopyForSend` below.
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
                // Same rationale as `invokeComparable` — a Копируемое
                // override calling получить()/получить_сигнал()/an async
                // builtin has no process context to suspend into here.
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

    // Restores copy-on-send isolation (ROADMAP.md Стадия 24, silently
    // dropped in the Zig migration — see `send`'s own comment). Two
    // dispatch paths, mirroring `Сравниваемое`'s existing name-keyed
    // lookup:
    //   - the message's runtime struct name has a registered `реализация
    //     Копируемое` override (`registerCopyableMethods`,
    //     `compiler.zig`) — call it directly and trust its result AS-IS
    //     (no further reflective walk — a custom override exists
    //     precisely to control what gets copied, e.g. deliberately
    //     sharing a cache field; re-walking afterward would defeat that).
    //   - otherwise, reflectively walk the value's structure and build an
    //     independent copy — cycle-safe via `seen` (old heap pointer →
    //     already-built copy), same shape as the GC mark-walker's own
    //     cycle protection, just building a copy instead of setting a
    //     mark bit.
    // Primitives (Число/Булево/Пусто/Никогда) and heap strings are NOT
    // copied — panos strings are immutable, so sharing them is always
    // safe (ROADMAP.md Стадия 24, decision 2). Native resource handles
    // (Процесс/Файл/Соединение/Соединение_БД/Слушатель/Запрос) are also
    // NOT copied — they identify a live resource, not data; copying one
    // would be meaningless (a "cloned" file handle doesn't point at a
    // second copy of the file) and sending a `Процесс(T)` handle must
    // keep pointing at the SAME target process.
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
        self.stack.items[interface_index] = .{ .function_ref = methods[call_info.method_index] };
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
            // Deep-copy for actor isolation — see `deepCopyForSend`'s own
            // comment. Only done when the target is actually alive (a
            // dead target is a silent no-op either way, no point paying
            // the copy cost).
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

    // `ждать(процесс)` — unlike получить/получить_сигнал/await_async
    // (parameterless, block on the CURRENT process's own queue),
    // `ждать` takes an argument (the target `Процесс(T)` handle) already
    // sitting on the stack from `compileExpression(call.arguments[0])`.
    // A suspend here only rewinds `frame.ip` back to THIS instruction —
    // the argument-computing instructions before it do NOT re-run — so
    // the target must be PEEKED (not popped) while still pending, and
    // only actually consumed once ready to push a real result.
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
            // A single process only ever executes one instruction at a
            // time (cooperative, single-threaded) — it can't already be
            // registered as a waiter for a DIFFERENT still-pending `ждать`
            // when this one starts, so a plain append here can't produce
            // a stale/duplicate registration in practice.
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

    // `выбор ожидание(источник) ... конец` — like `awaitTask`, the source
    // array is peeked (not popped) while nothing is ready, since a
    // suspend only rewinds `frame.ip` back to THIS instruction and the
    // instructions that computed the array won't re-run. Priority order
    // when multiple sources are ready simultaneously: mailbox, then
    // signals, then a listed process's completion — matching
    // получить/получить_сигнал/ждать's own relative ordering elsewhere in
    // this file (получить/получить_сигнал are always checked before any
    // task-completion path exists at all).
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
        // Nothing ready yet — register as a waiter on every still-pending
        // listed process, guarding against duplicate registration across
        // retries of this same suspended opcode (unlike `awaitTask`,
        // `selectWait` CAN legitimately retry multiple times before
        // anything becomes ready, e.g. woken by an unrelated mailbox
        // message that turns out not to be present anymore by the time
        // this instruction re-runs).
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

    // `ограничить_почту(N)` — sets a capacity on the CALLING process's OWN
    // mailbox (no target argument, mirrors `себя()`'s "current process"
    // shape). Only `отправить_или` below ever consults this — plain
    // `отправить` stays capacity-blind, matching every process's behavior
    // before this feature existed.
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
    // opt-in, backpressure-aware sibling of `отправить`. Rejects (without
    // appending) only when the TARGET has an explicit `mailbox_capacity`
    // AND is already at/over it; an unbounded target (the default) never
    // rejects, same as plain `отправить`.
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

    // `отмена(процесс)` — sets a flag on the TARGET; purely advisory,
    // nothing forces the target to notice. Sibling to `убить()`
    // (structurally: pops a `Процесс(T)`, no self-cancel/main-process
    // restriction needed since this can never actually stop anything on
    // its own).
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

    // `отменено()` — polls the CURRENT process's own flag. A process that
    // never calls this never observes cancellation at all.
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
        // A CPU-bound process (busy loop with no blocking call inside)
        // burned through its instruction budget without reaching
        // completion, failure, or a blocking op — distinct from
        // `.suspended`, which means "blocked on an empty mailbox/signal/
        // async queue, re-check the SAME instruction next slice." Budget
        // exhaustion has no such rollback: the loop below only checks the
        // budget BETWEEN completed `step()` calls, never mid-dispatch, so
        // `frame.ip` is already sitting exactly where execution should
        // resume — no new persisted state is needed beyond what
        // suspend/resume already maintains.
        budget_exhausted,
        failed,
    };

    // A process runs at most this many bytecode instructions per
    // scheduling slice before voluntarily yielding back to the scheduler,
    // even if it never calls получить()/получить_сигнал()/an async
    // builtin. Without this, a CPU-bound `пока истина цикл ... конец` with
    // no blocking call inside hangs the ENTIRE VM forever — round-robin in
    // name only, since `runProcessSlice` used to run a process strictly
    // until it blocked or finished. Value is a rough empirical balance:
    // large enough that ordinary short-lived process bodies never hit it
    // (avoiding needless round-trip overhead for the common case), small
    // enough that a busy-looping process can't starve message-blocked
    // siblings for more than a bounded number of scheduler rounds.
    const process_instruction_budget: u32 = 100_000;

    // Runs ONE process for one scheduling slice: swaps its persisted
    // stack/frames into the shared vm.stack/vm.frames (cheap — an
    // ArrayList header, not a data copy), steps until it either finishes,
    // crashes, suspends (получить/получить_сигнал/Await_Async on an empty
    // queue), or exhausts its instruction budget, then swaps its (possibly
    // still-mid-frame) state back. Mirrors Odin's run_scheduler swap
    // discipline (core/vm.odin), extended with the instruction budget.
    fn runProcessSlice(self: *Vm, process: *value.Process) anyerror!SliceOutcome {
        self.stack = process.stack;
        self.frames = process.frames;
        self.failure = null;
        self.current_process = process;
        defer {
            // Fully transfer ownership back (not just copy the header) —
            // leaving self.stack/self.frames aliased to the same backing
            // buffer as process.stack/process.frames would double-free at
            // Vm.deinit() (both `self.frames.deinit()` and
            // `process.deinit()` would free the same allocation).
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

    // Round-robin driver (mirrors Odin's run_scheduler): a process is
    // runnable if it has never run yet, or has a pending mailbox message /
    // monitor signal / async result waiting for it. Returns as soon as the
    // ROOT process (index 0, "старт()") finishes or crashes — orphaned
    // processes are simply abandoned, same contract as before this
    // refactor.
    fn runScheduler(self: *Vm, root: *value.Process) anyerror!Execution {
        while (true) {
            self.drainAsyncCompletions();
            var any_ran = false;
            var i: usize = 0;
            while (i < self.processes.items.len) : (i += 1) {
                const process = self.processes.items[i];
                if (process.status != .ready) continue;
                // A budget-exhausted OR task-wakeup-pending process is NOT
                // blocked on anything — it must always be eligible for its
                // next slice, or (respectively) a CPU-bound busy loop, or a
                // process whose `ждать`-ed task just finished, would be
                // wrongly treated as "no work to do" the moment its
                // mailbox/signals/async_results happen to all be empty.
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
                            self.joinAsyncPool();
                            return .{ .success = result };
                        }
                        try self.notifyWatchers(process, null);
                    },
                    .failed => {
                        if (process == root) {
                            self.joinAsyncPool();
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
        // Handle-lifecycle side effects (unpin, clear in_flight, apply a
        // deferred close) must run REGARDLESS of whether the target
        // process is still alive — a `.закрыть()` while a read is in
        // flight only sets close_requested, precisely because the actual
        // close is applied HERE, not conditionally on delivery succeeding.
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
                // Unreachable in practice — connection_read completions
                // only ever originate from submitConnectionRead, itself
                // gated to non-freestanding — but this function is called
                // unconditionally from drainAsyncCompletions for every
                // target, so it still needs a real `if`/`else` split.
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

    // Delivers a process's terminal outcome and wakes anything blocked
    // in `ждать(это)` — called exactly once per process, from whichever
    // path actually ends it (normal completion in `runScheduler`, or
    // `terminateProcess` for a crash/forceful `убить()`). Harmless no-op
    // work for a `запусти`-spawned process that nothing ever
    // calls `ждать` on (empty `task_waiters`, `result` simply unused).
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
    // The round-robin scheduler does NOT run отправить()'s target
    // synchronously (unlike the old recursive-execution model this test was
    // originally written against) — сосед() must stay alive (loop forever
    // instead of completing) so the link to жертва is still valid whenever
    // жертва actually gets scheduled and crashes. Same rendezvous idiom as
    // Odin's own equivalent test (core/e2e_actors_test.odin,
    // test_link_cascades_crash_to_linked_process): сосед pings родитель
    // back only AFTER связать() has run, so отправить(жертва, ...) below is
    // guaranteed to happen after the link exists.
    const source =
        \\функ падающий() -> Пусто
        \\    получить()
        \\    паника("сбой")
        \\конец
        \\функ сосед(партнёр: Процесс(Число), родитель: Процесс(Число)) -> Пусто
        \\    связать(партнёр)
        \\    отправить(родитель, 1)
        \\    получить()
        \\    сосед(партнёр, родитель)
        \\конец
        \\функ проверка() -> Булево
        \\    пер жертва: Процесс(Число) = запусти падающий()
        \\    пер process: Процесс(Число) = запусти сосед(жертва, себя())
        \\    наблюдать(process)
        \\    получить()
        \\    отправить(жертва, 1)
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

// Regression for a real bug found auditing panosiki's `cli` package:
// named-argument struct constructors were type-checked in the CALLER's
// argument order (correct, via `reorderNamedArguments`), but codegen
// zipped the raw, UNREORDERED `call.arguments` against the struct's
// declared field order — silently storing each value in the wrong
// field slot at runtime. `Точка(y = 1, x = 2)` (fields declared `x`
// then `y`) must build `x=2, y=1`, not `x=1, y=2`.
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

// Regression for a real bug found auditing panosiki's `gitsync`: a
// `выбор`/`если` whose arms are one bare interface-typed value and one
// concrete implementor (both individually assignable to a KNOWN
// `expected` type, e.g. a function's declared return type) must be
// accepted — `assignable` is directional for interfaces, so the old
// mutual pairwise check between arms rejected this even though each
// arm independently satisfies `expected`.
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

// Regression for a real bug found auditing panosiki's `configor`: a
// generic function whose parameter is bound by a USER-DEFINED interface
// (`[T: ИзTOML]`) calling a method on that bare parameter inside its own
// body (`это.метод()`) — panos generics aren't monomorphized, so this
// only works if the caller's concrete argument gets cast to the bound
// interface at the call site, and the method call inside the generic
// body dispatches through that same interface's vtable.
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

// Regression for a real bug found auditing panosiki's `cli-selector`
// (`новый_селектор[T](заголовок: Строка) -> Селектор(T)` whose body is
// `Селектор(заголовок, массив())`): a generic struct's own type
// parameter couldn't be inferred from an EMPTY array-literal
// constructor argument (`массив()` infers as `Массив(poison)`, and the
// old `inferGenericSubstitution` gave up silently instead of
// substituting `poison`) — the function's declared return type
// (`Коробка(T)`, the FUNCTION's own `T`) then failed to unify against
// the constructed `Коробка(poison)` at all, since plain nominal-type
// assignability required an exact argument match before the sibling
// `assignable` fix (see the elementwise-recursion case) started
// tolerating `poison` there too. This checks the DECLARATION alone —
// deliberately not a call site: calling a generic function whose type
// parameter appears ONLY in the return type (never in any parameter)
// can't be resolved from argument types either way, an entirely
// separate, orthogonal limitation real panosiki callers route around by
// never annotating the call (`пер с1 = выборка.новый_селектор(...)`,
// no `: Тип`) rather than something this fix touches.
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

// Regression for the bidirectional-inference fix this session added
// (`inferCallExpected`): `новая_коробка[T](метка: Строка) -> Коробка(T)`
// has `T` ONLY in the return type — with an explicit `: Коробка(Число)`
// annotation on the call site, `T` must now resolve to `Число` for real
// (seeded from the expected type), not silently fall back to `poison`.
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

// Regression: an ANNOTATED call whose generic type parameter STILL can't
// be resolved (expected type given, but structurally incompatible with
// the function's own return type) must now be a hard Type Error — not a
// silently-poisoned success. This is the "no unconstrained T out of thin
// air when context exists" half of the bidirectional-inference fix.
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
    // `Строка` (the annotation) is structurally incompatible with
    // `Коробка(T)` (the function's real return shape) — `T` can never be
    // seeded from it, and there's no argument to fall back to either.
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

// Direct reproduction of the scheduler-fairness bug (Phase A of the
// concurrency remediation plan): a CPU-bound process that never calls
// получить()/получить_сигнал()/an async builtin must NOT be able to starve
// a sibling process forever. `бесконечный` below is a genuinely
// non-terminating loop — before the instruction-budget fix, spawning it
// FIRST made `runProcessSlice` (and therefore this whole test) hang
// forever the moment the scheduler gave it a turn (`while (true) { step() }`
// with no exit condition it could ever reach). With the fix, the busy
// process yields back to the scheduler every `process_instruction_budget`
// instructions, so the sibling `ответчик` still gets scheduled, sends its
// reply, and `проверка` (root) receives it — even though `бесконечный`
// itself never completes and is simply abandoned when root returns.
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
        \\    отправить(родитель, 42)
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

// Phase B (concurrency remediation plan): `отправить` restores the
// Odin-era copy-on-send isolation guarantee (ROADMAP.md Стадия 24). The
// sender mutates its own array AFTER spawning a child and sending it a
// struct wrapping that array — the child must see the array as it was AT
// SEND TIME, not reflect the sender's later mutation, proving the message
// was NOT shared by reference.
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

// A `реализация Копируемое` override is invoked directly at send time
// instead of the default reflective walk — proving the custom clone (which
// deliberately replaces the label field) actually ran, not the structural
// default (which would have preserved the original label unchanged).
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

// Phase C (concurrency remediation plan, simplified per user feedback to
// avoid a redundant Erlang-less keyword/type): `запусти <вызов>` spawns a
// `Процесс(T)` where T is now correctly inferred from the spawned
// function's own return type. `ждать` blocks on that same `Процесс(T)`
// handle until it completes and returns `Результат.Успех(T)`.
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

// A spawned process that CRASHES (panics) must not take down the whole VM
// — `ждать` on it returns `Результат.Неудача(Ошибка(...))`, exactly like
// any other fallible native operation, not a propagated runtime fault.
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
