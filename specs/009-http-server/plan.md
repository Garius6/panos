# Implementation Plan: HTTP-сервер как языковая возможность panos

**Branch**: `009-http-server` | **Date**: 2026-07-23 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/009-http-server/spec.md`

## Summary

Мост между вендоренным `external/odin-http/server.odin` (свой event
loop + пул потоков, БЛОКИРУЮЩИЙ `serve()`/callback-based чтение тела —
см. research.md §1) и однопоточным panos-VM: новый opaque-тип
`Слушатель` (свой выделенный `thread.create_and_start`, не
`vm.async_pool` — тот блокировался бы навсегда), `.принять_запрос()`
как обычный `Await_Async`-builtin через уже существующий пул (воркер —
`chan.recv` на канале входящих запросов), `Запрос.ответить(...)` —
синхронный builtin, доставляющий ответ через per-request канал, на
котором odin-http-поток синхронно ждёт (`respond()` привязан к своему
потоку — research.md §1.2).

## Technical Context

**Language/Version**: Odin (toolchain pinned via `Justfile`), stdlib
`core:sync/chan`, `core:thread`, `core:net` (native only).
**Primary Dependencies**: `external/odin-http/server.odin` (уже
вендорено, используется впервые — до этого пакет использовался только
клиентской частью), никаких новых внешних зависимостей.
**Storage**: N/A.
**Testing**: РЕАЛЬНЫЙ сквозной прогон — `curl`/HTTP-клиент с другого
процесса против panos-скрипта, слушающего локальный порт (spec.md
Independent Test) — не 1С-специфичная фича этого проекта, здесь нет
недоступного внешнего мира, тестируем по-настоящему. Плюс `odin test
./core` для типовых unit-сценариев моста, где возможно без реального
сокета (парсинг Bridge_Request -> Http_Request_Value и т.п.).
**Target Platform**: нативно (macOS/Linux/Windows) — НЕ wasm (FR-007,
серверные сокеты бессмысленны в браузере).
**Project Type**: core-языковая фича компилятора (новый native builtin
слой), не пользовательский panos-пакет.
**Performance Goals**: не формализованы отдельно — потолок одновременно
обрабатываемых запросов ограничен `Server_Opts.thread_count`
нижележащей библиотеки (research.md §4), не переопределяется этой
фичей.
**Constraints**: `external/odin-http/server.odin` используется КАК ЕСТЬ,
не форкается (Assumptions, spec.md) — `respond()`'s thread-affinity
(research.md §1.2) и callback-based чтение тела (§1.3) — жёсткие
ограничения библиотеки, дизайн моста подстраивается под них, а не
наоборот.
**Scale/Scope**: один новый файл-пара (native/wasm), один новый
`Async_Result`-вариант, два новых GC-типа (`Http_Listener_Value`,
`Http_Request_Value`), регистрация типов в `core/stdlib.odin`, записи в
`is_async_builtin_name`/связанные таблицы `core/compiler.odin`.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **Think Before Coding**: три реальных ограничения библиотеки
  (блокирующий `serve()`, потоко-привязанный `respond()`,
  callback-based тело) обнаружены ЧТЕНИЕМ реального кода
  `external/odin-http`, не предположены — задокументированы в
  research.md §1 ДО написания кода моста.
- **Simplicity First**: НЕ форкаем/патчим `external/odin-http` ради
  снятия его ограничений (например, потолка `thread_count`
  одновременных запросов) — дизайн моста работает В РАМКАХ
  существующей библиотеки, не расширяет её.
- **Surgical Changes**: новый файл-пара `vm_http_server_{native,wasm}.
  odin`, НЕ трогает существующие `vm_http_native.odin`(клиент)/
  `vm_io_native.odin`(сокеты) — отдельная возможность, не вариант уже
  существующих. Одна точка пересечения с существующим кодом —
  `vm_async.odin` (новый вариант `Async_Result`, тот же паттерн, что уже
  там для tcp-connect) и `compiler.odin` (allowlist-таблицы, дописать
  одну запись, не менять существующую логику).

Нарушений нет.

## Project Structure

### Documentation (this feature)

```text
specs/009-http-server/
├── plan.md              # этот файл
├── research.md          # Phase 0 — три реальных ограничения odin-http, поток данных запроса, backpressure/параллелизм
├── data-model.md         # Phase 1 — Http_Listener_Value/Bridge_Request/Http_Request_Value, panos-facing API
└── quickstart.md         # Phase 1 — ручная проверка через реальный curl
```

Без `contracts/` — новый языковой builtin, не HTTP/CLI-контракт в
привычном смысле; сам API (`data-model.md`) и есть контракт.

### Source Code (repository root)

```text
core/
├── vm_http_server_native.odin   # НОВЫЙ: Http_Listener_Value, Http_Request_Value, listen/accept/respond builtins, поток odin-http.serve
├── vm_http_server_wasm.odin     # НОВЫЙ: те же имена функций, fmt.panicf при вызове (как vm_http_wasm.odin)
├── vm_async.odin                # + Http_Accept_Result_Data (платформонезависимая часть)
├── compiler.odin                # + запись в is_async_builtin_name ("сеть::http_принять")
├── stdlib.odin                  # + регистрация типов Слушатель/Запрос и их методов под модулем "сеть"
└── vm.odin                      # + ветка deliver_async_result для Http_Accept_Result_Data
```

**Structure Decision**: весь новый код — внутри `core/`, новый
файл-пара по образцу уже 8 существующих native/wasm пар (research.md
§8) — ни один существующий native/wasm файл не редактируется, кроме
трёх ТОЧЕЧНЫХ дополнений (allowlist-запись, регистрация типа,
одна новая ветка в уже существующем switch на `Async_Result`-вариант).

## Complexity Tracking

Нарушений конституции нет — секция не заполняется.
