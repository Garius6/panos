# Quickstart: gitsync — поверсионное авторство

## Ручная проверка (fake_1cv8.sh, без реальной платформы 1С)

```sh
cd /tmp && rm -rf gitsync_author_check && mkdir gitsync_author_check && cd gitsync_author_check
mkdir work

export GITSYNC_TEST_MAX_VERSION=3
export GITSYNC_V8_PATH=/path/to/panosiki/gitsync/fake_1cv8.sh
# fake_1cv8.sh теперь при /ConfigurationRepositoryReport пишет синтетический
# MXL (скобочный формат) с версиями 1-3, назначенными пользователям
# Иванов/Петров/Иванов (см. research.md §7)

panos /path/to/panosiki/gitsync/start.ps init /fake/storage work
cat > work/AUTHORS <<'EOF'
[Иванов]
имя = "Иван Иванов"
email = "ivanov@example.com"

[Петров]
имя = "Пётр Петров"
email = "petrov@example.com"
EOF

panos /path/to/panosiki/gitsync/start.ps sync /fake/storage work
cd work && git log --format='%an %ae'
# ожидается:
#   Иван Иванов ivanov@example.com     (версия 3)
#   Пётр Петров petrov@example.com     (версия 2)
#   Иван Иванов ivanov@example.com     (версия 1)
```

## Проверка fallback (отчёт недоступен)

```sh
cd /tmp/gitsync_author_check
export GITSYNC_TEST_REPORT_FAIL=1   # fake_1cv8.sh: /ConfigurationRepositoryReport теперь падает
panos /path/to/panosiki/gitsync/start.ps sync /fake/storage work
# ожидается: sync не падает, коммит(ы) создаются с единым автором
# контекст.пользователь_хранилища (как в 006), сообщение о недоступности
# поверсионного отчёта — в выводе
```

## Новые/изменённые e2e-тесты

- `panosiki/скобки/test_скобки.ps` — рекурсивный разбор `{...}`, кавычки/
  экранирование, многострочные значения.
- `panosiki/скобки/test_отчёт_версий.ps` — извлечение `ЗаписьВерсии` из
  разобранного дерева (синтетический fixture, см. research.md §7).
- `panosiki/v8storage/test_storage_manager.ps` — новый метод `отчёт_по_
  версиям` строит правильную командную строку (тот же паттерн, что
  остальные тесты пакета через `fake_1cv8.sh`).
- `panosiki/gitsync/test_sync.ps` — новые тесты: разные авторы разных
  версий (Acceptance Scenario 1), пользователь без записи в AUTHORS
  (Scenario 2), fallback при недоступном отчёте (Scenario 3).
