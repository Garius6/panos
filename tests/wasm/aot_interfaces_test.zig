const std = @import("std");
const panos = @import("panos_core");

// Verifies the WASM function-table (Table + Element sections) and
// `.call_indirect` codegen work correctly under plain wasmtime, in
// isolation from any interface-dispatch machinery — a hand-built MIR
// module (bypassing `mir_lowering.zig` entirely, same technique as
// `wasm_objects.zig`'s own hand-built runtime functions) with two
// candidate functions in the table and a `старт` that dispatches
// through a compile-time-constant table index. This is the foundation
// `wasm_interfaces.zig`'s real interface-cast/invoke expansion builds
// on top of.

fn wasmtimeInvoke(allocator: std.mem.Allocator, io: std.Io, wasm_path: []const u8, func: []const u8) !std.process.RunResult {
    return std.process.run(allocator, io, .{
        .argv = &.{ "wasmtime", "run", "--invoke", func, wasm_path },
        .expand_arg0 = .expand,
    });
}

fn buildDispatchModule(allocator: std.mem.Allocator, checked: *const panos.type_checker.CheckResult, table_index_const: u32) !panos.mir.Module {
    var module = panos.mir.Module.init(allocator);
    errdefer module.deinit(allocator);
    const number_type = checked.types.builtins.number;
    const idx_type = checked.types.builtins.boolean;
    const dummy_symbol: panos.symbols.SymbolId = @enumFromInt(0);
    const dummy_span: panos.source.Span = .{ .file_id = 0, .start = 0, .end = 0 };

    // func_a() -> Число: returns 1.0
    const func_a_id = try panos.mir_builder.newFunction(&module, allocator, "func_a", dummy_symbol, number_type, dummy_span);
    {
        var builder = try panos.mir_builder.Builder.beginFunction(&module, allocator, func_a_id);
        builder.currentFunction().parameters = &.{};
        builder.currentFunction().type_store = &checked.types;
        const one = try builder.newValue(number_type);
        try builder.emit(.{ .const_value = .{ .dst = one, .value = .{ .number = 1.0 } } });
        builder.terminate(.{ .return_value = .{ .value = one } });
    }

    // func_b() -> Число: returns 2.0
    const func_b_id = try panos.mir_builder.newFunction(&module, allocator, "func_b", dummy_symbol, number_type, dummy_span);
    {
        var builder = try panos.mir_builder.Builder.beginFunction(&module, allocator, func_b_id);
        builder.currentFunction().parameters = &.{};
        builder.currentFunction().type_store = &checked.types;
        const two = try builder.newValue(number_type);
        try builder.emit(.{ .const_value = .{ .dst = two, .value = .{ .number = 2.0 } } });
        builder.terminate(.{ .return_value = .{ .value = two } });
    }

    // старт() -> Число: dispatches through the table at a fixed index.
    const start_id = try panos.mir_builder.newFunction(&module, allocator, "старт", dummy_symbol, number_type, dummy_span);
    {
        var builder = try panos.mir_builder.Builder.beginFunction(&module, allocator, start_id);
        builder.currentFunction().parameters = &.{};
        builder.currentFunction().type_store = &checked.types;
        const table_index = try builder.newValue(idx_type);
        try builder.emit(.{ .const_value = .{ .dst = table_index, .value = .{ .address = table_index_const } } });
        const result = try builder.newValue(number_type);
        try builder.emit(.{ .call_indirect = .{ .dst = result, .table_index = table_index, .args = &.{} } });
        builder.terminate(.{ .return_value = .{ .value = result } });
    }

    return module;
}

test "call_indirect through a hand-built WASM function table dispatches to the correct implementation" {
    const allocator = std.testing.allocator;
    var io = std.Io.Threaded.init(allocator, .{ .environ = std.testing.environ });
    defer io.deinit();

    const source = "функ старт() -> Число\n0.0\nконец";
    var lexed = try panos.lexer.tokenize(allocator, source, 0);
    defer lexed.deinit();
    var parsed = try panos.parser.parse(allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try panos.resolver.resolve(allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try panos.type_checker.check(allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    const cases = [_]struct { table_index: u32, expected: []const u8, wasm_path: []const u8 }{
        .{ .table_index = 0, .expected = "1\n", .wasm_path = "zzz_aot_iface0.wasm" },
        .{ .table_index = 1, .expected = "2\n", .wasm_path = "zzz_aot_iface1.wasm" },
    };

    for (cases) |case| {
        var module = try buildDispatchModule(allocator, &checked, case.table_index);
        defer module.deinit(allocator);
        const func_a_id: panos.mir.FunctionId = @enumFromInt(0);
        const func_b_id: panos.mir.FunctionId = @enumFromInt(1);

        const wasm_bytes = try panos.wasm_emit.emitModule(allocator, &checked, &module, &.{ func_a_id, func_b_id });
        defer allocator.free(wasm_bytes);

        defer std.Io.Dir.cwd().deleteFile(io.io(), case.wasm_path) catch {};
        try std.Io.Dir.cwd().writeFile(io.io(), .{ .sub_path = case.wasm_path, .data = wasm_bytes });
        const result = try wasmtimeInvoke(allocator, io.io(), case.wasm_path, "старт");
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        try std.testing.expectEqualStrings(case.expected, result.stdout);
    }
}
