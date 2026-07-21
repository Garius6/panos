# Implementation Plan: Pan — пакетный менеджер для panos

**Branch**: `003-pan-package-manager` | **Date**: 2026-07-21 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/003-pan-package-manager/spec.md`

## Summary

Pan — пакетный менеджер для panos, написанный на panos, живущий в отдельном
репозитории `../panosiki/pan/`. Управляет git-зависимостями (semver-диапазоны
поверх тегов, единая версия пакета на весь граф), раскладывает их в
project-local `модули/` (уже резолвится существующим `core/resolver_import_native.odin`
без изменений), и предоставляет `pan run` для запуска пакета напрямую через
бинарь `panos`. Реализация требует минимального prerequisite-расширения
`core/` (Odin) тремя builtin'ами — спавн процессов (`ос.выполнить`),
завершение процесса с точным кодом (`ос.завершить`) и directory-ops в
`фс` — которых сегодня в стандартной библиотеке нет; без них ни `git clone`,
ни контролируемый cwd и exit code для `pan run`, ни раскладка вложенных путей
в `модули/`/кэше невозможны.

## Technical Context

**Language/Version**: panos (self-hosted, `.ps`-исходники) для самого pan;
Odin (тулчейн пинned через корневой `Justfile`) для двух новых builtin'ов в
`core/`.
**Primary Dependencies**: `std/кодирование/toml.ps` (манифест/lock),
`std/архив.ps` + `сжатие.разжать_gzip` (на случай вспомогательной распаковки,
основной путь получения зависимостей — git), `std/сеть/http.ps` (не
на критическом пути v1, см. research.md п.5), `std/тест.ps` (тесты pan);
новые builtin'ы `ос.выполнить` и directory-ops в `фс` (core, Odin).
**Storage**: локальная файловая система — `pan.toml`/`pan.lock` (человеко-
редактируемые/generated TOML) в корне пакета-потребителя, `модули/` в корне
пакета-потребителя, общий локальный кэш `~/.pan/cache/...` на машине
пользователя.
**Testing**: `just test` (`odin test ./core`) для двух новых builtin'ов;
`std/тест.ps` для panos-кода самого pan (в `../panosiki/pan/`).
**Target Platform**: CLI, там же, где уже собирается `panos` (native
build — macOS/Linux/Windows через Odin; wasm-сборка не затрагивается,
`ос.выполнить`/directory-ops — native-only по аналогии с
`resolver_import_native.odin` / `resolver_import_wasm.odin`).
**Project Type**: CLI-инструмент, разнесённый по двум репозиториям — core-
расширение в этом репозитории (`core/`) и сам pan как panos-пакет в
`../panosiki/pan/`.
**Performance Goals**: не критично — однопользовательский CLI-инструмент,
разрешение графа зависимостей и раскладка `модули/` — секунды, не мс/сек.
**Constraints**: `pan install` при валидном `pan.lock` и полном кэше не должен
обращаться к сети (SC-004); `pan run` должен давать идентичный результат из
любой поддиректории пакета (SC-005).
**Scale/Scope**: масштаб одного разработчика/небольшой экосистемы
(`panosiki`-org), не registry-масштаб; 4 user story (init, add/remove,
install, run), 14 функциональных требований (см. spec.md).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **I. Think Before Coding** — PASS. Все нетривиальные развилки (модель версий,
  синтаксис ограничений, источник имени пакета, build/run scope, недостающие
  stdlib-примитивы) прошли через явное обсуждение с пользователем
  (`/speckit.clarify` + последующий design discussion) до написания этого
  плана; решения и альтернативы зафиксированы в `research.md`. Ни одного
  решения не принято молча.
- **II. Simplicity First** — PASS с одной осознанной оговоркой. Три новых
  builtin'а в `core/` — не "функциональность сверх запрошенного", а
  необходимый prerequisite (без них фича не реализуема на panos в принципе);
  сама поверхность нового API — минимальна (см. Complexity Tracking ниже и
  `contracts/stdlib-additions.md`). Никакого registry, workspace,
  приватных/аутентифицированных источников, публикации пакетов — сознательно
  вне scope (см. Assumptions в spec.md).
- **III. Surgical Changes** — PASS. Изменения в `core/` — строго additive
  (новые procs в уже существующих модулях `ос`/`фс`, native-only build tag по
  аналогии с существующим `#+build !js` в резолвере импортов), не трогают
  поведение уже существующих builtin'ов. Весь остальной объём работы — новый
  код в отдельном репозитории `../panosiki/pan/`, не пересекается с
  существующими файлами этого репозитория за пределами `core/`.

Гейт пройден — нет неоправданных нарушений принципов, есть одна поименованная
и обоснованная сложность (см. Complexity Tracking).

## Project Structure

### Documentation (this feature)

```text
specs/003-pan-package-manager/
├── plan.md              # этот файл
├── research.md          # Phase 0 — решения и альтернативы
├── data-model.md         # Phase 1 — сущности (Манифест, Lock, Зависимость, ...)
├── quickstart.md         # Phase 1 — сквозной сценарий по всем 4 user story
├── contracts/
│   ├── cli.md                 # контракт команд pan (init/add/remove/install/run)
│   ├── stdlib-additions.md    # контракт двух новых builtin'ов в core
│   └── manifest-schema.md     # схема pan.toml / pan.lock
└── checklists/
    └── requirements.md   # уже пройден на этапе /speckit.specify
```

### Source Code (repository root)

Эта фича трогает файлы в **двух репозиториях**:

```text
# 1. Этот репозиторий (panos) — prerequisite-расширение core/
core/
├── stdlib.odin                    # + сигнатуры ос.выполнить, фс.создать_директорию/
│                                   #   список_директории/удалить_директорию
├── vm_io_native.odin               # (или новый файл vm_process_native.odin) —
│                                   #   реализация ос.выполнить поверх core:os/os2
└── (аналог resolver_import_native.odin/*_wasm.odin split — native-only,
     без wasm-варианта для этих двух builtin'ов)

core/*_test.odin                    # тесты новых builtin'ов (just test)

# 2. ../panosiki/pan/ (отдельный git-репозиторий) — сам pan, написан на panos
../panosiki/pan/
├── start.ps            # существующий entry point (CLI-парсинг флагов уже есть) —
│                        # расширяется диспетчеризацией подкоманд init/add/remove/install/run
├── манифест.ps          # разбор/сериализация pan.toml и pan.lock (поверх кодирование/toml)
├── семвер.ps            # парсинг и сравнение semver-диапазонов (^, ~, >=)
├── граф.ps              # разрешение графа зависимостей: единая версия на имя,
│                        # обнаружение конфликтов/циклов (FR-004, FR-005)
├── кэш.ps               # раскладка ~/.pan/cache и модули/ (поверх новых directory-ops)
├── гит.ps               # обёртка git clone/checkout поверх ос.выполнить
└── тесты/               # тесты на std/тест.ps, по одному файлу на модуль выше
```

**Structure Decision**: Разнесение по двум репозиториям — не архитектурный
выбор этой фичи, а следствие уже существующего разделения (`panos` — язык и
рантайм, `panosiki/pan` — пакет на этом языке, отдельный от рантайма
репозиторий, как и `panosiki/panos-raylib`). Внутри `../panosiki/pan/`
выбрана многофайловая структура (research.md п.10) вместо расширения одного
`start.ps` — каждый модуль независимо тестируется через `std/тест.ps` и
соответствует одной из сущностей `data-model.md`.

## Complexity Tracking

> Единственное отклонение от "чистого" Simplicity First — обосновано ниже.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|---------------------------------------|
| Три новых builtin'а в `core/` (`ос.выполнить`, `ос.завершить`, directory-ops в `фс`) | Подтверждено research-агентом: стандартная библиотека panos сегодня не даёт ни спавна процессов, ни создания/удаления/листинга директорий, ни явного завершения процесса с кодом. Без первого невозможны `git clone`/`git checkout` и контролируемый cwd для `pan run` (FR-013); без второго невозможен точный проброс exit code дочернего `panos` наружу; без третьего невозможна раскладка вложенных путей в `модули/` и локальном кэше. | Ограничиться только panos-кодом без правок `core/` — физически невозможно: нет обходного пути в userland для запуска процессов, явного завершения с кодом или работы с директориями как таковыми (не файлами). Пользователь явно подтвердил (Option A), что эта необходимость принимается как prerequisite, а не как повод сокращать scope фичи (Option C рассматривался и отклонён); `ос.завершить` добавлен по отдельному явному запросу закрыть exit-code гэп после первичной реализации. |
