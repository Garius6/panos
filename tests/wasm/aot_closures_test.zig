const std = @import("std");
const panos = @import("panos_core");

// Verifies WASM AOT closure support, Stage A (see
// `project_panos_wasm_aot_closures` design notes) — `mir_lowering.zig`'s
// `.lambda` lowering + `lowerSymbolValueRef`'s `.build_closure` fallback,
// `wasm_interfaces.zig`'s `expandBuildClosure`/`expandCallValue`. Real
// bug found only by running these under wasmtime, not by reading the
// code: `expandCallValue`'s first draft checked a callee ValueId against
// `direct_call_callees` (populated by scanning EVERY `.call_value`'s OWN
// callee field) — tautologically true for any call_value's own callee,
// so every closure call silently took the static-direct-call fast path
// and passed its raw (unboxed) box pointer straight to `call_indirect`
// as a table index ("undefined element: out of bounds table access").
// Fixed with a separate `static_callees` map, populated only when a
// `.function_ref` actually hits the SAME exclusion `.function_ref`'s own
// rewrite already uses.

fn wasmtimeInvoke(allocator: std.mem.Allocator, io: std.Io, wasm_path: []const u8, func: []const u8) !std.process.RunResult {
    return std.process.run(allocator, io, .{
        .argv = &.{ "wasmtime", "run", "--invoke", func, wasm_path },
        .expand_arg0 = .expand,
    });
}

const MemoryReader = struct {
    files: []const struct { path: []const u8, bytes: []const u8 },

    pub fn read(self: *const MemoryReader, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        for (self.files) |file| {
            if (std.mem.eql(u8, file.path, path)) return allocator.dupe(u8, file.bytes);
        }
        return error.FileNotFound;
    }
};

// `DOM.*` needs the graph-aware resolution path (prelude merge +
// `module_loader`'s native-module recognition) — bare `resolver.resolve`
// (`buildBytes` below) doesn't understand `импорт DOM` at all. Same
// shape as `aot_tree_shaking_test.zig`/`aot_gc_arena_test.zig`'s own
// DOM-touching helpers.
fn buildGraphBytes(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const reader = MemoryReader{ .files = &.{.{ .path = "программа.ps", .bytes = source }} };
    var graph = panos.module_loader.Graph.init(allocator);
    defer graph.deinit();
    try graph.load(&reader, "программа");
    _ = try graph.appendPreludeModule(panos.prelude.SOURCE);
    try std.testing.expectEqual(@as(usize, 0), graph.diagnostics.items.items.len);

    var compiled = try panos.module_compiler.compileGraphForTarget(allocator, &graph, .aot_js_wasm);
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var module = try panos.mir_lowering.lowerGraph(allocator, &graph, &compiled);
    defer module.deinit(allocator);

    const type_store = &compiled.modules[0].checked.?.types;
    try panos.wasm_objects.expand(allocator, &module, type_store);
    try panos.wasm_strings.expand(allocator, &module, type_store);
    try panos.wasm_maps.expand(allocator, &module, type_store);
    const iface_result = try panos.wasm_interfaces.expand(allocator, &module, type_store);
    defer allocator.free(iface_result.table);
    var frame_info = try panos.mir_cps.prepare(allocator, &module);
    defer frame_info.deinit();
    try panos.wasm_actors.expand(allocator, &module, type_store, &frame_info);
    try panos.wasm_gc_arena.expand(allocator, &module, type_store);

    return panos.wasm_emit.emitModule(allocator, &compiled.modules[0].checked.?, &module, iface_result.table);
}

fn buildBytes(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var lexed = try panos.lexer.tokenize(allocator, source, 0);
    defer lexed.deinit();
    var parsed = try panos.parser.parse(allocator, lexed.tokens.items);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    var resolved = try panos.resolver.resolve(allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try panos.type_checker.check(allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);

    var module = try panos.mir_lowering.lowerModule(allocator, &parsed.ast, &resolved, &checked);
    defer module.deinit(allocator);

    try panos.wasm_objects.expand(allocator, &module, &checked.types);
    try panos.wasm_strings.expand(allocator, &module, &checked.types);
    try panos.wasm_maps.expand(allocator, &module, &checked.types);
    const iface_result = try panos.wasm_interfaces.expand(allocator, &module, &checked.types);
    defer allocator.free(iface_result.table);
    var frame_info = try panos.mir_cps.prepare(allocator, &module);
    defer frame_info.deinit();
    try panos.wasm_actors.expand(allocator, &module, &checked.types, &frame_info);

    return panos.wasm_emit.emitModule(allocator, &checked, &module, iface_result.table);
}

// Full pipeline, mirroring `cli/main.zig`'s `runBuild` — same shape as
// `aot_gc_arena_test.zig`'s own helper (closures need `wasm_interfaces.
// expand` in its real position, same as GC needs `wasm_gc_arena.expand`).
fn buildAndRun(allocator: std.mem.Allocator, io: std.Io, source: []const u8, wasm_path: []const u8) !std.process.RunResult {
    const wasm_bytes = try buildBytes(allocator, source);
    defer allocator.free(wasm_bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = wasm_path, .data = wasm_bytes });
    return wasmtimeInvoke(allocator, io, wasm_path, "старт");
}

test "a lambda capturing a local number by value returns the correct sum" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const source =
        \\функ старт() -> Число
        \\пер x: Число = 42.0
        \\пер добавить_к_x = функ(y: Число) -> Число x + y конец
        \\добавить_к_x(8.0)
        \\конец
    ;
    const wasm_path = "zzz_aot_closures_capture.wasm";
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};
    const result = try buildAndRun(allocator, io.io(), source, wasm_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("50\n", result.stdout);
}

test "a plain named function used as a first-class value is called correctly through a wrapper" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const source =
        \\функ удвоить(x: Число) -> Число
        \\x * 2.0
        \\конец
        \\
        \\функ старт() -> Число
        \\пер f = удвоить
        \\f(21.0)
        \\конец
    ;
    const wasm_path = "zzz_aot_closures_plainfn.wasm";
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};
    const result = try buildAndRun(allocator, io.io(), source, wasm_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("42\n", result.stdout);
}

test "a closure returned from a function and passed to a higher-order function works" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const source =
        \\функ применить(ф: функ(Число) -> Число, x: Число) -> Число
        \\ф(x)
        \\конец
        \\
        \\функ сделать_умножитель(множитель: Число) -> функ(Число) -> Число
        \\функ(x: Число) -> Число x * множитель конец
        \\конец
        \\
        \\функ старт() -> Число
        \\пер утроить = сделать_умножитель(3.0)
        \\применить(утроить, 7.0)
        \\конец
    ;
    const wasm_path = "zzz_aot_closures_higher_order.wasm";
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};
    const result = try buildAndRun(allocator, io.io(), source, wasm_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("21\n", result.stdout);
}

test "a lambda nested inside a capturing lambda can capture both outer values" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const source =
        \\функ старт() -> Число
        \\    пер x: Число = 10.0
        \\    пер внешняя = функ(y: Число) -> функ() -> Число
        \\        функ() -> Число x + y конец
        \\    конец
        \\    пер внутренняя = внешняя(5.0)
        \\    внутренняя()
        \\конец
    ;
    const wasm_path = "zzz_aot_closures_nested.wasm";
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};
    const result = try buildAndRun(allocator, io.io(), source, wasm_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("15\n", result.stdout);
}

test "a lambda capturing two local values in order returns the correct (order-sensitive) result" {
    // Regression for the multi-capture reverse-order bug (`expandBuildClosure`
    // in `wasm_interfaces.zig` processed `v.captured` in array order, but the
    // values were PUSHED in array order too — with 2+ captures the LAST one
    // sits on top of the real stack, not the first). Every fixture before
    // this had exactly one capture and couldn't expose it. Subtraction (not
    // addition) deliberately makes a swapped-order bug produce a WRONG
    // answer instead of silently matching by coincidence.
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const source =
        \\функ старт() -> Число
        \\пер x: Число = 10.0
        \\пер y: Число = 3.0
        \\пер разница = функ() -> Число x - y конец
        \\разница()
        \\конец
    ;
    const wasm_path = "zzz_aot_closures_multicapture_order.wasm";
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};
    const result = try buildAndRun(allocator, io.io(), source, wasm_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("7\n", result.stdout);
}

test "DOM.на_клик capturing a scalar plus calling a plain function directly compiles (function_ref capture)" {
    // Regression for the two hardest follow-up bugs found converting the
    // real todo-app: (1) the resolver captures ANY `.function`-kind symbol
    // referenced inside a lambda, even one called DIRECTLY — so a plain
    // top-level function call inside the handler body makes `classifyCapture`
    // see a `.function_ref` capture needing `promoteFunctionRefCapture`'s
    // runtime env_ptr==0 check; (2) that check's OWN internal if/else branch
    // previously corrupted the `selector` value computed before it. This
    // fixture combines BOTH triggers at once (multi-capture including a
    // function_ref, alongside the selector argument) — the exact shape that
    // broke before `lowerDomClickClosure` was reordered (handler/promotion
    // fully resolved and stashed in a Local before `selector` is lowered).
    const allocator = std.testing.allocator;

    const source =
        \\импорт DOM
        \\импорт строки
        \\
        \\функ обработать(id: Число) -> Пусто
        \\    DOM.установить_текст_строка("#результат", строки.из_числа(id))
        \\конец
        \\
        \\функ старт() -> Пусто
        \\пер id: Число = 5.0
        \\DOM.на_клик("#кнопка", функ(_: DOM.СобытиеКлика) -> Пусто
        \\    обработать(id)
        \\конец)
        \\конец
    ;
    const wasm_bytes = try buildGraphBytes(allocator, source);
    defer allocator.free(wasm_bytes);

    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "dom_on_click") != null);
    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "@runtime_alloc_permanent") != null);
}

// `DOM.на_клик` closure registration — structural-only, matching
// `aot_tree_shaking_test.zig`'s/`aot_gc_arena_test.zig`'s own DOM test
// precedent: no host provides `env::dom_on_click` outside a
// real browser/JS loader, so this can't be invoked through bare
// `wasmtime run`. The deep end-to-end proof (a captured Число surviving
// across two SEPARATE simulated clicks, after an intervening arena
// reset) was done via a Node/wasmtime harness with a stub host import
// during development — see `project_panos_wasm_aot_closures`.
test "DOM.на_клик compiles and registers the fixed invoke_click trampoline" {
    const allocator = std.testing.allocator;

    const source =
        \\импорт DOM
        \\импорт строки
        \\
        \\функ старт() -> Пусто
        \\пер счётчик: Число = 42.0
        \\DOM.на_клик("#кнопка", функ(_: DOM.СобытиеКлика) -> Пусто
        \\    DOM.установить_текст_строка("#результат", строки.из_числа(счётчик))
        \\конец)
        \\конец
    ;
    const wasm_bytes = try buildGraphBytes(allocator, source);
    defer allocator.free(wasm_bytes);

    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "dom_on_click") != null);
    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "@invoke_click") != null);
    // Scalar-only captures (this fixture) go through Stage C's raw-copy
    // path (`classifyCapture` → `.scalar`, no promotion CALL needed at
    // all) — `@runtime_alloc_permanent` is still required (the box+env
    // allocations themselves always need the permanent region,
    // regardless of what's inside them).
    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "@runtime_alloc_permanent") != null);
    // `wasm_gc_arena.zig` must have wrapped the trampoline too (Task 45's
    // `module.dom_handler_names` addition) — the ORIGINAL trampoline
    // function survives renamed under the arena-wrapper convention.
    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "@arena_impl_@invoke_click") != null);
}

test "DOM.после_кадра does not promote a static context on every frame" {
    const allocator = std.testing.allocator;

    const source =
        \\импорт DOM
        \\
        \\функ кадр(_: Строка) -> Пусто
        \\    DOM.после_кадра("кадр", "")
        \\конец
        \\
        \\функ старт() -> Пусто
        \\    DOM.после_кадра("кадр", "")
        \\конец
    ;
    const wasm_bytes = try buildGraphBytes(allocator, source);
    defer allocator.free(wasm_bytes);

    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "dom_after_frame") != null);
    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "@promote_to_permanent") == null);
    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "@arena_impl_кадр") != null);
}

test "an exported AOT entry point survives tree shaking and gets an arena wrapper" {
    const allocator = std.testing.allocator;

    const source =
        \\импорт DOM
        \\
        \\экспорт функ кадр(_: Строка) -> Пусто
        \\конец
        \\
        \\функ запланировать(имя: Строка) -> Пусто
        \\    DOM.после_кадра(имя, "")
        \\конец
        \\
        \\функ старт() -> Пусто
        \\    запланировать("кадр")
        \\конец
    ;
    const wasm_bytes = try buildGraphBytes(allocator, source);
    defer allocator.free(wasm_bytes);

    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "@arena_impl_кадр") != null);
}

test "DOM.через_мс keeps its named callback reachable" {
    const allocator = std.testing.allocator;

    const source =
        \\импорт DOM
        \\
        \\функ таймер() -> Пусто
        \\конец
        \\
        \\функ старт() -> Пусто
        \\    DOM.через_мс("таймер", 100)
        \\конец
    ;
    const wasm_bytes = try buildGraphBytes(allocator, source);
    defer allocator.free(wasm_bytes);

    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "dom_after_delay") != null);
    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "@arena_impl_таймер") != null);
}

test "DOM.на_клик promotes a captured local closure and its environment" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const source =
        \\импорт DOM
        \\
        \\функ старт() -> Пусто
        \\    пер основа: Число = 41.0
        \\    пер вычислить = функ() -> Число основа + 1.0 конец
        \\    DOM.на_клик("#кнопка", функ(_: DOM.СобытиеКлика) -> Пусто
        \\        DOM.установить_текст("#результат", вычислить())
        \\    конец)
        \\конец
    ;
    const wasm_bytes = try buildGraphBytes(allocator, source);
    defer allocator.free(wasm_bytes);

    const wasm_path = "zzz_aot_closure_captures_closure.wasm";
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = wasm_path, .data = wasm_bytes });
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};

    const script =
        \\const fs = require("fs");
        \\(async () => {
        \\  let handler = 0;
        \\  let observed = 0;
        \\  const bytes = fs.readFileSync(process.argv[1]);
        \\  const imports = { env: {
        \\    dom_on_click: (_selector, box) => { handler = box; },
        \\    dom_set_text_num: (_selector, value) => { observed = value; },
        \\  } };
        \\  const { instance } = await WebAssembly.instantiate(bytes, imports);
        \\  instance.exports["старт"]();
        \\  instance.exports["@invoke_click"](handler, 0, 0, 0, 0, 0, 0, 0);
        \\  if (observed !== 42) throw new Error(`expected 42, got ${observed}`);
        \\  process.stdout.write(String(observed));
        \\})().catch((error) => { console.error(error); process.exit(1); });
    ;
    const result = try std.process.run(allocator, io.io(), .{
        .argv = &.{ "node", "-e", script, wasm_path },
        .expand_arg0 = .expand,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("42", result.stdout);
}

test "DOM.на_клик forwards MouseEvent fields through DOM.СобытиеКлика across arena resets" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const source =
        \\импорт DOM
        \\
        \\функ старт() -> Пусто
        \\    DOM.на_клик("#кнопка", функ(событие: DOM.СобытиеКлика) -> Пусто
        \\        пер сумма: Число = событие.клиент_x + событие.клиент_y + (событие.кнопка как Число)
        \\        если событие.ctrl тогда
        \\            сумма = сумма + 1.0
        \\        конец
        \\        если событие.shift тогда
        \\            сумма = сумма + 1.0
        \\        конец
        \\        если событие.alt тогда
        \\            сумма = сумма + 1.0
        \\        конец
        \\        если событие.meta тогда
        \\            сумма = сумма + 1.0
        \\        конец
        \\        DOM.установить_текст("#результат", сумма)
        \\    конец)
        \\конец
    ;
    const wasm_bytes = try buildGraphBytes(allocator, source);
    defer allocator.free(wasm_bytes);

    const wasm_path = "zzz_aot_click_event_fields.wasm";
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = wasm_path, .data = wasm_bytes });
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};

    const script =
        \\const fs = require("fs");
        \\(async () => {
        \\  let handler = 0;
        \\  let observed = 0;
        \\  const bytes = fs.readFileSync(process.argv[1]);
        \\  const imports = { env: {
        \\    dom_on_click: (_selector, box) => { handler = box; },
        \\    dom_set_text_num: (_selector, value) => { observed = value; },
        \\  } };
        \\  const { instance } = await WebAssembly.instantiate(bytes, imports);
        \\  instance.exports["старт"]();
        \\  instance.exports["@invoke_click"](handler, 10.5, 20.25, 2, 1, 0, 1, 1);
        \\  if (observed !== 35.75) throw new Error(`expected 35.75, got ${observed}`);
        \\  instance.exports["@invoke_click"](handler, 1, 2, 0, 0, 1, 0, 0);
        \\  if (observed !== 4) throw new Error(`expected 4, got ${observed}`);
        \\  process.stdout.write(String(observed));
        \\})().catch((error) => { console.error(error); process.exit(1); });
    ;
    const result = try std.process.run(allocator, io.io(), .{
        .argv = &.{ "node", "-e", script, wasm_path },
        .expand_arg0 = .expand,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("4", result.stdout);
}

test "DOM.на_клик capturing a Строка directly promotes it via @promote_to_permanent (Stage C)" {
    const allocator = std.testing.allocator;

    const source =
        \\импорт DOM
        \\
        \\функ старт() -> Пусто
        \\пер текст: Строка = "привет"
        \\DOM.на_клик("#кнопка", функ(_: DOM.СобытиеКлика) -> Пусто
        \\    DOM.установить_текст_строка("#результат", текст)
        \\конец)
        \\конец
    ;
    const wasm_bytes = try buildGraphBytes(allocator, source);
    defer allocator.free(wasm_bytes);

    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "@promote_to_permanent") != null);
}

test "DOM.на_клик capturing a struct with a Строка field promotes the field too (Stage C)" {
    const allocator = std.testing.allocator;

    const source =
        \\импорт DOM
        \\
        \\тип Задача = структура
        \\    id:    Число
        \\    текст: Строка
        \\конец
        \\
        \\функ старт() -> Пусто
        \\пер задача: Задача = Задача(7.0, "купить хлеб")
        \\DOM.на_клик("#кнопка", функ(_: DOM.СобытиеКлика) -> Пусто
        \\    DOM.установить_текст_строка("#результат", задача.текст)
        \\конец)
        \\конец
    ;
    const wasm_bytes = try buildGraphBytes(allocator, source);
    defer allocator.free(wasm_bytes);

    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "@runtime_alloc_permanent") != null);
    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "@promote_to_permanent") != null);
}

test "DOM.на_клик promotes a concrete generic struct capture" {
    const allocator = std.testing.allocator;

    const source =
        \\импорт DOM
        \\
        \\тип Коробка[T] = структура
        \\    значение: T
        \\конец
        \\
        \\функ старт() -> Пусто
        \\    пер коробка: Коробка(Строка) = Коробка("купить хлеб")
        \\    DOM.на_клик("#кнопка", функ(_: DOM.СобытиеКлика) -> Пусто
        \\        DOM.установить_текст_строка("#результат", коробка.значение)
        \\    конец)
        \\конец
    ;
    const wasm_bytes = try buildGraphBytes(allocator, source);
    defer allocator.free(wasm_bytes);

    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "@promote_to_permanent") != null);
}

// `Обёртка[T]{ внутри: Коробка(T) }` — the FIELD's declared type is itself
// a generic nominal built from the struct's OWN type parameter (`Коробка[T]`,
// not a bare `T`). Substituting `Обёртка(Строка)`'s concrete argument for
// `T` inside `внутри`'s declared type (`Коробка[T]`) requires rewriting the
// nested nominal's OWN argument list — the exact gap `concreteCaptureFieldType`'s
// new `.nominal` branch closes. A struct field simply typed `значение: T`
// (as in the single-level `Коробка[T]` fixture above) resolves through a
// chain of already-supported bare-placeholder substitutions and does not
// exercise this path at all.
test "DOM.на_клик promotes a struct field whose declared type nests the struct's own type parameter" {
    const allocator = std.testing.allocator;

    const source =
        \\импорт DOM
        \\
        \\тип Коробка[T] = структура
        \\    значение: T
        \\конец
        \\тип Обёртка[T] = структура
        \\    внутри: Коробка(T)
        \\конец
        \\
        \\функ старт() -> Пусто
        \\    пер обёртка: Обёртка(Строка) = Обёртка(Коробка("купить хлеб"))
        \\    DOM.на_клик("#кнопка", функ(_: DOM.СобытиеКлика) -> Пусто
        \\        DOM.установить_текст_строка("#результат", обёртка.внутри.значение)
        \\    конец)
        \\конец
    ;
    const wasm_bytes = try buildGraphBytes(allocator, source);
    defer allocator.free(wasm_bytes);

    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "@promote_to_permanent") != null);
}

// A genuinely unresolvable case (the closure's own generic function never
// concretely bound at compile time) was attempted here and dropped: every
// constructed fixture where `показать[T]`'s closure was actually reachable
// from `старт()` type-checked and lowered successfully even before this
// fix's `.nominal` branch existed, meaning `concreteCaptureFieldType`'s
// existing bare-`generic_parameter` substitution already covers whatever
// path the checker/lowering pipeline currently reaches for a reachable
// generic function — no reachable fixture reproduces the `null`-return
// (rejection) branch added above. Left unverified rather than asserting
// unconfirmed behavior; see spec.md's Edge Cases note that arbitrary depth
// is a bonus, not a hard requirement.

test "DOM.на_клик recursively promotes a nested struct capture" {
    const allocator = std.testing.allocator;

    const source =
        \\импорт DOM
        \\
        \\тип Подробности = структура
        \\    текст: Строка
        \\конец
        \\тип Задача = структура
        \\    подробности: Подробности
        \\конец
        \\
        \\функ старт() -> Пусто
        \\    пер задача = Задача(Подробности("купить хлеб"))
        \\    DOM.на_клик("#кнопка", функ(_: DOM.СобытиеКлика) -> Пусто
        \\        DOM.установить_текст_строка("#результат", задача.подробности.текст)
        \\    конец)
        \\конец
    ;
    const wasm_bytes = try buildGraphBytes(allocator, source);
    defer allocator.free(wasm_bytes);

    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "@runtime_alloc_permanent") != null);
    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "@promote_to_permanent") != null);
}

test "DOM.на_клик recursively promotes an array capture" {
    const allocator = std.testing.allocator;

    const source =
        \\импорт DOM
        \\
        \\функ старт() -> Пусто
        \\    пер задачи: Массив(Строка) = массив("первая", "вторая")
        \\    DOM.на_клик("#кнопка", функ(_: DOM.СобытиеКлика) -> Пусто
        \\        DOM.установить_текст_строка("#результат", задачи[1.0])
        \\    конец)
        \\конец
    ;
    const wasm_bytes = try buildGraphBytes(allocator, source);
    defer allocator.free(wasm_bytes);

    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "@runtime_alloc_permanent") != null);
    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "@promote_to_permanent") != null);
}

test "DOM.на_клик rejects a closure stored inside a captured aggregate" {
    const allocator = std.testing.allocator;

    const source =
        \\импорт DOM
        \\
        \\тип Коробка = структура
        \\    действие: функ() -> Число
        \\конец
        \\
        \\функ старт() -> Пусто
        \\    пер коробка = Коробка(функ() -> Число 7.0 конец)
        \\    DOM.на_клик("#кнопка", функ(_: DOM.СобытиеКлика) -> Пусто
        \\        коробка.действие()
        \\    конец)
        \\конец
    ;

    try std.testing.expectError(error.AotUnsupported, buildGraphBytes(allocator, source));
}

// `себя()` (self-reference to the CURRENTLY RUNNING process's own frame)
// outside any suspending context — this fixture's `старт()` never calls
// `получить()`, so it's not actor-CPS-rewritten at all. `specs/016-
// actor-dom-persistence/`'s fix (promoting `Процесс` captures, see the
// tests below) targets a `запусти`-spawned child specifically; this
// fixture exercises a DIFFERENT, degenerate shape (no real actor
// context) — kept as its own regression rather than assumed to behave
// like the spawn case.
test "DOM.на_клик with a себя() capture outside any suspending старт() reports a clear diagnostic" {
    const allocator = std.testing.allocator;

    const source =
        \\импорт DOM
        \\
        \\функ зарегистрировать(proc: Процесс(Число)) -> Пусто
        \\    DOM.на_клик("#кнопка", функ(_: DOM.СобытиеКлика) -> Пусто
        \\        отправить(proc, 1.0)
        \\    конец)
        \\конец
        \\
        \\функ старт() -> Пусто
        \\    зарегистрировать(себя())
        \\конец
    ;

    // `mir_lowering.zig`'s own capture check no longer rejects this
    // (see `specs/016-actor-dom-persistence/` — `Процесс` captures are
    // no longer blanket-unsupported) — this degenerate shape (no real
    // actor context) now falls through further, to `wasm_emit.zig`,
    // which fails to find a known host-import signature for `себя()`'s
    // lowered call. Still a hard compile-time rejection, not silent
    // corruption — just a different stage/error type than before.
    try std.testing.expectError(error.WasmEmitUnsupported, buildGraphBytes(allocator, source));
}

// specs/016-actor-dom-persistence — real, standalone bug found and fixed
// while building this feature (`wasm_actors.zig`'s `rewireSuspendCalls`):
// `is_i32`/`call.dst.?` used to be computed UNCONDITIONALLY for every
// `.call_builtin` inside a CPS-suspending function, before checking
// whether the callee name was even one of the 4 relevant suspend
// builtins — a guaranteed null-deref for any OTHER void call_builtin
// (like `DOM.на_клик(...)`) sharing a suspending function's body. No
// prior fixture combined "CPS-suspending function" with "an unrelated
// void call_builtin in the same body" — this is the first one that does
// (`старт()` awaits its own spawn reply, THEN registers a DOM handler).
test "DOM.на_клик promotes a запусти-spawned actor, старт() itself already suspended once via получить()" {
    const allocator = std.testing.allocator;

    const source =
        \\импорт DOM
        \\
        \\тип Ответ = перечисление
        \\    Значение(Число)
        \\конец
        \\
        \\тип Сообщение = перечисление
        \\    Увеличить(Число, Процесс(Ответ))
        \\    УвеличитьТихо(Число)
        \\конец
        \\
        \\функ счётчик(состояние: Число) -> Пусто
        \\    выбор получить()
        \\        Сообщение.Увеличить(шаг, отвечающему) тогда
        \\            пер новое = состояние + шаг
        \\            отправить(отвечающему, Ответ.Значение(новое))
        \\            счётчик(новое)
        \\        конец
        \\        Сообщение.УвеличитьТихо(шаг) тогда
        \\            счётчик(состояние + шаг)
        \\        конец
        \\    конец
        \\конец
        \\
        \\функ старт() -> Пусто
        \\    пер proc: Процесс(Сообщение) = запусти счётчик(0.0)
        \\    отправить(proc, Сообщение.Увеличить(1.0, себя()))
        \\    выбор получить()
        \\        Ответ.Значение(x) -> DOM.на_клик("#кнопка", функ(_: DOM.СобытиеКлика) -> Пусто
        \\            отправить(proc, Сообщение.УвеличитьТихо(x))
        \\        конец)
        \\    конец
        \\конец
    ;
    const wasm_bytes = try buildGraphBytes(allocator, source);
    defer allocator.free(wasm_bytes);

    try std.testing.expect(std.mem.indexOf(u8, wasm_bytes, "@invoke_click") != null);
}

// specs/016-actor-dom-persistence — User Story 2: `отправить` called
// from INSIDE a DOM handler (after `старт()` has already returned) now
// actually drives the target actor's step function
// (`emitSendRoundDriving`), so the message is genuinely PROCESSED
// before the handler returns, instead of just sitting enqueued. Observed
// here through a REAL side effect the actor produces upon receiving the
// message (`DOM.установить_текст`) — not through the handler awaiting a
// reply itself (the handler is not a suspending actor; only `старт()`/
// the spawned actor are, per Phase-1's own constraint).
test "DOM.на_клик's отправить() actually drives the actor to process the message, not just enqueue it" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const source =
        \\импорт DOM
        \\
        \\тип Ответ = перечисление
        \\    Значение(Число)
        \\конец
        \\
        \\тип Сообщение = перечисление
        \\    Увеличить(Число, Процесс(Ответ))
        \\    УвеличитьИПоказать(Число)
        \\конец
        \\
        \\функ счётчик(состояние: Число) -> Пусто
        \\    выбор получить()
        \\        Сообщение.Увеличить(шаг, отвечающему) тогда
        \\            пер новое = состояние + шаг
        \\            отправить(отвечающему, Ответ.Значение(новое))
        \\            счётчик(новое)
        \\        конец
        \\        Сообщение.УвеличитьИПоказать(шаг) тогда
        \\            пер новое = состояние + шаг
        \\            DOM.установить_текст("#результат", новое)
        \\            счётчик(новое)
        \\        конец
        \\    конец
        \\конец
        \\
        \\функ старт() -> Пусто
        \\    пер proc: Процесс(Сообщение) = запусти счётчик(0.0)
        \\    отправить(proc, Сообщение.Увеличить(1.0, себя()))
        \\    выбор получить()
        \\        Ответ.Значение(x) -> DOM.на_клик("#кнопка", функ(_: DOM.СобытиеКлика) -> Пусто
        \\            отправить(proc, Сообщение.УвеличитьИПоказать(1.0))
        \\        конец)
        \\    конец
        \\конец
    ;
    const wasm_bytes = try buildGraphBytes(allocator, source);
    defer allocator.free(wasm_bytes);

    const wasm_path = "zzz_aot_actor_dom_send_drives_rounds.wasm";
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = wasm_path, .data = wasm_bytes });
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};

    const script =
        \\const fs = require("fs");
        \\(async () => {
        \\  let handler = 0;
        \\  let observed = null;
        \\  const bytes = fs.readFileSync(process.argv[1]);
        \\  const imports = { env: {
        \\    dom_on_click: (_selector, box) => { handler = box; },
        \\    dom_set_text_num: (_selector, value) => { observed = value; },
        \\  } };
        \\  const { instance } = await WebAssembly.instantiate(bytes, imports);
        \\  instance.exports["старт"]();
        \\  if (handler === 0) throw new Error("handler was never registered");
        \\  if (observed !== null) throw new Error(`observed set before any click: ${observed}`);
        \\  instance.exports["@invoke_click"](handler, 0, 0, 0, 0, 0, 0, 0);
        \\  if (observed !== 2) throw new Error(`expected 2 after one click, got ${observed}`);
        \\  process.stdout.write(String(observed));
        \\})().catch((error) => { console.error(error); process.exit(1); });
    ;
    const result = try std.process.run(allocator, io.io(), .{
        .argv = &.{ "node", "-e", script, wasm_path },
        .expand_arg0 = .expand,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("2", result.stdout);
}

// До этой правки `DOM.на_клик` требовал, чтобы второй аргумент был
// ЛИТЕРАЛЬНЫМ `.lambda`-выражением непосредственно на месте вызова
// (`lowerDomClickClosure`) — обработчик, пришедший ИЗДАЛЕКА (параметр,
// поле структуры, элемент Опция), падал компиляцией. Настоящий фикс —
// promoteClosureBoxToPermanent теперь вызывается УНИВЕРСАЛЬНО при
// ПОСТРОЕНИИ любого замыкания (`lowerLambda`/`lowerSymbolValueRef`), не
// только для литерала прямо в DOM.на_клик — так что к моменту, когда
// хендлер, прошедший через Опция(функ(...)->Пусто) поле структуры,
// понижается здесь, он уже лежит в постоянной памяти, откуда бы ни
// пришёл. Тест — реальный марьяшка-паттерн (обычная именованная
// функция, обёрнутая в Опция.Есть, извлечённая через выбор/Есть,
// переданная в DOM.на_клик), проверенный через РЕАЛЬНЫЙ сброс арены
// (`@invoke_click` вызван ОТДЕЛЬНО от старт(), как и остальные тесты
// этого файла).
test "DOM.на_клик accepts a handler stored in a struct field's Опция, not just a lambda literal" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const source =
        \\импорт DOM
        \\
        \\тип Узел = структура
        \\    обработчик: Опция(функ(DOM.СобытиеКлика) -> Пусто)
        \\конец
        \\
        \\функ мой_обработчик(_: DOM.СобытиеКлика) -> Пусто
        \\    DOM.установить_текст("#результат", 42.0)
        \\конец
        \\
        \\функ монтировать(у: Узел) -> Пусто
        \\    выбор у.обработчик
        \\        Есть(обработчик) тогда
        \\            DOM.на_клик("#кнопка", обработчик)
        \\        конец
        \\        Нет тогда
        \\        конец
        \\    конец
        \\конец
        \\
        \\функ старт() -> Пусто
        \\    монтировать(Узел(Опция.Есть(мой_обработчик)))
        \\конец
    ;
    const wasm_bytes = try buildGraphBytes(allocator, source);
    defer allocator.free(wasm_bytes);

    const wasm_path = "zzz_aot_closure_via_option_field.wasm";
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = wasm_path, .data = wasm_bytes });
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};

    const script =
        \\const fs = require("fs");
        \\(async () => {
        \\  let handler = 0;
        \\  let observed = 0;
        \\  const bytes = fs.readFileSync(process.argv[1]);
        \\  const imports = { env: {
        \\    dom_on_click: (_selector, box) => { handler = box; },
        \\    dom_set_text_num: (_selector, value) => { observed = value; },
        \\  } };
        \\  const { instance } = await WebAssembly.instantiate(bytes, imports);
        \\  instance.exports["старт"]();
        \\  if (handler === 0) throw new Error("handler was never registered");
        \\  instance.exports["@invoke_click"](handler, 0, 0, 0, 0, 0, 0, 0);
        \\  if (observed !== 42) throw new Error(`expected 42, got ${observed}`);
        \\  process.stdout.write(String(observed));
        \\})().catch((error) => { console.error(error); process.exit(1); });
    ;
    const result = try std.process.run(allocator, io.io(), .{
        .argv = &.{ "node", "-e", script, wasm_path },
        .expand_arg0 = .expand,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("42", result.stdout);
}

// Верхнеуровневая `конст` компилируется ПОДСТАНОВКОЙ на месте
// использования (см. `compiler.zig`'s `predeclareConstants` —
// байткод-путь) — у AOT-пути раньше не было параллельной логики
// вообще, и ЛЮБАЯ ссылка на такую константу как на обычное значение
// (не в тривиальном контексте, который typechecker мог развернуть
// иначе) падала в `lowerSymbolValueRef`'s catch-all с "символ не
// является локалью или функцией". Найдено при разработке
// panosiki/марьяшка (константа, переданная аргументом функции).
test "a top-level конст referenced as a function argument lowers correctly under AOT WASM" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const source =
        \\экспорт конст ШИРИНА = 21.0
        \\
        \\функ удвоить(x: Число) -> Число
        \\x * 2.0
        \\конец
        \\
        \\функ старт() -> Число
        \\удвоить(ШИРИНА)
        \\конец
    ;
    const wasm_path = "zzz_aot_toplevel_const_as_arg.wasm";
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};
    const result = try buildAndRun(allocator, io.io(), source, wasm_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("42\n", result.stdout);
}

// `wasm_gc_arena.zig`'s `wrapEntryPoint` (arena-checkpoint wrapper for
// `старт`/`@invoke_click`) read `local.type_id` off the ORIGINAL
// function's locals but then set the NEW wrapper function's OWN
// `type_store` to the caller-supplied `type_store` argument — always
// the ENTRY module's store in every real caller. For `DOM.на_клик`
// declared inside an IMPORTED library (not the entry file), `@invoke_click`
// itself was built (`findOrBuildInvokeClickTrampoline`) against the
// LIBRARY's own `TypeStore` — a DIFFERENT instance. `TypeId`s are only
// meaningful relative to the store that minted them; reading them
// against the wrong store silently mis-mapped `Целое`/`Булево` params
// to the WASM `f64` fallback. Confirmed with `wasm2wat`: the wrapper
// ended up `(param f64 f64 f64 f64 f64 f64 f64 f64)` instead of the
// real `(i32 f64 f64 i32 i32 i32 i32 i32)` — a module that fails to
// even INSTANTIATE in a real engine (`panos build`'s own success
// doesn't validate this — confirmed the bug only by actually loading
// the module with `WebAssembly.Module()`). Fixed by preferring
// `original.type_store` (set once, per-function, when each function
// was originally lowered) over the caller-supplied fallback.
fn buildGraphBytesMulti(allocator: std.mem.Allocator, entry_source: []const u8, library_path: []const u8, library_source: []const u8) ![]u8 {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "программа.ps", .bytes = entry_source },
        .{ .path = library_path, .bytes = library_source },
    } };
    var graph = panos.module_loader.Graph.init(allocator);
    defer graph.deinit();
    try graph.load(&reader, "программа");
    _ = try graph.appendPreludeModule(panos.prelude.SOURCE);
    try std.testing.expectEqual(@as(usize, 0), graph.diagnostics.items.items.len);

    var compiled = try panos.module_compiler.compileGraphForTarget(allocator, &graph, .aot_js_wasm);
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var module = try panos.mir_lowering.lowerGraph(allocator, &graph, &compiled);
    defer module.deinit(allocator);

    const type_store = &compiled.modules[0].checked.?.types;
    try panos.wasm_objects.expand(allocator, &module, type_store);
    try panos.wasm_strings.expand(allocator, &module, type_store);
    try panos.wasm_maps.expand(allocator, &module, type_store);
    const iface_result = try panos.wasm_interfaces.expand(allocator, &module, type_store);
    defer allocator.free(iface_result.table);
    var frame_info = try panos.mir_cps.prepare(allocator, &module);
    defer frame_info.deinit();
    try panos.wasm_actors.expand(allocator, &module, type_store, &frame_info);
    try panos.wasm_gc_arena.expand(allocator, &module, type_store);

    return panos.wasm_emit.emitModule(allocator, &compiled.modules[0].checked.?, &module, iface_result.table);
}

test "DOM.на_клик declared in an IMPORTED (non-entry) module produces a valid, instantiable module" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const library_source =
        \\импорт DOM
        \\
        \\экспорт функ подключить(селектор: Строка, обработчик: функ(DOM.СобытиеКлика) -> Пусто) -> Пусто
        \\    DOM.на_клик(селектор, обработчик)
        \\конец
    ;
    const entry_source =
        \\импорт "библиотека.ps" как библиотека
        \\импорт DOM
        \\
        \\функ обработчик(событие: DOM.СобытиеКлика) -> Пусто
        \\    пер сумма: Число = событие.клиент_x + событие.клиент_y
        \\    DOM.установить_текст("#результат", сумма)
        \\конец
        \\
        \\функ старт() -> Пусто
        \\    библиотека.подключить("#кнопка", обработчик)
        \\конец
    ;
    const wasm_bytes = try buildGraphBytesMulti(allocator, entry_source, "библиотека.ps", library_source);
    defer allocator.free(wasm_bytes);

    const wasm_path = "zzz_aot_click_in_library_module.wasm";
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = wasm_path, .data = wasm_bytes });
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};

    const script =
        \\const fs = require("fs");
        \\(async () => {
        \\  let handler = 0;
        \\  let observed = 0;
        \\  const bytes = fs.readFileSync(process.argv[1]);
        \\  const imports = { env: {
        \\    dom_on_click: (_selector, box) => { handler = box; },
        \\    dom_set_text_num: (_selector, value) => { observed = value; },
        \\  } };
        \\  const { instance } = await WebAssembly.instantiate(bytes, imports);
        \\  instance.exports["старт"]();
        \\  if (handler === 0) throw new Error("handler was never registered");
        \\  instance.exports["@invoke_click"](handler, 10.5, 20.25, 2, 1, 0, 1, 1);
        \\  if (observed !== 30.75) throw new Error(`expected 30.75, got ${observed}`);
        \\  process.stdout.write(String(observed));
        \\})().catch((error) => { console.error(error); process.exit(1); });
    ;
    const result = try std.process.run(allocator, io.io(), .{
        .argv = &.{ "node", "-e", script, wasm_path },
        .expand_arg0 = .expand,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("30.75", result.stdout);
}

// `lowerCall`'s `.property`-callee branch (qualified call, `модуль.
// Имя(...)`) checked `symbol_to_function` and `lowerEnumConstructor`
// but never `lowerStructConstructor` — unlike the `.ident`-callee
// branch just above it, which DOES call all three. Any qualified
// struct constructor call from a DIFFERENT file than the one declaring
// the struct (`библиотека.Тип(a, b, c)`) fell through every branch to
// the generic `lowerExpr(call.callee)` catch-all, which sees a bare
// unconsumed property expression and rejects it. Found while building
// panosiki/марьяшка (a serializer constructing a struct type directly,
// not only through the declaring module's own wrapper functions).
test "a qualified struct constructor call from another module lowers correctly" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const library_source =
        \\экспорт тип Точка = структура
        \\    x: Число
        \\    y: Число
        \\конец
    ;
    const entry_source =
        \\импорт "библиотека.ps" как библиотека
        \\
        \\функ старт() -> Число
        \\    пер р = библиотека.Точка(3.0, 4.0)
        \\    р.x + р.y
        \\конец
    ;
    const wasm_bytes = try buildGraphBytesMulti(allocator, entry_source, "библиотека.ps", library_source);
    defer allocator.free(wasm_bytes);

    const wasm_path = "zzz_aot_qualified_struct_ctor.wasm";
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = wasm_path, .data = wasm_bytes });
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};

    const result = try wasmtimeInvoke(allocator, io.io(), wasm_path, "старт");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("7\n", result.stdout);
}

test "a payload-less custom enum variant lowers correctly outside call position" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const entry_source =
        \\тип Msg = перечисление
        \\    Иди
        \\    Стой
        \\конец
        \\
        \\функ метка(m: Msg) -> Число
        \\    выбор m
        \\        Иди тогда 1.0 конец
        \\        Стой тогда 0.0 конец
        \\    конец
        \\конец
        \\
        \\функ старт() -> Число
        \\    метка(Msg.Иди)
        \\конец
    ;
    const wasm_bytes = try buildGraphBytes(allocator, entry_source);
    defer allocator.free(wasm_bytes);

    const wasm_path = "zzz_aot_payloadless_enum_variant.wasm";
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = wasm_path, .data = wasm_bytes });
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};

    const result = try wasmtimeInvoke(allocator, io.io(), wasm_path, "старт");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("1\n", result.stdout);
}

test "a tuple literal, field access, and an array of tuples lower correctly" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const entry_source =
        \\функ старт() -> Число
        \\    пер t = ("a", 3.0)
        \\    пер массив_пар = массив(("x", 1.0), ("y", 2.0))
        \\    t.1 + массив_пар[0].1 + массив_пар[1].1
        \\конец
    ;
    const wasm_bytes = try buildGraphBytes(allocator, entry_source);
    defer allocator.free(wasm_bytes);

    const wasm_path = "zzz_aot_tuple_literal.wasm";
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = wasm_path, .data = wasm_bytes });
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};

    const result = try wasmtimeInvoke(allocator, io.io(), wasm_path, "старт");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("6\n", result.stdout);
}

// `Соответствие` под AOT WASM — строго строковые ключи (см.
// `wasm_maps.zig` doc-комментарий). Покрывает: литерал с начальными
// записями, `[]=` вставка И перезапись существующего ключа (разные
// пути в `@map_set_*`), `.получить(key, default)` для присутствующего
// и отсутствующего ключа, `.есть()`, `.длина()`.
test "Соответствие literal, []= insert/overwrite, .получить/.есть/.длина all work under AOT WASM" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const entry_source =
        \\функ старт() -> Число
        \\    пер м: Соответствие(Строка, Число) = соответствие("исходный" = 1.0)
        \\    м["a"] = 10.0
        \\    м["b"] = 20.0
        \\    м["a"] = 99.0
        \\    пер сумма = м.получить("исходный", 0.0) + м.получить("a", 0.0) + м.получить("b", 0.0) + м.получить("отсутствует", 5.0)
        \\    пер флаги = (если м.есть("a") тогда 100.0 иначе 0.0 конец) + (если м.есть("z") тогда 0.0 иначе 1000.0 конец)
        \\    сумма + флаги + (м.длина() как Число)
        \\конец
    ;
    const wasm_bytes = try buildGraphBytes(allocator, entry_source);
    defer allocator.free(wasm_bytes);

    const wasm_path = "zzz_aot_map_basic.wasm";
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = wasm_path, .data = wasm_bytes });
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};

    const result = try wasmtimeInvoke(allocator, io.io(), wasm_path, "старт");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    // сумма = 1 + 99 + 20 + 5 = 125; флаги = 100 + 1000 = 1100; длина = 3
    try std.testing.expectEqualStrings("1228\n", result.stdout);
}

// `.записи()` — реальный найденный баг (не гипотетический): в первой
// версии `@map_entries` `array_runtime.append_i32`'s аргументы
// (`arr`, `pair`) оказывались произведены в порядке, обратном списку
// аргументов `.call` — append писал в перепутанные значения, итоговый
// массив оставался пустым при непустой карте. Регресс специально
// проверяет и КОЛИЧЕСТВО записей, и извлечение конкретного значения по
// ключу через `.0`/`.1`, не только длину (длина одна могла бы
// случайно совпасть при другом классе бага).
test "Соответствие.записи() returns real (key, value) tuples, not an empty array" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const entry_source =
        \\функ старт() -> Число
        \\    пер м: Соответствие(Строка, Число) = соответствие()
        \\    м["x"] = 7.0
        \\    м["y"] = 13.0
        \\    пер записи = м.записи()
        \\    пер сумма_значений = 0.0
        \\    пер i: Целое = 0
        \\    пока i < записи.длина() цикл
        \\        сумма_значений = сумма_значений + записи[i].1
        \\        i = i + 1
        \\    конец
        \\    (записи.длина() как Число) + сумма_значений
        \\конец
    ;
    const wasm_bytes = try buildGraphBytes(allocator, entry_source);
    defer allocator.free(wasm_bytes);

    const wasm_path = "zzz_aot_map_entries.wasm";
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = wasm_path, .data = wasm_bytes });
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};

    const result = try wasmtimeInvoke(allocator, io.io(), wasm_path, "старт");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    // длина=2, сумма=7+13=20 -> 22
    try std.testing.expectEqualStrings("22\n", result.stdout);
}

// Реальный найденный баг: `lowerWhile` понижало `loop.condition` через
// общий `lowerExpr`+`.branch`, а не через `lowerCondition` — короткое
// замыкание `и`/`или` (`lowerShortCircuit`) строит СОБСТВЕННЫЙ
// `merge_block`, материализующий bool через Local; итоговый `.branch`
// цикла оказывался эмитирован в ЭТОТ чужой блок, а не в
// `header_block` (единственную законную цель обратного ребра) —
// `wasm_stackify.zig` не находил `header_block` среди открытых loop-
// scope ("br-цель не найдена"). Минимальный репро — `и` НАПРЯМУЮ как
// условие `пока`, без продолжить/структур/строк.
test "пока X и Y цикл — short-circuit AND directly as a while condition lowers correctly" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const entry_source =
        \\функ старт() -> Число
        \\    пер поз: Целое = 0
        \\    пока поз < 10 и поз < 100 цикл
        \\        поз = поз + 1
        \\    конец
        \\    поз как Число
        \\конец
    ;
    const wasm_bytes = try buildGraphBytes(allocator, entry_source);
    defer allocator.free(wasm_bytes);

    const wasm_path = "zzz_aot_while_short_circuit.wasm";
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = wasm_path, .data = wasm_bytes });
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};

    const result = try wasmtimeInvoke(allocator, io.io(), wasm_path, "старт");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("10\n", result.stdout);
}

// Реальный найденный баг: `Строка[i]` (индекс по руне) шло через общий
// `.get_index` MIR, который `wasm_objects.zig` ВСЕГДА раскрывает как
// array-get (`array_runtime`, числовой слот×8 байт) — для строки
// (заголовок `[len][UTF-8 байты]`, совсем другая раскладка) это молча
// читало мусор по неверному адресу вместо настоящего символа, никогда
// не падая на валидации (оба типа — просто i32 с точки зрения WASM).
// Никогда не ловилось раньше, потому что предыдущие тесты проверяли
// только УСПЕШНУЮ СБОРКУ строковых индексных выражений, не их
// РЕЗУЛЬТАТ.
test "Строка[i] (доступ к руне по индексу) возвращает настоящий символ, не мусор" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const entry_source =
        \\функ старт() -> Число
        \\    пер текст = "ab"
        \\    если текст[0] == "a" тогда
        \\        1.0
        \\    иначе
        \\        0.0
        \\    конец
        \\конец
    ;
    const wasm_bytes = try buildGraphBytes(allocator, entry_source);
    defer allocator.free(wasm_bytes);

    const wasm_path = "zzz_aot_string_index.wasm";
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = wasm_path, .data = wasm_bytes });
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};

    const result = try wasmtimeInvoke(allocator, io.io(), wasm_path, "старт");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("1\n", result.stdout);
}

// Реальный найденный баг: `Ошибка` — `.primitive{.error_value}` в
// `types.zig`, НЕ `.nominal` — `wasmValTypeForStore` (`wasm_module.zig`)
// не ловила эту ветку вообще (switch по `.get(type_id)` не перечислял
// `.primitive`), молча проваливаясь в дефолтный `wasm_f64` вместо
// правильного `wasm_i32` (двухполевой аггрегат-хэндл, та же категория,
// что обычная структура). Проявлялось только в функциях, возвращающих
// `Результат(T, Ошибка)` с РАННИМ `возврат Результат.Неудача(...)`
// внутри `если` (без `иначе`), за которым следует что-то ЕЩЁ в том же
// блоке — "type mismatch: expected f64, found i32" при валидации
// wasmtime, не при сборке panos.
test "функция, возвращающая Результат(T, Ошибка) с ранним возвратом Неудача внутри если, лоуерится корректно" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const entry_source =
        \\функ f(x: Целое, e: Ошибка) -> Результат(Целое, Ошибка)
        \\    если x == 2 тогда
        \\        возврат Результат.Неудача(e)
        \\    конец
        \\    Результат.Успех(0)
        \\конец
        \\
        \\функ старт() -> Число
        \\    пер р = f(1, Ошибка("m", "e"))
        \\    если р.ошибка() тогда возврат 0.0 конец
        \\    1.0
        \\конец
    ;
    const wasm_bytes = try buildGraphBytes(allocator, entry_source);
    defer allocator.free(wasm_bytes);

    const wasm_path = "zzz_aot_error_value_type.wasm";
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = wasm_path, .data = wasm_bytes });
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};

    const result = try wasmtimeInvoke(allocator, io.io(), wasm_path, "старт");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("1\n", result.stdout);
}
