# Quickstart: Validate Hardening Phase A

## Focused development loop

Итерировать по каждой User Story независимо (нет общих файлов между
US1/US2 и US3/US4):

```sh
zig test zig/core/diagnostic.zig     # US1
zig test zig/embed.zig               # US1 (helper) + US2 (error-path тесты)
zig test zig/core/mir_lowering.zig   # US3
zig test zig/core/runner.zig         # US4 (expressionDoc)
zig test zig/lsp/main.zig            # US4 (hover)
```

## Проверить каждый пункт вручную

### US1 — диагностики в `panos_embed`

1. Через `Runtime` загрузить скрипт с намеренной type-ошибкой.
2. Вызвать `Runtime.formatDiagnostics(writer, runtime.compilationDiagnostics().?)`.
3. Убедиться, что вывод — строка вида `путь:строка:колонка: сообщение`,
   идентичная по формату тому, что печатает `panos build --compile` на
   том же скрипте.
4. `zig build test` — CLI-тесты на формат диагностик (`cli/main.zig`
   строки ~689-740) не изменили ожидаемый вывод.

### US2 — error-path тесты

```sh
zig test zig/embed.zig
```

Три новых `test` блока должны быть зелёными: сломанный скрипт не
бросает Zig-error, `call()` после `.runtime_error` ведёт себя как
зафиксировано в `data-model.md`, вызов несуществующего экспорта
возвращает `error.ExportNotFound`.

### US3 — nested generic capture

1. Написать/скомпилировать фикстуру с closure, захватывающей
   двухуровневую generic-вложенность (`Коробка(Коробка(T))`-подобная
   форма) с конкретным `T`.
2. `zig build aot` — фикстура компилируется без диагностики об
   отклонении.
3. Прогнать полученный WASM (wasmtime или существующий AOT-раннер
   проекта) — результат совпадает с native-запуском того же кода.
4. Негативный случай: тот же паттерн, но `T` не выводим статически —
   компиляция даёт понятную диагностику, не крашится, не производит
   некорректный код.
5. Существующий одноуровневый generic-capture regression-тест —
   по-прежнему зелёный.

### US4 — doc-comment hover

1. Собрать LSP: `zig build lsp`.
2. Отправить `textDocument/hover` (как в существующем тесте
   `zig/lsp/main.zig:1713`) на использование функции, перед которой
   написан `///`-doc-комментарий.
3. Убедиться, что `result.contents.value` содержит текст комментария
   вместе с именем типа.
4. Тот же запрос на декларацию без doc-комментария — `contents.value`
   содержит только тип, как до изменения.

## Required regression checks

```sh
zig build test
zig build aot
zig build lsp
zig build browser
```

`zig build conformance`/`integration`/`bench`/`fuzz` — вне scope этой
спецификации (Phase B исходного hardening-плана), не запускать как
часть этой работы.
