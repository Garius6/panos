# Tasks: HTTP-сервер как языковая возможность panos

**Input**: Design documents from `/specs/009-http-server/`
**Prerequisites**: plan.md, research.md, data-model.md, quickstart.md

**Tests**: включены — `odin test ./core` с РЕАЛЬНЫМИ сокетами (тот же
приём, что `core/e2e_async_io_test.odin` уже использует для
`сеть.подключиться`), плюс ручной `curl`-прогон в конце (quickstart.md).
Не 1С-специфичная фича — реальный внешний мир доступен, ничего не
подделывается.

**Organization**: одна user story (P1) в spec.md — без отдельной
Foundational-фазы.

## Format: `[ID] [P?] [Story] Description`

## Phase 1: Setup

- [X] T001 Автономный smoke-test `external/odin-http/server.odin` (временная программа ВНЕ `core/`, например `/tmp` или scratch — не коммитится): `http.listen_and_serve` на тестовом порту + `curl` с него — подтвердить, что вендоренная библиотека реально работает как сервер, ДО интеграции с panos (research.md §1 — де-риск самой библиотеки отдельно от моста)

**Checkpoint**: `external/odin-http` подтверждён рабочим как сервер сам по себе.

---

## Phase 2: User Story 1 - Принять запрос и ответить (Priority: P1) 🎯 MVP

**Goal**: `сеть.http_сервер_слушать(порт)` + `.принять_запрос()`/
`Запрос.ответить(...)` — реальный HTTP-запрос снаружи получает реальный
ответ от panos-кода.

**Independent Test**: см. spec.md Independent Test — `curl` против
panos-скрипта с accept-loop.

### Tests for User Story 1 ⚠️

> Пишутся ПЕРВЫМИ, должны ПАДАТЬ до реализации ниже (не скомпилируются —
> новых builtin'ов ещё нет).

- [X] T002 [P] [US1] `core/e2e_http_server_test.odin`: panos-скрипт слушает порт + принимает 1 запрос, Odin-тест выступает КЛИЕНТОМ (реальное TCP-соединение, сырой `GET /` HTTP/1.1 запрос) — проверить код/заголовки/тело ответа совпадают с тем, что послал panos-код (Acceptance Scenario 1)
- [X] T003 [P] [US1] Тот же файл — запрос с телом (`POST` с произвольным текстом) — panos-код видит тело через `запрос.тело()` (Acceptance Scenario 2)
- [X] T004 [P] [US1] Тот же файл — клиент обрывает TCP-соединение ДО того, как panos успел вызвать `ответить(...)` — `ответить(...)` возвращает `Результат.Неудача`, НЕ паникует, сервер продолжает жить (Edge Case)
- [X] T005 [P] [US1] Тот же файл — двойной вызов `ответить(...)` на одном запросе — второй вызов `Результат.Неудача` (data-model.md `responded`-флаг)
- [X] T006 [US1] Тот же файл — НЕСКОЛЬКО panos-процессов вызывают `.принять_запрос()` на ОДНОМ слушателе, несколько curl ОДНОВРЕМЕННО — все получают правильные ответы, ни один не блокирует другие (Acceptance Scenario 3/SC-002)
- [X] T007 [US1] Тот же файл — `сеть.http_сервер_слушать(порт)` на УЖЕ занятом порту — `Результат.Неудача`, не паника (Edge Case)

### Implementation for User Story 1

- [X] T008 [US1] `core/vm_async.odin`: новый вариант `Async_Result` — `Http_Accept_Result_Data{req: ^Bridge_Request}` (data-model.md) — зависит от T001
- [X] T009 [US1] `core/vm_http_server_native.odin` (новый файл, `#+build !js`): `Http_Listener_Value`/`Http_Request_Value`/`Bridge_Request`/`Bridge_Response` (data-model.md); `сеть.http_сервер_слушать(порт)` — выделенный `thread.create_and_start` (НЕ `vm.async_pool` — research.md §1.1); отличие от исходного плана: `listen()` и `serve()` ОБА вызываются на этом выделенном потоке (не только `serve()`) — `http.listen()` привязывает nbio-event-loop к вызывающему ОС-потоку, а `serve()` читает именно этот thread-local loop, поэтому их нельзя разносить по потокам (найдено эмпирически, `EXC_BAD_ACCESS` на первом e2e-прогоне); результат `listen()` возвращается синхронному builtin'у через одноразовый `Http_Listen_Result`-канал. Handler регистрирует `http.body(...)`-callback (research.md §1.3); внутри callback'а — построение `Bridge_Request` со свежим `response_chan` (cap=1), `chan.send(listener.incoming, ...)`, синхронный `chan.recv(response_chan)`, затем `body_set`/`response_status`/`respond` (research.md §1.2, §2) — зависит от T008
- [X] T010 [US1] Тот же файл: `.принять_запрос()` — `submit_async_io_method` case (не `submit_async_io` — это МЕТОД на `Слушатель`, не module-level функция), воркер делает `chan.recv(listener.incoming)` (обычная задача `vm.async_pool` — research.md §3), без `gc_pin` (воркер копирует только плоское значение канала, не трогает сам GC-объект); `core/vm.odin`: ветка `deliver_async_result` для `Http_Accept_Result_Data`, строящая `Http_Request_Value` — зависит от T009
- [X] T011 [US1] Тот же файл: методы `Запрос.метод()`/`.путь()`/`.заголовки()`/`.тело()` (простые accessor'ы над уже скопированными полями) + `.ответить(статус, тип, тело)` — синхронный builtin, `chan.try_send(response_chan, ...)` (research.md §7), проверка `responded`-флага (data-model.md) — зависит от T010
- [X] T012 [US1] `core/vm_http_server_wasm.odin` (новый файл, `#+build js`): те же имена функций, `fmt.panicf` при вызове — тот же паттерн, что `vm_http_wasm.odin` (research.md §8, FR-007) — зависит от T009
- [X] T013 [US1] `core/compiler.odin`: отличие от исходного плана — НЕ запись в `is_async_builtin_name` (там нет `"сеть::http_принять"`, это не module-level функция), а `is_async_stream_method` расширен на `TY_HTTP_LISTENER` → `"принять_запрос"`, тот же механизм, что у `Файл`/`Соединение`-стриминга — зависит от T010
- [X] T014 [US1] `core/stdlib.odin`: регистрация типов `Слушатель`/`Запрос` и их методов под модулем `"сеть"` (тот же паттерн, что `Соединение`/`Файл`) — зависит от T009-T011
- [X] T015 [US1] Прогнать `odin test ./core` — T002-T007 зелёные (279/279 тестов проходят, 0 регрессий). По пути найдены и исправлены два реальных бага: (1) `context.allocator` на воркер-потоках odin-http ненадёжно наследовал `vm_heap_allocator()` через ambient context — `http_handler_proc`/`http_on_body_read` переведены на явный `vm_heap_allocator()` везде (тот же класс бага, что уже задокументирован в `deliver_async_result`); (2) `test_http_server_concurrent_processes` изначально зависал — `run_scheduler` возвращается СРАЗУ, как только процесс 0 (`старт()`) завершается, не дожидаясь спавненных детей (задокументированное поведение, `test_actor_spawn_send_start_exits_without_waiting_for_child`) — тест переписан так, что `старт()` дожидается `Уведомление.Готово` от обоих обработчиков через `получить()`/`отправить()` перед завершением

**Checkpoint**: HTTP-сервер работает end-to-end — самостоятельно тестируемый MVP.

---

## Phase 3: Polish & Cross-Cutting Concerns

- [X] T016 [P] Прогнать `quickstart.md` целиком вручную (реальный `curl`, оба сценария — базовый и конкурентный) — оба подтверждены; `quickstart.md`'s конкурентный пример тоже содержал ту же "старт() не ждёт детей" ошибку (плюс несуществующий `порождать`) — исправлен на паттерн "старт() сам — один из обработчиков"
- [X] T017 [P] Добавить раздел про HTTP-сервер в `docs/src/architecture/compiler-and-vm.md` § "Неблокирующий I/O" (тот же паттерн документирования, что уже у остального non-blocking-actor-io) — три ограничения odin-http (research.md §1) плюс четвёртое, найденное при реализации (listen/serve — один поток), поток данных (research.md §2), и планировщик-gotcha про `старт()`/спавненных детей
- [X] T018 Финальный полный `odin test ./core` — 279/279, 0 регрессий

---

## Dependencies & Execution Order

- Setup (T001) → US1 (T002-T015) → Polish (T016-T018)
- Внутри US1: тесты (T002-T007) пишутся и ПАДАЮТ до реализации; T008 → T009 → T010 → T011 → (T012 параллельно с T010/T011, зависит только от T009) → T013 → T014 → T015
