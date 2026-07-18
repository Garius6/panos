# libffi (vendored, prebuilt)

Стадия 8 (FFI фаза B, `внешний`-декларации) нуждается в libffi для вызова
функций с сигнатурой, известной только в рантайме (`ffi_prep_cif`/
`ffi_call`) — Odin, как и большинство статически скомпилированных языков,
не умеет вызвать `rawptr` как функцию с произвольной, заранее неизвестной
сигнатурой без этой низкоуровневой помощи.

По решению проекта (2026-07-18): panos должен быть полностью
самостоятельным — никаких системных зависимостей помимо самого
Odin-тулчейна. Значит НЕ `foreign import "system:ffi"` (требовал бы
`libffi-dev`/аналог на машине каждого, кто собирает panos), а
статическая линковка ПРЕКОМПИЛИРОВАННОГО архива, закоммиченного в
репозиторий — тот же принцип, что уже применяется к `external/back`/
`external/odin-http`/`external/toml_parser`, но с ОДНИМ существенным
отличием: те три — чистый Odin (или тонкие биндинги над уже системными
библиотеками), НИ ОДИН не требует C-компиляции. libffi — настоящая
C-библиотека с архитектуро-специфичным ассемблером (per-CPU trampolines)
— компилируется `./configure && make` (autotools), результат (`libffi.a`
+ сгенерированные заголовки, `ffi.h` СОДЕРЖИТ платформенные макросы,
НЕ переносим между архитектурами без пересборки) коммитится готовым,
не собирается заново при каждой сборке panos.

## Layout

```
external/libffi/
  LICENSE                          — оригинальная лицензия libffi (MIT-style)
  include/<platform>-ffi.h         — сгенерированный заголовок (референс, Odin-код НЕ парсит .h напрямую — свои биндинги в core/)
  include/<platform>-ffitarget.h   — тот же принцип
  lib/<platform>/libffi.a          — статический архив для линковки
```

`<platform>` — Odin-стиль `<os>-<arch>` (`darwin-arm64`, `darwin-amd64`,
`linux-amd64`, `linux-arm64`, ...). **Сейчас собрана и закоммичена
ТОЛЬКО `darwin-arm64`** (машина разработки) — остальные платформы не
покрыты, это честный, задокументированный пробел, не молчаливое
допущение "и так заработает".

## Пересборка / добавление новой платформы

Источник: [официальный релиз libffi](https://github.com/libffi/libffi/releases)
(релизный tarball, НЕ git-клон исходного репозитория — релиз уже
содержит сгенерированный `configure`, `git clone` потребовал бы
autoconf/automake для его генерации, которых у нас в build-пайплайне
принципиально нет и не будет).

```bash
curl -sL -o libffi.tar.gz https://github.com/libffi/libffi/releases/download/v3.7.1/libffi-3.7.1.tar.gz
tar xzf libffi.tar.gz
cd libffi-3.7.1
./configure --disable-shared --enable-static --disable-docs
make -j4
# результат: <triplet>/.libs/libffi.a, <triplet>/include/{ffi.h,ffitarget.h}
```

Скопировать `.libs/libffi.a` → `external/libffi/lib/<platform>/libffi.a`,
`include/{ffi.h,ffitarget.h}` → `external/libffi/include/<platform>-*.h`
(референс, при необходимости свериться с Odin-биндингами в
`core/ffi_bindings.odin`).

**Кросс-компиляция сейчас НЕ автоматизирована** — каждая платформа
собирается на своей же архитектуре (нет Docker/cross-toolchain в
пайплайне; добавление — отдельная задача, не блокирует MVP на
единственной платформе разработки).

Версия: **libffi 3.7.1** (текущий stable release на момент вендоринга,
2026-07-18).
