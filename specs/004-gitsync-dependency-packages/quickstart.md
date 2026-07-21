# Quickstart: пакеты-заготовки для зависимостей gitsync

**Feature**: `004-gitsync-dependency-packages`

## US1 + git-инициализация (7 пакетов)

Повторить `contracts/package-skeleton.md` для каждого из:
`tempfiles`, `v8runner`, `gitrunner`, `v8storage`, `cli`, `cli-selector`,
`configor`.

```bash
cd /Users/gaidar/dev/panosiki
for pkg in tempfiles v8runner gitrunner v8storage cli cli-selector configor; do
  mkdir -p "$pkg" && cd "$pkg"
  git init -q
  /Users/gaidar/dev/panos/panos /Users/gaidar/dev/panosiki/pan/start.ps init
  git add .
  git commit -qm "Инициализация пакета-заготовки для переноса $pkg"
  git tag v0.1.0
  cd ..
done
```

Проверка (SC-001):

```bash
for pkg in tempfiles v8runner gitrunner v8storage cli cli-selector configor; do
  echo "=== $pkg ==="
  cat "$pkg/pan.toml"
  git -C "$pkg" tag
done
```

## US2 (`слог`)

```bash
cat > /Users/gaidar/dev/panos/std/слог.ps <<'EOF'
# см. contracts/слог-api.md за полной сигнатурой
EOF
```

Проверка (US2 AC1):

```bash
cat > /tmp/слог_test.ps <<'EOF'
импорт слог

функ старт() -> Пусто
	слог.инфо("привет")
конец
EOF
/Users/gaidar/dev/panos/panos /tmp/слог_test.ps
# ожидается: [ИНФО] привет
```

## US3 (карта соответствия)

Уже существует — таблица "Key Entities" в `spec.md`. Дополнительных
действий не требуется; проверка (SC-004) — открыть `spec.md`, найти строку
по любому из 15 оригинальных имён, убедиться что судьба/имя/алиас понятны
без обращения к `packagedef` gitsync.
