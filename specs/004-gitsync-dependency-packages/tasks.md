---

description: "Task list template for feature implementation"
---

# Tasks: Пакеты-заготовки для зависимостей gitsync

**Input**: Design documents from `/specs/004-gitsync-dependency-packages/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: Не запрошены явно, кроме регрессии для нового stdlib-модуля
`слог` (US2) — единственной новой логики в этой фиче; 7 пакетов-заготовок
(US1) не содержат логики (FR-003), тестировать нечего, только структурную
валидность.

**Organization**: US1 и US2 — оба P1, полностью независимы друг от друга
(разные репозитории/файлы, ничего общего не трогают) — могут выполняться
параллельно. US3 — P2, отдельного нового артефакта не создаёт (карта уже
существует как таблица в `spec.md`), задача — финальная сверка.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: можно выполнять параллельно (разные файлы/репозитории, нет
  зависимости от незавершённых задач)
- **[Story]**: US1/US2/US3 из spec.md

## Path Conventions

- US1: `../panosiki/<латинское-имя>/` (7 новых независимых git-репозиториев)
- US2: `std/слог.ps` + тест в `core/` (этот репозиторий)
- US3: `specs/004-gitsync-dependency-packages/spec.md` (уже существует)

---

## Phase 1: Setup

**Purpose**: Подтвердить, что фундамент (из feature 003) на месте — без
него ни `pan init`, ни `pan add` в будущем не сработают.

- [X] T001 Подтвердить базовую линию: `just build && just test` в этом репозитории проходят; `panos ../panosiki/pan/start.ps` (без аргументов) печатает "Использование: pan <init|add|remove|install|run> [аргументы]" — sanity-check перед началом, без правок кода

---

## Phase 2: User Story 1 - Заготовка пакета на каждую зависимость (Priority: P1) 🎯 MVP

**Goal**: Для каждой из 7 зависимостей (`tempfiles`, `v8runner`, `gitrunner`, `v8storage`, `cli`, `cli-selector`, `configor`) — отдельный независимый git-репозиторий в `panosiki/`, `pan init`-нутый, с тегом `v0.1.0`.

**Independent Test**: `cat ../panosiki/<имя>/pan.toml` показывает валидный манифест (латинское имя, версия `0.1.0`); `git -C ../panosiki/<имя> tag` показывает `v0.1.0`.

### Implementation for User Story 1

- [X] T002 [P] [US1] Создать пакет-заготовку `tempfiles` в `../panosiki/tempfiles/` по `contracts/package-skeleton.md`: `mkdir` + `git init` + `panos ../panosiki/pan/start.ps init` + коммит (русское сообщение) + `git tag v0.1.0`
- [X] T003 [P] [US1] Создать пакет-заготовку `v8runner` в `../panosiki/v8runner/` — тот же процесс, что T002
- [X] T004 [P] [US1] Создать пакет-заготовку `gitrunner` в `../panosiki/gitrunner/` — тот же процесс, что T002
- [X] T005 [P] [US1] Создать пакет-заготовку `v8storage` в `../panosiki/v8storage/` — тот же процесс, что T002
- [X] T006 [P] [US1] Создать пакет-заготовку `cli` в `../panosiki/cli/` — тот же процесс, что T002
- [X] T007 [P] [US1] Создать пакет-заготовку `cli-selector` в `../panosiki/cli-selector/` — тот же процесс, что T002
- [X] T008 [P] [US1] Создать пакет-заготовку `configor` в `../panosiki/configor/` — тот же процесс, что T002
- [X] T009 [US1] Проверить все 7 из T002-T008 разом: `pan.toml` каждого валиден (имя = латинское имя пакета, версия `0.1.0`, точка_входа `start.ps`), у каждого репозитория ровно 1 коммит и тег `v0.1.0`, ни один не пересекается с уже существующими `panosiki/pan`/`panosiki/panos-raylib` (зависит от T002-T008)

**Checkpoint**: US1 полностью выполнена — 7 заготовок готовы к будущему `pan add`.

---

## Phase 3: User Story 2 - Логирование становится частью panos stdlib (`слог`) (Priority: P1)

**Goal**: `std/слог.ps` — 5 функций уровня логирования, доступные через `импорт слог` без pan-зависимости.

**Independent Test**: `.ps`-файл без pan-зависимостей с `импорт слог` и вызовом `слог.инфо("привет")` печатает `[ИНФО] привет`.

### Implementation for User Story 2

- [X] T010 [P] [US2] Реализовать `std/слог.ps` по `contracts/слог-api.md`: `отладка`/`инфо`/`предупреждение`/`ошибка`/`критично` (каждая — `(текст: Строка) -> Пусто`, печатает `[УРОВЕНЬ] текст` через `ввод_вывод.печать`/`.строка`), без appenders/layouts/фильтрации по уровню
- [X] T011 [US2] Добавить регрессионный тест для `слог` в `core/*_test.odin` (по аналогии с существующими e2e-тестами stdlib-модулей, напр. `core/e2e_modules_stdlib_test.odin`): импорт без pan-зависимости резолвится, каждая из 5 функций печатает ожидаемый формат — зависит от T010
- [X] T012 [US2] Прогнать `just test` — подтвердить отсутствие регрессий (зависит от T011)

**Checkpoint**: US1 и US2 обе выполнены независимо.

---

## Phase 4: User Story 3 - Карта соответствия «oscript-зависимость → судьба на panos» (Priority: P2)

**Goal**: Финальная сверка уже существующей таблицы в `spec.md` (Key Entities) — не создание нового артефакта.

**Independent Test**: Открыв `spec.md`, найти любую из 15 исходных зависимостей и по одной строке понять её судьбу/имя/алиас без обращения к `packagedef` gitsync.

### Implementation for User Story 3

- [X] T013 [US3] Сверить таблицу "Key Entities" в `specs/004-gitsync-dependency-packages/spec.md`: ровно 15 строк, статусы соответствуют реально созданному (7 пакетов из T002-T008 — "новый пакет"/"частичное покрытие", `слог` из T010 — "вошла в stdlib", остальные 7 — "исключена"/"отложена" без созданных артефактов); поправить расхождения, если найдены

**Checkpoint**: Все 3 user story выполнены — фундамент для будущего переноса `gitsync` готов.

---

## Phase 5: Polish & Cross-Cutting Concerns

- [X] T014 [P] Прогнать `quickstart.md` целиком (все 7 пакетов + `слог`), подтвердить SC-001…SC-006 из spec.md
- [X] T015 [P] Свериться с Constitution Principle III (Surgical Changes) — подтвердить, что в этом репозитории изменён только `std/слог.ps` (+ тест), ничего существующего не задето

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: без зависимостей
- **US1 (Phase 2)**: зависит только от Setup (нужен рабочий `panos`/`panosiki/pan`)
- **US2 (Phase 3)**: зависит только от Setup — полностью независима от US1 (разные репозитории/файлы)
- **US3 (Phase 4)**: логически сверяет результат US1+US2, но сама таблица уже написана в spec.md — можно выполнить в любой момент после T009 и T010 (для содержательной сверки), не блокирует и не блокируется остальными по коду
- **Polish (Phase 5)**: после всех выбранных user story

### Parallel Opportunities

- T002-T008 (US1) — 7 разных git-репозиториев, полностью параллельны
- US1 (Phase 2) и US2 (Phase 3) — полностью параллельны между собой (не пересекаются файлами)
- T014, T015 (Polish) — независимы друг от друга

---

## Parallel Example: US1 + US2 одновременно

```bash
# Ветка A — 7 пакетов (можно распараллелить и между собой):
Task: "T002 tempfiles"
Task: "T003 v8runner"
Task: "T004 gitrunner"
Task: "T005 v8storage"
Task: "T006 cli"
Task: "T007 cli-selector"
Task: "T008 configor"

# Ветка B — параллельно, слог (не пересекается с A):
Task: "T010 std/слог.ps"
Task: "T011 регрессионный тест слог"
```

---

## Implementation Strategy

### MVP First

1. Phase 1: Setup
2. Phase 2: US1 (7 заготовок) — можно параллельно с Phase 3
3. Phase 3: US2 (`слог`)
4. **STOP и проверить**: US1 и US2 работают независимо (quickstart.md)

### Incremental Delivery

1. Setup → US1 (7 заготовок) и US2 (`слог`) параллельно → проверить независимо
2. US3 (сверка карты) → финальная валидация
3. Polish → `quickstart.md` целиком + самопроверка Surgical Changes
