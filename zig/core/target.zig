const std = @import("std");

pub const TargetProfile = enum {
    native,
    browser_interpreter,
    aot_js_wasm,
    aot_wasi,

    pub fn isBytecodeVm(self: TargetProfile) bool {
        return switch (self) {
            .native, .browser_interpreter => true,
            .aot_js_wasm, .aot_wasi => false,
        };
    }

    pub fn allowsBuiltin(self: TargetProfile, availability: BuiltinAvailability) bool {
        return switch (self) {
            .native => availability != .aot_wasm_only,
            .browser_interpreter, .aot_wasi => availability == .all,
            .aot_js_wasm => availability != .native_only,
        };
    }
};

pub const BuiltinAvailability = enum {
    all,
    native_only,
    aot_wasm_only,
};

pub const RuntimeAvailabilityError = error{
    BuiltinUnavailable,
};

pub fn builtinAvailability(name: []const u8) BuiltinAvailability {
    if (std.mem.startsWith(u8, name, "DOM::") or
        std.mem.startsWith(u8, name, "состояние::") or
        std.mem.eql(u8, name, "сеть::http_запрос_sync") or
        std.mem.eql(u8, name, "сеть::http_запрос_sync_с_заголовками"))
    {
        return .aot_wasm_only;
    }

    if (std.mem.startsWith(u8, name, "фс::") or
        std.mem.startsWith(u8, name, "сжатие::") or
        std.mem.startsWith(u8, name, "синтаксис::") or
        std.mem.startsWith(u8, name, "бд::") or
        std.mem.startsWith(u8, name, "криптография::"))
    {
        return .native_only;
    }

    const native_only = [_][]const u8{
        "время::спать_мс",
        "ос::окружение",
        "ос::установить_окружение",
        "ос::удалить_окружение",
        "ос::выполнить",
        "ос::завершить",
        "ввод_вывод::прочитать_строку",
        "ввод_вывод::поток",
        // `.печать`/`.строка` (stdout) — как и остальной `ввод_вывод`,
        // никогда не имели AOT WASM-лоуеринга (нет записи в
        // mir_lowering.zig, нет host-импорта) — просто раньше не были
        // классифицированы здесь, из-за чего использование в
        // `--target=wasm` коде проваливалось глубоко внутри MIR-лоуеринга
        // с невнятным "свойство-модуль или вариант перечисления вне
        // вызова" вместо понятной ошибки типов на этапе typecheck
        // (найдено при отладке отдельной, не связанной проблемы —
        // `печать`/`строка` для отладки WASM-кода — реальный, легко
        // повторяемый источник путаницы, не гипотеза).
        "ввод_вывод::печать",
        "ввод_вывод::строка",
        "сеть::подключиться",
        "сеть::http_запрос",
        "сеть::http_запрос_без_редиректа",
        "сеть::http_сервер_слушать",
    };
    for (native_only) |builtin| {
        if (std.mem.eql(u8, name, builtin)) return .native_only;
    }
    return .all;
}

pub fn builtinAvailableForTarget(name: []const u8, profile: TargetProfile) bool {
    return profile.allowsBuiltin(builtinAvailability(name));
}

pub fn ensureRuntimeBuiltinAvailable(
    name: []const u8,
    profile: TargetProfile,
) RuntimeAvailabilityError!void {
    if (!builtinAvailableForTarget(name, profile)) return error.BuiltinUnavailable;
}

pub fn typeErrorMessage(
    allocator: std.mem.Allocator,
    name: []const u8,
    profile: TargetProfile,
) ![]u8 {
    std.debug.assert(!builtinAvailableForTarget(name, profile));

    const suffix = switch (builtinAvailability(name)) {
        .all => unreachable,
        .native_only => "недоступен для WASM-таргета",
        .aot_wasm_only => switch (profile) {
            .aot_wasi => "доступен только для JS AOT WASM-таргета",
            .native, .browser_interpreter => "доступен только для AOT WASM-таргета",
            .aot_js_wasm => unreachable,
        },
    };
    return std.fmt.allocPrint(allocator, "Type Error: builtin '{s}' {s}", .{ name, suffix });
}

pub fn runtimeErrorMessage(
    allocator: std.mem.Allocator,
    name: []const u8,
    profile: TargetProfile,
) ![]u8 {
    std.debug.assert(!builtinAvailableForTarget(name, profile));

    const suffix = switch (builtinAvailability(name)) {
        .all => unreachable,
        .native_only => "недоступно в этом runtime-таргете",
        .aot_wasm_only => switch (profile) {
            .aot_wasi => "доступно только в JS AOT WASM-выводе",
            .native, .browser_interpreter => "доступно только в AOT WASM-выводе, не в байткод-VM",
            .aot_js_wasm => unreachable,
        },
    };
    return std.fmt.allocPrint(allocator, "Runtime Panic: '{s}' {s}", .{ name, suffix });
}

test "builtin availability matches the expected classification per builtin" {
    try std.testing.expectEqual(BuiltinAvailability.all, builtinAvailability("массив::длина"));
    try std.testing.expectEqual(BuiltinAvailability.native_only, builtinAvailability("фс::есть"));
    try std.testing.expectEqual(BuiltinAvailability.native_only, builtinAvailability("сеть::http_запрос"));
    try std.testing.expectEqual(BuiltinAvailability.native_only, builtinAvailability("криптография::hmac_sha256_base64url"));
    try std.testing.expectEqual(BuiltinAvailability.aot_wasm_only, builtinAvailability("DOM::текст"));
    try std.testing.expectEqual(BuiltinAvailability.aot_wasm_only, builtinAvailability("сеть::http_запрос_sync"));
}

test "target profiles reject unavailable builtin classes" {
    try std.testing.expect(builtinAvailableForTarget("массив::длина", .native));
    try std.testing.expect(builtinAvailableForTarget("массив::длина", .browser_interpreter));
    try std.testing.expect(builtinAvailableForTarget("массив::длина", .aot_js_wasm));
    try std.testing.expect(builtinAvailableForTarget("массив::длина", .aot_wasi));

    try std.testing.expect(builtinAvailableForTarget("фс::есть", .native));
    try std.testing.expect(!builtinAvailableForTarget("фс::есть", .browser_interpreter));
    try std.testing.expect(!builtinAvailableForTarget("фс::есть", .aot_js_wasm));
    try std.testing.expect(!builtinAvailableForTarget("фс::есть", .aot_wasi));

    try std.testing.expect(!builtinAvailableForTarget("DOM::текст", .native));
    try std.testing.expect(!builtinAvailableForTarget("DOM::текст", .browser_interpreter));
    try std.testing.expect(builtinAvailableForTarget("DOM::текст", .aot_js_wasm));
    try std.testing.expect(!builtinAvailableForTarget("DOM::текст", .aot_wasi));
}

test "availability messages support static and runtime guards" {
    const native_type_error = try typeErrorMessage(std.testing.allocator, "DOM::текст", .native);
    defer std.testing.allocator.free(native_type_error);
    try std.testing.expectEqualStrings(
        "Type Error: builtin 'DOM::текст' доступен только для AOT WASM-таргета",
        native_type_error,
    );

    const wasm_type_error = try typeErrorMessage(std.testing.allocator, "фс::есть", .aot_js_wasm);
    defer std.testing.allocator.free(wasm_type_error);
    try std.testing.expectEqualStrings(
        "Type Error: builtin 'фс::есть' недоступен для WASM-таргета",
        wasm_type_error,
    );

    const runtime_error = try runtimeErrorMessage(std.testing.allocator, "DOM::текст", .browser_interpreter);
    defer std.testing.allocator.free(runtime_error);
    try std.testing.expectEqualStrings(
        "Runtime Panic: 'DOM::текст' доступно только в AOT WASM-выводе, не в байткод-VM",
        runtime_error,
    );
    try std.testing.expectError(
        error.BuiltinUnavailable,
        ensureRuntimeBuiltinAvailable("DOM::текст", .browser_interpreter),
    );
}
