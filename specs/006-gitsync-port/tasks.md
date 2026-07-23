---
description: "Task list for 006-gitsync-port"
---

# Tasks: Портирование ядра gitsync на panos

**Input**: Design documents from `/specs/006-gitsync-port/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: Включены — spec.md Success Criteria требуют e2e-проверки цикла
синхронизации (SC-003 — прерывание/возобновление), research.md §7
фиксирует решение тестировать через `fake_1cv8.sh` (тот же приём, что
`v8runner`/`v8storage`) + РЕАЛЬНЫЙ git (`gitrunner`).

**Organization**: Задачи сгруппированы по 3 user story (P1/P2/P3 из
spec.md). В отличие от 005 — здесь ЕСТЬ настоящая Foundational-фаза:
`version_file.ps`/`authors_file.ps` используются ВСЕМИ тремя story
(`sync` читает/пишет оба; `init` создаёт их шаблоны; `set-version`
пишет VERSION).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: можно выполнять параллельно (разные файлы/нет зависимости от
  незавершённых задач)
- **[Story]**: US1/US2/US3 из spec.md
- Точные пути к файлам указаны в описании каждой задачи

## Path Conventions

Новый самостоятельный пакет — `../panosiki/gitsync/` (свой git-репозиторий,
тот же паттерн, что остальные 7 зависимостей). Импорт зависимостей — через
`pan add` + путь внутрь `модули/` (research.md §8):
`импорт "модули/gitrunner/git.ps" как гит`,
`импорт "модули/v8runner/configurator.ps" как v8`,
`импорт "модули/v8storage/storage_manager.ps" как хран`,
`импорт "модули/cli/флаги.ps" как флаги`.

---

## Phase 1: Setup

**Purpose**: Инициализация пакета + подключение уже реализованных
зависимостей через `pan add`

- [X] T001 `pan init` в `../panosiki/gitsync/` (новый git-репозиторий,
  `pan.toml` + `start.ps`-заглушка) — тот же процесс, что 7 уже
  существующих пакетов
- [X] T002 `pan add /абсолютный/путь/panosiki/gitrunner ^0.1.1` в
  `../panosiki/gitsync/`
- [X] T003 `pan add /абсолютный/путь/panosiki/v8runner ^0.1.1`
- [X] T004 `pan add /абсолютный/путь/panosiki/v8storage ^0.1.1`
- [X] T005 `pan add /абсолютный/путь/panosiki/cli ^0.1.1`
- [X] T005a `pan add /абсолютный/путь/panosiki/tempfiles ^0.1.1` —
  найдено при исполнении: research.md §3 нужен `tempfiles.Менеджер` для
  временного .cf-файла в `sync.ps`, изначально пропущен в списке T002-T005
- [X] T006 Sanity: временный `.ps`-файл в `../panosiki/gitsync/`,
  импортирующий все 4 через `модули/<имя>/<файл>.ps` (см. Path
  Conventions), вызывающий по одному конструктору из каждого
  (`новый_репозиторий()`/`новый_конфигуратор()`/`новое_хранилище()`/
  `новая_конфигурация()`) — подтвердить, что резолвится РЕАЛЬНАЯ
  реализация (`git ls-files модули/gitrunner/` содержит `git.ps` с
  реальным содержимым, не заглушку), затем удалить временный файл

**Checkpoint**: Зависимости подключены и резолвятся правильно — можно
начинать Foundational.

---

## Phase 2: Foundational

**Purpose**: `VERSION`/`AUTHORS` — файлы, читаемые/пишемые ВСЕМИ тремя
user story (см. data-model.md)

**⚠️ CRITICAL**: Блокирует все 3 user story — `sync`/`init`/`set-version`
все обращаются к этим двум файлам одним и тем же кодом.

- [X] T007 [P] Написать тесты `version_file.ps` в
  `../panosiki/gitsync/test_version_file.ps` (`std/тест.ps`): нет
  файла → `0`; файл с `"3"` → `3`; запись `N` → перечитывается как `N`;
  файл с мусором (не число) → понятная ошибка, не паника вглубь
  `строки.в_число`
- [X] T008 [US-shared] Реализовать `../panosiki/gitsync/version_file.ps`:
  `прочитать_версию(рабочий_каталог: Строка) -> Число` (нет файла → `0`),
  `записать_версию(рабочий_каталог: Строка, версия: Число) ->
  Результат(Число, Ошибка)` (зависит от T007)
- [X] T009 [P] Написать тесты `authors_file.ps` в
  `../panosiki/gitsync/test_authors_file.ps`: TOML с 2 пользователями —
  поиск существующего возвращает `имя`+`email`, поиск несуществующего —
  `Опция.Нет` (не паника, см. FR-005); `пустой_шаблон()` — валидный TOML,
  парсится обратно без ошибок
- [X] T010 [US-shared] Реализовать `../panosiki/gitsync/authors_file.ps`:
  `тип Автор = структура имя: Строка email: Строка конец`,
  `прочитать_authors(путь: Строка) -> Соответствие(Строка, Автор)` (нет
  файла → пустое соответствие), `найти_автора(...) -> Опция(Автор)`,
  `пустой_шаблон() -> Строка` (для `init`, см. data-model.md) — зависит
  от T009
- [X] T011 Прогнать `panos test_version_file.ps` и
  `panos test_authors_file.ps` — тесты T007/T009 зелёные

**Checkpoint**: `VERSION`/`AUTHORS` работают независимо — US1/US2/US3
могут начинаться.

---

## Phase 3: User Story 1 - Синхронизация хранилища с git (Priority: P1) 🎯 MVP

**Goal**: `gitsync sync ПУТЬ РАБОЧИЙ_КАТАЛОГ` — полный цикл: новые версии
хранилища → файлы исходников → git-коммиты с правильным автором →
`VERSION` обновлён.

**Independent Test**: Bare git-репозиторий + `fake_1cv8.sh`,
симулирующий 3 версии хранилища — `sync` даёт 3 коммита, `VERSION` = `3`.

### Tests for User Story 1 ⚠️

> Пишутся ПЕРВЫМИ, должны ПАДАТЬ до реализации ниже.

- [ ] T012 [P] [US1] Расширить `../panosiki/gitsync/fake_1cv8.sh` (копия
  паттерна `v8runner`/`v8storage`, см. research.md §7): при `-v N` в
  аргументах — код возврата `0` и фиктивное содержимое в целевой файл,
  если `N <= $GITSYNC_TEST_MAX_VERSION`, иначе код `1`
- [X] T013 [US1] Написать e2e-тест "полная синхронизация" в
  `../panosiki/gitsync/test_sync.ps`: bare+рабочий git-репозиторий
  (реальный `gitrunner`, тот же приём, что `test_gitrunner.ps`),
  `Контекст_Синхронизации` указывает на `fake_1cv8.sh` с
  `GITSYNC_TEST_MAX_VERSION=3`, `VERSION` отсутствует — после `sync`: 3
  коммита, `VERSION` = `3` (Acceptance Scenario 1)
- [X] T014 [US1] В том же файле — тест "частичная синхронизация":
  `VERSION` уже `2` — после `sync` создаётся РОВНО 1 новый коммит,
  `VERSION` = `3` (Acceptance Scenario 2)
- [X] T015 [US1] В том же файле — тест "нечего синхронизировать":
  `VERSION` уже `3` (равен максимуму) — `sync` не создаёт коммитов,
  завершается успешно, не ошибкой (Acceptance Scenario 3/FR-004)
- [X] T016 [US1] В том же файле — тест "прерывание на середине":
  `GITSYNC_TEST_MAX_VERSION=2` (версия 3 недоступна/ошибка) — после
  `sync` создано 2 коммита, `VERSION` = `2`, НЕ `3` (SC-003/Edge Case)
- [X] T017 [US1] В том же файле — тест "автор из AUTHORS" (уточнено при
  планировании — ОДИН автор на весь запуск sync, не по-версионно, см.
  spec.md Assumptions про MXL/COM-недоступность): `AUTHORS` содержит
  запись для `контекст.пользователь_хранилища` этого запуска — ВСЕ
  коммиты сделаны с этим автором (`git log --format='%an %ae'`); ВТОРОЙ
  тест в этом же файле — пользователь БЕЗ записи в `AUTHORS` — коммиты
  всё равно создаются, автор = имя пользователя хранилища, без паники
  (Acceptance Scenario 4/FR-005)

### Implementation for User Story 1

- [X] T018 [US1] Реализовать `../panosiki/gitsync/sync.ps`:
  `получить_известные_версии(хранилище, начиная_с: Число) -> Число` —
  перебор `Хранилище.версию_в_файл(строки.из_числа(N), temp_путь)` от
  `начиная_с+1`, пока не `Результат.Неудача` (research.md §1) —
  зависит от T012 (тестируется через fake-бинарь)
- [X] T019 [US1] Реализовать в `sync.ps`: `выгрузить_версию_в_рабочий_
  каталог(v8, хранилище, N, рабочий_каталог)` — v8storage.версию_в_файл
  во временный .cf (`tempfiles.Менеджер`) → v8runner.Конфигуратор без
  контекста: `загрузить_конфигурацию_из_файла` + `выгрузить_
  конфигурацию_в_файлы(рабочий_каталог)` → удалить временный .cf
  (research.md §3) — зависит от T002-T004 (модули)
- [X] T020 [US1] Реализовать в `sync.ps`: `закоммитить_версию(репо,
  N, автор: Опция(Автор))` — `git add .` через `Репозиторий.выполнить_
  команду` (research.md §4), `установить_настройку("user.name"/"user.
  email", ...)` из автора ПЕРЕД `закоммитить` (research.md §2, только
  если автор есть — см. FR-005), затем `закоммитить("Версия N")`
- [X] T021 [US1] Реализовать `синхронизировать(контекст: Контекст_
  Синхронизации) -> Результат(Результат_Синхронизации, Ошибка)` в
  `sync.ps` — оркестрация T018-T020 + `version_file.записать_версию`
  ТОЛЬКО после успешного коммита каждой версии (зависит от T008, T010,
  T018-T020). Автор резолвится ОДИН РАЗ (через `authors_file.найти_
  автора(авторы, контекст.пользователь_хранилища)`) ДО цикла по версиям
  — не по-версионно (см. T017/spec.md Assumptions)
- [X] T022 [US1] Подключить подкоманду `sync`/`s` в
  `../panosiki/gitsync/start.ps` — флаги `--storage-user`/`-u`,
  `--storage-pwd`/`-p`, `--ext`/`-e` (`модули/cli/флаги.ps`), позиционные
  `ПУТЬ_ХРАНИЛИЩА`/`РАБОЧИЙ_КАТАЛОГ`, fallback на переменные окружения
  `GITSYNC_STORAGE_*`/`GITSYNC_WORKDIR` (contracts/cli-surface.md,
  FR-008/FR-009)
- [X] T023 [US1] Прогнать `panos test_sync.ps` — тесты T013-T017
  зелёные, регрессий в T007/T009 (Foundational) нет

**Checkpoint**: US1 — самостоятельно рабочий MVP (`sync` полностью
функционален независимо от `init`/`set-version`, если `VERSION`/`AUTHORS`
уже существуют вручную).

---

## Phase 4: User Story 2 - Подготовка нового репозитория (Priority: P2)

**Goal**: `gitsync init ПУТЬ РАБОЧИЙ_КАТАЛОГ` — идемпотентная
инициализация git-репозитория + шаблонов `VERSION`/`AUTHORS`.

**Independent Test**: `init` на пустом каталоге создаёт `.git/`+
`VERSION`(`0`)+`AUTHORS`(шаблон); повторный `init` их не трогает.

### Tests for User Story 2 ⚠️

> Пишутся ПЕРВЫМИ, должны ПАДАТЬ до реализации ниже.

- [X] T024 [US2] Написать e2e-тесты в
  `../panosiki/gitsync/test_repo_init.ps`: (1) `init` на ПУСТОМ каталоге
  — становится git-репозиторием, `VERSION` = `0`, `AUTHORS` — валидный
  пустой TOML-шаблон (Acceptance Scenario 1); (2) `init` на уже
  проинициализированном каталоге С изменённым (не дефолтным) `VERSION`/
  `AUTHORS` — файлы НЕ перезаписываются (Acceptance Scenario 2)

### Implementation for User Story 2

- [X] T025 [US2] Реализовать `../panosiki/gitsync/repo_init.ps`:
  `инициализировать(рабочий_каталог: Строка) -> Результат(Строка,
  Ошибка)` — `Репозиторий.это_репозиторий()`/`инициализировать()` только
  если ещё не git-репозиторий; `VERSION`/`AUTHORS` создаются ТОЛЬКО если
  `фс.есть(...)` ложь (используя `version_file.записать_версию(...,
  0)`/`authors_file.пустой_шаблон()`, зависит от T008, T010)
- [X] T026 [US2] Подключить подкоманду `init` в `start.ps` (те же флаги/
  env vars контекста, что `sync`, минус `--ext` — `init` не работает с
  расширением конфигурации)
- [X] T027 [US2] Прогнать `panos test_repo_init.ps` — тесты T024
  зелёные

**Checkpoint**: US1 и US2 работают независимо — `just`-эквивалентный
прогон обоих тестовых файлов пакета зелёный.

---

## Phase 5: User Story 3 - Ручная установка номера версии (Priority: P3)

**Goal**: `gitsync set-version НОМЕР РАБОЧИЙ_КАТАЛОГ` — перезапись
`VERSION`.

**Independent Test**: `set-version 5` → `VERSION` = `5`, следующий `sync`
начинает с версии 6.

### Tests for User Story 3 ⚠️

> Пишутся ПЕРВЫМИ, должны ПАДАТЬ до реализации ниже.

- [X] T028 [US3] Написать e2e-тесты в
  `../panosiki/gitsync/test_set_version.ps`: `set-version 10` на каталоге
  с `VERSION`=`2` → `VERSION`=`10` (Acceptance Scenario 1);
  нечисловой/отрицательный аргумент → ошибка, `VERSION` не изменяется
  (FR-007)

### Implementation for User Story 3

- [X] T029 [US3] Реализовать `../panosiki/gitsync/set_version.ps`:
  `установить_версию(рабочий_каталог: Строка, номер: Строка) ->
  Результат(Число, Ошибка)` — парсинг `номер` через `строки.в_число` +
  проверка неотрицательности ДО вызова `version_file.записать_версию`
  (зависит от T008)
- [X] T030 [US3] Подключить подкоманду `set-version`/`sv` в `start.ps`
- [X] T031 [US3] Прогнать `panos test_set_version.ps` — тесты T028
  зелёные

**Checkpoint**: Все три user story работают независимо — полный
тестовый набор пакета зелёный.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [X] T032 [P] Прогнать `quickstart.md` целиком вручную (`fake_1cv8.sh`
  + реальный git, без установленной платформы 1С)
- [X] T033 [P] Тег `v0.1.0` в `../panosiki/gitsync/` (первый релиз пакета,
  тот же паттерн, что остальные 7 зависимостей)
- [X] T034 Финальный полный прогон всех `test_*.ps` пакета
  (`test_version_file.ps`, `test_authors_file.ps`, `test_sync.ps`,
  `test_repo_init.ps`, `test_set_version.ps`) — 0 регрессий

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: без зависимостей
- **Foundational (Phase 2)**: зависит от Setup (нужны подключённые
  зависимости для `фс`/`строки`, уже builtin — Foundational реально не
  требует T002-T005, но следует после них по номеру для простоты) —
  БЛОКИРУЕТ все 3 user story
- **US1 (Phase 3)**: зависит от Foundational (version_file/authors_file)
  и Setup (T002-T004 — gitrunner/v8runner/v8storage)
- **US2 (Phase 4)**: зависит от Foundational — НЕ зависит от US1 (не
  использует `sync.ps` вообще)
- **US3 (Phase 5)**: зависит только от Foundational (`version_file.ps`)
  — НЕ зависит от US1/US2
- **Polish (Phase 6)**: после всех выбранных user story

### Within Each User Story

- Тесты (T013-T017, T024, T028) пишутся и ПАДАЮТ до соответствующей
  реализации
- US1: T018 → T019 → T020 → T021 (последовательная зависимость внутри
  `sync.ps`) → T022 → T023
- US2: T025 → T026 → T027
- US3: T029 → T030 → T031

### Parallel Opportunities

- T007/T009 (Foundational, тесты) — разные файлы, параллельно
- T002-T005 (Setup, `pan add`) — независимые команды, но пишут в один
  `pan.toml`/`pan.lock` — практическая последовательность важнее
  теоретической независимости (как в 005 с `core/parser.odin`)
- После Foundational — US2 (Phase 4) и US3 (Phase 5) параллельны друг
  другу и с US1 (Phase 3), если есть ресурсы на несколько потоков работы
- T032/T033 (Polish) — независимы, параллельно

---

## Parallel Example: Foundational

```bash
Task: "Написать тесты version_file.ps в test_version_file.ps"
Task: "Написать тесты authors_file.ps в test_authors_file.ps"
```

---

## Implementation Strategy

### MVP First

1. Phase 1: Setup
2. Phase 2: Foundational (VERSION/AUTHORS — блокирует всё)
3. Phase 3: US1 (`sync`) — весь смысл фичи
4. **STOP и проверить**: `test_sync.ps` зелёный, quickstart.md `sync`-раздел
   работает (на заранее вручную созданных VERSION/AUTHORS)

### Incremental Delivery

1. Setup → Foundational → US1 → проверить независимо (MVP)
2. US2 (`init`) → проверить независимо — теперь `VERSION`/`AUTHORS` не
   нужно создавать вручную перед первым `sync`
3. US3 (`set-version`) → проверить независимо
4. Polish → quickstart.md целиком + тег пакета + финальный прогон

---

## Notes

- [P] между T002-T005 (Setup) намеренно не проставлен — все четыре
  команды `pan add` пишут в один и тот же `pan.toml`/`pan.lock`
  последовательно, даже при формальной независимости источников
- Каждый `test_*.ps` — отдельный файл на свою область (version_file/
  authors_file/sync/repo_init/set_version), не один общий тестовый файл
  — так же как у `gitrunner`/`v8runner`/`v8storage` (`test_gitrunner.ps`/
  `test_configurator.ps`/`test_storage_manager.ps`)
