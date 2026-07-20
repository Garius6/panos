# Тулчейн и тестирование

## Что

Три независимые сборочные цели, все определены в `Justfile` (корень
репозитория):

- `just build` → `odin build . -out:panos` — нативный интерпретатор.
- `just build-lsp` → `odin build ./lsp -out:panos-lsp` — LSP-сервер,
  отдельный бинарник (см. [LSP-сервер](./lsp.md)).
- `just build-wasm` → `odin build wasm -target:js_wasm32 -o:size -out:demo/panos.wasm`
  — wasm-сборка для браузера/демо.
- `just build-all` — все три разом.
- `just build-lsp-debug` → `odin build ./lsp -out:panos-lsp -debug -o:none`
  — DWARF-символы без оптимизаций, для отладки через lldb-dap; НЕ заменяет
  `build-lsp` (релизная сборка не должна тащить `-debug`/`-o:none`).
- `just test` → `odin test ./core` — весь набор тестов.
- `just debug-file <path>` → запуск одного `.ps`-файла с vet/debug-флагами
  (`odin run . -debug -vet -strict-style -vet-tabs -warnings-as-errors`).

## Зачем

Три цели существуют раздельно, потому что у каждой свой рантайм-контекст:
нативный интерпретатор использует `os`/файловую систему напрямую,
LSP-сервер — отдельный процесс, общающийся по JSON-RPC через stdin/stdout,
wasm-сборка выполняется в браузере без файловой системы и без части
`core:os` (см. [platform-split](./platform-split.md)). Одна цель сборки
не может покрыть все три рантайма — `-target:js_wasm32` меняет доступный
набор пакетов стандартной библиотеки Odin.

`-o:size` в `build-wasm` — не эстетический выбор: дефолтный `-o:minimal`
даёт модуль, на котором падает JIT-компилятор Safari/WebKit (см.
`wasm/main.odin`).

## Почему так, а не иначе

Три отдельных бинарника вместо одного с флагами времени выполнения —
`core:os`/файловый ввод-вывод недоступны на `js_wasm32` НА ЭТАПЕ
КОМПИЛЯЦИИ (импорт `core:os` падает compile-time panic'ом под этой целью,
не runtime-ошибкой) — единый бинарник, определяющий рантайм по флагу,
физически не собрался бы под wasm, если бы использовал `core:os`
где-либо в общем коде.

## Конвенции тестирования

- `odin test ./core` — единственная команда для полного набора тестов
  (core-пакет).
- `run_code`/`run_code_with_args` (`core/e2e_test.odin`) — обёртка над
  `run_source_with_args` (`core/pipeline.odin`) для e2e-тестов: токенизация
  → парсинг → резолв → тайпчек → компиляция → выполнение на VM, всё в одном
  вызове, без файлового I/O.
- **Inline-pipeline** (`core/pipeline.odin`, `run_source_with_args`/
  `check_source`) — для программ БЕЗ реальных file-based `импорт`. Общий
  код для WASM-входа (`wasm/main.odin`) и тестовых обёрток `run_code`,
  поэтому живёт в `pipeline.odin`, а не в помеченном `#+build !js_wasm32`
  `e2e_test.odin` (`core:testing` не собирается под `js`).
- **Полный `Module_Graph`-пайплайн** (`core/module_loader.odin`,
  `load_module_graph_with_overrides`) — читает `std/*.ps` и другие модули с
  диска, резолвит граф импортов целиком. Используется LSP-сервером
  (`revalidate_document` в `lsp/lsp_server.odin`) и полноценным CLI-запуском
  файла, НЕ используется в изолированных unit-тестах core-пакета.
- **Известное следствие для тестов**: изолированный тестовый путь
  (`resolve_program`/`typecheck_program` напрямую на распарсенной
  `Program`, без `Module_Graph`) НЕ грузит файловые `std/*.ps`-модули с
  диска — `импорт математика` в таком тесте не резолвится (модуль не
  найден), а `импорт строки` резолвится (это core builtin-модуль,
  регистрируется без файлового I/O, см. [модульная система](./module-system.md)).
  Тесты, которым нужен реальный импорт stdlib-модуля, должны использовать
  builtin-модуль вроде `строки`, а не файловый `std/*.ps`-модуль (см.
  `core/semantic_tokens_test.odin` — конкретный пример этого затруднения и
  исправления).

## Ритуал редеплоя LSP-сервера

`panos-lsp`, собранный через `just build-lsp`, оказывается в корне
репозитория (`./panos-lsp`) — это единственный путь, который гарантированно
существует. Если ваш редактор запускает `panos-lsp` из ДРУГОГО места (PATH-
symlink, менеджер LSP-серверов вроде Mason в Neovim, бандл расширения
VS Code) — свежий бинарник нужно скопировать и туда тоже, иначе редактор
продолжит использовать старую версию. Конкретные пути зависят от вашей
локальной настройки редактора — команда `which panos-lsp`
(или `vim.fn.exepath('panos-lsp')` в Neovim) покажет, что реально
подхватывает ваш клиент.

## Точки входа для типичной правки

| Изменение | Файл/команда |
|---|---|
| Изменить флаги сборки нативного интерпретатора | `Justfile` → `build` |
| Изменить флаги сборки LSP | `Justfile` → `build-lsp`/`build-lsp-debug` |
| Изменить флаги wasm-сборки | `Justfile` → `build-wasm` |
| Обновить протокольный слой LSP из апстрима спеки | `Justfile` → `sync-lsp-protocol` (тянет `lsp/protocol/lsp_types.odin` из `Garius6/odin-lsp-protocol`) |
| Добавить e2e-тест | `core/e2e_test.odin`, обёртка `run_code`/`run_code_with_args` |
| Добавить тест, дергающий полный граф модулей | НЕ через `run_code` — нужен `core/module_loader.odin` напрямую или LSP-тестовый путь |
