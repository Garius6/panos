# Implementation Plan: gitsync — поверсионное авторство коммитов

**Branch**: `007-gitsync-per-version-author` | **Date**: 2026-07-23 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/007-gitsync-per-version-author/spec.md`

## Summary

Заменить единого автора всего запуска `sync` (упрощение из 006) на
поверсионного: расширить `panosiki/v8storage` методом, оборачивающим
`/ConfigurationRepositoryReport` (командная строка `1cv8`, тот же паттерн
`ос.выполнить`, что весь остальной `v8storage`); добавить новый пакет-парсер
скобочного текстового формата 1С (порт узкого среза `oscript-library/yabr`,
MPL-2.0 — только то, что нужно для отчёта по версиям хранилища, не полный
универсальный порт); подключить оба в `panosiki/gitsync/sync.ps`. Никакого
COM/native-слоя — вся новая логика на panos + существующий `ос.выполнить`.

## Technical Context

**Language/Version**: panos (Odin-toolchain компилятор, версия пина — `Justfile`), стандартные модули `фс`, `строки`, `ос`.
**Primary Dependencies**: `panosiki/v8storage` (расширяется методом), `panosiki/gitrunner`/`tempfiles`/`cli` (без изменений), новый пакет `panosiki/скобки` (парсер скобочного формата 1С — порт среза `oscript-library/yabr`).
**Storage**: файлы (MXL-отчёт хранилища, временный, как `.cf` в 006) — N/A постоянного хранилища.
**Testing**: `std/тест.ps` + `fake_1cv8.sh` (расширяется под `/ConfigurationRepositoryReport`) — тот же паттерн, что везде в проекте; реальная 1С недоступна в песочнице.
**Target Platform**: кроссплатформенно (в отличие от отклонённого COM-варианта) — `ос.выполнить` + текстовый парсер работают одинаково на любой ОС, где есть `1cv8`.
**Project Type**: library extension (расширение существующего пакета + новый библиотечный пакет), без нового CLI-surface — `gitsync sync` не меняет интерфейс для пользователя, только внутреннее поведение (авторство).
**Performance Goals**: не применимо — синхронный однократный вызов на версию, тот же порядок величины, что остальные вызовы `1cv8` в цикле `sync`.
**Constraints**: точный набор флагов `/ConfigurationRepositoryReport` и реальная структура MXL непроверяемы без установленной платформы 1С — та же оговорка, что весь проект.
**Scale/Scope**: один новый метод `v8storage`, один новый пакет-парсер (узкий срез — не универсальный `yabr`), изменение `sync.ps` (была: 1 автор на запуск → теперь: автор на версию, с fallback).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **Think Before Coding**: находка про yabr/скобочный формат — уже проверена
  реальным кодом (не гипотеза), MXL-cell-addressing (`magic offsets` в
  `ПолучитьОписаниеЯчейки`) — реальный риск, явно назван в research.md, не
  скрыт.
- **Simplicity First**: парсер — узкий срез (только то, что нужно для
  отчёта по версиям), НЕ полный универсальный порт `yabr` (который читает
  ЖР/настройки кластера/PFF — это всё не нужно gitsync).
- **Surgical Changes**: `v8storage` получает ОДИН новый метод, не
  рефакторинг существующих; `gitrunner`/`tempfiles`/`cli` не трогаются
  вообще; `sync.ps` меняется только там, где резолвится автор.

Нарушений нет.

## Project Structure

### Documentation (this feature)

```text
specs/007-gitsync-per-version-author/
├── plan.md              # этот файл
├── research.md          # Phase 0 — флаги /ConfigurationRepositoryReport, грамматика скобочного формата, MXL cell-addressing
├── data-model.md         # Phase 1 — Запись_Версии, структура нового метода v8storage
└── quickstart.md         # Phase 1 — ручная проверка через расширенный fake_1cv8.sh
```

Без `contracts/` — фича не меняет пользовательский CLI-интерфейс `gitsync`
(тот же `sync`/`init`/`set-version`, что в `specs/006-gitsync-port/contracts/
cli-surface.md`), меняет только внутреннее поведение авторства.

### Source Code (repository root)

```text
../panosiki/v8storage/
├── storage_manager.ps     # + новый метод отчёт_по_версиям(...)
└── test_storage_manager.ps # + тесты нового метода
../panosiki/v8storage/fake_1cv8.sh # расширяется под /ConfigurationRepositoryReport

../panosiki/скобки/          # НОВЫЙ пакет — парсер скобочного формата 1С (узкий срез yabr)
├── pan.toml
├── start.ps
├── скобки.ps               # рекурсивный парсер {...}
├── отчёт_версий.ps         # MXL-cell-addressing поверх скобки.ps → Автор/Дата/Комментарий по номеру версии
├── test_скобки.ps
├── test_отчёт_версий.ps
├── LICENSE                 # MIT (собственный код)
└── NOTICE.md               # атрибуция oscript-library/yabr, MPL-2.0

../panosiki/gitsync/
├── pan.toml                # + зависимость на скобки
├── sync.ps                 # резолвить_автора теперь ПОВЕРСИОННО, с fallback
└── test_sync.ps            # + тесты поверсионного авторства/fallback
```

**Structure Decision**: новый пакет `panosiki/скобки` (не встраивается в
`v8storage` напрямую) — потому что парсер скобочного формата — общего
назначения (используется и другими форматами 1С в оригинальном `yabr`, даже
если этот срез портирует только MXL-версии), логически отдельная
переиспользуемая библиотека, а не деталь реализации одного метода
`v8storage`. `v8storage` получает МЕТОД (генерация отчёта через
`ос.выполнить`), но ПАРСИНГ результата — отдельный пакет, который `gitsync`
импортирует напрямую (не через `v8storage`, чтобы не тянуть парсер как
транзитивную зависимость всем, кто использует `v8storage` без отчётов).

## Complexity Tracking

Нарушений конституции нет — секция не заполняется.
