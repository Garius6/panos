const std = @import("std");
const panos = @import("panos_core");

fn wasmtimeInvoke(allocator: std.mem.Allocator, io: std.Io, wasm_path: []const u8, func: []const u8) !std.process.RunResult {
    return std.process.run(allocator, io, .{
        .argv = &.{ "wasmtime", "run", "--invoke", func, wasm_path },
        .expand_arg0 = .expand,
    });
}

test "actor request/reply round trip: spawn + 2-field variant message + reply, no host imports" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const source =
        \\тип Ответ = перечисление
        \\    Значение(Число)
        \\конец
        \\
        \\тип Сообщение = перечисление
        \\    Увеличить(Число, Процесс(Ответ))
        \\конец
        \\
        \\функ счётчик(состояние: Число) -> Пусто
        \\    выбор получить()
        \\        Сообщение.Увеличить(шаг, отвечающему) тогда
        \\            пер новое = состояние + шаг
        \\            отправить(отвечающему, Ответ.Значение(новое))
        \\            счётчик(новое)
        \\        конец
        \\    конец
        \\конец
        \\
        \\функ старт() -> Число
        \\    пер proc: Процесс(Сообщение) = запусти счётчик(0.0)
        \\    отправить(proc, Сообщение.Увеличить(1.0, себя()))
        \\    выбор получить()
        \\        Ответ.Значение(x) -> x
        \\    конец
        \\конец
    ;

    var lexed = try panos.lexer.tokenize(allocator, source, 0);
    defer lexed.deinit();
    var parsed = try panos.parser.parse(allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try panos.resolver.resolve(allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try panos.type_checker.check(allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    var module = try panos.mir_lowering.lowerModule(allocator, &parsed.ast, &resolved, &checked);
    defer module.deinit(allocator);

    try panos.wasm_objects.expand(allocator, &module, &checked.types);
    var frame_info = try panos.mir_cps.prepare(allocator, &module);
    defer frame_info.deinit();
    try panos.wasm_actors.expand(allocator, &module, &checked.types, &frame_info);

    {
        const mir_validate = @import("panos_core").mir_validate;
        for (module.functions.items) |*function| {
            const store = function.type_store orelse &checked.types;
            const issues = try mir_validate.validateFunction(allocator, &module, function, store.builtins.void);
            defer mir_validate.freeIssues(allocator, issues);
            for (issues) |issue| {
                if (!issue.is_error) continue;
                std.debug.print("VALIDATE {s} error={} : {s}\n", .{ function.name, issue.is_error, issue.message });
            }
        }
    }

    const wasm_bytes = try panos.wasm_emit.emitModule(allocator, &checked, &module, &.{});
    defer allocator.free(wasm_bytes);

    const wasm_path = "zzz_actors_test.wasm";
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = wasm_path, .data = wasm_bytes });
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};

    const result = try wasmtimeInvoke(allocator, io.io(), wasm_path, "старт");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    // счётчик(0.0) replies to Увеличить(1.0, ...) with Значение(0.0+1.0)
    try std.testing.expectEqualStrings("1\n", result.stdout);
}
