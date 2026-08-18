# Quickstart: Validate Explicit Generic Arguments

## Focused development loop

```sh
zig test zig/core/type_checker.zig
```

Итерировать здесь — единственный реально меняющийся файл. Проверять
сценарии из plan.md's Implementation Outline п.6 по мере реализации
каждого шага (resolveTypeFromExpr → detect-ветка → substitutions →
рефакторинг `.function`-ветки).

## Обязательные сценарии перед тем как считать фичу готовой

1. **Explicit разрешает недовыводимый `T`**:
   ```panos
   функ ф[T](x: Строка) -> Тип(T)
       ...
   конец
   ф[Число]("42")   // без явного типа сегодня — unconstrained/ошибка
   ```
2. **Explicit конфликтует с аргументом — Type Error**:
   ```panos
   функ ф[T](x: T) -> T
       x
   конец
   ф[Число]("текст")   // Строка вместо Число — конфликт
   ```
3. **Нетиповидная форма на реально generic `ф`**:
   ```panos
   ф[1 + 2]("x")   // ф — generic, но [1+2] не тип — понятная диагностика
   ```
4. **Ноль регрессии для обычной индексации**:
   ```panos
   пер функции: Массив(функ(Число) -> Число) = массив(удвоить, утроить)
   функции[0](21.0)   // ф НЕ generic — индекс, потом вызов, как сегодня
   ```
5. **Несколько type-параметров**:
   ```panos
   функ пара[T, U](a: T, b: U) -> ...
   пара[(Число, Строка)](1.0, "x")
   ```
6. **Квалифицированный вызов**:
   ```panos
   модуль.ф[Тип](аргумент)
   ```

## Required regression checks

```sh
zig build test
zig build conformance
zig build aot
zig build lsp
zig build browser
```

`aot` особенно важен — подтвердить, что MIR-лоуэринг explicit-generic
вызова неотличим от inferred (читает уже разрешённые
`expression_types`/`symbol_types`, не сам факт explicit/inferred).
