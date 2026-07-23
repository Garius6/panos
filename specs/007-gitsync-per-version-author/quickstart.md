# Quickstart: gitsync — поверсионное авторство

## Ручная проверка (fake_1cv8.sh, без реальной платформы 1С)

```sh
cd /tmp && rm -rf gitsync_author_check && mkdir gitsync_author_check && cd gitsync_author_check
mkdir work

export GITSYNC_TEST_MAX_VERSION=3
export GITSYNC_V8_PATH=/path/to/panosiki/gitsync/fake_1cv8.sh
# GITSYNC_TEST_VERSION_AUTHORS обязателен для ЭТОЙ проверки — без него
# fake_1cv8.sh отдаёт ПУСТОЙ отчёт по версиям (карта авторства пуста,
# fallback на единого автора для всех версий, как в 006).
export GITSYNC_TEST_VERSION_AUTHORS="1=Иванов;2=Петров;3=Иванов"

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

Прогнано вручную 2026-07-23 (T017) — вывод совпал с ожидаемым один-в-один.

## Проверка fallback (отчёт недоступен)

Продолжение предыдущего сеанса (`work` уже синхронизирован до версии 3) —
нужны НОВЫЕ версии, иначе `sync` увидит "нечего синхронизировать" и
fallback не проверится:

```sh
cd /tmp/gitsync_author_check
export GITSYNC_TEST_MAX_VERSION=5   # версии 4-5 теперь "доступны"
export GITSYNC_TEST_REPORT_FAIL=1   # fake_1cv8.sh: /ConfigurationRepositoryReport теперь падает
panos /path/to/panosiki/gitsync/start.ps sync /fake/storage work
cd work && git log --format='%an %ae' | head -2
# ожидается: 2 НОВЫХ коммита (версии 4-5), sync не падает, автор ОБОИХ —
# контекст.пользователь_хранилища ("Администратор" по умолчанию, без
# записи в AUTHORS — синтетический email, см. FR-005), не по-версионно
```

Прогнано вручную 2026-07-23 (T017) — 2 новых коммита, автор
"Администратор Администратор@gitsync.local" (единый, как ожидается).

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
