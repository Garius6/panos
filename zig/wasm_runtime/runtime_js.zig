// Браузерная половина AOT-рантайма (зеркалит экспортируемые имена/сигнатуры
// `runtime_wasi.zig`, но с другой хост-привязкой: JS-модуль импорта
// "js_runtime" вместо WASI-сисколов). `pw_print_string`/`pw_println_string`
// здесь не реализованы — им нужен рантайм таблицы объектов
// (arena/obj_offsets/obj_sizes), которого пока нет; экспортированы только две
// функции часов.
extern "js_runtime" fn now_ms() f64;
extern "js_runtime" fn monotonic_ms() f64;

pub export fn panos_runtime_abi_version() u32 {
    return 0;
}

pub export fn pw_monotonic_ms() f64 {
    return monotonic_ms();
}

pub export fn pw_now_ms() f64 {
    return now_ms();
}
