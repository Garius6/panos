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
