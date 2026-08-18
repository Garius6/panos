# Implementation Plan: Явный generic-argument синтаксис

**Branch**: `013-explicit-generic-args` | **Date**: 2026-08-18 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `specs/013-explicit-generic-args/spec.md`

## Summary

Позволить вызывающему явно указать generic-аргументы функции
(`ф[Тип](...)`, несколько — `ф[(Тип1, Тип2)](...)`) без изменения
грамматики: синтаксис уже парсится сегодня как `Call_Expr{ callee:
Index_Expr }` (индекс-потом-вызов). Тайпчекер, обнаружив, что объект
индексации — generic-функция (не indexable-значение), реинтерпретирует
уже построенное `Index_Expr`-поддерево в список type-аргументов через
новую функцию `resolveTypeFromExpr` (Expr → TypeId, параллель
существующему `resolveType`, TypeNode → TypeId), засеивает ими карту
substitutions ДО обычного вывода из аргументов — конфликт
explicit-vs-inferred и bounds-проверка достаются бесплатно от уже
существующего кода (`inferGenericSubstitution`/bounds-цикл). Когда
объект индексации НЕ generic-функция, поведение не меняется ни байтом.

## Technical Context

**Language/Version**: Zig 0.16.0; Panos source language (typechecker-only
изменение, парсер не трогается)
**Primary Dependencies**: `zig/core/type_checker.zig` (основная логика —
детект/`resolveTypeFromExpr`/substitutions-seeding); `zig/core/compiler.zig`
и `zig/core/resolver.zig` — оба потребовали реальных точечных правок,
найденных ТОЛЬКО сквозным прогоном скомпилированного бинарника (не
предполагалось на этапе планирования — см. tasks.md's "Реальные
пробелы, найденные ТОЛЬКО сквозным прогоном"): резолвер и байткод-
компилятор оба независимо обходят тот же raw AST ДО/ПОСЛЕ typecheck'а
и нуждались в СИММЕТРИЧНОМ детекте explicit-generic-вызова, иначе
резолвер падал на примитивных type-именах без value-символа, а
компилятор пытался буквально скомпилировать имя типа как runtime-индекс
**Storage**: N/A
**Testing**: `zig build test` (focused `type_checker.zig` regressions),
`zig build conformance`, `zig build aot` (подтвердить, что MIR/AOT
codegen не видит разницы — substitutions уже разрешены к моменту
кодогенерации, как и для обычного inferred-вызова)
**Target Platform**: язык/компилятор — не платформенно-специфично,
работает одинаково на native и WASM AOT (typecheck-фаза общая)
**Project Type**: interpreter/compiler
**Performance Goals**: без измеримой деградации — новая ветка
затрагивает только вызовы, чей callee синтаксически `Index_Expr`
(редкая форма в реальном коде сегодня), и делает НЕ БОЛЬШЕ работы, чем
существующий inferred-путь при совпадении
**Constraints**: FR-006 — нулевая регрессия для `ф[X](...)`, где `ф` —
НЕ generic-функция (обычная индексация массива/соответствия с
последующим вызовом результата); permissive fallback (unconstrained
без явного аргумента) не меняется (FR-008); никаких изменений в
`Index_Expr`'s AST-форме (`index: ExprId`, arity не растёт)
**Scale/Scope**: `type_checker.zig` — новая функция `resolveTypeFromExpr`,
новая ветка в `inferCallExpected`'s callee-switch, рефакторинг
`.function`-ветки в переиспользуемый helper с параметром
pre-seeded-substitutions; метод-вызовы (`это.метод[Тип](...)`) — Phase 2,
не в этом plan'е

## Constitution Check

| Principle | Result | Evidence |
|---|---|---|
| Think Before Coding | Pass | Реальный грамматический конфликт найден и разрешён ДО написания кода (research.md); синтаксис явно подтверждён пользователем после объяснения альтернатив (turbofish/новый токен) и обоснования выбора. |
| Simplicity First | Pass | Ноль изменений грамматики/AST-форм; multi-arg через уже существующий `Expr.tuple`, не новую arity; explicit-vs-inferred конфликт переиспользует существующую проверку в `inferGenericSubstitution`, не дублирует её. |
| Surgical Changes | Pass | Три файла (`type_checker.zig`/`compiler.zig`/`resolver.zig`), каждая правка — точечная (одна новая ветка/helper на файл, не рефакторинг); mir_lowering/AOT не тронуты вообще (substitutions уже разрешены к моменту MIR-лоуэринга); все три правки МЕНЬШЕ отклонённой альтернативы с изменением `Index_Expr`-arity, которая задела бы 5+ файлов ради arity, не нужной по существу. |

## Project Structure

### Documentation (this feature)

```text
specs/013-explicit-generic-args/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
└── contracts/
    └── explicit-generic-call-resolution.md
```

### Source Code (repository root)

```text
zig/core/
└── type_checker.zig
    ├── resolveTypeFromExpr(self, expr: ast.ExprId) !?types.TypeId   # новая
    ├── inferCallExpected's callee-switch (~line 4402)                # новая .index-ветка
    └── .function-ветка (~line 4517-4700)                             # выделена в helper
                                                                       # с параметром explicit substitutions

zig/core/e2e_types_interfaces_test.odin  # НЕТ — Odin-эра, не существует;
                                          # реальные regression-тесты живут
                                          # прямо в type_checker.zig (test-блоки)
                                          # и/или zig/core/runner.zig (e2e)
```

**Structure Decision**: Точечное расширение существующего
typechecker-пайплайна; ни одного нового файла/модуля/поддиректории.

## Complexity Tracking

*Нет нарушений Constitution Check — секция не заполняется.*

## Implementation Outline

1. **`resolveTypeFromExpr`** — новая функция в `Checker`
   (`type_checker.zig`), параллель `resolveType` (4824), переключается
   по `self.tree.expr(expr).*`:
   - `.ident{name}` → `findGenericParameter(name) orelse
     builtinType(...) orelse` (через `findTypeSymbol` + `nominalType`),
     та же логика, что `resolveType`'s `.ident`-ветка (без
     `alias_type_nodes`/`current_nominal_owner`-веток, если они
     недостижимы из call-site позиции — проверить при реализации,
     не предполагать).
   - `.property{object, property}` → ТОЛЬКО если `object` сам `.ident`
     (иначе `null` — не типовидно); `findQualifiedTypeSymbol(module,
     property)`.
   - `.call{callee, arguments}` → резолвить `callee` рекурсивно как имя
     типа (той же веткой выше), каждый `arguments[i]` — рекурсивно
     через `resolveTypeFromExpr` (вложенные generic-инстанциации);
     `nominalType(symbol, resolved_arguments)`.
   - Всё остальное → `null` (FR-007 — не типовидно, не диагностика "не
     найден").
   - Открытый вопрос из research.md — где именно диагностировать
     "похоже на тип, но символ не найден" против "форма вообще не
     типовидна" — решить перед/во время реализации, не откладывать
     молча.

2. **Извлечение explicit-аргументов** из `Index_Expr`: если
   `self.tree.expr(index.index).*` — `.tuple`, использовать
   `.elements` (несколько type-аргументов); иначе — один элемент
   `[index.index]`. Каждый прогнать через `resolveTypeFromExpr`.

3. **Детект "это explicit-generic вызов"**: в `inferCallExpected`'s
   callee-switch (4402), новая ветка `.index => |index| { ... }`
   ПЕРЕД текущим `else => {}`. Если
   `self.resolution.expr_symbols.get(index.object)` резолвится в
   символ с непустым `generic_function_parameters.get(symbol)` —
   явный вызов; иначе — `continue`/fallthrough к существующему общему
   пути без изменений (FR-006).

4. **Построение предзасеянной substitutions-карты**: длина
   explicit-аргументов MUST совпасть с
   `generic_parameters.len` (иначе FR-003 diagnostic, не пытаться
   частично сопоставить); иначе — `substitutions.put(parameter.typ,
   resolved)` для каждой пары по объявленному порядку (FR-002).

5. **Рефакторинг `.function`-ветки** (~4517-4700) в helper, принимающий
   callee-выражение (сегодня жёстко `call.callee`, нужно параметризовать
   на `index.object` для explicit-пути) и НЕ ПУСТУЮ, а
   предзасеянную substitutions-карту вместо `std.AutoHashMap(...).init(...)`
   с нуля. Существующий цикл вывода из аргументов
   (`inferGenericSubstitution`) и bounds-проверка остаются без
   изменений — конфликт (FR-004) и bounds (FR-005) ловятся тем же
   кодом, что уже есть.

6. Тесты (в `type_checker.zig`, тот же файл, что вся остальная logic
   этой фичи):
   - US1: `функ ф[T](x: Строка) -> Тип(T)` вызван `ф[Число]("42")` без
     типизированной привязки — не даёт "не удалось вывести
     type-параметр", результат типа `Тип(Число)`.
   - US1 negative control: та же функция БЕЗ explicit-аргумента и без
     контекста — поведение не изменилось (unconstrained, не ошибка).
   - US2: `функ ф[T](x: T) -> T` вызвана `ф[Число]("текст")` — Type
     Error (конфликт).
   - US3: `ф[1 + 2](...)` на реально generic `ф` — понятная
     диагностика, не "как проиндексировать функцию".
   - FR-006 regression: массив функций `массив_функций[0](args)` — ноль
     изменений поведения (существующий тест, если есть; если нет —
     добавить, раз в scope этой проверки).
   - Множественный явный аргумент: `функ ф[T, U](...)` вызвана
     `ф[(Число, Строка)](...)`.
   - Квалифицированный вызов: `модуль.ф[Тип](...)`.

7. Регрессия: `zig build test`/`conformance`/`aot`/`lsp`/`browser` —
   все обязаны остаться зелёными; особое внимание AOT (mir_lowering
   читает уже РАЗРЕШЁННЫЕ types из `checked.expression_types`/
   `symbol_types`, не видит разницы между inferred и explicit
   substitutions — подтвердить это допущение реальным AOT-тестом с
   explicit generic-вызовом, не просто предполагать).

## Deferred (за рамками этого plan'а, см. spec.md Assumptions/Edge Cases)

- Явный generic-argument синтаксис на МЕТОДАХ (`это.метод[Тип](...)`)
  — отдельная точка интеграции внутри `inferMethodCall`, Phase 2.
- Явный аргумент на generic-bound interface-вызовах
  (`inferInterfaceCall`/`inferGenericBoundInterfaceCall`) — не
  затронуто исследованием, не предполагать поведение без отдельного
  прохода.
- Enum/struct-конструкторы — вне scope по определению (уже типизируются
  на уровне `Тип(Аргумент)`, не вызова).
