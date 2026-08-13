const std = @import("std");
const panos = @import("panos_core");

fn wasmtimeInvoke(allocator: std.mem.Allocator, io: std.Io, wasm_path: []const u8, func: []const u8) !std.process.RunResult {
    return std.process.run(allocator, io, .{
        .argv = &.{ "wasmtime", "run", "--invoke", func, wasm_path },
        .expand_arg0 = .expand,
    });
}

test "array object-table smoke: append + index + length + get_or, no host imports" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const source =
        \\функ старт() -> Число
        \\    пер числа = массив(10.0, 20.0)
        \\    числа[1] = 10.0
        \\    числа.добавить(12.0)
        \\    пер итог = 0.0
        \\    для i = 0 по числа.длина() - 1 цикл
        \\        итог = итог + числа.получить(i, 0.0)
        \\    конец
        \\    итог
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

    {
        const mir_validate = @import("panos_core").mir_validate;
        for (module.functions.items) |*function| {
            const store = function.type_store orelse &checked.types;
            const issues = try mir_validate.validateFunction(allocator, &module, function, store.builtins.void);
            defer mir_validate.freeIssues(allocator, issues);
            for (issues) |issue| {
                std.debug.print("VALIDATE {s} error={} : {s}\n", .{ function.name, issue.is_error, issue.message });
            }
        }
    }

    const wasm_bytes = try panos.wasm_emit.emitModule(allocator, &checked, &module);
    defer allocator.free(wasm_bytes);

    const wasm_path = "zzz_objects_test.wasm";
    try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = wasm_path, .data = wasm_bytes });
    defer std.Io.Dir.cwd().deleteFile(io.io(), wasm_path) catch {};

    const result = try wasmtimeInvoke(allocator, io.io(), wasm_path, "старт");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    // числа = [10.0, 10.0 (overwrite), 12.0 (append)], итог = sum == 32
    try std.testing.expectEqualStrings("32\n", result.stdout);
}
