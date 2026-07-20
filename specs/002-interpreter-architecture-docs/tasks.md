---

description: "Task list for feature 002-interpreter-architecture-docs"
---

# Tasks: Внутренняя документация архитектуры интерпретатора

**Input**: Design documents from `/specs/002-interpreter-architecture-docs/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/chapter-template.md, quickstart.md

**Tests**: Не запрошены явно в spec.md — эта фича не производит код, "тесты"
здесь заменены на верификационные задачи (`mdbook build`, чеклист
`contracts/chapter-template.md`, сценарии `quickstart.md`), включённые как
обычные задачи ниже, не отдельной "test-first" секцией.

**Organization**: Задачи сгруппированы по User Story из spec.md (US1 =
Pipeline, P1; US2 = LSP, P2; US3 = Рантайм/stdlib, P3), плюс Setup/
Foundational/Polish. Итоговое дерево файлов — `plan.md` → Project Structure.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: можно выполнять параллельно (разные файлы, зависимости уже закрыты)
- **[Story]**: US1/US2/US3 — только для фаз user story
- Каждая задача называет точный путь файла

## Path Conventions

Все пути — внутри существующего mdBook: `docs/src/architecture/...` (плюс
одна правка `docs/src/SUMMARY.md`). См. `plan.md` → Project Structure для
полного дерева из 20 файлов.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Создать скелет раздела — SUMMARY.md + файлы-заглушки для ВСЕХ
20 будущих глав, чтобы `mdbook build` проходил с первого коммита, а
дальнейшие задачи только заменяли заглушки реальным содержимым.

- [X] T001 Добавить в `docs/src/SUMMARY.md` новый раздел "Архитектура
      интерпретатора" (рядом с "Начало работы"/"Язык") со всеми 20 пунктами
      из `plan.md` → Project Structure; создать под каждый пункт файл-
      заглушку в `docs/src/architecture/` (и `docs/src/architecture/recipes/`
      для 7 файлов рецептов) с одной строкой `# <Название>` — без реального
      содержимого
- [X] T002 [P] Проверить `cd docs && mdbook build` без ошибок на заглушках
      (валидная структура SUMMARY.md, все ссылки резолвятся) — фиксирует
      базовую линию перед тем, как контент начнёт заполняться
- [X] T003 [P] Заполнить `docs/src/architecture/overview.md` реальным
      содержимым: как читать раздел, связь с `AGENTS.md` (pipeline-список) и
      `docs/src/language/*.md` (эта фича их не дублирует и не заменяет)
- [X] T004 [P] Заполнить `docs/src/architecture/recipes/overview.md`
      реальным содержимым — формат рецепта по Contract C из
      `contracts/chapter-template.md` (файлы по порядку → шаги → проверка)

**Checkpoint**: скелет готов, `mdbook build` зелёный, можно параллельно
начинать любую user story ниже.

---

## Phase 2: Foundational (Cross-Cutting Prerequisite)

**Purpose**: Единственная глава, не принадлежащая ни одной user story —
"Проверка" каждого рецепта во ВСЕХ трёх user story ссылается на команды
сборки/тестирования отсюда; пишем один раз, чтобы рецепты не дублировали
и не расходились в формулировках команд.

- [X] T005 Заполнить `docs/src/architecture/toolchain-and-testing.md`
      реальным содержимым — 3 сборочные цели (`odin build .`,
      `odin build ./lsp`, wasm через `Justfile`), ритуал редеплоя
      LSP-бинарника (все известные места установки, перепроверить
      актуальность путей руками, не по памяти сессии — см. `research.md`),
      конвенции тестирования (`run_code`/`core/pipeline.odin`/
      `core/e2e_test.odin` vs inline-pipeline)

**Checkpoint**: справочник команд сборки/тестирования готов — рецепты в
любой user story ниже могут на него ссылаться.

---

## Phase 3: User Story 1 — Изменение стадии pipeline без помощи LLM (Priority: P1) 🎯 MVP

**Goal**: Мейнтейнер находит для лексера/парсера/резолвера/тайпчекера/
компилятора+VM/generics — что стадия строит/потребляет, зачем она отдельна,
почему устроена так, и все точки входа для типичной правки.

**Independent Test**: `quickstart.md` → раздел 2 — открыть `parser.md` БЕЗ
предварительного чтения `core/parser.odin`, найти по "Точки входа" полный
список файлов для добавления нового бинарного оператора, сверить со
списком ПОСЛЕ самопроверки.

### Research (глубокое чтение — ОТДЕЛЬНО от написания, см. `research.md`)

- [X] T006 [P] [US1] Глубоко прочитать `core/lexer.odin` + `core/token.odin`:
      каталогизировать правила токенизации, `lookup_ident`, обработку
      escape-последовательностей строк — заметки для T010, без изменения
      файлов документации
- [X] T007 [P] [US1] Глубоко прочитать `core/parser.odin` (102KB): Pratt-
      parser, `infix_bp`/`prefix_bp`, все `parse_*`-точки входа — заметки
      для T011
- [X] T008 [P] [US1] Глубоко прочитать `core/type_cheker.odin` (274KB,
      САМЫЙ большой файл репозитория): `Type`/`Type_Kind`, unification,
      bounded generics, `report()` — заметки для T012
- [X] T009 [P] [US1] Глубоко прочитать `core/compiler.odin` + `core/vm.odin`:
      полный список `Opcode`, соответствие каждому opcode обработчика в VM,
      требование `GC_Header` первым полем у heap-managed `Value` — заметки
      для T013

### Написание глав (Contract A из `contracts/chapter-template.md`)

- [X] T010 [P] [US1] Написать `docs/src/architecture/lexer.md` по Contract A
      (Что/Зачем/Почему так/Точки входа), используя заметки T006
- [X] T011 [P] [US1] Написать `docs/src/architecture/parser.md` по
      Contract A, используя заметки T007
- [X] T012 [P] [US1] Написать `docs/src/architecture/type-checker.md` по
      Contract A, используя заметки T008
- [X] T013 [P] [US1] Написать `docs/src/architecture/compiler-and-vm.md` по
      Contract A (компилятор и VM ОДНОЙ главой — opcode трогает оба файла
      как одну операцию, см. `plan.md` → Structure Decision), используя
      заметки T009
- [X] T014 [P] [US1] Написать `docs/src/architecture/resolver.md` по
      Contract A — `Symbol_Store`/`Symbol_Id`/`graph.symbol_store`/
      `node_symbols`/`func_args` уже подтверждены в `spec.md`, отдельного
      research-прохода не требуется
- [X] T015 [P] [US1] Написать
      `docs/src/architecture/generics-and-monomorphization.md` по Contract A
      — причина клонирования AST (конфликт за `ctx.node_types` при повторной
      типизации узла с разными type-параметрами) уже подтверждена в `spec.md`

### Рецепты (Contract C, зависят от глав выше)

- [X] T016 [P] [US1] Написать
      `docs/src/architecture/recipes/new-binary-operator.md` по Contract C —
      файлы по порядку: `parser.odin` → `type_cheker.odin` → `compiler.odin`
      + `vm.odin` (зависит от T010, T011, T012, T013)
- [X] T017 [P] [US1] Написать `docs/src/architecture/recipes/new-ast-node.md`
      по Contract C — новый вид `Expr`/`Stmt` (зависит от T011, T012)
- [X] T018 [P] [US1] Написать
      `docs/src/architecture/recipes/new-diagnostic.md` по Contract C —
      новая проверка в резолвере ИЛИ тайпчекере, `report_resolve`/`report`
      (зависит от T014, T012)

**Checkpoint**: User Story 1 полностью функциональна и тестируема
независимо (`quickstart.md` → раздел 2 проходит).

---

## Phase 4: User Story 2 — Изменение LSP-сервера без помощи LLM (Priority: P2)

**Goal**: Мейнтейнер находит модель `LSP_Document`/переиспользуемые
структуры ядра/известные ограничения LSP и известные грабли, чтобы
добавить/починить LSP-метод без переоткрытия уже известных ловушек.

**Independent Test**: `quickstart.md` → раздел 3 — открыть `lsp.md`,
убедиться что "Известные ограничения" называют ОБЕ границы (открытые
документы / несравнимость `Symbol_Id`); открыть `known-pitfalls.md`,
убедиться что оба пункта полны (Симптом/Причина/Безопасный паттерн/Источник).

- [X] T019 [US2] Написать `docs/src/architecture/lsp.md` по Contract A —
      `LSP_Document`, переиспользование `Resolver_Ctx`/`Type_Ctx`/
      `Symbol_Store`, автогенерированный `lsp/protocol/lsp_types.odin`,
      подраздел "Известные ограничения" (rename/references видят только
      открытые документы; `Symbol_Id` не сравним между графами — сравнение
      по путь+byte-span) — материал уже собран в этой сессии, отдельный
      research-проход не требуется
- [X] T020 [US2] Написать `docs/src/architecture/known-pitfalls.md` по
      Contract B, минимум 2 пункта: (1) сегфолт на прямой индексации
      `map[K][dynamic]V` внутри `for`-range на отсутствующем ключе
      (источник: коммит `85b6455`) — безопасный паттерн `v, ok := m[key]`;
      (2) `core:encoding/json.marshal` не поддерживает поля-указатели
      (`Unsupported_Type`, найдено на `proto.SelectionRange.parent`) —
      безопасный паттерн: ручная сборка `json.Value` (зависит от T019 —
      ссылается на `lsp.md` как место обнаружения)
- [X] T021 [US2] Написать `docs/src/architecture/recipes/new-lsp-method.md`
      по Contract C — файлы по порядку: capability в `handle_initialize` →
      dispatch-case → сам handler в `lsp/lsp_server.odin` (зависит от T019)

**Checkpoint**: User Story 1 И 2 обе работают независимо
(`quickstart.md` → разделы 2 и 3 проходят).

---

## Phase 5: User Story 3 — Изменение стандартной библиотеки и рантайм-подсистем (Priority: P3)

**Goal**: Мейнтейнер находит инварианты GC (`GC_Header` первым полем),
модель модулей (`Module_Graph`) и правило platform-split (`_native`/`_wasm`),
чтобы безопасно добавить stdlib-функцию/модуль или builtin в VM.

**Independent Test**: US3 Acceptance Scenarios в `spec.md` — документация
объясняет обязательность `GC_Header` и правило "WASM не имеет ФС/`core:os`
падает compile-time panic'ом под `js_wasm32`".

### Research (глубокое чтение — ОТДЕЛЬНО от написания)

- [X] T022 [P] [US3] Глубоко прочитать `core/gc.odin` (25KB): алгоритм сборки
      мусора (mark/sweep vs generational — не установлено на момент
      планирования, см. `research.md`), обязательный инвариант `GC_Header`
      первым полем каждого heap-managed `Value` — заметки для T024
- [X] T023 [P] [US3] Перечислить ВСЕ пары `_native.odin`/`_wasm.odin` в
      `core/` и `lsp/` (не найдено исчерпывающе в этой сессии, см.
      `research.md`) — заметки для T026

### Написание глав

- [X] T024 [P] [US3] Написать `docs/src/architecture/memory-and-gc.md` по
      Contract A, используя заметки T022
- [X] T025 [P] [US3] Написать `docs/src/architecture/module-system.md` по
      Contract A — `Module_Graph`, `resolve_import_path`, встроенные vs
      файловые (`std/*.ps`) модули, `load_module_recursive` (уже частично
      подтверждено в этой сессии)
- [X] T026 [P] [US3] Написать `docs/src/architecture/platform-split.md` по
      Contract A, используя заметки T023

### Рецепты

- [X] T027 [P] [US3] Написать
      `docs/src/architecture/recipes/new-stdlib-function.md` по Contract C —
      новая экспортируемая функция в существующем `std/*.ps`-модуле (зависит
      от T025)
- [X] T028 [P] [US3] Написать
      `docs/src/architecture/recipes/new-stdlib-module.md` по Contract C —
      новый `std/*.ps`-файл целиком, включая регистрацию модуля (зависит от
      T025)

**Checkpoint**: все три user story работают независимо.

---

## Phase 6: Polish & Cross-Cutting Verification

**Purpose**: Финальная сверка ВСЕХ 20 глав против контракта и сценариев
`quickstart.md` — ничего не осталось заглушкой, каждая глава проходит FR-012.

- [X] T029 [P] Самопроверка каждой из 20 глав по чеклисту
      `contracts/chapter-template.md` (Contract A/B/C — соответствующий
      каждой главе) — каждый абзац "Что"/"Зачем"/"Почему так" содержит
      минимум одну цитату кода; править главы на месте, где не проходит
- [X] T030 Сверка перекрёстных ссылок: `lsp.md` → `known-pitfalls.md`
      (подраздел "Известные ограничения/грабли"); каждый рецепт в
      `recipes/*.md` ссылается ТОЛЬКО на файлы, уже описанные в
      соответствующей архитектурной главе (см. `data-model.md` → граф
      зависимостей) — не вводит новых архитектурных фактов от себя (зависит
      от T029 — сверка идёт по уже исправленным главам)
- [X] T031 Финальный `cd docs && mdbook build` без ошибок — ни одной
      оставшейся заглушки `# <Название>` без содержимого (зависит от T029,
      T030)
- [X] T032 Прогнать ВСЕ 4 сценария `quickstart.md` (сборка, US1-сценарий,
      US2-сценарий, проверка FR-012) на готовых главах (зависит от T031)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: без зависимостей — начинать сразу
- **Foundational (Phase 2)**: зависит от завершения Setup (нужны реальные
  заглушки/структура из T001); НЕ блокирует user story жёстко (US1/US2/US3
  не требуют физического существования `toolchain-and-testing.md`, чтобы
  начаться), но рецепты во всех трёх should дождаться T005, чтобы не
  придумывать формулировки команд заново — рекомендуемый, не строго
  обязательный порядок
- **User Stories (Phase 3+)**: могут идти параллельно после Foundational,
  или последовательно по приоритету (US1 → US2 → US3)
- **Polish (Phase 6)**: зависит от завершения всех трёх user story

### User Story Dependencies

- **US1 (P1)**: независима от US2/US3
- **US2 (P2)**: независима от US1/US3
- **US3 (P3)**: независима от US1/US2

### Внутри каждой User Story

- Research-задачи (где есть) → задачи написания главы → задачи рецептов
- Глава должна существовать ПЕРЕД рецептом, который на неё ссылается (см.
  `data-model.md` → граф зависимостей — рецепт не вводит новых архитектурных
  фактов, только компонует уже написанное)

### Parallel Opportunities

- T002, T003, T004 — параллельно (все зависят только от T001)
- T006, T007, T008, T009 — параллельно (независимые research-проходы по
  разным файлам)
- T010, T011, T012, T013, T014, T015 — параллельно (разные файлы, каждый
  ждёт только СВОЙ research-проход, не остальные)
- T016, T017, T018 — параллельно (разные файлы рецептов)
- T022, T023 — параллельно
- T025, T027, T028 — параллельно с T024/T026 (module-system.md не зависит от
  GC/platform-split research)
- US1, US2, US3 целиком — параллельно между собой при наличии нескольких
  исполнителей

---

## Parallel Example: User Story 1

```bash
# Research параллельно:
Task: "Глубоко прочитать core/lexer.odin + core/token.odin"
Task: "Глубоко прочитать core/parser.odin"
Task: "Глубоко прочитать core/type_cheker.odin"
Task: "Глубоко прочитать core/compiler.odin + core/vm.odin"

# Написание глав параллельно (после соответствующего research):
Task: "Написать docs/src/architecture/lexer.md"
Task: "Написать docs/src/architecture/parser.md"
Task: "Написать docs/src/architecture/resolver.md"
Task: "Написать docs/src/architecture/generics-and-monomorphization.md"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Phase 1: Setup
2. Phase 2: Foundational (`toolchain-and-testing.md`)
3. Phase 3: User Story 1 (Pipeline)
4. **STOP и проверить**: `quickstart.md` → раздел 2 независимо
5. Опубликовать (mdBook уже деплоится как единый сайт — раздел появится
   вместе со следующим релизом документации)

### Incremental Delivery

1. Setup + Foundational → скелет готов, `mdbook build` зелёный
2. + US1 (Pipeline) → проверить независимо → это MVP
3. + US2 (LSP) → проверить независимо
4. + US3 (Рантайм/stdlib) → проверить независимо
5. Polish → финальная сверка всех 20 глав разом

### Parallel Team Strategy

1. Вместе: Setup + Foundational
2. После Foundational: один автор — US1, второй — US2, третий — US3
   (независимы по файлам, независимо тестируемы)
3. Все трое сходятся на Polish

---

## Notes

- [P]-задачи = разные файлы, зависимости уже закрыты
- [Story]-метка — прослеживаемость к user story spec.md
- Каждая user story независимо завершаема и тестируема через
  `quickstart.md`
- Research-задачи (T006-T009, T022-T023) НЕ создают/не меняют файлы
  документации — только заметки для соответствующей задачи написания;
  не смешивать чтение и написание в одном коммите (см. `research.md`)
- Коммитить после каждой задачи или логической группы
- Останавливаться на любом Checkpoint, чтобы проверить story независимо
- Каждое утверждение в главе — с цитатой файла/структуры/функции (FR-012);
  абзац без такой цитаты — повод вернуть главу на доработку, а не считать
  задачу выполненной
