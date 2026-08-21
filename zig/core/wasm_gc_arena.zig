const std = @import("std");
const mir = @import("mir.zig");
const mir_builder = @import("mir_builder.zig");
const mir_cps = @import("mir_cps.zig");
const types = @import("types.zig");
const wasm_heap = @import("wasm_heap.zig");
const wasm_emit = @import("wasm_emit.zig");

// GC для WASM AOT. У WASM AOT нет трассирующего сборщика мусора (для
// настоящего потребовались бы дескрипторы раскладки типов и выгрузка
// каждой локальной переменной в линейную память) — этот проход даёт
// дешёвую, корректную по построению часть той же пользы: сбрасывает арену
// bump-аллокатора (`global 0`, `@runtime_alloc` в `wasm_heap.zig`) до
// контрольной точки в НАЧАЛЕ каждого вызова ТОЧКИ ВХОДА со стороны JS,
// восстанавливая её при возврате из вызова. Освобождает всё, что было
// выделено (и гарантированно мертво, поскольку ничто вне вызова не может
// на это ссылаться после его завершения) между ПОВТОРНЫМИ вызовами —
// именно такой формы паттерн Elm-архитектуры DOM-как-хранилища (`старт`,
// затем много независимых колбэков `DOM.на_клик`/`после_кадра`). НЕ
// освобождает мусор, порождённый ВНУТРИ одного долгого вызова (большого
// цикла) — для этого случая остаётся полагаться только на `memory.grow`.
//
// Выполняется ПОСЛЕДНИМ в пайплайне AOT-развёртывания (после
// `wasm_objects`/`wasm_strings`/`wasm_interfaces`/`wasm_actors`),
// переиспользуя приём переименования-и-обёртывания из `buildScheduler`
// в `wasm_actors.zig`: исходная функция точки входа переименовывается во
// внутреннее имя, а под ИСХОДНЫМ экспортируемым именем строится НОВАЯ
// функция вида `checkpoint = arena; call original; arena = checkpoint;
// return result`.
//
// Набор оборачиваемых функций намеренно НЕ "каждый WASM-экспорт" —
// `wasm_emit.zig` экспортирует каждую скомпилированную функцию верхнего
// уровня под её именем, а не только те, что JS вызывает напрямую;
// обёртывание случайно экспортированного внутреннего хелпера сбросило бы
// состояние арены В СЕРЕДИНЕ вызова, который его использует, повредив
// живые данные внутри вызова. Точный набор: `старт` плюс
// `module.dom_handler_names` (собирается во время обхода достижимости
// для tree-shaking в `mir_lowering.zig` — то же обнаружение "обработчик,
// зарегистрированный по строковому имени", что уже построено для того
// прохода, здесь переиспользуется для другой цели).

fn uniqueInternalName(module: *mir.Module, original_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(module.arena.allocator(), "@arena_impl_{s}", .{original_name});
}

fn wrapEntryPoint(allocator: std.mem.Allocator, module: *mir.Module, fallback_type_store: *const types.TypeStore, original_id: mir.FunctionId) !void {
    const original_name = try module.arena.allocator().dupe(u8, module.functions.items[@intFromEnum(original_id)].name);
    const internal_name = try uniqueInternalName(module, original_name);

    const original = &module.functions.items[@intFromEnum(original_id)];
    // `original`'s params/result carry `TypeId`s minted against ITS OWN
    // module's `TypeStore` (`TypeId.owner` is store-specific — a numeric
    // index that means something ELSE, or nothing, in a different store's
    // table). `@invoke_click` in particular is always built by
    // `findOrBuildInvokeClickTrampoline` using the LOWERING module's own
    // `ctx.checked.types` — for a `DOM.на_клик` call inside an IMPORTED
    // library (not the entry file), that's a DIFFERENT `TypeStore`
    // instance than `fallback_type_store` (always the ENTRY module's,
    // per this pass's one caller in `mir_lowering.zig`/`cli/main.zig`).
    // Using the wrong store here silently mis-mapped every non-obvious
    // `TypeId` to the WASM `f64` fallback — confirmed via `wasm2wat`:
    // `@invoke_click`'s wrapper ended up with `(param f64 f64 f64 f64
    // f64 f64 f64 f64)` instead of the real `(i32 f64 f64 i32 i32 i32
    // i32 i32)`, an invalid module that failed to even INSTANTIATE in a
    // real browser (`panos build`'s own success doesn't run a WASM
    // validator as strict as `WebAssembly.Module()`). `function.
    // type_store` (set once, per-function, at the point each function was
    // originally lowered — see `lowerLambda`/`findOrBuildInvokeClickTrampoline`
    // themselves setting it) is the one true source of truth for
    // interpreting a GIVEN function's own locals; only fall back to the
    // entry module's store for a function that never had one set (there
    // shouldn't be any in practice, but this pass ran with `orelse
    // fallback_type_store`-shaped mistakes before, better safe here too).
    const type_store = original.type_store orelse fallback_type_store;
    const result_type = original.result_type;
    const original_params = original.parameters;

    var param_types: std.ArrayList(types.TypeId) = .empty;
    defer param_types.deinit(allocator);
    var param_names: std.ArrayList([]const u8) = .empty;
    defer param_names.deinit(allocator);
    for (original_params) |local_id| {
        const local = original.locals.items[@intFromEnum(local_id)];
        try param_types.append(allocator, local.type_id);
        try param_names.append(allocator, local.name);
    }

    const new_id = try mir_builder.newFunction(module, allocator, original_name, wasm_heap.dummy_symbol, result_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, new_id);
    builder.currentFunction().type_store = type_store;

    var new_params: std.ArrayList(mir.LocalId) = .empty;
    for (param_types.items, param_names.items) |type_id, name| {
        const local = try builder.newLocal(wasm_heap.dummy_symbol, name, type_id);
        try new_params.append(allocator, local);
    }
    builder.currentFunction().parameters = try new_params.toOwnedSlice(allocator);

    // Фиксируем указатель bump-арены ДО выполнения оборачиваемого тела.
    const checkpoint = try builder.newValue(type_store.builtins.boolean);
    try builder.emit(.{ .global_get = .{ .dst = checkpoint, .global = wasm_emit.actor_heap_global_index } });
    const checkpoint_local = try wasm_heap.storeLocal(&builder, "@gc_checkpoint", type_store.builtins.boolean, checkpoint);

    // `module.arena`, а не `allocator` — этот срез хранится постоянно
    // внутри инструкции `.call` ниже, которую `Block.deinit` сама по себе
    // никогда не освобождает (освобождается только СПИСОК инструкций, но
    // не поля переменной длины внутри отдельных инструкций — см.
    // doc-комментарий `mir.Module.arena`).
    const arena = module.arena.allocator();
    var call_args: std.ArrayList(mir.ValueId) = .empty;
    for (builder.currentFunction().parameters, param_types.items) |local_id, type_id| {
        const value = try wasm_heap.loadLocal(&builder, local_id, type_id);
        try call_args.append(arena, value);
    }
    const args_slice = try call_args.toOwnedSlice(arena);

    const is_void = type_store.eql(result_type, type_store.builtins.void);
    if (is_void) {
        try builder.emit(.{ .call = .{ .dst = null, .callee = original_id, .args = args_slice } });
        const checkpoint_for_restore = try wasm_heap.loadLocal(&builder, checkpoint_local, type_store.builtins.boolean);
        try builder.emit(.{ .global_set = .{ .global = wasm_emit.actor_heap_global_index, .src = checkpoint_for_restore } });
        builder.terminate(.{ .return_value = .{ .value = null } });
    } else {
        const result = try builder.newValue(result_type);
        try builder.emit(.{ .call = .{ .dst = result, .callee = original_id, .args = args_slice } });
        const result_local = try wasm_heap.storeLocal(&builder, "@gc_result", result_type, result);
        const checkpoint_for_restore = try wasm_heap.loadLocal(&builder, checkpoint_local, type_store.builtins.boolean);
        try builder.emit(.{ .global_set = .{ .global = wasm_emit.actor_heap_global_index, .src = checkpoint_for_restore } });
        const result_for_return = try wasm_heap.loadLocal(&builder, result_local, result_type);
        builder.terminate(.{ .return_value = .{ .value = result_for_return } });
    }

    // Старая точка входа больше не достижима извне под исходным
    // экспортируемым именем (теперь им владеет обёртка выше) —
    // переименовывается, чтобы "экспортировать каждую функцию по имени" в
    // `wasm_emit.zig` не породило конфликтующий второй экспорт.
    module.functions.items[@intFromEnum(original_id)].name = internal_name;
}

pub fn expand(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore) !void {
    // Куча вообще не используется (нет `@runtime_alloc`/global 0 в
    // итоговом модуле, определяется собственным флагом `has_actors` в
    // `wasm_emit.zig`) — сбрасывать нечего, а генерация обёртки со
    // ссылкой на несуществующий global дала бы невалидный модуль.
    if (!mir_cps.usesActorMemory(module)) return;

    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    var entry_names: std.ArrayList([]const u8) = .empty;
    defer entry_names.deinit(allocator);
    if (!seen.contains("старт")) {
        try seen.put("старт", {});
        try entry_names.append(allocator, "старт");
    }
    for (module.dom_handler_names) |name| {
        if (seen.contains(name)) continue;
        try seen.put(name, {});
        try entry_names.append(allocator, name);
    }

    for (entry_names.items) |name| {
        const id = wasm_heap.findFunctionByName(module, name) orelse continue;
        try wrapEntryPoint(allocator, module, type_store, id);
    }
}
