# Implementation Plan: Внутренняя документация архитектуры интерпретатора

**Branch**: `002-interpreter-architecture-docs` | **Date**: 2026-07-20 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/002-interpreter-architecture-docs/spec.md`

## Summary

Написать внутреннюю (для мейнтейнеров, не пользователей языка) документацию
архитектуры интерпретатора panos — pipeline (лексер→парсер→резолвер→
тайпчекер→компилятор→VM), рантайм (GC, модули, platform-split), LSP-сервер,
известные грабли, тулчейн/тестирование и практические рецепты типичных
изменений. Каждый факт привязан к конкретному файлу/структуре/функции (не
общие фразы). Технический подход: новый раздел существующего mdBook
(`docs/src/architecture/`), контент извлекается прямым чтением АКТУАЛЬНОГО
кода (не памятью из истории чата), один markdown-файл на тему из
Key Entities спеки.

## Technical Context

**Language/Version**: Русскоязычная техническая проза (Markdown), тот же
регистр, что существующий `docs/src/language/*.md` (`book.toml`:
`language = "ru"`)
**Primary Dependencies**: mdBook (уже используется для `docs/`, новой
зависимости не вводится)
**Storage**: N/A
**Testing**: (1) `mdbook build` без ошибок (валидная структура, все
внутренние ссылки резолвятся); (2) самопроверка автором по каждому разделу
против чеклиста ниже (SC-002/SC-003 — без формального внешнего
тестировщика, см. Clarifications в spec.md)
**Target Platform**: Статический сайт mdBook (тот же вывод, что и
существующая документация языка)
**Project Type**: Документация (не код; исходники интерпретатора не
меняются этой фичей)
**Performance Goals**: N/A
**Constraints**: Каждое архитектурное утверждение ДОЛЖНО цитировать
конкретный файл/структуру/функцию (FR-012); контент отражает состояние кода
НА МОМЕНТ НАПИСАНИЯ, проверенное прямым чтением файлов, а не пересказом
исторических код-комментариев без проверки (см. Edge Cases в spec.md)
**Scale/Scope**: 6 сущностей документации из spec.md → ~20 markdown-файлов
(см. Project Structure ниже); НЕ включает пользовательскую документацию
языка (`docs/src/language/*.md` не трогается) и не расширяет `AGENTS.md`

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **I. Think Before Coding** — PASS. Все неоднозначности (расположение
  документации, объём LSP, наличие рецептов, полнота "граблей", размер
  списка рецептов, формальность SC-002) уже сняты в `/speckit.clarify` до
  начала планирования; ничего не додумывается молча в этом плане.
- **II. Simplicity First** — PASS. Структура файлов (Project Structure ниже)
  — прямое отображение 1:1 на Key Entities и FR-001…FR-014 спеки; ни одной
  главы/файла, не выведенной напрямую из явного требования (без
  "на будущее"/спекулятивных разделов вроде roadmap или FAQ).
- **III. Surgical Changes** — PASS. Изменения ограничены: новые файлы под
  `docs/src/architecture/`, одна аддитивная правка `docs/src/SUMMARY.md`
  (добавление раздела). `docs/src/language/*.md`, `AGENTS.md`, любой код в
  `core/`/`lsp/`/`std/` — НЕ трогаются (эта фича не меняет поведение
  интерпретатора, только документирует его текущее состояние).

Нарушений нет — Complexity Tracking не заполняется.

**Post-Design Re-check** (после Phase 1): структура из `data-model.md`/
`contracts/chapter-template.md` не добавила ничего сверх исходного
Project Structure — гейты остаются PASS без изменений.

## Project Structure

### Documentation (this feature)

```text
specs/002-interpreter-architecture-docs/
├── plan.md              # This file (/speckit.plan command output)
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   └── chapter-template.md   # Структурный контракт: обязательные секции каждой главы
└── tasks.md              # Phase 2 output (/speckit.tasks — не создаётся этой командой)
```

### Итоговый артефакт фичи (репозиторий panos)

Эта фича не производит код — только markdown-документацию внутри
существующего mdBook (`docs/`). Дерево ниже — прямое отображение Key
Entities из spec.md на конкретные файлы:

```text
docs/src/
├── SUMMARY.md                          # ПРАВИТСЯ: + раздел "Архитектура интерпретатора"
└── architecture/                        # НОВОЕ — весь объём этой фичи
    ├── overview.md                      # Как читать этот раздел, связь с AGENTS.md/language/
    │
    │   # --- Key Entity: "Pipeline" (FR-001, FR-002) ---
    ├── lexer.md                         # core/lexer.odin, token.odin
    ├── parser.md                        # core/parser.odin
    ├── resolver.md                      # core/resolver.odin
    ├── type-checker.md                  # core/type_cheker.odin
    ├── compiler-and-vm.md               # core/compiler.odin, vm.odin (см. US1/AC2: opcode трогает оба)
    ├── generics-and-monomorphization.md # core/monomorphize.odin, ast_clone.odin (FR-003)
    │
    │   # --- Key Entity: "Рантайм" (FR-004, FR-005, FR-009) ---
    ├── memory-and-gc.md                 # core/gc.odin, GC_Header-инвариант
    ├── module-system.md                 # core/module_loader.odin, Module_Graph, std/*.ps vs встроенные
    ├── platform-split.md                # _native/_wasm пары, #+build, wasm/main.odin
    │
    │   # --- Key Entity: "LSP" (FR-006, FR-007) ---
    ├── lsp.md                           # lsp/*.odin, LSP_Document, известные ограничения
    │
    │   # --- Key Entity: "Известные грабли" (FR-008) ---
    ├── known-pitfalls.md                # map[key]-сегфолт + json.marshal/указатели (открытый список)
    │
    │   # --- Key Entity: "Тулчейн и тестирование" (FR-010, FR-011) ---
    ├── toolchain-and-testing.md         # 3 сборочных цели, Justfile, редеплой LSP, run_code/e2e
    │
    │   # --- Key Entity: "Рецепты" (FR-014) ---
    └── recipes/
        ├── overview.md                  # Как устроен рецепт (см. contracts/chapter-template.md)
        ├── new-binary-operator.md
        ├── new-lsp-method.md
        ├── new-stdlib-function.md
        ├── new-ast-node.md
        ├── new-diagnostic.md
        └── new-stdlib-module.md
```

**Structure Decision**: Файл-на-тему, гранулярность 1:1 с Key Entities/FR
спеки (Simplicity First — ни объединения нескольких FR в один файл, ни
дробления одного FR на несколько без явной причины). Единственное
объединение — `compiler-and-vm.md`: сознательно, потому что FR-001/AC2
явно требует показывать opcode-изменение как ЕДИНУЮ операцию, трогающую оба
файла одновременно; раздельные главы создали бы ложное впечатление, что
компилятор и VM независимы. `docs/src/language/*.md` и `AGENTS.md` не
входят в дерево — они не меняются (см. Constitution Check, Assumptions
spec.md).
