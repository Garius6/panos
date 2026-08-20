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

// Открытый файловый дескриптор (`фс.открыть`). Держать живой `std.Io.File`
// между вызовами нельзя: это тянет за собой позиционные
// `File.Reader`/`File.Writer` из `std.Io.Threaded`, которые не собираются
// для `wasm32-freestanding` (у `getrandom`-проверки `RandomFile` нет
// freestanding-заглушки). Поэтому каждый метод переоткрывает файл по
// `path` на каждый вызов через те же цельнофайловые
// `readFileAlloc`/`writeFile`, которыми уже пользуются `фс.прочитать`/
// `фс.записать` (компилируются под любую цель) — `offset` это НАШ
// собственный логический курсор чтения/записи внутри содержимого файла,
// а не позиция seek в ОС.
pub const FileHandle = struct {
    header: GcHeader = .{},
    path: []u8,
    is_open: bool = true,
    offset: usize = 0,
    // Блокирует одновременное второе чтение/запись на ТОМ ЖЕ дескрипторе —
    // без этого два параллельных async-вызова могли бы оба прочитать
    // `offset` до того, как любой из них его обновит, ломая
    // последовательное чтение (та же гонка, от которой защищает
    // `Connection.in_flight`).
    in_flight: bool = false,
};

// Открытое TCP-соединение (`сеть.подключиться`). В отличие от `FileHandle`
// выше, здесь держится живой OS-сокет — соединение нельзя "переоткрыть по
// адресу" между вызовами, как файл переоткрывается по пути (once bytes
// are read off the wire они потеряны; новый `connect()` — это другой,
// пустой разговор, а не продолжение).
//
// `pending` — НАШ СОБСТВЕННЫЙ буфер байт для переноса недочитанной
// строки между вызовами `.получить_строку()` — умышленно не persisted
// `std.Io.net.Stream.Reader` (у которого свой буфер readahead): методы
// соединения в `vm.zig` всегда создают `Stream.Reader` локально, на
// каждый вызов, с нулевым буфером (`&.{}`), что заставляет его читать
// ровно столько байт, сколько запрошено, без опережающего чтения — так
// ничего не теряется, когда этот временный `Reader` выходит из области
// видимости в конце вызова. `pending`/`stream` — обычные данные
// (безопасные поля структуры); реальное создание
// `Stream.Reader`/`.Writer` происходит внутри настоящего `if`/`else` по
// `builtin.target.os.tag == .freestanding` (нормальное устранение ветки
// компилятором).
pub const Connection = struct {
    header: GcHeader = .{},
    stream: std.Io.net.Stream,
    is_open: bool = true,
    pending: std.ArrayList(u8) = .empty,
    // Установлен, пока для ЭТОГО соединения выполняется фоновое
    // чтение/запись (отправлено, но ещё не доставлено) — блокирует
    // одновременное второе чтение/запись (ошибка занятости) и откладывает
    // реальное закрытие на уровне ОС, если .закрыть() вызван в процессе
    // (close_requested применяется при доставке результата, а не гонится
    // с рабочим потоком за дескриптором).
    in_flight: bool = false,
    close_requested: bool = false,
};

// TCP-слушающий сокет (`сеть.http_сервер_слушать`) — `.socket` внутри
// `std.Io.net.Server` это просто хендл (обычное целое/структура),
// копируемый и безопасный для одновременного вызова `.accept()` из
// нескольких рабочих потоков сразу (в отличие от `Connection`, здесь
// НЕСКОЛЬКО одновременных `.принять_запрос()` — это и есть смысл
// сервера, поэтому блокировки `in_flight` нет: `Heap.pin`/`unpin` уже
// поддерживают несколько одновременных pin одного значения).
pub const Listener = struct {
    header: GcHeader = .{},
    server: std.Io.net.Server,
    is_open: bool = true,
};

// Один принятый HTTP-запрос (`Слушатель.принять_запрос()`) — `method`/
// `path` уже разобранные, GC-владеемые копии (построены на момент
// доставки из данных воркера); `stream` остаётся живым, чтобы
// `.ответить()` мог написать ответ позже, в основном потоке, полностью
// синхронно (форматирование+запись ответа быстрые — нет нужды гонять их
// через пул воркеров). Один запрос на соединение (без keep-alive) —
// поток закрывается сразу после `.ответить()`.
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

// Открытое SQLite-соединение (`бд.открыть`) — живой ресурс, как
// `Connection` выше, а не хендл "переоткрыть по пути", как `FileHandle`
// (переоткрытие файла SQLite посреди транзакции потеряло бы
// незакоммиченное состояние — та же причина, что и у TCP).
pub const SqlConnection = struct {
    header: GcHeader = .{},
    db: ?*sqlite3.sqlite3,
    is_open: bool = true,
    // Та же роль, что у `Connection.in_flight`/`FileHandle.in_flight` —
    // один async `.выполнить()`/`.запрос()` за раз на соединение,
    // сериализуется нами, а не собственным режимом потокобезопасности
    // SQLite.
    in_flight: bool = false,
};

pub const HeapString = struct {
    header: GcHeader = .{},
    bytes: []u8,
};

pub const Interface = struct {
    header: GcHeader = .{},
    receiver: Value,
    vtables: []const []const bytecode.FunctionId,
};

pub const ProcessStatus = enum {
    ready,
    completed,
    failed,
};

// Кадр вызова, принадлежащий приостановленному или выполняющемуся
// Process. Живёт здесь (не в vm.zig), чтобы Process мог держать
// СОБСТВЕННЫЕ постоянные frames/stack — планировщик подменяет
// `Vm.stack`/`Vm.frames` на `stack`/`frames` процесса на время одного
// кванта планирования, что позволяет приостанавливать выполнение
// посреди кадра.
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
    // Постоянное состояние продолжения — пусто, пока этот процесс не тот,
    // что сейчас подставлен в VM (либо ещё не запускался, либо
    // планировщик сейчас выполняет другой процесс).
    frames: std.ArrayList(Frame) = .empty,
    stack: std.ArrayList(Value) = .empty,
    // Новорождённый процесс должен получить минимум один квант
    // планирования даже с пустым почтовым ящиком (его тело не обязано
    // начинаться с получить()) — после этого пустые
    // mailbox/signals/async_results уже действительно значат "нечего
    // делать", а не "ещё не стартовал".
    has_run: bool = false,
    // Результаты async-вызовов встроенных функций (Await_Async) —
    // очередь ОТДЕЛЬНАЯ от mailbox/signals, чтобы результат фонового I/O
    // нельзя было спутать с обычным сообщением или сигналом монитора,
    // пришедшим во время ожидания.
    async_results: std.ArrayList(Value) = .empty,
    // Устанавливается, когда ПОСЛЕДНИЙ квант планирования закончился из-за
    // исчерпания бюджета инструкций без блокировки или завершения
    // (CPU-bound цикл без получить()/получить_сигнал()/async-вызова
    // внутри) — см. `Vm.runProcessSlice`. Проверка планировщиком
    // готовности процесса должна считать это как "есть ожидающее
    // сообщение": процесс с исчерпанным бюджетом НЕ заблокирован ни на
    // чём и должен оставаться допустимым для следующего кванта независимо
    // от пустоты mailbox/signals/async_results (в отличие от процесса,
    // реально заблокированного на СООБЩЕНИИ, для которого "ничего
    // ожидающего" действительно значит "пока нет работы").
    budget_exhausted: bool = false,
    // Поддержка `ждать(процесс)` — `result` заполняется ровно один раз,
    // когда процесс выходит из `.ready` (завершился или упал), независимо
    // от того, ждёт ли его кто-то в этот момент — дёшево записывать
    // всегда (одно опциональное поле), и это значит, что `ждать` никогда
    // не гонится с завершением: если результат уже там на момент
    // проверки, никакого suspend/wakeup не требуется.
    result: ?TaskResult = null,
    // Процессы, сейчас заблокированные в `ждать(это)` — отдельно от
    // `.watchers` (который питает `получить_сигнал()`, пользовательский
    // канал), чтобы внутреннее пробуждение по завершению задачи нельзя
    // было спутать с настоящим сигналом монитора в коде, который заодно
    // вызывает `получить_сигнал()`.
    task_waiters: std.ArrayList(*Process) = .empty,
    // Отражает роль `budget_exhausted` в проверке готовности
    // планировщиком: устанавливается на ОЖИДАЮЩЕМ процессе (не на
    // завершившейся задаче), когда то, что он ждёт через `ждать`, только
    // что завершилось — этот процесс не заблокирован на собственных
    // mailbox/signals/async_results, поэтому должен оставаться допустимым
    // для следующего кванта независимо от их пустоты.
    task_wakeup_pending: bool = false,
    // Ограниченный почтовый ящик — `null` (по умолчанию) значит
    // неограниченный. Устанавливается только через `ограничить_почту(N)`,
    // вызываемый процессом на самом себе; учитывается только
    // `отправить_или` (не обычным `отправить`).
    mailbox_capacity: ?u32 = null,
    // Кооперативная отмена — чисто рекомендательная, устанавливается
    // `отмена(proc)` на ЦЕЛЕВОМ процессе, читается `отменено()` на
    // ТЕКУЩЕМ процессе. Никакой другой код VM это поле не трогает;
    // процесс, никогда не вызывающий `отменено()`, ведёт себя так, как
    // будто отмены не существует.
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

// Результат процесса, запущенного через `запусти`, доставляется `ждать`
// как `Результат.Успех(значение)`/`Результат.Неудача(Ошибка(...))`.
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
