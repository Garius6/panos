# Tasks: gitsync — авто push/pull через --remote

**Input**: Design documents from `/specs/008-gitsync-auto-push-pull/`
**Prerequisites**: plan.md, research.md, data-model.md, quickstart.md

**Tests**: включены (тот же TDD-паттерн, что `006`/`007`).

**Organization**: одна user story (P1) — без Foundational-фазы.

## Format: `[ID] [P?] [Story] Description`

## Phase 1: Setup

- [ ] T001 Подготовить тестовую инфраструктуру в `../panosiki/gitsync/test_sync.ps`: хелперы `создать_bare_remote(имя)` (`git init --bare`) и `клонировать(bare_путь, каталог)` (`git clone`) поверх уже существующего `гит.новый_репозиторий()` — реальный git, без fake-бинарей (не 1С-специфика)

**Checkpoint**: можно создавать bare-репозиторий + клоны в тестах.

---

## Phase 2: User Story 1 - Синхронизация с удалённым репозиторием одной командой (Priority: P1) 🎯 MVP

**Goal**: `gitsync sync --remote <имя>` pull-ит (`--ff-only`) до цикла и push-ит после, если были новые коммиты; без флага — поведение не меняется.

**Independent Test**: см. spec.md Independent Test.

### Tests for User Story 1 ⚠️

> Пишутся ПЕРВЫМИ, должны ПАДАТЬ до реализации ниже.

- [ ] T002 [P] [US1] Тест в `test_sync.ps`: без `--remote` (Опция.Нет в контексте) — `sync` ведёт себя идентично `007` (регрессия, не новый сценарий) — НИКАКИХ git pull/push вызовов (Acceptance Scenario 5)
- [ ] T003 [P] [US1] Тест: два клона общего bare-репозитория, оба `sync --remote origin` без предварительных расхождений — новые коммиты первого клона видны в bare-репозитории после push (Acceptance Scenario 1)
- [ ] T004 [P] [US1] Тест: bare-репозиторий содержит коммит (сделан вторым клоном + push), первый клон делает `sync --remote origin` — коммит подтянут ЧЕРЕЗ pull ДО начала цикла версий хранилища (Acceptance Scenario 2)
- [ ] T005 [P] [US1] Тест: два клона расходятся (оба закоммитили независимо, не синхронизировав) — `sync --remote origin` в одном из них падает с ошибкой ДО начала цикла версий, `VERSION` не меняется, 0 версий хранилища обработано (Acceptance Scenario 3)
- [ ] T006 [P] [US1] Тест: `sync --remote origin`, хранилище не даёт новых версий (VERSION уже равен максимуму) — push НЕ вызывается (проверить, что bare-репозиторий не получил новых сетевых операций/коммитов) (Acceptance Scenario 4)
- [ ] T007 [US1] Тест: push сам по себе падает (например, целевая ветка в bare-репозитории защищена/`git push` возвращает ошибку) — `sync` в целом возвращает `Результат.Неудача`, но `VERSION`/локальные коммиты этого запуска УЖЕ сохранены (Edge Case)

### Implementation for User Story 1

- [ ] T008 [US1] Добавить поле `remote: Опция(Строка)` в `Контекст_Синхронизации` (`../panosiki/gitsync/sync.ps`, data-model.md)
- [ ] T009 [US1] Реализовать `подтянуть_с_удалённого(репо, remote) -> Результат(Строка, Ошибка)` в `sync.ps`: `получить_текущую_ветку()` + `выполнить_команду(массив("pull","--ff-only",remote,ветка))` (research.md §1/§4) — зависит от T008
- [ ] T010 [US1] Реализовать `отправить_на_удалённый(репо, remote) -> Результат(Строка, Ошибка)` в `sync.ps`: та же схема, `выполнить_команду(массив("push",remote,ветка))`, без `--force` — зависит от T008
- [ ] T011 [US1] Подключить оба в `синхронизировать`: pull СРАЗУ после проверки "это git-репозиторий", ДО чтения `VERSION` (research.md §4); push ПОСЛЕ цикла, ТОЛЬКО если `синхронизировано > 0` (research.md §2) — оба ТОЛЬКО если `контекст.remote.есть()` — зависит от T009, T010
- [ ] T012 [US1] Подключить флаг `--remote`/`-r` к подкоманде `sync` в `../panosiki/gitsync/start.ps` (contracts — расширение `006`'s `cli-surface.md`, не новая команда)
- [ ] T013 [US1] Прогнать `test_sync.ps` (T002-T007) — все зелёные, регрессий в остальных тестах пакета/`v8storage`/`скобки` нет

**Checkpoint**: `sync --remote <имя>` работает независимо — самостоятельно тестируемый MVP.

---

## Phase 3: Polish & Cross-Cutting Concerns

- [ ] T014 [P] Прогнать `quickstart.md` целиком вручную (реальный git, bare-репозиторий как remote)
- [ ] T015 [P] Патч-бамп версии + тег в `../panosiki/gitsync/` (изменённое поведение `sync`), пуш на `github.com/Garius6/gitsync`
- [ ] T016 Финальный полный прогон всех `test_*.ps` в `panosiki/gitsync` (+ `v8storage`/`скобки` — регрессия) — 0 регрессий

---

## Dependencies & Execution Order

- Setup (T001) → US1 (T002-T013) → Polish (T014-T016)
- Внутри US1: тесты (T002-T007) пишутся и ПАДАЮТ до реализации; T008 → T009/T010 (параллельно) → T011 → T012 → T013
