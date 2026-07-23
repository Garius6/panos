# Implementation Plan: Устранение проблем языка panos, найденных при переносе gitsync

**Branch**: `005-language-fixes` | **Date**: 2026-07-23 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/005-language-fixes/spec.md`

## Summary

Три точечных исправления/расширения грамматики и тайпчекера компилятора
panos, найденные при портировании 6 пакетов-зависимостей gitsync:

1. **P1** — `parse_type`'s `Type_Qualified`-ветка не проверяет `(`
   generic-аргументов после `модуль.Имя` (в отличие от локального
   `Type_Generic`, который эту проверку уже делает) — квалифицированный
   generic-тип из другого модуля непригоден как type-annotation.
2. **P2** — тело ветки `выбор`/шаблона — ровно один statement; `arm.body`
   уже типа `[dynamic]Stmt`, но парсер жёстко `break`-ит после первого. По
   итогам обсуждения с пользователем: дизайн для многострочной ветки —
   `Шаблон тогда ... конец` (переиспользует существующий токен `Then`,
   уже применяемый в `если...тогда`, вместо backtracking или нового
   keyword) — однострочная форма `Шаблон -> выражение` остаётся без
   изменений.
3. **P3** — рассинхронизация: `parse_param_list`/литералы `массив()`/
   `соответствие()` уже допускают завершающую запятую, а список аргументов
   вызова (`Call_Expr`), список типов варианта перечисления и список
   аргументов шаблона-конструктора — нет. Задача — привести оставшиеся
   вызовы к уже установленному в этом же файле паттерну.

## Technical Context

**Language/Version**: Odin (тулчейн зафиксирован через `Justfile`, см. AGENTS.md)
**Primary Dependencies**: Нет новых — правки только в существующих `core/*.odin` (компилятор), stdlib `core:fmt`
**Storage**: N/A
**Testing**: `odin test ./core` (`just test`) — существующий e2e-набор (`core/e2e_*_test.odin`, 251+ тестов) + новые e2e-тесты для каждой из трёх правок
**Target Platform**: Тот же, что и весь panos-тулчейн (native + wasm; фича не трогает `core/vm_*_wasm.odin`, только parse/resolve/typecheck/compile — фронтенд компилятора, общий для обеих сборок)
**Project Type**: compiler (единственный проект, `core/` — lexer→parser→resolver→type_cheker→compiler→vm pipeline)
**Performance Goals**: Не применимо — правки не в горячем пути рантайма (VM), только в парсинге/тайпчекинге исходного текста при компиляции
**Constraints**: Полная обратная совместимость (FR-008) — весь существующий `.ps`-код (`std/`, `panosiki/*`) должен продолжать компилироваться идентично
**Scale/Scope**: 3 точечных изменения в `core/parser.odin` (+ `core/resolver.odin`/`core/type_cheker.odin` для P1, возможно `core/compiler.odin` для P2) — не архитектурная переработка

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **I. Think Before Coding**: Пройдено ДО написания этого плана —
  многострочные ветки (P2) изначально казались тривиальной правкой ("просто
  убрать break"), но при чтении `parse_match_expr`/`parse_pattern`
  обнаружилась реальная неоднозначность грамматики (шаблон `a.b(...)`
  синтаксически неотличим от statement-вызова метода). Альтернативы
  представлены пользователю явно (новый keyword / backtracking / убрать из
  scope), выбран вариант с переиспользованием `тогда`/`конец` — см.
  research.md §2.
- **II. Simplicity First**: P1 и P3 — минимальные, локальные правки внутри
  уже существующих циклов парсинга, использующие уже установленный в этом
  же файле паттерн (trailing-comma safe loop уже есть у
  `parse_param_list`/литералов — просто копируется на оставшиеся 3 цикла).
  P2 переиспользует существующий токен `Then`, а не вводит новый — никакой
  новой инфраструктуры (backtracking, checkpoint/rewind) не добавляется.
- **III. Surgical Changes**: Изменения ограничены `core/parser.odin` (все
  три правки) + `core/type_cheker.odin` (только P1 — инстанцирование
  generic-аргументов квалифицированного типа, `Type_Qualified`-ветка
  `resolve_type_node`, тем же путём `instantiate_type`/
  `decl_type_param_order`/`generic_instance_cache`, что уже используется
  для локального `Type_Generic`). `core/resolver.odin` НЕ трогается —
  `Type_Qualified` резолвится целиком в `type_cheker.odin`, резолвер к
  типам вообще не обращается (подтверждено grep: `Type_Qualified` нигде в
  `resolver.odin`). `core/compiler.odin` НЕ трогается для P2 —
  `compile_match_expr` уже вызывает `compile_block(ctx, arm.body, is_val)`
  для ЛЮБОЙ длины `arm.body`, а `infer_match_expr` (type_cheker.odin) уже
  обходит `arm.body` циклом `for stmt, i in arm.body` с хвостовым-
  выражением-как-значением — вся остальная часть pipeline уже написана
  generically и ничего не знает о том, что раньше туда попадал только один
  statement. Ни один `std/`- или `panosiki/`-файл не меняется — фича
  демонстрирует, что существующий код (написанный в рамках старых
  ограничений) продолжает работать, а НЕ требует правки для использования
  новых возможностей.

**Итог**: нарушений нет, Complexity Tracking не заполняется.

## Project Structure

### Documentation (this feature)

```text
specs/005-language-fixes/
├── plan.md              # This file (/speckit.plan command output)
├── research.md          # Phase 0 output (/speckit.plan command)
├── data-model.md         # Phase 1 output (/speckit.plan command)
├── quickstart.md         # Phase 1 output (/speckit.plan command)
├── contracts/            # Phase 1 output (/speckit.plan command)
└── tasks.md              # Phase 2 output (/speckit.tasks command - NOT created by /speckit.plan)
```

### Source Code (repository root)

```text
core/
├── parser.odin           # Все три правки:
│                         #   P1 — Type_Qualified получает params []Type_Node + разбор "(...)"
│                         #   P2 — parse_match_expr: "Шаблон тогда ... конец" многострочная форма
│                         #   P3 — trailing comma: Call_Expr args, enum variant types,
│                         #        pattern-ctor args, Type_Generic type-args, Type_Tuple —
│                         #        полный список из 17 comma-циклов файла аудируется на
│                         #        implementation-этапе (research.md §3)
├── type_cheker.odin      # Только P1 — Type_Qualified-ветка resolve_type_node инстанцирует
│                         #   generic-аргументы тем же путём (instantiate_type/
│                         #   decl_type_param_order/generic_instance_cache), что и
│                         #   пользовательский Type_Generic — P2 и P3 НЕ требуют изменений
│                         #   здесь (infer_match_expr уже обходит arm.body произвольной длины)
└── e2e_*_test.odin       # Новые e2e-тесты для каждой из трёх правок (см. quickstart.md)
```

**Structure Decision**: Единственный существующий проект (`core/` —
компилятор panos). Новых директорий/модулей не создаётся. `core/resolver.
odin` и `core/compiler.odin` НЕ меняются — обе точки уже работают
generically (см. Constitution Check выше). Тестируется существующим `core`
test suite (`just test`).

## Complexity Tracking

*Не заполняется — нарушений Constitution Check нет.*
