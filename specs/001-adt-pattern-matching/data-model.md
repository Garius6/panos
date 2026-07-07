# Phase 1: Data Model — ADT и pattern-matching

Определяет: (a) AST-структуры, (b) сущности резольвера/тайп-чекера,
(c) рантайм-значения. Все имена согласованы с существующим кодом.

## 1. AST (parser.odin)

Уже присутствуют (сохраняются как есть):

```odin
Variant_Decl :: struct {
    name:  string,
    types: [dynamic]Type_Node,
}
Enum_Decl :: struct {
    name:        string,
    variants:    [dynamic]Variant_Decl,
    is_exported: bool,
}

Pattern_Wildcard    :: struct {}
Pattern_Literal     :: struct { value: Expr }  // определён, но НЕ парсится (Simplicity)
Pattern_Ident       :: struct { name: string }
Pattern_Constructor :: struct {
    module_name: string,   // "" если неквалифицирован
    name:        string,
    args:        [dynamic]Pattern,
}
Pattern :: union { ^Pattern_Wildcard, ^Pattern_Literal, ^Pattern_Ident, ^Pattern_Constructor }

Match_Arm :: struct { pattern: Pattern, body: [dynamic]Stmt }
Match_Expr :: struct { subject: Expr, arms: [dynamic]Match_Arm }
```

Меняется:

- В `Pattern_Constructor` поле `module_name` переиспользуется для «квалификатора
  типом» (например, `Фигура.Круг(р)` даст `module_name = "Фигура"`). Резольвер
  различает случаи «модуль» vs «тип» по успеху поиска в `imports` vs
  `Symbol_Kind.Type`.
- В union `Expr` добавляется `^Match_Expr`.

Правила парсера (contracts/grammar.md подробно):

- `parse_enum_decl` собирает список `Variant_Decl` до `конец`, разделители —
  `;` или новая строка (существующий `consume_semicolon_or_newline`).
- `parse_match_expr` вызывается из `parse_primary` при токене `.Match`
  (ключ `выбор`). Читает subject-выражение, затем `1..N` веток; каждая
  ветка = шаблон, стрелка `->`, тело до следующего разделителя ветки или
  до `конец`. Пустое `arms` — ошибка парсера.
- `parse_pattern` рекурсивен: `_` → `Pattern_Wildcard`; идентификатор без
  скобок и не совпадающий с известным вариантом → `Pattern_Ident`;
  идентификатор с `(...)` → `Pattern_Constructor`; `Ident.Ident(...)` →
  `Pattern_Constructor` с `module_name = Ident`.

## 2. Символы (resolver.odin)

Расширение `Symbol_Kind`:

```odin
Symbol_Kind :: enum {
    Variable, Function, Type, Module, Builtin,
    Enum_Variant,   // НОВОЕ
}
```

Правила:

- Для каждого `Enum_Decl`:
  - Создаётся `Symbol{kind = .Type}` под именем ADT (существующий путь для
    `тип X = структура`).
  - Для каждого варианта — `Symbol{kind = .Enum_Variant}`, привязанный к
    родительскому типу (через новое поле `owner_type: ^Symbol`, добавляемое
    в `Symbol`).
  - Символы вариантов регистрируются в скоупе модуля под своим коротким
    именем **и** под квалифицированным `Тип.Вариант`. Конфликт коротких
    имён (два ADT с одинаковым именем варианта) не является ошибкой на
    стадии объявления: помечается «двусмысленный», и запрос по короткому
    имени в резольвере выражений выдаёт диагностику.
- Для ветки `выбор`:
  - Скоуп ветки живёт только на время `resolve_stmt`/`resolve_expr` внутри
    тела ветки; биндеры из шаблона добавляются как `Symbol{kind =
    .Variable}` с флагом `is_pattern_binder = true` (новое поле у Symbol),
    чтобы компилятор мог различить обычные локали и биндеры при
    диагностике.

Экспорт (FR-012): при `is_exported = true` у ADT все его варианты
регистрируются в `module.exports` вместе с типом.

Cross-module разрешение (FR-012a, Q3): при обращении вида
`модуль.Тип.Вариант(...)` резольвер сначала находит символ модуля, затем
внутри `module.exports` — символ типа, затем — символ варианта по
`owner_type`. Форма `модуль.Вариант(...)` разрешается путём поиска
`Enum_Variant` символов среди экспортов модуля с этим коротким именем;
при 0 совпадений — «неизвестное имя», при >1 — «имя неоднозначно,
уточните тип».

Prelude (FR-011, Q5): при создании корневого scope модуля резольвер
регистрирует четыре встроенных варианта как обычные `Enum_Variant`:

- `Есть` → `owner_type` = символ типа `Опция`
- `Нет` → `owner_type` = символ типа `Опция`
- `Успех` → `owner_type` = символ типа `Результат`
- `Неудача` → `owner_type` = символ типа `Результат`

Никакой отдельный путь разрешения для этих имён не заводится: `Есть(41)`
в выражении и `Есть(х)` в шаблоне идут через тот же `Enum_Variant`.
Существующий экспорт `Есть`/`Нет`/... как builtin-функций через
`add_builtin_export` заменяется на этот путь.

## 3. Типы (type_cheker.odin)

Расширение:

```odin
Type_Kind :: enum {
    ..., Enum,   // НОВОЕ, добавляется в существующее перечисление
}

Type_Variant :: struct {
    name:   string,
    fields: [dynamic]^Type,
}
```

Поле `variants: [dynamic]Type_Variant` добавляется в структуру `Type`
(инициализировано пустым для не-ADT типов). Для встроенных `Option` и
`Result` `variants` заполняется реальными записями при интернировании
типа (Q5, R5), с фиксированным порядком тегов:

- `Опция(T)`: index 0 = `Нет` (без полей), index 1 = `Есть` (поле `T`).
- `Результат(T, E)`: index 0 = `Успех` (поле `T`), index 1 = `Неудача`
  (поле `E`).

Никаких других полей `Type` не меняется.

Правила:

- **Конструктор варианта**:
  - Без полей (`Точка`): выражение имеет тип ADT; если контекст ожидает
    `T = ADT`, используется напрямую.
  - С полями (`Круг(3)`): вызов, аргументы позиционные, тип каждого
    аргумента совместим с `Type_Variant.fields[i]` (существующая функция
    совместимости `types_assignable`).
- **Выражение `выбор`**:
  - Тип subject должен быть `.Enum`, `.Option`, `.Result` — иначе
    сообщение «выбор ожидает значение перечисления, получено ...».
  - Каждая ветка типизируется в своём скоупе (см. §2).
  - Общий тип — та же процедура, что для `если`: unify типа-результата
    ветвей, `.Never` игнорируется.
- **Исчерпываемость**: наивный алгоритм из R6.
- **Недостижимость**: см. R6.

Экспортируемые API type checker'а (для тестов и остальной части
пайплайна): чистые предикаты `variant_of_type(t: ^Type, name: string) ->
Maybe(int)`, `all_variants(t: ^Type) -> []string`, без скрытого состояния.

## 4. Значение (compiler.odin / vm.odin)

Добавляется в `Value` union:

```odin
Variant_Value :: struct {
    type_name: string,       // имя ADT (для диагностики и печати)
    tag_index: int,          // 0..len(variants)-1
    fields:    [dynamic]Value,
}
Value :: union {
    ..., ^Variant_Value,   // НОВОЕ
}
```

Существующие `^Option_Value` и `^Result_Value` НЕ меняются. Слой доступа
к тегам и полям через чистые процедуры:

```odin
variant_tag :: proc(v: Value) -> (tag: int, ok: bool)
variant_field :: proc(v: Value, i: int) -> (Value, bool)
```

- Для `^Variant_Value`: возвращают напрямую `tag_index`, `fields[i]`.
- Для `^Option_Value{has_value = false}` → tag = 0 (Нет), поле недоступно.
- Для `^Option_Value{has_value = true}` → tag = 1 (Есть), поле 0 = value.
- Для `^Result_Value{is_ok = true}` → tag = 0 (Успех), поле 0 = value.
- Для `^Result_Value{is_ok = false}` → tag = 1 (Неудача), поле 0 = error.

Порядок тегов зафиксирован для встроенных типов и повторяется в таблице
type checker'а из R5.

Экспорт: `Variant_Value` рождается только конструктором варианта; вне
этого пути не мутируется — это упрощает reasoning и соответствует
функциональному стилю FR-017.

Форматирование (FR-015a, Q2): существующая логика, которая превращает
`Value` в строку для встроенной процедуры `печать`/`строка`, расширяется
случаем для `^Variant_Value` формой `type_name.variants[tag_index].name`
плюс, при непустом `fields`, — `(f1, f2, ...)`, где каждый `fi`
рекурсивно проходит тот же форматтер. `^Option_Value`/`^Result_Value`
идут тем же путём через `variant_tag`/`variant_field`, что даёт
консистентный вывод `Есть(41)`, `Нет`, `Успех("ok")`, `Неудача(Ошибка(...))`.

## 5. Инварианты и валидации

| Инвариант | Стадия | Проверка |
|-----------|--------|----------|
| Имена вариантов ADT уникальны в пределах типа | parser или resolver | до type checking |
| Число полей у конструктора совпадает с объявлением | type checker | ошибка «ожидалось N аргументов, получено M» |
| Типы полей у конструктора совместимы | type checker | существующий `types_assignable` |
| Все варианты покрыты `выбор` (или есть `_`) | type checker | список непокрытых в сообщении |
| Ветка недостижима | type checker | указывает позицию ветки |
| Биндер не виден вне своей ветки | resolver | скоуп ветки уничтожается по выходу |
| ADT не может быть пустым | parser или type checker | «перечисление должно объявлять хотя бы один вариант» |
| Экспорт ADT все-или-ничего | resolver | по FR-012 |
| Runtime-tag существует | vm | иначе `Match_Fail` |
