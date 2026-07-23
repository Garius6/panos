# Quickstart: gitsync

**Feature**: `006-gitsync-port` | **Date**: 2026-07-23

## Ручная проверка (fake_1cv8.sh, без реальной платформы 1С)

```sh
cd /tmp && mkdir gitsync_check && cd gitsync_check
mkdir work

# fake_1cv8.sh симулирует хранилище с 3 версиями (см. research.md §7).
# GITSYNC_V8_PATH обязателен — без него start.ps попробует запустить
# настоящий "1cv8" (значение по умолчанию), которого в песочнице нет.
export GITSYNC_TEST_MAX_VERSION=3
export GITSYNC_V8_PATH=/path/to/panosiki/gitsync/fake_1cv8.sh

panos /path/to/panosiki/gitsync/start.ps init /fake/storage work
cat work/VERSION        # ожидается: 0
cat work/AUTHORS        # ожидается: пустой TOML-шаблон с комментарием

panos /path/to/panosiki/gitsync/start.ps sync /fake/storage work
cat work/VERSION        # ожидается: 3
cd work && git log --oneline    # ожидается: 3 коммита

# повторный sync без новых версий — без изменений
cd /tmp/gitsync_check
panos /path/to/panosiki/gitsync/start.ps sync /fake/storage work
cd work && git log --oneline    # ожидается: всё ещё 3 коммита

# set-version откатывает на произвольный номер
panos /path/to/panosiki/gitsync/start.ps set-version 1 work
cat work/VERSION        # ожидается: 1
```

Прогнано вручную 2026-07-23 (T032) — все шаги совпали с ожидаемым выводом.

## Новые e2e-тесты

`panosiki/gitsync/test_sync.ps` (`std/тест.ps`) поднимает: bare git remote
(опционально), рабочий git-репозиторий (`gitrunner`, реальный git — тот же
приём, что `test_gitrunner.ps`), `fake_1cv8.sh` вместо `1cv8`. Проверяет:

- `sync` на пустом VERSION синхронизирует версии 1..N одним вызовом
  (Acceptance Scenario 1, User Story 1).
- Повторный `sync` без новых версий не создаёт коммитов (Acceptance
  Scenario 3).
- `sync`, прерванный на середине (fake-бинарь настроен упасть на версии
  K), не продвигает VERSION дальше K-1 (Edge Case/SC-003).
- Автор коммита берётся из `AUTHORS`, а при отсутствии записи —
  используется имя пользователя хранилища без email (Acceptance
  Scenario 4).
- `init` идемпотентен — не перезаписывает существующие VERSION/AUTHORS
  (Acceptance Scenario 2, User Story 2).
- `set-version` перезаписывает VERSION, отклоняет нечисловой/
  отрицательный аргумент (User Story 3).

Прогоняется как обычный `.ps`-тест через собранный `panos`, отдельной
команды не требуется — часть регрессии самого пакета `panosiki/gitsync`
(этот пакет не входит в `core`-тестовый набор panos, у него собственный
тестовый прогон, как у остальных 7 зависимостей).
