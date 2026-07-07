# Implementation Plan: ADT и pattern-matching

**Branch**: `001-adt-pattern-matching` | **Date**: 2026-07-07 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/001-adt-pattern-matching/spec.md`

**Clarifications applied (session 2026-07-07)**:

- Q1 → квалификация варианта: `Тип.Вариант` (симметрично в выражениях и
  шаблонах).
- Q2 → печать ADT: `ИмяВарианта(арг, ...)` для вариантов с полями,
  `ИмяВарианта` без полей; те же правила для `Опция`/`Результат`
  (FR-015a).
- Q3 → cross-module: `модуль.Тип.Вариант(...)`; `модуль.Вариант(...)`
  допустим только если имя однозначно в модуле (FR-012a).
- Q4 → `_` в `выбор` только последней веткой; всё, что после — ошибка
  (FR-008).
- Q5 → `Есть`/`Нет`/`Успех`/`Неудача` регистрируются как обычные
  `Enum_Variant` символы в prelude модуля до старта; синтаксис
  выражений и шаблонов у них общий с пользовательскими ADT
  (FR-011).

## Summary

Довести до рабочего состояния уже частично зарезервированные конструкции языка:
пользовательские алгебраические типы данных (`тип X = перечисление ...`) и
выражение сопоставления (`выбор subject ... конец`). Изменения проходят по
всему пайплайну одного и того же процесса (`lexer → parser → resolver → type
checker → compiler → vm`), не вводя нового рантайма и нового формата
байткода — новые опкоды добавляются, но существующие не меняются.

Технический подход:

- В парсере починить недостроенный `parse_enum_decl`, добавить `parse_match_expr`
  и `parse_pattern`, встроить `выбор` в `parse_expression` как первичное
  выражение и разветвить top-level dispatch по `тип X = перечисление ...`.
- В резольвере регистрировать имя ADT и имена конструкторов как
  `Symbol_Kind.Type` и новый `Symbol_Kind.Enum_Variant`; ввести скоуп ветки
  `выбор` только для биндеров шаблона. Встроенные `Опция(T)` / `Результат(T, E)`
  и их варианты (`Есть`/`Нет`/`Успех`/`Неудача`) регистрируются тем же
  механизмом в prelude модуля (Q5), заменяя нынешний путь через
  hardcoded-таблицу в type checker'е.
- В type checker'е добавить `Type_Kind.Enum` (в существующей структуре
  `Type`, новое поле `variants: [dynamic]Type_Variant`), реализовать
  проверку конструктора, вывод типа `выбор`, исчерпываемость,
  недостижимость и правило "`_` — только последняя ветка" (Q4).
  Встроенные `Опция(T)` и `Результат(T, E)` разбираются через тот же
  путь: их существующие типы дополняются реальным списком вариантов
  при построении prelude (Q5), а не через параллельную hardcoded-таблицу.
- В компиляторе добавить четыре опкода: `Match_Tag` (сравнение тега
  вершины стека с константой), `Get_Variant_Field` (взять i-е поле
  варианта), `Match_Fail` (страховочный трап при недостижимом промахе)
  и `Build_Variant` (собрать `^Variant_Value` из type_name-константы,
  тега и `arity` полей на стеке); генерация match — линейная цепочка
  `Match_Tag → Jump_If_False` с `Match_Fail` в конце, реиспользуя
  существующие `Jump`/`Jump_If_False`.
- В VM добавить рантайм-представление `Variant_Value` (метка + аргументы) и
  выполнение новых опкодов. Встроенные `^Option_Value`/`^Result_Value`
  подхватываются read-only слоем `variant_tag`/`variant_field`, не заменяя
  их структуру.

Функциональный стиль реализации (см. FR-017 и Constitution): все новые
функции пайплайна принимают контекст явным параметром (`^Parser`,
`^Resolver_Ctx`, `^Type_Ctx`, `^Compiler`, `^VM`), новых package-level
мутабельных переменных не вводится, вспомогательные проверки (совпадение
тегов, вычисление покрытия вариантов) реализуются как чистые функции над
входным AST и таблицей вариантов.

## Technical Context

**Language/Version**: Odin (текущий toolchain из `Justfile`; версии не
закреплены — берётся то, что установлено локально)
**Primary Dependencies**: только `core:fmt`, `core:strings`, `core:strconv`,
`core:os` из стандартной библиотеки Odin (уже используются). Новых внешних
зависимостей не добавляется.
**Storage**: N/A (интерпретатор в одном процессе, состояние в памяти)
**Testing**: `odin test .` с флагами из `AGENTS.md`
(`-debug -vet -strict-style -vet-tabs -warnings-as-errors`); e2e-тесты через
`e2e_test.odin::run_code`.
**Target Platform**: та же платформа, что и у существующего интерпретатора
(`darwin`, `linux` — определяется установкой Odin).
**Project Type**: compiler / interpreter (моноpackage `main`).
**Performance Goals**: `выбор` c `n` ветками — `O(n)` шагов сопоставления,
без аллокаций на путь совпадения (кроме биндера).
**Constraints**:
- никаких новых глобальных мутабельных переменных;
- сообщения об ошибках — на русском;
- существующие e2e-тесты и `test.ps` продолжают проходить;
- ветка `Никогда` при вычислении типа `выбор` ведёт себя как в `если`.
**Scale/Scope**: язык учебный, программы — единицы файлов; ожидаемый предел
на один `выбор` — десятки веток, на один ADT — десятки вариантов; ограничение
`u8` на индексы констант в `Compiled_Function` остаётся в силе.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Constitution: [.specify/memory/constitution.md](../../.specify/memory/constitution.md), v1.0.0.

- **I. Think Before Coding**:
  - Явные предположения: см. секцию Assumptions в spec + список решений в
    Phase 0 research.md.
  - Открытые развилки закрыты явно: Q1 сессии клэрификации выбрала
    `Тип.Вариант`; разделитель вариантов ADT (`;` или новая строка)
    зафиксирован в research.md R1; выбор четвёртого опкода
    (`Build_Variant`) зафиксирован в contracts/opcodes.md и в T004/T017.
    Ни одна развилка не выбрана молча.
  - PASS.
- **II. Simplicity First**:
  - Только шаблоны из FR-006 (`_`, биндер, конструктор). Нет литеральных
    шаблонов, нет охран, нет or-шаблонов.
  - Нет универсального pattern-compilation engine — линейная цепочка
    сравнений тегов.
  - Переиспользуются существующие опкоды прыжков; добавляется минимум
    двух новых.
  - PASS.
- **III. Surgical Changes**:
  - Правки только в файлах пайплайна: `parser.odin`, `resolver.odin`,
    `type_cheker.odin`, `compiler.odin`, `vm.odin`, `token.odin` / `lexer.odin`
    (только если понадобится дополнительный токен — по текущему плану не
    понадобится). Новый файл: тесты в `e2e_test.odin` дополняются; создание
    отдельного `.ps` для смоук-программы.
  - Существующий сломанный branch `tok_kind == .Enum_Decl` в top-level
    dispatch parser'а исправляется (это прямая часть работы, не «drive-by»).
  - Никаких unrelated переименований / переформатирований.
  - PASS.

Complexity Tracking пуст: нарушений принципов нет.

## Project Structure

### Documentation (this feature)

```text
specs/001-adt-pattern-matching/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output (AST + Type + runtime shapes)
├── quickstart.md        # Phase 1 output (smoke-программа на языке)
├── contracts/           # Phase 1 output (грамматика + опкоды + ошибки)
│   ├── grammar.md
│   ├── opcodes.md
│   └── diagnostics.md
└── checklists/
    └── requirements.md  # spec quality checklist (already written)
```

### Source Code (repository root)

Проект — один Odin-package `main` в корне репозитория. Никаких новых
поддиректорий не создаётся.

```text
/                          # package main
├── token.odin             # TokenKind (уже содержит .Enum, .Match)
├── lexer.odin             # ключевые слова "перечисление"/"выбор" уже маппятся
├── parser.odin            # РАСШИРИТЬ: parse_enum_decl (починить),
│                          #   parse_match_expr, parse_pattern; top-level
│                          #   dispatch правит ветку `тип X = перечисление`.
├── resolver.odin          # РАСШИРИТЬ: Symbol_Kind.Enum_Variant, скоуп
│                          #   ветки match, разрешение конструкторов и
│                          #   квалифицированных имён.
├── type_cheker.odin       # РАСШИРИТЬ: Type_Kind.Enum + Type_Variant, вывод
│                          #   типа match, проверки исчерпываемости и
│                          #   недостижимости, разбор Опция/Результат.
├── compiler.odin          # РАСШИРИТЬ: Opcode.Match_Tag,
│                          #   Opcode.Get_Variant_Field; compile_match,
│                          #   compile_pattern; Value +^Variant_Value.
├── vm.odin                # РАСШИРИТЬ: исполнение новых опкодов; функции
│                          #   variant_tag / variant_field для встроенных
│                          #   Option/Result.
├── e2e_test.odin          # РАСШИРИТЬ: 3+ теста, покрывающие US1..US3.
└── specs/001-.../quickstart.md  # смоук .ps-программа (в спеках, не в корне)
```

**Structure Decision**: остаёмся в одном package `main`. Разделение по
файлам — по стадиям пайплайна, как сейчас. Никаких новых пакетов и подпапок
исходников не вводится (Simplicity First, Surgical Changes).

## Complexity Tracking

Нарушений Constitution нет; таблица не заполняется.
