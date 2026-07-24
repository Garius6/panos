# Data Model: HTTP-сервер как языковая возможность panos

## panos-facing API

```panos
сеть.http_сервер_слушать(порт: Число) -> Результат(Слушатель, Ошибка)

// Слушатель — opaque-тип, как Соединение/Файл (несёт живой ресурс).
Слушатель.принять_запрос() -> Результат(Запрос, Ошибка)   // async (Await_Async)
Слушатель.закрыть() -> Пусто                                // sync, graceful shutdown

// Запрос — opaque-тип, несёт скрытую ссылку на response_chan.
Запрос.метод() -> Строка         // "GET"/"POST"/...
Запрос.путь() -> Строка          // "/api/x"
Запрос.заголовки() -> Соответствие(Строка, Строка)
Запрос.тело() -> Строка          // уже полностью прочитано (Assumptions, spec.md)
Запрос.ответить(статус: Число, тип_содержимого: Строка, тело: Строка) -> Результат(Пусто, Ошибка)  // sync
```

## Odin-side (внутренний слой, `core/vm_http_server_native.odin`)

### `Http_Listener_Value` (новый GC-тип, тот же слой, что `Socket_Value`/`File_Value`)

```odin
Http_Listener_Value :: struct {
    header:        Object_Header,
    srv:           http.Server,          // из external/odin-http
    incoming:      chan.Chan(rawptr),    // rawptr -> ^Bridge_Request, cap фиксированная (research.md §4)
    listen_thread: ^thread.Thread,
    is_open:       bool,
}
```

### `Bridge_Request` (ПЛОСКИЕ Odin-данные — единственное, что видят воркер-потоки, никогда не GC-Value)

```odin
Bridge_Request :: struct {
    method:        string,
    path:          string,
    header_keys:   []string,
    header_values: []string,             // параллельный массив — как header_pairs у http-клиента
    body:          string,
    response_chan: chan.Chan(Bridge_Response), // cap = 1, создаётся ПЕРЕД chan.send в incoming
}

Bridge_Response :: struct {
    status:       int,
    content_type: string,
    body:         string,
}
```

### `Http_Request_Value` (новый GC-тип на panos-стороне после доставки)

```odin
Http_Request_Value :: struct {
    header:        Object_Header,
    method:        string,
    path:          string,
    header_keys:   []string,
    header_values: []string,
    body:          string,
    response_chan: chan.Chan(Bridge_Response), // тот же канал, теперь виден panos-стороне
    responded:     bool,                        // повторный .ответить() — Результат.Неудача, не паника
}
```

### Новый вариант `Async_Result` (`core/vm_async.odin`, платформонезависимая часть)

```odin
Http_Accept_Result_Data :: struct {
    req: ^Bridge_Request,   // из vm_heap_allocator(), освобождается после переноса полей в Http_Request_Value
}
```

## Поток данных при `Слушатель.принять_запрос()`

1. Компилятор эмитит `Call_Builtin_Async("сеть::http_принять")` + `Await_Async` (по аналогии с tcp-connect).
2. `submit_async_io` (native): `thread.pool_add_task` с задачей: `chan.recv(listener.incoming)` (плоский `rawptr`), оборачивает в `Async_Result{Http_Accept_Result_Data{req = ...}}`, кладёт в `vm.async_completions`.
3. `run_scheduler`/`drain_async_completions` (главный поток) находит целевой процесс по id, вызывает `deliver_async_result`.
4. `deliver_async_result`, новая ветка: строит `Http_Request_Value` из `Bridge_Request` (копирует поля, GC-регистрирует), `gc_new`, кладёт как `Value` в `target.async_results`.
5. `Await_Async` в панос-коде получает эту `Value` как результат `Результат.Успех(Запрос)`.

## Поток данных при `Запрос.ответить(...)`

1. Синхронный builtin (`invoke_io_method`-подобный switch, НЕ через async-пул — быстрая локальная передача по каналу).
2. Если `req.responded` — `Результат.Неудача("уже отвечено на этот запрос")`.
3. `chan.try_send(req.response_chan, Bridge_Response{status, content_type, body})` — при неудаче (получателя уже нет, research.md §7) — `Результат.Неудача`, иначе `req.responded = true`, `Результат.Успех(Пусто)`.
