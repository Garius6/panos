# Implementation Plan: Пакеты-заготовки для зависимостей gitsync

**Branch**: `004-gitsync-dependency-packages` | **Date**: 2026-07-21 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/004-gitsync-dependency-packages/spec.md`

## Summary

Первый этап переноса `gitsync` (синхронизация хранилища 1С с git,
https://github.com/oscript-library/gitsync) на panos: не порт кода, а
подготовка фундамента. Из 15 рантайм-зависимостей `gitsync` — 7 получают
пустой пакет-заготовку в `panosiki/` (латинское имя = оригинальному,
версия `0.1.0`, свой git-репозиторий с тегом `v0.1.0` — без него `pan`
не сможет их зарезолвить позже), 1 (`logos`) входит в panos stdlib под
именем `слог`, 6 исключены как дублирующие существующий stdlib/`pan`
(`json`, `strings`, `fs`, `delegate`, `opm`, `1commands`), 1 (`reflector`)
отложена — блокирует отсутствующая в panos рефлексия. Решения по каждой
зависимости — не по названию, а по факту (проверены реальные packagedef
через `gh api`) и с явным приоритетом "не дублировать, не портировать
1:1 то, что решается иначе средствами panos".

## Technical Context

**Language/Version**: panos (`.ps`) для модуля `слог`; никаких изменений в
`core/` (Odin) — в отличие от feature 003, эта фича не требует новых
builtin'ов (логирование целиком реализуется существующим `ввод_вывод`).
**Primary Dependencies**: уже существующий `panosiki/pan` (для `pan init`
каждой из 7 заготовок), системный `git` (для инициализации 7 репозиториев).
**Storage**: файловая система — 7 независимых git-репозиториев в
`panosiki/`, один новый файл `std/слог.ps` в этом репозитории.
**Testing**: `std/слог.ps` — через существующий `core` test suite (по
аналогии с прочими stdlib-модулями); 7 заготовок — структурная проверка
(валидный `pan.toml`, git-тег `v0.1.0`), без содержательных тестов (нет
бизнес-логики, FR-003).
**Target Platform**: та же среда, где уже работают `panos`/`pan` (macOS/
Linux, системный `git` в `PATH`).
**Project Type**: multi-repo scaffolding (этот репозиторий + 7 новых
независимых git-репозиториев в `panosiki/`) + одно stdlib-дополнение.
**Performance Goals**: не применимо — внутренний тулинг, не рантайм
конечного пользователя.
**Constraints**: `слог` не должен требовать изменений в `core/` (Simplicity
First — минимальный API поверх уже существующих builtin'ов).
**Scale/Scope**: 7 пакетов-заготовок, 1 stdlib-модуль (5 функций), 1
карта соответствия на 15 строк (уже в spec.md).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **I. Think Before Coding** — PASS. Каждое нетривиальное решение (состав
  15→7/1/6/1, нейминг, версионирование, git-инициализация, scope `слог`)
  прошло через явное обсуждение и/или `/speckit.clarify` с пользователем,
  по обеим сессиям специфицированное в `spec.md` → Clarifications и
  подкреплённое реальной проверкой packagedef каждой зависимости (не
  предположениями), см. `research.md`.
- **II. Simplicity First** — PASS. Явный, неоднократный отказ от
  переразмеренного scope: 6 зависимостей исключены как дубликаты,
  `reflector` отложена вместо принудительного (и нереализуемого без core-
  изменений) порта, `слог` сознательно урезан до 5 функций без appenders/
  layouts, `cli`/`cli-selector` явно помечены "редизайн"/"суженный scope",
  а не порт "на всякий случай" с запасом функциональности.
- **III. Surgical Changes** — PASS. Изменения в этом репозитории — ровно
  один новый файл (`std/слог.ps`) плюс обновление `CLAUDE.md`; ничего
  существующего не трогается. 7 новых git-репозиториев — полностью новые,
  не пересекаются с существующим содержимым `panosiki/`.

Гейт пройден — нарушений нет, Complexity Tracking не требуется.

## Project Structure

### Documentation (this feature)

```text
specs/004-gitsync-dependency-packages/
├── plan.md              # этот файл
├── research.md          # Phase 0 — решения и альтернативы
├── data-model.md         # Phase 1 — сущности (Пакет-заготовка, слог, Отложенная, Карта)
├── quickstart.md         # Phase 1 — сквозной сценарий (создание 7 пакетов + слог)
└── contracts/
    ├── package-skeleton.md   # контракт структуры каждого из 7 пакетов
    └── слог-api.md            # контракт API нового stdlib-модуля
```

### Source Code (repository root)

Эта фича трогает файлы в **этом репозитории** (1 новый файл) и создаёт
**7 полностью новых независимых репозиториев** в соседней директории:

```text
# 1. Этот репозиторий (panos)
std/
└── слог.ps              # новый: логирование (отладка/инфо/предупреждение/ошибка/критично)

# 2. ../panosiki/ (7 новых независимых git-репозиториев, плоско, без вложенности)
../panosiki/tempfiles/       # pan.toml (tempfiles, 0.1.0) + start.ps, git tag v0.1.0
../panosiki/v8runner/        # pan.toml (v8runner, 0.1.0) + start.ps, git tag v0.1.0
../panosiki/gitrunner/       # pan.toml (gitrunner, 0.1.0) + start.ps, git tag v0.1.0
../panosiki/v8storage/       # pan.toml (v8storage, 0.1.0) + start.ps, git tag v0.1.0
../panosiki/cli/             # pan.toml (cli, 0.1.0) + start.ps, git tag v0.1.0
../panosiki/cli-selector/    # pan.toml (cli-selector, 0.1.0) + start.ps, git tag v0.1.0
../panosiki/configor/        # pan.toml (configor, 0.1.0) + start.ps, git tag v0.1.0
```

**Structure Decision**: `std/слог.ps` — обычное дополнение стандартной
библиотеки, туда же, где уже лежат `std/архив.ps`, `std/супервизор.ps` и
т.д. 7 пакетов — плоско в `panosiki/`, как уже существующие `panosiki/pan`
и `panosiki/panos-raylib` (не вложены под общую "gitsync"-директорию —
решение зафиксировано в Assumptions spec.md).

## Complexity Tracking

> Нет нарушений Constitution Check — таблица не заполняется.
