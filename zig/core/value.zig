const std = @import("std");
const bytecode = @import("bytecode.zig");
const sqlite3 = @import("sqlite3_bindings.zig");

pub const Aggregate = struct {
    header: GcHeader = .{},
    name: ?[]const u8 = null,
    elements: []Value,
};

pub const Array = struct {
    header: GcHeader = .{},
    elements: []Value,
};

pub const Closure = struct {
    header: GcHeader = .{},
    function_id: bytecode.FunctionId,
    captures: []Value,
};

pub const MapEntry = struct {
    key: Value,
    value: Value,
};

pub const Map = struct {
    header: GcHeader = .{},
    entries: std.ArrayList(MapEntry) = .empty,

    pub fn deinit(self: *Map, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        self.* = undefined;
    }
};

pub const GcHeader = struct {
    marked: bool = false,
};

// Open filesystem handle (`фс.открыть`). Mirrors Odin's `File_Value`
// (`core/file_value_native.odin`) minus the live OS descriptor and the
// async in_flight/close_requested pair — see `vm.zig`'s `fileOpen`/
// `fileHandleRead*`/`fileHandleWrite` for why: keeping a real `std.Io.File`
// alive across calls pulls in `std.Io.Threaded`'s positional
// `File.Reader`/`File.Writer`, which fail to compile for the
// `wasm32-freestanding` browser target (`RandomFile`'s `getrandom` probe
// has no freestanding stub). Every method instead reopens the file by
// `path` per call through the same whole-file `readFileAlloc`/`writeFile`
// helpers `фс.прочитать`/`фс.записать` already use (proven to compile for
// every target) — `offset` is OUR OWN logical read/write cursor into that
// path's content, not an OS seek position.
pub const FileHandle = struct {
    header: GcHeader = .{},
    path: []u8,
    is_open: bool = true,
    offset: usize = 0,
    // Gates a concurrent second read/write on the SAME handle — without
    // this, two overlapping async calls could both snapshot `offset`
    // before either writes it back, corrupting the sequential-read
    // contract (same race `Connection.in_flight` guards against).
    in_flight: bool = false,
};

// Open TCP connection (`сеть.подключиться`). Unlike `FileHandle` above,
// this DOES hold a live OS socket — a connection can't be "reopened by
// address" between calls the way a file can be reopened by path (once
// bytes are read off the wire they're gone; a fresh `connect()` would be a
// different, empty conversation, not a resumption).
//
// `pending` is OUR OWN byte buffer for `.получить_строку()`'s partial-line
// carry-over — deliberately NOT a persisted `std.Io.net.Stream.Reader`
// (which owns its own lookahead buffer): `vm.zig`'s connection methods
// only ever construct a `Stream.Reader` locally, per call, with a
// zero-length buffer (`&.{}`), which forces it to read exactly as many
// bytes as requested with no opportunistic readahead — so nothing is ever
// silently lost when that transient `Reader` goes out of scope at the end
// of the call. `pending`/`stream` are both plain data (safe struct
// fields); the actual `Stream.Reader`/`.Writer` construction happens
// inside a real `if`/`else` on `builtin.target.os.tag == .freestanding`
// (proper Sema branch elimination — see the progress report's note on
// `ос.*` for why the early-return-then-fallthrough shape `Файл`'s methods
// use wouldn't be safe to reuse here).
pub const Connection = struct {
    header: GcHeader = .{},
    stream: std.Io.net.Stream,
    is_open: bool = true,
    pending: std.ArrayList(u8) = .empty,
    // Set while a background read/write for THIS connection is in flight
    // (submitted, not yet delivered) — gates a concurrent second read/write
    // (busy error, same as Odin) and defers the actual OS-level close if
    // .закрыть() is called mid-flight (close_requested, applied at
    // delivery time instead of racing the worker thread touching the fd).
    in_flight: bool = false,
    close_requested: bool = false,
};

// TCP listening socket (`сеть.http_сервер_слушать`) — `.socket` inside
// `std.Io.net.Server` is just a handle (plain integer/struct), copyable and
// safe to call `.accept()` on concurrently from multiple worker threads at
// once (unlike `Connection`, MULTIPLE `.принять_запрос()` calls in flight
// at the same time is the whole point of a server — no `in_flight` gate
// here, `Heap.pin`/`unpin` already support multiple concurrent pins of the
// same value via its by-value, not by-position, bookkeeping).
pub const Listener = struct {
    header: GcHeader = .{},
    server: std.Io.net.Server,
    is_open: bool = true,
};

// One accepted HTTP request (`Слушатель.принять_запрос()`) — `method`/
// `path` are already-parsed, GC-owned copies (built at delivery time from
// the worker's plain-data result); `stream` stays live so `.ответить()`
// can write the response later, on the main thread, entirely synchronously
// (formatting+writing a response is fast — no need to route it through the
// async worker pool). One request per connection (no keep-alive) — the
// stream is closed right after `.ответить()`.
pub const HttpHeaderEntry = struct { name: []u8, value: []u8 };

pub const HttpRequestHandle = struct {
    header: GcHeader = .{},
    stream: std.Io.net.Stream,
    method: []u8,
    path: []u8,
    body: []u8,
    headers: []HttpHeaderEntry,
    responded: bool = false,
};

// Open SQLite connection (`бд.открыть`) — a live resource like
// `Connection` above, not a "reopen by path" handle like `FileHandle`
// (re-opening a SQLite file mid-transaction would lose uncommitted state,
// same reasoning as TCP).
pub const SqlConnection = struct {
    header: GcHeader = .{},
    db: ?*sqlite3.sqlite3,
    is_open: bool = true,
    // Same purpose as `Connection.in_flight`/`FileHandle.in_flight` — one
    // async `.выполнить()`/`.запрос()` at a time per connection, serialized
    // by us rather than relying on SQLite's own internal threading mode.
    in_flight: bool = false,
};

pub const HeapString = struct {
    header: GcHeader = .{},
    bytes: []u8,
};

pub const Interface = struct {
    header: GcHeader = .{},
    receiver: Value,
    methods: []const bytecode.FunctionId,
};

pub const ProcessStatus = enum {
    ready,
    completed,
    failed,
};

// A call frame belonging to a suspended-or-running Process. Lives here (not
// vm.zig) so Process can hold its OWN persistent frames/stack — the
// scheduler swaps `Vm.stack`/`Vm.frames` with a process's `stack`/`frames`
// for the duration of one scheduling slice, instead of the old model where a
// process's whole execution ran-to-completion recursively on the Zig call
// stack with no way to pause mid-frame.
pub const Frame = struct {
    function_id: bytecode.FunctionId,
    ip: usize = 0,
    locals: []Value,
};

pub const Process = struct {
    id: u64,
    function_id: bytecode.FunctionId,
    captures: []Value,
    arguments: []Value,
    mailbox: std.ArrayList(Value) = .empty,
    signals: std.ArrayList(Value) = .empty,
    watchers: std.ArrayList(*Process) = .empty,
    links: std.ArrayList(*Process) = .empty,
    status: ProcessStatus = .ready,
    // Persistent continuation state — empty while this process is not the
    // one currently swapped into the VM (either it never started, or the
    // scheduler is running a different process right now).
    frames: std.ArrayList(Frame) = .empty,
    stack: std.ArrayList(Value) = .empty,
    // A freshly spawned process must get at least one scheduling slice even
    // with an empty mailbox (its body need not start with получить()) —
    // afterwards an empty mailbox/signals/async_results genuinely means
    // "nothing to do", not "hasn't started yet".
    has_run: bool = false,
    // Results of async builtin calls (Await_Async) — a queue SEPARATE from
    // mailbox/signals so a background I/O result can never be mistaken for
    // an ordinary message or a monitor signal that arrived while waiting.
    async_results: std.ArrayList(Value) = .empty,
    // Set when the LAST scheduling slice ended because this process burned
    // through its instruction budget without blocking or completing (a
    // CPU-bound busy loop with no получить()/получить_сигнал()/async call
    // inside) — see `Vm.runProcessSlice`. The scheduler's runnability check
    // must treat this the same as "has a pending message": a
    // budget-exhausted process is NOT actually blocked on anything and
    // must always be eligible for its next slice, regardless of whether
    // mailbox/signals/async_results are empty (unlike a genuinely
    // MESSAGE-blocked process, for which "nothing pending" really does
    // mean "no work to do yet").
    budget_exhausted: bool = false,
    // `ждать(процесс)` support — `result` is populated exactly
    // once, whenever this process transitions out of `.ready` (completed
    // OR failed), regardless of whether anything is actually waiting on
    // it — cheap to always record (one optional field), and means `ждать`
    // never races the completion: if it's already there when `ждать`
    // checks, no suspend/wakeup dance is needed at all.
    result: ?TaskResult = null,
    // Processes currently blocked in `ждать(это)` — separate from
    // `.watchers` (which feeds `получить_сигнал()`, a user-observable
    // channel) so an internal task-completion wakeup can never be
    // mistaken for a real monitor signal by code that happens to also
    // call `получить_сигнал()`.
    task_waiters: std.ArrayList(*Process) = .empty,
    // Mirrors `budget_exhausted`'s role in the scheduler's runnability
    // gate: set on a WAITING process (not on the completed task) when
    // something it's `ждать`-ing on just finished — this process is not
    // actually blocked on its own mailbox/signals/async_results, so it
    // must stay eligible for its next slice regardless of those being
    // empty.
    task_wakeup_pending: bool = false,
    // Bounded mailbox (Phase F, item 6) — `null` (default) means
    // unbounded, matching every process's behavior before this feature.
    // Set only via `ограничить_почту(N)`, called by the process on
    // itself; only `отправить_или` (not plain `отправить`) consults it.
    mailbox_capacity: ?u32 = null,
    // Cooperative cancellation (Phase F, item 7) — purely advisory, set
    // by `отмена(proc)` on the TARGET, read by `отменено()` on the
    // CURRENT process. No VM code besides these two builtins ever
    // touches this; a process that never calls `отменено()` behaves as
    // if cancellation doesn't exist.
    cancel_requested: bool = false,

    pub fn deinit(self: *Process, allocator: std.mem.Allocator) void {
        self.links.deinit(allocator);
        self.watchers.deinit(allocator);
        self.signals.deinit(allocator);
        self.mailbox.deinit(allocator);
        self.async_results.deinit(allocator);
        self.task_waiters.deinit(allocator);
        for (self.frames.items) |frame| allocator.free(frame.locals);
        self.frames.deinit(allocator);
        self.stack.deinit(allocator);
        allocator.free(self.captures);
        allocator.free(self.arguments);
        self.* = undefined;
    }
};

// The outcome of a `запусти`-spawned process, delivered by `ждать` as
// `Результат.Успех(значение)`/`Результат.Неудача(Ошибка(...))`.
pub const TaskResult = union(enum) {
    completed: Value,
    failed: *HeapString,
};

pub const Value = union(enum) {
    void: void,
    number: f64,
    boolean: bool,
    string: []const u8,
    heap_string: *HeapString,
    function_ref: bytecode.FunctionId,
    closure: *Closure,
    interface: *Interface,
    process: *Process,
    aggregate: *Aggregate,
    array: *Array,
    map: *Map,
    file: *FileHandle,
    connection: *Connection,
    sql_connection: *SqlConnection,
    listener: *Listener,
    http_request: *HttpRequestHandle,

    pub fn stringBytes(runtime_value: Value) ?[]const u8 {
        return switch (runtime_value) {
            .string => |string| string,
            .heap_string => |string| string.bytes,
            else => null,
        };
    }

    pub fn eql(left: Value, right: Value) bool {
        if (left.stringBytes()) |left_string| {
            const right_string = right.stringBytes() orelse return false;
            return std.mem.eql(u8, left_string, right_string);
        }
        if (right.stringBytes() != null) return false;
        return switch (left) {
            .void => right == .void,
            .number => |left_number| switch (right) {
                .number => |right_number| left_number == right_number,
                else => false,
            },
            .boolean => |left_boolean| switch (right) {
                .boolean => |right_boolean| left_boolean == right_boolean,
                else => false,
            },
            .string, .heap_string => unreachable,
            .function_ref => |left_function| switch (right) {
                .function_ref => |right_function| left_function == right_function,
                else => false,
            },
            .closure => |left_closure| switch (right) {
                .closure => |right_closure| left_closure == right_closure,
                else => false,
            },
            .interface => |left_interface| switch (right) {
                .interface => |right_interface| left_interface.receiver.eql(right_interface.receiver),
                else => false,
            },
            .process => |left_process| switch (right) {
                .process => |right_process| left_process.id == right_process.id,
                else => false,
            },
            .aggregate => |left_aggregate| switch (right) {
                .aggregate => |right_aggregate| aggregateEql(left_aggregate, right_aggregate),
                else => false,
            },
            .array => |left_array| switch (right) {
                .array => |right_array| valueSliceEql(left_array.elements, right_array.elements),
                else => false,
            },
            .map => |left_map| switch (right) {
                .map => |right_map| mapEql(left_map, right_map),
                else => false,
            },
            .file => |left_file| switch (right) {
                .file => |right_file| left_file == right_file,
                else => false,
            },
            .connection => |left_connection| switch (right) {
                .connection => |right_connection| left_connection == right_connection,
                else => false,
            },
            .sql_connection => |left_sql| switch (right) {
                .sql_connection => |right_sql| left_sql == right_sql,
                else => false,
            },
            .listener => |left_listener| switch (right) {
                .listener => |right_listener| left_listener == right_listener,
                else => false,
            },
            .http_request => |left_request| switch (right) {
                .http_request => |right_request| left_request == right_request,
                else => false,
            },
        };
    }
};

fn aggregateEql(left: *const Aggregate, right: *const Aggregate) bool {
    const names_match = if (left.name) |left_name|
        if (right.name) |right_name| std.mem.eql(u8, left_name, right_name) else false
    else
        right.name == null;
    return names_match and valueSliceEql(left.elements, right.elements);
}

fn valueSliceEql(left: []const Value, right: []const Value) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_value, right_value| {
        if (!left_value.eql(right_value)) return false;
    }
    return true;
}

fn mapEql(left: *const Map, right: *const Map) bool {
    if (left.entries.items.len != right.entries.items.len) return false;
    for (left.entries.items, right.entries.items) |left_entry, right_entry| {
        if (!left_entry.key.eql(right_entry.key) or !left_entry.value.eql(right_entry.value)) return false;
    }
    return true;
}

test "values compare scalars and aggregates structurally" {
    var tuple_values = [_]Value{ .{ .number = 1 }, .{ .string = "один" } };
    var left = Aggregate{ .elements = &tuple_values };
    var right = Aggregate{ .elements = &tuple_values };
    var different_name = Aggregate{ .name = "Точка", .elements = &tuple_values };

    try std.testing.expect(Value.eql(.{ .aggregate = &left }, .{ .aggregate = &right }));
    try std.testing.expect(!Value.eql(.{ .aggregate = &left }, .{ .aggregate = &different_name }));
    try std.testing.expect(Value.eql(.{ .number = 2 }, .{ .number = 2 }));
    try std.testing.expect(!Value.eql(.{ .number = 2 }, .{ .boolean = true }));
}
