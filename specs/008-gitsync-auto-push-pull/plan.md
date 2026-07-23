# Implementation Plan: gitsync — авто push/pull через --remote

**Branch**: `008-gitsync-auto-push-pull` | **Date**: 2026-07-23 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/008-gitsync-auto-push-pull/spec.md`

## Summary

Добавить `Контекст_Синхронизации.remote: Опция(Строка)` и, при указании,
обернуть цикл `синхронизировать` pull-ом (`--ff-only`, escape hatch через
`Репозиторий.выполнить_команду`) до и push-ом (только если новые коммиты
были) после. Ветка — всегда через `получить_текущую_ветку()`, не
хардкод. `--remote`/`-r` флаг у CLI-подкоманды `sync`. `gitrunner` не
меняется.

## Technical Context

**Language/Version**: panos, стандартные модули `фс`, `строки`, `ос`.
**Primary Dependencies**: `panosiki/gitrunner` (без изменений, только
существующие `выполнить_команду`/`получить_текущую_ветку`).
**Storage**: N/A (git-состояние, не файлы).
**Testing**: `std/тест.ps` + РЕАЛЬНЫЙ git (два локальных клона + общий
bare-репозиторий как "remote") — сеть/аутентификация не нужны для этой
проверки, весь git — настоящий, не подделка (в отличие от 1С-частей).
**Target Platform**: кроссплатформенно (git CLI везде одинаков).
**Project Type**: library extension (без нового пакета) — только
изменение `panosiki/gitsync/sync.ps` + `start.ps` (флаг).
**Performance Goals**: N/A — один pull + один push на запуск, не в цикле.
**Constraints**: push-ошибка не должна откатывать уже сделанные локальные
коммиты/VERSION (FR-004) — `Результат_Синхронизации` должен УЖЕ отражать
локальный успех ДО того, как push пробуется.
**Scale/Scope**: одно новое поле контекста, 2 новые внутренние функции в
`sync.ps` (обернуть pull/push), 1 новый CLI-флаг.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **Think Before Coding**: 3 развилки (опциональность/pull-стратегия/
  push-триггер) уже решены явно с пользователем до специфкации — не
  скрытые допущения.
- **Simplicity First**: `--ff-only` — прямой escape hatch, НЕ новый метод
  `gitrunner` (частный случай, не общего назначения).
- **Surgical Changes**: `gitrunner`/`v8storage`/`панosiki/скобки` не
  трогаются вообще — только `gitsync/sync.ps` + `start.ps`.

Нарушений нет.

## Project Structure

### Documentation (this feature)

```text
specs/008-gitsync-auto-push-pull/
├── plan.md
├── research.md        # Phase 0 — где именно pull/push в потоке синхронизации, обработка ошибок push
├── data-model.md       # Phase 1 — Контекст_Синхронизации.remote, Результат_Синхронизации (не меняется)
└── quickstart.md        # Phase 1 — ручная проверка через 2 локальных клона + bare-репозиторий
```

Без `contracts/` — меняет существующий `sync`-контракт ДОБАВЛЕНИЕМ
одного опционального флага, не вводит новую команду (см. `specs/
006-gitsync-port/contracts/cli-surface.md` — расширяется, не
переопределяется).

### Source Code (repository root)

```text
../panosiki/gitsync/
├── sync.ps      # + поле remote в Контекст_Синхронизации, pull/push-обёртки вокруг цикла
├── start.ps     # + флаг --remote/-r у подкоманды sync
└── test_sync.ps # + тесты: pull fast-forward, расхождение -> ошибка без прогресса, push только при новых коммитах, push-ошибка не откатывает VERSION
```

**Structure Decision**: изменения целиком внутри уже существующего
`panosiki/gitsync/` — ни один из 8 остальных пакетов не трогается.

## Complexity Tracking

Нарушений конституции нет — секция не заполняется.
