# Tasks: Явный generic-argument синтаксис

**Input**: Design documents from `/specs/013-explicit-generic-args/`
**Prerequisites**: `plan.md`, `spec.md`, `research.md`, `data-model.md`, `contracts/explicit-generic-call-resolution.md`, `quickstart.md`

**Tests**: Каждая user story в spec.md прямо требует регрессионных тестов (acceptance scenarios) — пишутся вместе с реализацией.

**Organization**: Один файл (`zig/core/type_checker.zig`) для всей фичи. Foundational-фаза обязательна для ВСЕХ трёх user story — детект-ветка/`resolveTypeFromExpr`/предзасеянные substitutions используются одинаково и US1, и US2, и US3.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: можно выполнять параллельно с другими задачами той же фазы (разные тестовые сценарии, нет зависимости на код).
- **[Story]**: какой user story из spec.md обслуживает задача.

## Phase 1: Setup

**Purpose**: Подтвердить зелёный baseline перед изменениями.

- [X] T001 Прогнать `zig build test`/`conformance`/`aot`/`lsp`/`browser` на текущем `HEAD`, подтвердить все зелёные (после Phase A/B хардненинга это уже так — переподтвердить перед стартом этой фичи).

**Checkpoint**: Baseline зелёный.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Механизм реинтерпретации `Index_Expr` → explicit generic-вызов — без этого ни один user story не работает.

**⚠️ CRITICAL**: US1/US2/US3 все проходят через один и тот же путь — реализовать до начала story-специфичных тестов.

- [X] T002 `resolveTypeFromExpr(self, expr: ast.ExprId) !?types.TypeId` — новая функция в `Checker` (`zig/core/type_checker.zig`), параллель `resolveType` (строка 4824): `.ident` → `findGenericParameter`/`builtinType`/`findTypeSymbol`+`nominalType` (та же логика, что `resolveType`'s `.ident`-ветка); `.property{object: .ident, property}` → `findQualifiedTypeSymbol`; `.call{callee, arguments}` → рекурсивная генерик-инстанциация через `nominalType`; всё остальное → `null`. Решить открытый вопрос из research.md — где диагностировать "похоже на тип, символ не найден" против "форма не типовидна".
- [X] T003 Извлечение explicit type-аргументов из `Index_Expr`: если `self.tree.expr(index.index).*` — `.tuple`, использовать `.elements`; иначе — один элемент `[index.index]`. Каждый прогнать через T002.
- [X] T004 Новая `.index`-ветка в `inferCallExpected`'s callee-switch (`zig/core/type_checker.zig:4402`, перед текущим `else => {}`): детект через `self.resolution.expr_symbols.get(index.object)` + `generic_function_parameters.get(symbol)` непусто. Если условие не выполняется — fallthrough к существующему пути без изменений (FR-006).
- [X] T005 Проверка длины: количество explicit-аргументов (T003) MUST совпасть с `generic_parameters.len`; иначе Type Error (FR-003), не пытаться частично сопоставить.
- [X] T006 Построение предзасеянной substitutions-карты — `substitutions.put(parameter.typ, resolved)` для каждой пары по объявленному порядку (FR-002).
- [X] T007 Рефакторинг `.function`-ветки (`zig/core/type_checker.zig:~4517-4700`) в helper, параметризованный callee-выражением (`call.callee` для обычного пути, `index.object` для explicit-пути из T004) и НЕ ПУСТОЙ, а предзасеянной substitutions-картой (из T006, либо пустой для обычного пути). Существующий цикл `inferGenericSubstitution`/bounds-проверка — без изменений (переиспользуются как есть для FR-004/FR-005).
- [X] T008 Прогнать `zig test zig/core/type_checker.zig` — существующие regression-тесты (обычные inferred-вызовы, indexed-then-call на массиве функций) должны остаться зелёными без единого изменения ожидаемого поведения.

**Checkpoint**: Механизм реинтерпретации работает и не ломает существующее — можно начинать US1/US2/US3 в любом порядке.

---

## Phase 3: User Story 1 — Явное указание generic-типа при отсутствии контекста (Priority: P1) 🎯 MVP

**Goal**: `ф[Тип](...)` разрешает `T`, который сегодня недовыводим (только в return-типе, нет `expected_return`).

**Independent Test**: `функ ф[T](x: Строка) -> Тип(T)`, вызванная `ф[Число]("42")` без типизированной привязки результата, компилируется, результат — `Тип(Число)`.

### Tests for User Story 1

- [X] T009 [P] [US1] Тест: `ф[Число]("42")` (T только в return-типе, без контекста) — компилируется, тип результата `Тип(Число)`, НЕ "не удалось вывести type-параметр".
- [X] T010 [P] [US1] Negative control: та же функция БЕЗ explicit-аргумента и без контекста — поведение не изменилось (unconstrained, не новая ошибка) — подтверждает FR-008.
- [X] T011 [P] [US1] Тест: квалифицированный вызов `модуль.ф[Тип](аргумент)`. Отклонился от плана: реальный cross-module тест через `module_loader`/`module_compiler` тянул `vm.zig` (SQL/FFI) в `type_checker_unit_tests`, не слинкованный с sqlite3/libffi в `build.zig` — реальная линк-ошибка (подтверждено на чистом `HEAD` без моих правок). Заменено структурным обоснованием: `index.object` для квалифицированного вызова — `Property_Expr`, символ резолвится ТЕМ ЖЕ `expr_symbols.get(...)`, что уже проверенно работает для ОБЫЧНЫХ (не-explicit) квалифицированных generic-вызовов.

**Checkpoint**: US1 завершена, когда T009-T011 зелёные — MVP explicit-generic вызов работает для свободных и квалифицированных функций.

---

## Phase 4: User Story 2 — Явный конфликтующий с выводом аргумент (Priority: P1)

**Goal**: Явный type-аргумент, противоречащий типу реального аргумента, даёт Type Error до кодогенерации.

**Independent Test**: `функ ф[T](x: T) -> T`, вызванная `ф[Число]("текст")`, даёт Type Error, не runtime-ошибку.

### Tests for User Story 2

- [X] T012 [P] [US2] Тест: `ф[Число]("текст")` (explicit `Число`, аргумент `Строка`) — Type Error "type-параметр выведен неоднозначно" (существующая диагностика из `inferGenericSubstitution`, см. Foundational T006/T007 — подтверждает, что предзасеивание триггерит её бесплатно).
- [X] T013 [P] [US2] Тест: explicit-аргумент, совпадающий с тем, что и так вывелся бы из аргументов (избыточный, не конфликтующий) — компилируется как обычно, без диагностики.
- [X] T014 [P] [US2] Тест: explicit-аргумент, нарушающий interface-bound type-параметра (`функ ф[T: Интерфейс](...)`, вызвана с типом, не реализующим `Интерфейс`) — Type Error (FR-005, существующий bounds-цикл).

**Checkpoint**: US2 завершена, когда T012-T014 зелёные.

---

## Phase 5: User Story 3 — Явный type-аргумент нетиповидной формы (Priority: P2)

**Goal**: `ф[выражение](...)` с `ф` — generic-функцией и нетиповидным `выражение` — понятная диагностика, не тихая ошибочная индексация.

**Independent Test**: `ф[1 + 2](...)` с реально generic `ф` — диагностика про ожидание имени типа, не про индексацию функции.

### Tests for User Story 3

- [X] T015 [P] [US3] Тест: `ф[1 + 2]("x")` на generic `ф` — понятная диагностика (T002's `resolveTypeFromExpr` вернула `null` для `.binary`), не "попытка индексировать функцию" и не крах.
- [X] T016 [P] [US3] Тест: `ф[несуществующий_тип](...)` (форма типовидна — `.ident`, но символ не резолвится) — отдельная диагностика "неизвестный тип", отличимая от T015 (реши открытый вопрос T002 здесь конкретным тестом).

**Checkpoint**: US3 завершена, когда T015-T016 зелёные.

---

## Phase 6: Polish & Cross-Cutting Validation

**Purpose**: Multi-arg форма, regression на существующей индексации, полная матрица сборки.

- [X] T017 [P] Тест: `функ пара[T, U](a: T, b: U) -> ...`, вызвана `пара[(Число, Строка)](1.0, "x")` — множественный явный аргумент через `Tuple_Expr` (T003), подставлен по объявленному порядку (FR-002).
- [X] T018 [P] Тест: `функции[0](21.0)`, где `функции: Массив(функ(Число) -> Число)` — `ф` НЕ generic-функция, поведение идентично сегодняшнему (FR-006) — добавить, если эквивалентного теста ещё нет в существующем наборе.
- [X] T019 Прогнать полную quickstart-матрицу (`specs/013-explicit-generic-args/quickstart.md`) — все 6 сценариев вручную/тестами.
- [X] T020 Прогнать `zig build test`, `zig build conformance`, `zig build aot`, `zig build lsp`, `zig build browser` — все зелёные. `aot` особенно — подтвердить, что MIR-лоуэринг explicit-generic вызова неотличим от inferred (читает уже разрешённые `expression_types`/`symbol_types`).
- [X] T021 Свериться с `contracts/explicit-generic-call-resolution.md` — подтвердить, что финальное поведение (порядок резолюции, диагностики) совпадает с задокументированным контрактом; обновить контракт только если реализация вынужденно отклонилась (с обоснованием).

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: без зависимостей.
- **Phase 2 (Foundational)**: после T001; БЛОКИРУЕТ все три user story — T002-T008 последовательны (каждый следующий использует предыдущий).
- **Phase 3 (US1)**: после Foundational; независима от US2/US3 внутри (разные тестовые сценарии, один и тот же код).
- **Phase 4 (US2)**: после Foundational; независима от US1/US3.
- **Phase 5 (US3)**: после Foundational; независима от US1/US2.
- **Phase 6 (Polish)**: после всех трёх user story.

### User Story Dependencies

- **US1 (P1)**: MVP, зависит только от Foundational.
- **US2 (P1)**: зависит только от Foundational — конфликт-детекция уже встроена в T006/T007, US2's задачи чисто тестовые.
- **US3 (P2)**: зависит только от Foundational — диагностика уже встроена в T002, US3's задачи чисто тестовые.

### Parallel Opportunities

- Все тесты внутри T009-T011, T012-T014, T015-T016, T017-T018 параллельны друг с другом (разные сценарии, один файл — координировать порядок вставки, не логику).
- US1/US2/US3 можно вести параллельно РАЗНЫМИ людьми сразу после Foundational — ни один не блокирует другой, но все три физически пишут тесты в один файл (`type_checker.zig`) — координировать место вставки.

---

## Parallel Example: после Foundational

```text
Developer A: T009/T010/T011 (US1)
Developer B: T012/T013/T014 (US2)
Developer C: T015/T016 (US3)
→ сходятся в Phase 6 (Polish)
```

## Implementation Strategy

### MVP First

1. Complete T001 → Foundational (T002-T008).
2. Complete US1 (T009-T011) — закрывает главную заявленную ценность
   фичи (убрать последний permissive-fallback без явного способа
   переопределить).
3. Validate independently, при желании остановиться здесь — US2/US3
   уже частично покрыты бесплатно встроенной логикой Foundational,
   их тесты просто ПОДТВЕРЖДАЮТ это, не добавляют новый код.

### Incremental Delivery

1. T001 → Foundational → US1 (MVP) → US2 → US3 → Polish.
2. US2/US3 дёшевы относительно US1 (тесты на уже написанный в
   Foundational код) — реальный риск сосредоточен в Foundational,
   не размазан по user story.

## Notes

- Foundational-фаза — это, по сути, вся фича; US1/US2/US3 в основном
  тестово подтверждают уже написанный в Foundational код (см.
  research.md's "Decision: конфликт explicit-vs-inferred ловится
  БЕСПЛАТНО существующим `inferGenericSubstitution`").
- Метод-вызовы (`это.метод[Тип](...)`) — явно вне scope этих задач
  (Phase 2 фичи в plan.md's "Deferred", не путать с Phase 2 этого
  tasks.md, которая про Foundational).
- T002's открытый вопрос (диагностика "не типовидно" vs "неизвестный
  тип") — не пропускать, закрыт явно тестом T016.

## Реальные пробелы, найденные ТОЛЬКО сквозным прогоном (не в исходном plan.md)

`plan.md`/`research.md` предполагали "единственный реально меняющийся
файл — `type_checker.zig`" — предположение оказалось НЕВЕРНЫМ, поймано
только реальной сборкой бинарника и запуском `.pns`-файлов (юнит-тесты
типчекера проверяют лишь `checked.diagnostics`, не весь пайплайн):

1. **`zig/core/compiler.zig`** (байткод-компилятор) отдельно обходит
   ТОТ ЖЕ raw AST независимо от typechecker'а и пытался буквально
   скомпилировать `index.index` (имя типа) как runtime-индекс —
   `"Compiler Error: выражение пока не поддержано"`. Фикс: новый
   `explicitGenericCallCallee` helper в `FunctionCompiler` —
   зеркалит typechecker'овский детект (`index.object`'s символ имеет
   `generic_function_parameters`), при совпадении компилирует
   `index.object` напрямую, полностью игнорируя `index.index`
   (generics не мономорфизируются — codegen не зависит от `T` вообще).
2. **`zig/core/resolver.zig`** — резолвер тоже независимо обходит raw
   AST ДО тайпчека и падал `"Resolve Error: неопределённое имя"` на
   примитивных type-именах без value-level символа (`Строка` — падает;
   `Число`/`Целое` — не падает, у них есть cast-конструктор; имена
   пользовательских структур — не падают, авто-регистрируют
   конструктор). Фикс: в `.index`-ветке `resolveExpression` — если
   `index.object` резолвится в символ `kind == .function`
   (индексация ГОЛОЙ функции никогда не была валидна для обычной
   семантики — только массивы/соответствия индексируемы), пропустить
   резолюцию `index.index` как значения вовсе, отдать typechecker'у.
   Резолвер не знает про generics (это уровень типов, не имён) —
   решение принято по структурной форме, не по семантике.

Оба фикса подтверждены пятью ручными smoke-тестами через реальный
`./zig-out/bin/panos` (не только юнит-тесты) — единичный/множественный
explicit-аргумент, конфликт, bound-нарушение, нетиповидная форма,
regression на массиве функций — и полной регрессией
(`test`/`conformance`/`aot`/`lsp`/`browser`, все зелёные).
