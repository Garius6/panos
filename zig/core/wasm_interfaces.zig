const std = @import("std");
const mir = @import("mir.zig");
const mir_builder = @import("mir_builder.zig");
const types = @import("types.zig");
const wasm_heap = @import("wasm_heap.zig");

// Превращает `.cast_interface`/`.invoke_interface` (оба —
// целенезависимый MIR, вычисленный через `type_checker.
// findInterfaceImplementation` — ТО ЖЕ разрешение времени компиляции,
// что уже использует нативный байткод-бэкенд) в настоящий код в
// линейной памяти модуля + `call_indirect`, переиспользуя bump-
// аллокатор `wasm_heap.zig` (общий с `wasm_objects.zig`/
// `wasm_strings.zig`/`wasm_actors.zig`). Выполняется в ТОМ ЖЕ слоте
// прохода, что и они (до `mir_cps.prepare`).
//
// Представление: значение интерфейса — упакованное значение в куче —
// `alloc(8)`, `receiver: i32` по смещению 0 (собственный хэндл
// нижележащей конкретной структуры/перечисления, нетронутый),
// `vtable_ptr: i32` по смещению 4 (небольшой плоский массив i32-
// ИНДЕКСОВ ТАБЛИЦЫ WASM, по одному на метод интерфейса, в порядке
// объявления методов самого интерфейса — порядок
// `InterfaceMethodBinding`, уже разрешённый `mir_lowering.zig`). И
// массив vtable, и сам box аллоцируются заново при каждом выполнении
// `.cast_interface` (ПОЛУЧАТЕЛЬ — настоящее значение времени
// выполнения — какая конкретная структура стоит за ним, может
// отличаться от вызова к вызову — так что сам box не может быть
// константой времени компиляции, в отличие от строковых литералов
// `wasm_strings.zig`); СОДЕРЖИМОЕ массива vtable (какие индексы
// таблицы) — константа времени компиляции, записывается обычным
// `mem_store` констант `.const_value{.address}`, тот же паттерн, что
// `emitConstString` в `wasm_strings.zig`.
//
// Цепочка диспетчеризации `.invoke_interface`: распаковать box (два
// `mem_load` — receiver, vtable_ptr), прочитать слот vtable по
// `method_index*4` (индекс таблицы WASM, разрешается только во ВРЕМЯ
// ВЫПОЛНЕНИЯ — это подлинно динамическая диспетчеризация, а не вызов,
// разрешимый на этапе компиляции), затем `.call_indirect` с
// `[receiver] ++ args`.
//
// Сама ТАБЛИЦА функций WASM (каждая функция, когда-либо помещённая в
// ЛЮБУЮ vtable, без дублей, в порядке первого появления) накапливается
// как побочный эффект этого прохода и возвращается вызывающему коду —
// параметру `interface_table` в `wasm_emit.emitModule` нужен ТОЧНО
// ТОТ ЖЕ список, в ТОМ ЖЕ порядке, что этот проход уже запёк как
// литеральные константы индексов таблицы в построение массива vtable
// каждой `.cast_interface`.

fn unsupported(comptime what: []const u8) error{InterfaceExpandUnsupported} {
    std.debug.print("panos build: AOT (wasm) интерфейсы — " ++ what ++ "\n", .{});
    return error.InterfaceExpandUnsupported;
}

pub const ExpansionResult = struct {
    table: []const mir.FunctionId,
};

const ExpandCtx = struct {
    layout: wasm_heap.PtrLayout,
    type_store: *const types.TypeStore,
};

pub fn expand(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore) !ExpansionResult {
    if (!usesInterfaces(module)) return .{ .table = &.{} };

    const layout = wasm_heap.PtrLayout{
        .ptr_type = type_store.builtins.string,
        .idx_type = type_store.builtins.boolean,
        .bool_type = type_store.builtins.boolean,
    };
    _ = try wasm_heap.findOrBuildAlloc(allocator, module, type_store, layout);

    // Присваивается в порядке первого появления при переписывании мест
    // `.cast_interface` ниже — порядок обхода обычной `AutoHashMap` не
    // стабилен между запусками, поэтому присваивание ДОЛЖНО идти через
    // единый линейный проход (не через, скажем, обход хэш-мапы "все
    // когда-либо виденные методы"), который собственный поблочный,
    // поинструкционный обход `expandBlock` уже естественно даёт
    // бесплатно.
    var table: std.ArrayList(mir.FunctionId) = .empty;
    var table_index_of: std.AutoHashMap(mir.FunctionId, u32) = .init(allocator);
    defer table_index_of.deinit();
    // Обычным (не-default) методам, помещаемым в vtable интерфейса,
    // нужна тонкая ОБЁРТКА-распаковщик box (см. doc-комментарий
    // `wrapperFor`) — мемоизируется по ИСХОДНОМУ FunctionId, так что
    // один и тот же метод, достигнутый через несколько cast'ов,
    // получает только ОДНУ обёртку, добавляемую в `module.functions`
    // лениво при первой надобности (безопасно посреди цикла: внешний
    // `while` ниже перепроверяет `module.functions.items.len` на каждой
    // итерации, тот же паттерн, что уже установлен построением
    // runtime-функций в `wasm_objects.zig`).
    var wrapper_of: std.AutoHashMap(mir.FunctionId, mir.FunctionId) = .init(allocator);
    defer wrapper_of.deinit();
    // Та же форма мемоизации, что и `wrapper_of` выше, но для
    // собственной нужды `.build_closure` в обёртке — см. doc-комментарий
    // `closureWrapperFor`. Отдельная карта (не общая с `wrapper_of`),
    // так как у двух обёрток разная форма (распаковка box в receiver
    // против игнорируемого хвостового env_ptr) и обе, в принципе, могут
    // понадобиться для ОДНОЙ И ТОЙ ЖЕ целевой функции (используемой и
    // как метод интерфейса, и передаваемой как значение первого
    // класса).
    var closure_wrapper_of: std.AutoHashMap(mir.FunctionId, mir.FunctionId) = .init(allocator);
    defer closure_wrapper_of.deinit();

    var index: usize = 0;
    while (index < module.functions.items.len) : (index += 1) {
        const function_id: mir.FunctionId = @enumFromInt(index);
        // Каждая функция в графе модуля может принадлежать РАЗНОМУ
        // исходному файлу/модулю, а значит РАЗНОМУ экземпляру
        // `types.TypeStore` (`TypeId.owner` намеренно специфичен для
        // хранилища — см. doc-комментарий `types.zig`: "делает
        // случайное межхранилищное использование ошибочным"). Значения
        // box/массива vtable, создаваемые ниже, должны быть
        // типизированы относительно СОБСТВЕННОГО хранилища ЭТОЙ
        // функции, а не переданного вызывающим кодом верхнеуровневого
        // `type_store` (это хранилище только ВХОДНОГО модуля) —
        // использование не того хранилища здесь тихо породило бы
        // `TypeId`, который `wasm_emit.zig` потом никогда не смог бы
        // найти (`store.get` возвращает null для чужого владельца),
        // подставляя для этого значения WASM-тип f64 вместо i32 и
        // портя вычисление индекса типа для `call_indirect`.
        const function_store = module.functions.items[index].type_store orelse type_store;
        const function_layout = wasm_heap.PtrLayout{
            .ptr_type = function_store.builtins.string,
            .idx_type = function_store.builtins.boolean,
            .bool_type = function_store.builtins.boolean,
        };
        const function_ctx = ExpandCtx{ .layout = function_layout, .type_store = function_store };
        var direct_call_callees = try directCallCallees(allocator, &module.functions.items[index]);
        defer direct_call_callees.deinit();
        // Заполняется веткой `.function_ref` ниже КАЖДЫЙ РАЗ, когда она
        // попадает в исключение `direct_call_callees` (т.е. `dst` этого
        // function_ref напрямую питает callee `call_value` В ТОЙ ЖЕ
        // функции) — это правильный сигнал "является ли callee этого
        // call_value на самом деле известной статической функцией" для
        // `expandCallValue`. Сам `direct_call_callees` для этой
        // проверки не годится: он заполняется прямым сканированием
        // полей `.call_value.callee`, так что собственный callee
        // call_value тривиально всегда входит в это множество —
        // сверка с самим собой была бы тавтологией, из-за которой
        // `expandCallValue` посчитал бы КАЖДЫЙ вызов замыкания
        // статическим прямым вызовом, тихо передав сырой (нераспакованный)
        // указатель box прямо в `call_indirect` как индекс таблицы.
        var static_callees: std.AutoHashMap(mir.ValueId, mir.FunctionId) = .init(allocator);
        defer static_callees.deinit();
        const block_count = module.functions.items[index].blocks.items.len;
        var block_index: usize = 0;
        while (block_index < block_count) : (block_index += 1) {
            var builder = mir_builder.Builder{ .module = module, .allocator = allocator, .function_id = function_id };
            try expandBlock(&builder, allocator, @enumFromInt(block_index), function_ctx, &table, &table_index_of, &wrapper_of, &closure_wrapper_of, &direct_call_callees, &static_callees);
        }
    }

    return .{ .table = try table.toOwnedSlice(allocator) };
}

// Обычные методы `реализация X для Y` ожидают `это` как СЫРОЕ
// нижележащее конкретное значение (настоящий доступ к полю настоящей
// структуры) — но каждый слот vtable интерфейса вызывается единообразно
// через ОДИН И ТОТ ЖЕ упакованный `это` (см. `expandInvokeInterface`),
// поскольку `это` метода интерфейса по умолчанию должен оставаться
// АБСТРАКТНЫМ упакованным значением (чтобы продолжать полиморфную
// диспетчеризацию через `это.другой_метод()` — зеркалит разделение
// `callInterface`/`is_default_interface_method` в `vm.zig`, то же
// рассуждение, только в форме WASM). Вместо того чтобы заставлять
// `expandInvokeInterface` ветвиться во время выполнения по тому, какой
// callee ей попался (у WASM нет рефлексии "исследовать эту функцию"),
// каждый ОБЫЧНЫЙ метод вместо этого получает здесь трамплин:
// распаковать box один раз (`mem_load` box+0), передать в реальный
// метод с сырым receiver + остальные аргументы без изменений. Методам
// по умолчанию обёртка НЕ нужна — box УЖЕ имеет ту форму, которую они
// ожидают.
fn wrapperFor(module: *mir.Module, allocator: std.mem.Allocator, fallback_type_store: *const types.TypeStore, wrapper_of: *std.AutoHashMap(mir.FunctionId, mir.FunctionId), target: mir.FunctionId) !mir.FunctionId {
    if (wrapper_of.get(target)) |existing| return existing;

    // Копируем всё нужное из target ДО вызова
    // `mir_builder.newFunction`/`beginFunction` ниже — обе функции
    // ДОБАВЛЯЮТ в `module.functions`, что может переаллоцировать
    // подложный массив и инвалидировать сырой `*mir.Function`,
    // удерживаемый через вызов (собственный doc-комментарий модуля в
    // `mir_builder.zig`).
    const target_function = &module.functions.items[@intFromEnum(target)];
    // Собственные типы обёртки (параметр box, receiver, результат)
    // должны браться из хранилища TARGET, а не вызывающего кода (места
    // `.cast_interface`) — target может жить в другом модуле, чем
    // место cast'а (например, метод прелюдии по умолчанию кастует
    // структуру, объявленную в ТОМ ЖЕ модуле прелюдии, обёрнутую и
    // вызываемую из функции входного модуля). Использование здесь
    // хранилища вызывающего кода воспроизвело бы ту же межхранилищную
    // ошибку `TypeId`, для исправления которой добавлен собственный
    // поэкземплярный вывод `type_store` в `expand()`.
    const target_type_store = target_function.type_store orelse fallback_type_store;
    const target_layout = wasm_heap.PtrLayout{
        .ptr_type = target_type_store.builtins.string,
        .idx_type = target_type_store.builtins.boolean,
        .bool_type = target_type_store.builtins.boolean,
    };
    const target_name = try module.arena.allocator().dupe(u8, target_function.name);
    const target_result_type = target_function.result_type;
    const target_extra_param_types = try allocator.alloc(types.TypeId, target_function.parameters.len - 1);
    defer allocator.free(target_extra_param_types);
    for (target_function.parameters[1..], target_extra_param_types) |local, *out| {
        out.* = target_function.locals.items[@intFromEnum(local)].type_id;
    }

    const wrapper_name = try std.fmt.allocPrint(module.arena.allocator(), "@iface_wrap_{s}", .{target_name});
    const wrapper_id = try mir_builder.newFunction(module, allocator, wrapper_name, wasm_heap.dummy_symbol, target_result_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, wrapper_id);

    const box_param = try builder.newLocal(wasm_heap.dummy_symbol, "box", target_layout.ptr_type);
    var params: std.ArrayList(mir.LocalId) = .empty;
    try params.append(allocator, box_param);
    var extra_locals: std.ArrayList(mir.LocalId) = .empty;
    for (target_extra_param_types) |t| {
        const p = try builder.newLocal(wasm_heap.dummy_symbol, "a", t);
        try params.append(allocator, p);
        try extra_locals.append(allocator, p);
    }
    builder.currentFunction().parameters = try params.toOwnedSlice(allocator);
    builder.currentFunction().type_store = target_type_store;

    const box_val = try wasm_heap.loadLocal(&builder, box_param, target_layout.ptr_type);
    const receiver = try builder.newValue(target_layout.ptr_type);
    try builder.emit(.{ .mem_load = .{ .dst = receiver, .addr = box_val } });

    const arena = module.arena.allocator();
    var args: std.ArrayList(mir.ValueId) = .empty;
    try args.append(arena, receiver);
    for (extra_locals.items) |local| {
        const t = builder.currentFunction().locals.items[@intFromEnum(local)].type_id;
        try args.append(arena, try wasm_heap.loadLocal(&builder, local, t));
    }

    const is_void = target_type_store.eql(target_result_type, target_type_store.builtins.void);
    const dst = if (is_void) null else try builder.newValue(target_result_type);
    try builder.emit(.{ .call = .{ .dst = dst, .callee = target, .args = try args.toOwnedSlice(arena) } });
    builder.terminate(.{ .return_value = .{ .value = dst } });

    try wrapper_of.put(target, wrapper_id);
    return wrapper_id;
}

// Обычной именованной функции, используемой как ЗНАЧЕНИЕ замыкания
// первого класса (`.build_closure{already_env_aware: false}` —
// `lowerSymbolValueRef` в `mir_lowering.zig`), нужна тонкая ОБЁРТКА,
// помещаемая в таблицу вместо самой оригинальной функции: каждое
// замыкание вызывается единообразно через `call_indirect` с
// ХВОСТОВЫМ аргументом `env_ptr` (см. `expandCallValue`), но
// собственная реальная сигнатура/места прямого вызова оригинальной
// функции должны остаться нетронутыми — добавление параметра САМОЙ
// функции сломало бы каждый обычный вызов `f(x)` к ней в другом
// месте. Обёртка передаёт вызов в реальную функцию без изменений,
// просто отбрасывая хвостовой `env_ptr` (у обычной ссылки-на-функцию,
// ставшей значением, никогда нет реальных захватов). Мемоизируется по
// ИСХОДНОМУ FunctionId в `closure_wrapper_of`, та же форма "построить
// один раз, при первой надобности", что и `wrapperFor` выше.
fn closureWrapperFor(module: *mir.Module, allocator: std.mem.Allocator, fallback_type_store: *const types.TypeStore, closure_wrapper_of: *std.AutoHashMap(mir.FunctionId, mir.FunctionId), target: mir.FunctionId) !mir.FunctionId {
    if (closure_wrapper_of.get(target)) |existing| return existing;

    // Та же дисциплина "скопировать всё ДО вызова newFunction/
    // beginFunction", что и в `wrapperFor` — обе функции ДОБАВЛЯЮТ в
    // `module.functions`, что может переаллоцировать и инвалидировать
    // сырой `*mir.Function`.
    const target_function = &module.functions.items[@intFromEnum(target)];
    const target_type_store = target_function.type_store orelse fallback_type_store;
    const target_layout = wasm_heap.PtrLayout{
        .ptr_type = target_type_store.builtins.string,
        .idx_type = target_type_store.builtins.boolean,
        .bool_type = target_type_store.builtins.boolean,
    };
    const target_name = try module.arena.allocator().dupe(u8, target_function.name);
    const target_result_type = target_function.result_type;
    const target_param_types = try allocator.alloc(types.TypeId, target_function.parameters.len);
    defer allocator.free(target_param_types);
    for (target_function.parameters, target_param_types) |local, *out| {
        out.* = target_function.locals.items[@intFromEnum(local)].type_id;
    }

    const wrapper_name = try std.fmt.allocPrint(module.arena.allocator(), "@closure_wrap_{s}", .{target_name});
    const wrapper_id = try mir_builder.newFunction(module, allocator, wrapper_name, wasm_heap.dummy_symbol, target_result_type, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, wrapper_id);

    var params: std.ArrayList(mir.LocalId) = .empty;
    var real_locals: std.ArrayList(mir.LocalId) = .empty;
    defer real_locals.deinit(allocator);
    for (target_param_types) |t| {
        const p = try builder.newLocal(wasm_heap.dummy_symbol, "a", t);
        try params.append(allocator, p);
        try real_locals.append(allocator, p);
    }
    const env_param = try builder.newLocal(wasm_heap.dummy_symbol, "@env", target_layout.idx_type);
    try params.append(allocator, env_param);
    builder.currentFunction().parameters = try params.toOwnedSlice(allocator);
    builder.currentFunction().type_store = target_type_store;

    const arena = module.arena.allocator();
    var args: std.ArrayList(mir.ValueId) = .empty;
    for (real_locals.items) |local| {
        const t = builder.currentFunction().locals.items[@intFromEnum(local)].type_id;
        try args.append(arena, try wasm_heap.loadLocal(&builder, local, t));
    }

    const is_void = target_type_store.eql(target_result_type, target_type_store.builtins.void);
    const dst = if (is_void) null else try builder.newValue(target_result_type);
    try builder.emit(.{ .call = .{ .dst = dst, .callee = target, .args = try args.toOwnedSlice(arena) } });
    builder.terminate(.{ .return_value = .{ .value = dst } });

    try closure_wrapper_of.put(target, wrapper_id);
    return wrapper_id;
}

// Раскрывает `.build_closure{dst, function, captured, already_env_aware}`.
// Без захватов выбирается дедуплицированный статический box
// `{table_index, 0}` из data-секции. С захватами строится аллокация
// ОКРУЖЕНИЯ (по одному 8-байтовому слоту `frame_store` на
// захваченное значение, та же форма обычной структуры, что уже
// использует `wasm_objects.zig` — разнородные захваты i32/f64
// одинаково подходят, в отличие от побайтовой упаковки), затем BOX
// ИЗ 2 ПОЛЕЙ, `mem_load`/`mem_store` по смещениям байт 0 и 4 (НЕ слоты
// фрейма — оба поля box всегда обычные i32, никогда напрямую
// захваченный f64, в точности совпадает с формой box `{receiver,
// vtable_ptr}` из `expandCastInterface`): `table_index` в +0, `env_ptr`
// в +4. `already_env_aware` решает, помещается ли `function` в таблицу
// напрямую (тело лямбды, уже синтезированное с собственным хвостовым
// параметром `env_ptr` — `lowerLambda` в `mir_lowering.zig`) или через
// `closureWrapperFor` (обычная именованная функция, нуждается в
// обёртке с игнорируемым `env_ptr`).
fn expandBuildClosure(builder: *mir_builder.Builder, allocator: std.mem.Allocator, v: anytype, ctx: ExpandCtx, table: *std.ArrayList(mir.FunctionId), table_index_of: *std.AutoHashMap(mir.FunctionId, u32), closure_wrapper_of: *std.AutoHashMap(mir.FunctionId, mir.FunctionId)) !void {
    const layout = ctx.layout;
    const module = builder.module;
    const callee = if (v.already_env_aware) v.function else try closureWrapperFor(module, allocator, ctx.type_store, closure_wrapper_of, v.function);
    const table_index = try tableIndexFor(table, table_index_of, allocator, callee);

    // Captureless closure не содержит никакого рантайм-состояния:
    // её box — константа `{table_index, 0}`. Одна статическая
    // запись на индекс таблицы живёт в data-секции WASM и может
    // безопасно пережить любое число arena-reset'ов. Это убирает
    // permanent-heap из hot path передачи named function как callback.
    if (v.captured.len == 0) {
        var slot: ?u32 = null;
        for (module.static_closure_table_indices.items, 0..) |known, index| {
            if (known == table_index) {
                slot = @intCast(index);
                break;
            }
        }
        if (slot == null) {
            slot = @intCast(module.static_closure_table_indices.items.len);
            try module.static_closure_table_indices.append(allocator, table_index);
        }
        try builder.emit(.{ .static_closure_ref = .{ .dst = v.dst, .slot = slot.? } });
        return;
    }

    const alloc_id = wasm_heap.findFunctionByName(module, wasm_heap.alloc_function_name).?;

    // `v.captured` — предсуществующие значения (произведены раньше в
    // потоке инструкций тем, что вычислило каждое захваченное выражение,
    // В ПОРЯДКЕ МАССИВА — `lowerLambda` в `mir_lowering.zig` эмитит
    // производителя каждого прямо при обходе `captures`) — маршрутизируем
    // через Locals НЕМЕДЛЕННО, та же дисциплина "погребённого значения",
    // что и у `v.src` в `expandCastInterface` — но именно в ОБРАТНОМ
    // порядке: при N>1 захватах производитель `v.captured[N-1]` был
    // воспроизведён ПОСЛЕДНИМ, так что это значение, реально лежащее
    // НАВЕРХУ настоящего стека WASM в этой точке — обработка
    // `storeLocal` в порядке МАССИВА (сначала индекс 0) пыталась бы
    // вытолкнуть его в НЕ ТУ локаль.
    const capture_locals = try module.arena.allocator().alloc(mir.LocalId, v.captured.len);
    var capture_index = v.captured.len;
    while (capture_index > 0) {
        capture_index -= 1;
        capture_locals[capture_index] = try wasm_heap.storeLocal(builder, "@capture", builder.currentFunction().valueType(v.captured[capture_index]), v.captured[capture_index]);
    }

    const env_local: mir.LocalId = env_blk: {
        const env_size = try wasm_heap.addressConst(builder, layout.idx_type, @intCast(v.captured.len * 8));
        const env = try builder.newValue(layout.ptr_type);
        try builder.emit(.{ .call = .{ .dst = env, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, env_size) } });
        const local = try wasm_heap.storeLocal(builder, "@env", layout.ptr_type, env);

        // Обратный порядок — установленное соглашение о порядке стека
        // (см. собственный цикл сохранения полей обычной структуры в
        // `wasm_objects.zig`, то же рассуждение).
        var i = capture_locals.len;
        while (i > 0) {
            i -= 1;
            const capture_type = builder.currentFunction().locals.items[@intFromEnum(capture_locals[i])].type_id;
            const capture_val = try wasm_heap.loadLocal(builder, capture_locals[i], capture_type);
            const env_for_store = try wasm_heap.loadLocal(builder, local, layout.ptr_type);
            try builder.emit(.{ .frame_store = .{ .frame = env_for_store, .slot = @intCast(i), .src = capture_val } });
        }
        break :env_blk local;
    };

    const box_size = try wasm_heap.addressConst(builder, layout.idx_type, 8);
    const box = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = box, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, box_size) } });
    const box_local = try wasm_heap.storeLocal(builder, "@closure_box", layout.ptr_type, box);

    const table_index_const = try wasm_heap.addressConst(builder, layout.idx_type, table_index);
    const box_for_table = try wasm_heap.loadLocal(builder, box_local, layout.ptr_type);
    try builder.emit(.{ .mem_store = .{ .addr = box_for_table, .src = table_index_const } });

    const env_for_box = try wasm_heap.loadLocal(builder, env_local, layout.ptr_type);
    const four = try wasm_heap.addressConst(builder, layout.idx_type, 4);
    const box_for_env_addr = try wasm_heap.loadLocal(builder, box_local, layout.ptr_type);
    const env_field_addr = try wasm_heap.binOp(builder, layout.idx_type, .add, box_for_env_addr, four);
    try builder.emit(.{ .mem_store = .{ .addr = env_field_addr, .src = env_for_box } });

    try builder.emit(.{ .load_local = .{ .dst = v.dst, .local = box_local } });
}

// Раскрывает `.call_value{callee, args, dst}` с типом замыкания (box,
// произведённый `.build_closure`, или любая локаль/параметр/поле,
// держащие его) в: распаковку (`mem_load` table_index @+0, `mem_load`
// env_ptr @+4), добавление `env_ptr` ХВОСТОВЫМ аргументом,
// `.call_indirect` — в точности зеркалит собственную форму
// распаковка-затем-`call_indirect` из `expandInvokeInterface`, та же
// дисциплина порядка стека (`table_index` должен быть ПОСЛЕДНИМ
// произведённым операндом, по семантике WASM для `call_indirect`).
// СТАТИЧЕСКИЕ прямые вызовы (`static_callees` — см. собственный
// doc-комментарий в месте вызова в `expand`) остаются полностью
// нетронутыми — существующий быстрый путь `value_to_function` в
// `wasm_emit.zig` по-прежнему обрабатывает их как обычный `call`, без
// накладных расходов на замыкание.
fn expandCallValue(builder: *mir_builder.Builder, allocator: std.mem.Allocator, v: anytype, ctx: ExpandCtx, static_callees: *const std.AutoHashMap(mir.ValueId, mir.FunctionId)) !void {
    if (static_callees.contains(v.callee)) {
        try builder.emit(.{ .call_value = .{ .dst = v.dst, .callee = v.callee, .args = v.args } });
        return;
    }
    _ = allocator;
    const layout = ctx.layout;
    const module = builder.module;

    const box_local = try wasm_heap.storeLocal(builder, "@call_box", layout.ptr_type, v.callee);
    const arg_locals = try module.arena.allocator().alloc(mir.LocalId, v.args.len);
    // Callee был произведён после аргументов и уже снят выше;
    // на стеке осталось `[arg0, arg1, ...]`, где последний arg —
    // на вершине. `local.set` снимает именно вершину, поэтому сохраняем
    // в обратном порядке. Прямой цикл незаметно менял `f(a, b)` на
    // `f(b, a)` для любого динамического function-value с двумя аргументами.
    var arg_index = v.args.len;
    while (arg_index > 0) {
        arg_index -= 1;
        const arg = v.args[arg_index];
        arg_locals[arg_index] = try wasm_heap.storeLocal(builder, "@call_arg", builder.currentFunction().valueType(arg), arg);
    }

    const box_for_table = try wasm_heap.loadLocal(builder, box_local, layout.ptr_type);
    const table_index_val = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load = .{ .dst = table_index_val, .addr = box_for_table } });
    const table_index_local = try wasm_heap.storeLocal(builder, "@table_index", layout.idx_type, table_index_val);

    const box_for_env = try wasm_heap.loadLocal(builder, box_local, layout.ptr_type);
    const four = try wasm_heap.addressConst(builder, layout.idx_type, 4);
    const env_addr = try wasm_heap.binOp(builder, layout.idx_type, .add, box_for_env, four);
    const env_ptr_val = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .mem_load = .{ .dst = env_ptr_val, .addr = env_addr } });
    const env_ptr_local = try wasm_heap.storeLocal(builder, "@call_env", layout.ptr_type, env_ptr_val);

    const arena = module.arena.allocator();
    var args: std.ArrayList(mir.ValueId) = .empty;
    for (arg_locals) |local| {
        const t = builder.currentFunction().locals.items[@intFromEnum(local)].type_id;
        try args.append(arena, try wasm_heap.loadLocal(builder, local, t));
    }
    try args.append(arena, try wasm_heap.loadLocal(builder, env_ptr_local, layout.ptr_type));

    const table_index_for_call = try wasm_heap.loadLocal(builder, table_index_local, layout.idx_type);
    try builder.emit(.{ .call_indirect = .{ .dst = v.dst, .table_index = table_index_for_call, .args = try args.toOwnedSlice(arena) } });
}

// Также включает вентиль для ЗНАЧЕНИЙ функций первого класса
// (`.function_ref`, использованный как что-либо, кроме собственного
// статически разрешённого callee у `.spawn` — см. переписывание
// `directCallCallees`/`.function_ref` в `expandInstruction`) И
// замыканий (`.build_closure` — `lowerLambda`/`lowerSymbolValueRef` в
// `mir_lowering.zig`) — все три возможности делят инфраструктуру
// alloc/таблицы этого прохода, и программа, не использующая ни одну
// из них, не должна платить за их настройку.
fn usesInterfaces(module: *const mir.Module) bool {
    for (module.functions.items) |function| for (function.blocks.items) |block|
        for (block.instructions.items) |instruction| switch (instruction) {
            .cast_interface, .invoke_interface, .function_ref, .call_value, .build_closure => return true,
            else => {},
        };
    return false;
}

// Два вида callee НИКОГДА не должны иметь свой `.function_ref`
// переписанным в настоящую константу-индекс таблицы i32 — оба
// остаются литеральным, ничего не делающим `.function_ref`,
// разрешаемым нижестоящим сканированием прямых вызовов вместо
// `call_indirect`:
//
// 1. Собственный callee `.spawn` — `resolveSpawnTarget` в
//    `wasm_actors.zig` сканирует на совпадающую инструкцию
//    `.function_ref` (`wasm_actors.expand` выполняется ПОСЛЕ этого
//    прохода, так что переписывание её здесь тихо сломало бы каждый
//    вызов `запусти`).
//
// 2. Собственный callee `.call_value` для каждого СТАТИЧЕСКИ известного
//    именованного вызова (быстрые пути ident/method_calls/module-import
//    в `mir_lowering.zig` — общий случай, `.function_ref` питает
//    `call_value.callee` НАПРЯМУЮ, без промежуточного store/reload).
//    Карта `value_to_function` в `wasm_emit.zig` разрешает их в обычный
//    прямой `call`, без нужды в косвенности. Переписывание их в записи
//    таблицы — не просто лишняя работа: для конкретно САМОрекурсивного
//    вызова это активно неверно: `wasm_actors.zig` переиспользует/
//    переименовывает собственный `FunctionId` функции на месте, когда
//    превращает её в функцию планировщика актора, так что запись
//    таблицы, зарегистрированная для этого `FunctionId` ДО
//    переименования, к моменту, когда `emitModule` строит секции
//    Table/Element, указывает на НЕ ТУ (постпереименованную)
//    сигнатуру. (call_value, чей callee приходит из
//    `storeCalleeLocal`/`reloadCalleeLocal` в `mir_lowering.zig` —
//    подлинно динамический запасной путь — использует СВЕЖИЙ `ValueId`
//    из перезагрузки, никогда не собственный `dst` оригинального
//    `.function_ref`, так что он естественно исключён из этого
//    множества и по-прежнему переписывается по мере надобности.)
//
// Собирается по функциям (соответствует собственному сканированию
// всей функции у `resolveSpawnTarget`) до начала какого-либо
// переписывания.
fn directCallCallees(allocator: std.mem.Allocator, function: *const mir.Function) !std.AutoHashMap(mir.ValueId, void) {
    var set: std.AutoHashMap(mir.ValueId, void) = .init(allocator);
    for (function.blocks.items) |block| for (block.instructions.items) |instruction| switch (instruction) {
        .spawn => |v| try set.put(v.callee, {}),
        .call_value => |v| try set.put(v.callee, {}),
        else => {},
    };
    return set;
}

fn tableIndexFor(table: *std.ArrayList(mir.FunctionId), table_index_of: *std.AutoHashMap(mir.FunctionId, u32), allocator: std.mem.Allocator, function_id: mir.FunctionId) !u32 {
    if (table_index_of.get(function_id)) |existing| return existing;
    const index: u32 = @intCast(table.items.len);
    try table.append(allocator, function_id);
    try table_index_of.put(function_id, index);
    return index;
}

fn expandBlock(builder: *mir_builder.Builder, allocator: std.mem.Allocator, block_id: mir.BlockId, ctx: ExpandCtx, table: *std.ArrayList(mir.FunctionId), table_index_of: *std.AutoHashMap(mir.FunctionId, u32), wrapper_of: *std.AutoHashMap(mir.FunctionId, mir.FunctionId), closure_wrapper_of: *std.AutoHashMap(mir.FunctionId, mir.FunctionId), direct_call_callees: *const std.AutoHashMap(mir.ValueId, void), static_callees: *std.AutoHashMap(mir.ValueId, mir.FunctionId)) !void {
    const function = builder.currentFunction();
    var original = function.blockConst(block_id).*;
    function.block(block_id).instructions = .empty;
    builder.setCurrentBlock(block_id);
    builder.terminated = false;

    for (original.instructions.items) |instruction| {
        try expandInstruction(builder, allocator, instruction, ctx, table, table_index_of, wrapper_of, closure_wrapper_of, direct_call_callees, static_callees);
    }
    builder.terminate(original.terminator);
    original.instructions.deinit(allocator);
}

fn expandInstruction(builder: *mir_builder.Builder, allocator: std.mem.Allocator, instruction: mir.Instruction, ctx: ExpandCtx, table: *std.ArrayList(mir.FunctionId), table_index_of: *std.AutoHashMap(mir.FunctionId, u32), wrapper_of: *std.AutoHashMap(mir.FunctionId, mir.FunctionId), closure_wrapper_of: *std.AutoHashMap(mir.FunctionId, mir.FunctionId), direct_call_callees: *const std.AutoHashMap(mir.ValueId, void), static_callees: *std.AutoHashMap(mir.ValueId, mir.FunctionId)) !void {
    switch (instruction) {
        .cast_interface => |v| {
            try expandCastInterface(builder, allocator, v, ctx, table, table_index_of, wrapper_of);
        },
        .invoke_interface => |v| {
            try expandInvokeInterface(builder, ctx, v);
        },
        // Переписывает ссылку на функцию в настоящий индекс таблицы
        // WASM i32 (`.const_value{.address}`) — см. doc-комментарии
        // `usesInterfaces` и `directCallCallees` о том, почему
        // собственный callee `.spawn` намеренно исключён.
        .function_ref => |v| {
            if (direct_call_callees.contains(v.dst)) {
                try static_callees.put(v.dst, v.function);
                try builder.emit(instruction);
                return;
            }
            const table_index = try tableIndexFor(table, table_index_of, allocator, v.function);
            try builder.emit(.{ .const_value = .{ .dst = v.dst, .value = .{ .address = table_index } } });
        },
        // Замыкания WASM AOT — см. doc-комментарий `expandBuildClosure`.
        .build_closure => |v| {
            try expandBuildClosure(builder, allocator, v, ctx, table, table_index_of, closure_wrapper_of);
        },
        // Callee с типом замыкания (значение типа `.function`,
        // произведённое `.build_closure` или обычной локалью/
        // параметром/полем, держащими его) — см. doc-комментарий
        // `expandCallValue`. Быстрый путь СТАТИЧЕСКОГО прямого вызова
        // (`static_callees`) не затрагивается, точно как в
        // переписывании `.function_ref` выше.
        .call_value => |v| {
            try expandCallValue(builder, allocator, v, ctx, static_callees);
        },
        else => try builder.emit(instruction),
    }
}

// `alloc(vtable.len * 4)`, по одному `mem_store` на запись (каждая —
// константный времени компиляции индекс таблицы WASM, разрешённый
// через `tableIndexFor`, та же форма "аллоцировать свежий массив
// констант", что уже установлена `emitConstString` в
// `wasm_strings.zig` для побайтового содержимого строк), затем
// `alloc(8)` для самого box (`receiver` по смещению 0, собственный
// адрес массива vtable по смещению 4).
fn expandCastInterface(builder: *mir_builder.Builder, allocator: std.mem.Allocator, v: anytype, ctx: ExpandCtx, table: *std.ArrayList(mir.FunctionId), table_index_of: *std.AutoHashMap(mir.FunctionId, u32), wrapper_of: *std.AutoHashMap(mir.FunctionId, mir.FunctionId)) !void {
    const layout = ctx.layout;
    const module = builder.module;
    const alloc_id = wasm_heap.findFunctionByName(module, wasm_heap.alloc_function_name).?;

    // `v.src` — ПРЕДСУЩЕСТВУЮЩЕЕ значение, уже произведённое (и
    // оставленное на настоящем стеке WASM) той инструкцией, что
    // непосредственно предшествовала исходной (сейчас раскрываемой)
    // `.cast_interface` — его нужно немедленно маршрутизировать через
    // Local, до выполнения любых СОБСТВЕННЫХ инструкций этой функции,
    // иначе оно окажется погребено под всем, что эта функция вставляет
    // (аллокация/сохранения массива vtable, аллокация box), без
    // возможности снова до него добраться.
    const src_local = try wasm_heap.storeLocal(builder, "@src", layout.ptr_type, v.src);

    const vtable_size = try wasm_heap.addressConst(builder, layout.idx_type, @intCast(v.vtable.len * 4));
    const vtable_array = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = vtable_array, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, vtable_size) } });
    const vtable_array_local = try wasm_heap.storeLocal(builder, "@vtable", layout.ptr_type, vtable_array);

    for (v.vtable, 0..) |binding, i| {
        // Обычные (не-default) методы маршрутизируются через тонкую
        // обёртку-распаковщик box — почему, см. doc-комментарий
        // `wrapperFor`. Методы по умолчанию используют собственный
        // FunctionId напрямую (box И ЕСТЬ та форма, которую они
        // ожидают для `это`).
        const callee = if (binding.is_default) binding.function else try wrapperFor(module, allocator, ctx.type_store, wrapper_of, binding.function);
        const table_index = try tableIndexFor(table, table_index_of, allocator, callee);
        const table_index_const = try wasm_heap.addressConst(builder, layout.idx_type, table_index);
        const offset = try wasm_heap.addressConst(builder, layout.idx_type, @intCast(i * 4));
        const vtable_array_for_addr = try wasm_heap.loadLocal(builder, vtable_array_local, layout.ptr_type);
        const addr = try wasm_heap.binOp(builder, layout.idx_type, .add, vtable_array_for_addr, offset);
        try builder.emit(.{ .mem_store = .{ .addr = addr, .src = table_index_const } });
    }

    const box_size = try wasm_heap.addressConst(builder, layout.idx_type, 8);
    const box = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .call = .{ .dst = box, .callee = alloc_id, .args = try wasm_heap.dupeOne(module, box_size) } });
    const box_local = try wasm_heap.storeLocal(builder, "@box", layout.ptr_type, box);

    // `src` (receiver) перезагружается свежим из `src_local`, ДО `box`
    // (тоже перезагружаемого свежим) — установленное соглашение стека
    // для `mem_store` (`src` первым, `addr` последним/смежным).
    const src_for_receiver = try wasm_heap.loadLocal(builder, src_local, layout.ptr_type);
    const box_for_receiver = try wasm_heap.loadLocal(builder, box_local, layout.ptr_type);
    try builder.emit(.{ .mem_store = .{ .addr = box_for_receiver, .src = src_for_receiver } });

    // `src` (`vtable_array_for_store`) производится ДО `addr`
    // (`vtable_field_addr`) — соглашение `mem_store`: кодогенерация
    // просто выталкивает то, что наверху, как `addr`, и следующее как
    // `src`, без семантической проверки, так что нарушение этого
    // порядка тихо записало бы значение адреса не туда.
    const vtable_array_for_store = try wasm_heap.loadLocal(builder, vtable_array_local, layout.ptr_type);
    const four = try wasm_heap.addressConst(builder, layout.idx_type, 4);
    const box_for_vtable_addr = try wasm_heap.loadLocal(builder, box_local, layout.ptr_type);
    const vtable_field_addr = try wasm_heap.binOp(builder, layout.idx_type, .add, box_for_vtable_addr, four);
    try builder.emit(.{ .mem_store = .{ .addr = vtable_field_addr, .src = vtable_array_for_store } });

    try builder.emit(.{ .load_local = .{ .dst = v.dst, .local = box_local } });
}

// Читает слот vtable по `method_index*4` (ЕДИНСТВЕННАЯ подлинно
// динамическая часть — i32 времени выполнения, неизвестный до
// фактического запуска программы), затем `.call_indirect` с
// `[box] ++ args` — САМ BOX (не распакованный receiver) передаётся
// единообразно в каждый слот vtable; почему — см. doc-комментарий
// `wrapperFor` (обычные методы получают тонкую обёртку-распаковщик
// box, порождённую в их месте `.cast_interface`, методы по умолчанию
// уже ожидают box напрямую как `это`).
fn expandInvokeInterface(builder: *mir_builder.Builder, ctx: ExpandCtx, v: anytype) !void {
    const layout = ctx.layout;

    const box_for_receiver = v.receiver;
    const box_local = try wasm_heap.storeLocal(builder, "@iface_box", layout.ptr_type, box_for_receiver);

    // `v.args` — ТОЖЕ предсуществующие значения (из исходного потока
    // инструкций, произведены до этой `.invoke_interface`) —
    // маршрутизируются через Locals немедленно, то же рассуждение, что
    // и для `v.receiver` выше и `v.src` в `expandCastInterface`,
    // поскольку реально нужны намного позже (после кода поиска vtable
    // ниже).
    const arg_locals = try builder.module.arena.allocator().alloc(mir.LocalId, v.args.len);
    for (v.args, arg_locals) |arg, *local| {
        local.* = try wasm_heap.storeLocal(builder, "@iface_arg", builder.currentFunction().valueType(arg), arg);
    }

    const four = try wasm_heap.addressConst(builder, layout.idx_type, 4);
    const box_for_vtable = try wasm_heap.loadLocal(builder, box_local, layout.ptr_type);
    const vtable_field_addr = try wasm_heap.binOp(builder, layout.idx_type, .add, box_for_vtable, four);
    const vtable_array = try builder.newValue(layout.ptr_type);
    try builder.emit(.{ .mem_load = .{ .dst = vtable_array, .addr = vtable_field_addr } });
    const vtable_array_local = try wasm_heap.storeLocal(builder, "@vtable", layout.ptr_type, vtable_array);

    // Требование стека WASM для `call_indirect` — `[args...,
    // table_index]` (индекс выталкивается ПЕРВЫМ/сверху) — поэтому
    // args (box + реальные аргументы) должны быть произведены ДО
    // `table_index`, а не после, хотя слот vtable, нужный для
    // ВЫЧИСЛЕНИЯ `table_index`, уже прочитан выше; само чтение
    // (`mem_load` в собственный ValueId `table_index`) отложено до
    // момента прямо перед вызовом специально, чтобы оставаться
    // ПОСЛЕДНИМ произведённым операндом.
    const box_for_call = try wasm_heap.loadLocal(builder, box_local, layout.ptr_type);
    const arena = builder.module.arena.allocator();
    var args: std.ArrayList(mir.ValueId) = .empty;
    try args.append(arena, box_for_call);
    for (arg_locals) |local| {
        const arg_type = builder.currentFunction().locals.items[@intFromEnum(local)].type_id;
        try args.append(arena, try wasm_heap.loadLocal(builder, local, arg_type));
    }

    const method_offset = try wasm_heap.addressConst(builder, layout.idx_type, @as(u32, v.method_index) * 4);
    const vtable_array_for_addr = try wasm_heap.loadLocal(builder, vtable_array_local, layout.ptr_type);
    const method_addr = try wasm_heap.binOp(builder, layout.idx_type, .add, vtable_array_for_addr, method_offset);
    const table_index = try builder.newValue(layout.idx_type);
    try builder.emit(.{ .mem_load = .{ .dst = table_index, .addr = method_addr } });

    try builder.emit(.{ .call_indirect = .{ .dst = v.dst, .table_index = table_index, .args = try args.toOwnedSlice(arena) } });
}
