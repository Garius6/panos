# Тайпчекер

## Что

Точка входа — `typecheck_program :: proc(ctx: ^Type_Ctx, prog: Program)`
(`core/type_cheker.odin:2007`). Работает в 4 прохода (`Pass_Kind`,
`type_cheker.odin:2000`): **Nominal** (создать заглушки типов
struct/interface/enum), **Signatures** (заполнить поля, сигнатуры функций,
варианты enum, `generic_origin`), **Impls** (привязать `реализация`-блоки к
типам), **Bodies** (типизировать тела функций/методов, разрешить
`InferVar`, обобщить полиморфные лямбды).

**`Type`** (`type_cheker.odin:69`) — центральная структура:
`kind: Type_Kind`, `name: string`, `params`/`return_type` (для функций),
`elements` (туплы), `fields: [dynamic]Struct_Field` (структуры),
`methods: map[string]Symbol_Id`, `implemented_interfaces`,
`interface_methods`, `element_type` (Массив/Процесс/Указатель),
`key_type`/`value_type` (Соответствие), `infer_id`/`binding` (для
`InferVar` — цепочка унификации), `variants: [dynamic]Type_Variant`
(перечисления), `variant_index`, `generic_origin: Symbol_Id` (откуда
инстанциирован — для идентичности рекурсивных generic-типов, см. ниже).

**`Type_Kind`** (`type_cheker.odin:10`) — `Number`, `Integer` (отдельный от
`Number` тип — см. [дженерики](./generics-and-monomorphization.md) про
рантайм-представление), `Bool`, `String`, `Void`, `Never`, `Function`,
`Tuple`, `Struct`, `Interface`, `Array`, `Map`, `Error`, `InferVar`, `Enum`,
`File`, `Connection`, `Process`, `Pointer`, `Poison` (заглушка ошибки, см.
ниже).

**`Type_Ctx`** — рабочий контекст тайпчекера: `res: ^Resolver_Ctx`,
**`node_types: map[Expr]^Type`** (кэш выведенного типа на каждый узел —
ключ дизайна: см. [дженерики](./generics-and-monomorphization.md), почему
клонирование AST нужно именно из-за этой карты), `call_infos` (метаданные
вызова — какой конструктор/метод), `symbol_schemes` (полиморфные лямбды),
`current_type_params`/`decl_type_params` (T/E generic-декларации в
области видимости), `generic_instance_cache` (канонизация одинаковых
generic-инстанциаций по строковому ключу — не по указателю), `symbol_to_func_decl`,
`generic_call_instantiations`/`generic_call_callee_sym` (что мономорфизации
нужно скомпилировать — читает `core/monomorphize.odin`).

**`infer_expr`** (`type_cheker.odin:5831`) — bottom-up вывод типа: если
`ctx.node_types[expr]` уже посчитан — вернуть закэшированное; иначе
switch по варианту `Expr`, посчитать, **записать в `ctx.node_types[expr]`
ПЕРЕД возвратом**. `check_expr` (`type_cheker.odin:3242`) — двунаправленная
проверка: проталкивает ожидаемый тип вниз по дереву (нужно для сужения
литералов `Число`→`Целое` по контексту).

## Зачем

Тайпчекер отделён от резолвера, потому что связывание имён не требует
знания типов, а вывод типа выражения уже требует РЕЗОЛВЛЕННОГО символа. Не
менее важная причина полноценного inference-прохода (а не просто проверки
объявленных типов): лямбды без явной аннотации типов параметров получают
свежий `InferVar`, тип которого выводится из тела/контекста вызова;
числовые литералы без точки по умолчанию `Целое`, но расширяются до
`Число` в `Число`-контексте — оба случая требуют unification, а не
плоского сравнения объявленных типов.

## Почему так, а не иначе

**`generic_instance_cache` канонизирует ПО СТРОКОВОМУ КЛЮЧУ
(`generic_instance_key`, `type_cheker.odin:1338`), не по указателю** —
причина: рекурсивные generic-типы (`тип Список[T] = структура
следующий: Опция(Список(T)) конец`). Комментарий у `Type.generic_origin`
(`type_cheker.odin:96-107`): self-ссылка внутри ОДНОЙ инстанциации
канонизируется через `generic_instance_cache` только ПОСЛЕ полной
унификации конструктора; ДО этого две разные инстанциации одного
объявления — физически разные `^Type`-указатели, хотя семантически один
тип. Identity-only сравнение (случаи `.Struct`/`.Enum` в `unify_types`)
сочло бы их несовместимыми без канонизации.

**`unify_types`** (`type_cheker.odin:1374`, сигнатура
`(a: ^Type, b: ^Type, visited: ^map[[2]^Type]bool = nil) -> bool`) —
параметр `visited` (пары уже сравниваемых указателей выше по стеку
рекурсии) нужен ИМЕННО из-за рекурсивных generic-типов: сравнение двух
РАЗНЫХ инстанциаций одного объявления рекурсивно заходит в свои же поля
(`Список[T]` содержит `Опция(Список(T))`) — без `visited` это была бы
бесконечная рекурсия. Для `.Struct`/`.Enum`: если оба имеют одинаковый
`generic_origin` (или один `INVALID_SYMBOL`) — сравниваются структурно
(поэлементно); иначе — `false`, ДАЖЕ если структурно идентичны (разные
generic-декларации не совместимы, несмотря на совпадающую форму).

**`Poison` (`Type_Kind.Poison`)** — заглушка для узла, где уже
зарепорчена ошибка. Unify'ится с ЧЕМ УГОДНО (см. `unify_types`) — не даёт
одной первопричине расплодиться в десяток производных диагностик по всему
выражению. Возвращается функцией `report()`.

**`report`** (`type_cheker.odin:1044`, сигнатура
`(ctx: ^Type_Ctx, span: Span, format: string, args: ..any) -> ^Type`) —
форматирует diagnostic, ДЕДУПЛИЦИРУЕТ (не репортит тот же текст на том же
span дважды), добавляет в `ctx.diagnostics`, всегда возвращает
`TY_POISON` — вызывающему коду не нужна отдельная ветка для
error-recovery, просто использовать результат `report(...)` как обычный
`^Type`.

**Bounded generics («ограниченные дженерики», `[T: Интерфейс1 + Интерфейс2]`)**
— `Type.required_interfaces` заполняется в `make_decl_type_params`; при
типизации ТЕЛА generic-функции (`ctx.in_abstract_generic_body = true`) T
остаётся decl-param `InferVar` (НЕ конкретизируется) — `type_satisfies_interface`
проверяет `required_interfaces` абстрактно. На конкретном call site
(`infer_bounded_generic_call`, `type_cheker.odin:4720`) T инстанциируется
свежим `InferVar`, подставляется в аргументы вызова, проверяется на
соответствие `required_interfaces` УЖЕ конкретным типом — результат кладётся
в `ctx.generic_call_instantiations[expr]` для
[мономорфизации](./generics-and-monomorphization.md).

## Точки входа для типичной правки

| Изменение | Файл/функция |
|---|---|
| Новый бинарный оператор (тайпчек) | `infer_binary_expr` (`type_cheker.odin:4170`) — добавить `case` в `#partial switch e.op`, вызвать `prune_type(infer_expr(...))` на оба операнда, `unify_types` или прямая проверка, `report(...)` при несовпадении |
| Новый вид `Expr` (тайпчек) | добавить `case ^НовыйExpr:` в switch внутри `infer_expr` (`type_cheker.odin:5836`), написать `infer_новый_expr` рядом с существующими `infer_*`-функциями |
| Новая diagnostic-проверка | `report()` (`type_cheker.odin:1044`) — тот же паттерн, что везде в файле |
| Изменить порядок/состав проходов тайпчека | `typecheck_program` (`type_cheker.odin:2007`), `Pass_Kind` (`type_cheker.odin:2000`) |
