# Quickstart: gitsync — авто push/pull

## Ручная проверка (реальный git, локальный bare-репозиторий как "remote")

```sh
cd /tmp && rm -rf gitsync_remote_check && mkdir gitsync_remote_check && cd gitsync_remote_check
git init --bare remote.git

git clone remote.git clone-a
git clone remote.git clone-b

export GITSYNC_TEST_MAX_VERSION=1
export GITSYNC_V8_PATH=/path/to/panosiki/gitsync/fake_1cv8.sh

# clone-a синхронизирует версию 1, пушит
panos /path/to/panosiki/gitsync/start.ps init /fake/storage clone-a
panos /path/to/panosiki/gitsync/start.ps sync /fake/storage clone-a --remote origin
cd clone-a && git log --oneline && cd ..
# ожидается: 1 коммит, отправлен в remote.git (виден в clone-b после pull)

# clone-b подтягивает коммит clone-a через pull ПЕРЕД собственным sync
cd clone-b && git log --oneline && cd ..
# ожидается: пусто (ещё не пуллил)

panos /path/to/panosiki/gitsync/start.ps init /fake/storage clone-b
export GITSYNC_TEST_MAX_VERSION=2
panos /path/to/panosiki/gitsync/start.ps sync /fake/storage clone-b --remote origin
cd clone-b && git log --oneline && cd ..
# ожидается: 2 коммита — версия 1 (из clone-a, через pull) + версия 2 (свежая)
```

## Проверка расхождения (не fast-forward)

```sh
cd /tmp/gitsync_remote_check
# clone-a коммитит ЕЩЁ один коммит, НЕ пушит
cd clone-a && git commit --allow-empty -m "локальный коммит без push" && cd ..
# clone-b уже спушил версию 2 (с предыдущего шага) — теперь у clone-a
# и remote.git РАЗНЫЕ истории (расхождение)
panos /path/to/panosiki/gitsync/start.ps sync /fake/storage clone-a --remote origin
# ожидается: sync падает с ошибкой ДО начала цикла версий хранилища,
# VERSION в clone-a НЕ меняется, ноль новых коммитов версий хранилища
```

## Новые/изменённые e2e-тесты

- `panosiki/gitsync/test_sync.ps` — новые тесты через два реальных
  локальных клона + bare-репозиторий (без `--remote` — поведение не
  меняется, `--remote` — pull fast-forward работает, расхождение
  останавливает `sync` без прогресса, push вызывается только при
  реально новых коммитах, ошибка push не откатывает уже сделанную
  локальную синхронизацию).
