# Implementation Plan: Портирование ядра gitsync на panos

**Branch**: `006-gitsync-port` | **Date**: 2026-07-23 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/006-gitsync-port/spec.md`

## Summary

Новый самодостаточный пакет `panosiki/gitsync` (свой git-репозиторий, тот
же паттерн, что остальные 7 зависимостей): CLI с тремя подкомандами
(`sync`/`init`/`set-version`) поверх уже реализованных `gitrunner`/
`v8runner`/`v8storage`/`cli`/`std/кодирование/toml.ps`. Ключевая находка
планирования (см. research.md) — ни один из уже реализованных пакетов не
нуждается в расширении: то, что казалось пробелом (нет "список версий
хранилища", нет "автор коммита" в `закоммитить`), на деле уже закрыто
композицией существующих методов (последовательный перебор номеров версий
до первой ошибки; `установить_настройку(user.name/email)` перед каждым
`закоммитить` вместо отдельного параметра-автора).

## Technical Context

**Language/Version**: panos (сам язык, не Odin — это пользовательский
пакет на panos, как остальные 7 зависимостей, не правка компилятора)
**Primary Dependencies**: `panosiki/gitrunner`, `panosiki/v8runner`,
`panosiki/v8storage`, `panosiki/cli`, `std/кодирование/toml.ps`,
`std/слог.ps`, `фс`/`ос` builtins — ВСЕ уже реализованы, ни один не
меняется этой фичей (см. Summary)
**Storage**: Файлы `VERSION` (текст, число) и `AUTHORS` (TOML) в рабочем
git-каталоге пользователя — не БД, не сервис
**Testing**: `std/тест.ps`-стиль e2e-тесты нового пакета, тот же приём
(подменный исполняемый файл вместо реального 1cv8), что уже применён в
`v8runner`/`v8storage` — плюс РЕАЛЬНЫЙ git (как в `gitrunner`), поскольку
git-часть логики полностью проверяема без 1С
**Target Platform**: Тот же, что весь остальной стек panos-пакетов
(native `panos`-интерпретатор, CLI-инструмент)
**Project Type**: CLI-инструмент (единственный пакет, `panosiki/gitsync/`)
**Performance Goals**: Не применимо — синхронизация несколько версий раз в
день/неделю, не hot path
**Constraints**: Нет реальной платформы 1С в песочнице разработки (как и
для `v8runner`/`v8storage` ранее) — 1С-специфичное поведение
непроверяемо, тестируется через подменный исполняемый файл
**Scale/Scope**: Единицы-десятки версий хранилища за один вызов `sync`,
единицы пользователей в `AUTHORS`

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **I. Think Before Coding**: Два места, где на первый взгляд не хватало
  функциональности уже реализованных пакетов (список версий хранилища;
  автор коммита), разобраны ДО написания кода — оба закрываются композицией
  уже существующих методов, без изменения этих пакетов (см. research.md
  §1, §2). Решение не выдумано втихую — альтернатива (расширить
  `v8storage` парсингом вывода `/ConfigurationRepositoryReport`) явно
  отклонена как более рискованная (риск непроверяемо угадать формат вывода
  без реальной платформы — та же причина, по которой история версий уже
  была исключена из v8storage в spec 004).
- **II. Simplicity First**: Ни одного нового native/core builtin'а, ни
  одного расширения уже существующих 7 пакетов — вся фича на 100%
  композиция уже готового. VERSION — простой текстовый файл (не JSON/TOML
  ради одного числа). Плагины/push-pull автоматизация/http-хранилище
  осознанно вне scope (см. spec.md Assumptions).
- **III. Surgical Changes**: Новый пакет `panosiki/gitsync` — отдельный
  git-репозиторий, изменений в panos (`core/`, `std/`) или в остальных 7
  panosiki-пакетах эта фича не требует вообще.

**Итог**: нарушений нет, Complexity Tracking не заполняется.

## Project Structure

### Documentation (this feature)

```text
specs/006-gitsync-port/
├── plan.md              # This file (/speckit.plan command output)
├── research.md          # Phase 0 output (/speckit.plan command)
├── data-model.md         # Phase 1 output (/speckit.plan command)
├── quickstart.md         # Phase 1 output (/speckit.plan command)
├── contracts/            # Phase 1 output (/speckit.plan command)
└── tasks.md              # Phase 2 output (/speckit.tasks command - NOT created by /speckit.plan)
```

### Source Code (repository root)

Новый пакет живёт ВНЕ этого репозитория, в `../panosiki/gitsync/` (тот же
паттерн, что 7 уже реализованных пакетов — `pan init` + свой
git-репозиторий, не подкаталог `panos`):

```text
../panosiki/gitsync/
├── pan.toml               # имя=gitsync, зависимости на gitrunner/v8runner/v8storage/cli
├── start.ps                # точка входа — разбор CLI-аргументов, диспетчинг подкоманд
├── sync.ps                 # US1 — цикл синхронизации (ядро фичи)
├── version_file.ps          # чтение/запись VERSION (текстовый файл, см. data-model.md)
├── authors_file.ps           # чтение AUTHORS (TOML), lookup по имени пользователя хранилища
├── repo_init.ps               # US2 — init (git init + VERSION/AUTHORS заготовки, идемпотентно)
├── set_version.ps              # US3 — set-version (перезапись VERSION)
├── fake_1cv8.sh                 # подменный исполняемый файл для тестов (тот же приём, что
│                                #   v8runner/v8storage), с поддержкой "-v N" -> ошибка при N > порог
└── test_*.ps                     # e2e-тесты (std/тест.ps), см. quickstart.md
```

**Structure Decision**: Новый самостоятельный пакет `panosiki/gitsync/`,
файлы разделены по ответственности (sync/version_file/authors_file/
repo_init/set_version) — не один гигантский `start.ps`, каждый файл
независимо тестируем.

## Complexity Tracking

*Не заполняется — нарушений Constitution Check нет.*
