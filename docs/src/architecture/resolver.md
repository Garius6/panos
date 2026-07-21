# Резолвер

## Что

Резолвер (`core/resolver.odin`) связывает идентификаторы в AST с
конкретными объявлениями (переменная/функция/тип/модуль). Главная точка
входа — `resolve_program :: proc(ctx: ^Resolver_Ctx, prog: Program)`
(`resolver.odin:913`).

Центральные структуры:

- **`Symbol`** (`resolver.odin:18`) — семантическая сущность: `name`/
  `full_name` (`Interned`, не `string` — см. `core/interner.odin`), `kind`
  (`Symbol_Kind`), `module` (`^Module`), `is_exported`, `decl` (`Decls` —
  какая AST-декларация породила символ), `owner_type` (`Symbol_Id` — для
  методов/полей), `is_const`, `span` (для go-to-definition в LSP).
- **`Symbol_Kind`** (`resolver.odin:8`) — `Variable`, `Function`, `Type`,
  `Module`, `Builtin`, `Enum_Variant`.
- **`Symbol_Id`** (`resolver.odin:40`) — `distinct u32`, индекс в
  `Symbol_Store.symbols` ([dynamic]Symbol), а не указатель — стабильный
  хэндл для cross-reference таблиц (LSP find-references/rename).
- **`Symbol_Store`** (`resolver.odin:45`) — `{symbols: [dynamic]Symbol}`,
  индекс 0 зарезервирован под `INVALID_SYMBOL` (sentinel).
- **`Module_Graph`** (`resolver.odin:88`) — `modules: map[string]^Module`,
  `order` (порядок загрузки), `symbol_types`, **`symbol_store: ^Symbol_Store`
  — ОДИН общий Symbol_Store на ВЕСЬ граф импортов**, не по одному на модуль.
- **`Resolver_Ctx`** (`resolver.odin:416`) — рабочий контекст одного прохода
  резолва: `current_scope`/`global_scope` (`^Scope`), `current_module`,
  `module_graph`, `symbol_store`, `symbol_types: map[Symbol_Id]^Type`,
  плюс side-table'ы: `decl_symbols: map[Decls]Symbol_Id`,
  `stmt_symbols: map[Stmt]Symbol_Id`, **`node_symbols: map[Expr]Symbol_Id`**
  (какой символ резолвится для конкретного Expr-узла — используется LSP:
  hover/definition/rename/semantic tokens), `func_args: map[Decls][dynamic]Symbol_Id`
  (список Symbol_Id параметров функции — единственный способ отличить
  параметр от обычной локальной `пер`-переменной, обе имеют
  `Symbol_Kind.Variable`), `lambda_args`, `lambda_captures` (упорядоченный
  список захваченных из внешнего scope символов для замыканий — порядок
  здесь должен совпадать с порядком, в котором `compiler.odin` кладёт
  значения на стек при `.Build_Closure`).
- **`Scope`** (`resolver.odin:211`) — `{parent: ^Scope, symbols: map[Interned]Symbol_Id}`,
  односвязный список scope'ов вверх до `global_scope`.

## Зачем

Резолвер существует отдельно от тайпчекера, потому что связывание имён
(«какой именно символ имеет в виду этот идентификатор») и вывод/проверка
типов («какого типа этот символ») — разные задачи с разными зависимостями:
резолв не требует знания типов (может определить, что `x` — это ТА САМАЯ
переменная из внешнего scope, не глядя на её тип), а тайпчекеру для вывода
типа выражения уже НУЖЕН резолвленный символ (чтобы найти его объявленный/
выведенный тип). Разделение также даёт LSP дешёвый путь: hover и
go-to-definition используют ТОЛЬКО `node_symbols`/`Symbol_Store`, не требуя
повторного вывода типов там, где тип не нужен.

## Почему так, а не иначе

**`Symbol_Store` — общий указатель на весь `Module_Graph`, а не по одному на
модуль** (`graph.symbol_store`, `resolver.odin:93`): экспортированный символ
одного модуля должен быть узнаваем (тем же `Symbol_Id`) при обращении из
ДРУГОГО модуля, импортирующего его. Если бы у каждого модуля был свой
`Symbol_Store`, `Symbol_Id` из модуля A ничего не значил бы в контексте
модуля B — пришлось бы городить перевод идентификаторов между графами.
Именно поэтому в LSP, где КАЖДЫЙ открытый документ строит СВОЙ ОТДЕЛЬНЫЙ
`Module_Graph` (`load_module_graph_with_overrides` на документ, не на
проект), `Symbol_Id` из графа одного документа НЕ сравним с `Symbol_Id` из
графа другого документа напрямую — сравнивать приходится по (путь файла,
byte-span объявления), см. [LSP-сервер](./lsp.md).

**`module := new(Module)` в `resolve_program`, а НЕ стековый композитный
литерал** (`resolver.odin:914`, комментарий на месте) — каждый созданный
здесь `Symbol` хранит `Symbol.module` (`^Module`) и переживает саму
`resolve_program` (читается вплоть до `compile_program`/
`monomorphize_program`, см. `core/monomorphize.odin`). Стековая версия
(была раньше) давала dangling pointer, как только `resolve_program`
возвращалась — молча не всплывало годами, пока bounded traits'
`monomorphize_one` не стал первым кодом, читающим `Symbol.module` так
поздно (на этапе компиляции, стек уже многократно переиспользован). Тот же
класс бага, что stack-escape в `parse_for_range_stmt_into` (парсер, Стадия
32, для `Целое`-индексов) — см. [известные грабли](./known-pitfalls.md).

**`func_args: map[Decls][dynamic]Symbol_Id`** существует отдельно, потому
что и параметр функции, и обычная локальная переменная — оба
`Symbol_Kind.Variable`; enum одного варианта на оба случая не различает их,
а LSP-фичам (semantic tokens: `parameter` vs `variable` — см.
[семантические токены](./lsp.md)) различие нужно.

## Точки входа для типичной правки

| Изменение | Файл/функция |
|---|---|
| Новая diagnostic-проверка при резолве (например запрет использования зарезервированного имени) | `report_resolve` (`resolver.odin:489`) — репортит `Diagnostic` в `ctx.diagnostics`, не паникует (accumulate-not-panic, тот же паттерн, что в парсере/тайпчекере) |
| Новый вид объявления, которое резолвер должен видеть на верхнем уровне модуля | `resolve_program`/место обхода `prog.decls` — нужно добавить ветку `#partial switch` |
| Изменить, как резолвится путь импорта | `resolve_import_path` (`resolver.odin:309`) — конкатенация `importer_dir`+`import_spec`, добавление `.ps`-суффикса, нормализация пути |
| Изменить, что попадает в `node_symbols` (для LSP-фич вроде semantic tokens/rename) | места вызова `ctx.node_symbols[expr] = sym_id` внутри резолва `Ident_Expr`/`Property_Expr` |
