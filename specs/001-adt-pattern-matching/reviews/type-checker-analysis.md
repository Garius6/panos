# Анализ `type_cheker.odin`

**Дата**: 2026-07-07
**Область**: `type_cheker.odin` после фичи ADT + pattern-matching
**Цель**: выявить точки переусложнения, продиктовать целенаправленный
рефакторинг, оценить порядок работ.

Отчёт составлен пост-фактум по стабильной ветке `001-adt-pattern-matching`
(коммиты `314d894`, `8fdf931`, `cae8257`, `8b2779e`, `e41f3cc`). Все 38 e2e-тестов
проходят, `test.ps` работает без регрессий. Проблемы — не блокеры, а долги,
которые накапливаются и увеличивают стоимость каждой следующей фичи.

---

## Оглавление

1. Метрики и общая картина
2. Крупные проблемы (P1–P6): impact HIGH
3. Средние проблемы (P7–P11): impact MEDIUM
4. Мелочи (P12–P15): impact LOW
5. Прогнозируемая экономия строк
6. Приоритизация волнами
7. Альтернатива: разделение файла на модули
8. Migration path и меры безопасности
9. Что не является проблемой (защита от over-refactor)
10. Итог и рекомендации

---

## 1. Метрики и общая картина

| Показатель | Значение | Комментарий |
|------------|----------|-------------|
| Строк всего | 2359 | Крупнейший файл проекта |
| Процедур | 42 | Из них 6 крупных (>100 строк) |
| `infer_expr` | 854 строки | 36 % файла в одной процедуре |
| `typecheck_program` | 154 строки | 4 прохода в одной proc |
| `standard_method_type` | 149 строк | Плоский switch по методам |
| `builtin_constructor_type` | 51 строка | Плоский switch по builtin'ам |
| `check_match_coverage` | 72 строки | Только эту стоит трогать осторожно — pure |
| Side-tables на `Type_Ctx` | 11 карт | Каждая — отдельная семантика |

### Что говорят метрики

- **Один файл — вся стадия**. Type-inference, method-dispatch,
  variant-classification, exhaustiveness, unify — всё в одном пространстве
  имён. Cross-cutting concerns (например, "как записывается результат вывода
  типа") распределены по всему файлу.
- **Один `infer_expr` — вся семантика выражений**. Каждый case — маленький
  парсер+анализатор. Изменение поведения одного узла AST требует навигации
  внутри монолита.
- **Много side-tables — много точек синхронизации**. Компилятор читает эти
  карты; при изменении одной таблицы нужно менять и производителя, и
  консюмера.

Это классические признаки того, что модуль перерос свой первоначальный
дизайн. Не показатель "плохого кода" — показатель "фичи росли инкрементально
без периодической ревизии".

---

## 2. Крупные проблемы

### P1. `infer_expr` — 854-строчный monolith

**Где**: `type_cheker.odin:1499-2353`.

**Что**. Один `switch` по типам AST-узла, в котором каждый case делает
всё сам: лукап `Symbol`, ветвление по `Symbol_Kind`, запись side-tables,
инкрементальная унификация, генерация диагностических сообщений.

Кейс `Call_Expr` — **отдельная драма на ~300 строк**: сначала проверка на
`Enum_Variant` (~60 строк), потом дубль для `Ident_Expr`-callee (~60 строк),
потом ветка `.Builtin` через `builtin_constructor_type` (~20 строк), потом
`Property_Expr` (Module.export, Struct-конструктор, метод collection'а,
метод Опции/Результата, метод интерфейса, метод структуры) — суммарно ещё
~160 строк.

**Пример** — упрощённый профиль текущего Call_Expr:

```odin
case ^Call_Expr:
    // Ветка 1: callee resolves к Enum_Variant (через node_symbols).
    callee_sym := ctx.res.node_symbols[e.callee]
    if callee_sym != nil && callee_sym.kind == .Enum_Variant {
        // ~60 строк: lookup owner_type, tag search, arity check,
        // per-field unify_types, запись в variant_calls.
    }
    // Ветка 2: то же самое, но выборкой через .(^Ident_Expr).
    if _, ok := e.callee.(^Ident_Expr); ok {
        if sym := ctx.res.node_symbols[e.callee]; sym != nil &&
           sym.kind == .Enum_Variant {
            // ~60 строк: почти идентичный код.
        }
    }
    // Ветка 3: Builtin constructor (Есть, Нет, Успех, Неудача, Ошибка, ...).
    if ident, ok := e.callee.(^Ident_Expr); ok {
        if sym := ctx.res.node_symbols[e.callee]; sym != nil &&
           sym.kind == .Builtin {
            // ~10 строк: делегация в builtin_constructor_type.
        }
    }
    // Ветка 4: Property_Expr (модуль.имя, obj.метод).
    #partial switch prop_expr in e.callee {
    case ^Property_Expr:
        // ~200 строк: разбор по kind object'а — Module, Array, Map,
        // Struct, Interface, Опция, Результат.
    }
    // Ветка 5: обычный вызов функции.
    ...
```

**Почему больно**.
- Изменение поведения одного узла требует прочтения всех сотен строк —
  боишься сломать что-то далёкое.
- Тесты покрывают через e2e-flow, но не изолируют узел.
- Одна большая функция в отладчике сложна: приходится ставить условные
  breakpoints по AST-узлам.
- Расширение (например, добавление вложенных match'ей в выражение) —
  разбавит monolith ещё больше.

**Фикс**. Извлечь по одной процедуре на каждый case:

```odin
infer_expr :: proc(ctx: ^Type_Ctx, expr: Expr) -> ^Type {
    if expr == nil do return nil
    if t, ok := ctx.node_types[expr]; ok do return t

    t: ^Type
    switch e in expr {
    case ^Number_Expr:  t = TY_NUM
    case ^Boolean_Expr: t = TY_BOOL
    case ^String_Expr:  t = TY_STRING
    case ^Ident_Expr:   t = infer_ident_expr(ctx, expr, e)
    case ^Call_Expr:    t = infer_call_expr(ctx, expr, e)
    case ^Match_Expr:   t = infer_match_expr(ctx, expr, e)
    case ^Property_Expr:t = infer_property_expr(ctx, expr, e)
    case ^Binary_Expr:  t = infer_binary_expr(ctx, expr, e)
    ...
    }
    ctx.node_types[expr] = t
    return t
}
```

Каждая новая процедура (`infer_call_expr`, `infer_match_expr`, ...) —
80–200 строк, читаема отдельно. `infer_expr` становится диспатчером на ~40
строк.

**Effort**: MEDIUM. Механический процесс: вырезаем case → отдельная функция
→ переносим локальные переменные в параметры. Существующие тесты — гарант
корректности. Один вечер.

**Line delta**: тот же порядок строк (не уменьшает, но убирает вложенность
и делает файлы обозримыми). Если после split'а перенести процедуры в
отдельные файлы (`typecheck_call.odin` и т.п.) — файл `type_cheker.odin`
сократится до ядра (типы, унификация, диспатч).

**Тесты**: не требуют изменений — существующие покрывают.

**Связанные проблемы**: P2 (дубль внутри `Call_Expr`) закрывается легче
после split'а — три ветки уже в одной функции.

---

### P2. Тройная дупликация `Enum_Variant`-конструктора

**Где**:
- `type_cheker.odin:1523-1567` (Ident_Expr → constructor value)
- `type_cheker.odin:1656-1715` (Call_Expr через callee_sym)
- `type_cheker.odin:1717-1772` (Call_Expr через `.(^Ident_Expr)`)

**Что**. Один и тот же алгоритм выполняется три раза с чуть-чуть разными
входными данными:

1. Взять `owner_type` из `sym.owner_type`.
2. Убедиться, что тип-владелец построен (`symbol_types[owner]`).
3. Линейным поиском найти `tag_index` варианта по имени.
4. Проверить arity (для zero-field — ровно 0; для Call_Expr — совпадение
   с числом полей).
5. Пропустить `unify_types` по каждому полю с кастомной русскоязычной
   диагностикой.
6. Записать `variant_calls[expr]` или `variant_idents[expr]`.
7. Вернуть тип-владельца.

Разница между вариантами:
- Ident-путь: arity = 0, записываем в `variant_idents`.
- Call-путь через `callee_sym`: любой arity, `variant_calls`.
- Call-путь через `.(^Ident_Expr)`: идентично предыдущему, но в другой
  ветке (осталось после инкрементального добавления).

**Почему больно**.
- Три места, три возможных ошибки. Любое расширение (например, доб.
  диагностика "имя типа" в панике) нужно повторить трижды.
- Компилятор читает **обе** side-tables (`variant_calls` + `variant_idents`)
  для одинаковой семантики — двойная работа.
- При первом чтении файла новичок не может понять, зачем два места делают
  одно и то же.

**Фикс**. Одна процедура-helper:

```odin
Variant_Ctor_Info :: struct {
    owner_type: ^Type
    tag_index: int
    arity: int
}

// Проверяет arity + типы аргументов, возвращает тип-результат и
// заполняет ctx.variant_ctors. Единый путь для Ident-конструктора
// (arity=0), Call с Ident-callee, Call с Property-callee.
resolve_variant_ctor :: proc(
    ctx: ^Type_Ctx,
    expr: Expr,
    variant_sym: ^Symbol,
    args: []Expr,
) -> ^Type {
    owner := variant_sym.owner_type
    owner_type := ctx.res.symbol_types[owner]
    if owner_type == nil {
        fmt.panicf(
            "Type Error: тип-владелец варианта '%s' ещё не построен",
            variant_sym.name,
        )
    }
    tag, ok := variant_index(owner_type, variant_sym.name)
    if !ok {
        fmt.panicf(
            "Type Error: вариант '%s' не найден в '%s'",
            variant_sym.name, owner_type.name,
        )
    }
    fields := owner_type.variants[tag].fields
    if len(args) != len(fields) {
        fmt.panicf(
            "Type Error: у варианта '%s.%s' ожидалось %d аргументов, получено %d",
            owner_type.name, variant_sym.name, len(fields), len(args),
        )
    }
    for arg, i in args {
        actual := prune_type(infer_expr(ctx, arg))
        if !unify_types(actual, fields[i]) {
            fmt.panicf(
                "Type Error: у варианта '%s.%s' поле #%d ожидает '%s', получено '%s'",
                owner_type.name, variant_sym.name, i,
                prune_type(fields[i]).name, prune_type(actual).name,
            )
        }
    }
    ctx.variant_ctors[expr] = Variant_Ctor_Info {
        owner_type = owner_type,
        tag_index  = tag,
        arity      = len(args),
    }
    return owner_type
}
```

Все три места сжимаются до одного вызова:

```odin
// Ident:  return resolve_variant_ctor(ctx, expr, sym, nil)
// Call:   return resolve_variant_ctor(ctx, expr, callee_sym, e.args[:])
```

**Effort**: LOW. ~30 минут. Помогает P3 (единый lookup через
`variant_index`).

**Line delta**: **–180 строк** дупликата → +40 строк helper'а. Итог **–140
строк**.

**Тесты**: без изменений; те же входы дают те же результаты.

**Связанные**: P4 (унификация `variant_calls`+`variant_idents` в
`variant_ctors`), P3 (helper `variant_index`).

---

### P3. `O(V)` линейный поиск варианта по имени

**Где**: 6 разных мест по файлу — в `infer_expr` (3 раза), в
`classify_pattern` (3 раза), в `check_match_coverage` (косвенно через
структуру `arm_infos`, а также при формировании диагностики).

**Что**. Каждый lookup:

```odin
tag := -1
for v, i in owner_type.variants {
    if v.name == sym.name {
        tag = i
        break
    }
}
if tag < 0 { fmt.panicf(...) }
```

- Сложность `O(V)` на каждый lookup.
- Пять–шесть повторов одного pattern'а в файле.

**Почему больно**.
- Для типичных ADT (5–10 вариантов) — незаметно. Для гипотетического
  perf-critical scenario (генерируемые enum'ы из ProtoBuf или сериализатор
  с 100+ вариантами) — уже заметно.
- Дублированный boilerplate = дублированный шанс поставить одну
  ошибочно.
- Скрывает, что "найти вариант" — это re-usable примитив, не 6 разных
  задач.

**Фикс**. Добавить `variant_index: map[string]int` в `Type` и
заполнять при построении Enum-типа (в проходе 2 `typecheck_program`).
Helper на файловом уровне:

```odin
variant_index :: proc(enum_type: ^Type, name: string) -> (int, bool) {
    idx, ok := enum_type.variant_index[name]
    return idx, ok
}
```

Все 6 мест — один вызов. Плюс `synth_option_enum`/`synth_result_enum`
заполняют `variant_index` при создании.

**Effort**: LOW. ~20 минут (правки Type struct, конструкторов Enum-типов
и synth-функций). Тесты те же.

**Line delta**: **–30 строк** (6 повторов × 5 строк) + 3 строки на
структуру + 3 на helper = **–24 строки**.

**Дополнительный бонус**: убирает риск, что кто-то забудет `if tag < 0`
проверку.

---

### P4. 11 side-tables на `Type_Ctx` — знание распределено

**Где**: `type_cheker.odin:349-380` (объявление `Type_Ctx`), плюс
`compiler.odin`, который читает большинство из них.

**Что**. Текущие side-tables:

```odin
Type_Ctx :: struct {
    res:              ^Resolver_Ctx,
    node_types:       map[Expr]^Type,          // universal
    is_constructor:   map[Expr]bool,           // Struct constructor only
    property_indices: map[Expr]int,            // struct field access
    method_calls:     map[Expr]^Symbol,        // struct method
    interface_casts:  map[Expr]^Type,          // interface upcast
    interface_calls:  map[Expr]string,         // interface method dispatch
    collection_calls: map[Expr]string,         // Array/Map/Option/Result methods
    builtin_calls:    map[Expr]string,         // Builtin function call
    variant_calls:    map[Expr]Variant_Call_Info, // Enum_Variant Call_Expr
    variant_idents:   map[Expr]Variant_Call_Info, // Enum_Variant Ident_Expr
    match_arm_infos:  map[^Match_Expr][dynamic]Match_Arm_Info,
    ...
}
```

Компилятор при обработке `Call_Expr` последовательно проверяет несколько:

```odin
case ^Call_Expr:
    if info, is_variant := ctx.tc.variant_calls[expr]; is_variant { ... }
    if _, is_builtin := ctx.tc.builtin_calls[expr]; is_builtin { ... }
    if _, is_collection := ctx.tc.collection_calls[expr]; is_collection { ... }
    if _, is_iface := ctx.tc.interface_calls[expr]; is_iface { ... }
    if method_sym, is_method := ctx.tc.method_calls[expr]; is_method { ... }
    if ctx.tc.is_constructor[expr] { ... }
    else { /* обычный вызов */ }
```

**Почему больно**.
- Порядок проверок в компиляторе неявно кодирует приоритет kind'а вызова.
  Если кто-то забудет проверить один из них — молчаливая недоопределённость.
- При добавлении нового kind'а нужно (а) новую карту, (б) добавить проверку
  в compiler, (в) не сломать существующий порядок.
- Тестирование single-source-of-truth ломается: два разных Type Checker
  теста могут поставить `variant_calls` и `is_constructor` — какой из них
  победит?

**Фикс**. Один тег + одна struct:

```odin
Call_Kind :: enum {
    Function,        // обычная функция или лямбда
    Builtin,         // печать, длина, паника, ...
    Method_Struct,   // obj.метод(...)
    Method_Interface,// atk.атаковать(...)
    Method_Collection, // arr.добавить(...), opt.получить(...)
    Constructor_Struct,  // Игрок(...)
    Constructor_Variant, // Круг(...)
}

Call_Info :: struct {
    kind: Call_Kind,
    // Подходящие поля по kind — либо union, либо все поля с nil-значениями.
    symbol_ref: ^Symbol,     // для Method_Struct, Function
    text_name: string,       // для Builtin, Method_*
    variant_ref: Variant_Ctor_Info, // для Constructor_Variant
}

Type_Ctx :: struct {
    ...
    call_infos: map[Expr]Call_Info,   // единая карта вместо семи
    property_indices: map[Expr]int,    // остаётся: не про Call
    interface_casts: map[Expr]^Type,   // остаётся: не про Call
    match_arm_infos: map[^Match_Expr][dynamic]Match_Arm_Info,  // остаётся
    node_types: map[Expr]^Type,        // остаётся
}
```

Компилятор диспатчит `switch info.kind`:

```odin
case ^Call_Expr:
    info := ctx.tc.call_infos[expr]
    switch info.kind {
    case .Constructor_Variant: emit_build_variant(...)
    case .Constructor_Struct:  emit_build_aggregate(...)
    case .Builtin:             emit_call_builtin(...)
    case .Method_Collection:   emit_invoke_collection(...)
    case .Method_Interface:    emit_invoke_interface(...)
    case .Method_Struct:       emit_call_method(...)
    case .Function:            emit_call(...)
    }
```

**Единственный source of truth**. Ошибочный порядок невозможен.
Расширяемость: новый kind = запись в enum + case в компиляторе.

**Effort**: MEDIUM. ~2–3 часа. Затрагивает и type checker (все места, где
писали в старые карты), и компилятор (все места, где читали). Тесты те же —
но нужно внимание к порядку.

**Line delta**: type_cheker.odin **–70** (7 разбросанных записей → 1
типизированная); compiler.odin **–30**; +40 на определения структуры.
Итого **–60 строк** плюс огромное улучшение обозримости.

**Тесты**: без изменений семантики.

**Связанные**: P2 (Variant_Call_Info поглощает variant_calls+variant_idents),
P10 (`is_constructor` уходит в `Call_Kind`).

---

### P5. `synth_option_enum`/`synth_result_enum` — утечки памяти

**Где**: `type_cheker.odin:247-273` (объявления), плюс вызываются в
`classify_pattern` и `infer_expr` для Match_Expr.

**Что**.

```odin
synth_option_enum :: proc(option_type: ^Type) -> ^Type {
    t := new(Type)                              // ← аллокация
    t.kind = .Enum
    t.name = option_type.name
    t.variants = make([dynamic]Type_Variant)    // ← аллокация
    append(&t.variants, Type_Variant{name = "Нет", fields = make(...)})
    ...
    return t
}
```

Каждый `выбор о` над `Опция(Число)` вызывает `synth_option_enum` заново.
Никакого кэширования: если функция матчит опцию 10 раз, создаётся 10
идентичных Type-объектов.

**Почему больно**.
- **Утечка памяти**: Odin с tracking-аллокатором показывает эти утечки в
  выводе тестов (сотни байт на прогон).
- **Identity-check не работает**: два Type'а, представляющие одну и ту же
  Опцию(Число), — разные объекты. Если в будущем сравнивать типы через
  указатель (быстрая проверка), сломается.
- **Профилирование**: горячий путь match'а не эксплуатирует кэши.

**Фикс**. Кэш в `Type_Ctx`:

```odin
Type_Ctx :: struct {
    ...
    synth_enum_cache: map[^Type]^Type,  // base type → synth enum view
}

synth_enum_view :: proc(ctx: ^Type_Ctx, base: ^Type) -> ^Type {
    if cached, ok := ctx.synth_enum_cache[base]; ok do return cached
    result: ^Type
    #partial switch base.kind {
    case .Option: result = build_option_enum(base)
    case .Result: result = build_result_enum(base)
    case: fmt.panicf("не-Option/Result тип: %v", base.kind)
    }
    ctx.synth_enum_cache[base] = result
    return result
}
```

Все места:
```odin
enum_view := synth_enum_view(ctx, subject_type)  // instead of synth_option_enum/synth_result_enum
```

**Effort**: LOW. ~20 минут.

**Line delta**: +5 строк (кэш и helper); –0 (две существующие функции
остаются как build-helpers, но их будут вызывать один раз на тип).

**Тесты**: без изменений, но memory-tracker перестанет показывать эти
утечки.

**Связанные**: P3 (variant_index заполняется один раз при cache-miss).

---

### P6. `builtin_constructor_type` + `standard_method_type` — 200 строк boilerplate

**Где**:
- `builtin_constructor_type`: `type_cheker.odin:1297-1346`
- `standard_method_type`: `type_cheker.odin:1348-1496`

**Что**. Каждый case выглядит так:

```odin
case "есть":
    if len(args) != 0 do fmt.panicf("Type Error: Опция.есть() не принимает аргументы")
    ctx.collection_calls[call] = method_name
    return TY_BOOL, true
case "пусто":
    if len(args) != 0 do fmt.panicf("Type Error: Опция.пусто() не принимает аргументы")
    ctx.collection_calls[call] = method_name
    return TY_BOOL, true
case "значение":
    ...
```

Повторяется 20+ раз. Пять строк на case, три из которых — идентичные:
проверка arity, запись в side-table, возврат.

**Почему больно**.
- Ошибки правки: изменил тип в одном месте, забыл в другом.
- При добавлении нового метода — копипаст.
- Сложно оценить полноту: какие методы у Опции? Приходится читать все
  case'ы.
- Дублирует диагностику: "не принимает аргументы" встречается 10+ раз
  в файле.

**Фикс**. Data-driven:

```odin
Method_Sig :: struct {
    name: string,
    arity: int,
    // Функция получает receiver_type и args, возвращает тип-результат.
    // Для простых случаев — короткий handler; для сложных (Опция.запас с
    // унификацией) — полноценная процедура.
    handler: proc(ctx: ^Type_Ctx, call: Expr,
                  receiver: ^Type, args: []Expr) -> ^Type,
    marker: string,   // что записать в collection_calls
}

OPTION_METHODS := []Method_Sig {
    {name = "есть", arity = 0, marker = "есть",
     handler = proc(...) -> ^Type { return TY_BOOL }},
    {name = "пусто", arity = 0, marker = "пусто",
     handler = proc(...) -> ^Type { return TY_BOOL }},
    {name = "значение", arity = 0, marker = "значение",
     handler = proc(_, _, r, _) -> ^Type { return prune_type(r.element_type) }},
    // ...
}

standard_method_type :: proc(...) -> (^Type, bool) {
    method_list := select_method_list(receiver_type.kind)
    if method_list == nil do return nil, false
    for m in method_list {
        if m.name != method_name do continue
        if len(args) != m.arity {
            fmt.panicf(
                "Type Error: %s.%s() ожидает %d аргументов, получено %d",
                receiver_type.name, method_name, m.arity, len(args),
            )
        }
        ctx.collection_calls[call] = m.marker
        return m.handler(ctx, call, receiver_type, args), true
    }
    return nil, false
}
```

Каждый case превращается в одну строку таблицы. Сложные случаи (Опция.запас,
Опция.результат_или) используют дополнительный `handler`.

**Effort**: MEDIUM. ~2 часа. Требует внимания, чтобы сохранить точный
текст диагностик (они exact-matched в e2e-тестах).

**Line delta**: **–150 строк** boilerplate → +60 строк таблицы. Итог
**–90 строк**.

**Тесты**: все негативные тесты с exact-match сообщений должны
продолжить работать. Возможно, придётся аккуратно унифицировать формат
русскоязычной ошибки.

**Дополнительный бонус**: таблицу легко распечатать/сериализовать для
документации (авто-генерация раздела language.md).

---

## 3. Средние проблемы

### P7. Мутация `ctx.res.symbol_types` из type checker

**Где**: `type_cheker.odin:534` и подобные — type checker пишет в
`ctx.res.symbol_types`, карту, которой владеет резольвер:

```odin
ctx.res.symbol_types[ctx.res.decl_symbols[decl]] = struct_type
ctx.res.symbol_types[binder_sym] = expected_type
```

**Что**. Резольвер объявляет `symbol_types` как поле `Resolver_Ctx` и
заполняет его частично (для встроенных модулей). Type checker дозаполняет
эту же карту для user-declared типов и binder'ов из match arm'ов.

**Почему больно**.
- Нарушение single-responsibility. Кто-то читающий резольвер увидит,
  что `symbol_types` пусто в конце `resolve_program`, но полно в
  начале `typecheck_program`. Магический переход.
- При отладке трудно понять, где именно поставилась запись — resolver
  или type checker.
- Инкрементальное type checking (для будущего IDE-режима) требует
  снапшота: старая копия карты + дельта type checker'а. Сейчас снапшот
  сделать сложно.

**Фикс**. Разделить:

```odin
Resolver_Ctx :: struct {
    ...
    symbol_types: map[^Symbol]^Type,  // readonly после resolve
}
Type_Ctx :: struct {
    res: ^Resolver_Ctx,
    derived_types: map[^Symbol]^Type, // пишется type checker'ом
    ...
}

// Единая точка чтения:
type_of :: proc(ctx: ^Type_Ctx, sym: ^Symbol) -> ^Type {
    if t, ok := ctx.res.symbol_types[sym]; ok do return t
    if t, ok := ctx.derived_types[sym]; ok do return t
    return nil
}
```

**Effort**: MEDIUM. ~2 часа. Много мест, где сейчас читается напрямую.

**Line delta**: около 0 (переименование + helper).

**Тесты**: без семантических изменений.

**Стоит ли делать**: только если есть план на IDE-mode или инкрементальный
recheck. Иначе перфекционизм.

---

### P8. Panic на первой ошибке — плохой UX

**Где**: весь файл. `fmt.panicf` — единственный способ репортить ошибку.

**Что**. Ошибка типа `X` в строке 100 → panic → пользователь видит одну
ошибку → правит → компилирует → видит следующую → правит → и так до
десяти итераций.

Real language `rustc`, `tsc`, `mypy` собирают все ошибки в один pass:
пользователь получает N ошибок и правит группу.

**Фикс** (большой):

```odin
Diagnostic :: struct {
    severity: Severity,
    message: string,
    location: Source_Location,  // строка + столбец
}

Type_Ctx :: struct {
    ...
    diagnostics: [dynamic]Diagnostic,
}

// Вместо fmt.panicf — append + poison type:
report :: proc(ctx: ^Type_Ctx, format: string, args: ..any) -> ^Type {
    msg := fmt.aprintf(format, ..args)
    append(&ctx.diagnostics, Diagnostic{severity = .Error, message = msg})
    return TY_POISON  // специальный тип, тихо unify'ется со всем
}
```

`TY_POISON` — концепция из компиляторов ML/OCaml: если выражение уже
некорректно, все зависимые выражения тоже некорректны, но не хотим
каскадные ошибки. `TY_POISON` `unify`'ется с чем угодно, но помечает
поддерево как ошибочное.

**Почему больно** (проблема, если не сделать).
- Пользователь тратит время на цикл "правка → перезапуск → следующая
  ошибка".
- Автоматизированные тесты негативных сценариев видят только первую
  ошибку — тесты, проверяющие сразу несколько ошибок, невозможны.
- Отсутствие Source_Location в диагностиках — грустно, но это отдельная
  проблема (Panos не хранит span'ы в AST-узлах).

**Effort**: HIGH. ~6–10 часов. Требует
- Добавить Source_Location в токены и AST (сейчас нет).
- TY_POISON + правило "poison никогда не мешает".
- Все 100+ `fmt.panicf` → `report(ctx, ...)`.
- Проверка в конце `typecheck_program`: если `len(diagnostics) > 0`
  — печать всех + non-zero exit.
- Обновление всех e2e-тестов: `testing.expect_assert` уже не подходит,
  нужен другой механизм проверки.

**Стоит ли делать**: да, но отдельным phase'ом. Это не рефакторинг —
это фича с большой user-visible ценностью. `/speckit-specify` подходящий
инструмент.

**Line delta**: +200 строк (diagnostic infrastructure), но окупается
качественно.

---

### P9. Четыре прохода `typecheck_program` без формальной семантики

**Где**: `type_cheker.odin:749-900`.

**Что**. Проходы:

1. **Nominal**. Создать placeholder Type для Struct/Interface/Enum.
2. **Fields + Signatures**. Заполнить поля структур, сигнатуры функций,
   методы интерфейсов, варианты enum'ов.
3. **Impl bindings**. Связать `реализация`-блоки с типами.
4. **Bodies**. Проверить тела функций и методов.

Порядок неявный, комментарии описывают его. Enum_Decl участвует в
проходах 1 и 2, но не в 3 — что делает `реализация Фигура ... конец`
невозможной (не блокер сейчас, но ловушка при расширении).

**Почему больно**.
- Расширение (например, статические методы enum, generic-параметры,
  associated types) потребует внимания ко всем проходам.
- Порядок фиксирован не тестом, а положением в файле.
- Если случайно добавить действие в неправильный проход, тесты могут
  проходить (случайно), а падать в специфичных сценариях.

**Фикс** (малой кровью):

```odin
Pass_Kind :: enum { Nominal, Signatures, Impls, Bodies }

typecheck_program :: proc(ctx: ^Type_Ctx, prog: Program) {
    passes := []Pass_Kind{.Nominal, .Signatures, .Impls, .Bodies}
    for pass in passes {
        run_pass(ctx, prog, pass)
    }
}

run_pass :: proc(ctx: ^Type_Ctx, prog: Program, pass: Pass_Kind) {
    for decl in prog.decls {
        run_pass_for_decl(ctx, decl, pass)
    }
}

run_pass_for_decl :: proc(ctx: ^Type_Ctx, decl: Decls, pass: Pass_Kind) {
    switch d in decl {
    case ^Struct_Decl:    typecheck_struct(ctx, d, pass)
    case ^Interface_Decl: typecheck_interface(ctx, d, pass)
    case ^Enum_Decl:      typecheck_enum(ctx, d, pass)
    case ^Function_Decl:  typecheck_function(ctx, d, pass)
    case ^Impl_Decl:      typecheck_impl(ctx, d, pass)
    ...
    }
}
```

Каждая процедура типа `typecheck_enum(ctx, d, pass)` внутри имеет
собственный switch по `pass`, где перечислены обязанности этого typedecl
на каждом проходе. Ясно и локально.

**Effort**: MEDIUM. ~2–3 часа. Тесты те же.

**Line delta**: +30 строк на диспатч, но структура более обозрима.

**Стоит ли делать**: при добавлении новых видов Decl — да; сейчас — по
желанию.

---

### P10. `is_constructor: map[Expr]bool` — legacy

**Где**: `type_cheker.odin:352`, компилятор `compiler.odin`.

**Что**. Единственное использование: пометить, что `Call_Expr` — это
struct-конструктор (`Игрок(...)`), не обычный вызов функции. Компилятор
эмитит `Build_Aggregate` вместо `Call`.

**Почему больно**. Каждый другой тип конструкции получил свою специальную
таблицу (variant_calls, builtin_calls, ...). Только struct-конструктор
представлен через bool-флаг. Раскол стиля.

**Фикс**. Уходит в `Call_Info` (см. P4):

```odin
if info, ok := ctx.tc.call_infos[expr]; ok && info.kind == .Constructor_Struct {
    emit_build_aggregate(...)
}
```

**Effort**: включён в P4.

**Line delta**: включён в P4.

---

### P11. `check_expr` vs `unify_types` — раскол стиля

**Где**: в моих Enum_Variant-путях (Call_Expr) я использую `unify_types`
+ inline `fmt.panicf` с кастомной диагностикой. В остальном файле —
`check_expr` с generic-сообщением.

**Что**. Два способа проверить "expr имеет ожидаемый тип":

```odin
// Способ A (остальной файл):
check_expr(ctx, arg, expected_type)  // panic: "Type Error: ожидался '%s', получен '%s'"

// Способ B (мой Variant Ctor):
actual := prune_type(infer_expr(ctx, arg))
if !unify_types(actual, expected) {
    fmt.panicf("Type Error: у варианта '%s.%s' поле #%d ...", ...)  // подробная
}
```

**Почему больно**.
- Кто-то, читающий файл, не поймёт, какой из способов "правильный".
- При добавлении новой конструкции придётся выбрать (и, вероятно, скопировать
  один из способов).

**Фикс**. Расширить `check_expr` с опциональным контекстным префиксом:

```odin
check_expr_ctx :: proc(
    ctx: ^Type_Ctx, expr: Expr, expected: ^Type,
    on_mismatch: proc(actual, expected: ^Type),
    loc := #caller_location,
) {
    actual := prune_type(infer_expr(ctx, expr))
    actual = prune_type(actual)
    if !unify_types(actual, prune_type(expected)) {
        on_mismatch(actual, prune_type(expected))
    }
}
```

Обычный `check_expr` — обёртка с дефолтным `on_mismatch = fmt.panicf(...)`.
Кастомная диагностика:

```odin
check_expr_ctx(ctx, arg, expected_field, proc(actual, expected) {
    fmt.panicf(
        "Type Error: у варианта '%s.%s' поле #%d ожидает '%s', получено '%s'",
        owner_type.name, variant.name, i, expected.name, actual.name,
    )
})
```

**Effort**: LOW. ~30 минут. Требует придумать API для передачи closure'а
или flag'а.

**Line delta**: ~0 (в целом).

**Стоит ли делать**: связано с P8. Если делать multi-error accumulation,
это API станет частью большого редизайна. Сейчас — мелкое улучшение.

---

## 4. Мелочи

### P12. Лишние `prune_type` вызовы

**Где**: 40+ вхождений `prune_type(x)`.

**Что**. Некоторые — идемпотентны:

```odin
actual := prune_type(infer_expr(...))
actual = prune_type(actual)   // ← бесполезно
```

`prune_type` идемпотентен, но не помечен как таковой. Odin компилятор
не оптимизирует.

**Фикс**. Пройти по файлу, убрать вложенные вызовы. Или добавить
early-return:

```odin
prune_type :: proc(t: ^Type) -> ^Type {
    if t == nil do return nil
    if t.kind != .InferVar do return t   // ранний выход
    if t.binding == nil do return t
    resolved := prune_type(t.binding)
    t.binding = resolved
    return resolved
}
```

**Effort**: LOW. 15 минут.

**Line delta**: −20 строк (убрать двойные вызовы).

---

### P13. `Type_Ident` — 5 if-else по имени базового типа

**Где**: `type_cheker.odin:906-916`.

**Что**.

```odin
if n.name == "Число" do return TY_NUM
if n.name == "Булево" do return TY_BOOL
if n.name == "Строка" do return TY_STRING
if n.name == "Пусто" do return TY_VOID
if n.name == "Ошибка" do return TY_ERROR
if sym := lookup_symbol(...); sym != nil { ... }
```

**Фикс**.

```odin
BASE_TYPES := map[string]^Type {
    "Число"   = TY_NUM,
    "Булево"  = TY_BOOL,
    "Строка"  = TY_STRING,
    "Пусто"   = TY_VOID,
    "Ошибка"  = TY_ERROR,
    "Никогда" = TY_NEVER,  // ← бонус, сейчас забыто
}

if t, ok := BASE_TYPES[n.name]; ok do return t
if sym := lookup_symbol(...); sym != nil { ... }
```

**Effort**: LOW. 10 минут.

**Line delta**: −5 строк.

**Дополнительный бонус**: замечен пропущенный `Никогда` в текущем коде
— `resolve_type_node` для `Type_Ident{name = "Никогда"}` падает, потому
что символа `Никогда` нет в глобальном scope. Если пользователь напишет
`функ f() -> Никогда`, будет ошибка. Правится вместе с этим рефакторингом.

---

### P14. `Match_Arm_Info` — пустой wrapper

**Где**: `type_cheker.odin:146-148`.

**Что**.

```odin
Match_Arm_Info :: struct {
    pattern: Pattern_Info,
}
```

Одно поле. Излишний уровень indirection.

**Фикс**.

```odin
// Убрать структуру, использовать Pattern_Info напрямую:
match_arm_infos: map[^Match_Expr][dynamic]Pattern_Info,
```

Все места `arm_info.pattern` → `pattern_info`.

**Effort**: LOW. 15 минут.

**Line delta**: −10 строк.

**Обоснование wrapper'а**: было создано на будущее (arm-level info кроме
pattern — например, guard'ы). Пока guard'ов нет, wrapper — over-engineering.

---

### P15. `variant_calls` + `variant_idents` — две карты для одной концепции

**Где**: `type_cheker.odin:363,364`, компилятор `compiler.odin:415,590`.

**Что**. Разница между картами — arity: `variant_idents` для `Круг`
(arity 0), `variant_calls` для `Круг(3)` (arity>0).

Оба содержат одну и ту же `Variant_Call_Info`. Компилятор проверяет обе:

```odin
// Ident_Expr case:
if info, is_variant := ctx.tc.variant_idents[expr]; is_variant { ... }

// Call_Expr case:
if info, is_variant := ctx.tc.variant_calls[expr]; is_variant { ... }
```

**Почему больно**. См. P4. Раскол одной концепции на два имени.

**Фикс**. Одна карта:

```odin
variant_ctors: map[Expr]Variant_Ctor_Info,
```

Компилятор в обоих случаях (Ident и Call) проверяет одну карту. Arity
считывается из `info.arity`.

**Effort**: LOW. Часть P4 или отдельная 20-минутная правка.

**Line delta**: −5 строк.

---

## 5. Прогнозируемая экономия строк

| Правка | Строк меньше | Ясность | Effort |
|--------|--------------|---------|--------|
| P1 (split infer_expr) | 0 (структура) | ★★★★★ | MEDIUM |
| P2 (variant ctor helper) | −140 | ★★★★★ | LOW |
| P3 (variant_index) | −24 | ★★★ | LOW |
| P4 (Call_Info унификация) | −60 | ★★★★★ | MEDIUM |
| P5 (synth cache) | +5, но 0 утечек | ★★ | LOW |
| P6 (data-driven builtins) | −90 | ★★★★ | MEDIUM |
| P7 (Ctx split) | 0 | ★★★ | MEDIUM |
| P8 (multi-error) | +200 | ★★★★★ (UX) | HIGH |
| P9 (проходы) | +30, но локализовано | ★★★ | MEDIUM |
| P10 (is_constructor) | часть P4 | часть P4 | часть P4 |
| P11 (check_expr унификация) | 0 | ★★ | LOW |
| P12 (prune_type шум) | −20 | ★ | LOW |
| P13 (BASE_TYPES map) | −5 + fix Никогда | ★★ | LOW |
| P14 (Match_Arm_Info) | −10 | ★★ | LOW |
| P15 (variant_calls unify) | часть P4 | часть P4 | часть P4 |
| **Итого без P8** | **−349 строк** | | |
| **Итого с P8** | **−149 строк** (но с многозначительной UX-фичей) | | |

**File перестанет быть монстром на 2359 строк** — станет **~2000 строк**
и, что важнее, будет структурирован по обязанностям.

---

## 6. Приоритизация волнами

### Волна 1 — быстрые победы (1 вечер, ~2 часа)

Собрать в один commit «расчистка на месте», нулевой риск:

- **P2** — helper `resolve_variant_ctor` (−140 строк).
- **P3** — `variant_index` map (−24 строки).
- **P5** — synth cache (устраняет утечки).
- **P12** — убрать двойные `prune_type` (−20 строк).
- **P13** — BASE_TYPES map + fix `Никогда` (−5 + баг-фикс).
- **P14** — убрать `Match_Arm_Info` wrapper (−10 строк).
- **P15** — унифицировать `variant_calls`+`variant_idents` (−5 строк
  в type checker'е, −5 в compiler'е).

**Итог волны 1**: −209 строк, 0 нового кода, читаемость лучше, утечек
меньше, `Никогда` в аннотации типа работает.

**Тесты**: все 38 проходят без изменений.

### Волна 2 — структурная (1 день, ~6 часов)

- **P1** — split `infer_expr` на процедуры по case (структура).
- **P4** — унифицировать side-tables в `Call_Info` (−60 строк).
- **P6** — data-driven `builtin_constructor_type` и `standard_method_type`
  (−90 строк).

**Итог волны 2**: file распадается на управляемые части, ещё −150 строк.

**Тесты**: могут потребовать точной сверки exact-match error strings.
Не блокирует, но требует внимания.

### Волна 3 — архитектурная (2–3 дня, ~12+ часов)

- **P7** — разделение symbol_types на readonly + derived.
- **P8** — multi-error diagnostic accumulation (**новая фича**, а не
  рефакторинг).
- **P9** — явные проходы `typecheck_program` через enum + процедуры.
- **P11** — унифицированный `check_expr_ctx` с колбэком.

Волна 3 стоит только если запланировано:
- IDE-mode (incremental type check),
- многоошибочный вывод для больших программ,
- скоро придут generics/associated types.

Если ничего из этого не планируется — волна 3 = perfectionism.

---

## 7. Альтернатива: разделение файла на модули

После волны 1 + 2 файл `type_cheker.odin` можно разделить на несколько
файлов внутри одного `main` package:

```
type_cheker.odin          # Type, Type_Kind, Type_Ctx, диспатчер
typecheck_program.odin    # typecheck_program + проходы
typecheck_stmt.odin       # infer_stmt, check_stmt
typecheck_call.odin       # infer_call_expr + resolve_variant_ctor
typecheck_match.odin      # infer_match_expr, classify_pattern, check_match_coverage
typecheck_builtins.odin   # BUILTINS таблица + handler'ы
typecheck_methods.odin    # OPTION_METHODS, RESULT_METHODS, ARRAY_METHODS, MAP_METHODS
typecheck_prop.odin       # infer_property_expr (module.имя, obj.поле)
type_unify.odin           # unify_types, prune_type, infer_var infrastructure
```

**Плюсы**:
- Каждый файл — ~200–300 строк, обозрим.
- Клоны/дубликаты сложнее (при чтении одной темы видишь только её).
- Меньше merge-конфликтов между разными фичами (Call изменяется в одном
  файле, Match — в другом).

**Минусы**:
- Odin package — единое пространство имён. Раскладка по файлам не даёт
  privacy, но даёт визуальную группировку.
- Одноразовая работа по расстановке procs.

**Рекомендация**: начать после волны 2. Волна 1 фиксирует внутреннюю
структуру достаточно, чтобы split не был поверхностным.

---

## 8. Migration path и меры безопасности

### Как не сломать существующие тесты

1. **Волну 1 делать по одному fix'у** — commit per P#. Прогонять
   `odin test .` между каждым.
2. **Волну 2** — feature-branch, крупные шаги: split infer_expr, потом
   Call_Info, потом data-driven. Между шагами — regression check.
3. **Волну 3** — как отдельные фичи через `/speckit-specify`, потому что
   это не рефакторинг, а расширение.

### Про exact-match error strings в тестах

Существующие негативные тесты используют `testing.expect_assert(t, exact)`.
Odin в новых версиях сравнивает по полному равенству строки. При
рефакторинге сообщений (P6, P11) любое изменение формулировки — падение
теста.

**Правило**: сообщения переносятся из inline `fmt.panicf` в handler
функции без правки текста. Если нужно улучшить формулировку — делать
отдельным commit'ом с одновременным обновлением всех связанных тестов.

### Про memory-tracker

Odin memory-tracker в debug-режиме печатает `+++ leak` для каждой
незакрытой аллокации. Волна 1 (P5 — synth cache) уменьшит эти сообщения.
Волна 2 сохранит текущий уровень. Полное устранение утечек — отдельная
работа (тестовые прогоны создают ~50 leak-записей на файл).

---

## 9. Что не является проблемой

Защита от over-refactor: перечислю места, которые выглядят подозрительно,
но менять их не стоит.

- **`ensure_type_resolved` и `has_unresolved_infer_vars`** — специфика
  Hindley-Milner-lite. Внутри уместно.
- **Тройной обход `typecheck_program`** — оправдан forward references.
  Проход 1 создаёт placeholder'ы, проход 2 заполняет — это стандартная
  практика для nominal typing с recursion.
- **`unify_types` через `bind_infer_var`** — уместное occurs-check и
  binding. Не переусложнено, а необходимо для корректности.
- **`check_expr` с `#caller_location`** — Odin-специфичная возможность
  отладки, оставляет location в panic-сообщении. Не удалять.
- **`variant_calls` содержит `owner_type`** (не только tag_index) — нужен
  компилятору для эмиссии `type_name` в Build_Variant. Не убирать.

---

## 10. Итог и рекомендации

**Диагноз**: файл `type_cheker.odin` — не плохой код, но перерос свой
дизайн. Инкрементальные фичи (structs → interfaces → collections → Option
→ Result → ADT → match) добавили специальные пути в общий infer_expr без
периодической консолидации.

**Симптомы**: 854-строчный `infer_expr`, 11 side-tables, дубликаты
Variant_Ctor логики, boilerplate в builtin/method-табличках.

**Рекомендуемое лечение**:

- **Немедленно** (следующая PR-сессия): Волна 1. 2 часа, −209 строк, 0
  риска. Прямая выгода.
- **В ближайшую неделю**: Волна 2. 1 день, структурное улучшение, −150
  строк, split возможен после.
- **По необходимости** (когда планируется IDE-mode или generics): Волна 3.
  Отдельные /speckit-specify циклы.

**Приоритет одной правки, если бы делать только одну**: **P2**
(`resolve_variant_ctor` helper). Убирает 140 строк дупликата, ноль риска,
20 минут работы.

**Приоритет одной правки для UX**: **P8** (multi-error accumulation),
но это фича, не рефакторинг.

---

**Источник данных**: коммиты `314d894`, `8fdf931`, `cae8257`, `8b2779e`,
`e41f3cc` в ветке `001-adt-pattern-matching`. Тесты 38/38 проходят,
`test.ps` работает без регрессий. Анализ — статический (чтение файлов),
без run-time профилирования.
