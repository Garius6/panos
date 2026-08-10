# panos

Экспериментальный скриптовый язык программирования с русскими ключевыми
словами и синтаксисом, близким к Go и Rust. Статическая типизация,
структуры и интерфейсы, перечисления (ADT) с pattern matching, дженерики,
замыкания, простой mark-and-sweep сборщик мусора, cooperative-scheduled
акторная модель (процессы, mailbox, наблюдение/линки, select).

```panos
тип Фигура = перечисление
    Точка
    Круг(Число)
    Прямоугольник(Число, Число)
конец

функ площадь(ф: Фигура) -> Число
    возврат выбор ф
        Точка -> 0
        Круг(р) -> р * р * 314 / 100
        Прямоугольник(ш, в) -> ш * в
    конец
конец

функ старт() -> Число
    площадь(Фигура.Прямоугольник(3, 4))
конец
```

Компилятор целиком: лексер → парсер → resolver → type checker → компилятор
в байткод → VM, плюс LSP-сервер (`panos-lsp`) с диагностикой, hover,
автокомплитом и rename/references на весь граф импортов, и WASM-сборка для
браузера.

Полная документация: <https://garius6.github.io/panos/> ·
живая песочница: <https://garius6.github.io/panos/playground/>.

## Установка

Готовые бинарники (`panos` CLI + `panos-lsp`) под Linux/macOS/Windows — на
странице [релизов](https://github.com/Garius6/panos/releases/latest).

Сборка из исходников (нужен [Zig](https://ziglang.org/download/) `0.16.0`):

```sh
git clone --recurse-submodules https://github.com/Garius6/panos.git
cd panos
zig build              # CLI-интерпретатор → zig-out/bin/panos
zig build lsp           # LSP-сервер
zig build browser       # WASM-сборка для браузера
```

Стандартная библиотека (`std/`) живёт в отдельном репозитории
([panos-std](https://github.com/Garius6/panos-std)), подключённом как git
submodule — `--recurse-submodules` обязателен, иначе `std/` останется
пустой директорией и `zig build test`/`conformance` не найдут стандартные
модули. Уже склонировали без него? `git submodule update --init`.

Или через `just` (обёртки над теми же командами, см. `Justfile`):
`just build` / `just build-lsp` / `just build-wasm` / `just build-all`.

## Быстрый старт

```sh
echo 'функ старт() -> Число
    10 + 20
конец' > hello.ps
./panos hello.ps
```

Подробнее — [Установка](https://garius6.github.io/panos/getting-started/installation.html)
и [Быстрый старт](https://garius6.github.io/panos/getting-started/quickstart.html)
в документации.

## Тесты

```sh
zig build test          # быстрые unit-тесты (per-file)
zig build conformance    # conformance-матрица
```

Полный список тестовых шагов (`integration`/`aot`/`bench`/`fuzz`) — в
`AGENTS.md`.

## Структура репозитория

```text
zig/core/   # лексер, парсер, resolver, type checker, компилятор, VM, LSP core
zig/cli/    # нативная точка входа CLI
zig/lsp/    # точка входа LSP-сервера
zig/browser/# точка входа WASM-интерпретатора для браузера
std/        # стандартная библиотека panos (.ps)
tests/      # conformance-корпус, интеграционные фикстуры, LSP/WASM тесты
fixtures/   # тестовые фикстуры
docs/       # исходники документации (mdBook)
specs/      # speckit-спецификации фич
```

## Статус

Активно развивается, поведение языка может меняться. Смотрите
[ROADMAP.md](./ROADMAP.md) за списком нереализованных пока направлений и
`AGENTS.md`/`CLAUDE.md` за деталями пайплайна и конвенций для контрибьюторов.
